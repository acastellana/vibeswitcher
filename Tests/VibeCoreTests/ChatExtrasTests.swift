import Foundation
import Testing
@testable import VibeCore

struct ChatExtrasTests {
    func lines(_ objects: [[String: Any]]) -> Data {
        var data = Data()
        for object in objects {
            data.append(try! JSONSerialization.data(withJSONObject: object))
            data.append(0x0A)
        }
        return data
    }

    func log(_ objects: [[String: Any]], format: TranscriptReader.Format = .claude) -> ChatLog {
        var log = ChatLog()
        log.append(ChatReader.read(lines(objects), format: format).events)
        return log
    }

    func assistant(_ blocks: [[String: Any]], id: String = "msg1", uuid: String = "a1", usage: [String: Any]? = nil) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "id": id, "model": "claude-opus-5-5", "content": blocks]
        if let usage { message["usage"] = usage }
        return ["type": "assistant", "uuid": uuid, "timestamp": "2026-10-16T10:00:00Z", "message": message]
    }

    @Test func claudeUsageCountsEachMessageOnce() {
        let usage: [String: Any] = ["input_tokens": 10, "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 90, "output_tokens": 50]
        let chat = log([assistant([["type": "text", "text": "a"]], uuid: "a1", usage: usage),
                        assistant([["type": "text", "text": "b"]], uuid: "a2", usage: usage),   // same message, next block
                        assistant([["type": "text", "text": "c"]], id: "msg2", uuid: "a3", usage: usage)])
        #expect(chat.usage?.model == "claude-opus-5-5")
        #expect(chat.usage?.contextTokens == 1100)
        #expect(chat.outputTokens == 100)
        #expect(chat.usage?.contextWindow == nil)
    }

    @Test func codexTokenCountsAndModel() {
        let chat = log([
            ["type": "turn_context", "payload": ["model": "gpt-5.5-codex", "cwd": "/x"]],
            ["type": "event_msg", "payload": ["type": "token_count", "info": [
                "last_token_usage": ["input_tokens": 21691, "output_tokens": 270],
                "total_token_usage": ["input_tokens": 50000, "output_tokens": 900],
                "model_context_window": 258400], "rate_limits": ["primary": ["used_percent": 9.0]]]],
        ], format: .codex)
        #expect(chat.usage?.model == "gpt-5.5-codex")
        #expect(chat.usage?.contextTokens == 21691)
        #expect(chat.usage?.contextWindow == 258400)
        #expect(chat.usage?.rateLimitPercent == 9.0)
        #expect(chat.outputTokens == 900)
    }

    @Test func todosPlansAndThinking() {
        let chat = log([assistant([
            ["type": "thinking", "thinking": "Let me look at the build first.\nThen tests."],
            ["type": "thinking", "thinking": ""],
            ["type": "tool_use", "id": "t1", "name": "TodoWrite", "input": ["todos": [
                ["content": "Build", "status": "completed"], ["content": "Test", "status": "in_progress"], ["content": "Ship", "status": "pending"]]]],
            ["type": "tool_use", "id": "t2", "name": "ExitPlanMode", "input": ["plan": "# Plan\n1. Do it"]],
        ])])
        let tools = chat.entries.compactMap { entry -> ChatTool? in if case .tool(let tool) = entry.kind { return tool } else { return nil } }
        #expect(tools.map(\.detail) == [.thought("Let me look at the build first.\nThen tests."),
                                       .todos([ChatTodo(text: "Build", status: .done), ChatTodo(text: "Test", status: .active),
                                               ChatTodo(text: "Ship", status: .pending)]),
                                       .plan("# Plan\n1. Do it")])
        #expect(tools[0].title == "Let me look at the build first.")
        #expect(chat.todos?.map(\.text) == ["Build", "Test", "Ship"])
        #expect(ChatTimeline.summary(tools) == "Updated the to-dos · wrote a plan")
        #expect(ChatTimeline.summary([tools[0]]) == "Thought")
    }

    @Test func codexPlanUpdatesAndReasoningSummaries() {
        let line = { (payload: [String: Any]) -> [String: Any] in ["type": "response_item", "timestamp": "2026-10-16T10:00:00Z", "payload": payload] }
        let chat = log([
            line(["type": "reasoning", "id": "r1", "summary": [["type": "summary_text", "text": "**Checking files**"]]]),
            line(["type": "function_call", "name": "update_plan", "call_id": "c1",
                  "arguments": "{\"plan\":[{\"step\":\"Read\",\"status\":\"completed\"},{\"step\":\"Write\",\"status\":\"in_progress\"}]}"]),
        ], format: .codex)
        let tools = chat.entries.compactMap { entry -> ChatTool? in if case .tool(let tool) = entry.kind { return tool } else { return nil } }
        #expect(tools.map(\.detail) == [.thought("**Checking files**"),
                                       .todos([ChatTodo(text: "Read", status: .done), ChatTodo(text: "Write", status: .active)])])
    }

    @Test func exportAsMarkdown() {
        let result = ChatResult(output: "", truncated: false, failed: false, at: nil, images: [])
        let entries = [ChatEntry(id: "p", at: nil, kind: .prompt(text: "Fix it", images: [])),
                       ChatEntry(id: "t", at: nil, kind: .tool(ChatTool(id: "t", name: "Bash", title: "Run tests", detail: .command("swift test"),
                                                                         at: nil, result: result))),
                       ChatEntry(id: "r", at: nil, kind: .reply("Fixed **it**."))]
        #expect(ChatExport.markdown(entries, agent: "Claude") ==
                "**You**\n\nFix it\n\n> Ran 1 command\n\n**Claude**\n\nFixed **it**.\n")
    }

    @Test func queuedMessagesDisappearOnceTheyShowUp() {
        let pending = [PendingMessage(text: "next", afterPrompts: 2), PendingMessage(text: "later", afterPrompts: 2)]
        #expect(PendingMessage.remaining(pending, prompts: ["a", "next"]).map(\.text) == ["next", "later"])   // "next" was sent earlier too
        #expect(PendingMessage.remaining(pending, prompts: ["a", "b", "next"]).map(\.text) == ["later"])
    }

    @Test func pathsInCodeBecomeLinksWhenTheyExist() {
        let exists = { (path: String) in ["/repo/Sources/App.swift", "/etc/hosts", NSHomeDirectory() + "/notes.md"].contains(path) }
        #expect(PathLinks.target("Sources/App.swift:42", cwd: "/repo", exists: exists) == "/repo/Sources/App.swift")
        #expect(PathLinks.target("/etc/hosts", cwd: nil, exists: exists) == "/etc/hosts")
        #expect(PathLinks.target("~/notes.md", cwd: nil, exists: exists) == NSHomeDirectory() + "/notes.md")
        #expect(PathLinks.target("let x = 1", cwd: "/repo", exists: exists) == nil)
        #expect(PathLinks.target("Missing.swift", cwd: "/repo", exists: exists) == nil)
    }
}
