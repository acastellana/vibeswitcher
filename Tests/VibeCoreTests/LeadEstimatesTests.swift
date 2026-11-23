import Foundation
import Testing
@testable import VibeCore

/// Estimates (the web design of 2026-11-23, "Estimates (new in the node)", `LeadEstimates.swift`): the worker's on its
/// progress, the lead's on add_task and update_task, the time blocked from the status stamps, the project's score (time
/// blocked excluded, clamped), the forecast (running, over, overdue, queued on the workers after what it waits on,
/// blocked, a goal by its last task), the lead told once an estimate of a task past its worst case, and board files both
/// ways.
struct LeadEstimatesTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("estimates")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    static func task(_ slug: String, _ status: LeadTask.Status, after: [String]? = nil) -> LeadTask {
        var task = LeadTask(id: slug, slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""), status: status)
        task.after = after
        return task
    }

    @Test func theWorkerAndTheLeadGiveEstimates() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("add_task", ["title": "Fix", "goal": "g", "acceptance": ["a"], "likely_min": 30, "worst_min": 60]).isError)
        let board = { BoardStore(root: root).load() }
        #expect(board().task("fix")?.estimates?.map { [$0.likelyMin, $0.worstMin] } == [[30, 60]] && board().task("fix")?.estimates?.first?.by == .lead)
        _ = lead.call("start_worker", ["task": "fix"])
        let worker = try seat("worker-fix", runtime)
        let given = worker.call("progress", ["text": "Parser done", "likely_min": 20, "worst_min": 45])
        #expect(given.text.contains("with your estimate (20 min likely, 45 at worst)"), "\(given.text)")
        #expect(board().task("fix")?.estimates?.last == board().task("fix")?.estimates?.last.map { LeadEstimate(likelyMin: 20, worstMin: 45, at: $0.at, by: .worker) })
        #expect(worker.call("progress", ["text": "x", "likely_min": 50, "worst_min": 40]).isError, "worst under likely")
        #expect(worker.call("progress", ["text": "x", "likely_min": 5]).isError, "one without the other")
        // The lead corrects it.
        #expect(lead.call("update_task", ["task": "fix", "likely_min": 90, "worst_min": 120]).text.contains("90 min likely, 120 at worst"))
        #expect(board().task("fix")?.estimates?.count == 3 && board().task("fix")?.estimates?.last?.by == .lead)

        // A worker with no estimate yet is asked for one; with one, not.
        _ = lead.call("add_task", ["title": "Other", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "other"])
        let other = try seat("worker-other", runtime)
        #expect(other.call("progress", ["text": "Started"]).text.contains("Give your estimate with your next progress"))
        _ = other.call("progress", ["text": "Going", "likely_min": 10, "worst_min": 20])
        #expect(!other.call("progress", ["text": "More"]).text.contains("Give your estimate"))
        // The first is always kept, the rest the newest.
        var task = Self.task("t", .running)
        for index in 1...30 { task.add(LeadEstimate(likelyMin: index, worstMin: index, at: Double(index), by: .worker)) }
        #expect(task.estimates?.count == LeadTask.keptEstimates && task.estimates?.first?.likelyMin == 1 && task.estimates?.last?.likelyMin == 30)
    }

    /// Each status change is stamped; the time blocked is read from them, a spell still open up to now.
    @Test func timeBlockedComesFromTheStamps() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        _ = lead.call("add_task", ["title": "Fix", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("update_task", ["task": "fix", "status": "blocked"])
        let stamps = BoardStore(root: root).load().task("fix")?.states ?? []
        #expect(stamps.map(\.status) == [.planned, .blocked], "\(stamps)")
        var task = Self.task("t", .running)
        task.states = [LeadStateStamp(status: .running, at: 0), LeadStateStamp(status: .blocked, at: 600), LeadStateStamp(status: .running, at: 1500),
                       LeadStateStamp(status: .blocked, at: 3000)]
        #expect(task.blockedMinutes(from: 0, to: 3600) == 25)
        #expect(task.blockedMinutes(from: 900, to: 3300) == 15)
    }

    /// The score: the median of unblocked time over the first likely estimate, the share inside the worst case; fewer
    /// than five said so with no correction; a median past 5× clamped and said.
    @Test func theScoreExcludesTimeBlockedAndIsClamped() {
        func board(_ count: Int, likely: Int, took minutes: Double, blocked: Double = 0) -> LeadBoard {
            var board = LeadBoard()
            for index in 0..<count {
                var task = Self.task("m\(index)", .done)
                let start = Double(index) * 100_000
                task.startedAt = start
                task.add(LeadEstimate(likelyMin: likely, worstMin: likely * 2, at: start, by: .worker))
                task.states = [LeadStateStamp(status: .running, at: start), LeadStateStamp(status: .blocked, at: start + 60),
                               LeadStateStamp(status: .running, at: start + 60 + blocked * 60)]
                task.merged = LeadMergeRecord(commit: "c", tested: true)
                task.merged?.at = start + (minutes + blocked) * 60
                board.tasks.append(task)
            }
            return board
        }
        let few = LeadForecast.score(board(4, likely: 10, took: 20))
        #expect(!few.isEnough && few.correction == 1 && few.line.contains("fewer than 5"), "\(few)")
        // Took 20 at work and 30 blocked on a 10-minute estimate: 2× over, not 5×; all inside the worst case (20).
        let over = LeadForecast.score(board(6, likely: 10, took: 20, blocked: 30))
        #expect(over.ratio == 2 && over.correction == 2 && over.insideWorst == 1 && !over.clamped, "\(over)")
        #expect(over.line == "Estimates here run 2.0× over (excluding time blocked); 100% land inside the worst case.", "\(over.line)")
        let wild = LeadForecast.score(board(6, likely: 10, took: 100))
        #expect(wild.ratio == 10 && wild.correction == 5 && wild.clamped && wild.line.contains("corrected by 5.0× at most"), "\(wild.line)")
        #expect(LeadForecast.score(board(6, likely: 100, took: 10)).correction == 0.5)
    }

    /// The forecast at `now`: a running task by its estimate, corrected; one over its likely estimate; one past its
    /// worst case (no date); queued ones on the workers, after what they wait on; a blocked one says on whom it waits;
    /// a goal lands with its last task, at least then while one has no date.
    @Test func theForecastPlacesEachTaskAndGoal() {
        let now = 1_000_000.0
        var board = LeadBoard()
        var running = Self.task("running", .running)
        running.add(LeadEstimate(likelyMin: 30, worstMin: 60, at: now - 600, by: .worker))
        running.goalID = "g"
        var over = Self.task("over", .review)
        over.add(LeadEstimate(likelyMin: 5, worstMin: 30, at: now - 600, by: .worker))
        var overdue = Self.task("overdue", .running)
        overdue.add(LeadEstimate(likelyMin: 5, worstMin: 8, at: now - 600, by: .worker))
        var first = Self.task("first", .planned)
        first.add(LeadEstimate(likelyMin: 60, worstMin: 120, at: now - 10, by: .lead))
        var second = Self.task("second", .planned, after: ["running"])
        second.add(LeadEstimate(likelyMin: 10, worstMin: 20, at: now - 10, by: .lead))
        second.goalID = "g"
        var blocked = Self.task("blocked", .blocked)
        blocked.blocker = "Which plan names?\nmore"
        blocked.goalID = "h"
        var queuedBehind = Self.task("behind", .planned, after: ["blocked"])
        queuedBehind.goalID = "h"
        board.tasks = [running, over, overdue, first, second, blocked, queuedBehind]
        board.goals = [LeadGoal(id: "g", title: "G", done: "d"), LeadGoal(id: "h", title: "H", done: "d")]
        // One worker: the running ones hold it.
        let result = LeadForecast.forecast(board, workers: 1, now: now)
        #expect(result.tasks["running"] == LeadLanding(likely: now + 1200, worst: now + 3000, basis: .estimated))
        #expect(result.tasks["over"] == LeadLanding(likely: now, worst: now + 1200, basis: .estimated, over: true))
        #expect(result.tasks["overdue"] == LeadLanding(basis: .overdue, overdueMinutes: 2))
        // Three running hold three slots (one asked for: the free ones are theirs); first takes the slot freed first
        // (over's, at now), second waits on running (20 min on).
        #expect(result.tasks["first"]?.likely == now + 3600, "\(String(describing: result.tasks["first"]))")
        #expect(result.tasks["second"]?.likely == now + 1200 + 600 && result.tasks["second"]?.worst == now + 3000 + 1200, "\(String(describing: result.tasks["second"]))")
        #expect(result.tasks["blocked"] == LeadLanding(basis: .blocked, waitsOn: "Which plan names?"))
        #expect(result.tasks["behind"] == LeadLanding(basis: .blocked, waitsOn: "blocked"))
        #expect(result.goals["g"]?.likely == now + 1800 && result.goals["g"]?.basis == .estimated)
        #expect(result.goals["h"] == LeadLanding(basis: .none, undated: 2))
        #expect(LeadForecast.text(result.tasks["overdue"]!, now: now) == "past its worst case by 2 min")
        #expect(LeadForecast.text(result.tasks["blocked"]!, now: now) == "no date: waits on Which plan names?")
    }

    /// The lead's next tool result asks for a new estimate of a task at work past its worst case, once per estimate.
    @Test func theLeadIsToldOnceOfATaskPastItsWorstCase() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "Fix", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "fix"])
        _ = try BoardStore(root: root).update { board in
            let at = board.taskIndex("fix")!
            board.tasks[at].add(LeadEstimate(likelyMin: 5, worstMin: 10, at: Date().timeIntervalSince1970 - 3600, by: .worker))
        }
        let told = lead.call("board", [:]).text
        #expect(told.contains("Estimates: past the worst case: fix (by 5") && told.contains("new estimate"), "\(told)")
        #expect(!lead.call("board", [:]).text.contains("past the worst case"), "once an estimate")
        _ = try BoardStore(root: root).update { board in
            let at = board.taskIndex("fix")!
            board.tasks[at].add(LeadEstimate(likelyMin: 5, worstMin: 10, at: Date().timeIntervalSince1970 - 1800, by: .worker))
        }
        #expect(lead.call("board", [:]).text.contains("past the worst case: fix"), "a new estimate run past is told again")
    }

    /// A board with estimates and stamps read by a build before them passes over the keys; an old board reads with none.
    @Test func boardFilesReadBothWays() throws {
        var board = LeadBoard()
        var task = Self.task("t", .running)
        task.add(LeadEstimate(likelyMin: 1, worstMin: 2, at: 3, by: .worker))
        task.states = [LeadStateStamp(status: .running, at: 3)]
        task.overdueTold = 3
        board.tasks = [task]
        let data = try JSONEncoder().encode(board)
        struct OldTask: Codable, Equatable { var id: String; var slug: String; var status: String }
        struct OldBoard: Codable { var tasks: [OldTask] }
        #expect(try JSONDecoder().decode(OldBoard.self, from: data).tasks == [OldTask(id: "t", slug: "t", status: "running")])
        let again = try JSONDecoder().decode(LeadBoard.self, from: data)
        #expect(again.tasks.first?.estimates == task.estimates && again.tasks.first?.states == task.states && again.tasks.first?.overdueTold == 3)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["tasks"] = (object["tasks"] as? [[String: Any]])?.map { var task = $0; for key in ["estimates", "states", "overdueTold"] { task[key] = nil }; return task }
        let older = try JSONDecoder().decode(LeadBoard.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.tasks.first?.estimates == nil && LeadForecast.forecast(older, workers: 3, now: 10).tasks["t"]?.basis == LeadLanding.Basis.none)
    }
}
