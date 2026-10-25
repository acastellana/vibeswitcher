import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The lead's chat pinned "No questions waiting" and a withdrawn question under the conversation (seen 2026-10-25):
/// only open questions are pinned now (`ChatContainer`), and one that closed without an answer joins the conversation
/// where it closed, with what became of a late answer.
@MainActor
struct LeadChatQuestionTests {
    static func time(_ minute: Int) -> String { String(format: "2026-10-25T09:%02d:00Z", minute) }
    static func at(_ minute: Int) -> Double { ISO8601DateFormatter().date(from: time(minute))!.timeIntervalSince1970 }

    @Test func closedQuestionsJoinTheConversationWhereTheyClosed() async throws {
        let scratch = Scratch()
        let home = try #require(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], "Run with CFFIXED_USER_HOME on a scratch folder")
        let projects = scratch.adopt(URL(fileURLWithPath: home).appendingPathComponent(".claude/projects/lead-chat-questions-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let path = projects.appendingPathComponent("lead.jsonl")
        var data = Data()
        for (index, minute) in [10, 20, 30].enumerated() {
            let line: [String: Any] = ["type": "assistant", "uuid": "r\(index)", "timestamp": Self.time(minute),
                                       "message": ["role": "assistant", "content": [["type": "text", "text": "Reply \(index)"]]]]
            data.append(try JSONSerialization.data(withJSONObject: line))
            data.append(0x0A)
        }
        try data.write(to: path)
        let chat = ChatModel()
        chat.show(path: path.path)
        let deadline = Date().addingTimeInterval(hangGuard)
        // The read lands through the main queue: let it run.
        while chat.state != .ready, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(chat.state == .ready)

        var withdrawn = LeadQuestion(id: "W", text: "Keep the review badges?", options: [], at: Self.at(5))
        withdrawn.withdrawnAt = Self.at(25)
        withdrawn.withdrawReason = "User asked to re-ask it."
        var answered = LeadQuestion(id: "A", text: "Ship it?", options: [], at: Self.at(5))
        answered.answer = "Yes"
        answered.answeredAt = Self.at(15)
        let open = LeadQuestion(id: "O", text: "Blue or red?", options: [], at: Self.at(12))
        chat.showQuestions([open, withdrawn, answered], notices: ["O": "unrelated"])
        #expect(chat.items.map(\.id) == ["r0.0", "r1.0", "question:W", "r2.0"])

        // A late answer's notice shows on it.
        chat.showQuestions([open, withdrawn, answered], notices: ["W": "Withdrawn before your answer."])
        #expect(chat.items.contains(.question(withdrawn, notice: "Withdrawn before your answer.")))
        // Another conversation (no lead): none.
        chat.showQuestions([], notices: [:])
        #expect(chat.items.map(\.id) == ["r0.0", "r1.0", "r2.0"])
    }
}
