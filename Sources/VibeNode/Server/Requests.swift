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
    private let note: (String) -> Void
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

    /// Answers `request` from the process `facts` reads (whose kind this server takes: `NodeServer` answers the
    /// rest), through `reply`, once. On `queue`.
    public func handle(_ request: NodeWire.Request, from facts: PeerFacts, reply: @escaping (NodeWire.Reply) -> Void) {
        let needs = NodeWire.kinds[request.kind] ?? .user
        if needs == .user {
            if case .notUser(let why) = Voice.judge(facts, live: live, rule: rule) {
                note("refused \(request.kind) from pid \(facts.pid): not the user's voice: \(why)")
                return reply(.init(re: request.id, error: .init(.voice, "not the user's voice: \(why)")))
            }
            guard request.action.map({ UUID(uuidString: $0) != nil }) == true else {
                return reply(.init(re: request.id, error: .init(.badArgs, "\(request.kind) needs an action id (a UUID)")))
            }
            guard !stopping else { return reply(.init(re: request.id, error: .init(.stopping, "the node is stopping"))) }
            // Before the host's welcome (and while the link reconnects) its session list isn't known: a state change
            // judged on it could be wrong (a `stop` would find nothing live). The command line asks again.
            guard link.state == .connected else {
                return reply(.init(re: request.id, error: .init(.notYet, "the server's link to its host isn't welcomed yet: retry")))
            }
            record(request, from: facts)
        }
        switch request.kind {
        case "status": status(request, reply: reply)
        case "start": start(request, reply: reply)
        case "stop": stop(request, reply: reply)
        case "lead": lead(request, reply: reply)
        default: reply(.init(re: request.id, error: .init(.unknownKind, "this server doesn't take \(request.kind)")))
        }
    }

    /// A user's-voice request, kept for `status` before it is acted on.
    private func record(_ request: NodeWire.Request, from facts: PeerFacts) {
        let subject = request.args?["card"]?.string ?? request.args?["project"]?.string ?? request.args?["folder"]?.string
        accepted.append(Accepted(kind: request.kind, action: request.action, subject: subject, at: Date(), pid: facts.pid,
                                 cgroup: facts.cgroup.flatMap { PeerFacts.unifiedPath($0) ?? PeerFacts.systemdPath($0) },
                                 commandLine: facts.commandLine))
        if accepted.count > Self.acceptedKept { accepted.removeFirst(accepted.count - Self.acceptedKept) }
        note("accepted \(request.kind) (action \(request.action ?? "none")) from pid \(facts.pid)")
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
            "leads": .array((engine?.leads.leads.values.sorted { $0.root < $1.root } ?? []).map(\.value)),
            "cards": .object(["questions": .int(0), "approvals": .int(0), "config": .int(0), "base": .int(0)]),
            "accepted": .array(accepted.map(\.value)),
            "notices": .array((stopping ? ["the node is stopping"] : []).map(NodeWire.Value.string)
                + (engine?.leads.leads.values.sorted { $0.root < $1.root }.compactMap(\.notice) ?? []).map(NodeWire.Value.string)),
        ])
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
