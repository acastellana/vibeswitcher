import Foundation
import Testing
@testable import VibeCore

/// revert(task, reason): a merged task undone in one step, as one tested commit on top of the base, never by rewriting
/// it. A failing test run or a conflict with later work leaves the base as it was; the conflict names the files and
/// the later tasks (from the board's merged ranges) that touched them.
struct LeadRevertTests: LeadTeamFixture {
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

    func commit(_ file: String, _ text: String, in dir: String, message: String? = nil) throws {
        try text.write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: dir)
        Git.run(["commit", "-q", "-m", message ?? "change \(file)"], in: dir)
    }

    /// A review none task titled `title` whose worker commits each of `files` (name → text), reports done, and merge
    /// takes it; returns its slug.
    @discardableResult
    func merged(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String, _ title: String, _ files: [(String, String)]) throws -> String {
        #expect(!lead.call("add_task", ["title": title, "goal": "it changes files", "acceptance": ["they're there"]]).isError)
        let slug = try #require(BoardStore(root: root).load().tasks.last?.slug)
        #expect(!lead.call("start_worker", ["task": slug]).isError)
        for (file, text) in files { try commit(file, text, in: Worktrees.path(root: root, slug: slug)) }
        #expect(!(try seat("worker-\(slug)", runtime)).call("report", doneReport("changed")).isError)
        let merged = lead.call("merge", ["task": slug])
        #expect(!merged.isError, "\(merged.text)")
        return slug
    }

    func head(_ root: String) -> String { Git.run(["rev-parse", "main"], in: root).output }

    /// The revert commit the board recorded for `slug` (the lead's records commit may follow it on the base).
    func revertCommit(_ root: String, _ slug: String) throws -> String {
        try #require(BoardStore(root: root).load().task(slug)?.merged?.revertedBy)
    }

    /// The test command's own record of each run: its folder, HOME, test-lock slot, and the process it runs under.
    func runs(_ root: String) -> [String] {
        ((try? String(contentsOfFile: vault.scratch(root: root, "runs").path, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init)
    }

    static let recordingTest = #"printf '%s|%s|%s|%s\n' "$PWD" "$HOME" "$VIBESWITCHER_TEST_LOCK" "$(ps -o args= -p $PPID)" >> "$HOME/../runs""#

    // MARK: One call

    @Test func aMergedTaskIsRevertedInOneTestedCommitOnTopOfTheBase() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": Self.recordingTest + " && test -f a.txt"]).isError)
        let change = try merged(lead, runtime, root: root, "Change", [("b.txt", "bee\n"), ("c.txt", "sea\n")])
        let record = try #require(BoardStore(root: root).load().task(change)?.merged)
        let brought = Git.run(["rev-list", "\(try #require(record.onto))..\(record.commit)"], in: root).output.split(whereSeparator: \.isNewline)
        #expect(brought.count == 2)
        // A later task's merge, on other files: it stays.
        let later = try merged(lead, runtime, root: root, "Later", [("d.txt", "dee\n")])
        let before = head(root)

        let reverted = lead.call("revert", ["task": change, "reason": "b.txt broke the build"])
        #expect(!reverted.isError, "\(reverted.text)")
        let made = try revertCommit(root, change)
        #expect(reverted.text.contains("Reverted \(change) on main: one commit, \(made.prefix(8))"), "\(reverted.text)")
        #expect(reverted.text.contains("The test command passed on it") && reverted.text.contains("post_update") && reverted.text.contains("record_incident"))
        // One commit, on top of the base as it was (then the lead's records, as after a merge): nothing rewritten.
        #expect(Git.run(["rev-parse", "\(made)~1"], in: root).output == before)
        #expect(Git.run(["merge-base", "--is-ancestor", made, "main"], in: root).ok)
        #expect(Git.run(["merge-base", "--is-ancestor", record.commit, "main"], in: root).ok)
        #expect(Git.run(["log", "--format=%s", "\(before)..main"], in: root).output.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("Revert") } == ["Revert \(change): Change"])
        let message = Git.run(["log", "-1", "--format=%B", made], in: root).output
        #expect(message.hasPrefix("Revert \(change): Change\n\nb.txt broke the build\n"), "\(message)")
        for commit in brought { #expect(message.contains("This reverts commit \(commit).")) }
        #expect(!FileManager.default.fileExists(atPath: root + "/b.txt") && !FileManager.default.fileExists(atPath: root + "/c.txt"))
        #expect(Git.run(["show", "main:d.txt"], in: root).output == "dee")

        // The base passes its tests: the run was the revert's, in its own worktree, under the test lock, as branch code.
        let run = try #require(runs(root).last).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        #expect(run[0].hasSuffix("revert-\(change)"), "\(run)")
        #expect(run[1].hasSuffix("revert-\(change)-home"), "\(run)")
        #expect(run[2].hasPrefix(testLock.directory), "\(run)")
        #expect(run[3].contains("vibeswitcher-branch-code"), "\(run)")
        #expect(!FileManager.default.fileExists(atPath: run[0]) && !FileManager.default.fileExists(atPath: run[1]))

        // The task reads reverted, with its revert commit and why; the scorecard counts it.
        let task = try #require(BoardStore(root: root).load().task(change))
        #expect(task.status == .reverted)
        #expect(task.merged?.revertedBy == made && task.merged?.revertReason == "b.txt broke the build" && task.merged?.revertedAt != nil)
        #expect(LeadScorecard(BoardStore(root: root).load()).reverts == 1)
        #expect(BoardStore(root: root).load().task(later)?.status == .done)
        let board = lead.call("board", [:]).text
        #expect(board.contains("1 revert;") && board.contains("1 reverted"), "\(board)")
        #expect(board.contains("- \(change) [reverted] Change — reverted by \(made.prefix(8)): b.txt broke the build"), "\(board)")
        let status = lead.call("status", [:]).text
        #expect(status.contains("reverted (1): \(change) (by \(made.prefix(8)): b.txt broke the build)"), "\(status)")
        // Recorded already: status doesn't find it again as the base's own revert.
        #expect(!status.contains("Reverted on main since they merged"), "\(status)")
        #expect(try String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8).contains("Reverted \(change): Change, by \(made.prefix(8))"))

        // Done with: again, merge, start_worker and update_task refuse it.
        #expect(lead.call("revert", ["task": change, "reason": "again"]).text.contains("reverted already"))
        #expect(lead.call("merge", ["task": change]).text.contains("was merged and then reverted"))
        #expect(lead.call("start_worker", ["task": change]).isError)
        #expect(lead.call("update_task", ["task": change, "status": "planned"]).text.contains("it stays reverted"))
        #expect(Git.run(["log", "--format=%s", "\(made)..main"], in: root).output.split(whereSeparator: \.isNewline).allSatisfy { !$0.hasPrefix("Revert") })
    }

    /// Reverted before its cleanup (auto_advance cleans up only done tasks): cleanup removes its worktree and it stays
    /// reverted, not failed or abandoned.
    @Test func aRevertedTaskStaysRevertedThroughItsCleanup() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "true"]).isError)
        let change = try merged(lead, runtime, root: root, "Change", [("b.txt", "bee\n")])
        #expect(!lead.call("revert", ["task": change, "reason": "it broke"]).isError)
        let made = try revertCommit(root, change)
        let cleaned = lead.call("cleanup", ["task": change])
        #expect(!cleaned.isError, "\(cleaned.text)")
        let task = try #require(BoardStore(root: root).load().task(change))
        #expect(task.status == .reverted && task.worktree == nil && !task.isAbandoned)
        #expect(task.merged?.revertedBy == made && task.merged?.revertReason == "it broke")
        #expect(lead.call("status", [:]).text.contains("reverted (1): \(change) (by \(made.prefix(8)): it broke)"))
        #expect(lead.call("update_task", ["task": change, "status": "planned"]).isError)
        #expect(LeadScorecard(BoardStore(root: root).load()).reverts == 1)
    }

    // MARK: Refused, the base untouched

    @Test func aFailingTestRunLeavesTheBaseUntouchedAndNamesTheFailingTests() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let test = #"test -f b.txt || { echo "✘ Test needsB() recorded an issue at Bee.swift:3:5: Expectation failed: b.txt is there"; echo "✘ Test needsB() failed after 0.001 seconds with 1 issue."; exit 1; }"#
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": test]).isError)
        let change = try merged(lead, runtime, root: root, "Change", [("b.txt", "bee\n")])
        let before = head(root)
        let refused = lead.call("revert", ["task": change, "reason": "it broke"])
        #expect(refused.isError)
        #expect(refused.text.contains("Not reverted: the test command fails with \(change) reverted on main. main is as it was"), "\(refused.text)")
        #expect(refused.text.contains("needsB()"), "\(refused.text)")
        #expect(refused.text.contains("revert-test.log"))
        #expect(head(root) == before)
        #expect(Git.run(["show", "main:b.txt"], in: root).output == "bee")
        let task = try #require(BoardStore(root: root).load().task(change))
        #expect(task.status == .done && task.merged?.revertedBy == nil)
        #expect(Git.run(["worktree", "list", "--porcelain"], in: root).output.components(separatedBy: "worktree ").count == 2 + 1)
    }

    @Test func aConflictLeavesTheBaseUntouchedAndNamesTheFilesAndTheLaterTasks() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "true"]).isError)
        let change = try merged(lead, runtime, root: root, "Change", [("b.txt", "bee\n"), ("c.txt", "sea\n")])
        // A later task builds on b.txt.
        let later = try merged(lead, runtime, root: root, "Later", [("b.txt", "bee, and more\n")])
        // The user's own commit on c.txt, which the vault took.
        try commit("c.txt", "sea, edited\n", in: root, message: "Edit c by hand")
        try vault.setHead(head(root), root: root, branch: "main")
        let before = head(root)

        let refused = lead.call("revert", ["task": change, "reason": "it broke"])
        #expect(refused.isError)
        let text = refused.text
        #expect(text.contains("Not reverted: reverting \(change) conflicts with what main did since it merged, in 2 files"), "\(text)")
        #expect(text.contains("b.txt (changed since by task \(later))"), "\(text)")
        #expect(text.contains("c.txt (changed since by commit \(Git.run(["rev-parse", "--short=8", "main"], in: root).output) “Edit c by hand”)"), "\(text)")
        #expect(text.contains("main is as it was, and \(change) stays merged") && text.contains("fix-forward task"), "\(text)")
        #expect(head(root) == before)
        #expect(Git.run(["status", "--porcelain"], in: root).output.isEmpty)
        #expect(BoardStore(root: root).load().task(change)?.status == .done)
    }

    @Test func aTaskWithNoRecordedRangeOrNoMergeIsRefusedWithTheReason() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "true"]).isError)
        let change = try merged(lead, runtime, root: root, "Change", [("b.txt", "bee\n")])
        let before = head(root)
        // A reason is required.
        let bare = lead.call("revert", ["task": change])
        #expect(bare.isError && bare.text.contains("say what the merge broke (reason)"), "\(bare.text)")
        #expect(lead.call("revert", ["task": change, "reason": "  "]).isError)
        #expect(lead.tools.first { $0.name == "revert" }?.required == ["task", "reason"])
        // Merged before merged.onto was recorded.
        try BoardStore(root: root).update { board in
            board.tasks[board.taskIndex(change)!].merged?.onto = nil
        }
        let older = lead.call("revert", ["task": change, "reason": "it broke"])
        #expect(older.isError && older.text.contains("before the board recorded the commit it went onto"), "\(older.text)")
        // Never merged.
        _ = lead.call("add_task", ["title": "Planned", "goal": "g", "acceptance": ["a"]])
        let planned = lead.call("revert", ["task": "planned", "reason": "it broke"])
        #expect(planned.isError && planned.text.contains("planned isn't merged (it's planned)"), "\(planned.text)")
        // Done on the board with no merged commit.
        try BoardStore(root: root).update { board in
            board.tasks[board.taskIndex(change)!].merged = nil
        }
        let none = lead.call("revert", ["task": change, "reason": "it broke"])
        #expect(none.isError && none.text.contains("\(change) isn't merged"), "\(none.text)")
        #expect(head(root) == before)
    }

    // MARK: What merge keeps

    @Test func revertKeepsTheBatteryHoldAndWaitsForTheLoad() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "true"]).isError)
        let change = try merged(lead, runtime, root: root, "Change", [("b.txt", "bee\n")])
        let before = head(root)
        var held = PowerState(onBattery: true, percent: 40)
        held.heldUnder = 50
        lead.power = { held }
        let refused = lead.call("revert", ["task": change, "reason": "it broke"])
        #expect(refused.isError && refused.text.hasPrefix("Not reverted: the Mac is on battery at 40 %"), "\(refused.text)")
        #expect(head(root) == before)

        lead.power = { nil }
        lead.macLimits = { MacLimits(maxSessions: 6, loadThreshold: 24) }
        lead.loadPoll = 0.01
        runtime.loadReadings = [150, 40, 3]
        let reads = runtime.loadReads
        let reverted = lead.call("revert", ["task": change, "reason": "it broke"])
        #expect(!reverted.isError, "\(reverted.text)")
        #expect(reverted.text.contains("waited") && reverted.text.contains("from 150 below load_threshold"), "\(reverted.text)")
        #expect(runtime.loadReads - reads == 3)
        #expect(Git.run(["rev-parse", "\(try revertCommit(root, change))~1"], in: root).output == before)
    }

    @Test func aBaseMovedByNobodyTheVaultKnowsIsRefused() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "true"]).isError)
        let change = try merged(lead, runtime, root: root, "Change", [("b.txt", "bee\n")])
        try commit("e.txt", "unaccounted\n", in: root)
        let before = head(root)
        let refused = lead.call("revert", ["task": change, "reason": "it broke"])
        #expect(refused.isError, "\(refused.text)")
        #expect(head(root) == before)
        #expect(BoardStore(root: root).load().task(change)?.status == .done)
    }

    // MARK: The git side

    @Test func revertAndTestOnlyAddsACommitAndRefusesAMergeCommitInTheRange() throws {
        let root = try repo()
        let onto = head(root)
        try commit("b.txt", "bee\n", in: root)
        let tip = head(root)
        let scratch = temp.url("revert")
        guard case .passed(let made) = Worktrees.revertAndTest(root: root, onto: onto, commit: tip, base: tip, message: "Revert x\n\nThis reverts commit \(tip).",
                                                               test: "test ! -f b.txt", scratch: scratch, lock: nil) else {
            Issue.record("not passed"); return
        }
        // Made, not landed: the base is the caller's to move.
        #expect(head(root) == tip)
        #expect(Git.run(["rev-parse", "\(made)~1"], in: root).output == tip)
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        // Nothing left to revert once the base undid it.
        Git.run(["merge", "--ff-only", "-q", made], in: root)
        guard case .error(let nothing) = Worktrees.revertAndTest(root: root, onto: onto, commit: tip, base: made, message: "m", test: "true", scratch: scratch, lock: nil) else {
            Issue.record("not refused"); return
        }
        #expect(nothing.contains("changes nothing"))
        // A merge commit in the range.
        Git.run(["checkout", "-q", "-b", "side", onto], in: root)
        try commit("s.txt", "side\n", in: root)
        Git.run(["checkout", "-q", "main"], in: root)
        Git.run(["merge", "-q", "--no-ff", "-m", "merge side", "side"], in: root)
        guard case .error(let merge) = Worktrees.revertAndTest(root: root, onto: made, commit: head(root), base: head(root), message: "m", test: "true", scratch: scratch, lock: nil) else {
            Issue.record("not refused"); return
        }
        #expect(merge.contains("holds a merge commit"))
        // Not on the base.
        guard case .error(let off) = Worktrees.revertAndTest(root: root, onto: onto, commit: Git.run(["rev-parse", "side"], in: root).output, base: tip,
                                                             message: "m", test: "true", scratch: scratch, lock: nil) else {
            Issue.record("not refused"); return
        }
        #expect(off.contains("isn't on"))
    }

    // MARK: The lead's brief

    @Test func theLeadsBriefSaysWhenToRevert() {
        let prompt = LeadPrompts.lead(project: "p", root: "/p", workflow: LeadWorkflow())
        #expect(prompt.contains("When a merged change broke something and a fix-forward would take longer than undoing it, revert(task, reason)"))
        #expect(LeadPrompts.tools.contains("merge, revert, cleanup"))
    }
}
