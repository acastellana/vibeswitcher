import Foundation
import Testing
@testable import VibeCore

/// A team task's receipt (see `LeadReceipt.members`, design T11): its members' working time and worker tokens summed
/// into the receipt's, and listed per member; a plain task's receipt is what it was before teams.
struct LeadReceiptTeamTests {
    let temp = Scratch()
    /// The scratch home whose `.claude/projects` holds the fixture transcripts.
    let home: String
    let root: String
    init() {
        home = temp.url("home").path
        root = temp.url("lead").path
    }

    static let opus = "claude-opus-5-5"

    static func plainTask() -> LeadTask {
        var task = LeadTask(slug: "t", title: "T", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""), status: .done)
        task.startedAt = 1000
        task.worked = 3 * 3600 + 60
        var audits = LeadAuditLedger()
        audits.rounds = 2
        task.audits = audits
        task.merged = LeadMergeRecord(commit: "1234567890ab", tested: true, onto: "abcdef123456")
        return task
    }

    static let usage = LeadReceipts.Usage(worker: LeadTokens(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, sessions: 1, models: [opus], cost: 1.5),
                                          verifier: LeadTokens(input: 10, output: 20, sessions: 1, models: ["claude-fable-5-1"], cost: 0.25))

    /// Writes `lines` as session `session`'s transcript in Claude's folder for the worktree of `slug` (a member's
    /// `<slug>--<name>`).
    func transcript(_ session: String, name: String, _ lines: [String], slug: String) throws {
        let folder = try #require(LeadReceipts.folders(root: root, slug: slug, home: home).first)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let all = LeadReceiptTests.named(name, session: session) + lines
        try (all.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8)
    }

    // MARK: A plain task: unchanged

    /// The receipt of a plain task, as JSON and as its line, exactly as before teams (captured on main before T11).
    @Test func aPlainTasksReceiptIsByteForByteWhatItWas() throws {
        let receipt = LeadReceipt(Self.plainTask(), ending: .merged, questions: [], usage: Self.usage, tests: 9, commits: 3, now: 1000 + 5 * 3600)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(receipt), as: UTF8.self)
        #expect(json == #"{"commit":"1234567890ab","commits":3,"endedAt":19000,"ending":"merged","mergeReruns":0,"onto":"abcdef123456","pricesAsOf":"2026-10-06","questions":0,"rerolls":0,"rounds":2,"startedAt":1000,"tests":9,"verifier":{"cacheRead":0,"cacheWrite":0,"cacheWrite1h":0,"cost":0.25,"input":10,"models":["claude-fable-5-1"],"output":20,"sameModel":false,"sessions":1},"waitingOnUser":0,"worked":10860,"worker":{"cacheRead":3,"cacheWrite":4,"cacheWrite1h":0,"cost":1.5,"input":1,"models":["claude-opus-5-5"],"output":2,"sessions":1}}"#, "\(json)")
        #expect(receipt.line == "Receipt (merged; cost an estimate at prices of 2026-10-06): 3 h 1 min worked, 5 h wall · worker 10 tokens (in 1, out 2, "
            + "cache read 3, cache write 4; claude-opus-5-5), verifier 30 tokens (in 10, out 20, cache read 0, cache write 0; claude-fable-5-1) · est. $1.75 · 2 audit rounds · 9 tests in the merge's run · 3 commits abcdef12..12345678; rollback point abcdef12", "\(receipt.line)")
    }

    // MARK: A team task: summed and listed

    /// A team of three (core the integrator, ui and docs), created at `start`, done.
    func teamTask(start: Double) throws -> LeadTask {
        var task = Self.plainTask()
        task.slug = "team"
        task.createdAt = start
        task.startedAt = start
        task.team = try LeadTeam.make(slug: "team", root: root, parts: [(name: "core", part: "the runner"), (name: "ui", part: "the views"),
                                                                      (name: "docs", part: "the guide")])
        return task
    }

    /// Each member's worker in its own worktree's folder, the task's verifier in the task's, and sessions that aren't
    /// the team's (the user's own, a verifier name in a member's folder, another task's worker) that never count.
    func teamFixtures(start: Double) throws {
        let response = LeadReceiptTests.response
        try transcript("core-1", name: "worker-team", [
            response("c1", Self.opus, 10, 1000, 50_000, 2000, 0, start + 10, "s", 0),
            response("c2", Self.opus, 5, 500, 0, 0, 0, start + 20, "s", 0),
        ], slug: "team")
        try transcript("verify-1", name: "verify-team", [response("v1", "claude-fable-5-1", 100, 4000, 0, 0, 0, start + 30, "s", 0)], slug: "team")
        try transcript("ui-1", name: "worker-team--ui", [response("u1", Self.opus, 20, 2000, 100_000, 0, 0, start + 40, "s", 0)], slug: "team--ui")
        // Resumed: its second session repeats the first's response, which counts once.
        try transcript("docs-1", name: "worker-team--docs", [response("d1", Self.opus, 1, 300, 0, 0, 0, start + 50, "s", 0)], slug: "team--docs")
        try transcript("docs-2", name: "worker-team--docs", [response("d1", Self.opus, 1, 300, 0, 0, 0, start + 50, "s", 0),
                                                              response("d2", Self.opus, 2, 400, 0, 0, 0, start + 60, "s", 0)], slug: "team--docs")
        try transcript("own", name: "my-own-look", [response("x1", Self.opus, 5_000_000, 5_000_000, 0, 0, 0, start + 70, "s", 0)], slug: "team--ui")
        try transcript("fake-v", name: "verify-team--ui", [response("x2", Self.opus, 7_000_000, 0, 0, 0, 0, start + 70, "s", 0)], slug: "team--ui")
        try transcript("other", name: "worker-team-two", [response("x3", Self.opus, 9_000_000, 0, 0, 0, 0, start + 70, "s", 0)], slug: "team")
    }

    @Test func aTeamTasksReceiptSumsItsMembersMinutesAndTokensAndListsEach() throws {
        let start = Date().timeIntervalSince1970
        try teamFixtures(start: start)
        let task = try teamTask(start: start)
        let usage = LeadReceipts.usage(root: root, task: task, home: home)
        let members = try #require(usage.members)
        let core = try #require(members["core"]), ui = try #require(members["ui"]), docs = try #require(members["docs"])
        #expect(core.input == 15 && core.output == 1500 && core.cacheRead == 50_000 && core.cacheWrite == 2000 && core.sessions == 1, "\(core)")
        #expect(ui.input == 20 && ui.output == 2000 && ui.cacheRead == 100_000 && ui.sessions == 1, "\(ui)")
        #expect(docs.input == 3 && docs.output == 700 && docs.sessions == 2, "\(docs)")
        #expect(usage.verifier?.output == 4000 && usage.verifier?.sessions == 1, "\(String(describing: usage.verifier))")

        let worked = ["core": 40 * 60.0, "ui": 25 * 60.0, "docs": 10 * 60.0]
        let receipt = LeadReceipt(task, ending: .merged, questions: [], usage: usage, memberWorked: worked, now: start + 3600)
        // The totals are the members' sums.
        #expect(receipt.worked == 75 * 60.0)
        let worker = try #require(receipt.worker)
        #expect(worker.input == 15 + 20 + 3 && worker.output == 1500 + 2000 + 700 && worker.cacheRead == 150_000 && worker.cacheWrite == 2000, "\(worker)")
        #expect(worker.sessions == 4 && worker.models == [Self.opus] && worker.total == core.total + ui.total + docs.total)
        #expect(abs((worker.cost ?? -1) - [core, ui, docs].reduce(0) { $0 + ($1.cost ?? .nan) }) < 1e-12)
        #expect(receipt.tokens == worker.total + 4100)
        // Listed per member, the integrator first, each with its own minutes and tokens.
        #expect(receipt.members == [LeadReceipt.Member(name: "core", worked: 2400, worker: core), LeadReceipt.Member(name: "ui", worked: 1500, worker: ui),
                                    LeadReceipt.Member(name: "docs", worked: 600, worker: docs)])
        #expect(receipt.line.contains("1 h 15 min worked") || receipt.line.contains("75 min worked"), "\(receipt.line)")
        let listed = "team of 3: core \(LeadToolset.age(2400)) worked, \(LeadReceipt.count(core.total)) tokens, est. \(LeadReceipt.dollars(core.cost!)); "
            + "ui \(LeadToolset.age(1500)) worked, \(LeadReceipt.count(ui.total)) tokens, est. \(LeadReceipt.dollars(ui.cost!)); "
            + "docs \(LeadToolset.age(600)) worked, \(LeadReceipt.count(docs.total)) tokens, est. \(LeadReceipt.dollars(docs.cost!))"
        #expect(receipt.line.contains(listed), "\(receipt.line)")
        // Never the sessions that aren't the team's workers.
        #expect(!receipt.line.contains("M tokens"), "\(receipt.line)")
        // Kept on the board, and back the same.
        let decoded = try JSONDecoder().decode(LeadReceipt.self, from: JSONEncoder().encode(receipt))
        #expect(decoded == receipt)
        // A batch's totals take the summed receipt.
        var ended = task
        ended.receipt = receipt
        #expect(LeadReceiptTotals([ended])?.worked == 75 * 60.0 && LeadReceiptTotals([ended])?.tokens == receipt.tokens)
    }

    @Test func aMemberNotCountedOrWithNoTranscriptIsSaidSoAndTheTotalFallsBackToTheTasks() throws {
        let start = Date().timeIntervalSince1970
        let response = LeadReceiptTests.response
        try transcript("core-1", name: "worker-team", [response("c1", Self.opus, 10, 1000, 0, 0, 0, start + 10, "s", 0)], slug: "team")
        var task = try teamTask(start: start)
        task.worked = 50 * 60
        let usage = LeadReceipts.usage(root: root, task: task, home: home)
        #expect(usage.members?.keys.sorted() == ["core"])
        let receipt = LeadReceipt(task, ending: .abandoned, questions: [], usage: usage, memberWorked: ["core": 600, "ui": 300], now: start + 3600)
        // docs wasn't counted: the task's own count, not a partial sum.
        #expect(receipt.worked == 50 * 60.0)
        #expect(receipt.worker == usage.members?["core"])
        #expect(receipt.members?.map(\.name) == ["core", "ui", "docs"] && receipt.members?[2].worked == nil && receipt.members?[1].worker == nil)
        #expect(receipt.line.contains("; ui \(LeadToolset.age(300)) worked, tokens unknown; docs time not counted, tokens unknown"), "\(receipt.line)")
        // Usage not read per member (today's receiptUsage): its members are listed with tokens unknown, its total as read.
        let unsplit = LeadReceipt(task, ending: .abandoned, questions: [], usage: Self.usage, now: start + 3600)
        #expect(unsplit.worker == Self.usage.worker && unsplit.members?.count == 3 && unsplit.members?.allSatisfy { $0.worker == nil } == true)
    }

    @Test func aPlainTasksUsageIsReadAsBeforeWithNoMembers() throws {
        let start = Date().timeIntervalSince1970
        try teamFixtures(start: start)
        var task = try teamTask(start: start)
        task.team = nil
        let usage = LeadReceipts.usage(root: root, task: task, home: home)
        #expect(usage == LeadReceipts.usage(root: root, slug: "team", since: start, home: home) && usage.members == nil)
        #expect(LeadReceipt(task, ending: .merged, questions: [], usage: usage, memberWorked: ["core": 1], now: start + 1).members == nil)
    }

    @Test func aReceiptFromBeforeTeamsLoadsWithNoMembers() throws {
        let old = #"{"endedAt":19000,"ending":"merged","mergeReruns":0,"pricesAsOf":"2026-10-06","questions":0,"rerolls":0,"rounds":2,"startedAt":1000,"#
            + #""waitingOnUser":0,"worked":10860,"worker":{"cacheRead":3,"cacheWrite":4,"cacheWrite1h":0,"cost":1.5,"input":1,"models":["claude-opus-5-5"],"output":2,"sessions":1}}"#
        let receipt = try JSONDecoder().decode(LeadReceipt.self, from: Data(old.utf8))
        #expect(receipt.members == nil && receipt.worked == 10860 && receipt.worker?.output == 2)
        #expect(!receipt.line.contains("team of"))
        // And on an older board's task.
        var task = Self.plainTask()
        task.receipt = receipt
        let board = try JSONDecoder().decode(LeadTask.self, from: JSONEncoder().encode(task))
        #expect(board.receipt == receipt)
    }
}
