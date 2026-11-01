import Foundation
import Testing
@testable import VibeCore

/// Boost release (2026-11-01): a task's worker, idle since its done report, is released while its audit runs, its
/// worktree and branch kept, so its Mac slot and ~450 MB are free during review. Findings the verdict sends back start a
/// fresh worker there; a clean verdict merges with none. Fake sessions only; each wait is on the loop's own passes.
extension LeadAdvanceTests {
    func setStatus(_ session: String, _ status: String, _ runtime: FakeRuntime) {
        runtime.calls.lock()
        runtime.statuses[session] = status
        runtime.calls.unlock()
    }

    func spawnedLabels(_ runtime: FakeRuntime) -> [String] {
        runtime.calls.lock()
        defer { runtime.calls.unlock() }
        return runtime.spawned.map(\.label)
    }

    /// An audit task whose worker (idle between turns when `idle`) reported done, its audit started by the loop: the
    /// worker, the head, and the verifiers spawned by the time each session was killed.
    func releasedAudit(idle: Bool, _ root: String, _ runtime: FakeRuntime, _ advancing: Advancing, _ lead: LeadToolset)
        throws -> (worker: String, head: String, kills: () -> [String: [String]]) {
        let kills = NSLock()
        var seen: [String: [String]] = [:]
        runtime.calls.lock()
        runtime.onKill = { session, labels in
            kills.lock()
            seen[session] = labels.filter { $0.hasPrefix("Verifier:") }
            kills.unlock()
        }
        runtime.calls.unlock()
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "review": "audit"])
        #expect(advancing.until { task("add-b", root)?.status == .running })
        let worker = try #require(task("add-b", root)?.worker)
        if idle { setStatus(worker, LeadActivity.idle(background: nil).text, runtime) }
        try work("add-b", file: "b.txt", root: root, runtime)
        let head = head("agent/add-b", root)
        #expect(advancing.until { vault.current(.verifier, root: root, task: "add-b")?.auditing == head && task("add-b", root)?.verifier != nil })
        return (worker, head, {
            kills.lock()
            defer { kills.unlock() }
            return seen
        })
    }

    @Test func anIdleWorkerIsReleasedOnceItsAuditsVerifierIsUpAndNoOtherTasksWorker() throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        // Another task at work, between turns too: never its worker.
        _ = lead.call("add_task", ["title": "Add c", "goal": "c.txt exists", "acceptance": ["test -f c.txt"], "review": "audit"])
        #expect(advancing.until { task("add-c", root)?.status == .running })
        let other = try #require(task("add-c", root)?.worker)
        setStatus(other, LeadActivity.idle(background: nil).text, runtime)
        let (worker, head, kills) = try releasedAudit(idle: true, root, runtime, advancing, lead)
        #expect(advancing.until { killed(worker, runtime) && task("add-b", root)?.released == worker })
        // Ended after its verifier was spawned, never before.
        #expect(kills()[worker] == ["Verifier: Add b"], "\(kills())")
        advancing.settle()
        #expect(!killed(other, runtime))
        let after = try #require(task("add-b", root))
        #expect(after.stopped == worker && after.status == .review && after.worktree != nil)
        // Its branch and worktree are as they were.
        #expect(self.head("agent/add-b", root) == head)
        #expect(FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: "add-b") + "/b.txt"))
        #expect(reports(runtime).contains { $0.contains("Started the audit of add-b") && $0.contains("Released its worker, idle since its done report") },
                "\(reports(runtime))")
        #expect(progress(root).contains("Released add-b's worker (idle since its done report on \(head.prefix(8))) while its audit runs"))
        // Status and board say so, never "worker ended".
        let status = lead.call("status", [:]).text
        #expect(status.contains("add-b") && status.contains("worker released during audit") && !status.contains("worker ended"), "\(status)")
        let board = lead.call("board", [:]).text
        #expect(board.contains("worker released during audit") && !board.contains("worker ended"), "\(board)")
        #expect(lead.call("board", ["task": "add-b"]).text.contains("Now: worker released during audit"))
    }

    /// The worker had only just reported: mid-turn at the audit's start, or on a prompt, it's left; once its turn ends
    /// (the app's witness nudges the loop), it's released.
    @Test func aWorkerMidTurnAtTheAuditsStartIsReleasedOnlyOnceItsTurnEnds() throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        let (worker, _, kills) = try releasedAudit(idle: false, root, runtime, advancing, lead)
        advancing.settle()
        #expect(!killed(worker, runtime) && task("add-b", root)?.released == nil)
        // Waiting on its background task, or on a prompt: still mid-turn.
        setStatus(worker, LeadActivity.idle(background: "swift test").text, runtime)
        advancing.settle()
        #expect(!killed(worker, runtime))
        runtime.calls.lock()
        runtime.statuses[worker] = LeadActivity.idle(background: nil).text
        runtime.waiting[worker] = PendingPrompt(text: "Run: ls?")
        runtime.calls.unlock()
        advancing.settle()
        #expect(!killed(worker, runtime))
        // Its turn ends: the witness sees it between turns and nudges the loop.
        runtime.calls.lock()
        runtime.waiting[worker] = nil
        runtime.calls.unlock()
        var board = BoardStore(root: root).load()
        let idle = LeadWitness.Seen(live: true, status: .done, activity: .idle(background: nil))
        #expect(LeadWitness.releasableForAdvance(board: board, seen: [worker: idle]) == [worker])
        LeadAdvance.nudge(root: root)
        #expect(advancing.until { killed(worker, runtime) && task("add-b", root)?.released == worker })
        #expect(kills()[worker] == ["Verifier: Add b"])
        #expect(reports(runtime).contains { $0.contains("Released add-b's worker, idle since its done report") }, "\(reports(runtime))")
        board = BoardStore(root: root).load()
        #expect(LeadWitness.releasableForAdvance(board: board, seen: [worker: idle]).isEmpty)
    }

    @Test func openImportantFindingsAfterAReleaseGoToAFreshWorkerInTheSameWorktree() throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        let (worker, head, _) = try releasedAudit(idle: true, root, runtime, advancing, lead)
        #expect(advancing.until { killed(worker, runtime) && task("add-b", root)?.released == worker })
        // No alarm for its end: in review, and failed on the verdict alike.
        let gone = LeadWitness.Seen(live: false, exit: 143, cause: "killed by SIGTERM")
        var board = BoardStore(root: root).load()
        #expect(!LeadWitness.events(board: board, seen: [worker: gone]).contains { $0.key.hasPrefix(worker) })
        board.tasks[try #require(board.taskIndex("add-b"))].status = .failed
        #expect(!LeadWitness.events(board: board, seen: [worker: gone]).contains { $0.key.hasPrefix(worker) })
        let finding: [String: Any] = ["severity": "Important", "file": "b.txt", "line": 1, "evidence": "b.txt says bee, the contract wants b",
                                      "failure_scenario": "cat b.txt gives bee where the contract wants b", "status": "open"]
        let verdict = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "one problem",
                                                                                "tests": "passed", "findings": [finding]])
        #expect(!verdict.isError, "\(verdict.text)")
        #expect(advancing.until { task("add-b", root)?.worker != worker && toWorker("add-b", root, runtime).contains { $0.contains("F1: ") }
            && reports(runtime).contains { $0.contains("Sent add-b's worker the open Important findings add-b:F1") } })
        let fresh = try #require(task("add-b", root))
        #expect(fresh.status == .running && fresh.released == nil && fresh.stopped == nil && fresh.autoSentBack == head)
        // In the same worktree, on the same branch, nothing of it lost.
        runtime.calls.lock()
        let started = runtime.spawned.last { $0.id == fresh.worker }
        runtime.calls.unlock()
        #expect(started?.cwd == Worktrees.path(root: root, slug: "add-b"))
        #expect(self.head("agent/add-b", root) == head)
        #expect(Git.run(["show", "agent/add-b:b.txt"], in: root).output == "bee")
        // The findings, with what the worker before it did.
        let sent = try #require(toWorker("add-b", root, runtime).first { $0.contains("F1: ") })
        #expect(sent.contains("You're a new worker on this task") && sent.contains("was released while the audit ran"), "\(sent)")
        #expect(sent.contains("at \(head.prefix(8))") && sent.contains("git log main..HEAD") && sent.contains("Its done report: added b.txt"), "\(sent)")
        #expect(sent.contains("contract wants b") && sent.contains("answer_findings"), "\(sent)")
        #expect(reports(runtime).contains { $0.contains("(in a new worker: its last one was released during the audit)") }, "\(reports(runtime))")
        advancing.settle()
        #expect(toWorker("add-b", root, runtime).filter { $0.contains("F1: ") }.count == 1)
    }

    @Test func aCleanVerdictAfterAReleaseMergesWithNoWorker() throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        let (worker, _, _) = try releasedAudit(idle: true, root, runtime, advancing, lead)
        #expect(advancing.until { killed(worker, runtime) && task("add-b", root)?.released == worker })
        let verdict = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "checked", "tests": "passed"])
        #expect(!verdict.isError, "\(verdict.text)")
        #expect(advancing.until { task("add-b", root)?.status == .done && reports(runtime).contains { $0.contains("Merged add-b") } })
        #expect(Git.run(["show", "main:b.txt"], in: root).output == "bee")
        #expect(spawnedLabels(runtime).filter { $0.hasPrefix("Worker:") }.count == 1, "\(spawnedLabels(runtime))")
    }

    /// Without the loop (auto_advance off), nothing would start a worker for the findings: the lead's audit releases none.
    @Test func noReleaseWithAutoAdvanceOff() throws {
        let (root, runtime, lead) = try team(["auto_advance": false])
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "review": "audit"])
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        let worker = try #require(task("add-b", root)?.worker)
        setStatus(worker, LeadActivity.idle(background: nil).text, runtime)
        try work("add-b", file: "b.txt", root: root, runtime)
        let audit = lead.call("audit", ["task": "add-b"])
        #expect(!audit.isError && !audit.text.contains("Released"), "\(audit.text)")
        #expect(!killed(worker, runtime) && task("add-b", root)?.released == nil)
    }
}

extension LeadWitnessTests {
    /// The workers the app nudges auto_advance to release: a reviewed task's, between turns, with its verifier at work.
    @Test func releasableWorkersAreOnlyIdleOnesOfTasksUnderAuditThatMoveByThemselves() {
        let idle = LeadWitness.Seen(live: true, status: .done, activity: .idle(background: nil))
        #expect(LeadWitness.releasableForAdvance(board: inReview(), seen: ["w1": idle]) == ["w1"])
        // Mid-turn, waiting on its background task or a prompt, gone or its agent quit: not yet, or not at all.
        let not: [LeadWitness.Seen] = [
            .init(live: true, status: .working, activity: .working("Bash")),
            .init(live: true, status: .done, activity: .idle(background: "swift test")),
            .init(live: true, status: .needsInput, pending: PendingPrompt(text: "Run: ls?"), activity: .idle(background: nil)),
            .init(live: false, exit: 143),
            .init(live: true, agentQuit: true, activity: .idle(background: nil)),
        ]
        for seen in not { #expect(LeadWitness.releasableForAdvance(board: inReview(), seen: ["w1": seen]).isEmpty, "\(seen)") }
        // Released (stopped) already, opted out, its verdict in, or running: not its.
        for change in ["stopped", "opted out", "verdict", "running"] {
            var board = inReview()
            switch change {
            case "stopped": board.tasks[0].stopped = "w1"
            case "opted out": board.tasks[0].autoAdvance = false
            case "verdict": board.tasks[0].evidence = LeadEvidence(completion: .complete, integrity: .clean, summary: "", commit: "a", at: 0)
            default: board.tasks[0].status = .running
            }
            #expect(LeadWitness.releasableForAdvance(board: board, seen: ["w1": idle]).isEmpty, "\(change)")
        }
    }
}
