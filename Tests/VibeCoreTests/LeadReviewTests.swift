import Foundation
import Testing
@testable import VibeCore

/// Review levels: a `review: none` task (the default) merges on its own worker's done report and the merge's own test
/// run, with no verdict; an `audit` task, or one whose branch touches sensitive_paths, needs its passing audit as before.
/// The level merge goes by is the stricter of the board's and the vault's, which only the lead sets.
struct LeadReviewTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("review")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func commit(_ file: String, _ text: String, in dir: String) throws {
        let path = dir + "/" + file
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: dir)
        Git.run(["commit", "-q", "-m", "change \(file)"], in: dir)
    }

    /// A lead with merge_policy auto and `test` as its test command.
    func team(test: String? = "test -f b.txt") throws -> (root: String, runtime: FakeRuntime, lead: LeadToolset) {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        var settings = ["merge_policy": "auto"]
        if let test { settings["test_command"] = test }
        #expect(!lead.call("configure", settings).isError)
        return (root, runtime, lead)
    }

    /// Task "add-b" (with `review` when given), its worker started, `file` committed and its done reported.
    func reported(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String, review: String? = nil, file: String = "b.txt") throws {
        var task: [String: Any] = ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]]
        if let review { task["review"] = review }
        #expect(!lead.call("add_task", task).isError)
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        try commit(file, "bee\n", in: Worktrees.path(root: root, slug: "add-b"))
        let report = try seat("worker-add-b", runtime).call("report", doneReport("added"))
        #expect(!report.isError, "\(report.text)")
    }

    func head(_ ref: String, _ root: String) -> String { Git.run(["rev-parse", ref], in: root).output }

    // MARK: add_task, update_task, and where the level shows

    @Test func addTaskTakesAReviewLevelNoneByDefault() throws {
        let (root, _, lead) = try team()
        let added = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"]])
        #expect(added.text.contains("review none"), "\(added.text)")
        let audited = lead.call("add_task", ["title": "Risky", "goal": "g", "acceptance": ["a"], "review": "Audit"])
        #expect(audited.text.contains("review audit"), "\(audited.text)")
        let board = BoardStore(root: root).load()
        #expect(board.task("plain")?.reviewLevel == LeadTask.Review.none && board.task("plain")?.review == nil)
        #expect(board.task("risky")?.review == .audit)
        #expect(try vault.unaudited(root: root, task: "risky").review == .audit)
        #expect(try vault.unaudited(root: root, task: "plain").review == LeadTask.Review.none)
        // Anything else is refused, and nothing is added.
        let refused = lead.call("add_task", ["title": "Odd", "goal": "g", "acceptance": ["a"], "review": "light"])
        #expect(refused.isError && refused.text.contains("none or audit"))
        #expect(BoardStore(root: root).load().task("odd") == nil)

        // status, board and the task in full say it; the Team view's line does too.
        #expect(lead.call("status", [:]).text.contains("- risky: Risky — review audit"))
        let listing = lead.call("board", [:]).text
        #expect(listing.contains("- plain [planned] Plain\n") && listing.contains("- risky [planned] Risky — review audit"), "\(listing)")
        #expect(listing.contains(LeadToolset.reviewLegend) && lead.call("status", [:]).text.contains(LeadToolset.shortReviewLegend))
        #expect(lead.call("board", ["task": "risky"]).text.contains("\nReview: audit"))
        let schemas = lead.tools.filter { ["add_task", "update_task"].contains($0.name) }
        #expect(schemas.count == 2 && schemas.allSatisfy { $0.properties["review"]?.options == ["none", "audit"] })
        #expect(BoardStore(root: root).load().task("risky")?.score?.line.hasPrefix("Review audit · Not audited yet") == true)
        #expect(BoardStore(root: root).load().task("plain")?.score?.line.hasPrefix("Review none: no audit") == true)
    }

    @Test func updateTaskChangesTheLevelOnTheBoardAndInTheVault() throws {
        let (root, _, lead) = try team()
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"]])
        let raised = lead.call("update_task", ["task": "plain", "review": "audit"])
        #expect(raised.text.contains("review audit"), "\(raised.text)")
        #expect(BoardStore(root: root).load().task("plain")?.review == .audit)
        #expect(try vault.unaudited(root: root, task: "plain").review == .audit)
        #expect(!lead.call("update_task", ["task": "plain", "review": "none"]).isError)
        #expect(try vault.unaudited(root: root, task: "plain").review == LeadTask.Review.none)
        #expect(lead.call("update_task", ["task": "plain", "review": "maybe"]).isError)
        #expect(BoardStore(root: root).load().task("plain")?.reviewLevel == LeadTask.Review.none)
    }

    @Test func onlyTheLeadSetsALevelAndOnlyTheTasksWorkerReportsItDone() throws {
        let (root, runtime, lead) = try team()
        try reported(lead, runtime, root: root, review: "audit")
        let worker = FakeSeat(runtime, agent: LeadAgent(pid: 7002, tty: "ttys072", session: try launched("worker-add-b", runtime).session))
        #expect(throws: LeadVault.Refused.self) { try self.vault(for: worker).setReview(.none, root: root, task: "add-b") }
        #expect(throws: LeadVault.Refused.self) { try self.vault.setReview(.none, root: root, task: "add-b") }
        #expect(try vault.unaudited(root: root, task: "add-b").review == .audit)
        // Its worker's done is on its head; nobody else's counts.
        #expect(try vault.unaudited(root: root, task: "add-b").reported == head("agent/add-b", root))
        #expect(throws: LeadVault.Refused.self) { try self.vault(for: worker).reportDone(root: root, task: "other", commit: "x") }
        #expect(throws: LeadVault.Refused.self) { try self.vault(for: runtime).reportDone(root: root, task: "add-b", commit: "x") }
        // A blocked report takes the done back.
        _ = try seat("worker-add-b", runtime).call("report", ["status": "blocked", "summary": "stuck"])
        #expect(try vault.unaudited(root: root, task: "add-b").reported == nil)
    }

    // MARK: merge

    @Test func aNoneTaskMergesOnItsWorkersReportAndTheTestRun() throws {
        let (root, runtime, lead) = try team()
        try reported(lead, runtime, root: root)
        // The lead was told no audit is needed.
        #expect(BoardStore(root: root).load().reports?.last?.text.contains("Its review is none: merge(add-b) runs the full test suite") == true)
        #expect(vault.verdict(root: root, task: "add-b") == nil)
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(merged.text.contains("No audit: review none"))
        #expect(Git.run(["show", "main:b.txt"], in: root).output == "bee")
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.status == .done && task.merged?.tested == true && task.merged?.unaudited == true)
        #expect(lead.call("status", [:]).text.contains("add-b (unaudited)"))
        // The scorecard counts it apart from the audited merges.
        let scorecard = LeadScorecard(BoardStore(root: root).load())
        #expect(scorecard.merged == 1 && scorecard.mergedUnaudited == 1 && scorecard.counted == 0)
        #expect(scorecard.line.contains("1 merged with no audit (review none)") && !scorecard.line.contains("rounds of"), "\(scorecard.line)")
        #expect(task.score?.line.hasPrefix("Merged with no audit (review none)") == true)
    }

    @Test func aNoneTaskWhoseTestsFailDoesntMerge() throws {
        let (root, runtime, lead) = try team(test: "echo BROKEN; exit 1")
        try reported(lead, runtime, root: root)
        let main = head("main", root)
        let refused = lead.call("merge", ["task": "add-b"])
        #expect(refused.isError && refused.text.contains("The test command fails"), "\(refused.text)")
        #expect(head("main", root) == main)
        #expect(BoardStore(root: root).load().task("add-b")?.status == .failed)
    }

    @Test func aNoneTaskNeedsItsWorkersDoneOnTheHeadAndATestCommand() throws {
        let (root, runtime, lead) = try team()
        try reported(lead, runtime, root: root)
        // A commit after the report: nobody said it's done.
        try commit("c.txt", "sea\n", in: Worktrees.path(root: root, slug: "add-b"))
        let refused = lead.call("merge", ["task": "add-b"])
        #expect(refused.isError && refused.text.contains("merges without one only on its worker's done report"), "\(refused.text)")
        // A done written on the board only, as any session can, isn't the worker's report.
        try BoardStore(root: root).update { board in
            let index = try #require(board.taskIndex("add-b"))
            board.tasks[index].status = .review
            board.tasks[index].report = "done (forged)"
        }
        #expect(lead.call("merge", ["task": "add-b"]).isError)
        _ = try seat("worker-add-b", runtime).call("report", doneReport("added c too"))
        // Without a test command nothing would check it.
        #expect(!lead.call("configure", ["test_command": ""]).isError)
        let untested = lead.call("merge", ["task": "add-b"])
        #expect(untested.isError && untested.text.contains("no test_command"), "\(untested.text)")
        #expect(!lead.call("configure", ["test_command": "test -f c.txt"]).isError)
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
    }

    @Test func anAuditTaskStillNeedsItsPassingAudit() throws {
        let (root, runtime, lead) = try team()
        try reported(lead, runtime, root: root, review: "audit")
        #expect(BoardStore(root: root).load().reports?.last?.text.contains("Run audit(add-b)") == true)
        let refused = lead.call("merge", ["task": "add-b"])
        #expect(refused.isError && refused.text.contains("no passing audit") && refused.text.contains("Its review is audit."), "\(refused.text)")
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        #expect(!(try seat("verify-add-b", runtime)).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "ok"]).isError)
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(BoardStore(root: root).load().task("add-b")?.merged?.audited == nil)
        #expect(LeadScorecard(BoardStore(root: root).load()).mergedUnaudited == 0)
    }

    @Test func aBoardLoweredToNoneDoesntLowerTheVaults() throws {
        let (root, runtime, lead) = try team()
        try reported(lead, runtime, root: root, review: "audit")
        // A worker's Bash writes review none into board.json.
        try BoardStore(root: root).update { board in
            let index = try #require(board.taskIndex("add-b"))
            board.tasks[index].review = LeadTask.Review.none
        }
        let main = head("main", root)
        let refused = lead.call("merge", ["task": "add-b"])
        #expect(refused.isError && refused.text.contains("Its review is audit."), "\(refused.text)")
        #expect(head("main", root) == main)
    }

    @Test func aBranchTouchingSensitivePathsIsAuditedWhateverItsReviewSays() throws {
        let (root, runtime, lead) = try team(test: "true")
        try reported(lead, runtime, root: root, file: ".github/workflows/ci.yml")
        #expect(BoardStore(root: root).load().reports?.last?.text.contains("treated as audit") == true)
        // The board says why, so the Team view shows it needs an audit rather than "Ready to merge".
        #expect(BoardStore(root: root).load().task("add-b")?.auditNeeded?.contains(".github/workflows/ci.yml") == true)
        let refused = lead.call("merge", ["task": "add-b"])
        #expect(refused.isError, "\(refused.text)")
        #expect(refused.text.contains("touches sensitive_paths (.github/workflows/ci.yml), so it's treated as audit whatever its review says"), "\(refused.text)")
        #expect(BoardStore(root: root).load().task("add-b")?.status != .done)
    }

    @Test func onceAnAuditStartsItsVerdictDecides() throws {
        let (root, runtime, lead) = try team()
        try reported(lead, runtime, root: root)
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        let refused = lead.call("merge", ["task": "add-b"])
        #expect(refused.isError && refused.text.contains("An audit was started on it"), "\(refused.text)")
        // A failing verdict isn't stepped around by the review level.
        _ = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "incomplete", "integrity": "clean", "summary": "no"])
        #expect(lead.call("merge", ["task": "add-b"]).text.contains("no passing audit"))
    }

    @Test func aMergeRecordWithoutTheFieldWasAudited() throws {
        let old = #"{"commit":"abc","tested":true,"at":1}"#
        let record = try JSONDecoder().decode(LeadMergeRecord.self, from: Data(old.utf8))
        #expect(record.audited == nil && !record.unaudited)
        #expect(LeadTask.Review(text: " AUDIT ") == .audit && LeadTask.Review(text: "light") == nil)
        #expect(LeadTask.Review.none.atLeast(.audit) == .audit && LeadTask.Review.none.atLeast(nil) == LeadTask.Review.none)
    }
}

/// The working policy as each role's prompt says it, from one place (`LeadPrompts.Policy`).
struct LeadPolicyPromptTests {
    static let task: LeadTask = {
        var task = LeadTask(slug: "add-login", title: "Add login",
                            contract: LeadContract(goal: "Users can log in", acceptance: ["LoginTests pass"], boundaries: ["only Sources/Auth"], context: ""))
        task.review = .audit
        return task
    }()

    /// Sentences in `text`: each ends with ., ! or ? before a space or the end.
    static func sentences(_ text: String) -> Int {
        try! NSRegularExpression(pattern: #"[.!?](\s|$)"#).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    @Test func theWorkerIsToldTheTestingRuleAndThatItOwnsItsChangeInTwoSentencesEach() {
        let workflow = LeadWorkflow.parse("---\ninit_command: make\ntest_command: make test\n---")
        let testing = LeadPrompts.Policy.workerTesting(test: "make test")
        #expect(Self.sentences(testing) == 2, "\(testing)")
        #expect(Self.sentences(LeadPrompts.Policy.workerOwnership) == 2)
        for needle in ["affects while you edit", "merge runs the full suite (`make test`) once", "that run is the one full suite", "shared test or build infrastructure", "after a failed merge",
                       "summary line", "don't repeat runs or benches"] {
            #expect(testing.contains(needle), "missing \(needle)")
        }
        for needle in ["own this change through completion", "small file outside the listed boundaries", "list each in your report",
                       "direction, scope changes, or anything risky or irreversible"] {
            #expect(LeadPrompts.Policy.workerOwnership.contains(needle), "missing \(needle)")
        }
        let audited = LeadPrompts.worker(task: Self.task, root: "/r", workflow: workflow)
        #expect(audited.contains(testing) && audited.contains(LeadPrompts.Policy.workerOwnership))
        // No full run at the start, and done no longer asks for one.
        #expect(!audited.contains("where things stand") && !audited.contains("`make test` passes"))
        #expect(audited.contains("A verifier will check your branch independently."))
        var plain = Self.task
        plain.review = nil
        let unaudited = LeadPrompts.worker(task: plain, root: "/r", workflow: workflow)
        #expect(unaudited.contains("The lead merges it on your report after the merge's own full test run"))
        #expect(!unaudited.contains("A verifier will check"))
    }

    @Test func aReauditChecksOnlyTheOpenFindingsConcerns() {
        for scope in [LeadPrompts.Reaudit.Scope.since, .ownFiles(["a.swift"]), .wholeBranch(sameCommit: false)] {
            let text = LeadPrompts.recheck(.init(round: 2, since: "aaaaaaaa1111", head: "bbbbbbbb2222", open: [], known: [], stat: "", diff: nil,
                                                 base: "dev", scope: scope))
            #expect(text.contains(LeadPrompts.Policy.reaudit), "\(scope)")
            #expect(text.contains("checks only the concerns the open findings below raise"))
            #expect(!text.contains("run every acceptance check again") && text.contains("never a new Nit"), "\(scope)")
        }
        let first = LeadPrompts.verifier(task: Self.task, root: "/r", workflow: LeadWorkflow.parse("---\ntest_command: make test\n---"))
        #expect(!first.contains(LeadPrompts.Policy.reaudit) && first.contains("run every acceptance check and `make test`"))
    }

    @Test func theLeadIsToldWhenToChooseAnAuditAndThatNitsNeverBecomeTasks() {
        let prompt = LeadPrompts.lead(project: "acme", root: "/r", workflow: LeadWorkflow.parse("---\nmerge_policy: auto\n---"))
        for needle in [LeadPrompts.Policy.leadReview, LeadPrompts.Policy.leadUnaudited, LeadPrompts.Policy.nits, "security", "irreversible operations",
                       "complex changes", "touches sensitive_paths is audited", "re-audit checks only those findings' concerns"] {
            #expect(prompt.contains(needle), "missing \(needle)")
        }
        #expect(!prompt.contains("worthwhile Nits"))
        // No prompt or tool reply suggests making a Nit a task.
        #expect(!LeadPrompts.Policy.nits.isEmpty && LeadPrompts.Policy.nits.contains("add_task refuses one"))
    }
}
