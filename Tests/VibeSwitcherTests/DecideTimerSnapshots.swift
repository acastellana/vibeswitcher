import AppKit
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Pictures of the lead's questions with a timer, drawn offscreen from `LeadQuestionStack`: one counting down
/// (its proposal highlighted, "Going with SQLite in 8 min", Hold), one you held, one the lead went ahead on when no
/// answer came, the same after a late answer, and all of them in one stack. Only with
/// `DECIDE_TIMER_SNAPSHOT_DIR=/some/folder swift test --filter DecideTimerSnapshots`.
@MainActor
struct DecideTimerSnapshots {
    static let folder = ProcessInfo.processInfo.environment["DECIDE_TIMER_SNAPSHOT_DIR"]

    struct Scene {
        var counting: LeadQuestion
        var held: LeadQuestion
        var decided: LeadQuestion
        var late: LeadQuestion
        var board: LeadBoard
    }

    static func scene(now: Date) throws -> Scene {
        let at = now.timeIntervalSince1970
        var board = LeadBoard()
        // 7:42 left of 10 minutes: "in 8 min".
        let counting = board.ask("Which store for the session cache?", options: ["SQLite", "Postgres", "Plain JSON files"], priority: nil,
                                 whyNow: "The cache task starts as soon as this is settled; SQLite needs no server.",
                                 proposal: "SQLite", at: at - 138)
        let heldAsked = board.ask("Label for the new tab: “Team” or “Crew”?", options: ["Team", "Crew"], priority: .whenever,
                                  whyNow: "Only the label; nothing waits on it.", proposal: "Team", decideIn: 15, at: at - 6 * 60)
        try board.hold(heldAsked.id, at: at - 4 * 60)
        let decidedAsked = board.ask("Show times as “5 min ago” or 17:42?", options: ["5 min ago", "17:42"], priority: nil, whyNow: nil,
                                     proposal: "5 min ago", at: at - 13 * 60)
        let lateAsked = board.ask("Retry a failed merge once on its own?", options: ["Retry once", "Never"], priority: nil, whyNow: nil,
                                  proposal: "Retry once", decideIn: 5, at: at - 20 * 60)
        _ = board.expire(now: at - 3 * 60)
        _ = board.answer(lateAsked.id, with: "Never", saw: 1, at: at - 60)
        func question(_ id: String) throws -> LeadQuestion { try #require(board.questions.first { $0.id == id }) }
        return Scene(counting: try question(counting.id), held: try question(heldAsked.id), decided: try question(decidedAsked.id),
                     late: try question(lateAsked.id), board: board)
    }

    /// The scene is what the board says, whatever the folder.
    @Test func theSceneIsCountingHeldAndDecided() throws {
        let now = Date()
        let scene = try Self.scene(now: now)
        #expect(scene.counting.isCounting)
        #expect(timeLeft((scene.counting.decideBy ?? 0) - now.timeIntervalSince1970) == "8 min")
        #expect(timeLeft(42) == "42 s")
        #expect(timeLeft(0.2) == "1 s")
        #expect(scene.held.isOpen && !scene.held.isCounting && scene.held.heldAt != nil)
        #expect(scene.decided.state == .autoDecided && scene.decided.answer == nil)
        #expect(scene.late.state == .autoDecided && scene.late.answer == "Never")
        #expect(scene.board.questionStack(now: now.timeIntervalSince1970).map(\.id) == [scene.counting.id, scene.held.id, scene.late.id, scene.decided.id]
            || scene.board.questionStack(now: now.timeIntervalSince1970).map(\.id) == [scene.counting.id, scene.held.id, scene.decided.id, scene.late.id])
    }

    @Test(.enabled(if: folder != nil)) func drawDecideTimer() throws {
        let folder = try #require(Self.folder)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let scene = try Self.scene(now: Date())
        let pictures = LeadQuestionSnapshots()
        let late = [scene.late.id: "The timer had run out: the lead went ahead with ‘Retry once’. Your answer reached it as a note."]
        // As wide as the chat column.
        try pictures.write(LeadQuestionStack(questions: [scene.counting], answer: { _, _ in }).padding(16),
                           width: 560, name: "counting", folder: folder)
        try pictures.write(LeadQuestionStack(questions: [scene.held], answer: { _, _ in }).padding(16),
                           width: 560, name: "held", folder: folder)
        try pictures.write(LeadQuestionStack(questions: [scene.decided], answer: { _, _ in }).padding(16),
                           width: 560, name: "auto-decided", folder: folder)
        try pictures.write(LeadQuestionStack(questions: [scene.late], notices: late, answer: { _, _ in }).padding(16),
                           width: 560, name: "late-answer", folder: folder)
        try pictures.write(LeadQuestionStack(questions: scene.board.questionStack(), notices: late, answer: { _, _ in }).padding(16),
                           width: 560, name: "stack", folder: folder)
        // The inspector's narrower column.
        try pictures.write(LeadQuestionStack(questions: [scene.counting], answer: { _, _ in }).padding(14),
                           width: 360, name: "counting-narrow", folder: folder)
    }
}
