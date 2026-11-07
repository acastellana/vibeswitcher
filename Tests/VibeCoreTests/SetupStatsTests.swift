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
    func loadReport(home: URL, _ days: [String]) async throws -> String {
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
        // The tool's run read to its end and waited for on a thread of its own, not the cooperative pool.
        let output = await offPool { () -> String in
            let read = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            waitForEnd(process)
            return read
        }
        return output
    }

    static func format(_ value: Double?, _ digits: Int = 2) -> String { value.map { String(format: "%.\(digits)f", $0) } ?? "n/a" }

    @Test func itMatchesImpactMetricsOnTheFixtureDay() async throws {
        let script = ImpactMetricsScriptTests()
        let (project, home) = try layout()
        let run = try await script.metrics(["2026-10-20..2026-10-20", "--project", project.path, "--home", home.path])
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
        let out = try await loadReport(home: home, ["2026-10-20", "2026-10-20"])
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

    // MARK: What's recorded since receipts, the recorder and the leads' ledger kept more

    @Test func itReadsWaitsCodexTokensBoostAndLeadTokensWhereRecordedAndNotBefore() async throws {
        let root = temp.url("recorded")
        let home = root.appendingPathComponent("home"), stats = home.appendingPathComponent("stats")
        try FileManager.default.createDirectory(at: stats, withIntermediateDirectories: true)
        let at = Self.date(2026, 10, 20, 12).timeIntervalSince1970
        var newer = Self.receipt(started: at - 7200, ended: at, tokens: 1000)
        newer["worker"] = ["cost": 1.0, "input": 1000, "output": 0, "cacheRead": 0, "cacheWrite": 0, "codex": 400, "models": ["gpt-6.1-sol"]]
        newer["waitingOnUser"] = 360
        newer["waits"] = ["auditWait": 1800, "auditing": 3600, "verifierTime": 7200, "mergeLoadWait": 600, "mergeSlotWait": 1200, "mergeTesting": 900]
        var outside = newer
        outside["endedAt"] = at - 3 * 86_400
        let one = try project("one", tasks: [
            Self.task("a", at: at, extra: ["codexWorked": true, "merged": ["commit": "c", "tested": true, "at": at], "receipt": newer]),
            // A receipt from before: none of the new figures, and nothing it lacks counted as zero but the user's wait.
            Self.task("b", at: at, extra: ["merged": ["commit": "c", "tested": true, "at": at], "receipt": Self.receipt(started: at - 600, ended: at)]),
            Self.task("c", at: at, extra: ["receipt": outside]),
        ], in: root)
        // The lead's ledger: the range's day, a day before it, and an unpriced day after it.
        let ledger: [String: Any] = ["since": at - 5 * 86_400, "at": at, "files": [:], "days": [
            "2026-10-20": ["input": 100, "output": 50, "cacheRead": 1000, "cacheWrite": 0, "cacheWrite1h": 0, "cost": 0.5, "models": [:], "sessions": []],
            "2026-10-19": ["input": 9999, "output": 0, "cacheRead": 0, "cacheWrite": 0, "cacheWrite1h": 0, "cost": 9.0, "models": [:], "sessions": []],
            "2026-10-21": ["input": 7, "output": 0, "cacheRead": 0, "cacheWrite": 0, "cacheWrite1h": 0, "cost": 0, "unpriced": ["x"], "models": [:], "sessions": []]]]
        try JSONSerialization.data(withJSONObject: ledger).write(to: one.appendingPathComponent(".vibeswitcher/lead-tokens.json"))
        // A project whose ledger began after the range: its lead's tokens not recorded for it; one with none at all.
        let two = try project("two", tasks: [], in: root)
        let late: [String: Any] = ["since": at + 2 * 86_400, "at": at + 2 * 86_400, "files": [:], "days": [:]]
        try JSONSerialization.data(withJSONObject: late).write(to: two.appendingPathComponent(".vibeswitcher/lead-tokens.json"))
        let three = try project("three", tasks: [], in: root)
        // Load lines: three boosted minutes, one not, and one from before the flag.
        let lines = (0..<5).map { minute -> String in
            let flag = minute < 3 ? ", \"boost\": true" : minute == 3 ? ", \"boost\": false" : ""
            return "{\"t\": \"2026-10-20T10:0\(minute):00+00:00\", \"load\": [10, 9, 8], \"cores\": 16\(flag)}"
        }
        try (lines.joined(separator: "\n") + "\n").write(to: stats.appendingPathComponent("load-2026-10-20.jsonl"), atomically: true, encoding: .utf8)

        let result = await collector(home: home).collect(projects: [one.path, two.path, three.path], range: Self.fixtureDay)
        let first = try #require(result.projects.first { $0.name == "one" }?.figures)
        #expect(first.ended == 2 && first.codexTokens == 400)
        #expect(first.verifierHours == 2 && first.auditWaitHours == 0.5 && first.auditingHours == 1)
        #expect(first.mergeWaitHours == 0.5 && first.mergeTestHours == 0.25 && first.userWaitHours == 0.1)
        #expect(first.leadTokens == 1150 && first.leadCost == 0.5 && first.leadUnpricedDays == 0)
        let second = try #require(result.projects.first { $0.name == "two" }?.figures)
        let third = try #require(result.projects.first { $0.name == "three" }?.figures)
        for figures in [second, third] {
            #expect(figures.leadTokens == nil && figures.leadCost == nil && figures.codexTokens == nil && figures.verifierHours == nil)
            #expect(figures.auditWaitHours == nil && figures.userWaitHours == nil)
        }
        let total = try #require(result.total)
        #expect(total.codexTokens == 400 && total.leadTokens == 1150 && total.verifierHours == 2)
        #expect(result.mac.codexTokens == 400)
        #expect(result.mac.hoursBoosted == 3.0 / 60)
        // Its earlier figures as they were.
        #expect(first.merged == 2 && first.workerTokens == 1000 && first.cost == 2 && first.workerHours == 2)

        // A range with an unpriced day: its tokens counted, its cost not known.
        let next = DateInterval(start: Self.date(2026, 10, 21), end: Self.date(2026, 10, 22))
        let later = await collector(home: home).collect(projects: [one.path], range: next)
        let figures = try #require(later.projects.first?.figures)
        #expect(figures.leadTokens == 7 && figures.leadCost == nil && figures.leadUnpricedDays == 1)
        #expect(later.mac.hoursBoosted == nil, "no sample in the range says")
    }

    @Test func aMergesLinesFirstRunIsReadAsTheRecorderWritesItATasksOwnFirst() throws {
        let stamps = StampParser(calendar: Self.utc)
        func line(_ json: String) throws -> RecorderLine {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return try #require(RecorderLine(object, stamps: stamps))
        }
        #expect(try line(#"{"t":"2026-10-20T09:00:00+00:00","task":"a","first_run":"failed","result":"passed_on_rerun"}"#).firstRun == "failed")
        // A batch's shared first run failed, this task's own passed: its own counts.
        #expect(try line(#"{"t":"2026-10-20T09:00:00+00:00","task":"a","first_run":"failed","task_first_run":"passed","batch":"b"}"#).firstRun == "passed")
        #expect(try line(#"{"t":"2026-10-20T09:00:00+00:00","task":"a","firstRun":"passed"}"#).firstRun == "passed")
        #expect(try line(#"{"t":"2026-10-20T09:00:00+00:00","task":"a"}"#).firstRun == nil)
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
        // A hand-edited line with numbers no Int holds: read, those figures absent, never a trap.
        let huge = #"{"id": "H", "status": "done", "score": {"rounds": 1e300, "importantFindings": -1e300}, "receipt": {"endedAt": 0, "mergeReruns": 1e300, "worker": {"input": 1e300}}}"#
        let good = try project("good", tasks: [], archive: [line, "{\"id\": \"CUT", "[1, 2]", huge], in: root)
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

    /// Streaming is checked by the reads the collector makes, not by a clock: each file read through once, in reads
    /// of at most `readSize`, and not again while unchanged. The time limit is only a hang guard.
    @Test(.timeLimit(.minutes(10))) func largeFilesAreStreamedReadOnceInBoundedReads() async throws {
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
        var loadFiles: [String] = []
        for day in 0..<8 {
            var lines = ""
            for minute in 0..<1440 {
                let at = Date(timeIntervalSince1970: start + Double(day * 86_400 + minute * 60))
                lines += #"{"t":"\#(stamps.string(from: at))","load":[\#(minute % 60),1,1],"cores":12,"sessions":[],"heavy":{"slots":3,"held":[]},"cost_ms":1}"# + "\n"
            }
            let file = stats.appendingPathComponent("load-\(SetupStatsCollector(home: home, codexHome: nil, calendar: Self.utc).days(range)[day]).jsonl")
            try lines.write(to: file, atomically: true, encoding: .utf8)
            loadFiles.append(file.path)
        }
        let collector = collector(home: home, now: range.end)
        let result = await collector.collect(projects: [project.path], range: range)
        #expect(result.projects.first?.figures?.merged == 20_000)
        #expect(result.projects.first?.figures?.workerTokens == 200_000)
        #expect(result.mac.load?.minutes == 8 * 1440)
        #expect(result.mac.load?.minutesAt24 == 8 * 24 * 36)

        // The collector names the archive by its standardized repository path.
        let archivePath = ((project.path as NSString).standardizingPath as NSString).appendingPathComponent(".vibeswitcher/board-archive.jsonl")
        let files = [archivePath] + loadFiles
        func size(_ path: String) throws -> Int { try #require(FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) }
        #expect(try size(archivePath) > 8 * SetupStatsCollector.readSize, "the archive spans many reads")
        for path in files {
            let reads = collector.reads(of: path), bytes = try size(path)
            // Read through exactly once (no whole-file reread per figure), a bounded read at a time (never slurped).
            #expect(reads.bytes == bytes, "\(path): \(reads.bytes) bytes read of \(bytes)")
            #expect(reads.largest <= SetupStatsCollector.readSize, "\(path): a read of \(reads.largest) bytes")
            #expect(reads.calls >= (bytes + SetupStatsCollector.readSize - 1) / SetupStatsCollector.readSize, "\(path): \(reads.calls) reads")
        }
        // Unchanged files come from the cache: nothing read again.
        let before = files.map { collector.reads(of: $0) }
        let again = await collector.collect(projects: [project.path], range: range)
        #expect(again.projects.first?.figures?.merged == 20_000)
        #expect(files.map { collector.reads(of: $0) } == before)
    }

    // MARK: Quality, autonomy, time and cost

    /// A merged task as the board keeps it: created 2 h before `at`, started 1 h before, merged at `at`.
    static func merged(_ slug: String, at: Double, codex: Bool = false, model: String? = nil) -> LeadTask {
        var task = LeadTask(id: slug.uppercased(), slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""),
                            status: .done)
        task.createdAt = at - 7200
        task.startedAt = at - 3600
        task.worker = "w-\(slug)"
        task.merged = LeadMergeRecord(commit: "c-\(slug)", tested: true, at: at)
        if codex {
            task.codexWorked = true
            task.launched(["w-\(slug)"], on: "codex")
        } else if let model {
            task.launched(["w-\(slug)"], on: model)
        }
        return task
    }

    static func tokens(cost: Double?) -> LeadTokens {
        var tokens = LeadTokens(input: 10, output: 1, cacheRead: 0, cacheWrite: 0, cacheWrite1h: 0, sessions: 1, models: ["claude-opus-5-5"])
        tokens.cost = cost
        return tokens
    }

    static func finding(_ id: String, _ severity: LeadFinding.Severity, _ status: LeadFinding.Status, closedBy: String? = nil,
                        followUp: String? = nil) -> LeadFinding {
        var finding = LeadFinding(id: id, severity: severity, file: "A.swift", line: id.count, evidence: "e", status: status, reason: nil, raised: 1)
        finding.closedBy = closedBy
        finding.followUp = followUp
        return finding
    }

    /// A scratch project `name` whose board.json is `board`, encoded as the app writes it.
    func project(_ name: String, board: LeadBoard, in root: URL) throws -> URL {
        let folder = root.appendingPathComponent(name).appendingPathComponent(".vibeswitcher")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(board).write(to: folder.appendingPathComponent("board.json"))
        return root.appendingPathComponent(name)
    }

    /// The hand-built board: on the fixture day, a (Claude on opus: audited, passed first, needed nobody), b (Claude on
    /// sonnet: two audits, a question, a lead message, a re-roll, a merge rerun, an incident after it) and c (Codex:
    /// unaudited, reverted, its cost unknown), an abandoned f; d two weeks before (the trend's).
    func qualityLayout() throws -> (project: URL, home: URL, at: Double) {
        let root = temp.url("quality")
        let at = Self.date(2026, 10, 20, 12).timeIntervalSince1970
        var a = Self.merged("a", at: at, model: "claude-opus-5-5")
        var ledger = LeadAuditLedger()
        ledger.rounds = 1
        ledger.passed = true
        ledger.findings = [Self.finding("F1", .important, .fixed, closedBy: "verifier"), Self.finding("F2", .nit, .open),
                           Self.finding("F3", .important, .unconfirmed)]
        a.audits = ledger
        a.receipt = LeadReceipt(ending: .merged, startedAt: at - 3600, endedAt: at, worked: 3600, worker: Self.tokens(cost: 2),
                                verifier: Self.tokens(cost: 1), rounds: 1)
        var b = Self.merged("b", at: at + 60, model: "sonnet")
        ledger = LeadAuditLedger()
        ledger.rounds = 2
        ledger.passed = true
        ledger.findings = [Self.finding("F1", .important, .dismissed, closedBy: "verifier"),
                           Self.finding("F2", .important, .dismissed, closedBy: "lead", followUp: "fix-x"),
                           Self.finding("F3", .nit, .dismissed, closedBy: "lead")]
        b.audits = ledger
        b.answers = [LeadFindingAnswer(id: "f1", kind: .disagree, reason: "not a bug", commit: nil, round: 1, at: at - 1000)]
        b.rerolls = [LeadReroll(archive: "agent/b-1", commit: nil, round: 1, at: at - 3000)]
        b.keep(LeadNote(kind: .message, text: "look at X", by: "lead of quality", at: at - 2000))
        b.receipt = LeadReceipt(ending: .merged, startedAt: at - 3000, endedAt: at + 60, worked: 1800, worker: Self.tokens(cost: 4),
                                verifier: Self.tokens(cost: 2), rounds: 2, rerolls: 1, mergeReruns: 1)
        var c = Self.merged("c", at: at + 120, codex: true)
        c.merged?.audited = false
        c.merged?.revertedBy = "r1"
        c.receipt = LeadReceipt(ending: .merged, startedAt: at - 600, endedAt: at + 120, worked: 600, worker: Self.tokens(cost: nil), verifier: nil)
        var d = Self.merged("d", at: Self.date(2026, 10, 10, 12).timeIntervalSince1970, model: "opus")
        ledger = LeadAuditLedger()
        ledger.rounds = 1
        ledger.passed = true
        d.audits = ledger
        d.receipt = LeadReceipt(ending: .merged, startedAt: nil, endedAt: d.merged!.at, worked: 600, worker: Self.tokens(cost: 5), verifier: nil)
        var f = LeadTask(id: "F", slug: "f", title: "f", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""), status: .abandoned)
        f.receipt = LeadReceipt(ending: .abandoned, startedAt: at - 1200, endedAt: at + 300, worked: 1200, worker: Self.tokens(cost: 1), verifier: nil)
        var board = LeadBoard()
        board.tasks = [a, b, c, d, f]
        var aboutB = LeadQuestion(id: "q1", text: "?", options: [], at: at - 1000)
        aboutB.task = "b"
        aboutB.answer = "yes"
        aboutB.answeredAt = at - 400
        var untasked = LeadQuestion(id: "q2", text: "?", options: [], at: at - 900)
        untasked.answer = "no"
        untasked.answeredAt = at - 600
        var before = LeadQuestion(id: "q3", text: "?", options: [], at: at - 20 * 86_400)
        before.answer = "old"
        before.answeredAt = before.askedAt + 6000
        board.questions = [aboutB, untasked, before]
        let project = try project("quality", board: board, in: root)
        // The incident about b, after it merged; one about a, before it merged.
        let lead = project.appendingPathComponent(".vibeswitcher")
        // Stamped in local time, as the lead's record_incident writes them.
        let after = LeadDecision.stamp(Date(timeIntervalSince1970: at + 6 * 3600)), earlier = LeadDecision.stamp(Date(timeIntervalSince1970: at - 4 * 3600))
        try ("# Incidents\n\n## \(after) b broke X\n\nEvidence: e\n\nTask: b\nCheck: task t.\n\n"
             + "## \(earlier) a stalled\n\nEvidence: e\n\nTask: a\n\n").write(to: lead.appendingPathComponent("incidents.md"), atomically: true, encoding: .utf8)
        // The merges recorder: a passed; b failed, then passed on the rerun; another project's a failed.
        let home = root.appendingPathComponent("home"), stats = home.appendingPathComponent("stats")
        try FileManager.default.createDirectory(at: stats, withIntermediateDirectories: true)
        try [#"{"t":"2026-10-20T11:55:00+00:00","project":"quality","task":"a","firstRun":"passed","result":"passed"}"#,
             #"{"t":"2026-10-19T10:00:00+00:00","project":"quality","task":"b","firstRun":"failed","result":"failed"}"#,
             #"{"t":"2026-10-20T11:59:00+00:00","project":"quality","task":"b","firstRun":"failed","result":"passed_on_rerun"}"#,
             #"{"t":"2026-10-20T09:00:00+00:00","project":"elsewhere","task":"a","firstRun":"failed","result":"failed"}"#]
            .joined(separator: "\n").write(to: stats.appendingPathComponent("merges-2026-10-20.jsonl"), atomically: true, encoding: .utf8)
        return (project, home, at)
    }

    @Test func itWorksOutQualityAutonomyTimeAndCost() async throws {
        let (project, home, at) = try qualityLayout()
        let stats = await collector(home: home, now: Self.date(2026, 10, 21)).collect(projects: [project.path], range: Self.fixtureDay)
        let quality = try #require(stats.quality)
        let all = quality.all
        // Quality: a and b audited (1 and 2 rounds), c merged with no audit.
        #expect(all.merged == 3 && all.audited == 2)
        #expect(all.firstAuditPassRate == 0.5 && all.meanRoundsToPass == 1.5)
        #expect(all.importantFindings == 3 && all.importantPerAudited == 1.5)
        #expect(all.findings == FindingOutcomes(fixed: 1, disagreementAccepted: 1, dismissedByVerifier: 0, dismissedByLead: 1, movedToTask: 1,
                                                leftOpen: 1, important: 3))
        #expect(all.findings?.total == 5)
        // b's first run (the day before) failed; c has no line.
        #expect(all.mergeFirstTry == MergeFirstTry(counted: 2, firstTry: 1))
        #expect(all.rerolls == 1 && all.reverts == 1)
        #expect(all.escapes == 2, "c reverted, b named by an incident after it merged (a's incident came before)")
        // Autonomy: b's question (10 min) and the untasked one in the range (5 min); the one before the range is not counted.
        #expect(all.questions == 2 && all.questionsPerMergedTask == 2.0 / 3)
        #expect(all.userMinutesPerMergedTask == 5)
        #expect(all.neededNobody == 2 && all.neededNobodyShare == 2.0 / 3)
        // Time: created 2 h before each merge.
        #expect(all.createdToMerged == [7200, 7200, 7200])
        #expect(all.medianCreatedToMerged == 7200 && all.p90CreatedToMerged == 7200)
        #expect(all.timed == 3 && all.timedSpan == 21_600 && all.timedWorked == 6000 && all.workingShare == 6000.0 / 21_600)
        #expect(all.auditWaitShare == nil, "not recorded")
        #expect(all.restShare == 1 - 6000.0 / 21_600)
        // a, b, c and the abandoned f ended in the range: 2 worker hours over 65 min of wall clock.
        #expect(all.workerHours == 2 && abs(all.busyHours - 3900.0 / 3600) < 1e-9)
        #expect(all.parallelism.map { abs($0 - 7200.0 / 3900) < 1e-9 } == true)
        // Cost: a and b (c's worker cost is unknown).
        #expect(all.costed == 2 && all.cost == 9 && all.workerCost == 6 && all.verifierCost == 3)
        #expect(all.costPerMergedTask == 4.5 && all.implementationShare == 6.0 / 9 && all.verificationShare == 3.0 / 9)
        #expect(all.mergeRerunCost == nil, "not recorded")
        // The definitions are the scorecard's: the same tasks through LeadScorecard give the same numbers.
        var board = try JSONDecoder().decode(LeadBoard.self, from: Data(contentsOf: project.appendingPathComponent(".vibeswitcher/board.json")))
        board.tasks.removeAll { !(at - 1 ... at + 200).contains($0.merged?.at ?? 0) }
        board.questions.removeAll { $0.id == "q3" }
        let card = LeadScorecard(board, now: Self.date(2026, 10, 21).timeIntervalSince1970)
        #expect(card.firstAuditPassRate == all.firstAuditPassRate && card.meanRoundsToPass == all.meanRoundsToPass)
        #expect(card.userMinutesPerMergedTask == all.userMinutesPerMergedTask && card.reverts == all.reverts)
    }

    @Test func itSplitsByAgentAndModel() async throws {
        let (project, home, _) = try qualityLayout()
        let stats = await collector(home: home, now: Self.date(2026, 10, 21)).collect(projects: [project.path], range: Self.fixtureDay)
        let quality = try #require(stats.quality)
        #expect(quality.byAgent.map(\.name) == ["Claude", "Codex"])
        let claude = quality.byAgent[0].figures, codex = quality.byAgent[1].figures
        #expect(claude.merged == 2 && claude.firstAuditPassRate == 0.5 && claude.costPerMergedTask == 4.5)
        // Only b's question: the one about no task is no agent's.
        #expect(claude.questions == 1 && claude.userMinutesPerMergedTask == 5)
        #expect(claude.mergeFirstTry == MergeFirstTry(counted: 2, firstTry: 1) && claude.escapes == 1)
        // a, b and the abandoned f: 6600 s worked over 3900 s.
        #expect(claude.parallelism.map { abs($0 - 6600.0 / 3900) < 1e-9 } == true)
        #expect(codex.merged == 1 && codex.audited == 0 && codex.firstAuditPassRate == nil)
        #expect(codex.costPerMergedTask == nil && codex.costed == 0, "its cost isn't known: not recorded")
        #expect(codex.mergeFirstTry == nil, "the recorder has no line for c")
        #expect(codex.findings == nil, "no audits kept for c")
        #expect(codex.escapes == 1 && codex.reverts == 1 && codex.neededNobody == 1)
        // Models: Claude's only, by family, in order.
        #expect(quality.byModel.map(\.name) == ["opus", "sonnet"])
        #expect(quality.byModel[0].figures.merged == 1 && quality.byModel[0].figures.firstAuditPassRate == 1)
        #expect(quality.byModel[1].figures.merged == 1 && quality.byModel[1].figures.firstAuditPassRate == 0)
        #expect(quality.byModel[1].figures.rerolls == 1 && quality.byModel[1].figures.neededNobody == 0)
    }

    @Test func itKeepsAnEightWeekTrend() async throws {
        let (project, home, _) = try qualityLayout()
        let stats = await collector(home: home, now: Self.date(2026, 10, 21)).collect(projects: [project.path], range: Self.fixtureDay)
        let weeks = try #require(stats.quality?.weeks)
        #expect(weeks.count == 8)
        #expect(weeks.last?.end == Self.date(2026, 10, 21) && weeks.first?.start == Self.date(2026, 8, 26))
        #expect(zip(weeks, weeks.dropFirst()).allSatisfy { $0.end == $1.start })
        // The last week: a, b and c; the one before: d, alone, passed first, $5.
        #expect(weeks[7].merged == 3 && weeks[7].firstAuditPassRate == 0.5 && weeks[7].costPerMergedTask == 4.5)
        #expect(weeks[6].merged == 1 && weeks[6].firstAuditPassRate == 1 && weeks[6].costPerMergedTask == 5)
        #expect(weeks[0..<6].allSatisfy { $0.merged == 0 && $0.firstAuditPassRate == nil && $0.costPerMergedTask == nil })
    }

    @Test func qualityFiguresNotKeptAreNotRecordedNeverZero() async throws {
        let root = temp.url("quality-bare")
        let at = Self.date(2026, 10, 20, 12).timeIntervalSince1970
        // A merge as older boards kept it: no audits, no receipt, no launched model, and no merges recorder on the Mac.
        var board = LeadBoard()
        board.tasks = [Self.merged("old", at: at)]
        let project = try project("bare", board: board, in: root)
        let stats = await collector(home: root.appendingPathComponent("home"), now: Self.date(2026, 10, 21))
            .collect(projects: [project.path], range: Self.fixtureDay)
        let all = try #require(stats.quality?.all)
        #expect(all.merged == 1)
        #expect(all.findings == nil && all.mergeFirstTry == nil)
        #expect(all.costPerMergedTask == nil && all.implementationShare == nil && all.mergeRerunCost == nil)
        #expect(all.workingShare == nil && all.restShare == nil && all.auditWaitShare == nil && all.parallelism == nil)
        #expect(all.firstAuditPassRate == nil && all.meanRoundsToPass == nil && all.importantPerAudited == nil)
        #expect(stats.quality?.byModel == [], "no model recorded")
        // A receipt whose working time wasn't counted: no parallelism (not 0×).
        var uncounted = Self.merged("uncounted", at: at)
        uncounted.receipt = LeadReceipt(ending: .merged, startedAt: at - 3600, endedAt: at, worked: nil, worker: nil, verifier: nil)
        board.tasks = [uncounted]
        let other = try self.project("uncounted", board: board, in: root)
        let counted = await collector(home: root.appendingPathComponent("home"), now: Self.date(2026, 10, 21))
            .collect(projects: [other.path], range: Self.fixtureDay)
        #expect(counted.quality?.all.parallelism == nil && counted.quality?.all.workerHours == 0 && counted.quality?.all.busyHours == 0)
        // Nothing merged: per-merge figures have nothing to count.
        let empty = await collector(home: root.appendingPathComponent("home"), now: Self.date(2026, 10, 21))
            .collect(projects: [project.path], range: DateInterval(start: Self.date(2026, 9, 1), end: Self.date(2026, 9, 2)))
        let none = try #require(empty.quality?.all)
        #expect(none.merged == 0 && none.questionsPerMergedTask == nil && none.neededNobodyShare == nil && none.userMinutesPerMergedTask == nil)
        #expect(none.medianCreatedToMerged == nil && none.p90CreatedToMerged == nil)
        // No readable board: no quality at all.
        let nothing = await collector(home: root.appendingPathComponent("home")).collect(projects: [], range: Self.fixtureDay)
        #expect(nothing.quality == nil)
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
