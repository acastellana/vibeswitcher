import Foundation
import Testing
@testable import VibeCore

/// What the board keeps for a task's lane: workers' checkpoints, how long it's been where it is, and the rounds of
/// rework a failed task goes through (the lead messaging its worker, or starting a new one).
struct LeadProgressTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func task(_ root: String, _ slug: String = "fix") -> LeadTask? { BoardStore(root: root).load().task(slug) }

    /// A task whose audit failed: its worker is still live.
    func failedAudit(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String) throws {
        _ = lead.call("add_task", ["title": "Fix", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "fix"])
        _ = lead.call("audit", ["task": "fix"])
        _ = try seat("verify-fix", runtime).call("submit_audit", ["completion": "incomplete", "integrity": "clean", "summary": "the test still fails"])
    }

    @Test func aWorkerNotesCheckpointsOnItsOwnTask() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for title in ["Fix", "Other"] { _ = lead.call("add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        _ = lead.call("start_worker", ["task": "fix"])
        let worker = try seat("worker-fix", runtime)
        let noted = worker.call("progress", ["text": "Parser done,\ntests next"])
        #expect(!noted.isError, "\(noted.text)")
        // Whatever task it names, it's its own; one line.
        #expect(!worker.call("progress", ["task": "other", "text": "Tests pass"]).isError)
        #expect(task(root)?.checkpoints?.map(\.text) == ["Parser done, tests next", "Tests pass"])
        #expect(task(root, "other")?.checkpoints == nil)
        // It doesn't message the lead.
        #expect(runtime.steered.isEmpty)
        #expect(worker.call("progress", ["text": "  "]).isError)
        // Long ones are cut; only the latest are kept.
        _ = worker.call("progress", ["text": String(repeating: "x", count: 400)])
        #expect(task(root)?.checkpoints?.last?.text.count == 301)
        for number in 0..<50 { _ = worker.call("progress", ["text": "step \(number)"]) }
        #expect(task(root)?.checkpoints?.count == LeadTask.keptCheckpoints)
        #expect(task(root)?.checkpoints?.last?.text == "step 49")
        // The lead's status shows the latest.
        #expect(lead.call("status", [:]).text.contains("last progress: step 49"))
    }

    @Test func onlyWorkersHaveTheProgressTool() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(lead.call("progress", ["text": "x"]).isError)
        let verifier = try issued(.verifier, task: "fix", root: root, runtime)
        #expect(verifier.call("progress", ["text": "x"]).isError)
    }

    @Test func theBriefAsksForProgressAtMilestones() throws {
        let task = LeadTask(slug: "fix", title: "Fix", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        let brief = LeadPrompts.worker(task: task, root: "/r", workflow: LeadWorkflow())
        #expect(brief.contains("call progress"))
        #expect(brief.contains("milestone"))
    }

    @Test func everyStatusChangeIsStamped() throws {
        let root = try repo()
        let store = BoardStore(root: root)
        var task = LeadTask(slug: "fix", title: "Fix", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.createdAt = 1_000
        try store.update { $0.tasks.append(task) }
        #expect(store.load().task("fix")?.since == 1_000)
        // A change that leaves the status alone keeps the stamp.
        try store.update { $0.tasks[0].title = "Fix it" }
        #expect(store.load().task("fix")?.since == 1_000)
        let before = Date().timeIntervalSince1970
        try store.update { $0.tasks[0].status = .running }
        #expect((store.load().task("fix")?.since ?? 0) >= before)
    }

    @Test func aFirstWorkerIsTheFirstAttempt() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "Fix", "goal": "g", "acceptance": ["a"]])
        #expect(task(root)?.attempts == nil)
        _ = lead.call("start_worker", ["task": "fix"])
        #expect(task(root)?.attempts == 1)
        #expect(task(root)?.rework == 0)
        #expect(task(root)?.startedAt != nil)
    }

    @Test func aFailedAuditIsKeptAsTheSetback() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try failedAudit(lead, runtime, root: root)
        let failed = try #require(task(root))
        #expect(failed.status == .failed)
        #expect(failed.setback?.stage == .review)
        #expect(failed.setback?.reason == "the test still fails")
        #expect(failed.setback?.evidence?.completion == .incomplete)
    }

    @Test func messagingTheLiveWorkerOfAFailedTaskStartsARework() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try failedAudit(lead, runtime, root: root)
        #expect(!lead.call("message", ["task": "fix", "text": "The test still fails: fix it"]).isError)
        let reworked = try #require(task(root))
        #expect(reworked.status == .running)
        #expect(reworked.attempts == 2)
        #expect(reworked.rework == 1)
        #expect(reworked.evidence == nil)
        // Why it's being reworked stays.
        #expect(reworked.setback?.reason == "the test still fails")
        // Another message while it works is no new round.
        _ = lead.call("message", ["task": "fix", "text": "also the docs"])
        #expect(task(root)?.attempts == 2)
    }

    @Test func messagingAnEndedWorkerOfAFailedTaskChangesNothing() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try failedAudit(lead, runtime, root: root)
        runtime.killed.append("session-1")
        _ = lead.call("message", ["task": "fix", "text": "fix it"])
        #expect(task(root)?.status == .failed)
        #expect(task(root)?.attempts == 1)
    }

    @Test func restartingAFailedTaskIsAReworkRound() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try failedAudit(lead, runtime, root: root)
        _ = lead.call("stop_worker", ["task": "fix"])
        #expect(task(root)?.status == .failed)
        #expect(!lead.call("start_worker", ["task": "fix"]).isError)
        let restarted = try #require(task(root))
        #expect(restarted.status == .running)
        #expect(restarted.attempts == 2)
        #expect(restarted.setback?.stage == .review)
    }

    @Test func aBlockedWorkerSaysWhyAndAnAnswerSendsItBack() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "Fix", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "fix"])
        _ = try seat("worker-fix", runtime).call("report", ["status": "blocked", "summary": "Need the API key"])
        #expect(task(root)?.status == .blocked)
        #expect(task(root)?.blocker == "Need the API key")
        _ = lead.call("message", ["task": "fix", "text": "It's in .env"])
        #expect(task(root)?.status == .running)
        #expect(task(root)?.blocker == nil)
        // Not a failure: no rework round.
        #expect(task(root)?.attempts == 1)
    }

    @Test func aStoppedWorkerIsTheBlocker() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "Fix", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "fix"])
        _ = lead.call("stop_worker", ["task": "fix"])
        #expect(task(root)?.status == .blocked)
        #expect(task(root)?.blocker == "The lead stopped its worker.")
        // Started again: not blocked, the same round.
        _ = lead.call("start_worker", ["task": "fix"])
        #expect(task(root)?.blocker == nil)
        #expect(task(root)?.attempts == 1)
    }

    @Test func theDoneReportIsKept() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "Fix", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("start_worker", ["task": "fix"])
        _ = try seat("worker-fix", runtime).call("report", ["status": "done", "summary": "Fixed; swift test passes"])
        #expect(task(root)?.report == "Fixed; swift test passes")
    }

    /// A task with a passing audit on a commit that adds b.txt.
    func audited(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String) throws {
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        _ = lead.call("start_worker", ["task": "add-b"])
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b"], in: worktree)
        _ = try seat("worker-add-b", runtime).call("report", ["status": "done", "summary": "added"])
        _ = lead.call("audit", ["task": "add-b"])
        _ = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "checked"])
    }

    @Test func aMergeRecordsItsCommitAndWhetherTestsRan() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try audited(lead, runtime, root: root)
        #expect(!lead.call("merge", ["task": "add-b"]).isError)
        let merged = try #require(task(root, "add-b")?.merged)
        #expect(merged.commit == Git.run(["rev-parse", "main"], in: root).output)
        #expect(merged.tested == false)

        let other = try repo()
        let lead2 = try self.lead(other, runtime)
        _ = lead2.call("configure", ["test_command": "test -f b.txt"])
        try audited(lead2, runtime, root: other)
        #expect(!lead2.call("merge", ["task": "add-b"]).isError)
        #expect(task(other, "add-b")?.merged?.tested == true)
    }

    @Test func aMergeWhoseTestsFailIsTheSetback() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("configure", ["test_command": "echo boom; false"])
        try audited(lead, runtime, root: root)
        #expect(lead.call("merge", ["task": "add-b"]).isError)
        let failed = try #require(task(root, "add-b"))
        #expect(failed.status == .failed)
        #expect(failed.setback?.stage == .merge)
        #expect(failed.setback?.reason.contains("Tests fail") == true)
    }

    @Test func olderBoardsStillRead() throws {
        let json = #"{"tasks":[{"id":"1","slug":"fix","title":"Fix","status":"running","createdAt":5,"contract":{"goal":"g","acceptance":["a"],"boundaries":[],"context":""}}],"questions":[],"updates":[]}"#
        let board = try JSONDecoder().decode(LeadBoard.self, from: Data(json.utf8))
        #expect(board.task("fix")?.attempts == nil)
        #expect(board.task("fix")?.rework == 0)
        #expect(board.task("fix")?.checkpoints == nil)
    }
}
