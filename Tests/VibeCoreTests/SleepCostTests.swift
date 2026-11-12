import Foundation
import Testing
@testable import VibeCore

/// What the Mac's sleep paused (see `SleepCost`): the in-flight task time that fell in sleep by the witness's sleep log
/// (injected here: its clocks are the test's), as the day's app-health digest and status say it; the notice on waking;
/// and what a battery hold says it pauses.
struct SleepCostTests {
    static let a = "/projects/site", b = "/projects/payouts"

    /// 2026-11-07 at `hour`:`minute`, this Mac's time.
    static func at(_ hour: Int, _ minute: Int = 0, day: Int = 7) -> Double {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!.timeIntervalSince1970
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

    /// Site has one task running and one in review (and one planned, one merged: not in flight); payouts one running.
    static let boards = [a: board([task("cache", .running), task("login", .review), task("later", .planned), task("old", .done)]),
                         b: board([task("refund", .running)])]

    /// The sleep log noting the clocks `looks` (wall, awake), each wake it finds counted against `inFlight` at it.
    static func cost(_ looks: [(wall: Double, awake: Double, inFlight: [String: LeadBoard])]) -> SleepCost {
        var log = MacSleepLog(), cost = SleepCost()
        for look in looks {
            if let wake = log.note(wall: look.wall, awake: look.awake) {
                cost.record(wake, inFlight: look.inFlight.mapValues { SleepCost.inFlight($0).map(\.slug) })
            }
        }
        return cost
    }

    /// One night: an hour asleep with both projects' work in flight, then half an hour with only site's. Site paused
    /// 2 tasks × 1.5 h = 3.0 task-hours, payouts 1.0; the day's digest and status say so.
    static let night = cost([(at(1), 100, boards), (at(2), 100, boards), (at(3), 3700, [a: boards[a]!]),
                             (at(3, 30), 3700, [a: boards[a]!])])

    @Test func theDigestSaysEachProjectsInFlightTimeThatFellInSleep() throws {
        let day = AppHealth.Watch.day(Date(timeIntervalSince1970: Self.at(12)))
        let text = try #require(Self.night.digestText(day: day))
        #expect(text.contains("site 3.0 task-hours in 2 sleeps (longest 1 h; most: cache 1.5 h, login 1.5 h)"), "\(text)")
        #expect(text.contains("payouts 1.0 task-hours in 1 sleep (longest 1 h; most: refund 1.0 h)"), "\(text)")
        // Most first, and what keeps work running.
        #expect(text.range(of: "site")!.lowerBound < text.range(of: "payouts")!.lowerBound)
        #expect(text.contains("AC power with the lid open"))
        // The day's trend carries it, on a day otherwise quiet; the next day has none.
        var watch = AppHealth.Watch()
        watch.lookedOn = day
        let folders = AppHealth.Folders(debug: URL(fileURLWithPath: "/nonexistent-debug"), reports: URL(fileURLWithPath: "/nonexistent-reports"))
        // The app's look after midnight has brought the ledger up to date.
        var night = Self.night
        night.seen = Self.at(0, 1, day: 8)
        watch.look(now: Date(timeIntervalSince1970: Self.at(0, 5, day: 8)), folders: folders, memory: nil, sleep: { night })
        #expect(watch.pending.count == 1)
        #expect(watch.pending.first?.contains("site 3.0 task-hours in 2 sleeps") == true, "\(watch.pending)")
        #expect(Self.night.digestText(day: AppHealth.Watch.day(Date(timeIntervalSince1970: Self.at(12, day: 8)))) == nil)
    }

    /// The Mac slept through midnight: the first look of the new day comes before the app has counted that sleep. The
    /// day's trend waits for the ledger to see the day end (not past an hour of looks), then says it whole.
    @Test func theDaysDigestWaitsForTheLedgerToReachTheDaysEnd() throws {
        let day = AppHealth.Watch.day(Date(timeIntervalSince1970: Self.at(12)))
        let folders = AppHealth.Folders(debug: URL(fileURLWithPath: "/nonexistent-debug"), reports: URL(fileURLWithPath: "/nonexistent-reports"))
        var behind = SleepCost()
        behind.seen = Self.at(22, 30)
        var watch = AppHealth.Watch()
        watch.lookedOn = day
        let morning = Date(timeIntervalSince1970: Self.at(7, 30, day: 8))
        watch.look(now: morning, folders: folders, memory: nil, sleep: { behind })
        #expect(watch.pending.isEmpty && watch.lookedOn == day && watch.sleepWaits == 1)
        #expect(watch.nextLook(now: morning) == morning.addingTimeInterval(5 * 60))
        // The app counted the night (seen past midnight): the trend has the hours before midnight.
        var caught = SleepCost()
        caught.record(MacSleepLog.Wake(from: Self.at(22, 30), to: Self.at(7, 30, day: 8), slept: 9 * 3600), inFlight: [Self.b: ["refund"]])
        watch.look(now: morning.addingTimeInterval(300), folders: folders, memory: nil, sleep: { caught })
        #expect(watch.pending.count == 1 && watch.sleepWaits == nil)
        #expect(watch.pending.first?.contains("payouts 1.5 task-hours in 1 sleep (longest 9 h") == true, "\(watch.pending)")
        // A ledger that never catches up holds the trend an hour of looks at most; one no look wrote, not at all.
        var stuck = AppHealth.Watch()
        stuck.lookedOn = day
        for minutes in 0..<12 { stuck.look(now: morning.addingTimeInterval(Double(minutes) * 300), folders: folders, memory: nil, sleep: { behind }) }
        #expect(stuck.pending.isEmpty && stuck.sleepWaits == 12)
        stuck.look(now: morning.addingTimeInterval(12 * 300), folders: folders, memory: nil, sleep: { behind })
        #expect(stuck.pending.isEmpty && stuck.lookedOn == AppHealth.Watch.day(morning) && stuck.sleepWaits == nil)
        var fresh = AppHealth.Watch()
        fresh.lookedOn = day
        fresh.look(now: morning, folders: folders, memory: nil, sleep: { SleepCost() })
        #expect(fresh.lookedOn == AppHealth.Watch.day(morning) && fresh.sleepWaits == nil)
    }

    @Test func statusSaysTodayYesterdayAndTheWeekForItsOwnProject() throws {
        let now = Date(timeIntervalSince1970: Self.at(9, day: 8))
        let line = try #require(Self.night.statusLine(root: Self.a, now: now))
        #expect(line.contains("today none; yesterday 3.0 task-hours in 2 sleeps (longest 1 h); 7 days 3.0 task-hours"), "\(line)")
        // The same folder spelled another way is the same project; another project's figure is its own.
        #expect(Self.night.statusLine(root: Self.a + "/", now: now) == line)
        #expect(try #require(Self.night.statusLine(root: Self.b, now: now)).contains("yesterday 1.0 task-hours in 1 sleep"))
        // A week on, nothing to say.
        #expect(Self.night.statusLine(root: Self.a, now: Date(timeIntervalSince1970: Self.at(9, day: 15))) == nil)
    }

    /// A sleep from 23:00 to 01:00 is shared between the two days.
    @Test func aSleepAcrossMidnightIsSharedBetweenTheDays() {
        let cost = Self.cost([(Self.at(23), 0, [Self.b: Self.boards[Self.b]!]), (Self.at(1, day: 8), 0, [Self.b: Self.boards[Self.b]!])])
        #expect(cost.days[AppHealth.Watch.day(Date(timeIntervalSince1970: Self.at(12)))]?[Self.b]?.taskSeconds == 3600)
        #expect(cost.days[AppHealth.Watch.day(Date(timeIntervalSince1970: Self.at(12, day: 8)))]?[Self.b]?.taskSeconds == 3600)
    }

    /// Saved and read back as the lead's tool server reads it; old days pruned.
    @Test func theLedgerIsKeptInAFileAndPruned() throws {
        let temp = Scratch()
        let file = temp.url("sleep-cost").appendingPathComponent("sleep-cost.json")
        Self.night.save(to: file)
        #expect(SleepCost.load(from: file) == Self.night)
        var later = Self.night
        later.prune(now: Date(timeIntervalSince1970: Self.at(9, day: 20)))
        #expect(later.days.isEmpty)
        #expect(SleepCost.load(from: file.appendingPathExtension("missing")) == SleepCost())
    }

    @Test func aLongSleepWithWorkInFlightIsToldOnWakingAShortOneIsNot() throws {
        let long = MacSleepLog.Wake(from: Self.at(1), to: Self.at(3, 10), slept: 2 * 3600 + 5 * 60)
        let inFlight = Self.boards.mapValues(SleepCost.inFlight)
        let notice = try #require(SleepCost.notice(long, inFlight: inFlight))
        #expect(notice.title == "The Mac slept 2 h 5 min: 3 tasks paused")
        #expect(notice.body.hasPrefix("payouts: refund; site: cache, login."), "\(notice.body)")
        // Ten minutes is long enough; nine isn't; nothing in flight says nothing.
        #expect(SleepCost.notice(.init(from: 0, to: 600, slept: 600), inFlight: inFlight) != nil)
        #expect(SleepCost.notice(.init(from: 0, to: 540, slept: 540), inFlight: inFlight) == nil)
        #expect(SleepCost.notice(long, inFlight: [Self.a: [], Self.b: []]) == nil)
        // Many tasks: six named, the rest counted.
        let many = (1...9).map { Self.task("t\($0)", .running) }
        let crowded = try #require(SleepCost.notice(long, inFlight: [Self.a: many]))
        #expect(crowded.body.hasPrefix("site: t1, t2, t3, t4, t5, t6 and 3 more."), "\(crowded.body)")
    }

    @Test func aBatteryHoldSaysWhatItPausesAndHowLongItLasted() {
        let since = Self.at(14, 2)
        #expect(SleepCost.pausedText(Self.boards[Self.a]!, since: since) == "2 tasks paused since 14:02 (1 planned, 1 in review)")
        #expect(SleepCost.pausedText(Self.boards[Self.b]!, since: since) == "no task paused yet, since 14:02")
        #expect(SleepCost.releasedText(onBattery: false, after: 45 * 60) == "Released: on AC power, after 45 min.")
        #expect(SleepCost.releasedText(onBattery: true, after: 90 * 60) == "Released: no longer under your battery limit, after 1 h 30 min.")
    }
}
