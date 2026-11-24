import Foundation
import Testing
@testable import VibeCore

/// A project lead's chat reads as one conversation across handovers (`LeadChatHistory`): the earlier lead sessions'
/// turns, a divider per handover, then the live session's.
struct LeadChatHistoryTests {
    /// A project and a home of its own, with Claude transcripts in `~/.claude/projects/<project>/`.
    struct Fixture {
        let scratch = Scratch()
        let root: String
        let home: String
        let projects: URL

        init() throws {
            root = scratch.url("lead-chat-project").path
            home = scratch.url("lead-chat-home").path
            projects = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects/-lead-chat-project")
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        }

        static func time(_ minute: Int) -> String { String(format: "2026-11-22T09:%02d:00.000Z", minute) }
        static func at(_ minute: Int) -> Double { ISO8601DateFormatter().date(from: String(format: "2026-11-22T09:%02d:00Z", minute))!.timeIntervalSince1970 }

        static func user(_ id: String, _ text: String, minute: Int) -> [String: Any] {
            ["type": "user", "uuid": id, "timestamp": time(minute), "message": ["role": "user", "content": text]]
        }
        static func reply(_ id: String, _ text: String, minute: Int) -> [String: Any] {
            ["type": "assistant", "uuid": id, "timestamp": time(minute),
             "message": ["role": "assistant", "content": [["type": "text", "text": text]]]]
        }

        /// A transcript of `lines` named `name`.
        @discardableResult
        func transcript(_ name: String, _ lines: [[String: Any]]) throws -> String {
            var data = Data()
            for line in lines {
                data.append(try JSONSerialization.data(withJSONObject: line))
                data.append(0x0A)
            }
            let url = projects.appendingPathComponent("\(name).jsonl")
            try data.write(to: url)
            return url.path
        }

        func handover(from: String, to: String, transcript: String?, minute: Int, reason: String, root: String? = nil, role: String = "lead") throws {
            try LeadChatHistory.record(.init(from: from, to: to, transcript: transcript, at: Self.at(minute), reason: reason,
                                             root: root ?? self.root, role: role))
        }

        /// The texts of a part's prompts and replies, in order.
        static func texts(_ entries: [ChatEntry]) -> [String] {
            entries.compactMap { entry in
                switch entry.kind {
                case .prompt(let text, _), .steered(let text, _), .reply(let text): return text
                case .tool: return nil
                }
            }
        }
    }

    static let a = UUID().uuidString, b = UUID().uuidString, c = UUID().uuidString

    @Test func twoEarlierSessionsComeInOrderEachWithItsDivider() throws {
        let fixture = try Fixture()
        let first = try fixture.transcript("a", [Fixture.user("a1", "Make the films page", minute: 1), Fixture.reply("a2", "Started a worker on it.", minute: 2)])
        let second = try fixture.transcript("b", [Fixture.user("b1", "Add a dark mode", minute: 11), Fixture.reply("b2", "Planned it.", minute: 12)])
        try fixture.handover(from: Self.a, to: Self.b, transcript: first, minute: 10, reason: "the last session was over 24 hours old")
        try fixture.handover(from: Self.b, to: Self.c, transcript: second, minute: 20, reason: "the last one's context was 72% full")

        let parts = LeadChatHistory.parts(session: Self.c, root: fixture.root, home: fixture.home)
        #expect(parts.map(\.handover.to) == [Self.b, Self.c])
        #expect(parts.map { Fixture.texts($0.entries) } == [["Make the films page", "Started a worker on it."], ["Add a dark mode", "Planned it."]])
        let items = LeadChatHistory.items(parts)
        #expect(items.map(\.id) == ["a1", "a2.0", "handover:\(Self.b)", "b1", "b2.0", "handover:\(Self.c)"])
        let dividers = items.compactMap { item -> String? in if case .handover(_, let notice, _) = item { return notice } else { return nil } }
        #expect(dividers == [LeadRotation.notice(reason: "the last session was over 24 hours old", at: Date(timeIntervalSince1970: Fixture.at(10))),
                             LeadRotation.notice(reason: "the last one's context was 72% full", at: Date(timeIntervalSince1970: Fixture.at(20)))])
        #expect(dividers.allSatisfy { $0.hasPrefix("Started a fresh lead session at ") })

        // The middle session's own chat: only the one before it.
        #expect(LeadChatHistory.parts(session: Self.b, root: fixture.root, home: fixture.home).map(\.handover.to) == [Self.b])
        // A lead no handover led to: none.
        #expect(LeadChatHistory.parts(session: Self.a, root: fixture.root, home: fixture.home).isEmpty)
        #expect(LeadChatHistory.parts(session: UUID().uuidString, root: fixture.root, home: fixture.home).isEmpty)
    }

    /// A lead reopened after a restart carries on B's conversation in a new window session: its chat keeps A's turns
    /// and the line where B began; a reopen of a lead no handover led to adds nothing.
    @Test func aReopenedLeadKeepsItsEarlierSessions() throws {
        let fixture = try Fixture()
        let first = try fixture.transcript("a", [Fixture.user("a1", "Make the films page", minute: 1)])
        try fixture.handover(from: Self.a, to: Self.b, transcript: first, minute: 10, reason: "scheduled")
        let reopened = UUID().uuidString
        try LeadChatHistory.carry(root: fixture.root, from: Self.b, to: reopened)
        let parts = LeadChatHistory.parts(session: reopened, root: fixture.root, home: fixture.home)
        #expect(parts.map { Fixture.texts($0.entries) } == [["Make the films page"]])
        #expect(parts.map(\.handover.notice) == [LeadRotation.notice(reason: "scheduled", at: Date(timeIntervalSince1970: Fixture.at(10)))])
        let count = LeadChatHistory.load(root: fixture.root).count
        try LeadChatHistory.carry(root: fixture.root, from: Self.a, to: UUID().uuidString)
        #expect(LeadChatHistory.load(root: fixture.root).count == count)
    }

    @Test func theHandoversMachineryIsNotConversation() throws {
        let fixture = try Fixture()
        let marker = LeadRotation.noteMarker + UUID().uuidString
        let request = LeadRotation.request + " Start your reply with this line:\n" + marker + "\nThen write the handover note."
        let first = try fixture.transcript("a", [
            Fixture.user("a1", "Make the films page", minute: 1),
            Fixture.reply("a2", "On it.", minute: 2),
            Fixture.user("a3", request, minute: 8),
            Fixture.reply("a4", marker + "\nOpen threads: the films page worker.", minute: 9),
        ])
        let start = LeadPrompts.leadStart(root: fixture.root, goal: nil, note: "a note", replaced: ("/dev/ttys001", "/x/replaced-lead-turns.md"),
                                          scheduledNote: "/x/scheduled-lead-handover.md")
        let second = try fixture.transcript("b", [
            Fixture.user("b1", start, minute: 10),
            Fixture.reply("b2", "Took over: the films page worker runs.", minute: 10),
            Fixture.user("b3", "Thanks", minute: 11),
        ])
        try fixture.handover(from: Self.a, to: Self.b, transcript: first, minute: 10, reason: "scheduled")
        try fixture.handover(from: Self.b, to: Self.c, transcript: second, minute: 20, reason: "scheduled")

        let parts = LeadChatHistory.parts(session: Self.c, root: fixture.root, home: fixture.home)
        #expect(parts.map { Fixture.texts($0.entries) } == [["Make the films page", "On it."], ["Took over: the films page worker runs.", "Thanks"]])
        // Nor in the live session: its start prompt goes, the rest stays.
        let live = [ChatEntry(id: "c1", at: nil, kind: .prompt(text: start, images: [])), ChatEntry(id: "c2", at: nil, kind: .reply("Hello"))]
        #expect(LeadChatHistory.conversation(live, startedByHandover: true).map(\.id) == ["c2"])
        // A lead no handover started keeps its start prompt (as the chat shows it today).
        #expect(LeadChatHistory.conversation(live, startedByHandover: false).map(\.id) == ["c1", "c2"])
    }

    @Test func onlyThisProjectsLeadSessionsAreStitched() throws {
        let fixture = try Fixture()
        let other = try Fixture()
        let lead = try fixture.transcript("a", [Fixture.user("a1", "The lead's turn", minute: 1)])
        let worker = try fixture.transcript("w", [Fixture.user("w1", "A worker's turn", minute: 2)])
        let elsewhere = try other.transcript("o", [Fixture.user("o1", "Another project's lead", minute: 3)])
        // Another project's handover into the same session id, in its own record and (forged) in this one's.
        try other.handover(from: UUID().uuidString, to: Self.c, transcript: elsewhere, minute: 4, reason: "other")
        try fixture.handover(from: Self.a, to: Self.b, transcript: lead, minute: 10, reason: "scheduled")
        // Entries naming a worker, a verifier, a shell or another project never join the chain.
        try fixture.handover(from: "worker", to: Self.a, transcript: worker, minute: 5, reason: "x", role: "worker")
        try fixture.handover(from: "verifier", to: "worker", transcript: worker, minute: 4, reason: "x", role: "verifier")
        try fixture.handover(from: "shell", to: "verifier", transcript: nil, minute: 3, reason: "x", role: "shell")
        try fixture.handover(from: "elsewhere", to: Self.c, transcript: elsewhere, minute: 30, reason: "x", root: other.root)

        let parts = LeadChatHistory.parts(session: Self.b, root: fixture.root, home: fixture.home)
        #expect(parts.map(\.handover.from) == [Self.a])
        #expect(parts.flatMap { Fixture.texts($0.entries) } == ["The lead's turn"])
        #expect(LeadChatHistory.parts(session: Self.c, root: fixture.root, home: fixture.home).isEmpty)
        #expect(LeadChatHistory.parts(session: Self.c, root: other.root, home: other.home).map { Fixture.texts($0.entries) } == [["Another project's lead"]])

        // Only a lead's window session has earlier sessions: never a worker's, a verifier's or a shell's.
        let session = UUID()
        #expect(LeadChatHistory.source(label: "Lead · site", session: session, cwd: fixture.root) == .init(root: fixture.root, session: session.uuidString))
        for label in ["Worker: films-page", "Verifier: films-page", "Shell", "Claude", nil] as [String?] {
            #expect(LeadChatHistory.source(label: label, session: session, cwd: fixture.root) == nil)
        }
    }

    @Test func aMissingOrUnreadableTranscriptKeepsItsDivider() throws {
        let fixture = try Fixture()
        let missing = fixture.projects.appendingPathComponent("gone.jsonl").path
        // Not a transcript the chat reads: outside ~/.claude/projects, and a folder named like one.
        let outside = fixture.scratch.adopt(fixture.scratch.url("outside").appendingPathExtension("jsonl"))
        try Data("{\"type\":\"user\",\"uuid\":\"x\",\"message\":{\"role\":\"user\",\"content\":\"secret\"}}\n".utf8).write(to: outside)
        let folder = fixture.projects.appendingPathComponent("folder.jsonl")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let last = try fixture.transcript("d", [Fixture.user("d1", "Still here", minute: 31)])
        let sessions = (0..<4).map { _ in UUID().uuidString } + [Self.c]
        for (index, transcript) in [missing, outside.path, folder.path, last].enumerated() {
            try fixture.handover(from: sessions[index], to: sessions[index + 1], transcript: transcript, minute: 10 * index + 1, reason: "r\(index)")
        }
        // The newest three: the outside one, the folder, the readable one.
        let parts = LeadChatHistory.parts(session: Self.c, root: fixture.root, home: fixture.home)
        #expect(parts.map(\.handover.reason) == ["r1", "r2", "r3"])
        #expect(parts.map { Fixture.texts($0.entries) } == [[], [], ["Still here"]])
        #expect(LeadChatHistory.items(parts).filter { if case .handover = $0 { true } else { false } }.count == 3)
        // The missing one, from the session after it.
        let before = LeadChatHistory.parts(session: sessions[1], root: fixture.root, home: fixture.home)
        #expect(before.map(\.handover.reason) == ["r0"])
        #expect(before.first?.entries.isEmpty == true)
    }

    @Test func tenEarlierSessionsReadNoMoreThanTheCap() throws {
        let fixture = try Fixture()
        let sessions = (0..<10).map { _ in UUID().uuidString } + [Self.c]
        for index in 0..<10 {
            let path = try fixture.transcript("s\(index)", [Fixture.user("s\(index)", "Session \(index)", minute: index)])
            try fixture.handover(from: sessions[index], to: sessions[index + 1], transcript: path, minute: index, reason: "r\(index)")
        }
        let reads = Counter()
        let parts = LeadChatHistory.parts(session: Self.c, root: fixture.root, home: fixture.home) { url in
            reads.add()
            return LeadChatHistory.tail(url)
        }
        #expect(reads.count == LeadChatHistory.maxSessions)
        #expect(parts.map(\.handover.reason) == ["r7", "r8", "r9"])

        // Each from its end, at most `tailBytes`.
        let line = String(repeating: "x", count: 1000)
        let big = try fixture.transcript("big", (0..<3000).map { Fixture.user("big\($0)", line, minute: 50) })
        let size = try #require(FileManager.default.attributesOfItem(atPath: big)[.size] as? Int)
        #expect(size > 2 * LeadChatHistory.tailBytes)
        let tail = try #require(LeadChatHistory.tail(URL(fileURLWithPath: big)))
        #expect(tail.count <= LeadChatHistory.tailBytes)
        #expect(tail.count > LeadChatHistory.tailBytes - 2000)

        // The record itself stays bounded.
        for index in 0..<(LeadChatHistory.kept + 5) {
            try fixture.handover(from: "x\(index)", to: "x\(index + 1)", transcript: nil, minute: 1, reason: "bulk")
        }
        #expect(LeadChatHistory.load(root: fixture.root).count == LeadChatHistory.kept)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func add() { lock.lock(); value += 1; lock.unlock() }
    }
}
