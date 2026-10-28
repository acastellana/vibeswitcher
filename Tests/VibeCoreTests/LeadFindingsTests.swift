import Foundation
import Testing
@testable import VibeCore

/// An audit's findings as a state machine (`LeadAuditLedger`): what a round may add or close, what it may never raise
/// again, and when the rounds call for reconsidering the approach.
struct LeadAuditLedgerTests {
    typealias Report = LeadFinding.Report

    func important(_ file: String = "Sources/A.swift", _ line: Int = 12, id: String? = nil, status: LeadFinding.Status = .open, reason: String? = nil) -> Report {
        Report(id: id, severity: .important, file: file, line: line, evidence: "swift test fails: testA", status: status, reason: reason)
    }

    @Test func aFirstAuditRaisesItsFindingsOpenWithIDs() throws {
        var ledger = LeadAuditLedger()
        try ledger.record([important(), Report(severity: .nit, file: "Sources/B.swift", line: 3, evidence: "typo"),
                           Report(severity: .preExisting, file: "Sources/C.swift", line: 9, evidence: "leaks on main too")],
                          commit: "c1", passes: true)
        #expect(ledger.findings.map(\.id) == ["F1", "F2", "F3"])
        #expect(ledger.findings.allSatisfy { $0.isOpen && $0.raised == 1 })
        #expect(ledger.rounds == 1 && ledger.commit == "c1")
        // Only the Important one blocks; the Pre-existing one isn't the branch's to recheck.
        #expect(ledger.blocking.map(\.id) == ["F1"])
        #expect(ledger.toRecheck.map(\.id) == ["F1", "F2"])
        #expect(ledger.failedRounds == 1)
        #expect(ledger.bySeverity.map(\.severity) == [.important, .nit, .preExisting])
    }

    func verdict(_ completion: LeadEvidence.Completion = .complete, tests: LeadVault.TestRun? = .passed, commit: String = "c1") -> LeadVault.Verdict {
        LeadVault.Verdict(task: "t", completion: completion, integrity: .violation, summary: "s", commit: commit, verifier: "v", session: "s", at: 0, tests: tests)
    }

    /// What lets a failed verdict merge on the lead's dismissals: only the Important findings it left open, all dismissed
    /// by the lead after it, on a complete audit whose tests passed.
    @Test func aVerdictStandsOnTheLeadsDismissalsOnlyWhenTheyAreAllThatFailedIt() throws {
        var ledger = LeadAuditLedger()
        try ledger.record([important(), important("Sources/B.swift", 3)], commit: "c1", passes: false)
        #expect(verdict().dismissed(in: ledger) == nil, "open ones")
        try ledger.dismiss("F1", reason: "a routine call")
        #expect(verdict().dismissed(in: ledger) == nil, "one still open")
        try ledger.dismiss("F2", reason: "a routine call")
        #expect(verdict().dismissed(in: ledger)?.map(\.id) == ["F1", "F2"])
        #expect(verdict(.incomplete).dismissed(in: ledger) == nil)
        #expect(verdict(.blocked).dismissed(in: ledger) == nil)
        #expect(verdict(tests: .failed).dismissed(in: ledger) == nil)
        #expect(verdict(tests: .notRun).dismissed(in: ledger) == nil)
        #expect(verdict(tests: nil).dismissed(in: ledger) == nil)
        #expect(verdict(commit: "c2").dismissed(in: ledger) == nil, "another audit's ledger")
        // Dismissed before a later round that failed again: that round's failure isn't what the lead dismissed.
        try ledger.record([], commit: "c2", passes: false, changed: [])
        #expect(verdict(commit: "c2").dismissed(in: ledger) == nil)
        // A failure with no Important finding at all: nothing the lead looked at explains it.
        var none = LeadAuditLedger()
        try none.record([Report(severity: .nit, file: "a", line: 1, evidence: "e")], commit: "c1", passes: false)
        #expect(verdict().dismissed(in: none) == nil)
        // The verifier closing one isn't the lead's dismissal.
        var fixed = LeadAuditLedger()
        try fixed.record([important()], commit: "c1", passes: false)
        try fixed.record([important(id: "F1", status: .dismissed, reason: "not a problem")], commit: "c1", passes: false, changed: [])
        #expect(verdict().dismissed(in: fixed) == nil)
    }

    @Test func aCleanRoundWithOnlyNitsAndPreExistingOnesIsNotAFailure() throws {
        var ledger = LeadAuditLedger()
        try ledger.record([Report(severity: .nit, file: "a", line: 1, evidence: "e"), Report(severity: .preExisting, file: "b", line: 1, evidence: "e")],
                          commit: "c1", passes: true)
        #expect(ledger.blocking.isEmpty)
        #expect(ledger.failedRounds == 0)
        #expect(!ledger.reconsider)
    }

    @Test func aReauditClosesWhatWasFixedAndMustSaySoForEachOpenOne() throws {
        var ledger = LeadAuditLedger()
        try ledger.record([important(), Report(severity: .nit, file: "Sources/B.swift", line: 3, evidence: "typo")], commit: "c1", passes: false)
        let before = ledger
        // Leaving out an open one is refused, and changes nothing.
        #expect(throws: LeadAuditLedger.Refusal.self) {
            try ledger.record([self.important(id: "F1", status: .fixed)], commit: "c2", passes: true, changed: ["Sources/A.swift"])
        }
        #expect(ledger == before)
        try ledger.record([important(id: "f1", status: .fixed), Report(id: "F2", severity: .nit, file: "Sources/B.swift", line: 3, evidence: "still", status: .open)],
                          commit: "c2", passes: true, changed: ["Sources/A.swift"])
        #expect(ledger.finding("F1")?.status == .fixed)
        #expect(ledger.finding("F1")?.closed == 2)
        #expect(ledger.finding("F1")?.closedBy == "verifier")
        #expect(ledger.finding("F2")?.isOpen == true)
        #expect(ledger.blocking.isEmpty)
        #expect(ledger.failedRounds == 0)
        #expect(ledger.rounds == 2 && ledger.commit == "c2")
    }

    @Test func aClosedFindingIsNeverRaisedAgain() throws {
        var ledger = LeadAuditLedger()
        try ledger.record([important()], commit: "c1", passes: false)
        try ledger.record([important(id: "F1", status: .fixed)], commit: "c2", passes: true, changed: ["Sources/A.swift"])
        let closed = ledger
        // Reopened by its id…
        #expect(throws: LeadAuditLedger.Refusal.self) {
            try ledger.record([self.important(id: "F1", status: .open)], commit: "c3", passes: false, changed: ["Sources/A.swift"])
        }
        // …or raised as a new one at its place.
        #expect(throws: LeadAuditLedger.Refusal.self) {
            try ledger.record([self.important()], commit: "c3", passes: false, changed: ["Sources/A.swift"])
        }
        #expect(ledger == closed)
        // Saying again that it's fixed is no news, and fine.
        try ledger.record([important(id: "F1", status: .fixed)], commit: "c3", passes: true, changed: [])
        #expect(ledger.findings.count == 1)
        #expect(ledger.finding("F1")?.closed == 2)
    }

    @Test func aReauditRaisesNewFindingsFromTheNewDiffOnly() throws {
        var ledger = LeadAuditLedger()
        try ledger.record([], commit: "c1", passes: true)
        #expect(throws: LeadAuditLedger.Refusal.self) {
            try ledger.record([self.important("Sources/Untouched.swift", 4)], commit: "c2", passes: false, changed: ["Sources/A.swift"])
        }
        try ledger.record([important("Sources/A.swift", 4)], commit: "c2", passes: false, changed: ["Sources/A.swift"])
        #expect(ledger.findings.map(\.place) == ["Sources/A.swift:4"])
        #expect(ledger.finding("F1")?.raised == 2)
    }

    @Test func aNewFindingIsOpenAndNotAtAnOpenOnesPlace() throws {
        var ledger = LeadAuditLedger()
        #expect(throws: LeadAuditLedger.Refusal.self) { try ledger.record([self.important(status: .fixed)], commit: "c1", passes: true) }
        #expect(throws: LeadAuditLedger.Refusal.self) { try ledger.record([self.important(), self.important()], commit: "c1", passes: true) }
        try ledger.record([important()], commit: "c1", passes: true)
        #expect(throws: LeadAuditLedger.Refusal.self) {
            try ledger.record([self.important(id: "F1"), self.important()], commit: "c2", passes: true, changed: ["Sources/A.swift"])
        }
    }

    @Test func theLeadDismissesAnOpenFindingWithAReason() throws {
        var ledger = LeadAuditLedger()
        try ledger.record([important()], commit: "c1", passes: true)
        #expect(throws: LeadAuditLedger.Refusal.self) { try ledger.dismiss("F1", reason: "  ") }
        #expect(throws: LeadAuditLedger.Refusal.self) { try ledger.dismiss("F9", reason: "no") }
        try ledger.dismiss("F1", reason: "the contract allows it", followUp: "fix-a")
        #expect(ledger.blocking.isEmpty)
        #expect(ledger.finding("F1")?.closedBy == "lead")
        #expect(ledger.finding("F1")?.followUp == "fix-a")
        #expect(throws: LeadAuditLedger.Refusal.self) { try ledger.dismiss("F1", reason: "again") }
        // A dismissed one isn't raised again either.
        #expect(throws: LeadAuditLedger.Refusal.self) {
            try ledger.record([self.important()], commit: "c2", passes: true, changed: ["Sources/A.swift"])
        }
    }

    @Test func twoRoundsThatLeaveImportantFindingsOpenCallForReconsidering() throws {
        #expect(LeadAuditLedger.roundCap == 2)
        var ledger = LeadAuditLedger()
        try ledger.record([important()], commit: "c1", passes: true)
        #expect(!ledger.reconsider)
        try ledger.record([important(id: "F1")], commit: "c2", passes: true, changed: ["Sources/A.swift"])
        #expect(ledger.failedRounds == 2)
        #expect(ledger.reconsider)
        // Re-planned: the rounds count from there.
        var replanned = ledger
        replanned.replan()
        #expect(!replanned.reconsider)
        // A round that leaves nothing Important open ends it.
        try ledger.record([important(id: "F1", status: .fixed)], commit: "c3", passes: true, changed: ["Sources/A.swift"])
        #expect(ledger.failedRounds == 0)
        #expect(!ledger.reconsider)
    }

    @Test func failedVerdictsCountAsFailedRoundsToo() throws {
        var ledger = LeadAuditLedger()
        try ledger.record([], commit: "c1", passes: false, changed: [])
        #expect(!ledger.reconsider)
        try ledger.record([], commit: "c2", passes: false, changed: [])
        #expect(ledger.reconsider)
    }

    /// What counted toward reconsidering is said: findings left open, failed verdicts, or both.
    @Test func theReconsiderCauseNamesWhatCounted() throws {
        var open = LeadAuditLedger()
        try open.record([important(), important("Sources/B.swift", 3)], commit: "c1", passes: true)
        try open.record([important(id: "F1"), important(id: "F2")], commit: "c2", passes: true, changed: ["Sources/A.swift"])
        #expect(open.reconsiderCause == "2 Important findings left open across 2 rounds")

        var failed = LeadAuditLedger()
        for commit in ["c1", "c2"] { try failed.record([], commit: commit, passes: false, changed: []) }
        #expect(failed.reconsiderCause == "2 failed verdicts in a row")

        var both = LeadAuditLedger()
        try both.record([important()], commit: "c1", passes: false)
        try both.record([important(id: "F1")], commit: "c2", passes: true, changed: [])
        #expect(both.reconsider)
        #expect(both.reconsiderCause == "2 audits in a row: 1 failed verdict, and 1 that left Important findings open (1 open now)")

        // A ledger recorded before failed verdicts were counted reads, and says it as before.
        var old = try JSONDecoder().decode(LeadAuditLedger.self, from: Data(#"{"findings":[],"rounds":3,"failedRounds":3,"commit":"c3","passed":false}"#.utf8))
        #expect(old.failedVerdicts == nil && old.reconsider)
        #expect(old.reconsiderCause == "3 audits in a row left Important findings open or failed")
        old.replan()
        #expect(old.failedVerdicts == 0)
    }

    /// The lead dismissing the last Important finding on a passing round makes it a clean one: the rounds start over.
    @Test func dismissingTheLastImportantFindingOnAPassStartsTheRoundsOver() throws {
        var ledger = LeadAuditLedger()
        try ledger.record([important()], commit: "c1", passes: true)
        try ledger.record([important(id: "F1")], commit: "c2", passes: true, changed: ["Sources/A.swift"])
        #expect(ledger.reconsider)
        try ledger.dismiss("F1", reason: "the contract allows it")
        #expect(ledger.failedRounds == 0 && ledger.failedVerdicts == 0 && !ledger.reconsider)

        // On a failed verdict it doesn't: that round still failed.
        var failing = LeadAuditLedger()
        try failing.record([important()], commit: "c1", passes: false)
        try failing.dismiss("F1", reason: "not a problem")
        #expect(failing.failedRounds == 1)
    }

    /// Each re-audit scope names its own diff and the command that gives it.
    @Test func eachReauditScopeSaysWhatItCovers() {
        func prompt(_ scope: LeadPrompts.Reaudit.Scope, stat: String = "") -> String {
            LeadPrompts.recheck(.init(round: 2, since: "aaaaaaaa1111", head: "bbbbbbbb2222", open: [], known: [], stat: stat, diff: nil, base: "dev", scope: scope))
        }
        #expect(prompt(.since).contains("the worker changed it since") && prompt(.since).contains("`git diff aaaaaaaa1111 bbbbbbbb2222`"))
        #expect(prompt(.since).contains("(no file differs from aaaaaaaa)"))
        let rewritten = prompt(.wholeBranch(sameCommit: false))
        #expect(rewritten.contains("no longer in its history") && rewritten.contains("`git diff dev...bbbbbbbb2222`"), "\(rewritten)")
        let same = prompt(.wholeBranch(sameCommit: true), stat: " b.txt | 1 +")
        #expect(same.contains("this very commit, aaaaaaaa") && same.contains("The branch's whole change since its merge-base with dev:\n b.txt | 1 +"), "\(same)")
        let own = prompt(.ownFiles(["Sources/A.swift", "docs/a b.md"]))
        #expect(own.contains("`git diff dev...bbbbbbbb2222 -- Sources/A.swift 'docs/a b.md'`"), "\(own)")
        #expect(prompt(.ownFiles([])).contains("(its own commits since aaaaaaaa change no file: only dev's came in)"))
        for scope in [LeadPrompts.Reaudit.Scope.since, .ownFiles([]), .wholeBranch(sameCommit: true)] { #expect(!prompt(scope).contains("(nothing changed)")) }
    }

    /// A re-audit of the commit already audited covers the whole branch, and says so when it refuses a file.
    @Test func aSameCommitReauditSaysItCoversTheWholeBranch() throws {
        var ledger = LeadAuditLedger()
        try ledger.record([], commit: "c1", passes: false)
        do {
            try ledger.record([important("Sources/Untouched.swift", 4)], commit: "c1", passes: false, changed: ["Sources/A.swift"])
            Issue.record("refused")
        } catch let refusal as LeadAuditLedger.Refusal {
            #expect(refusal.description.contains("the branch's whole change only (it covers Sources/A.swift)"), "\(refusal)")
        }
        try ledger.record([important("Sources/A.swift", 4)], commit: "c1", passes: false, changed: ["Sources/A.swift"])
        #expect(ledger.findings.map(\.place) == ["Sources/A.swift:4"])
    }
}

/// The findings through the tools: a fake verifier's submit_audit, the merge gate, the lead's dismissals and tasks
/// made of findings, re-audits and the round cap.
struct LeadFindingsToolTests: LeadTeamFixture {
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

    func call(_ tools: LeadToolset, _ name: String, _ arguments: [String: Any] = [:]) -> MCPToolResult { tools.call(name, arguments) }

    /// The worker commits `file` and reports done.
    func work(_ runtime: FakeRuntime, root: String, slug: String = "add-b", file: String, text: String) throws {
        let worktree = Worktrees.path(root: root, slug: slug)
        try text.write(toFile: worktree + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: worktree)
        Git.run(["commit", "-q", "-m", "work on \(file)"], in: worktree)
        let reported = call(try seat("worker-\(slug)", runtime), "report", doneReport("did \(file)"))
        #expect(!reported.isError, "\(reported.text)")
    }

    /// A task started and worked on, ready for its audit.
    func started(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String) throws {
        _ = call(lead, "add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        #expect(!call(lead, "start_worker", ["task": "add-b"]).isError)
        try work(runtime, root: root, file: "b.txt", text: "bee\n")
    }

    /// The last verifier started's prompt.
    func verifierPrompt(_ runtime: FakeRuntime) throws -> String {
        let spawn = try #require(runtime.spawned.last { $0.command.contains("--name 'verify-") })
        let range = try #require(spawn.command.range(of: #"--append-system-prompt-file '([^']+)'"#, options: .regularExpression))
        let path = String(spawn.command[range].dropFirst("--append-system-prompt-file '".count).dropLast())
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    func audit(_ lead: LeadToolset, _ runtime: FakeRuntime, _ verdict: [String: Any], slug: String = "add-b") throws -> MCPToolResult {
        let started = call(lead, "audit", ["task": slug])
        #expect(!started.isError, "\(started.text)")
        return call(try seat("verify-\(slug)", runtime), "submit_audit", verdict)
    }

    static let threeKinds: [[String: Any]] = [
        ["severity": "Important", "failure_scenario": "b.txt holding bee: the contract's check of b gives the wrong result", "file": "b.txt", "line": 1, "evidence": "test -f b.txt passes but b.txt says bee, the contract wants b", "status": "open"],
        ["severity": "Nit", "file": "b.txt", "line": 2, "evidence": "no trailing newline", "status": "open"],
        ["severity": "Pre-existing", "file": "a.txt", "line": 1, "evidence": "a.txt says one; it did on main too"],
    ]

    @Test func aVerifierThatFindsNothingAndPassesIsUnchangedForTheLead() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        let submitted = try audit(lead, runtime, ["completion": "complete", "integrity": "clean", "summary": "test -f b.txt passes"])
        #expect(!submitted.isError, "\(submitted.text)")
        #expect(runtime.steered.last?.text == "The audit of add-b passed (complete, clean): test -f b.txt passes\nmerge(add-b) when you're ready.")
        #expect(!call(lead, "status").text.contains("findings"))
        #expect(BoardStore(root: root).load().task("add-b")?.status == .review)
        #expect(!call(lead, "merge", ["task": "add-b"]).isError)
    }

    @Test func theVerifierIsAskedForFindingsWithEvidence() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        _ = call(lead, "audit", ["task": "add-b"])
        let prompt = try verifierPrompt(runtime)
        for words in ["findings", "Important", "Nit", "Pre-existing", "file and line", "the command you ran and what it gave"] {
            #expect(prompt.contains(words), "\(words)")
        }
        let schema = try #require(try seat("verify-add-b", runtime).tools.first { $0.name == "submit_audit" })
        #expect(schema.properties["findings"]?.type == "array")
        #expect(schema.required == ["completion", "integrity", "summary"])
    }

    @Test func anOpenImportantFindingHoldsTheMergeBackAndNitsAndPreExistingOnesDont() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        let submitted = try audit(lead, runtime, ["completion": "complete", "integrity": "clean", "summary": "checked", "findings": Self.threeKinds])
        #expect(!submitted.isError, "\(submitted.text)")
        // The vault keeps them; the board mirrors them.
        let ledger = try #require(vault.audits(root: root, task: "add-b"))
        #expect(ledger.findings.map(\.id) == ["F1", "F2", "F3"])
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.audits == ledger)
        #expect(task.status == .failed)
        let told = try #require(runtime.steered.last?.text)
        #expect(told.contains("Important:\n- add-b:F1 b.txt:1"), "\(told)")
        #expect(told.contains("Nit:\n- add-b:F2 b.txt:2"))
        #expect(told.contains("Pre-existing:\n- add-b:F3 a.txt:1"))
        #expect(told.contains("merge refuses while an Important finding is open"))

        // status and board(task) show them, by severity.
        let status = call(lead, "status").text
        #expect(status.contains("findings: Important open F1 b.txt:1; 1 Important open, 1 Nit open, 1 Pre-existing open"), "\(status)")
        let board = call(lead, "board", ["task": "add-b"]).text
        #expect(board.contains("Findings (round 1; 1 Important open, 1 Nit open, 1 Pre-existing open):\nImportant:\n- add-b:F1"), "\(board)")

        // merge names the open Important one.
        let refused = call(lead, "merge", ["task": "add-b"])
        #expect(refused.isError)
        #expect(refused.text.contains("add-b:F1 b.txt:1"), "\(refused.text)")
        #expect(!FileManager.default.fileExists(atPath: root + "/b.txt"))

        // A report on the audited commit leaves it failed, the verdict and its open finding standing.
        try #require(!call(try seat("worker-add-b", runtime), "report", doneReport("nothing new")).isError)
        #expect(BoardStore(root: root).load().task("add-b")?.status == .failed)
        #expect(runtime.steered.last?.text.contains("with Important findings open (add-b:F1)") == true, "\(runtime.steered.last?.text ?? "")")

        // Dismissed with a reason, it no longer holds the merge back; the Nit and the Pre-existing one never did.
        #expect(call(lead, "dismiss_finding", ["task": "add-b", "id": "F1", "reason": ""]).isError)
        let dismissed = call(lead, "dismiss_finding", ["task": "add-b", "id": "add-b:F1", "reason": "the contract only asks for the file"])
        #expect(!dismissed.isError, "\(dismissed.text)")
        #expect(vault.audits(root: root, task: "add-b")?.finding("F1")?.status == .dismissed)
        #expect(BoardStore(root: root).load().task("add-b")?.audits?.finding("F1")?.reason == "the contract only asks for the file")
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(FileManager.default.fileExists(atPath: root + "/b.txt"))
    }

    @Test func onlyTheLeadDismissesAFinding() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        _ = try audit(lead, runtime, ["completion": "complete", "integrity": "clean", "summary": "checked", "findings": Self.threeKinds])
        #expect(throws: LeadVault.Refused.self) {
            try self.vault(for: FakeSeat(runtime, agent: LeadAgent(pid: 1, tty: "x", session: "session-1"))).dismissFinding(root: root, task: "add-b", id: "F1", reason: "mine")
        }
        #expect(vault.audits(root: root, task: "add-b")?.finding("F1")?.isOpen == true)
    }

    @Test func aPreExistingFindingBecomesATaskInOneCall() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        _ = try audit(lead, runtime, ["completion": "complete", "integrity": "clean", "summary": "checked", "findings": Self.threeKinds])
        let added = call(lead, "add_task", ["from_finding": "add-b:F3"])
        #expect(!added.isError, "\(added.text)")
        let board = BoardStore(root: root).load()
        let made = try #require(board.tasks.last)
        #expect(made.slug != "add-b")
        #expect(made.contract.goal.contains("a.txt:1"))
        #expect(made.contract.context.contains("a.txt says one"))
        #expect(!made.contract.acceptance.isEmpty)
        let finding = try #require(vault.audits(root: root, task: "add-b")?.finding("F3"))
        #expect(finding.status == .dismissed)
        #expect(finding.followUp == made.slug)
        // What the lead passes replaces that part.
        #expect(!call(lead, "add_task", ["from_finding": "add-b:F1", "title": "Fix b"]).isError)
        #expect(BoardStore(root: root).load().tasks.last?.title == "Fix b")
        // A Nit never becomes one (see LeadRuleChecksTests).
        #expect(call(lead, "add_task", ["from_finding": "add-b:F2", "title": "Tidy b"]).isError)
        #expect(call(lead, "add_task", ["from_finding": "add-b:F9"]).isError)
        #expect(call(lead, "add_task", ["title": "No goal"]).isError)
    }

    @Test func aFindingOfAnArchivedTaskStillBecomesATask() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        _ = try audit(lead, runtime, ["completion": "complete", "integrity": "clean", "summary": "checked", "findings": Self.threeKinds])
        // add-b finished two days ago, its worktree gone: the lead's server moves it to the archive.
        let store = BoardStore(root: root)
        try store.locked {
            var board = try store.read()
            let index = try #require(board.taskIndex("add-b"))
            board.tasks[index].status = .done
            board.tasks[index].worktree = nil
            board.tasks[index].since = Date().timeIntervalSince1970 - 2 * 86_400
            try store.write(board)
        }
        lead.archiveFinished(force: true)
        #expect(store.load().task("add-b") == nil && store.archived().map(\.slug) == ["add-b"])
        let added = call(lead, "add_task", ["from_finding": "add-b:F3"])
        #expect(!added.isError, "\(added.text)")
        let made = try #require(store.load().tasks.last)
        #expect(made.contract.context.contains("a.txt says one"))
        #expect(vault.audits(root: root, task: "add-b")?.finding("F3")?.followUp == made.slug)
    }

    @Test func aReauditChecksTheOpenFindingsAndTheNewDiffAndNeverRepeatsAClosedOne() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        let first = Git.run(["rev-parse", "agent/add-b"], in: root).output
        _ = try audit(lead, runtime, ["completion": "complete", "integrity": "clean", "summary": "checked", "findings": Self.threeKinds])
        // The worker fixes it.
        try work(runtime, root: root, file: "c.txt", text: "sea\n")
        let started = call(lead, "audit", ["task": "add-b"])
        #expect(started.text.contains("re-audit (round 2)"), "\(started.text)")
        let prompt = try verifierPrompt(runtime)
        #expect(prompt.contains("re-audit (round 2)"))
        #expect(prompt.contains("git diff \(first)"))
        #expect(prompt.contains("- F1 [Important] b.txt:1"))
        #expect(prompt.contains("- F2 [Nit] b.txt:2"))
        #expect(prompt.contains("+sea"), "the diff since the audited commit")
        #expect(!prompt.contains("+bee"), "only the diff since the audited commit")
        let verifier = try seat("verify-add-b", runtime)
        let verdict: [String: Any] = ["completion": "complete", "integrity": "clean", "summary": "checked again"]
        // Each open finding must be marked.
        let skipped = call(verifier, "submit_audit", verdict.merging(["findings": [["id": "F1", "severity": "Important", "failure_scenario": "b.txt holding bee: the contract's check of b gives the wrong result", "file": "b.txt", "line": 1, "evidence": "fixed", "status": "fixed"]]]) { $1 })
        #expect(skipped.isError)
        #expect(skipped.text.contains("F2"), "\(skipped.text)")
        // New findings only from the new diff.
        let marks: [[String: Any]] = [["id": "F1", "severity": "Important", "failure_scenario": "b.txt holding bee: the contract's check of b gives the wrong result", "file": "b.txt", "line": 1, "evidence": "b.txt says b now", "status": "fixed"],
                                      ["id": "F2", "severity": "Nit", "file": "b.txt", "line": 2, "evidence": "still no newline", "status": "open"]]
        let outside = call(verifier, "submit_audit", verdict.merging(["findings": marks + [["severity": "Nit", "file": "a.txt", "line": 5, "evidence": "old"]]]) { $1 })
        #expect(outside.isError)
        #expect(outside.text.contains("new diff only"), "\(outside.text)")
        #expect(vault.verdict(root: root, task: "add-b") == nil, "nothing recorded on a refusal")
        let passed = call(verifier, "submit_audit", verdict.merging(["findings": marks + [["severity": "Nit", "file": "c.txt", "line": 1, "evidence": "sea is spelled see in the contract"]]]) { $1 })
        #expect(!passed.isError, "\(passed.text)")
        let ledger = try #require(vault.audits(root: root, task: "add-b"))
        #expect(ledger.rounds == 2)
        #expect(ledger.finding("F1")?.status == .fixed)
        #expect(ledger.finding("F4")?.place == "c.txt:1")
        #expect(ledger.blocking.isEmpty)
        #expect(runtime.steered.last?.text.contains("Nits and Pre-existing findings don't hold it back") == true)

        // A third round can't bring F1 back, by id or at its place.
        try work(runtime, root: root, file: "b.txt", text: "b\n")
        _ = call(lead, "audit", ["task": "add-b"])
        #expect(try verifierPrompt(runtime).contains("- F1 [Important, fixed] b.txt:1"))
        let third = try seat("verify-add-b", runtime)
        let open: [[String: Any]] = [["id": "F2", "severity": "Nit", "file": "b.txt", "line": 2, "evidence": "e", "status": "fixed"],
                                     ["id": "F4", "severity": "Nit", "file": "c.txt", "line": 1, "evidence": "e", "status": "open"]]
        let reopened = call(third, "submit_audit", verdict.merging(["findings": open + [["id": "F1", "severity": "Important", "failure_scenario": "b.txt holding bee: the contract's check of b gives the wrong result", "file": "b.txt", "line": 1, "evidence": "back", "status": "open"]]]) { $1 })
        #expect(reopened.isError)
        #expect(reopened.text.contains("isn't raised again"), "\(reopened.text)")
        let renamed = call(third, "submit_audit", verdict.merging(["findings": open + [["severity": "Important", "failure_scenario": "b.txt holding bee: the contract's check of b gives the wrong result", "file": "b.txt", "line": 1, "evidence": "back again"]]]) { $1 })
        #expect(renamed.isError)
        #expect(renamed.text.contains("isn't raised again"), "\(renamed.text)")
        #expect(!call(third, "submit_audit", verdict.merging(["findings": open]) { $1 }).isError)
        #expect(vault.audits(root: root, task: "add-b")?.findings.count == 4)
        #expect(!call(lead, "merge", ["task": "add-b"]).isError)
    }

    @Test func afterTwoRoundsWithImportantFindingsOpenTheLeadIsToldToReroll() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        let still: [String: Any] = ["id": "F1", "severity": "Important", "failure_scenario": "b.txt holding bee: the contract's check of b gives the wrong result", "file": "b.txt", "line": 1, "evidence": "still wrong", "status": "open"]
        _ = try audit(lead, runtime, ["completion": "complete", "integrity": "clean", "summary": "1", "findings": [Self.threeKinds[0]]])
        #expect(!call(lead, "status").text.contains("reconsider the approach"))
        #expect(runtime.steered.last?.text.contains("Reconsider the approach") == false)
        try work(runtime, root: root, file: "c.txt", text: "1\n")
        #expect(!(try audit(lead, runtime, ["completion": "complete", "integrity": "clean", "summary": "2", "findings": [still]])).isError)
        let told = try #require(runtime.steered.last?.text)
        #expect(told.contains("Reconsider the approach: 1 Important finding left open across 2 rounds"), "\(told)")
        #expect(told.contains("re-roll add-b (update_task(add-b, reroll: true)") && told.contains("ask the user"), "\(told)")
        let status = call(lead, "status").text
        #expect(status.contains("add-b: Add b — reconsider the approach (1 Important finding left open across 2 rounds)"), "\(status)")
        #expect(call(lead, "board", ["task": "add-b"]).text.contains("Reconsider the approach"))
        // The lead's own prompt says what to do then.
        #expect(LeadPrompts.lead(project: "p", root: root, workflow: LeadWorkflow()).contains("\"reconsider the approach\": don't send the worker back for a third round; re-roll it"))
        // Re-planned, the rounds count from there.
        #expect(!call(lead, "update_task", ["task": "add-b", "status": "planned"]).isError)
        #expect(vault.audits(root: root, task: "add-b")?.reconsider == false)
        #expect(!call(lead, "status").text.contains("reconsider the approach"))
    }

    @Test func malformedFindingsAreRefusedSaying() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        _ = call(lead, "audit", ["task": "add-b"])
        let verifier = try seat("verify-add-b", runtime)
        let base: [String: Any] = ["completion": "complete", "integrity": "clean", "summary": "s"]
        for (finding, words) in [(["severity": "Major", "file": "b.txt", "line": 1, "evidence": "e"], "Important, Nit or Pre-existing"),
                                 (["severity": "Nit", "file": "b.txt", "evidence": "e"], "line"),
                                 (["severity": "Nit", "file": "b.txt", "line": 1], "evidence"),
                                 (["severity": "Nit", "file": "b.txt", "line": 1, "evidence": "e", "status": "dismissed"], "reason")] as [([String: Any], String)] {
            let refused = call(verifier, "submit_audit", base.merging(["findings": [finding]]) { $1 })
            #expect(refused.isError)
            #expect(refused.text.contains(words), "\(refused.text)")
        }
        #expect(vault.verdict(root: root, task: "add-b") == nil)
        // A list given as JSON text, with the line as text, is read.
        let json = #"[{"severity": "nit", "file": "b.txt", "line": "2", "evidence": "e"}]"#
        #expect(!call(verifier, "submit_audit", base.merging(["findings": json]) { $1 }).isError)
        #expect(vault.audits(root: root, task: "add-b")?.finding("F1")?.place == "b.txt:2")
    }

    /// Findings stay through a new verifier and a worker's report; the task's cleanup takes them with its verdict.
    @Test func theFindingsOutliveEachVerifierAndGoWithTheTask() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        _ = try audit(lead, runtime, ["completion": "complete", "integrity": "clean", "summary": "s", "findings": Self.threeKinds])
        try work(runtime, root: root, file: "c.txt", text: "c\n")
        #expect(vault.verdict(root: root, task: "add-b") == nil)
        #expect(vault.audits(root: root, task: "add-b")?.findings.count == 3)
        _ = call(lead, "audit", ["task": "add-b"])
        #expect(vault.audits(root: root, task: "add-b")?.findings.count == 3)
        #expect(!call(lead, "cleanup", ["task": "add-b", "force": true]).isError)
        #expect(vault.audits(root: root, task: "add-b") == nil)
    }

    /// A re-audit of the very commit audited (after a 'blocked' verdict, say) covers the whole branch since its
    /// merge-base: its prompt shows that diff, and new findings anywhere the branch changes are taken.
    @Test func aReauditOfTheSameCommitCoversTheWholeBranch() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        let head = Git.run(["rev-parse", "agent/add-b"], in: root).output
        #expect(!(try audit(lead, runtime, ["completion": "blocked", "integrity": "clean", "summary": "swift wasn't there"])).isError)
        let again = call(lead, "audit", ["task": "add-b"])
        #expect(again.text.contains("re-audit (round 2): the verifier checks the 0 open findings and the whole branch (the commit audited before, again)"), "\(again.text)")
        let prompt = try verifierPrompt(runtime)
        #expect(prompt.contains("this very commit, \(head.prefix(8))"), "\(prompt)")
        #expect(prompt.contains("`git diff main...\(head)`"))
        #expect(prompt.contains("+bee"), "the whole branch's diff")
        #expect(!prompt.contains("(nothing changed)"))
        let verifier = try seat("verify-add-b", runtime)
        let verdict: [String: Any] = ["completion": "complete", "integrity": "clean", "summary": "built this time"]
        let outside = call(verifier, "submit_audit", verdict.merging(["findings": [Self.threeKinds[2].merging(["severity": "Nit"]) { $1 }]]) { $1 })
        #expect(outside.isError)
        #expect(outside.text.contains("the branch's whole change only (it covers b.txt)"), "\(outside.text)")
        let found = call(verifier, "submit_audit", verdict.merging(["findings": [Self.threeKinds[0]]]) { $1 })
        #expect(!found.isError, "\(found.text)")
        #expect(vault.audits(root: root, task: "add-b")?.finding("F1")?.place == "b.txt:1")
    }

    /// A branch that merged the base since its audit is re-audited on its own commits' files (a merge's where its
    /// resolution changed them), against the base's merge-base: the base's own work isn't in it.
    @Test func aReauditOfABranchThatMergedTheBaseCoversOnlyItsOwnFiles() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        #expect(!(try audit(lead, runtime, ["completion": "complete", "integrity": "clean", "summary": "checked"])).isError)
        // The base moves on: a file of its own, and b.txt too, which the worker's merge resolves.
        try "mmm\n".write(toFile: root + "/m.txt", atomically: true, encoding: .utf8)
        try "main bee\n".write(toFile: root + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "m.txt", "b.txt"], in: root)
        Git.run(["commit", "-q", "-m", "the base's work"], in: root)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        #expect(!Git.run(["merge", "-q", "main", "-m", "merge main"], in: worktree).ok, "b.txt conflicts")
        try "bee and main bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        #expect(Git.run(["commit", "-q", "--no-edit"], in: worktree).ok)
        try work(runtime, root: root, file: "c.txt", text: "sea\n")
        let head = Git.run(["rev-parse", "agent/add-b"], in: root).output

        let again = call(lead, "audit", ["task": "add-b"])
        #expect(again.text.contains("the branch's own files since"), "\(again.text)")
        let prompt = try verifierPrompt(runtime)
        #expect(prompt.contains("merged main in"), "\(prompt)")
        #expect(prompt.contains("`git diff main...\(head) -- b.txt c.txt`"), "\(prompt)")
        #expect(prompt.contains("+sea") && prompt.contains("+bee and main bee"))
        #expect(!prompt.contains("+mmm") && !prompt.contains("m.txt"), "the base's own file isn't the branch's to review")
        let verifier = try seat("verify-add-b", runtime)
        let verdict: [String: Any] = ["completion": "complete", "integrity": "clean", "summary": "checked again"]
        let base = call(verifier, "submit_audit", verdict.merging(["findings": [["severity": "Nit", "file": "m.txt", "line": 1, "evidence": "mmm"]]]) { $1 })
        #expect(base.isError)
        #expect(base.text.contains("new diff only (it covers b.txt, c.txt)"), "\(base.text)")
        let own = call(verifier, "submit_audit", verdict.merging(["findings": [["severity": "Nit", "file": "b.txt", "line": 1, "evidence": "the merge kept both lines' words"]]]) { $1 })
        #expect(!own.isError, "\(own.text)")
    }

    /// The last Important finding dismissed on a passing audit: the task is back in review, its setback gone, and
    /// the lead is told merge can go ahead. Moved to a task of its own, the same.
    @Test func dismissingTheLastImportantFindingOnAPassPutsTheTaskBackInReview() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        _ = try audit(lead, runtime, ["completion": "complete", "integrity": "clean", "summary": "checked", "findings": Self.threeKinds])
        #expect(BoardStore(root: root).load().task("add-b")?.status == .failed)
        #expect(BoardStore(root: root).load().task("add-b")?.setback != nil)
        let dismissed = call(lead, "dismiss_finding", ["task": "add-b", "id": "F1", "reason": "the contract only asks for the file"])
        #expect(!dismissed.isError, "\(dismissed.text)")
        #expect(dismissed.text.contains("add-b is back in review; merge(add-b) when you're ready"), "\(dismissed.text)")
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.status == .review && task.setback == nil && task.evidence?.passes == true)
        #expect(!call(lead, "merge", ["task": "add-b"]).isError)
    }

    @Test func movingTheLastImportantFindingToATaskPutsAPassBackInReview() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        _ = try audit(lead, runtime, ["completion": "complete", "integrity": "clean", "summary": "checked", "findings": [Self.threeKinds[0]]])
        let moved = call(lead, "add_task", ["from_finding": "add-b:F1"])
        #expect(moved.text.contains("it's back in review; merge(add-b) when you're ready"), "\(moved.text)")
        #expect(BoardStore(root: root).load().task("add-b")?.status == .review)
    }

    /// On an audit that didn't pass, closing its Important findings leaves it failed: the verdict still fails.
    @Test func dismissingOnAFailedAuditLeavesItFailed() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        _ = try audit(lead, runtime, ["completion": "incomplete", "integrity": "clean", "summary": "c.txt is missing", "findings": [Self.threeKinds[0]]])
        let dismissed = call(lead, "dismiss_finding", ["task": "add-b", "id": "F1", "reason": "not a problem"])
        #expect(!dismissed.isError, "\(dismissed.text)")
        #expect(!dismissed.text.contains("merge("), "\(dismissed.text)")
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.status == .failed && task.setback != nil)
        #expect(call(lead, "merge", ["task": "add-b"]).text.contains("no passing audit"))
    }

    /// Two Important findings, each a file outside the boundaries the worker listed as a routine call.
    static let excursions: [[String: Any]] = [
        ["severity": "Important", "failure_scenario": "merging the branch changes a.txt, which the contract doesn't cover", "file": "a.txt", "line": 1, "evidence": "a.txt is outside the boundaries; no lead's note accepts it", "status": "open"],
        ["severity": "Important", "failure_scenario": "merging the branch changes c.txt, which the contract doesn't cover", "file": "c.txt", "line": 1, "evidence": "c.txt is outside the boundaries; no lead's note accepts it", "status": "open"],
    ]

    /// 2026-10-24: a verifier found the work correct with every test passing, gave violation only for files outside the
    /// boundaries the worker had listed as routine calls, and after the lead dismissed all of them merge still refused
    /// with "no passing audit". A complete audit whose tests passed merges once the lead has dismissed every Important
    /// finding that failed it, and the merge names the dismissals.
    @Test func aCompleteAuditWithPassingTestsMergesOnceTheLeadDismissesWhatFailedIt() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        _ = try audit(lead, runtime, ["completion": "complete", "integrity": "violation", "tests": "passed",
                                      "summary": "correct; every test passes; a.txt and c.txt are outside the boundaries", "findings": Self.excursions])
        #expect(BoardStore(root: root).load().task("add-b")?.status == .failed)
        let open = call(lead, "merge", ["task": "add-b"])
        #expect(open.isError && open.text.contains("2 open Important findings"), "\(open.text)")
        let first = call(lead, "dismiss_finding", ["task": "add-b", "id": "F1", "reason": "the worker's routine call: wiring the goal needs"])
        #expect(!first.text.contains("merge("), "\(first.text)")
        let half = call(lead, "merge", ["task": "add-b"])
        #expect(half.isError && half.text.contains("1 open Important finding") && half.text.contains("F2"), "\(half.text)")
        let second = call(lead, "dismiss_finding", ["task": "add-b", "id": "F2", "reason": "a test helper the worker listed"])
        #expect(second.text.contains("complete with its tests passing") && second.text.contains("add-b is back in review; merge(add-b) when you're ready"), "\(second.text)")
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.status == .review && task.setback == nil)
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(merged.text.contains("the 2 Important findings that failed it you dismissed: F1 a.txt:1 (the worker's routine call: wiring the goal needs); F2 c.txt:1 (a test helper the worker listed)"), "\(merged.text)")
        #expect(BoardStore(root: root).load().task("add-b")?.status == .done)
    }

    /// Dismissing every Important finding doesn't make a pass of an incomplete audit, one whose tests failed, or one
    /// whose verifier didn't say they passed: each still needs a new verifier run.
    @Test func dismissalsDontPassAnIncompleteAuditOrOneWhoseTestsFailed() throws {
        let cases: [(verdict: [String: Any], says: String)] = [
            (["completion": "incomplete", "integrity": "violation", "tests": "passed"], "this one is incomplete"),
            (["completion": "complete", "integrity": "violation", "tests": "failed"], "this one's tests failed"),
            (["completion": "complete", "integrity": "violation", "tests": "not_run"], "didn't say its tests passed"),
            (["completion": "complete", "integrity": "violation"], "didn't say its tests passed"),
        ]
        for (verdict, says) in cases {
            let root = try repo()
            let runtime = FakeRuntime()
            let lead = try lead(root, runtime)
            try started(lead, runtime, root: root)
            _ = try audit(lead, runtime, verdict.merging(["summary": "checked", "findings": Self.excursions]) { $1 })
            for id in ["F1", "F2"] {
                let dismissed = call(lead, "dismiss_finding", ["task": "add-b", "id": id, "reason": "a routine call"])
                #expect(!dismissed.isError && !dismissed.text.contains("merge("), "\(dismissed.text)")
            }
            #expect(BoardStore(root: root).load().task("add-b")?.status == .failed)
            let merged = call(lead, "merge", ["task": "add-b"])
            #expect(merged.isError && merged.text.contains("no passing audit") && merged.text.contains(says), "\(verdict): \(merged.text)")
        }
    }

    @Test func testsMustBeOneOfThree() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try started(lead, runtime, root: root)
        let refused = try audit(lead, runtime, ["completion": "complete", "integrity": "clean", "tests": "mostly", "summary": "checked"])
        #expect(refused.isError && refused.text.contains("tests must be passed, failed or not_run"), "\(refused.text)")
    }
}
