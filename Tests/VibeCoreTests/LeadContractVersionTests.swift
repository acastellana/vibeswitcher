import Foundation
import Testing
@testable import VibeCore

/// Versioned contracts (backlog A6): each update_task that changes a task's contract adds a version; an audit at work
/// is sent what changed, through the channel the lead's messages take; its verdict records the version it judged, and
/// one on an older version than the task has says so to the lead, in status and in board(task).
struct LeadContractVersionTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("contracts")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// A lead whose task "add-b" (review audit) was worked on and reported done; `finders` per audit.
    func reported(finders: Int = 1, policy: String = "ask_all", test: String = "test -f b.txt") throws -> (root: String, runtime: FakeRuntime, lead: LeadToolset) {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": policy, "test_command": test, "audit_finders": finders]).isError)
        #expect(!lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "review": "audit"]).isError)
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b"], in: worktree)
        let report = try seat("worker-add-b", runtime).call("report", doneReport("added b"))
        #expect(!report.isError, "\(report.text)")
        return (root, runtime, lead)
    }

    func task(_ root: String) throws -> LeadTask { try #require(BoardStore(root: root).load().task("add-b")) }

    /// What the lead was told (its verdict messages), newest last.
    func toldLead(_ runtime: FakeRuntime) -> [String] {
        runtime.steered.filter { $0.target == "agent:\(runtime.me.pid)" }.map(\.text)
    }

    static let clean: [String: Any] = ["task": "add-b", "completion": "complete", "integrity": "clean", "summary": "checked"]

    // MARK: The version

    @Test func updateTaskBumpsTheVersionAndBoardShowsIt() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        #expect(!lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]]).isError)
        #expect(lead.call("board", ["task": "add-b"]).text.contains("Contract: v1"))

        let goal = lead.call("update_task", ["task": "add-b", "goal": "b.txt exists and says b"])
        #expect(goal.text.contains("contract now v2"), "\(goal.text)")
        let shown = lead.call("board", ["task": "add-b"]).text
        #expect(shown.contains("Contract: v2") && shown.contains("\"contractVersion\" : 2"), "\(shown)")

        #expect(lead.call("update_task", ["task": "add-b", "append_context": "Mind the newline."]).text.contains("contract now v3"))
        #expect(lead.call("update_task", ["task": "add-b", "boundaries": ["b.txt only"]]).text.contains("contract now v4"))
        // Not the contract: the title, the state, the same text given again.
        for unchanged: [String: Any] in [["title": "Add bee"], ["status": "blocked"], ["goal": "b.txt exists and says b"]] {
            let result = lead.call("update_task", ["task": "add-b"].merging(unchanged) { $1 })
            #expect(!result.isError && !result.text.contains("contract now"), "\(unchanged): \(result.text)")
        }
        #expect(try task(root).contractRevision == 4)
    }

    @Test func changesNameWhatChangedSectionBySection() {
        let old = LeadContract(goal: "g", acceptance: ["a", "b"], boundaries: ["x"], context: "Some context.")
        #expect(old.changes(from: old).isEmpty)
        var new = old
        new.goal = "g2"
        new.acceptance = ["a", "c"]
        new.context = "Some context.\n\nEditing scripts/x.sh is accepted."
        let text = new.changes(from: old)
        #expect(text.contains("## Goal (replaced)\ng2"), "\(text)")
        #expect(text.contains("Added: c") && text.contains("Dropped: b"), "\(text)")
        #expect(text.contains("## Context (added to)\nEditing scripts/x.sh is accepted."), "\(text)")
        #expect(!text.contains("Boundaries"), "\(text)")
        new.context = "Other."
        #expect(new.changes(from: old).contains("## Context (replaced)\nOther."))
    }

    // MARK: A verifier at work hears of it

    @Test func anUpdateDuringAnAuditIsSentToItsVerifier() throws {
        let (root, runtime, lead) = try reported()
        let started = lead.call("audit", ["task": "add-b"])
        #expect(!started.isError, "\(started.text)")
        let verifier = try #require(try task(root).verifier)
        #expect(try task(root).auditBrief?.version == 1)
        let spawn = try #require(runtime.spawned.last { $0.id == verifier })
        let range = try #require(spawn.command.range(of: #"--append-system-prompt-file '([^']+)'"#, options: .regularExpression))
        let prompt = try String(contentsOfFile: String(spawn.command[range].dropFirst("--append-system-prompt-file '".count).dropLast()), encoding: .utf8)
        #expect(prompt.contains("This is contract v1.") && prompt.contains("contract_version"), "\(prompt)")

        let updated = lead.call("update_task", ["task": "add-b", "append_context": "Editing scripts/x.sh is accepted (sensitive path)."])
        #expect(updated.text.contains("contract now v2") && updated.text.contains("was sent what changed (contract v1 to v2)"), "\(updated.text)")
        let sent = runtime.steered.filter { $0.target == verifier }
        #expect(sent.count == 1)
        let text = try #require(sent.first?.text)
        #expect(text.contains("it's now contract v2 (you had v1)") && text.contains("Editing scripts/x.sh is accepted (sensitive path).")
                && text.contains("contract_version: 2"), "\(text)")
        if case .lead(let name)? = sent.first?.sender { #expect(name.hasPrefix("lead of ")) } else { Issue.record("not sent as the lead's: \(String(describing: sent.first?.sender))") }
        #expect(try task(root).auditBrief?.version == 2)
        // Sent once: a call that doesn't change the contract sends nothing more.
        _ = lead.call("update_task", ["task": "add-b", "title": "Add bee"])
        #expect(runtime.steered.filter { $0.target == verifier }.count == 1)

        let submitted = try seat("verify-add-b", runtime).call("submit_audit", Self.clean.merging(["contract_version": 2]) { $1 })
        #expect(!submitted.isError, "\(submitted.text)")
        #expect(try task(root).evidence?.contract == 2)
        #expect(try task(root).staleContract == nil)
        #expect(toldLead(runtime).last?.contains("judged contract") == false)
    }

    // MARK: A verdict on an older version says so

    @Test func aVerdictOnAnOlderVersionSaysSoInTheReportStatusAndBoard() throws {
        let (root, runtime, lead) = try reported()
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        let verifier = try #require(try task(root).verifier)
        // The verifier can't be reached: its brief keeps v1.
        runtime.onSteer = { target, _, _ in
            if case .session(let id) = target, id == verifier { throw BoardError(text: "no such tty") }
            return .steered
        }
        let updated = lead.call("update_task", ["task": "add-b", "acceptance": ["test -f b.txt", "grep -q b b.txt"]])
        #expect(updated.text.contains("couldn't all be sent the change") && updated.text.contains("judged contract v1, not v2"), "\(updated.text)")
        #expect(try task(root).auditBrief?.version == 1)

        // It says v2, having seen none of it: never past what it was sent.
        let submitted = try seat("verify-add-b", runtime).call("submit_audit", Self.clean.merging(["contract_version": 2]) { $1 })
        #expect(!submitted.isError, "\(submitted.text)")
        #expect(try task(root).evidence?.contract == 1)
        #expect(try task(root).staleContract == "judged contract v1, current v2")
        let report = try #require(toldLead(runtime).last)
        #expect(report.contains("This verdict judged contract v1, current v2"), "\(report)")
        let status = lead.call("status", [:]).text
        #expect(status.contains("audit clean (judged contract v1, current v2)"), "\(status)")
        let board = lead.call("board", ["task": "add-b"]).text
        #expect(board.contains("Contract: v2 (its verdict judged contract v1, current v2)"), "\(board)")
    }

    @Test func aVerifierThatSaysItJudgedTheOlderVersionIsRecordedSo() throws {
        let (root, runtime, lead) = try reported()
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        #expect(lead.call("update_task", ["task": "add-b", "goal": "b.txt says b"]).text.contains("was sent what changed"))
        // Sent, but it submitted before its next step took it in.
        let refused = try seat("verify-add-b", runtime).call("submit_audit", Self.clean.merging(["contract_version": "two"]) { $1 })
        #expect(refused.isError && refused.text.contains("contract_version is the version"), "\(refused.text)")
        #expect(!(try seat("verify-add-b", runtime)).call("submit_audit", Self.clean.merging(["contract_version": 1]) { $1 }).isError)
        #expect(try task(root).evidence?.contract == 1)
        #expect(try task(root).staleContract == "judged contract v1, current v2")
    }

    /// Sent, but it submitted without saying what it judged: its brief's version, not the one sent (an amendment
    /// reaches it at its next step, which may come after its verdict).
    @Test func aVerifierThatDoesntSayWhatItJudgedIsTakenToHaveJudgedItsBrief() throws {
        let (root, runtime, lead) = try reported()
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        #expect(lead.call("update_task", ["task": "add-b", "acceptance": ["test -f b.txt", "grep -q b b.txt"]]).text.contains("was sent what changed"))
        #expect(try task(root).auditBrief?.version == 2)
        #expect(!(try seat("verify-add-b", runtime)).call("submit_audit", Self.clean).isError)
        #expect(try task(root).evidence?.contract == 1)
        #expect(toldLead(runtime).last?.contains("This verdict judged contract v1, current v2") == true)
    }

    @Test func anUpdateBeforeTheVerifierIsUpIsSentOnceItIs() throws {
        let (root, runtime, lead) = try reported()
        // The lead amends the contract while audit starts the verifier: between its board read and the verifier's start.
        runtime.onSpawn = { _ in
            try? BoardStore(root: root).update { board in
                guard let index = board.taskIndex("add-b"), board.tasks[index].contractVersion == nil else { return }
                board.tasks[index].contract.context = "Late note: x.sh accepted."
                board.tasks[index].contractVersion = 2
            }
        }
        let started = lead.call("audit", ["task": "add-b"])
        #expect(started.text.contains("was sent what changed (contract v1 to v2)"), "\(started.text)")
        let verifier = try #require(try task(root).verifier)
        #expect(runtime.steered.first { $0.target == verifier }?.text.contains("Late note: x.sh accepted.") == true)
        #expect(try task(root).auditBrief?.version == 2)
    }

    @Test func aFinderThatSubmittedBeforeTheAmendmentMakesTheVerdictJudgeTheOlderVersion() throws {
        let (root, runtime, lead) = try reported(finders: 2)
        let started = lead.call("audit", ["task": "add-b"])
        #expect(!started.isError, "\(started.text)")
        let finders = try #require(try task(root).panel?.sessions)
        #expect(finders.count == 2)
        #expect(!(try seat("finder2-add-b", runtime)).call("submit_audit", Self.clean).isError)
        // Only the finder still at work hears of it.
        let updated = lead.call("update_task", ["task": "add-b", "append_context": "x.sh accepted."])
        #expect(updated.text.contains("was sent what changed (contract v1 to v2)"), "\(updated.text)")
        #expect(runtime.steered.filter { $0.target == finders[0] }.count == 1)
        #expect(runtime.steered.filter { $0.target == finders[1] }.isEmpty)
        #expect(!(try seat("verify-add-b", runtime)).call("submit_audit", Self.clean.merging(["contract_version": 2]) { $1 }).isError)
        #expect(try task(root).evidence?.contract == 1)
        #expect(toldLead(runtime).last?.contains("This verdict judged contract v1, current v2") == true)
    }

    // MARK: A verdict on an older version doesn't merge by itself

    /// A clean verdict on v1, and the lead changed the acceptance since: merge refuses it, naming both versions; with
    /// the lead's stated reason it merges, and the reason goes into the progress log.
    @Test func mergeRefusesAVerdictOnAnOlderVersionUnlessTheLeadAcceptsItWithAReason() throws {
        let (root, runtime, lead) = try reported(policy: "auto")
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        #expect(!(try seat("verify-add-b", runtime)).call("submit_audit", Self.clean.merging(["tests": "passed"]) { $1 }).isError)
        #expect(lead.call("update_task", ["task": "add-b", "acceptance": ["test -f b.txt", "test -s b.txt"]]).text.contains("contract now v2"))

        let refused = lead.call("merge", ["task": "add-b"])
        #expect(refused.isError && refused.text.contains("judged contract v1, and its contract is now v2")
                && refused.text.contains("audit(add-b) again") && refused.text.contains("accept_stale_verdict"), "\(refused.text)")
        #expect(!Git.run(["show", "main:b.txt"], in: root).ok)
        // A blank reason is no reason.
        #expect(lead.call("merge", ["task": "add-b", "accept_stale_verdict": "  "]).isError)

        let reason = "v2 only adds test -s b.txt, which v1's run of test -f b.txt on a one-line file covers"
        let merged = lead.call("merge", ["task": "add-b", "accept_stale_verdict": reason])
        #expect(!merged.isError, "\(merged.text)")
        #expect(Git.run(["show", "main:b.txt"], in: root).output == "bee")
        let progress = try String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)
        #expect(progress.contains("on a verdict that judged contract v1, and its contract is now v2, accepted by the lead: \(reason)"), "\(progress)")
    }

    /// The verdict judged the contract as it was when the merge began, and the lead amends it while the tests run: the
    /// tests pass, and it still doesn't land on that verdict. The lead's stated reason merges it then, as before.
    @Test func aContractAmendedWhileTheMergesTestsRunDoesntLandOnTheOldVerdict() async throws {
        let running = temp.url("tests-running").path, amended = temp.url("amended").path
        let test = "touch '\(running)'; for _ in $(seq 1 6000); do [ -e '\(amended)' ] && exit 0; sleep 0.05; done; exit 1"
        let (root, runtime, lead) = try reported(policy: "auto", test: test)
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        #expect(!(try seat("verify-add-b", runtime)).call("submit_audit", Self.clean.merging(["tests": "passed"]) { $1 }).isError)

        async let merge = offPool { lead.call("merge", ["task": "add-b"]) }
        #expect(await eventually { FileManager.default.fileExists(atPath: running) })
        #expect(lead.call("update_task", ["task": "add-b", "acceptance": ["test -f b.txt", "test -s b.txt"]]).text.contains("contract now v2"))
        FileManager.default.createFile(atPath: amended, contents: nil)
        let refused = await merge

        #expect(refused.isError && refused.text.contains("amended while its tests ran (they passed)")
                && refused.text.contains("judged contract v1, and its contract is now v2")
                && refused.text.contains("audit(add-b) again") && refused.text.contains("accept_stale_verdict"), "\(refused.text)")
        #expect(!Git.run(["show", "main:b.txt"], in: root).ok)
        #expect(try task(root).status == .review)
        let progress = try String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)
        #expect(progress.contains("Didn't merge add-b: its contract was amended while its tests ran"), "\(progress)")

        let accepted = lead.call("merge", ["task": "add-b", "accept_stale_verdict": "v2 adds only test -s, and b.txt says bee"])
        #expect(!accepted.isError, "\(accepted.text)")
        #expect(Git.run(["show", "main:b.txt"], in: root).output == "bee")
    }

    /// The verdict's report says merge refuses it as it is, not "merge when you're ready".
    @Test func theVerdictsReportOnAnOlderVersionSaysMergeRefusesIt() throws {
        let (_, runtime, lead) = try reported()
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        let verifier = try #require(BoardStore(root: lead.root).load().task("add-b")?.verifier)
        runtime.onSteer = { target, _, _ in
            if case .session(let id) = target, id == verifier { throw BoardError(text: "no such tty") }
            return .steered
        }
        _ = lead.call("update_task", ["task": "add-b", "goal": "b.txt exists and says bee"])
        #expect(!(try seat("verify-add-b", runtime)).call("submit_audit", Self.clean).isError)
        let report = try #require(toldLead(runtime).last)
        #expect(report.contains("so merge refuses it as it is") && report.contains("accept_stale_verdict") && !report.contains("merge(add-b) when you're ready"), "\(report)")
    }

    // MARK: Every change to the contract is a version

    /// A reroll appends what the rounds learned to the context: a new version.
    @Test func aRerollBumpsTheVersion() throws {
        let (root, _, lead) = try reported()
        let rerolled = lead.call("update_task", ["task": "add-b", "reroll": true])
        #expect(!rerolled.isError, "\(rerolled.text)")
        let task = try task(root)
        #expect(task.contract.context.contains("## Re-roll 1: what the earlier attempt's audits learned"), "\(task.contract.context)")
        #expect(task.contractRevision == 2, "\(String(describing: task.contractVersion))")
    }

    /// A flaky test noted in an open task's context is a new version of its contract, and an audit at work on it is
    /// sent what changed.
    @Test func aFlakeNoteInAnOpenTasksContextBumpsTheVersionAndReachesItsAudit() throws {
        let (root, runtime, lead) = try reported()
        let test = "ContractFlakeSuite.flakyThing()"
        #expect(lead.call("update_task", ["task": "add-b", "goal": "b.txt exists; \(test) stops flaking"]).text.contains("contract now v2"))
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        let verifier = try #require(try task(root).verifier)
        #expect(try task(root).auditBrief?.version == 2)
        var noted: LeadToolset.FlakePlan?
        for n in 1...LeadBoard.flakeLimit {
            noted = try lead.store.update { board in
                lead.planFlakeFixes(&board, flakes: [test], slug: "other-\(n)", commit: String(repeating: "\(n)", count: 40), at: Date(),
                                    logged: [], log: nil, workflow: lead.workflow)
            }
        }
        #expect(noted?.planned.first.map { $0.slug == "add-b" && $0.noted } == true, "\(String(describing: noted?.planned))")
        #expect(try task(root).contractRevision == 3)
        // What the merge does once the board is written.
        lead.sendFlakeNotes(try #require(noted))
        let sent = try #require(runtime.steered.last { $0.target == verifier }?.text)
        #expect(sent.contains("it's now contract v3 (you had v2)") && sent.contains(test), "\(sent)")
    }

    /// The worker's report on a commit with a standing verdict rebuilds the board's copy of it: with the version it
    /// judged, so the merge gate still sees a verdict on an older version.
    @Test func aReportThatRebuildsTheVerdictKeepsTheVersionItJudged() throws {
        let (root, runtime, lead) = try reported(policy: "auto")
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        #expect(!(try seat("verify-add-b", runtime)).call("submit_audit", Self.clean.merging(["tests": "passed"]) { $1 }).isError)
        #expect(lead.call("update_task", ["task": "add-b", "append_context": "b.txt may end in a newline."]).text.contains("contract now v2"))
        // The board's copy gone (an older build wrote the board), the vault's verdict on the head stands.
        try BoardStore(root: root).update { board in board.tasks[board.taskIndex("add-b")!].evidence = nil }
        let report = try seat("worker-add-b", runtime).call("report", doneReport("added b, again"))
        #expect(!report.isError, "\(report.text)")
        #expect(try task(root).evidence?.contract == 1)
        let refused = lead.call("merge", ["task": "add-b"])
        #expect(refused.isError && refused.text.contains("judged contract v1, and its contract is now v2"), "\(refused.text)")
    }

    /// Between the vault's verdict and the board's copy of it (submit_audit writes the board after the vault), the
    /// gate goes by the version the audit's brief says was judged: a stale verdict doesn't slip through that window.
    @Test func beforeTheBoardHasTheVerdictTheGateGoesByTheVersionTheBriefSaysWasJudged() throws {
        let (root, runtime, lead) = try reported(policy: "auto")
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        #expect(!(try seat("verify-add-b", runtime)).call("submit_audit", Self.clean.merging(["tests": "passed"]) { $1 }).isError)
        #expect(lead.call("update_task", ["task": "add-b", "acceptance": ["test -f b.txt", "test -s b.txt"]]).text.contains("contract now v2"))
        // The window: the vault has the verdict, the board's copy isn't written yet.
        try BoardStore(root: root).update { board in board.tasks[board.taskIndex("add-b")!].evidence = nil }
        #expect(try task(root).auditBrief?.judged == 1)
        let refused = lead.call("merge", ["task": "add-b"])
        #expect(refused.isError && refused.text.contains("judged contract v1, and its contract is now v2"), "\(refused.text)")
        #expect(!Git.run(["show", "main:b.txt"], in: root).ok)
    }

    /// A verdict that didn't pass judged nothing to narrow a re-audit to: after the contract changes, the next audit
    /// checks the whole branch as ever, not only what changed.
    @Test func aFailedVerdictOnAnOlderVersionIsReauditedWhole() throws {
        let (root, runtime, lead) = try reported()
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        let blocked = try seat("verify-add-b", runtime).call("submit_audit", ["task": "add-b", "completion": "blocked", "integrity": "clean", "summary": "couldn't run the check"])
        #expect(!blocked.isError, "\(blocked.text)")
        #expect(lead.call("update_task", ["task": "add-b", "acceptance": ["test -s b.txt"]]).text.contains("contract now v2"))
        let started = lead.call("audit", ["task": "add-b"])
        #expect(!started.isError && !started.text.contains("judges only what changed"), "\(started.text)")
        let verifier = try #require(try task(root).verifier)
        let spawn = try #require(runtime.spawned.last { $0.id == verifier })
        let range = try #require(spawn.command.range(of: #"--append-system-prompt-file '([^']+)'"#, options: .regularExpression))
        let prompt = try String(contentsOfFile: String(spawn.command[range].dropFirst("--append-system-prompt-file '".count).dropLast()), encoding: .utf8)
        #expect(!prompt.contains("## What this audit judges") && prompt.contains("This is contract v2."), "\(prompt)")
    }
}
