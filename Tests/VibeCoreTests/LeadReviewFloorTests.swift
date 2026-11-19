import Foundation
import Testing
@testable import VibeCore

/// The review rules' floor (`LeadReviewFloor`): the user sets it in Settings, the app alone writes it to the vault, the
/// lead's configure may raise a rule above it and is refused below it, and what's in force is the floor joined with
/// workflow.md, whatever a worker writes there.
struct LeadReviewFloorTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("floor")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// The fixture's lead, reading the floor afresh at each access (`floorClock` a whole `floorFresh` on each time):
    /// these tests set the floor after the lead's first read. Those about the brief cache set their own clock.
    func freshLead(_ root: String, _ runtime: FakeRuntime) throws -> LeadToolset {
        let lead = try lead(root, runtime)
        let clock = Clock()
        lead.floorClock = {
            clock.now += LeadToolset.floorFresh
            return clock.now
        }
        return lead
    }

    func file(_ root: String) -> String { root + "/.vibeswitcher/workflow.md" }

    /// What a worker's Bash does to the project's workflow.md: one setting's line rewritten.
    func workerWrites(_ key: String, _ value: String, root: String) throws {
        let current = FileManager.default.contents(atPath: file(root)) ?? Data()
        try LeadWorkflow.updating(current, with: [(key, value)]).write(to: URL(fileURLWithPath: file(root)))
    }

    func refusedForFloor(_ result: MCPToolResult) -> Bool {
        result.isError && result.text.hasPrefix("Nothing was changed") && result.text.contains(LeadReviewFloor.place)
    }

    @Test func pathsDroppingAFloorGlobAreRefusedAddingOneIsTakenAndTheUnionIsInForce() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try freshLead(root, runtime)
        try vault.setReviewFloor(LeadReviewFloor(sensitivePaths: [".github/", "secrets/"], strictPaths: ["src/signing/**"]), root: root)
        for (key, floor, other) in [("sensitive_paths", "secrets/", ".github/"), ("strict_paths", "src/signing/**", "src/other/")] {
            let before = FileManager.default.contents(atPath: file(root))
            let dropped = lead.call("configure", [key: [other]])
            #expect(refusedForFloor(dropped) && dropped.text.contains("leave out \(floor)"), "\(dropped.text)")
            #expect(FileManager.default.contents(atPath: file(root)) == before)
            let added = lead.call("configure", [key: [floor, other, "docs/keys/"]])
            #expect(!added.isError, "\(added.text)")
        }
        // A worker drops them from the file: the floor's are in force still, joined with what the file says.
        try workerWrites("sensitive_paths", "docs/keys/", root: root)
        try workerWrites("strict_paths", "", root: root)
        try workerWrites("merge_policy", "ask_sensitive", root: root)
        let workflow = lead.workflow
        #expect(Set(workflow.sensitiveGlobs) == [".github/", "secrets/", "docs/keys/"])
        #expect(workflow.strictGlobs == ["src/signing/**"])
        #expect(workflow.filesNeedingApproval(["secrets/token", "README.md"]) == ["secrets/token"])
        #expect(workflow.strictTouched(["src/signing/key.swift", "a.txt"]) == ["src/signing/key.swift"])
        // What the file says stays as written, for the guard rails' hashes.
        #expect(workflow.sensitivePaths == ["docs/keys/"] && workflow.strictPaths == nil)
    }

    @Test func findersPolicyAndRiskBelowTheFloorAreRefusedAndTheStricterIsInForce() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try freshLead(root, runtime)
        try vault.setReviewFloor(LeadReviewFloor(auditFinders: 2, mergePolicy: .askSensitive, riskLines: 300, riskModel: true), root: root)
        for (key, value) in [("audit_finders", "1"), ("merge_policy", "auto"), ("risk_lines", "500"), ("risk_lines", "0"), ("risk_model", "false")] {
            let refused = lead.call("configure", [key: value])
            #expect(refusedForFloor(refused) && refused.text.contains(key), "\(key) \(value): \(refused.text)")
        }
        // One refused rule changes nothing, not even the others given with it.
        #expect(refusedForFloor(lead.call("configure", ["audit_finders": "1", "max_workers": "2"])))
        #expect(LeadWorkflow.load(from: file(root)).maxWorkers == 3)
        for (key, value) in [("audit_finders", "3"), ("audit_finders", "2"), ("merge_policy", "ask_all"), ("merge_policy", "ask_sensitive"),
                             ("merge_policy", ""), ("risk_lines", "300"), ("risk_lines", "120"), ("risk_model", "true")] {
            let taken = lead.call("configure", [key: value])
            #expect(!taken.isError, "\(key) \(value): \(taken.text)")
        }
        // A worker loosens the file: the floor's stricter values are in force.
        for (key, value) in [("audit_finders", "1"), ("merge_policy", "auto"), ("risk_lines", "0"), ("risk_model", "false")] {
            try workerWrites(key, value, root: root)
        }
        let workflow = lead.workflow
        #expect(workflow.findersInForce == 2 && workflow.policyInForce == .askSensitive)
        #expect(workflow.riskLinesInForce == 300 && workflow.riskModelInForce)
        #expect(LeadRisk.deterministic(changes: [LeadRisk.Change(path: "Sources/x.swift", added: 400, removed: 0)], patch: { nil }, workflow: workflow) != nil)
        // The file's stricter value stays in force over the floor's.
        try workerWrites("risk_lines", "50", root: root)
        try workerWrites("merge_policy", "ask_all", root: root)
        #expect(lead.workflow.riskLinesInForce == 50 && lead.workflow.policyInForce == .askAll)
    }

    @Test func aVerifierOnTheWorkersModelIsRefusedWhileTheFloorSaysDifferent() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        runtime.claude = "claude --model opus --dangerously-skip-permissions"
        let lead = try freshLead(root, runtime)
        let clock = Clock()
        lead.floorClock = { clock.now }
        try vault.setReviewFloor(LeadReviewFloor(), root: root)
        for model in ["opus", "claude-opus-5-5"] {
            let refused = lead.call("configure", ["verifier_model": model])
            #expect(refusedForFloor(refused) && refused.text.contains("verifier_model"), "\(refused.text)")
        }
        #expect(!lead.call("configure", ["verifier_model": "fable"]).isError)
        #expect(lead.auditModel(lead.workflow) == "fable")
        // Written into the file by a worker: audits run on another model all the same.
        try workerWrites("verifier_model", "opus", root: root)
        #expect(lead.auditModel(lead.workflow) == "fable")
        // The user allows it in Settings: it's taken at once (configure reads the vault afresh), and in force once the
        // floor last read is stale.
        try vault.setReviewFloor(LeadReviewFloor(verifierDifferent: false), root: root)
        #expect(!lead.call("configure", ["verifier_model": "opus"]).isError)
        clock.now += LeadToolset.floorFresh
        #expect(lead.auditModel(lead.workflow) == "opus")
    }

    /// Workers on Claude's default (no --model, nothing in Claude's settings, or an alias): counted as opus, so
    /// neither configure nor workflow.md puts audits on opus under the floor (blind check).
    @Test func workersOnClaudesDefaultCountAsOpusUnderTheFloor() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        runtime.claude = "claude --dangerously-skip-permissions"
        let lead = try freshLead(root, runtime)
        try vault.setReviewFloor(LeadReviewFloor(), root: root)
        #expect(runtime.workerModel(root: root) == nil)
        let refused = lead.call("configure", ["verifier_model": "opus"])
        #expect(refusedForFloor(refused) && refused.text.contains("Claude's default, opus"), "\(refused.text)")
        try workerWrites("verifier_model", "opus", root: root)
        #expect(!LeadReviewFloor.sameModel(lead.auditModel(lead.workflow), "opus"), "\(lead.auditModel(lead.workflow))")
        #expect(LeadReviewFloor().refusal(key: "verifier_model", value: "opus", workerModel: "default") != nil)
        #expect(LeadReviewFloor().refusal(key: "verifier_model", value: "sonnet", workerModel: nil) == nil)
    }

    /// A task pinned to the verifier's model (add_task's model) under "never the workers' model": its audit runs on
    /// a model that's neither the task's own nor the project's workers' (board.json's model may be a worker's own word).
    @Test func aTaskPinnedToTheVerifiersModelIsAuditedOnAnother() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        runtime.claude = "claude --model opus --dangerously-skip-permissions"
        let lead = try freshLead(root, runtime)
        let clock = Clock()
        lead.floorClock = { clock.now }
        try vault.setReviewFloor(LeadReviewFloor(), root: root)
        #expect(!lead.call("configure", ["verifier_model": "fable"]).isError)
        var pinned = LeadTask(slug: "pinned", title: "Pinned", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""), status: .review)
        pinned.model = "fable"
        #expect(lead.auditModel(lead.workflow, task: pinned) == "sonnet")
        try workerWrites("verifier_model", "", root: root)
        #expect(lead.auditModel(lead.workflow, task: pinned) == "sonnet")
        // Without the floor's word, as before: verifier_model, or another than the project's workers'.
        try vault.setReviewFloor(LeadReviewFloor(verifierDifferent: false), root: root)
        clock.now += LeadToolset.floorFresh
        #expect(lead.auditModel(lead.workflow, task: pinned) == "fable")
    }

    /// A worker started on the workers' model (opus) writes another model as its task's in board.json: its audit
    /// still never runs on opus, with verifier_model unset or naming the model it wrote.
    @Test func aModelWrittenIntoTheBoardDoesntPutTheAuditOnTheWorkersModel() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        runtime.claude = "claude --model opus --dangerously-skip-permissions"
        let lead = try freshLead(root, runtime)
        try vault.setReviewFloor(LeadReviewFloor(), root: root)
        // Unpinned, so its worker started on opus; then the board says fable.
        try lead.store.update { board in
            board.tasks.append(LeadTask(slug: "forged", title: "Forged", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""),
                                        status: .review))
        }
        try lead.store.update { board in board.tasks[try #require(board.taskIndex("forged"))].model = "fable" }
        let task = try #require(lead.store.load().task("forged"))
        #expect(task.model == "fable")
        #expect(!LeadReviewFloor.sameModel(lead.auditModel(lead.workflow, task: task), "opus"))
        #expect(!lead.call("configure", ["verifier_model": "fable"]).isError)
        #expect(!LeadReviewFloor.sameModel(lead.auditModel(lead.workflow, task: task), "opus"))
        // Claude's default (no --model, nothing in settings) counts as opus.
        runtime.claude = "claude --dangerously-skip-permissions"
        try workerWrites("verifier_model", "", root: root)
        #expect(lead.auditModel(lead.workflow, task: task) == "sonnet")
    }

    /// An alias (default, best) may be the workers' model: refused under the floor, and passed over when written in.
    @Test func aVerifierModelThatNamesNoModelIsRefusedUnderTheFloor() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        runtime.claude = "claude --model opus --dangerously-skip-permissions"
        let lead = try freshLead(root, runtime)
        try vault.setReviewFloor(LeadReviewFloor(), root: root)
        for alias in ["default", "best"] {
            let refused = lead.call("configure", ["verifier_model": alias])
            #expect(refusedForFloor(refused) && refused.text.contains("doesn't say which model"), "\(refused.text)")
        }
        try workerWrites("verifier_model", "default", root: root)
        #expect(lead.auditModel(lead.workflow) == "fable")
        #expect(!lead.call("configure", ["verifier_model": "claude-sonnet-5-5"]).isError)
    }

    /// A vault read that fails once (a timeout) keeps the floor last read: the rules don't fall back to the file's.
    @Test func aFloorReadThatFailsKeepsTheLastFloor() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try freshLead(root, runtime)
        try vault.setReviewFloor(LeadReviewFloor(mergePolicy: .askAll), root: root)
        let failing = Flag()
        let host = vault(for: runtime)
        let flaky = LeadVault(folder: vault.folder) { request in
            if case .reviewFloor = request, failing.on { throw LeadVault.Refused("timed out") }
            return try host.call(request)
        }
        let lead = LeadToolset(root: root, runtime: runtime, vault: flaky)
        let clock = Clock()
        lead.floorClock = { clock.now }
        #expect(lead.workflow.policyInForce == .askAll)
        failing.on = true
        clock.now += LeadToolset.floorFresh
        #expect(lead.workflow.policyInForce == .askAll)
        #expect(lead.workflow.filesNeedingApproval(["a.txt"]) == ["a.txt"])
    }

    /// One tool call reads `workflow` many times: the floor is asked of the host once while it's fresh, again after.
    @Test func theFloorIsReadOnceWhileFresh() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try freshLead(root, runtime)
        try vault.setReviewFloor(LeadReviewFloor(auditFinders: 2), root: root)
        let reads = Counter()
        let host = vault(for: runtime)
        let counting = LeadVault(folder: vault.folder) { request in
            if case .reviewFloor = request { reads.add() }
            return try host.call(request)
        }
        let lead = LeadToolset(root: root, runtime: runtime, vault: counting)
        let clock = Clock()
        lead.floorClock = { clock.now }
        // The toolset read it once when made (its introduction), on the system's clock: that read is stale on the test's.
        let made = reads.value
        for _ in 0..<5 { #expect(lead.workflow.findersInForce == 2) }
        _ = lead.call("status", [:])
        #expect(reads.value == made + 1)
        // The user raises it in Settings: in force at the next read once the last one is stale.
        try vault.setReviewFloor(LeadReviewFloor(auditFinders: 3), root: root)
        clock.now += LeadToolset.floorFresh - 0.5
        #expect(lead.workflow.findersInForce == 2 && reads.value == made + 1)
        clock.now += 0.5
        #expect(lead.workflow.findersInForce == 3 && reads.value == made + 2)
    }

    @Test func auditSamplePercentBelowTheFloorIsRefusedAndTheHigherIsInForce() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try freshLead(root, runtime)
        try vault.setReviewFloor(LeadReviewFloor(auditSamplePercent: 20), root: root)
        for value in ["10", "0", ""] {
            let refused = lead.call("configure", ["audit_sample_percent": value])
            #expect(refusedForFloor(refused) && refused.text.contains("audit_sample_percent"), "\(value): \(refused.text)")
        }
        for value in ["20", "50"] { #expect(!lead.call("configure", ["audit_sample_percent": value]).isError) }
        // A worker writes 0 into the file: the floor's share is drawn all the same.
        try workerWrites("audit_sample_percent", "0", root: root)
        #expect(lead.workflow.auditSamplePercent == 0 && lead.workflow.samplePercentInForce == 20)
        #expect(lead.call("status", [:]).text.contains("audit_sample_percent 20 (workflow.md: 0)"))
        #expect(lead.call("configure", [:]).text.contains("- audit_sample_percent: floor 20; in force 20"))
        try workerWrites("audit_sample_percent", "70", root: root)
        #expect(lead.workflow.samplePercentInForce == 70)
    }

    /// A floor recorded before audit_sample_percent was part of it decodes with no share held.
    @Test func aFloorRecordedWithoutTheSampleShareHoldsNone() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LeadReviewFloor(auditFinders: 2, auditSamplePercent: 30))) as! [String: Any]
        #expect(object["auditSamplePercent"] as? Int == 30)
        object["auditSamplePercent"] = nil
        let older = try JSONDecoder().decode(LeadReviewFloor.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older == LeadReviewFloor(auditFinders: 2, auditSamplePercent: 0))
    }

    /// The workers' model, when the app knows it: a verifier_model naming theirs starts the floor at "any model".
    @Test func theStartingFloorTakesTheWorkersModel() {
        var workflow = LeadWorkflow()
        workflow.verifierModel = "opus"
        #expect(LeadReviewFloor.starting(from: workflow, workerModel: "claude-opus-5-5").verifierDifferent == false)
        #expect(LeadReviewFloor.starting(from: workflow, workerModel: "sonnet").verifierDifferent)
        #expect(LeadReviewFloor.starting(from: workflow).verifierDifferent)
    }

    @Test func onlyTheAppWritesTheFloorAndStatusShowsIt() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try freshLead(root, runtime)
        let floor = LeadReviewFloor(sensitivePaths: ["secrets/"], auditFinders: 2, mergePolicy: .askSensitive, riskLines: 400, riskModel: true)
        try vault.setReviewFloor(floor, root: root)
        // The lead asking the host itself, a worker's session, a process outside every session: each refused.
        let worker = book.vault(folder: vault.folder, as: { .session("worker-session") })
        let outside = book.vault(folder: vault.folder, as: { .unknown })
        for caller in [vault(for: runtime), worker, outside] {
            #expect(throws: LeadVault.Refused.self) { try caller.setReviewFloor(LeadReviewFloor(), root: root) }
            #expect(throws: LeadVault.Refused.self) { try caller.setReviewFloor(LeadReviewFloor(), root: root, onlyIfUnset: true) }
        }
        #expect(try vault.reviewFloor(root: root) == floor)
        // Kept with the vault: the host's sealed copy restores it.
        let restored = LeadVault.Book(restoring: book.serialized).vault(folder: vault.folder, as: { .app })
        #expect(try restored.reviewFloor(root: root) == floor)
        // status: the floor, and what's in force.
        try workerWrites("audit_finders", "3", root: root)
        // status: one line, each rule the floor holds above workflow.md; finders 3 > the floor's 2 isn't one.
        let status = lead.call("status", [:]).text
        let line = try #require(status.components(separatedBy: "\n").first { $0.hasPrefix("Review rules' floor") }, "\(status)")
        #expect(!line.contains("merge_policy"), "\(line)")
        #expect(line.contains("risk_model") == false && !line.contains("audit_finders"), "\(line)")
        #expect(line.contains("sensitive_paths also secrets/"), "\(line)")
        // A floor above the file's value: named, with the file's.
        try workerWrites("risk_model", "false", root: root)
        #expect(lead.call("status", [:]).text.contains("risk_model on (workflow.md: off)"))
        // configure(): each rule in full, and where the user sets the floor.
        let shown = lead.call("configure", [:]).text
        #expect(shown.contains("Review rules' floor, set by the user in \(LeadReviewFloor.place)"), "\(shown)")
        #expect(shown.contains("- audit_finders: floor 2; in force 3"), "\(shown)")
        #expect(shown.contains("- merge_policy: floor ask_sensitive; in force not chosen (ask_sensitive)"), "\(shown)")
        #expect(shown.contains("- sensitive_paths: floor secrets/; in force"), "\(shown)")
    }

    @Test func theFloorStartsAtTheProjectsValuesSoNothingChanges() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        // The project as it is: its own sensitive_paths, auto, the rest left to their defaults.
        try FileManager.default.createDirectory(atPath: root + "/.vibeswitcher", withIntermediateDirectories: true)
        let template = LeadWorkflow.updating(LeadWorkflow.template, with: [("merge_policy", "auto"), ("sensitive_paths", ".claude/, AGENTS.md, Sources/VibeHost/")])
        try template.write(toFile: file(root), atomically: true, encoding: .utf8)
        let workflow = LeadWorkflow.load(from: file(root))
        let starting = LeadReviewFloor.starting(from: workflow)
        #expect(starting == LeadReviewFloor(sensitivePaths: [".claude/", "AGENTS.md", "Sources/VibeHost/"], strictPaths: [], auditFinders: 1,
                                            mergePolicy: .auto, riskLines: 400, riskModel: true, verifierDifferent: true,
                                            auditSamplePercent: 10))
        // The app records it when it starts the lead, once: a later start doesn't replace what the user set.
        _ = try vault.startLead(root: root, branch: "main", floor: starting)
        #expect(try vault.reviewFloor(root: root) == starting)
        let raised = LeadReviewFloor(sensitivePaths: [".claude/"], auditFinders: 2)
        try vault.setReviewFloor(raised, root: root)
        _ = try vault.startLead(root: root, branch: "main", floor: starting)
        #expect(try vault.reviewFloor(root: root) == raised)
        try vault.setReviewFloor(starting, root: root)
        // At the starting floor, what's in force is what the file says, and setting it again is taken.
        let lead = try freshLead(root, runtime)
        var floored = lead.workflow
        #expect(floored.floor == starting)
        floored.floor = nil
        #expect(lead.workflow.sensitiveGlobs == floored.sensitiveGlobs && lead.workflow.findersInForce == 1 && lead.workflow.policyInForce == .auto)
        #expect(lead.workflow.riskLinesInForce == 400 && lead.workflow.riskModelInForce && lead.workflow.strictGlobs == nil)
        let again = lead.call("configure", ["sensitive_paths": [".claude/", "AGENTS.md", "Sources/VibeHost/"], "audit_finders": "1", "merge_policy": "auto",
                                            "risk_lines": "400", "risk_model": "true", "verifier_model": "", "audit_sample_percent": "10"])
        #expect(!again.isError, "\(again.text)")
    }

    @Test func withNoFloorRecordedTheRulesAreAsTheFileSays() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try freshLead(root, runtime)
        #expect(try vault.reviewFloor(root: root) == nil)
        for (key, value) in [("audit_finders", "1"), ("merge_policy", "auto"), ("risk_lines", "0"), ("risk_model", "false")] {
            #expect(!lead.call("configure", [key: value]).isError)
        }
        #expect(lead.workflow.floor == nil && lead.workflow.riskLinesInForce == 0 && !lead.workflow.riskModelInForce)
        // configure() says none is recorded; status, kept short, has no floor line.
        #expect(lead.call("configure", [:]).text.contains("none recorded yet"))
        #expect(!lead.call("status", [:]).text.contains("Review rules' floor"))
    }

    /// A floor that holds nothing above workflow.md: status has no floor line at all.
    @Test func aFloorEqualToTheFileAddsNoStatusLine() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try freshLead(root, runtime)
        try vault.setReviewFloor(LeadReviewFloor.starting(from: lead.workflow, workerModel: runtime.workerModel(root: root)), root: root)
        #expect(lead.call("configure", [:]).text.contains("Review rules' floor, set by the user"))
        #expect(!lead.call("status", [:]).text.contains("Review rules' floor"))
    }
}

/// A switch a test flips while another closure reads it.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var on: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// A test's own monotonic clock (seconds) for the floor's freshness.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    // Before any system uptime: a read the toolset made on the system clock is stale on this one.
    private var value: TimeInterval = 0
    var now: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Counts what another closure saw.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add() { lock.lock(); count += 1; lock.unlock() }
}
