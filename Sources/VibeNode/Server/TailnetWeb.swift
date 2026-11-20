import Foundation
import VibeCore

/// The node's page on the user's tailnet (the remote access note, docs/superpowers/specs/2026-11-20-v2-remote-access.md):
/// a second listener beside the loopback one, on this machine's Tailscale address, under its MagicDNS name, behind a
/// gate of its own. `NodeLive` makes one on the user's node only; a scratch server has none.
///
/// - **Off by default.** Bound when `vibeswitcher web --tailnet` (`open`, the user's voice) makes a code, or after a
///   restart when `web-tokens-tailnet.json` holds a live token; let go once neither is alive, or at `revoke`.
/// - **Where.** `Tailnet.find` (a root-only `tailscale`, run off the engine's queue): the 100.64/10 address on one of
///   this machine's interfaces is bound, never `0.0.0.0`; the page's one name is the MagicDNS name, so Host must be
///   exactly `<name>:<port>` and Origin `http://<name>:<port>` (`NodeWebListener`), and the policy names that socket.
///   A peer outside Tailscale's ranges is closed at accept (`admitPeer`).
/// - **Its own gate.** `WebAccess` on `WebTokens.tailnet`: 8 h tokens, at most 4, in their own file, so a loopback
///   code or token is never taken here nor one of these on loopback. The same rights: read and draft, never the
///   user's voice; no terminal (its `hello` lists no `term.*`, and the screen refuses them).
///
/// On the engine's queue (`queue`), but `open` and `follow` may be called from any thread.
public final class TailnetWeb: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case off
        /// Asking `tailscale` where to bind.
        case looking
        case on(TailnetPlace, port: UInt16)
        /// Wanted, and it couldn't be bound: why.
        case refused(String)
    }

    /// Where to bind and whom to keep: Tailscale's answer and ranges on the user's node, a test's own otherwise.
    public struct Options: Sendable {
        public var find: Tailnet.Finder
        public var admitPeer: @Sendable (String) -> Bool

        public init(find: @escaping Tailnet.Finder = Tailnet.find, admitPeer: @escaping @Sendable (String) -> Bool = Platform.TCP.isTailscaleAddress) {
            self.find = find
            self.admitPeer = admitPeer
        }
    }

    /// What a page on the tailnet is told to run again.
    public static let command = "vibeswitcher web --tailnet"

    public let queue: DispatchQueue
    public let access: WebAccess
    private let port: UInt16
    private let find: Tailnet.Finder
    private let admitPeer: @Sendable (String) -> Bool
    private let folder: URL?
    private let handler: WebSocketHandler
    private let hello: (WebAdmission) -> Data?
    private let clock: NodeClock
    private let note: @Sendable (String) -> Void

    private let lock = NSLock()
    private var current = State.off
    /// The listener, under `lock`, for `connectionCount` from any thread.
    private var held: NodeWebListener?
    // On `queue`.
    private var listener: NodeWebListener? {
        didSet { lock.withLock { held = listener } }
    }
    private var waiting: [(Result<TailnetPlace, WebTokens.Refusal>) -> Void] = []

    /// `root`: the node's (its `v2/web-tokens-tailnet.json`). `port`: the web's. `find`: where to bind (`Tailnet.find`;
    /// a test's own). `admitPeer`: which peers are kept (Tailscale's ranges; a test's own). `folder`: a scratch
    /// server's page files. `handler`: the screen around the hub, with no terminal. `hello`: the `hello` for an
    /// admitted connection.
    public init(root: URL, queue: DispatchQueue, clock: NodeClock, port: UInt16 = NodeWeb.port, find: @escaping Tailnet.Finder = Tailnet.find,
                admitPeer: @escaping @Sendable (String) -> Bool = Platform.TCP.isTailscaleAddress, folder: URL? = nil,
                handler: WebSocketHandler, hello: @escaping (WebAdmission) -> Data?, now: @escaping @Sendable () -> Date = { Date() },
                note: @escaping @Sendable (String) -> Void = { _ in }) {
        self.queue = queue
        self.port = port
        self.find = find
        self.admitPeer = admitPeer
        self.folder = folder
        self.handler = handler
        self.hello = hello
        self.clock = clock
        self.note = note
        access = WebAccess(tokens: WebTokens.tailnet(root: root), now: now, note: { note("tailnet: " + $0) })
        access.listen = { [weak self] in
            guard let self, let port = self.port(of: self.state) else { return .failure(WebTokens.Refusal("the tailnet listener isn't up")) }
            return .success(port)
        }
        access.onChange = { [weak self] in self?.follow() }
        access.onRevoke = { [weak self] in
            self?.queue.async { self?.listener?.closeAll(code: "revoked", reason: "this page's access was revoked: run `\(Self.command)` again") }
        }
    }

    public var state: State { lock.withLock { current } }

    /// The listener's connections open now (tests, `status`).
    public var connectionCount: Int { lock.withLock { held }?.connectionCount ?? 0 }

    // MARK: The user's voice

    /// `web.open` with `tailnet`: the listener bound where Tailscale says (asked off the queue when it isn't bound),
    /// then a code made; `done` gets the address to print, or why there is none. `done` is called on `queue`.
    public func open(_ done: @escaping (Result<WebAccess.Opened, WebTokens.Refusal>) -> Void) {
        queue.async { [self] in
            if listener != nil { return done(access.open()) }
            place { [self] found in
                switch found {
                case .failure(let refusal): done(.failure(refusal))
                case .success(let place):
                    if let refusal = bind(place) { return done(.failure(refusal)) }
                    done(access.open())
                }
            }
        }
    }

    /// Every tailnet code and token dropped, every tailnet page closed (`revoked`), and the listener let go: how many
    /// tokens were alive.
    public func revoke() -> Result<Int, WebTokens.Refusal> { access.revoke() }

    // MARK: Up while wanted

    /// Brings the listener to what the gate wants: bound while a code or a token is alive (Tailscale asked first, off
    /// the queue), let go otherwise, its pages told `revoked`. At the start, at each change of the gate, at each sweep.
    public func follow() {
        queue.async { [self] in
            if access.wanted {
                guard listener == nil, waiting.isEmpty else { return }
                place { [self] found in
                    guard access.wanted, listener == nil else { return }
                    if case .success(let place) = found { _ = bind(place) }
                }
            } else if let listener {
                listener.closeAll(code: "revoked", reason: "the tailnet page was closed: run `\(Self.command)` again")
                listener.stop()
                self.listener = nil
                set(.off)
                note("tailnet: the listener was let go: no code or token is alive")
            } else if waiting.isEmpty {
                set(.off)
            }
        }
    }

    /// Late codes dropped, pages whose token ran out closed, and the listener brought to what the gate wants.
    public func sweep() {
        access.sweep()
        queue.async { [self] in listener?.closeUnheld() }
        follow()
    }

    // MARK: On the queue

    /// Asks `find` off the queue, once for every caller waiting, and calls each back on the queue.
    private func place(_ then: @escaping (Result<TailnetPlace, WebTokens.Refusal>) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        waiting.append(then)
        guard waiting.count == 1 else { return }
        set(.looking)
        let find = find
        DispatchQueue.global().async { [weak self] in
            let found = find()
            self?.queue.async { [weak self] in
                guard let self else { return }
                let callers = waiting
                waiting = []
                if case .failure(let refusal) = found {
                    set(.refused(refusal.description))
                    note("tailnet: not bound: \(refusal.description)")
                }
                for caller in callers { caller(found) }
            }
        }
    }

    /// A listener on `place`: nil once it is bound, or why it couldn't be.
    private func bind(_ place: TailnetPlace) -> WebTokens.Refusal? {
        dispatchPrecondition(condition: .onQueue(queue))
        if listener != nil { return nil }
        let bound = Bound()
        let assets = LiveAssets(folder: folder, port: { bound.port }, host: place.name)
        let made = NodeWebListener(port: port, address: place.address, name: place.name, admitPeer: admitPeer, command: Self.command,
                                   assets: assets, gate: access, handler: handler, queue: queue, clock: clock, hello: hello, note: { [note] in note("tailnet: " + $0) })
        bound.web = made
        do {
            let port = try made.start()
            listener = made
            access.host = place.name
            set(.on(place, port: port))
            note("tailnet: listening on \(place.address):\(port) as \(place.name)")
            return nil
        } catch {
            let why: String
            if case .refused(let said) = made.state { why = said } else { why = "\(error)" }
            set(.refused(why))
            return WebTokens.Refusal(why)
        }
    }

    private func set(_ state: State) { lock.withLock { current = state } }

    private func port(of state: State) -> UInt16? {
        if case .on(_, let port) = state { return port }
        return nil
    }

    /// The listener, once made: its port is in its files' policy.
    private final class Bound: @unchecked Sendable {
        weak var web: NodeWebListener?
        var port: UInt16 { web?.port ?? 0 }
    }

    /// `status`'s `webTailnet`: `{"state": "off" | "looking" | "listening" | "refused: <why>", "name", "address", "port",
    /// "tokens", "connections"}`, the place's fields null while it isn't bound.
    public func value() -> NodeWire.Value {
        var fields: [String: NodeWire.Value] = ["name": .null, "address": .null, "port": .null,
                                                "tokens": .int(access.tokens.live(now: Date())), "connections": .int(connectionCount)]
        switch state {
        case .off: fields["state"] = .string("off")
        case .looking: fields["state"] = .string("looking")
        case .refused(let why): fields["state"] = .string("refused: " + why)
        case .on(let place, let port):
            fields["state"] = .string("listening")
            (fields["name"], fields["address"], fields["port"]) = (.string(place.name), .string(place.address), .int(Int(port)))
        }
        return .object(fields)
    }

    /// `status`'s words for it: `off`, `looking`, `listening on http://<name>:<port>`, `refused: <why>`.
    public var words: String {
        switch state {
        case .off: return "off"
        case .looking: return "looking for this machine's Tailscale address"
        case .on(let place, let port): return "listening on http://\(place.name):\(port)/ (\(place.address))"
        case .refused(let why): return "refused: " + why
        }
    }
}
