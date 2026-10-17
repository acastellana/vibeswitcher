import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Pictures of the lead's "Questions for you" stack, drawn offscreen from `LeadQuestionStack` and `LeadTeamView`: a
/// blocking question, one the lead revised (its earlier wording open and closed), one that can wait, one withdrawn
/// while you were writing an answer and one withdrawn after you answered it. Only with
/// `QUESTION_SNAPSHOT_DIR=/some/folder swift test --filter LeadQuestionSnapshots`.
@MainActor
struct LeadQuestionSnapshots {
    static let folder = ProcessInfo.processInfo.environment["QUESTION_SNAPSHOT_DIR"]

    struct Scene {
        var board: LeadBoard
        var revised: String
        var withdrawnWhileWriting: String
        var withdrawnAfterAnswer: String
    }

    static func scene(now: Date) throws -> Scene {
        let at = now.timeIntervalSince1970
        var board = LeadBoard()
        board.ask("Can workers force-push their own agent/* branches when a rebase goes wrong?", options: ["Yes, their own branches only", "No, never"],
                  priority: .blocking, whyNow: "Two workers are waiting to rebase onto the new main.", at: at - 25 * 60)
        let revised = board.ask("Should merges run swift test, or the full make check?", options: ["swift test", "make check"],
                                priority: nil, whyNow: nil, at: at - 70 * 60)
        try board.revise(revised.id, text: "Should merges run swift test, or swift test plus the offscreen renders?",
                         options: ["swift test", "swift test + renders"],
                         note: "make check was removed in 0947d51; the renders are the slow part now", at: at - 12 * 60)
        board.ask("Name for the menu item: “Team” or “Crew”?", options: ["Team", "Crew"], priority: .whenever,
                  whyNow: "Only the label; nothing waits on it.", at: at - 5 * 60)
        let writing = board.ask("Base branch and test_command for this repo?", options: [], priority: .blocking, whyNow: nil, at: at - 6 * 3_600)
        try board.withdraw(writing.id, reason: "Settled with configure: main, swift test", at: at - 3 * 60)
        let answered = board.ask("Keep the old lanes view behind a setting?", options: ["Yes", "No"], priority: nil, whyNow: nil, at: at - 40 * 60)
        try board.withdraw(answered.id, reason: "The old view was removed in the merge", at: at - 8 * 60)
        _ = board.answer(answered.id, with: "No", saw: 1, at: at - 60)
        // History: one answered after a revision (the earlier wording), one answered as asked.
        let older = board.ask("Squash workers' commits on merge?", options: ["Squash", "Keep them"], priority: nil, whyNow: nil, at: at - 3 * 3_600)
        try board.revise(older.id, text: "Squash workers' commits on merge, or keep them and rebase?", options: nil,
                         note: "Rebase came up in review", at: at - 2 * 3_600)
        _ = board.answer(older.id, with: "Keep them", saw: 1, at: at - 2 * 3_600 + 30)
        let plain = board.ask("Ship the welcome window this week?", options: ["Yes"], priority: nil, whyNow: nil, at: at - 4 * 3_600)
        _ = board.answer(plain.id, with: "Yes", saw: 1, at: at - 4 * 3_600 + 600)
        return Scene(board: board, revised: revised.id, withdrawnWhileWriting: writing.id, withdrawnAfterAnswer: answered.id)
    }

    /// Drawn in a window far off every display (text fields and buttons are AppKit views, which `ImageRenderer`
    /// leaves out), as tall as the view needs unless `height` is given (a view that scrolls).
    func write<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, name: String, folder: String) throws {
        for scheme in [ColorScheme.light, .dark] {
            let framed = view
                .frame(width: width, height: height, alignment: .topLeading)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
                .environment(\.colorScheme, scheme)
            let hosting = NSHostingView(rootView: framed)
            let size = height.map { CGSize(width: width, height: $0) } ?? hosting.fittingSize
            let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = hosting
            window.orderFrontRegardless()
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    /// Whatever the folder, the stack is what the board says: open ones by priority then age, then the withdrawn.
    @Test func theSceneStacksAsTheBoardOrdersIt() throws {
        let scene = try Self.scene(now: Date())
        let stack = scene.board.questionStack()
        #expect(stack.filter(\.isOpen).map(\.rank) == [.blocking, .important, .whenever])
        #expect(stack.filter { $0.state == .withdrawn }.map(\.id) == [scene.withdrawnWhileWriting, scene.withdrawnAfterAnswer])
        #expect(scene.board.blockingQuestions == 1)
        #expect(questionCount(3) == "3 questions for you")
        #expect(questionCount(1) == "1 question for you")
    }

    @Test(.enabled(if: folder != nil)) func drawQuestionStack() throws {
        let folder = try #require(Self.folder)
        let scene = try Self.scene(now: Date())
        let stack = scene.board.questionStack()
        let notices = [scene.withdrawnAfterAnswer: "Withdrawn before your answer: The old view was removed in the merge. The lead got your answer as a note."]
        let drafts = [scene.withdrawnWhileWriting: "main, and swift test"]

        // In the lead's chat (about as wide as the chat column), the earlier wording folded, then open.
        try write(LeadQuestionStack(questions: stack, notices: notices, answer: { _, _ in }, drafts: drafts).padding(16),
                  width: 560, name: "questions-stack", folder: folder)
        try write(LeadQuestionStack(questions: stack, notices: notices, answer: { _, _ in }, historyOpen: [scene.revised], drafts: drafts).padding(16),
                  width: 560, name: "questions-stack-history", folder: folder)
        // The Team tab, with the history of answered and withdrawn ones below the tasks.
        try write(LeadTeamView(root: "/Users/you/dev/vibeswitcher", board: scene.board, seen: [:], open: { _ in }, notices: notices),
                  width: 360, height: 1_300, name: "questions-team-tab", folder: folder)
        // The strip over the lead's chat, with its count.
        try write(TeamStrip(board: scene.board, open: { _ in }), width: 560, name: "questions-team-strip", folder: folder)
    }
}
