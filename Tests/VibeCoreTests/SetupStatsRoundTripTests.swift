import Foundation
import Testing
@testable import VibeCore

/// `SetupStatsCollector` reads what the recorders really write: each sample here is written by the writer the app
/// runs (LoadRecorder's load lines, `MergeSample`'s merges lines, a board saved through `BoardStore` with
/// `LeadReceipt`s and their `LeadWaits`, and `LeadTokenLedger.tally`'s file), never by hand, so a key the reading side
/// spells another way than the writer (the merges lines' `first_run`, once read as `firstRun`) comes back missing
/// here. In a scratch home and a scratch project, in local time as the app writes them.
struct SetupStatsRoundTripTests {
    let temp = Scratch()

    @Test func everyFieldStatisticsReadsComesBackFromWhatTheWritersWrite() async throws {
        let calendar = Calendar.current
        let now = Date()
        let t = now.timeIntervalSince1970
        // The day before now's through the day after: every sample below (minutes to an hour around now) is in it,
        // whatever the time of day.
        let today = calendar.startOfDay(for: now)
        let range = DateInterval(start: calendar.date(byAdding: .day, value: -1, to: today)!, end: calendar.date(byAdding: .day, value: 2, to: today)!)

        let scratch = temp.url("round-trip")
        let home = scratch.appendingPathComponent("home"), stats = home.appendingPathComponent("stats")
        let projectURL = scratch.appendingPathComponent("trip")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let root = projectURL.resolvingSymlinksInPath().path
        let name = (root as NSString).lastPathComponent

        // Load lines, by the recorder: three minutes boosted, one not.
        let boosted = BoolBox()
        let recorder = LoadRecorder(folder: stats, sources: LoadRecorder.Sources(
            averages: { [10, 9, 8] }, memory: { nil }, heavy: { (0, []) }, processes: { [] }, cwd: { _ in nil }, project: { _ in nil },
            boost: { boosted.value }))
        for minute in 0..<4 {
            boosted.set(minute < 3)
            try recorder.write(census: [], at: Date(timeIntervalSince1970: t - Double(240 - 60 * minute)))
        }

        // Merges lines, by `MergeSample`: a passed first; b failed first and passed on its rerun; d failed, then
        // passed; c and e tested in a batch whose first run failed (e broke it, c landed on the split's passing run),
        // then e passed on its own.
        var mergeDates: [Date] = []
        func merge(_ sample: MergeSample, at: Double) throws {
            let date = Date(timeIntervalSince1970: at)
            try sample.append(in: stats, at: date)
            mergeDates.append(date)
        }
        func solo(_ task: String, _ check: Worktrees.Check, rerun: MergeRerun.Plan? = nil, at: Double) throws {
            let started = Date(timeIntervalSince1970: at)
            try merge(MergeSample(check: check, rerun: rerun, project: name, task: task, started: started, load: [12.345, 10, 9],
                                  waited: 30, slotWait: 45, ended: started.addingTimeInterval(300)), at: at)
        }
        try solo("d", .failed("boom"), at: t - 3000)
        // The batch's lines as `LeadMergeBatch` writes them: the batch's shared first run, and each task's own.
        for (task, result, own) in [("c", "passed", "passed"), ("e", "failed", "failed")] {
            var sample = MergeSample(t: LoadStats.stamp(Date(timeIntervalSince1970: t - 2800)), project: name, task: task, load: [11, 10, 9],
                                     waitedS: 0, slotWaitS: 10, durationS: 600, firstRun: "failed", reran: nil, rerunWhole: nil, result: result)
            sample.batch = LoadStats.stamp(Date(timeIntervalSince1970: t - 2800)) + "-c"
            sample.batchTasks = 2
            sample.batchRuns = 3
            sample.taskFirstRun = own
            try merge(sample, at: t - 2800)
        }
        try solo("d", .passed("c-d"), at: t - 1500)
        try solo("e", .passed("c-e"), at: t - 1400)
        try solo("b", .passedOnRerun(commit: "c-b", failed: "x", rerun: "y"),
                 rerun: MergeRerun.Plan(tests: ["T.x"], filtered: true, command: "test"), at: t - 1300)
        try solo("a", .passed("c-a"), at: t - 1200)

        // The board, through `BoardStore`: a Codex worker's a with its waits and Codex tokens; b with a merge rerun; c,
        // d and e merged with receipts that kept no waits.
        var a = SetupStatsTests.merged("a", at: t - 600, codex: true)
        a.worked = 1800
        a.noteWaits { waits in
            waits.reportedDone(at: t - 5000)
            waits.auditStarted(at: t - 4000, sessions: 2)
            waits.auditEnded(at: t - 2000)
        }
        a.noteMergeRun(loadWait: 120, called: Date(timeIntervalSince1970: t - 1000), begun: Date(timeIntervalSince1970: t - 700),
                       ended: Date(timeIntervalSince1970: t - 100))
        let codexWorker = LeadTokens(input: 1000, output: 100, cacheRead: 0, cacheWrite: 0, sessions: 1, models: ["gpt-6.1-sol"], cost: 1, codex: 400)
        a.receipt = LeadReceipt(a, ending: .merged, questions: [], usage: LeadReceipts.Usage(worker: codexWorker, verifier: SetupStatsTests.tokens(cost: 0.5)),
                                now: t - 600)
        var tasks = [a]
        for (slug, reruns) in [("b", 1), ("c", 0), ("d", 0), ("e", 0)] {
            var task = SetupStatsTests.merged(slug, at: t - 500, model: "claude-opus-5-5")
            task.worked = 900
            task.receipt = LeadReceipt(task, ending: .merged, questions: [], usage: LeadReceipts.Usage(worker: SetupStatsTests.tokens(cost: 1)),
                                       mergeReruns: reruns, now: t - 500)
            tasks.append(task)
        }
        try BoardStore(root: root).update { $0.tasks = tasks }
        let stored = BoardStore(root: root).load().tasks.first { $0.slug == "a" }
        let waits = try #require(stored?.receipt?.waits)
        #expect(waits.auditWait == 1000 && waits.auditing == 2000 && waits.verifierTime == 4000)
        #expect(waits.mergeLoadWait == 120 && waits.mergeSlotWait == 300 && waits.mergeTesting == 600)

        // The lead's ledger, by `LeadTokenLedger.tally`: made before the lead's responses, then tallied again after them.
        let claude = URL(fileURLWithPath: home.path).appendingPathComponent(".claude/projects").appendingPathComponent(RecentProjects.claudeSlug(for: root))
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let transcript = claude.appendingPathComponent("lead.jsonl")
        let leadName = LeadTokenLedger.leadName(root: root)
        try (LeadReceiptTests.named(leadName, session: "lead").joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let begun = Date().timeIntervalSince1970
        try #require(try LeadTokenLedger.tally(root: root, home: home.path, now: Date(timeIntervalSince1970: begun)))
        let responses = [LeadReceiptTests.response("m1", "claude-opus-5-5", input: 100, output: 50, read: 1000, at: begun + 10),
                         LeadReceiptTests.response("m2", "claude-opus-5-5", input: 10, output: 5, at: begun + 20)]
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((responses.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        let ledger = try #require(try LeadTokenLedger.tally(root: root, home: home.path, now: Date(timeIntervalSince1970: begun + 60)))
        let ledgerCost = ledger.days.values.reduce(0) { $0 + $1.cost }
        #expect(ledger.days.values.reduce(0) { $0 + $1.total } == 1165 && ledgerCost > 0)

        let collector = SetupStatsCollector(home: home, codexHome: nil, calendar: calendar, now: { now })
        let result = await collector.collect(projects: [root], range: range)

        // Load and boost.
        let load = try #require(result.mac.load)
        #expect(load.minutes == 4 && load.median == 10 && load.cores == MacLoad.processors)
        #expect(result.mac.hoursBoosted == 3.0 / 60)
        // The merges: every line, and those that landed.
        #expect(result.mac.merges?.recorded == 7 && result.mac.merges?.landed == 5)

        // Waits and Codex tokens, from the board's receipts.
        let figures = try #require(result.projects.first?.figures)
        #expect(figures.ended == 5 && figures.merged == 5 && figures.mergeReruns == 1)
        func hours(_ value: Double?, _ seconds: Double) -> Bool { value.map { abs($0 - seconds / 3600) < 1e-9 } ?? false }
        #expect(hours(figures.auditWaitHours, 1000) && hours(figures.auditingHours, 2000) && hours(figures.verifierHours, 4000))
        #expect(hours(figures.mergeWaitHours, 420) && hours(figures.mergeTestHours, 600))
        #expect(figures.codexTokens == 400 && result.total?.codexTokens == 400 && result.mac.codexTokens == 400)
        #expect(figures.codexTasks == 1 && figures.claudeTasks == 4)

        // Lead tokens, from the ledger.
        #expect(figures.leadTokens == 1165 && figures.leadUnpricedDays == 0)
        #expect(figures.leadCost.map { abs($0 - ledgerCost) < 1e-12 } == true)
        let quality = try #require(result.quality)
        #expect(quality.all.lead?.tokens == 1165)

        // First runs, as the collector reads each line: the run's (`first_run`), a batched task's own (`task_first_run`).
        let stamps = StampParser(calendar: calendar)
        let paths = Set(mergeDates.map { stats.appendingPathComponent(LoadStats.fileName("merges", for: $0)).path })
        let lines = paths.sorted().flatMap { path in
            (SetupStatsCollector.jsonLines(path) ?? []).compactMap { RecorderLine($0, stamps: stamps) }
        }.sorted { $0.at < $1.at }
        #expect(lines.count == 7)
        let read = lines.map { "\($0.task ?? "?") \($0.result ?? "?") \($0.firstRun ?? "none")" }
        #expect(read == ["d failed failed", "c passed passed", "e failed failed", "d passed passed", "e passed passed",
                         "b passed_on_rerun failed", "a passed passed"])
        #expect(lines.allSatisfy { $0.project == name && $0.load.first != nil })
        #expect(lines.first.map { abs($0.at - (t - 3000).rounded(.down)) < 1 } == true)

        // Merge first try: a and c (its own run passed, though the batch's first failed); b reran, d and e were sent back.
        let first = try #require(quality.all.mergeFirstTry)
        #expect(first.counted == 5 && first.firstTry == 2)
        #expect(quality.all.sentBack == 2)
        #expect(quality.all.codexTokens == 400)
        #expect(quality.all.auditWaited == 1000 && quality.all.waited == 1)
    }
}

/// A flag the recorder's boost source reads.
private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set(_ value: Bool) { lock.withLock { stored = value } }
}
