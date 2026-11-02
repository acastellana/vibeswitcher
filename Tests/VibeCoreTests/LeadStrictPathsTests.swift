import Foundation
import Testing
@testable import VibeCore

/// strict_paths (workflow.md): on a branch touching one, an Important finding the finders' vote left unconfirmed holds
/// merge and auto_advance as an open one does, until the lead dismisses it, makes it a task, or a re-audit closes it.
/// A branch touching none, or a project that sets none, is as before.
struct LeadStrictPathsParseTests {
    @Test func strictPathsIsParsedAsAListOfGlobs() {
        #expect(LeadWorkflow.parse("---\nstrict_paths: src/signing/**, src/hot/** ,src/hardware/**\n---").strictPaths
                == ["src/signing/**", "src/hot/**", "src/hardware/**"])
        #expect(LeadWorkflow.parse("---\nstrict_paths:\n---").strictPaths == nil)
        #expect(LeadWorkflow.parse("---\nmax_workers: 2\n---").strictPaths == nil)
        let workflow = LeadWorkflow.parse("---\nstrict_paths: src/signing/**\n---")
        #expect(workflow.strictTouched(["src/signing/key.swift", "src/signing/deep/sign.swift", "src/ui/view.swift"])
                == ["src/signing/key.swift", "src/signing/deep/sign.swift"])
        #expect(LeadWorkflow().strictTouched(["src/signing/key.swift"]).isEmpty, "none set: nothing is strict")
        #expect(LeadWorkflow.configurable.contains("strict_paths") && LeadVault.guardedKeys.contains("strict_paths"))
        #expect(LeadWorkflow.template.contains("\nstrict_paths:\n"))
        #expect(LeadWorkflow.parse(LeadWorkflow.template).strictPaths == nil)
    }

    @Test func strictPathsHoldsOnlyLiveImportantFindingsOfAStrictBranch() throws {
        var ledger = LeadAuditLedger()
        let important = LeadFinding.Report(severity: .important, file: "b.txt", line: 1, evidence: "lone", status: .unconfirmed, failureScenario: "x")
        let nit = LeadFinding.Report(severity: .nit, file: "b.txt", line: 5, evidence: "lone nit", status: .unconfirmed)
        try ledger.record([], unconfirmed: [important, nit], commit: "c1", passes: true)
        #expect(ledger.blocking.isEmpty)
        #expect(ledger.holding(strict: false).isEmpty)
        #expect(ledger.holding(strict: true).map(\.id) == ["F1"], "the unconfirmed Nit never holds it")
        #expect(ledger.unconfirmedImportant.map(\.id) == ["F1"])
        try ledger.dismiss("F1", reason: "not a real problem")
        #expect(ledger.holding(strict: true).isEmpty)
    }
}

extension LeadAuditFindersTests {
    /// A lone Important finding (finder 3's), the other two finders clean: unconfirmed by the vote, and the verdict passes.
    func strictVote(_ runtime: FakeRuntime, strict: String, finding: [String: Any]? = nil,
                    edit: ((String) throws -> Void)? = nil) throws -> (root: String, lead: LeadToolset) {
        let (root, lead) = try ready(runtime, edit: edit)
        let set = call(lead, "configure", ["strict_paths": strict])
        #expect(!set.isError, "\(set.text)")
        #expect(!call(lead, "audit", ["task": "add-b"]).isError)
        let seats = try (1...3).map { try finder($0, runtime) }
        #expect(!call(seats[0], "submit_audit", Self.verdict).isError)
        #expect(!call(seats[1], "submit_audit", Self.verdict).isError)
        let last = call(seats[2], "submit_audit", Self.verdict.merging(["findings": [finding ?? Self.crash]]) { $1 })
        #expect(!last.isError, "\(last.text)")
        let verdict = try #require(vault.verdict(root: root, task: "add-b"))
        #expect(verdict.passes)
        #expect(vault.audits(root: root, task: "add-b")?.finding("F1")?.status == .unconfirmed)
        return (root, lead)
    }

    @Test func strictPathsIsSetWithConfigureAndReadBack() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        #expect(!call(lead, "configure", [:]).text.contains("strict_paths"), "not set: not shown")
        let set = call(lead, "configure", ["strict_paths": ["src/signing/**", " src/hot/** ", ""]])
        #expect(!set.isError, "\(set.text)")
        #expect(set.text.contains("- strict_paths: src/signing/**, src/hot/** (on a branch touching one"), "\(set.text)")
        #expect(LeadWorkflow.load(from: root + "/.vibeswitcher/workflow.md").strictPaths == ["src/signing/**", "src/hot/**"])
        #expect(!call(lead, "configure", ["strict_paths": "src/hardware/**"]).isError)
        #expect(LeadWorkflow.load(from: root + "/.vibeswitcher/workflow.md").strictPaths == ["src/hardware/**"])
        #expect(!call(lead, "configure", ["strict_paths": ""]).isError)
        #expect(LeadWorkflow.load(from: root + "/.vibeswitcher/workflow.md").strictPaths == nil)
    }

    @Test func strictPathsHoldTheMergeOnAnUnconfirmedImportantFindingAndDismissingItLiftsIt() throws {
        let runtime = FakeRuntime()
        let (root, lead) = try strictVote(runtime, strict: "b.txt")
        let finderPrompt = try prompt(2, runtime)
        #expect(finderPrompt.contains("kept as unconfirmed, which doesn't hold the merge back unless strict_paths holds it: this branch touches b.txt, "
            + "so an unconfirmed Important finding holds the merge as an open one does. So give each finding"), "\(finderPrompt)")
        let told = try #require(runtime.steered.last?.text)
        #expect(told.contains("F1 is unconfirmed by the finders' vote, and strict_paths holds it: the branch touches b.txt"), "\(told)")
        #expect(!told.contains(LeadAdvance.mergesItself), "\(told)")
        #expect(BoardStore(root: root).load().task("add-b")?.status == .failed)
        let refused = call(lead, "merge", ["task": "add-b"])
        #expect(refused.isError)
        #expect(refused.text.contains("Not merged: add-b has 1 Important finding holding it back: add-b:F1 b.txt:1"), "\(refused.text)")
        #expect(refused.text.contains("strict_paths holds it: the branch touches b.txt"), "\(refused.text)")
        #expect(!Git.run(["show", "main:b.txt"], in: root).ok)
        let status = call(lead, "status").text
        #expect(status.contains("held by strict_paths F1 b.txt:1 (unconfirmed Important; the branch touches b.txt)"), "\(status)")
        let board = call(lead, "board", ["task": "add-b"]).text
        #expect(board.contains("Held by strict_paths: F1 is unconfirmed by the finders' vote, and strict_paths holds it"), "\(board)")

        #expect(!call(lead, "dismiss_finding", ["task": "add-b", "id": "F1", "reason": "the contract allows bee"]).isError)
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(Git.run(["show", "main:b.txt"], in: root).ok)
    }

    /// A batch (merge_batching, merge with tasks) checks strict_paths for each task as merge does alone: the held one
    /// stays out, held, and the other merges on the batch's run.
    @Test func strictPathsHoldATaskOutOfABatchAndTheRestMerge() throws {
        let runtime = FakeRuntime()
        let (root, lead) = try strictVote(runtime, strict: "b.txt")
        #expect(!call(lead, "add_task", ["title": "Add d", "goal": "d.txt exists", "acceptance": ["test -f d.txt"], "review": "none"]).isError)
        #expect(!call(lead, "start_worker", ["task": "add-d"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-d")
        for (file, text) in ["b.txt": "bee\n", "d.txt": "dee\n"] { try text.write(toFile: worktree + "/" + file, atomically: true, encoding: .utf8) }
        Git.run(["add", "b.txt", "d.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add d"], in: worktree)
        #expect(!call(try seat("worker-add-d", runtime), "report", doneReport("added d")).isError)

        let merged = call(lead, "merge", ["tasks": ["add-b", "add-d"]])
        #expect(!merged.isError, "\(merged.text)")
        #expect(merged.text.contains("add-b: not merged. Not merged: add-b has 1 Important finding holding it back: add-b:F1 b.txt:1"), "\(merged.text)")
        #expect(merged.text.contains("add-d: merged at"), "\(merged.text)")
        #expect(BoardStore(root: root).load().task("add-b")?.status == .failed && BoardStore(root: root).load().task("add-d")?.status == .done)
        #expect(Git.run(["show", "main:d.txt"], in: root).ok)
    }

    /// A held finding is a concrete concern: the lead may audit the same commit again (to judge a worker's
    /// disagreement), where a clean pass with nothing held is refused.
    @Test func strictPathsLetTheLeadAuditTheSameCommitAgainWhileAFindingIsHeld() throws {
        let runtime = FakeRuntime()
        let (_, lead) = try strictVote(runtime, strict: "b.txt")
        let again = call(lead, "audit", ["task": "add-b"])
        #expect(!again.isError && again.text.contains("3 finders started on add-b"), "\(again.text)")
    }

    /// A file moved out of a strict path touches it: git's rename detection would list only its new path.
    @Test func strictPathsHoldABranchThatMovesAFileOutOfOne() throws {
        let runtime = FakeRuntime()
        let (root, lead) = try strictVote(runtime, strict: "a.txt") { worktree in
            #expect(Git.run(["mv", "a.txt", "moved.txt"], in: worktree).ok)
        }
        let refused = call(lead, "merge", ["task": "add-b"])
        #expect(refused.isError)
        #expect(refused.text.contains("strict_paths holds it: the branch touches a.txt"), "\(refused.text)")
        #expect(!Git.run(["show", "main:b.txt"], in: root).ok)
    }

    @Test func strictPathsDontHoldABranchTouchingNone() throws {
        let runtime = FakeRuntime()
        let (root, lead) = try strictVote(runtime, strict: "src/signing/**, src/hot/**")
        let finderPrompt = try prompt(2, runtime)
        #expect(finderPrompt.contains("kept as unconfirmed, which doesn't hold the merge back. So give each finding its exact file and line."), "as before: \(finderPrompt)")
        let told = try #require(runtime.steered.last?.text)
        #expect(told.contains("(unconfirmed ones don't hold the merge back"), "\(told)")
        #expect(BoardStore(root: root).load().task("add-b")?.status == .review)
        #expect(!call(lead, "status").text.contains("held by strict_paths"))
        #expect(call(lead, "audit", ["task": "add-b"]).text.contains("Not audited: add-b's audit"), "a clean pass, nothing held: no second round")
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
    }

    @Test func strictPathsHoldIsLiftedByMakingTheFindingATask() throws {
        let runtime = FakeRuntime()
        let (root, lead) = try strictVote(runtime, strict: "b.txt")
        #expect(call(lead, "merge", ["task": "add-b"]).isError)
        let added = call(lead, "add_task", ["from_finding": "add-b:F1"])
        #expect(!added.isError, "\(added.text)")
        #expect(added.text.contains("add-b:F1 is closed on add-b as moved to it"), "\(added.text)")
        #expect(added.text.contains("it's back in review"), "\(added.text)")
        #expect(vault.audits(root: root, task: "add-b")?.finding("F1")?.status == .dismissed)
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
    }

    @Test func strictPathsHoldIsLiftedByAPassingReauditThatClosesIt() throws {
        let runtime = FakeRuntime()
        let (root, lead) = try strictVote(runtime, strict: "b.txt")
        // The worker fixes it, answers, and reports done: its re-audit is asked about F1, with the answer.
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "b\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["commit", "-qam", "b, as the contract says"], in: worktree)
        let worker = try seat("worker-add-b", runtime)
        let answered = call(worker, "answer_findings", ["answers": [["id": "F1", "answer": "fixed", "reason": "b.txt says b"]]])
        #expect(!answered.isError, "\(answered.text)")
        #expect(!call(worker, "report", doneReport("fixed F1")).isError)
        #expect(call(lead, "merge", ["task": "add-b"]).isError, "not audited since")
        #expect(!call(lead, "audit", ["task": "add-b"]).isError)
        let prompt = try prompt(1, runtime)
        #expect(prompt.contains("- F1 [Important, unconfirmed by the last vote; strict_paths holds the merge on it] b.txt:1"), "\(prompt)")
        #expect(prompt.contains("The worker's answer: fixed"), "\(prompt)")
        let fixed: [String: Any] = ["id": "F1", "severity": "Important", "file": "b.txt", "line": 1, "evidence": "b.txt says b now", "status": "fixed", "reason": "checked"]
        let seats = try (1...3).map { try finder($0, runtime) }
        for seat in seats { #expect(!call(seat, "submit_audit", Self.verdict.merging(["findings": [fixed]]) { $1 }).isError) }
        #expect(vault.audits(root: root, task: "add-b")?.finding("F1")?.status == .fixed)
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
    }
}

extension LeadAdvanceTests {
    /// An audit task's 3 finders vote one lone Important finding, unconfirmed, on b.txt; `strict`: strict_paths.
    func strictAudit(strict: String) throws -> (root: String, runtime: FakeRuntime, advancing: Advancing) {
        let (root, runtime, lead) = try team(["audit_finders": 3, "strict_paths": strict])
        let advancing = Advancing(lead)
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "review": "audit"])
        #expect(advancing.until { task("add-b", root)?.status == .running })
        try work("add-b", file: "b.txt", root: root, runtime)
        #expect(advancing.until { task("add-b", root)?.panel?.size == 3 && vault.current(.verifier, root: root, task: "add-b") != nil })
        let clean: [String: Any] = ["completion": "complete", "integrity": "clean", "summary": "checked", "tests": "passed"]
        let lone: [String: Any] = ["severity": "Important", "file": "b.txt", "line": 1, "evidence": "only finder 3 sees it",
                                   "failure_scenario": "cat b.txt gives bee where the contract wants b"]
        #expect(!(try seat("verify-add-b", runtime)).call("submit_audit", clean).isError)
        #expect(!(try seat("finder2-add-b", runtime)).call("submit_audit", clean).isError)
        let last = try seat("finder3-add-b", runtime).call("submit_audit", clean.merging(["findings": [lone]]) { $1 })
        #expect(!last.isError, "\(last.text)")
        #expect(vault.audits(root: root, task: "add-b")?.finding("F1")?.status == .unconfirmed)
        return (root, runtime, advancing)
    }

    @Test func strictPathsKeepAutoAdvanceFromMergingAnUnconfirmedImportantFinding() throws {
        let (root, runtime, advancing) = try strictAudit(strict: "b.txt")
        defer { advancing.stop() }
        // Sent to the worker as an open one would be, and not merged.
        #expect(advancing.until { toWorker("add-b", root, runtime).contains { $0.contains("F1") && $0.contains("strict_paths holds it") } })
        advancing.settle()
        #expect(task("add-b", root)?.status != .done)
        #expect(!Git.run(["show", "main:b.txt"], in: root).ok)
        #expect(!reports(runtime).contains { $0.contains("Merged add-b") }, "\(reports(runtime))")
    }

    @Test func strictPathsLetAutoAdvanceMergeABranchTouchingNone() throws {
        let (root, runtime, advancing) = try strictAudit(strict: "src/signing/**")
        defer { advancing.stop() }
        #expect(advancing.until { task("add-b", root)?.status == .done && reports(runtime).contains { $0.contains("Merged add-b") } })
        #expect(Git.run(["show", "main:b.txt"], in: root).output == "bee")
    }
}
