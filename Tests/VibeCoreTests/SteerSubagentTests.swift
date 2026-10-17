import Foundation
import Testing
@testable import VibeCore

/// Messages for an agent reach its main thread, never a subagent's tool result (seen live: a verifier's report for the
/// lead landed in the WebFetch result of a background subagent the lead had started, and the lead never got it).
struct SteerSubagentTests {
    /// Hook payloads recorded from Claude Code 2.1.302 (`claude -p`, a foreground general-purpose subagent running one
    /// Bash command), in the order they fired; paths shortened, prompts and tool results trimmed.
    static let recorded: [(name: String, json: String)] = [
        ("main prompt", #"{"session_id":"e3db30de-fab4-4169-8309-10b3d589f049","transcript_path":"/tmp/rec/e3db30de-fab4-4169-8309-10b3d589f049.jsonl","cwd":"/tmp/rec","prompt_id":"f6339138-55cc-4985-8a58-acfc9ef99375","permission_mode":"auto","hook_event_name":"UserPromptSubmit","prompt":"First run the shell command: echo main-t"}"#),
        ("main Bash", #"{"session_id":"e3db30de-fab4-4169-8309-10b3d589f049","transcript_path":"/tmp/rec/e3db30de-fab4-4169-8309-10b3d589f049.jsonl","cwd":"/tmp/rec","prompt_id":"f6339138-55cc-4985-8a58-acfc9ef99375","permission_mode":"auto","effort":{"level":"medium"},"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo main-thread","description":"Echo main-thread"},"tool_response":{"stdout":"main-thread","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false},"tool_use_id":"toolu_01JjKb3zKFrvWFrYTRpL2T5a","duration_ms":61}"#),
        ("subagent Bash", #"{"session_id":"e3db30de-fab4-4169-8309-10b3d589f049","transcript_path":"/tmp/rec/e3db30de-fab4-4169-8309-10b3d589f049.jsonl","cwd":"/tmp/rec","prompt_id":"f6339138-55cc-4985-8a58-acfc9ef99375","permission_mode":"auto","agent_id":"ad4f57ccde05da3b1","agent_type":"general-purpose","effort":{"level":"medium"},"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo from-subagent","description":"Echo the requested test string"},"tool_response":{"stdout":"from-subagent","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false},"tool_use_id":"toolu_01PvzBCh9kduk2S29fAsWN9Z","duration_ms":7}"#),
        ("subagent hand-back", #"{"session_id":"e3db30de-fab4-4169-8309-10b3d589f049","transcript_path":"/tmp/rec/e3db30de-fab4-4169-8309-10b3d589f049.jsonl","cwd":"/tmp/rec","prompt_id":"f6339138-55cc-4985-8a58-acfc9ef99375","permission_mode":"auto","agent_id":"ad4f57ccde05da3b1","agent_type":"general-purpose","effort":{"level":"medium"},"hook_event_name":"PostToolUse","tool_name":"SubagentHandback","tool_input":{"message":"The Bash command `echo from-su"},"tool_response":{"status":"completed"},"tool_use_id":"toolu_01USgzofKXRhzyMdzcFesz5J","duration_ms":17}"#),
        ("subagent stop", #"{"session_id":"e3db30de-fab4-4169-8309-10b3d589f049","transcript_path":"/tmp/rec/e3db30de-fab4-4169-8309-10b3d589f049.jsonl","cwd":"/tmp/rec","prompt_id":"f6339138-55cc-4985-8a58-acfc9ef99375","permission_mode":"auto","agent_id":"ad4f57ccde05da3b1","agent_type":"general-purpose","effort":{"level":"medium"},"hook_event_name":"SubagentStop","stop_hook_active":false,"agent_transcript_path":"/tmp/rec/agent-ad4f57ccde05da3b1.jsonl","background_tasks":[],"session_crons":[]}"#),
        ("main Agent", #"{"session_id":"e3db30de-fab4-4169-8309-10b3d589f049","transcript_path":"/tmp/rec/e3db30de-fab4-4169-8309-10b3d589f049.jsonl","cwd":"/tmp/rec","prompt_id":"f6339138-55cc-4985-8a58-acfc9ef99375","permission_mode":"auto","effort":{"level":"medium"},"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"Run echo from-subagent","prompt":"Run exactly one shell command:","subagent_type":"general-purpose","run_in_background":false},"tool_response":{"status":"completed"},"tool_use_id":"toolu_01LJvxvdtZQesaRETzqhh6hW","duration_ms":3871}"#),
        ("main hand-back prompt", #"{"session_id":"e3db30de-fab4-4169-8309-10b3d589f049","transcript_path":"/tmp/rec/e3db30de-fab4-4169-8309-10b3d589f049.jsonl","cwd":"/tmp/rec","prompt_id":"f6339138-55cc-4985-8a58-acfc9ef99375","permission_mode":"auto","hook_event_name":"UserPromptSubmit","prompt":"<agent-message from=\"ad4f57ccde05da3b1\">"}"#),
        ("main stop", #"{"session_id":"e3db30de-fab4-4169-8309-10b3d589f049","transcript_path":"/tmp/rec/e3db30de-fab4-4169-8309-10b3d589f049.jsonl","cwd":"/tmp/rec","prompt_id":"f6339138-55cc-4985-8a58-acfc9ef99375","permission_mode":"auto","effort":{"level":"medium"},"hook_event_name":"Stop","stop_hook_active":false,"background_tasks":[],"session_crons":[]}"#),
    ]

    static func payload(_ name: String) throws -> [String: Any] {
        let json = try #require(recorded.first { $0.name == name }?.json)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("steer-sub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func report(_ id: String) -> SteerMessage {
        SteerMessage(id: id, text: "The audit of standard-mac-window-and passed", from: .system("verifier standard-mac-window-and"), agentPid: 42, at: 1)
    }

    @Test func onlyTheMainThreadsEventsTakeMessages() throws {
        let takers = try Self.recorded.filter { SteerReply.takesMessages(payload: try Self.payload($0.name)) }.map(\.name)
        #expect(takers == ["main prompt", "main Bash", "main Agent", "main hand-back prompt", "main stop"])
    }

    @Test func aSubagentsToolCallGetsNothingAndTheMainThreadGetsTheMessage() throws {
        let root = try root()
        try SteerInbox.post(report("r1"), tty: "ttys001", root: root)
        var written: [Data] = []
        // The subagent's Bash call and hand-back fire first: nothing is handed over, nothing is marked delivered.
        for name in ["subagent Bash", "subagent hand-back", "subagent stop"] {
            #expect(SteerReply.answer(try Self.payload(name), tty: "ttys001", agentPid: 42, root: root) { written.append($0); return true } == nil)
        }
        #expect(written.isEmpty)
        #expect(SteerInbox.pending(tty: "ttys001", root: root).map(\.id) == ["r1"])
        #expect(SteerInbox.delivered(tty: "ttys001", root: root).isEmpty)
        // The main thread's next tool call gets it.
        let output = try #require(SteerReply.answer(try Self.payload("main Agent"), tty: "ttys001", agentPid: 42, root: root) { written.append($0); return true })
        #expect(written == [output])
        let object = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        let context = try #require((object["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String)
        #expect(SteerReply.messages(inContext: context).map(\.text) == ["The audit of standard-mac-window-and passed"])
        #expect(SteerInbox.pending(tty: "ttys001", root: root).isEmpty)
        #expect(SteerInbox.delivered(tty: "ttys001", root: root) == ["r1"])
    }

    @Test func theMainThreadsStopKeepsTheTurnGoingWithIt() throws {
        let root = try root()
        try SteerInbox.post(report("r1"), tty: "ttys001", root: root)
        let output = try #require(SteerReply.answer(try Self.payload("main stop"), tty: "ttys001", agentPid: 42, root: root) { _ in true })
        let object = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(object["decision"] as? String == "block")
        #expect(SteerInbox.delivered(tty: "ttys001", root: root) == ["r1"])
    }

    @Test func aReplyThatCouldntBeWrittenLeavesTheMessageWaiting() throws {
        let root = try root()
        try SteerInbox.post(report("r1"), tty: "ttys001", root: root)
        try SteerInbox.post(report("r2"), tty: "ttys001", root: root)
        // The pipe is gone (the hook timed out, Claude Code moved on): nothing is in the agent's context.
        #expect(SteerReply.answer(try Self.payload("main Bash"), tty: "ttys001", agentPid: 42, root: root) { _ in false } == nil)
        #expect(SteerInbox.delivered(tty: "ttys001", root: root).isEmpty)
        #expect(SteerInbox.pending(tty: "ttys001", root: root).map(\.id) == ["r1", "r2"])
        #expect(SteerReply.answer(try Self.payload("main Bash"), tty: "ttys001", agentPid: 42, root: root) { _ in true } != nil)
        #expect(SteerInbox.delivered(tty: "ttys001", root: root) == ["r1", "r2"])
    }

    @Test func onlyWhatWentInIsMarkedDeliveredTheRestStaysFirstInLine() throws {
        let root = try root()
        for id in ["a", "b", "c"] { try SteerInbox.post(report(id), tty: "ttys001", root: root) }
        let handed = SteerInbox.deliver(tty: "ttys001", agentPid: 42, root: root) { messages in
            #expect(messages.map(\.id) == ["a", "b", "c"])
            return 1
        }
        #expect(handed.map(\.id) == ["a"])
        #expect(SteerInbox.delivered(tty: "ttys001", root: root) == ["a"])
        try SteerInbox.post(report("d"), tty: "ttys001", root: root)
        #expect(SteerInbox.pending(tty: "ttys001", root: root).map(\.id) == ["b", "c", "d"])
    }
}
