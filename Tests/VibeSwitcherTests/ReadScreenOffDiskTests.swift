import Foundation
import Testing

/// hang-20261031-102359: the window's each-second `followChat` → `readScreen` read the selected Claude session's hook
/// state file on the main thread, to tell whether its agent is idle for steering; under memory pressure that read held
/// the window for 4 s. The state comes from the store's scan now (`Session.hookEvent`, read off main). Scans the
/// controller's source, so a file read that comes back on that path fails here.
struct ReadScreenOffDiskTests {
    static let controller = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/VibeSwitcher/MainWindow/MainWindowController.swift")

    /// What reads a file: a hook state, its path, or any file's contents.
    static let fileReads = ["HookState.load(", "VibePaths.stateFile(", "contentsOf:", "FileManager.default.contents(",
                            "FileHandle(forReadingAtPath:", "FileHandle(forReadingFrom:"]

    @Test func readScreenAndFollowChatReadNoFileAndTakeTheStoresHookEvent() throws {
        let text = try String(contentsOf: Self.controller, encoding: .utf8)
        let readScreen = DebugAidsLintTests.blocks(in: text, opening: "private func readScreen()")
        let followChat = DebugAidsLintTests.blocks(in: text, opening: "private func followChat()")
        try #require(readScreen.count == 1 && followChat.count == 1, "the scan no longer finds readScreen or followChat")
        for block in readScreen + followChat {
            let reads = Self.fileReads.filter(block.contains)
            #expect(reads.isEmpty, "reads a file (\(reads)) on the main thread in:\n\(block)")
        }
        // Idle for steering by the session the store published.
        #expect(readScreen[0].contains("LeadDelivery.way(for: session)"))
    }
}
