import Foundation

/// What the witness reads of a lead's team at each look, on `LeadReads`' queue: a team's transcripts are a few hundred
/// KB each to parse (thirty of them froze the window when read on the main thread). The sessions as they were when the
/// look began, what each member it watches is doing (`LeadObserver.watching`), the oldest message waiting for each
/// worker, and the project's workflow.
public struct TeamReading {
    public typealias Watched = (activity: LeadActivity, tail: TranscriptTail?, progress: TranscriptProgress?)

    /// The window's sessions, and the scan's agents in them, by host session id.
    public var hosted: [String: HostSession] = [:]
    public var sessions: [String: Session] = [:]
    public var watched: [String: Watched] = [:]
    public var held: [String: SteerMessage] = [:]
    /// The live workers with a run in line for the Mac-wide test and build lock (see `LeadWitness.Seen.lockWait`).
    public var lockWaits: [String: TestLock.Wait] = [:]
    public var workflow = LeadWorkflow()
    /// The account's usage, the workers' model and the usage-limit setting, for the team rows' usage waits: read by the
    /// app's `read` (left empty by this one).
    public var usage = AccountUsage()
    public var workerModel: String?
    public var ignoreUsageLimits = false
    /// Made on the read queue: selecting a held audit model can need the existing branch security check.
    public var reviewUsageWaits: [String: ReviewUsageWait]?
    /// The lead's loop runs with workflow.md's auto_advance on: a verifier that ends without a verdict is its to
    /// audit again (see `LeadWitness.leftToAdvance`), a worker's first stop without a report its to nudge
    /// (`LeadWitness.stopsForAdvance`). Looked at only while a task is in review or running.
    public var advancing = false
    /// The live members with no agent in the scan whose agent's process has exited, by a process table read here (see
    /// `HostSession.agentRuns`): only these have quit. One whose agent waits on a background command runs on.
    public var agentGone: Set<String> = []

    public init(hosted: [String: HostSession] = [:], sessions: [String: Session] = [:], watched: [String: Watched] = [:],
                held: [String: SteerMessage] = [:], lockWaits: [String: TestLock.Wait] = [:], workflow: LeadWorkflow = LeadWorkflow(),
                usage: AccountUsage = AccountUsage(), workerModel: String? = nil, ignoreUsageLimits: Bool = false,
                reviewUsageWaits: [String: ReviewUsageWait]? = nil, advancing: Bool = false, agentGone: Set<String> = []) {
        self.hosted = hosted
        self.sessions = sessions
        self.watched = watched
        self.held = held
        self.lockWaits = lockWaits
        self.workflow = workflow
        self.usage = usage
        self.workerModel = workerModel
        self.ignoreUsageLimits = ignoreUsageLimits
        self.reviewUsageWaits = reviewUsageWaits
        self.advancing = advancing
        self.agentGone = agentGone
    }

    /// The member `id`'s agent quit, leaving its session's shell open: the scan has no agent on it a minute on
    /// (`scanSaysQuit`, see `TableRead.agentQuit`), and its agent's own process has exited (`agentGone`).
    public func agentQuit(_ id: String, session: Session?, scanSaysQuit: Bool) -> Bool {
        session == nil && scanSaysQuit && agentGone.contains(id)
    }

    /// Each live member's transcript is read whatever it shows: a worker's stall is one that reads as working too (see
    /// `LeadStall`), and a turn that ended on the account's usage limit reads as working (Claude Code fires no Stop hook
    /// on it; a verifier's audit sat there for hours, 2026-10-31): its transcript says so (see `UsageLimit`). `inbox`:
    /// the root whose steer inboxes hold what waits for each worker (the app's `VibePaths.root`). `lock`: the Mac-wide
    /// test and build lock its workers queue on (none: no wait is read), asked only when a worker runs.
    public static func read(root: String, board: LeadBoard, hosted: [String: HostSession], sessions: [String: Session],
                            observer: LeadObserver, inbox: URL, lock: @autoclosure () -> TestLock?) -> TeamReading {
        var team = TeamReading(hosted: hosted, sessions: sessions)
        let workers = workerSessions(board)
        for id in board.tasks.flatMap(\.watched) where team.watched[id] == nil {
            guard let info = hosted[id], info.isLive, let session = sessions[id] else { continue }
            team.watched[id] = observer.watching(info, agentPid: session.pid)
            if workers.contains(id) {
                team.held[id] = SteerInbox.pending(tty: session.tty, root: inbox).filter { $0.agentPid == session.pid }.min { $0.at < $1.at }
            }
        }
        let folders = workers.compactMap { id in hosted[id].flatMap { $0.isLive ? (id, $0.cwd) : nil } }
        if !folders.isEmpty, let lock = lock() {
            team.lockWaits = lock.waits(for: Dictionary(folders, uniquingKeysWith: { first, _ in first }))
        }
        team.workflow = LeadWorkflow.load(from: (BoardStore(root: root).folder as NSString).appendingPathComponent("workflow.md"))
        team.advancing = team.workflow.autoAdvance && board.tasks.contains { [.review, .running].contains($0.status) } && LeadAdvance.running(BoardStore(root: root))
        // The table is read only when the scan lacks a member's agent (rare), here off the main thread.
        let unseen = board.tasks.flatMap(\.watched).compactMap { id in
            hosted[id].flatMap { $0.isLive && sessions[id] == nil ? (id: id, session: $0) : nil }
        }
        if !unseen.isEmpty, let table = ProcessTable.trySnapshot() {
            team.agentGone = Set(unseen.filter { !$0.session.agentRuns(in: table) }.map(\.id))
        }
        return team
    }

    /// The sessions whose shells, held messages and test-lock waits are read: each task's worker and each team
    /// member's (`LeadTask.memberSessions`), watched as the worker is.
    public static func workerSessions(_ board: LeadBoard) -> Set<String> {
        Set(board.tasks.flatMap { task in [task.worker].compactMap { $0 } + task.memberSessions.map(\.session) })
    }

    /// Who a waiting message is from, in words.
    public static func sender(_ sender: SteerMessage.Sender) -> String {
        switch sender {
        case .user: return "the user"
        case .lead(let name): return name
        case .system(let about): return "VibeSwitcher (\(about))"
        case .teammate(let member, let task): return "teammate \(member) on \(task)"
        }
    }
}

/// A recorded stop or a hold on the model an audit would start on. No review clock runs while it waits.
public struct ReviewUsageWait: Equatable {
    public var model: String?
    public var resetsAt: Double?

    public init(model: String? = nil, resetsAt: Double? = nil) {
        self.model = model
        self.resetsAt = resetsAt
    }

    public var name: String { model.flatMap(AccountUsage.family).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "the account" }
    public var state: String { model == nil ? "Waits for usage limit" : "Waits for \(name)" }
    public var line: String {
        let whose = model == nil ? "The account's" : "\(name)'s"
        return whose + " limit " + (resetsAt.map { "resets \(UsageLimit.resetText($0))" } ?? "reset time is not known")
    }
}
