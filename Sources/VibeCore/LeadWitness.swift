import Foundation

/// What VibeSwitcher sees that the lead can't: a worker or verifier that waits for input, stops without
/// reporting, ends (its session, or only its agent, leaving the shell open), or stalls whatever its screen says (see
/// `LeadStall`). Each event is keyed by its session, so it's told once, and a new session on the same task is
/// watched afresh.
public enum LeadWitness {
    /// A session as VibeSwitcher sees it.
    public struct Seen: Equatable, Sendable {
        public var live: Bool
        public var exit: Int32?
        /// How it ended, in words (see `HostSession.Exit.cause`): "killed by SIGTERM", "exited 143".
        public var cause: String?
        public var status: SessionStatus?
        public var since: Date?
        public var detail: String?
        /// Mid-turn, the call its transcript shows with no result yet, in full (`TranscriptTail.pending`): while it
        /// waits for input, what it waits for, where `detail` has it cut to a line.
        public var pending: PendingPrompt?
        /// The session lives on as a shell, its agent gone (see `HostSession.agentQuit`).
        public var agentQuit: Bool
        /// Its last turn ended on this API error (see `TranscriptTail`), and it's between turns; `apiErrorAt` is when
        /// that turn ended (each error is told once).
        public var apiError: String?
        public var apiErrorAt: Double?
        /// What its hooks and transcript together say it's doing (see `LeadActivity`), when read.
        public var activity: LeadActivity?
        /// When its transcript was last written to (see `TranscriptProgress`), and when it ends at a compaction.
        public var lastActivity: Double?
        public var compactedAt: Double?
        /// The shells of its own the store's last scan found running (see `Session.backgroundJobs`), in the foreground
        /// or the background: mid-turn, the command its turn runs (see `turnShells`); between turns, background work it
        /// waits on, whether or not its transcript's read window names the task (see `waitingOn`).
        public var shells: [BackgroundJob]
        /// The oldest message waiting in its inbox, and who sent it.
        public var heldSince: Double?
        public var heldFrom: String?
        /// When this session was started (the host spawned it): a status or quiet from before then is another
        /// session's (the terminal it reuses, or none read yet).
        public var started: Double?
        /// A verifier that gave its verdict (or cast its ballot), by the vault's roster: when. The host ends it
        /// shortly after (its job is done), so its end is expected, never news.
        public var submittedAt: Double?

        /// How it ended, in words; its exit code when that wasn't said.
        var ending: String { cause ?? "exit \(exit ?? 0)" }

        /// Between turns, the work of its own it waits on, in words: the background task its transcript names, or
        /// else its shells, as the lead's status says them ("1 shell: bash calm-check.sh", "2 shells"). Its turn goes
        /// on when that's done.
        public var waitingOn: String? {
            if case .idle(let running?)? = activity { return running }
            let waited = waitedShells
            guard activity?.betweenTurns ?? [.done, .idle, .background].contains(status ?? .unknown), let first = waited.first else { return nil }
            return waited.count == 1 ? "1 shell: \(first.command.prefix(80))" : "\(waited.count) shells"
        }

        /// Between turns, the shells its turn could have ended to wait on: those started within `backgroundCeiling` of
        /// its last step. One older than that (a `run_in_background` server it started hours ago and kept working
        /// beside) is past the wait it gets already, and isn't what its turn waits on.
        var waitedShells: [BackgroundJob] {
            guard let last = lastActivity else { return shells }
            return shells.filter { $0.startedAt.timeIntervalSince1970 >= last - LeadStall.backgroundCeiling }
        }

        /// Mid-turn, the shells that are its turn at work: a command it runs in the foreground. Claude writes the call
        /// to its transcript before the shell starts, and gives a foreground command at most `LeadStall.bashCeiling`,
        /// so that's one started since its transcript's last write or within the ceiling. Any other is one it left in
        /// the background (a server, a wait loop): it runs on whether or not the agent does anything.
        public func turnShells(now: Date) -> [BackgroundJob] {
            shells.filter { shell in
                let started = shell.startedAt.timeIntervalSince1970
                return started >= (lastActivity ?? .infinity) || now.timeIntervalSince(shell.startedAt) <= LeadStall.bashCeiling
            }
        }

        public init(live: Bool, exit: Int32? = nil, cause: String? = nil, status: SessionStatus? = nil, since: Date? = nil, detail: String? = nil,
                    pending: PendingPrompt? = nil, agentQuit: Bool = false, apiError: String? = nil, apiErrorAt: Double? = nil, activity: LeadActivity? = nil,
                    lastActivity: Double? = nil, compactedAt: Double? = nil, shells: [BackgroundJob] = [],
                    heldSince: Double? = nil, heldFrom: String? = nil, started: Double? = nil, submittedAt: Double? = nil) {
            self.live = live
            self.started = started
            self.submittedAt = submittedAt
            self.activity = activity
            self.lastActivity = lastActivity
            self.compactedAt = compactedAt
            self.shells = shells
            self.heldSince = heldSince
            self.heldFrom = heldFrom
            self.agentQuit = agentQuit
            self.apiError = apiError
            self.apiErrorAt = apiErrorAt
            self.exit = exit
            self.cause = cause
            self.status = status
            self.since = since
            self.detail = detail
            self.pending = pending
        }

        /// While it waits for input, what it waits for and since when (its status's since).
        public var prompt: PendingPrompt {
            PendingPrompt.waiting(asked: detail, pending: pending, since: since?.timeIntervalSince1970)
        }
    }

    /// How long a session may sit finished before it counts as stopped.
    public static let quiet: TimeInterval = 90

    public static func events(board: LeadBoard, seen: [String: Seen], now: Date = Date()) -> [(key: String, text: String)] {
        var events: [(key: String, text: String)] = []
        for task in board.tasks where task.status != .done {
            // A worker the lead stopped itself ended because it was told to.
            if let worker = task.worker, worker != task.stopped, let info = seen[worker] {
                if !info.live, [.running, .failed].contains(task.status) {
                    events.append(("\(worker)|ended", "The worker on \(task.slug) ended (\(info.ending)) without reporting. Its commits are on agent/\(task.slug); read_session to see why, then start_worker(\(task.slug)) starts it again where it was (the task needn't be set to blocked first), or re-plan."))
                } else if info.live, info.agentQuit, [.running, .failed].contains(task.status) {
                    events.append(("\(worker)|ended", "The worker on \(task.slug) ended without reporting: its agent quit and left the session's shell open. Its commits are on agent/\(task.slug); read_session to see why, then stop_worker (it closes the shell) and start_worker again, or re-plan."))
                } else if info.live, !info.agentQuit, let error = info.apiError, [.running, .failed].contains(task.status) {
                    events.append(("\(worker)|api-error-\(Int(info.apiErrorAt ?? 0))", "The worker on \(task.slug) stopped mid-task: its turn ended on an API error (\(error)). Tell it to go on with message(\(task.slug), …); it picks up where it was."))
                } else if info.live, !info.agentQuit, let event = waiting(info, session: worker, now: now,
                                                         input: waitingText("The worker on \(task.slug)", info, now: now, advice: "Answer it with message, or ask the user if it's theirs to decide."),
                                                         stopped: task.status == .running ? "The worker on \(task.slug) stopped without calling report. read_session to see where it is, then message it." : nil) {
                    events.append(event)
                }
                if info.live {
                    for stall in LeadStall.detect(info, task: task, now: now) {
                        events.append((stall.key(session: worker), "The worker on \(task.slug) is \(stall.text(now: now)). \(stall.advice(slug: task.slug))"))
                    }
                }
            }
            // With several finders, each that hasn't submitted yet.
            for verifier in task.status == .review && task.evidence == nil ? task.awaitedVerifiers : [] {
                guard let info = seen[verifier], !gaveVerdict(info, on: task) else { continue }
                if info.live, !info.agentQuit, let error = info.apiError {
                    events.append(("\(verifier)|api-error-\(Int(info.apiErrorAt ?? 0))", "The verifier on \(task.slug) stopped mid-audit: its turn ended on an API error (\(error)). Tell the user, or audit again."))
                } else if !info.live || info.agentQuit {
                    events.append(("\(verifier)|ended", "The verifier on \(task.slug) ended without a verdict (\(info.live ? "its agent quit; the session's shell is still open" : info.ending)). read_session(\(task.slug), who: verifier) to see why, then audit again."))
                } else if let event = waiting(info, session: verifier, now: now,
                                              input: waitingText("The verifier on \(task.slug)", info, now: now, advice: "Tell the user if it's theirs, or audit again."),
                                              stopped: "The verifier on \(task.slug) stopped without calling submit_audit. read_session(\(task.slug), who: verifier) to see why, then audit again.") {
                    events.append(event)
                }
            }
        }
        return events
    }

    /// What to tell the lead: the `events` not `told` yet, as they are, except that sessions that ended without
    /// reporting are told together, in one message naming each task and how it ended (a stray kill ends many at
    /// once). Each message carries the keys of the events it tells.
    public static func messages(board: LeadBoard, seen: [String: Seen], now: Date = Date(), told: (String) -> Bool) -> [(keys: [String], text: String)] {
        let fresh = events(board: board, seen: seen, now: now).filter { !told($0.key) }
        let ended = Set(fresh.map(\.key).filter { $0.hasSuffix("|ended") })
        guard ended.count > 1 else { return fresh.map { ([$0.key], $0.text) } }
        let lines = endings(board: board, seen: seen).filter { ended.contains($0.key) }
        var advice: [String] = []
        if lines.contains(where: { $0.restart == .worker }) {
            advice.append("start_worker(<task>) starts a worker again where it was, its worktree and commits kept; the task needn't be set to blocked first")
        }
        if lines.contains(where: { $0.restart == .stopFirst }) { advice.append("a worker whose agent quit needs stop_worker (it closes the shell) first") }
        if lines.contains(where: { $0.restart == .verifier }) { advice.append("audit(<task>) checks a task again") }
        let text = "\(lines.count) sessions ended without reporting:\n" + lines.map { "- The \($0.line)" }.joined(separator: "\n")
            + "\nread_session to see why. " + advice.joined(separator: "; ") + "."
        return [(lines.map(\.key), text)] + fresh.filter { !ended.contains($0.key) }.map { ([$0.key], $0.text) }
    }

    private enum Restart { case worker, stopFirst, verifier }

    /// The verifier submitted its audit (the vault says so: the host ends it shortly after), or gave the verdict the
    /// board keeps for an older commit (it, or its panel, was at work before that verdict came): its audit is done,
    /// and the worker committed again since (report told the lead to audit that). A verifier the lead starts for the
    /// new commit starts after that verdict, and is watched as any other.
    private static func gaveVerdict(_ info: Seen, on task: LeadTask) -> Bool {
        if info.submittedAt != nil { return true }
        guard let earlier = task.outdatedEvidence, let started = info.started else { return false }
        return earlier.at >= started
    }

    /// Each session `events` tells as ended, in a line: "worker on a: killed by SIGTERM".
    private static func endings(board: LeadBoard, seen: [String: Seen]) -> [(key: String, line: String, restart: Restart)] {
        var lines: [(key: String, line: String, restart: Restart)] = []
        for task in board.tasks where task.status != .done {
            if let worker = task.worker, worker != task.stopped, let info = seen[worker], [.running, .failed].contains(task.status) {
                if !info.live {
                    lines.append(("\(worker)|ended", "worker on \(task.slug): \(info.ending)", .worker))
                } else if info.agentQuit {
                    lines.append(("\(worker)|ended", "worker on \(task.slug): its agent quit, leaving the session's shell open", .stopFirst))
                }
            }
            for verifier in task.status == .review && task.evidence == nil ? task.awaitedVerifiers : [] {
                guard let info = seen[verifier], !info.live || info.agentQuit, !gaveVerdict(info, on: task) else { continue }
                lines.append(("\(verifier)|ended", "verifier on \(task.slug): \(info.live ? "its agent quit, leaving the session's shell open" : info.ending)", .verifier))
            }
        }
        return lines
    }

    /// The stall to keep on each running task whose worker is stalled now (the most telling one), by task id.
    public static func stalls(board: LeadBoard, seen: [String: Seen], now: Date = Date()) -> [String: LeadStall] {
        var found: [String: LeadStall] = [:]
        for task in board.tasks {
            guard let worker = task.worker, worker != task.stopped, let info = seen[worker],
                  let stall = LeadStall.detect(info, task: task, now: now).first else { continue }
            found[task.id] = stall
        }
        return found
    }

    /// How often the stranded sessions are told at most (see `strandedText`).
    public static let strandedEvery: TimeInterval = 3600

    /// The workers and verifiers of finished tasks that still run, idle over an hour (see `LeadTeams.stranded`), in
    /// every project, as one message, a line each: VibeSwitcher ends a finished task's sessions itself, so these are
    /// ones it couldn't. Nil when there are none.
    public static func strandedText(_ stranded: [LeadTeams.Stranded], now: Date = Date()) -> String? {
        guard !stranded.isEmpty else { return nil }
        let count = stranded.count == 1 ? "1 role session still runs" : "\(stranded.count) role sessions still run"
        return "\(count) though its task is finished, idle over \(LeadTeams.hours(LeadTeams.strandedAfter)) (VibeSwitcher couldn't end \(stranded.count == 1 ? "it" : "them")):\n"
            + stranded.map { "- The \($0.line(now: now))" }.joined(separator: "\n")
            + "\ncleanup(<task>) ends your own project's; tell the user about the others (they can end them in VibeSwitcher's window)."
    }

    /// Watches the free space on the volume holding a project's worktrees: when it drops below the workflow's
    /// warning, the lead is told once (until it's back up, see `DiskWatch`), with the task folders that take most.
    /// With `file`, what was told is kept there (`DiskWatch.file`), so a relaunched app doesn't tell it again.
    public struct Disk {
        let free: (String) -> Int64?
        let scratch: URL
        let sessions: URL
        let file: URL?
        public private(set) var watch = DiskWatch()
        private var restored = false

        public init(free: @escaping (String) -> Int64? = DiskSpace.free(at:), scratch: URL = ClaudeScratch.root,
                    sessions: URL = SessionTemp.root, file: URL? = nil) {
            self.free = free
            self.scratch = scratch
            self.sessions = sessions
            self.file = file
        }

        /// The free space to tell the lead about now (once per episode); nil otherwise. Cheap: sizing the folders
        /// is `text`'s.
        public mutating func check(root: String, workflow: LeadWorkflow, now: Date = Date()) -> Int64? {
            if !restored, let file {
                restored = true
                if let saved = DiskWatch.load(root: root, from: file) { watch = saved }
            }
            let free = self.free((root as NSString).appendingPathComponent(".vibeswitcher/worktrees"))
            let before = watch
            let tell = watch.check(free: free, warning: workflow.diskWarning, now: now)
            if watch != before, let file { watch.save(root: root, to: file) }
            return tell ? free : nil
        }

        /// What to tell the lead: the space left, the biggest task folders, and every project's big session TMPDIRs
        /// (`cwds`: the listed sessions' folders, to name them by), sized now: it takes a while.
        public func text(free: Int64, root: String, board: LeadBoard, workflow: LeadWorkflow, cwds: [String] = [],
                         size: (String) -> Int64 = DiskSpace.size(of:)) -> String {
            LeadWitness.diskText(free: free, workflow: workflow, folders: TaskFolder.all(root: root, board: board, scratch: scratch, sessions: sessions,
                                                                                            size: size),
                                 tmpdirs: SessionTemp.big(cwds: cwds, in: sessions, size: size))
        }

        /// Both at once.
        public mutating func event(root: String, board: LeadBoard, workflow: LeadWorkflow, cwds: [String] = [],
                                   size: (String) -> Int64 = DiskSpace.size(of:)) -> String? {
            check(root: root, workflow: workflow).map { text(free: $0, root: root, board: board, workflow: workflow, cwds: cwds, size: size) }
        }
    }

    /// Watches the Mac-wide test and build slots (the app looks once a minute, see `TestLock`): a slot held over
    /// `TestLock.longAfter` is told to every running lead once per holder, as long. Only said: nothing is ended (it may
    /// be another project's, and a long suite isn't a hung one).
    public struct HeavySlots {
        let lock: TestLock?
        /// The long holders told, by slot, note and since: one that's let go is forgotten.
        public private(set) var told: Set<String> = []

        public init(lock: TestLock? = TestLock.standard()) { self.lock = lock }

        /// What to tell the leads now, if anything.
        public mutating func look(now: Date = Date()) -> String? {
            guard let lock else { return nil }
            let long = lock.holders().filter { $0.isLong(now: now) }
            let keyed = long.map { (holder: $0, key: "\($0.slot)|\($0.note ?? "")|\($0.since?.timeIntervalSince1970 ?? 0)") }
            told.formIntersection(keyed.map(\.key))
            let new = keyed.filter { !told.contains($0.key) }
            guard !new.isEmpty else { return nil }
            told.formUnion(new.map(\.key))
            return LeadWitness.longSlotText(new.map(\.holder), now: now)
        }
    }

    /// "A Mac-wide test and build slot is held long: slot 1 held by pid 30098, pytest -q in /…/TGE (TGE), for 38 min,
    /// long. …".
    public static func longSlotText(_ holders: [TestLock.Holder], now: Date = Date()) -> String {
        (holders.count == 1 ? "A Mac-wide test and build slot is held long: " : "\(holders.count) Mac-wide test and build slots are held long: ")
            + TestLock.text(holders, now: now) + ". Nothing ends it: builds, suites and merges wait only once every slot is held. "
            + "If it's one of this project's and looks hung, have its worker look; if it's another project's, tell the user."
    }

    /// Watches the Mac's power source (the app looks once a minute): a hold when the charge is under the user's limit
    /// on battery, and the resume after one, told to every running lead once (see `PowerWatch`); each reading is kept
    /// in `file` for status, with the hold while it lasts.
    public struct Power {
        let read: () -> PowerState?
        /// The limit in Settings, read at each look (0: never hold).
        let limit: () -> Int
        let file: URL
        public private(set) var watch = PowerWatch()

        public init(read: @escaping () -> PowerState?, limit: @escaping () -> Int = { PowerWatch.defaultLimit },
                    file: URL = PowerState.file) {
            self.read = read
            self.limit = limit
            self.file = file
        }

        /// Reads the power source: what to tell the leads now, if anything.
        public mutating func look() -> String? {
            let state = read()
            let event = watch.check(state, limit: PowerWatch.clamp(limit()))
            if var state {
                state.heldUnder = state.onBattery ? watch.heldUnder : nil
                state.save(to: file)
            }
            return event.map(LeadWitness.powerText)
        }
    }

    /// "On battery: 45 %, under your 50 % limit: start no workers or audits …"; "On AC power: resume starts and merges
    /// (80 %, charging)."; on battery after the limit was lowered or turned off, "On battery: 45 %, no longer under your
    /// limit (now 40 %): resume starts and merges.".
    public static func powerText(_ event: PowerWatch.Event) -> String {
        switch event {
        case let .hold(state, limit):
            return "On battery: \(state.percent) %, under your \(limit) % limit: start no workers or audits and merge nothing "
                + "until AC power returns; work in flight finishes."
                + (state.minutesLeft.map { " About \(PowerState.clock($0)) left." } ?? "")
        case let .resume(state, limit):
            guard state.onBattery else {
                return "On AC power: resume starts and merges (\(state.percent) %, \(state.charging ? "charging" : "not charging"))."
            }
            return "On battery: \(state.percent) %, no longer under your limit (now \(limit == 0 ? "off" : "\(limit) %")): resume starts and merges."
        }
    }

    /// "Disk space is low: 7.4 GB free … Biggest task folders: … Sessions' TMPDIRs over 500 MB (every project's): …".
    /// `tmpdirs`: the big ones (`SessionTemp.big`); one already among `folders` (this project's task's) isn't said twice.
    public static func diskText(free: Int64, workflow: LeadWorkflow, folders: [TaskFolder], tmpdirs: [SessionTemp.Big] = []) -> String {
        let biggest = folders.prefix(5).map(\.text)
        let finished = folders.contains(where: \.finished)
        let shown = Set(folders.prefix(5).map(\.path))
        let others = tmpdirs.filter { !shown.contains($0.path) }.prefix(3).map(\.text)
        return "Disk space is low: \(DiskSpace.text(free)) free on the volume holding the worktrees (the warning is at \(LeadToolset.gb(workflow.diskWarningGB)) GB; "
            + "start_worker refuses below \(LeadToolset.gb(workflow.diskFloorGB)) GB, and at 0 every session stops). "
            + (biggest.isEmpty ? (others.isEmpty ? "No task folder takes much of it; tell the user what else fills the disk." : "No task folder takes much of it. ")
               : "Biggest task folders: \(biggest.joined(separator: "; ")). "
               + (finished ? "cleanup the finished tasks to free theirs; " : "")
               + "tell the user if it stays low.")
            + (others.isEmpty ? "" : (biggest.isEmpty ? "" : " ") + "Sessions' TMPDIRs over \(DiskSpace.text(SessionTemp.bigOver)) (every project's): "
               + others.joined(separator: "; ") + ". VibeSwitcher clears pytest's earlier runs from them and an ended session's whole; "
               + "if one of this project's keeps growing, have its worker look; another project's, tell the user.")
    }

    /// "The worker on a is waiting for input since 09:52 (6 min): “Run: ls”. <advice>", what it waits for quoted in
    /// full (a long or several-line one in a fenced block, see `PendingPrompt.quoted`).
    static func waitingText(_ who: String, _ info: Seen, now: Date, advice: String) -> String {
        let prompt = info.prompt
        let quoted = prompt.quoted
        let head = "\(who) is waiting for input" + (prompt.waited(now: now).map { " \($0)" } ?? "")
        return quoted.hasPrefix("“") ? "\(head): \(quoted). \(advice)" : "\(head). It waits on:\n\(quoted)\n\(advice)"
    }

    private static func waiting(_ info: Seen, session: String, now: Date, input: String, stopped: String?) -> (key: String, text: String)? {
        let since = Int(info.since?.timeIntervalSince1970 ?? 0)
        if info.status == .needsInput { return ("\(session)|input-\(since)", input) }
        // Waiting on its own background task (a long test run) or shell, its turn goes on when that's done.
        if info.waitingOn != nil { return nil }
        // The store reads a quiet session with shells of its own as in the background; with none it waits on (a server
        // it left running hours ago), its turn is simply over.
        let finished: Set<SessionStatus> = info.shells.isEmpty ? [.done, .idle] : [.done, .idle, .background]
        guard let stopped, let status = info.status, finished.contains(status), let at = info.since else { return nil }
        // Its hooks or transcript, read after the status, say it's mid-turn: the status is stale.
        if case .working? = info.activity { return nil }
        // Quiet since the last of: its turn ending, this session starting (a session first seen before its hooks
        // fire reads as finished since ever, one on a reused terminal as the earlier session finished), and its
        // transcript's last write.
        let quietSince = max(at.timeIntervalSince1970, info.started ?? -.infinity, info.lastActivity ?? -.infinity)
        return now.timeIntervalSince1970 - quietSince > quiet ? ("\(session)|stopped-\(since)", stopped) : nil
    }
}
