import Foundation
import Testing
@testable import VibeCore

/// A stall or a hung run says which it really is, with what shows it and when: the Mac asleep, a test slot, a prompt, a
/// live process with no output, a background job of its own, or that it couldn't tell. Every clock and process list here
/// is the test's own: nothing sleeps, and nothing reads pmset.
struct LeadWitnessCauseTests {
    static let t0 = 1_800_000_000.0
    static func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: t0 + minutes * 60) }
    static func clock(_ minutes: Double) -> String { LeadBoard.clock(t0 + minutes * 60) }

    static func task() -> LeadTask {
        var task = LeadTask(slug: "fix", title: "fix", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.status = .running
        task.worker = "w1"
        return task
    }

    static func board() -> LeadBoard {
        var board = LeadBoard()
        board.tasks = [task()]
        return board
    }

    /// The witness looked at `minutes` (a fake awake clock that stops during each sleep), the Mac asleep through `sleeps`.
    static func log(_ minutes: [Double], sleeps: [(from: Double, to: Double)] = []) -> MacSleepLog {
        var log = MacSleepLog()
        var awake = 0.0, last = minutes.first ?? 0
        for minute in minutes {
            let slept = sleeps.filter { $0.from >= last && $0.to <= minute }.reduce(0.0) { $0 + $1.to - $1.from }
            awake += (minute - last - slept) * 60
            log.note(wall: t0 + minute * 60, awake: awake)
            last = minute
        }
        return log
    }

    static func silent(sleep: MacSleepLog = MacSleepLog(), shells: [BackgroundJob] = []) -> LeadWitness.Seen {
        LeadWitness.Seen(live: true, status: .working, since: at(0), activity: .working(nil), lastActivity: t0, shells: shells, started: t0 - 3600, sleep: sleep)
    }

    static func job(_ pid: Int32 = 4242, _ command: String = "swift test", started minutes: Double) -> BackgroundJob {
        BackgroundJob(pid: pid, command: command, startedAt: at(minutes))
    }

    static func waiting(tasks: [TranscriptTail.Background], shells: [BackgroundJob], read: Bool = true, status: SessionStatus = .done) -> LeadWitness.Seen {
        LeadWitness.Seen(live: true, status: status, since: at(0), activity: .idle(background: tasks.first?.text), lastActivity: t0, shells: shells,
                         started: t0 - 3600, backgroundTasks: tasks, shellsRead: read)
    }

    static let eval = TranscriptTail.Background(id: "bg1", what: "Run the eval", startedAt: t0 - 5)

    // MARK: The Mac asleep

    @Test func aMacThatSleptThroughTheWholeWindowIsTheCause() throws {
        let log = Self.log([-1, 0.1, 20], sleeps: [(0.1, 20)])
        let now = Self.at(20)
        let stall = try #require(LeadStall.detect(Self.silent(sleep: log), task: Self.task(), now: now).first)
        guard case .macAsleep(let reading)? = stall.cause else { Issue.record("\(String(describing: stall.cause))"); return }
        #expect(reading.slept == 19.9 * 60 && reading.sleeps == 1)
        let report = stall.report(now: now)
        #expect(report.contains("the Mac was asleep: the Mac slept 20 min of the 20 min since \(Self.clock(0)), by its awake clock (1 sleep, last woke \(Self.clock(20)))"), "\(report)")
        #expect(LeadWitness.events(board: Self.board(), seen: ["w1": Self.silent(sleep: log)], now: now).first?.text.contains("the Mac was asleep") == true)
    }

    @Test func aMacAwakeLongEnoughForTheStallIsntTheCauseButIsSaid() throws {
        // Slept 5 of 30 minutes: 25 awake, more than the 15 a silent stall takes: the sleep is only a fact on the side.
        let log = Self.log([-1, 2, 7, 30], sleeps: [(2, 7)])
        let now = Self.at(30)
        let stall = try #require(LeadStall.detect(Self.silent(sleep: log), task: Self.task(), now: now).first)
        guard case .unknown? = stall.cause else { Issue.record("\(String(describing: stall.cause))"); return }
        #expect(stall.report(now: now).contains("the Mac slept 5 min of the 30 min"))
    }

    @Test func theSleepLogCountsOnlyTheWindowAndSaysWhatItDidntWatch() {
        let log = Self.log([0, 10, 20, 40], sleeps: [(10, 20), (20, 40)])
        // A window from 15: half of the first sleep, all of the second.
        #expect(log.reading(from: Self.t0 + 15 * 60, to: Self.t0 + 40 * 60)?.slept == 25 * 60)
        // Before the first look, nothing is known: it says so.
        let late = Self.log([100, 110])
        #expect(late.reading(from: Self.t0, to: Self.t0 + 110 * 60)?.unwatchedBefore == Self.t0 + 100 * 60)
        #expect(MacSleepLog().reading(from: 0, to: 1) == nil)
        // A jitter of the clocks is no sleep.
        var jitter = MacSleepLog()
        jitter.note(wall: 1000, awake: 10)
        jitter.note(wall: 1061, awake: 70)
        #expect(jitter.reading(from: 0, to: 2000)?.sleeps == 0)
    }

    // MARK: A test slot

    @Test func aMessageHeldBehindATestSlotNamesTheSlotAndItsHolder() throws {
        let holder = TestLock.Holder(slot: 2, note: "pid 9, swift test in /Users/a/p/.vibeswitcher/worktrees/other, since 1", since: Self.at(-3),
                                     project: "p", task: "other")
        let waiter = TestLock.Waiter(number: 4, slots: 3, who: TestLock.Holder(slot: 0, note: "pid 5, scripts/test.sh in /Users/a/p/.vibeswitcher/worktrees/fix, since 1",
                                                                               since: Self.at(-2), project: "p", task: "fix"))
        var seen = Self.waiting(tasks: [], shells: [])
        seen.lockWait = TestLock.Wait(waiter: waiter, ahead: 1, holders: [holder])
        seen.heldSince = Self.t0
        let now = Self.at(10)
        let stall = try #require(LeadStall.detect(seen, task: Self.task(), now: now).first)
        #expect(stall.reason == .undelivered)
        let report = stall.report(now: now)
        #expect(report.contains("waiting for a slot of the Mac-wide test and build lock since \(Self.clock(-2)) (12 min), 2nd in line"), "\(report)")
        #expect(report.contains("slot 2 held by p/other since \(Self.clock(-3))"), "\(report)")
    }

    // MARK: A prompt

    @Test func aPromptWaitedPastTheMarkShowsInStatusAndIsntToldTwice() throws {
        let pending = PendingPrompt(text: "Run: rm -rf x", since: Self.t0)
        let seen = LeadWitness.Seen(live: true, status: .needsInput, since: Self.at(0), pending: pending, activity: .needsInput("Run: rm -rf x"), lastActivity: Self.t0)
        // Not on the Stalled lines before the mark.
        #expect(LeadWitness.stalls(board: Self.board(), seen: ["w1": seen], now: Self.at(14)).isEmpty)
        let now = Self.at(16)
        let found = LeadWitness.stalls(board: Self.board(), seen: ["w1": seen], now: now)
        let stall = try #require(found[Self.board().tasks[0].id])
        #expect(stall.reason == .prompt)
        let report = stall.report(now: now)
        #expect(report.contains("a permission prompt or question is on its screen since \(Self.clock(0)) (16 min): “Run: rm -rf x”"), "\(report)")
        // The witness told it when it began (its "waiting for input"), and doesn't again as a stall.
        let events = LeadWitness.events(board: Self.board(), seen: ["w1": seen], now: now)
        #expect(events.map(\.key) == ["w1|input-\(Int(Self.t0))"])
    }

    // MARK: A live process with no output

    @Test func aLiveProcessWithNoOutputNamesItsPidAndHowLong() throws {
        let now = Self.at(20)
        let stall = try #require(LeadStall.detect(Self.silent(shells: [Self.job(77, "npm test", started: -130)]), task: Self.task(), now: now).first)
        #expect(stall.reason == .silent)
        let report = stall.report(now: now)
        #expect(report.contains("a live process with no output: pid 77 (npm test), started \(Self.clock(-130)), and nothing written for 20 min, since \(Self.clock(0))"), "\(report)")
    }

    // MARK: A background job of its own

    /// The eval of 2026-11-09: a worker waited on its live background job, 3 cases done at about 10 minutes each, and was
    /// reported stalled at 45 minutes as if it needed the lead.
    @Test func aLiveBackgroundJobIsntReportedAsAStallAtTheCeiling() throws {
        let seen = Self.waiting(tasks: [Self.eval], shells: [Self.job(started: 0)])
        let now = Self.at(46)
        #expect(LeadWitness.events(board: Self.board(), seen: ["w1": seen], now: now).isEmpty, "held back: nothing for the lead to do")
        let stall = try #require(LeadStall.detect(seen, task: Self.task(), now: now).first)
        #expect(stall.heldBack && stall.waitsOnOwnJob)
        let report = stall.report(now: now)
        #expect(report.hasPrefix("not stalled: waiting on its own background job (Run the eval): pid 4242, started \(Self.clock(0)), still alive after 46 min"), "\(report)")
        #expect(!report.contains("for over 45 min"))
    }

    @Test func aShellItsTranscriptDoesntNameIsLabelledNotHeldBack() throws {
        let seen = Self.waiting(tasks: [], shells: [Self.job(started: -1)], status: .background)
        let now = Self.at(46)
        let stall = try #require(LeadStall.detect(seen, task: Self.task(), now: now).first)
        #expect(!stall.heldBack && stall.waitsOnOwnJob)
        // It could be a server it left running, so the lead still hears, labelled as what it is.
        let event = try #require(LeadWitness.events(board: Self.board(), seen: ["w1": seen], now: now).first)
        #expect(event.text.contains("is not stalled: waiting on its own background job (swift test)"), "\(event.text)")
        #expect(event.text.contains("its transcript names no task it waits on, only this shell"), "\(event.text)")
        #expect(!event.text.contains("for over 45 min"))
    }

    @Test func aJobWhoseProcessDiedIsToldAtOnceAsStopped() throws {
        let seen = Self.waiting(tasks: [Self.eval], shells: [])
        #expect(seen.waitingOn == nil && seen.diedJob == Self.eval)
        // Not at the ceiling: minutes after its turn ended, past the usual quiet.
        let event = try #require(LeadWitness.events(board: Self.board(), seen: ["w1": seen], now: Self.at(2)).first)
        #expect(event.key == "w1|stopped-\(Int(Self.t0))")
        #expect(event.text.contains("stopped without calling report: the background job it waited on (Run the eval"), "\(event.text)")
        #expect(event.text.contains("has no process any more"), "\(event.text)")
        // It isn't said in the quiet minute it takes for a notification to arrive.
        #expect(LeadWitness.events(board: Self.board(), seen: ["w1": seen], now: Self.at(1)).isEmpty)
    }

    @Test func anUnreadProcessTableOrAnAgentIsNotCalledDead() {
        #expect(Self.waiting(tasks: [Self.eval], shells: [], read: false).diedJob == nil, "not read: unknown, not dead")
        let agent = TranscriptTail.Background(id: "a1", what: "review", startedAt: Self.t0 - 5, isShell: false)
        #expect(Self.waiting(tasks: [agent], shells: []).diedJob == nil, "a background agent has no process to look for")
        #expect(Self.waiting(tasks: [Self.eval, agent], shells: []).diedJob == nil)
    }

    @Test func aShellStartedAtAnotherTimeIsntTheNamedJob() {
        // A server it left running two hours before doesn't keep the eval alive.
        let seen = Self.waiting(tasks: [Self.eval], shells: [Self.job(started: -130)])
        #expect(seen.diedJob == Self.eval && seen.liveNamedJob == nil)
    }

    // MARK: Couldn't tell

    @Test func whenNothingShowsWhyItSaysSoAndShowsWhatItRead() throws {
        var seen = LeadWitness.Seen(live: true, status: .done, since: Self.at(0), activity: .idle(background: nil), lastActivity: Self.t0, started: Self.t0 - 3600,
                                    sleep: Self.log([-1, 5, 11]))
        seen.pending = PendingPrompt(text: "Run: ls", since: Self.t0)
        let now = Self.at(11)
        let stall = try #require(LeadStall.detect(seen, task: Self.task(), now: now).first)
        guard case .unknown(let read)? = stall.cause else { Issue.record("\(String(describing: stall.cause))"); return }
        #expect(read.contains("status done since \(Self.clock(0))"))
        #expect(read.contains("transcript last written \(Self.clock(0))"))
        #expect(read.contains("no shells of its own in the process table"))
        #expect(read.contains("its last call has no result yet: Run: ls"))
        #expect(read.contains("the Mac was awake the whole time, by its awake clock"))
        #expect(stall.report(now: now).contains("Cause: couldn't tell why. What was read: status done"))
    }

    @Test func aSleepNotWatchedIsSaidNotGuessed() throws {
        let now = Self.at(11)
        let stall = try #require(LeadStall.detect(LeadWitness.Seen(live: true, status: .done, since: Self.at(0), activity: .idle(background: nil), lastActivity: Self.t0, started: Self.t0 - 3600),
                                                  task: Self.task(), now: now).first)
        guard case .unknown(let read)? = stall.cause else { Issue.record("\(String(describing: stall.cause))"); return }
        #expect(read.contains("how long the Mac slept wasn't watched"))
    }

    // MARK: On the board

    @Test func theCauseSurvivesTheBoardAndAChangedCauseReplacesIt() throws {
        var board = Self.board()
        let id = board.tasks[0].id
        let old = LeadStall(reason: .silent, lastActivity: Self.t0, at: Self.t0 + 900, cause: .unknown(read: ["x"]))
        #expect(board.noteStalls([id: old]))
        var fresh = old
        fresh.at = Self.t0 + 1800
        fresh.cause = .liveProcess(pid: 1, command: "c", startedAt: Self.t0, quietSince: Self.t0)
        #expect(board.noteStalls([id: fresh]))
        #expect(board.tasks[0].stall?.at == old.at, "first noticed stays")
        #expect(board.tasks[0].stall?.cause == fresh.cause)
        #expect(!board.noteStalls([id: fresh]), "nothing changed: the board isn't written again")
        let decoded = try JSONDecoder().decode(LeadStall.self, from: JSONEncoder().encode(board.tasks[0].stall!))
        #expect(decoded.cause == fresh.cause)
        // A board written before this has no cause, and reads as it did.
        let older = try JSONDecoder().decode(LeadStall.self, from: Data(#"{"reason":"silent","lastActivity":1800000000,"at":1800000900}"#.utf8))
        #expect(older.cause == nil && older.report(now: Self.at(20)) == older.text(now: Self.at(20)))
    }

    @Test func onlyARealStallIsARedRow() {
        let job = LeadStall(reason: .idle, lastActivity: Self.t0, background: "x", cause: .backgroundJob(what: "x", pid: 1, startedAt: Self.t0, named: true))
        #expect(!job.showsAsStalled)
        #expect(!LeadStall(reason: .prompt, lastActivity: Self.t0).showsAsStalled)
        #expect(LeadStall(reason: .silent, lastActivity: Self.t0, cause: .macAsleep(.init(from: Self.t0, slept: 60, sleeps: 1, lastWoke: nil, unwatchedBefore: nil))).showsAsStalled)
    }

    // MARK: Hung runs

    static let stall = StallWatch.Stall(idle: 600, load: 4.2, loadLimit: 24, lastTest: nil, processes: ["5 1 sleeping 0.1 swift-test"], tail: [])

    @Test func aHungRunSaysWhatItReadWithTheMacsSleep() {
        let started = Self.at(0), stopped = Self.at(30)
        let live = MergeRerun.causeNote(stall: Self.stall, quiet: nil, slept: 0, window: 1800, started: started, stopped: stopped, queued: nil)
        #expect(live.hasPrefix("Why it stopped: a live process with no output for 10 min of awake time, its processes when stopped: 5 1 sleeping 0.1 swift-test"), "\(live)")
        #expect(live.contains("the Mac was awake the whole 30 min it ran, from \(Self.clock(0)) to \(Self.clock(30))"), "\(live)")
        let writing = MergeRerun.causeNote(stall: nil, quiet: 3, slept: 300, window: 3000, started: started, stopped: stopped, queued: nil)
        #expect(writing.contains("it was still writing output (its last line 3 s of awake time before the stop): it ran out of time, not stuck"), "\(writing)")
        #expect(writing.contains("the Mac slept 5 min of the 50 min it ran"), "\(writing)")
        let silent = MergeRerun.causeNote(stall: nil, quiet: 900, slept: 0, window: 2700, started: started, stopped: stopped, queued: nil)
        #expect(silent.contains("a live process with no output: its last line came 15 min of awake time before the stop"), "\(silent)")
        let unread = MergeRerun.causeNote(stall: nil, quiet: nil, slept: 0, window: 2700, started: started, stopped: stopped, queued: nil)
        #expect(unread.contains("couldn't tell why"), "\(unread)")
    }

    @Test func aHungRunAcrossSleepIsSaidToBeTheMacAsleep() {
        // The incident's shape: hours on the wall clock, its limit reached in awake time alone.
        let note = MergeRerun.causeNote(stall: Self.stall, quiet: nil, slept: 4 * 3600, window: 5 * 3600, started: Self.at(0), stopped: Self.at(300), queued: nil)
        #expect(note.hasPrefix("Why it stopped: the Mac slept through most of it: the Mac slept 240 min of the 300 min it ran"), "\(note)")
        #expect(note.contains("so it had 60 min awake"), "\(note)")
    }

    @Test func aHungRunStillInLineForASlotNamesIt() {
        let holder = TestLock.Holder(slot: 1, note: "pid 9, swift test, since 1", since: Self.at(-1))
        let waiter = TestLock.Waiter(number: 2, slots: 2, who: TestLock.Holder(slot: 0, note: "pid 5, vs-heavy swift test in /x/y, since 1", since: Self.at(1)))
        let note = MergeRerun.causeNote(stall: nil, quiet: 900, slept: 0, window: 2700, started: Self.at(0), stopped: Self.at(45),
                                        queued: TestLock.Wait(waiter: waiter, ahead: 0, holders: [holder]))
        #expect(note.contains("something it started sat in line for a Mac-wide test slot since \(Self.clock(1)) (vs-heavy swift test"), "\(note)")
        #expect(note.contains("slot 1 held by pid 9, swift test"), "\(note)")
    }

    @Test func theCauseReachesTheHungReportsAndTheLog() {
        let output = "line\n\n" + MergeRerun.causeNote(stall: Self.stall, quiet: nil, slept: 0, window: 1800, started: Self.at(0), stopped: Self.at(30), queued: nil)
        #expect(MergeRerun.causeText(output).hasPrefix("Why it stopped: a live process"))
        #expect(MergeRerun.causeText("no note") == "")
        #expect(MergeRerun.hungLog(task: "t", commit: "abc", command: "test command", after: 2700, output: output).contains("Why it stopped: a live process"))
        #expect(MergeRerun.phase(in: output) == .unknown, "the note isn't read as a build or test line")
    }
}
