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
            guard !stopping else { return reply(.init(re: request.id, error: .init(.refused, "the node is stopping"))) }
            record(request, from: facts)
        }
        switch request.kind {
        case "status": status(request, reply: reply)
        case "start": start(request, reply: reply)
        case "stop": stop(request, reply: reply)
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
    /// (none before E4 and E6), the accepted requests and the notices. On `queue`.
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
            "leads": .array([]),
            "cards": .object(["questions": .int(0), "approvals": .int(0), "config": .int(0), "base": .int(0)]),
            "accepted": .array(accepted.map(\.value)),
            "notices": .array(stopping ? [.string("the node is stopping")] : []),
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

    /// EN-D6: no other state-changing request from now on; the leads ended first, then every other session; once
    /// nothing is live (at most `stopWait`, then it says which remain), the host is asked to shut down, and the reply
    /// goes as soon as it accepted (the host ends this server a moment after).
    private func stop(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        stopping = true
        let live = link.sessions.filter(\.isLive)
        let leads = live.filter { LeadTeams.role(label: $0.label) == .lead }
        for session in leads + live.filter({ LeadTeams.role(label: $0.label) != .lead }) { link.kill(session.id) }
        note("stop: ending \(leads.count) leads and \(live.count - leads.count) other sessions")
        let ended = live.count
        let waiting = Waiting()
        func look() {
            guard !waiting.answered, link.sessions.filter(\.isLive).isEmpty else { return }
            waiting.answered = true
            waiting.watch = nil
            shutDown(request, ended: ended, reply: reply)
        }
        waiting.watch = link.changes.subscribe(on: queue) { _ in look() }
        queue.asyncAfter(deadline: .now() + Self.stopWait) { [weak self] in
            guard let self, !waiting.answered else { return }
            waiting.answered = true
            waiting.watch = nil
            let remaining = self.link.sessions.filter(\.isLive).map { "\($0.tty) (\(ConfigSeal.inert($0.label, limit: 80)))" }
            self.stopping = false
            reply(.init(re: request.id, error: .init(.refused, "sessions still live after \(Int(Self.stopWait)) s: \(remaining.joined(separator: ", "))")))
        }
        look()
    }

    /// One wait of `stop`'s, on `queue`: whether it was answered, and its watch of the link's changes.
    private final class Waiting: @unchecked Sendable {
        var answered = false
        var watch: Subscription?
    }

    /// Nothing is live: the reply goes first (the host ends this server a moment after it accepts), then the host is
    /// asked to shut down; should it refuse (a session started meanwhile), the log says so and requests are taken again.
    private func shutDown(_ request: NodeWire.Request, ended: Int, reply: @escaping (NodeWire.Reply) -> Void) {
        note("stop: \(ended) sessions ended; asking the host to shut down")
        reply(.init(re: request.id, result: .object(["sessionsEnded": .int(ended), "host": .string("asked to shut down")])))
        let ask = shutdown
        DispatchQueue.global().async { [weak self] in
            let answer = ask()
            guard let self else { return }
            self.queue.async {
                guard case .ok? = answer else {
                    self.stopping = false
                    let why: String = { if case .error(let message)? = answer { return message } else { return "it didn't answer" } }()
                    return self.note("stop: the host refused to shut down: \(why)")
                }
                self.note("stop: the host accepted; it ends this server")
            }
        }
    }
}
