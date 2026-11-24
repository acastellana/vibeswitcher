import Foundation
import VibeCore

/// A request an agent's command filed for a plugin and the session host stamped (`WalletStamp`): what the one reader
/// (`PluginDesk.stamped`) gives a plugin.
public protocol StampedAsk: Sendable {
    /// Its id, also its file's name.
    var id: String { get }
    /// The asking session's id, lower case, as the host placed the filing process.
    var session: String { get }
    /// When it was filed, by the filing process's clock.
    var created: Date { get }
}

/// What a plugin gets of the engine (the definition's "What stays the core's"): its stamped requests through one reader
/// that holds rule 1 itself, its cards (drawn after the core's checks), the sessions the host runs, starting a session,
/// telling an asker, the clock. Nothing else of the engine: no card store, no host link, no files of its own beyond its
/// folder's (`PluginLintTests`). Everything on the engine's queue unless it says otherwise.
public struct PluginDesk {
    private unowned let runtime: PluginRuntime
    /// The runtime again, held weakly: what a plugin's program answers late (after the engine and its runtime went, a
    /// test's) is dropped.
    private weak var alive: PluginRuntime?
    public let plugin: FeaturePlugin
    /// The node's root, the log and the queues: the desk's own, so a late callback reaching them touches no engine.
    public let root: URL
    public let note: (String) -> Void
    /// The engine's queue, and the plugins' own for reading files (one step at a time).
    public let queue: DispatchQueue
    public let work: DispatchQueue

    init(runtime: PluginRuntime, plugin: FeaturePlugin) {
        self.runtime = runtime
        self.alive = runtime
        self.plugin = plugin
        (root, note, queue, work) = (runtime.root, runtime.note, runtime.queue, runtime.work)
    }

    /// Runs `body` on the engine's queue while the engine lives, holding it for the body's length; nothing once it has
    /// gone. The only way back to the engine's queue for anything that ran elsewhere (a plugin's work, a program's
    /// answer, the host's spawn): the desk holds the runtime unowned, so a block reaching it after the runtime went would
    /// trap.
    public func later(_ body: @escaping () -> Void) {
        queue.async { [weak alive] in
            guard let held = alive else { return }
            withExtendedLifetime(held) { body() }
        }
    }

    var id: String { plugin.info.id }
    /// The plugins' clock (a test's own).
    public var now: Date { runtime.now() }
    /// A scratch node's (a test's): what its sessions get keeps to its root.
    public var isScratch: Bool { runtime.isScratch }

    /// This plugin's settings as the user set them, by name (none set: its default).
    public var settings: [String: String] {
        Dictionary(uniqueKeysWithValues: plugin.info.settings.map { ($0.key, runtime.setting(id, $0.key) ?? $0.defaultValue) })
    }

    /// Where a page for the person's browser gets its listening socket (the session host's, held as the web's).
    public var bind: WebBind { runtime.webBind }

    /// The engine's clock, or one of the plugins' own on the engine's queue (a test's engine has none).
    public var clock: NodeClock { runtime.pagesClock }

    /// Where this plugin's command files requests (`PluginInfo.folder` under the root), when it does.
    public var folder: URL? { plugin.info.folder.map { root.appendingPathComponent($0, isDirectory: true) } }

    // MARK: Sessions

    /// Whether the host's list is known (its welcome came, and the link holds).
    public var connected: Bool { runtime.connected }

    /// The live sessions the user opened (`opened`), by lower-case id.
    public var live: [String: HostSession] {
        Dictionary(runtime.sessions.filter(opened).map { ($0.id.uuidString.lowercased(), $0) }) { first, _ in first }
    }

    /// The session the host lists with `id`, live or ended.
    public func session(_ id: UUID) -> HostSession? { runtime.sessions.first { $0.id == id } }

    /// Whether `session` may ask (rule 1: a live session the user opened): live, and not a team's worker or verifier as
    /// the vault's roster says (the host's record, not a label anyone can give a session).
    public func opened(_ session: HostSession) -> Bool {
        session.isLive && !runtime.isTeam(session.id.uuidString.lowercased())
    }

    /// Looks at the plugins again (one look at a time), then `done`.
    public func lookAgain(done: @escaping () -> Void) { runtime.look(done: done) }

    /// The host's id of a session the node names `local:<uuid>` (`NodeIds.session(host:)`); nil for any other.
    public static func hostSession(_ id: String) -> UUID? {
        let prefix = "\(NodeIds.node):"
        return id.hasPrefix(prefix) ? UUID(uuidString: String(id.dropFirst(prefix.count))) : nil
    }

    /// A session's name as the node lists it; a Run-card shell's name is an agent's (`Shell: <its --label>`), marked so.
    public static func asker(_ session: HostSession) -> String {
        if session.label.isEmpty { return "session \(session.tty)" }
        return ShellTidy.opened(session) ? "a shell an agent asked for, named by it \u{201C}\(session.label)\u{201D}" : session.label
    }

    // MARK: The one reader (rule 1)

    /// The requests in this plugin's folder that the session host stamped for a live session the user opened, decoded by
    /// `decode` only once the desk has checked them: each `<id>.json` and its `<id>.seal` read here (no link followed, a
    /// regular file, bounded), the stamp's digest of those very bytes, the stamp the host's own (the vault's
    /// `verifyWallet`, asked once a stamp), its session live and the user's (`opened`); then decoded, its id its file's
    /// name and its session the stamp's, filed no more than `aheadAtMost` past the clock. A request from a session that
    /// ended is never decoded. Read on `work`; `then` on the engine's queue with them, oldest first.
    public func stamped<Ask: StampedAsk>(_ decode: @escaping @Sendable (Data) throws -> Ask, then: @escaping ([Ask]) -> Void) {
        guard let folder, let vault = runtime.vault else { return then([]) }
        let live = Set(runtime.sessions.filter(\.isLive).map { $0.id.uuidString.lowercased() })
        let (trusted, drawn) = runtime.readState(id)
        let (now, note, id) = (now, note, id)
        let desk = self
        work.async {
            // The team's sessions, from the vault's roster: unknown (it didn't answer), nothing is given this look.
            let team = (try? vault.roster()).map { Set($0.filter { $0.role != .lead }.map { $0.session.lowercased() }) }
            let found = team.map { team in
                Self.read(folder: folder, decode: decode, trusted: trusted, vault: vault, opened: live.subtracting(team), drawn: drawn, now: now,
                          plugin: id, note: note)
            }
            if team == nil { note("\(id) requests: the vault's roster didn't answer, so no session's request is read this time") }
            // Back through `later`: the runtime isn't held across the read, and a read it outlived gives nothing.
            desk.later {
                guard let found else {
                    if let team { desk.runtime.read(id, team: team, trusted: desk.runtime.readState(id).trusted, stamps: []) }
                    return then([])
                }
                desk.runtime.read(id, team: team, trusted: found.trusted, stamps: found.requests.map { entry in
                    (PluginKey(plugin: id, request: entry.ask.id).name,
                     PluginStamp(digest: entry.stamp.digest, session: entry.stamp.session.lowercased(), created: entry.ask.created))
                })
                then(found.requests.map(\.ask))
            }
        }
    }

    /// A request dated this far ahead of the server's clock isn't given (its life would run late).
    public static let aheadAtMost: TimeInterval = 120
    /// A request file at most (the wallet format's own limit), and its stamp.
    static let requestBytesAtMost = 64 * 1024
    static let stampBytesAtMost = 4 * 1024
    /// The most requests read a look, and stamps asked of the vault at once (a folder flooded with pairs can't push the
    /// vault's question past its frame, nor hide the others' requests for long).
    static let readAtMost = 64
    static let verifyBatch = 16

    /// A regular file's bytes, no link followed, `limit` at most; nil otherwise.
    static func bounded(_ file: URL, limit: Int) -> Data? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    /// A request the reader gave, with the stamp it came with.
    struct Read<Ask> {
        var ask: Ask
        var stamp: WalletStamp
    }

    /// The reader itself. `drawn`: the digest each of this plugin's cards was drawn from (`PluginKey.name`): an id whose
    /// bytes changed since is dropped, said. A pair that can't be a request (no stamp, other bytes, not the host's stamp)
    /// is removed. Blocks: on the plugins' `work`.
    static func read<Ask: StampedAsk>(folder: URL, decode: (Data) throws -> Ask, trusted given: [String: WalletStamp], vault: LeadVault,
                                      opened: Set<String>, drawn: [String: String] = [:], now: Date, plugin: String,
                                      note: (String) -> Void) -> (requests: [Read<Ask>], trusted: [String: WalletStamp]) {
        let say = { (text: String) in ConfigSeal.inert(text, limit: 120) }
        let drop = { (id: String) in
            for name in ["\(id).json", "\(id).seal"] { unlink(folder.appendingPathComponent(name).path) }
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        var filed: [(id: String, bytes: Data, stamp: WalletStamp)] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            guard filed.count < readAtMost else { note("\(plugin) requests: more than \(readAtMost) in the folder: the rest at a later look"); break }
            let id = String(name.dropLast(5))
            guard WalletRequestFormat.isID(id) else {
                note("\(plugin) request not shown: \(say(name)): not a request's name; removed")
                unlink(folder.appendingPathComponent(name).path)
                continue
            }
            guard let bytes = bounded(folder.appendingPathComponent(name), limit: requestBytesAtMost),
                  let sealed = bounded(folder.appendingPathComponent("\(id).seal"), limit: stampBytesAtMost),
                  let stamp = try? JSONDecoder().decode(WalletStamp.self, from: sealed) else {
                note("\(plugin) request not shown: \(id): not a regular file of its size with a stamp beside it; removed")
                drop(id)
                continue
            }
            guard stamp.digest == WalletStamp.digest(bytes) else {
                note("\(plugin) request not shown: \(id): its stamp is for other bytes; removed")
                drop(id)
                continue
            }
            if let was = drawn["\(plugin):\(id)"], was != stamp.digest {
                note("\(plugin) request not shown: \(id): its bytes changed under its id since its card was drawn")
                continue
            }
            filed.append((id, bytes, stamp))
        }
        var trusted = given.filter { key, stamp in filed.contains { $0.id == key && $0.stamp == stamp } }
        let unasked = filed.filter { trusted[$0.id] == nil }
        for start in stride(from: 0, to: unasked.count, by: verifyBatch) {
            let batch = Array(unasked[start..<min(start + verifyBatch, unasked.count)])
            do {
                let valid = try vault.verifyWallet(batch.map(\.stamp))
                for (entry, ok) in zip(batch, valid) {
                    if ok { trusted[entry.id] = entry.stamp } else {
                        note("\(plugin) request not shown: \(entry.id): its stamp isn't the session host's; removed")
                        drop(entry.id)
                    }
                }
            } catch {
                note("\(plugin) requests: \(batch.count) stamp(s) weren't checked: \(error)")
            }
        }
        var found: [Read<Ask>] = []
        for entry in filed where trusted[entry.id] == entry.stamp {
            // Rule 1 before any decoder: a live session the user opened.
            guard opened.contains(entry.stamp.session.lowercased()) else {
                note("\(plugin) request not shown: \(entry.id): its session isn't a live one the user opened")
                continue
            }
            let request: Ask
            do { request = try decode(entry.bytes) } catch {
                note("\(plugin) request not shown: \(entry.id): \(say("\(error)"))")
                continue
            }
            guard request.id == entry.id, request.session == entry.stamp.session.lowercased() else {
                note("\(plugin) request not shown: \(entry.id): its id or session isn't its file's and stamp's")
                continue
            }
            guard request.created.timeIntervalSince(now) <= aheadAtMost else {
                note("\(plugin) request not shown: \(request.id): filed for \(request.created), ahead of this clock")
                continue
            }
            found.append(Read(ask: request, stamp: entry.stamp))
        }
        return (found.sorted { ($0.ask.created, $0.ask.id) < ($1.ask.created, $1.ask.id) }, trusted)
    }

    // MARK: Cards

    /// This plugin's card for request `request`, when one was drawn.
    public func card(request: String) -> CardStore.Card? {
        runtime.card(PluginKey(plugin: id, request: request))
    }

    /// Draws `shown` as a new open card in `root` (the folder it's about), filed `at`. Refused, with why, when the plugin
    /// isn't on (a look that hopped queues after a withdrawal), when the core's checks refuse the card
    /// (`PluginCard.refusal`), when it has no expiry or one past the plugin's declared life (rule 4), when its asker isn't
    /// a live session the user opened, when it isn't this plugin's, already has a card, or was settled (answered,
    /// withdrawn, expired: never drawn again). Its context is cut (`PluginCard.drawn`).
    @discardableResult
    public func draw(_ shown: PluginCard, root: String, at: Date) -> Result<CardStore.Card, PluginRefusal> {
        guard runtime.registry.isOn(id) else { return .failure(PluginRefusal("\(plugin.info.title) is off")) }
        guard runtime.knowsSettled else { return .failure(PluginRefusal("the vault hasn't said which requests are settled yet")) }
        guard shown.plugin == id else { return .failure(PluginRefusal("a card of another plugin")) }
        let key = PluginKey(plugin: id, request: shown.request)
        // The asking session, its name and the time filed are the stamped request's, never the plugin's word.
        guard let stamp = runtime.stamp(key.name), let session = UUID(uuidString: stamp.session),
              let asker = runtime.sessions.first(where: { $0.id == session }), opened(asker) else {
            return .failure(PluginRefusal("no stamped request \(shown.request) of a live session the user opened"))
        }
        var card = shown
        card.session = NodeIds.session(host: session)
        card.asker = Self.asker(asker)
        if let why = card.refusal { return .failure(PluginRefusal(why)) }
        guard let expires = card.expiresAt, expires > stamp.created, expires.timeIntervalSince(stamp.created) <= plugin.info.life + 1 else {
            return .failure(PluginRefusal("its expiry isn't within \(plugin.info.title)'s declared life (\(Int(plugin.info.life / 60)) minutes) of its filing"))
        }
        // Expired already: never drawn (the review of 6e91f053, L2).
        guard expires > now else { return .failure(PluginRefusal("request \(shown.request) expired before it was drawn")) }
        guard !runtime.hasCard(key) else { return .failure(PluginRefusal("request \(shown.request) has a card already")) }
        guard !runtime.isSettled(key.name) else { return .failure(PluginRefusal("request \(shown.request) was settled already")) }
        // A request a server before this one drew (kept across its restart or a switch) keeps its card's id.
        let kept = runtime.cards.adopt(plugin: id, request: shown.request, now: now)
        var made = CardStore.Card(id: kept?.id ?? NodeIds.card(), root: root, kind: .plugin, at: stamp.created)
        made.plugin = card.drawn
        runtime.drew(made, key: key, digest: stamp.digest)
        return .success(made)
    }

    /// Changes this plugin's card for `request` (its state, its outcome; `closed` closes it, and settles the request):
    /// nothing when there's none. The request it shows can't change: what was shown is what is answered.
    public func change(request: String, state: String, outcome: String?, closed: String? = nil) {
        guard var card = card(request: request), var shown = card.plugin else { return }
        // An answered card never waits again: an answer is taken once.
        if state == PluginCard.waitingState && !shown.isWaiting { return }
        guard shown.state != state || shown.outcome != outcome || (closed != nil && card.isOpen) else { return }
        shown.state = state
        shown.outcome = outcome
        card.plugin = shown
        if let closed, card.isOpen {
            card.closed = closed
            settle(request)
        }
        runtime.put(card)
    }

    /// Forgets the card of `request` (its request is gone): an open one closes, saying `closed`; the request is settled.
    public func forget(request: String, closed: String) {
        let key = PluginKey(plugin: id, request: request)
        settle(request)
        runtime.forget(key, closed: closed)
    }

    /// Whether `request` was settled (here or by a server before this one): it won't be drawn, so it isn't asked about.
    public func isSettled(_ request: String) -> Bool { runtime.isSettled(PluginKey(plugin: id, request: request).name) }

    /// Withdraws every open card of this plugin, telling their askers (its program broke the protocol, say).
    /// Every open card of this plugin's withdrawn, its askers told: `ended`, its program ended (why), else turned off.
    public func withdrawAll(ended: String? = nil) { runtime.withdraw(plugin, ended: ended) }

    /// `request` is settled (it got no card, or its card closed): never drawn again, this server's or the next's
    /// (kept in the vault).
    public func settle(_ request: String) { runtime.settle([PluginKey(plugin: id, request: request).name]) }

    /// The requests this plugin has cards for.
    public var carded: [String] { runtime.carded(id) }

    // MARK: Telling

    /// Tells request `request`'s asker `text` as a message from `from` (VibeSwitcher's words: "from New Shell"): the
    /// session its stamp names, never one a plugin says. `then` with how it went (`.ended` when there's no such request).
    public func tell(_ text: String, from: String, request: String, then: @escaping (SessionDelivery) -> Void) {
        guard let stamp = runtime.stamp(PluginKey(plugin: id, request: request).name), let session = UUID(uuidString: stamp.session) else {
            return then(.ended)
        }
        runtime.tell(text, from: .system(from), session: session, then: then)
    }

    /// Tells `session` `text` from VibeSwitcher until it reached it or the session is gone, even while the plugin is off
    /// (a withdrawal's words, a started shell that won't be followed): retried at each plugins' look.
    public func tellSurely(_ text: String, session: UUID) { runtime.tellSurely(text, session: session, key: "\(id):\(UUID().uuidString)") }

    /// What an asker is told when its card was withdrawn while an answer was acting on it.
    public func withdrawnWhileAnsweredText(_ card: PluginCard) -> String {
        "[VibeSwitcher] Your \(card.noun) \(card.request) was being answered when the user turned \(plugin.info.title) off on this node: "
            + "what the answer started may still run, but you won't hear more of it from VibeSwitcher."
    }

    /// What an asker is told when its card was withdrawn because the plugin's program ended (`why`).
    public func endedText(_ card: PluginCard, why: String) -> String {
        "[VibeSwitcher] Your \(card.noun) \(card.request) was withdrawn: \(plugin.info.title)'s program ended (\(why)), "
            + "so nothing more will be done for it. Don't file it again unless the user turns \(plugin.info.title) off and on."
    }

    /// What an asker is told when its card was withdrawn: the user turned the plugin off.
    public func withdrawnText(_ card: PluginCard) -> String {
        "[VibeSwitcher] Your \(card.noun) \(card.request) was withdrawn: the user turned \(plugin.info.title) off on this node, "
            + "so nothing was done and nothing will be. Don't file it again unless the user turns it back on."
    }
}

/// A request as the reader gave it: its stamp's digest and session, and when it was filed.
struct PluginStamp: Equatable {
    var digest: String
    var session: String
    var created: Date
}

/// What a plugin's `perform` may do for the card it answers, and nothing else: start a session (the host's spawn).
public struct PluginAct {
    let start: (SpawnRequest, @escaping (Result<HostSession, HostLink.Failure>) -> Void) -> Void
    let page: (PluginPage.Spec, @escaping (Data, @escaping (Bool) -> Void) -> Void, @escaping (Bool) -> Void, @escaping (Result<Void, PluginRefusal>) -> Void) -> Void

    /// Starts a session through the host; `then` with it, off the engine's queue.
    public func spawn(_ request: SpawnRequest, then: @escaping (Result<HostSession, HostLink.Failure>) -> Void) { start(request, then) }

    /// Serves `spec` once (`PluginPage`): `take` hears each answer's bytes (true: taken), `ended` whether one was taken
    /// when the page stops; `then` with whether it opened, or why not (one page at a time on a node; only an acting
    /// answer opens one). The plugin never sees the page's address: the core prints it in the answering terminal's
    /// reply itself (the review of 6e91f053, L1). Callbacks on the engine's queue.
    public func openPage(_ spec: PluginPage.Spec, take: @escaping (Data, @escaping (Bool) -> Void) -> Void, ended: @escaping (Bool) -> Void,
                         then: @escaping (Result<Void, PluginRefusal>) -> Void) { page(spec, take, ended, then) }
}

/// A plugin's card, by its request.
struct PluginKey: Hashable {
    var plugin: String
    var request: String
    /// As the vault keeps a settled one: `<plugin>:<id>`.
    var name: String { "\(plugin):\(request)" }
}

public struct PluginRefusal: Error, Equatable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}
