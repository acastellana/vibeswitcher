import Foundation
import Testing
@testable import VibeCore

/// The comparison with working solo (SetupStatsCompared.swift), on hand-built boards in scratch projects (never a real
/// board): each estimate from what's recorded, split by Claude and Codex, and "not recorded" (nil) where its inputs
/// aren't kept; and the figures statistics-3 left unrecorded that the new records now fill.
struct SetupStatsComparedTests {
    let temp = Scratch()
    static let at = SetupStatsTests.date(2026, 10, 20, 12).timeIntervalSince1970

    func project(_ name: String, board: LeadBoard, in root: URL) throws -> URL {
        let folder = root.appendingPathComponent(name).appendingPathComponent(".vibeswitcher")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(board).write(to: folder.appendingPathComponent("board.json"))
        return root.appendingPathComponent(name)
    }

    static func receipt(worked: Double, worker: Double?, verifier: Double?, codex: Int? = nil, rerolls: Int = 0, mergeReruns: Int = 0,
                        waits: LeadWaits? = nil, ended: Double = at) -> LeadReceipt {
        var tokens = SetupStatsTests.tokens(cost: worker)
        tokens.codex = codex
        var receipt = LeadReceipt(ending: .merged, startedAt: ended - 3600, endedAt: ended, worked: worked, worker: tokens,
                                  verifier: verifier.map { SetupStatsTests.tokens(cost: $0) }, rerolls: rerolls, mergeReruns: mergeReruns)
        receipt.waits = waits
        return receipt
    }

    /// Project "solo", every merge on the fixture day:
    /// - s1 (Claude, opus): $6 + $2 verifier, an hour's work, 15 min waiting for its audit, 30 min of verifier time;
    ///   Important F1 fixed, Important F2 and Nit F3 left; a batched merge line whose shared first run failed but its own passed.
    /// - s2 (Claude, sonnet): $4 + $1, re-rolled once; its audits kept, no finding; passed on the rerun (a flake);
    ///   named by an incident after it merged.
    /// - s3 (Codex): $0.50 of Claude tokens + $1.50 verifier, 2M Codex tokens, an hour's work, an hour of verifier time
    ///   and no audit wait; its first line failed (sent back), its second passed.
    /// - s4 (Claude): merged before receipts (no cost, no time), since reverted; no merge line.
    /// - s5 (Claude): $2 and no verifier, 20 min of work, its merge's tests rerun.
    /// Flakes in the range: s1's, s3's and a task no longer on the board's (one before the range too). The lead: $3 on
    /// the day. A question about s1 waited 10 minutes.
    func soloLayout() throws -> (project: URL, home: URL) {
        let root = temp.url("compared")
        let at = Self.at
        var s1 = SetupStatsTests.merged("s1", at: at, model: "claude-opus-5-5")
        var ledger = LeadAuditLedger()
        (ledger.rounds, ledger.passed) = (2, true)
        ledger.findings = [SetupStatsTests.finding("F1", .important, .fixed), SetupStatsTests.finding("F2", .important, .open),
                           SetupStatsTests.finding("F3", .nit, .fixed)]
        s1.audits = ledger
        s1.receipt = Self.receipt(worked: 3600, worker: 6, verifier: 2,
                                  waits: LeadWaits(auditWait: 900, auditing: 1800, verifierTime: 1800, mergeLoadWait: 0))
        var s2 = SetupStatsTests.merged("s2", at: at + 60, model: "sonnet")
        ledger = LeadAuditLedger()
        (ledger.rounds, ledger.passed) = (1, true)
        s2.audits = ledger
        s2.rerolls = [LeadReroll(archive: "agent/s2-1", commit: nil, round: 1, at: at - 5000)]
        s2.receipt = Self.receipt(worked: 1800, worker: 4, verifier: 1, rerolls: 1, ended: at + 60)
        var s3 = SetupStatsTests.merged("s3", at: at + 120, codex: true)
        s3.receipt = Self.receipt(worked: 3600, worker: 0.5, verifier: 1.5, codex: 2_000_000,
                                  waits: LeadWaits(auditWait: 0, auditing: 3600, verifierTime: 3600, mergeLoadWait: 0), ended: at + 120)
        var s4 = SetupStatsTests.merged("s4", at: at + 180)
        s4.merged?.revertedBy = "r1"
        var s5 = SetupStatsTests.merged("s5", at: at + 240)
        s5.receipt = Self.receipt(worked: 1200, worker: 2, verifier: nil, mergeReruns: 1, ended: at + 240)
        var board = LeadBoard()
        board.tasks = [s1, s2, s3, s4, s5]
        board.flakes = [LeadFlake(test: "T1", task: "s1", commit: "c", at: at - 100), LeadFlake(test: "T2", task: "s3", commit: "c", at: at - 50),
                        LeadFlake(test: "T3", task: "gone", commit: "c", at: at - 20), LeadFlake(test: "T4", task: "s1", commit: "c", at: at - 9 * 86_400)]
        var asked = LeadQuestion(id: "q1", text: "?", options: [], at: at - 1200)
        asked.task = "s1"
        asked.answer = "yes"
        asked.answeredAt = at - 600
        board.questions = [asked]
        let project = try project("solo", board: board, in: root)
        let folder = project.appendingPathComponent(".vibeswitcher")
        let after = LeadDecision.stamp(Date(timeIntervalSince1970: at + 6 * 3600))
        try "# Incidents\n\n## \(after) s2 broke Y\n\nEvidence: e\n\nTask: s2\n\n".write(to: folder.appendingPathComponent("incidents.md"),
                                                                                         atomically: true, encoding: .utf8)
        let day: [String: Any] = ["input": 1000, "output": 150, "cacheRead": 0, "cacheWrite": 0, "cacheWrite1h": 0, "cost": 3.0, "models": [:],
                                  "sessions": []]
        let lead: [String: Any] = ["since": at - 5 * 86_400, "at": at, "files": [:], "days": ["2026-10-20": day]]
        try JSONSerialization.data(withJSONObject: lead).write(to: folder.appendingPathComponent(LeadTokenLedger.fileName))
        let home = root.appendingPathComponent("home"), stats = home.appendingPathComponent("stats")
        try FileManager.default.createDirectory(at: stats, withIntermediateDirectories: true)
        try [#"{"t":"2026-10-20T11:50:00+00:00","project":"solo","task":"s1","first_run":"failed","task_first_run":"passed","result":"passed","batch":"b1"}"#,
             #"{"t":"2026-10-20T11:51:00+00:00","project":"solo","task":"s2","first_run":"failed","result":"passed_on_rerun"}"#,
             #"{"t":"2026-10-20T10:00:00+00:00","project":"solo","task":"s3","first_run":"failed","result":"failed"}"#,
             #"{"t":"2026-10-20T11:52:00+00:00","project":"solo","task":"s3","first_run":"passed","result":"passed"}"#,
             #"{"t":"2026-10-20T11:53:00+00:00","project":"solo","task":"s5","first_run":"failed","result":"passed_on_rerun"}"#]
            .joined(separator: "\n").write(to: stats.appendingPathComponent("merges-2026-10-20.jsonl"), atomically: true, encoding: .utf8)
        return (project, home)
    }

    func collect(_ projects: [URL], home: URL) async -> SetupStats {
        await SetupStatsCollector(home: home, codexHome: nil, calendar: SetupStatsTests.utc, now: { SetupStatsTests.date(2026, 10, 21) })
            .collect(projects: projects.map(\.path), range: SetupStatsTests.fixtureDay)
    }

    @Test func processCostIsTheShareThatIsntTheMergedAttemptsWorkers() async throws {
        let (project, home) = try soloLayout()
        let quality = try #require(await collect([project], home: home).quality)
        // The baseline: s1 and s5 (s2 re-rolled, s3 Codex's, s4 no cost). The process: their verifiers ($2) and their
        // share of the lead's $3, spread over the 5 merges: 2/5 of it.
        let all = try #require(quality.all.processCost)
        #expect(all.merges == 2 && all.solo == 8 && all.verifiers == 2 && all.leadWhole == 3 && all.merged == 5)
        #expect(all.lead.map { abs($0 - 1.2) < 1e-9 } == true)
        #expect(abs(all.process - 3.2) < 1e-9 && abs(all.total - 11.2) < 1e-9 && all.share.map { abs($0 - 3.2 / 11.2) < 1e-9 } == true)
        #expect(!all.leadPartial, "the ledger covers the whole day")
        #expect(all.reran == 1 && all.rerolledLeftOut == 1 && all.codexLeftOut == 1)
        #expect(all.atLeast, "s5's merge rerun and s2's re-rolled attempt aren't priced: a lower bound")
        #expect(quality.all.lead == LeadSpend(tokens: 1150, cost: 3, unpricedDays: 0))
        // Claude's: the same merges, no lead (it isn't one agent's).
        let claude = try #require(quality.byAgent.first { $0.name == "Claude" }?.figures)
        #expect(claude.lead == nil)
        let mine = try #require(claude.processCost)
        #expect(mine.lead == nil && mine.process == 2 && mine.share == 0.2 && mine.atLeast)
        // Codex's: its tokens have no price, so no baseline: not recorded, its tokens counted.
        let codex = try #require(quality.byAgent.first { $0.name == "Codex" }?.figures)
        #expect(codex.processCost == nil && codex.codexLeftOut == 1 && codex.codexTokens == 2_000_000)
        #expect(quality.all.codexTokens == 2_000_000 && claude.codexTokens == nil)
    }

    @Test func whatItCaughtSitsBesideWhatEscapedPer100Merges() async throws {
        let (project, home) = try soloLayout()
        let quality = try #require(await collect([project], home: home).quality)
        let all = quality.all
        #expect(all.merged == 5)
        // Caught: F1 (Important, fixed) over the 2 merges whose audits are kept; F2 left open and the Nit not counted.
        #expect(all.importantFixed == 1 && all.auditsKept == 2 && all.importantFixedPer100 == 50)
        // s3's first run failed and it went back; s2's and s5's passed on the rerun (flakes); s1's own first run passed in
        // its batch; s4 has no line.
        #expect(all.mergeFirstTry == MergeFirstTry(counted: 4, firstTry: 1) && all.sentBack == 1 && all.sentBackPer100 == 25)
        // Three flakes in the range (one before it not counted), per 5 merges.
        #expect(all.flakesCaught == 3 && all.flakesCaughtPer100 == 60)
        // Escaped: s4 reverted, s2 named by a later incident.
        #expect(all.revertsPer100 == 20 && all.incidents == 1 && all.incidentsPer100 == 20)
        // By agent: the flake about a task no longer on the board is in All only.
        let claude = try #require(quality.byAgent.first { $0.name == "Claude" }?.figures)
        let codex = try #require(quality.byAgent.first { $0.name == "Codex" }?.figures)
        #expect(claude.flakesCaught == 1 && claude.flakesCaughtPer100 == 25 && codex.flakesCaught == 1 && codex.flakesCaughtPer100 == 100)
        #expect(claude.importantFixedPer100 == 50 && codex.importantFixedPer100 == nil, "no audits kept for s3: not recorded")
        #expect(claude.sentBackPer100 == 0 && codex.sentBackPer100 == 100)
        #expect(claude.revertsPer100 == 25 && claude.incidentsPer100 == 25 && codex.revertsPer100 == 0 && codex.incidentsPer100 == 0)
    }

    @Test func timeFiguresAreWorkPerHourAndHandsOffWorkPerMinuteOfYours() async throws {
        let (project, home) = try soloLayout()
        let quality = try #require(await collect([project], home: home).quality)
        let all = quality.all
        #expect(all.hoursOfWorkPerHour == all.parallelism && all.parallelism != nil, "statistics-3's parallelism, not worked out again")
        // Worked: 3600 + 1800 + 3600 + 1200 s over the 4 merges whose working time is known; 10 of your minutes over 5 merges.
        #expect(all.workerHoursPerMergedTask == 10_200.0 / 3600 / 4)
        #expect(all.userMinutesPerMergedTask == 2)
        #expect(all.handsOffMinutesPerUserMinute.map { abs($0 - 10_200.0 / 60 / 4 / 2) < 1e-9 } == true)
        // Codex: no question waited on the user: no minute to divide by.
        let codex = try #require(quality.byAgent.first { $0.name == "Codex" }?.figures)
        #expect(codex.userMinutesPerMergedTask == 0 && codex.handsOffMinutesPerUserMinute == nil && codex.workerHoursPerMergedTask == 1)
    }

    @Test func theNewRecordsFillTheAuditWaitAndVerifierHours() async throws {
        let (project, home) = try soloLayout()
        let quality = try #require(await collect([project], home: home).quality)
        let all = quality.all
        // s1 and s3 keep their waits (created 2 h before each merge): 15 min of 4 h; s2 and s5 keep none.
        #expect(all.waited == 2 && all.waitedSpan == 14_400 && all.auditWaited == 900 && all.auditWaitShare == 900.0 / 14_400)
        #expect(all.restShare == 1 - all.workingShare! - 900.0 / 14_400)
        #expect(all.verifierHours == 1.5)
        #expect(quality.byAgent.first { $0.name == "Claude" }?.figures.verifierHours == 0.5)
        #expect(quality.byAgent.first { $0.name == "Codex" }?.figures.verifierHours == 1)
    }

    @Test func inputsNotKeptAreNotRecordedNeverAGuess() async throws {
        let root = temp.url("compared-bare")
        // A merge from before receipts, in a project with no flake ledger, no incidents record and no lead ledger, on a
        // Mac with no merges recorder.
        var board = LeadBoard()
        board.tasks = [SetupStatsTests.merged("old", at: Self.at)]
        let project = try project("bare", board: board, in: root)
        let all = try #require(await collect([project], home: root.appendingPathComponent("home")).quality?.all)
        #expect(all.merged == 1)
        #expect(all.processCost == nil && all.lead == nil && all.codexTokens == nil)
        #expect(all.importantFixedPer100 == nil && all.sentBackPer100 == nil && all.flakesCaughtPer100 == nil)
        #expect(all.incidentsPer100 == 0, "the lead makes incidents.md on the first incident: no file is none")
        #expect(all.hoursOfWorkPerHour == nil && all.workerHoursPerMergedTask == nil && all.handsOffMinutesPerUserMinute == nil)
        #expect(all.auditWaitShare == nil && all.verifierHours == nil)
        #expect(all.revertsPer100 == 0, "reverts are on the board itself")
        // Only re-rolled merges have a known cost: their attempts aren't split, so no baseline.
        var rerolled = SetupStatsTests.merged("rr", at: Self.at)
        rerolled.receipt = Self.receipt(worked: 600, worker: 1, verifier: 1, rerolls: 1)
        board.tasks = [rerolled]
        let other = try self.project("rerolled", board: board, in: root)
        let figures = try #require(await collect([other], home: root.appendingPathComponent("home")).quality?.all)
        #expect(figures.processCost == nil && figures.rerolledLeftOut == 1)
        // Nothing merged: nothing to count.
        let none = QualityFigures()
        #expect(none.revertsPer100 == nil && none.flakesCaughtPer100 == nil && none.processCost == nil)
    }

    @Test func theLeadsCostIsSpreadOverTheMergesNotPutOnTheBaselineAlone() {
        // One Claude merge in the baseline, nine Codex merges left out: the baseline carries a tenth of the lead's $20.
        var f = QualityFigures()
        (f.merged, f.soloMerges, f.soloWorkerCost, f.soloVerifierCost, f.codexLeftOut) = (10, 1, 2, 0.5, 9)
        f.lead = LeadSpend(tokens: 10, cost: 20, unpricedDays: 0)
        let cost = f.processCost!
        #expect(cost.lead == 2 && cost.process == 2.5 && cost.share == 2.5 / 4.5, "not 20.5 / 22.5")
    }

    @Test func aLeadLedgerCoveringPartOfTheRangeIsMarkedPartial() async throws {
        let (project, home) = try soloLayout()
        // The ledger began after the range started: the days before it aren't counted.
        let ledger = project.appendingPathComponent(".vibeswitcher").appendingPathComponent(LeadTokenLedger.fileName)
        var lead = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as? [String: Any])
        lead["since"] = Self.at - 3600
        try JSONSerialization.data(withJSONObject: lead).write(to: ledger)
        let late = try #require(await collect([project], home: home).quality?.all)
        #expect(late.lead?.partial == true && late.lead?.cost == 3 && late.processCost?.leadPartial == true && late.processCost?.atLeast == true)
        // A whole ledger, but another project with a board keeps none for the range.
        lead["since"] = Self.at - 5 * 86_400
        try JSONSerialization.data(withJSONObject: lead).write(to: ledger)
        let other = try self.project("unledgered", board: LeadBoard(), in: temp.url("compared-other"))
        let both = try #require(await collect([project, other], home: home).quality?.all)
        #expect(both.lead?.partial == true)
        let alone = try #require(await collect([project], home: home).quality?.all)
        #expect(alone.lead?.partial == false)
    }

    @Test func theLeadsUnpricedDaysMakeItsCostALowerBound() {
        var f = QualityFigures()
        (f.merged, f.soloMerges, f.soloWorkerCost, f.soloVerifierCost) = (1, 1, 4, 1)
        f.lead = LeadSpend(tokens: 10, cost: 1, unpricedDays: 1)
        let cost = f.processCost!
        #expect(cost.share == 2.0 / 6 && cost.atLeast)
        #expect(cost.lead == 1, "one merge: the lead's whole cost")
        f.lead = LeadSpend(tokens: 10, cost: 1, unpricedDays: 0)
        #expect(f.processCost?.atLeast == false, "every part recorded: no rerun, no re-roll, the lead priced")
        f.lead = LeadSpend(tokens: 10, cost: nil, unpricedDays: 2)
        #expect(f.processCost?.lead == nil && f.processCost?.atLeast == true && f.processCost?.share == 0.2)
    }
}
