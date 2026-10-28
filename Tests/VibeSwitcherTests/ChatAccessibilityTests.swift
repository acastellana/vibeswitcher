import AppKit
import Combine
import Darwin
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// A long lead chat with an accessibility client attached froze the app for 3–25 s at a time (hang-20261027-200338,
/// 201159, 201459 and the others of that evening): SwiftUI keeps its accessibility tree up to date while a client
/// watches the app, and every update walked every node of the chat's shown rows (`AccessibilityViewGraph.needsUpdate`,
/// `AccessibilityNode.updateChildren`, `defaultCombine`). A lead chat of 300 entries beside a team of 10 rows, its
/// tree walked as a client walks it after each update.
@MainActor
struct ChatAccessibilityTests {
    /// What a parent's update hands the chat: as the window draws it again for every host change.
    final class Ticker: ObservableObject {
        @Published var count = 0
    }

    struct Root: View {
        @ObservedObject var chat: ChatModel
        @ObservedObject var ticker: Ticker
        let board: LeadBoard

        var body: some View {
            HStack(spacing: 0) {
                ChatView(chat: chat, row: nil, live: false, leadNotices: ["tick": "\(ticker.count)"], showTerminal: {},
                         choose: { _, _, _ in }, moveTab: { _ in }, resend: { _ in })
                    .frame(width: 900)
                LeadTeamView(root: "/r", board: board, seen: [:], open: { _ in }, decisions: [], keepingAwake: false,
                             mac: MacLine(text: "Mac: load \(ticker.count % 20), 10 team sessions", spoken: "", isOver: false))
                    .frame(width: 360)
            }
        }
    }

    static func board() -> LeadBoard {
        var board = LeadBoard()
        let statuses: [LeadTask.Status] = [.running, .review, .planned, .blocked, .running]
        board.tasks = (0..<10).map { TeamRowsTests.task("task-\($0)", statuses[$0 % statuses.count], title: "Task \($0): a change of its own") }
        return board
    }

    /// What's on screen and a screen either side is seen; the band moves only as what's on screen nears its edge, so
    /// scrolling a little changes nothing accessibility sees.
    @Test func theBandFollowsTheScreenLazily() {
        let band = ChatExposure.band(nil, top: 1_000, height: 500)
        #expect(band == 500...2_000)
        // A little up or down: kept.
        #expect(ChatExposure.band(band, top: 1_200, height: 500) == nil)
        #expect(ChatExposure.band(band, top: 760, height: 500) == nil)
        // Near its edge: moved, around what's on screen.
        #expect(ChatExposure.band(band, top: 1_300, height: 500) == 800...2_300)
        #expect(ChatExposure.band(band, top: 700, height: 500) == 200...1_700)
        // A row is seen when any of it is in the band; one not laid out yet is seen; nothing is hidden before the band.
        let tops = ["a": 0.0, "b": 400, "c": 900, "d": 2_100, "e": 2_500]
        #expect(ChatExposure.hidden(tops: tops, exposed: band) == ["a", "d", "e"])
        #expect(ChatExposure.hidden(tops: tops, exposed: nil).isEmpty)
    }

    @Test func aLongLeadChatKeepsItsAccessibilityTreeSmall() async throws {
        let scratch = Scratch()
        let home = try #require(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], "Run with CFFIXED_USER_HOME on a scratch folder")
        let projects = scratch.adopt(URL(fileURLWithPath: home).appendingPathComponent(".claude/projects/chat-ax-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let path = projects.appendingPathComponent("lead.jsonl")
        // 75 turns of 4 entries: the stakegen lead's 290-odd.
        try ChatKeyViewLoopTests.transcript(turns: 75).write(to: path)

        let chat = ChatModel()
        chat.show(path: path.path)
        // Each wait ends on what it waits for, under its own hang guard: other main-actor suites in the same run can
        // hold the main actor for minutes, so one deadline for all of them ran out before the chat had a turn.
        #expect(await until { chat.state == .ready && chat.staging == nil }, "the chat didn't load")
        #expect(chat.log.entries.count >= 290)

        let ticker = Ticker()
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1260, height: 1000), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Root(chat: chat, ticker: ticker, board: Self.board()).frame(width: 1260, height: 1000))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        func settle() {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date())
        }
        #expect(await until { settle(); return ChatKeyViewLoopTests.count("ChatTextView", in: host) >= 10 }, "the chat's rows weren't drawn")
        settle()
        // The client attaches, and reads the window.
        #expect(AXClient.attach(window) == 1)
        ticker.count += 1
        settle()
        // What the newest turn and an older shown one say (each turn's reply: "task-N is done; …").
        let shown = ChatWindow.shown(chat.items, limit: chat.shownLimit, including: nil).items
        #expect(shown.count == ChatWindow.page)
        let replies = shown.compactMap { item -> String? in if case .reply(let entry) = item, case .reply(let text) = entry.kind { return text } else { return nil } }
        let oldest = try #require(replies.first), newest = try #require(replies.last)
        #expect(newest.hasPrefix("task-74 "))
        func reached() -> String { AXClient.texts(window).joined(separator: "\n") }
        var texts = reached()
        // The chat is scrolled to its end: its oldest shown rows, screens above, go out of the tree once the scroll view
        // has said where it is.
        _ = await until {
            settle()
            texts = reached()
            return !texts.contains(oldest)
        }
        #expect(texts.contains(newest), "the newest row isn't in the tree")
        #expect(!texts.contains(oldest), "\(oldest.prefix(8)), screens above what's shown, is in the tree")
        let elements = AXClient.walk(window)

        let main = mach_thread_self()
        let updates = 20
        let before = TeamChurnBench.cpu(of: main)
        for _ in 0..<updates {
            ticker.count += 1
            settle()
            _ = AXClient.walk(window)
        }
        let each = (TeamChurnBench.cpu(of: main) - before) / Double(updates)
        print(String(format: "RESULT chat-ax elements %d, main-thread ms per update %.1f", elements, each * 1000))
    }
}
