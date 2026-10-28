import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The app's side of the board's archive (`BoardStore.archive`): its Team rows, history and sidebar summary come from
/// board.json alone, which holds the live tasks and the last day's finished ones (and slim copies of the open
/// batch's archived ones, for its card and cost); nothing in the app reads the archive.
struct TeamArchiveTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/VibeSwitcher")

    /// Every file of the app's sources that reads the archive, by the calls that do.
    static func archiveReaders() throws -> [String: Int] {
        let calls = try Regex(#"\.(archived|loadAll|withArchive|archive|restore|takenSlugs)\("#)
        var found: [String: Int] = [:]
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let count = try String(contentsOf: url, encoding: .utf8).matches(of: calls).count
            if count > 0 { found[url.lastPathComponent] = count }
        }
        return found
    }

    @Test func nothingInTheAppReadsTheArchive() throws {
        // Its rows, history, summaries, scorecard, batch cost and all-done cards come from board.json alone.
        #expect(try Self.archiveReaders() == [:])
    }

    @Test func theTeamRowsAreBoardJSONsTasksAfterTheArchive() throws {
        let now = TeamRowsTests.now.timeIntervalSince1970
        let root = scratchRoot.appendingPathComponent("team-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        let store = BoardStore(root: root.path)
        var board = LeadBoard()
        for index in 0..<40 {
            var task = TeamRowsTests.task("old-\(index)", .done, since: 3 * 86_400 - Double(index))
            task.worktree = nil
            task.merged = LeadMergeRecord(commit: "c\(index)", tested: true, at: task.since ?? 0)
            board.tasks.append(task)
        }
        var recent = TeamRowsTests.task("recent", .done, since: 3_600)
        recent.worktree = nil
        board.tasks += [recent, TeamRowsTests.task("work", .running), TeamRowsTests.task("next", .planned)]
        try store.locked { try store.write(board) }
        #expect(try store.archive(now: now) == 40)

        let read = store.load()
        let cache = TeamRowsCache()
        let seen = TeamSeen(members: ["w-work": TeamRowsTests.member()], listed: true)
        let rows = cache.rows("/r", board: read, seen: seen)
        #expect(rows.map(\.id) == ["work", "next", "recent"])
        #expect(TeamHistory(read).rows.map(\.id) == ["recent"])
        #expect(TeamRows.summary(rows) == TeamRows.summary(TeamRows.rows(board, seen: seen).filter { !$0.id.hasPrefix("old-") }))
        // The Team tab's scorecard still counts every merge, from board.json alone.
        #expect(LeadScorecard(read, now: now).merged == 40)
    }

    /// Measures what the archive saves on a copy of a real board (`VIBESWITCHER_BOARD_COPY=<a copy of board.json>`;
    /// the copy is copied again into a scratch folder, so neither file is changed): board.json's size and decode time,
    /// and `TeamRowsCache.rows` and `LeadBoard.isSame` (with a whole `==` for comparison), before and after.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBESWITCHER_BOARD_COPY"] != nil))
    func measureARealBoardBeforeAndAfterTheArchive() throws {
        let copy = try #require(ProcessInfo.processInfo.environment["VIBESWITCHER_BOARD_COPY"])
        let root = scratchRoot.appendingPathComponent("board-measure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        let store = BoardStore(root: root.path)
        try store.locked { try FileManager.default.copyItem(atPath: copy, toPath: store.file) }

        func median(_ body: () -> Void) -> Double {
            let clock = ContinuousClock()
            let times = (0..<7).map { _ in clock.measure(body) }.sorted()
            let mid = times[times.count / 2].components
            return Double(mid.seconds) * 1_000 + Double(mid.attoseconds) / 1e15
        }
        func measure(_ label: String) throws -> String {
            let data = try Data(contentsOf: URL(fileURLWithPath: store.file))
            let decode = median { _ = try? JSONDecoder().decode(LeadBoard.self, from: data) }
            let board = try JSONDecoder().decode(LeadBoard.self, from: data)
            let again = try JSONDecoder().decode(LeadBoard.self, from: data)
            let seen = TeamSeen(members: [:], listed: true)
            // A new cache each time: rows made from scratch (TeamHistory included), as for a board just read.
            let rows = median { _ = TeamRowsCache().rows("/r", board: board, seen: seen) }
            var same = false, equal = false
            let isSame = median { same = board.isSame(as: again) }
            let whole = median { equal = board == again }
            #expect(!same && equal)
            return String(format: "%@: board.json %.2f MB, %d tasks; decode %.1f ms; TeamRowsCache.rows %.2f ms; isSame %.4f ms (whole == %.2f ms)",
                          label, Double(data.count) / 1_048_576, board.tasks.count, decode, rows, isSame, whole)
        }
        let before = try measure("before")
        let moved = try store.archive()
        let after = try measure("after")
        let archive = (try? FileManager.default.attributesOfItem(atPath: store.archiveFile)[.size] as? Int) ?? 0
        print("board-measure \(before)")
        print("board-measure \(after) (\(moved) tasks to board-archive.jsonl, \(String(format: "%.2f", Double(archive) / 1_048_576)) MB)")
    }
}
