import Foundation
import VibeCore

/// What the plugin runtime needs of the engine: telling a session from VibeSwitcher, the vault the cards are built from,
/// and whether the node is a scratch one. Held weakly; asked on the engine's queue.
protocol PluginHost: AnyObject {
    /// `text` told into `session` from `from`; `then` with how it went. On the engine's queue.
    func pluginTell(_ text: String, from: SteerMessage.Sender, session: UUID, then: @escaping (SessionDelivery) -> Void)
    /// The vault the cards are built from and the stamps checked against (`LeadEngine.cardVault`).
    var pluginVault: LeadVault { get }
    /// A scratch node's (a test's): what its sessions get keeps to its root.
    var pluginIsScratch: Bool { get }
}

/// The feature plugins' runtime (docs/superpowers/specs/2026-11-22-v2-feature-plugins.md), out of the engine (the
/// architecture review's row 8): which are on (the vault's record, `PluginRegistry`), turning one on or off
/// (`vibeswitcher plugin on|off NAME`, after `Requests.voiced`), the 15 s look (each plugin that is on looks at its
/// requests; an off one's folder is emptied unread), an answer on a plugin's card (the core's checks, the card marked,
/// then the plugin's `perform`), a plugin turned off withdrawing its open cards and telling their askers, and `status`'s
/// notice for each card waiting on the user. Its state is its own, on the engine's queue; the desk (`PluginDesk`) is a
/// plugin's only window onto it, and the engine is reached only through `PluginHost`, held weakly.
final class PluginRuntime {
    let registry: PluginRegistry
    let queue: DispatchQueue
    let cards: CardStore
    private let link: HostLink
    /// The node's root and its log (what a desk hands a plugin).
    let root: URL
    private let clock: NodeClock?
    private let bind: WebBind?
    let note: (String) -> Void
    /// What it needs of the engine, held weakly.
    weak var host: PluginHost?

    /// Each plugin request's card (`PluginKey` to card id), the stamps the host vouched for (per plugin).
    private var cardsByRequest: [PluginKey: String] = [:]
    private var trusted: [String: [String: WalletStamp]] = [:]
    /// Each plugin's look under way, and who waits for its end.
    private var looking: [String: [() -> Void]] = [:]
    /// Each plugin's look asked for while one was under way (which may have read its folder before what this one is
    /// for was filed): one more look, after it, and who waits for that one.
    private var lookAgain: [String: [() -> Void]] = [:]
    private var asking = false
    /// Who waits for the vault's answer under way.
    private var askWaiters: [() -> Void] = []
    /// Waiters that came while an ask was under way, and whether another ask follows it (`ask`).
    private var askNextWaiters: [() -> Void] = []
    private var askAgain = false
    /// The plugin writes to the vault queued so far (on, off, add, remove, a setting): an ask queued before one of them
    /// read the vault before it, and its answer is stale (`ask`).
    private var writes = 0
    private var timer: Subscription?
    /// The plugin requests settled (`PluginKey.name`), as the vault keeps them: never drawn again.
    private var settled: Set<String> = []
    /// Whether the vault said which requests are settled (nothing is drawn until it did).
    private var settledKnown = false
    /// The acting answers whose settle the vault is still asked for (`PluginKey.name`): nothing has run for them yet.
    private var settling: Set<String> = []
    /// The node's one plugin page, whose plugin and request it serves (`openPage`).
    private var page: PluginPageSlot?
    /// A page's address for the answer that opened it (`PluginKey.name`): printed in that answer's reply, then let go.
    private var pageLines: [String: (url: URL, life: TimeInterval)] = [:]
    /// When the vault's record began, as the vault says (a host restart starts it over): what `plugin list` says a
    /// plugin is at its default since.
    private var since: Date?
    /// Each request the reader last gave, by `PluginKey.name`: the stamp it came with (its digest, its session) and when
    /// it was filed. What a card is drawn from, and who its tells go to.
    private var stamps: [String: PluginStamp] = [:]
    /// The digest each card was drawn from, by `PluginKey.name`: a request whose bytes changed under its id is dropped.
    private var drawn: [String: String] = [:]
    /// The sessions of a team (a worker's, a verifier's) as the vault's roster said at the last look: not the user's.
    private var team: Set<String> = []
    /// What must reach a session from VibeSwitcher even while its plugin is off (a withdrawal's words), by key, until it
    /// did or the session is gone; tried again at each plugins' look.
    private var tells: [String: (session: UUID, text: String)] = [:]
    private var telling: Set<String> = []
    /// The plugins' settings the user set, as the vault last said (`<plugin>.<name>`).
    private var settings: [String: String] = [:]
    /// A clock for the plugins' pages when the engine has none (a test's engine), on its queue.
    private lazy var pageClock = NodeClock(queue: queue)
    /// The folders, the vault and the pages' sockets, one at a time, off the engine's queue.
    let work = DispatchQueue(label: "vibenode.lead-engine.plugins", qos: .userInitiated)
    /// The plugins' clock (a test's later).
    var now: () -> Date = Date.init

    init(registry: PluginRegistry, cards: CardStore, link: HostLink, queue: DispatchQueue, root: URL, clock: NodeClock?, bind: WebBind?,
         note: @escaping (String) -> Void) {
        self.registry = registry
        self.cards = cards
        self.link = link
        self.queue = queue
        self.root = root
        self.clock = clock
        self.bind = bind
        self.note = note
    }

    /// Each plugin that is on looks every `lookEvery` s from now on (the room watch's start).
    func startLooking() {
        timer = clock?.every(Self.lookEvery) { [weak self] in self?.queue.async { self?.look() } }
    }

    // MARK: What the desk asks (the plugins' only window), each on the engine's queue

    var vault: LeadVault? { host?.pluginVault }
    var isScratch: Bool { host?.pluginIsScratch ?? true }
    var webBind: WebBind { bind ?? .direct }
    var pagesClock: NodeClock { clock ?? pageClock }
    var sessions: [HostSession] { link.sessions }
    var connected: Bool { link.state == .connected }

    /// The value `plugin`'s setting `key` has (the user's, else its default).
    func setting(_ id: String, _ key: String) -> String? {
        EngineWatch.assertOn(queue)
        return settings["\(id).\(key)"]
    }

    /// Whether `session` is a team's (a worker's, a verifier's), as the vault's roster last said.
    func isTeam(_ session: String) -> Bool {
        EngineWatch.assertOn(queue)
        return team.contains(session)
    }

    /// What the reader keeps between looks for plugin `id`: the stamps it trusted, the digests drawn.
    func readState(_ id: String) -> (trusted: [String: WalletStamp], drawn: [String: String]) {
        EngineWatch.assertOn(queue)
        return (trusted[id] ?? [:], drawn.filter { $0.key.hasPrefix("\(id):") })
    }

    /// What a look of plugin `id`'s requests found: the team, the stamps it trusts, each request's stamp.
    func read(_ id: String, team found: Set<String>?, trusted kept: [String: WalletStamp], stamps given: [(key: String, stamp: PluginStamp)]) {
        EngineWatch.assertOn(queue)
        if let found { team = found }
        trusted[id] = kept
        for (key, stamp) in given { stamps[key] = stamp }
    }

    /// The stamp request `key` came with (`PluginKey.name`).
    func stamp(_ key: String) -> PluginStamp? {
        EngineWatch.assertOn(queue)
        return stamps[key]
    }

    /// The card drawn for `key`, if any.
    func card(_ key: PluginKey) -> CardStore.Card? {
        EngineWatch.assertOn(queue)
        return cardsByRequest[key].flatMap { cards.cards[$0] }
    }

    /// Whether a card was drawn for `key` (open or closed).
    func hasCard(_ key: PluginKey) -> Bool { EngineWatch.assertOn(queue); return cardsByRequest[key] != nil }

    /// `text` told into `session` from `from` through the engine; `.ended` when there's no engine any more.
    func tell(_ text: String, from: SteerMessage.Sender, session: UUID, then: @escaping (SessionDelivery) -> Void) {
        EngineWatch.assertOn(queue)
        guard let host else { return then(.ended) }
        host.pluginTell(text, from: from, session: session, then: then)
    }

    /// Whether the vault said which requests are settled; whether `key` was settled; the requests of plugin `id` carded.
    var knowsSettled: Bool { EngineWatch.assertOn(queue); return settledKnown }
    func isSettled(_ key: String) -> Bool { EngineWatch.assertOn(queue); return settled.contains(key) }
    func carded(_ id: String) -> [String] { EngineWatch.assertOn(queue); return cardsByRequest.keys.filter { $0.plugin == id }.map(\.request) }

    /// `made`, drawn for `key` from the bytes of digest `digest`: kept and shown.
    func drew(_ made: CardStore.Card, key: PluginKey, digest: String) {
        EngineWatch.assertOn(queue)
        cardsByRequest[key] = made.id
        drawn[key.name] = digest
        cards.put(made)
    }

    /// `card` as changed. The card of `key` forgotten, closed saying `closed` when open.
    func put(_ card: CardStore.Card) { EngineWatch.assertOn(queue); cards.put(card) }
    func forget(_ key: PluginKey, closed: String) {
        EngineWatch.assertOn(queue)
        guard let id = cardsByRequest.removeValue(forKey: key) else { return }
        if var card = cards.cards[id], card.isOpen {
            card.closed = closed
            cards.put(card)
        }
    }

    // MARK: What the requests ask (`plugin.list`, add, remove, `set`), each on the engine's queue

    /// When the vault's record began, as it last said.
    var recordSince: Date? { EngineWatch.assertOn(queue); return since }

    /// `body` off the engine's queue, in order with the vault and the folders (a folder's inspection).
    func offQueue(_ body: @escaping () -> Void) { work.async(execute: body) }

    /// A plugin write to the vault (`write`), counted (an ask under way when it was queued is stale), off the engine's
    /// queue; `then` on it with what came of it.
    func vaultWrite<T>(_ write: @escaping () throws -> T, then: @escaping (Result<T, Error>) -> Void) {
        EngineWatch.assertOn(queue)
        writes += 1
        work.async { [queue] in
            let kept = Result { try write() }
            queue.async { then(kept) }
        }
    }

    /// The user's `set` of `plugin`'s `setting` to `checked` (the plugin said it may be): kept in the vault, then taken;
    /// `then` with the value as shown and the one before.
    func keepSetting(_ key: String, plugin: FeaturePlugin, setting: PluginInfo.Setting, value checked: String?,
                     then: @escaping (Result<(value: String, was: String), LeadEngine.CardFailure>) -> Void) {
        EngineWatch.assertOn(queue)
        let stored = "\(plugin.info.id).\(setting.key)"
        let was = settings[stored] ?? setting.defaultValue
        let client = link.vaultV2
        vaultWrite({ try client.setPluginSetting(stored, to: checked) }) { [weak self] kept in
            guard let self else { return }
            switch kept {
            case .failure(let error): then(.failure(.refused("the session host's vault didn't keep it, so nothing changed: \(error)")))
            case .success(let settings):
                self.settings = settings
                self.note("set \(key) (plugin \(plugin.info.id)): changed")
                then(.success((settings[stored] ?? setting.defaultValue, was)))
            }
        }
    }

    // MARK: What tests look at and set (a test's stand-ins)

    var pageOpen: Bool { EngineWatch.assertOn(queue); return page != nil }
    func drawnDigest(_ key: String) -> String? { EngineWatch.assertOn(queue); return drawn[key] }
    /// As if the vault had never settled `key` (a test's restart without it), or never said what is settled.
    func unsettle(_ key: String) { EngineWatch.assertOn(queue); settled.remove(key) }
    func forgetSettledKnown() { EngineWatch.assertOn(queue); settledKnown = false }

    // MARK: The runtime

    /// How often the plugins look.
    static let lookEvery = 15


    /// The desk `plugin` works through.
    func desk(_ plugin: FeaturePlugin) -> PluginDesk { PluginDesk(runtime: self, plugin: plugin) }

    /// Asks the vault which plugins the user set (at each welcome, and at a look while it hasn't said). `then` on `queue`
    /// once it answered or couldn't. On `queue`.
    func ask(then: (() -> Void)? = nil) {
        EngineWatch.assertOn(queue)
        // An ask under way read the vault before this was asked (an add or a remove may have just written it): this waits
        // for the next ask, which follows it.
        guard !asking else {
            if let then { askNextWaiters.append(then) }
            askAgain = true
            return
        }
        if let then { askWaiters.append(then) }
        asking = true
        let client = link.vaultV2
        let writes = writes
        work.async { [weak self] in
            let kept = Result { try client.plugins() }
            let settled = Result { try client.settledRequests() }
            let since = try? client.recordSince()
            let settings = try? client.pluginSettings()
            let builtIn = self?.registry.builtIn ?? []
            let external = (try? client.externalPlugins()).map { Self.externalPlugins($0, builtIn: builtIn) }
            self?.queue.async {
                guard let self else { return }
                self.asking = false
                // A write queued after this ask's reads (the work queue is serial): its answer predates it, so it isn't
                // taken (it would turn back what the user just set); the next ask, after the write, answers its waiters.
                if self.writes != writes {
                    self.askNextWaiters = self.askWaiters + self.askNextWaiters
                    self.askWaiters = []
                    self.askAgain = false
                    let next = self.askNextWaiters
                    self.askNextWaiters = []
                    return self.ask { next.forEach { $0() } }
                }
                if let since { self.since = since }
                if let settings { self.settings = settings }
                if let external { self.registry.takeExternal(external.mapValues(\.record)) { id, _ in external[id] } }
                // Not known (the vault didn't answer): nothing is drawn until it does.
                switch settled {
                case .success(let keys):
                    self.settled.formUnion(keys)
                    self.settledKnown = true
                case .failure(let error):
                    self.note("plugins: the vault didn't say which requests are settled (\(error)); nothing is drawn until it does")
                }
                let waiters = self.askWaiters
                self.askWaiters = []
                if self.askAgain {
                    self.askAgain = false
                    let next = self.askNextWaiters
                    self.askNextWaiters = []
                    self.askWaiters = next
                    defer { self.ask() }
                }
                switch kept {
                // Its waiters hear once the mirror and the wrappers are written: what a reply says is on, a filer finds on.
                case .success(let kept): self.kept(kept) { waiters.forEach { $0() } }
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
    func kept(_ kept: [String: Bool], written: (() -> Void)? = nil) {
        EngineWatch.assertOn(queue)
        let wasOn = Set(registry.known ? registry.onIDs : [])
        registry.kept = kept
        for plugin in registry.plugins where wasOn.contains(plugin.info.id) && !registry.isOn(plugin.info.id) { withdraw(plugin) }
        let (data, file) = (registry.mirror, root.appendingPathComponent("plugins.json"))
        let note = self.note
        // The external plugins' wrappers (`vs-<name> …` is `vs-ask <id> -- …`), only while each is on.
        let wrappers = Dictionary(registry.on.compactMap { $0 as? ExternalPlugin }.flatMap { plugin in
            plugin.info.commands.map { ($0.name, plugin.info.id) }
        }) { first, _ in first }
        let bin = root.appendingPathComponent("plugins/bin", isDirectory: true)
        let queue = self.queue
        work.async {
            do { try VibePaths.writePrivate(data, to: file) } catch { note("plugins: \(file.lastPathComponent) not written: \(error)") }
            Self.writeWrappers(wrappers, in: bin, note: note)
            if let written { queue.async(execute: written) }
        }
        if registry.on.contains(where: { !wasOn.contains($0.info.id) }) { look() }
    }

    /// The user's `plugin on|off NAME` (`Requests.voiced` passed it, and the vault recorded the action): kept in the vault,
    /// then taken (`keptPlugins`). `then` on `queue`. On `queue`.
    func set(_ id: String, on: Bool, then: @escaping (Result<NodeWire.Value, LeadEngine.CardFailure>) -> Void) {
        EngineWatch.assertOn(queue)
        guard let plugin = registry.plugin(id) else {
            return then(.failure(.gone("no plugin \(ConfigSeal.inert(id, limit: 40)) in this build: `vibeswitcher plugin list` lists them")))
        }
        // An external plugin whose program ended starts afresh when the user turns it on again.
        if on, let external = plugin as? ExternalPlugin, external.held == nil { external.ended = nil }
        if on, let why = plugin.availability() { return then(.failure(.refused("\(plugin.info.title) can't run on this node: \(why)"))) }
        let client = link.vaultV2
        let open = cards.list().filter { $0.plugin?.plugin == id }.count
        writes += 1
        work.async { [weak self] in
            let kept = Result { try client.setPlugin(id, on: on) }
            self?.queue.async {
                guard let self else { return }
                switch kept {
                case .failure(let error):
                    then(.failure(.refused("the session host's vault didn't keep it, so nothing changed: \(error)")))
                case .success(let kept):
                    self.note("plugin \(id) turned \(on ? "on" : "off") by the user")
                    self.kept(kept) { [weak self] in
                        guard let self else { return }
                        then(.success(.object(["plugin": .string(id), "on": .bool(self.registry.isOn(id)), "withdrawn": .int(on ? 0 : open)])))
                    }
                }
            }
        }
    }

    /// Each plugin that is on looks at its requests; an off one's folder is emptied unread (what its command filed
    /// anyway, or a file put there). `done` on `queue` once every look is done. On `queue`.
    func look(done: (() -> Void)? = nil) {
        EngineWatch.assertOn(queue)
        // Cards a server before this one kept are taken back first, so a request is drawn again under its kept id.
        guard !cards.restoring else { done?(); return }
        guard registry.known, settledKnown else {
            return ask { [weak self] in
                guard let self, self.registry.known, self.settledKnown else { done?(); return }
                self.look(done: done)
            }
        }
        retryTells()
        expireCards()
        var waiting = 1
        let finish = { waiting -= 1; if waiting == 0 { done?() } }
        for plugin in registry.plugins {
            let id = plugin.info.id
            if registry.isOn(id) {
                waiting += 1
                // One look at a time: asked for while one is under way, one more look follows it (the one under way may
                // have read the folder before what this is for was filed), and this waits for that one.
                if looking[id] != nil {
                    lookAgain[id, default: []].append(finish)
                    continue
                }
                looking[id] = [finish]
                startLook(plugin)
            } else if let relative = plugin.info.folder {
                waiting += 1
                let (note, root) = (self.note, self.root)
                work.async { [weak self] in
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
                let waiters = self.looking.removeValue(forKey: id) ?? []
                if let again = self.lookAgain.removeValue(forKey: id) {
                    if self.registry.isOn(id) {
                        self.looking[id] = again
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
    /// and each name is removed relative to the folder opened, so nothing outside it is touched. Blocks: on `work`.
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
    func answer(_ card: CardStore.Card, text: String, then: @escaping (Result<NodeWire.Value, LeadEngine.CardFailure>) -> Void) {
        EngineWatch.assertOn(queue)
        guard let shown = card.plugin, let plugin = registry.plugin(shown.plugin) else {
            return then(.failure(.gone("no plugin's request on card \(card.id)")))
        }
        guard registry.isOn(shown.plugin) else {
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
        if acting, let expires = shown.expiresAt, now() >= expires {
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
                                self?.openPage(spec, plugin: shown.plugin, key: key, take: take, ended: ended, then: opened)
                            })
        // The page's address, the core's to print: in this answer's reply only (the review of 6e91f053, L1).
        let given = then
        let then: (Result<NodeWire.Value, LeadEngine.CardFailure>) -> Void = { [weak self] result in
            let say = self?.pageSay(key)
            guard case .success(.object(var fields)) = result, let say else { return given(result) }
            fields["say"] = .array(say + (fields["say"]?.array ?? []))
            fields["once"] = .bool(true)
            given(.success(.object(fields)))
        }
        guard acting else { return plugin.perform(action.word, on: marked, desk: desk, act: act, then: then) }
        // An acting answer: settled in the vault, confirmed, before it acts, so no restart draws it again.
        let client = link.vaultV2
        settling.insert(key)
        work.async { [weak self] in
            let kept = Result { try client.settleRequests([key]) }
            self?.queue.async {
                guard let self else { return }
                self.settling.remove(key)
                switch kept {
                case .success:
                    self.settled.insert(key)
                    // Turned off (or the card withdrawn) while the vault was asked: nothing runs; the settle stands.
                    guard self.registry.isOn(shown.plugin), let now = self.cards.cards[marked.id], now.isOpen,
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
        EngineWatch.assertOn(queue)
        let desk = desk(plugin)
        // Its page goes with it (the review of 6e91f053, M2): the host lets the port go, then the slot is freed.
        if let slot = page, slot.plugin == plugin.info.id { slot.page.stop() }
        let title = plugin.info.title
        for var card in cards.list() where card.plugin?.plugin == plugin.info.id {
            guard var shown = card.plugin else { continue }
            // Already being acted on (an answer marked it): what it started may run; say what is true.
            let underWay = !shown.isWaiting && !settling.contains(PluginKey(plugin: shown.plugin, request: shown.request).name)
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
    /// kept for the answer's reply (`pageLines`), never handed to the plugin (L1). On `queue`.
    func openPage(_ spec: PluginPage.Spec, plugin: String, key: String, take: @escaping (Data, @escaping (Bool) -> Void) -> Void,
                        ended: @escaping (Bool) -> Void, then: @escaping (Result<Void, PluginRefusal>) -> Void) {
        guard page == nil else { return then(.failure(PluginRefusal("a plugin's page is open already: answer it, or wait for it to stop"))) }
        let slot = PluginPageSlot(page: PluginPage(spec: spec), plugin: plugin, key: key)
        page = slot
        let (bind, clock, queue, page) = (bind ?? .direct, clock ?? pageClock, self.queue, slot.page)
        work.async { [weak self] in
            let started = Result {
                try page.start(bind: bind, clock: clock, take: { bytes, answer in queue.async { take(bytes, answer) } }, ended: { taken in
                    queue.async {
                        if self?.page === slot { self?.page = nil }
                        // A page that never opened ends nothing of the plugin's: its start's failure says so.
                        if slot.opened { ended(taken) } else { slot.endedEarly = true }
                    }
                })
            }
            queue.async {
                switch started {
                case .success(let url) where !slot.endedEarly:
                    slot.opened = true
                    self?.pageLines[key] = (url, spec.life)
                    then(.success(()))
                case .success:
                    then(.failure(PluginRefusal("its page stopped before it opened")))
                case .failure(let error):
                    then(.failure(error as? PluginRefusal ?? PluginRefusal("\(error)")))
                }
            }
        }
    }

    /// The page open for card `id`'s request, stopped now, unanswered: its address went in a reply that was lost (the
    /// command line asked again by its action id, `Requests.kept`), so nobody can answer it; it ends as its life's end
    /// would (the plugin's `ended`: the card closes, its asker is told), and the node's one page slot is freed. True when
    /// it was open. Once-only stands: nothing is performed again. On `queue`.
    func stopPage(card id: String) -> Bool {
        EngineWatch.assertOn(queue)
        guard let shown = cards.cards[id]?.plugin, let slot = page, slot.opened,
              slot.key == PluginKey(plugin: shown.plugin, request: shown.request).name else { return false }
        pageLines[slot.key] = nil
        note("plugin \(shown.plugin): card \(id)'s page stopped unanswered: its address was lost with its reply")
        slot.page.stop(taken: false)
        return true
    }

    /// The lines that give the answering terminal a page's address, taken once.
    func pageSay(_ key: String) -> [NodeWire.Value]? {
        guard let line = pageLines.removeValue(forKey: key) else { return nil }
        return [.string("Open this page in your browser (it works once, \(max(1, Int(line.life / 60))) minutes at most):"),
                .string("  " + line.url.absoluteString)]
    }

    /// Settles `keys` (`PluginKey.name`): never drawn again, here and in the vault. On `queue`.
    func settle(_ keys: [String]) {
        EngineWatch.assertOn(queue)
        let new = keys.filter { settled.insert($0).inserted }
        guard !new.isEmpty else { return }
        let (client, note) = (link.vaultV2, self.note)
        work.async {
            do { try client.settleRequests(new) } catch { note("plugins: \(new.count) settled request(s) not kept in the vault: \(error)") }
        }
    }

    /// Tells `session` `text` from VibeSwitcher until it reached it or the session is gone (`tells`). On `queue`.
    func tellSurely(_ text: String, session: UUID, key: String) {
        EngineWatch.assertOn(queue)
        tells[key] = (session, text)
        retryTells()
    }

    /// Each message `tells` holds, tried again (one at a time a message). On `queue`.
    func retryTells() {
        for (key, entry) in tells where telling.insert(key).inserted {
            guard let host else { telling.remove(key); continue }
            host.pluginTell(entry.text, from: .system("from VibeSwitcher"), session: entry.session) { [weak self] delivery in
                guard let self else { return }
                self.telling.remove(key)
                if delivery != .notYet { self.tells[key] = nil }
            }
        }
    }

    /// Rule 4, the core's: an open plugin card still waiting past its expiry closes as expired, and is settled (the
    /// plugin tells its asker at its look). On `queue`.
    func expireCards() {
        EngineWatch.assertOn(queue)
        let now = now()
        for var card in cards.list() where card.kind == .plugin {
            guard var shown = card.plugin, shown.isWaiting, let expires = shown.expiresAt, now >= expires else { continue }
            shown.state = "expired"
            shown.outcome = "Expired unanswered"
            card.plugin = shown
            card.closed = "expired unanswered"
            cards.put(card)
            settle([PluginKey(plugin: shown.plugin, request: shown.request).name])
            note("plugin \(shown.plugin): card \(card.id) expired unanswered")
        }
    }

    /// `status`'s notice for each plugin card waiting on the user, then each plugin's own. The agent's words are marked as
    /// its own, quoted: the first line of what it asks. On `queue`.
    var notices: [String] {
        EngineWatch.assertOn(queue)
        let waiting = cards.list().compactMap { card -> String? in
            guard card.kind == .plugin, let shown = card.plugin, shown.isWaiting, registry.isOn(shown.plugin) else { return nil }
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
        return waiting + registry.on.flatMap { $0.notices(desk($0)) }
    }
}
