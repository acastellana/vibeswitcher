import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The lead controller's look every 3 s on the main thread: a board or decisions file is read again only when it changed.
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

    @Test func aMissingBoardIsAnEmptyOneAndIsLookedForAgain() throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var files = LeadFiles()
        #expect(files.board(root) == LeadBoard())
        try BoardStore(root: root).update { $0.baseBranch = "main" }
        #expect(files.board(root).baseBranch == "main")
    }
}
