import Foundation
import Testing
@testable import VibeCore

/// merge(task, dry_run: true) (`LeadToolset.dryRunMerge`) and a kept task's receipt (`LeadReceipt.Ending.kept`): a team
/// experiment's arm runs the merge's rebase and test command without the fast-forward, is kept unmerged, and its
/// receipt keeps when it was merge-ready. Scratch repositories only.
struct MergeDryRunTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("dry")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["config", "commit.gpgsign", "false"]] {
            Git.run(args, in: root)
        }
        try commit(["a.txt": "one\n", "docs/lead/progress.md": "# Progress\n"], in: root, "first")
        return root
    }

    func commit(_ files: [String: String], in dir: String, _ message: String) throws {
        for (file, text) in files {
            let path = (dir as NSString).appendingPathComponent(file)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            Git.run(["add", file], in: dir)
        }
        #expect(Git.run(["commit", "-q", "-m", message], in: dir).ok)
    }

    func configure(_ lead: LeadToolset, _ settings: [String: Any]) {
        let set = lead.call("configure", settings)
        #expect(!set.isError, "\(set.text)")
    }

    /// add-b, with b.txt on its branch, taken to a passing audit.
    func audited(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String) throws {
        let added = lead.call("add_task", ["title": "add-b", "goal": "g", "acceptance": ["a"]])
        #expect(!added.isError, "\(added.text)")
        let start = lead.call("start_worker", ["task": "add-b"])
        #expect(!start.isError, "\(start.text)")
        try commit(["b.txt": "bee\n"], in: Worktrees.path(root: root, slug: "add-b"), "add-b's work")
        #expect(!(try seat("worker-add-b", runtime).call("report", doneReport("done"))).isError)
        let audit = lead.call("audit", ["task": "add-b"])
        #expect(!audit.isError, "\(audit.text)")
        let verdict = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "tests": "passed", "summary": "ok"])
        #expect(!verdict.isError, "\(verdict.text)")
    }

    /// Everything a dry run must leave as it was: every ref, the worktrees git knows, and both checkouts' files.
    func snapshot(_ root: String) -> [String] {
        let worktree = Worktrees.path(root: root, slug: "add-b")
        return [Git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: root).output,
                Git.run(["worktree", "list", "--porcelain"], in: root).output,
                Git.run(["status", "--porcelain", "--untracked-files=all"], in: root).output,
                Git.run(["rev-parse", "HEAD"], in: worktree).output,
                Git.run(["status", "--porcelain", "--untracked-files=all"], in: worktree).output,
                Git.run(["symbolic-ref", "-q", "HEAD"], in: worktree).output]
    }

    func dryRun(_ lead: LeadToolset) -> MCPToolResult { lead.call("merge", ["task": "add-b", "dry_run": true]) }

    // MARK: Dry run

    /// It runs the test command in the merge's slot (the command sees the slot's share of the cores), records its pass
    /// and when, and moves nothing: not main (the lead's uncommitted records stay uncommitted), not the branch, not its
    /// worktree. A real merge afterwards merges as ever.
    @Test func aDryRunPassesWithoutMovingAnythingThenTheMergeLandsAsEver() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let seen = temp.url("cores").path
        configure(lead, ["test_command": "echo \"$\(TestLock.coresVariable)\" > \(RecentProjects.shellQuote(seen)) && test -f b.txt && echo '✔ Test run with 3 tests passed'"])
        try audited(lead, runtime, root: root)
        // The lead's records, changed and not committed: a merge commits them first, a dry run mustn't.
        try "# Progress\n- a line\n".write(toFile: root + "/docs/lead/progress.md", atomically: true, encoding: .utf8)
        let before = snapshot(root)
        let main = Git.run(["rev-parse", "main"], in: root).output
        let head = Git.run(["rev-parse", "agent/add-b"], in: root).output

        let tried = dryRun(lead)

        #expect(!tried.isError, "\(tried.text)")
        #expect(tried.text.contains("merge-ready") && tried.text.contains("not merged"), "\(tried.text)")
        #expect(snapshot(root) == before)
        let cores = try String(contentsOfFile: seen, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int(cores) != nil, "\(cores)")
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.status == .review && task.merged == nil && task.receipt == nil && task.setback == nil, "\(task.status)")
        let run = try #require(task.dryRun)
        #expect(run.passed && run.onto == main && run.commit == head && run.tests == 3 && run.reason == nil, "\(run)")
        #expect(abs(run.at - Date().timeIntervalSince1970) < hangGuard)
        #expect(task.waits?.mergeTesting != nil, "\(String(describing: task.waits))")
        // A dry run leaves no scratch worktree behind.
        #expect(!FileManager.default.fileExists(atPath: vault.scratch(root: root, "merge-add-b").path))

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(Git.run(["rev-parse", "main"], in: root).output != main)
        #expect(Git.run(["show", "main:b.txt"], in: root).ok)
        let done = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(done.status == .done && done.receipt?.ending == .merged, "\(done.status)")
        #expect(done.receipt?.mergeReady != nil)
    }

    /// A failing run is recorded as failed, with why and when; the task isn't sent back, and its worktree gets no
    /// failure log (a merge would copy one into it).
    @Test func aFailingDryRunIsRecordedAndSendsNothingBack() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        configure(lead, ["test_command": "test -f nothing.txt"])
        try audited(lead, runtime, root: root)
        let before = snapshot(root)

        let tried = dryRun(lead)

        #expect(tried.isError, "\(tried.text)")
        #expect(tried.text.contains("failed at") && tried.text.contains("Not sent back"), "\(tried.text)")
        #expect(snapshot(root) == before)
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.status == .review && task.setback == nil, "\(task.status)")
        let run = try #require(task.dryRun)
        #expect(!run.passed && run.reason?.contains("Tests fail rebased onto main") == true && run.tests == nil, "\(run)")
        #expect(!FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: "add-b") + "/.vibeswitcher/merge-failure"))
        #expect(!FileManager.default.fileExists(atPath: vault.scratch(root: root, "merge-add-b").path))
    }

    /// It waits for the Mac's load as a merge does, before anything is tested.
    @Test func aDryRunWaitsForTheLoadToDrop() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        configure(lead, ["test_command": "test -f b.txt"])
        try audited(lead, runtime, root: root)
        lead.macLimits = { MacLimits(maxSessions: 6, loadThreshold: 24) }
        lead.loadPoll = 0.01
        runtime.loadReadings = [150, 40, 3]
        let reads = runtime.loadReads

        let tried = dryRun(lead)

        #expect(!tried.isError, "\(tried.text)")
        #expect(tried.text.contains("waited"), "\(tried.text)")
        #expect(runtime.loadReads - reads == 3)
        #expect(BoardStore(root: root).load().task("add-b")?.dryRun?.passed == true)
    }

    /// Every slot of the Mac-wide test lock held: it waits as a merge does, then refuses with nothing tested and nothing
    /// recorded. A slot frees: it runs.
    @Test func aDryRunTakesASlotOfTheMacWideTestLock() async throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try audited(lead, runtime, root: root)
        // 0.02 min: the wait for a slot is bounded at 1.2 s.
        configure(lead, ["heavy_slots": "1", "test_command": "test -f b.txt", "test_timeout_min": "0.02"])
        let lock = testLock.with(slots: 1)
        let holder = try TestLockTests.outsideHolder(path: lock.slotPath(1))
        try "pid \(holder.processIdentifier), vs-heavy swift build in \(root), since 02:53:22\n".write(toFile: lock.slotPath(1) + ".holder", atomically: true, encoding: .utf8)
        defer { kill(holder.processIdentifier, SIGKILL); _ = waitForEnd(holder) }
        let before = snapshot(root)

        let refused = dryRun(lead)

        #expect(refused.isError)
        #expect(refused.text.contains("Every slot of the Mac-wide test and build lock") && refused.text.contains("Nothing was tested"), "\(refused.text)")
        #expect(snapshot(root) == before)
        #expect(BoardStore(root: root).load().task("add-b")?.dryRun == nil)
        kill(holder.processIdentifier, SIGKILL)
        #expect(await offPool { waitForEnd(holder) })
        let ran = dryRun(lead)
        #expect(!ran.isError, "\(ran.text)")
        #expect(BoardStore(root: root).load().task("add-b")?.dryRun?.passed == true)
    }

    /// A real merge of the task under way (its test command waiting on a file): the dry run is refused, records
    /// nothing, and the merge lands when it's let go.
    @Test func aDryRunIsRefusedWhileAMergeOfTheTaskRuns() async throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let started = temp.url("started").path, go = temp.url("go").path
        configure(lead, ["test_command": "touch \(RecentProjects.shellQuote(started)); until [ -e \(RecentProjects.shellQuote(go)) ]; do sleep 0.05; done; test -f b.txt"])
        try audited(lead, runtime, root: root)

        async let merged = offPool { lead.call("merge", ["task": "add-b"]) }
        #expect(await eventually { FileManager.default.fileExists(atPath: started) })
        let refused = await offPool { dryRun(lead) }
        FileManager.default.createFile(atPath: go, contents: Data())

        #expect(refused.isError)
        #expect(refused.text.contains("a merge of add-b (or a dry run of it) is already running"), "\(refused.text)")
        let result = await merged
        #expect(!result.isError, "\(result.text)")
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.status == .done && task.dryRun == nil, "\(task.status)")
    }

    /// One task at a time: a batch doesn't take dry_run.
    @Test func aDryRunIsntTakenWithABatch() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        let refused = lead.call("merge", ["tasks": ["one", "two"], "dry_run": true])
        #expect(refused.isError && refused.text.contains("dry_run goes with task"), "\(refused.text)")
    }

    // MARK: A kept task's receipt

    /// The experiment's arm B: audited, dry-run merged, then kept. It gets a receipt ending kept, with the dry run's
    /// pass as its merge-ready time; status counts it without calling it merged; it still doesn't merge.
    @Test func aKeptArmKeepsAReceiptEndingKeptWithItsMergeReadyTime() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        configure(lead, ["test_command": "test -f b.txt && echo '✔ Test run with 7 tests passed'"])
        try audited(lead, runtime, root: root)
        #expect(!dryRun(lead).isError)
        let run = try #require(BoardStore(root: root).load().task("add-b")?.dryRun)

        let kept = lead.call("update_task", ["task": "add-b", "status": "kept", "reason": "team experiment arm B: kept unless the user picks it"])
        #expect(!kept.isError, "\(kept.text)")

        let task = try #require(BoardStore(root: root).load().task("add-b"))
        let receipt = try #require(task.receipt)
        #expect(task.status == .kept && receipt.ending == .kept && receipt.mergeReady == run.at && receipt.tests == 7, "\(receipt)")
        #expect(receipt.commit == nil && receipt.onto == nil && receipt.waits?.mergeTesting != nil)
        #expect(receipt.line.hasPrefix("Receipt (kept;") && receipt.line.contains("by a dry run: not merged"), "\(receipt.line)")
        let status = lead.call("status", [:]).text
        let line = try #require(status.components(separatedBy: "\n").first { $0.hasPrefix("Receipts (") })
        #expect(line.contains("1 task (1 kept unmerged)") && !line.contains("merged,"), "\(line)")
        // Its reason changed, or kept said again: the receipt stays.
        #expect(!lead.call("update_task", ["task": "add-b", "reason": "still arm B"]).isError)
        #expect(!lead.call("update_task", ["task": "add-b", "status": "kept", "reason": "arm B"]).isError)
        #expect(BoardStore(root: root).load().task("add-b")?.receipt == receipt)
        // Kept, it still doesn't merge, and a dry run of it is refused the same way.
        let main = Git.run(["rev-parse", "main"], in: root).output
        #expect(lead.call("merge", ["task": "add-b"]).text.contains("kept unmerged"))
        #expect(dryRun(lead).text.contains("kept unmerged"))
        #expect(Git.run(["rev-parse", "main"], in: root).output == main)
        // Planned again, it's open work: no receipt.
        #expect(!lead.call("update_task", ["task": "add-b", "status": "planned"]).isError)
        #expect(BoardStore(root: root).load().task("add-b")?.receipt == nil)
    }

    /// A dry run of an older commit isn't the kept work's merge-ready: the branch moved on after it, so the receipt
    /// has no merge-ready time (nor that run's test count).
    @Test func aDryRunOfAnOlderCommitIsntTheKeptReceiptsMergeReady() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        configure(lead, ["test_command": "test -f b.txt && echo '✔ Test run with 7 tests passed'"])
        try audited(lead, runtime, root: root)
        #expect(!dryRun(lead).isError)
        try commit(["c.txt": "see\n"], in: Worktrees.path(root: root, slug: "add-b"), "more work after the dry run")

        let kept = lead.call("update_task", ["task": "add-b", "status": "kept", "reason": "arm B"])

        #expect(!kept.isError, "\(kept.text)")
        let receipt = try #require(BoardStore(root: root).load().task("add-b")?.receipt)
        #expect(receipt.ending == .kept && receipt.mergeReady == nil && receipt.tests == nil, "\(receipt)")
    }

    /// A task that has a receipt already (it was abandoned) and is set kept keeps one, ending kept.
    @Test func aTaskWithAReceiptSetKeptKeepsItEndingKept() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        #expect(!lead.call("add_task", ["title": "x", "goal": "g", "acceptance": ["a"]]).isError)
        #expect(!lead.call("update_task", ["task": "x", "status": "abandoned", "reason": "dropped"]).isError)
        #expect(BoardStore(root: root).load().task("x")?.receipt?.ending == .abandoned)

        let kept = lead.call("update_task", ["task": "x", "status": "kept", "reason": "the user's word"])

        #expect(!kept.isError, "\(kept.text)")
        let task = try #require(BoardStore(root: root).load().task("x"))
        #expect(task.status == .kept && task.receipt?.ending == .kept && task.receipt?.mergeReady == nil, "\(String(describing: task.receipt))")
    }

    /// Receipts written before kept was an ending (and before mergeReady) still read, and a kept one round-trips.
    @Test func oldReceiptsStillDecode() throws {
        for ending in ["merged", "folded", "abandoned"] {
            let json = #"{"ending":"\#(ending)","endedAt":1700000000,"rounds":1,"rerolls":0,"mergeReruns":0,"questions":0,"waitingOnUser":0,"pricesAsOf":"2026-10-06"}"#
            let receipt = try JSONDecoder().decode(LeadReceipt.self, from: Data(json.utf8))
            #expect(receipt.ending.rawValue == ending && receipt.mergeReady == nil)
        }
        var kept = LeadReceipt(ending: .kept, startedAt: 100, endedAt: 900, worked: 60, worker: nil, verifier: nil)
        kept.mergeReady = 700
        #expect(try JSONDecoder().decode(LeadReceipt.self, from: JSONEncoder().encode(kept)) == kept)
        // Totals from before kept counts were kept decode too.
        let totals = #"{"tasks":2,"worked":60,"tokens":0,"cost":0,"unpriced":0,"pricesAsOf":"2026-10-06"}"#
        #expect(try JSONDecoder().decode(LeadReceiptTotals.self, from: Data(totals.utf8)).kept == nil)
    }

    /// The Receipts line counts kept receipts as tasks, and says how many are kept, never as merged.
    @Test func theReceiptsLineCountsAKeptArmWithoutCallingItMerged() throws {
        func task(_ slug: String, _ status: LeadTask.Status, _ ending: LeadReceipt.Ending) -> LeadTask {
            var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""))
            task.status = status
            task.createdAt = 1000
            task.since = 2000
            task.receipt = LeadReceipt(ending: ending, startedAt: 1000, endedAt: 2000, worked: 3600, worker: nil, verifier: nil)
            return task
        }
        var board = LeadBoard()
        board.tasks = [task("a", .done, .merged), task("b", .kept, .kept)]
        let line = try #require(LeadReceiptTotals.line(board))
        #expect(line.contains("2 tasks (1 kept unmerged)"), "\(line)")
        board.tasks = [task("a", .done, .merged)]
        #expect(try #require(LeadReceiptTotals.line(board)).contains("1 task,"))
    }
}
