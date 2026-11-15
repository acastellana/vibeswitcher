import Foundation
import VibeCore

/// What the server does with a request (the engine plan's "The protocol"): kind → voice → handler, and the list of the
/// user's-voice requests it accepted. On the engine's queue (`queue`, the link's), as `NodeServer` calls it.
///
/// Every accepted user's-voice request is, in this order, recorded (before E6's `vaultV2`, in the server's memory:
/// `accepted`), acted on, and kept among the last 50 `status` shows: its kind, card or project, when, the sender's pid,
/// cgroup and command line, and its action id. The command line writes it to the journal itself (EN-D15).
public final class Requests: @unchecked Sendable {
    /// One accepted user's-voice request, as `status` shows it.
    public struct Accepted: Equatable, Sendable {
        public var kind: String
        public var action: String?
        /// The card or project it named, when it named one.
        public var subject: String?
        public var at: Date
        public var pid: pid_t
        public var cgroup: String?
        public var commandLine: [String]

        public var value: NodeWire.Value {
            .object(["kind": .string(kind), "action": action.map(NodeWire.Value.string) ?? .null,
                     "subject": subject.map(NodeWire.Value.string) ?? .null, "at": .date(at), "pid": .int(Int(pid)),
                     "cgroup": cgroup.map(NodeWire.Value.string) ?? .null,
                     "commandLine": .array(commandLine.map(NodeWire.Value.string))])
        }
    }

    /// How many accepted requests `status` keeps.
    public static let acceptedKept = 50
    /// How long `stop` waits for the sessions it ended to be gone.
    public static let stopWait: TimeInterval = 30

    public let queue: DispatchQueue
    public let link: HostLink
    public let sessions: NodeSessions?
    public let rule: VoiceRule
    public let root: URL
    public let hostSocket: String
    /// A UUID made at this server's start (rule 8).
    public let epoch = UUID().uuidString.lowercased()
    public let startedAt = Date()
    public let commit: String
    let note: (String) -> Void
    /// The host and the server, for the voice rule's ancestry.
    private let hostPID: pid_t
    private let serverPID = getpid()

    public private(set) var accepted: [Accepted] = []
    /// The host's notes as last asked, and when they came.
    public private(set) var notes: (notes: HostNotes, at: Date)?
    /// `stop` is under way: no other state-changing request is taken.
    public private(set) var stopping = false
    /// The host's shutdown, as `stop` asks it; a test gives its own.
    var shutdown: () -> HostEvent? = { nil }
    /// The lead engine `lead` starts leads through, and whose leads `status` lists (E4); none: `lead` is refused.
    public var engine: LeadEngine?
    /// The reply each recorded action got, by action id, the newest `repliesKept` (a retry is answered so).
    private var replies: [String: NodeWire.Reply] = [:]
    private var replyOrder: [String] = []
    /// Each request as it is acted on, after the voice, the code and the vault's record (for tests). On `queue`.
    public var acting: (NodeWire.Request) -> Void = { _ in }

    public init(link: HostLink, sessions: NodeSessions?, rule: VoiceRule, root: URL, hostSocket: String, commit: String,
                hostPID: pid_t = getppid(), note: @escaping (String) -> Void = { _ in }) {
        queue = link.queue
        self.link = link
        self.sessions = sessions
        self.rule = rule
        self.root = root
        self.hostSocket = hostSocket
        self.commit = commit
        self.hostPID = hostPID
        self.note = note
        shutdown = { [hostSocket] in try? HostCall.request(.shutdown, socket: hostSocket, appKey: nil, timeout: 15) }
    }

    /// The live sessions now, for the voice rule. On `queue`.
    public var live: LiveSessions { LiveSessions(link.sessions, host: hostPID, server: serverPID) }

    /// The hello a new connection from `peer` gets. On `queue`.
    public func hello(peer: PeerFacts?) -> NodeWire.Hello {
        let voice = peer.map { Voice.judge($0, live: live, rule: rule) } ?? .notUser("its process can't be read")
        let why: String? = { if case .notUser(let why) = voice { return why } else { return nil } }()
        return NodeWire.Hello(node: NodeIds.node, epoch: epoch,
                              server: .init(commit: commit, startedAt: NodeWire.dateText(startedAt), pid: serverPID),
                              host: .init(startedAt: link.hostStartedAt.map(NodeWire.dateText), notes: notes.map { Self.value($0.notes, at: $0.at) }),
                              kinds: NodeWire.taken, peer: .init(voice: voice == .user ? "user" : "other", why: why),
                              rule: rule.mode.rawValue)
    }

    /// Asks the host's notes (`HostLink.notes`) and keeps them; `done` once they came, or didn't. Each housekeeping
    /// asks, and `status` asks too. On `queue`.
    public func refreshNotes(_ done: @escaping () -> Void = {}) {
        link.notes { [weak self] notes in
            guard let self else { return done() }
            self.queue.async {
                if let notes { self.notes = (notes, Date()) }
                done()
            }
        }
    }

    /// The kinds recorded in the vault before they are acted on (EN-D11): every state-changing user's-voice request.
    public static let recorded: Set<String> = ["start", "stop", "lead", "answer", "hold", "config.accept", "base.accept", "base.keep"]
    /// The kinds on a card: the card's code (EN-D5), typed by the user, is checked here.
    public static let carded: Set<String> = ["answer", "hold", "config.accept", "base.accept", "base.keep"]
    /// How many replies to recorded actions are kept, so a repeated action (a retry) gets the reply it got.
    static let repliesKept = 200

    /// Answers `request` from the process `facts` reads (whose kind this server takes: `NodeServer` answers the
    /// rest), through `reply`, once. On `queue`.
    ///
    /// A user's-voice request passes the voice, then (one on a card) its card's code, then, when it changes state, is
    /// recorded in the host's vault with its action id and digest (`LeadVaultV2Client.recordUserAction`) before it is
    /// acted on: one the vault doesn't take is refused, and an action the vault holds already (a retry) is answered as
    /// it was, not done again.
    public func handle(_ request: NodeWire.Request, from facts: PeerFacts, reply: @escaping (NodeWire.Reply) -> Void) {
        let needs = NodeWire.kinds[request.kind] ?? .user
        if needs == .leadToolServer { return questionPost(request, from: facts, reply: reply) }
        if needs == .user {
            if case .notUser(let why) = Voice.judge(facts, live: live, rule: rule) {
                note("refused \(request.kind) from pid \(facts.pid): not the user's voice: \(why)")
                return reply(.init(re: request.id, error: .init(.voice, "not the user's voice: \(why)")))
            }
            let records = Self.recorded.contains(request.kind)
            guard !records || request.action.map({ UUID(uuidString: $0) != nil }) == true else {
                return reply(.init(re: request.id, error: .init(.badArgs, "\(request.kind) needs an action id (a UUID)")))
            }
            guard !stopping else { return reply(.init(re: request.id, error: .init(.stopping, "the node is stopping"))) }
            // Before the host's welcome (and while the link reconnects) its session list isn't known: a state change
            // judged on it could be wrong (a `stop` would find nothing live). The command line asks again.
            guard link.state == .connected else {
                return reply(.init(re: request.id, error: .init(.notYet, "the server's link to its host isn't welcomed yet: retry")))
            }
            if Self.carded.contains(request.kind), let refusal = cardRefusal(request) { return reply(refusal) }
            if records, let action = request.action?.lowercased() {
                return record(request, action: action, from: facts) { [weak self] recorded in
                    guard let self else { return }
                    switch recorded {
                    case .failure(let why):
                        self.note("refused \(request.kind) (action \(action)): not recorded in the vault: \(why)")
                        reply(.init(re: request.id, error: .init(.internal, "not recorded in the host's vault, so not done: \(ConfigSeal.inert(why.description, limit: .max))")))
                    case .success(false):
                        self.note("\(request.kind) (action \(action)) was recorded already: answered as before, not done again")
                        var again = self.replies[action] ?? .init(re: request.id, result: .object(["again": .bool(true), "said": .string("this action was done already")]))
                        again.re = request.id
                        reply(again)
                    case .success(true):
                        self.act(request) { [weak self] answer in
                            self?.keep(answer, for: action)
                            reply(answer)
                        }
                    }
                }
            }
        }
        act(request, reply: reply)
    }

    /// What `request` does, once it passed.
    private func act(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        acting(request)
        switch request.kind {
        case "status": status(request, reply: reply)
        case "start": start(request, reply: reply)
        case "stop": stop(request, reply: reply)
        case "lead": lead(request, reply: reply)
        case "questions": questions(request, reply: reply)
        case "answer": answer(request, reply: reply)
        case "hold": hold(request, reply: reply)
        case "config.held": configHeld(request, reply: reply)
        case "config.accept": configAccept(request, reply: reply)
        case "base.show": baseShow(request, reply: reply)
        case "base.accept", "base.keep": baseAnswer(request, reply: reply)
        default: reply(.init(re: request.id, error: .init(.unknownKind, "this server doesn't take \(request.kind)")))
        }
    }

    private func keep(_ reply: NodeWire.Reply, for action: String) {
        replies[action] = reply
        replyOrder.append(action)
        if replyOrder.count > Self.repliesKept { replies[replyOrder.removeFirst()] = nil }
    }

    /// A user's-voice request, recorded in the vault (`done` on `queue` with whether it is the action's first record,
    /// or why it wasn't recorded), then kept for `status`.
    private func record(_ request: NodeWire.Request, action: String, from facts: PeerFacts, done: @escaping (Result<Bool, RecordFailure>) -> Void) {
        let subject = Self.subject(request)
        let digest = LeadVaultV2.digest(String(decoding: NodeWire.line(request.args ?? [:]), as: UTF8.self))
        let (client, kind) = (link.vaultV2, request.kind)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let recorded = Result { try client.recordUserAction(action, kind: kind, subject: subject, digest: digest) }.mapError { RecordFailure("\($0)") }
            guard let self else { return }
            self.queue.async {
                if case .success = recorded {
                    self.accepted.append(Accepted(kind: request.kind, action: action, subject: subject, at: Date(), pid: facts.pid,
                                                  cgroup: facts.cgroup.flatMap { PeerFacts.unifiedPath($0) ?? PeerFacts.systemdPath($0) },
                                                  commandLine: facts.commandLine))
                    if self.accepted.count > Self.acceptedKept { self.accepted.removeFirst(self.accepted.count - Self.acceptedKept) }
                    self.note("accepted \(request.kind) (action \(action)) from pid \(facts.pid), recorded in the vault")
                }
                done(recorded)
            }
        }
    }

    struct RecordFailure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    /// The card or project a request names, as recorded and shown.
    static func subject(_ request: NodeWire.Request) -> String? {
        request.args?["card"]?.string ?? request.args?["project"]?.string ?? request.args?["folder"]?.string
    }

    // MARK: status

    /// How long `status` waits for the host's notes before it answers with the last ones it has.
    public static let notesWait: TimeInterval = 5

    private func status(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let waiting = Waiting()
        let answer = { [weak self] in
            guard let self, !waiting.answered else { return }
            waiting.answered = true
            reply(.init(re: request.id, result: self.statusValue()))
        }
        refreshNotes(answer)
        queue.asyncAfter(deadline: .now() + Self.notesWait) { answer() }
    }

    /// `status`'s result: the node, the server, the host and its notes, the rule, the sessions, leads and cards
    /// (none before E4 and E6), the accepted requests and the notices (the node stopping; a lead whose board names a
    /// session the vault doesn't bind, E5). On `queue`.
    public func statusValue() -> NodeWire.Value {
        let list = sessions?.sessions ?? []
        return .object([
            "node": .string(NodeIds.node),
            "epoch": .string(epoch),
            "root": .string(root.path),
            "server": .object(["pid": .int(Int(serverPID)), "startedAt": .date(startedAt), "commit": .string(commit)]),
            "host": .object(["startedAt": link.hostStartedAt.map(NodeWire.Value.date) ?? .null,
                             "state": .string(Self.word(link.state)),
                             "notes": notes.map { Self.value($0.notes, at: $0.at) } ?? .null]),
            "rule": .object(["mode": .string(rule.mode.rawValue), "says": .string(rule.says),
                             "scopes": .array(rule.scopes.map { .string($0.pattern) })]),
            "sessions": .array(list.map(Self.value)),
            "leads": .array((engine?.leads.leads.values.sorted { $0.root < $1.root } ?? []).map(leadValue)),
            "cards": Self.counts(engine?.cards.counts() ?? [:]),
            "accepted": .array(accepted.map(\.value)),
            "notices": .array((stopping ? ["the node is stopping"] : []).map(NodeWire.Value.string)
                + (engine?.leads.leads.values.sorted { $0.root < $1.root }.compactMap(\.notice) ?? []).map(NodeWire.Value.string)),
        ])
    }

    /// A lead as `status` lists it: the store's, with its open and blocking questions and its open cards (E6).
    private func leadValue(_ lead: LeadStore.Lead) -> NodeWire.Value {
        guard case .object(var fields) = lead.value else { return lead.value }
        let open = engine?.cards.list(project: lead.project) ?? []
        let questions = open.filter { $0.kind == .question || $0.kind == .approval }
        fields["questions"] = .object(["open": .int(questions.count), "blocking": .int(questions.filter(\.isBlocking).count)])
        fields["cards"] = .array(open.map { .string($0.id) })
        return .object(fields)
    }

    /// Open cards counted by kind, as `status` gives them.
    static func counts(_ counts: [CardStore.Kind: Int]) -> NodeWire.Value {
        .object(["questions": .int(counts[.question] ?? 0), "approvals": .int(counts[.approval] ?? 0),
                 "config": .int(counts[.configHeld] ?? 0), "base": .int(counts[.baseMove] ?? 0)])
    }

    static func word(_ state: HostLink.State) -> String {
        switch state {
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .gone(let why): return "gone: " + why
        }
    }

    static func value(_ notes: HostNotes, at: Date) -> NodeWire.Value {
        .object(["startedAt": .date(notes.startedAt), "serverRestarts": .int(notes.serverRestarts),
                 "replacedPaths": .array(notes.replacedPaths.map(NodeWire.Value.string)),
                 "refusedAppConnections": .int(notes.refusedAppConnections),
                 "lockHeldElsewhere": notes.lockHeldElsewhere.map(NodeWire.Value.string) ?? .null,
                 "at": .date(at)])
    }

    /// A session as `status` lists it; its status word as `status --probe` writes one.
    static func value(_ session: Session) -> NodeWire.Value {
        .object(["id": .string(NodeSessions.id(of: session)), "terminal": .string(session.tty), "agent": .string(session.agent.rawValue),
                 "cwd": session.cwd.map(NodeWire.Value.string) ?? .null, "status": .string(statusWord(session.status)),
                 "since": .date(session.statusSince), "hosted": .bool(session.hostID != nil),
                 "role": session.teamRole.map { .string("\($0)") } ?? .null])
    }

    /// `needs-you`, `working`, …: the glossary's word in kebab case, as `LocalSession.statusWord`.
    public static func statusWord(_ status: SessionStatus) -> String {
        status.word.rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1-$2", options: .regularExpression).lowercased()
    }

    // MARK: start

    /// The node runs: its start time. Starting a stopped node is the bootstrap path's step 8's, without the server.
    private func start(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        reply(.init(re: request.id, result: .object([
            "running": .bool(true), "serverStartedAt": .date(startedAt),
            "hostStartedAt": link.hostStartedAt.map(NodeWire.Value.date) ?? .null, "epoch": .string(epoch),
        ])))
    }

    // MARK: stop

    /// EN-D6: no other state-changing request from now on; the leads ended first, and once none is live every other
    /// session; at each change of the link's list until nothing is live, any live session not yet asked to end is (a
    /// worker a lead's tool server started meanwhile, a lead that came), the leads still first. Once nothing is live
    /// (at most `stopWait`, then it says which remain) the host is asked to shut down, and the reply says what it
    /// answered (the host ends this server a moment after it accepts).
    private func stop(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        stopping = true
        engine?.stopStarting()
        let live = link.sessions.filter(\.isLive)
        let leadCount = live.filter(Self.isLead).count
        note("stop: ending \(leadCount) leads and \(live.count - leadCount) other sessions")
        let waiting = Waiting()
        func look() {
            guard !waiting.answered else { return }
            let now = link.sessions.filter(\.isLive)
            guard !now.isEmpty else {
                waiting.answered = true
                waiting.watch = nil
                return shutDown(request, ended: waiting.ended.count, reply: reply)
            }
            let leads = now.filter(Self.isLead)
            for session in leads.isEmpty ? now : leads where !waiting.ended.contains(session.id) {
                waiting.ended.insert(session.id)
                link.kill(session.id)
            }
        }
        waiting.watch = link.changes.subscribe(on: queue) { _ in look() }
        queue.asyncAfter(deadline: .now() + Self.stopWait) { [weak self] in
            guard let self, !waiting.answered else { return }
            waiting.answered = true
            waiting.watch = nil
            let remaining = self.link.sessions.filter(\.isLive).map { "\($0.tty) (\(ConfigSeal.inert($0.label, limit: 80)))" }
            self.stopping = false
            self.engine?.startAgain()
            reply(.init(re: request.id, error: .init(.refused, "sessions still live after \(Int(Self.stopWait)) s: \(remaining.joined(separator: ", "))")))
        }
        look()
    }

    private static func isLead(_ session: HostSession) -> Bool { LeadTeams.role(label: session.label) == .lead }

    // MARK: lead

    /// `lead FOLDER [--goal TEXT] [--take-head] [--replace]` (E4): the engine's start, its outcome as the result:
    /// the project's id, the lead's session, what happened (`started`, `shown`, `waiting`), the program's absolute path
    /// (EN-D13), and notes; a refusal is `refused` with the engine's reason.
    private func lead(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let folder = request.args?["folder"]?.string, folder.hasPrefix("/") else {
            return reply(.init(re: request.id, error: .init(.badArgs, "lead needs folder, an absolute path")))
        }
        let goal = request.args?["goal"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server starts no leads"))) }
        engine.startLead(folder: folder, goal: goal, takeHead: request.args?["takeHead"]?.bool == true,
                         replace: request.args?["replace"]?.bool == true) { outcome in
            reply(Self.reply(request.id, folder: folder, outcome))
        }
    }

    /// A start's outcome as `lead`'s reply.
    static func reply(_ id: String, folder: String, _ outcome: LeadEngine.StartOutcome) -> NodeWire.Reply {
        func result(_ happened: String, session: UUID?, program: String?, notes: [String]) -> NodeWire.Reply {
            .init(re: id, result: .object([
                "happened": .string(happened),
                "session": session.map { .string(NodeIds.session(host: $0)) } ?? .null,
                "program": program.map(NodeWire.Value.string) ?? .null,
                "notes": .array(notes.map(NodeWire.Value.string)),
            ]))
        }
        switch outcome {
        case .started(let session, let program, let notes): return result("started", session: session, program: program, notes: notes)
        case .shown(let session, let notes): return result("shown", session: session, program: nil, notes: notes)
        case .waiting: return result("waiting", session: nil, program: nil, notes: ["the start goes on once the server's link to its host is welcomed"])
        case .refused(let why): return .init(re: id, error: .init(.refused, why))
        }
    }

    /// One wait of `stop`'s, on `queue`: whether it was answered, its watch of the link's changes, and the sessions
    /// it asked to end.
    private final class Waiting: @unchecked Sendable {
        var answered = false
        var watch: Subscription?
        var ended: Set<UUID> = []
    }

    /// Nothing is live: the host is asked to shut down, and the reply says what it answered. Accepted, the host ends
    /// this server 0.1 s later, so the reply goes at once (should it not get out in time, the command line finds the
    /// node gone and says so). Refused (a session started meanwhile) or unanswered, `stop` is refused with the host's
    /// reason and requests are taken again.
    private func shutDown(_ request: NodeWire.Request, ended: Int, reply: @escaping (NodeWire.Reply) -> Void) {
        note("stop: \(ended) sessions ended; asking the host to shut down")
        let ask = shutdown
        DispatchQueue.global().async { [weak self] in
            let answer = ask()
            guard let self else { return }
            self.queue.async {
                guard case .ok? = answer else {
                    self.stopping = false
                    self.engine?.startAgain()
                    let why: String = { if case .error(let message)? = answer { return message } else { return "it didn't answer" } }()
                    self.note("stop: the host refused to shut down: \(why)")
                    return reply(.init(re: request.id, error: .init(.refused, "\(ended) sessions ended, but the host refused to shut down: \(ConfigSeal.inert(why, limit: .max))")))
                }
                reply(.init(re: request.id, result: .object(["sessionsEnded": .int(ended), "host": .string("shutting down")])))
                self.note("stop: the host accepted; it ends this server")
            }
        }
    }
}
