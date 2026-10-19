import AppKit
import SwiftUI
import Testing
import VibeCore
@testable import VibeSwitcher

/// Pictures of the chat over the fake Claude Code of `ChatSyncTests` (a scratch host, never a real session), light
/// and dark: back on a question already answered (tabs), a multi-select with a tick and the terminal's cursor on its
/// Submit row, and a message sent while a permission prompt is open. Only with
/// `CHAT_SYNC_SNAPSHOT_DIR=/some/folder swift test --filter ChatSyncSnapshots`; `CHAT_SYNC_SNAPSHOT_NAME` goes in the
/// file names (default "after": chat-sync-tabs-after-light.png, …).
@MainActor
@Suite(.serialized)
struct ChatSyncSnapshots {
    nonisolated static let folder = ProcessInfo.processInfo.environment["CHAT_SYNC_SNAPSHOT_DIR"]
    static let name = ProcessInfo.processInfo.environment["CHAT_SYNC_SNAPSHOT_NAME"] ?? "after"
    let temp = Scratch()

    @Test(.enabled(if: folder != nil)) func drawBackOnAnAnsweredTab() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [ChatSyncTests.fruit, ChatSyncTests.toppings]])
        try await h.settle { $0.contains("Which fruit?") }
        h.keys("\u{1b}[B\r")
        try await h.settle { $0.contains("Which toppings?") && $0.contains("☒ Fruit") }
        h.keys("\u{1b}[D")
        try await h.settle { $0.contains("Which fruit?") }
        try draw(h, "tabs")
    }

    @Test(.enabled(if: folder != nil)) func drawAMultiSelectOnItsSubmitRow() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [ChatSyncTests.toppings]])
        try await h.settle { $0.contains("Which toppings?") }
        h.keys("1")
        try await h.settle { $0.contains("[✔] Cream") }
        h.keys("\u{1b}[B\u{1b}[B\u{1b}[B")
        try await h.settle { $0.contains("❯    Submit") }
        try draw(h, "multi-select")
    }

    @Test(.enabled(if: folder != nil)) func drawASendWhileAPermissionPromptIsOpen() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "permission", "command": "touch /tmp/x"])
        try await h.settle { $0.contains("Do you want to proceed?") }
        h.send("1 more thing, then stop")
        try await h.quiet()
        try await h.quiet()
        try draw(h, "send-during-prompt", terminal: true)
    }

    /// The chat as the window shows it, with the terminal's screen beside it (`terminal`) to compare.
    func draw(_ h: Harness, _ name: String, terminal: Bool = true) throws {
        let folder = try #require(Self.folder)
        let row = WindowRow(content: .hosted(h.session), project: "fake")
        let screen = h.screen
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            let view = HStack(alignment: .top, spacing: 0) {
                ChatView(chat: h.chat, row: row, live: true, showTerminal: {}, choose: { _, _, _ in }, moveTab: { _ in }, resend: { _ in })
                    .frame(width: 620, height: 640)
                if terminal {
                    Text(screen).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(white: 0.9))
                        .frame(width: 520, height: 640, alignment: .topLeading).padding(10).background(Color(white: 0.1))
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            let width: CGFloat = terminal ? 1160 : 620
            let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 660), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme)
            let host = NSHostingView(rootView: view)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            let file = "chat-sync-\(name)-\(Self.name)-\(scheme == .darkAqua ? "dark" : "light").png"
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(file))
        }
    }
}
