import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Pictures of a lead's chat with the messages VibeSwitcher handed it, light and dark: the real chat view, offscreen,
/// on a made-up transcript (a worker's report with its TL;DR, a witness notice, a failed audit opened, the user's
/// answer relayed, a message in parts, the wake-up typed while it was idle, the agent's replies around them). Only
/// with `TEAM_MESSAGE_SNAPSHOT_DIR=/some/folder` and HOME and CFFIXED_USER_HOME on a scratch folder, where
/// the transcript is written.
@MainActor
struct TeamMessageSnapshots {
    nonisolated static let folder = ProcessInfo.processInfo.environment["TEAM_MESSAGE_SNAPSHOT_DIR"]

    static func context(_ text: String, from sender: SteerMessage.Sender, handedOver: Int? = nil) -> String {
        var message = SteerMessage(text: text, from: sender, agentPid: 1)
        message.handedOver = handedOver
        return SteerReply.context([message])
    }

    static func transcript() throws -> (data: Data, open: [String]) {
        var lines: [[String: Any]] = []
        var stamp = 0
        func time() -> String { stamp += 1; return String(format: "2026-10-19T08:%02d:00Z", 30 + stamp) }
        func user(_ text: String) { lines.append(["type": "user", "uuid": "u\(lines.count)", "timestamp": time(), "message": ["role": "user", "content": text]]) }
        func reply(_ text: String) {
            lines.append(["type": "assistant", "uuid": "r\(lines.count)", "timestamp": time(),
                          "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
        }
        func delivered(_ context: String) -> String {
            let uuid = "a\(lines.count)"
            lines.append(["type": "attachment", "uuid": uuid, "timestamp": time(),
                          "attachment": ["type": "hook_additional_context", "content": [context], "hookEvent": "UserPromptSubmit"]])
            return uuid + ".0"
        }
        user("How are the workers doing?")
        reply("Two are at work. **fix-the-chat-layout** is close to done; I'll check its report when it comes.")
        user(LeadDelivery.typed("1 new report (worker fix-the-chat-layout done). Call status.", from: .system("reports")))
        _ = delivered(context("The worker on fix-the-chat-layout says it's done: the chat list keeps its place when a long reply streams in. "
            + "`ChatWindow.anchor` now measures from the top row; 12 new tests in ChatWindowTests, and `swift build && swift test` passes twice "
            + "on a scratch home (998 → 1010 tests).\n\nLeft: the inspector still jumps once on a resize; I didn't touch it.\n"
            + "Run audit(fix-the-chat-layout); only the verifier's report counts.", from: .system("worker fix-the-chat-layout")))
        reply("Starting the audit of fix-the-chat-layout.")
        _ = delivered(context("The worker on stale-git-index-lock is stalled: it's between turns without having reported, and has no question "
            + "to the lead pending, last activity 10 min ago. read_session(stale-git-index-lock) to see where it stopped, then message it what to do next.",
            from: .system("witness")))
        let failed = delivered(context("The audit of board-decode-off-the did not pass (incomplete, clean): the board still decodes on the main thread "
            + "when the Team view opens.\n\n- `BoardBenchTests` is still red\n- `LeadController.refresh` calls `BoardStore.load()` directly\n\n"
            + "Send the worker the findings with message, or re-plan the task.", from: .system("verifier board-decode-off-the")))
        let answer = delivered(context("The user answered your question \"Which colour for team messages?\": purple, so they don't look like mine.", from: .user))
        let long = SteerMessage(text: "The worker on big-refactor says it's done: " + String(repeating: "Moved one more reader off the main thread and checked it.\n", count: 400),
                                from: .system("worker big-refactor"), agentPid: 1)
        _ = delivered(context(long.text, from: .system("worker big-refactor"), handedOver: SteerReply.partEnds(long)[0]))
        reply("The audit failed: I'll send the worker the findings.")
        var data = Data()
        for line in lines { data.append(try JSONSerialization.data(withJSONObject: line)); data.append(0x0A) }
        return (data, [failed, answer])
    }

    @Test(.enabled(if: folder != nil)) func drawTeamMessages() async throws {
        let folder = try #require(Self.folder)
        let scratch = Scratch()
        // The chat reads transcripts only under ~/.claude/projects: a scratch home's, never the real one.
        let home = try #require(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], "Run with CFFIXED_USER_HOME on a scratch folder")
        #expect(NSHomeDirectory() == home)
        let projects = scratch.adopt(URL(fileURLWithPath: home).appendingPathComponent(".claude/projects/team-message-snapshots-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let path = projects.appendingPathComponent("lead.jsonl")
        let (data, open) = try Self.transcript()
        try data.write(to: path)
        // A fake helper: a line per message.
        let summaries = TeamSummaryModel(generate: { prompt in
            prompt.contains("big-refactor") ? "Every reader is off the main thread now; more in the next parts"
                : prompt.contains("board-decode") ? "The board still loads on the main thread, so the audit failed"
                : "The chat keeps its place while replies stream in; tests pass, the inspector is left"
        },
                                         run: { $0() }, deliver: { $0() }, perform: { $0() })
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            let chat = ChatModel()
            chat.show(path: path.path)
            let deadline = Date().addingTimeInterval(10)
            // The read lands through the main queue: let it run.
            while chat.state != .ready, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(chat.state == .ready)
            for id in open { chat.expanded.insert(TeamMessageCard.key(ChatEntry(id: id, at: nil, kind: .reply("")))) }
            let view = ChatView(chat: chat, row: nil, live: false, showTerminal: {}, choose: { _, _, _ in }, moveTab: { _ in }, resend: { _ in })
                .environment(\.teamSummaries, summaries)
                .frame(width: 760, height: 1500)
                .background(Color(nsColor: .textBackgroundColor))
            let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 760, height: 1500), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme)
            let host = NSHostingView(rootView: view)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.close() }
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(50))
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("chat-team-messages-\(scheme == .darkAqua ? "dark" : "light").png"))
        }
    }
}
