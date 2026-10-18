import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The lead controller's look every 3 s, off the main thread (`LeadReads`): a board or decisions file is read again only
/// when it changed, and what's read is handed to the main thread.
struct LeadFilesTests {
    private func scratchRoot() throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lead-files-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    @Test func anUnchangedBoardIsNotReadAgain() throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = BoardStore(root: root)
        try store.update { $0.baseBranch = "main" }
        try store.appendDecision("Ship it", why: "It works.")
        var files = LeadFiles()
        #expect(files.board(root).baseBranch == "main")
        #expect(files.decisions(root).map(\.text) == ["Ship it"])
        #expect(files.fileReads == 2)
        for _ in 0..<5 {
            _ = files.board(root)
            _ = files.decisions(root)
        }
        #expect(files.fileReads == 2)
        // Written again (the lead's tools): read again, once.
        try store.update { $0.baseBranch = "develop" }
        try store.appendDecision("Keep going", why: "")
        #expect(files.board(root).baseBranch == "develop")
        #expect(files.decisions(root).map(\.text) == ["Ship it", "Keep going"])
        #expect(files.board(root).baseBranch == "develop")
        #expect(files.fileReads == 4)
    }

    /// What `reads` hands the main thread, and whether it read on the main thread.
    @MainActor
    private func read<T>(_ reads: LeadReads, _ work: @escaping (inout LeadFiles) -> T) async -> (value: T, onMain: Bool, handedOnMain: Bool)? {
        var result: (value: T, onMain: Bool, handedOnMain: Bool)?
        reads.async({ files in (work(&files), Thread.isMainThread) }) { value, onMain in
            result = (value, onMain, Thread.isMainThread)
        }
        _ = await until { result != nil }
        return result
    }

    @Test @MainActor func boardsAreReadOffTheMainThreadAndHandedToIt() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = BoardStore(root: root)
        try store.update { $0.baseBranch = "main" }
        let reads = LeadReads()
        let first = try #require(await read(reads) { $0.board(root) })
        #expect(first.value.baseBranch == "main")
        #expect(!first.onMain && first.handedOnMain)
        // A write through the same queue is seen by the read after it.
        reads.async { _ in try? store.update { $0.baseBranch = "develop" } }
        #expect(try #require(await read(reads) { $0.board(root) }).value.baseBranch == "develop")
    }

    @Test @MainActor func aBoardThatDoesntReadIsShownEmptyAsBefore() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = BoardStore(root: root)
        try FileManager.default.createDirectory(atPath: store.folder, withIntermediateDirectories: true)
        try Data("{ not a board".utf8).write(to: URL(fileURLWithPath: (store.folder as NSString).appendingPathComponent("board.json")))
        #expect(throws: BoardError.self) { try store.read() }
        let shown = try #require(await read(LeadReads()) { $0.board(root) })
        #expect(shown.value == LeadBoard())
        #expect(shown.handedOnMain)
    }

    /// Whom to deliver to, read on the main thread: only the lead's fields, the same as the whole board says, and read
    /// again only when the board changed.
    @Test func theLeadsNameIsReadAloneAndOnlyWhenTheBoardChanged() throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = BoardStore(root: root)
        try store.update { board in
            board.leadPid = 4242
            board.leadTTY = "ttys004"
            board.leadSession = "S1"
            board.baseBranch = "main"
            board.reports = [LeadReport(about: "worker a", text: String(repeating: "report ", count: 2000))]
        }
        var names = LeadNames()
        let named = names.board(root)
        #expect(LeadHandover.named(named) == LeadHandover.named(store.load()))
        #expect(named.leadSession == "S1" && named.baseBranch == nil && named.reports == nil)
        _ = names.board(root)
        #expect(names.fileReads == 1)
        try store.update { LeadHandover.release(&$0) }
        #expect(LeadHandover.named(names.board(root)) == nil)
        #expect(names.fileReads == 2)
    }

    @Test func aBoardThatDoesntReadNamesNoLead() throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = BoardStore(root: root)
        try FileManager.default.createDirectory(atPath: store.folder, withIntermediateDirectories: true)
        try Data("{ \"leadPid\": 1, not a board".utf8).write(to: URL(fileURLWithPath: (store.folder as NSString).appendingPathComponent("board.json")))
        #expect(store.loadLead() == LeadBoard())
        var names = LeadNames()
        #expect(LeadHandover.named(names.board(root)) == nil)
    }

    @Test func aMissingBoardIsAnEmptyOneAndIsLookedForAgain() throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var files = LeadFiles()
        #expect(files.board(root) == LeadBoard())
        try BoardStore(root: root).update { $0.baseBranch = "main" }
        #expect(files.board(root).baseBranch == "main")
    }
}
