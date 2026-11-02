import Foundation
import Testing

/// scripts/impact-metrics.sh: the impact ledger's standard metrics for a date range (docs/process/impact.md), from a
/// project's board, archive, progress.md and incidents.md and the Mac's hang logs and load recorder files. The fixture
/// set (Tests/Fixtures/impact-metrics, times in UTC: the script runs with TZ=UTC) is built so every number is known;
/// its generator's reasoning is in each expectation's comment.
struct ImpactMetricsScriptTests {
    static let repo = KeychainLintTests.repo
    static let fixtures = repo.appendingPathComponent("Tests/Fixtures/impact-metrics")
    let temp = Scratch()

    func metrics(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repo.appendingPathComponent("scripts/impact-metrics.sh").path] + arguments
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
        return (process.terminationStatus, output)
    }

    /// A project folder `proj` and a VibeSwitcher home laid out as on a Mac, from the fixtures.
    func layout() throws -> (project: URL, home: URL) {
        let root = temp.url("impact")
        let project = root.appendingPathComponent("proj"), home = root.appendingPathComponent("home")
        let fm = FileManager.default
        let board = project.appendingPathComponent(".vibeswitcher"), lead = project.appendingPathComponent("docs/lead")
        for folder in [board, lead, home] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        for name in ["board.json", "board-archive.jsonl"] {
            try fm.copyItem(at: Self.fixtures.appendingPathComponent(name), to: board.appendingPathComponent(name))
        }
        for name in ["progress.md", "incidents.md"] {
            try fm.copyItem(at: Self.fixtures.appendingPathComponent(name), to: lead.appendingPathComponent(name))
        }
        for name in ["stats", "debug"] {
            try fm.copyItem(at: Self.fixtures.appendingPathComponent(name), to: home.appendingPathComponent(name))
        }
        return (project, home)
    }

    func value(_ output: String, _ metric: String) -> String? {
        output.components(separatedBy: "\n").first { $0.hasPrefix("  \(metric): ") }
            .map { String($0.dropFirst(metric.count + 4)) }
    }

    @Test func itPrintsTheKnownNumbersOfTheFixtureDay() throws {
        let (project, home) = try layout()
        let run = try metrics(["2026-10-20..2026-10-20", "--project", project.path, "--home", home.path])
        #expect(run.status == 0, "\(run.output)")
        let out = run.output
        // alpha (board), beta (archive only), gamma (board) merged on the day; delta the day before. Progress lines on
        // the day fall in hours 08, 09, 10, 11, 12, 13, 14 and 15.
        #expect(value(out, "merges/h") == "0.12 (3 merges in 24.0 h; 0.38 per active hour, 8 h with lead activity)")
        // Starts to merges: 120, 60 and 180 min.
        #expect(value(out, "median start-to-merge") == "2.0 h (3 of 3 merges have a start)")
        // alpha's audit started 09:00, merged 10:00 (60 min); gamma's first audit 13:30, merged 15:00 (90 min). gamma's
        // audit start after its merge (the day after) doesn't count; beta wasn't audited.
        #expect(value(out, "median audit-to-merge") == "75 min (2 of 2 audited merges have an audit start in progress.md)")
        #expect(value(out, "audit rounds per audited task") == "1.50 (3 rounds over 2 audited of 3 merges)")
        #expect(value(out, "Important findings per task") == "1.00 (3 over 3 merges; 1.50 per audited task)")
        // beta, reverted at 15:00.
        #expect(value(out, "reverts")?.hasPrefix("1 ") == true)
        // Of three incidents, one is on the day.
        #expect(value(out, "incidents")?.hasPrefix("1 ") == true)
        // alpha passed on the merge's rerun; the ledger's flakes on the day are alpha's two (delta's is the day before).
        #expect(value(out, "flaky-merge rate")
            == "33% (1 of 3 merges with a receipt passed only on the rerun; flake ledger: 2 flakes of 2 tests in 1 merges)")
        // proj's recorded runs: 200, 240 (failed first), 300 s; its conflict ran no tests; "other" is another project.
        #expect(value(out, "median full-suite duration") == "240 s (3 recorded merge test runs; 1 failed their first run)")
        // Receipts ended on the day: alpha 1 h, beta 0.5 h, gamma 1.5 h, epsilon (abandoned) 0.5 h. Costs: alpha $4, beta
        // $2, epsilon $1; gamma's verifier ran a model with no price, so its cost is unknown, not counted as $6.
        #expect(value(out, "worker hours") == "3.5 h (4 tasks ended with a receipt)")
        #expect(value(out, "estimated cost per task") == "$2.33 ($7.00 over 3 receipts with a known cost)")
        #expect(value(out, "usage-limit stops")?.hasPrefix("n/a") == true)
        // Freezes on the day: 05:00, 10:00:30 (a .txt and a .log: one), 10:30, 20:00; 23:00 the day before and 12:00 the day
        // after aren't (the one before also shows no report of the day was pruned).
        #expect(value(out, "freezes/h") == "0.17 (4 hang reports in 24.0 h)")
        // Samples: 10:00–10:59 at load 30, 20:00–21:59 at load 50; 05:00 has none within 2 minutes.
        #expect(out.contains("    24-36      2.00  (2 / 1.0 h)"), "\(out)")
        #expect(out.contains("    48-72      0.50  (1 / 2.0 h)"), "\(out)")
        #expect(out.contains("    unsampled 1 (no load sample within 2 minutes)"), "\(out)")
    }

    @Test func aRangeOfHoursCountsOnlyThoseHours() throws {
        let (project, home) = try layout()
        let run = try metrics(["2026-10-20T09:30..2026-10-20T12:30", "--project", project.path, "--home", home.path])
        #expect(run.status == 0, "\(run.output)")
        // alpha (10:00) and beta (12:00) in 3 h; progress lines at 10:00, 11:00, 12:00.
        #expect(value(run.output, "merges/h") == "0.67 (2 merges in 3.0 h; 0.67 per active hour, 3 h with lead activity)")
        // Freezes at 10:00:30 and 10:30.
        #expect(value(run.output, "freezes/h") == "0.67 (2 hang reports in 3.0 h)")
    }

    /// The app prunes hang reports (a week, at most 500 MB): hours before the oldest report left aren't counted as
    /// freeze-free. The fixtures' oldest report is 2026-10-19 23:00.
    @Test func hoursWhoseHangReportsWerePrunedArentCounted() throws {
        let (project, home) = try layout()
        // From 23:00 to 12:00: 13 h covered, with the freezes at 23:00, 05:00, 10:00:30 and 10:30.
        let partial = try metrics(["2026-10-19T12:00..2026-10-20T12:00", "--project", project.path, "--home", home.path])
        #expect(partial.status == 0, "\(partial.output)")
        #expect(value(partial.output, "freezes/h")
            == "0.31 (4 hang reports in 13.0 h; partial: reports before 2026-10-19 23:00 were pruned by the app, which keeps a week, at most 500 MB)")
        // A day before every report left: no number at all, for freezes or their load buckets.
        let pruned = try metrics(["2026-10-18..2026-10-18", "--project", project.path, "--home", home.path])
        #expect(pruned.status == 0, "\(pruned.output)")
        #expect(value(pruned.output, "freezes/h")?.hasPrefix("n/a (reports before 2026-10-19 23:00 were pruned") == true, "\(pruned.output)")
    }

    @Test func missingSourcesAreNotApplicableNeverGuessed() throws {
        let root = temp.url("impact-empty")
        let project = root.appendingPathComponent("proj"), home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let run = try metrics(["2026-10-20..2026-10-20", "--project", project.path, "--home", home.path])
        #expect(run.status == 0, "\(run.output)")
        for metric in ["merges/h", "median start-to-merge", "median audit-to-merge", "audit rounds per audited task",
                       "Important findings per task", "reverts", "incidents", "flaky-merge rate", "median full-suite duration",
                       "worker hours", "estimated cost per task", "usage-limit stops", "freezes/h", "freezes/h by load bucket"] {
            #expect(value(run.output, metric)?.hasPrefix("n/a (") == true, "\(metric): \(run.output)")
        }
    }

    @Test func aBadRangeIsRefused() throws {
        for range in ["2026-10-20", "2026-10-21..2026-10-20", "yesterday..today"] {
            let run = try metrics([range, "--home", temp.url("home").path])
            #expect(run.status != 0, "\(range): \(run.output)")
        }
    }
}
