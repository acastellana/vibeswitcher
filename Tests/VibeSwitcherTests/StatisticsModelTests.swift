import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The Statistics page's model: what it shows of a fixed `SetupStats` (a figure not recorded reads so, never 0), its
/// loading state until the stats are in, the range picker's reload, and the real collector working off the main thread.
@MainActor
struct StatisticsModelTests {
    let scratch = Scratch()

    /// Loads that wait until the test lets each go, recording what each asked for.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [(range: DateInterval, resume: CheckedContinuation<SetupStats, Never>)] = []
        private(set) var asked: [DateInterval] = []

        var count: Int { lock.withLock { waiting.count } }
        var ranges: [DateInterval] { lock.withLock { asked } }

        func load(_ range: DateInterval) async -> SetupStats {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    waiting.append((range, continuation))
                    asked.append(range)
                }
            }
        }

        /// Lets the `index`th load still waiting finish with `stats`.
        func release(_ index: Int, with stats: SetupStats) {
            let continuation = lock.withLock { waiting[index].resume }
            continuation.resume(returning: stats)
        }
    }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()
    /// 2026-11-02 15:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_793_631_600)

    static func stats(range: DateInterval, merged: Int = 3) -> SetupStats {
        var known = ProjectFigures()
        known.merged = merged
        known.abandoned = 1
        known.audited = 2
        known.auditRounds = 3
        known.flakes = ProjectFigures.Flakes(flakes: 2, tests: 2, merges: 1)
        known.ended = 4
        known.workerHours = 6.5
        known.cost = 12.5
        known.costed = 3
        known.codexTasks = 1
        known.claudeTasks = 3
        known.startToMerge = [1_800, 5_400, 3_600]
        // Ended tasks with no cost known, no flake ledger, nothing merged.
        var unknown = ProjectFigures()
        unknown.ended = 2
        unknown.claudeTasks = 2
        unknown.workerHours = 1
        let projects = [SetupStats.Project(name: "alpha", root: "/p/alpha", hasArchive: true, figures: known),
                        SetupStats.Project(name: "beta", root: "/p/beta", hasArchive: false, figures: unknown),
                        SetupStats.Project(name: "gamma", root: "/p/gamma", hasArchive: true, figures: nil)]
        let mac = SetupStats.MacWide(
            load: LoadProfile(minutes: 600, median: 8, p90: 20.4, max: 40, minutesAt24: 90, minutesAt36: 12, cores: 14),
            merges: MergeRate(recorded: 5, landed: 4, hours: 8),
            claude: [UsageNow(name: "seven_day", model: nil, usedPercent: 64, resetsAt: nil, reached: false, pace: UsagePace(used: 64, elapsed: 52))])
        return SetupStats(range: range, at: now, projects: projects, total: known.adding(unknown), mac: mac)
    }

    @Test func thePageShowsTheFiguresAndSaysWhatIsNotRecorded() throws {
        let range = StatisticsRange.week.interval(now: Self.now, calendar: Self.utc)
        let page = StatisticsPage(Self.stats(range: range), calendar: Self.utc)
        #expect(page.span == "Oct 27, 2026 – Nov 2, 2026")

        func figure(_ label: String) throws -> StatisticsPage.Figure { try #require(page.mac.first { $0.label == label }) }
        #expect(try figure("Load").value == "median 8 · p90 20.4 · max 40")
        #expect(try figure("Load").detail == "1.5 h at 24 or more, 12 min at 36 or more · 14 cores")
        #expect(try figure("Merges per hour").value == "0.5")
        // Not kept anywhere: said so, never 0.
        #expect(try figure("Freezes").value == "Not recorded")
        #expect(try figure("Boost hours").value == "Not recorded")
        #expect(try figure("Boost hours").detail == nil)
        #expect(try figure("Codex usage").value == "Not recorded")
        let weekly = try figure("Claude weekly")
        #expect(weekly.value == "64%")
        #expect(weekly.detail == "12 points ahead of pace")
        #expect(weekly.meter == StatisticsPage.Meter(used: 0.64, elapsed: 0.52, reached: false))
        #expect(weekly.spoken == "Claude weekly: 64%, 12 points ahead of pace")

        #expect(StatisticsPage.columns == ["Merged", "Abandoned", "Audits · rounds", "Flakes", "Worker hours", "Cost", "Codex share", "Median to merge"])
        #expect(page.projects.map(\.name) == ["alpha", "beta", "gamma"])
        #expect(page.projects[0].cells == ["3", "1", "2 · 3", "2", "6.5 h", "≥ $12.50", "25%", "1 h"])
        #expect(page.projects[0].note == nil)
        // No ledger, no cost known: not recorded; nothing merged: no median ("–"), never 0.
        #expect(page.projects[1].cells == ["0", "0", "0", "Not recorded", "1 h", "Not recorded", "0%", "–"])
        #expect(page.projects[1].note == "no archive: archived tasks not counted")
        #expect(page.projects[2].cells == Array(repeating: "Not recorded", count: 8))
        #expect(page.projects[2].note == "board not readable")
        #expect(page.projects[0].spoken.hasPrefix("alpha, Merged 3, Abandoned 1, Audits · rounds 2 · 3"))
        let total = try #require(page.total)
        #expect(total.name == "Total")
        #expect(total.cells == ["3", "1", "2 · 3", "2", "7.5 h", "≥ $12.50", "17%", "1 h"])
    }

    @Test func nothingReadableIsNotRecordedEverywhere() {
        let range = StatisticsRange.today.interval(now: Self.now, calendar: Self.utc)
        let page = StatisticsPage(SetupStats(range: range, at: Self.now, projects: [], total: nil, mac: SetupStats.MacWide()), calendar: Self.utc)
        #expect(page.span == "Nov 2, 2026")
        #expect(page.total == nil)
        #expect(page.projects.isEmpty)
        #expect(page.mac.map(\.label) == ["Load", "Freezes", "Boost hours", "Merges per hour", "Claude usage", "Codex usage"])
        #expect(page.mac.allSatisfy { $0.value == "Not recorded" && $0.meter == nil })
        // Cost: nothing ended is $0 spent; every task's cost known is that cost.
        #expect(StatisticsPage.row(name: "idle", note: nil, ProjectFigures(), id: "idle").cells[5] == "$0.00")
        var costed = ProjectFigures()
        (costed.ended, costed.costed, costed.cost) = (2, 2, 3)
        #expect(StatisticsPage.row(name: "costed", note: nil, costed, id: "costed").cells[5] == "$3.00")
    }

    @Test func itShowsLoadingUntilTheStatsAreInThenThem() async throws {
        let gate = Gate()
        let model = StatisticsModel(calendar: Self.utc, now: { Self.now }, projects: { ["/p/alpha"] }, load: { _, range in await gate.load(range) })
        model.reload()
        #expect(model.state == .loading)
        #expect(await until { gate.count == 1 })
        #expect(model.state == .loading)
        let range = try #require(gate.ranges.first)
        #expect(range == DateInterval(start: Date(timeIntervalSince1970: 1_793_059_200), end: Date(timeIntervalSince1970: 1_793_664_000)))
        gate.release(0, with: Self.stats(range: range))
        #expect(await until { model.state != .loading })
        #expect(model.state == .loaded(StatisticsPage(Self.stats(range: range), calendar: Self.utc)))
    }

    @Test func pickingARangeReloadsAndTheLastPickWins() async throws {
        let gate = Gate()
        let model = StatisticsModel(calendar: Self.utc, now: { Self.now }, load: { _, range in await gate.load(range) })
        model.reload()
        #expect(await until { gate.count == 1 })
        model.range = .today
        #expect(model.state == .loading)
        #expect(await until { gate.count == 2 })
        let today = gate.ranges[1]
        #expect(today == DateInterval(start: Date(timeIntervalSince1970: 1_793_577_600), end: Date(timeIntervalSince1970: 1_793_664_000)))
        // The week's answer comes in after today's was asked for: dropped.
        gate.release(0, with: Self.stats(range: gate.ranges[0], merged: 9))
        gate.release(1, with: Self.stats(range: today, merged: 1))
        #expect(await until { model.state != .loading })
        guard case .loaded(let page) = model.state else { Issue.record("not loaded"); return }
        #expect(page.projects[0].cells[0] == "1")
        #expect(page.span == "Nov 2, 2026")
        model.range = .month
        #expect(await until { gate.count == 3 })
        #expect(gate.ranges[2].start == Date(timeIntervalSince1970: 1_791_072_000))
        gate.release(2, with: Self.stats(range: gate.ranges[2]))
        #expect(await until { model.state != .loading })
    }

    /// The app's model on the real collector: worked out on the collector's queue, never on the main thread, and with
    /// nothing in its folder, every Mac-wide figure not recorded.
    @Test func theCollectorWorksOffTheMainThread() async throws {
        let home = scratch.url("statistics-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let collector = SetupStatsCollector(home: home, codexHome: nil)
        let model = StatisticsModel(collector: collector, projects: { [home.path] })
        model.reload()
        #expect(model.state == .loading)
        #expect(await until { model.state != .loading })
        #expect(collector.mainThreadRuns == 0)
        guard case .loaded(let page) = model.state else { Issue.record("not loaded"); return }
        #expect(page.projects.isEmpty)
        #expect(page.mac.allSatisfy { $0.value == "Not recorded" })
    }
}
