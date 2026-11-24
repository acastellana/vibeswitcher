import Foundation
import Testing
@testable import VibeCore

/// REVIEW.md's rules by id (`LeadReviewRules`): REVIEW.md gives each an id, a trigger and a source; the verifier lists
/// the ids it applied in submit_audit, which the audit's ledger records with the rules its findings came from; status
/// counts each rule's audits over 30 days.
struct LeadReviewRulesTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every rule under Important has its id, a Trigger and a Source; the Nit and Report sections have no ids.
    @Test func everyRuleInReviewMdHasAnIdATriggerAndASource() throws {
        let guide = try String(contentsOf: Self.repo.appendingPathComponent(LeadRisk.guideFile), encoding: .utf8)
        let sections = guide.components(separatedBy: "\n## ")
        let important = try #require(sections.first { $0.hasPrefix("Important") })
        let items = important.components(separatedBy: "\n- ").dropFirst()
        #expect(items.count == 13, "REVIEW.md's 13 rules, none added or dropped")
        let ids = LeadReviewRules.ids(in: guide)
        #expect(ids == (1...items.count).map { "R\($0)" })
        for (index, item) in items.enumerated() {
            #expect(item.hasPrefix("**R\(index + 1)** "), "\(item)")
            #expect(item.contains("\n  Trigger: "), "R\(index + 1) has no Trigger")
            let source = try #require(item.range(of: "\n  Source: "), "R\(index + 1) has no Source")
            #expect(!item[source.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        for section in sections where section.hasPrefix("Nit") || section.hasPrefix("Report") {
            #expect(LeadReviewRules.ids(in: "\n" + section).isEmpty)
        }
        #expect(sections.contains { $0.hasPrefix("Nit, never more\n- Copy, naming, comments") })
        #expect(sections.contains { $0.hasPrefix("Report\n- Each finding: file:line") && $0.contains("Last line: the count by severity") })
        // It reaches the verifier whole.
        #expect(guide.utf8.count < LeadRisk.guideLimit, "\(guide.utf8.count) bytes")
    }

    @Test func idsAreReadFromBoldListItemsOnlyAndSortedByNumber() {
        let guide = "## Important\n- **R2** two\n  Trigger: any diff\n* **r10** ten\n- R3 not bold\n- **R2** again\nSee **R7** in text."
        #expect(LeadReviewRules.ids(in: guide) == ["R2", "R10"])
        #expect(LeadReviewRules.ids(in: nil).isEmpty)
        #expect(LeadReviewRules.sorted(["R10", "R2", "R2", "S1", "R1"]) == ["R1", "R2", "R10", "S1"])
        #expect(LeadReviewRules.id(" **r4** ") == "R4" && LeadReviewRules.id("[R12]") == "R12")
        #expect(LeadReviewRules.id("R1 (main thread)") == "R1" && LeadReviewRules.id("**r5**: tests") == "R5")
        #expect(LeadReviewRules.id("rule four") == nil && LeadReviewRules.id("") == nil && LeadReviewRules.id("R") == nil)
    }

    /// submit_audit's `rules`: a list, that list as JSON text or ids in one text; none (an older verifier) is nil;
    /// anything that isn't an id is refused.
    @Test func theVerdictsRulesParseInEachShapeAndNoneStillParses() throws {
        #expect(try LeadToolset.rulesArgument(["r4", "R1", "R4 "]) == ["R1", "R4"])
        #expect(try LeadToolset.rulesArgument("[\"R10\", \"R2\"]") == ["R2", "R10"])
        #expect(try LeadToolset.rulesArgument("R3, R1") == ["R1", "R3"])
        #expect(try LeadToolset.rulesArgument(nil) == nil)
        #expect(try LeadToolset.rulesArgument(NSNull()) == nil)
        #expect(try LeadToolset.rulesArgument([String]()) == nil)
        #expect(try LeadToolset.rulesArgument("") == nil)
        // As a verifier may write them: an id with its name, or none.
        #expect(try LeadToolset.rulesArgument(["R1 (main thread)", "R13: the other branch"]) == ["R1", "R13"])
        #expect(try LeadToolset.rulesArgument(["none"]) == nil && LeadToolset.rulesArgument("None") == nil)
        #expect(throws: LeadToolset.Problem.self) { try LeadToolset.rulesArgument(["R1", "the main thread one"]) }
        #expect(throws: LeadToolset.Problem.self) { try LeadToolset.rulesArgument([3]) }
        #expect(throws: LeadToolset.Problem.self) { try LeadToolset.rulesArgument(["rules": "R1"]) }
        // A finding's rule: kept as an id, left out when it isn't one (the finding itself still counts).
        let findings = try LeadToolset.findingReports([
            ["severity": "Nit", "file": "a.txt", "line": 1, "evidence": "e", "rule": "r3"],
            ["severity": "Nit", "file": "a.txt", "line": 2, "evidence": "e", "rule": "main thread"],
            ["severity": "Nit", "file": "a.txt", "line": 3, "evidence": "e"],
        ])
        #expect(findings.map(\.rule) == ["R3", nil, nil])
    }

    /// The ledger keeps one use per audit that listed its rules: the rules applied (with any a finding names) and those
    /// its new findings came from; an audit that listed none keeps nothing.
    @Test func theLedgerRecordsEachAuditsRulesAndTheOnesThatFound() throws {
        var ledger = LeadAuditLedger()
        let important = LeadFinding.Report(severity: .important, file: "a.swift", line: 3, evidence: "e", failureScenario: "f", rule: "R2")
        let nit = LeadFinding.Report(severity: .nit, file: "b.swift", line: 9, evidence: "e", rule: "R7")
        try ledger.record([important, nit], commit: "c1", passes: true, rules: ["R1", "R2"], at: 100)
        #expect(ledger.ruleUses == [LeadRuleUse(round: 1, at: 100, applied: ["R1", "R2", "R7"], found: ["R2", "R7"])])
        #expect(ledger.findings.map(\.rule) == ["R2", "R7"])
        // A re-audit: the open finding said again isn't new, so it finds nothing for R2 this time.
        var again = important
        again.id = "F1"
        try ledger.record([again, LeadFinding.Report(id: "F2", severity: .nit, file: "b.swift", line: 9, evidence: "e", status: .fixed, reason: "ok")],
                          commit: "c2", passes: true, rules: ["R2"], at: 200)
        #expect(ledger.ruleUses?.last == LeadRuleUse(round: 2, at: 200, applied: ["R2"], found: []))
        // A verdict listing no rules (an older verifier): recorded as ever, no use kept.
        try ledger.record([again], commit: "c3", passes: true)
        #expect(ledger.rounds == 3 && ledger.ruleUses?.count == 2)
        // A refused record keeps nothing.
        let before = ledger
        #expect(throws: LeadAuditLedger.Refusal.self) { try ledger.record([], commit: "c4", passes: true, rules: ["R1"]) }
        #expect(ledger == before)
        // Ledgers written before rule uses decode with none.
        let old = try JSONDecoder().decode(LeadAuditLedger.self, from: Data(#"{"findings":[],"rounds":1,"failedRounds":0}"#.utf8))
        #expect(old.ruleUses == nil)
    }

    func task(_ slug: String, uses: [LeadRuleUse], removed: Bool = false) -> LeadTask {
        var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""), status: .done)
        var ledger = LeadAuditLedger()
        ledger.ruleUses = uses
        task.audits = ledger
        if removed { task.removedAt = 1 }
        return task
    }

    /// The per-rule count over 30 days: audits that applied each rule, and those it produced a finding in.
    @Test func eachRulesCountOverThirtyDaysComesFromTheRecordedAudits() {
        let now = 100 * 86_400.0, day = 86_400.0
        let tasks = [
            task("a", uses: [LeadRuleUse(round: 1, at: now - 2 * day, applied: ["R1", "R2"], found: ["R2"]),
                             LeadRuleUse(round: 2, at: now - day, applied: ["R1", "R2"], found: [])]),
            task("b", uses: [LeadRuleUse(round: 1, at: now - 29 * day, applied: ["R2", "R9"], found: ["R2", "R9"]),
                             // Older than 30 days: not counted.
                             LeadRuleUse(round: 1, at: now - 31 * day, applied: ["R3"], found: ["R3"])]),
            task("gone", uses: [LeadRuleUse(round: 1, at: now - day, applied: ["R3"], found: ["R3"])], removed: true),
            task("none", uses: []),
        ]
        let (audits, rules) = LeadReviewRules.counts(tasks, now: now)
        #expect(audits == 3)
        #expect(rules == ["R1": .init(applied: 2, found: 0), "R2": .init(applied: 3, found: 2), "R9": .init(applied: 1, found: 1)])
        let line = LeadReviewRules.statusLine(tasks, known: ["R1", "R2", "R3"], now: now)
        #expect(line == "Review rules, last 30 days (3 audits listed theirs; applied/with a finding): R1 2/0, R2 3/2, R3 0/0, "
            + "R9 1/1 (not in REVIEW.md). Never applied: R3. Applied, never a finding: R1.")
        // No audit listed its rules: no line, and REVIEW.md isn't read.
        #expect(LeadReviewRules.statusLine([task("none", uses: [])], known: { Issue.record("read REVIEW.md"); return [] }(), now: now) == nil)
    }

    /// The verifier's prompt: with rule ids in REVIEW.md, apply only those the diff triggers and list them; without,
    /// as before.
    @Test func theVerifierIsToldToApplyOnlyTriggeredRulesAndListThem() {
        let task = LeadTask(slug: "add-b", title: "Add b", contract: LeadContract(goal: "b", acceptance: [], boundaries: [], context: ""), status: .review)
        let withIds = LeadPrompts.verifier(task: task, root: "/r", workflow: LeadWorkflow(), guide: "## Important\n- **R1** one\n  Trigger: any diff\n  Source: x")
        #expect(withIds.contains(LeadPrompts.rulesRule) && withIds.contains("- **R1** one"))
        for needle in ["Apply only the rules whose Trigger this diff matches", "trigger is any diff always applies", "give rules: the ids",
                       "each finding that comes from one of them its rule"] {
            #expect(LeadPrompts.rulesRule.contains(needle), "missing \(needle)")
        }
        let plain = LeadPrompts.verifier(task: task, root: "/r", workflow: LeadWorkflow(), guide: "## Important\n- Secrets in logs.")
        #expect(plain.contains("- Secrets in logs.") && !plain.contains(LeadPrompts.rulesRule))
        #expect(LeadToolset.rulesShape.contains("REVIEW.md rules you applied"))
    }
}

/// The same through the tools: a verifier's submit_audit with rules recorded on the audit (vault and board), one
/// without still taken, a finders' vote taking every finder's rules, and status's count.
struct LeadReviewRulesToolsTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func call(_ tools: LeadToolset, _ name: String, _ arguments: [String: Any] = [:]) -> MCPToolResult { tools.call(name, arguments) }

    /// A repository whose base has a REVIEW.md with rules R1–R3, a lead (with `finders` finders when given) and the
    /// task add-b worked on, reported and under audit.
    func audited(_ runtime: FakeRuntime, finders: Int? = nil) throws -> (root: String, lead: LeadToolset) {
        let url = temp.url("lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        try "## Important\n- **R1** one\n  Trigger: any diff\n  Source: x\n- **R2** two\n  Trigger: a.txt\n  Source: y\n- **R3** three\n  Trigger: c\n  Source: z\n"
            .write(toFile: root + "/REVIEW.md", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt", "REVIEW.md"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        let lead = try lead(root, runtime)
        if let finders {
            #expect(!call(lead, "configure", ["audit_finders": finders, "test_command": "test -f b.txt"]).isError)
        }
        _ = call(lead, "add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "review": "audit"])
        #expect(!call(lead, "start_worker", ["task": "add-b"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b"], in: worktree)
        #expect(!call(try seat("worker-add-b", runtime), "report", doneReport("added b")).isError)
        let audit = call(lead, "audit", ["task": "add-b"])
        #expect(!audit.isError, "\(audit.text)")
        return (root, lead)
    }

    static let verdict: [String: Any] = ["completion": "complete", "integrity": "clean", "summary": "checked"]
    static let nit: [String: Any] = ["severity": "Nit", "file": "b.txt", "line": 1, "evidence": "no capital", "rule": "R2"]

    @Test func aVerdictListingRuleIdsIsRecordedOnTheAuditAndStatusCountsThem() throws {
        let runtime = FakeRuntime()
        let (root, lead) = try audited(runtime)
        let verifier = try seat("verify-add-b", runtime)
        let given = call(verifier, "submit_audit", Self.verdict.merging(["rules": ["r1", "R2"], "findings": [Self.nit]]) { $1 })
        #expect(!given.isError, "\(given.text)")
        let ledger = try #require(vault.audits(root: root, task: "add-b"))
        let use = try #require(ledger.ruleUses?.first)
        #expect(ledger.ruleUses?.count == 1 && use.round == 1 && use.applied == ["R1", "R2"] && use.found == ["R2"])
        #expect(abs(use.at - Date().timeIntervalSince1970) < 600)
        #expect(ledger.findings.first?.rule == "R2")
        // The board's copy, which the archive keeps and status counts.
        #expect(BoardStore(root: root).load().task("add-b")?.audits?.ruleUses == ledger.ruleUses)
        let status = call(lead, "status").text
        #expect(status.contains("Review rules, last 30 days (1 audit listed theirs; applied/with a finding): R1 1/0, R2 1/1, R3 0/0. "
            + "Never applied: R3. Applied, never a finding: R1."), "\(status)")
    }

    @Test func aVerdictListingNoRulesStillParsesAndRecordsNone() throws {
        let runtime = FakeRuntime()
        let (root, lead) = try audited(runtime)
        let verifier = try seat("verify-add-b", runtime)
        // As a verifier from before rules were asked submits it.
        let given = call(verifier, "submit_audit", Self.verdict.merging(["findings": [Self.nit.filter { $0.key != "rule" }]]) { $1 })
        #expect(!given.isError, "\(given.text)")
        #expect(try #require(vault.verdict(root: root, task: "add-b")).passes)
        let ledger = try #require(vault.audits(root: root, task: "add-b"))
        #expect(ledger.rounds == 1 && ledger.findings.count == 1 && ledger.ruleUses == nil)
        #expect(!call(lead, "status").text.contains("Review rules"))
        #expect(BoardStore(root: root).load().task("add-b")?.status == .review)
    }

    @Test func aVerdictWithSomethingElseForRulesIsRefusedAndNothingIsRecorded() throws {
        let runtime = FakeRuntime()
        let (root, _) = try audited(runtime)
        let verifier = try seat("verify-add-b", runtime)
        let refused = call(verifier, "submit_audit", Self.verdict.merging(["rules": ["the main-thread rule"]]) { $1 })
        #expect(refused.isError && refused.text.contains("rules is a list of REVIEW.md rule ids"), "\(refused.text)")
        #expect(vault.verdict(root: root, task: "add-b") == nil)
    }

    /// A finders' vote: the rules any finder applied, and those a kept finding came from.
    @Test func theFindersVoteRecordsEveryFindersRules() throws {
        let runtime = FakeRuntime()
        let (root, _) = try audited(runtime, finders: 3)
        let seats = try (1...3).map { try seat($0 == 1 ? "verify-add-b" : "finder\($0)-add-b", runtime) }
        #expect(!call(seats[0], "submit_audit", Self.verdict.merging(["rules": ["R1"], "findings": [Self.nit]]) { $1 }).isError)
        #expect(!call(seats[1], "submit_audit", Self.verdict.merging(["rules": ["R2"], "findings": [Self.nit]]) { $1 }).isError)
        // An older finder lists none.
        let last = call(seats[2], "submit_audit", Self.verdict)
        #expect(!last.isError && last.text.contains("the vote is done"), "\(last.text)")
        let ledger = try #require(vault.audits(root: root, task: "add-b"))
        #expect(ledger.ruleUses?.map(\.applied) == [["R1", "R2"]] && ledger.ruleUses?.first?.found == ["R2"])
        #expect(ledger.findings.first?.rule == "R2")
    }
}
