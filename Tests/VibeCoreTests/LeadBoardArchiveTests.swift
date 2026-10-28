import Foundation
import Testing
@testable import VibeCore

/// The board's archive (`BoardStore.archive`): finished tasks a day old leave board.json for board-archive.jsonl,
/// appended under the board's lock; the scorecard and receipts still count them, and nothing is lost or doubled by a
/// crash part way.
struct LeadBoardArchiveTests {
    let temp = Scratch()
    let now = 2_000_000_000.0

    func store() throws -> BoardStore {
        let url = temp.url("archive")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        return BoardStore(root: url.path)
    }

    /// A task that took `status` at `finished` (made an hour before); a merged one passed its audit in `rounds`.
    static func task(_ slug: String, _ status: LeadTask.Status, finished: Double, rounds: Int = 1, report: String? = nil) -> LeadTask {
        let report = report ?? "report of \(slug)"
        var task = LeadTask(id: "id-\(slug)", slug: slug, title: "Task \(slug)",
                            contract: LeadContract(goal: "goal of \(slug)", acceptance: ["check"], boundaries: [], context: ""), status: status)
        task.createdAt = finished - 3_600
        task.since = finished
        task.report = report
        if [.done, .reverted].contains(status) {
            task.merged = LeadMergeRecord(commit: "c-\(slug)", tested: slug.hasSuffix("untested") ? false : true, onto: "o-\(slug)",
                                          audited: rounds == 0 ? false : nil, at: finished)
            task.receipt = LeadReceipt(ending: .merged, startedAt: finished - 3_000, endedAt: finished, worked: 1_800,
                                       worker: LeadTokens(input: 1_000, output: 200, cost: 0.5), verifier: nil)
            if rounds > 0 {
                var audits = LeadAuditLedger()
                audits.rounds = rounds
                audits.passed = true
                task.audits = audits
            }
        }
        if status == .reverted { task.merged?.revertedBy = "r-\(slug)" }
        if status == .folded { task.foldedInto = "live-run" }
        if status == .abandoned { task.abandonedBecause = "not wanted" }
        return task
    }

    /// A board with each live state, recent and old finished tasks, and an old merged task whose worktree is still
    /// there.
    func board() -> LeadBoard {
        let old = now - 2 * 86_400, recent = now - 3_600
        var board = LeadBoard()
        board.tasks = [
            Self.task("old-done", .done, finished: old - 50, rounds: 2),
            Self.task("old-first", .done, finished: old - 40, rounds: 1),
            Self.task("old-untested", .done, finished: old - 30, rounds: 0),
            Self.task("old-folded", .folded, finished: old - 20),
            Self.task("old-abandoned", .abandoned, finished: old - 10),
            Self.task("old-reverted", .reverted, finished: old),
            Self.task("live-planned", .planned, finished: old),
            Self.task("live-run", .running, finished: old),
            Self.task("live-review", .review, finished: old),
            Self.task("live-kept", .kept, finished: old),
            Self.task("live-blocked", .blocked, finished: old),
            Self.task("live-failed", .failed, finished: old),
        ]
        // A failed task's worktree waits on the lead's decision (one cleaned up after failing is abandoned).
        board.tasks[board.tasks.count - 1].worktree = "/somewhere/worktrees/live-failed"
        var unclean = Self.task("old-unclean", .done, finished: old)
        unclean.worktree = "/somewhere/worktrees/old-unclean"
        board.tasks += [unclean, Self.task("recent-done", .done, finished: recent, rounds: 3)]
        board.ask("Which?", options: ["a", "b"], priority: nil, whyNow: nil, task: "old-done", at: old - 100)
        return board
    }

    static let movedSlugs = ["old-done", "old-first", "old-untested", "old-folded", "old-abandoned", "old-reverted"]

    func lines(_ store: BoardStore) -> [String] {
        ((try? String(contentsOfFile: store.archiveFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func ids(_ store: BoardStore) -> [String] {
        lines(store).compactMap { try? JSONDecoder().decode(LeadTask.self, from: Data($0.utf8)).id }
    }

    @Test func finishedTasksADayOldMoveToTheArchiveAndTheRestStay() throws {
        let store = try store()
        let before = board()
        try store.locked { try store.write(before) }
        #expect(try store.archive(now: now) == Self.movedSlugs.count)
        let after = store.load()
        #expect(after.tasks.map(\.slug) == ["live-planned", "live-run", "live-review", "live-kept", "live-blocked", "live-failed", "old-unclean", "recent-done"])
        #expect(store.archived().map(\.slug) == Self.movedSlugs)
        #expect(ids(store) == Self.movedSlugs.map { "id-\($0)" })
        // Each moved whole, its fields as they were.
        #expect(store.archived() == before.tasks.filter { Self.movedSlugs.contains($0.slug) })
        // The board and its archive are every task, in the order they were made.
        #expect(store.loadAll().tasks == before.tasks)
        // The archive is private, as the board is.
        let mode = try FileManager.default.attributesOfItem(atPath: store.archiveFile)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // Again: nothing more is due.
        #expect(try store.archive(now: now) == 0)
        #expect(lines(store).count == Self.movedSlugs.count)
    }

    @Test func theScorecardAndReceiptsStillCountArchivedTasks() throws {
        let store = try store()
        let before = board()
        try store.locked { try store.write(before) }
        try store.archive(now: now)
        let after = store.load()
        // board.json alone, as the app reads it: its tally carries the archived merges.
        #expect(LeadScorecard(after, now: now) == LeadScorecard(before, now: now))
        #expect(LeadScorecard(before, now: now).merged == 6 && LeadScorecard(before, now: now).reverts == 1)
        // With the archive, as the lead's tools read it: the same numbers, nothing counted twice.
        #expect(LeadScorecard(store.loadAll(), now: now) == LeadScorecard(before, now: now))
        #expect(LeadReceiptTotals.line(store.loadAll()) == LeadReceiptTotals.line(before))
        #expect(LeadReceiptTotals.line(before) != nil)
        // The last all-done card's batch archived: its receipts as the card kept them.
        var marked = after
        var mark = LeadAllDone(at: now - 86_000, since: now - 3 * 86_400,
                               tasks: ["old-done", "old-first"].map { .init(slug: $0, title: $0, outcome: .merged) })
        mark.receipts = LeadReceiptTotals(before.tasks.filter { ["old-done", "old-first"].contains($0.slug) })
        marked.allDone = [mark]
        marked.tasks.removeAll { $0.slug == "recent-done" }
        #expect(LeadReceiptTotals.current(marked)?.totals == mark.receipts)
    }

    @Test func aCrashPartWayLosesNothingAndDuplicatesNothing() throws {
        let store = try store()
        let before = board()
        try store.locked { try store.write(before) }
        // A crash after the archive took some lines and before board.json was written: two whole lines, the third cut.
        let leaving = before.tasks.filter { Self.movedSlugs.contains($0.slug) }
        let encoder = JSONEncoder()
        var written = Data()
        for task in leaving.prefix(2) { written += try encoder.encode(task) + Data([0x0A]) }
        written += try encoder.encode(leaving[2]).prefix(40)
        try VibePaths.writePrivate(written, to: URL(fileURLWithPath: store.archiveFile))
        #expect(store.load().tasks.count == before.tasks.count)
        // What reads the archive meanwhile sees the whole lines only, and the board's copy wins.
        #expect(store.archived().map(\.slug) == ["old-done", "old-first"])
        #expect(store.loadAll().tasks == before.tasks)
        // The next run finishes the move: each task once, the cut line gone, the scores counted once.
        #expect(try store.archive(now: now) == Self.movedSlugs.count)
        #expect(ids(store) == Self.movedSlugs.map { "id-\($0)" })
        #expect(lines(store).allSatisfy { (try? JSONDecoder().decode(LeadTask.self, from: Data($0.utf8))) != nil })
        #expect(store.archived() == leaving)
        #expect(LeadScorecard(store.load(), now: now) == LeadScorecard(before, now: now))

        // A crash after every line and before board.json: the next run appends nothing.
        try store.locked { try store.write(before) }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: store.archiveFile))
        #expect(try store.archive(now: now) == Self.movedSlugs.count)
        #expect(try Data(contentsOf: URL(fileURLWithPath: store.archiveFile)) == bytes)
        #expect(LeadScorecard(store.load(), now: now) == LeadScorecard(before, now: now))
    }

    @Test func theArchiveIsOnlyAppendedTo() throws {
        let store = try store()
        try store.locked { try store.write(board()) }
        try store.archive(now: now)
        let first = try Data(contentsOf: URL(fileURLWithPath: store.archiveFile))
        // A day on, recent-done goes too: after what's there.
        #expect(try store.archive(now: now + 86_400) == 1)
        let second = try Data(contentsOf: URL(fileURLWithPath: store.archiveFile))
        #expect(second.count > first.count && second.prefix(first.count) == first)
        #expect(store.archived().map(\.slug) == Self.movedSlugs + ["recent-done"])
    }

    @Test func anArchivedTaskBroughtBackChangesOnTheBoardAndLeavesAgain() throws {
        let store = try store()
        let before = board()
        try store.locked { try store.write(before) }
        try store.archive(now: now)
        let started = Date().timeIntervalSince1970
        try store.update { board in
            let index = try #require(store.restore("old-first", into: &board))
            #expect(board.tasks[index].slug == "old-first")
            board.tasks[index].status = .reverted
            board.tasks[index].merged?.revertedBy = "r-first"
        }
        let board = store.load()
        let back = try #require(board.task("old-first"))
        // Its status changed now (not when it was made), and it sits where it was made among the board's tasks.
        #expect((back.since ?? 0) >= started)
        #expect(board.tasks.first?.slug == "old-first")
        var copy = board
        #expect(store.restore("nowhere", into: &copy) == nil)
        // Counted once: on the board now, out of the tally.
        #expect(LeadScorecard(board, now: now).merged == 6 && LeadScorecard(board, now: now).reverts == 2)
        #expect(LeadScorecard(store.loadAll(), now: now) == LeadScorecard(board, now: now))
        #expect(store.loadAll().task("old-first")?.status == .reverted)
        // A day after its revert it leaves again: its new line after the old one, which counts.
        #expect(try store.archive(now: (back.since ?? now) + BoardStore.archiveAge + 1) >= 1)
        #expect(ids(store).filter { $0 == "id-old-first" }.count == 2)
        #expect(store.archived().first { $0.slug == "old-first" }?.status == .reverted)
        #expect(store.archived().filter { $0.slug == "old-first" }.count == 1)
        #expect(LeadScorecard(store.load(), now: now).reverts == 2)
    }

    @Test func anArchivedSlugIsNeverMadeAgain() throws {
        let store = try store()
        try store.locked { try store.write(board()) }
        try store.archive(now: now)
        #expect(store.load().task("old-done") == nil)
        #expect(Slug.make("Old done", taken: store.takenSlugs(store.load())) == "old-done-2")
    }

    @Test func theOpenBatchsCardAndCostAreToldFromBoardJSONAlone() throws {
        let store = try store()
        var board = board()
        // The last card was three days ago: the batch since is every finished task here.
        board.allDone = [LeadAllDone(at: now - 3 * 86_400, since: now - 4 * 86_400, tasks: [])]
        try store.locked { try store.write(board) }
        let cost = LeadReceiptTotals.current(board)
        let batch = BatchSummary.batch(board).map(\.slug)
        try store.archive(now: now)
        // board.json alone, as the app reads it: the batch, its cost line and its card as before the archive.
        let read = store.load()
        let text = try String(contentsOfFile: store.file, encoding: .utf8)
        // What the batch reads of its archived tasks stays, not the rest of them (their reports, their contexts).
        #expect(text.contains("goal of old-done") && !text.contains("report of old-done"))
        #expect(Set(BatchSummary.batch(read).map(\.slug)) == Set(batch))
        #expect(LeadReceiptTotals.current(read)?.totals == cost?.totals && cost != nil)
        var previous = read
        previous.tasks = previous.tasks.filter { !["live-planned", "live-run", "live-review", "live-kept", "live-blocked", "live-failed"].contains($0.slug) }
        var cleared = previous
        previous.tasks.append(Self.task("live-run", .running, finished: now))
        let mark = try #require(BatchSummary.mark(&cleared, previous: previous, now: now))
        #expect(Set(mark.tasks.map(\.slug)) == Set(batch))
        #expect(BatchSummary.input(mark, board: cleared, project: "p").tasks.contains { $0.goal == "goal of old-done" })
        // The card holds the batch now: its copies go with the next archive.
        try store.locked { try store.write(cleared) }
        #expect(try store.archive(now: now + 86_400) == 1)
        #expect(!(try String(contentsOfFile: store.file, encoding: .utf8)).contains("goal of old-done"))
    }

    @Test func aFailedTaskStaysOnTheBoard() throws {
        let store = try store()
        var board = LeadBoard()
        var failed = Self.task("cleaned-failed", .failed, finished: now - 3 * 86_400)
        failed.worker = "w"
        board.tasks = [failed]
        try store.locked { try store.write(board) }
        #expect(try store.archive(now: now) == 0)
        #expect(store.load().task("cleaned-failed") != nil)
    }
}
