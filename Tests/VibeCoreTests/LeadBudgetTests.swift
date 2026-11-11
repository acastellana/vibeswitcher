import Foundation
import Testing
@testable import VibeCore

/// Each task has a time budget (see `LeadBudget`): the witness counts its worker's working time, and at the budget
/// the worker is told to stop and report over_budget, once per budget; the lead decides. The clock is the test's own:
/// each look is a call with its `now`, never a wait.
struct LeadBudgetTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    static let working = LeadWitness.Seen(live: true, status: .working, activity: .working("Bash"))
    /// Waiting on a permission prompt: the user's to answer.
    static let needsInput = LeadWitness.Seen(live: true, status: .needsInput, activity: .needsInput("Run: swift test"))
    /// Between turns with nothing of its own running: waiting on the lead (ask_lead) or the user.
    static let waiting = LeadWitness.Seen(live: true, status: .done, activity: .idle(background: nil))
    /// Between turns waiting on its own background test run: that's work.
    static let backgroundRun = LeadWitness.Seen(live: true, status: .done, activity: .idle(background: "swift test"))

    static func task(budget: Int? = 1, _ status: LeadTask.Status = .running) -> LeadTask {
        var task = LeadTask(slug: "fix", title: "fix", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.status = status
        task.worker = "w1"
        task.budgetMin = budget
        return task
    }

    /// The witness's looks every 3 s from `start` for `seconds`, the worker as `seen` says: the tasks told at each.
    @discardableResult
    static func look(_ board: inout LeadBoard, _ seen: LeadWitness.Seen, from start: Double, for seconds: Double,
                     defaultMinutes: Int = 120) -> [(at: Double, slug: String)] {
        var told: [(at: Double, slug: String)] = []
        var now = start
        while now <= start + seconds {
            let working = LeadBudget.working(board: board, seen: ["w1": seen])
            told += board.noteWork(working, defaultMinutes: defaultMinutes, now: now).reached.map { (now, $0.slug) }
            now += 3
        }
        return told
    }

    static let t0: Double = 1_790_000_000

    /// The Mac's two clocks, the test's own: `stayAwake` moves both, `sleep` only the wall clock. Each look notes them
    /// in the sleep log first, as the witness does, then counts the work.
    struct Mac {
        var wall = LeadBudgetTests.t0
        var awake: TimeInterval = 1_000
        var log = MacSleepLog()
        var told: [String] = []

        /// The witness's looks every 3 s for `seconds` of time awake, the worker reading as working.
        mutating func stayAwake(_ seconds: Double, _ board: inout LeadBoard) {
            let end = wall + seconds
            while true {
                look(&board)
                guard wall + 3 <= end else { break }
                wall += 3
                awake += 3
            }
        }

        /// The Mac asleep for `seconds`: no look, and the awake clock stands still.
        mutating func sleep(_ seconds: Double) { wall += seconds }

        mutating func look(_ board: inout LeadBoard) {
            log.note(wall: wall, awake: awake)
            let working = LeadBudget.working(board: board, seen: ["w1": LeadBudgetTests.working])
            told += board.noteWork(working, defaultMinutes: 120, now: wall, sleep: log).reached.map(\.slug)
        }
    }

    // MARK: The Mac asleep

    /// 2026-11-11 01:13 to 04:36: a worker that wrote one line read as working while the Mac slept nearly all of 3 h
    /// 23 min, waking every few minutes; each wake's look counted the step since the last, and at 60 min it was told to stop.
    @Test func aWorkerReadingAsWorkingThroughANightOfSleepDoesntReachItsBudget() {
        var board = LeadBoard()
        board.tasks = [Self.task(budget: 60)]
        var mac = Mac()
        var awake = 0.0
        while mac.wall < Self.t0 + 203 * 60 {
            // A dark wake: 21 s of looks, then asleep again for 4 min 39 s.
            mac.stayAwake(21, &board)
            awake += 21
            mac.sleep(279)
        }
        mac.look(&board)
        #expect(mac.told.isEmpty, "told to stop after \(LeadBudget.text(board.tasks[0].worked ?? 0)) of work in \(LeadBudget.text(awake)) awake")
        #expect(board.tasks[0].overBudget == nil)
        // Only the time awake counted (to the minute: a count is written once a minute's worth has passed).
        let worked = board.tasks[0].worked ?? 0
        #expect(worked <= awake && worked > awake - LeadBudget.step, "\(worked) of \(awake)")
    }

    @Test func anHourAsleepAndTenMinutesAwakeLeaveFiftyOfASixtyMinuteBudget() {
        var board = LeadBoard()
        board.tasks = [Self.task(budget: 60)]
        var mac = Mac()
        mac.stayAwake(5 * 60, &board)
        mac.sleep(3600)
        mac.stayAwake(5 * 60, &board)
        let left = Double(LeadBudget.minutes(board.tasks[0], default: 120)! * 60) - (board.tasks[0].worked ?? 0)
        #expect(left == Double(50 * 60), "\(left / 60) min left")
        #expect(mac.told.isEmpty)
        // And the budget is still reached, on time awake: 50 more minutes of it.
        mac.stayAwake(50 * 60, &board)
        #expect(mac.told == ["fix"])
        #expect(board.tasks[0].overBudget?.at == mac.wall)
    }

    @Test func theStoresCountTakesOnlyTheTimeAwakeToo() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        _ = lead.call("add_task", ["title": "Fix", "goal": "g", "acceptance": ["a"], "budget_min": 60])
        _ = lead.call("start_worker", ["task": "fix"])
        let store = BoardStore(root: root)
        let id = try #require(store.load().task("fix")?.id)
        var log = MacSleepLog()
        log.note(wall: Self.t0, awake: 0)
        try store.noteWork([id], defaultMinutes: 120, now: Self.t0, sleep: log)
        // An hour asleep, then two minutes awake.
        log.note(wall: Self.t0 + 3720, awake: 120)
        #expect(store.load().notesWork([id], defaultMinutes: 120, now: Self.t0 + 3720, clock: store.budgetClock(), sleep: log))
        try store.noteWork([id], defaultMinutes: 120, now: Self.t0 + 3720, sleep: log)
        var board = store.load()
        store.budgetClock().apply(to: &board)
        #expect(board.task("fix")?.worked == 120)
    }

    /// Fail closed: what the awake clock can't say counts as awake, as it did before the clock was read.
    @Test func timeTheSleepLogDoesntCoverCountsAsAwake() {
        #expect(LeadBudget.awake(from: Self.t0, to: Self.t0 + 90, sleep: MacSleepLog()) == 90)
        // The log began after the count did: only the sleep it saw is taken out.
        var late = MacSleepLog()
        late.note(wall: Self.t0 + 60, awake: 0)
        late.note(wall: Self.t0 + 180, awake: 20)
        #expect(LeadBudget.awake(from: Self.t0, to: Self.t0 + 180, sleep: late) == 80)
        var board = LeadBoard()
        board.tasks = [Self.task(budget: 60)]
        let id = board.tasks[0].id
        board.noteWork([id], defaultMinutes: 120, now: Self.t0)
        board.noteWork([id], defaultMinutes: 120, now: Self.t0 + 90, sleep: MacSleepLog())
        #expect(board.tasks[0].worked == 90)
    }

    // MARK: Counting

    @Test func aWorkerThatKeepsWorkingIsToldOnceAtItsBudgetNotAtEveryLook() {
        var board = LeadBoard()
        board.tasks = [Self.task(budget: 1)]
        let told = Self.look(&board, Self.working, from: Self.t0, for: 30 * 60)
        #expect(told.count == 1, "\(told)")
        #expect(told.first.map { $0.at - Self.t0 } == 60)
        #expect(board.tasks[0].overBudget?.minutes == 1)
        #expect(board.tasks[0].overBudget?.at == Self.t0 + 60)
        // It goes on being counted: status says how long it has worked.
        #expect(board.tasks[0].worked == Double(30 * 60))
    }

    @Test func workedTimeIsWrittenAtMostOnceAMinute() {
        var board = LeadBoard()
        board.tasks = [Self.task(budget: 0)]
        var writes = 0
        var now = Self.t0
        while now <= Self.t0 + 10 * 60 {
            if board.noteWork(LeadBudget.working(board: board, seen: ["w1": Self.working]), defaultMinutes: 120, now: now).changed { writes += 1 }
            now += 3
        }
        // The first look starts the count; then one write a minute.
        #expect(writes == 11, "\(writes)")
        // budget 0: no budget, never told.
        #expect(board.tasks[0].overBudget == nil)
    }

    @Test func aWaitingWorkerDoesntGoOverBudget() {
        for seen in [Self.needsInput, Self.waiting] {
            var board = LeadBoard()
            board.tasks = [Self.task(budget: 1)]
            // 40 s of work, then three hours waiting on the user or the lead.
            Self.look(&board, Self.working, from: Self.t0, for: 40)
            let told = Self.look(&board, seen, from: Self.t0 + 43, for: 3 * 3600)
            #expect(told.isEmpty, "\(seen)")
            #expect((board.tasks[0].worked ?? 0) < 60, "\(seen)")
            #expect(board.tasks[0].overBudget == nil, "\(seen)")
        }
    }

    @Test func anAuditAndTheMacsTestLockDontCountEither() {
        var lockWait = Self.working
        lockWait.lockWait = TestLock.Wait(waiter: TestLock.Waiter(number: 1, slots: 1, who: TestLock.Holder(slot: 0, note: "swift test", since: Date(timeIntervalSince1970: Self.t0))),
                                          ahead: 0, holders: [])
        var reviewed = LeadBoard()
        reviewed.tasks = [Self.task(budget: 1, .review)]
        #expect(Self.look(&reviewed, Self.working, from: Self.t0, for: 3600).isEmpty)
        #expect(reviewed.tasks[0].worked == nil)
        var queued = LeadBoard()
        queued.tasks = [Self.task(budget: 1)]
        #expect(Self.look(&queued, lockWait, from: Self.t0, for: 3600).isEmpty)
        #expect(queued.tasks[0].worked == nil)
    }

    @Test func itsOwnBackgroundRunCountsAndAGapTheAppDidntSeeCountsAtMostAStep() {
        var board = LeadBoard()
        board.tasks = [Self.task(budget: 10)]
        Self.look(&board, Self.backgroundRun, from: Self.t0, for: 5 * 60)
        #expect(board.tasks[0].worked == Double(5 * 60))
        // The Mac slept for an hour between two looks.
        let after = board.tasks[0].worked ?? 0
        _ = board.noteWork(["\(board.tasks[0].id)"], defaultMinutes: 120, now: Self.t0 + 5 * 60 + 3600)
        #expect(board.tasks[0].worked == after + LeadBudget.longestStep)
    }

    @Test func theDefaultBudgetIsTheWorkflowsAndZeroIsNone() {
        var board = LeadBoard()
        board.tasks = [Self.task(budget: nil)]
        #expect(Self.look(&board, Self.working, from: Self.t0, for: 119 * 60, defaultMinutes: 120).isEmpty)
        #expect(Self.look(&board, Self.working, from: Self.t0 + 119 * 60 + 3, for: 120, defaultMinutes: 120).count == 1)
        #expect(board.tasks[0].overBudget?.minutes == 120)
        var none = LeadBoard()
        none.tasks = [Self.task(budget: nil)]
        #expect(Self.look(&none, Self.working, from: Self.t0, for: 5 * 3600, defaultMinutes: 0).isEmpty)
    }

    // MARK: Workflow and briefs

    @Test func taskBudgetMinIsInWorkflowMdAnd120WhenUnset() {
        #expect(LeadWorkflow.parse("---\nmax_workers: 2\n---").taskBudgetMinutes == 120)
        #expect(LeadWorkflow.parse("---\ntask_budget_min:\n---").taskBudgetMinutes == 120)
        #expect(LeadWorkflow.parse("---\ntask_budget_min: 45\n---").taskBudgetMinutes == 45)
        #expect(LeadWorkflow.parse("---\ntask_budget_min: 0\n---").taskBudgetMinutes == 0)
        #expect(LeadWorkflow.parse(LeadWorkflow.template).taskBudgetMinutes == 120)
        #expect(LeadWorkflow.template.contains("task_budget_min: 120"))
    }

    @Test func theLeadsAndTheWorkersBriefsSayWhatHappensAtTheBudget() throws {
        let root = try repo()
        var workflow = LeadWorkflow()
        workflow.taskBudgetMinutes = 90
        let worker = LeadPrompts.worker(task: Self.task(budget: nil), root: root, workflow: workflow, policy: "", lints: [], screenshots: .some(nil))
        let line = try #require(worker.split(separator: "\n").first { $0.hasPrefix("Time budget:") })
        #expect(line.contains("90 min") && line.contains("over_budget"), "\(line)")
        let own = LeadPrompts.worker(task: Self.task(budget: 30), root: root, workflow: workflow, policy: "", lints: [], screenshots: .some(nil))
        #expect(own.contains("Time budget: 30 min"))
        let lead = LeadPrompts.Policy.leadBudget(workflow)
        #expect(lead.contains("90 min (task_budget_min)") && lead.contains("over_budget") && lead.contains("budget_min"), "\(lead)")
        #expect(!lead.contains("\n"))
    }

    // MARK: The tools

    func repo() throws -> String {
        let url = temp.url("budget")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// Task "add-b" with budget_min `budget`, review none, its worker started and b.txt committed.
    func started(_ root: String, _ runtime: FakeRuntime, budget: Int = 1) throws -> (lead: LeadToolset, worker: LeadToolset) {
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "test -f b.txt", "auto_advance": false]).isError)
        let added = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "budget_min": budget])
        #expect(!added.isError, "\(added.text)")
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b"], in: worktree)
        return (lead, try seat("worker-add-b", runtime))
    }

    /// The witness's looks on the board as stored, the worker at work: the tasks told.
    func work(_ root: String, from start: Double, for seconds: Double) throws -> [String] {
        let store = BoardStore(root: root)
        var told: [String] = []
        var now = start
        while now <= start + seconds {
            told += try store.update { board in
                let worker = board.task("add-b")?.worker ?? ""
                return board.noteWork(LeadBudget.working(board: board, seen: [worker: Self.working]), defaultMinutes: 120, now: now).reached.map(\.slug)
            }
            now += 15
        }
        return told
    }

    @Test func statusShowsATaskOverBudgetWithItsTimeAndTheOverBudgetReport() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let (lead, worker) = try started(root, runtime)
        #expect(BoardStore(root: root).load().task("add-b")?.budgetMin == 1)
        #expect(try work(root, from: Self.t0, for: 5 * 60) == ["add-b"])
        var status = lead.call("status", [:]).text
        #expect(status.contains("Over budget (1)"), "\(status)")
        #expect(status.contains("add-b: over its 1 min budget (5 min worked); told to stop at"), "\(status)")
        #expect(lead.call("board", [:]).text.contains("over budget: 5 min of 1 min, no report yet"))

        let reported = worker.call("report", ["status": "over_budget", "summary": "b.txt is added and test -f b.txt passes; missing: the docs. Proposal: finish in 10 more minutes."])
        #expect(!reported.isError, "\(reported.text)")
        #expect(reported.text.contains("Wait for the lead's decision"))
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.status == .blocked)
        #expect(task.overBudget?.report?.contains("finish in 10 more minutes") == true)
        #expect(task.report == nil)
        // The lead was told, with what to decide.
        #expect(runtime.steered.last?.text.contains("The worker on add-b is over its 1 min time budget (5 min worked)") == true)
        #expect(runtime.steered.last?.text.contains("update_task(add-b, budget_min:") == true)
        status = lead.call("status", [:]).text
        #expect(status.contains("add-b: over its 1 min budget (5 min worked): b.txt is added"), "\(status)")
        // It isn't a done: a review none task's merge takes only its worker's done report.
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError, "\(merged.text)")
        #expect(BoardStore(root: root).load().task("add-b")?.status != .done)
    }

    @Test func overBudgetReplacesAnEarlierDoneForMerge() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let (lead, worker) = try started(root, runtime)
        #expect(!worker.call("report", doneReport("added b.txt")).isError)
        #expect(!worker.call("report", ["status": "over_budget", "summary": "went on past it; the docs are missing"]).isError)
        #expect(lead.call("merge", ["task": "add-b"]).isError)
        #expect(!FileManager.default.fileExists(atPath: root + "/b.txt"))
    }

    @Test func raisingBudgetMinClearsTheOverBudgetStateAndTheNextStopComesAtTheNewBudget() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let (lead, worker) = try started(root, runtime)
        #expect(try work(root, from: Self.t0, for: 90) == ["add-b"])
        #expect(!worker.call("report", ["status": "over_budget", "summary": "half done; proposal: 5 more minutes"]).isError)

        // The same budget again changes nothing.
        #expect(!lead.call("update_task", ["task": "add-b", "budget_min": 1]).isError)
        #expect(BoardStore(root: root).load().task("add-b")?.overBudget != nil)

        let raised = lead.call("update_task", ["task": "add-b", "budget_min": 5])
        #expect(!raised.isError, "\(raised.text)")
        #expect(raised.text.contains("the next stop comes at 5 min"), "\(raised.text)")
        #expect(raised.text.contains("message(add-b, …) to tell it to go on"), "\(raised.text)")
        var task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.overBudget == nil && task.budgetMin == 5)
        #expect(!lead.call("status", [:]).text.contains("Over budget"))

        // The lead tells it to go on: it works again, and is told once more at 5 min.
        #expect(!lead.call("message", ["task": "add-b", "text": "Go on: 5 more minutes."]).isError)
        #expect(BoardStore(root: root).load().task("add-b")?.status == .running)
        let worked = task.worked ?? 0
        let more = try work(root, from: Self.t0 + 3600, for: 10 * 60)
        #expect(more == ["add-b"], "\(more)")
        task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.overBudget?.minutes == 5)
        #expect(worked < 5 * 60 && (task.worked ?? 0) >= 5 * 60)

        // budget_min refuses what isn't a whole number of minutes.
        #expect(lead.call("update_task", ["task": "add-b", "budget_min": -1]).isError)
        #expect(lead.call("update_task", ["task": "add-b", "budget_min": "soon"]).isError)
        #expect(lead.call("add_task", ["title": "C", "goal": "g", "acceptance": ["a"], "budget_min": 1.5]).isError)
    }

    @Test func configureSetsTaskBudgetMin() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        let set = lead.call("configure", ["task_budget_min": 45])
        #expect(!set.isError, "\(set.text)")
        #expect(LeadWorkflow.load(from: root + "/.vibeswitcher/workflow.md").taskBudgetMinutes == 45)
        #expect(lead.call("configure", [:]).text.contains("- task_budget_min: 45"))
        #expect(!lead.call("configure", ["task_budget_min": 0]).isError)
        #expect(lead.call("configure", [:]).text.contains("- task_budget_min: 0 (no time budget"))
        #expect(!lead.call("configure", ["task_budget_min": ""]).isError)
        #expect(LeadWorkflow.load(from: root + "/.vibeswitcher/workflow.md").taskBudgetMinutes == 120)
        #expect(lead.call("configure", ["task_budget_min": -5]).isError)
    }
}
