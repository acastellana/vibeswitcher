import Foundation
import Testing
@testable import VibeCore

/// A task folded into another (2026-10-19, the genswap lead: "The board had no way to mark a task as merged into
/// another one, so I marked them failed"; ten 'failed' in its Team header, and two overtaken tasks left 'blocked' on
/// this project's board): a state of its own, counted with the merged ones, never failed or blocked, with its target.
/// Beside it, abandoned (nothing will carry the work, counted apart) and removed (a record that never ran).
struct LeadFoldTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("fold")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// add-b with a worker running (it committed b.txt), and add-c planned.
    func twoTasks(_ lead: LeadToolset, root: String) throws {
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        _ = lead.call("add_task", ["title": "Add c", "goal": "c.txt exists", "acceptance": ["test -f c.txt"]])
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "b"], in: worktree)
    }

    @Test func aFoldedTaskKeepsItsTargetAndCountsAsMerged() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try twoTasks(lead, root: root)

        // Its worker still runs: refused until it's stopped.
        let running = lead.call("update_task", ["task": "add-b", "status": "folded", "into": "add-c"])
        #expect(running.isError && running.text.contains("worker is still running"), "\(running.text)")
        #expect(BoardStore(root: root).load().task("add-b")?.status == .running)
        #expect(!lead.call("stop_worker", ["task": "add-b"]).isError)

        // Into what: said, on the board, and not itself.
        let unsaid = lead.call("update_task", ["task": "add-b", "status": "folded"])
        #expect(unsaid.isError && unsaid.text.contains("into"))
        let unknown = lead.call("update_task", ["task": "add-b", "status": "folded", "into": "nope"])
        #expect(unknown.isError && unknown.text.contains("No task nope"), "\(unknown.text)")
        let itself = lead.call("update_task", ["task": "add-b", "status": "folded", "into": "add-b"])
        #expect(itself.isError && itself.text.contains("itself"), "\(itself.text)")
        let stray = lead.call("update_task", ["task": "add-b", "status": "blocked", "into": "add-c"])
        #expect(stray.isError && stray.text.contains("into goes with status folded"))
        #expect(BoardStore(root: root).load().task("add-b")?.status != .folded)

        let folded = lead.call("update_task", ["task": "add-b", "status": "folded", "into": "add-c"])
        #expect(!folded.isError, "\(folded.text)")
        #expect(folded.text.contains("state folded into add-c"))
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.status == .folded && task.foldedInto == "add-c")

        // The board's JSON carries it, and reads back.
        let json = try String(contentsOfFile: root + "/.vibeswitcher/board.json", encoding: .utf8)
        #expect(json.contains("\"folded\"") && json.contains("\"foldedInto\""))
        let back = try JSONDecoder().decode(LeadBoard.self, from: Data(json.utf8))
        #expect(back.task("add-b")?.status == .folded && back.task("add-b")?.foldedInto == "add-c")
        #expect(lead.call("board", ["task": "add-b"]).text.contains("\"foldedInto\" : \"add-c\""))

        // Counted with the merged ones, never as failed or blocked.
        let status = lead.call("status", [:]).text
        #expect(status.contains("done (1, 1 folded): folded: add-b → add-c"), "\(status)")
        #expect(!status.contains("\nfailed") && !status.contains("\nblocked") && !status.contains("\nabandoned"))
        let board = lead.call("board", [:]).text
        #expect(board.contains("1 done (1 folded)"), "\(board)")
        #expect(board.contains("- add-b [folded]") && board.contains("folded into add-c"))
        #expect(!board.contains("failed") && !board.contains("blocked"))
        #expect(LeadTeams.isFinished(task))

        // Nothing more starts, audits or merges on it; each refusal names the target.
        for tool in ["start_worker", "audit", "merge"] {
            let refused = lead.call(tool, ["task": "add-b"])
            #expect(refused.isError && refused.text.contains("folded into add-c"), "\(tool): \(refused.text)")
        }

        // cleanup takes its worktree and branch without force, like an abandoned task's; the record stays.
        let cleaned = lead.call("cleanup", ["task": "add-b"])
        #expect(!cleaned.isError, "\(cleaned.text)")
        #expect(!FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: "add-b")))
        #expect(!Git.run(["rev-parse", "--verify", "agent/add-b"], in: root).ok)
        let kept = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(kept.status == .folded && kept.foldedInto == "add-c" && kept.worktree == nil)

        // Set back to planned, it's an ordinary task again.
        #expect(!lead.call("update_task", ["task": "add-b", "status": "planned"]).isError)
        let again = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(again.status == .planned && again.foldedInto == nil)
    }

    @Test func foldingWaitsForAMergeAndNeverChains() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try twoTasks(lead, root: root)
        #expect(!lead.call("stop_worker", ["task": "add-b"]).isError)
        _ = lead.call("add_task", ["title": "Add d", "goal": "d.txt exists", "acceptance": ["test -f d.txt"]])

        // A merge of it under way (its lock held): refused until it's done.
        let folder = BoardStore(root: root).folder + "/run"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let merging = try #require(FileLock.attempt(folder + "/merge-add-b.lock"))
        let refused = lead.call("update_task", ["task": "add-b", "status": "folded", "into": "add-c"])
        #expect(refused.isError && refused.text.contains("merge of add-b is under way"), "\(refused.text)")
        merging.release()
        #expect(!lead.call("update_task", ["task": "add-b", "status": "folded", "into": "add-c"]).isError)

        // Into a folded task: refused, naming the one that carries the work.
        let chained = lead.call("update_task", ["task": "add-d", "status": "folded", "into": "add-b"])
        #expect(chained.isError && chained.text.contains("fold add-d into that one") && chained.text.contains("add-c"), "\(chained.text)")
        // A merged task stays merged.
        try BoardStore(root: root).update { board in board.tasks[board.taskIndex("add-c")!].status = .done }
        #expect(lead.call("update_task", ["task": "add-c", "status": "folded", "into": "add-d"]).text.contains("merged already"))
    }

    @Test func theScorecardIgnoresFoldedTasks() {
        var board = LeadBoard()
        var merged = LeadTask(slug: "merged", title: "Merged", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""), status: .done)
        merged.merged = LeadMergeRecord(commit: "abc", tested: true)
        var folded = LeadTask(slug: "folded", title: "Folded", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""), status: .folded)
        folded.foldedInto = "merged"
        // Whatever an older record says of it, it isn't a merge of its own.
        folded.merged = LeadMergeRecord(commit: "def", tested: false)
        board.tasks = [merged, folded]
        let scorecard = LeadScorecard(board)
        #expect(scorecard.merged == 1 && scorecard.mergedWithoutTests == 0)
        #expect(!scorecard.line.contains("without tests"))
        let score = LeadTaskScore(folded, questions: [])
        #expect(score.roundsToPass == nil && score.mergedWithoutTests == nil)
        #expect(!score.line.contains("merged without tests"))
        // Only folded tasks: nothing merged.
        board.tasks = [folded]
        #expect(LeadScorecard(board).merged == 0)
        // Nor abandoned ones.
        var abandoned = folded
        abandoned.status = .abandoned
        abandoned.foldedInto = nil
        board.tasks = [merged, abandoned]
        #expect(LeadScorecard(board).merged == 1 && LeadScorecard(board).mergedWithoutTests == 0)
        #expect(LeadTaskScore(abandoned, questions: []).mergedWithoutTests == nil)
    }

    @Test func theLeadIsToldWhenToFoldAbandonOrRemove() {
        let prompt = LeadPrompts.lead(project: "p", root: "/r", workflow: LeadWorkflow())
        #expect(prompt.contains("failed is for work that was tried and didn't pass"))
        #expect(prompt.contains("Folded when another task carries its work"))
        #expect(prompt.contains("update_task(task, status: folded, into: the task that carries it)"))
        #expect(prompt.contains("Abandoned when nothing will carry it"))
        #expect(prompt.contains("update_task(task, status: abandoned, reason: why)"))
        #expect(prompt.contains("Removed only for a record made by mistake that never ran"))
        #expect(LeadToolset.settableStates.contains(.folded) && LeadToolset.settableStates.contains(.abandoned))
        #expect(Set(LeadTask.Status.allCases) == Set(LeadTask.Status.attentionOrder))
    }

    // MARK: Abandoned

    @Test func anAbandonedTaskCountsUnderAbandonedNeverFailed() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try twoTasks(lead, root: root)

        let running = lead.call("update_task", ["task": "add-b", "status": "abandoned", "reason": "no longer wanted"])
        #expect(running.isError && running.text.contains("worker is still running: stop_worker first, then abandon it"), "\(running.text)")
        #expect(!lead.call("stop_worker", ["task": "add-b"]).isError)
        let unsaid = lead.call("update_task", ["task": "add-b", "status": "abandoned"])
        #expect(unsaid.isError && unsaid.text.contains("reason"))
        let folder = BoardStore(root: root).folder + "/run"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let merging = try #require(FileLock.attempt(folder + "/merge-add-b.lock"))
        let refused = lead.call("update_task", ["task": "add-b", "status": "abandoned", "reason": "no longer wanted"])
        #expect(refused.isError && refused.text.contains("merge of add-b is under way"), "\(refused.text)")
        merging.release()
        #expect(BoardStore(root: root).load().task("add-b")?.status != .abandoned)

        let abandoned = lead.call("update_task", ["task": "add-b", "status": "abandoned", "reason": "no longer wanted"])
        #expect(!abandoned.isError, "\(abandoned.text)")
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.status == .abandoned && task.abandonedBecause == "no longer wanted" && task.isAbandoned)
        #expect(LeadTeams.isFinished(task))
        let json = try String(contentsOfFile: root + "/.vibeswitcher/board.json", encoding: .utf8)
        #expect(json.contains("\"abandoned\"") && json.contains("\"abandonedBecause\""))

        // An older task cleaned up after failing is abandoned too, never failed.
        try BoardStore(root: root).update { board in
            var old = LeadTask(slug: "old-one", title: "Old one", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""), status: .failed)
            old.worker = "gone"
            board.tasks.append(old)
        }
        let status = lead.call("status", [:]).text
        #expect(status.contains("abandoned (2): add-b (no longer wanted), old-one"), "\(status)")
        #expect(!status.contains("\nfailed") && !status.contains("\nblocked"))
        let board = lead.call("board", [:]).text
        #expect(board.contains("2 abandoned") && !board.contains("failed") && !board.contains("blocked"), "\(board)")
        #expect(board.contains("- add-b [abandoned]") && board.contains("abandoned: no longer wanted") && board.contains("- old-one [abandoned]"))

        for tool in ["start_worker", "audit", "merge"] {
            let refused = lead.call(tool, ["task": "add-b"])
            #expect(refused.isError && refused.text.contains("add-b is abandoned (no longer wanted)"), "\(tool): \(refused.text)")
        }
        // It carries nothing: nothing folds into it.
        let into = lead.call("update_task", ["task": "add-c", "status": "folded", "into": "add-b"])
        #expect(into.isError && into.text.contains("add-b is abandoned: it carries nothing"), "\(into.text)")
        // reason with another state is refused; with abandoned, it rewords why.
        #expect(lead.call("update_task", ["task": "add-c", "reason": "x"]).isError)
        #expect(!lead.call("update_task", ["task": "add-b", "reason": "the user dropped it"]).isError)
        #expect(BoardStore(root: root).load().task("add-b")?.abandonedBecause == "the user dropped it")

        // cleanup without force, like folded; the record stays.
        let cleaned = lead.call("cleanup", ["task": "add-b"])
        #expect(!cleaned.isError, "\(cleaned.text)")
        #expect(!FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: "add-b")))
        #expect(!Git.run(["rev-parse", "--verify", "agent/add-b"], in: root).ok)
        #expect(BoardStore(root: root).load().task("add-b")?.status == .abandoned)
        // Set back to planned, it's an ordinary task again.
        #expect(!lead.call("update_task", ["task": "add-b", "status": "planned"]).isError)
        let back = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(back.status == .planned && back.abandonedBecause == nil)
    }

    // MARK: Removed

    @Test func aRecordThatNeverRanIsRemovedAndKeptAside() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try twoTasks(lead, root: root)
        _ = lead.call("add_task", ["title": "Add d by mistake", "goal": "d", "acceptance": ["d"]])
        let slug = try #require(BoardStore(root: root).load().tasks.last?.slug)

        #expect(lead.call("update_task", ["task": slug, "status": "removed", "goal": "x"]).text.contains("takes task and reason only"))
        let removed = lead.call("update_task", ["task": slug, "status": "removed", "reason": "added twice"])
        #expect(!removed.isError, "\(removed.text)")
        let board = BoardStore(root: root).load()
        #expect(board.task(slug) == nil && board.tasks.count == 2)
        let kept = try #require(board.removed?.first)
        #expect(kept.slug == slug && kept.removedAt != nil && kept.removedBecause == "added twice")
        let json = try String(contentsOfFile: root + "/.vibeswitcher/board.json", encoding: .utf8)
        #expect(json.contains("\"removed\""))
        // Hidden everywhere, counted nowhere.
        let status = lead.call("status", [:]).text
        let listing = lead.call("board", [:]).text
        #expect(!status.contains(slug) && !listing.contains(slug), "\(listing)")
        #expect(listing.contains("2 task(s)"))
        #expect(lead.call("board", ["task": slug]).isError)
        #expect(lead.call("update_task", ["task": slug, "status": "removed"]).text.contains("No such task"))
    }

    @Test func removingARecordThatRanIsRefusedSayingWhy() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try twoTasks(lead, root: root)
        // A worker was started on it.
        let worked = lead.call("update_task", ["task": "add-b", "status": "removed"])
        #expect(worked.isError && worked.text.contains("a worker was started on it") && worked.text.contains("fold it") && worked.text.contains("abandon it"), "\(worked.text)")
        // A branch git has, though the board doesn't say so.
        Git.run(["branch", "agent/add-c"], in: root)
        let branched = lead.call("update_task", ["task": "add-c", "status": "removed"])
        #expect(branched.isError && branched.text.contains("it has a branch"), "\(branched.text)")
        Git.run(["branch", "-D", "agent/add-c"], in: root)
        // A merge record.
        try BoardStore(root: root).update { board in board.tasks[board.taskIndex("add-c")!].merged = LeadMergeRecord(commit: "abc", tested: true) }
        #expect(lead.call("update_task", ["task": "add-c", "status": "removed"]).text.contains("it merged"))
        try BoardStore(root: root).update { board in board.tasks[board.taskIndex("add-c")!].merged = nil }
        // A task folded into it would point at nothing.
        _ = lead.call("add_task", ["title": "Add e", "goal": "e", "acceptance": ["e"]])
        #expect(!lead.call("update_task", ["task": "add-e", "status": "folded", "into": "add-c"]).isError)
        let target = lead.call("update_task", ["task": "add-c", "status": "removed"])
        #expect(target.isError && target.text.contains("add-e is folded into it"), "\(target.text)")
        #expect(BoardStore(root: root).load().tasks.count == 3 && BoardStore(root: root).load().removed == nil)
        // Never ran, nothing folded into it: removed.
        #expect(!lead.call("update_task", ["task": "add-e", "status": "removed"]).isError)
    }
}
