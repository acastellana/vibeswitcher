import Foundation
import VibeCore

/// The engine's side of the feature plugins (docs/superpowers/specs/2026-11-22-v2-feature-plugins.md): which are on (the
/// vault's record, `PluginRegistry`), turning one on or off (`vibeswitcher plugin on|off NAME`, after `Requests.voiced`),
/// the 15 s look (each plugin that is on looks at its requests; an off one's folder is emptied unread), an answer on a
/// plugin's card (the core's checks, the card marked, then the plugin's `perform`), a plugin turned off withdrawing its
/// open cards and telling their askers, and `status`'s notice for each card waiting on the user. On `queue`.
extension LeadEngine {
    /// How often the plugins look.
    static let pluginLookEvery = 15

    /// The desk `plugin` works through.
    func desk(_ plugin: FeaturePlugin) -> PluginDesk { PluginDesk(engine: self, plugin: plugin) }

    /// Asks the vault which plugins the user set (at each welcome, and at a look while it hasn't said). `then` on `queue`
    /// once it answered or couldn't. On `queue`.
    func askPlugins(then: (() -> Void)? = nil) {
        guard !pluginAsking else { then?(); return }
        pluginAsking = true
        let client = link.vaultV2
        pluginWork.async { [weak self] in
            let kept = Result { try client.plugins() }
            self?.queue.async {
                guard let self else { return }
                self.pluginAsking = false
                switch kept {
                case .success(let kept): self.keptPlugins(kept)
                case .failure(let error): self.note("plugins: the vault didn't say which are on (\(error)); each stays as it was")
                }
                then?()
            }
        }
    }

    /// The vault keeps `kept`: the registry takes it; a plugin no longer on withdraws its open cards; the mirror is
    /// written; one newly on looks. On `queue`.
    func keptPlugins(_ kept: [String: Bool]) {
        let wasOn = Set(plugins.known ? plugins.onIDs : [])
        plugins.kept = kept
        for plugin in plugins.plugins where wasOn.contains(plugin.info.id) && !plugins.isOn(plugin.info.id) { withdraw(plugin) }
        let (data, file) = (plugins.mirror, root.appendingPathComponent("plugins.json"))
        let note = self.note
        pluginWork.async {
            do { try VibePaths.writePrivate(data, to: file) } catch { note("plugins: \(file.lastPathComponent) not written: \(error)") }
        }
        if plugins.on.contains(where: { !wasOn.contains($0.info.id) }) { lookAtPlugins() }
    }

    /// The user's `plugin on|off NAME` (`Requests.voiced` passed it, and the vault recorded the action): kept in the vault,
    /// then taken (`keptPlugins`). `then` on `queue`. On `queue`.
    func setPlugin(_ id: String, on: Bool, then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        guard let plugin = plugins.plugin(id) else {
            return then(.failure(.gone("no plugin \(ConfigSeal.inert(id, limit: 40)) in this build: `vibeswitcher plugin list` lists them")))
        }
        if on, let why = plugin.availability() { return then(.failure(.refused("\(plugin.info.title) can't run on this node: \(why)"))) }
        let client = link.vaultV2
        let open = cards.list().filter { $0.plugin?.plugin == id }.count
        pluginWork.async { [weak self] in
            let kept = Result { try client.setPlugin(id, on: on) }
            self?.queue.async {
                guard let self else { return }
                switch kept {
                case .failure(let error):
                    then(.failure(.refused("the session host's vault didn't keep it, so nothing changed: \(error)")))
                case .success(let kept):
                    self.note("plugin \(id) turned \(on ? "on" : "off") by the user")
                    self.keptPlugins(kept)
                    then(.success(.object(["plugin": .string(id), "on": .bool(self.plugins.isOn(id)),
                                           "withdrawn": .int(on ? 0 : open)])))
                }
            }
        }
    }

    /// Each plugin that is on looks at its requests; an off one's folder is emptied unread (what its command filed
    /// anyway, or a file put there). `done` on `queue` once every look is done. On `queue`.
    func lookAtPlugins(done: (() -> Void)? = nil) {
        guard plugins.known else {
            return askPlugins { [weak self] in
                guard let self, self.plugins.known else { done?(); return }
                self.lookAtPlugins(done: done)
            }
        }
        var waiting = 1
        let finish = { waiting -= 1; if waiting == 0 { done?() } }
        for plugin in plugins.plugins {
            let id = plugin.info.id
            if plugins.isOn(id) {
                waiting += 1
                // One look at a time: a look under way is waited for, not started again.
                if pluginLooking[id] != nil {
                    pluginLooking[id]?.append(finish)
                    continue
                }
                pluginLooking[id] = [finish]
                plugin.look(desk(plugin)) { [weak self] in
                    self?.queue.async {
                        guard let self else { return }
                        let waiters = self.pluginLooking.removeValue(forKey: id) ?? []
                        waiters.forEach { $0() }
                    }
                }
            } else if let folder = desk(plugin).folder {
                waiting += 1
                let note = self.note
                pluginWork.async { [weak self] in
                    let dropped = Self.dropUnread(folder)
                    if dropped > 0 { note("plugin \(id) is off: \(dropped) file(s) in \(folder.lastPathComponent) dropped unread") }
                    self?.queue.async { finish() }
                }
            }
        }
        finish()
    }

    /// Removes every file and link in `folder` (not a folder inside it), reading none: how many. Blocks: on `pluginWork`.
    static func dropUnread(_ folder: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var dropped = 0
        for name in names {
            let path = folder.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR else { continue }
            if unlink(path) == 0 { dropped += 1 }
        }
        return dropped
    }

    /// The user's answer `text` on a plugin's card (`answer CARD WORD`, after `Requests.voiced`): the plugin is on, the
    /// word is one of the card's actions, the card is open and waiting, an acting one isn't past its time; then the card
    /// takes the action's mark at once (a second answer finds it answered) and the plugin performs it. On `queue`.
    func answerPlugin(_ card: CardStore.Card, text: String, then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        guard let shown = card.plugin, let plugin = plugins.plugin(shown.plugin) else {
            return then(.failure(.gone("no plugin's request on card \(card.id)")))
        }
        guard plugins.isOn(shown.plugin) else {
            return then(.failure(.refused("this node doesn't have \(plugin.info.title) on: nothing was done")))
        }
        guard let action = shown.action(text) else {
            let words = shown.actions.map(\.word)
            return then(.failure(.badArgs("a \(shown.noun) card is answered \(words.joined(separator: " or ")) "
                                          + "(`vibeswitcher answer \(card.id) \(words.first ?? "")`)")))
        }
        guard card.isOpen, shown.isWaiting else {
            return then(.failure(.refused("card \(card.id) is answered already: \(card.closed ?? shown.state)")))
        }
        if action.acts, let expires = shown.expiresAt, pluginNow() >= expires {
            return then(.failure(.refused("it expired: nothing ran")))
        }
        var marked = card
        marked.plugin?.state = action.marks
        cards.put(marked)
        plugin.perform(action.word, on: marked, desk: desk(plugin), then: then)
    }

    /// `plugin` was turned off: each open card of its closes as withdrawn, its asker is told, and the plugin keeps that
    /// nothing more comes of it. On `queue`.
    func withdraw(_ plugin: FeaturePlugin) {
        let desk = desk(plugin)
        for var card in cards.list() where card.plugin?.plugin == plugin.info.id {
            guard var shown = card.plugin else { continue }
            shown.state = PluginCard.withdrawnState
            shown.outcome = "Withdrawn: you turned \(plugin.info.title) off"
            card.plugin = shown
            card.closed = "withdrawn: \(plugin.info.title) was turned off on this node; nothing ran"
            cards.put(card)
            note("plugin \(plugin.info.id) off: card \(card.id) withdrawn")
            if let session = PluginDesk.hostSession(shown.session) {
                desk.tell(desk.withdrawnText(shown), from: "from VibeSwitcher", session: session) { _ in }
            }
            plugin.withdrawn(shown, desk: desk)
        }
    }

    /// `status`'s notice for each plugin card waiting on the user, then each plugin's own. On `queue`.
    var pluginNotices: [String] {
        let waiting = cards.list().compactMap { card -> String? in
            guard card.kind == .plugin, let shown = card.plugin, shown.isWaiting, plugins.isOn(shown.plugin) else { return nil }
            let inert = { (text: String) in ConfigSeal.inert(text, limit: 300) }
            let answers = shown.actions.enumerated().map { index, action in
                "`vibeswitcher answer \(card.id) \(action.word)` \(index == 0 ? "shows it whole and " : "")\(inert(action.short))"
            }.joined(separator: ", ")
            return "a \(inert(shown.noun)) waits for you: \(inert(shown.asker)) \(inert(shown.summary)). \(answers)"
                + (shown.expiresAt.map { "; it expires at \(NodeWire.dateText($0))" } ?? "")
        }
        return waiting + plugins.on.flatMap { $0.notices(desk($0)) }
    }
}
