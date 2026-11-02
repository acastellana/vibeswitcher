import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The chat's tool lines (a run's summary line and each tool's line under it) are one element each that says what the
/// line says, as the button's combined label said it, and still opens and closes; the Team rows' open state is their
/// value. scripts/hang-accessibility.py: the chat's hosting view had most of the accessibility work in the hang reports.
@MainActor
@Suite(.serialized)
struct ChatToolLineAccessibilityTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func tool(_ id: String, _ title: String, seconds: TimeInterval, failed: Bool = false) -> ChatTool {
        ChatTool(id: id, name: "Bash", title: title, detail: .command(title), at: start,
                 result: ChatResult(output: "ok", truncated: false, failed: failed, at: start + seconds, images: []))
    }

    static let tools = [tool("t1", "git status", seconds: 2), tool("t2", "swift build", seconds: 4, failed: true), tool("t3", "ls", seconds: 0.2)]

    func show<V: View>(_ view: V) -> (window: NSWindow, settle: () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 600, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.frame(width: 600, height: 300, alignment: .topLeading))
        window.contentView = host
        window.orderFrontRegardless()
        return (window, {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date())
        })
    }

    @Test func eachToolLineIsOneElementThatSaysWhatTheLineSays() async throws {
        let chat = ChatModel()
        let (window, settle) = show(ToolGroupView(id: "g", tools: Self.tools, chat: chat, expanded: ["g"], openImage: { _ in }))
        defer { window.close() }
        settle()
        #expect(AXClient.attach(window) == 1)
        settle()
        let texts = AXClient.texts(window)
        // The summary line: its summary and the run's time, as the button's texts said them.
        let summary = ChatTimeline.summary(Self.tools)
        #expect(texts.contains("\(summary), 6s"), "\(texts)")
        // Each tool's line: a failure first, its title, its time when it took a second or more.
        #expect(texts.contains("git status, 2s"), "\(texts)")
        #expect(texts.contains("Failed, swift build, 4s"), "\(texts)")
        #expect(texts.contains("ls"), "\(texts)")
        // Nothing else says them: no element for each text and mark inside a line.
        #expect(texts.filter { $0.contains("git status") }.count == 1, "\(texts)")
        #expect(!texts.contains("2s") && !texts.contains("Failed"), "\(texts)")
    }

    @Test func aToolLinesElementOpensAndClosesIt() async throws {
        let chat = ChatModel()
        #expect(!chat.expanded.contains("t1"))
        let line = ToolRowView(tool: Self.tools[0], chat: chat, open: false)
        let (window, settle) = show(line)
        defer { window.close() }
        settle()
        #expect(AXClient.attach(window) == 1)
        settle()
        #expect(AXClient.press(window, labelled: "git status, 2s"), "no element said the line: \(AXClient.dump(window))")
        #expect(chat.expanded.contains("t1"))
    }

    @Test func aTeamRowsOpenStateIsItsValue() async throws {
        let row = try #require(TeamPanelCostTests.rows(1).first)
        for open in [false, true] {
            let (window, settle) = show(TeamRowView(row: row, now: TeamRowsTests.now, summary: nil, isOpen: open, canOpen: { _ in false },
                                                    open: { _ in }, toggle: {}))
            defer { window.close() }
            settle()
            #expect(AXClient.attach(window) == 1)
            settle()
            let texts = AXClient.texts(window)
            #expect(texts.contains(open ? "expanded" : "collapsed"), "\(texts)")
            #expect(texts.contains(row.spoken(now: TeamRowsTests.now, summary: nil)), "\(texts)")
        }
    }
}
