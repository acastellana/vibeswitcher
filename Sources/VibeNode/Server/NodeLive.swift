import Foundation
import VibeCore

/// The live protocol and the web page joined to a server (the live plan's I1): the hub (lane B) fed by the stores, the
/// gate and its tokens (lane F), the page's files (lane C) and the listener (lane A), each behind its seam. The
/// integrator's file; `ServerStart` makes one, `NodeServer` hands it the Unix socket's `subscribe`, and `Requests` its
/// `web.open` and `web.revoke`.
///
/// - **Streams.** `node` (`NodeStatusStore`: `status` less its lists, with `web`), `sessions` (`Session.liveValue`, by
///   terminal), `leads` (`status`'s lead values, by root), `cards` (`CardStore.Card.value`, by `at`) and `boards`
///   (`LiveBoards`' `BoardValue`, by project: each lead's board, read-only). A lead's value
///   says its open cards and the witness's looks, which `LeadStore` doesn't send, so the leads are looked at again on
///   each change of the leads or the cards and at each of the engine's refreshes; an equal value sends nothing.
/// - **The web.** Off until a code or a token is alive (LW-D3): `follow()` at the start binds it only when
///   `web-tokens.json` holds a live token. `web.open` binds it (`WebAccess.listen`); a revoke closes every page
///   (`revoked`, 4403) and, with nothing alive, the listener. A sweep at each housekeeping drops late codes, closes a
///   page whose token ran out, and lets the listener go once nothing wants it.
/// - **Chats** (slice 2): `ChatStore` on the sessions' transcripts, a session's stream opened by its first `chat`
///   subscription and dropped a minute after its last; `chat.page` reads one. The hub takes both.
/// - **A web connection** is screened first (`WebRequestScreen`: a token reads and drafts, never the user's voice),
///   then the hub takes `subscribe` and `unsubscribe`, a draft goes to `Requests.draft` (I3), and what is left
///   (`status`, `questions`) goes to `Requests` as a peer that is nobody's voice.
///
/// On the engine's queue (`queue`): the listener's sockets are served there too, so a store's change, the hub's delta
/// and its frame are written in one turn, with no hop between (the plan's LW-D14).
public final class NodeLive: @unchecked Sendable {
    public let queue: DispatchQueue
    public let hub: LiveHub
    public let status: NodeStatusStore
    public let access: WebAccess
    public let web: NodeWebListener
    /// The page on the user's tailnet (`vibeswitcher web --tailnet`); none on a scratch server.
    public let tailnet: TailnetWeb?
    /// The page's files: the embedded ones, or a scratch server's folder.
    public let assets: LiveAssets
    /// The sessions' chats; none for a server with no sessions store.
    public private(set) var chats: ChatStore?
    /// The leads' boards (the `boards` stream, `vibeswitcher board`); none for a server with no engine.
    public private(set) var boards: LiveBoards?
    /// The `sessions` stream's values: each session with its prompt and draft.
    private var sessionValues: SessionLiveValues?

    private let requests: Requests
    private let sessions: NodeSessions?
    private let engine: LeadEngine?
    private let clock: NodeClock
    private let note: @Sendable (String) -> Void
    /// The leads' values as the `leads` stream follows them (a lead's open cards and looks are `status`'s additions).
    private let leads = Changes<NodeWire.Value>()
    private var leadIDs: Set<String> = []
    private var follows: [Subscription] = []
    private var ticks: [Subscription] = []

    /// How often late codes are dropped and pages whose token ran out are closed, in seconds.
    public static let sweepEvery = 30

    /// `port`: the web's (`NodeWeb.port` on the user's node; a scratch server's `--test-web-port=`, 0 for the kernel's
    /// pick). `webRoot`: a scratch server's `--test-web-root=`. `terminals`: what a page may do with a session's
    /// terminal (`term.open` through a `TerminalRelay`, the live plan's I4; `ServerArguments.webTerminal`: the user's
    /// node watches, a scratch server's `--test-web-terminal` types); nil, `term.open` is `unknown-kind`. `clock`: the
    /// engine's. `tailnet`: the user's node's page on the tailnet (`TailnetWeb`, on the same port at the tailnet's
    /// address); nil, `web --tailnet` is refused.
    public init(requests: Requests, sessions: NodeSessions?, engine: LeadEngine?, clock: NodeClock, port: UInt16 = NodeWeb.port,
                webRoot: URL? = nil, terminals mode: TerminalRelay.Mode? = nil, tailnet: TailnetWeb.Options? = nil,
                note: @escaping @Sendable (String) -> Void = { _ in }) {
        queue = requests.queue
        self.requests = requests
        self.sessions = sessions
        self.engine = engine
        self.clock = clock
        self.note = note
        hub = LiveHub(queue: queue, epoch: requests.epoch)
        let terminals = mode != nil
        if let mode { hub.terminals = TerminalRelay(link: requests.link, mode: mode, note: note) }
        access = WebAccess(tokens: WebTokens(root: requests.root), note: note)
        let bound = BoundPort()
        let assets = LiveAssets(folder: webRoot, port: { bound.port })
        self.assets = assets
        web = NodeWebListener(port: port, assets: assets, gate: access, handler: WebRequestScreen(hub, terminals: terminals, note: note),
                              queue: queue, clock: clock, hello: { [weak requests] admission in
                                  guard let requests else { return nil }
                                  var hello = requests.webHello(admission, assets: assets.build)
                                  if terminals, admission.rights.contains(.read) { hello.kinds += Self.terminalKinds }
                                  return NodeWire.message(hello)
                              }, note: { note($0) })
        bound.web = web
        // The tailnet's page: the same hub behind its own screen, which lets no terminal kind through.
        let liveQueue = requests.queue, liveHub = hub
        self.tailnet = tailnet.map { options in
            TailnetWeb(root: requests.root, queue: liveQueue, clock: clock, port: port, find: options.find, admitPeer: options.admitPeer,
                       folder: webRoot, handler: WebRequestScreen(liveHub, terminals: false, note: note),
                       hello: { [weak requests] admission in
                           guard let requests else { return nil }
                           return NodeWire.message(requests.webHello(admission, assets: assets.build))
                       }, note: note)
        }
        let said = SaidWeb()
        status = NodeStatusStore(requests: requests, web: { said.live?.webValue() ?? NodeStatusStore.webOff })
        let web = web
        access.listen = {
            if let port = web.port { return .success(port) }
            do {
                return .success(try web.start())
            } catch {
                if case .refused(let why) = web.state { return .failure(WebTokens.Refusal(why)) }
                return .failure(WebTokens.Refusal("\(error)"))
            }
        }
        access.onChange = { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.web.follow()
                self.status.look()
            }
        }
        access.onRevoke = { web.closeAll(code: "revoked", reason: "this page's access was revoked: run `vibeswitcher web` again") }
        hub.others = { [weak requests] request, transport, rights in
            guard let requests else { return }
            let answer = { (reply: NodeWire.Reply) in transport.send(NodeWire.message(reply)) }
            // A draft is a page's alone: its token's right judged again here (the screen judged it first), never `handle`.
            if NodeWire.kinds[request.kind] == .webDraft {
                guard rights.contains(.draft) else { return answer(.init(re: request.id, error: .init(.voice, "this page's token doesn't draft"))) }
                return requests.draft(request, reply: answer)
            }
            // A private record's read (Between leads): the screen judged its token's `read` right; never `handle`'s
            // user's-voice path, which a page never passes.
            if NodeWire.kinds[request.kind] == .webRead {
                guard rights.contains(.read) else { return answer(.init(re: request.id, error: .init(.voice, "this page's token doesn't read"))) }
                return requests.webRead(request, reply: answer)
            }
            requests.handle(request, from: NodeLive.webPeer, reply: answer)
        }
        let hub = hub
        requests.liveSeq = { [weak hub] in hub?.seq(of: $0) ?? 0 }
        requests.web = access
        requests.tailnet = self.tailnet
        requests.webValue = { said.live?.webValue() ?? NodeStatusStore.webOff }
        said.live = self
    }

    /// What a server that opens terminals adds to a page's `hello.kinds`.
    public static let terminalKinds = ["term.open", "term.close"]

    /// A web connection as `Requests` sees it: no process, no terminal, no cgroup. It is never the user's voice (the
    /// screen refuses those kinds before; this is the second lock), and nobody's tool server.
    static let webPeer = PeerFacts(pid: 0, uid: nil, cgroup: nil, ancestry: nil, terminal: .none, sessionMarker: nil, underRunner: nil)

    /// The streams fed, the leads looked at, the web brought to what the tokens want, and the sweeps on the clock. On
    /// `queue`, once.
    public func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        let sessionsStream = LiveStream(collection: "sessions", order: .field("terminal"))
        let leadsStream = LiveStream(collection: "leads", order: .field("root"))
        let cardsStream = LiveStream(collection: "cards", order: .fields(["at"]))
        let nodeStream = LiveStream(collection: "node")
        for stream in [sessionsStream, leadsStream, cardsStream, nodeStream] { hub.add(collection: stream.collection, stream) }
        if let sessions {
            let values = SessionLiveValues(queue: queue, sessions: sessions, drafts: requests.sessionDrafts, held: requests.heldSends,
                                           hosts: requests.link.changes)
            values.start()
            hub.follow(values.changes, into: sessionsStream) { $0 }
            sessionValues = values
            status.watch(sessions.changes)
            // Long messages' TL;DRs from the engine's AI summaries (`TeamSummaryWatch`), when there is an engine.
            let chats = ChatStore(queue: queue, home: requests.home, sessions: sessions.changes, note: note, summaries: engine?.messageSummaries,
                                  ask: engine.map { engine in { session, entry, message in engine.summarizeMessage(session: session, entry: entry, message: message) } },
                                  extras: engine?.chatExtras)
            chats.start(clock: clock)
            hub.chats = chats
            self.chats = chats
        }
        status.watch(requests.link.changes)
        if let engine {
            hub.follow(engine.cards.changes, into: cardsStream) { $0.value }
            status.watch(engine.leads.changes)
            status.watch(engine.cards.changes)
            follows.append(engine.leads.changes.subscribe(on: queue) { [weak self] _ in self?.lookLeads() })
            follows.append(engine.cards.changes.subscribe(on: queue) { [weak self] _ in self?.lookLeads() })
        }
        lookLeads()
        hub.follow(leads, into: leadsStream) { $0 }
        if let engine { startBoards(engine) }
        status.start(clock: clock)
        hub.follow(status.changes, into: nodeStream) { $0 }
        ticks.append(clock.every(NodeStatusStore.refreshEvery) { [weak self] in self?.lookLeads() })
        ticks.append(clock.every(Self.sweepEvery) { [weak self] in self?.sweep() })
        // After a restart, the web is bound again only when a token is alive (LW-D3).
        web.follow()
        if case .refused(let why) = web.state { note("the web isn't up: \(why)") }
        tailnet?.follow()
    }

    /// The `boards` stream (the parity table's gap 4): each lead's board, read by `LiveBoards`, and `board`'s answer.
    private func startBoards(_ engine: LeadEngine) {
        let boards = LiveBoards(queue: queue, leads: engine.leads.changes, usageWaits: engine.usageWaits, summaries: engine.teamSummaries,
                                decisions: engine.boardDecisions, note: note)
        let stream = LiveStream(collection: "boards", order: .field("project"))
        hub.add(collection: stream.collection, stream)
        boards.start(clock: clock)
        hub.follow(boards.changes, into: stream) { $0 }
        requests.boards = { [weak boards] in boards?.values ?? [:] }
        self.boards = boards
    }

    /// Late codes dropped, pages whose token ran out closed, and the listener let go once nothing wants it.
    func sweep() {
        access.sweep()
        web.closeUnheld()
        web.follow()
        tailnet?.sweep()
        status.look()
    }

    /// Each lead's value now, sent when it changed; a lead gone is removed. On `queue`.
    private func lookLeads() {
        guard let engine else { return }
        var now: [String: NodeWire.Value] = [:]
        for lead in engine.leads.leads.values { now[lead.project] = requests.leadValue(lead) }
        for gone in leadIDs.subtracting(now.keys).sorted() { leads.send(gone, nil) }
        for id in now.keys.sorted() { leads.send(id, now[id]) }
        leadIDs = Set(now.keys)
    }

    /// `status`'s and the `node` stream's `web`: the listener's state (`off`, `listening`, `refused: <why>`), its port,
    /// the tokens alive and the connections open.
    public func webValue() -> NodeWire.Value {
        let state: String, port: NodeWire.Value
        switch web.state {
        case .off: (state, port) = ("off", .null)
        case .on(let bound): (state, port) = ("listening", .int(Int(bound)))
        case .refused(let why): (state, port) = ("refused: " + why, .null)
        }
        return .object(["state": .string(state), "port": port, "tokens": .int(access.tokens.live(now: Date())),
                        "connections": .int(web.connectionCount)])
    }

    /// This, once made: what `status` and the `node` stream ask for `web`.
    private final class SaidWeb: @unchecked Sendable {
        weak var live: NodeLive?
    }

    /// The listener, once made: its port is the page's origin, which the files' policy names.
    private final class BoundPort: @unchecked Sendable {
        weak var web: NodeWebListener?
        var port: UInt16 { web?.port ?? 0 }
    }
}

/// The page's files as the listener serves them: the embedded ones (the user's node, rule 10), or a scratch server's
/// folder read at each request; their policy names the port the listener is bound to.
public struct LiveAssets: WebAssetSource {
    public let folder: URL?
    let port: @Sendable () -> UInt16
    /// The listener's name in the policy: the loopback's address, or the tailnet's MagicDNS name (`TailnetWeb`).
    var host = "127.0.0.1"

    public func asset(path: String) -> WebAsset? {
        if let folder { return FolderAssets(root: folder, port: port(), host: host).asset(path: path) }
        return EmbeddedAssets(port: port(), host: host).asset(path: path)
    }

    /// `hello.assets`: the build of the files served now.
    public var build: String {
        folder.flatMap { FolderAssets(root: $0, port: 0).build } ?? EmbeddedAssets.build
    }
}
