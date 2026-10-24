import Foundation
import Testing
@testable import VibeCore

struct ChatTranscriptTests {
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

    func claudeUser(_ content: Any, uuid: String = "u1", at: String = "2026-10-16T10:00:00Z") -> [String: Any] {
        ["type": "user", "uuid": uuid, "timestamp": at, "message": ["role": "user", "content": content]]
    }

    func claudeAssistant(_ blocks: [[String: Any]], uuid: String = "a1", at: String = "2026-10-16T10:00:05Z") -> [String: Any] {
        ["type": "assistant", "uuid": uuid, "timestamp": at, "message": ["role": "assistant", "content": blocks]]
    }

    let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()

    @Test func claudePromptsRepliesAndSkippedLines() {
        let chat = log([
            claudeUser("Fix the build"),
            claudeUser("<system-reminder>injected</system-reminder>", uuid: "u2"),
            ["type": "user", "uuid": "u3", "isMeta": true, "message": ["role": "user", "content": "meta"]],
            ["type": "assistant", "uuid": "s1", "isSidechain": true, "message": ["role": "assistant", "content": [["type": "text", "text": "side"]]]],
            claudeAssistant([["type": "thinking", "thinking": " "], ["type": "text", "text": "Done **now**."]]),
        ])
        #expect(chat.entries.map(\.kind) == [.prompt(text: "Fix the build", images: []), .reply("Done **now**.")])
        #expect(chat.prompts == ["Fix the build"])
        #expect(chat.entries.first?.at == ISO8601DateFormatter().date(from: "2026-10-16T10:00:00Z"))
    }

    @Test func claudeImagesInPromptsAndToolResults() {
        let chat = log([
            claudeUser([["type": "text", "text": "Look [Image #1]"],
                        ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png]]]),
            claudeAssistant([["type": "tool_use", "id": "t1", "name": "mcp__chrome__screenshot", "input": [:]]]),
            claudeUser([["type": "tool_result", "tool_use_id": "t1",
                         "content": [["type": "text", "text": "shot"],
                                     ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png]]]]],
                       uuid: "u2", at: "2026-10-16T10:00:09Z"),
        ])
        guard case .prompt(let text, let images) = chat.entries[0].kind else { Issue.record("no prompt"); return }
        #expect(text == "Look [Image #1]")
        #expect(images.first?.data == Data([0x89, 0x50, 0x4E, 0x47]))
        guard case .tool(let tool) = chat.entries[1].kind else { Issue.record("no tool"); return }
        #expect(tool.result?.output == "shot")
        #expect(tool.result?.images.count == 1)
        #expect(tool.duration == 4)
        #expect(chat.entries.count == 2)
    }

    @Test func claudeToolDetails() {
        let chat = log([claudeAssistant([
            ["type": "tool_use", "id": "b", "name": "Bash", "input": ["command": "swift test", "description": "Run tests"]],
            ["type": "tool_use", "id": "e", "name": "Edit", "input": ["file_path": "/x/A.swift", "old_string": "a", "new_string": "b"]],
            ["type": "tool_use", "id": "m", "name": "MultiEdit",
             "input": ["file_path": "/x/B.swift", "edits": [["old_string": "1", "new_string": "2"], ["old_string": "3", "new_string": "4"]]]],
            ["type": "tool_use", "id": "w", "name": "Write", "input": ["file_path": "/x/C.md", "content": "# Hi"]],
            ["type": "tool_use", "id": "r", "name": "Read", "input": ["file_path": "/x/D.swift"]],
            ["type": "tool_use", "id": "q", "name": "AskUserQuestion",
             "input": ["questions": [["question": "Which?", "header": "Pick", "options": [["label": "A"], ["label": "B"]]]]]],
            ["type": "tool_use", "id": "g", "name": "Agent", "input": ["description": "Review", "prompt": "Check it"]],
            ["type": "tool_use", "id": "o", "name": "WebFetch", "input": ["url": "https://x.dev", "prompt": "sum"]],
        ])])
        let details = chat.entries.compactMap { entry -> ToolDetail? in
            if case .tool(let tool) = entry.kind { return tool.detail }
            return nil
        }
        #expect(details == [
            .command("swift test"),
            .edit(path: "/x/A.swift", changes: [ChatEditChange(old: "a", new: "b")]),
            .edit(path: "/x/B.swift", changes: [ChatEditChange(old: "1", new: "2"), ChatEditChange(old: "3", new: "4")]),
            .write(path: "/x/C.md", content: "# Hi"),
            .read(path: "/x/D.swift"),
            .questions([ChatQuestion(question: "Which?", options: ["A", "B"], header: "Pick")]),
            .agent(description: "Review", prompt: "Check it"),
            .fields([ChatField(name: "prompt", value: "sum"), ChatField(name: "url", value: "https://x.dev")]),
        ])
        if case .tool(let first) = chat.entries[0].kind { #expect(first.title == "Run tests") }
    }

    @Test func aResultInALaterReadCompletesItsCall() {
        var chat = ChatLog()
        chat.append(ChatReader.read(lines([claudeAssistant([["type": "tool_use", "id": "t", "name": "Bash", "input": ["command": "sleep 60"]]])]),
                                    format: .claude).events)
        chat.append(ChatReader.read(lines([claudeUser([["type": "tool_result", "tool_use_id": "t", "content": "boom", "is_error": true]],
                                                      uuid: "u9")]), format: .claude).events)
        guard case .tool(let tool) = chat.entries.last?.kind else { Issue.record("no tool"); return }
        #expect(tool.result?.output == "boom")
        #expect(tool.result?.failed == true)
    }

    @Test func loadingEarlierPrependsAndCompletesOrphans() {
        var chat = ChatLog()
        chat.append(ChatReader.read(lines([claudeUser([["type": "tool_result", "tool_use_id": "t", "content": "late"]], uuid: "u9"),
                                           claudeAssistant([["type": "text", "text": "after"]], uuid: "a9")]), format: .claude).events)
        #expect(chat.entries.map(\.kind) == [.reply("after")])
        chat.prepend(ChatReader.read(lines([claudeUser("first"),
                                            claudeAssistant([["type": "tool_use", "id": "t", "name": "Bash", "input": ["command": "ls"]]])]),
                                     format: .claude).events)
        #expect(chat.entries.count == 3)
        guard case .tool(let tool) = chat.entries[1].kind else { Issue.record("no tool"); return }
        #expect(tool.result?.output == "late")
    }

    @Test func codexMessagesCallsOutputsAndPatches() {
        let line = { (payload: [String: Any]) -> [String: Any] in
            ["type": "response_item", "timestamp": "2026-10-16T10:00:00Z", "payload": payload]
        }
        let chat = log([
            line(["type": "message", "role": "developer", "content": [["type": "input_text", "text": "rules"]]]),
            line(["type": "message", "role": "user", "id": "m1",
                  "content": [["type": "input_text", "text": "Ship it"], ["type": "input_image", "image_url": "data:image/png;base64,\(png)"]]]),
            line(["type": "reasoning", "id": "r1", "summary": []]),
            line(["type": "function_call", "name": "exec_command", "call_id": "c1", "arguments": "{\"cmd\":\"pwd\"}"]),
            line(["type": "function_call_output", "call_id": "c1", "output": "Process exited with code 1\n/tmp"]),
            line(["type": "custom_tool_call", "name": "exec", "call_id": "c2",
                  "input": "text(await tools.exec_command({cmd:\"rg -n \\\"x\\\" src\"}))"]),
            line(["type": "custom_tool_call", "name": "apply_patch", "call_id": "c3", "input": "*** Begin Patch\n+new\n*** End Patch"]),
            line(["type": "custom_tool_call_output", "call_id": "c2",
                  "output": [["type": "input_text", "text": "hit"], ["type": "input_image", "image_url": "data:image/png;base64,\(png)"]]]),
            line(["type": "message", "role": "assistant", "id": "m2", "content": [["type": "output_text", "text": "Shipped."]]]),
        ], format: .codex)
        #expect(chat.entries.count == 5)
        guard case .prompt(let text, let images) = chat.entries[0].kind else { Issue.record("no prompt"); return }
        #expect(text == "Ship it")
        #expect(images.count == 1)
        let tools = chat.entries.compactMap { entry -> ChatTool? in
            if case .tool(let tool) = entry.kind { return tool }
            return nil
        }
        #expect(tools.map(\.detail) == [.command("pwd"), .command("rg -n \"x\" src"), .patch("*** Begin Patch\n+new\n*** End Patch")])
        #expect(tools[0].result?.failed == true)
        #expect(tools[1].result?.output == "hit")
        #expect(tools[1].result?.images.count == 1)
        #expect(chat.entries.last?.kind == .reply("Shipped."))
    }

    @Test func longOutputIsCut() {
        let big = String(repeating: "x", count: ChatReader.outputLimit + 10)
        let chat = log([claudeAssistant([["type": "tool_use", "id": "t", "name": "Bash", "input": ["command": "yes"]]]),
                        claudeUser([["type": "tool_result", "tool_use_id": "t", "content": big]], uuid: "u2")])
        guard case .tool(let tool) = chat.entries[0].kind else { Issue.record("no tool"); return }
        #expect(tool.result?.truncated == true)
        #expect(tool.result?.output.count == ChatReader.outputLimit)
    }
}

struct ChatTranscriptReviewFixTests {
    func lines(_ objects: [[String: Any]]) -> Data {
        var data = Data()
        for object in objects { data.append(try! JSONSerialization.data(withJSONObject: object)); data.append(0x0A) }
        return data
    }

    @Test func duplicateIdsInOneReadAppearOnce() {
        let line: [String: Any] = ["type": "user", "uuid": "same", "message": ["role": "user", "content": "hi"]]
        var log = ChatLog()
        log.append(ChatReader.read(lines([line, line]), format: .claude).events)
        #expect(log.entries.count == 1)
    }

    @Test func interruptionNoticesAreNotPrompts() {
        let line: [String: Any] = ["type": "user", "uuid": "u", "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]]]
        var log = ChatLog()
        log.append(ChatReader.read(lines([line]), format: .claude).events)
        #expect(log.entries.isEmpty)
    }
}

struct PastedAndCommandPromptTests {
    @Test func pastedContentIsUnwrapped() {
        #expect(ChatReader.humanText("<pasted_content id=\"be79\">\nok now going back\n</pasted_content id=\"be79\">") == "ok now going back")
        #expect(ChatReader.humanText("look at this:\n<pasted_content id=\"a1\">\nerror line\n</pasted_content id=\"a1\">\nthanks")
                == "look at this:\nerror line\nthanks")
    }

    @Test func commandBlocksAreStrippedKeepingTheTypedText() {
        let text = "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args></command-args>\n"
            + "<local-command-stdout>Set model to Opus</local-command-stdout>\nnow fix the bug"
        #expect(ChatReader.humanText(text) == "now fix the bug")
        #expect(ChatReader.humanText("<command-name>/clear</command-name>\n<local-command-stdout></local-command-stdout>") == nil)
    }

    @Test func injectedContextIsStillDropped() {
        #expect(ChatReader.humanText("<system-reminder>be careful</system-reminder>") == nil)
        #expect(ChatReader.humanText("<task-notification>done</task-notification>") == nil)
        #expect(TranscriptReader.humanTextForTesting("<pasted_content id=\"x\">\nhello\n</pasted_content id=\"x\">") == "hello")
    }
}

struct MessagesFromOtherAgentsTests {
    let crossSession = "Another Claude session sent a message:\n<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-name=\"vibeswitcher-d5\" from-mode=\"prompting\">\nImage paste works now.\n</cross-session-message>"
    let handBack = "<agent-message from=\"adb98e7da9c83f502\">\n[Subagent hand-back] report text\n</agent-message>"

    @Test func theyAreNotTheUsersPrompts() {
        var data = Data()
        for (uuid, text) in [("a", crossSession), ("b", handBack), ("c", "my own words")] {
            let line: [String: Any] = ["type": "user", "uuid": uuid, "message": ["role": "user", "content": text]]
            data.append(try! JSONSerialization.data(withJSONObject: line)); data.append(0x0A)
        }
        var log = ChatLog()
        log.append(ChatReader.read(data, format: .claude).events)
        #expect(log.entries.map(\.kind) == [.steered(text: "Image paste works now.", fromLead: true),
                                            .steered(text: "[Subagent hand-back] report text", fromLead: true),
                                            .prompt(text: "my own words", images: [])])
        #expect(log.prompts == ["my own words"])
    }

    @Test func hooksAndThePhoneDontTakeThemForPrompts() {
        #expect(SessionNaming.isSystemPrompt(crossSession))
        #expect(SessionNaming.isSystemPrompt(handBack))
        #expect(SessionNaming.isSystemPrompt("fix the build") == false)
        #expect(TranscriptReader.humanTextForTesting(crossSession) == nil)
        #expect(TranscriptReader.humanTextForTesting(handBack) == nil)
    }
}

/// What's typed while Claude works is taken at its next step and written as a `queued_command` attachment, not a
/// user line (2.1.30x): the chat shows it as your prompt.
struct QueuedPromptTests {
    func read(_ lines: [String]) -> ChatLog {
        var log = ChatLog()
        log.append(ChatReader.read(Data((lines.joined(separator: "\n") + "\n").utf8), format: .claude).events)
        return log
    }

    @Test func aQueuedMessageIsAPrompt() {
        let log = read([
            #"{"type":"attachment","uuid":"q1","timestamp":"2026-10-19T08:00:00.000Z","isSidechain":false,"attachment":{"type":"queued_command","prompt":"also update the docs","source_uuid":"s1","commandMode":"prompt","origin":{"kind":"human"}}}"#,
            // A task notification queued the same way isn't yours.
            #"{"type":"attachment","uuid":"q2","timestamp":"2026-10-19T08:00:01.000Z","attachment":{"type":"queued_command","prompt":"<task-notification>\n<task-id>b7</task-id>\n</task-notification>","commandMode":"task-notification"}}"#,
            // A user line written for the same message is the same entry.
            #"{"type":"user","uuid":"s1","timestamp":"2026-10-19T08:00:02.000Z","message":{"role":"user","content":"also update the docs"}}"#,
        ])
        #expect(log.entries.map(\.kind) == [.prompt(text: "also update the docs", images: [])])
        #expect(log.entries.first?.id == "s1")
        #expect(SentMatch.prompts(log.entries).map(\.text) == ["also update the docs"])
    }
}

/// A `!` command typed in the composer, as Claude Code 2.1.302 records it once it has run (2026-10-24: the chat
/// left it "Not in the conversation yet" though Claude Code had run it and moved it to the background).
struct ShellCommandTests {
    let caveat = "<local-command-caveat>The command below was run directly in Claude Code, not sent to you as a request, and its output goes straight to the user. It's recorded here as context for later messages.</local-command-caveat>"

    func log(_ command: String, stdout: String) -> ChatLog {
        let objects: [[String: Any]] = [
            ["type": "user", "uuid": "c", "isMeta": true, "timestamp": "2026-10-24T09:53:05.979Z", "message": ["role": "user", "content": caveat]],
            ["type": "user", "uuid": "b", "timestamp": "2026-10-24T09:51:05.741Z",
             "message": ["role": "user", "content": "<bash-input>\(command)</bash-input>"]],
            ["type": "user", "uuid": "o", "timestamp": "2026-10-24T09:53:05.979Z",
             "message": ["role": "user", "content": "<bash-stdout>\(stdout)</bash-stdout><bash-stderr></bash-stderr>"]],
        ]
        var data = Data()
        for object in objects {
            data.append(try! JSONSerialization.data(withJSONObject: object))
            data.append(0x0A)
        }
        var log = ChatLog()
        log.append(ChatReader.read(data, format: .claude).events)
        return log
    }

    @Test func itShowsAsTheCommandTypedAndNothingElse() {
        let log = log("cd /Users/x/dev/p\nscripts/build-app.sh --install",
                      stdout: "Command did not complete within its 120s timeout and was moved to the background (ID: b1).")
        #expect(log.entries.count == 1)
        #expect(log.prompts == ["!cd /Users/x/dev/p\nscripts/build-app.sh --install"])
        // Stamped when it was sent, though written two minutes later.
        #expect(log.entries.first?.at == stamp("2026-10-24T09:51:05.741Z"))
        // An older Claude Code kept the space typed after `!`.
        #expect(self.log(" git stash", stdout: "Saved").prompts == ["!git stash"])
        #expect(ChatReader.humanText("<bash-stdout>x</bash-stdout><bash-stderr></bash-stderr>") == nil)
        #expect(ChatReader.humanText("<bash-input></bash-input>") == nil)
    }

    @Test func theComposersMessageMatchesIt() {
        let sentAt = stamp("2026-10-24T09:51:05.500Z")!
        let multi = PendingMessage(text: "!cd /Users/x/dev/p\nscripts/build-app.sh --install", afterPrompts: 0, expectsSoon: true, sentAt: sentAt)
        let prompts = SentMatch.prompts(log("cd /Users/x/dev/p\nscripts/build-app.sh --install", stdout: "moved to the background").entries)
        #expect(PendingMessage.remaining([multi], prompts: prompts).isEmpty)
        #expect(PendingMessage.remaining([PendingMessage(text: "! git stash", afterPrompts: 0)], prompts: ["!git stash"]).isEmpty)
        // Not the same as the words without the `!`.
        #expect(PendingMessage.remaining([PendingMessage(text: "git stash", afterPrompts: 0)], prompts: ["!git stash"]).count == 1)
    }

    @Test func itIsNotLateWhileItCanStillBeRunning() {
        let sentAt = Date(timeIntervalSince1970: 1_000_000)
        let shell = PendingMessage(text: "!scripts/build-app.sh", afterPrompts: 0, expectsSoon: true, sentAt: sentAt)
        // Recorded once it has run, or at Claude Code's 120 s Bash timeout.
        #expect(!shell.late(at: sentAt.addingTimeInterval(125)))
        #expect(shell.late(at: sentAt.addingTimeInterval(140)))
        let text = PendingMessage(text: "fix it", afterPrompts: 0, expectsSoon: true, sentAt: sentAt)
        #expect(text.late(at: sentAt.addingTimeInterval(16)))
    }
}

/// A transcript's timestamp.
private func stamp(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
}
