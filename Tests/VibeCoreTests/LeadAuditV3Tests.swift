import Foundation
import Testing
@testable import VibeCore

/// Lead process v3, phase 2 (2026-10-25): Important only with a failure, the worker answers each finding (fixed or
/// disagree), the re-audit judges the answers, two rounds then a re-roll, and audits on another model than the workers'.
extension LeadFindingsToolTests {
    /// The last session started as `name`'s system prompt.
    func prompt(of name: String, _ runtime: FakeRuntime) throws -> String {
        let spawn = try #require(runtime.spawned.last { $0.command.contains("--name '\(name)'") })
        let range = try #require(spawn.command.range(of: #"--append-system-prompt-file '([^']+)'"#, options: .regularExpression))
        let path = String(spawn.command[range].dropFirst("--append-system-prompt-file '".count).dropLast())
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    static let crash: [String: Any] = ["severity": "Important", "file": "b.txt", "line": 1, "evidence": "b.txt says bee, the contract wants b",
                                       "failure_scenario": "test -f b.txt run on the branch: b.txt holds bee, not b", "status": "open"]
    static let doubt: [String: Any] = ["severity": "Important", "file": "b.txt", "line": 1, "evidence": "the file could be named better"]

    @Test func anImportantFindingWithoutAFailureScenarioIsStoredAsANit() throws {
        // The parser: Important needs failure_scenario; a re-audit's mark of an earlier finding doesn't.
        let parsed = try LeadToolset.parsedFindings([Self.crash, Self.doubt.merging(["line": 2]) { $1 },
                                                     ["id": "F9", "severity": "Important", "file": "b.txt", "line": 3, "evidence": "fixed now", "status": "fixed"]])
        #expect(parsed.reports.map(\.severity) == [.important, .nit, .important])
        #expect(parsed.reports[0].failureScenario == "test -f b.txt run on the branch: b.txt holds bee, not b")
        #expect(parsed.demoted == ["b.txt:2"])

        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        _ = call(lead, "audit", ["task": "add-b"])
        // The brief and the schema ask for it.
        let brief = try verifierPrompt(runtime)
        #expect(brief.contains("Important only for a concrete problem that blocks the merge") && brief.contains("failure_scenario"), "\(brief)")
        #expect(brief.contains("an Important finding without failure_scenario is recorded as a Nit"))
        let verifier = try seat("verify-add-b", runtime)
        #expect(try #require(verifier.tools.first { $0.name == "submit_audit" }).properties["findings"]?.description.contains("failure_scenario") == true)

        let submitted = call(verifier, "submit_audit", ["completion": "complete", "integrity": "clean", "summary": "checked",
                                                        "findings": [Self.doubt.merging(["line": 2]) { $1 }, Self.crash]])
        #expect(!submitted.isError, "\(submitted.text)")
        #expect(submitted.text.contains("Recorded as Nit, having no failure_scenario: b.txt:2"), "\(submitted.text)")
        let ledger = try #require(vault.audits(root: root, task: "add-b"))
        #expect(ledger.findings.map(\.severity) == [.nit, .important])
        #expect(ledger.findings[1].failureScenario == "test -f b.txt run on the branch: b.txt holds bee, not b")
        #expect(ledger.blocking.map(\.id) == ["F2"])
        // The lead sees the failure with the finding.
        #expect(runtime.steered.last?.text.contains("(fails: test -f b.txt run on the branch: b.txt holds bee, not b)") == true)
    }

    @Test func theWorkerAnswersFindingsAndTheReauditJudgesThem() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        let second: [String: Any] = ["severity": "Important", "file": "b.txt", "line": 4, "evidence": "b.txt has no header",
                                     "failure_scenario": "a reader that wants a header line rejects b.txt", "status": "open"]
        _ = try audit(lead, runtime, ["completion": "complete", "integrity": "clean", "summary": "checked", "findings": [Self.crash, second]])
        #expect(vault.audits(root: root, task: "add-b")?.blocking.map(\.id) == ["F1", "F2"])

        let worker = try seat("worker-add-b", runtime)
        #expect(try prompt(of: "worker-add-b", runtime).contains("answer each open one with answer_findings"))
        // Refused whole: a fix with nothing committed since the audit, an id that isn't there, a disagreement without a reason.
        let early = call(worker, "answer_findings", ["answers": [["id": "F1", "answer": "fixed"]]])
        #expect(early.isError && early.text.contains("commit the fix first"), "\(early.text)")
        try "b\n".write(toFile: Worktrees.path(root: root, slug: "add-b") + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["commit", "-qam", "b.txt says b"], in: Worktrees.path(root: root, slug: "add-b"))
        let unknown = call(worker, "answer_findings", ["answers": [["id": "F7", "answer": "fixed"]]])
        #expect(unknown.isError && unknown.text.contains("no finding F7"), "\(unknown.text)")
        let bare = call(worker, "answer_findings", ["answers": [["id": "F1", "answer": "fixed"], ["id": "F2", "answer": "disagree"]]])
        #expect(bare.isError && bare.text.contains("say why you disagree"), "\(bare.text)")
        #expect(BoardStore(root: root).load().task("add-b")?.answers == nil, "nothing recorded on a refusal")

        let answered = call(worker, "answer_findings", ["answers": [["id": "f1", "answer": "fixed", "reason": "b.txt says b"],
                                                                    ["id": "F2", "answer": "disagree", "reason": "the contract asks for no header; nothing reads one"]]])
        #expect(!answered.isError, "\(answered.text)")
        #expect(runtime.steered.last?.text.contains("answered findings: add-b:F1 fixed at") == true)
        #expect(runtime.steered.last?.text.contains("add-b:F2 disagrees: the contract asks for no header") == true)
        // The lead sees them in board(task), each under its finding.
        let board = call(lead, "board", ["task": "add-b"]).text
        #expect(board.contains("- add-b:F2 b.txt:4 — b.txt has no header (fails: a reader that wants a header line rejects b.txt)\n  The worker's answer: disagrees: the contract asks for no header; nothing reads one"), "\(board)")
        #expect(!call(worker, "report", doneReport("fixed F1, answered F2")).isError)

        // The re-audit is told the answers and how to judge them.
        _ = call(lead, "audit", ["task": "add-b"])
        let recheck = try verifierPrompt(runtime)
        #expect(recheck.contains("- F2 [Important] b.txt:4: b.txt has no header\n  Fails when: a reader that wants a header line rejects b.txt\n  The worker's answer: disagrees: the contract asks for no header; nothing reads one"), "\(recheck)")
        #expect(recheck.contains("judge each answer, don't review the finding from scratch") && recheck.contains("\"disagreement accepted:\""))
        // It accepts the disagreement: the finding closes, nothing holds the merge back.
        let verifier = try seat("verify-add-b", runtime)
        let verdict = call(verifier, "submit_audit", ["completion": "complete", "integrity": "clean", "summary": "F1 fixed; F2's reason holds",
                                                      "findings": [["id": "F1", "severity": "Important", "file": "b.txt", "line": 1, "evidence": "b.txt says b", "status": "fixed"],
                                                                   ["id": "F2", "severity": "Important", "file": "b.txt", "line": 4, "evidence": "no reader needs a header",
                                                                    "status": "dismissed", "reason": "disagreement accepted: the contract asks for none"]]])
        #expect(!verdict.isError, "\(verdict.text)")
        let ledger = try #require(vault.audits(root: root, task: "add-b"))
        #expect(ledger.blocking.isEmpty)
        #expect(ledger.finding("F2")?.status == .dismissed && ledger.finding("F2")?.closedBy == "verifier")
        // Answers count for the audit after them only.
        #expect(BoardStore(root: root).load().task("add-b")?.currentAnswers(ledger).isEmpty == true)
        #expect(!call(lead, "merge", ["task": "add-b"]).isError)
    }

    @Test func aRerollKeepsTheOldBranchAndStartsAFreshWorkerWithWhatTheRoundsLearned() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        let still: [String: Any] = ["id": "F1", "severity": "Important", "file": "b.txt", "line": 1, "evidence": "still bee", "status": "open"]
        _ = try audit(lead, runtime, ["completion": "complete", "integrity": "clean", "summary": "1", "findings": [Self.crash]])
        try work(runtime, root: root, file: "c.txt", text: "1\n")
        #expect(!call(try seat("worker-add-b", runtime), "answer_findings",
                      ["answers": [["id": "F1", "answer": "disagree", "reason": "bee is how b is spelled out"]]]).isError)
        _ = try audit(lead, runtime, ["completion": "complete", "integrity": "clean", "summary": "2", "findings": [still]])
        #expect(runtime.steered.last?.text.contains("Reconsider the approach") == true)
        let old = Git.run(["rev-parse", "agent/add-b"], in: root).output
        let oldWorker = try #require(BoardStore(root: root).load().task("add-b")?.worker)

        #expect(call(lead, "update_task", ["task": "add-b", "reroll": true, "status": "planned"]).isError, "reroll goes without status")
        let rerolled = call(lead, "update_task", ["task": "add-b", "reroll": true, "append_context": "b.txt holds exactly the letter b."])
        #expect(!rerolled.isError, "\(rerolled.text)")
        #expect(rerolled.text.contains("its branch is kept as archive/add-b-1 (at \(old.prefix(8)))") && rerolled.text.contains("Worker started on add-b"), "\(rerolled.text)")
        // The old worker stopped; its branch kept under the archive name; agent/add-b is new, from main.
        #expect(runtime.killed.contains(oldWorker))
        #expect(Git.run(["rev-parse", "archive/add-b-1"], in: root).output == old)
        #expect(Git.run(["rev-parse", "agent/add-b"], in: root).output == Git.run(["rev-parse", "main"], in: root).output)
        #expect(!FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: "add-b") + "/b.txt"))
        // The fresh worker's brief carries the contract change and the summary of the findings and answers.
        let brief = try prompt(of: "worker-add-b", runtime)
        #expect(brief.contains("b.txt holds exactly the letter b.\n\n## Re-roll 1: what the earlier attempt's audits learned"), "\(brief)")
        #expect(brief.contains("The earlier attempt is kept on the branch archive/add-b-1"))
        #expect(brief.contains("- F1 [Important, open] b.txt:1: b.txt says bee, the contract wants b Fails when: test -f b.txt run on the branch: b.txt holds bee, not b The worker's answer: disagrees: bee is how b is spelled out"), "\(brief)")
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.status == .running && task.worker != oldWorker && task.attempts == 2)
        #expect(task.rerolls == [LeadReroll(archive: "archive/add-b-1", commit: old, round: 2, at: try #require(task.rerolls?.first?.at))])
        #expect(task.answers == nil)
        // Its rounds count from zero; its findings stay for the fresh branch's first audit.
        let ledger = try #require(vault.audits(root: root, task: "add-b"))
        #expect(ledger.failedRounds == 0 && !ledger.reconsider && ledger.blocking.map(\.id) == ["F1"])
        #expect(vault.verdict(root: root, task: "add-b") == nil)

        try work(runtime, root: root, file: "b.txt", text: "b\n")
        _ = call(lead, "audit", ["task": "add-b"])
        let recheck = try verifierPrompt(runtime)
        #expect(recheck.contains("the task was re-rolled after round 2") && recheck.contains("as in a first audit"), "\(recheck)")
        // A second re-roll gets the next archive name.
        _ = call(try seat("verify-add-b", runtime), "submit_audit", ["completion": "incomplete", "integrity": "clean", "summary": "3", "findings": [still]])
        #expect(call(lead, "update_task", ["task": "add-b", "reroll": true]).text.contains("archive/add-b-2"))
    }

    @Test func auditsRunOnAnotherModelThanTheWorkersUnlessVerifierModelIsSet() throws {
        let home = temp.url("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        // Which model a Claude command runs: its own --model, else the settings in its home.
        #expect(LeadWorkflow.claudeModel(command: "claude --dangerously-skip-permissions") == nil)
        #expect(LeadWorkflow.claudeModel(command: "claude --model 'sonnet' --verbose") == "sonnet")
        #expect(LeadWorkflow.claudeModel(command: "claude --model=claude-fable-5-1") == "claude-fable-5-1")
        #expect(LeadWorkflow.claudeModel(command: "claude", home: home.path) == nil)
        try #"{"model": "opus", "hooks": {}}"#.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        #expect(LeadWorkflow.claudeModel(command: "claude", home: home.path) == "opus")
        #expect(LeadWorkflow.claudeModel(command: "claude --model sonnet", home: home.path) == "sonnet")
        // Another model, at least as capable; verifier_model set still wins.
        #expect(LeadWorkflow().auditModel(workerModel: nil) == "fable")
        #expect(LeadWorkflow().auditModel(workerModel: "opus") == "fable")
        #expect(LeadWorkflow().auditModel(workerModel: "claude-fable-5-1") == "opus")
        var set = LeadWorkflow()
        set.verifierModel = "sonnet"
        #expect(set.auditModel(workerModel: "sonnet") == "sonnet")

        // Through audit: the verifier starts on it.
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        _ = call(lead, "audit", ["task": "add-b"])
        #expect(runtime.spawned.last?.command.contains("--model 'fable'") == true)
        #expect(runtime.spawned.last { $0.command.contains("--name 'worker-add-b'") }?.command.contains("--model") == false)
        #expect(call(lead, "configure").text.contains("verifier_model: not set: audits run on fable"))
        runtime.claude = "claude --model fable"
        _ = call(lead, "audit", ["task": "add-b"])
        #expect(runtime.spawned.last?.command.contains("--model 'opus'") == true)
    }
}
