import Foundation
import Testing
@testable import VibeCore

/// A task folded into another (2026-10-19, the genswap lead: "The board had no way to mark a task as merged into
/// another one, so I marked them failed"; ten 'failed' in its Team header, and two overtaken tasks left 'blocked' on
/// this project's board): a state of its own, counted with the merged ones, never failed or blocked, with its target.
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
    }

    @Test func theLeadIsToldWhenToFoldAndWhenToAbandon() {
        let prompt = LeadPrompts.lead(project: "p", root: "/r", workflow: LeadWorkflow())
        #expect(prompt.contains("update_task(task, status: folded, into: the task that carries it)"))
        #expect(prompt.contains("Abandoned (nothing will carry it"))
        #expect(prompt.contains("cleanup(task, force: true)"))
        #expect(LeadToolset.settableStates.contains(.folded))
        #expect(LeadTask.Status.attentionOrder.contains(.folded))
    }
}
