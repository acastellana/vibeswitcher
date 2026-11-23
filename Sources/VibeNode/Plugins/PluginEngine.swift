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
        // An ask under way read the vault before this was asked (an add or a remove may have just written it): this waits
        // for the next ask, which follows it.
        guard !pluginAsking else {
            if let then { pluginAskNextWaiters.append(then) }
            pluginAskAgain = true
            return
        }
        if let then { pluginAskWaiters.append(then) }
        pluginAsking = true
        let client = link.vaultV2
        let writes = pluginWrites
        pluginWork.async { [weak self] in
            let kept = Result { try client.plugins() }
            let settled = Result { try client.settledRequests() }
            let since = try? client.recordSince()
            let settings = try? client.pluginSettings()
            let builtIn = self?.plugins.builtIn ?? []
            let external = (try? client.externalPlugins()).map { Self.externalPlugins($0, builtIn: builtIn) }
            self?.queue.async {
                guard let self else { return }
                self.pluginAsking = false
                // A write queued after this ask's reads (the work queue is serial): its answer predates it, so it isn't
                // taken (it would turn back what the user just set); the next ask, after the write, answers its waiters.
                if self.pluginWrites != writes {
                    self.pluginAskNextWaiters = self.pluginAskWaiters + self.pluginAskNextWaiters
                    self.pluginAskWaiters = []
                    self.pluginAskAgain = false
                    let next = self.pluginAskNextWaiters
                    self.pluginAskNextWaiters = []
                    return self.askPlugins { next.forEach { $0() } }
                }
                if let since { self.pluginRecordSince = since }
                if let settings { self.pluginSettings = settings }
                if let external { self.plugins.takeExternal(external.mapValues(\.record)) { id, _ in external[id] } }
                // Not known (the vault didn't answer): nothing is drawn until it does.
                switch settled {
                case .success(let keys):
                    self.pluginSettled.formUnion(keys)
                    self.pluginSettledKnown = true
                case .failure(let error):
                    self.note("plugins: the vault didn't say which requests are settled (\(error)); nothing is drawn until it does")
                }
                let waiters = self.pluginAskWaiters
                self.pluginAskWaiters = []
                if self.pluginAskAgain {
                    self.pluginAskAgain = false
                    let next = self.pluginAskNextWaiters
                    self.pluginAskNextWaiters = []
                    self.pluginAskWaiters = next
                    defer { self.askPlugins() }
                }
                switch kept {
                // Its waiters hear once the mirror and the wrappers are written: what a reply says is on, a filer finds on.
                case .success(let kept): self.keptPlugins(kept) { waiters.forEach { $0() } }
                case .failure(let error):
                    self.note("plugins: the vault didn't say which are on (\(error)); each stays as it was")
                    waiters.forEach { $0() }
                }
            }
        }
    }

    /// `wrappers` (command name: plugin id) as the scripts in `bin`, and nothing else there. Blocks.
    static func writeWrappers(_ wrappers: [String: String], in bin: URL, note: (String) -> Void) {
        // The node's own folder, never through a link: else nothing is written or removed (the review of step C, L4).
        let root = bin.deletingLastPathComponent().deletingLastPathComponent()
        if case .failure(let why) = PluginFolders.own(bin, root: root) { return note("plugins: no wrappers written: \(why)") }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? [] where wrappers[name] == nil {
            unlink(bin.appendingPathComponent(name).path)
        }
        for (name, id) in wrappers {
            let script = "#!/bin/sh\n# The node's wrapper for its external plugin \(id): `vibeswitcher plugin list`.\nexec vs-ask \(id) -- \"$@\"\n"
            let file = bin.appendingPathComponent(name)
            do {
                try VibePaths.writePrivate(Data(script.utf8), to: file)
                chmod(file.path, 0o700)
            } catch { note("plugins: the wrapper \(name) not written: \(error)") }
        }
    }

    /// The external plugins the vault's records name, each built from its folder's manifest as it is now: one whose
    /// manifest no longer reads, or reads another hash, is held (it runs nothing until added again). Reads the disk.
    static func externalPlugins(_ records: [String: String], builtIn: Set<String>) -> [String: ExternalPlugin] {
        var made: [String: ExternalPlugin] = [:]
        for (id, text) in records {
            guard let record = PluginRecord.read(text) else { continue }
            let bytes = PluginDesk.bounded(URL(fileURLWithPath: record.folder).appendingPathComponent(PluginManifest.fileName), limit: PluginManifest.bytesAtMost)
            if let bytes, BuildInfo.sha256(of: bytes) == record.manifest, case .success(let manifest) = PluginManifest.read(bytes, builtIn: builtIn), manifest.id == id {
                made[id] = ExternalPlugin(manifest: manifest, record: record)
            } else {
                let held = PluginManifest(protocol: 1, id: id, version: "?", title: id, summary: "an external plugin whose folder changed", program: "?",
                                          commands: nil, settings: nil, brief: nil, life: nil, lifeWhy: nil, page: nil, defaultOn: nil)
                made[id] = ExternalPlugin(manifest: held, record: record,
                                          held: "its manifest changed since you added it, or isn't there: `vibeswitcher plugin add \(record.folder)` again")
            }
        }
        return made
    }

    /// The vault keeps `kept`: the registry takes it; a plugin no longer on withdraws its open cards; the mirror is
    /// written; one newly on looks. On `queue`.
    /// `written` hears (on `queue`) once the mirror and the wrappers are on disk: a reply that says a plugin is on is sent
    /// only then, so a filer started right after it (`vs-ask` reads the mirror) finds it on.
    func keptPlugins(_ kept: [String: Bool], written: (() -> Void)? = nil) {
        let wasOn = Set(plugins.known ? plugins.onIDs : [])
        plugins.kept = kept
        for plugin in plugins.plugins where wasOn.contains(plugin.info.id) && !plugins.isOn(plugin.info.id) { withdraw(plugin) }
        let (data, file) = (plugins.mirror, root.appendingPathComponent("plugins.json"))
        let note = self.note
        // The external plugins' wrappers (`vs-<name> …` is `vs-ask <id> -- …`), only while each is on.
        let wrappers = Dictionary(plugins.on.compactMap { $0 as? ExternalPlugin }.flatMap { plugin in
            plugin.info.commands.map { ($0.name, plugin.info.id) }
        }) { first, _ in first }
        let bin = root.appendingPathComponent("plugins/bin", isDirectory: true)
        let queue = self.queue
        pluginWork.async {
            do { try VibePaths.writePrivate(data, to: file) } catch { note("plugins: \(file.lastPathComponent) not written: \(error)") }
            Self.writeWrappers(wrappers, in: bin, note: note)
            if let written { queue.async(execute: written) }
        }
        if plugins.on.contains(where: { !wasOn.contains($0.info.id) }) { lookAtPlugins() }
    }

    /// The user's `plugin on|off NAME` (`Requests.voiced` passed it, and the vault recorded the action): kept in the vault,
    /// then taken (`keptPlugins`). `then` on `queue`. On `queue`.
    func setPlugin(_ id: String, on: Bool, then: @escaping (Result<NodeWire.Value, CardFailure>) -> Void) {
        guard let plugin = plugins.plugin(id) else {
            return then(.failure(.gone("no plugin \(ConfigSeal.inert(id, limit: 40)) in this build: `vibeswitcher plugin list` lists them")))
        }
        // An external plugin whose program ended starts afresh when the user turns it on again.
        if on, let external = plugin as? ExternalPlugin, external.held == nil { external.ended = nil }
        if on, let why = plugin.availability() { return then(.failure(.refused("\(plugin.info.title) can't run on this node: \(why)"))) }
        let client = link.vaultV2
        let open = cards.list().filter { $0.plugin?.plugin == id }.count
        pluginWrites += 1
        pluginWork.async { [weak self] in
            let kept = Result { try client.setPlugin(id, on: on) }
            self?.queue.async {
                guard let self else { return }
                switch kept {
                case .failure(let error):
                    then(.failure(.refused("the session host's vault didn't keep it, so nothing changed: \(error)")))
                case .success(let kept):
                    self.note("plugin \(id) turned \(on ? "on" : "off") by the user")
                    self.keptPlugins(kept) { [weak self] in
                        guard let self else { return }
                        then(.success(.object(["plugin": .string(id), "on": .bool(self.plugins.isOn(id)), "withdrawn": .int(on ? 0 : open)])))
                    }
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
        // An external plugin's every answer that reaches its program is acting: it chose `acts` itself, so its word for
        // it doesn't skip expiry, the live asker or the settle first (the review of step C, M1).
        let acting = action.acts || plugin is ExternalPlugin
        if acting, let expires = shown.expiresAt, pluginNow() >= expires {
            return then(.failure(.refused("it expired: nothing ran")))
        }
        // The asker still a live session the user opened (it may have ended since the card was drawn).
        let desk = desk(plugin)
        guard !acting || PluginDesk.hostSession(shown.session).flatMap({ id in link.sessions.first { $0.id == id } }).map(desk.opened) == true else {
            return then(.failure(.refused("its asking session isn't live any more: nothing ran")))
        }
        var marked = card
        marked.plugin?.state = action.marks
        cards.put(marked)
        let key = PluginKey(plugin: shown.plugin, request: shown.request).name
        let acts = action.acts
        let act = PluginAct(start: { [link] request, done in link.spawn(request, completion: done) },
                            page: { [weak self] spec, take, ended, opened in
                                guard acts else { return opened(.failure(PluginRefusal("only an acting answer opens a page"))) }
                                self?.openPluginPage(spec, plugin: shown.plugin, key: key, take: take, ended: ended, then: opened)
                            })
        // The page's address, the core's to print: in this answer's reply only (the review of 6e91f053, L1).
        let given = then
        let then: (Result<NodeWire.Value, CardFailure>) -> Void = { [weak self] result in
            let say = self?.pluginPageSay(key)
            guard case .success(.object(var fields)) = result, let say else { return given(result) }
            fields["say"] = .array(say + (fields["say"]?.array ?? []))
            fields["once"] = .bool(true)
            given(.success(.object(fields)))
        }
        guard acting else { return plugin.perform(action.word, on: marked, desk: desk, act: act, then: then) }
        // An acting answer: settled in the vault, confirmed, before it acts, so no restart draws it again.
        let client = link.vaultV2
        pluginSettling.insert(key)
        pluginWork.async { [weak self] in
            let kept = Result { try client.settleRequests([key]) }
            self?.queue.async {
                guard let self else { return }
                self.pluginSettling.remove(key)
                switch kept {
                case .success:
                    self.pluginSettled.insert(key)
                    // Turned off (or the card withdrawn) while the vault was asked: nothing runs; the settle stands.
                    guard self.plugins.isOn(shown.plugin), let now = self.cards.cards[marked.id], now.isOpen,
                          now.plugin?.state == action.marks else {
                        self.note("plugin \(shown.plugin): card \(marked.id) not acted on: turned off while it was being answered")
                        if let session = PluginDesk.hostSession(shown.session) {
                            self.tellSurely("[VibeSwitcher] Your \(shown.noun) \(shown.request) wasn't done: the user turned \(plugin.info.title) off "
                                            + "before it ran.", session: session, key: "\(shown.plugin):\(shown.request):not-run")
                        }
                        return then(.failure(.refused("\(plugin.info.title) was turned off while it was being answered: nothing ran")))
                    }
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
    func withdraw(_ plugin: FeaturePlugin, ended: String? = nil) {
        let desk = desk(plugin)
        // Its page goes with it (the review of 6e91f053, M2): the host lets the port go, then the slot is freed.
        if let slot = pluginPage, slot.plugin == plugin.info.id { slot.page.stop() }
        let title = plugin.info.title
        for var card in cards.list() where card.plugin?.plugin == plugin.info.id {
            guard var shown = card.plugin else { continue }
            // Already being acted on (an answer marked it): what it started may run; say what is true.
            let underWay = !shown.isWaiting && !pluginSettling.contains(PluginKey(plugin: shown.plugin, request: shown.request).name)
            shown.state = PluginCard.withdrawnState
            if let ended {
                let said = ConfigSeal.inert(ended, limit: 200)
                shown.outcome = "Withdrawn: its program ended (\(said))"
                card.closed = "withdrawn: \(title)'s program ended (\(said))" + (underWay ? "; what the answer started may still run" : "; nothing ran")
            } else {
                shown.outcome = "Withdrawn: you turned \(title) off" + (underWay ? " while it was being answered" : "")
                card.closed = underWay ? "withdrawn: \(title) was turned off while it was being answered; what that started may still run"
                    : "withdrawn: \(title) was turned off on this node; nothing ran"
            }
            card.plugin = shown
            cards.put(card)
            desk.settle(shown.request)
            note("plugin \(plugin.info.id) \(ended == nil ? "off" : "ended"): card \(card.id) withdrawn")
            // The plugin keeps that nothing more comes of it (its words count only when it was turned off).
            let own = plugin.withdrawn(shown, desk: desk)
            if let session = PluginDesk.hostSession(shown.session) {
                if let ended {
                    desk.tellSurely(desk.endedText(shown, why: ConfigSeal.inert(ended, limit: 200)), session: session)
                } else {
                    desk.tellSurely(own ?? (underWay ? desk.withdrawnWhileAnsweredText(shown) : desk.withdrawnText(shown)), session: session)
                }
            }
        }
        guard ended == nil else { return }
        for (session, text) in plugin.turnedOff(desk) { desk.tellSurely(text, session: session) }
    }

    /// Serves a plugin's page once (`PluginPage`), one at a time on the node, for `plugin`'s request `key`: started off
    /// the engine's queue (the host binds its socket); every callback on the engine's queue. The slot is freed only once
    /// the host let the port go, however the page ends (a failed start too: the review of 6e91f053, L6). Its address is
    /// kept for the answer's reply (`pluginPageLines`), never handed to the plugin (L1). On `queue`.
    func openPluginPage(_ spec: PluginPage.Spec, plugin: String, key: String, take: @escaping (Data, @escaping (Bool) -> Void) -> Void,
                        ended: @escaping (Bool) -> Void, then: @escaping (Result<Void, PluginRefusal>) -> Void) {
        guard pluginPage == nil else { return then(.failure(PluginRefusal("a plugin's page is open already: answer it, or wait for it to stop"))) }
        let slot = PluginPageSlot(page: PluginPage(spec: spec), plugin: plugin, key: key)
        pluginPage = slot
        let (bind, clock, queue, page) = (options.pluginBind ?? .direct, clock ?? pluginClock, self.queue, slot.page)
        pluginWork.async { [weak self] in
            let started = Result {
                try page.start(bind: bind, clock: clock, take: { bytes, answer in queue.async { take(bytes, answer) } }, ended: { taken in
                    queue.async {
                        if self?.pluginPage === slot { self?.pluginPage = nil }
                        // A page that never opened ends nothing of the plugin's: its start's failure says so.
                        if slot.opened { ended(taken) } else { slot.endedEarly = true }
                    }
                })
            }
            queue.async {
                switch started {
                case .success(let url) where !slot.endedEarly:
                    slot.opened = true
                    self?.pluginPageLines[key] = (url, spec.life)
                    then(.success(()))
                case .success:
                    then(.failure(PluginRefusal("its page stopped before it opened")))
                case .failure(let error):
                    then(.failure(error as? PluginRefusal ?? PluginRefusal("\(error)")))
                }
            }
        }
    }

    /// The lines that give the answering terminal a page's address, taken once.
    func pluginPageSay(_ key: String) -> [NodeWire.Value]? {
        guard let line = pluginPageLines.removeValue(forKey: key) else { return nil }
        return [.string("Open this page in your browser (it works once, \(max(1, Int(line.life / 60))) minutes at most):"),
                .string("  " + line.url.absoluteString)]
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

/// The node's one plugin page: the page, the plugin and request it serves, whether it opened. On the engine's queue.
final class PluginPageSlot {
    let page: PluginPage
    let plugin: String
    let key: String
    var opened = false
    var endedEarly = false
    init(page: PluginPage, plugin: String, key: String) {
        self.page = page
        self.plugin = plugin
        self.key = key
    }
}
