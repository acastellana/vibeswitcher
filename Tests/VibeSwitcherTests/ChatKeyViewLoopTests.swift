import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// A long lead chat keeps its rows' controls out of SwiftUI's key-view loop (`chatRowControl`). SwiftUI keeps an AppKit
/// proxy view (`KeyViewProxy`) for each focusable control of a hosting view and rebuilds them all, in layout, whenever
/// the set changes: with a button on every tool run and team message, a lead chat taking in new rows with its window
/// not key froze the app for 10 s (hang-20261027-014048, all of it in `FocusBridge.updateDefaultKeyViewLoop`).
@MainActor
struct ChatKeyViewLoopTests {
    /// A lead's conversation as it runs: each turn a worker's report handed over, a run of tool calls, a reply.
    static func transcript(turns: Int) throws -> Data {
        var lines: [[String: Any]] = []
        var stamp = 0
        func time() -> String {
            stamp += 1
            return String(format: "2026-10-27T%02d:%02d:%02dZ", stamp / 3600, stamp / 60 % 60, stamp % 60)
        }
        for turn in 0..<turns {
            let slug = "task-\(turn)"
            lines.append(["type": "user", "uuid": "u\(turn)", "timestamp": time(),
                          "message": ["role": "user", "content": LeadDelivery.typed("1 new report (worker \(slug) done). Call status.",
                                                                                   from: .system("reports"))]])
            let tools = (0..<3).map { "t\(turn)-\($0)" }
            lines.append(["type": "assistant", "uuid": "a\(turn)", "timestamp": time(),
                          "message": ["role": "assistant", "content": tools.map { id in
                              ["type": "tool_use", "id": id, "name": "Bash", "input": ["command": "git log --oneline -3 \(slug)"]] as [String: Any]
                          }]])
            lines.append(["type": "user", "uuid": "r\(turn)", "timestamp": time(),
                          "message": ["role": "user", "content": tools.map { id in
                              ["type": "tool_result", "tool_use_id": id, "content": "abc1234 \(slug): its change\n"] as [String: Any]
                          }]])
            lines.append(["type": "assistant", "uuid": "b\(turn)", "timestamp": time(),
                          "message": ["role": "assistant", "content": [["type": "text", "text": "\(slug) is done; it goes to its audit next."]]]])
        }
        var data = Data()
        for line in lines {
            data.append(try JSONSerialization.data(withJSONObject: line))
            data.append(0x0A)
        }
        return data
    }

    /// The hosting view's key-view proxies, all of them (they're its subviews, or theirs).
    static func proxies(in view: NSView) -> Int {
        (String(describing: type(of: view)).contains("KeyViewProxy") ? 1 : 0) + view.subviews.reduce(0) { $0 + proxies(in: $1) }
    }

    static func count(_ name: String, in view: NSView) -> Int {
        (String(describing: type(of: view)) == name ? 1 : 0) + view.subviews.reduce(0) { $0 + count(name, in: $1) }
    }

    @Test func aLongLeadChatKeepsItsRowsOutOfTheKeyViewLoop() async throws {
        let scratch = Scratch()
        // The chat reads transcripts only under ~/.claude/projects: a scratch home's, never the real one.
        let home = try #require(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], "Run with CFFIXED_USER_HOME on a scratch folder")
        #expect(NSHomeDirectory() == home)
        let projects = scratch.adopt(URL(fileURLWithPath: home).appendingPathComponent(".claude/projects/key-view-loop-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let path = projects.appendingPathComponent("lead.jsonl")
        try Self.transcript(turns: 60).write(to: path)

        let chat = ChatModel()
        chat.show(path: path.path)
        let deadline = Date().addingTimeInterval(20)
        // The read lands through the main queue, and the rows are staged in over a few turns: let them run.
        while chat.state != .ready || chat.staging != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(chat.state == .ready && chat.staging == nil)
        // Some tool runs opened: each of their tools is a row with its own disclosure.
        for item in chat.items.suffix(40) { if case .tools(let id, _) = item { chat.expanded.insert(id) } }

        let view = ChatView(chat: chat, row: nil, live: false, showTerminal: {}, choose: { _, _, _ in }, moveTab: { _ in }, resend: { _ in })
            .frame(width: 900, height: 1000)
        // Borderless: never key, as the window was when it froze.
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 1000), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        #expect(!window.isKeyWindow)
        // Laid out until the chat's rows are in (the stack is eager: every shown row is a view), then once more: the
        // key-view loop is rebuilt in layout.
        let shown = ChatWindow.shown(chat.items, limit: chat.shownLimit, including: nil).items
        let tools = shown.filter { if case .tools = $0 { return true } else { return false } }.count
        let teams = shown.filter { if case .team = $0 { return true } else { return false } }.count
        while Self.count("ChatTextView", in: host) < 10, Date() < deadline {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(Self.count("ChatTextView", in: host) >= 10, "the chat's replies aren't laid out")
        #expect(tools >= 20 && teams >= 20, "tool runs \(tools), team messages \(teams) shown")
        // The composer, the Latest and Show earlier buttons and the like: a handful, however long the chat.
        let proxies = Self.proxies(in: host)
        #expect(proxies <= 6, "\(proxies) key-view proxies for \(tools) tool runs and \(teams) team messages")
    }

    /// The lead's Team strip on a day's board (254 tasks, 4 under way): a chip for each task under way and the latest
    /// finished ones, not one for every task (each was a button and a tooltip, all made again on every board change).
    @Test func theTeamStripKeepsToTheTasksUnderWay() async throws {
        var board = LeadBoard()
        let contract = LeadContract(goal: "A goal as long as a real one's.", acceptance: ["a"], boundaries: [], context: "")
        for index in 0..<254 {
            let status: LeadTask.Status = index < 2 ? .running : index < 4 ? .review : index % 9 == 0 ? .abandoned : .done
            var task = LeadTask(slug: "task-\(index)", title: "Task \(index)", contract: contract, status: status)
            task.since = 1_793_000_000 + Double(index) * 60
            board.tasks.append(task)
        }
        let chips = TeamStrip.chips(board)
        #expect(chips.count == 4 + TeamStrip.finishedChips)
        // The latest finished, after the ones under way.
        #expect(chips.prefix(4).allSatisfy { !LeadTeams.isFinished($0) })
        #expect(chips.suffix(TeamStrip.finishedChips).map(\.slug).contains("task-253"))

        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1200, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TeamStrip(board: board) { _ in }.frame(width: 1200, height: 120))
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let proxies = Self.proxies(in: host)
        #expect(proxies <= chips.count, "\(proxies) key-view proxies in the strip of \(board.tasks.count) tasks")
    }
}
