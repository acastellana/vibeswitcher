import Foundation
import Testing
@testable import VibeCore

/// The vote of an audit by several finders (`LeadAuditVote`), on its own: what a majority keeps, what stays
/// unconfirmed, the Nits' cap, earlier rounds' findings and the verdict.
struct LeadAuditVoteTests {
    typealias Report = LeadFinding.Report

    func ballot(_ finder: Int, _ findings: [Report], completion: LeadEvidence.Completion = .complete,
                integrity: LeadEvidence.Integrity = .clean) -> LeadAuditVote.Ballot {
        LeadAuditVote.Ballot(finder: finder, focus: ["contract and acceptance", "bugs and regressions", "tests and edge cases"][finder - 1],
                             completion: completion, integrity: integrity, summary: "finder \(finder) checked", findings: findings)
    }

    func important(_ file: String = "Sources/A.swift", _ line: Int = 12, _ evidence: String = "crashes on empty input",
                   id: String? = nil, status: LeadFinding.Status = .open) -> Report {
        Report(id: id, severity: .important, file: file, line: line, evidence: evidence, status: status, reason: status == .open ? nil : "checked")
    }

    func nit(_ line: Int) -> Report { Report(severity: .nit, file: "Sources/N.swift", line: line, evidence: "nit \(line)") }

    /// The finders' word on the tests: failed when any said so, passed when one did and none failed.
    @Test func theVotesTestsAreTheWorstAnyFinderSaw() {
        func tally(_ said: [LeadVault.TestRun?]) -> LeadVault.TestRun? {
            let ballots = said.enumerated().map { index, tests in
                var ballot = ballot(index + 1, [])
                ballot.tests = tests
                return ballot
            }
            return LeadAuditVote.tally(ballots, size: ballots.count, ledger: LeadAuditLedger(), nitCap: 5).tests
        }
        #expect(tally([.passed, .passed, .passed]) == .passed)
        #expect(tally([.passed, .failed, .passed]) == .failed)
        #expect(tally([.passed, nil, .notRun]) == .passed)
        #expect(tally([nil, .notRun]) == .notRun)
        #expect(tally([nil, nil]) == nil)
    }

    @Test func aFindingMostFindersRaiseIsConfirmedOpen() throws {
        // Two of three at the same file and kind, two lines apart: the same finding.
        let vote = LeadAuditVote.tally([ballot(1, [important("Sources/A.swift", 12, "empty input crashes")]), ballot(2, [important("Sources/A.swift", 14)]), ballot(3, [])],
                                       size: 3, ledger: LeadAuditLedger(), nitCap: 5)
        #expect(vote.reports.count == 1)
        #expect(vote.reports[0].place == "Sources/A.swift:12")
        #expect(vote.reports[0].status == .open)
        #expect(vote.reports[0].evidence == "empty input crashes [2 of 3 finders]")
        #expect(vote.unconfirmed.isEmpty)
        #expect(vote.outcome == LeadAuditVote.Outcome(finders: 3, focuses: ["contract and acceptance", "bugs and regressions", "tests and edge cases"],
                                                      confirmed: 1, unconfirmed: 0, nitsLeftOut: 0, nitCap: 5))
        var ledger = LeadAuditLedger()
        try ledger.record(vote.reports, unconfirmed: vote.unconfirmed, vote: vote.outcome, commit: "c1", passes: vote.passes)
        #expect(ledger.blocking.map(\.place) == ["Sources/A.swift:12"])
        #expect(ledger.vote?.text == "3 finders voted: 1 new finding confirmed, 0 unconfirmed")
    }

    @Test func aFindingOnlyOneFinderSawIsKeptUnconfirmedAndHoldsNothingBack() throws {
        let vote = LeadAuditVote.tally([ballot(1, []), ballot(2, [important()]), ballot(3, [])], size: 3, ledger: LeadAuditLedger(), nitCap: 5)
        #expect(vote.reports.isEmpty)
        let doubted = try #require(vote.unconfirmed.first)
        #expect(doubted.status == .unconfirmed)
        #expect(doubted.reason == "1 of 3 finders saw it: finder 2 (bugs and regressions)")
        var ledger = LeadAuditLedger()
        try ledger.record(vote.reports, unconfirmed: vote.unconfirmed, vote: vote.outcome, commit: "c1", passes: vote.passes)
        let finding = try #require(ledger.finding("F1"))
        #expect(finding.status == .unconfirmed && finding.place == "Sources/A.swift:12")
        // Visible, but not open: it holds no merge back, and no re-audit has to recheck it.
        #expect(ledger.blocking.isEmpty && ledger.toRecheck.isEmpty)
        #expect(ledger.failedRounds == 0)
        #expect(ledger.bySeverity.first?.findings.map(\.id) == ["F1"])
        #expect(LeadToolset.findingsTally(ledger) == "1 Important unconfirmed")
        #expect(finding.line1.contains("[unconfirmed: 1 of 3 finders saw it"))
        // Two finders: one of two is no majority either.
        let two = LeadAuditVote.tally([ballot(1, [important()]), ballot(2, [])], size: 2, ledger: LeadAuditLedger(), nitCap: 5)
        #expect(two.reports.isEmpty && two.unconfirmed.count == 1)
    }

    @Test func differentFilesKindsOrFarLinesAreDifferentFindings() {
        let vote = LeadAuditVote.tally([ballot(1, [important("Sources/A.swift", 12)]),
                                        ballot(2, [important("Sources/B.swift", 12), important("Sources/A.swift", 30)]),
                                        ballot(3, [Report(severity: .nit, file: "Sources/A.swift", line: 12, evidence: "naming")])],
                                       size: 3, ledger: LeadAuditLedger(), nitCap: 5)
        #expect(vote.reports.isEmpty)
        #expect(Set(vote.unconfirmed.map(\.place)) == ["Sources/B.swift:12", "Sources/A.swift:30", "Sources/A.swift:12"])
        // One finding per place: the Important one there, the Nit folded into it, in view.
        let there = vote.unconfirmed.filter { $0.place == "Sources/A.swift:12" }
        #expect(there.map(\.severity) == [.important])
        #expect(there.first?.evidence == "crashes on empty input; also raised here as Nit by finder 3: naming")
    }

    /// A lone Important finding where most raised a Nit stays an Important one of its own, unconfirmed: where it is
    /// never lowers its severity. A lone Nit where most raised an Important one is folded into it.
    @Test func aMoreSevereLoneFindingAtAConfirmedOnesPlaceStaysItsOwn() throws {
        let nitThere = Report(severity: .nit, file: "Sources/A.swift", line: 12, evidence: "naming")
        let vote = LeadAuditVote.tally([ballot(1, [nitThere]), ballot(2, [important()]), ballot(3, [nitThere])], size: 3, ledger: LeadAuditLedger(), nitCap: 5)
        #expect(vote.reports.map(\.severity) == [.nit] && vote.reports.first?.evidence == "naming [2 of 3 finders]")
        #expect(vote.unconfirmed.map(\.severity) == [.important] && vote.unconfirmed.first?.place == "Sources/A.swift:12")
        var ledger = LeadAuditLedger()
        try ledger.record(vote.reports, unconfirmed: vote.unconfirmed, vote: vote.outcome, commit: "c1", passes: vote.passes)
        #expect(ledger.findings.map { "\($0.id) \($0.severity.rawValue) \($0.status.rawValue)" } == ["F1 Nit open", "F2 Important unconfirmed"])
        // Raised again by most, at its place with its severity: that one, confirmed; a new Nit there is still refused.
        let again = LeadAuditVote.tally([ballot(1, [important(), nitThere.with(id: "F1", file: "Sources/A.swift", line: 12)]),
                                         ballot(2, [important(), nitThere.with(id: "F1", file: "Sources/A.swift", line: 12)]),
                                         ballot(3, [nitThere.with(id: "F1", file: "Sources/A.swift", line: 12)])], size: 3, ledger: ledger, nitCap: 5)
        try ledger.record(again.reports, unconfirmed: again.unconfirmed, vote: again.outcome, commit: "c2", passes: true, changed: ["Sources/A.swift"])
        #expect(ledger.findings.count == 2 && ledger.blocking.map(\.id) == ["F2"])
        #expect(throws: LeadAuditLedger.Refusal.self) {
            try ledger.record([nitThere, self.important(id: "F2"), nitThere.with(id: "F1", file: "Sources/A.swift", line: 12)], commit: "c3", passes: true, changed: ["Sources/A.swift"])
        }
        // The other way round: folded into the confirmed Important one.
        let folded = LeadAuditVote.tally([ballot(1, [important()]), ballot(2, [important()]), ballot(3, [nitThere])], size: 3, ledger: LeadAuditLedger(), nitCap: 5)
        #expect(folded.reports.map(\.severity) == [.important] && folded.unconfirmed.isEmpty)
        #expect(folded.reports.first?.evidence == "crashes on empty input [2 of 3 finders]; also raised here as Nit by finder 3: naming")
    }

    @Test func newNitsPastTheCapAreLeftOutCounted() throws {
        // Seven Nits: the two all three saw first, then the rest in the order raised, five in all.
        let many = (1...7).map { nit($0 * 10) }
        let vote = LeadAuditVote.tally([ballot(1, many), ballot(2, [nit(60), nit(70)]), ballot(3, [nit(70), nit(60)])],
                                       size: 3, ledger: LeadAuditLedger(), nitCap: 5)
        #expect(vote.reports.map(\.line) == [60, 70])
        #expect(vote.unconfirmed.map(\.line) == [10, 20, 30])
        #expect(vote.outcome.nitsLeftOut == 2)
        #expect(vote.outcome.text == "3 finders voted: 2 new findings confirmed, 3 unconfirmed, 2 Nits past audit_nit_cap (5) left out")
        // The cap holds Nits only; 0 keeps none.
        let none = LeadAuditVote.tally([ballot(1, many + [important()]), ballot(2, [important()])], size: 2, ledger: LeadAuditLedger(), nitCap: 0)
        #expect(none.reports.map(\.severity) == [.important])
        #expect(none.unconfirmed.isEmpty && none.outcome.nitsLeftOut == 7)
    }

    @Test func anEarlierFindingClosesOnlyWhenMostSaySo() throws {
        var ledger = LeadAuditLedger()
        try ledger.record([important(), Report(severity: .nit, file: "Sources/B.swift", line: 3, evidence: "typo")], commit: "c1", passes: true)
        // F1: two of three say fixed; F2: one says fixed, two still see it.
        let vote = LeadAuditVote.tally([ballot(1, [important(id: "F1", status: .fixed), nit(0).with(id: "F2", file: "Sources/B.swift", line: 3)]),
                                        ballot(2, [important(id: "F1", status: .fixed), nit(0).with(id: "F2", file: "Sources/B.swift", line: 3, status: .fixed)]),
                                        ballot(3, [important(id: "F1"), nit(0).with(id: "F2", file: "Sources/B.swift", line: 3)])],
                                       size: 3, ledger: ledger, nitCap: 5)
        try ledger.record(vote.reports, unconfirmed: vote.unconfirmed, vote: vote.outcome, commit: "c2", passes: vote.passes, changed: ["Sources/A.swift"])
        #expect(ledger.finding("F1")?.status == .fixed)
        #expect(ledger.finding("F2")?.isOpen == true)
        #expect(ledger.blocking.isEmpty)
    }

    @Test func anUnconfirmedFindingIsConfirmedWhenMostRaiseItAgain() throws {
        var ledger = LeadAuditLedger()
        let first = LeadAuditVote.tally([ballot(1, [important()]), ballot(2, []), ballot(3, [])], size: 3, ledger: ledger, nitCap: 5)
        try ledger.record(first.reports, unconfirmed: first.unconfirmed, vote: first.outcome, commit: "c1", passes: true)
        #expect(ledger.finding("F1")?.status == .unconfirmed)
        // Raised again by one: it stays as it is.
        let again = LeadAuditVote.tally([ballot(1, [important()]), ballot(2, []), ballot(3, [])], size: 3, ledger: ledger, nitCap: 5)
        #expect(again.reports.isEmpty && again.unconfirmed.isEmpty)
        // By two, at its place or by its id: confirmed, open, and it holds the merge back now.
        let most = LeadAuditVote.tally([ballot(1, [important()]), ballot(2, [important(id: "F1")]), ballot(3, [])], size: 3, ledger: ledger, nitCap: 5)
        try ledger.record(most.reports, unconfirmed: most.unconfirmed, vote: most.outcome, commit: "c2", passes: true, changed: ["Sources/A.swift"])
        #expect(ledger.findings.count == 1)
        #expect(ledger.finding("F1")?.isOpen == true)
        #expect(ledger.blocking.map(\.id) == ["F1"])
    }

    @Test func theVerdictIsEachPartsMajorityElseTheWorse() {
        let pass = LeadAuditVote.tally([ballot(1, []), ballot(2, [], completion: .incomplete), ballot(3, [])], size: 3, ledger: LeadAuditLedger(), nitCap: 5)
        #expect(pass.completion == .complete && pass.integrity == .clean && pass.passes)
        #expect(pass.summary.hasPrefix("Finder 1 (contract and acceptance; complete, clean): finder 1 checked\nFinder 2 (bugs and regressions; incomplete, clean)"))
        // No majority: the worse.
        let split = LeadAuditVote.tally([ballot(1, []), ballot(2, [], completion: .blocked)], size: 2, ledger: LeadAuditLedger(), nitCap: 5)
        #expect(split.completion == .blocked && !split.passes)
        // One finder's violation makes it suspect at least.
        let violation = LeadAuditVote.tally([ballot(1, []), ballot(2, []), ballot(3, [], integrity: .violation)], size: 3, ledger: LeadAuditLedger(), nitCap: 5)
        #expect(violation.integrity == .suspect && !violation.passes)
    }

    @Test func aVerifierCantMarkAFindingUnconfirmedButTheLeadCanDismissOne() throws {
        var ledger = LeadAuditLedger()
        #expect(throws: LeadAuditLedger.Refusal.self) { try ledger.record([self.important(status: .unconfirmed)], commit: "c1", passes: true) }
        try ledger.record([], unconfirmed: [important(status: .unconfirmed)], commit: "c1", passes: true)
        try ledger.dismiss("F1", reason: "only one finder saw it, and it's handled upstream")
        #expect(ledger.finding("F1")?.status == .dismissed)
        // One verifier raising it again at its place confirms it (a one-verifier audit is its own majority).
        var other = LeadAuditLedger()
        try other.record([], unconfirmed: [important(status: .unconfirmed)], commit: "c1", passes: true)
        try other.record([important()], commit: "c2", passes: true, changed: ["Sources/A.swift"])
        #expect(other.findings.count == 1 && other.finding("F1")?.isOpen == true)
    }
}

private extension LeadFinding.Report {
    var place: String { "\(file):\(line)" }

    func with(id: String, file: String, line: Int, status: LeadFinding.Status = .open) -> LeadFinding.Report {
        LeadFinding.Report(id: id, severity: severity, file: file, line: line, evidence: evidence, status: status, reason: status == .open ? nil : "done")
    }
}

/// An audit by several finders through the tools: audit_finders set with configure, the Mac-wide room for them, one
/// shared build and test run whose logs reach every finder, their ballots and the vote's one verdict, which merge
/// takes as any audit's.
struct LeadAuditFindersTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    /// Each run of the test command adds a line to this file, from the scratch home it ran in.
    let runs: String
    init() {
        vault = Self.newVault(in: temp)
        runs = temp.url("runs").path
    }

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

    /// A lead with `finders` finders and a test command that says where it ran, and a task worked on and reported.
    func ready(_ runtime: FakeRuntime, finders: Int = 3) throws -> (root: String, lead: LeadToolset) {
        let root = try repo()
        let lead = try lead(root, runtime)
        let test = "test -f b.txt && echo \"shared run of $(git rev-parse --short HEAD) in home $HOME\" && echo \"$HOME\" >> \(runs)"
        let set = call(lead, "configure", ["audit_finders": finders, "test_command": test])
        #expect(!set.isError, "\(set.text)")
        _ = call(lead, "add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        #expect(!call(lead, "start_worker", ["task": "add-b"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b"], in: worktree)
        #expect(!call(try seat("worker-add-b", runtime), "report", doneReport("added b")).isError)
        return (root, lead)
    }

    /// Finder `index`'s tool server.
    func finder(_ index: Int, _ runtime: FakeRuntime) throws -> LeadToolset {
        try seat(index == 1 ? "verify-add-b" : "finder\(index)-add-b", runtime)
    }

    /// Finder `index`'s prompt.
    func prompt(_ index: Int, _ runtime: FakeRuntime) throws -> String {
        let name = index == 1 ? "verify-add-b" : "finder\(index)-add-b"
        let spawn = try #require(runtime.spawned.last { $0.command.contains("--name '\(name)'") })
        let range = try #require(spawn.command.range(of: #"--append-system-prompt-file '([^']+)'"#, options: .regularExpression))
        return try String(contentsOfFile: String(spawn.command[range].dropFirst("--append-system-prompt-file '".count).dropLast()), encoding: .utf8)
    }

    func lines(_ path: String) -> [String] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).map(String.init)
    }

    static let verdict: [String: Any] = ["completion": "complete", "integrity": "clean", "summary": "checked"]
    static let crash: [String: Any] = ["severity": "Important", "failure_scenario": "b.txt holding bee: the contract's check of b gives the wrong result", "file": "b.txt", "line": 1, "evidence": "b.txt says bee, the contract wants b"]

    @Test func auditFindersIsSetWithConfigureWithinItsRange() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        #expect(LeadWorkflow().auditFinders == 1 && LeadWorkflow().auditNitCap == 5)
        let bad: [Any] = [0, 4, "two"]
        for bad in bad {
            let refused = call(lead, "configure", ["audit_finders": bad])
            #expect(refused.isError && refused.text.contains("audit_finders must be 1"), "\(refused.text)")
        }
        #expect(call(lead, "configure", ["audit_nit_cap": -1]).isError)
        let set = call(lead, "configure", ["audit_finders": 2, "audit_nit_cap": 3])
        #expect(!set.isError, "\(set.text)")
        #expect(set.text.contains("- audit_finders: 2 (finders per audit") && set.text.contains("- audit_nit_cap: 3"), "\(set.text)")
        let workflow = LeadWorkflow.load(from: root + "/.vibeswitcher/workflow.md")
        #expect(workflow.auditFinders == 2 && workflow.auditNitCap == 3)
        #expect(LeadWorkflow.parse("---\naudit_finders: 9\n---").auditFinders == 3)
        #expect(LeadVault.guardedKeys.contains("audit_finders") && LeadVault.guardedKeys.contains("audit_nit_cap"))
        #expect(LeadWorkflow.template.contains("audit_finders: 1") && LeadWorkflow.template.contains("audit_nit_cap: 5"))
    }

    @Test func threeFindersShareOneBuildAndTestRunAndEachGetsItsFocusAndTheLogs() throws {
        let runtime = FakeRuntime()
        let (root, lead) = try ready(runtime)
        let head = Git.run(["rev-parse", "agent/add-b"], in: root).output
        let started = call(lead, "audit", ["task": "add-b"])
        #expect(!started.isError, "\(started.text)")
        #expect(started.text.contains("3 finders started on add-b"), "\(started.text)")
        #expect(started.text.contains("finder 1: contract and acceptance, finder 2: bugs and regressions, finder 3: tests and edge cases"))
        #expect(started.text.contains("the test command passed"))
        // One run, under a scratch home (not this test's HOME), of exactly the audited commit.
        let homes = lines(runs)
        #expect(homes.count == 1)
        #expect(homes.first != NSHomeDirectory() && homes.first?.contains("audit-add-b-home") == true, "\(homes)")
        let log = root + "/.vibeswitcher/audit/add-b/\(head.prefix(12))/test.log"
        let logged = try String(contentsOfFile: log, encoding: .utf8)
        #expect(logged.contains("shared run of \(head.prefix(7))"), "\(logged)")
        #expect(!FileManager.default.fileExists(atPath: vault.scratch(root: root, "audit-add-b").path), "its worktree is gone")
        #expect(!Git.run(["worktree", "list"], in: root).output.contains("audit-add-b"))
        // Three finders, each with its focus, the shared logs, and no full run of its own.
        let spawned = runtime.spawned.filter { $0.label.hasPrefix("Verifier: ") }
        #expect(spawned.count == 3)
        #expect(spawned.map(\.label) == ["Verifier: Add b (finder 1/3: contract and acceptance)", "Verifier: Add b (finder 2/3: bugs and regressions)",
                                         "Verifier: Add b (finder 3/3: tests and edge cases)"])
        for (index, focus) in [(1, "Your focus: the contract"), (2, "Your focus: bugs and regressions"), (3, "Your focus: the tests")] {
            let text = try prompt(index, runtime)
            #expect(text.contains("You are finder \(index) of 3"), "\(text)")
            #expect(text.contains(focus), "\(text)")
            #expect(text.contains(log))
            #expect(text.contains("the test command passed"))
            #expect(text.contains("Don't build the whole project or run the whole suite again"))
            #expect(!text.contains("run every acceptance check and `test -f b.txt"), "no run of the test command of its own")
        }
        let board = BoardStore(root: root).load().task("add-b")
        #expect(board?.panel?.size == 3 && board?.panel?.logs == [log])
        let status = call(lead, "status").text
        #expect(status.contains("add-b: Add b") && status.contains("— audit by 3 finders, 0 reported"), "\(status)")

        // An audit of the same commit again reuses the run.
        #expect(!call(lead, "audit", ["task": "add-b"]).isError)
        #expect(lines(runs).count == 1)
    }

    @Test func theFindersBallotsAreVotedIntoOneVerdictThatMergeTakes() throws {
        let runtime = FakeRuntime()
        let (root, lead) = try ready(runtime)
        #expect(!call(lead, "audit", ["task": "add-b"]).isError)
        let seats = try (1...3).map { try finder($0, runtime) }
        let lone: [String: Any] = ["severity": "Important", "failure_scenario": "b.txt holding bee: the contract's check of b gives the wrong result", "file": "b.txt", "line": 1, "evidence": "only finder 2 sees it"]
        let nit: [String: Any] = ["severity": "Nit", "file": "b.txt", "line": 1, "evidence": "no capital"]
        // Finder 2 alone sees an Important finding; finders 1 and 3 a Nit.
        let one = call(seats[0], "submit_audit", Self.verdict.merging(["findings": [nit]]) { $1 })
        #expect(!one.isError, "\(one.text)")
        #expect(one.text.contains("1 of 3 finders have submitted"), "\(one.text)")
        #expect(vault.verdict(root: root, task: "add-b") == nil)
        #expect(call(lead, "merge", ["task": "add-b"]).isError)
        #expect(BoardStore(root: root).load().task("add-b")?.panel?.reported == [1])
        #expect(call(lead, "status").text.contains("audit by 3 finders, 1 reported"))
        // A finding that breaks the ledger's rules is refused for that finder alone.
        #expect(call(seats[1], "submit_audit", Self.verdict.merging(["findings": [lone.merging(["status": "fixed"]) { $1 }]]) { $1 }).isError)
        #expect(!call(seats[1], "submit_audit", Self.verdict.merging(["findings": [lone]]) { $1 }).isError)
        #expect(runtime.steered.isEmpty || !runtime.steered.contains { $0.text.contains("The audit of add-b") }, "no verdict before the last ballot")
        let last = call(seats[2], "submit_audit", Self.verdict.merging(["findings": [nit]]) { $1 })
        #expect(!last.isError, "\(last.text)")
        #expect(last.text.contains("the last of 3: the vote is done"))
        #expect(call(seats[0], "submit_audit", Self.verdict).isError, "no ballot after the vote")

        let verdict = try #require(vault.verdict(root: root, task: "add-b"))
        #expect(verdict.passes)
        let ledger = try #require(vault.audits(root: root, task: "add-b"))
        #expect(ledger.rounds == 1)
        #expect(ledger.findings.map(\.severity) == [.nit, .important])
        #expect(ledger.finding("F1")?.isOpen == true)
        #expect(ledger.vote?.text == "3 finders voted: 1 new finding confirmed, 1 unconfirmed")
        // The Important one shares the Nit's place: it stays an Important finding of its own, unconfirmed.
        #expect(ledger.finding("F2")?.status == .unconfirmed && ledger.finding("F2")?.place == "b.txt:1")
        #expect(ledger.finding("F2")?.evidence == "only finder 2 sees it")
        let told = try #require(runtime.steered.last?.text)
        #expect(told.contains("The audit of add-b passed (complete, clean): Finder 1 (contract and acceptance; complete, clean): checked"), "\(told)")
        #expect(told.contains("3 finders voted: 1 new finding confirmed, 1 unconfirmed"))
        let status = call(lead, "status").text
        #expect(status.contains("3 finders voted"), "\(status)")
        #expect(BoardStore(root: root).load().task("add-b")?.panel?.reported == [1, 2, 3])
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        // cleanup takes the shared run's logs with the task.
        #expect(FileManager.default.fileExists(atPath: root + "/.vibeswitcher/audit/add-b"))
        #expect(!call(lead, "cleanup", ["task": "add-b"]).isError)
        #expect(!FileManager.default.fileExists(atPath: root + "/.vibeswitcher/audit/add-b"))
    }

    @Test func aConfirmedImportantFindingHoldsTheMergeAndAnUnconfirmedOneDoesnt() throws {
        let runtime = FakeRuntime()
        let (root, lead) = try ready(runtime)
        #expect(!call(lead, "audit", ["task": "add-b"]).isError)
        let seats = try (1...3).map { try finder($0, runtime) }
        let other: [String: Any] = ["severity": "Important", "failure_scenario": "line 40 of b.txt read on startup crashes it", "file": "b.txt", "line": 40, "evidence": "only finder 3 sees this"]
        #expect(!call(seats[0], "submit_audit", Self.verdict.merging(["findings": [Self.crash]]) { $1 }).isError)
        #expect(!call(seats[1], "submit_audit", Self.verdict.merging(["findings": [Self.crash.merging(["line": 2]) { $1 }]]) { $1 }).isError)
        #expect(!call(seats[2], "submit_audit", Self.verdict.merging(["findings": [other]]) { $1 }).isError)
        let ledger = try #require(vault.audits(root: root, task: "add-b"))
        #expect(ledger.blocking.map(\.place) == ["b.txt:1"])
        #expect(ledger.findings.first { $0.place == "b.txt:40" }?.status == .unconfirmed)
        let told = try #require(runtime.steered.last?.text)
        #expect(told.contains("1 new finding confirmed, 1 unconfirmed (unconfirmed ones don't hold the merge back"), "\(told)")
        #expect(told.contains("[unconfirmed: 1 of 3 finders saw it: finder 3 (tests and edge cases)]"), "\(told)")
        let refused = call(lead, "merge", ["task": "add-b"])
        #expect(refused.isError && refused.text.contains("add-b:F1 b.txt:1"), "\(refused.text)")
        #expect(!call(lead, "dismiss_finding", ["task": "add-b", "id": "F1", "reason": "the contract allows bee"]).isError)
        #expect(!call(lead, "merge", ["task": "add-b"]).isError, "the unconfirmed one doesn't hold it back")
    }

    @Test func auditRefusesMoreFindersThanTheMacHasRoomFor() throws {
        let runtime = FakeRuntime()
        let (root, lead) = try ready(runtime)
        // Six sessions at most, Mac-wide; four other projects' sessions leave room for two.
        runtime.others = (1...4).map { LeadSessionInfo(id: "other-\($0)", cwd: "/Users/x/dev/project-c/.vibeswitcher/worktrees/t\($0)",
                                                         label: "Worker: t\($0)", live: true, status: "working", tty: nil) }
        let before = runtime.spawned.count
        let refused = call(lead, "audit", ["task": "add-b"])
        #expect(refused.isError)
        #expect(refused.text.contains("audit_finders is 3, and mac_max_sessions leaves room for 2 more sessions now"), "\(refused.text)")
        #expect(refused.text.contains("4 team sessions across 1 project (project-c 4) (mac_max_sessions 6)"), "\(refused.text)")
        #expect(refused.text.contains(LeadPrompts.retryWhenWoken), "\(refused.text)")
        #expect(runtime.spawned.count == before)
        #expect(lines(runs).isEmpty, "nothing built or tested")
        // Two fit.
        #expect(!call(lead, "configure", ["audit_finders": 2]).isError)
        let started = call(lead, "audit", ["task": "add-b"])
        #expect(!started.isError, "\(started.text)")
        #expect(runtime.spawned.filter { $0.label.hasPrefix("Verifier: ") }.count == 2)
        _ = root
    }

    /// With finders, audit runs init_command and test_command as the lead before any finder starts: one a worker
    /// wrote is refused, naming it, before anything is built or tested.
    @Test func aCommandAWorkerWroteIsntRunByAnAuditsSharedRun() throws {
        for key in ["test_command", "init_command"] {
            let runtime = FakeRuntime()
            let (root, lead) = try ready(runtime, finders: 2)
            let ran = temp.url("ran-as-lead").path
            // From the worker's session: its own command in place of the lead's.
            let path = root + "/.vibeswitcher/workflow.md"
            try LeadWorkflow.updating(try Data(contentsOf: URL(fileURLWithPath: path)), with: [(key, "touch \(ran); true")]).write(to: URL(fileURLWithPath: path))
            let refused = call(lead, "audit", ["task": "add-b"])
            #expect(refused.isError)
            #expect(refused.text.hasPrefix("Not audited, nothing built or tested, no finder started"), "\(refused.text)")
            #expect(refused.text.contains("\(key) is now `touch \(ran); true`") && refused.text.contains("configure"), "\(refused.text)")
            #expect(!FileManager.default.fileExists(atPath: ran), "nothing of the worker's command ran")
            #expect(lines(runs).isEmpty, "nothing built or tested")
            #expect(!FileManager.default.fileExists(atPath: root + "/.vibeswitcher/audit"))
            #expect(!runtime.spawned.contains { $0.label.hasPrefix("Verifier: ") })
        }
    }

    @Test func aWorkerCantChangeTheFindersBehindTheLeadsBack() throws {
        let runtime = FakeRuntime()
        let (root, lead) = try ready(runtime)
        let path = root + "/.vibeswitcher/workflow.md"
        try LeadWorkflow.updating(try Data(contentsOf: URL(fileURLWithPath: path)), with: [("audit_finders", "1")]).write(to: URL(fileURLWithPath: path))
        let refused = call(lead, "audit", ["task": "add-b"])
        #expect(refused.isError)
        #expect(refused.text.contains("audit_finders is now `1`") && refused.text.contains("configure"), "\(refused.text)")
        #expect(!runtime.spawned.contains { $0.label.hasPrefix("Verifier: ") })
    }

    @Test func sensitivePathsBringASecurityFinder() throws {
        #expect(LeadPrompts.Focus.panel(3, sensitive: true) == [.contract, .bugs, .security])
        #expect(LeadPrompts.Focus.panel(3, sensitive: false) == [.contract, .bugs, .tests])
        #expect(LeadPrompts.Focus.panel(2, sensitive: true) == [.contract, .bugsAndSecurity])
        #expect(LeadPrompts.Focus.panel(2, sensitive: false) == [.contract, .bugs])
        let runtime = FakeRuntime()
        let (root, lead) = try ready(runtime)
        #expect(!call(lead, "configure", ["sensitive_paths": "b.txt"]).isError)
        #expect(!call(lead, "audit", ["task": "add-b"]).isError)
        let text = try prompt(3, runtime)
        #expect(text.contains("Your focus: security: the branch touches sensitive paths (b.txt)"), "\(text)")
        _ = root
    }
}
