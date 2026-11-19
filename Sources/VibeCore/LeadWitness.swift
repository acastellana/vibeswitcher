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
        /// By the vault's roster: when it was bound to its session, and when its tool server first asked the host who
        /// it is (see `LeadVault.RosterEntry.toolsAt`). Bound `toolsWithin` ago with neither, it never got its tools.
        public var boundAt: Double?
        public var toolsAt: Double?
        /// Its place in line for the Mac-wide test and build lock, while a run in its folder waits for a slot (see
        /// `TestLock.waits`): it waits on the lock, not stalled (11 of 19 stall alarms in TGE were workers in line).
        public var lockWait: TestLock.Wait?
        /// What its transcript names still running in the background (`TranscriptTail.background`).
        public var backgroundTasks: [TranscriptTail.Background]
        /// `shells` comes from a reading of the process table for this session, and a job missing from it has stayed
        /// missing (`MissingJobs`), so it has no process.
        public var shellsRead: Bool
        /// How long the Mac has slept, by the awake clock (see `MacSleepLog`).
        public var sleep: MacSleepLog
        /// Its job has no process in this look but hasn't stayed missing yet (`MissingJobs`): for that minute and a
        /// half it's neither waiting on a live job nor stopped, and nothing is said of it.
        public var jobCheckPending = false

        /// How it ended, in words; its exit code when that wasn't said.
        var ending: String { cause ?? "exit \(exit ?? 0)" }

        /// Its turn ended on the account's usage limit, by its transcript (see `LeadActivity.usageLimit`): stopped until
        /// the limit resets, whatever its hooks (and so `status`) say. Claude Code fires no Stop hook on it.
        public var usageLimit: UsageLimit? {
            if case .usageLimit(let limit)? = activity { return limit }
            return nil
        }

        /// Between turns, the work of its own it waits on, in words: the background task its transcript names, or
        /// else its shells, as the lead's status says them ("1 shell: bash calm-check.sh", "2 shells"). Its turn goes
        /// on when that's done.
        public var waitingOn: String? {
            // The job its transcript names has no process left: its turn won't go on, whatever else runs.
            if diedJob != nil { return nil }
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
                    heldSince: Double? = nil, heldFrom: String? = nil, started: Double? = nil, submittedAt: Double? = nil,
                    boundAt: Double? = nil, toolsAt: Double? = nil, lockWait: TestLock.Wait? = nil,
                    backgroundTasks: [TranscriptTail.Background] = [], shellsRead: Bool = false, sleep: MacSleepLog = MacSleepLog()) {
            self.live = live
            self.lockWait = lockWait
            self.backgroundTasks = backgroundTasks
            self.shellsRead = shellsRead
            self.sleep = sleep
            self.started = started
            self.submittedAt = submittedAt
            self.boundAt = boundAt
            self.toolsAt = toolsAt
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

        /// Its tool server never asked the host who it is, `toolsWithin` after its session was bound (see `neverGotTools`).
        public func neverGotTools(now: Date) -> Bool {
            LeadWitness.neverGotTools(boundAt: boundAt, toolsAt: toolsAt, submittedAt: submittedAt, now: now)
        }
    }

    /// How long a worker's or verifier's tool server has, from its session's start, to ask the session host who it
    /// is (it does first thing, in seconds): one that hasn't by then never got its tools, and can neither report nor
    /// give a verdict, however long it works.
    public static let toolsWithin: TimeInterval = 5 * 60

    /// A session bound to its role `toolsWithin` ago whose tool server never asked who it is (and gave no verdict). A
    /// bind time not known (an older host) says nothing.
    public static func neverGotTools(boundAt: Double?, toolsAt: Double?, submittedAt: Double?, now: Date) -> Bool {
        guard let boundAt, toolsAt == nil, submittedAt == nil else { return false }
        return now.timeIntervalSince1970 - boundAt >= toolsWithin
    }

    /// "The verifier on a never got its tools: …", for the lead (`ended`: its session was gone already).
    static func noToolsText(_ who: String, task: LeadTask, session: String, info: Seen, ended: Bool) -> String {
        let started = (info.started ?? info.boundAt).map { ", started \(LeadBoard.clock($0))" } ?? ""
        let again = who == "worker"
            ? "start_worker(\(task.slug)) starts another in its worktree, its commits kept"
            : "audit(\(task.slug)) starts another verifier"
        return "The \(who) on \(task.slug) never got its tools: its vibeswitcher tool server didn't answer within "
            + "\(Int(toolsWithin / 60)) min of its start (session \(session.prefix(8))\(started)), so it can't \(who == "worker" ? "report" : "give a verdict"). "
            + (ended ? "Its session has ended. " : "VibeSwitcher ends its session, freeing its Mac slot. ")
            + "\(again); if that one doesn't get its tools either, tell the user (the session host or the tool server is broken) instead of starting more."
    }

    /// The live workers and verifiers that never got their tools, which VibeSwitcher ends (`events` tells each once).
    public static func withoutTools(board: LeadBoard, seen: [String: Seen], now: Date = Date()) -> [String] {
        board.tasks.flatMap { task in noToolsSessions(task, seen: seen, now: now) }.filter { seen[$0]?.live == true }
    }

    /// The task's worker (running) and awaited verifiers (in review) that never got their tools.
    private static func noToolsSessions(_ task: LeadTask, seen: [String: Seen], now: Date) -> [String] {
        var sessions: [String] = []
        if task.status == .running, let worker = task.worker, worker != task.stopped { sessions.append(worker) }
        if task.status == .review, task.evidence == nil { sessions += task.awaitedVerifiers }
        return sessions.filter { seen[$0]?.neverGotTools(now: now) == true }
    }

    /// How long a session may sit finished before it counts as stopped.
    public static let quiet: TimeInterval = 90

    /// What a verifier whose agent quit, leaving its session's shell open, is said to have ended with.
    public static let agentQuitEnding = "its agent quit; the session's shell is still open"

    /// How a verifier that gave no verdict ended, in words (what the lead is told): its session's ending, or that its
    /// agent quit with the shell left open.
    static func verifierEnding(_ info: Seen) -> String { info.live ? agentQuitEnding : info.ending }

    /// A live session's agent quit, leaving its shell open: a minute after it started (`HostSession.agentQuit`), its
    /// agent's process has exited (`HostSession.agentRuns`), by a table read whole. Not from what its terminal shows: an
    /// agent waiting on a background command runs on (2026-10-27: verifiers alive and waiting on a load run were said
    /// to have quit, and their audits started again). `agentQuitEnding` then, else nil (no table: not known).
    public static func agentQuitEnding(_ hosted: HostSession, table: [Int32: ProcInfo]?, now: Date = Date()) -> String? {
        guard hosted.agentQuit(now: now), let table, !hosted.agentRuns(in: table) else { return nil }
        return agentQuitEnding
    }

    /// How long a verifier that ended without a verdict is left to auto_advance (see `leftToAdvance`) before the lead
    /// is told as ever: its loop audits again within a pass of the app's nudge, unless the Mac has no room or the
    /// ending couldn't be read there.
    public static let advanceGrace: TimeInterval = 5 * 60

    /// The verifiers that ended without a verdict on a task that moves by itself: auto_advance audits it again once,
    /// or reports that its retry's verifier ended too (`LeadAdvance`). The app nudges the loop at the first sight of each.
    public static func endedForAdvance(board: LeadBoard, seen: [String: Seen], now: Date = Date()) -> [String] {
        board.tasks.filter { $0.status == .review && $0.evidence == nil && $0.autoAdvance != false }.flatMap { task in
            let noTools = noToolsSessions(task, seen: seen, now: now)
            return task.awaitedVerifiers.filter { verifier in
                guard !noTools.contains(verifier), let info = seen[verifier] else { return false }
                return (!info.live || info.agentQuit) && !gaveVerdict(info, on: task)
            }
        }
    }

    /// The workers auto_advance releases while their task's audit runs (see `LeadToolset.releaseWorker`), seen between
    /// turns now: a task that moves by itself, in review with its verifiers at work, whose worker (not stopped or
    /// released already) is live, finished its turn, and waits on nothing. A worker mid-turn when its audit started
    /// (it had only just reported) writes nothing in the project's folder when its turn ends: the app nudges the loop
    /// at the first sight of each, and the loop's own checks decide.
    public static func releasableForAdvance(board: LeadBoard, seen: [String: Seen]) -> [String] {
        board.tasks.compactMap { task in
            guard task.status == .review, task.evidence == nil, task.autoAdvance != false, !task.awaitedVerifiers.isEmpty,
                  let worker = task.worker, worker != task.stopped, let info = seen[worker], info.live, !info.agentQuit,
                  info.pending == nil, info.activity == .idle(background: nil) else { return nil }
            return worker
        }
    }

    /// What becomes of a running task's worker whose turn ended without a report (`notices`' stop).
    enum StopTurn: Equatable {
        /// A report call of its is under way (`LeadReportCall`): nothing to say.
        case inFlight
        /// A first stop: auto_advance nudges it (`stopsForAdvance`), the lead isn't told.
        case toNudge
        /// Handed over or nudged already, this stop not past it yet: nothing to say meanwhile.
        case nudging
        /// The lead is told, as ever: auto_advance doesn't move the task, or didn't nudge within `advanceGrace`.
        case tell
        /// Stopped again after the one nudge (sent at `sentAt`), or the nudge brought no turn within `advanceGrace`.
        case again(sentAt: Double)
    }

    /// How often the witness confirms an unsent nudge whose worker is still in that stop (`handOver`), and how recent a
    /// confirmation the loop sends on (`LeadStopNudge.fresh`): a few of the app's looks, so a pass that comes minutes
    /// late, its worker gone back to work meanwhile, sends nothing.
    public static let nudgeConfirmEvery: TimeInterval = 20
    public static let nudgeFresh: TimeInterval = 60

    /// `nudge`, not sent yet, is for the stop `info` is in now: the same stop (its status's since) the witness handed
    /// over, nothing written to its transcript since. One for an earlier stop is no record of this one: its worker went
    /// back to work (the user typed, a background command returned) and stopped again, or hasn't stopped since.
    static func sameStop(_ nudge: LeadStopNudge, _ info: Seen) -> Bool {
        guard let since = info.since, Int(since.timeIntervalSince1970) == Int(nudge.stoppedAt) else { return false }
        return (info.lastActivity ?? -.infinity) < nudge.seenAt
    }

    static func stopTurn(_ task: LeadTask, worker: String, info: Seen, now: Date, advancing: Bool) -> StopTurn {
        if task.reportCall?.inFlight(now: now) == true { return .inFlight }
        let at = now.timeIntervalSince1970
        if let nudge = task.stopNudge, nudge.worker == worker, nudge.sentAt != nil || sameStop(nudge, info) {
            if let sent = nudge.sentAt {
                // Quiet since after the nudge went in: a turn of its own ended since.
                let quietSince = max(info.since?.timeIntervalSince1970 ?? -.infinity, info.lastActivity ?? -.infinity)
                return quietSince > sent || at - sent >= advanceGrace ? .again(sentAt: sent) : .nudging
            }
            return advancing && at - nudge.seenAt < advanceGrace ? .nudging : .tell
        }
        return advancing && task.autoAdvance != false ? .toNudge : .tell
    }

    /// The lead's word on a worker's stop without a report (nil: none now, see `stopTurn`), with the last refused
    /// report call's refusal when there is one.
    static func stopText(_ task: LeadTask, worker: String, info: Seen, now: Date, advancing: Bool) -> String? {
        let job = info.diedJob.map { ": \($0.goneText)" } ?? ""
        let refused = task.reportRefused.map { " Its last report call, at \(LeadBoard.clock($0.at)), was refused: “\(LeadToolset.clip($0.text, 300))”." } ?? ""
        switch stopTurn(task, worker: worker, info: info, now: now, advancing: advancing) {
        case .inFlight, .toNudge, .nudging: return nil
        case .tell:
            return "The worker on \(task.slug) stopped without calling report\(job).\(refused) read_session to see where it is, then message it."
        case .again(let sent):
            return "The worker on \(task.slug) stopped without calling report again\(job). auto_advance already sent it its one nudge at "
                + "\(LeadBoard.clock(sent)) (report done or blocked, and stay until the report answers), and no report has come since.\(refused) "
                + "read_session to see where it is, then message it."
        }
    }

    /// A worker's stop auto_advance nudges (see `LeadStopNudge`).
    public struct StopForAdvance: Equatable, Sendable {
        public var slug: String
        public var worker: String
        /// When its turn ended (its status's since).
        public var stoppedAt: Double
        /// The background job its turn waited on is gone, in words (`TranscriptTail.Background.goneText`).
        public var job: String?
        /// Its turn showed as waiting on a background task or shell (see `LeadStopNudge.background`).
        public var background = false
        /// The stop its unsent record is for, still (`sameStop`): `handOver` confirms that record rather than replacing it.
        public var confirming = false
    }

    /// The running tasks' workers stopped without a report for the first time, which the lead's loop nudges instead
    /// of the lead being woken (`stopTurn`'s `toNudge`): the stop `notices` would tell, with no report call under way,
    /// on a task that moves by itself. Not one waiting on a prompt, at a usage limit, on an API error, or on a
    /// teammate's answer: those keep their own notices. The app records each on the board (`LeadStopNudge`) and
    /// nudges the loop.
    public static func stopsForAdvance(board: LeadBoard, seen: [String: Seen], now: Date = Date()) -> [StopForAdvance] {
        board.tasks.compactMap { task in
            guard task.status == .running, let worker = task.worker, worker != task.stopped, let info = seen[worker],
                  info.live, !info.agentQuit, info.usageLimit == nil, info.apiError == nil,
                  !noToolsSessions(task, seen: seen, now: now).contains(worker),
                  task.peerWait(session: worker, now: now.timeIntervalSince1970) == nil,
                  let event = waiting(info, session: worker, now: now, input: "", stopped: ""), event.key.contains("|stopped-") else { return nil }
            let confirming: Bool
            switch stopTurn(task, worker: worker, info: info, now: now, advancing: true) {
            case .toNudge: confirming = false
            // Handed over, not sent yet, and still that stop: confirmed again for the loop (`handOver`).
            case .nudging where task.stopNudge?.sentAt == nil: confirming = true
            default: return nil
            }
            var background = info.diedJob != nil || !info.shells.isEmpty
            if case .idle(_?)? = info.activity { background = true }
            return StopForAdvance(slug: task.slug, worker: worker, stoppedAt: info.since?.timeIntervalSince1970 ?? now.timeIntervalSince1970,
                                  job: info.diedJob?.goneText, background: background, confirming: confirming)
        }
    }

    /// Records each of `stops` on its task for the lead's loop to nudge (`LeadStopNudge`), unless its worker was nudged
    /// already (once) or the task moved on meanwhile. A stop recorded and not sent yet is confirmed (`confirmedAt`) every
    /// `nudgeConfirmEvery` while its worker is still in it, and one for an earlier stop is replaced: the loop sends only
    /// on a recent confirmation. Whether anything was written (the board's write makes the loop look).
    @discardableResult
    public static func handOver(_ stops: [StopForAdvance], on board: inout LeadBoard, now: Date = Date()) -> Bool {
        var recorded = false
        let at = now.timeIntervalSince1970
        for stop in stops {
            guard let index = board.taskIndex(stop.slug), board.tasks[index].status == .running, board.tasks[index].worker == stop.worker else { continue }
            if var nudge = board.tasks[index].stopNudge, nudge.worker == stop.worker {
                guard nudge.sentAt == nil else { continue }
                // Only the stop it's for (`sameStop`): one with the same since but written to after the hand-over is a
                // new stop, replaced below, or the record would be neither sent (never fresh) nor told (blind check).
                if stop.confirming, Int(nudge.stoppedAt) == Int(stop.stoppedAt) {
                    guard at - (nudge.confirmedAt ?? nudge.seenAt) >= nudgeConfirmEvery else { continue }
                    nudge.confirmedAt = at
                    board.tasks[index].stopNudge = nudge
                    recorded = true
                    continue
                }
            }
            board.tasks[index].stopNudge = LeadStopNudge(worker: stop.worker, stoppedAt: stop.stoppedAt, seenAt: at, job: stop.job,
                                                         background: stop.background, confirmedAt: at)
            recorded = true
        }
        return recorded
    }

    /// Of `endedForAdvance`, those `events` leaves to the loop while it runs (the app's `firstSeen`: when it first saw
    /// each so): its report told of it already (the retry's verifier, which ended too), or it was seen less than
    /// `advanceGrace` ago. Past that with no retry (the verifier still awaited), the lead is told as ever.
    public static func leftToAdvance(board: LeadBoard, seen: [String: Seen], now: Date = Date(), firstSeen: [String: Date]) -> Set<String> {
        Set(endedForAdvance(board: board, seen: seen, now: now).filter { verifier in
            let task = board.tasks.first { $0.awaitedVerifiers.contains(verifier) }
            if let retry = task?.verifierRetry, retry.second != nil, retry.verifiers.contains(verifier) { return true }
            return firstSeen[verifier].map { now.timeIntervalSince($0) < advanceGrace } ?? true
        })
    }

    /// `advanced`: the verifiers left to auto_advance (see `leftToAdvance`), not told here.
    /// `advancing`: the lead's loop runs with auto_advance on, so a worker's first stop without a report is its to
    /// nudge (`stopsForAdvance`), not told here.
    public static func events(board: LeadBoard, seen: [String: Seen], now: Date = Date(), advanced: Set<String> = [],
                              advancing: Bool = false) -> [(key: String, text: String)] {
        notices(board: board, seen: seen, now: now, advanced: advanced, advancing: advancing).map { ($0.key, $0.text()) }
    }

    /// An event to tell, its text built only when read (`text()`): a waiting session's quotes what it waits for in
    /// full, credentials masked (`PendingPrompt.quoted`), which took up to a second on the main thread a refresh
    /// (hang-20261027-201145) for events told long before.
    public typealias Notice = (key: String, text: @Sendable () -> String)

    /// `events`, their texts not built yet.
    public static func notices(board: LeadBoard, seen: [String: Seen], now: Date = Date(), advanced: Set<String> = [],
                               advancing: Bool = false) -> [Notice] {
        var events: [Notice] = []
        func add(_ key: String, _ text: @autoclosure @escaping @Sendable () -> String) { events.append((key, text)) }
        for task in board.tasks where task.status != .done {
            // One whose tools never connected is told so, once, and nothing else of it is (its end is VibeSwitcher's).
            let noTools = noToolsSessions(task, seen: seen, now: now)
            for session in noTools {
                guard let info = seen[session] else { continue }
                let who = session == task.worker ? "worker" : "verifier"
                add("\(session)|no-tools", noToolsText(who, task: task, session: session, info: info, ended: !info.live))
            }
            // A worker the lead stopped itself ended because it was told to.
            if let worker = task.worker, worker != task.stopped, !noTools.contains(worker), let info = seen[worker] {
                if !info.live, [.running, .failed].contains(task.status) {
                    add("\(worker)|ended", "The worker on \(task.slug) ended (\(info.ending)) without reporting. Its commits are on agent/\(task.slug); read_session to see why, then start_worker(\(task.slug)) starts it again where it was (the task needn't be set to blocked first), or re-plan.")
                } else if info.live, info.agentQuit, [.running, .failed].contains(task.status) {
                    add("\(worker)|ended", "The worker on \(task.slug) ended without reporting: its agent quit and left the session's shell open. Its commits are on agent/\(task.slug); read_session to see why, then stop_worker (it closes the shell) and start_worker again, or re-plan.")
                } else if info.live, !info.agentQuit, let limit = info.usageLimit, [.running, .failed].contains(task.status) {
                    add(usageLimitKey(worker, limit), "The worker on \(task.slug) stopped at the account's usage limit: \(limitText(limit)). "
                        + "It does nothing until then; its work so far is on agent/\(task.slug). Tell the user; after the reset, message(\(task.slug), …) tells it to go on where it was.")
                } else if info.live, !info.agentQuit, let error = info.apiError, [.running, .failed].contains(task.status) {
                    add("\(worker)|api-error-\(Int(info.apiErrorAt ?? 0))", "The worker on \(task.slug) stopped mid-task: its turn ended on an API error (\(error)). Tell it to go on with message(\(task.slug), …); it picks up where it was.")
                    // A turn ended on a question to a teammate, within its deadline, is what the wall asks (it
                    // shows as "waiting on @x"); past it, the usual notice (T9).
                } else if info.live, !info.agentQuit, let event = waiting(info, session: worker, now: now,
                                                         input: waitingText("The worker on \(task.slug)", info, now: now, advice: "Answer it with message, or ask the user if it's theirs to decide."),
                                                         stopped: task.status == .running && task.peerWait(session: worker, now: now.timeIntervalSince1970) == nil
                                                            ? stopText(task, worker: worker, info: info, now: now, advancing: advancing) : nil) {
                    events.append(event)
                }
                // A report call of its under way (its check waiting for a slot, then running) is no stall either.
                if info.live, task.reportCall?.inFlight(now: now) != true {
                    for stall in LeadStall.detect(info, task: task, now: now, waitingOn: task.peerWait(session: worker, now: now.timeIntervalSince1970)) where !stall.heldBack {
                        // A job of its own that's alive is labelled so, not as a stall needing the lead.
                        add(stall.key(session: worker), "The worker on \(task.slug) is \(stall.report(now: now)). \(stall.waitsOnOwnJob ? "If that shell isn't what it's waiting for, read_session(\(task.slug)) or message it." : stall.advice(slug: task.slug))")
                    }
                }
            }
            events += memberNotices(task, seen: seen, now: now)
            // With several finders, each that hasn't submitted yet.
            for verifier in task.status == .review && task.evidence == nil ? task.awaitedVerifiers : [] {
                guard !noTools.contains(verifier), !advanced.contains(verifier), let info = seen[verifier], !gaveVerdict(info, on: task) else { continue }
                if info.live, !info.agentQuit, let limit = info.usageLimit {
                    // Fable's alone: the next audit goes on another model (`LeadToolset.auditModel`), no wait for the reset.
                    let fable = LeadUsageFallback.fableOnly(limit, model: LeadUsageFallback.launchedModel(task, verifier))
                    add(usageLimitKey(verifier, limit), "The verifier on \(task.slug) stopped mid-audit at the account's usage limit: \(limitText(limit)). "
                        + (fable ? "It gives no verdict. Fable is held back until then, so audit(\(task.slug)) again now: it starts on another model."
                            : "It gives no verdict until then. Tell the user; audit(\(task.slug)) again after the reset."))
                } else if info.live, !info.agentQuit, let error = info.apiError {
                    add("\(verifier)|api-error-\(Int(info.apiErrorAt ?? 0))", "The verifier on \(task.slug) stopped mid-audit: its turn ended on an API error (\(error)). Tell the user, or audit again.")
                } else if !info.live || info.agentQuit {
                    add("\(verifier)|ended", "The verifier on \(task.slug) ended without a verdict (\(verifierEnding(info))). read_session(\(task.slug), who: verifier) to see why, then audit again.")
                } else if info.status == .needsInput {
                    // Waiting on a prompt: told once it's waited `promptWait`, with what VibeSwitcher did about it
                    // (`stuckPrompts`). Told now, the lead could only start the audit again, the finders' work lost.
                } else if let event = waiting(info, session: verifier, now: now,
                                              input: waitingText("The verifier on \(task.slug)", info, now: now, advice: "Tell the user if it's theirs, or audit again."),
                                              stopped: "The verifier on \(task.slug) stopped without calling submit_audit. read_session(\(task.slug), who: verifier) to see why, then audit again.") {
                    events.append(event)
                }
            }
        }
        return events
    }

    /// A team task's members other than its integrator, watched as its worker is (`notices`), each named, while they're
    /// at work (`LeadTask.deadlinesRun`: running, or blocked on the lead with its members still going): one whose agent
    /// quit and left its shell open, waiting for input, stopped between turns outside a wait on a teammate's answer
    /// (`LeadTeamMember.waits`), stopped at the usage limit or on an API error, or stalled (`LeadStall.detect`). Not once
    /// its part is done (`LeadTeam.partDone`): it waits on the integrator then. A member whose session is gone is told by
    /// `endedMembers`. All of it goes to the lead; nothing here is typed into the member.
    static func memberNotices(_ task: LeadTask, seen: [String: Seen], now: Date) -> [Notice] {
        guard task.deadlinesRun else { return [] }
        // Its stalls are read as a running task's: blocked on the lead is the integrator's state, not its members'.
        var atWork = task
        atWork.status = .running
        var events: [Notice] = []
        func add(_ key: String, _ text: @autoclosure @escaping @Sendable () -> String) { events.append((key, text)) }
        for (member, session) in task.memberSessions where session != task.stopped && !LeadTeam.partDone(task, member: member.name) {
            guard let info = seen[session], info.live else { continue }
            let (slug, name, branch) = (task.slug, member.name, member.branch)
            let who = "Member \(name) of \(slug)'s team"
            let tell = "message(\(slug), …, member: \(name))"
            // Its shell still open, its session counts as live, so `endedMembers` doesn't see it and start_worker
            // doesn't start it again: told here. Its own key, not "|ended": `unbuiltMessages` gathers those into one
            // message from `endings`, which has no line for a member, so two members quitting at once were told by no one.
            if info.agentQuit {
                add("\(session)|member-ended", "\(who) ended without saying its part is done: its agent quit and left the session's shell open. "
                    + "Its commits are on \(branch). Ask the user to close that session, then start_worker(\(slug)) starts the member again where it was; "
                    + "or stop_worker(\(slug)) ends the whole team and start_worker(\(slug)) starts it again.")
                continue
            }
            let wait = task.peerWait(member: name, now: now.timeIntervalSince1970)
            if let limit = info.usageLimit {
                add(usageLimitKey(session, limit), "\(who) stopped at the account's usage limit: \(limitText(limit)). "
                    + "It does nothing until then; its work so far is on \(branch). Tell the user; after the reset, \(tell) tells it to go on where it was.")
            } else if let error = info.apiError {
                add("\(session)|api-error-\(Int(info.apiErrorAt ?? 0))", "\(who) stopped mid-part: its turn ended on an API error (\(error)). Tell it to go on with \(tell); it picks up where it was.")
            } else if let event = waiting(info, session: session, now: now,
                                          input: waitingText(who, info, now: now, advice: "Answer it with \(tell), or ask the user if it's theirs to decide."),
                                          stopped: wait == nil ? "\(who) stopped without saying its part is done\(info.diedJob.map { ": \($0.goneText)" } ?? ""). Ask it where it is with \(tell)." : nil) {
                events.append(event)
            }
            for stall in LeadStall.detect(info, task: atWork, now: now, waitingOn: wait) where !stall.heldBack {
                add(stall.key(session: session), "\(who) is \(stall.report(now: now)). \(stall.waitsOnOwnJob ? "If that shell isn't what it's waiting for, ask it with \(tell)." : stall.advice(slug: slug, member: name))")
            }
        }
        return events
    }

    /// A verifier (or a finder) waiting on a prompt no one answers (see `stuckPrompts`).
    public struct StuckPrompt: Equatable, Sendable {
        /// The event key it's told by, once: the one its waiting notice had ("<session>|input-<since>").
        public var key: String
        public var session: String
        public var slug: String
        public var prompt: PendingPrompt

        public init(key: String, session: String, slug: String, prompt: PendingPrompt) {
            self.key = key
            self.session = session
            self.slug = slug
            self.prompt = prompt
        }
    }

    /// How long a verifier waits on a prompt before VibeSwitcher declines it: time for a user who's watching to answer.
    public static let promptWait: TimeInterval = 120

    /// What a declined verifier prompt tells the verifier (typed as the prompt's "No" reason): what it can do instead.
    public static let declineReason = "No one answers verifier prompts: use only read-only commands, or report what you couldn't check."

    /// The awaited verifiers (and finders) that have waited on a prompt for `promptWait` or longer. No one answers
    /// one (the user doesn't see its session; the lead can't answer it), and on 2026-10-31 and 2026-11-01 two audits
    /// hung so until the lead started them again, the finders' work lost. The app declines each permission prompt with
    /// `declineReason` (`declinePlan`) and tells the lead once what was asked (`declinedText`), or that it couldn't
    /// (`undeclinedText`); `events` tells nothing of them meanwhile.
    public static func stuckPrompts(board: LeadBoard, seen: [String: Seen], now: Date = Date(), advanced: Set<String> = []) -> [StuckPrompt] {
        var stuck: [StuckPrompt] = []
        for task in board.tasks where task.status == .review && task.evidence == nil {
            let noTools = noToolsSessions(task, seen: seen, now: now)
            for verifier in task.awaitedVerifiers {
                guard !noTools.contains(verifier), !advanced.contains(verifier), let info = seen[verifier], !gaveVerdict(info, on: task),
                      info.live, !info.agentQuit, info.usageLimit == nil, info.apiError == nil, info.status == .needsInput,
                      let since = info.since, now.timeIntervalSince(since) >= promptWait else { continue }
                stuck.append(StuckPrompt(key: "\(verifier)|input-\(Int(since.timeIntervalSince1970))", session: verifier,
                                         slug: task.slug, prompt: info.prompt))
            }
        }
        return stuck
    }

    /// How the app declines a stuck prompt (`declinePlan`): the menu as it was read, its No row, the stuck command as
    /// the screen must show it, and the keys (arrows to No, Tab to open its text field, the reason, Enter), each
    /// checked against the screen before it goes (`declineMayGo`).
    public struct DeclinePlan: Equatable, Sendable {
        public var menu: ScreenMenu
        public var no: Int
        /// The stuck prompt's command, squashed (`squashed`): the screen shows that prompt only while it holds it.
        public var command: String
        /// Whether a Tab goes before the reason: the No row read a plain "No" (Claude Code 2.1.316's, see `amendKey`).
        public var amend: Bool
        public var writes: [HostInput.Write]
        /// Esc, when the No row took no reason: it rejects the prompt (never approves), whichever row the cursor is on.
        public static let escape = HostInput.Write(bytes: [27], delay: 0)
    }

    /// The plan for declining `prompt` (a stuck Bash prompt's "Run: <command>", or a file tool's "Allow: Read <name>")
    /// on `screen`, with `declineReason`. Nil unless the screen shows that command or file (`commandKey`) over a
    /// permission prompt ("Do you want to …?" over Yes … No): a question isn't answered, and a prompt opened since
    /// (the one waited on was answered meanwhile) isn't declined. A file tool's prompt is the same menu in Claude Code
    /// 2.1.318 (read in its bundle, not captured: "Read file", the call, "Do you want to proceed?", Yes, "Yes, allow
    /// reading from <folder>/ during this session", a plain No that Tab opens). The one auto mode shows for its first
    /// read outside the working directories ("Allow this read outside the working directories?", with a row that
    /// blocks such reads in every project) isn't one: nothing is typed there, and the lead is told it waits.
    public static func declinePlan(screen: String, prompt: PendingPrompt) -> DeclinePlan? {
        guard let command = commandKey(prompt), squashed(screen).contains(command), let menu = permissionMenu(screen),
              let no = menu.options.lastIndex(where: { $0 == "No" || $0.hasPrefix("No,") || $0.hasPrefix("No ") }) else { return nil }
        let arrow: [UInt8] = no > menu.selected ? [27, 91, 66] : [27, 91, 65]
        var writes = (0..<abs(no - menu.selected)).map { HostInput.Write(bytes: arrow, delay: $0 == 0 ? 0 : 0.03) }
        let amend = squashed(menu.options[no]) == "No"
        if amend { writes.append(HostInput.Write(bytes: amendKey, delay: 0.08)) }
        writes.append(HostInput.Write(bytes: Array(declineReason.utf8), delay: 0.08))
        writes.append(HostInput.Write(bytes: [13], delay: 0.08))
        return DeclinePlan(menu: menu, no: no, command: command, amend: amend, writes: writes)
    }

    /// Tab: in Claude Code 2.1.316 the Bash prompt's No row is a plain "No" until Tab ("Tab to amend") turns it into a
    /// text field (placeholder "and tell Claude what to do differently"). Before that, typed letters are the menu's
    /// keys: j and k move the cursor (the "k" in "check" goes up a row), so the reason never arrives. In the bundle:
    /// the permission menu pushes `{type:"input",label:"No",placeholder:"and tell Claude what to do differently"}`
    /// only while `noInputMode` (the hook's `rejectInputMode`, false at first, flipped by `handleInputModeToggle`), and
    /// the Select's key handler calls `onInputModeToggle(focused)` on `key === "tab"`; its keybindings map j and k to
    /// select:next and select:previous.
    public static let amendKey: [UInt8] = [9]

    /// The placeholder Claude Code 2.1.316's No row shows once Tab opened its text field, squashed. The Bash prompt's
    /// menu has `inlineDescriptions` on, which its Select passes each row as `showLabel`: the open field is drawn after
    /// its label and ", ", so the row reads "No, and tell Claude what to do differently" (`amendOpen`).
    static let amendPlaceholder = squashed("and tell Claude what to do differently")

    /// Whether the No row (squashed) shows its text field open and empty: the placeholder, after "No," or alone.
    static func amendOpen(_ row: String) -> Bool {
        (row.hasPrefix("No,") ? String(row.dropFirst(3)) : row).hasPrefix(amendPlaceholder)
    }

    /// Whether the plan's write `step` may go, by the screen now: the same prompt (its command, question and rows),
    /// and the cursor where the keys so far put it. Tab goes only on the No row still a plain "No"; the reason only
    /// once that row shows its text field (Tab opened it); Enter only on the No row showing the reason typed in. A No
    /// row Tab didn't open, or keys taken as moves, stop it short (Esc then), and never end on a Yes row.
    public static func declineMayGo(_ plan: DeclinePlan, step: Int, screen: String) -> Bool {
        guard squashed(screen).contains(plan.command), let menu = permissionMenu(screen), menu.question == plan.menu.question,
              menu.options.count == plan.menu.options.count,
              menu.options.indices.allSatisfy({ $0 == plan.no || menu.options[$0] == plan.menu.options[$0] }) else { return false }
        let arrows = abs(plan.no - plan.menu.selected)
        if step < arrows {
            return menu.selected == plan.menu.selected + (plan.no > plan.menu.selected ? step : -step)
                && menu.options[plan.no] == plan.menu.options[plan.no]
        }
        let row = squashed(menu.options[plan.no])
        if plan.amend && step == arrows { return menu.selected == plan.no && row == "No" }
        let typing = arrows + (plan.amend ? 1 : 0)
        if step == typing { return menu.selected == plan.no && (!plan.amend || amendOpen(row)) }
        return menu.selected == plan.no && row.contains(squashed(String(declineReason.prefix(24))))
    }

    /// Whether Esc may go after a decline stopped short: the stuck command's prompt still shows.
    public static func escapeMayGo(_ plan: DeclinePlan, screen: String) -> Bool {
        squashed(screen).contains(plan.command) && permissionMenu(screen)?.question == plan.menu.question
    }

    /// The permission prompt on `screen`: "Do you want to …?" over a single choice that starts with Yes.
    static func permissionMenu(_ screen: String) -> ScreenMenu? {
        guard let menu = ScreenMenu.parse(Platform.lines(screen)), !menu.picker, !menu.commands, menu.tabs.isEmpty,
              !menu.multiSelect, menu.question.contains("Do you want to"), menu.options.first?.hasPrefix("Yes") == true else { return nil }
        return menu
    }

    /// What the screen must show of a stuck prompt, squashed. A Bash prompt's ("Run: <command>"): the command's first
    /// line, at most 48 characters (a long one wraps or is cut on screen). A file tool's ("Allow: Read <name>" over
    /// its input, `PendingPrompt.text`): the file's name, its last 48 characters, which the prompt shows in the call
    /// it asks about ("Read(<path>)") however it spells the folders before it. On 2026-11-05 a verifier's Read of an
    /// evidence screenshot had no key, so its prompt was never declined and three audits hung on it. Nil for
    /// anything else (a question, a tool with no file): nothing is typed.
    static func commandKey(_ prompt: PendingPrompt) -> String? {
        if prompt.text.hasPrefix("Run: ") {
            let first = prompt.text.dropFirst(5).split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            let key = String(squashed(first).prefix(48))
            return key.isEmpty ? nil : key
        }
        guard prompt.text.hasPrefix("Allow: "), let input = prompt.text.firstIndex(of: "\n").map({ prompt.text[prompt.text.index(after: $0)...] }),
              let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
              let path = object["file_path"] as? String ?? object["notebook_path"] as? String else { return nil }
        let key = String(squashed((path as NSString).lastPathComponent).suffix(48))
        return key.isEmpty ? nil : key
    }

    /// `text` without spaces, line breaks and box drawing: a wrapped line reads as one.
    static func squashed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !(0x2500...0x257F).contains($0.value) }
            .map(Character.init))
    }

    /// "The verifier on a waited 2 min on a permission prompt no one answers: “Run: git config …”. VibeSwitcher
    /// declined it, telling it …", for the lead.
    public static func declinedText(_ stuck: StuckPrompt, now: Date = Date()) -> String {
        "The verifier on \(stuck.slug) waited \(waitedText(stuck, now: now)) on a permission prompt no one answers\(asked(stuck.prompt)) "
            + "VibeSwitcher declined it, telling it: “\(declineReason)” Its audit goes on; its report says what it couldn't check. "
            + "If that command is one verifiers need, tell the user."
    }

    /// For a prompt VibeSwitcher declined with Esc (its No row took no reason), for the lead.
    public static func escapedText(_ stuck: StuckPrompt, now: Date = Date()) -> String {
        "The verifier on \(stuck.slug) waited \(waitedText(stuck, now: now)) on a permission prompt no one answers\(asked(stuck.prompt)) "
            + "VibeSwitcher declined it with Esc (its No row took no reason), so the verifier's turn stopped there. "
            + "Audit again if it doesn't go on; if that command is one verifiers need, tell the user."
    }

    /// For a prompt VibeSwitcher couldn't decline (no permission prompt on its screen: a question, or the screen
    /// unread), for the lead: what it waits on.
    public static func undeclinedText(_ stuck: StuckPrompt, now: Date = Date()) -> String {
        "The verifier on \(stuck.slug) has waited \(waitedText(stuck, now: now)) for input no one answers\(asked(stuck.prompt)) "
            + "VibeSwitcher couldn't decline it (that prompt isn't on its screen, or it changed while the keys went in). "
            + "Tell the user if it's theirs, or audit again."
    }

    private static func waitedText(_ stuck: StuckPrompt, now: Date) -> String {
        LeadToolset.age(now.timeIntervalSince1970 - (stuck.prompt.since ?? now.timeIntervalSince1970))
    }

    /// ": “Run: ls”." inline, or ". It waited on:" and a fenced block for a long one (`PendingPrompt.quoted`).
    private static func asked(_ prompt: PendingPrompt) -> String {
        let quoted = prompt.quoted
        return quoted.hasPrefix("“") ? ": \(quoted)." : ". It waited on:\n\(quoted)\n"
    }

    /// A usage-limit stop is told once: by its session and when the line was written.
    static func usageLimitKey(_ session: String, _ limit: UsageLimit) -> String {
        "\(session)|usage-limit-\(Int(limit.at ?? limit.resetsAt ?? 0))"
    }

    /// "Claude said “You've hit your weekly limit · …”, and it resets Nov 3, 01:00".
    private static func limitText(_ limit: UsageLimit) -> String {
        "Claude said “\(limit.said)”" + (limit.resetText.map { ", and it resets \($0)" } ?? ", and the reset time isn't known")
    }

    /// What to tell the lead: the `events` not `told` yet, as they are, except that sessions that ended without
    /// reporting are told together, in one message naming each task and how it ended (a stray kill ends many at
    /// once). Each message carries the keys of the events it tells.
    public static func messages(board: LeadBoard, seen: [String: Seen], now: Date = Date(), advanced: Set<String> = [],
                                told: (String) -> Bool) -> [(keys: [String], text: String)] {
        unbuiltMessages(board: board, seen: seen, now: now, advanced: advanced, told: told).map { ($0.keys, $0.text()) }
    }

    /// `messages`, their texts built only when read (see `Notice`): the app builds them off the main thread.
    public static func unbuiltMessages(board: LeadBoard, seen: [String: Seen], now: Date = Date(), advanced: Set<String> = [],
                                       advancing: Bool = false, told: (String) -> Bool) -> [(keys: [String], text: @Sendable () -> String)] {
        let fresh = notices(board: board, seen: seen, now: now, advanced: advanced, advancing: advancing).filter { !told($0.key) }
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
        return [(lines.map(\.key), { text })] + fresh.filter { !ended.contains($0.key) }.map { ([$0.key], $0.text) }
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
            guard let worker = task.worker, worker != task.stopped, let info = seen[worker], !info.neverGotTools(now: now),
                  task.reportCall?.inFlight(now: now) != true,
                  let stall = LeadStall.detect(info, task: task, now: now, waitingOn: task.peerWait(session: worker, now: now.timeIntervalSince1970)).first
                    ?? LeadStall.awaitingPrompt(info, task: task, now: now) else { continue }
            found[task.id] = stall
        }
        return found
    }

    /// The members of running team tasks, other than the integrator (whose end `notices` tells as the task's worker's),
    /// whose worker's session is gone (not in `live`) before the member said its part is done (`LeadTeam.partDone`),
    /// not told yet (`LeadTeamMember.endTold`). auto_advance doesn't start such a member again; start_worker(slug) does.
    /// Only while its integrator runs: stop_worker ends the integrator first, then its members, and the integrator's
    /// own end is told as the task's worker's (`notices`).
    public static func endedMembers(board: LeadBoard, live: Set<String>) -> [(slug: String, member: String, worker: String)] {
        var ended: [(slug: String, member: String, worker: String)] = []
        for task in board.tasks where task.status == .running && task.isTeam {
            guard let integrator = task.worker, integrator != task.stopped, live.contains(integrator) else { continue }
            for member in (task.team ?? []).dropFirst() {
                guard let worker = member.worker, !live.contains(worker), member.endTold != worker, !LeadTeam.partDone(task, member: member.name) else { continue }
                ended.append((task.slug, member.name, worker))
            }
        }
        return ended
    }

    /// What the lead is told of a member `endedMembers` found.
    static func endedMemberText(slug: String, member: String) -> String {
        "Member \(member) of \(slug)'s team ended (its session is gone) without saying its part is done. auto_advance doesn't start it again: "
            + "start_worker(\(slug)) starts it again on agent/\(slug)\(LeadTeam.joiner)\(member), in its worktree, its commits kept."
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
    /// `TestLock.longAfter` is told to its owner once per holder. Unowned runs go only to projects queued behind them.
    public struct HeavySlots {
        let lock: TestLock?
        /// The long holders told, by slot, note and since: one that's let go is forgotten.
        public private(set) var told: Set<String> = []
        private var toldTo: [String: Set<String>] = [:]

        public init(lock: TestLock? = TestLock.standard()) { self.lock = lock }

        /// What to tell the leads now, if anything.
        public mutating func look(now: Date = Date()) -> String? {
            let new = newHolders(now: now)
            return new.isEmpty ? nil : LeadWitness.longSlotText(new, now: now)
        }

        /// Only the owning project can act on its run. A bare run is relevant to its queued waiters.
        public mutating func look(roots: Set<String>, now: Date = Date()) -> [String: String] {
            guard let lock else { return [:] }
            let holders = lock.holders().filter { $0.isLong(now: now) }
            let keys = Set(holders.map(Self.key))
            let waiters = lock.waiters()
            var out: [String: String] = [:]
            for root in roots {
                var sent = (toldTo[root] ?? []).intersection(keys)
                let fresh = holders.filter { !sent.contains(Self.key($0)) }
                let reports = Self.reports(holders: fresh, waiters: waiters, roots: [root], now: now)
                if let text = reports[root] {
                    out[root] = text
                    // Mark only the holders routed to this root, so a later waiter still hears about a bare run.
                    for holder in fresh where !Self.reports(holders: [holder], waiters: waiters, roots: [root], now: now).isEmpty {
                        sent.insert(Self.key(holder))
                    }
                }
                toldTo[root] = sent
            }
            return out
        }

        public static func reports(holders: [TestLock.Holder], waiters: [TestLock.Waiter], roots: Set<String>, now: Date,
                                   isRepository: (String) -> Bool = LoadStats.isRepository) -> [String: String] {
            func belongs(_ holder: TestLock.Holder, to root: String) -> Bool {
                if let directory = holder.directory {
                    return directory == root || directory.hasPrefix(root + "/")
                }
                return holder.project == TestLock.whose(root).project
            }
            var reports: [String: String] = [:]
            for root in roots {
                let relevant = holders.filter { holder in
                    // vs-heavy records PWD's basename as "project" even outside a repository.
                    let owned = roots.contains { belongs(holder, to: $0) }
                        || (holder.directory.map { LoadStats.project(ofFolder: $0, isRepository: isRepository) != nil } ?? (holder.project != nil))
                    if owned { return belongs(holder, to: root) }
                    return waiters.contains { $0.slots >= holder.slot && belongs($0.who, to: root) }
                }
                if !relevant.isEmpty { reports[root] = LeadWitness.longSlotText(relevant, now: now) }
            }
            return reports
        }

        private static func key(_ holder: TestLock.Holder) -> String {
            "\(holder.slot)|\(holder.note ?? "")|\(holder.since?.timeIntervalSince1970 ?? 0)"
        }

        private mutating func newHolders(now: Date) -> [TestLock.Holder] {
            guard let lock else { return [] }
            let long = lock.holders().filter { $0.isLong(now: now) }
            let keyed = long.map { (holder: $0, key: Self.key($0)) }
            told.formIntersection(keyed.map(\.key))
            let new = keyed.filter { !told.contains($0.key) }
            told.formUnion(new.map(\.key))
            return new.map(\.holder)
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

    private static func waiting(_ info: Seen, session: String, now: Date, input: @autoclosure @escaping @Sendable () -> String,
                                stopped: String?) -> Notice? {
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
        return now.timeIntervalSince1970 - quietSince > quiet ? ("\(session)|stopped-\(since)", { stopped }) : nil
    }
}

extension LeadWitness {
    /// The leads whose start_worker, audit or merge was refused for the Mac's room or load (see `MacLimits`), each
    /// woken once when there's room again, whichever project's sessions ended to make it. The refusal tells the lead
    /// not to poll; before this nothing woke it when another project's sessions ended, so leads slept and polled
    /// (project-c's on 10-23 and 10-24). Each refusal is a file of its own in `folder`, written by the lead's tool server;
    /// the app looks once a minute (`look`) and removes the ones it told, so a refusal written meanwhile isn't lost.
    public struct RoomWaits {
        /// One refused call.
        public struct Wait: Codable, Equatable, Sendable {
            /// The project's root.
            public var root: String
            /// What was refused, as the lead would call it again: "start_worker(one)".
            public var what: String
            /// The team sessions it needs room for (a worker 1, an audit its finders); 0: only the load (merge).
            public var need: Int
            /// When it was refused (seconds since 1970).
            public var at: Double
            /// Refused to VibeSwitcher's own automatic step (see `LeadAdvance`), not to the lead: once there's room,
            /// the lead's tool server is nudged to try again, and the lead isn't told.
            public var auto: Bool?
        }

        public let folder: URL

        public static var folder: URL { VibePaths.root.appendingPathComponent("room-waits") }
        /// A wait this old is dropped untold: its lead has moved on, or ended.
        public static let expiry: TimeInterval = 12 * 3600

        /// The sleep ledger reader, injected by tests to check which thread takes its lock and reads its file.
        var pendingSleep: (String) -> Bool = { root in
            (try? LeadSleepRecovery.Store(root: root).pending().isEmpty) == false
        }

        public init(folder: URL = RoomWaits.folder) { self.folder = folder }

        /// Keeps a refusal for the lead of `root` until there's room for it.
        public func record(root: String, what: String, need: Int, auto: Bool = false, now: Date = Date()) {
            let wait = Wait(root: (root as NSString).standardizingPath, what: what, need: max(0, need), at: now.timeIntervalSince1970,
                            auto: auto ? true : nil)
            guard let data = try? JSONEncoder().encode(wait) else { return }
            try? VibePaths.ensurePrivate(folder)
            try? VibePaths.writePrivate(data, to: folder.appendingPathComponent(UUID().uuidString + ".json"))
        }

        /// The waits kept now, with their files.
        func waits() -> [(file: URL, wait: Wait)] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }.compactMap { file in
                (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Wait.self, from: $0) }.map { (file, $0) }
            }
        }

        /// What to tell each refused lead now that the Mac has room, one message per project: the waits `mac` has
        /// room for under `limits` (the load, `MacLoad.Averages.steady`, not over load_threshold, and with a wait's sessions the team
        /// sessions within mac_max_sessions and the Mac not short of memory, `MacMemory.shortage`). Those told are removed; the rest stay until there's room for them too.
        /// A project whose automatic steps were refused is nudged (`LeadAdvance.nudge`) instead: its lead's tool server
        /// tries them again, and only the lead's own refusals are told.
        /// While boosted, the room is shared out in turn instead (`Self.inTurn`): the project the user last worked in
        /// (`BoostState.favored`) first, then the rest by when they were refused, each wait only while the sessions
        /// woken before it leave room for it.
        public func look(mac: MacLoad, limits: MacLimits, now: Date = Date()) -> [(root: String, text: String)] {
            var due: [String: [Wait]] = [:]
            var kept: [(file: URL, wait: Wait)] = []
            for (file, wait) in waits() {
                // A sleep interruption stays pending through a long battery/load hold, even overnight.
                if now.timeIntervalSince1970 - wait.at > Self.expiry
                    && !(wait.auto == true && wait.what == LeadSleepRecovery.retryWait && pendingSleep(wait.root)) {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                kept.append((file, wait))
            }
            let favored = limits.boost?.favored
            if favored != nil { kept = Self.inTurn(kept, favored: favored) }
            // The sessions the waits woken so far will start, and the room kept for the favored project's first wait
            // when it doesn't fit yet (as `heldFor` keeps it from start_worker and audit).
            var woken = 0
            var keptFor = false
            for (file, wait) in kept {
                var room = mac
                if favored != nil, woken > 0 { room.holders.append(Holder(project: "", sessions: woken)) }
                guard Self.hasRoom(for: wait, mac: room, limits: limits) else {
                    if favored != nil, !keptFor, wait.need > 0, Self.isProject(wait.root, favored) {
                        keptFor = true
                        woken += wait.need
                    }
                    continue
                }
                if favored != nil, Self.isProject(wait.root, favored), wait.need > 0 { keptFor = true }
                woken += wait.need
                try? FileManager.default.removeItem(at: file)
                due[wait.root, default: []].append(wait)
            }
            for root in due.keys.sorted() where due[root]!.contains(where: { $0.auto == true }) { LeadAdvance.nudge(root: root) }
            return due.keys.sorted().compactMap { root in
                let waits = due[root]!.filter { $0.auto != true }.sorted { $0.at < $1.at }
                guard !waits.isEmpty else { return nil }
                var whats: [String] = []
                for wait in waits where !whats.contains(wait.what) { whats.append(wait.what) }
                return (root, LeadWitness.roomText(whats, mac: mac, limits: limits, root: root))
            }
        }

        static func hasRoom(for wait: Wait, mac: MacLoad, limits: MacLimits) -> Bool {
            guard !mac.isBusy(threshold: limits.loadLimit) else { return false }
            // A merge's wait (no session) waits on the load alone, as merge does; starts and audits on memory too.
            return wait.need == 0 || (mac.memoryShortage(limits) == nil && mac.sessions + wait.need <= limits.maxSessions)
        }

        private typealias Holder = MacLoad.Holder

        /// `waits` with the project `favored`'s first, each part by when it was refused.
        static func inTurn(_ waits: [(file: URL, wait: Wait)], favored: String?) -> [(file: URL, wait: Wait)] {
            waits.sorted { a, b in
                let first = (Self.isProject(a.wait.root, favored), Self.isProject(b.wait.root, favored))
                return first.0 != first.1 ? first.0 : a.wait.at < b.wait.at
            }
        }

        /// The folder `path` is the project `root` or inside it (its worktrees are).
        static func isProject(_ path: String, _ root: String?) -> Bool {
            guard let root else { return false }
            let folder = (path as NSString).standardizingPath, project = (root as NSString).standardizingPath
            return folder == project || folder.hasPrefix(project + "/")
        }

        /// While boosted, the wait of the project the user last worked in (`BoostState.favored`) that `need` more
        /// sessions for the project `root` would take the room of: a refused start or audit of the favored project,
        /// still waiting, which wouldn't fit beside them. Nil when not boosted, `root` is the favored project, it
        /// waits on nothing, or there's room for both. Fairness: freed room goes to where the user works first.
        public func heldFor(root: String, need: Int, mac: MacLoad, limits: MacLimits, now: Date = Date()) -> Wait? {
            guard let favored = limits.boost?.favored, !Self.isProject(root, favored) else { return nil }
            let theirs = waits().map(\.wait).filter {
                Self.isProject($0.root, favored) && $0.need > 0 && now.timeIntervalSince1970 - $0.at <= Self.expiry
            }.sorted { $0.at < $1.at }
            guard let first = theirs.first else { return nil }
            return mac.sessions + need + first.need > limits.maxSessions ? first : nil
        }
    }

    /// "The Mac has room again for what was refused: start_worker(one), audit(two). Now: load 3.0 (load_threshold 24,
    /// twice the 12 cores), 4 team sessions across 2 projects (this one 1, 1 other 3) (mac_max_sessions 10). Retry what's
    /// still wanted." Naming no project but the lead's `root`'s: the lead may copy it into its repo's records.
    public static func roomText(_ whats: [String], mac: MacLoad, limits: MacLimits, root: String) -> String {
        "The Mac has room again for what was refused: \(whats.joined(separator: ", ")). Now: load \(mac.loadText) "
            + "(load_threshold \(limits.loadLimitText)), \(mac.sessionsText(for: root)) (mac_max_sessions \(limits.maxSessionsText))"
            + (mac.memory.map { ", \($0.text)" } ?? "") + ". "
            + "Retry what's still wanted; other projects' leads may take the room too."
    }
}
