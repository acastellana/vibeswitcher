import Foundation
import Testing
import VibeCore
import VibeNode

/// The engine's look at the boards, on its reads queue (`LeadReads`), never its own (the app's `LeadFilesTests`, its
/// six board cases, ported: "off the main thread" is "off the engine queue", EN-D1): a board is read again only when it
/// changed, and what's read is handed to the engine's queue. Not `linuxOnly`: the Mac runs it.
struct BoardFilesTests {
    let scratch = Scratch()

    private func newRoot() throws -> String {
        let root = scratch.url("board-files").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    @Test func anUnchangedBoardIsNotReadAgain() throws {
        let root = try newRoot()
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

    /// The engine's queue, and a way to tell whether code runs on it.
    struct EngineQueue {
        let queue = DispatchQueue(label: "test.engine")
        let key = DispatchSpecificKey<Bool>()
        init() { queue.setSpecific(key: key, value: true) }
        var onIt: Bool { DispatchQueue.getSpecific(key: key) == true }
    }

    /// What `reads` hands the engine's queue, whether it read on that queue, and whether it was handed there.
    private func read<T: Sendable>(_ reads: LeadReads, _ engine: EngineQueue, _ work: @escaping (inout LeadFiles) -> T) async
        -> (value: T, onEngine: Bool, handedOnEngine: Bool)? {
        let result = Locked<(value: T, onEngine: Bool, handedOnEngine: Bool)?>(nil)
        reads.async({ files in (work(&files), engine.onIt) }) { value, onEngine in
            result.value = (value, onEngine, engine.onIt)
        }
        _ = await eventually(timeout: 60) { result.value != nil }
        return result.value
    }

    @Test func boardsAreReadOffTheEngineQueueAndHandedToIt() async throws {
        let root = try newRoot()
        let store = BoardStore(root: root)
        try store.update { $0.baseBranch = "main" }
        let engine = EngineQueue()
        let reads = LeadReads(handTo: engine.queue)
        let first = try #require(await read(reads, engine) { $0.board(root) })
        #expect(first.value.baseBranch == "main")
        #expect(!first.onEngine && first.handedOnEngine)
        // A write through the same queue is seen by the read after it.
        reads.async { _ in try? store.update { $0.baseBranch = "develop" } }
        #expect(try #require(await read(reads, engine) { $0.board(root) }).value.baseBranch == "develop")
    }

    @Test func aBoardThatDoesntReadIsShownEmptyAsBefore() async throws {
        let root = try newRoot()
        let store = BoardStore(root: root)
        try FileManager.default.createDirectory(atPath: store.folder, withIntermediateDirectories: true)
        try Data("{ not a board".utf8).write(to: URL(fileURLWithPath: (store.folder as NSString).appendingPathComponent("board.json")))
        #expect(throws: BoardError.self) { try store.read() }
        let engine = EngineQueue()
        let shown = try #require(await read(LeadReads(handTo: engine.queue), engine) { $0.board(root) })
        #expect(shown.value == LeadBoard())
        #expect(shown.handedOnEngine)
    }

    /// Whom to deliver to: only the lead's fields, the same as the whole board says, and read again only when the board
    /// changed.
    @Test func theLeadsNameIsReadAloneAndOnlyWhenTheBoardChanged() throws {
        let root = try newRoot()
        let store = BoardStore(root: root)
        try store.update { board in
            board.leadPid = 4242
            board.leadTTY = "ttypts4"
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
        let root = try newRoot()
        let store = BoardStore(root: root)
        try FileManager.default.createDirectory(atPath: store.folder, withIntermediateDirectories: true)
        try Data("{ \"leadPid\": 1, not a board".utf8).write(to: URL(fileURLWithPath: (store.folder as NSString).appendingPathComponent("board.json")))
        #expect(store.loadLead() == LeadBoard())
        var names = LeadNames()
        #expect(LeadHandover.named(names.board(root)) == nil)
    }

    @Test func aMissingBoardIsAnEmptyOneAndIsLookedForAgain() throws {
        let root = try newRoot()
        var files = LeadFiles()
        #expect(files.board(root) == LeadBoard())
        try BoardStore(root: root).update { $0.baseBranch = "main" }
        #expect(files.board(root).baseBranch == "main")
    }
}
