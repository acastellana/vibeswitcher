import Foundation
import Testing
@testable import VibeCore

/// `SetupStatsCollector`: the statistics page's numbers, from fixture folders in a scratch home and scratch projects
/// (never the real ~/.vibeswitcher or a real project's board). Its per-project and Mac-wide figures match
/// scripts/impact-metrics.sh's and scripts/load-report.sh's on the same fixtures (Tests/Fixtures/impact-metrics, times
/// in UTC), each run here beside it.
struct SetupStatsTests {
    let temp = Scratch()
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// 2026-10-20, the fixtures' day, in UTC.
    static let fixtureDay = DateInterval(start: date(2026, 10, 20), end: date(2026, 10, 21))

    /// A project folder `proj` and a VibeSwitcher home laid out from the fixtures, in this suite's scratch (as
    /// ImpactMetricsScriptTests lays them out).
    func layout() throws -> (project: URL, home: URL) {
        let root = temp.url("setup-stats")
        let project = root.appendingPathComponent("proj"), home = root.appendingPathComponent("home")
        let fm = FileManager.default, fixtures = ImpactMetricsScriptTests.fixtures
        let board = project.appendingPathComponent(".vibeswitcher"), lead = project.appendingPathComponent("docs/lead")
        for folder in [board, lead, home] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        for name in ["board.json", "board-archive.jsonl"] { try fm.copyItem(at: fixtures.appendingPathComponent(name), to: board.appendingPathComponent(name)) }
        for name in ["progress.md", "incidents.md"] { try fm.copyItem(at: fixtures.appendingPathComponent(name), to: lead.appendingPathComponent(name)) }
        for name in ["stats", "debug"] { try fm.copyItem(at: fixtures.appendingPathComponent(name), to: home.appendingPathComponent(name)) }
        return (project, home)
    }

    func collector(home: URL, codexHome: URL? = nil, now: Date = Date()) -> SetupStatsCollector {
        SetupStatsCollector(home: home, codexHome: codexHome, calendar: Self.utc, now: { now })
    }

    /// load-report.sh's output for `days` on `home`, in UTC.
    func loadReport(home: URL, _ days: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [KeychainLintTests.repo.appendingPathComponent("scripts/load-report.sh").path, "--home", home.path] + days
        var environment = ProcessInfo.processInfo.environment
        environment["TZ"] = "UTC"
        environment.removeValue(forKey: "VIBESWITCHER_HOME")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output
    }

    static func format(_ value: Double?, _ digits: Int = 2) -> String { value.map { String(format: "%.\(digits)f", $0) } ?? "n/a" }

    @Test func itMatchesImpactMetricsOnTheFixtureDay() async throws {
        let script = ImpactMetricsScriptTests()
        let (project, home) = try layout()
        let run = try script.metrics(["2026-10-20..2026-10-20", "--project", project.path, "--home", home.path])
        #expect(run.status == 0, "\(run.output)")
        let out = run.output
        let stats = await collector(home: home).collect(projects: [project.path], range: Self.fixtureDay)

        #expect(stats.projects.map(\.name) == ["proj"])
        let p = try #require(stats.projects.first?.figures)
        #expect(stats.projects.first?.hasArchive == true)
        // alpha (board), beta (archive only), gamma (board); delta the day before.
        #expect(p.merged == 3)
        #expect(script.value(out, "merges/h")?.hasPrefix("0.12 (\(p.merged) merges in 24.0 h") == true, "\(out)")
        // Starts to merges: 120, 60 and 180 min.
        #expect(p.startToMerge.count == 3)
        #expect(p.medianStartToMerge == 7200)
        #expect(script.value(out, "median start-to-merge")
            == "\(Self.format(p.medianStartToMerge.map { $0 / 3600 }, 1)) h (\(p.startToMerge.count) of \(p.merged) merges have a start)")
        #expect(p.audited == 2 && p.auditRounds == 3 && p.importantFindings == 3)
        #expect(script.value(out, "audit rounds per audited task")
            == "\(Self.format(p.roundsPerAudited)) (\(p.auditRounds) rounds over \(p.audited) audited of \(p.merged) merges)")
        #expect(script.value(out, "Important findings per task")
            == "\(Self.format(p.importantPerMerge)) (\(p.importantFindings) over \(p.merged) merges; \(Self.format(Double(p.importantFindings) / Double(p.audited))) per audited task)")
        #expect(p.reverts == 1)
        #expect(script.value(out, "reverts")?.hasPrefix("\(p.reverts) ") == true)
        // alpha passed on the rerun; the ledger's flakes on the day are alpha's two.
        let flakes = try #require(p.flakes)
        #expect(p.mergeReruns == 1 && p.mergesWithReceipt == 3 && flakes == ProjectFigures.Flakes(flakes: 2, tests: 2, merges: 1))
        #expect(script.value(out, "flaky-merge rate")
            == "\(Self.format(p.flakyMergeRate.map { $0 * 100 }, 0))% (\(p.mergeReruns) of \(p.mergesWithReceipt) merges with a receipt passed only on the rerun; flake ledger: \(flakes.flakes) flakes of \(flakes.tests) tests in \(flakes.merges) merges)")
        // Receipts ended on the day: alpha, beta, gamma, epsilon (abandoned); gamma's cost is unknown.
        #expect(p.ended == 4 && p.workerHours == 3.5)
        #expect(script.value(out, "worker hours") == "\(Self.format(p.workerHours, 1)) h (\(p.ended) tasks ended with a receipt)")
        #expect(p.costed == 3 && p.cost == 7)
        #expect(script.value(out, "estimated cost per task")
            == "$\(Self.format(p.costPerTask)) ($\(Self.format(p.cost)) over \(p.costed) receipts with a known cost)")
        // What the script doesn't print: epsilon abandoned; none folded or failed; every task ended on Claude.
        #expect(p.abandoned == 1 && p.folded == 0 && p.failed == 0)
        #expect(p.codexTasks == 0 && p.claudeTasks == 4 && p.codexShare == 0)
        // The fixtures' receipts carry costs but no token counts: not recorded. Verifier hours: never recorded.
        #expect(p.workerTokens == nil && p.verifierTokens == nil && p.verifierHours == nil)
        #expect(stats.total == p)

        // Mac-wide: freezes at 05:00, 10:00:30 (a .txt and a .log: one), 10:30, 20:00.
        let freezes = try #require(stats.mac.freezes)
        #expect(freezes.count == 4 && freezes.hours == 24 && !freezes.partial)
        #expect(script.value(out, "freezes/h") == "\(Self.format(freezes.perHour)) (\(freezes.count) hang reports in 24.0 h)")
        #expect(freezes.perDay == ["2026-10-20": 4])
        let buckets = try #require(freezes.byLoad)
        #expect(buckets == [Freezes.LoadBucket(name: "24-36", minutes: 60, freezes: 2), Freezes.LoadBucket(name: "48-72", minutes: 120, freezes: 1)])
        for bucket in buckets {
            let line = "    \(bucket.name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(String(repeating: " ", count: max(0, 6 - Self.format(bucket.perHour).count)))\(Self.format(bucket.perHour))  (\(bucket.freezes) / \(Self.format(Double(bucket.minutes) / 60, 1)) h)"
            #expect(out.contains(line), "\(line) in \(out)")
        }
        #expect(freezes.unsampled == 1)
        #expect(out.contains("    unsampled \(freezes.unsampled) (no load sample within 2 minutes)"))
    }

    @Test func itMatchesLoadReportOnTheFixtureDay() async throws {
        let (_, home) = try layout()
        let out = try loadReport(home: home, ["2026-10-20", "2026-10-20"])
        let stats = await collector(home: home).collect(projects: [], range: Self.fixtureDay)
        // 10:00–10:59 at load 30, 20:00–21:59 at 50.
        let load = try #require(stats.mac.load)
        #expect(load == LoadProfile(minutes: 180, median: 50, p90: 50, max: 50, minutesAt24: 180, minutesAt36: 120, cores: 12))
        #expect(out.contains("Samples: \(load.minutes) minutes (3.0 h); 1-min load median \(Self.format(load.median, 1)), p90 \(Self.format(load.p90, 1)), max \(Self.format(load.max, 1)); 12 cores"), "\(out)")
        // The day's five merge lines (one a conflict), four landed, over 24 hours.
        let merges = try #require(stats.mac.merges)
        #expect(merges.recorded == 5 && merges.landed == 4 && merges.hours == 24)
        #expect(stats.total == nil && stats.projects.isEmpty)
    }

    @Test func aRangeOfHoursCountsOnlyThoseHours() async throws {
        let script = ImpactMetricsScriptTests()
        let (project, home) = try layout()
        let stats = await collector(home: home).collect(projects: [project.path],
                                                        range: DateInterval(start: Self.date(2026, 10, 20, 9, 30), end: Self.date(2026, 10, 20, 12, 30)))
        // alpha (10:00) and beta (12:00); freezes at 10:00:30 and 10:30 (impact-metrics' own expectations).
        #expect(stats.projects.first?.figures?.merged == 2)
        #expect(stats.mac.freezes?.count == 2 && stats.mac.freezes?.hours == 3)
        // Merge lines at 10:00 (passed on rerun), 11:00 (passed), 12:00 (a conflict).
        #expect(stats.mac.merges?.recorded == 3 && stats.mac.merges?.landed == 2)
    }

    @Test func hoursBeforeTheOldestHangReportArentCounted() async throws {
        let (_, home) = try layout()
        // From 2026-10-19 12:00: the oldest report is 23:00, so 13 h are counted, as impact-metrics.sh counts them.
        let partial = await collector(home: home).collect(projects: [], range: DateInterval(start: Self.date(2026, 10, 19, 12), end: Self.date(2026, 10, 20, 12)))
        #expect(partial.mac.freezes?.count == 4 && partial.mac.freezes?.hours == 13 && partial.mac.freezes?.partial == true)
        // A day before every report left: not recorded.
        let pruned = await collector(home: home).collect(projects: [], range: DateInterval(start: Self.date(2026, 10, 18), end: Self.date(2026, 10, 19)))
        #expect(pruned.mac.freezes == nil)
    }

    @Test func theDefaultRangeIsTheLastSevenDaysAndToday() {
        let range = SetupStatsCollector.defaultRange(now: Self.date(2026, 11, 2, 15), calendar: Self.utc)
        #expect(range == DateInterval(start: Self.date(2026, 10, 26), end: Self.date(2026, 11, 3)))
        let collector = collector(home: temp.url("home"))
        #expect(collector.days(range) == ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02"])
    }

    // MARK: Per project, beyond the scripts

    /// A scratch project `name` whose board holds `tasks` (and `flakes`, when given), with `archive` lines.
    func project(_ name: String, tasks: [[String: Any]], archive: [String]? = nil, flakes: [[String: Any]]? = nil, in root: URL) throws -> URL {
        let folder = root.appendingPathComponent(name).appendingPathComponent(".vibeswitcher")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var board: [String: Any] = ["tasks": tasks, "questions": [], "updates": []]
        if let flakes { board["flakes"] = flakes }
        try JSONSerialization.data(withJSONObject: board).write(to: folder.appendingPathComponent("board.json"))
        if let archive { try (archive.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("board-archive.jsonl"), atomically: true, encoding: .utf8) }
        return root.appendingPathComponent(name)
    }

    static func task(_ slug: String, status: String = "done", at: Double, extra: [String: Any] = [:]) -> [String: Any] {
        var task: [String: Any] = ["id": slug.uppercased(), "slug": slug, "title": slug, "status": status, "createdAt": at - 7200,
                                   "contract": ["goal": "g", "acceptance": [], "boundaries": [], "context": ""]]
        for (key, value) in extra { task[key] = value }
        return task
    }

    static func receipt(ending: String = "merged", started: Double, ended: Double, worked: Double = 3600, tokens: Int? = nil, cost: Double = 1) -> [String: Any] {
        var worker: [String: Any] = ["cost": cost, "models": ["claude-opus-5-5"]]
        if let tokens { worker.merge(["input": tokens, "output": 0, "cacheRead": 0, "cacheWrite": 0]) { $1 } }
        return ["ending": ending, "startedAt": started, "endedAt": ended, "worked": worked, "rounds": 0, "rerolls": 0, "mergeReruns": 0,
                "questions": 0, "waitingOnUser": 0, "pricesAsOf": "2026-10-06", "worker": worker]
    }

    @Test func itCountsEndingsTokensAndTheCodexShareAndSumsTheProjects() async throws {
        let root = temp.url("projects")
        let at = Self.date(2026, 10, 20, 12).timeIntervalSince1970
        let one = try project("one", tasks: [
            Self.task("a", at: at, extra: ["startedAt": at - 3600, "merged": ["commit": "c", "tested": true, "at": at],
                                           "codexWorked": true, "receipt": Self.receipt(started: at - 3600, ended: at, tokens: 1000)]),
            Self.task("b", status: "folded", at: at, extra: ["receipt": Self.receipt(ending: "folded", started: at - 600, ended: at, tokens: 500)]),
            Self.task("c", status: "failed", at: at, extra: ["since": at]),
            Self.task("d", status: "failed", at: at, extra: ["since": at - 30 * 86_400]),
        ], in: root)
        let two = try project("two", tasks: [
            Self.task("e", at: at, extra: ["agent": "codex", "startedAt": at - 7200, "merged": ["commit": "c", "tested": true, "at": at + 60],
                                           "receipt": Self.receipt(started: at - 7200, ended: at + 60)]),
            Self.task("f", status: "abandoned", at: at, extra: ["since": at + 120]),
        ], in: root)
        // Not a project with a board: left out. A worktree path counts as its repository, once.
        let bare = root.appendingPathComponent("bare")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        let stats = await collector(home: temp.url("home")).collect(
            projects: [one.path, bare.path, one.appendingPathComponent(".vibeswitcher/worktrees/x").path, two.path], range: Self.fixtureDay)
        #expect(stats.projects.map(\.name) == ["one", "two"])
        #expect(stats.projects.allSatisfy { !$0.hasArchive })
        let first = try #require(stats.projects[0].figures), second = try #require(stats.projects[1].figures)
        #expect(first.merged == 1 && first.folded == 1 && first.failed == 1 && first.abandoned == 0)
        #expect(first.workerTokens == 1500 && first.verifierTokens == nil && first.ended == 2)
        #expect(first.codexTasks == 1 && first.claudeTasks == 1 && first.codexShare == 0.5)
        #expect(first.flakes == nil, "the board keeps no flake ledger: not recorded")
        #expect(second.merged == 1 && second.abandoned == 1 && second.codexTasks == 1 && second.workerTokens == nil)
        let total = try #require(stats.total)
        #expect(total.merged == 2 && total.folded == 1 && total.failed == 1 && total.abandoned == 1)
        #expect(total.codexTasks == 2 && total.claudeTasks == 1 && total.workerTokens == 1500)
        #expect(total.startToMerge.sorted() == [3600, 7260] && total.medianStartToMerge == 5430)
        #expect(total.cost == 3 && total.costed == 3)
    }

    // MARK: Failing soft

    @Test func missingOrUnreadableFilesAreNotRecordedAndStopNothingElse() async throws {
        let root = temp.url("soft")
        let home = root.appendingPathComponent("home")
        let stats = home.appendingPathComponent("stats"), debug = home.appendingPathComponent("debug")
        for folder in [stats, debug] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        // A board that isn't JSON, beside a good one whose archive has a line cut short.
        let broken = root.appendingPathComponent("broken/.vibeswitcher")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "{ not json".write(to: broken.appendingPathComponent("board.json"), atomically: true, encoding: .utf8)
        let at = Self.date(2026, 10, 20, 12).timeIntervalSince1970
        let merged = Self.task("m", at: at, extra: ["merged": ["commit": "c", "tested": true, "at": at]])
        let line = String(decoding: try JSONSerialization.data(withJSONObject: merged), as: UTF8.self)
        let good = try project("good", tasks: [], archive: [line, "{\"id\": \"CUT", "[1, 2]"], in: root)
        // Recorder files: garbage lines, a line with no stamp, one good merge line.
        try "garbage\n{\"load\": [30]}\n".write(to: stats.appendingPathComponent("load-2026-10-20.jsonl"), atomically: true, encoding: .utf8)
        try "{\"t\": \"2026-10-20T09:00:00+00:00\", \"result\": \"passed\"}\nnope\n".write(to: stats.appendingPathComponent("merges-2026-10-20.jsonl"), atomically: true, encoding: .utf8)
        try "x".write(to: debug.appendingPathComponent("hang-not-a-stamp.txt"), atomically: true, encoding: .utf8)
        for name in ["boost.json", "account-usage.json"] { try "{".write(to: home.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let codex = root.appendingPathComponent("codex")

        let result = await collector(home: home, codexHome: codex, now: Self.date(2026, 10, 21)).collect(
            projects: [broken.deletingLastPathComponent().path, good.path], range: Self.fixtureDay)
        #expect(result.projects.map(\.name) == ["broken", "good"])
        #expect(result.projects[0].figures == nil)
        #expect(result.projects[1].figures?.merged == 1 && result.projects[1].hasArchive)
        #expect(result.total?.merged == 1)
        #expect(result.mac.load == nil, "no sample reads: not recorded")
        #expect(result.mac.merges == MergeRate(recorded: 1, landed: 1, hours: 24))
        // A debug folder with no report: the last week is covered, freeze-free.
        #expect(result.mac.freezes?.count == 0 && result.mac.freezes?.byLoad == nil)
        #expect(result.mac.boostNow == nil && result.mac.claude == nil && result.mac.codex == nil)
        #expect(result.mac.hoursBoosted == nil && result.mac.codexTokens == nil)

        // No home at all, no projects: every Mac-wide figure not recorded.
        let empty = await collector(home: root.appendingPathComponent("none")).collect(projects: [], range: Self.fixtureDay)
        #expect(empty.mac == SetupStats.MacWide() && empty.total == nil)
    }

    // MARK: Usage and boost now

    @Test func itReadsBothAccountsUsageWithPaceAndBoostNow() async throws {
        let root = temp.url("usage")
        let home = root.appendingPathComponent("home"), codex = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let now = Self.date(2026, 11, 2, 12)
        let seconds = now.timeIntervalSince1970
        // Claude weekly at 64 % with half the week gone: 14 points ahead of pace.
        let limits: [String: Any] = ["limits": [["name": "seven_day", "usedPercent": 64.0, "resetsAt": seconds + 3.5 * 86_400, "at": seconds - 60, "reached": false]]]
        try JSONSerialization.data(withJSONObject: limits).write(to: home.appendingPathComponent("account-usage.json"))
        // Codex weekly at 40 % with a quarter gone.
        let day = codex.appendingPathComponent("sessions/2026/11/02")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let event: [String: Any] = ["timestamp": "2026-11-02T11:59:00Z", "type": "event_msg", "payload": [
            "type": "token_count", "rate_limits": ["limit_id": "codex", "primary": ["used_percent": 40.0, "window_minutes": 10080, "resets_at": seconds + 5.25 * 86_400],
                                                   "secondary": NSNull()]]]
        try (String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n").write(to: day.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)
        try BoostState(on: true, why: "automatic: away, on AC", at: seconds - 30).save(to: home.appendingPathComponent("boost.json"))

        let stats = await collector(home: home, codexHome: codex, now: now).collect(projects: [])
        let claude = try #require(stats.mac.claude?.first)
        #expect(claude.name == "seven_day" && claude.usedPercent == 64 && !claude.reached)
        #expect(claude.pace.elapsed == 50 && claude.pace.ahead == 14)
        let window = try #require(stats.mac.codex?.first)
        #expect(window.name == "weekly" && window.usedPercent == 40 && window.pace.elapsed == 25 && window.pace.ahead == 15)
        #expect(stats.mac.boostNow?.on == true)
        #expect(stats.mac.hoursBoosted == nil, "nothing records boost's history")
        #expect(stats.range == SetupStatsCollector.defaultRange(now: now, calendar: Self.utc))
    }

    // MARK: Off the main thread, cached, bounded

    @MainActor @Test func itWorksOffTheMainThread() async throws {
        let (project, home) = try layout()
        let collector = collector(home: home)
        let stats = await collector.collect(projects: [project.path], range: Self.fixtureDay)
        #expect(stats.projects.first?.figures?.merged == 3)
        #expect(collector.mainThreadRuns == 0)
        let heard = DispatchSemaphore(value: 0)
        let onMain = LockedFlag()
        collector.collect(projects: [project.path], range: Self.fixtureDay) { _ in
            onMain.set(Thread.isMainThread)
            heard.signal()
        }
        // Waiting off the main thread for the reply (a semaphore, never a sleep).
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { heard.wait(); continuation.resume() }
        }
        #expect(onMain.value == false)
        #expect(collector.mainThreadRuns == 0)
    }

    @Test func filesAreParsedAgainOnlyWhenTheyChange() async throws {
        let (project, home) = try layout()
        let collector = collector(home: home)
        let first = await collector.collect(projects: [project.path], range: Self.fixtureDay)
        let parses = collector.parses
        #expect(parses > 0)
        let again = await collector.collect(projects: [project.path], range: Self.fixtureDay)
        #expect(collector.parses == parses, "nothing changed: everything from the cache")
        #expect(again.projects == first.projects && again.mac == first.mac)
        // A task archived since (an append changes the archive's size): that file alone is read again.
        let at = Self.date(2026, 10, 20, 18).timeIntervalSince1970
        let task = Self.task("late", at: at, extra: ["merged": ["commit": "l", "tested": true, "at": at]])
        let handle = try FileHandle(forWritingTo: project.appendingPathComponent(".vibeswitcher/board-archive.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8) + JSONSerialization.data(withJSONObject: task) + Data("\n".utf8))
        try handle.close()
        let changed = await collector.collect(projects: [project.path], range: Self.fixtureDay)
        #expect(collector.parses == parses + 1)
        #expect(changed.projects.first?.figures?.merged == 4)
    }

    @Test func largeFilesAreStreamedWithinATimeBound() async throws {
        let root = temp.url("large")
        let home = root.appendingPathComponent("home"), stats = home.appendingPathComponent("stats")
        try FileManager.default.createDirectory(at: stats, withIntermediateDirectories: true)
        let start = Self.date(2026, 10, 26).timeIntervalSince1970
        // 20,000 archived merges over the 8 days, each with a receipt, a long contract and a line cut short among them.
        var archive: [String] = []
        let padding = String(repeating: "x", count: 400)
        for index in 0..<20_000 {
            let at = start + Double(index) * 34
            archive.append(#"{"id":"T\#(index)","slug":"t\#(index)","title":"t","status":"done","createdAt":\#(at - 600),"contract":{"goal":"\#(padding)","acceptance":[],"boundaries":[],"context":""},"startedAt":\#(at - 600),"merged":{"commit":"c","tested":true,"at":\#(at)},"receipt":{"ending":"merged","startedAt":\#(at - 600),"endedAt":\#(at),"worked":600,"mergeReruns":0,"worker":{"cost":1,"input":10,"output":0,"cacheRead":0,"cacheWrite":0}}}"#)
        }
        archive.insert(#"{"id":"CUT","slug":"#, at: 10_000)
        let project = try project("big", tasks: [], archive: archive, in: root)
        // A sample a minute for the 8 days.
        let range = DateInterval(start: Date(timeIntervalSince1970: start), duration: 8 * 86_400)
        let stamps = ISO8601DateFormatter()
        for day in 0..<8 {
            var lines = ""
            for minute in 0..<1440 {
                let at = Date(timeIntervalSince1970: start + Double(day * 86_400 + minute * 60))
                lines += #"{"t":"\#(stamps.string(from: at))","load":[\#(minute % 60),1,1],"cores":12,"sessions":[],"heavy":{"slots":3,"held":[]},"cost_ms":1}"# + "\n"
            }
            try lines.write(to: stats.appendingPathComponent("load-\(SetupStatsCollector(home: home, codexHome: nil, calendar: Self.utc).days(range)[day]).jsonl"),
                            atomically: true, encoding: .utf8)
        }
        let clock = ContinuousClock()
        let began = clock.now
        let result = await collector(home: home, now: range.end).collect(projects: [project.path], range: range)
        let took = clock.now - began
        #expect(result.projects.first?.figures?.merged == 20_000)
        #expect(result.projects.first?.figures?.workerTokens == 200_000)
        #expect(result.mac.load?.minutes == 8 * 1440)
        #expect(result.mac.load?.minutesAt24 == 8 * 24 * 36)
        // Generous for a loaded Mac and a debug build; a whole-file reread per figure or a quadratic join would blow it.
        #expect(took < .seconds(60), "took \(took)")
    }

    @Test func aLineOverTheLimitIsPassedOver() throws {
        let file = temp.url("long")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let path = file.appendingPathComponent("lines.jsonl").path
        let long = "{\"id\": \"" + String(repeating: "y", count: SetupStatsCollector.maxLine + 10) + "\"}"
        try ("{\"id\": \"a\"}\n" + long + "\n{\"id\": \"b\"}").write(toFile: path, atomically: true, encoding: .utf8)
        let lines = try #require(SetupStatsCollector.jsonLines(path))
        #expect(lines.map { String(($0["id"] as? String ?? "").prefix(8)) } == ["a", "b"])
        #expect(SetupStatsCollector.jsonLines(file.appendingPathComponent("none").path) == nil)
    }
}

/// A flag set on one thread and read on another.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    func set(_ value: Bool) { lock.withLock { stored = value } }
    var value: Bool? { lock.withLock { stored } }
}
