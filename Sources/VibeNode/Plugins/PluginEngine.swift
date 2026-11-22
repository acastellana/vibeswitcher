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
        // An ask under way: this waits for its answer (a look asked meanwhile mustn't take "not known" for an answer).
        if let then { pluginAskWaiters.append(then) }
        guard !pluginAsking else { return }
        pluginAsking = true
        let client = link.vaultV2
        pluginWork.async { [weak self] in
            let kept = Result { try client.plugins() }
            let settled = Result { try client.settledRequests() }
            let since = try? client.recordSince()
            let settings = try? client.pluginSettings()
            self?.queue.async {
                guard let self else { return }
                self.pluginAsking = false
                if let since { self.pluginRecordSince = since }
                if let settings { self.pluginSettings = settings }
                // Not known (the vault didn't answer): nothing is drawn until it does.
                switch settled {
                case .success(let keys):
                    self.pluginSettled.formUnion(keys)
                    self.pluginSettledKnown = true
                case .failure(let error):
                    self.note("plugins: the vault didn't say which requests are settled (\(error)); nothing is drawn until it does")
                }
                switch kept {
                case .success(let kept): self.keptPlugins(kept)
                case .failure(let error): self.note("plugins: the vault didn't say which are on (\(error)); each stays as it was")
                }
                let waiters = self.pluginAskWaiters
                self.pluginAskWaiters = []
                waiters.forEach { $0() }
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
        guard plugins.known, pluginSettledKnown else {
            return askPlugins { [weak self] in
                guard let self, self.plugins.known, self.pluginSettledKnown else { done?(); return }
                self.lookAtPlugins(done: done)
            }
        }
        retryPluginTells()
        expirePluginCards()
        var waiting = 1
        let finish = { waiting -= 1; if waiting == 0 { done?() } }
        for plugin in plugins.plugins {
            let id = plugin.info.id
            if plugins.isOn(id) {
                waiting += 1
                // One look at a time: asked for while one is under way, one more look follows it (the one under way may
                // have read the folder before what this is for was filed), and this waits for that one.
                if pluginLooking[id] != nil {
                    pluginLookAgain[id, default: []].append(finish)
                    continue
                }
                pluginLooking[id] = [finish]
                startLook(plugin)
            } else if let relative = plugin.info.folder {
                waiting += 1
                let (note, root) = (self.note, self.root)
                pluginWork.async { [weak self] in
                    let dropped = Self.dropUnread(root: root, relative: relative)
                    if dropped > 0 { note("plugin \(id) is off: \(dropped) file(s) in \(relative) dropped unread") }
                    self?.queue.async { finish() }
                }
            }
        }
        finish()
    }

    /// Runs `plugin`'s look; when it ends, its waiters are told, and a look asked for meanwhile starts. On `queue`.
    private func startLook(_ plugin: FeaturePlugin) {
        let id = plugin.info.id
        plugin.look(desk(plugin)) { [weak self] in
            self?.queue.async {
                guard let self else { return }
                let waiters = self.pluginLooking.removeValue(forKey: id) ?? []
                if let again = self.pluginLookAgain.removeValue(forKey: id) {
                    if self.plugins.isOn(id) {
                        self.pluginLooking[id] = again
                        self.startLook(plugin)
                    } else {
                        again.forEach { $0() }
                    }
                }
                waiters.forEach { $0() }
            }
        }
    }

    /// Removes what a plugin's command files in its folder (`relative` under `root`: `<id>.json`, `<id>.seal`,
    /// `.<id>.answer`, regular files and links, never a folder), reading none: how many. Each component of the folder is
    /// opened without following a link (a session could make `shell-requests/asked` a link to a folder of the user's),
    /// and each name is removed relative to the folder opened, so nothing outside it is touched. Blocks: on `pluginWork`.
    static func dropUnread(root: URL, relative: String) -> Int {
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return 0 }
        for part in relative.split(separator: "/") {
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { return 0 }
            fd = next
        }
        guard let directory = fdopendir(fd) else { close(fd); return 0 }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) } }
            if name.hasSuffix(".json") || name.hasSuffix(".seal") || name.hasSuffix(".answer") { names.append(name) }
        }
        var dropped = 0
        for name in names {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFLNK else { continue }
            if unlinkat(fd, name, 0) == 0 { dropped += 1 }
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
        // The asker still a live session the user opened (it may have ended since the card was drawn).
        let desk = desk(plugin)
        guard action.acts == false || PluginDesk.hostSession(shown.session).flatMap({ id in link.sessions.first { $0.id == id } }).map(desk.opened) == true else {
            return then(.failure(.refused("its asking session isn't live any more: nothing ran")))
        }
        var marked = card
        marked.plugin?.state = action.marks
        cards.put(marked)
        let act = PluginAct(start: { [link] request, done in link.spawn(request, completion: done) },
                            page: { [weak self] spec, take, ended, then in self?.openPluginPage(spec, take: take, ended: ended, then: then) })
        guard action.acts else { return plugin.perform(action.word, on: marked, desk: desk, act: act, then: then) }
        // An acting answer: settled in the vault, confirmed, before it acts, so no restart draws it again.
        let key = PluginKey(plugin: shown.plugin, request: shown.request).name
        let client = link.vaultV2
        pluginWork.async { [weak self] in
            let kept = Result { try client.settleRequests([key]) }
            self?.queue.async {
                guard let self else { return }
                switch kept {
                case .success:
                    self.pluginSettled.insert(key)
                    plugin.perform(action.word, on: marked, desk: desk, act: act, then: then)
                case .failure(let error):
                    var closed = marked
                    closed.plugin?.state = "failed"
                    closed.plugin?.outcome = "Not done: the session host's vault didn't record it"
                    closed.closed = "not done: the vault didn't record the answer, so nothing ran"
                    self.cards.put(closed)
                    then(.failure(.refused("the session host's vault didn't record it as settled, so nothing ran: \(error)")))
                }
            }
        }
    }

    /// `plugin` was turned off: each open card of its closes as withdrawn and is settled, its asker is told (until it
    /// heard, the plugin off or not), and the plugin keeps that nothing more comes of it; whoever waits on something it
    /// started is told nothing more will be said. On `queue`.
    func withdraw(_ plugin: FeaturePlugin) {
        let desk = desk(plugin)
        for var card in cards.list() where card.plugin?.plugin == plugin.info.id {
            guard var shown = card.plugin else { continue }
            // Already being acted on (an answer marked it): what it started may run; say what is true.
            let underWay = !shown.isWaiting
            shown.state = PluginCard.withdrawnState
            shown.outcome = "Withdrawn: you turned \(plugin.info.title) off" + (underWay ? " while it was being answered" : "")
            card.plugin = shown
            card.closed = underWay ? "withdrawn: \(plugin.info.title) was turned off while it was being answered; what that started may still run"
                : "withdrawn: \(plugin.info.title) was turned off on this node; nothing ran"
            cards.put(card)
            desk.settle(shown.request)
            note("plugin \(plugin.info.id) off: card \(card.id) withdrawn")
            let said = plugin.withdrawn(shown, desk: desk) ?? (underWay ? desk.withdrawnWhileAnsweredText(shown) : nil)
            if let session = PluginDesk.hostSession(shown.session) { desk.tellSurely(said ?? desk.withdrawnText(shown), session: session) }
        }
        for (session, text) in plugin.turnedOff(desk) { desk.tellSurely(text, session: session) }
    }

    /// Serves a plugin's page once (`PluginPage`), one at a time on the node: started off the engine's queue (the host
    /// binds its socket); every callback on the engine's queue. On `queue`.
    func openPluginPage(_ spec: PluginPage.Spec, take: @escaping (Data, @escaping (Bool) -> Void) -> Void, ended: @escaping (Bool) -> Void,
                        then: @escaping (Result<URL, PluginRefusal>) -> Void) {
        guard pluginPage == nil else { return then(.failure(PluginRefusal("a plugin's page is open already: answer it, or wait for it to stop"))) }
        let page = PluginPage(spec: spec)
        pluginPage = page
        let (bind, clock, queue) = (options.pluginBind ?? .direct, clock ?? pluginClock, self.queue)
        pluginWork.async { [weak self] in
            let started = Result {
                try page.start(bind: bind, clock: clock, take: { bytes, answer in queue.async { take(bytes, answer) } }, ended: { taken in
                    queue.async {
                        if self?.pluginPage === page { self?.pluginPage = nil }
                        ended(taken)
                    }
                })
            }
            queue.async {
                if case .failure = started, self?.pluginPage === page { self?.pluginPage = nil }
                then(started.mapError { $0 as? PluginRefusal ?? PluginRefusal("\($0)") })
            }
        }
    }

    /// Settles `keys` (`PluginKey.name`): never drawn again, here and in the vault. On `queue`.
    func settlePluginRequests(_ keys: [String]) {
        let new = keys.filter { pluginSettled.insert($0).inserted }
        guard !new.isEmpty else { return }
        let (client, note) = (link.vaultV2, self.note)
        pluginWork.async {
            do { try client.settleRequests(new) } catch { note("plugins: \(new.count) settled request(s) not kept in the vault: \(error)") }
        }
    }

    /// Tells `session` `text` from VibeSwitcher until it reached it or the session is gone (`pluginTells`). On `queue`.
    func tellSurely(_ text: String, session: UUID, key: String) {
        pluginTells[key] = (session, text)
        retryPluginTells()
    }

    /// Each message `pluginTells` holds, tried again (one at a time a message). On `queue`.
    func retryPluginTells() {
        for (key, entry) in pluginTells where pluginTelling.insert(key).inserted {
            tell(entry.text, from: .system("from VibeSwitcher"), session: entry.session) { [weak self] delivery in
                guard let self else { return }
                self.pluginTelling.remove(key)
                if delivery != .notYet { self.pluginTells[key] = nil }
            }
        }
    }

    /// Rule 4, the core's: an open plugin card still waiting past its expiry closes as expired, and is settled (the
    /// plugin tells its asker at its look). On `queue`.
    func expirePluginCards() {
        let now = pluginNow()
        for var card in cards.list() where card.kind == .plugin {
            guard var shown = card.plugin, shown.isWaiting, let expires = shown.expiresAt, now >= expires else { continue }
            shown.state = "expired"
            shown.outcome = "Expired unanswered"
            card.plugin = shown
            card.closed = "expired unanswered"
            cards.put(card)
            settlePluginRequests([PluginKey(plugin: shown.plugin, request: shown.request).name])
            note("plugin \(shown.plugin): card \(card.id) expired unanswered")
        }
    }

    /// `status`'s notice for each plugin card waiting on the user, then each plugin's own. The agent's words are marked as
    /// its own, quoted: the first line of what it asks. On `queue`.
    var pluginNotices: [String] {
        let waiting = cards.list().compactMap { card -> String? in
            guard card.kind == .plugin, let shown = card.plugin, shown.isWaiting, plugins.isOn(shown.plugin) else { return nil }
            let inert = { (text: String) in ConfigSeal.inert(text, limit: 300) }
            let answers = shown.actions.enumerated().map { index, action in
                "`vibeswitcher answer \(card.id) \(action.word)` \(index == 0 ? "shows it whole and " : "")\(inert(action.short))"
            }.joined(separator: ", ")
            let facts = shown.facts.filter(\.decisive).map { "\(inert($0.label)) \(inert($0.value))" }
            let first = shown.body.lines.first ?? ""
            let more = shown.body.lines.count > 1 || first.count > 100 ? " …" : ""
            return "a \(inert(shown.noun)) waits for you: \(inert(shown.asker)) \(inert(shown.ask))"
                + (facts.isEmpty ? "" : " (\(facts.joined(separator: ", ")))")
                + "; its \(inert(shown.body.name)), the agent's words: \u{201C}\(ConfigSeal.inert(String(first.prefix(100)), limit: 120))\(more)\u{201D}. \(answers)"
                + (shown.expiresAt.map { "; it expires at \(NodeWire.dateText($0))" } ?? "")
        }
        return waiting + plugins.on.flatMap { $0.notices(desk($0)) }
    }
}
