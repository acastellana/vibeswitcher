import Foundation
import Testing
@testable import VibeCore

struct SteerTests {
    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("steer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func message(_ text: String, pid: Int32 = 42, from: SteerMessage.Sender = .user, id: String = UUID().uuidString) -> SteerMessage {
        SteerMessage(id: id, text: text, from: from, agentPid: pid, at: 1)
    }

    @Test func postedMessagesAreTakenOnceByTheirAgent() throws {
        let root = try root()
        try SteerInbox.post(message("first", id: "a"), tty: "ttys001", root: root)
        try SteerInbox.post(message("second", id: "b"), tty: "ttys001", root: root)
        #expect(SteerInbox.take(tty: "ttys001", agentPid: 42, root: root).map(\.text) == ["first", "second"])
        #expect(SteerInbox.take(tty: "ttys001", agentPid: 42, root: root).isEmpty)
        #expect(SteerInbox.delivered(tty: "ttys001", root: root) == ["a", "b"])
    }

    @Test func messagesForAnEarlierAgentOnTheSameTerminalAreDropped() throws {
        let root = try root()
        try SteerInbox.post(message("stale", pid: 7, id: "old"), tty: "ttys001", root: root)
        try SteerInbox.post(message("fresh", pid: 42, id: "new"), tty: "ttys001", root: root)
        #expect(SteerInbox.take(tty: "ttys001", agentPid: 42, root: root).map(\.text) == ["fresh"])
        #expect(SteerInbox.delivered(tty: "ttys001", root: root) == ["new"])
        #expect(SteerInbox.pending(tty: "ttys001", root: root).isEmpty)
    }

    @Test func otherTerminalsAreSeparate() throws {
        let root = try root()
        try SteerInbox.post(message("x"), tty: "ttys002", root: root)
        #expect(SteerInbox.take(tty: "ttys001", agentPid: 42, root: root).isEmpty)
        #expect(SteerInbox.pending(tty: "ttys002", root: root).count == 1)
    }

    @Test func badTerminalNamesAreRefused() throws {
        let root = try root()
        #expect(throws: (any Error).self) { try SteerInbox.post(message("x"), tty: "../evil", root: root) }
    }

    @Test func repliesAddContextOrKeepTheTurnGoing() throws {
        let messages = [message("use port 8080"), message("and skip the docs", from: .lead("lead"))]
        let post = try #require(SteerReply.output(event: "PostToolUse", messages: messages))
        let object = try #require(try JSONSerialization.jsonObject(with: post) as? [String: Any])
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PostToolUse")
        let context = try #require(specific["additionalContext"] as? String)
        #expect(context.contains("The user sent this while you were working"))
        #expect(context.contains("use port 8080"))
        #expect(context.contains("not the user"))
        #expect(context.contains("and skip the docs"))

        let stop = try #require(SteerReply.output(event: "Stop", messages: messages))
        let stopObject = try #require(try JSONSerialization.jsonObject(with: stop) as? [String: Any])
        #expect(stopObject["decision"] as? String == "block")
        #expect((stopObject["reason"] as? String)?.contains("use port 8080") == true)

        #expect(SteerReply.output(event: "UserPromptSubmit", messages: messages) != nil)
        #expect(SteerReply.output(event: "PreToolUse", messages: messages) == nil)
        #expect(SteerReply.output(event: "PostToolUse", messages: []) == nil)
        #expect(SteerReply.takesMessages(event: "PreToolUse") == false)
        #expect(SteerReply.takesMessages(event: "Stop"))
    }

    @Test func longMessagesAreCutToTheHookLimit() throws {
        let big = message(String(repeating: "x", count: 20_000))
        let data = try #require(SteerReply.output(event: "PostToolUse", messages: [big]))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let context = (object["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String ?? ""
        #expect(context.count <= SteerReply.contextLimit)
    }
}

struct SteeredInTranscriptTests {
    @Test func deliveredSteeringShowsAsASteeredMessage() throws {
        let context = SteerReply.context([SteerMessage(text: "use port 8080", from: .user, agentPid: 1)])
        let line: [String: Any] = ["type": "attachment", "uuid": "s1", "timestamp": "2026-10-17T10:00:00Z",
                                   "attachment": ["type": "hook_additional_context", "content": [context], "hookEvent": "PostToolUse"]]
        let other: [String: Any] = ["type": "attachment", "uuid": "s2",
                                    "attachment": ["type": "hook_additional_context", "content": ["You are in learning mode"], "hookEvent": "SessionStart"]]
        var data = Data()
        for object in [line, other] { data.append(try JSONSerialization.data(withJSONObject: object)); data.append(0x0A) }
        var log = ChatLog()
        log.append(ChatReader.read(data, format: .claude).events)
        #expect(log.entries.map(\.kind) == [.steered(text: "use port 8080", fromLead: false)])
        #expect(log.prompts.isEmpty)
    }
}
