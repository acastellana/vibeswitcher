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

/// What a plugin gets of the engine (the definition's "What stays the core's"): its stamped requests through one reader,
/// its cards (drawn after the core's checks), the sessions the host runs, telling an asker, the clock. Everything on the
/// engine's queue unless it says otherwise.
public struct PluginDesk {
    unowned let engine: LeadEngine
    public let plugin: FeaturePlugin

    var id: String { plugin.info.id }

    /// The node's root.
    public var root: URL { engine.root }
    public var note: (String) -> Void { engine.note }
    /// The plugins' clock (a test's own).
    public var now: Date { engine.pluginNow() }
    /// A scratch node's (a test's): what its sessions get keeps to its root.
    public var isScratch: Bool { engine.isScratch }
    /// The host.
    public var link: HostLink { engine.link }
    /// The engine's queue, and the plugins' own for reading files (one step at a time).
    public var queue: DispatchQueue { engine.queue }
    public var work: DispatchQueue { engine.pluginWork }

    /// Where this plugin's command files requests (`PluginInfo.folder` under the root), when it does.
    public var folder: URL? { plugin.info.folder.map { root.appendingPathComponent($0, isDirectory: true) } }

    /// The live sessions the host runs, by lower-case id.
    public var live: [String: HostSession] {
        Dictionary(engine.link.sessions.filter(\.isLive).map { ($0.id.uuidString.lowercased(), $0) }) { first, _ in first }
    }

    /// The host's id of a session the node names `local:<uuid>` (`NodeIds.session(host:)`); nil for any other.
    public static func hostSession(_ id: String) -> UUID? {
        let prefix = "\(NodeIds.node):"
        return id.hasPrefix(prefix) ? UUID(uuidString: String(id.dropFirst(prefix.count))) : nil
    }

    /// A session's name as the node lists it.
    public static func asker(_ session: HostSession) -> String { session.label.isEmpty ? "session \(session.tty)" : session.label }

    // MARK: The one reader

    /// The requests in this plugin's folder that the session host stamped (`parse` reads the folder strictly, as
    /// `ShellAsk.filed` does: requests, the stamp beside each, what it refused), each stamp checked with the host once
    /// (the vault's `verifyWallet`), none dated more than `aheadAtMost` past the clock. Read on `work`; `then` on the
    /// engine's queue with them, oldest first.
    public func stamped<Ask: StampedAsk>(
        _ parse: @escaping @Sendable (URL) -> (requests: [Ask], stamps: [String: WalletStamp], refused: [(file: URL, why: String)]),
        then: @escaping ([Ask]) -> Void
    ) {
        guard let folder else { return then([]) }
        let (vault, trusted, now, note, id, engine) = (engine.cardVault, engine.pluginTrusted[id] ?? [:], now, note, id, engine)
        work.async {
            let found = Self.read(folder: folder, parse: parse, trusted: trusted, vault: vault, now: now, plugin: id, note: note)
            engine.queue.async {
                engine.pluginTrusted[id] = found.trusted
                then(found.requests)
            }
        }
    }

    /// A request dated this far ahead of the server's clock isn't given (its life would run late).
    public static let aheadAtMost: TimeInterval = 120

    /// The reader itself. Blocks: on the plugins' `work`.
    static func read<Ask: StampedAsk>(folder: URL, parse: (URL) -> (requests: [Ask], stamps: [String: WalletStamp], refused: [(file: URL, why: String)]),
                                      trusted given: [String: WalletStamp], vault: LeadVault, now: Date, plugin: String,
                                      note: (String) -> Void) -> (requests: [Ask], trusted: [String: WalletStamp]) {
        let (requests, stamps, refused) = parse(folder)
        for (file, why) in refused { note("\(plugin) request not shown: \(file.lastPathComponent): \(why)") }
        var trusted = given.filter { stamps[$0.key] == $0.value }
        let unasked = requests.filter { trusted[$0.id] == nil }.compactMap { request in stamps[request.id].map { (request.id, $0) } }
        if !unasked.isEmpty {
            do {
                let valid = try vault.verifyWallet(unasked.map(\.1))
                for ((id, stamp), ok) in zip(unasked, valid) {
                    if ok { trusted[id] = stamp } else { note("\(plugin) request not shown: \(id): its stamp isn't the session host's") }
                }
            } catch {
                note("\(plugin) requests: the stamps weren't checked: \(error)")
            }
        }
        var found: [Ask] = []
        for request in requests where trusted[request.id] != nil && trusted[request.id] == stamps[request.id] {
            guard request.created.timeIntervalSince(now) <= aheadAtMost else {
                note("\(plugin) request not shown: \(request.id): filed for \(request.created), ahead of this clock")
                continue
            }
            found.append(request)
        }
        return (found, trusted)
    }

    // MARK: Cards

    /// This plugin's card for request `request`, when one was drawn.
    public func card(request: String) -> CardStore.Card? {
        engine.pluginCards[PluginKey(plugin: id, request: request)].flatMap { engine.cards.cards[$0] }
    }

    /// Draws `shown` as a new open card in `root` (the folder it's about): refused, with why, when the core's checks
    /// refuse it (`PluginCard.refusal`), when it isn't this plugin's or already has a card. Its context is cut
    /// (`PluginCard.drawn`).
    @discardableResult
    public func draw(_ shown: PluginCard, root: String, at: Date) -> Result<CardStore.Card, PluginRefusal> {
        guard shown.plugin == id else { return .failure(PluginRefusal("a card of another plugin")) }
        if let why = shown.refusal { return .failure(PluginRefusal(why)) }
        let key = PluginKey(plugin: id, request: shown.request)
        guard engine.pluginCards[key] == nil else { return .failure(PluginRefusal("request \(shown.request) has a card already")) }
        var card = CardStore.Card(root: root, kind: .plugin, at: at)
        card.plugin = shown.drawn
        engine.pluginCards[key] = card.id
        engine.cards.put(card)
        return .success(card)
    }

    /// Changes this plugin's card for `request` (its state, its outcome; `closed` closes it): nothing when there's none.
    /// The request it shows can't change: what was shown is what is answered.
    public func change(request: String, state: String, outcome: String?, closed: String? = nil) {
        guard var card = card(request: request), var shown = card.plugin else { return }
        guard shown.state != state || shown.outcome != outcome || (closed != nil && card.isOpen) else { return }
        shown.state = state
        shown.outcome = outcome
        card.plugin = shown
        if let closed, card.isOpen { card.closed = closed }
        engine.cards.put(card)
    }

    /// Forgets the card of `request` (its request is gone): an open one closes, saying `closed`.
    public func forget(request: String, closed: String) {
        let key = PluginKey(plugin: id, request: request)
        guard let cardID = engine.pluginCards.removeValue(forKey: key) else { return }
        if var card = engine.cards.cards[cardID], card.isOpen {
            card.closed = closed
            engine.cards.put(card)
        }
    }

    /// The requests this plugin has cards for.
    public var carded: [String] { engine.pluginCards.keys.filter { $0.plugin == id }.map(\.request) }

    // MARK: Telling

    /// Tells `session` `text` as a message from `from` (VibeSwitcher's words: "from New Shell"); `then` with how it went.
    public func tell(_ text: String, from: String, session: UUID, then: @escaping (SessionDelivery) -> Void) {
        engine.tell(text, from: .system(from), session: session, then: then)
    }

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
}

public struct PluginRefusal: Error, Equatable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}
