import Foundation
import Testing
@testable import VibeCore

struct TranscriptPathCaptureTests {
    func reduce(_ payload: [String: Any], onto state: HookState? = nil) -> HookState? {
        let update = HookState.reduce(current: state, payload: payload, agent: .claude, tty: "ttys001", agentPid: 42, now: 1000)
        if case .write(let next) = update { return next }
        return state
    }

    @Test func hooksRecordWhereTheTranscriptIs() throws {
        let path = "/Users/me/.claude/projects/-Users-me-app/s1.jsonl"
        let started = try #require(reduce(["hook_event_name": "SessionStart", "session_id": "s1", "transcript_path": path]))
        #expect(started.transcriptPath == path)
        // Events without the field keep it; absurd values are ignored.
        let prompted = try #require(reduce(["hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt": "hi"], onto: started))
        #expect(prompted.transcriptPath == path)
        let junk = try #require(reduce(["hook_event_name": "Stop", "session_id": "s1",
                                        "transcript_path": String(repeating: "x", count: 5000)], onto: prompted))
        #expect(junk.transcriptPath == path)
    }
}

struct ScrollbackTests {
    @Test func dropsTheVisibleScreenFromTheEnd() {
        #expect(Scrollback.lines(history: "a\nb\nc\nd\n", screen: "c\nd\n") == ["a", "b"])
        #expect(Scrollback.lines(history: "a\nb\nc  \nd   \n\n", screen: "c\nd") == ["a", "b"])
        // No overlap (e.g. the screen just redrew): keep everything rather than guess.
        #expect(Scrollback.lines(history: "a\nb", screen: "zzz") == ["a", "b"])
        #expect(Scrollback.lines(history: "", screen: "x") == [])
    }

    @Test func pagesBackwardsByAbsoluteLineNumber() {
        let lines = (0..<1200).map(String.init)
        let last = Scrollback.page(lines, before: nil, limit: 500)
        #expect(last == Scrollback.Page(lines: Array(lines[700..<1200]), start: 700, total: 1200, first: 0))
        let earlier = Scrollback.page(lines, before: 700, limit: 500)
        #expect(earlier.start == 200)
        #expect(earlier.lines.first == "200")
        let oldest = Scrollback.page(lines, before: 200, limit: 500)
        #expect(oldest.start == 0)
        #expect(oldest.lines.count == 200)
        #expect(Scrollback.page(lines, before: 1200, limit: 9999).lines.count == Scrollback.pageLimit)
    }

    @Test func pagesNeverGoPastWhatExists() {
        let lines = (0..<6000).map(String.init)
        let capped = Scrollback.page(lines, before: 1500, limit: 500)
        #expect(capped.first == 1000)                // only the last 5,000 lines are reachable
        #expect(capped.start == 1000)
        #expect(capped.lines.count == 500)
        #expect(Scrollback.page(lines, before: 900, limit: 500).lines.isEmpty)
        // After `clear`, the phone may ask past the (now shorter) end.
        let shrunk = Scrollback.page(["x", "y"], before: 700, limit: 500)
        #expect(shrunk == Scrollback.Page(lines: ["x", "y"], start: 0, total: 2, first: 0))
        #expect(Scrollback.page(["x"], before: -5, limit: 500).lines.isEmpty)
    }
}

struct TranscriptReaderTests {
    func jsonl(_ objects: [[String: Any]]) -> Data {
        Data(objects.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n" }.joined().utf8)
    }

    let claudeLines: [[String: Any]] = [
        ["type": "user", "uuid": "u1", "timestamp": "2026-10-03T10:00:00.000Z", "message": ["role": "user", "content": "Fix the login bug"]],
        ["type": "user", "uuid": "u2", "timestamp": "2026-10-03T10:00:00.500Z", "isMeta": true, "message": ["role": "user", "content": "<local-command-caveat>x</local-command-caveat>"]],
        ["type": "user", "uuid": "u3", "timestamp": "2026-10-03T10:00:00.600Z", "message": ["role": "user", "content": "<task-notification>done</task-notification>"]],
        ["type": "assistant", "uuid": "a1", "timestamp": "2026-10-03T10:00:02.000Z", "message": ["role": "assistant", "content": [
            ["type": "thinking", "thinking": "secret plan"],
            ["type": "text", "text": "Looking at auth.ts first."],
            ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "npm test", "description": "Run unit tests"]],
        ]]],
        ["type": "user", "uuid": "u4", "timestamp": "2026-10-03T10:00:42.000Z", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "toolu_1", "content": "2 failed", "is_error": true],
        ]]],
        ["type": "assistant", "uuid": "a2", "isSidechain": true, "timestamp": "2026-10-03T10:00:43.000Z", "message": ["role": "assistant", "content": [["type": "text", "text": "subagent chatter"]]]],
        ["type": "system", "uuid": "s1", "timestamp": "2026-10-03T10:00:44.000Z", "content": "compacted"],
    ]

    @Test func readsClaudeTranscripts() {
        let result = TranscriptReader.read(jsonl(claudeLines), format: .claude)
        #expect(result.entries.map(\.kind) == [.prompt, .reply, .tool])
        #expect(result.entries[0].text == "Fix the login bug")
        #expect(result.entries[1].text == "Looking at auth.ts first.")
        let tool = result.entries[2]
        #expect(tool.id == "toolu_1")
        #expect(tool.tool == "Bash")
        #expect(tool.text == "Run unit tests")
        #expect(tool.output == "2 failed")
        #expect(tool.failed)
        #expect(tool.duration == 40)
        #expect(result.consumed == jsonl(claudeLines).count)
    }

    @Test func toolResultsArrivingLaterAreSeparateEntries() {
        let first = TranscriptReader.read(jsonl(Array(claudeLines[0...3])), format: .claude)
        #expect(first.entries.last?.kind == .tool)
        #expect(first.entries.last?.output == nil)
        let later = TranscriptReader.read(jsonl([claudeLines[4]]), format: .claude)
        #expect(later.entries.map(\.kind) == [.toolResult])
        #expect(later.entries[0].id == "toolu_1")
        #expect(later.entries[0].failed)
    }

    @Test func readsCodexTranscripts() {
        let lines: [[String: Any]] = [
            ["timestamp": "2026-10-03T10:00:00.000Z", "type": "session_meta", "payload": ["id": "x", "cwd": "/tmp"]],
            ["timestamp": "2026-10-03T10:00:00.100Z", "type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>x</environment_context>"]]]],
            ["timestamp": "2026-10-03T10:00:01.000Z", "type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "delete it"]]]],
            ["timestamp": "2026-10-03T10:00:02.000Z", "type": "response_item", "payload": ["type": "function_call", "name": "shell", "call_id": "c1", "arguments": "{\"command\":[\"rm\",\"old.ts\"]}"]],
            ["timestamp": "2026-10-03T10:00:03.000Z", "type": "response_item", "payload": ["type": "function_call_output", "call_id": "c1", "output": "ok"]],
            ["timestamp": "2026-10-03T10:00:04.000Z", "type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Removed it."]]]],
            ["timestamp": "2026-10-03T10:00:05.000Z", "type": "response_item", "payload": ["type": "reasoning", "summary": []]],
        ]
        let result = TranscriptReader.read(jsonl(lines), format: .codex)
        #expect(result.entries.map(\.kind) == [.prompt, .tool, .reply])
        #expect(result.entries[0].text == "delete it")
        #expect(result.entries[1].text == "rm old.ts")
        #expect(result.entries[1].output == "ok")
        #expect(result.entries[1].duration == 1)
        #expect(result.entries[2].text == "Removed it.")
    }

    @Test func incompleteLinesWaitForTheNextRead() {
        let full = jsonl(Array(claudeLines[0...1]))
        let cut = full + Data("{\"type\":\"user\",\"mess".utf8)
        let result = TranscriptReader.read(cut, format: .claude)
        #expect(result.entries.count == 1)
        #expect(result.consumed == full.count)
        let garbage = TranscriptReader.read(Data("not json\n".utf8) + full, format: .claude)
        #expect(garbage.entries.count == 1)
        // A tail read that starts mid-line skips to the first full line.
        let tail = Data("partial line}\n".utf8) + full
        #expect(TranscriptReader.tailStart(tail) == 14)
        #expect(TranscriptReader.tailStart(Data("no newline".utf8)) == 10)
    }

    @Test func toolOutputIsTruncatedAndImagesAreSummarized() {
        let long = String(repeating: "x", count: 10_000)
        let lines: [[String: Any]] = [
            ["type": "assistant", "uuid": "a", "message": ["content": [["type": "tool_use", "id": "t", "name": "Read", "input": ["file_path": "/a/b.png"]]]]],
            ["type": "user", "uuid": "u", "message": ["content": [["type": "tool_result", "tool_use_id": "t", "content": [
                ["type": "text", "text": long], ["type": "image", "source": ["type": "base64", "data": "AAAA"]],
            ]]]]],
        ]
        let result = TranscriptReader.read(jsonl(lines), format: .claude, outputLimit: 4096)
        let tool = result.entries[0]
        #expect(tool.output?.utf8.count ?? 0 <= 4096 + 40)
        #expect(tool.outputTruncated)
        #expect(!(tool.output ?? "").contains("AAAA"))
    }

    @Test func everythingIsMasked() {
        let token = "ghp_" + String(repeating: "a", count: 36)
        let lines: [[String: Any]] = [
            ["type": "user", "uuid": "u", "message": ["content": "use \(token) please"]],
            ["type": "assistant", "uuid": "a", "message": ["content": [
                ["type": "text", "text": "Using \(token)"],
                ["type": "tool_use", "id": "t", "name": "Bash", "input": ["command": "curl -H 'Authorization: Bearer \(token)' x"]],
            ]]],
            ["type": "user", "uuid": "r", "message": ["content": [["type": "tool_result", "tool_use_id": "t", "content": "token=\(token)"]]]],
        ]
        let result = TranscriptReader.read(jsonl(lines), format: .claude)
        for entry in result.entries {
            #expect(!entry.text.contains(token))
            #expect(!(entry.output ?? "").contains(token))
        }
    }

    @Test func transcriptPathsMustStayInTheAgentFolders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vs-home-\(UUID().uuidString)")
        let projects = home.appendingPathComponent(".claude/projects/p")
        let sessions = home.appendingPathComponent(".codex/sessions/2026/10/03")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let good = projects.appendingPathComponent("s.jsonl")
        try Data("{}\n".utf8).write(to: good)
        let codex = sessions.appendingPathComponent("rollout-x.jsonl")
        try Data("{}\n".utf8).write(to: codex)
        let outside = home.appendingPathComponent("secret.jsonl")
        try Data("{}\n".utf8).write(to: outside)
        let link = projects.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(TranscriptReader.checkedURL(good.path, home: home.path)?.1 == .claude)
        #expect(TranscriptReader.checkedURL(codex.path, home: home.path)?.1 == .codex)
        #expect(TranscriptReader.checkedURL(outside.path, home: home.path) == nil)
        #expect(TranscriptReader.checkedURL(link.path, home: home.path) == nil)
        #expect(TranscriptReader.checkedURL(projects.path + "/../../../secret.jsonl", home: home.path) == nil)
        #expect(TranscriptReader.checkedURL(projects.path, home: home.path) == nil)          // a directory
        #expect(TranscriptReader.checkedURL(projects.appendingPathComponent("none.jsonl").path, home: home.path) == nil)
    }
}

// Final-review fixes.
struct HistoryReviewFixTests {
    @Test func absurdPageRequestsDontCrash() {
        let page = Scrollback.page(["a", "b"], before: Int.min, limit: Int.max)
        #expect(page.lines.isEmpty)
        let fromEnd = Scrollback.page(["a", "b"], before: Int.max, limit: Int.min)
        #expect(fromEnd.lines.isEmpty)
    }

    @Test func cursorsOnlyContinueTheSameFileAndNeverReadTooMuch() {
        let tail = 2_000_000
        // Same file, small step: continue after the cursor.
        #expect(TranscriptWindow.plan(fileSize: 5_000, after: 4_000, sameFile: true, tailBytes: tail) == .init(start: 4_000, fresh: false))
        // Fresh open: the tail (from one byte early, so a line starting exactly there isn't skipped).
        #expect(TranscriptWindow.plan(fileSize: 5_000_000, after: nil, sameFile: true, tailBytes: tail) == .init(start: 2_999_999, fresh: true))
        #expect(TranscriptWindow.plan(fileSize: 100, after: nil, sameFile: true, tailBytes: tail) == .init(start: 0, fresh: true))
        // Another transcript (after /clear or /resume), a shrunk file, or a huge gap: start over from the tail.
        #expect(TranscriptWindow.plan(fileSize: 5_000, after: 4_000, sameFile: false, tailBytes: tail).fresh)
        #expect(TranscriptWindow.plan(fileSize: 3_000, after: 4_000, sameFile: true, tailBytes: tail).fresh)
        #expect(TranscriptWindow.plan(fileSize: 9_000_000, after: 10, sameFile: true, tailBytes: tail) == .init(start: 6_999_999, fresh: true))
    }

    @Test func freshTailsSkipOnlyAPartialFirstLine() {
        // Starting one byte early: if that byte is the newline ending the previous line, only it is skipped.
        #expect(TranscriptReader.tailStart(Data("\n{\"a\":1}\n".utf8)) == 1)
        #expect(TranscriptReader.tailStart(Data("ial}\n{\"a\":1}\n".utf8)) == 5)
    }

    @Test func showAllFindsOneCallInAHugeTranscript() throws {
        var lines: [String] = []
        for i in 0..<2_000 {
            lines.append(#"{"type":"assistant","uuid":"a\#(i)","message":{"content":[{"type":"tool_use","id":"t\#(i)","name":"Bash","input":{"command":"echo \#(i)"}}]}}"#)
            lines.append(#"{"type":"user","uuid":"u\#(i)","message":{"content":[{"type":"tool_result","tool_use_id":"t\#(i)","content":"out \#(i)"}]}}"#)
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let only = TranscriptReader.lines(mentioning: "t1234", in: data)
        #expect(only.split(separator: 0x0A).count == 2)
        let entry = try #require(TranscriptReader.read(only, format: .claude).entries.first { $0.id == "t1234" })
        #expect(entry.output == "out 1234")
    }

    @Test func longPromptsAndRepliesAreCapped() {
        let huge = String(repeating: "log line\n", count: 50_000)
        let object: [String: Any] = ["type": "user", "uuid": "u", "message": ["content": huge]]
        let data = Data((String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n").utf8)
        let entry = TranscriptReader.read(data, format: .claude).entries[0]
        #expect(entry.text.utf8.count <= TranscriptReader.textLimit + 8)
        #expect(entry.text.hasSuffix("…"))
    }
}
