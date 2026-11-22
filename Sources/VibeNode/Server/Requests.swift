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
        /// The card, project, folder or session it named, when it named one; else a setting's key.
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
    /// The messages web pages left for sessions (`session.draft`), by the node's id for each: told to nobody until
    /// `vibeswitcher send SESSION` types one. On `queue`.
    public let sessionDrafts = Changes<SessionDraft>()
    /// The messages `send` holds for sessions while a question is open on their screens (`HeldSend`), by the node's id
    /// for each, oldest first. On `queue`.
    public let heldSends = Changes<[HeldSend]>()
    /// The sessions whose held messages are being typed in now (`pumpHeld`). On `queue`.
    var pumping: Set<UUID> = []
    /// The held messages' vault calls and file writes, one after another (`HeldSendStore.swift`), and whether the file's
    /// were restored yet (at the first welcome). On `queue`.
    let heldWrites = DispatchQueue(label: "vibeswitcher-server.held-sends")
    var heldRestored = false
    /// How a held message's action is spent in the vault (`spendHeld`): the vault's call; a test's that fails.
    lazy var spendUserActions: @Sendable ([String]) throws -> Void = { [client = link.vaultV2] actions in try client.spendUserActions(actions) }
    /// What sessions' composers complete (`session.complete`), kept a while.
    let completionIndex = SessionCompletions()
    /// Images web pages are sending in parts (`session.attach`). On `queue`.
    let attachments = SessionAttachments()
    /// The reply each recorded action (and each page's draft) got, by action id, the newest `repliesKept` (a retry is
    /// answered so).
    var replies: [String: NodeWire.Reply] = [:]
    private var replyOrder: [String] = []
    /// The recorded actions being done now (recorded, their reply not yet given). On `queue`.
    private var doing: Set<String> = []
    /// A scratch server's test (`--test-stall=`): true once for each `<root>/test-hold-act` made, and that recorded
    /// action is held for good after its record, before its act, as a server that ends in between leaves it.
    var testHoldsAct: (() -> Bool)?
    /// Each request as it is acted on, after the voice, the code and the vault's record (for tests). On `queue`.
    public var acting: (NodeWire.Request) -> Void = { _ in }
    /// The build's folder (`ServerArguments.nodeRoot`): where `hooks.install` reads the programs it installs; none:
    /// `hooks.install` is refused.
    public var nodeRoot: String?
    /// The home `hooks.install` and `hooks.remove` write in: the server's own (`getpwuid`'s on the node, the scratch home
    /// on a scratch node).
    public var home = VibePaths.home
    /// `stats`' collector (`Stats/StatisticsWire.swift`): the node's root, the home's Codex folder; made at the first ask
    /// and kept, so a file unchanged is parsed once.
    lazy var statsCollector = SetupStatsCollector(home: root, codexHome: URL(fileURLWithPath: home).appendingPathComponent(".codex"))
    /// Where `build.switch` finds the builds it switches between, and `status` the install record (the start plan's
    /// S8b): the account's `NodeFolders.defaultPrefix` on the node, `--test-install-root` on a scratch node; none:
    /// `build.switch` is refused and `status` gives no `builds`.
    public var installRoot: String?
    /// The Mac's voice (`VoiceRule.Mode.approval`): the caller checks and Touch ID per state change. Nil elsewhere.
    public var approval: ApprovalVoice?
    /// The Touch ID approvals waiting or asked: one at a time, on a queue of their own (`approvalVoice`). On `queue`.
    var approvalsPending = 0
    /// Whether the link to the host is welcomed, as the Mac's rule asks before a dialog (nil: `link.state`'s; a test's own).
    var approvalLinkWelcomed: (() -> Bool)?
    /// No dialog before this, after one that came to nothing (`approvalCooldown`), and the clock it's judged by.
    var approvalQuietUntil: Date?
    var approvalNow: () -> Date = Date.init
    let approvals = DispatchQueue(label: "vibenode.requests.approvals", qos: .userInitiated)
    /// The health digest (`NodeHealth`): the server's own watchdog, slow refreshes and last errors.
    public var health: NodeHealth?
    /// Check for Updates (`UpdateWatch`): the user's node's only. Its notice is `status`'s, its last answer `update`.
    public var updates: UpdateWatch?
    /// The batches `approve.list` kept for `approve` (`ApproveRequest.swift`). On `queue`.
    var approveBatches: [ApproveBatch] = []
    /// The waits a `build.switch` runs on (a test's shorter ones).
    public var switchTiming = SwitchRequest.Timing()
    /// The web's gate and tokens (the live plan's I1, `NodeLive`): what `web.open` and `web.revoke` act on; none:
    /// both are refused.
    public var web: WebAccess?
    /// The page on the user's tailnet (`NodeLive`'s, the user's node only): what `web.open` with `tailnet` acts on, and
    /// `web.revoke` too; none: `web.open` with `tailnet` is refused.
    public var tailnet: TailnetWeb?
    /// `status`'s `web`: the listener's state (`NodeLive.webValue`); none: off.
    public var webValue: (() -> NodeWire.Value)?
    /// The `seq` a live stream is at, by collection (`LiveHub.seq(of:)`, set by `NodeLive`): a draft's `applied`. On
    /// `queue`.
    public var liveSeq: ((String) -> Int)?
    /// Each lead's board value by project (`LiveBoards`, set by `NodeLive`): `board`'s answer. On `queue`.
    public var boards: (() -> [String: NodeWire.Value])?
    /// A scratch server's `--test-web-pair`: `web.open` is taken from any process of the uid, its voice and typed code
    /// not asked (the sandbox's and the tests' scratch form). Never on the user's node (`ServerArguments` refuses it).
    public var openWebForAnyone = false
    /// The repository a request's folder is in (`repository(_:)`, git: never on `queue`); a test's instead.
    var repositoryOf: @Sendable (String) -> String = { Requests.repository($0) }

    public init(link: HostLink, sessions: NodeSessions?, rule: VoiceRule, root: URL, hostSocket: String, commit: String,
                hostPID: pid_t = getppid(), note: @escaping (String) -> Void = { _ in }) {
        queue = link.queue
        queue.setSpecific(key: Self.onQueue, value: true)
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

    /// A refusal of a request from `pid`, in the log: at most `refusalsPerWindow` lines a sender in each
    /// `refusalWindow`, the rest counted and said in one line when the next window opens (a peer pipelining refused
    /// requests would otherwise write a line for each: the review of the runtime hardening). On `queue`.
    func refusalNote(_ pid: pid_t, _ line: String) {
        let now = MacTime.real.awake()
        var entry = refusals[pid] ?? (since: now, said: 0, held: 0)
        if now - entry.since >= Self.refusalWindow {
            if entry.held > 0 { note("\(entry.held) more refusals from pid \(pid) weren't logged") }
            entry = (now, 0, 0)
        }
        if entry.said < Self.refusalsPerWindow {
            entry.said += 1
            note(line + (entry.said == Self.refusalsPerWindow ? " (more from pid \(pid) in the next \(Int(Self.refusalWindow)) s are counted, not logged)" : ""))
        } else {
            entry.held += 1
        }
        refusals[pid] = entry
        if refusals.count > 256 { refusals = refusals.filter { now - $0.value.since < Self.refusalWindow } }
    }

    /// How many stuck ends in a row of the server (`HostNotes.serverStuckInARow`) `status` says.
    static let stuckNoticeAfter = 3

    static let refusalsPerWindow = 5
    static let refusalWindow: TimeInterval = 10
    private var refusals: [pid_t: (since: TimeInterval, said: Int, held: Int)] = [:]

    /// Whether the process `facts` reads may be the user's voice, as a connection's accept judges it (the slots only it
    /// takes, `NodeServer.reservedForUser`): the voice rule's verdict; under the Mac's rule (asked per request) a process
    /// that isn't a session's. Never a judgment of a request: each is judged again as it comes. On `queue`.
    ///
    /// Under the Mac's rule only what a session's process can't change counts (its environment's marker is its own to
    /// set): its user, an ancestry read whole with no live session's program, the host or the server in it, no branch
    /// code runner above it, and a terminal that isn't a live session's (`Voice.judge`'s own checks of these).
    func mayBeUsersVoice(_ facts: PeerFacts) -> Bool {
        guard rule.mode == .approval else {
            if case .user = Voice.judge(facts, live: live, rule: rule) { return true }
            return false
        }
        let live = self.live
        guard facts.uid == rule.uid, let ancestry = facts.ancestry, facts.underRunner == false else { return false }
        guard !ancestry.contains(where: { $0.pid == live.host || $0.pid == live.server || live.programs.contains($0.pid) }) else { return false }
        switch facts.terminal {
        case .unreadable: return false
        case .named(let name): return !live.terminals.contains(name)
        case .none: return true
        }
    }

    /// The share a connection from `facts` counts toward (`NodeServer`'s caps), by what the process can't
    /// change: the live session its ancestry runs under; else, under the systemd rule, its cgroup (a scope: a
    /// terminal's, an app's, the host's service); else its pid alone. A process that forks for more connections stays
    /// in its session's or cgroup's share. On `queue`.
    func share(_ facts: PeerFacts) -> String {
        let live = self.live
        if let program = facts.ancestry?.first(where: { live.programs.contains($0.pid) }) { return "session \(program.pid)" }
        if rule.mode == .systemd, let lines = facts.cgroup, let last = lines.last, !last.isEmpty { return "cgroup \(last)" }
        return "pid \(facts.pid)"
    }

    /// The hello a new connection from `peer` gets. On `queue`.
    public func hello(peer: PeerFacts?, token: Platform.PeerToken? = nil) -> NodeWire.Hello {
        // Under the Mac's rule a read's voice (no dialog: `status` changes nothing) says whether the peer passes the
        // caller checks.
        let voice = peer.map { facts in
            rule.mode == .approval
                ? (approval?.judge(kind: "status", card: nil, peer: token, facts: facts, live: live, uid: rule.uid) ?? .notUser(Self.approvalUnset))
                : Voice.judge(facts, live: live, rule: rule)
        } ?? .notUser("its process can't be read")
        let why: String? = { if case .notUser(let why) = voice { return why } else { return nil } }()
        return NodeWire.Hello(node: NodeIds.node, epoch: epoch,
                              server: .init(commit: commit, startedAt: NodeWire.dateText(startedAt), pid: serverPID),
                              host: .init(startedAt: link.hostStartedAt.map(NodeWire.dateText), notes: notes.map { Self.value($0.notes, at: $0.at) },
                                          pid: link.hostPID),
                              kinds: NodeWire.taken, peer: .init(voice: voice == .user ? "user" : "other", why: why),
                              rule: rule.mode.rawValue, plugins: engine?.plugins.onValue)
    }

    /// The hello a web connection gets once its `auth` was admitted (the live wire contract's §2): the Unix socket's,
    /// with the kinds its rights may send, a peer that is never the user's, `auth`, and the build of the files served.
    /// On `queue`.
    public func webHello(_ admission: WebAdmission, assets: String) -> NodeWire.Hello {
        var hello = hello(peer: nil)
        hello.kinds = WebAccess.kinds(for: admission.rights)
        hello.peer = .init(voice: "other", why: WebAccess.peerWhy)
        hello.auth = admission.auth
        hello.assets = assets
        return hello
    }

    /// Asks the host's notes (`HostLink.notes`) and keeps them; `done` once they came, or didn't. Each housekeeping
    /// asks, and `status` asks too. On `queue`.
    public func refreshNotes(_ done: @escaping () -> Void = {}) {
        link.notes { [weak self] notes in
            guard let self else { return done() }
            self.queue.async {
                if let notes { self.notes = (notes, Date()) }
                self.refreshBuilds(done)
            }
        }
    }

    /// `status`'s `builds` as last read (`refreshBuilds`), for the build that ran then: the install root's folders and its
    /// `installs` file are read off `queue` (the architecture review's row 19), never by `statusValue`, which every
    /// change of the node's stream calls. On `queue`.
    private var builds: NodeWire.Value?
    private let buildsReads = DispatchQueue(label: "vibenode.status-builds", qos: .utility)

    /// The install root read again on a queue of its own, `builds` set on `queue`, then `done` there. At each
    /// `refreshNotes` (each `status`, and each housekeeping). Nothing without an install root.
    func refreshBuilds(_ done: @escaping () -> Void = {}) {
        guard let installRoot else { return done() }
        let running = notes?.notes.build
        buildsReads.async { [weak self] in
            let value = SwitchRequest.buildsValue(installRoot: installRoot, running: running)
            guard let self else { return }
            self.queue.async {
                self.builds = value
                done()
            }
        }
    }

    /// The kinds recorded in the vault before they are acted on (EN-D11): every state-changing user's-voice request.
    public static let recorded: Set<String> = ["start", "stop", "lead", "answer", "hold", "config.accept", "base.accept", "base.keep",
                                               "hooks.install", "hooks.remove", "build.switch", "web.open", "web.revoke", "tell",
                                               "send", "session.new", "session.end", "session.reply",
                                               "set", "push", "push.decline", "session.reopen", "prompt-audit",
                                               "session.rename", "session.pause", "session.resume", "session.close-shells", "presets.edit",
                                               "approve", "plugin.on", "plugin.off"]
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
    /// Set on `queue`: whether an answer is given on it (`handle`).
    static let onQueue = DispatchSpecificKey<Bool>()
    private let offQueueLock = NSLock()
    nonisolated(unsafe) private var offQueue: Set<String> = []

    /// The kinds of the requests answered off `queue` so far (each noted once). Empty: every answer came on it.
    public var offQueueReplies: Set<String> { offQueueLock.withLock { offQueue } }

    private func noteOffQueue(_ kind: String) {
        let first = offQueueLock.withLock { offQueue.insert(kind).inserted }
        if first { note("internal: \(kind) answered off the requests' queue") }
    }

    public func handle(_ request: NodeWire.Request, from facts: PeerFacts, token: Platform.PeerToken? = nil,
                       reply given: @escaping (NodeWire.Reply) -> Void) {
        // Each answer comes on `queue` (the server writes it from there); one given elsewhere is noted by its kind
        // (`offQueueReplies`), which the tests' worlds expect empty (`settings` answered from its reading queue until
        // 2026-11-22, and the server crashed on the race).
        let reply = { [weak self] (answer: NodeWire.Reply) in
            if DispatchQueue.getSpecific(key: Self.onQueue) != true { self?.noteOffQueue(request.kind) }
            given(answer)
        }
        let needs = NodeWire.kinds[request.kind] ?? .user
        if needs == .leadToolServer { return questionPost(request, from: facts, reply: reply) }
        // A draft comes from a web page (`NodeLive` hands those to `draft` itself): from here it is no one's to leave.
        if needs == .webDraft {
            refusalNote(facts.pid, "refused \(request.kind) from pid \(facts.pid): a draft comes from a web page")
            return reply(.init(re: request.id, error: .init(.voice, "a draft comes from a web page; in a terminal, `vibeswitcher answer CARD TEXT` answers and `vibeswitcher send SESSION TEXT` sends")))
        }
        if request.kind == "web.open", openWebForAnyone, request.args?["tailnet"] == nil {
            note("web.open from pid \(facts.pid), in a scratch server's form (--test-web-pair): no voice asked")
            return act(request, from: facts, reply: reply)
        }
        // A private record's read (`webRead`) on the socket is the user's alone, as a user's-voice read (no typed word);
        // a page's comes through `webRead(_:reply:)`.
        if needs == .user || needs == .webRead {
            // The Mac's rule: the caller checks, then Touch ID for a state change, off `queue` (`approvalVoice`).
            if rule.mode == .approval { return approvalVoice(request, from: facts, token: token, reply: reply) }
            if case .notUser(let why) = Voice.judge(facts, live: live, rule: rule) {
                refusalNote(facts.pid, "refused \(request.kind) from pid \(facts.pid): not the user's voice: \(why)")
                return reply(.init(re: request.id, error: .init(.voice, "not the user's voice: \(why)")))
            }
            if let why = Voice.handsRefusal(facts, kind: request.kind, rule: rule) {
                refusalNote(facts.pid, "refused \(request.kind) from pid \(facts.pid): \(why)")
                return reply(.init(re: request.id, error: .init(.voice, why)))
            }
            return voiced(request, from: facts, reply: reply)
        }
        act(request, from: facts, reply: reply)
    }

    /// A user's-voice request whose voice passed: its action id, the card's code, the vault's record, then the act. On
    /// `queue`.
    func voiced(_ request: NodeWire.Request, from facts: PeerFacts, reply given: @escaping (NodeWire.Reply) -> Void) {
        // Checked here too: `approve` calls this for each of its batch's items, which `handle` doesn't see.
        let reply = { [weak self] (answer: NodeWire.Reply) in
            if DispatchQueue.getSpecific(key: Self.onQueue) != true { self?.noteOffQueue(request.kind) }
            given(answer)
        }
        let records = Self.recorded.contains(request.kind)
        guard !records || request.action.map({ UUID(uuidString: $0) != nil }) == true else {
            return reply(.init(re: request.id, error: .init(.badArgs, "\(request.kind) needs an action id (a UUID)")))
        }
        if let refusal = RequestArguments.refusal(request) ?? RequestArguments.formRefusal(request) { return reply(refusal) }
        guard !stopping else { return reply(.init(re: request.id, error: .init(.stopping, "the node is stopping"))) }
        // Before the host's welcome (and while the link reconnects) its session list isn't known: a state change
        // judged on it could be wrong (a `stop` would find nothing live). The command line asks again.
        guard link.state == .connected else {
            return reply(.init(re: request.id, error: .init(.notYet, "the server's link to its host isn't welcomed yet: retry")))
        }
        if Self.carded.contains(request.kind), let refusal = cardRefusal(request) { return reply(refusal) }
        // A retry of an approve already done (its action's reply kept) is answered as before, below; any other is checked first.
        if request.kind == "approve", request.action.map({ replies[$0.lowercased()] == nil }) ?? true, let refusal = approveRefusal(request) {
            return reply(refusal)
        }
        if records, let action = request.action?.lowercased() {
            return record(request, action: action, from: facts) { [weak self] recorded in
                guard let self else { return }
                switch recorded {
                case .failure(let why):
                    self.note("refused \(request.kind) (action \(action)): not recorded in the vault: \(why)")
                    reply(.init(re: request.id, error: .init(.internal, "not recorded in the host's vault, so not done: \(ConfigSeal.inert(why.description, limit: .max))")))
                case .success(false):
                    self.retry(request, action: action, from: facts, reply: reply)
                case .success(true):
                    if self.testHoldsAct?() == true {
                        return self.note("a scratch node's test: \(request.kind) (action \(action)) recorded, and held for good before its act")
                    }
                    self.perform(request, action: action, from: facts, reply: reply)
                }
            }
        }
        act(request, from: facts, reply: reply)
    }

    /// What `request` does, once it passed.
    private func act(_ request: NodeWire.Request, from facts: PeerFacts, reply: @escaping (NodeWire.Reply) -> Void) {
        acting(request)
        switch request.kind {
        case "status": status(request, reply: reply)
        case "start": start(request, reply: reply)
        case "stop": stop(request, reply: reply)
        case "lead": lead(request, reply: reply)
        case "questions": questions(request, reply: reply)
        case "board": board(request, reply: reply)
        case "settings": settings(request, reply: reply)
        case "recent": recent(request, reply: reply)
        case "brief": brief(request, reply: reply)
        case "update.check": updateCheck(request, reply: reply)
        case "approve.list": approveList(request, reply: reply)
        case "approve": approve(request, from: facts, reply: reply)
        case "plugin.list": pluginList(request, page: facts.pid == NodeLive.webPeer.pid, reply: reply)
        case "plugin.on", "plugin.off": pluginSet(request, reply: reply)
        case "session.ports": sessionPorts(request, reply: reply)
        case "set": set(request, reply: reply)
        case "answer": answer(request, reply: reply)
        case "hold": hold(request, reply: reply)
        case "tell": tell(request, reply: reply)
        case "push", "push.decline": push(request, reply: reply)
        case "send": send(request, reply: reply)
        case "session.new": newSession(request, reply: reply)
        case "session.end": endSession(request, reply: reply)
        case "session.reply": replySession(request, reply: reply)
        case "session.presets": presets(request, terminal: facts.pid != NodeLive.webPeer.pid && facts.uid != nil, reply: reply)
        case "session.complete": complete(request, reply: reply)
        case "stats": stats(request, reply: reply)
        case "board.task": boardTask(request, reply: reply)
        case "board.image": boardImage(request, reply: reply)
        case "session.reopen": reopenSessions(request, reply: reply)
        case "mail": mail(request, reply: reply)
        case "prompt-audit": promptAudit(request, reply: reply)
        case "session.rename": renameSession(request, reply: reply)
        case "session.pause": pauseSession(request, reply: reply)
        case "session.resume": resumeSession(request, reply: reply)
        case "shells": shells(request, reply: reply)
        case "session.close-shells": closeShells(request, reply: reply)
        case "presets.edit": editPreset(request, reply: reply)
        case "seen": seen(request, reply: reply)
        case "config.held": configHeld(request, reply: reply)
        case "config.accept": configAccept(request, reply: reply)
        case "base.show": baseShow(request, reply: reply)
        case "base.accept", "base.keep": baseAnswer(request, reply: reply)
        case "hooks.install", "hooks.remove": hooks(request, reply: reply)
        case "build.switch": buildSwitch(request, reply: reply)
        case "web.open", "web.revoke":
            if request.kind == "web.open", request.args?["tailnet"]?.bool == true { return webOpenTailnet(request, reply: reply) }
            guard let web else { return reply(.init(re: request.id, error: .init(.refused, "this server has no web listener"))) }
            if request.kind == "web.open" { webOpen(request, web: web, reply: reply) } else { webRevoke(request, web: web, reply: reply) }
        default: reply(.init(re: request.id, error: .init(.unknownKind, "this server doesn't take \(request.kind)")))
        }
    }

    /// The act of a recorded action (its record made first), then its outcome written on that record, through the host
    /// as the record was (`finishUserAction`), before the answer goes: an answer someone saw is in the record. A host
    /// that doesn't take the outcome (one before it) leaves the record begun, noted. On `queue`.
    private func perform(_ request: NodeWire.Request, action: String, from facts: PeerFacts, reply: @escaping (NodeWire.Reply) -> Void) {
        doing.insert(action)
        act(request, from: facts) { [weak self] answer in
            guard let self else { return reply(answer) }
            self.queue.async {
                self.keep(answer, for: action)
                let (client, kind, outcome) = (self.link.vaultV2, request.kind, Self.outcome(of: answer))
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let written = Result { try client.finishUserAction(action, kind: kind, outcome: outcome) }
                    self?.queue.async {
                        if case .failure(let why) = written { self?.note("\(kind) (action \(action)): its outcome isn't in the vault's record: \(why)") }
                        self?.doing.remove(action)
                        reply(answer)
                    }
                }
            }
        }
    }

    /// What the record keeps of `answer`: done with its result (when it fits), or failed with why.
    static func outcome(of answer: NodeWire.Reply) -> LeadVaultV2.UserAction.Outcome {
        guard answer.ok else { return .init(done: false, note: answer.error?.message ?? "no reason given", code: answer.error?.code) }
        return .init(done: true, note: answer.result.map { String(decoding: NodeWire.line($0).dropLast(), as: UTF8.self) })
    }

    /// The kinds that a second act leaves as one does (each sets a state, or ends or holds what it names), so a retry of
    /// one whose server ended before its outcome was written does it again: its record's digest the same, and begun
    /// `rerunWithin` ago at most. Every other recorded kind isn't (it types or sends text, starts a session or a lead,
    /// answers or runs what a card asks, pushes, switches the build, opens a link): a retry of one is told it began and
    /// its outcome isn't known (`unknownCheck`).
    public static let rerunnable: Set<String> = ["start", "stop", "hold", "config.accept", "base.accept", "base.keep",
                                                 "hooks.install", "hooks.remove", "web.revoke", "session.end", "set",
                                                 "prompt-audit", "push.decline", "session.rename", "session.pause",
                                                 "session.resume", "session.close-shells", "plugin.on", "plugin.off"]
    /// How old a begun record may be for its retry to do it again: later, something else may have set it since.
    static let rerunWithin: TimeInterval = 15 * 60

    /// A retry of `action`, recorded already. Answered from what this server kept when it can (its reply; or that it is
    /// being done now); else from the vault's record (the architecture review's row 10): done, its recorded result;
    /// failed, why, and whether a new attempt can do it; begun with no outcome (the server ended in between), done again
    /// when its kind is `rerunnable`, else that it began and its outcome isn't known, with what to look at. A record the
    /// host can't give (one before outcomes) is told the outcome isn't known. Never "done" unless it was. On `queue`.
    func retry(_ request: NodeWire.Request, action: String, from facts: PeerFacts, reply: @escaping (NodeWire.Reply) -> Void) {
        if let known = kept(request, action: action) { return reply(known) }
        let (client, kind) = (link.vaultV2, request.kind)
        let digest = LeadVaultV2.digest(String(decoding: NodeWire.line(request.args ?? [:]), as: UTF8.self))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let record = Result { try client.userAction(action, kind: kind) }
            guard let self else { return }
            self.queue.async {
                // Asked again meanwhile, and done, or under way, since.
                if let known = self.kept(request, action: action) { return reply(known) }
                switch record {
                case .failure(let why):
                    self.note("\(kind) (action \(action)) was recorded already; its record can't be read (\(why)): its outcome isn't known")
                    reply(.init(re: request.id, error: .init(.refused, Self.outcomeUnknown(action: action))))
                case .success(nil):
                    reply(.init(re: request.id, error: .init(.refused, Self.outcomeUnknown(action: action))))
                case .success(let recorded?):
                    let began = Date(timeIntervalSince1970: recorded.at)
                    if let outcome = recorded.outcome {
                        self.note("\(kind) (action \(action)) was recorded already: answered from its record (\(outcome.done ? "done" : "failed")), not done again")
                        return reply(Self.answer(request, action: action, outcome: outcome))
                    }
                    if Self.rerunnable.contains(kind), recorded.digest == digest, Date().timeIntervalSince(began) <= Self.rerunWithin {
                        self.note("\(kind) (action \(action)) began at \(Self.shown(began)) with no outcome recorded: done again, as a second act leaves it as one does")
                        return self.perform(request, action: action, from: facts, reply: reply)
                    }
                    self.note("\(kind) (action \(action)) began at \(Self.shown(began)) with no outcome recorded: not done again")
                    reply(.init(re: request.id, error: .init(.refused, Self.begunUnknown(action: action, kind: kind, at: began))))
                }
            }
        }
    }

    /// The answer a retry gets from this server's memory: the reply it kept, or that its first request is being done.
    private func kept(_ request: NodeWire.Request, action: String) -> NodeWire.Reply? {
        if var kept = replies[action] {
            kept.re = request.id
            return kept
        }
        if doing.contains(action) {
            return .init(re: request.id, error: .init(.refused, "action \(action) is being done now, from its first request: not done again; that request's answer says how it went"))
        }
        return nil
    }

    /// A retry's answer from a recorded outcome: done, the result recorded (or that it was done, when its answer was too
    /// long to keep); failed, why, under the code it failed with, and whether running the command again can do it.
    static func answer(_ request: NodeWire.Request, action: String, outcome: LeadVaultV2.UserAction.Outcome) -> NodeWire.Reply {
        let when = shown(Date(timeIntervalSince1970: outcome.at))
        if outcome.done {
            if let note = outcome.note, let result = try? JSONDecoder().decode(NodeWire.Value.self, from: Data(note.utf8)) {
                return .init(re: request.id, result: result)
            }
            return .init(re: request.id, error: .init(.refused, "action \(action) was done at \(when) (its answer was too long to keep): not done again; `vibeswitcher status` shows what is now"))
        }
        let code = outcome.code.flatMap(NodeWire.Code.init(rawValue:)) ?? .refused
        let again = code == .gone ? "what it named is gone, so a new attempt can't do it" : "nothing was done, and running the command again is a new attempt"
        return .init(re: request.id, error: .init(code, "action \(action) failed at \(when): \(ConfigSeal.inert(outcome.note ?? "no reason given", limit: .max)). Not done again: \(again)"))
    }

    /// What a retry of a recorded action whose reply isn't kept, and whose record says nothing more, is told.
    static func outcomeUnknown(action: String) -> String {
        "action \(action) was recorded before this server restarted (or too long ago for its answer to be kept): whether it was carried out isn't known, and it isn't done again; `vibeswitcher status` shows what is now"
    }

    /// What a retry of an action that began and has no outcome (its server ended in between) is told, when its kind
    /// isn't done again.
    static func begunUnknown(action: String, kind: String, at began: Date) -> String {
        "action \(action) (\(kind)) began at \(shown(began)) and the server ended before it finished: whether it was carried out isn't known, and it isn't done again, as a second \(kind) wouldn't be the same as one; \(unknownCheck(kind))"
    }

    /// What to look at to see whether an action of `kind` happened.
    static func unknownCheck(_ kind: String) -> String {
        switch kind {
        case "send", "session.reply": return "the session's screen shows whether the text arrived"
        case "tell": return "the lead's chat shows whether the message arrived"
        case "lead", "session.new", "session.reopen": return "`vibeswitcher status` lists the sessions running now"
        case "answer", "approve": return "`vibeswitcher questions` shows whether the card is still open (a shell request's session shows whether its command ran)"
        case "push": return "the repository's remote shows whether the push went"
        case "build.switch": return "`vibeswitcher status` names the build running now"
        case "web.open": return "`vibeswitcher web open` gives a link again"
        case "presets.edit": return "`vibeswitcher presets` shows the presets now"
        default: return "`vibeswitcher status` shows what is now"
        }
    }

    /// `date` as a retry's answer says it: local time, to the second.
    static func shown(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return format.string(from: date)
    }

    func keep(_ reply: NodeWire.Reply, for action: String) {
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
            ?? request.args?["session"]?.string ?? request.args?["key"]?.string ?? request.args?["plugin"]?.string
    }

    // MARK: status

    /// How long `status` waits for the host's notes before it answers with the last ones it has.
    public static let notesWait: TimeInterval = 5

    private func status(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let waiting = Waiting()
        let answer = { [weak self] in
            guard let self, !waiting.answered else { return }
            waiting.answered = true
            reply(.init(re: request.id, typed: self.statusResult()))
        }
        refreshNotes(answer)
        queue.asyncAfter(deadline: .now() + Self.notesWait) { answer() }
    }

    /// `status`'s notices, in order: the node stopping; each lead's (E5); the refresh's (E7); a host restart's and a lead
    /// with no role (E8); a project due a prompt audit, a team session behind a dialog nothing reads, a board that
    /// cleared, and a session left alone (2026-11-20). On `queue`.
    /// `reminders`: the sessions' (`NodeSessions.reminderNotices`), when the caller has them already.
    func statusNotices(reminders: [String]? = nil) -> [String] {
        var notices = stopping ? ["the node is stopping"] : []
        notices += engine?.leads.leads.values.sorted { $0.root < $1.root }.compactMap(\.notice) ?? []
        notices += engine?.notices.sorted { $0.key < $1.key }.flatMap(\.value) ?? []
        notices += (engine?.restartNotices ?? []) + (engine?.rolelessNotices ?? [])
        notices += engine?.promptAuditNotices ?? []
        notices += engine?.unknownDialogNotices ?? []
        notices += engine?.allDoneNotices ?? []
        notices += engine?.toolchainNotices ?? []
        notices += engine?.pluginNotices ?? []
        notices += reminders ?? sessions?.reminderNotices() ?? []
        if let stuck = notes?.notes.serverStuckInARow, stuck >= Self.stuckNoticeAfter {
            notices.append("the server ended stuck \(stuck) times in a row (its engine's queue didn't answer), and the host started it again each time: its log says what it was doing; if it goes on, `vibeswitcher stop`, then `vibeswitcher start`")
        }
        if let notice = updates?.notice { notices.append(notice) }
        return notices
    }

    /// `status`'s result: the node, the server, the host (its live sessions counted: what `stop` ends, its confirmation's
    /// count; the review of the start plan's S3) and its notes, the rule, the sessions, leads and cards
    /// (none before E4 and E6), the accepted requests and the notices (the node stopping; a lead whose board names a
    /// session the vault doesn't bind, E5; a base move that refused a running lead's merge, E7's refresh; a host restart
    /// that ended a project's team, and a running lead the vault gives no role, E8), and the last host restart
    /// (`restart`, E8: the command line shows it with how the host ended). On `queue`.
    public func statusValue() -> NodeWire.Value { NodeWire.Value(wire: statusResult()) }

    /// `status`'s result, typed (`WireKinds.Status`). On `queue`.
    public func statusResult() -> WireKinds.Status.Result {
        typealias Status = WireKinds.Status
        let list = sessions?.sessions ?? []
        // Each once per status (the review's row 19): the switch's blockers walk the host's sessions, the reminders the scan's.
        let switching = switchBlockersNow()
        let due = sessions?.reminders() ?? []
        let reminders = NodeSessions.notices(due)
        var result = Status.Result()
        result.node = NodeIds.node
        result.epoch = epoch
        result.root = root.path
        result.server = Status.Server(pid: Int(serverPID), startedAt: NodeWire.dateText(startedAt), commit: commit)
        result.host = Status.Host(startedAt: link.hostStartedAt.map(NodeWire.dateText), pid: link.hostPID.map { Int($0) }, state: Self.word(link.state),
                                  liveSessions: link.sessions.filter(\.isLive).count, notes: notes.map { Self.notes($0.notes, at: $0.at) })
        result.rule = Status.Rule(mode: rule.mode.rawValue, says: rule.says, scopes: rule.scopes.map(\.pattern))
        result.sessions = list.map { session in
            let id = NodeSessions.id(of: session)
            return session.liveValue(prompt: sessions?.prompts.values[id], draft: sessionDrafts.values[id], queued: heldSends.values[id] ?? [])
        }
        result.leads = (engine?.leads.leads.values.sorted { $0.root < $1.root } ?? []).map(leadValue)
        result.cards = Self.counts(engine?.cards.counts() ?? [:])
        result.plugins = engine?.plugins.onValue ?? .array([])
        result.accepted = accepted.map(\.value)
        result.notices = statusNotices(reminders: reminders)
        // The reminders due now, each its session's (the page notifies once an episode: "Remind me about waiting or
        // stuck sessions", 2026-11-22).
        result.reminders = due.map(\.value)
        result.restart = engine?.restartValue ?? .null
        result.reopen = engine?.offeredValue ?? .array([])
        result.ended = engine?.endedValue ?? .array([])
        result.ending = engine?.endingValue ?? .array([])
        // As last read off the queue (`refreshBuilds`): null until the first read is in.
        result.builds = installRoot == nil ? nil : builds.flatMap { try? $0.wire(Status.Builds.self) }
        result.web = webValue?() ?? NodeStatusStore.webOff
        result.usage = engine?.usage.map(NodeUsage.value)
        result.boost = engine?.boostValue
        // What refuses a switch now (decision 6), less the workers it would park (`SwitchPark`, by the last look).
        result.switchBlockers = switching.blockers
        result.switchParks = switching.parks
        // The user's node's tailnet page, for the command line (not in the `node` stream: `NodeStatusStore.value`).
        if let tailnet { result.webTailnet = tailnet.value() }
        // The last update check's answer, for the command line (the page has its notice).
        if let updates { result.update = updates.value }
        // The health digest (`status --health`, the page's This node).
        if let health {
            result.health = health.value(serverRestarts: notes?.notes.serverRestarts, refusedConnections: notes?.notes.refusedAppConnections,
                                         hostRestartAt: engine?.restartValue["at"]?.string.flatMap(NodeWire.date),
                                         waiting: reminders, serverEnd: notes?.notes.lastServerEnd)
        }
        return result
    }

    /// A lead as `status` lists it: the store's, with its open and blocking questions and its open cards (E6), and how
    /// many of the witness's looks this server applied for it (`looks`, E8's review).
    func leadValue(_ lead: LeadStore.Lead) -> NodeWire.Value {
        guard case .object(var fields) = lead.value else { return lead.value }
        fields["looks"] = .int(engine?.witnessLooks[lead.root] ?? 0)
        let open = engine?.cards.list(project: lead.project) ?? []
        let questions = open.filter { $0.kind == .question || $0.kind == .approval }
        fields["questions"] = .object(["open": .int(questions.count), "blocking": .int(questions.filter(\.isBlocking).count)])
        fields["cards"] = .array(open.map { .string($0.id) })
        return .object(fields)
    }

    /// Open cards counted by kind, as `status` gives them.
    static func counts(_ counts: [CardStore.Kind: Int]) -> WireKinds.Status.CardCounts {
        .init(questions: counts[.question] ?? 0, approvals: counts[.approval] ?? 0, config: counts[.configHeld] ?? 0, base: counts[.baseMove] ?? 0)
    }

    static func word(_ state: HostLink.State) -> String {
        switch state {
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .gone(let why): return "gone: " + why
        }
    }

    static func value(_ notes: HostNotes, at: Date) -> NodeWire.Value { NodeWire.Value(wire: Self.notes(notes, at: at)) }

    /// The host's notes as `status` gives them.
    static func notes(_ notes: HostNotes, at: Date) -> WireKinds.Status.Notes {
        .init(startedAt: NodeWire.dateText(notes.startedAt), serverRestarts: notes.serverRestarts, replacedPaths: notes.replacedPaths,
              refusedAppConnections: notes.refusedAppConnections, lockHeldElsewhere: notes.lockHeldElsewhere, build: notes.build,
              at: NodeWire.dateText(at))
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

    // MARK: seen

    /// `seen` with `session` (a node's session id): the session counts as seen now (`NodeSessions.acknowledge`,
    /// the app's looking at its tab), so its finished turn reads `idle`. A web page sends it while it has the session
    /// open. It changes nothing but the seen mark, so it needs no voice: anyone that reads (a page's `read` right).
    private func seen(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        // A project's all-done cards seen (the board's `allDone`, the app's `AllDoneWatch.see`): only that mark changes.
        if let project = request.args?["project"]?.string, !project.isEmpty {
            guard let engine, let root = engine.leads.leads[project]?.root else {
                return reply(.init(re: request.id, error: .init(.gone, "no lead's project \(ConfigSeal.inert(project, limit: 80)) on this node")))
            }
            return engine.seeAllDone(root: root) { reply(.init(re: request.id, result: .object(["changed": .bool($0)]))) }
        }
        guard let id = request.args?["session"]?.string, !id.isEmpty else {
            return reply(.init(re: request.id, error: .init(.badArgs, "seen needs a session or a project")))
        }
        guard let sessions else { return reply(.init(re: request.id, error: .init(.notYet, "this server keeps no session list"))) }
        sessions.acknowledge(id) { found in
            reply(found ? .init(re: request.id, result: .object([:]))
                : .init(re: request.id, error: .init(.gone, "no session \(ConfigSeal.inert(id, limit: 80)) on this node")))
        }
    }

    // MARK: hooks

    /// `hooks.install` / `hooks.remove` with `agents`, a list of `claude` and `codex` (the start plan's S6, ST-D17): the
    /// hooks written in the server's home as the app, then sealed (`HooksRequest`), on the engine's read queue (the vault's
    /// calls block on the host), the programs checked against the host's notes' `binaries` as last asked. The result
    /// names what was written: `programs` (install) and `configs`.
    private func hooks(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let names = request.args?["agents"]?.array?.compactMap(\.string) ?? []
        let agents = Agent.allCases.filter { agent in names.contains(agent.rawValue) }
        guard !names.isEmpty, names.allSatisfy({ Agent(rawValue: $0) != nil }) else {
            return reply(.init(re: request.id, error: .init(.badArgs, "\(request.kind) needs agents, a list of claude and codex")))
        }
        let install = request.kind == "hooks.install"
        guard !install || nodeRoot != nil else {
            return reply(.init(re: request.id, error: .init(.refused, "this server has no build folder to install the hooks' programs from")))
        }
        let (nodeRoot, home, vault, commit) = (self.nodeRoot ?? "", self.home, link.vault, self.commit)
        let work = { (binaries: [String: String]?, hostBuild: String?) -> NodeWire.Reply in
            var hooks = HooksRequest(nodeRoot: nodeRoot, home: home, binaries: binaries, vault: vault)
            // While the host runs another build than this server, a program that isn't its `binaries` entry is the
            // build switch not finished yet (the server restarts onto it once idle), said so.
            (hooks.hostBuild, hooks.serverBuild) = (hostBuild, commit == "unknown" ? nil : commit)
            let configs = agents.map { hooks.configPath($0) }
            if install {
                switch hooks.install(agents: agents) {
                case .failure(let refusal): return .init(re: request.id, error: .init(.refused, refusal.text))
                case .success(let installed):
                    return .init(re: request.id, typed: WireKinds.HooksInstall.Result(programs: installed.programs, configs: installed.configs))
                }
            }
            switch hooks.remove(agents: agents) {
            case .failure(let refusal): return .init(re: request.id, error: .init(.refused, refusal.text))
            case .success: return .init(re: request.id, typed: WireKinds.HooksRemove.Result(configs: configs))
            }
        }
        let note = self.note
        let said = { (answer: NodeWire.Reply) in
            note("\(request.kind) \(names.joined(separator: ",")): \(answer.ok ? "done" : answer.error?.message ?? "refused")")
            reply(answer)
        }
        // On `queue`: the notes as last asked.
        let run = { [weak self] in
            guard let self else { return }
            let (binaries, hostBuild) = (self.notes?.notes.binaries, self.notes?.notes.build)
            if let engine = self.engine {
                engine.reads.async({ _ in work(binaries, hostBuild) }, then: said)
            } else {
                DispatchQueue.global(qos: .userInitiated).async { [queue = self.queue] in
                    let answer = work(binaries, hostBuild)
                    queue.async { said(answer) }
                }
            }
        }
        // The host's notes asked again first: the programs are checked against its `binaries` as it says them now.
        guard install else { return run() }
        refreshNotes(run)
    }

    // MARK: build.switch

    /// `build.switch` with `commit` (the start plan's S8b): `SwitchRequest`'s plan, handover and outcome, on the
    /// install root's builds, a handover refused while the seal holds a change under the builds folder or the unit's
    /// folder in this server's home (`HeldChange`). The host's notes are asked again after it, so `status` names the
    /// build that runs.
    /// The sessions that refuse a switch now (`SwitchRequest.blockers`), less the workers the engine's last look saw only
    /// waiting on their lead, which the switch parks (`parks`). On `queue`.
    func switchBlockersNow() -> (blockers: [String], parks: [String]) {
        let hinted = engine?.switchParkHint(link.sessions) ?? []
        let parked = Set(hinted.map(\.session))
        let holding = SwitchRequest.holding(link.sessions).filter { !parked.contains($0.id) }
        return (SwitchRequest.blockers(holding, describe: switchDoing), hinted.map(\.named))
    }

    /// What a session that holds a switch is doing and since when, by the node's last scan of it.
    func switchDoing(_ session: HostSession) -> String? {
        let scanned = sessions?.sessions.first { $0.hostID == session.id }
        return SwitchRequest.doing(session, status: scanned?.status, since: scanned?.statusSince, now: Date())
    }

    private func buildSwitch(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let commit = request.args?["commit"]?.string else {
            return reply(.init(re: request.id, error: .init(.badArgs, "build.switch needs commit, 40 lowercase hex digits")))
        }
        guard let installRoot else {
            return reply(.init(re: request.id, error: .init(.refused, "this server has no install root to switch builds in")))
        }
        // A change under the builds folder or the unit's folder nobody accepted refuses the handover (`SwitchRequest`).
        let (home, vault) = (self.home, link.vault)
        let held: @Sendable () -> String? = {
            HeldChange.refusal(SwitchRequest.heldNames, home: home, vault: vault, accept: SwitchRequest.acceptFirst)?.text
        }
        // The workers that only wait on their lead are parked for it (`SwitchPark`): the engine's, on its queue.
        let park: SwitchRequest.Park? = engine.map { engine in { live, commit, done in
            engine.queue.async {
                engine.parkForSwitch(live, commit: commit) { parked in done(parked.map(\.named)) }
            }
        } }
        SwitchRequest(link: link, installRoot: installRoot, timing: switchTiming, held: held, park: park,
                      describe: { [weak self] in self?.switchDoing($0) }, note: note).run(commit: commit) { [weak self] answer in
            switch answer {
            case .done(let result): reply(.init(re: request.id, typed: result))
            case .refused(let code, let why): reply(.init(re: request.id, error: .init(code, why)))
            }
            self?.refreshNotes()
        }
    }

    // MARK: start

    /// The node runs: its start time. Starting a stopped node is the bootstrap path's step 8's, without the server.
    private func start(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        reply(.init(re: request.id, typed: WireKinds.Start.Result(running: true, serverStartedAt: NodeWire.dateText(startedAt),
                                                                   hostStartedAt: link.hostStartedAt.map(NodeWire.dateText), epoch: epoch)))
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

    /// `lead FOLDER [--goal TEXT] [--take-head] [--replace] [--resume]` (E4): the engine's start, its outcome as the result:
    /// the project's id, the lead's session, what happened (`started`, `shown`, `waiting`), the program's absolute path
    /// (EN-D13), and notes; a refusal is `refused` with the engine's reason.
    private func lead(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        guard let folder = request.args?["folder"]?.string, folder.hasPrefix("/") else {
            return reply(.init(re: request.id, error: .init(.badArgs, "lead needs folder, an absolute path")))
        }
        let goal = request.args?["goal"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server starts no leads"))) }
        engine.startLead(folder: folder, goal: goal, takeHead: request.args?["takeHead"]?.bool == true,
                         replace: request.args?["replace"]?.bool == true, resume: request.args?["resume"]?.bool == true,
                         initialized: request.args?["initialized"]?.bool == true) { outcome in
            reply(Self.reply(request.id, folder: folder, outcome))
        }
    }

    /// A start's outcome as `lead`'s reply.
    static func reply(_ id: String, folder: String, _ outcome: LeadEngine.StartOutcome) -> NodeWire.Reply {
        func result(_ happened: String, session: UUID?, program: String?, notes: [String]) -> NodeWire.Reply {
            .init(re: id, typed: WireKinds.Lead.Result(happened: happened, session: session.map { NodeIds.session(host: $0) }, program: program,
                                                       notes: notes))
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
    final class Waiting: @unchecked Sendable {
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
                reply(.init(re: request.id, typed: WireKinds.Stop.Result(sessionsEnded: ended, host: "shutting down")))
                self.note("stop: the host accepted; it ends this server")
            }
        }
    }
}
