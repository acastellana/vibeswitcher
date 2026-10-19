import Foundation
import Testing
@testable import VibeCore

/// The lead's scorecard (each task's score on the board, summed up for the Team tab and status), regression_command in
/// merge, the base's reverts found later, and record_incident.
struct LeadScorecardTests: LeadTeamFixture {
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

    func commit(_ file: String, _ text: String, in dir: String) throws {
        let path = dir + "/" + file
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: dir)
        Git.run(["commit", "-q", "-m", "change \(file)"], in: dir)
    }

    /// Task `change` with its worker's commit of `file`, audited and passed; returns the audited commit.
    @discardableResult
    func audited(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String, file: String = "b.txt") throws -> String {
        if BoardStore(root: root).load().task("change") == nil {
            _ = lead.call("add_task", ["title": "Change", "goal": "it changes", "acceptance": ["it's there"]])
            _ = lead.call("start_worker", ["task": "change"])
        }
        try commit(file, "\(UUID())\n", in: Worktrees.path(root: root, slug: "change"))
        _ = try seat("worker-change", runtime).call("report", ["status": "done", "summary": "changed"])
        #expect(!lead.call("audit", ["task": "change"]).isError)
        #expect(!(try seat("verify-change", runtime)).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "ok"]).isError)
        return Git.run(["rev-parse", "agent/change"], in: root).output
    }

    func task(_ slug: String, rounds: Int, passed: Bool, findings: [LeadFinding] = [], merged: LeadMergeRecord? = nil) -> LeadTask {
        var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        var audits = LeadAuditLedger()
        audits.rounds = rounds
        audits.passed = passed
        audits.findings = findings
        task.audits = rounds == 0 ? nil : audits
        task.merged = merged
        if merged != nil { task.status = .done }
        return task
    }

    func finding(_ id: String, _ severity: LeadFinding.Severity, _ status: LeadFinding.Status) -> LeadFinding {
        LeadFinding(id: id, severity: severity, file: "a.swift", line: 1, evidence: "e", status: status, reason: nil, raised: 1)
    }

    // MARK: Each task's score

    @Test func aTasksScoreCountsItsAuditsFindingsAndTheUsersTime() {
        let findings = [finding("F1", .important, .fixed), finding("F2", .important, .dismissed), finding("F3", .important, .unconfirmed),
                        finding("F4", .nit, .open)]
        let merged = task("a", rounds: 2, passed: true, findings: findings, merged: LeadMergeRecord(commit: "abc", tested: false))
        var answered = LeadQuestion(text: "Which?", options: ["x", "y"], at: 1000)
        answered.task = "a"
        answered.answer = "x"
        answered.answeredAt = 1000 + 300
        var withdrawn = LeadQuestion(text: "Still?", options: [], at: 2000)
        withdrawn.task = "a"
        withdrawn.withdrawnAt = 2000 + 60
        var open = LeadQuestion(text: "And?", options: [], at: 5000)
        open.task = "a"
        open.heldAt = 5100
        let elsewhere = LeadQuestion(text: "Other task?", options: [], at: 0)
        let score = LeadTaskScore(merged, questions: [answered, withdrawn, open, elsewhere], now: 5000 + 120)
        #expect(score.roundsToPass == 2 && score.rounds == 2)
        // Confirmed Important ones only, whatever became of them.
        #expect(score.importantFindings == 2)
        #expect(score.questions == 3 && score.answers == 1)
        // 300 s answered, 60 s until withdrawn, 120 s open so far (held, still waiting on the user).
        #expect(score.waitingOnUser == 480)
        #expect(score.mergedWithoutTests == true && score.revertedBy == nil)
        #expect(score.line == "Passed on audit 2 · 2 Important findings · 3 questions to you (1 answered), 8.0 min waiting on you · merged without tests")

        // A timer's own decision ends the wait, and isn't an answer.
        var decided = LeadQuestion(text: "Go?", options: ["yes", "no"], proposal: "yes", decideIn: 10, at: 0)
        decided.autoDecidedAt = 600
        #expect(decided.waitingOnUser(now: 99_999) == 600)
    }

    @Test func aTaskPassesOnlyOnceItsLastAuditPassedWithNoImportantFindingOpen() {
        #expect(LeadTaskScore(task("a", rounds: 0, passed: false), questions: []).roundsToPass == nil)
        #expect(LeadTaskScore(task("a", rounds: 1, passed: false), questions: []).roundsToPass == nil)
        #expect(LeadTaskScore(task("a", rounds: 2, passed: true, findings: [finding("F1", .important, .open)]), questions: []).roundsToPass == nil)
        #expect(LeadTaskScore(task("a", rounds: 3, passed: true, findings: [finding("F1", .important, .fixed)]), questions: []).roundsToPass == 3)
        #expect(LeadTaskScore(task("a", rounds: 1, passed: false), questions: []).line == "1 audit, not passed yet · 0 Important findings")
    }

    @Test func theBoardRecordsEachTasksScoreWithEveryChange() throws {
        let root = try repo()
        let store = BoardStore(root: root)
        try store.update { board in
            board.tasks.append(task("a", rounds: 1, passed: true))
            _ = board.ask("Which?", options: ["x"], priority: nil, whyNow: nil, task: "a")
        }
        let text = try String(contentsOfFile: (store.folder as NSString).appendingPathComponent("board.json"), encoding: .utf8)
        #expect(text.contains("\"score\"") && text.contains("\"roundsToPass\" : 1") && text.contains("\"waitingOnUser\""))
        let score = try #require(store.load().task("a")?.score)
        #expect(score.roundsToPass == 1 && score.questions == 1 && score.answers == 0)
        #expect(store.load().questions.first?.task == "a")
    }

    // MARK: The scorecard

    @Test func theScorecardSumsUpTheMergedTasks() {
        var board = LeadBoard()
        board.tasks = [task("a", rounds: 1, passed: true, merged: LeadMergeRecord(commit: "a1", tested: true)),
                       task("b", rounds: 1, passed: true, merged: LeadMergeRecord(commit: "b1", tested: false)),
                       task("c", rounds: 4, passed: true, merged: LeadMergeRecord(commit: "c1", tested: true)),
                       // Merged before rounds were kept: in the merged count, not in the rounds.
                       task("d", rounds: 0, passed: false, merged: LeadMergeRecord(commit: "d1", tested: true)),
                       // Not merged: its rounds don't count.
                       task("e", rounds: 5, passed: false)]
        board.tasks[2].merged?.revertedBy = "deadbeef00"
        var question = LeadQuestion(text: "Which?", options: [], at: 0)
        question.answer = "x"
        question.answeredAt = 30 * 60
        var other = LeadQuestion(text: "About c?", options: [], at: 0)
        other.task = "c"
        other.withdrawnAt = 10 * 60
        board.questions = [question, other]
        let card = LeadScorecard(board, now: 99_999)
        #expect(card.merged == 4 && card.counted == 3)
        #expect(card.meanRoundsToPass == 2)
        #expect(abs((card.firstAuditPassRate ?? 0) - 2.0 / 3.0) < 0.0001)
        // Every question's wait (40 min) over the 4 merged tasks.
        #expect(card.userMinutes == 40 && card.userMinutesPerMergedTask == 10)
        #expect(card.reverts == 1 && card.mergedWithoutTests == 1)
        #expect(card.items.map(\.value) == ["2.0", "67%", "10", "1"])
        #expect(card.items.map(\.label) == ["audit rounds to pass", "pass the first audit", "user min per merged task", "revert"])
        #expect(card.line == "Scorecard (4 merged (rounds of 3 of them)): 2.0 audit rounds to pass, 67% pass the first audit, 10 user min per merged task, 1 revert; 1 merged without tests.")
        #expect(card.spoken.contains("67 percent passed the first audit") && card.spoken.contains("1 reverted later"))
        #expect(LeadScorecard(LeadBoard()).line == "Scorecard: nothing merged yet.")
        #expect(LeadScorecard(LeadBoard()).items.map(\.value) == ["–", "–", "–", "0"])
    }

    // MARK: regression_command

    @Test func regressionCommandIsAGuardedSettingMergeRunsAfterTheTests() {
        let workflow = LeadWorkflow.parse("---\ntest_command: swift test\nregression_command: scripts/bench --chat-bench hangs\n---\n")
        #expect(workflow.regressionCommand == "scripts/bench --chat-bench hangs")
        #expect(LeadWorkflow.template.contains("\nregression_command:\n"))
        #expect(LeadWorkflow.parse(LeadWorkflow.template).regressionCommand == nil)
        #expect(LeadWorkflow.configurable.contains("regression_command"))
        #expect(LeadVault.guardedKeys.contains("regression_command"))
        #expect(LeadVault.guardedValue("regression_command", in: workflow) == "scripts/bench --chat-bench hangs")
        #expect(workflow.mergeChecks == "{\nswift test\n} && {\necho '\(LeadWorkflow.regressionMarker)'\nscripts/bench --chat-bench hangs\n}")
        // Without one, merge runs test_command exactly as before.
        #expect(LeadWorkflow.parse("---\ntest_command: swift test\n---\n").mergeChecks == "swift test")
        #expect(LeadWorkflow.parse("---\nregression_command: r\n---\n").mergeChecks == "echo '\(LeadWorkflow.regressionMarker)'\nr")
        #expect(LeadWorkflow().mergeChecks == nil)
        #expect(LeadPrompts.lead(project: "p", root: "/p", workflow: LeadWorkflow()).contains("record_incident(what, evidence, task)"))
    }

    @Test func mergeRunsRegressionCommandAfterTheTestsAndRecordsIt() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "echo TESTS-RAN > \"$HOME/../order\"",
                                         "regression_command": "grep -q TESTS-RAN \"$HOME/../order\""]).isError)
        let onto = Git.run(["rev-parse", "main"], in: root).output
        try audited(lead, runtime, root: root)
        let merged = lead.call("merge", ["task": "change"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(merged.text.contains("regression_command passed too"))
        let record = try #require(BoardStore(root: root).load().task("change")?.merged)
        #expect(record.tested && record.regression == true && record.onto == onto)
    }

    @Test func aFailingRegressionCommandRefusesTheMergeAndSaysSo() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "echo TESTS-RAN",
                                         "regression_command": "echo HANG-CASE-FAILED; exit 3"]).isError)
        try audited(lead, runtime, root: root)
        let refused = lead.call("merge", ["task": "change"])
        #expect(refused.isError)
        #expect(refused.text.contains("The regression_command (the checks incidents became; test_command passed) fails"), "\(refused.text)")
        let task = try #require(BoardStore(root: root).load().task("change"))
        #expect(task.status == .failed && task.merged == nil)
        #expect(task.setback?.reason.hasPrefix("regression_command fails rebased onto main") == true)
        let log = try String(contentsOfFile: vault.scratch(root: root, "change/merge-test.log").path, encoding: .utf8)
        let tests = try #require(log.range(of: "TESTS-RAN")), regression = try #require(log.range(of: "HANG-CASE-FAILED"))
        #expect(tests.lowerBound < regression.lowerBound)
    }

    @Test func failingTestsStopTheMergeBeforeTheRegressionCommand() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "echo BROKEN; exit 1",
                                         "regression_command": "echo REGRESSION-RAN"]).isError)
        try audited(lead, runtime, root: root)
        let refused = lead.call("merge", ["task": "change"])
        #expect(refused.isError && refused.text.contains("The test command fails"), "\(refused.text)")
        let log = try String(contentsOfFile: vault.scratch(root: root, "change/merge-test.log").path, encoding: .utf8)
        #expect(log.contains("BROKEN") && !log.contains("REGRESSION-RAN") && !log.contains(LeadWorkflow.regressionMarker))
    }

    @Test func aRegressionCommandAWorkerChangedIsRefused() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "true", "regression_command": "scripts/bench hangs"]).isError)
        try audited(lead, runtime, root: root)
        let path = (BoardStore(root: root).folder as NSString).appendingPathComponent("workflow.md")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        try text.replacingOccurrences(of: "regression_command: scripts/bench hangs", with: "regression_command: true").write(toFile: path, atomically: true, encoding: .utf8)
        let refused = lead.call("merge", ["task": "change"])
        #expect(refused.isError && refused.text.contains("regression_command is now `true`"), "\(refused.text)")
        #expect(BoardStore(root: root).load().task("change")?.status != .done)
    }

    // MARK: Reverts

    @Test func revertCommitsAreParsedFromTheLog() {
        let output = "c2\u{1f}Revert \"x\"\n\nThis reverts commit 1111111aaaa.\n\u{1e}\nc1\u{1f}Squashed\n\nThis reverts commit 2222222.\nThis reverts commit 3333333.\n\u{1e}\nc0\u{1f}Mentions reverts but none\n\u{1e}"
        let parsed = LeadReverts.parse(output)
        #expect(parsed.map(\.commit) == ["c2", "c1"])
        #expect(parsed.map(\.reverted) == [["1111111aaaa"], ["2222222", "3333333"]])
    }

    @Test func statusFindsAMergeTheBaseRevertedAndRecordsIt() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "true"]).isError)
        try audited(lead, runtime, root: root)
        #expect(!lead.call("merge", ["task": "change"]).isError)
        #expect(!lead.call("status", [:]).text.contains("Reverted on main"))
        let board = lead.call("board", [:]).text
        #expect(board.contains("Scorecard (1 merged): 1.0 audit rounds to pass, 100% pass the first audit, 0.0 user min per merged task, 0 reverts."), "\(board)")
        // The user reverts the merge on main.
        let merged = try #require(BoardStore(root: root).load().task("change")?.merged)
        #expect(Git.run(["revert", "--no-edit", merged.commit], in: root).ok)
        let revert = Git.run(["rev-parse", "main"], in: root).output
        let after = lead.call("status", [:]).text
        #expect(after.contains("Reverted on main since they merged (1): change (by \(revert.prefix(8)))"), "\(after)")
        #expect(after.contains("record_incident"))
        #expect(lead.call("board", [:]).text.contains("100% pass the first audit, 0.0 user min per merged task, 1 revert."))
        let task = try #require(BoardStore(root: root).load().task("change"))
        #expect(task.merged?.revertedBy == revert && task.merged?.revertedAt != nil)
        #expect(task.score?.revertedBy == revert)
        // Found once: the next status doesn't say it again.
        #expect(!lead.call("status", [:]).text.contains("Reverted on main since"))
        #expect(try String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8).contains("Reverted on main: change's merge"))
    }

    @Test func aMergeOfSeveralCommitsCountsAsRevertedWhenAnyOfThemIs() throws {
        let root = try repo()
        let onto = Git.run(["rev-parse", "main"], in: root).output
        try commit("b.txt", "b\n", in: root)
        let first = Git.run(["rev-parse", "main"], in: root).output
        try commit("c.txt", "c\n", in: root)
        let head = Git.run(["rev-parse", "main"], in: root).output
        let record = LeadMergeRecord(commit: head, tested: true, onto: onto, at: 1)
        #expect(LeadReverts.find(root: root, base: "main", merges: [("x", record)]).isEmpty)
        // A later commit on main, then a revert of the first of the merge's two commits.
        try commit("d.txt", "d\n", in: root)
        #expect(Git.run(["revert", "--no-edit", first], in: root).ok)
        let revert = Git.run(["rev-parse", "main"], in: root).output
        #expect(LeadReverts.find(root: root, base: "main", merges: [("x", record)]) == ["x": revert])
        // One known as reverted already isn't looked for again.
        var known = record
        known.revertedBy = revert
        #expect(LeadReverts.find(root: root, base: "main", merges: [("x", known)]).isEmpty)
    }

    // MARK: record_incident

    @Test func recordIncidentWritesIncidentsMdAndPlansACheck() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["test_command": "swift test", "regression_command": "scripts/chat-bench --corpus hangs"]).isError)
        _ = lead.call("add_task", ["title": "Chat sync", "goal": "g", "acceptance": ["a"]])
        let result = lead.call("record_incident", ["what": "The chat hung on a long tool result", "evidence": "transcript 4f2a: no reply for 9 min after Read",
                                                   "task": "chat-sync"])
        #expect(!result.isError, "\(result.text)")
        #expect(result.text.contains("docs/lead/incidents.md") && result.text.contains("regression_command is `scripts/chat-bench --corpus hangs`"))
        let incidents = try String(contentsOfFile: BoardStore(root: root).recordPath("incidents.md"), encoding: .utf8)
        #expect(BoardStore(root: root).recordPath("incidents.md") == root + "/docs/lead/incidents.md")
        #expect(incidents.hasPrefix("# Incidents\n\n## "))
        #expect(incidents.contains("The chat hung on a long tool result\n\nEvidence: transcript 4f2a: no reply for 9 min after Read\n\nTask: chat-sync\n"))
        let check = try #require(BoardStore(root: root).load().tasks.last)
        #expect(check.status == .planned)
        #expect(check.title == "Turn this incident into a check: The chat hung on a long tool result")
        #expect(incidents.contains("Check: task \(check.slug) turns it into a check that runs before merge."))
        #expect(check.contract.goal.contains("runs before every merge") && check.contract.goal.contains("The chat hung"))
        #expect(check.contract.acceptance.contains { $0.contains("fails on the code as it was") })
        #expect(check.contract.acceptance.contains { $0.contains("`scripts/chat-bench --corpus hangs`") })
        #expect(check.contract.acceptance.contains("`swift test` passes"))
        #expect(check.contract.context.contains("Evidence: transcript 4f2a") && check.contract.context.contains("task chat-sync"))
        #expect(try String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8).contains("Incident: The chat hung on a long tool result (in chat-sync)"))

        // A second, with no task and no regression_command yet: the lead is told to set one.
        #expect(!lead.call("configure", ["regression_command": ""]).isError)
        let lost = lead.call("record_incident", ["what": "A user message was lost", "evidence": "sent 10:02, never in the transcript"])
        #expect(!lost.isError && lost.text.contains("set it with configure (regression_command)"))
        #expect(try String(contentsOfFile: BoardStore(root: root).recordPath("incidents.md"), encoding: .utf8).contains("## ") )
        #expect(BoardStore(root: root).load().tasks.filter { $0.title.hasPrefix("Turn this incident into a check") }.count == 2)
    }

    @Test func recordIncidentNeedsWhatAndEvidenceAndAKnownTask() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        #expect(lead.tools.contains { $0.name == "record_incident" })
        #expect(lead.call("record_incident", ["what": "x"]).isError)
        #expect(lead.call("record_incident", ["evidence": "y"]).isError)
        let unknown = lead.call("record_incident", ["what": "x", "evidence": "y", "task": "nope"])
        #expect(unknown.isError && unknown.text.contains("No task nope"))
        #expect(BoardStore(root: root).load().tasks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: BoardStore(root: root).recordPath("incidents.md")))
    }

    @Test func incidentsAreCommittedWithTheRecords() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        #expect(!lead.call("record_incident", ["what": "A merge was reverted", "evidence": "abc123 reverted def456"]).isError)
        let outcome = lead.records.flush(base: "main")
        guard case .committed(let commit) = outcome else { Issue.record("not committed: \(outcome)"); return }
        let files = Git.run(["show", "--name-only", "--format=", commit], in: root).output.split(whereSeparator: \.isNewline).map(String.init)
        #expect(files.contains("docs/lead/incidents.md"))
        #expect(Git.run(["show", "main:docs/lead/incidents.md"], in: root).output.contains("A merge was reverted"))
    }

    // MARK: ask_user about a task

    @Test func askUserTakesTheTaskItsAbout() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        _ = lead.call("add_task", ["title": "Change", "goal": "g", "acceptance": ["a"]])
        #expect(!lead.call("ask_user", ["question": "Which color?", "options": ["red", "blue"], "task": "change"]).isError)
        let refused = lead.call("ask_user", ["question": "Which?", "task": "nope"])
        #expect(refused.isError && refused.text.contains("No task nope"))
        let board = BoardStore(root: root).load()
        #expect(board.questions.count == 1 && board.questions[0].task == "change")
        #expect(board.task("change")?.score?.questions == 1)
    }
}
