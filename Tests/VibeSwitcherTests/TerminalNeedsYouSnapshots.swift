import AppKit
import SwiftUI
import Testing
import VibeCore
@testable import VibeSwitcher

/// Pictures of a Terminal.app session that needs you, as the window's chat shows it, light and dark: the needs-you
/// card (no question read off its tab), the answer card from its tab's text, the one-line confirmation, and the
/// refusal when the question changed. Drawn offscreen from the app's own views over a scratch transcript and the
/// fixtures of `TerminalAnswerTests`; nothing reads or types into Terminal. Only with
/// `TERMINAL_NEEDS_YOU_SNAPSHOT_DIR=/some/folder CFFIXED_USER_HOME=/scratch swift test --filter TerminalNeedsYouSnapshots`.
@MainActor
@Suite(.serialized)
struct TerminalNeedsYouSnapshots {
    nonisolated static let folder = ProcessInfo.processInfo.environment["TERMINAL_NEEDS_YOU_SNAPSHOT_DIR"]
    let temp = Scratch()

    static let session: Session = {
        var session = Session(tty: "ttys990", agent: .claude, pid: 1, startedAt: Date(), cwd: "/tmp/acme-site", project: "acme-site",
                              task: "Website redesign", status: .needsInput, statusSince: Date().addingTimeInterval(-90),
                              detail: "Claude needs your permission to use Bash", hasHooks: true, inTerminalApp: true)
        session.activity = nil
        return session
    }()

    @Test(.enabled(if: folder != nil)) func drawTerminalNeedsYou() async throws {
        let folder = try #require(Self.folder)
        // The chat reads transcripts only under ~/.claude/projects: a scratch home's, never the real one.
        let home = try #require(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], "Run with CFFIXED_USER_HOME on a scratch folder")
        #expect(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == URL(fileURLWithPath: home).resolvingSymlinksInPath())
        let projects = temp.adopt(URL(fileURLWithPath: home).appendingPathComponent(".claude/projects/terminal-needs-you-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let path = projects.appendingPathComponent("session.jsonl")
        try Data([
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-19T09:00:00.000Z","message":{"role":"user","content":"Add a probe file so the health check can see the deploy."}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-19T09:00:04.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"I'll create `/tmp/x` for the health check to find."}]}}"#,
        ].joined(separator: "\n").appending("\n").utf8).write(to: path)

        let permission = try #require(ChatSync.terminalMenu(TerminalAnswerTests.permission))
        let other = try #require(ChatSync.terminalMenu(TerminalAnswerTests.other))
        let row = WindowRow(content: .agent(Self.session), project: "acme-site")
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            let chat = ChatModel()
            chat.show(path: path.path)
            let deadline = Date().addingTimeInterval(10)
            while chat.state != .ready, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(chat.state == .ready)

            chat.menu = nil
            try await draw(scene(chat, row, asking: false), "needs-you", scheme, folder)
            chat.menu = permission
            try await draw(scene(chat, row, asking: true), "answer-card", scheme, folder)
            let card = AnswerCard(menu: permission, pending: nil, agent: "Claude", notice: nil, answering: false, choose: { _, _ in },
                                  moveTab: { _ in }, showTerminal: {}, dismiss: {}, openInTerminal: {},
                                  confirming: AnswerCard.Choice(index: 0, typing: nil))
            try await draw(AnyView(VStack(spacing: 0) {
                card.padding(.horizontal, 22).padding(.vertical, 16).frame(maxHeight: .infinity, alignment: .bottom)
                Divider()
                TerminalReplyHint(canMove: false, asking: true, open: {}, move: {})
            }), "confirm", scheme, folder)
            chat.menu = other
            chat.answerNotice = ChatSync.refusal(other)
            try await draw(scene(chat, row, asking: true), "refused", scheme, folder)
        }
    }

    /// The chat pane as `ChatContainer` lays it out for a Terminal session: the conversation, then the footer.
    func scene(_ chat: ChatModel, _ row: WindowRow, asking: Bool) -> AnyView {
        AnyView(VStack(spacing: 0) {
            ChatView(chat: chat, row: row, live: false, inTerminal: {}, showTerminal: {}, choose: { _, _, _ in }, moveTab: { _ in },
                     resend: { _ in })
            Divider()
            TerminalReplyHint(canMove: false, asking: asking, open: {}, move: {})
        })
    }

    func draw(_ view: AnyView, _ name: String, _ scheme: NSAppearance.Name, _ folder: String) async throws {
        let size = NSSize(width: 680, height: 520)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .textBackgroundColor)))
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
        try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(scheme == .darkAqua ? "dark" : "light").png"))
    }
}
