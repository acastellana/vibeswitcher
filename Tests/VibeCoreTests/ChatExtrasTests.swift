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

    func assistant(_ blocks: [[String: Any]], id: String = "msg1", uuid: String = "a1", usage: [String: Any]? = nil,
                   model: String = "claude-opus-5-5") -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "id": id, "model": model, "content": blocks]
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

    /// "i changed to opus but the chat view didnt update": `/model opus` answered, and the chip still read Fable 5.2
    /// until the next reply. The command's output in the transcript switches it at once.
    @Test func modelCommandSwitchesTheModelBeforeTheNextReply() {
        let usage: [String: Any] = ["input_tokens": 10, "cache_read_input_tokens": 1000, "output_tokens": 50]
        let stdout = "<local-command-stdout>Set model to `Opus 5.5` and saved as your default for new sessions</local-command-stdout>"
        let switched = log([
            assistant([["type": "text", "text": "a"]], uuid: "a1", usage: usage, model: "claude-fable-5-2"),
            ["type": "user", "uuid": "u1", "timestamp": "2026-10-16T10:01:00Z", "message": ["role": "user", "content": stdout]],
        ])
        #expect(switched.usage?.model == "claude-opus-5-5")
        #expect(switched.usage?.contextTokens == 1010)
        #expect(switched.entries.count == 1)   // the command's output isn't a prompt
    }

    /// Claude Code's other ways of writing it: a system local_command line, the name in ANSI bold, an id in brackets.
    @Test func modelCommandOutputInItsOtherShapes() {
        let fable = assistant([["type": "text", "text": "a"]], uuid: "a1", usage: ["input_tokens": 5, "output_tokens": 1],
                              model: "claude-fable-5-2")
        func system(_ text: String) -> [String: Any] {
            ["type": "system", "subtype": "local_command", "uuid": "s1", "timestamp": "2026-10-16T10:01:00Z",
             "content": "<local-command-stdout>\(text)</local-command-stdout>"]
        }
        #expect(log([fable, system("Set model to \u{1B}[1mSonnet 5.5\u{1B}[22m")]).usage?.model == "claude-sonnet-5-5")
        #expect(log([fable, system("Set model to **Haiku 5.5** (claude-haiku-5-5-20261001)")]).usage?.model == "claude-haiku-5-5-20261001")
        #expect(log([fable, system("Set model to Opus 5.5 (1M context)")]).usage?.model == "claude-opus-5-5")
        #expect(log([fable, ["type": "user", "uuid": "u1", "message": ["role": "user", "content": [
            ["type": "text", "text": "<local-command-stdout>Set model to Opus 5.5</local-command-stdout>"]]]]]).usage?.model == "claude-opus-5-5")
        // Kept, failed or other commands' output leave the model alone.
        #expect(log([fable, system("Kept model as Fable 5.2")]).usage?.model == "claude-fable-5-2")
        #expect(log([fable, system("Model 'foo' not found")]).usage?.model == "claude-fable-5-2")
        // Typed by the user, it's a prompt, not a switch.
        #expect(log([fable, ["type": "user", "uuid": "u1", "message": ["role": "user", "content": "Set model to Opus 5.5"]]]).usage?.model
                == "claude-fable-5-2")
    }

    /// Claude Code may write the command, its output and text typed after it in one user line: the text stays a prompt.
    /// The same words quoted in a prompt (a pasted task, a log) aren't a switch, and the prompt shows.
    @Test func modelCommandOutputInAPromptLine() {
        let fable = assistant([["type": "text", "text": "a"]], uuid: "a1", usage: ["input_tokens": 5, "output_tokens": 1],
                              model: "claude-fable-5-2")
        let combined = "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>opus</command-args>\n"
            + "<local-command-stdout>Set model to Opus 5.5</local-command-stdout>\nnow fix the bug"
        let both = log([fable, ["type": "user", "uuid": "u1", "message": ["role": "user", "content": combined]]])
        #expect(both.usage?.model == "claude-opus-5-5")
        #expect(both.prompts == ["now fix the bug"])
        let quoted = "The chip should follow `<local-command-stdout>Set model to `Opus 5.5` and saved as your default</local-command-stdout>`"
        let pasted = log([fable, ["type": "user", "uuid": "u1", "message": ["role": "user", "content": quoted]]])
        #expect(pasted.usage?.model == "claude-fable-5-2")
        #expect(pasted.prompts.count == 1)
        let wrapped = "<pasted_content id=\"p1\">\n<local-command-stdout>Set model to Opus 5.5</local-command-stdout>\n</pasted_content id=\"p1\">"
        #expect(log([fable, ["type": "user", "uuid": "u1", "message": ["role": "user", "content": wrapped]]]).usage?.model == "claude-fable-5-2")
    }

    /// The next reply says which model really answered: if it differs from what /model said, it wins.
    @Test func aLaterReplyOnAnotherModelWins() {
        let chat = log([
            assistant([["type": "text", "text": "a"]], uuid: "a1", usage: ["input_tokens": 5, "output_tokens": 1], model: "claude-fable-5-2"),
            ["type": "system", "subtype": "local_command", "uuid": "s1", "timestamp": "2026-10-16T10:01:00Z",
             "content": "<local-command-stdout>Set model to Opus 5.5 and saved as your default for new sessions</local-command-stdout>"],
            assistant([["type": "text", "text": "b"]], id: "msg2", uuid: "a2", usage: ["input_tokens": 5, "output_tokens": 1],
                      model: "claude-sonnet-5-5"),
        ])
        #expect(chat.usage?.model == "claude-sonnet-5-5")
        // Read in two parts, the earlier part's switch doesn't replace the later reply's model either.
        var split = ChatLog()
        let all = lines([
            assistant([["type": "text", "text": "a"]], uuid: "a1", usage: ["input_tokens": 5, "output_tokens": 1], model: "claude-fable-5-2"),
            ["type": "system", "subtype": "local_command", "uuid": "s1",
             "content": "<local-command-stdout>Set model to Opus 5.5</local-command-stdout>"],
        ])
        split.append(ChatReader.read(lines([assistant([["type": "text", "text": "b"]], id: "msg2", uuid: "a2",
                                                       usage: ["input_tokens": 5, "output_tokens": 1], model: "claude-sonnet-5-5")]),
                                     format: .claude).events)
        split.prepend(ChatReader.read(all, format: .claude).events)
        #expect(split.usage?.model == "claude-sonnet-5-5")
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
