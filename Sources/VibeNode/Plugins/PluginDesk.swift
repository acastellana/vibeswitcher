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
    private unowned let engine: LeadEngine
    public let plugin: FeaturePlugin

    init(engine: LeadEngine, plugin: FeaturePlugin) {
        self.engine = engine
        self.plugin = plugin
    }

    var id: String { plugin.info.id }

    /// The node's root.
    public var root: URL { engine.root }
    public var note: (String) -> Void { engine.note }
    /// The plugins' clock (a test's own).
    public var now: Date { engine.pluginNow() }
    /// A scratch node's (a test's): what its sessions get keeps to its root.
    public var isScratch: Bool { engine.isScratch }
    /// The engine's queue, and the plugins' own for reading files (one step at a time).
    public var queue: DispatchQueue { engine.queue }
    public var work: DispatchQueue { engine.pluginWork }

    /// Where this plugin's command files requests (`PluginInfo.folder` under the root), when it does.
    public var folder: URL? { plugin.info.folder.map { root.appendingPathComponent($0, isDirectory: true) } }

    // MARK: Sessions

    /// Whether the host's list is known (its welcome came, and the link holds).
    public var connected: Bool { engine.link.state == .connected }

    /// The live sessions the user opened (`opened`), by lower-case id.
    public var live: [String: HostSession] {
        Dictionary(engine.link.sessions.filter(Self.opened).map { ($0.id.uuidString.lowercased(), $0) }) { first, _ in first }
    }

    /// The session the host lists with `id`, live or ended.
    public func session(_ id: UUID) -> HostSession? { engine.link.sessions.first { $0.id == id } }

    /// Whether `session` may ask (rule 1: a live session the user opened): live, and no worker's or verifier's of a team,
    /// which a lead's tool server starts (`LeadTeams.role`).
    public static func opened(_ session: HostSession) -> Bool {
        guard session.isLive else { return false }
        let role = LeadTeams.role(label: session.label)
        return role != .worker && role != .verifier
    }

    /// Starts a session through the host; `then` with it, off the engine's queue.
    public func spawn(_ request: SpawnRequest, then: @escaping (Result<HostSession, HostLink.Failure>) -> Void) {
        engine.link.spawn(request, completion: then)
    }

    /// Looks at the plugins again (one look at a time), then `done`.
    public func lookAgain(done: @escaping () -> Void) { engine.lookAtPlugins(done: done) }

    /// The host's id of a session the node names `local:<uuid>` (`NodeIds.session(host:)`); nil for any other.
    public static func hostSession(_ id: String) -> UUID? {
        let prefix = "\(NodeIds.node):"
        return id.hasPrefix(prefix) ? UUID(uuidString: String(id.dropFirst(prefix.count))) : nil
    }

    /// A session's name as the node lists it.
    public static func asker(_ session: HostSession) -> String { session.label.isEmpty ? "session \(session.tty)" : session.label }

    // MARK: The one reader (rule 1)

    /// The requests in this plugin's folder that the session host stamped for a live session the user opened, decoded by
    /// `decode` only once the desk has checked them: each `<id>.json` and its `<id>.seal` read here (no link followed, a
    /// regular file, bounded), the stamp's digest of those very bytes, the stamp the host's own (the vault's
    /// `verifyWallet`, asked once a stamp), its session live and the user's (`opened`); then decoded, its id its file's
    /// name and its session the stamp's, filed no more than `aheadAtMost` past the clock. A request from a session that
    /// ended is never decoded. Read on `work`; `then` on the engine's queue with them, oldest first.
    public func stamped<Ask: StampedAsk>(_ decode: @escaping @Sendable (Data) throws -> Ask, then: @escaping ([Ask]) -> Void) {
        guard let folder else { return then([]) }
        let opened = Set(live.keys)
        let (vault, trusted, now, note, id, engine) = (engine.cardVault, engine.pluginTrusted[id] ?? [:], now, note, id, engine)
        work.async {
            let found = Self.read(folder: folder, decode: decode, trusted: trusted, vault: vault, opened: opened, now: now, plugin: id, note: note)
            engine.queue.async {
                engine.pluginTrusted[id] = found.trusted
                then(found.requests)
            }
        }
    }

    /// A request dated this far ahead of the server's clock isn't given (its life would run late).
    public static let aheadAtMost: TimeInterval = 120
    /// A request file at most (the wallet format's own limit), and its stamp.
    static let requestBytesAtMost = 64 * 1024
    static let stampBytesAtMost = 4 * 1024

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

    /// The reader itself. Blocks: on the plugins' `work`.
    static func read<Ask: StampedAsk>(folder: URL, decode: (Data) throws -> Ask, trusted given: [String: WalletStamp], vault: LeadVault,
                                      opened: Set<String>, now: Date, plugin: String,
                                      note: (String) -> Void) -> (requests: [Ask], trusted: [String: WalletStamp]) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        var filed: [(id: String, bytes: Data, stamp: WalletStamp)] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let id = String(name.dropLast(5))
            guard WalletRequestFormat.isID(id) else { note("\(plugin) request not shown: \(name): not a request's name"); continue }
            guard let bytes = bounded(folder.appendingPathComponent(name), limit: requestBytesAtMost),
                  let sealed = bounded(folder.appendingPathComponent("\(id).seal"), limit: stampBytesAtMost),
                  let stamp = try? JSONDecoder().decode(WalletStamp.self, from: sealed) else {
                note("\(plugin) request not shown: \(name): not a regular file of its size with a stamp beside it")
                continue
            }
            guard stamp.digest == WalletStamp.digest(bytes) else { note("\(plugin) request not shown: \(name): its stamp is for other bytes"); continue }
            filed.append((id, bytes, stamp))
        }
        var trusted = given.filter { key, stamp in filed.contains { $0.id == key && $0.stamp == stamp } }
        let unasked = filed.filter { trusted[$0.id] == nil }
        if !unasked.isEmpty {
            do {
                let valid = try vault.verifyWallet(unasked.map(\.stamp))
                for (entry, ok) in zip(unasked, valid) {
                    if ok { trusted[entry.id] = entry.stamp } else { note("\(plugin) request not shown: \(entry.id): its stamp isn't the session host's") }
                }
            } catch {
                note("\(plugin) requests: the stamps weren't checked: \(error)")
            }
        }
        var found: [Ask] = []
        for entry in filed where trusted[entry.id] == entry.stamp {
            // Rule 1 before any decoder: a live session the user opened.
            guard opened.contains(entry.stamp.session.lowercased()) else { continue }
            let request: Ask
            do { request = try decode(entry.bytes) } catch {
                note("\(plugin) request not shown: \(entry.id): \(error)")
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
            found.append(request)
        }
        return (found.sorted { ($0.created, $0.id) < ($1.created, $1.id) }, trusted)
    }

    // MARK: Cards

    /// This plugin's card for request `request`, when one was drawn.
    public func card(request: String) -> CardStore.Card? {
        engine.pluginCards[PluginKey(plugin: id, request: request)].flatMap { engine.cards.cards[$0] }
    }

    /// Draws `shown` as a new open card in `root` (the folder it's about), filed `at`. Refused, with why, when the plugin
    /// isn't on (a look that hopped queues after a withdrawal), when the core's checks refuse the card
    /// (`PluginCard.refusal`), when it has no expiry or one past the plugin's declared life (rule 4), when its asker isn't
    /// a live session the user opened, when it isn't this plugin's, already has a card, or was settled (answered,
    /// withdrawn, expired: never drawn again). Its context is cut (`PluginCard.drawn`).
    @discardableResult
    public func draw(_ shown: PluginCard, root: String, at: Date) -> Result<CardStore.Card, PluginRefusal> {
        guard engine.plugins.isOn(id) else { return .failure(PluginRefusal("\(plugin.info.title) is off")) }
        guard shown.plugin == id else { return .failure(PluginRefusal("a card of another plugin")) }
        if let why = shown.refusal { return .failure(PluginRefusal(why)) }
        guard let expires = shown.expiresAt, expires > at, expires.timeIntervalSince(at) <= plugin.info.life + 1 else {
            return .failure(PluginRefusal("its expiry isn't within \(plugin.info.title)'s declared life (\(Int(plugin.info.life / 60)) minutes)"))
        }
        guard let session = Self.hostSession(shown.session), engine.link.sessions.contains(where: { $0.id == session && Self.opened($0) }) else {
            return .failure(PluginRefusal("its asker isn't a live session the user opened"))
        }
        let key = PluginKey(plugin: id, request: shown.request)
        guard engine.pluginCards[key] == nil else { return .failure(PluginRefusal("request \(shown.request) has a card already")) }
        guard !engine.pluginSettled.contains(key.name) else { return .failure(PluginRefusal("request \(shown.request) was settled already")) }
        var card = CardStore.Card(root: root, kind: .plugin, at: at)
        card.plugin = shown.drawn
        engine.pluginCards[key] = card.id
        engine.cards.put(card)
        return .success(card)
    }

    /// Changes this plugin's card for `request` (its state, its outcome; `closed` closes it, and settles the request):
    /// nothing when there's none. The request it shows can't change: what was shown is what is answered.
    public func change(request: String, state: String, outcome: String?, closed: String? = nil) {
        guard var card = card(request: request), var shown = card.plugin else { return }
        guard shown.state != state || shown.outcome != outcome || (closed != nil && card.isOpen) else { return }
        shown.state = state
        shown.outcome = outcome
        card.plugin = shown
        if let closed, card.isOpen {
            card.closed = closed
            settle(request)
        }
        engine.cards.put(card)
    }

    /// Forgets the card of `request` (its request is gone): an open one closes, saying `closed`; the request is settled.
    public func forget(request: String, closed: String) {
        let key = PluginKey(plugin: id, request: request)
        settle(request)
        guard let cardID = engine.pluginCards.removeValue(forKey: key) else { return }
        if var card = engine.cards.cards[cardID], card.isOpen {
            card.closed = closed
            engine.cards.put(card)
        }
    }

    /// `request` is settled (it got no card, or its card closed): never drawn again, this server's or the next's
    /// (kept in the vault).
    public func settle(_ request: String) { engine.settlePluginRequests([PluginKey(plugin: id, request: request).name]) }

    /// The requests this plugin has cards for.
    public var carded: [String] { engine.pluginCards.keys.filter { $0.plugin == id }.map(\.request) }

    // MARK: Telling

    /// Tells `session` `text` as a message from `from` (VibeSwitcher's words: "from New Shell"); `then` with how it went.
    public func tell(_ text: String, from: String, session: UUID, then: @escaping (SessionDelivery) -> Void) {
        engine.tell(text, from: .system(from), session: session, then: then)
    }

    /// Tells `session` `text` from VibeSwitcher until it reached it or the session is gone, even while the plugin is off
    /// (a withdrawal's words, a started shell that won't be followed): retried at each plugins' look.
    public func tellSurely(_ text: String, session: UUID) { engine.tellSurely(text, session: session, key: "\(id):\(UUID().uuidString)") }

    /// What an asker is told when its card was withdrawn: the user turned the plugin off.
    public func withdrawnText(_ card: PluginCard) -> String {
        "[VibeSwitcher] Your \(card.noun) \(card.request) was withdrawn: the user turned \(plugin.info.title) off on this node, "
            + "so nothing was done and nothing will be. Don't file it again unless the user turns it back on."
    }
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
