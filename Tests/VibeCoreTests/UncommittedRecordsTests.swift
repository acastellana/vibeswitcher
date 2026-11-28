import Foundation
import Testing
@testable import VibeCore

/// Since 2026-11-27 the lead's records stay written and not committed between the things that need them in git (a
/// merge, a push request, a lead handover: `LeadRecords`), often for hours, where the 5-minute timer committed them
/// before. Everything else the lead does on its base runs with docs/lead/ changed in the main checkout, and leaves
/// it changed: nothing of it is lost, committed or put in a worker's tree.
extension LeadRecordsTests {
    /// docs/lead/ changed and not committed in the main checkout, as the day leaves it: the logs the lead's calls wrote
    /// and a line of its own. Returns that line.
    func dirtyRecords(_ lead: LeadToolset, _ root: String) throws -> String {
        #expect(!lead.call("record_decision", ["decision": "Not committed yet", "why": "no merge since"]).isError)
        let line = "- a line not committed yet"
        try lead.store.appendProgress(line)
        #expect(!Git.run(["status", "--porcelain", "--", "docs/lead"], in: root).output.isEmpty)
        return line
    }

    @Test func aWorkerStartsOnTheCommittedRecordsAndLeavesTheCheckoutsAlone() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try dirtyRecords(lead, root)
        let main = head("main", root)
        _ = lead.call("add_task", ["title": "add-b", "goal": "g", "acceptance": ["a"]])
        let decisions = read(root + "/docs/lead/decisions.md")

        let started = lead.call("start_worker", ["task": "add-b"])
        #expect(!started.isError, "\(started.text)")
        // From main's head, with main's copy of the records: none of the lines not committed.
        let worktree = Worktrees.path(root: root, slug: "add-b")
        #expect(Git.run(["rev-parse", "HEAD"], in: worktree).output == main)
        #expect(Git.run(["status", "--porcelain", "--untracked-files=no"], in: worktree).output.isEmpty)
        #expect(!read(worktree + "/docs/lead/decisions.md").contains("Not committed yet"))
        // The main checkout's records as they were, the start's own line added; nothing committed.
        #expect(head("main", root) == main)
        #expect(read(root + "/docs/lead/decisions.md") == decisions)
        #expect(read(root + "/docs/lead/progress.md").contains("Started a worker on add-b"))
    }

    @Test func aRevertLandsWithTheRecordsUncommittedAndKeepsThem() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try audited(lead, runtime, root: root, slug: "add-b", file: "b.txt")
        #expect(!lead.call("merge", ["task": "add-b"]).isError)
        let line = try dirtyRecords(lead, root)
        let merged = head("main", root)

        let reverted = lead.call("revert", ["task": "add-b", "reason": "b.txt broke the build"])
        #expect(!reverted.isError, "\(reverted.text)")
        #expect(BoardStore(root: root).load().task("add-b")?.status == .reverted)
        #expect(head("main~1", root) == merged)
        #expect(!FileManager.default.fileExists(atPath: root + "/b.txt"))
        // The revert's commit is the code alone: the records stay on disk, uncommitted, the revert's line added.
        #expect(files(of: head("main", root), root) == ["b.txt"])
        #expect(read(root + "/docs/lead/progress.md").contains(line))
        #expect(read(root + "/docs/lead/decisions.md").contains("Not committed yet"))
        #expect(!Git.run(["show", "main:docs/lead/decisions.md"], in: root).output.contains("Not committed yet"))
    }

    @Test func aCleanupRunsWithTheRecordsUncommittedAndKeepsThem() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try audited(lead, runtime, root: root, slug: "add-b", file: "b.txt")
        #expect(!lead.call("merge", ["task": "add-b"]).isError)
        let line = try dirtyRecords(lead, root)
        let main = head("main", root)

        let cleaned = lead.call("cleanup", ["task": "add-b"])
        #expect(!cleaned.isError, "\(cleaned.text)")
        #expect(!FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: "add-b")))
        #expect(head("main", root) == main)
        #expect(read(root + "/docs/lead/progress.md").contains(line))
        #expect(read(root + "/docs/lead/progress.md").contains("Merged add-b"))
    }

    /// Records written and not committed are no trouble, so status says nothing of them; a commit that waits says when
    /// it's tried next, as the rule now goes.
    @Test func statusNamesOnlyACommitThatWaitsAndWhenItsTriedNext() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        _ = try dirtyRecords(lead, root)
        #expect(!lead.call("status", [:]).text.contains("Records:"))
        // A commit nobody accounted for: the records commit waits for a merge to take it.
        try "x\n".write(toFile: root + "/x.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "x.txt"], in: root)
        Git.run(["commit", "-q", "-m", "hand-made"], in: root)
        guard case .waiting = lead.records.flush(base: "main") else { Issue.record("committed on top of an untaken move"); return }
        let status = lead.call("status", [:]).text
        #expect(status.contains("Records: decisions.md and progress.md wait to be committed"), "\(status)")
        #expect(status.contains("committed on the next try (before the next merge, push request or lead handover)"), "\(status)")
    }
}
