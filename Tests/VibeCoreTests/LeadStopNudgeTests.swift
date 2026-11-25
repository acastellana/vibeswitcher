import Foundation
import Testing
@testable import VibeCore

/// A worker whose turn ends without a report reaching the lead gets one standard prompt from auto_advance instead of the
/// lead being woken to type it (`LeadStopNudge`); a report call under way is no stop at all (`LeadReportCall`). Six
/// times on 2026-11-17/18 the lead was woken by "stopped without calling report" and answered with the same sentence.
extension LeadWitnessTests {
    static let nudgeT0 = Date(timeIntervalSince1970: 1_795_000_000)

    /// Its turn ended at `since`, idle between turns, nothing running.
    static func stoppedWorker(since: Date) -> LeadWitness.Seen {
        LeadWitness.Seen(live: true, status: .done, since: since, activity: .idle(background: nil), lastActivity: since.timeIntervalSince1970,
                         started: since.timeIntervalSince1970 - 3_600)
    }

    func nudgeBoard(_ change: (inout LeadTask) -> Void = { _ in }) -> LeadBoard {
        var running = task("add-b", .running, worker: "w1")
        change(&running)
        var board = LeadBoard()
        board.tasks = [running]
        return board
    }

    func stopEvents(_ board: LeadBoard, _ seen: LeadWitness.Seen, now: Date, advancing: Bool = true) -> [String] {
        LeadWitness.events(board: board, seen: ["w1": seen], now: now, advancing: advancing).map(\.text)
            .filter { $0.contains("stopped without calling report") }
    }

    @Test func aFirstStopIsLeftToAutoAdvanceToNudgeAndRecordedOnce() {
        let t0 = Self.nudgeT0
        let seen = Self.stoppedWorker(since: t0)
        var board = nudgeBoard()
        let now = t0 + 200
        // With the loop running: no wake, handed over instead.
        #expect(stopEvents(board, seen, now: now).isEmpty)
        let stops = LeadWitness.stopsForAdvance(board: board, seen: ["w1": seen], now: now)
        #expect(stops == [LeadWitness.StopForAdvance(slug: "add-b", worker: "w1", stoppedAt: t0.timeIntervalSince1970, job: nil)])
        // Without it (auto_advance off, or the loop not running): told as ever.
        #expect(stopEvents(board, seen, now: now, advancing: false).count == 1)
        // Under 90 s quiet it isn't a stop yet.
        #expect(LeadWitness.stopsForAdvance(board: board, seen: ["w1": seen], now: t0 + 60).isEmpty)
        // Recorded once: the app's next looks don't record it again, nor hand it over.
        #expect(LeadWitness.handOver(stops, on: &board, now: now))
        #expect(board.tasks[0].stopNudge == LeadStopNudge(worker: "w1", stoppedAt: t0.timeIntervalSince1970, seenAt: now.timeIntervalSince1970,
                                                          background: false, confirmedAt: now.timeIntervalSince1970))
        let again = LeadWitness.stopsForAdvance(board: board, seen: ["w1": seen], now: now + 5)
        #expect(!LeadWitness.handOver(again, on: &board, now: now + 5))
        #expect(stopEvents(board, seen, now: now + 5).isEmpty)
        // The loop never nudged within the grace: the lead is told, as ever.
        let late = now + LeadWitness.advanceGrace + 1
        #expect(stopEvents(board, seen, now: late).count == 1)
        #expect(!stopEvents(board, seen, now: late)[0].contains("again"))
        // First seen long after it began (the app relaunched): still nudged, not told.
        let past = t0 + 3_600
        #expect(stopEvents(nudgeBoard(), seen, now: past).isEmpty)
        #expect(LeadWitness.stopsForAdvance(board: nudgeBoard(), seen: ["w1": seen], now: past).count == 1)
    }

    /// Those keep their own handling: a prompt, the usage limit, an API error. A held task (kept, blocked, auto_advance
    /// false) isn't nudged; the last is told to the lead as ever.
    @Test(arguments: ["prompt", "usage limit", "api error", "kept", "blocked", "auto_advance false"])
    func noNudgeForAWorkerOnAPromptALimitAnErrorOrAHeldTask(_ hold: String) {
        let t0 = Self.nudgeT0
        var seen = Self.stoppedWorker(since: t0)
        let board = nudgeBoard { task in
            switch hold {
            case "kept": task.status = .kept
            case "blocked": task.status = .blocked
            case "auto_advance false": task.autoAdvance = false
            default: break
            }
        }
        switch hold {
        case "prompt":
            seen.status = .needsInput
            seen.detail = "Run: ls"
        case "usage limit":
            seen.activity = .usageLimit(UsageLimit(said: "You've hit your limit", resetsAt: t0.timeIntervalSince1970 + 3_600))
        case "api error":
            seen.apiError = "API Error: 529 Overloaded"
            seen.apiErrorAt = t0.timeIntervalSince1970
        default: break
        }
        let now = t0 + 200
        #expect(LeadWitness.stopsForAdvance(board: board, seen: ["w1": seen], now: now).isEmpty, "\(hold)")
        let told = LeadWitness.events(board: board, seen: ["w1": seen], now: now, advancing: true).map(\.text)
        switch hold {
        case "prompt": #expect(told.contains { $0.contains("is waiting for input") }, "\(told)")
        case "usage limit": #expect(told.contains { $0.contains("usage limit") }, "\(told)")
        case "api error": #expect(told.contains { $0.contains("API error") }, "\(told)")
        case "auto_advance false": #expect(stopEvents(board, seen, now: now).count == 1, "\(told)")
        default: #expect(told.isEmpty, "\(told)")
        }
    }

    /// 2026-11-18, scorecard-merge and lead-context-cost-hand: the done report's pre-done check waited for a test slot,
    /// the client put the call in the background and the turn ended. A report on its way is no stop: no nudge, no wake.
    @Test func noNudgeNorWakeWhileAReportCallIsInFlight() throws {
        let t0 = Self.nudgeT0
        let seen = Self.stoppedWorker(since: t0)
        let now = t0 + 400
        let pending = LeadReportCall(at: t0.timeIntervalSince1970 - 30, pid: getpid(), until: now.timeIntervalSince1970 + 600)
        let board = nudgeBoard { $0.reportCall = pending }
        #expect(LeadWitness.stopsForAdvance(board: board, seen: ["w1": seen], now: now).isEmpty)
        #expect(stopEvents(board, seen, now: now).isEmpty)
        #expect(stopEvents(board, seen, now: now, advancing: false).isEmpty)
        // Past its longest, or its tool server gone: no longer under way.
        let past = nudgeBoard { $0.reportCall = LeadReportCall(at: pending.at, pid: getpid(), until: now.timeIntervalSince1970 - 1) }
        #expect(LeadWitness.stopsForAdvance(board: past, seen: ["w1": seen], now: now).count == 1)
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        let gone = nudgeBoard { $0.reportCall = LeadReportCall(at: pending.at, pid: exited.processIdentifier, until: pending.until) }
        #expect(stopEvents(gone, seen, now: now, advancing: false).count == 1)
        // Its check ran past the idle-stall threshold (a slot's wait, then the run): no stall told or kept either.
        let long = t0 + LeadStall.idleAfter + 300
        let running = nudgeBoard { $0.reportCall = LeadReportCall(at: pending.at, pid: getpid(), until: long.timeIntervalSince1970 + 600) }
        #expect(LeadWitness.events(board: running, seen: ["w1": seen], now: long).isEmpty, "\(LeadWitness.events(board: running, seen: ["w1": seen], now: long).map(\.text))")
        #expect(LeadWitness.stalls(board: running, seen: ["w1": seen], now: long).isEmpty)
        // Without the call, that's a stall.
        #expect(!LeadWitness.stalls(board: nudgeBoard(), seen: ["w1": seen], now: long).isEmpty)
        #expect(LeadWitness.events(board: nudgeBoard(), seen: ["w1": seen], now: long).contains { $0.text.contains("is stalled") })
    }

    /// F1: an unsent nudge is for the stop it was handed over for only. While its worker stays in it, the witness
    /// confirms it now and then (the loop sends only on a recent confirmation); once the worker goes back to work it's
    /// confirmed no more, and the worker's next stop is a first one, handed over afresh, not told to the lead.
    @Test func anUnsentNudgeIsConfirmedOnlyWhileItsWorkerStaysInThatStop() {
        let t0 = Self.nudgeT0
        let stop = Self.stoppedWorker(since: t0)
        var board = nudgeBoard()
        let seenAt = t0 + 200
        #expect(LeadWitness.handOver(LeadWitness.stopsForAdvance(board: board, seen: ["w1": stop], now: seenAt), on: &board, now: seenAt))
        // Still that stop: confirmed every `nudgeConfirmEvery`, no more often.
        let later = seenAt + LeadWitness.nudgeConfirmEvery
        #expect(LeadWitness.handOver(LeadWitness.stopsForAdvance(board: board, seen: ["w1": stop], now: later), on: &board, now: later))
        #expect(board.tasks[0].stopNudge?.confirmedAt == later.timeIntervalSince1970)
        #expect(!LeadWitness.handOver(LeadWitness.stopsForAdvance(board: board, seen: ["w1": stop], now: later + 5), on: &board, now: later + 5))
        // Its transcript written after the hand-over, its status's since the same (a short turn no look caught): a new
        // stop, handed over afresh, so the loop can still send it within its grace.
        var touched = board
        var written = stop
        written.lastActivity = (seenAt + 1).timeIntervalSince1970
        let rewritten = later + 200
        #expect(LeadWitness.handOver(LeadWitness.stopsForAdvance(board: touched, seen: ["w1": written], now: rewritten), on: &touched, now: rewritten))
        #expect(touched.tasks[0].stopNudge?.seenAt == rewritten.timeIntervalSince1970)
        #expect(touched.tasks[0].stopNudge?.fresh(now: rewritten.timeIntervalSince1970) == true)
        // Back at work (the user typed into it, or a background command returned), then its turn ends to wait on its
        // own test run: neither is that stop, so the record isn't confirmed, and nothing is told.
        let working = LeadWitness.Seen(live: true, status: .working, since: later + 10, activity: .working(nil),
                                       lastActivity: (later + 30).timeIntervalSince1970, started: stop.started)
        let suite = LeadWitness.Seen(live: true, status: .done, since: later + 60, activity: .idle(background: "1 shell: bash scripts/test.sh"),
                                     lastActivity: (later + 60).timeIntervalSince1970, started: stop.started)
        for (seen, at) in [(working, later + 40), (suite, later + 300)] {
            #expect(LeadWitness.stopsForAdvance(board: board, seen: ["w1": seen], now: at).isEmpty)
            #expect(!LeadWitness.handOver(LeadWitness.stopsForAdvance(board: board, seen: ["w1": seen], now: at), on: &board, now: at))
            #expect(stopEvents(board, seen, now: at).isEmpty)
        }
        // So the loop wouldn't send it.
        #expect(board.tasks[0].stopNudge?.fresh(now: (later + 300).timeIntervalSince1970) == false)
        // Its next stop without a report is a first one: handed over afresh, not told (the old record is past the
        // grace, never sent, and for another stop), and not "again".
        let next = Self.stoppedWorker(since: later + 400)
        let look = later + 600
        #expect(stopEvents(board, next, now: look).isEmpty)
        let stops = LeadWitness.stopsForAdvance(board: board, seen: ["w1": next], now: look)
        #expect(stops.map(\.stoppedAt) == [(later + 400).timeIntervalSince1970])
        #expect(LeadWitness.handOver(stops, on: &board, now: look))
        #expect(board.tasks[0].stopNudge == LeadStopNudge(worker: "w1", stoppedAt: (later + 400).timeIntervalSince1970, seenAt: look.timeIntervalSince1970,
                                                          background: false, confirmedAt: look.timeIntervalSince1970))
        #expect(stopEvents(board, next, now: look + 30).isEmpty)
    }

    @Test func afterTheNudgeTheSameStopIsQuietAndASecondStopWakesTheLeadSayingANudgeWasSent() {
        let t0 = Self.nudgeT0
        let sent = t0.timeIntervalSince1970 + 150
        let refused = LeadReportRefusal(at: t0.timeIntervalSince1970 - 10, text: "Not reported: your branch adds or changes tests (Tests/A.swift)")
        let board = nudgeBoard {
            $0.stopNudge = LeadStopNudge(worker: "w1", stoppedAt: t0.timeIntervalSince1970, seenAt: t0.timeIntervalSince1970 + 120, sentAt: sent)
            $0.reportRefused = refused
        }
        // The stop it was sent for, before the nudge's turn shows: nothing.
        #expect(stopEvents(board, Self.stoppedWorker(since: t0), now: t0 + 200).isEmpty)
        // Its turn after the nudge ended without a report too: the lead is woken, told a nudge went already.
        let again = Date(timeIntervalSince1970: sent + 60)
        for advancing in [true, false] {
            let told = stopEvents(board, Self.stoppedWorker(since: again), now: again + 200, advancing: advancing)
            #expect(told.count == 1)
            #expect(told.first?.contains("stopped without calling report again") == true, "\(told)")
            #expect(told.first?.contains("already sent it its one nudge at \(LeadBoard.clock(sent))") == true, "\(told)")
            #expect(told.first?.contains("was refused: “Not reported: your branch adds or changes tests") == true, "\(told)")
        }
        #expect(LeadWitness.stopsForAdvance(board: board, seen: ["w1": Self.stoppedWorker(since: again)], now: again + 200).isEmpty)
        // A nudge that brought no turn at all: told once the grace is past.
        #expect(stopEvents(board, Self.stoppedWorker(since: t0), now: Date(timeIntervalSince1970: sent + LeadWitness.advanceGrace)).count == 1)
        // A new worker on the task: its stop is a first one.
        var fresh = board
        fresh.tasks[0].worker = "w2"
        let seen = Self.stoppedWorker(since: again)
        #expect(LeadWitness.stopsForAdvance(board: fresh, seen: ["w2": seen], now: again + 200).map(\.worker) == ["w2"])
    }
}

extension LeadAdvanceTests {
    /// The loop's running task `add-b` whose worker, idle between turns, the witness saw stop without a report at
    /// `stoppedAt` (after its start, as a real stop is) and handed over.
    func handedOverStop(_ root: String, _ runtime: FakeRuntime, _ advancing: Advancing) async throws -> (worker: String, stoppedAt: Date) {
        #expect(await advancing.until { task("add-b", root)?.status == .running })
        let worker = try #require(task("add-b", root)?.worker)
        runtime.calls.lock()
        runtime.statuses[worker] = LeadActivity.idle(background: nil).text
        runtime.calls.unlock()
        let stoppedAt = Date()
        let seen = [worker: LeadWitnessTests.stoppedWorker(since: stoppedAt)]
        let look = stoppedAt + 120
        let board = BoardStore(root: root).load()
        // The lead isn't woken for it.
        #expect(!LeadWitness.events(board: board, seen: seen, now: look, advancing: true).contains { $0.text.contains("stopped without calling report") })
        let stops = LeadWitness.stopsForAdvance(board: board, seen: seen, now: look)
        #expect(stops.map(\.worker) == [worker])
        #expect(try BoardStore(root: root).update { LeadWitness.handOver(stops, on: &$0, now: look) })
        LeadAdvance.nudge(root: root)
        return (worker, stoppedAt)
    }

    func nudges(_ root: String, _ runtime: FakeRuntime) -> [String] {
        toWorker("add-b", root, runtime).filter { $0.hasPrefix("Your turn ended without a report reaching the lead") }
    }

    @Test func aWorkerThatStopsWithoutReportingGetsOneNudgeAndASecondStopWakesTheLead() async throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        let (worker, stoppedAt) = try await handedOverStop(root, runtime, advancing)
        #expect(await advancing.until { nudges(root, runtime).count == 1 && reports(runtime).contains { $0.contains("Nudged add-b's worker") } })
        let nudge = try #require(nudges(root, runtime).first)
        #expect(nudge.contains("call report(done) now and stay until it answers") && nudge.contains("report(blocked)"), "\(nudge)")
        // In the progress log and the one report, which doesn't wake the lead.
        #expect(progress(root).contains("Automatically (auto_advance): Nudged add-b's worker: its turn ended at \(LeadBoard.clock(stoppedAt.timeIntervalSince1970))"))
        let report = try #require(reports(runtime).first { $0.contains("Nudged add-b's worker") })
        #expect(SteerMessage(text: report, from: .system(LeadAdvance.sender), agentPid: runtime.me.pid).wakes == false)
        let sent = try #require(task("add-b", root)?.stopNudge?.sentAt)
        // Once: more passes, and another look of the app's, send nothing more.
        await advancing.settle()
        LeadAdvance.nudge(root: root)
        await advancing.settle()
        #expect(nudges(root, runtime).count == 1)
        let board = BoardStore(root: root).load()
        let same = [worker: LeadWitnessTests.stoppedWorker(since: stoppedAt)]
        #expect(LeadWitness.stopsForAdvance(board: board, seen: same, now: Date(timeIntervalSince1970: sent + 30)).isEmpty)
        #expect(!LeadWitness.events(board: board, seen: same, now: Date(timeIntervalSince1970: sent + 30), advancing: true)
            .contains { $0.text.contains("stopped without calling report") })
        // It stops again without reporting: the lead is woken, told a nudge was sent already; no second nudge.
        let again = Date(timeIntervalSince1970: sent + 60)
        let second = [worker: LeadWitnessTests.stoppedWorker(since: again)]
        let told = LeadWitness.events(board: board, seen: second, now: again + 120, advancing: true).map(\.text)
        #expect(told.contains { $0.contains("The worker on add-b stopped without calling report again") && $0.contains("already sent it its one nudge") }, "\(told)")
        #expect(LeadWitness.stopsForAdvance(board: board, seen: second, now: again + 120).isEmpty)
        await advancing.settle()
        #expect(nudges(root, runtime).count == 1)
    }

    /// Its turn waited on a background job that's gone (the witness saw it so), or it left a shell of its own running
    /// that its turn doesn't wait on (a server): the host says it waits on its background task, and the nudge goes all
    /// the same, saying what the witness saw.
    @Test(arguments: [true, false])
    func aWorkerWithABackgroundJobGoneOrAShellLeftRunningIsNudged(jobGone: Bool) async throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        #expect(await advancing.until { task("add-b", root)?.status == .running })
        let worker = try #require(task("add-b", root)?.worker)
        runtime.calls.lock()
        runtime.statuses[worker] = LeadActivity.idle(background: jobGone ? "Full suite, started 13:02" : "1 shell: npm run dev").text
        runtime.calls.unlock()
        let stoppedAt = Date().timeIntervalSince1970
        let gone = jobGone ? "the background job it waited on (Full suite, started 13:02) has no process any more" : nil
        try BoardStore(root: root).update { board in
            board.tasks[board.taskIndex("add-b")!].stopNudge = LeadStopNudge(worker: worker, stoppedAt: stoppedAt, seenAt: stoppedAt + 120, job: gone,
                                                                             background: true)
        }
        LeadAdvance.nudge(root: root)
        #expect(await advancing.until { nudges(root, runtime).count == 1 })
        #expect(nudges(root, runtime).first?.contains("the background job your turn waited on (Full suite, started 13:02) has no process any more") == jobGone,
                "\(nudges(root, runtime))")
    }

    /// The loop checks again before it sends: a worker that went to a prompt or the usage limit since, a report call
    /// under way, or a task the lead holds gets nothing.
    @Test(arguments: ["prompt", "usage limit", "report in flight", "kept", "blocked", "auto_advance false"])
    func noNudgeFromTheLoopForAWorkerOnAPromptALimitAReportOrAHeldTask(_ hold: String) async throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        #expect(await advancing.until { task("add-b", root)?.status == .running })
        let worker = try #require(task("add-b", root)?.worker)
        runtime.calls.lock()
        switch hold {
        case "prompt": runtime.waiting[worker] = PendingPrompt(text: "Run: ls")
        case "usage limit": runtime.usageLimits[worker] = UsageLimit(said: "You've hit your limit", resetsAt: Date().timeIntervalSince1970 + 3_600)
        default: break
        }
        runtime.calls.unlock()
        switch hold {
        case "report in flight":
            try BoardStore(root: root).update { board in
                board.tasks[board.taskIndex("add-b")!].reportCall = LeadReportCall(at: Date().timeIntervalSince1970, pid: getpid(),
                                                                                   until: Date().timeIntervalSince1970 + 600)
            }
        case "kept": #expect(!lead.call("update_task", ["task": "add-b", "status": "kept", "reason": "the user looks first"]).isError)
        case "blocked": #expect(!lead.call("update_task", ["task": "add-b", "status": "blocked"]).isError)
        case "auto_advance false": #expect(!lead.call("update_task", ["task": "add-b", "auto_advance": false]).isError)
        default: break
        }
        // Handed over as the witness saw it before (the loop's own look is what decides).
        let stoppedAt = Date().timeIntervalSince1970
        try BoardStore(root: root).update { board in
            board.tasks[board.taskIndex("add-b")!].stopNudge = LeadStopNudge(worker: worker, stoppedAt: stoppedAt, seenAt: stoppedAt + 120)
        }
        runtime.calls.lock()
        runtime.statuses[worker] = LeadActivity.idle(background: nil).text
        runtime.calls.unlock()
        LeadAdvance.nudge(root: root)
        await advancing.settle()
        await advancing.settle()
        #expect(nudges(root, runtime).isEmpty, "\(hold)")
        #expect(task("add-b", root)?.stopNudge?.sentAt == nil, "\(hold)")
        #expect(!reports(runtime).contains { $0.contains("Nudged add-b") }, "\(hold)")
    }
}

extension LeadAdvanceTests {
    /// F1: the loop's pass comes minutes after the witness handed a stop over (a merge's test run ahead of it). The
    /// worker went back to work meanwhile, with no message from the lead, and its turn now waits on its own test run.
    /// It's not sent the nudge then, nor on a record the witness hasn't confirmed lately; its next stop is nudged.
    @Test func aNudgeLeftUnsentWhileItsWorkerWentBackToWorkIsNotSent() async throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        #expect(await advancing.until { task("add-b", root)?.status == .running })
        let worker = try #require(task("add-b", root)?.worker)
        let now = Date().timeIntervalSince1970
        // Handed over three minutes ago, last confirmed 100 s ago (it's been at work since).
        try BoardStore(root: root).update { board in
            let index = board.taskIndex("add-b")!
            board.tasks[index].messagedAt = now - 1_000
            board.tasks[index].stopNudge = LeadStopNudge(worker: worker, stoppedAt: now - 300, seenAt: now - 180, background: false,
                                                         confirmedAt: now - 100)
        }
        for status in [LeadActivity.idle(background: "1 shell: bash scripts/test.sh").text, LeadActivity.idle(background: nil).text] {
            runtime.calls.lock()
            runtime.statuses[worker] = status
            runtime.calls.unlock()
            LeadAdvance.nudge(root: root)
            await advancing.settle()
            await advancing.settle()
            #expect(nudges(root, runtime).isEmpty, "\(status)")
            #expect(task("add-b", root)?.stopNudge?.sentAt == nil)
        }
        // Its test run over, its turn ends without a report: the witness hands that stop over, and the loop nudges it.
        let stoppedAt = Date()
        let seen = [worker: LeadWitnessTests.stoppedWorker(since: stoppedAt)]
        let look = stoppedAt + 120
        let board = BoardStore(root: root).load()
        #expect(!LeadWitness.events(board: board, seen: seen, now: look, advancing: true).contains { $0.text.contains("stopped without calling report") })
        let stops = LeadWitness.stopsForAdvance(board: board, seen: seen, now: look)
        #expect(stops.map(\.worker) == [worker])
        #expect(try BoardStore(root: root).update { LeadWitness.handOver(stops, on: &$0, now: look) })
        LeadAdvance.nudge(root: root)
        #expect(await advancing.until { nudges(root, runtime).count == 1 })
        #expect(progress(root).contains("Nudged add-b's worker: its turn ended at \(LeadBoard.clock(stoppedAt.timeIntervalSince1970))"))
    }

    /// F1: a fresh record still isn't sent when the host shows the worker's turn waiting on a job of its own though the
    /// stop the witness saw didn't (it went back to work and started one), or the worker now waits on a teammate.
    @Test(arguments: ["own job", "teammate"])
    func aFreshNudgeIsNotSentToAWorkerWaitingOnItsJobOrATeammate(_ hold: String) async throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        #expect(await advancing.until { task("add-b", root)?.status == .running })
        let worker = try #require(task("add-b", root)?.worker)
        let now = Date().timeIntervalSince1970
        runtime.calls.lock()
        runtime.statuses[worker] = LeadActivity.idle(background: hold == "own job" ? "1 shell: bash scripts/test.sh" : nil).text
        runtime.calls.unlock()
        try BoardStore(root: root).update { board in
            let index = board.taskIndex("add-b")!
            board.tasks[index].messagedAt = now - 1_000
            if hold == "teammate" {
                var integrator = LeadTeamMember(name: "core", part: "the core", worker: worker, branch: "agent/add-b", worktree: "add-b")
                integrator.waits = [LeadPeerWait(post: 1, on: "@ui", until: now + 600)]
                board.tasks[index].team = [integrator]
            }
            board.tasks[index].stopNudge = LeadStopNudge(worker: worker, stoppedAt: now - 200, seenAt: now - 60, background: false, confirmedAt: now)
        }
        LeadAdvance.nudge(root: root)
        await advancing.settle()
        await advancing.settle()
        #expect(nudges(root, runtime).isEmpty, "\(hold)")
        #expect(task("add-b", root)?.stopNudge?.sentAt == nil, "\(hold)")
    }
}

extension LeadAdvanceTests {
    /// The report call is kept on the board while its pre-done check runs (here until the test lets it go): the witness
    /// tells nothing of the worker's stop meanwhile. A refused call is kept to tell; one that goes through clears it,
    /// the call, and the stop's nudge.
    @Test func aReportCallIsKeptWhileItRunsSoItsWorkersStopIsNoNewsAndANudgeIsClearedByAReport() async throws {
        let (root, runtime, lead) = try team()
        let go = temp.url("go").path
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"],
                                   "done_check": "while [ ! -f '\(go)' ]; do sleep 0.05; done"])
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        let worker = try #require(task("add-b", root)?.worker)
        try commit("b.txt", "bee\n", in: Worktrees.path(root: root, slug: "add-b"))
        let seat = try seat("worker-add-b", runtime)
        // Refused (no evidence): kept, with its words.
        #expect(seat.call("report", ["status": "done", "summary": "added b.txt"]).isError)
        let refused = try #require(task("add-b", root)?.reportRefused)
        #expect(task("add-b", root)?.reportCall == nil)
        // The witness had handed a stop over; the report runs, its check held.
        try BoardStore(root: root).update { board in
            board.tasks[board.taskIndex("add-b")!].stopNudge = LeadStopNudge(worker: worker, stoppedAt: refused.at, seenAt: refused.at, sentAt: refused.at + 1)
        }
        let answered = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reply: MCPToolResult?
        Thread.detachNewThread {
            reply = seat.call("report", doneReport("added b.txt"))
            answered.signal()
        }
        #expect(await eventually { task("add-b", root)?.reportCall != nil })
        let call = try #require(task("add-b", root)?.reportCall)
        #expect(call.pid == getpid() && call.inFlight(now: Date()))
        let stopped = Date(timeIntervalSince1970: refused.at + 100)
        let seen = [worker: LeadWitnessTests.stoppedWorker(since: stopped)]
        let board = BoardStore(root: root).load()
        for advancing in [true, false] {
            #expect(!LeadWitness.events(board: board, seen: seen, now: stopped + 200, advancing: advancing).contains { $0.text.contains("stopped without calling report") })
        }
        #expect(LeadWitness.stopsForAdvance(board: board, seen: seen, now: stopped + 200).isEmpty)
        FileManager.default.createFile(atPath: go, contents: Data())
        #expect(await offPool { answered.wait(timeout: .now() + hangGuard) } == .success)
        #expect(reply?.isError == false, "\(reply?.text ?? "")")
        let after = try #require(task("add-b", root))
        #expect(after.status == .review && after.reportCall == nil && after.reportRefused == nil && after.stopNudge == nil)
    }
}

extension LeadAdvanceTests {
    /// A refused report's text, kept on the board for the witness and the nudge to quote, ends with a failed pre-done
    /// check's raw output: it's masked for secrets where it's kept (`Redaction.secrets`), so neither board.json, the
    /// lead's wake nor the worker's nudge carries a credential the check printed.
    @Test func aRefusedReportsTextIsMaskedForSecretsOnTheBoardInTheWitnessAndInTheNudge() async throws {
        let (root, runtime, lead) = try team()
        // Assembled at run time (SecretShapeLint). The check quotes it in its command, where the witness's and the nudge's
        // 300 characters reach, and prints it, in the output's tail, after the scratch home's header.
        let secret = "correct-horse" + "-battery-7f3a"
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"],
                                   "done_check": "echo API_KEY=\(secret); exit 1"])
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        let worker = try #require(task("add-b", root)?.worker)
        try commit("b.txt", "bee\n", in: Worktrees.path(root: root, slug: "add-b"))
        let reply = try seat("worker-add-b", runtime).call("report", doneReport("added b.txt"))
        #expect(reply.isError && reply.text.contains("pre-done check failed"), "\(reply.text)")
        // On the board (board.json, as read back), in the command and in the output.
        let refused = try #require(task("add-b", root)?.reportRefused)
        #expect(!refused.text.contains(secret) && refused.text.components(separatedBy: "API_KEY=•••").count == 3, "\(refused.text)")
        // The lead's wake on the worker's stop.
        let stopped = Date(timeIntervalSince1970: refused.at + 100)
        let seen = [worker: LeadWitnessTests.stoppedWorker(since: stopped)]
        let told = LeadWitness.events(board: BoardStore(root: root).load(), seen: seen, now: stopped + 200, advancing: false)
            .map(\.text).filter { $0.contains("stopped without calling report") }
        #expect(told.count == 1 && told.allSatisfy { $0.contains("API_KEY=•••") && !$0.contains(secret) }, "\(told)")
        // The worker's nudge.
        let nudge = LeadAdvance.nudgeText(job: nil, refused: refused)
        #expect(nudge.contains("API_KEY=•••") && !nudge.contains(secret), "\(nudge)")
    }
}
