import Foundation

/// A task's time budget: once its workers' working time reaches it, VibeSwitcher tells the worker to stop, commit what
/// works and report over_budget (what works, with evidence; what's missing; its proposal), and the lead decides:
/// extend it (update_task budget_min), re-plan or abandon. Nothing is ended or stopped: it's a message and a report.
/// The witness counts the time (see `LeadWitness`), so there's no timer of its own; the planted-git-hooks task spent
/// about 1.5 h on ever deeper corner cases before the lead cut it.
public enum LeadBudget {
    /// The default budget when workflow.md sets none (`task_budget_min:`).
    public static let defaultMinutes = 120
    /// Worked time is written to the board at most this often.
    public static let step: TimeInterval = 60
    /// The most one step between two looks counts: past it the app wasn't looking (asleep, quit), so it isn't known
    /// what the worker did meanwhile.
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
        guard task.status == .running, seen.live, !seen.agentQuit, seen.apiError == nil, seen.lockWait == nil,
              seen.status != .needsInput else { return false }
        switch seen.activity {
        case .needsInput?, .apiError?: return false
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
    /// Counts working time: each running task whose worker works now (`working`, by task id) gets the time since its
    /// last count (at most `LeadBudget.longestStep`, written at most every `LeadBudget.step`); any other stops counting.
    /// A running task whose time reached its budget (its own, else `defaultMinutes`) is marked over budget, once per
    /// budget: the lead changing budget_min clears it. Returns the tasks marked now, and whether anything changed.
    /// Only the tasks in `budgeted` are copied or changed: a board of hundreds of finished tasks costs no more than
    /// its running ones (hang-20261027-041428 caught it copying and comparing each of 254 on the main thread).
    @discardableResult
    public mutating func noteWork(_ working: Set<String>, defaultMinutes: Int, now: Double = Date().timeIntervalSince1970)
        -> (reached: [LeadTask], changed: Bool) {
        var reached: [LeadTask] = []
        var changed = false
        for index in budgeted {
            var task = tasks[index]
            let noted = Self.noteWork(&task, working: working.contains(task.id), defaultMinutes: defaultMinutes, now: now)
            if noted.reached { reached.append(task) }
            if noted.changed {
                tasks[index] = task
                changed = true
            }
        }
        return (reached, changed)
    }

    /// Whether `noteWork` would change anything, without changing the board: the witness asks on the main thread, and
    /// only then writes it, off it.
    public func notesWork(_ working: Set<String>, defaultMinutes: Int, now: Double = Date().timeIntervalSince1970) -> Bool {
        budgeted.contains { index in
            var task = tasks[index]
            return Self.noteWork(&task, working: working.contains(task.id), defaultMinutes: defaultMinutes, now: now).changed
        }
    }

    /// The tasks the budget looks at, by index: the running ones, and any other still holding the start of a count
    /// (`workedAt`, from before it stopped running), which `noteWork` clears. Reads two fields of each task.
    var budgeted: [Int] { tasks.indices.filter { tasks[$0].status == .running || tasks[$0].workedAt != nil } }

    /// One task's count (see `noteWork`): whether it changed, and whether it reached its budget now.
    private static func noteWork(_ task: inout LeadTask, working: Bool, defaultMinutes: Int, now: Double) -> (changed: Bool, reached: Bool) {
        let before = (worked: task.worked, workedAt: task.workedAt)
        if task.status == .running, working {
            if let since = task.workedAt {
                let step = now - since
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
