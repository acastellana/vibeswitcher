import Foundation
import Testing
@testable import VibeCore

/// Each task that ends gets a receipt (see `LeadReceipt`): its time, its worker's and verifier's tokens read from their
/// own transcripts (fixtures here, written as Claude Code writes them), an estimated cost, its rounds, the merge's test
/// count and its rollback point. The scorecard and the all-done card sum a batch's.
struct LeadReceiptTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    /// The scratch home whose `.claude/projects` holds the fixture transcripts.
    let home: String
    init() {
        vault = Self.newVault(in: temp)
        home = temp.url("home").path
    }

    func repo() throws -> String {
        let url = temp.url("lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    // MARK: Fixture transcripts

    static func stamp(_ time: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: time))
    }

    /// One transcript line of an API response, as Claude Code writes it (one per content block, the usage repeated).
    static func response(_ id: String, _ model: String, input: Int, output: Int, read: Int = 0, write: Int = 0, write1h: Int = 0,
                         at time: Double, session: String = "s", block: Int = 0) -> String {
        let usage: [String: Any] = ["input_tokens": input, "output_tokens": output, "cache_read_input_tokens": read,
                                    "cache_creation_input_tokens": write,
                                    "cache_creation": ["ephemeral_1h_input_tokens": write1h, "ephemeral_5m_input_tokens": write - write1h],
                                    "service_tier": "standard", "speed": "standard"]
        let line: [String: Any] = ["type": "assistant", "uuid": UUID().uuidString, "sessionId": session, "timestamp": stamp(time),
                                   "requestId": "req_\(id)", "apiBlockIndex": block,
                                   "message": ["id": id, "model": model, "role": "assistant", "type": "message",
                                               "content": [["type": "text", "text": "SECRET-TRANSCRIPT-TEXT"]], "usage": usage]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), as: UTF8.self)
    }

    static func named(_ name: String, session: String) -> [String] {
        ["{\"type\":\"custom-title\",\"customTitle\":\"\(name)\",\"sessionId\":\"\(session)\"}",
         "{\"type\":\"agent-name\",\"agentName\":\"\(name)\",\"sessionId\":\"\(session)\"}"]
    }

    static func prompt(_ text: String, at time: Double, session: String = "s") -> String {
        "{\"type\":\"user\",\"sessionId\":\"\(session)\",\"timestamp\":\"\(stamp(time))\",\"message\":{\"role\":\"user\",\"content\":\"\(text)\"}}"
    }

    /// Writes `lines` as session `name`'s transcript in Claude's folder for `slug`'s worktree under `root`.
    func transcript(_ session: String, _ lines: [String], root: String, slug: String, subagent: String? = nil) throws {
        var folder = try #require(LeadReceipts.folders(root: root, slug: slug, home: home).first)
        var file = folder.appendingPathComponent("\(session).jsonl")
        if let subagent {
            folder = folder.appendingPathComponent(session).appendingPathComponent("subagents")
            file = folder.appendingPathComponent("agent-\(subagent).jsonl")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// Task `slug`'s sessions as a resumed worker, a verifier with a subagent, and the user's own session in the same
    /// folder, all since `start`.
    func fixtures(root: String, slug: String, start: Double) throws {
        let opus = "claude-opus-5-5"
        let first = Self.response("msg_w1", opus, input: 10, output: 1000, read: 50_000, write: 2000, write1h: 2000, at: start + 10)
        let second = Self.response("msg_w2", opus, input: 5, output: 500, read: 60_000, write: 1000, at: start + 20)
        // The first worker: its first response written twice (two content blocks), a response from before the task
        // (a folder an earlier task of that name left), and a note of Claude Code's own with no tokens.
        try transcript("w-a", Self.named("worker-\(slug)", session: "w-a") + [
            Self.prompt("Your task", at: start + 1),
            Self.response("msg_old", opus, input: 999, output: 999_999, at: start - 86_400),
            first, first.replacingOccurrences(of: "\"apiBlockIndex\":0", with: "\"apiBlockIndex\":1"), second,
            Self.response("msg_syn", "<synthetic>", input: 0, output: 0, at: start + 21),
        ], root: root, slug: slug)
        // Resumed: the new session's transcript copies the earlier responses, then goes on (compacted on the way).
        try transcript("w-b", Self.named("worker-\(slug)", session: "w-b") + [
            first, second,
            "{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"timestamp\":\"\(Self.stamp(start + 30))\"}",
            "{\"type\":\"user\",\"isCompactSummary\":true,\"message\":{\"role\":\"user\",\"content\":\"summary\"}}",
            Self.response("msg_w3", opus, input: 1, output: 2000, read: 70_000, at: start + 40),
        ], root: root, slug: slug)
        try transcript("v-a", Self.named("verify-\(slug)", session: "v-a") + [
            Self.response("msg_v1", "claude-fable-5-1", input: 100, output: 4000, read: 20_000, write: 10_000, at: start + 50),
        ], root: root, slug: slug)
        try transcript("v-a", [Self.response("msg_s1", "claude-haiku-4-5-20251001", input: 1000, output: 100, at: start + 55)],
                       root: root, slug: slug, subagent: "a1")
        // The user's own session in the worktree: never counted, never read past its name.
        try transcript("u-a", Self.named("my-own-look", session: "u-a") + [
            Self.response("msg_u1", opus, input: 5_000_000, output: 5_000_000, at: start + 60),
        ], root: root, slug: slug)
    }

    // MARK: Tokens

    @Test func tokensAreSummedPerRoleAndAResumedOrCompactedSessionCountsOnce() throws {
        let root = try repo()
        let start = Date().timeIntervalSince1970
        try fixtures(root: root, slug: "change", start: start)
        let usage = LeadReceipts.usage(root: root, slug: "change", since: start, home: home)
        let worker = try #require(usage.worker)
        #expect(worker.input == 16 && worker.output == 3500 && worker.cacheRead == 180_000 && worker.cacheWrite == 3000, "\(worker)")
        #expect(worker.cacheWrite1h == 2000 && worker.sessions == 2 && worker.models == ["claude-opus-5-5"])
        // 16 × $4 + 3500 × $20 + 180k × $0.20 + 2000 × $8 (1-hour writes) + 1000 × $5 (5-minute writes), per million.
        #expect(abs((worker.cost ?? -1) - 0.127064) < 1e-9, "\(String(describing: worker.cost))")
        let verifier = try #require(usage.verifier)
        #expect(verifier.input == 1100 && verifier.output == 4100 && verifier.cacheRead == 20_000 && verifier.cacheWrite == 10_000, "\(verifier)")
        #expect(verifier.sessions == 2 && verifier.models == ["claude-fable-5-1", "claude-haiku-4-5-20251001"])
        // Fable 5.1: 100 × $10 + 4000 × $50 + 20k × $0.25 + 10k × $12.50; its Haiku subagent 1000 × $1 + 100 × $5.
        #expect(abs((verifier.cost ?? -1) - 0.3325) < 1e-9, "\(String(describing: verifier.cost))")
    }

    @Test func aFindersTranscriptCountsAsTheVerifiersAndOtherNamesNever() {
        #expect(LeadReceipts.role(named: ["finder2-change"], slug: "change") == .verifier)
        #expect(LeadReceipts.role(named: ["verify-change"], slug: "change") == .verifier)
        #expect(LeadReceipts.role(named: ["worker-change"], slug: "change") == .worker)
        #expect(LeadReceipts.role(named: ["worker-change-two"], slug: "change") == nil)
        #expect(LeadReceipts.role(named: ["finderx-change", "lead"], slug: "change") == nil)
        #expect(LeadReceipts.role(named: [], slug: "change") == nil)
    }

    @Test func anUnknownModelShowsTokensWithCostUnknownNotAWrongNumber() throws {
        let root = try repo()
        let start = Date().timeIntervalSince1970
        try transcript("w", Self.named("worker-x", session: "w") + [
            Self.response("m1", "claude-opus-5-5", input: 10, output: 10, at: start + 1),
            Self.response("m2", "claude-newmodel-9", input: 20, output: 20, at: start + 2),
        ], root: root, slug: "x")
        let usage = LeadReceipts.usage(root: root, slug: "x", since: start, home: home)
        let worker = try #require(usage.worker)
        #expect(worker.total == 60 && worker.cost == nil && worker.unpriced == ["claude-newmodel-9"])
        var task = LeadTask(slug: "x", title: "X", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""))
        task.startedAt = start
        let receipt = LeadReceipt(task, ending: .abandoned, questions: [], usage: usage, now: start + 600)
        #expect(receipt.cost == nil)
        #expect(receipt.line.contains("cost unknown (no price for claude-newmodel-9)"), "\(receipt.line)")
        #expect(!receipt.line.contains("$"), "\(receipt.line)")
        #expect(receipt.line.contains("cost an estimate at prices of \(LeadPrices.asOf)"))
        // Summed, its task's cost stays unknown, never $0.
        task.receipt = receipt
        #expect(LeadReceiptTotals([task])?.text.contains("cost unknown") == true)
    }

    @Test func pricesComeFromOneTableWithTheirDate() {
        #expect(LeadPrices.asOf == "2026-10-06")
        #expect(LeadPrices.price("claude-opus-5-5")?.input == 4)
        #expect(LeadPrices.price("claude-opus-5-5[1m]")?.output == 20)
        #expect(LeadPrices.price("claude-fable-5-1")?.cacheRead == 0.25)
        #expect(LeadPrices.price("claude-haiku-4-5-20251001")?.input == 1)
        #expect(LeadPrices.price("us.anthropic.claude-sonnet-5-5")?.input == 2)
        // A longer name isn't its prefix's model.
        #expect(LeadPrices.price("claude-opus-5-5-mini") == nil)
        #expect(LeadPrices.price("gpt-5") == nil)
    }

    @Test func theMergesTestCountIsReadFromItsOutput() {
        #expect(LeadReceipt.testCount("Test Suite 'All tests' passed\n\t Executed 1234 tests, with 0 failures (0 unexpected) in 12.3 seconds\n"
            + "Test Suite 'Foo' passed\n\t Executed 12 tests, with 0 failures (0 unexpected)\n✔ Test run with 56 tests in 7 suites passed after 3 seconds.") == 1290)
        #expect(LeadReceipt.testCount("ℹ tests 14\nℹ suites 2\nℹ pass 14") == 14)
        #expect(LeadReceipt.testCount("========== 42 passed, 1 skipped in 3.1s ==========") == 42)
        #expect(LeadReceipt.testCount("Tests:       3 skipped, 40 passed, 43 total") == 43)
        #expect(LeadReceipt.testCount("test result: ok. 5 passed; 0 failed\ntest result: ok. 2 passed; 0 failed") == 7)
        #expect(LeadReceipt.testCount("Build complete!") == nil)
    }

    // MARK: Stored when it ends, shown in board(task)

    @Test func aMergedTasksReceiptIsStoredWithTheMergeAndShowsInBoardTask() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.claudeHome = home
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "printf 'Executed 37 tests, with 0 failures (0 unexpected)\\n'"]).isError)
        let onto = Git.run(["rev-parse", "main"], in: root).output
        _ = lead.call("add_task", ["title": "Change", "goal": "it changes", "acceptance": ["it's there"], "review": "none"])
        #expect(!lead.call("start_worker", ["task": "change"]).isError)
        let start = try #require(BoardStore(root: root).load().task("change")).createdAt
        try fixtures(root: root, slug: "change", start: start)
        let worktree = Worktrees.path(root: root, slug: "change")
        for file in ["b.txt", "c.txt"] {
            try "\(file)\n".write(toFile: worktree + "/" + file, atomically: true, encoding: .utf8)
            Git.run(["add", file], in: worktree)
            Git.run(["commit", "-q", "-m", file], in: worktree)
        }
        #expect(!(try seat("worker-change", runtime)).call("report", doneReport("changed")).isError)
        let merged = lead.call("merge", ["task": "change"])
        #expect(!merged.isError, "\(merged.text)")

        let task = try #require(BoardStore(root: root).load().task("change"))
        let receipt = try #require(task.receipt)
        #expect(receipt.ending == .merged && receipt.tests == 37 && receipt.commits == 2 && receipt.mergeReruns == 0)
        #expect(receipt.onto == onto && receipt.commit == task.merged?.commit && receipt.startedAt == task.startedAt)
        #expect(receipt.worker?.output == 3500 && receipt.verifier?.output == 4100)
        #expect(abs((receipt.cost ?? -1) - (0.127064 + 0.3325)) < 1e-9)
        // Numbers only: no transcript text is kept on the board.
        let saved = try String(contentsOfFile: (BoardStore(root: root).folder as NSString).appendingPathComponent("board.json"), encoding: .utf8)
        #expect(!saved.contains("SECRET-TRANSCRIPT-TEXT") && !saved.contains("my-own-look"))

        let shown = lead.call("board", ["task": "change"]).text
        #expect(shown.contains("Receipt (merged; cost an estimate at prices of \(LeadPrices.asOf))"), "\(shown)")
        #expect(shown.contains("worker 187k tokens") && shown.contains("verifier 35.2k tokens") && shown.contains("est. $0.46"), "\(shown)")
        #expect(shown.contains("37 tests in the merge's run") && shown.contains("2 commits \(onto.prefix(8))..") && shown.contains("rollback point \(onto.prefix(8))"), "\(shown)")
        // The board and status sum the batch's.
        #expect(lead.call("board", [:]).text.contains("Receipts (this batch"))
        #expect(lead.call("status", [:]).text.contains("most expensive: Change (est. $0.46)"))
    }

    @Test func aFoldedOrAbandonedTaskGetsItsReceiptWhenItEnds() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.claudeHome = home
        _ = lead.call("add_task", ["title": "Add b", "goal": "b", "acceptance": ["b"]])
        _ = lead.call("add_task", ["title": "Add c", "goal": "c", "acceptance": ["c"]])
        _ = lead.call("add_task", ["title": "Add d", "goal": "d", "acceptance": ["d"]])
        let start = try #require(BoardStore(root: root).load().task("add-b")).createdAt
        try transcript("w", Self.named("worker-add-b", session: "w") + [Self.response("m1", "claude-opus-5-5", input: 1, output: 100, at: start + 1)],
                       root: root, slug: "add-b")
        #expect(!lead.call("update_task", ["task": "add-b", "status": "folded", "into": "add-c"]).isError)
        let folded = try #require(BoardStore(root: root).load().task("add-b")?.receipt)
        #expect(folded.ending == .folded && folded.worker?.output == 100 && folded.verifier == nil && folded.commit == nil)
        #expect(lead.call("board", ["task": "add-b"]).text.contains("Receipt (folded"))

        #expect(!lead.call("update_task", ["task": "add-d", "status": "abandoned", "reason": "not wanted"]).isError)
        let abandoned = try #require(BoardStore(root: root).load().task("add-d")?.receipt)
        // No session ever ran: its tokens are unknown, said so, never zeros.
        #expect(abandoned.ending == .abandoned && abandoned.worker == nil && abandoned.cost == nil)
        #expect(abandoned.line.contains("tokens unknown (no transcripts of its sessions found)") && !abandoned.line.contains("0 tokens"), "\(abandoned.line)")
        // Never started, no working time counted: neither time is shown as 0.
        #expect(!abandoned.line.contains("worked") && !abandoned.line.contains("wall"), "\(abandoned.line)")
    }

    @Test func aTaskReopenedAndEndedAgainCountsEveryRoundNotItsFirstEnding() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.claudeHome = home
        _ = lead.call("add_task", ["title": "Add b", "goal": "b", "acceptance": ["b"]])
        _ = lead.call("add_task", ["title": "Add c", "goal": "c", "acceptance": ["c"]])
        let start = try #require(BoardStore(root: root).load().task("add-b")).createdAt
        try transcript("w1", Self.named("worker-add-b", session: "w1") + [Self.response("m1", "claude-opus-5-5", input: 1, output: 100, at: start + 1)],
                       root: root, slug: "add-b")
        #expect(!lead.call("update_task", ["task": "add-b", "status": "abandoned", "reason": "not now"]).isError)
        #expect(BoardStore(root: root).load().task("add-b")?.receipt?.worker?.output == 100)
        // Reopened: an open task has no receipt.
        #expect(!lead.call("update_task", ["task": "add-b", "status": "planned"]).isError)
        #expect(BoardStore(root: root).load().task("add-b")?.receipt == nil)
        #expect(!lead.call("board", ["task": "add-b"]).text.contains("Receipt ("))
        // A second round of work, then it ends again, folded this time: both rounds, and how it ended now.
        try transcript("w2", Self.named("worker-add-b", session: "w2") + [Self.response("m2", "claude-opus-5-5", input: 1, output: 200, at: start + 2)],
                       root: root, slug: "add-b")
        #expect(!lead.call("update_task", ["task": "add-b", "status": "folded", "into": "add-c"]).isError)
        let receipt = try #require(BoardStore(root: root).load().task("add-b")?.receipt)
        #expect(receipt.ending == .folded && receipt.worker?.output == 300 && receipt.worker?.sessions == 2, "\(receipt)")
    }

    // MARK: Tasks from before receipts

    @Test func aTaskMergedBeforeReceiptsShowsNothingNotZeros() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        // An older board's merged task: no receipt field at all.
        var old = LeadTask(slug: "old", title: "Old", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""), status: .done)
        old.merged = LeadMergeRecord(commit: "abc", tested: true)
        try BoardStore(root: root).update { $0.tasks = [old] }
        #expect(!(String(decoding: try JSONEncoder().encode(old), as: UTF8.self)).contains("receipt"))
        let shown = lead.call("board", ["task": "old"]).text
        #expect(!shown.contains("Receipt") && !shown.contains("receipt"), "\(shown)")
        #expect(!lead.call("board", [:]).text.contains("Receipts"))
        #expect(!lead.call("status", [:]).text.contains("Receipts"))
        let board = BoardStore(root: root).load()
        #expect(LeadReceiptTotals(board.tasks) == nil && LeadReceiptTotals.line(board) == nil)
        // Nor does its all-done card.
        var previous = board
        previous.tasks[0].status = .running
        #expect(BatchSummary.detect(previous: previous, current: board, now: Date().timeIntervalSince1970 + 1)?.receipts == nil)
    }

    // MARK: A batch's totals

    func ended(_ slug: String, title: String, worked: Double, output: Int, model: String = "claude-opus-5-5", at: Double) -> LeadTask {
        var task = LeadTask(slug: slug, title: title, contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""), status: .done)
        task.createdAt = at - 3600
        task.since = at
        task.merged = LeadMergeRecord(commit: "c-\(slug)", tested: true)
        let tokens = LeadTokens(output: output, sessions: 1, models: [model], cost: LeadPrices.price(model).map { Double(output) * $0.output / 1_000_000 },
                                unpriced: LeadPrices.price(model) == nil ? [model] : nil)
        task.receipt = LeadReceipt(ending: .merged, startedAt: at - 3600, endedAt: at, worked: worked, worker: tokens, verifier: nil)
        return task
    }

    @Test func theAllDoneCardAndStatusSumTheBatchAndNameItsMostExpensiveTask() throws {
        let now = Date().timeIntervalSince1970
        var board = LeadBoard()
        board.tasks = [ended("a", title: "Cheap one", worked: 1800, output: 10_000, at: now - 300),
                       ended("b", title: "Every task gets a receipt", worked: 5400, output: 500_000, at: now - 200),
                       ended("c", title: "Odd model", worked: 3600, output: 1_000_000, model: "claude-unknown", at: now - 100)]
        var previous = board
        previous.tasks[2].status = .running
        let mark = try #require(BatchSummary.detect(previous: previous, current: board, now: now))
        let totals = try #require(mark.receipts)
        #expect(totals.tasks == 3 && totals.worked == 10_800 && totals.tokens == 1_510_000 && totals.unpriced == 1)
        #expect(abs(totals.cost - 10.2) < 1e-9 && totals.top == "b")
        #expect(totals.text == "3 tasks, 3.0 h of worker time, 1.5M tokens, est. $10.20 (+ 1 task of unknown cost); most expensive: Every task gets a receipt (est. $10.00)",
                "\(totals.text)")
        // Status's line: the batch since the last card; once a card is made, that card's batch.
        #expect(LeadReceiptTotals.line(board)?.hasPrefix("Receipts (this batch; costs are estimates at prices of \(LeadPrices.asOf)): 3 tasks") == true)
        board.allDone = [mark]
        let line = try #require(LeadReceiptTotals.line(board))
        #expect(line.hasPrefix("Receipts (last batch, all done at \(LeadBoard.clock(now))") && line.contains("most expensive: Every task gets a receipt"), "\(line)")
    }

    @Test func aTasksReceiptLineSaysItsTimeRoundsQuestionsAndRollbackPoint() {
        var task = LeadTask(slug: "t", title: "T", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""), status: .done)
        task.startedAt = 1000
        task.worked = 3 * 3600 + 60
        var audits = LeadAuditLedger()
        audits.rounds = 2
        task.audits = audits
        task.rerolls = [LeadReroll(archive: "agent/t-1", commit: nil, round: 0)]
        task.merged = LeadMergeRecord(commit: "1234567890ab", tested: true, onto: "abcdef123456")
        var question = LeadQuestion(id: "q1", text: "?", options: [], at: 2000)
        question.task = "t"
        question.answer = "yes"
        question.answeredAt = 2240
        let usage = LeadReceipts.Usage(worker: LeadTokens(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, sessions: 1, models: ["claude-opus-5-5"], cost: 1.5))
        let receipt = LeadReceipt(task, ending: .merged, questions: [question], usage: usage, tests: 9, mergeReruns: 1, commits: 3, now: 1000 + 5 * 3600)
        #expect(receipt.wall == 5 * 3600 && receipt.rounds == 2 && receipt.rerolls == 1 && receipt.questions == 1 && receipt.waitingOnUser == 240)
        #expect(receipt.line == "Receipt (merged; cost an estimate at prices of \(LeadPrices.asOf)): 3 h 1 min worked, 5 h wall · "
            + "worker 10 tokens (in 1, out 2, cache read 3, cache write 4; claude-opus-5-5) · est. $1.50 · 2 audit rounds, 1 re-roll, 1 merge rerun · "
            + "9 tests in the merge's run · 1 question to you, 4.0 min waiting · 3 commits abcdef12..12345678; rollback point abcdef12", "\(receipt.line)")
    }
}
