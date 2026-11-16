import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// What the Mac's sleep paused, as the lead controller notes it at each refresh (`SleepWatch`): the clocks are the
/// test's (the Mac "sleeps" when the wall clock moves and the awake clock doesn't), the ledger a scratch file. And the
/// battery hold's card (`PowerLook.text`).
struct SleepWatchTests {
    let temp = Scratch()

    /// The Mac's two clocks, moved by the test.
    final class Clocks: @unchecked Sendable {
        private let lock = NSLock()
        private var wall: Double
        private var awake: TimeInterval = 1_000

        init(wall: Double) { self.wall = wall }

        var time: MacTime { MacTime(wall: { [self] in Date(timeIntervalSince1970: lock.withLock { wall }) }, awake: { [self] in lock.withLock { awake } }) }

        /// Awake for `seconds`: both clocks move.
        func run(_ seconds: TimeInterval) { lock.withLock { wall += seconds; awake += seconds } }
        /// Asleep for `seconds`: only the wall clock moves.
        func sleep(_ seconds: TimeInterval) { lock.withLock { wall += seconds } }
    }

    static func task(_ slug: String, _ status: LeadTask.Status) -> LeadTask {
        var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.status = status
        return task
    }

    static func board(_ tasks: [LeadTask]) -> LeadBoard {
        var board = LeadBoard()
        board.tasks = tasks
        return board
    }

    static let boards = ["/projects/site": board([task("cache", .running), task("login", .review), task("later", .planned)]),
                         "/projects/payouts": board([task("refund", .running), task("old", .done)])]

    /// 14:00 on 2026-11-07, this Mac's time.
    static let start = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 14))!.timeIntervalSince1970

    @Test func aLongSleepWithWorkInFlightIsToldOnceOnWakingAndCounted() throws {
        let clocks = Clocks(wall: Self.start), file = temp.url("sleep-cost").appendingPathComponent("sleep-cost.json")
        let watch = SleepWatch(time: clocks.time, file: file)
        var log = MacSleepLog()
        // The first look only starts the log; a look 3 s on, awake, finds nothing.
        #expect(watch.look(&log, boards: Self.boards) == nil)
        clocks.run(3)
        #expect(watch.look(&log, boards: Self.boards) == nil)
        // Asleep 2 h: told once the Mac has stayed awake (not in a dark wake), with the tasks it paused; the next look
        // says nothing more.
        clocks.sleep(2 * 3600)
        #expect(watch.look(&log, boards: Self.boards) == nil)
        clocks.run(SleepWatch.realWake - 1)
        #expect(watch.look(&log, boards: Self.boards) == nil)
        clocks.run(1)
        let notice = try #require(watch.look(&log, boards: Self.boards))
        #expect(notice.title == "The Mac slept 2 h: 3 tasks paused")
        #expect(notice.body.hasPrefix("payouts: refund; site: cache, login."), "\(notice.body)")
        clocks.run(3)
        #expect(watch.look(&log, boards: Self.boards) == nil)
        // Counted into the ledger, as status and the digest read it.
        watch.settled()
        let cost = SleepCost.load(from: file)
        let day = AppHealth.Watch.day(Date(timeIntervalSince1970: Self.start))
        #expect(cost.days[day]?["/projects/site"]?.taskSeconds == 14_400.0)
        #expect(cost.days[day]?["/projects/payouts"]?.tasks == ["refund": 7_200.0])
        #expect(cost.digestText(day: day)?.contains("site 4.0 task-hours in 1 sleep") == true)
    }

    @Test func aShortSleepSaysNothingButIsCounted() throws {
        let clocks = Clocks(wall: Self.start), file = temp.url("sleep-cost").appendingPathComponent("sleep-cost.json")
        let watch = SleepWatch(time: clocks.time, file: file)
        var log = MacSleepLog()
        _ = watch.look(&log, boards: Self.boards)
        clocks.sleep(9 * 60)
        #expect(watch.look(&log, boards: Self.boards) == nil)
        clocks.run(SleepWatch.realWake)
        #expect(watch.look(&log, boards: Self.boards) == nil)
        watch.settled()
        let day = AppHealth.Watch.day(Date(timeIntervalSince1970: Self.start))
        #expect(SleepCost.load(from: file).days[day]?["/projects/payouts"]?.taskSeconds == 540.0)
        #expect(SleepCost.load(from: file).days[day]?["/projects/site"]?.taskSeconds == 1_080.0)
        // A long one with nothing in flight says nothing either, and counts nothing more.
        let idle = ["/projects/site": Self.board([Self.task("later", .planned)])]
        clocks.sleep(3 * 3600)
        #expect(watch.look(&log, boards: idle) == nil)
        clocks.run(SleepWatch.realWake)
        #expect(watch.look(&log, boards: idle) == nil)
        watch.settled()
        #expect(SleepCost.load(from: file).days[day]?["/projects/site"]?.taskSeconds == 1_080.0)
        #expect(SleepCost.load(from: file).days[day]?["/projects/site"]?.sleeps == 1)
    }

    /// A night asleep with the Mac's dark wakes in it (a few seconds awake every 15 minutes): one sleep, told once
    /// when the Mac really wakes, not a notice per dark wake; the ledger counts it as one sleep, its whole length.
    @Test func darkWakesInsideASleepAreOneSleepToldOnce() throws {
        let clocks = Clocks(wall: Self.start), file = temp.url("sleep-cost").appendingPathComponent("sleep-cost.json")
        let watch = SleepWatch(time: clocks.time, file: file)
        var log = MacSleepLog()
        _ = watch.look(&log, boards: Self.boards)
        for _ in 0..<4 {
            clocks.sleep(15 * 60)
            #expect(watch.look(&log, boards: Self.boards) == nil)
            clocks.run(5)
            #expect(watch.look(&log, boards: Self.boards) == nil)
        }
        clocks.run(SleepWatch.realWake)
        let notice = try #require(watch.look(&log, boards: Self.boards))
        #expect(notice.title == "The Mac slept 1 h: 3 tasks paused")
        clocks.run(3)
        #expect(watch.look(&log, boards: Self.boards) == nil)
        watch.settled()
        let project = try #require(SleepCost.load(from: file).days[AppHealth.Watch.day(Date(timeIntervalSince1970: Self.start))]?["/projects/payouts"])
        #expect(project.sleeps == 1 && project.longest == 3_600.0 && project.taskSeconds == 3_600.0)
    }

    /// The hold's card says what it pauses in each project and since when; its end, how long it lasted.
    @Test func theBatteryHoldsCardSaysWhatItPausesAndSinceWhen() {
        let since = Self.start + 2 * 60
        let held = PowerLook.Told(text: "On battery: 45 %, under your 50 % limit: …", since: since)
        #expect(PowerLook.text(held, board: Self.boards["/projects/site"])
                == "On battery: 45 %, under your 50 % limit: … Here, 2 tasks paused since 14:02 (1 planned, 1 in review).")
        #expect(PowerLook.text(held, board: nil) == held.text)
        let ended = PowerLook.Told(text: "On AC power: resume starts and merges (60 %, charging).", since: since, ended: true)
        #expect(PowerLook.text(ended, board: Self.boards["/projects/site"], now: Date(timeIntervalSince1970: since + 45 * 60))
                == "On AC power: resume starts and merges (60 %, charging). The hold since 14:02 lasted 45 min.")
    }

    /// The look tracks the hold: since when it began, and the look that ends it.
    @Test func thePowerLookKnowsWhenTheHoldBeganAndEnded() throws {
        final class Reading: @unchecked Sendable {
            private let lock = NSLock()
            private var state: PowerState? = PowerState(onBattery: true, percent: 20)
            func get() -> PowerState? { lock.withLock { state } }
            func set(_ new: PowerState?) { lock.withLock { state = new } }
        }
        let state = Reading()
        let look = PowerLook(read: { state.get() }, file: temp.url("power.json"))
        let began = Date(timeIntervalSince1970: Self.start)
        let hold = try #require(look.look(limit: 50, now: began))
        #expect(hold.since == Self.start && !hold.ended)
        state.set(PowerState(onBattery: false, percent: 30, charging: true))
        let resume = try #require(look.look(limit: 50, now: began.addingTimeInterval(600)))
        #expect(resume.since == Self.start && resume.ended)
        // AC power on: nothing to tell, no hold.
        #expect(look.look(limit: 50, now: began.addingTimeInterval(1200)) == nil)
    }
}
