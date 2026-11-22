import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The lead's chat across a handover (2026-11-22, "it just has one continuous one, but there should be some signal
/// that I started a new lead"): the new lead's chat opens with the earlier sessions' conversation, a divider where it
/// began, then its own turns; a lead with no earlier session reads as before.
@MainActor
struct LeadChatHandoverTests {
    static func time(_ minute: Int) -> String { String(format: "2026-11-22T10:%02d:00.000Z", minute) }

    static func lines(_ lines: [(type: String, id: String, text: String, minute: Int)]) throws -> Data {
        var data = Data()
        for line in lines {
            let message: [String: Any] = line.type == "user" ? ["role": "user", "content": line.text]
                : ["role": "assistant", "content": [["type": "text", "text": line.text]]]
            data.append(try JSONSerialization.data(withJSONObject: ["type": line.type, "uuid": line.id, "timestamp": time(line.minute), "message": message]))
            data.append(0x0A)
        }
        return data
    }

    static func opened(_ chat: ChatModel, path: String, history: LeadChatHistory.Source?) async {
        chat.show(path: path, history: history)
        #expect(await until { chat.state == .ready })
    }

    @Test func theNewLeadsChatCarriesTheOldOnesAboveADivider() async throws {
        let scratch = Scratch()
        let root = scratch.url("handover-chat-project").path
        let home = scratch.url("handover-chat-home").path
        let projects = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects/-handover-chat-project")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let marker = LeadRotation.noteMarker + "1"
        let old = projects.appendingPathComponent("old.jsonl"), new = projects.appendingPathComponent("new.jsonl")
        try Self.lines([("user", "o1", "Make the films page", 1), ("assistant", "o2", "A worker is on it.", 2),
                        ("user", "o3", LeadRotation.request + "\n" + marker, 8), ("assistant", "o4", marker + "\nThe note.", 9)]).write(to: old)
        let start = LeadPrompts.leadStart(root: root, goal: nil, note: "n", replaced: ("/dev/ttys001", "/x/turns.md"), scheduledNote: "/x/note.md")
        try Self.lines([("user", "n1", start, 10), ("assistant", "n2", "Took over the films page.", 10),
                        ("user", "n3", "Thanks", 11)]).write(to: new)
        let (oldID, newID) = (UUID(), UUID())
        let at = ISO8601DateFormatter().date(from: "2026-11-22T10:10:00Z")!
        try LeadChatHistory.record(.init(from: oldID.uuidString, to: newID.uuidString, transcript: old.path, at: at.timeIntervalSince1970,
                                         reason: "the last one's context was 72% full", root: root))

        let chat = ChatModel(home: home)
        await Self.opened(chat, path: new.path, history: .init(root: root, session: newID.uuidString))
        let notice = LeadRotation.notice(reason: "the last one's context was 72% full", at: at)
        #expect(chat.items.map(\.id) == ["o1", "o2.0", "handover:\(newID.uuidString)", "n2.0", "n3"])
        #expect(chat.items.dropFirst(2).first == .handover(id: "handover:\(newID.uuidString)", notice: notice, at: at.timeIntervalSince1970))
        #expect(notice.hasPrefix("Started a fresh lead session at "))
        // The earlier session's rows are display only: no Send Again or Edit in Composer; the live session's keep them.
        #expect(chat.isHistory("o1") && chat.isHistory("handover:\(newID.uuidString)") && !chat.isHistory("n3"))

        // The old lead's own chat, and a chat with no lead's history: exactly its own turns.
        let plain = ChatModel(home: home)
        await Self.opened(plain, path: new.path, history: nil)
        #expect(plain.items.map(\.id) == ["n1", "n2.0", "n3"])
        let first = ChatModel(home: home)
        await Self.opened(first, path: old.path, history: .init(root: root, session: oldID.uuidString))
        #expect(first.items.map(\.id) == ["o1", "o2.0", "o3", "o4.0"])
    }
}
