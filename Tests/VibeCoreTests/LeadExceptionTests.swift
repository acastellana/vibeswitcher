import Foundation
import Testing
@testable import VibeCore

/// Audit exceptions (update_task's exception, accept_verdict and hold_audit): a deviation the lead accepts is a sealed,
/// structured note the verifier reads before it starts, and a verdict held up only by one goes to the lead. Everything
/// here goes through the tools, as a lead, worker and verifier do. See `LeadException`.
struct LeadExceptionTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("exception")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    static let scoped: [String: Any] = ["scope": ["a.txt"], "reason": "one line of wiring the goal needs", "evidence": "a.txt:1 is the only change there"]

    /// The task "fix": b.txt is its job, a.txt an edit outside its boundaries. Reported done, with `settings` configured.
    func reported(_ root: String, _ runtime: FakeRuntime, settings: [String: Any] = [:], addTask: [String: Any] = [:]) throws -> LeadToolset {
        let lead = try lead(root, runtime)
        var all: [String: Any] = ["merge_policy": "auto", "test_command": "true"]
        all.merge(settings) { $1 }
        let configured = lead.call("configure", all)
        #expect(!configured.isError, "\(configured.text)")
        var task: [String: Any] = ["title": "Fix", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "boundaries": ["only b.txt"]]
        task.merge(addTask) { $1 }
        #expect(!lead.call("add_task", task).isError)
        #expect(!lead.call("start_worker", ["task": "fix"]).isError)
        let worktree = Worktrees.path(root: root, slug: "fix")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        try "wired\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt", "a.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b, wire a"], in: worktree)
        #expect(!(try seat("worker-fix", runtime)).call("report", doneReport("added b.txt")).isError)
        return lead
    }

    func task(_ root: String) -> LeadTask? { BoardStore(root: root).load().task("fix") }

    func prompt(_ root: String, _ runtime: FakeRuntime) throws -> String {
        try LaunchArguments.prompt(of: "verify-fix", runtime)
    }

    func notes(_ prompt: String) throws -> Substring {
        let start = try #require(prompt.range(of: LeadPrompts.notesHeading))
        return prompt[start.lowerBound...]
    }

    /// The audit's verdict, as its verifier gives it.
    func verdict(_ lead: LeadToolset, _ runtime: FakeRuntime, integrity: String = "suspect", completion: String = "complete", tests: String = "passed",
                 outside: [String]? = ["a.txt"], findings: [[String: Any]] = []) throws {
        let audited = lead.call("audit", ["task": "fix"])
        #expect(!audited.isError, "\(audited.text)")
        var arguments: [String: Any] = ["completion": completion, "integrity": integrity, "summary": "a.txt was edited, outside the boundaries", "tests": tests, "findings": findings]
        if let outside { arguments["outside_boundaries"] = outside }
        let submitted = try seat("verify-fix", runtime).call("submit_audit", arguments)
        #expect(!submitted.isError, "\(submitted.text)")
    }

    func accept(_ lead: LeadToolset, scope: Any = ["a.txt"]) -> MCPToolResult {
        lead.call("update_task", ["task": "fix", "exception": ["scope": scope, "reason": "one line of wiring", "evidence": "a.txt:1"], "accept_verdict": true])
    }

    // MARK: Recording

    @Test(arguments: [("scope", "scope"), ("reason", "reason"), ("evidence", "evidence")])
    func anExceptionMissingAPartIsRefusedSayingWhich(key: String, named: String) throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        var given = Self.scoped
        given[key] = nil
        let refused = lead.call("update_task", ["task": "fix", "exception": given])
        #expect(refused.isError && refused.text.contains("missing its") && refused.text.contains(named), "\(refused.text)")
        var empty = Self.scoped
        empty[key] = key == "scope" ? [] as [String] : "  "
        #expect(lead.call("update_task", ["task": "fix", "exception": empty]).text.contains(named))
        #expect(task(root)?.notes == nil, "nothing was recorded")
    }

    @Test(arguments: ["**", "*", "**/*", "/etc/passwd", "../outside", "~/x", "a\nb"])
    func aScopeThatIsntOneIsRefused(scope: String) throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        var given = Self.scoped
        given["scope"] = scope
        #expect(lead.call("update_task", ["task": "fix", "exception": given]).isError)
        #expect(task(root)?.notes == nil)
    }

    @Test func anUnreadableExceptionIsRefused() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        #expect(lead.call("update_task", ["task": "fix", "exception": "not json"]).isError)
        #expect(lead.call("update_task", ["task": "fix", "exception": ["scope": 7, "reason": "r", "evidence": "e"]]).isError)
        var extra = Self.scoped
        extra["waive"] = true
        let unknown = lead.call("update_task", ["task": "fix", "exception": extra])
        #expect(unknown.isError && unknown.text.contains("waive"))
        #expect(lead.call("update_task", ["task": "fix", "accept_verdict": true]).isError)
        #expect(lead.call("update_task", ["task": "fix", "exception": Self.scoped, "accept_verdict": "maybe"]).isError)
        #expect(task(root)?.notes == nil)
    }

    /// Recorded before the audit starts: the verifier reads it in the lead's notes, and the contract (so its version,
    /// so any verdict's standing) doesn't move.
    @Test func theVerifierSeesAnExceptionRecordedBeforeItsAudit() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        let version = try #require(task(root)?.contractRevision)
        let recorded = lead.call("update_task", ["task": "fix", "exception": Self.scoped])
        #expect(!recorded.isError && recorded.text.contains("Its next audit's verifier sees it"), "\(recorded.text)")
        #expect(task(root)?.contractRevision == version)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let section = try notes(try prompt(root, runtime))
        #expect(section.contains("appended to the task: Exception to the boundaries, accepted by the lead. It accepts edits to a.txt and nothing else."), "\(section)")
        #expect(section.contains("Reason: one line of wiring the goal needs") && section.contains("Evidence: a.txt:1 is the only change there"))
    }

    /// The tool says so: a verifier already at work wasn't given it, and only the next audit is.
    @Test func anExceptionAfterTheAuditStartedIsNotPresentedAsCoveringIt() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let late = lead.call("update_task", ["task": "fix", "exception": Self.scoped])
        #expect(!late.isError && late.text.contains("isn't presented as covering the audit of fix"), "\(late.text)")
        #expect(!(try notes(try prompt(root, runtime))).contains("Exception to the boundaries"))
        // A verdict that doesn't pass comes back; the next audit has it.
        _ = try seat("verify-fix", runtime).call("submit_audit", ["completion": "complete", "integrity": "suspect", "summary": "s", "tests": "passed"])
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        #expect((try notes(try prompt(root, runtime))).contains("Exception to the boundaries"))
    }

    // MARK: Holding

    @Test func aHeldAuditWaitsForTheException() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        #expect(!lead.call("update_task", ["task": "fix", "hold_audit": true]).isError)
        let held = lead.call("audit", ["task": "fix"])
        #expect(held.isError && held.text.contains("held"), "\(held.text)")
        #expect(!runtime.spawned.contains { $0.label.hasPrefix("Verifier: ") })
        #expect(lead.call("board", ["task": "fix"]).text.contains("Audit held by the lead"))
        #expect(!lead.call("update_task", ["task": "fix", "exception": Self.scoped]).isError)
        #expect(!lead.call("board", ["task": "fix"]).text.contains("Audit held by the lead"))
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        #expect((try notes(try prompt(root, runtime))).contains("Exception to the boundaries"))
    }

    @Test func holdAuditFalseLetsGo() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        #expect(!lead.call("update_task", ["task": "fix", "hold_audit": true]).isError)
        #expect(!lead.call("update_task", ["task": "fix", "hold_audit": false]).isError)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
    }

    /// A hold set once the audit is under way doesn't pretend to hold it.
    @Test func aHoldAfterTheAuditStartedSaysSo() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let late = lead.call("update_task", ["task": "fix", "hold_audit": true])
        #expect(!late.isError && late.text.contains("had started already"), "\(late.text)")
    }

    // MARK: A verdict only an exception holds up

    /// Suspect, no Important finding, only a.txt outside the boundaries: the lead settles it, and it merges with no
    /// new audit; the record shows the verdict and who accepted what.
    @Test func aSuspectVerdictOnlyForFilesOutsideTheBoundariesIsTheLeadsToAccept() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        try verdict(lead, runtime)
        #expect(task(root)?.status == .failed)
        let told = BoardStore(root: root).load().reports?.last?.text ?? ""
        #expect(told.contains("only concern is an edit outside the boundaries (a.txt)") && told.contains("accept_verdict: true"), "\(told)")
        #expect(lead.call("merge", ["task": "fix"]).isError, "not until it's accepted")
        let spawned = runtime.spawned.count
        let accepted = accept(lead)
        #expect(!accepted.isError && accepted.text.contains("verdict settled"), "\(accepted.text)")
        #expect(task(root)?.status == .review && task(root)?.setback == nil)
        let board = lead.call("board", ["task": "fix"]).text
        #expect(board.contains("Exceptions (oldest first)") && board.contains("by lead of ") && board.contains("It settles the suspect verdict at") && board.contains("whose only concern was the edit to a.txt"), "\(board)")
        let merged = lead.call("merge", ["task": "fix"])
        #expect(!merged.isError && merged.text.contains("accepted as an exception"), "\(merged.text)")
        #expect(task(root)?.status == .done && runtime.spawned.count == spawned, "no new audit")
        let progress = (try? String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)) ?? ""
        #expect(progress.contains("accepted the suspect verdict on fix") && progress.contains("lead of"), "\(progress)")
        #expect(progress.contains("suspect audit accepted by the lead as an exception for a.txt"), "\(progress)")
        #expect(Git.run(["log", "-5", "--format=%B", "main"], in: root).output.contains("suspect, accepted by the lead as an exception"))
    }

    /// The other way out: back to the worker, by the lead's message, as any failed audit goes.
    @Test func theLeadCanSendItBackInstead() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        try verdict(lead, runtime)
        #expect(!lead.call("message", ["task": "fix", "text": "take the a.txt edit out"]).isError)
        #expect(task(root)?.status == .running)
    }

    // MARK: Behaves as today

    /// Each is refused, and merge stays refused: the verifier's other concerns aren't the lead's to wave through here.
    @Test(arguments: [
        ("no list", nil as [String]?, "suspect", "complete", "passed"),
        ("a file the branch didn't change", ["c.txt"], "suspect", "complete", "passed"),
        ("a violation", ["a.txt"], "violation", "complete", "passed"),
        ("incomplete", ["a.txt"], "suspect", "incomplete", "passed"),
        ("tests failed", ["a.txt"], "suspect", "complete", "failed"),
        ("tests not run", ["a.txt"], "suspect", "complete", "not_run"),
    ])
    func anyOtherVerdictIsntAccepted(_ why: String, outside: [String]?, integrity: String, completion: String, tests: String) throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        try verdict(lead, runtime, integrity: integrity, completion: completion, tests: tests, outside: outside)
        let refused = accept(lead)
        #expect(refused.isError && refused.text.contains("Not accepted"), "\(why): \(refused.text)")
        #expect(task(root)?.status == .failed, "\(why)")
        #expect(task(root)?.notes == nil, "\(why): nothing recorded")
        #expect(lead.call("merge", ["task": "fix"]).isError, "\(why)")
        let told = BoardStore(root: root).load().reports?.last?.text ?? ""
        #expect(!told.contains("only concern is an edit outside the boundaries"), "\(why): \(told)")
    }

    @Test func anOpenImportantFindingIsntAccepted() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        try verdict(lead, runtime, findings: [["severity": "Important", "file": "b.txt", "line": 1, "evidence": "says bee",
                                               "failure_scenario": "cat b.txt gives bee, the contract wants b", "status": "open"]])
        let refused = accept(lead)
        #expect(refused.isError && refused.text.contains("Not accepted"), "\(refused.text)")
        #expect(lead.call("merge", ["task": "fix"]).isError)
    }

    @Test func outsideBoundariesOnACleanVerdictIsRefused() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let verifier = try seat("verify-fix", runtime)
        #expect(verifier.call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "s", "outside_boundaries": ["a.txt"]]).isError)
    }

    // MARK: How it could pass while wrong

    /// A wider scope doesn't cover anything beyond the files in question.
    @Test func aScopeWiderThanTheFilesCoversOnlyThem() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        try verdict(lead, runtime)
        #expect(!accept(lead, scope: "*.txt").isError)
        let note = try #require(task(root)?.notes?.last)
        #expect(note.text.contains("It accepts edits to a.txt and nothing else.") && !note.text.contains("*.txt"), "\(note.text)")
        // A file past those it named is a new commit: the acceptance is the old verdict's, and merge refuses it.
        let worktree = Worktrees.path(root: root, slug: "fix")
        try "more\n".write(toFile: worktree + "/c.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "c.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "and c"], in: worktree)
        #expect(lead.call("merge", ["task": "fix"]).isError)
        // Nor does the next audit's verifier read it as accepting more than a.txt.
        #expect(!(try seat("worker-fix", runtime)).call("report", doneReport("added c.txt")).isError)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let section = try notes(try prompt(root, runtime))
        #expect(section.contains("It accepts edits to a.txt and nothing else.") && !section.contains("*.txt"), "\(section)")
    }

    @Test func aScopeThatMissesAFileIsRefusedNamingIt() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        try verdict(lead, runtime, outside: ["a.txt", "b.txt"])
        let refused = accept(lead)
        #expect(refused.isError && refused.text.contains("doesn't cover b.txt"), "\(refused.text)")
        #expect(task(root)?.notes == nil)
    }

    /// Shown to the verifier, and not a way past the audit: its review floor stands and accepting the verdict is refused.
    @Test func anExceptionOnASensitivePathDoesntSkipTheAudit() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime, settings: ["sensitive_paths": "a.txt"], addTask: ["review": "none"])
        #expect(!lead.call("update_task", ["task": "fix", "exception": Self.scoped]).isError)
        let head = Git.run(["rev-parse", "agent/fix"], in: root).output
        #expect(lead.advanceReviewNeeded("fix", commit: head) != nil, "the exception doesn't lower the floor")
        try verdict(lead, runtime)
        #expect((try notes(try prompt(root, runtime))).contains("Exception to the boundaries"))
        let told = BoardStore(root: root).load().reports?.last?.text ?? ""
        #expect(told.contains("is on a sensitive path"), "\(told)")
        let refused = accept(lead)
        #expect(refused.isError && refused.text.contains("sensitive path"), "\(refused.text)")
        #expect(task(root)?.status == .failed && lead.call("merge", ["task": "fix"]).isError)
    }

    @Test func aWorkerOrVerifierCantRecordOne() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        let worker = try seat("worker-fix", runtime)
        #expect(worker.call("update_task", ["task": "fix", "exception": Self.scoped]).isError)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let verifier = try seat("verify-fix", runtime)
        #expect(verifier.call("update_task", ["task": "fix", "exception": Self.scoped]).isError)
        #expect(task(root)?.notes == nil)
    }

    /// The board is a file a worker's Bash can write: an exception it puts there, or bolts onto a note the lead did seal,
    /// settles nothing.
    @Test func anExceptionOnTheBoardThatIsntTheLeadsSettlesNothing() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        #expect(!lead.call("update_task", ["task": "fix", "append_context": "Looks fine."]).isError)
        try verdict(lead, runtime)
        let verdict = try #require(vault.verdict(root: root, task: "fix"))
        let settles: [String: Any] = ["commit": verdict.commit, "verifier": verdict.verifier, "integrity": "suspect", "summary": "s", "files": ["a.txt"]]
        let exception: [String: Any] = ["scope": ["a.txt"], "reason": "r", "evidence": "e", "settles": settles]
        try BoardStore(root: root).update { board in
            let index = try #require(board.taskIndex("fix"))
            let sealed = try #require(board.tasks[index].notes?.first)
            // The lead's seal, on words that aren't this exception's.
            var bolted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sealed)) as? [String: Any] ?? [:]
            bolted["exception"] = exception
            board.tasks[index].keep(try JSONDecoder().decode(LeadNote.self, from: JSONSerialization.data(withJSONObject: bolted)))
            // Forged whole: its own text, no seal.
            let forged: [String: Any] = ["id": UUID().uuidString, "kind": "context", "text": "Exception", "by": "lead of x", "at": 1.0, "exception": exception]
            board.tasks[index].keep(try JSONDecoder().decode(LeadNote.self, from: JSONSerialization.data(withJSONObject: forged)))
            board.tasks[index].status = .review
            board.tasks[index].setback = nil
        }
        #expect(lead.call("merge", ["task": "fix"]).isError)
        #expect(task(root)?.status != .done)
    }

    /// One acceptance is for one verdict: a later audit of the same commit is a verdict it says nothing about.
    @Test func anAcceptanceIsForTheVerdictItNames() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime)
        try verdict(lead, runtime)
        #expect(!accept(lead).isError)
        try verdict(lead, runtime)
        #expect(lead.call("merge", ["task": "fix"]).isError, "the new verifier's verdict wasn't accepted")
    }

    // MARK: Finders

    func verdictOfFinders(_ lead: LeadToolset, _ runtime: FakeRuntime, _ second: (integrity: String, outside: [String]?)) throws {
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let names = ["verify-fix", "finder2-fix", "finder3-fix"]
        for (index, name) in names.enumerated() {
            let said = index == 1 ? second : (integrity: "suspect", outside: ["a.txt"] as [String]?)
            var arguments: [String: Any] = ["completion": "complete", "integrity": said.integrity, "summary": "s", "tests": "passed"]
            if let outside = said.outside { arguments["outside_boundaries"] = outside }
            #expect(!(try seat(name, runtime)).call("submit_audit", arguments).isError)
        }
    }

    @Test func aPanelSettlesOnlyWhenEveryFinderNamesOnlyTheFiles() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime, settings: ["audit_finders": 3])
        try verdictOfFinders(lead, runtime, ("clean", nil))
        #expect(!accept(lead).isError)
    }

    @Test(arguments: [("suspect", nil as [String]?), ("violation", ["a.txt"])])
    func aPanelWithAnotherConcernIsntAccepted(integrity: String, outside: [String]?) throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try reported(root, runtime, settings: ["audit_finders": 3])
        try verdictOfFinders(lead, runtime, (integrity, outside))
        #expect(accept(lead).isError)
    }
}

extension LeadAdvanceTests {
    /// 2026-11-07: chat-view-copying-text came back suspect because the lead's note landed after auto_advance had
    /// started the verifier. With the audit held, the note is in first: the verifier has it.
    @Test func aHeldAuditWaitsUnderAutoAdvanceUntilTheExceptionIsIn() async throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["a"], "review": "audit"])
        #expect(await advancing.until { task("add-b", root)?.status == .running })
        #expect(!lead.call("update_task", ["task": "add-b", "hold_audit": true]).isError)
        try work("add-b", file: "b.txt", root: root, runtime)
        #expect(await advancing.until { reports(runtime).contains { $0.contains("add-b's audit at") && $0.contains("is held") } }, "\(reports(runtime))")
        #expect(!runtime.spawned.contains { $0.label.hasPrefix("Verifier: ") })
        #expect(!lead.call("update_task", ["task": "add-b", "exception": ["scope": "a.txt", "reason": "wiring", "evidence": "a.txt:1"]]).isError)
        #expect(await advancing.until { reports(runtime).contains { $0.contains("Started the audit of add-b") } }, "\(reports(runtime))")
        let prompt = try LaunchArguments.prompt(of: "verify-add-b", runtime)
        #expect(prompt.contains("Exception to the boundaries, accepted by the lead. It accepts edits to a.txt and nothing else."))
    }

    /// A review none task has no audit to hold, and still doesn't merge past the lead's hold.
    @Test func aHeldReviewNoneTaskDoesntMergeByItself() async throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["a"], "review": "none"])
        #expect(await advancing.until { task("add-b", root)?.status == .running })
        #expect(!lead.call("update_task", ["task": "add-b", "hold_audit": true]).isError)
        try work("add-b", file: "b.txt", root: root, runtime)
        #expect(await advancing.until { reports(runtime).contains { $0.contains("add-b's audit at") && $0.contains("is held") } }, "\(reports(runtime))")
        #expect(task("add-b", root)?.status == .review)
        #expect(!lead.call("update_task", ["task": "add-b", "hold_audit": false]).isError)
        #expect(await advancing.until { task("add-b", root)?.status == .done }, "\(reports(runtime))")
    }

    /// The case that cost a round: no hold, the note lands after the verifier started. The tool says it doesn't cover
    /// that audit; the verdict goes to the lead, not back to the worker; accepting it merges with no new audit.
    @Test func aNoteAfterTheVerifierStartedDoesntCoverItAndTheVerdictIsTheLeadsToSettle() async throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["a"], "review": "audit"])
        #expect(await advancing.until { task("add-b", root)?.status == .running })
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try commit("b.txt", "bee\n", in: worktree)
        try commit("a.txt", "wired\n", in: worktree)
        #expect(!(try seat("worker-add-b", runtime)).call("report", doneReport("added b.txt")).isError)
        #expect(await advancing.until { reports(runtime).contains { $0.contains("Started the audit of add-b") } }, "\(reports(runtime))")

        let given: [String: Any] = ["scope": "a.txt", "reason": "wiring", "evidence": "a.txt:1"]
        let late = lead.call("update_task", ["task": "add-b", "exception": given])
        #expect(late.text.contains("isn't presented as covering the audit of add-b"), "\(late.text)")
        let prompt = try LaunchArguments.prompt(of: "verify-add-b", runtime)
        #expect(!prompt.contains("Exception to the boundaries"))

        let before = toWorker("add-b", root, runtime).count
        let spawned = runtime.spawned.count
        #expect(!(try seat("verify-add-b", runtime)).call("submit_audit", ["completion": "complete", "integrity": "suspect", "summary": "a.txt edited", "tests": "passed", "outside_boundaries": ["a.txt"]]).isError)
        await advancing.settle()
        #expect(task("add-b", root)?.status == .failed)
        #expect(toWorker("add-b", root, runtime).count == before, "auto_advance doesn't send it back")

        #expect(!lead.call("update_task", ["task": "add-b", "exception": given, "accept_verdict": true]).isError)
        #expect(await advancing.until { task("add-b", root)?.status == .done }, "\(reports(runtime))")
        #expect(runtime.spawned.count == spawned, "merged on the verdict the lead accepted, no new audit")
    }
}
