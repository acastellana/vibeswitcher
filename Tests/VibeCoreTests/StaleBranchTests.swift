import Foundation
import Testing
@testable import VibeCore

/// 2026-10-19, twice: an audited branch broke the merge's build on the rebased tree in
/// Tests/VibeSwitcherTests/LeadFilesTests.swift (timed-out-shell-runs at 09:1x, lines 51/65/79/101; the-witness-reads
/// at 10:5x, lines 80 and 136), each because a base commit that landed after the branch's last `git merge` of the base
/// had changed the same test file. Each cost a verifier's two test runs, a rework round and a second audit. audit
/// now refuses such a branch before a verifier starts, and a merge whose build fails names the base's commits that
/// touched the files in the errors.
struct StaleBranchTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("stale")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["config", "commit.gpgsign", "false"]] {
            Git.run(args, in: root)
        }
        try commit("a.txt", "one\n", in: root, "first")
        return root
    }

    func commit(_ file: String, _ text: String, in dir: String, _ message: String) throws {
        let path = (dir as NSString).appendingPathComponent(file)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: dir)
        #expect(Git.run(["commit", "-q", "-m", message], in: dir).ok)
    }

    func sha(_ ref: String, _ root: String) -> String { Git.run(["rev-parse", "--short", ref], in: root).output }

    /// A task whose worker started (its branch at main's head then) and reported done.
    func started(_ lead: LeadToolset, _ runtime: FakeRuntime) {
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        let start = lead.call("start_worker", ["task": "add-b"])
        #expect(!start.isError, "\(start.text)")
    }

    func reported(_ runtime: FakeRuntime) throws {
        let report = try seat("worker-add-b", runtime).call("report", ["status": "done", "summary": "done"])
        #expect(!report.isError, "\(report.text)")
    }

    func verifierStarted(_ runtime: FakeRuntime) -> Bool { runtime.spawned.contains { $0.command.contains("--name 'verify-add-b'") } }

    // MARK: audit

    @Test func aBranchBehindTheBaseInAFileItChangesIsRefused() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        started(lead, runtime)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try commit("a.txt", "one, the worker's\n", in: worktree, "worker edits a")
        try commit("b.txt", "bee\n", in: worktree, "add b")
        try reported(runtime)
        // Meanwhile the base changes a.txt too, and something the branch doesn't touch.
        try commit("a.txt", "one, the base's\n", in: root, "base edits a")
        let edit = sha("main", root)
        try commit("c.txt", "see\n", in: root, "add c")
        let unrelated = sha("main", root)

        let audit = lead.call("audit", ["task": "add-b"])
        #expect(audit.isError)
        #expect(audit.text.contains("no verifier started"), "\(audit.text)")
        #expect(audit.text.contains("\(edit) base edits a (a.txt)"), "\(audit.text)")
        #expect(audit.text.contains("Files: a.txt."), "\(audit.text)")
        #expect(!audit.text.contains(unrelated) && !audit.text.contains("c.txt") && !audit.text.contains("b.txt"), "\(audit.text)")
        #expect(audit.text.contains("`git merge main`"), "\(audit.text)")
        #expect(!verifierStarted(runtime))
        #expect(BoardStore(root: root).load().task("add-b")?.verifier == nil)

        // Once the worker merges the base in, the same branch is audited.
        let merged = Git.run(["merge", "-q", "-X", "ours", "-m", "Merge main", "main"], in: worktree)
        #expect(merged.ok, "\(merged.error)")
        let again = lead.call("audit", ["task": "add-b"])
        #expect(!again.isError, "\(again.text)")
        #expect(verifierStarted(runtime))
    }

    @Test func aBaseThatMovedInOtherFilesIsAudited() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        started(lead, runtime)
        try commit("b.txt", "bee\n", in: Worktrees.path(root: root, slug: "add-b"), "add b")
        try reported(runtime)
        try commit("c.txt", "see\n", in: root, "add c")
        try commit("a.txt", "one, the base's\n", in: root, "base edits a")

        let audit = lead.call("audit", ["task": "add-b"])
        #expect(!audit.isError, "\(audit.text)")
        #expect(audit.text.contains("Verifier started on add-b"))
        #expect(audit.text.contains("agent/add-b is 2 commits behind main; a trial merge onto it is clean."), "\(audit.text)")
        #expect(verifierStarted(runtime))
    }

    /// 2026-10-20: a-role-session-s passed its audit, and only then did its verifier find a trial merge conflicting
    /// with work merged meanwhile. audit runs that trial merge itself, first.
    @Test func aBranchWhoseTrialMergeConflictsIsRefusedNamingTheFilesAndTheBaseCommits() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        started(lead, runtime)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try commit("a.txt", "one, the worker's\n", in: worktree, "worker edits a")
        try commit("Sources/Lead Tools.swift", "let tools = 1\n", in: worktree, "worker adds the tools")
        try commit("b.txt", "bee\n", in: worktree, "add b")
        try reported(runtime)
        let status = BoardStore(root: root).load().task("add-b")?.status
        #expect(status == .review)
        // Meanwhile the base changes both files the other way (one of them twice), and one the branch doesn't touch.
        try commit("a.txt", "one, the base's\n", in: root, "base edits a")
        let edit = sha("main", root)
        try commit("Sources/Lead Tools.swift", "let tools = 2\n", in: root, "base adds the tools")
        let tools = sha("main", root)
        try commit("Sources/Lead Tools.swift", "let tools = 3\n", in: root, "base changes the tools")
        let again = sha("main", root)
        try commit("c.txt", "see\n", in: root, "add c")
        let unrelated = sha("main", root)
        let refs = Git.run(["show-ref"], in: root).output
        let rootStatus = Git.run(["status", "--porcelain"], in: root).output

        let audit = lead.call("audit", ["task": "add-b"])
        #expect(audit.isError)
        #expect(audit.text.contains("Not audited, no verifier started: a trial merge of agent/add-b"), "\(audit.text)")
        #expect(audit.text.contains("Files: Sources/Lead Tools.swift, a.txt."), "\(audit.text)")
        #expect(audit.text.contains("\(again) base changes the tools (Sources/Lead Tools.swift); \(tools) base adds the tools (Sources/Lead Tools.swift); \(edit) base edits a (a.txt)."), "\(audit.text)")
        #expect(!audit.text.contains(unrelated) && !audit.text.contains("c.txt") && !audit.text.contains("b.txt"), "\(audit.text)")
        #expect(audit.text.contains("`git merge main`") && audit.text.contains("run the test suite once and report"), "\(audit.text)")
        #expect(!verifierStarted(runtime))
        let task = BoardStore(root: root).load().task("add-b")
        #expect(task?.verifier == nil && task?.status == .review)
        // The trial merge left the repository as it was: no ref moved, nothing in the worktree.
        #expect(Git.run(["show-ref"], in: root).output == refs)
        #expect(Git.run(["status", "--porcelain"], in: worktree).output.isEmpty)
        #expect(Git.run(["status", "--porcelain"], in: root).output == rootStatus)

        // Once the worker merges the base in and resolves, the same branch is audited, and nothing is behind.
        #expect(!Git.run(["merge", "-q", "-m", "Merge main", "main"], in: worktree).ok)
        try "one, both\n".write(toFile: (worktree as NSString).appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "let tools = 4\n".write(toFile: (worktree as NSString).appendingPathComponent("Sources/Lead Tools.swift"), atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt", "Sources/Lead Tools.swift"], in: worktree)
        #expect(Git.run(["commit", "-q", "--no-edit"], in: worktree).ok)
        let audited = lead.call("audit", ["task": "add-b"])
        #expect(!audited.isError, "\(audited.text)")
        #expect(audited.text.contains("Verifier started on add-b") && !audited.text.contains("behind"), "\(audited.text)")
        #expect(verifierStarted(runtime))
    }

    /// genswap, 2026-10-23: a branch that held another base's records (`records_dir`) was refused for conflicting in
    /// them, and its worker may not touch them. merge takes the base's records, so audit counts neither their
    /// conflicts nor their changes; a conflict in another file is refused as before, naming only that file.
    @Test func aConflictOnlyInTheLeadsRecordsIsAuditedAndAnotherFileStillRefused() throws {
        let root = try repo()
        try commit("docs/lead/progress.md", "# Progress\n\n- one\n", in: root, LeadRecords.subject)
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        started(lead, runtime)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try commit("docs/lead/progress.md", "# Progress\n\n- one\n- the other base's\n", in: worktree, LeadRecords.subject)
        try commit("b.txt", "bee\n", in: worktree, "add b")
        try reported(runtime)
        try commit("docs/lead/progress.md", "# Progress\n\n- one\n- the base's\n", in: root, LeadRecords.subject)
        #expect(try Worktrees.trialMerge(root: root, base: "main", commit: "agent/add-b").get() == ["docs/lead/progress.md"])

        let audit = lead.call("audit", ["task": "add-b"])
        #expect(!audit.isError, "\(audit.text)")
        #expect(audit.text.contains("Verifier started on add-b") && !audit.text.contains("docs/lead"), "\(audit.text)")
        #expect(verifierStarted(runtime))
    }

    /// As above, with a conflict in a.txt too: refused for a.txt only.
    @Test func aConflictInTheLeadsRecordsAndAnotherFileIsRefusedForThatFile() throws {
        let root = try repo()
        try commit("docs/lead/progress.md", "# Progress\n\n- one\n", in: root, LeadRecords.subject)
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        started(lead, runtime)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try commit("docs/lead/progress.md", "# Progress\n\n- one\n- the other base's\n", in: worktree, LeadRecords.subject)
        try commit("a.txt", "one, the worker's\n", in: worktree, "worker edits a")
        try reported(runtime)
        try commit("docs/lead/progress.md", "# Progress\n\n- one\n- the base's\n", in: root, LeadRecords.subject)
        try commit("a.txt", "one, the base's\n", in: root, "base edits a")
        let refused = lead.call("audit", ["task": "add-b"])
        #expect(refused.isError)
        #expect(refused.text.contains("Not audited, no verifier started: a trial merge of agent/add-b"), "\(refused.text)")
        #expect(refused.text.contains("Files: a.txt.") && !refused.text.contains("docs/lead/progress.md"), "\(refused.text)")
        #expect(!verifierStarted(runtime))
    }

    /// Both sides changed a file in lines apart: the trial merge is clean, and the branch is still refused as behind
    /// where it matters (it could break the build at merge).
    @Test func aCleanTrialMergeInAFileBothChangedIsStillRefusedAsBehind() throws {
        let root = try repo()
        try commit("a.txt", "one\ntwo\nthree\nfour\nfive\n", in: root, "a has lines")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        started(lead, runtime)
        try commit("a.txt", "one, the worker's\ntwo\nthree\nfour\nfive\n", in: Worktrees.path(root: root, slug: "add-b"), "worker edits a")
        try reported(runtime)
        try commit("a.txt", "one\ntwo\nthree\nfour\nfive, the base's\n", in: root, "base edits a")
        let edit = sha("main", root)
        #expect(try Worktrees.trialMerge(root: root, base: "main", commit: "agent/add-b").get() == [])

        let audit = lead.call("audit", ["task": "add-b"])
        #expect(audit.isError)
        #expect(!audit.text.contains("trial merge"), "\(audit.text)")
        #expect(audit.text.contains("\(edit) base edits a (a.txt)") && audit.text.contains("Files: a.txt."), "\(audit.text)")
        #expect(!verifierStarted(runtime))
    }

    @Test func aBranchThatMergedTheBaseInIsAuditedAndNotBehind() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        started(lead, runtime)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try commit("b.txt", "bee\n", in: worktree, "add b")
        try commit("c.txt", "see\n", in: root, "add c")
        #expect(Git.run(["merge", "-q", "-m", "Merge main", "main"], in: worktree).ok)
        try reported(runtime)

        let audit = lead.call("audit", ["task": "add-b"])
        #expect(!audit.isError, "\(audit.text)")
        #expect(audit.text.contains("Verifier started on add-b") && !audit.text.contains("behind"), "\(audit.text)")
        #expect(verifierStarted(runtime))
    }

    @Test func aTrialMergeNamesItsConflictsAndSaysWhenItCantTell() throws {
        let root = try repo()
        Git.run(["branch", "side"], in: root)
        try commit("a.txt", "one, main's\n", in: root, "main edits a")
        try commit("b.txt", "bee\n", in: root, "main adds b")
        #expect(try Worktrees.trialMerge(root: root, base: "main", commit: "main").get() == [])
        #expect(try Worktrees.trialMerge(root: root, base: "side", commit: "main").get() == [])
        Git.run(["switch", "-q", "side"], in: root)
        try commit("a.txt", "one, side's\n", in: root, "side edits a")
        Git.run(["switch", "-q", "main"], in: root)
        #expect(try Worktrees.trialMerge(root: root, base: "main", commit: "side").get() == ["a.txt"])
        guard case .failure(let error) = Worktrees.trialMerge(root: root, base: "main", commit: "no-such-branch") else {
            Issue.record("a ref that isn't there merged")
            return
        }
        #expect("\(error)".contains("git merge-tree main no-such- failed"), "\(error)")
    }

    @Test func aBranchAtTheBaseTipIsAudited() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        started(lead, runtime)
        #expect(Git.run(["rev-parse", "agent/add-b"], in: root).output == Git.run(["rev-parse", "main"], in: root).output)

        let audit = lead.call("audit", ["task": "add-b"])
        #expect(!audit.isError, "\(audit.text)")
        #expect(verifierStarted(runtime))
    }

    // MARK: merge

    @Test func aMergeWhoseBuildFailsNamesTheBaseCommitsThatTouchedTheFilesInTheErrors() throws {
        let root = try repo()
        try commit("Tests/LeadFilesTests.swift", "let x = 1\n", in: root, "add the tests")
        try commit("Sources/Own.swift", "let own = 1\n", in: root, "add own")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        // The build as the merge's worktree sees it: errors in a file the base changed, and in one only the branch did.
        try "---\ntest_command: echo \"$PWD/Tests/LeadFilesTests.swift:51:10: error: missing argument for parameter 'clock' in call\"; echo \"$PWD/Tests/LeadFilesTests.swift:65:3: error: extra argument\"; echo \"$PWD/Sources/Own.swift:3:1: error: cannot find 'y' in scope\"; exit 1\n---\n"
            .write(toFile: root + "/.vibeswitcher/workflow.md", atomically: true, encoding: .utf8)
        started(lead, runtime)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try commit("Sources/Own.swift", "let own = 2\n", in: worktree, "edit own")
        try reported(runtime)
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        let verdict = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "ok"])
        #expect(!verdict.isError, "\(verdict.text)")
        // The base moves after the audit (as through another task's merge): two commits change the test file.
        try commit("Tests/LeadFilesTests.swift", "let x = 2\n", in: root, "the clock is an argument")
        let first = sha("main", root)
        try commit("c.txt", "see\n", in: root, "add c")
        let unrelated = sha("main", root)
        try commit("Tests/LeadFilesTests.swift", "let x = 3\n", in: root, "and so is the shell")
        let second = sha("main", root)
        try vault.setHead(Git.run(["rev-parse", "main"], in: root).output, root: root, branch: "main")

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError)
        let lines = merged.text.components(separatedBy: "\n")
        #expect(lines.first == "The test command fails on add-b rebased onto main.", "\(merged.text)")
        #expect(merged.text.contains("by file in the errors (its worker's `git merge main` brings them in):"), "\(merged.text)")
        #expect(lines.contains("- Tests/LeadFilesTests.swift: \(second) and so is the shell; \(first) the clock is an argument"), "\(merged.text)")
        #expect(lines.contains { $0.hasPrefix("- Sources/Own.swift: no commit of main's since ") }, "\(merged.text)")
        #expect(!merged.text.contains(unrelated), "\(merged.text)")
        #expect(lines.last?.hasPrefix("Full output: ") == true)
    }

    @Test func compilerErrorsNameTheirFiles() {
        let output = """
        /tmp/m/Tests/A.swift:51:10: error: missing argument
        /tmp/m/Tests/A.swift:65:3: error: extra argument
        /tmp/m/Sources/B.swift:3: error: cannot find 'y' in scope
        error: fatalError
        """
        #expect(TestFailures(output: output).errorFiles == ["/tmp/m/Tests/A.swift", "/tmp/m/Sources/B.swift"])
    }
}
