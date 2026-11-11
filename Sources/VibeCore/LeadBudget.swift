import Foundation

/// A task's time budget: once its workers' working time reaches it, VibeSwitcher tells the worker to stop, commit what
/// works and report over_budget (what works, with evidence; what's missing; its proposal), and the lead decides:
/// extend it (update_task budget_min), re-plan or abandon. Nothing is ended or stopped: it's a message and a report.
/// The witness counts the time (see `LeadWitness`), so there's no timer of its own; the planted-git-hooks task spent
/// about 1.5 h on ever deeper corner cases before the lead cut it.
public enum LeadBudget {
    /// The default budget when workflow.md sets none (`task_budget_min:`).
    public static let defaultMinutes = 120
    /// Worked time is counted at most this often, on the side clock (`LeadBudgetClock`).
    public static let step: TimeInterval = 60
    /// board.json takes the count at most this often for the budget's accounting alone: it's megabytes rewritten and
    /// read back by everything watching it. A task reaching its budget, or leaving running, writes it at once
    /// (`BoardStore.noteWork`).
    public static let boardEvery: TimeInterval = 5 * 60
    /// The most one step between two looks counts: past it the app wasn't looking (quit), so it isn't known what the
    /// worker did meanwhile. A step counts only its time awake (`awake`), so the Mac's sleep is never in it.
    public static let longestStep: TimeInterval = 5 * 60

    /// The task's budget in minutes: its own (budget_min), else the workflow's; nil for none (0).
    public static func minutes(_ task: LeadTask, default fallback: Int) -> Int? {
        let minutes = task.budgetMin ?? fallback
        return minutes > 0 ? minutes : nil
    }

    /// Whether the worker's time counts now: its task runs, and it's mid-turn, or between turns waiting on work of its
    /// own (a long test run). Waiting doesn't count: on a prompt (the user's), between turns on the lead or the user,
    /// in line for the Mac-wide test and build lock; nor does a session that ended, or quit, or stopped on an API
    /// error. Nor an audit: its task is in review, not running.
    public static func counts(_ seen: LeadWitness.Seen, task: LeadTask) -> Bool {
        guard task.status == .running, seen.live, !seen.agentQuit, seen.apiError == nil, seen.usageLimit == nil, seen.lockWait == nil,
              seen.status != .needsInput else { return false }
        switch seen.activity {
        case .needsInput?, .apiError?, .usageLimit?: return false
        case .working?: return true
        case .idle?: return seen.waitingOn != nil
        case .unknown?, nil:
            if [.done, .idle, .background].contains(seen.status ?? .unknown) { return seen.waitingOn != nil }
            return seen.status == .working
        }
    }

    /// The running tasks whose workers work now (see `counts`), by task id. Only the running tasks are copied.
    public static func working(board: LeadBoard, seen: [String: LeadWitness.Seen]) -> Set<String> {
        var working: Set<String> = []
        for index in board.tasks.indices where board.tasks[index].status == .running {
            let task = board.tasks[index]
            guard let worker = task.worker, worker != task.stopped, let info = seen[worker], counts(info, task: task) else { continue }
            working.insert(task.id)
        }
        return working
    }

    /// The time awake from `from` to `to`, by the witness's sleep log (the awake clock merges and stall reports use):
    /// a worker reads as working all through a sleep, and a Mac that wakes every few minutes in the night would count
    /// each wake's step (2026-11-11: a worker that wrote one line was told to stop at its 60 min budget). What the
    /// log can't say (nothing noted, or the time before it began) counts as awake.
    static func awake(from: Double, to: Double, sleep: MacSleepLog) -> TimeInterval {
        max(0, to - from - (sleep.reading(from: from, to: to)?.slept ?? 0))
    }

    /// "2 h 5 min" of working time.
    public static func text(_ seconds: Double) -> String { LeadToolset.age(seconds) }

    /// What the worker is told once its time reaches the budget.
    public static func stopText(_ task: LeadTask, minutes: Int) -> String {
        "Your task \(task.slug) has reached its time budget: \(text(task.worked ?? 0)) of work against \(minutes) min. "
            + "Stop here: commit what works, then report with status over_budget, saying what works (with evidence: the "
            + "tests or checks you ran and what they showed), what's missing, and your proposal: finish in N more minutes, "
            + "cut scope (which part), or another approach. Then wait: the lead decides whether to extend the budget, "
            + "re-plan or abandon."
    }

    /// What the lead is told at the same moment.
    public static func leadText(_ task: LeadTask, minutes: Int) -> String {
        "The worker on \(task.slug) has reached its \(minutes) min time budget (\(text(task.worked ?? 0)) of work). "
            + "VibeSwitcher told it to stop, commit what works and report over_budget with what works, what's missing and "
            + "its proposal. Nothing is stopped: when its report comes, decide: extend (update_task(\(task.slug), budget_min: "
            + "more), then message it to go on), re-plan, or abandon."
    }
}

/// The running tasks' working time since board.json last took it (`.vibeswitcher/budget-clock.json`): a minute's count
/// is written here, a few bytes, and the board takes it every `LeadBudget.boardEvery` (`BoardStore.noteWork`). Written
/// and read under the board's lock. A board that hasn't taken it yet is behind by at most that much: status and the
/// Team view may show a task's worked time up to 5 minutes old; the budget's stop uses the fresh count.
public struct LeadBudgetClock: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var worked: Double?
        public var workedAt: Double?
    }

    /// By task id, what `LeadTask.worked` and `workedAt` are now: each task the count looked at since board.json took it.
    public var entries: [String: Entry] = [:]
    /// When board.json last took the count.
    public var flushedAt: Double?

    public init() {}

    /// `task`'s count, as this clock has it.
    func apply(to task: inout LeadTask) {
        guard let entry = entries[task.id] else { return }
        task.worked = entry.worked
        task.workedAt = entry.workedAt
    }

    /// `board`'s tasks with this clock's count on them.
    public func apply(to board: inout LeadBoard) {
        guard !entries.isEmpty else { return }
        for index in board.tasks.indices where entries[board.tasks[index].id] != nil { apply(to: &board.tasks[index]) }
    }

    /// Whether board.json should take the count now: `boardEvery` has passed, or a task with a count waiting left
    /// running (its receipt reads it from the board) or the board.
    func due(on board: LeadBoard, now: Double) -> Bool {
        guard !entries.isEmpty else { return false }
        if let flushedAt, now - flushedAt < LeadBudget.boardEvery {
            return entries.keys.contains { board.task($0)?.status != .running }
        }
        return true
    }
}

extension BoardStore {
    var budgetClockFile: String { (folder as NSString).appendingPathComponent("budget-clock.json") }

    /// The count not on board.json yet (empty when there's none).
    public func budgetClock() -> LeadBudgetClock {
        (FileManager.default.contents(atPath: budgetClockFile).flatMap { try? JSONDecoder().decode(LeadBudgetClock.self, from: $0) }) ?? LeadBudgetClock()
    }

    /// Counts working time as the board's `noteWork` does, on the board with the clock's count on it, and writes the
    /// count: to the clock, and to board.json when it's due (`LeadBudgetClock.due`) or a task reached its budget now.
    /// Under the board's lock. Returns the tasks that reached their budget now.
    @discardableResult
    public func noteWork(_ working: Set<String>, defaultMinutes: Int, now: Double = Date().timeIntervalSince1970,
                         sleep: MacSleepLog = MacSleepLog()) throws -> [LeadTask] {
        try locked {
            var board = try read()
            var clock = budgetClock()
            clock.apply(to: &board)
            let noted = board.noteWork(working, defaultMinutes: defaultMinutes, now: now, sleep: sleep)
            if !noted.reached.isEmpty || clock.due(on: board, now: now) {
                board.refreshScores(now: now)
                try write(board)
                clock = LeadBudgetClock()
                clock.flushedAt = now
            } else if noted.changed {
                if clock.flushedAt == nil { clock.flushedAt = now }
                for index in board.budgeted {
                    clock.entries[board.tasks[index].id] = LeadBudgetClock.Entry(worked: board.tasks[index].worked, workedAt: board.tasks[index].workedAt)
                }
            } else {
                return noted.reached
            }
            try VibePaths.writePrivate(try JSONEncoder().encode(clock), to: URL(fileURLWithPath: budgetClockFile))
            return noted.reached
        }
    }

    /// Forgets task `id`'s count: the lead re-planned it, and its next worker's time starts from zero. Under the
    /// board's lock (from `update`).
    func dropBudgetClock(_ id: String) {
        var clock = budgetClock()
        guard clock.entries.removeValue(forKey: id) != nil else { return }
        try? VibePaths.writePrivate(try JSONEncoder().encode(clock), to: URL(fileURLWithPath: budgetClockFile))
    }
}

/// A task whose working time reached its budget (see `LeadBudget`): kept on it until the lead changes budget_min.
public struct LeadOverBudget: Codable, Equatable, Sendable {
    /// The budget it reached, in minutes.
    public var minutes: Int
    /// When its worker was told to stop (or reported over_budget without being told).
    public var at: Double
    /// The worker's over_budget report, once it came.
    public var report: String?

    public init(minutes: Int, at: Double = Date().timeIntervalSince1970, report: String? = nil) {
        self.minutes = minutes
        self.at = at
        self.report = report
    }

    /// "over its 120 min budget (2 h 3 min worked): <report>", or "…; told to stop at 14:02, no report yet".
    public func text(worked: Double?) -> String {
        "over its \(minutes) min budget (\(LeadBudget.text(worked ?? 0)) worked)"
            + (report.map { ": \($0)" } ?? "; told to stop at \(LeadBoard.clock(at)), no over_budget report yet")
    }
}

extension LeadBoard {
    /// Counts working time: each running task whose worker works now (`working`, by task id) gets the time awake since
    /// its last count (by `sleep`, see `LeadBudget.awake`; at most `LeadBudget.longestStep`, written at most every
    /// `LeadBudget.step`); any other stops counting.
    /// A running task whose time reached its budget (its own, else `defaultMinutes`) is marked over budget, once per
    /// budget: the lead changing budget_min clears it. Returns the tasks marked now, and whether anything changed.
    /// Only the tasks in `budgeted` are copied or changed: a board of hundreds of finished tasks costs no more than
    /// its running ones (hang-20261027-041428 caught it copying and comparing each of 254 on the main thread).
    @discardableResult
    public mutating func noteWork(_ working: Set<String>, defaultMinutes: Int, now: Double = Date().timeIntervalSince1970,
                                  sleep: MacSleepLog = MacSleepLog()) -> (reached: [LeadTask], changed: Bool) {
        var reached: [LeadTask] = []
        var changed = false
        for index in budgeted {
            var task = tasks[index]
            let noted = Self.noteWork(&task, working: working.contains(task.id), defaultMinutes: defaultMinutes, now: now, sleep: sleep)
            if noted.reached { reached.append(task) }
            if noted.changed {
                tasks[index] = task
                changed = true
            }
        }
        return (reached, changed)
    }

    /// Whether `noteWork` would change anything, the clock's count on the board, without changing the board, or the
    /// count is due on board.json: the witness asks on the main thread, and only then writes it, off it.
    public func notesWork(_ working: Set<String>, defaultMinutes: Int, now: Double = Date().timeIntervalSince1970,
                          clock: LeadBudgetClock = LeadBudgetClock(), sleep: MacSleepLog = MacSleepLog()) -> Bool {
        var board = self
        clock.apply(to: &board)
        if clock.due(on: board, now: now) { return true }
        return board.budgeted.contains { index in
            var task = board.tasks[index]
            return Self.noteWork(&task, working: working.contains(task.id), defaultMinutes: defaultMinutes, now: now, sleep: sleep).changed
        }
    }

    /// The tasks the budget looks at, by index: the running ones, and any other still holding the start of a count
    /// (`workedAt`, from before it stopped running), which `noteWork` clears. Reads two fields of each task.
    var budgeted: [Int] { tasks.indices.filter { tasks[$0].status == .running || tasks[$0].workedAt != nil } }

    /// One task's count (see `noteWork`): whether it changed, and whether it reached its budget now.
    private static func noteWork(_ task: inout LeadTask, working: Bool, defaultMinutes: Int, now: Double, sleep: MacSleepLog) -> (changed: Bool, reached: Bool) {
        let before = (worked: task.worked, workedAt: task.workedAt)
        if task.status == .running, working {
            if let since = task.workedAt {
                // Until it has had a step's time awake the count stays where it began, so the sleep is all in one window.
                let step = LeadBudget.awake(from: since, to: now, sleep: sleep)
                if step >= LeadBudget.step {
                    task.worked = (task.worked ?? 0) + min(step, LeadBudget.longestStep)
                    task.workedAt = now
                }
            } else {
                task.workedAt = now
            }
        } else {
            task.workedAt = nil
        }
        var reached = false
        if task.status == .running, task.overBudget == nil, let minutes = LeadBudget.minutes(task, default: defaultMinutes),
           (task.worked ?? 0) >= Double(minutes) * 60 {
            task.overBudget = LeadOverBudget(minutes: minutes, at: now)
            reached = true
        }
        return (reached || task.worked != before.worked || task.workedAt != before.workedAt, reached)
    }

    /// The tasks over their budget that aren't finished, the earliest first.
    public var overBudget: [LeadTask] {
        tasks.filter { $0.overBudget != nil && !LeadTeams.isFinished($0) }.sorted { $0.overBudget!.at < $1.overBudget!.at }
    }
}
