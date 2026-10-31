import Foundation
import Testing

/// hang-20261031-102359: the window's each-second `followChat` → `readScreen` read the selected Claude session's hook
/// state file on the main thread, to tell whether its agent is idle for steering; under memory pressure that read held
/// the window for 4 s. The state comes from the store's scan now (`Session.hookEvent`, read off main). Scans the
/// bodies of the controller's `readScreen` and `followChat` only, so a file read written back into them fails here.
/// What they call, the chat's `watchSteering` and `refreshSteering`, read the steer inbox on the chat's inbox queue
/// (`ChatModel.loadSteering`; `SteerInboxReadOffMainTests` checks where it runs): their bodies are scanned here too.
struct ReadScreenOffDiskTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/VibeSwitcher/MainWindow")
    static let controller = sources.appendingPathComponent("MainWindowController.swift")
    static let chatModel = sources.appendingPathComponent("Chat/ChatModel.swift")

    /// What reads a file: a hook state, its path, or any file's contents.
    static let fileReads = ["HookState.load(", "VibePaths.stateFile(", "contentsOf:", "FileManager.default.contents(",
                            "FileHandle(forReadingAtPath:", "FileHandle(forReadingFrom:"]

    @Test func readScreenAndFollowChatReadNoHookStateFileAndTakeTheStoresHookEvent() throws {
        let text = try String(contentsOf: Self.controller, encoding: .utf8)
        let readScreen = DebugAidsLintTests.blocks(in: text, opening: "private func readScreen()")
        let followChat = DebugAidsLintTests.blocks(in: text, opening: "private func followChat()")
        try #require(readScreen.count == 1 && followChat.count == 1, "the scan no longer finds readScreen or followChat")
        for block in readScreen + followChat {
            let reads = Self.fileReads.filter(block.contains)
            #expect(reads.isEmpty, "reads a file (\(reads)) itself on the main thread in:\n\(block)")
        }
        // Idle for steering by the session the store published.
        #expect(readScreen[0].contains("LeadDelivery.way(for: session)"))
    }

    @Test func watchSteeringAndRefreshSteeringReadNoInboxThemselves() throws {
        let text = try String(contentsOf: Self.chatModel, encoding: .utf8)
        let watch = DebugAidsLintTests.blocks(in: text, opening: "func watchSteering(")
        let refresh = DebugAidsLintTests.blocks(in: text, opening: "func refreshSteering()")
        try #require(watch.count == 1 && refresh.count == 1, "the scan no longer finds watchSteering or refreshSteering")
        for block in watch + refresh {
            let reads = (Self.fileReads + ["SteerInbox."]).filter(block.contains)
            #expect(reads.isEmpty, "reads the inbox (\(reads)) on the main thread in:\n\(block)")
        }
    }
}
