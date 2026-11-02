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

    // MARK: Quality, autonomy, time and cost

    /// Claude's 2 merges (one on opus), Codex's 1 with no cost known; an 8-week trend whose first weeks merged nothing.
    static func quality() -> SetupQuality {
        var claude = QualityFigures()
        claude.merged = 2
        claude.audited = 2
        claude.firstAuditPassRate = 0.5
        claude.meanRoundsToPass = 1.5
        claude.importantFindings = 3
        claude.findings = FindingOutcomes(fixed: 1, disagreementAccepted: 1, dismissedByVerifier: 0, dismissedByLead: 1, movedToTask: 1, leftOpen: 1,
                                          important: 3)
        claude.mergeFirstTry = MergeFirstTry(counted: 2, firstTry: 1)
        claude.rerolls = 1
        claude.escapes = 1
        claude.questions = 1
        claude.userMinutesPerMergedTask = 5
        claude.neededNobody = 1
        claude.createdToMerged = [7200, 7260]
        (claude.timed, claude.timedSpan, claude.timedWorked) = (2, 14_460, 5400)
        (claude.workerHours, claude.busyHours) = (1.5, 1)
        (claude.costed, claude.cost, claude.workerCost, claude.verifierCost) = (2, 9, 6, 3)
        var codex = QualityFigures()
        codex.merged = 1
        codex.reverts = 1
        codex.escapes = 1
        codex.neededNobody = 1
        codex.userMinutesPerMergedTask = 0
        codex.createdToMerged = [7320]
        var opus = claude
        opus.merged = 1
        opus.firstAuditPassRate = 1
        var all = claude
        all.merged = 3
        all.questions = 2
        all.reverts = 1
        all.escapes = 2
        all.neededNobody = 2
        all.createdToMerged = [7200, 7260, 7320]
        let start = Date(timeIntervalSince1970: 1_788_825_600)  // 2026-09-08
        let passes: [Double?] = [nil, nil, nil, nil, nil, nil, 1, 0.5]
        let costs: [Double?] = [nil, nil, nil, nil, nil, nil, 5, 4.5]
        let week: Double = 7 * 86_400
        let weeks: [QualityWeek] = (0..<8).map { (index: Int) -> QualityWeek in
            let from = start.addingTimeInterval(Double(index) * week)
            return QualityWeek(start: from, end: from.addingTimeInterval(week), merged: index < 6 ? 0 : 3,
                               firstAuditPassRate: passes[index], costPerMergedTask: costs[index])
        }
        return SetupQuality(all: all, byAgent: [QualityGroup(name: "Claude", figures: claude), QualityGroup(name: "Codex", figures: codex)],
                            byModel: [QualityGroup(name: "opus", figures: opus)], weeks: weeks)
    }

    @Test func thePageShowsQualityAutonomyTimeAndCost() throws {
        let range = StatisticsRange.week.interval(now: Self.now, calendar: Self.utc)
        var stats = Self.stats(range: range)
        stats.quality = Self.quality()
        let quality = try #require(StatisticsPage(stats, calendar: Self.utc).quality)
        #expect(quality.sections.map(\.title) == ["Quality", "Autonomy", "Where time goes", "Cost"])
        func figure(_ label: String) throws -> StatisticsPage.Figure {
            try #require(quality.sections.flatMap(\.figures).first { $0.label == label })
        }
        let pass = try figure("First-audit pass rate")
        #expect(pass.value == "50%" && pass.detail == "1 of 2 audited merges passed their first audit")
        #expect(pass.meter == StatisticsPage.Meter(used: 0.5, elapsed: nil, reached: false))
        #expect(pass.spoken == "First-audit pass rate: 50%, 1 of 2 audited merges passed their first audit")
        #expect(try figure("Audit rounds to pass").value == "1.5")
        #expect(try figure("Important findings per audited task").value == "1.5")
        #expect(try figure("What became of findings").value == "5 findings")
        #expect(try figure("What became of findings").detail
            == "1 fixed by the worker · 1 disagreement accepted by the verifier · 1 dismissed by the lead · 1 moved to a task · 1 left open (Nits, Pre-existing)")
        #expect(try figure("Merge first try").value == "50%")
        #expect(try figure("Re-rolls").value == "1" && figure("Reverts").value == "1" && figure("Escapes").value == "2")
        #expect(try figure("Questions to you per merged task").value == "0.67")
        #expect(try figure("Your wait per merged task").value == "5 min")
        #expect(try figure("Needed nobody").value == "67%")
        #expect(try figure("Created → merged").value == "median 2 h · p90 2 h")
        #expect(try figure("Worker working").value == "37%" && figure("The rest").value == "63%")
        #expect(try figure("Parallelism").value == "1.5×")
        #expect(try figure("Cost per merged task").value == "$4.50")
        #expect(try figure("Implementation (worker)").value == "$6.00 · 67%")
        #expect(try figure("Verification (verifier)").value == "$3.00 · 33%")
        // Not kept: said so, never 0.
        #expect(try figure("Waiting for its audit").value == "Not recorded")
        #expect(try figure("Merge reruns").value == "Not recorded")
        // Every figure says what it is on hover, and speaks its label and value.
        for figure in quality.sections.flatMap(\.figures) {
            #expect(figure.help?.isEmpty == false, "\(figure.label)")
            #expect(figure.spoken.hasPrefix("\(figure.label): \(figure.value)"))
        }
    }

    @Test func theBreakdownSplitsClaudeCodexAndModels() throws {
        let range = StatisticsRange.week.interval(now: Self.now, calendar: Self.utc)
        var stats = Self.stats(range: range)
        stats.quality = Self.quality()
        let quality = try #require(StatisticsPage(stats, calendar: Self.utc).quality)
        #expect(quality.breakdown.map(\.name) == ["Claude", "opus", "Codex"])
        #expect(quality.breakdown.map(\.model) == [false, true, false])
        #expect(quality.breakdown[0].cells == ["2", "50%", "1.5", "1.5", "50%", "0.5", "50%", "2 h", "$4.50"])
        // Codex: no audit ("–"), the recorder saw none of its merges and its cost isn't known (not recorded).
        #expect(quality.breakdown[2].cells == ["1", "–", "–", "–", "Not recorded", "0", "100%", "2 h", "Not recorded"])
        #expect(quality.breakdown[2].spoken.hasPrefix("Codex, Merged 1, First audit –"))
        #expect(quality.modelsNote == nil)
        #expect(QualityPage.columnHelp.count == QualityPage.columns.count)
        // No model recorded: said under the table.
        var none = Self.quality()
        none.byModel = []
        #expect(QualityPage(none, calendar: Self.utc).modelsNote == "Models: Not recorded (no merge's worker model is kept)")
        #expect(QualityPage(none, calendar: Self.utc).breakdown.map(\.name) == ["Claude", "Codex"])
    }

    @Test func theTrendShowsEightWeeksOfPassRateAndCost() throws {
        let trend = QualityPage(Self.quality(), calendar: Self.utc).trend
        #expect(trend.count == 8)
        #expect(trend.first?.label == "Sep 8" && trend.last?.label == "Oct 27")
        #expect(trend[0].passRate == "–" && trend[0].passBar == nil && trend[0].cost == "–" && trend[0].costBar == nil)
        #expect(trend[6].passRate == "100%" && trend[6].passBar == 1 && trend[6].cost == "$5.00" && trend[6].costBar == 1)
        #expect(trend[7].passRate == "50%" && trend[7].passBar == 0.5 && trend[7].cost == "$4.50" && trend[7].costBar == 0.9)
        #expect(trend[7].spoken == "Week of Oct 27: 3 merged, first-audit pass rate 50%, cost per merged task $4.50")
    }

    @Test func nothingMergedReadsAsNothingToCountAndUnkeptAsNotRecorded() throws {
        let empty = QualityPage(SetupQuality(all: QualityFigures(), byAgent: [], byModel: [], weeks: []), calendar: Self.utc)
        let figures = empty.sections.flatMap(\.figures)
        // Nothing merged: per-merge figures have nothing to count; counts are 0.
        #expect(figures.first { $0.label == "First-audit pass rate" }?.value == "–")
        #expect(figures.first { $0.label == "Cost per merged task" }?.value == "–")
        #expect(figures.first { $0.label == "Re-rolls" }?.value == "0")
        // Merged but nothing kept: not recorded.
        var old = QualityFigures()
        old.merged = 2
        old.createdToMerged = [60, 120]
        let page = QualityPage(SetupQuality(all: old, byAgent: [], byModel: [], weeks: []), calendar: Self.utc)
        let kept = page.sections.flatMap(\.figures)
        for label in ["What became of findings", "Merge first try", "Worker working", "Waiting for its audit", "The rest", "Parallelism",
                      "Cost per merged task", "Implementation (worker)", "Verification (verifier)", "Merge reruns"] {
            #expect(kept.first { $0.label == label }?.value == "Not recorded", "\(label)")
        }
        #expect(kept.first { $0.label == "First-audit pass rate" }?.detail == "no audited merge")
        // No board: no quality section at all.
        #expect(StatisticsPage(SetupStats(range: DateInterval(start: Self.now, duration: 1), at: Self.now, projects: [], total: nil,
                                          mac: SetupStats.MacWide()), calendar: Self.utc).quality == nil)
    }

    // MARK: Compared with working solo

    /// `quality()` with what the comparison needs: Claude's 2 merges both in the solo baseline ($6 worker, $3 verifier,
    /// one merge rerun), Codex's merge with 1.5M Codex tokens and no price; the lead $1.50 in All.
    static func compared() -> SetupQuality {
        var quality = Self.quality()
        func fill(_ f: inout QualityFigures, codex: Bool) {
            if codex {
                (f.codexLeftOut, f.codexTokens) = (1, 1_500_000)
                (f.timed, f.timedWorked) = (1, 1800)
                f.mergeFirstTry = MergeFirstTry(counted: 1, firstTry: 0)
                (f.sentBack, f.flakesCaught, f.incidentsWatched) = (1, 0, 1)
                (f.workerHours, f.busyHours) = (0.5, 0.5)
            } else {
                (f.soloMerges, f.soloWorkerCost, f.soloVerifierCost, f.soloReran) = (2, 6, 3, 1)
                (f.auditsKept, f.importantFixed, f.flakesCaught, f.incidentsWatched) = (2, 1, 1, 2)
            }
        }
        fill(&quality.byAgent[0].figures, codex: false)
        fill(&quality.byAgent[1].figures, codex: true)
        var all = quality.all
        fill(&all, codex: false)
        (all.codexLeftOut, all.codexTokens, all.flakesCaught, all.incidentsWatched, all.sentBack) = (1, 1_500_000, 1, 3, 1)
        all.mergeFirstTry = MergeFirstTry(counted: 3, firstTry: 1)
        all.lead = LeadSpend(tokens: 2_400_000, cost: 1.5, unpricedDays: 0)
        quality.all = all
        return quality
    }

    @Test func comparedWithWorkingSoloIsAnEstimateSplitByAgent() throws {
        let page = QualityPage(Self.compared(), calendar: Self.utc).compared
        #expect(ComparedPage.title == "Compared with working solo" && ComparedPage.badge == "Estimate")
        #expect(ComparedPage.method.hasPrefix("Estimated, not measured: nothing was run solo."))
        #expect(page.groups.map(\.title) == ["What it costs", "Caught before merge, per 100 merged", "Escaped after merge, per 100 merged", "Time"])
        func row(_ label: String) throws -> ComparedPage.Row { try #require(page.groups.flatMap(\.rows).first { $0.label == label }) }
        // Process cost: All has the lead; Claude's hasn't (in All only); Codex's tokens have no price.
        let cost = try row("Process cost")
        #expect(cost.cells.map(\.value) == ["≥ 43%", "≥ 33%", "Not recorded"])
        #expect(cost.cells[0].detail == "$4.50 of $10.50 over 2 merges · lead $1.50, verifiers $3.00 · not recorded: 1 merge rerun "
            + "· Codex tokens 1.5M, not in the cost")
        #expect(cost.cells[1].detail == "$3.00 of $9.00 over 2 merges · verifiers $3.00 · not recorded: the lead's (in All only), 1 merge rerun")
        #expect(cost.cells[2].detail == "Codex tokens have no price: 1.5M, not in the cost")
        // Caught beside escaped.
        #expect(try row("Important findings fixed").cells.map(\.value) == ["50", "50", "Not recorded"])
        #expect(try row("Important findings fixed").cells[0].detail == "1 of 2 merges whose audits are kept")
        #expect(try row("Important findings fixed").cells[2].detail == "no merge's audits are kept")
        #expect(try row("Test failures sent back").cells.map(\.value) == ["33", "0", "100"])
        #expect(try row("Test failures sent back").cells[1].detail == "0 of 2 merges the merges recorder saw")
        #expect(try row("Flaky tests caught by reruns").cells.map(\.value) == ["33", "50", "0"])
        #expect(try row("Reverts").cells.map(\.value) == ["33", "0", "100"])
        #expect(try row("Incidents").cells.map(\.value) == ["0", "0", "0"])
        // Time.
        #expect(try row("Hours of work per hour").cells.map(\.value) == ["1.5", "1.5", "1"])
        #expect(try row("Your minutes per merged task").cells.map(\.value) == ["5 min", "5 min", "0 min"])
        let handsOff = try row("Hands-off work per minute of yours")
        // Claude: 45 min of work per merged task over 5 of your minutes; Codex: no minute of yours.
        #expect(handsOff.cells.map(\.value) == ["9 min", "9 min", "–"])
        #expect(handsOff.cells[1].detail == "45 min of work per merged task" && handsOff.cells[2].detail == "30 min of work per merged task, no minute of yours")
        // Every row says what it assumes on hover, and speaks each column.
        for row in page.groups.flatMap(\.rows) {
            #expect(!row.help.isEmpty && row.cells.count == ComparedPage.columns.count, "\(row.label)")
            #expect(row.spoken.hasPrefix("\(row.label); All \(row.cells[0].value)"))
        }
    }

    @Test func comparedFiguresNotKeptReadNotRecordedAndNothingMergedReadsNone() throws {
        // Merged, nothing kept: every estimate whose inputs are missing says so.
        var old = QualityFigures()
        old.merged = 2
        old.createdToMerged = [60, 120]
        let page = ComparedPage(all: old, byAgent: [])
        let cells = Dictionary(uniqueKeysWithValues: page.groups.flatMap(\.rows).map { ($0.label, $0.cells[0]) })
        for label in ["Process cost", "Important findings fixed", "Test failures sent back", "Flaky tests caught by reruns", "Incidents",
                      "Hours of work per hour", "Hands-off work per minute of yours"] {
            #expect(cells[label]?.value == "Not recorded", "\(label)")
            #expect(cells[label]?.detail?.isEmpty == false, "\(label) says why")
        }
        #expect(cells["Process cost"]?.detail == "no merge's cost is known")
        #expect(cells["Reverts"]?.value == "0", "reverts are kept on the board")
        // Only re-rolled merges with a known cost.
        old.rerolledLeftOut = 2
        #expect(ComparedPage.processCost(old, all: true).detail == "the merges with a known cost were re-rolled: their attempts aren't split")
        // No agent's merges: nothing to count ("–"), not "Not recorded".
        let none = ComparedPage(all: QualityFigures(), byAgent: [])
        for row in none.groups.flatMap(\.rows) where row.label != "Hours of work per hour" {
            #expect(row.cells.allSatisfy { $0.value == "–" }, "\(row.label)")
        }
    }

    @Test func theNewRecordsFillWhatStatistics3LeftNotRecorded() throws {
        var quality = Self.compared()
        (quality.all.waited, quality.all.waitedSpan, quality.all.auditWaited) = (2, 14_460, 1446)
        quality.all.verifierHours = 1.25
        let page = QualityPage(quality, calendar: Self.utc)
        func figure(_ label: String) throws -> StatisticsPage.Figure { try #require(page.sections.flatMap(\.figures).first { $0.label == label }) }
        #expect(try figure("Waiting for its audit").value == "10%")
        #expect(try figure("Waiting for its audit").detail == "of created → merged, over 2 merges whose waits are kept")
        #expect(try figure("Worker working").value == "37%" && figure("The rest").value == "53%")
        #expect(try figure("Verifier hours").value == StatisticsPage.hours(1.25))
        #expect(try figure("Project lead").value == "$1.50" && figure("Project lead").detail == "2.4M tokens")
        #expect(try figure("Codex tokens").value == "1.5M" && figure("Codex tokens").detail == "not in the cost: Codex has no price here")
        #expect(try figure("Merge reruns").value == "Not recorded", "receipts still don't price a rerun")
        // Not kept: said so.
        var bare = QualityFigures()
        bare.merged = 1
        let kept = QualityPage(SetupQuality(all: bare, byAgent: [], byModel: [], weeks: []), calendar: Self.utc).sections.flatMap(\.figures)
        for label in ["Waiting for its audit", "Verifier hours", "Project lead", "Codex tokens"] {
            #expect(kept.first { $0.label == label }?.value == "Not recorded", "\(label)")
        }
        // The lead's days without a price: what's known, marked at least.
        #expect(QualityPage.lead(LeadSpend(tokens: 5000, cost: 2, unpricedDays: 1)).value == "≥ $2.00")
        #expect(QualityPage.lead(LeadSpend(tokens: 5000, cost: nil, unpricedDays: 3)).value == "Not recorded")
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
