import Foundation
import Testing
@testable import VibeCore

/// The chat read from real Claude Code 2.1.302 / Opus 5.5 transcripts (see `ClaudeFixtures`).
struct ClaudeFixtureChatTests {
    func log(_ fixture: String) -> ChatLog {
        var log = ChatLog()
        log.append(ChatReader.read(Data((fixture + "\n").utf8), format: .claude).events)
        return log
    }

    func tools(_ log: ChatLog) -> [ChatTool] {
        log.entries.compactMap { entry -> ChatTool? in if case .tool(let tool) = entry.kind { return tool } else { return nil } }
    }

    /// TodoWrite is gone on 5.x models; with the task tools turned back on, the to-do strip follows TaskCreate/TaskUpdate.
    @Test func taskToolsMakeTheToDoList() {
        let chat = log(ClaudeFixtures.taskTools)
        #expect(chat.todos == [ChatTodo(text: "Write a.txt", status: .done), ChatTodo(text: "Write b.txt", status: .active),
                               ChatTodo(text: "Write c.txt", status: .pending)])
        let taskCalls = tools(chat).filter { $0.name.hasPrefix("Task") }
        #expect(taskCalls.count == 5)
        #expect(ChatTimeline.summary(taskCalls) == "Updated the to-dos")
    }

    @Test func taskListsFollowWhicheverCameLast() {
        let result = { (text: String) in ChatResult(output: text, truncated: false, failed: false, at: nil, images: []) }
        func tool(_ id: String, _ name: String, _ detail: ToolDetail, _ output: String? = nil) -> ChatEntry {
            ChatEntry(id: id, at: nil, kind: .tool(ChatTool(id: id, name: name, title: name, detail: detail, at: nil, result: output.map(result))))
        }
        func fields(_ pairs: [(String, String)]) -> ToolDetail { .fields(pairs.map { ChatField(name: $0.0, value: $0.1) }) }
        var chat = ChatLog()
        chat.append([.entry(tool("w", "TodoWrite", .todos([ChatTodo(text: "Old", status: .pending)])))])
        #expect(chat.todos?.map(\.text) == ["Old"])
        chat.append([
            // Ids come from the result; a call still running gets the next number.
            .entry(tool("c1", "TaskCreate", fields([("subject", "One")]), "Task #7 created successfully: One")),
            .entry(tool("c2", "TaskCreate", fields([("subject", "Two")]))),
            .entry(tool("c3", "TaskCreate", fields([("subject", "Three")]), "Task #9 created successfully: Three")),
            .entry(tool("u1", "TaskUpdate", fields([("taskId", "7"), ("status", "deleted")]), "Updated task #7 deleted")),
            .entry(tool("u2", "TaskUpdate", fields([("taskId", "9"), ("status", "in_progress"), ("subject", "Three, renamed")]), "Updated task #9")),
        ])
        #expect(chat.todos == [ChatTodo(text: "Two", status: .pending), ChatTodo(text: "Three, renamed", status: .active)])
        // A failed update changes nothing.
        chat.append([.entry(ChatEntry(id: "u3", at: nil, kind: .tool(ChatTool(id: "u3", name: "TaskUpdate", title: "", detail: fields([("taskId", "9"), ("status", "completed")]), at: nil,
                                                                               result: ChatResult(output: "Task not found", truncated: false, failed: true, at: nil, images: [])))))])
        #expect(chat.todos?.last?.status == .active)
    }

    /// Plan mode on 5.x writes the plan to ~/.claude/plans/<slug>.md: it shows as the plan, not as a written file.
    @Test func thePlanComesFromThePlanFile() throws {
        let chat = log(ClaudeFixtures.planFile)
        let plan = try #require(tools(chat).first { if case .plan = $0.detail { return true } else { return false } })
        guard case .plan(let text) = plan.detail else { return }
        #expect(text.hasPrefix("# Plan: add hello.txt"))
        #expect(text.contains("2. Check it by running `cat hello.txt`."))
        #expect(ChatTimeline.summary([plan]) == "Wrote a plan")
        #expect(chat.todos == nil)
        #expect(ChatReader.isPlanFile("/Users/me/.claude/plans/plan-x.md"))
        #expect(!ChatReader.isPlanFile("/Users/me/project/plans/plan-x.md"))
        #expect(!ChatReader.isPlanFile("/Users/me/.claude/plans/sub/notes.txt"))
    }

    /// Thinking shows as steps of the tool run around it: the empty signed block is left out, the summary that follows
    /// is a step titled by its first line, and a run of steps ends at the reply.
    @Test func thinkingBetweenToolCallsShowsAsSteps() throws {
        let chat = log(ClaudeFixtures.thinkingBetweenTools)
        let items = ChatTimeline.items(chat.entries, newAfter: nil)
        #expect(items.count == 2)
        guard case .tools(_, let run) = items[0], case .reply(let reply) = items[1] else {
            Issue.record("expected one tool run and a reply, got \(items)"); return
        }
        #expect(run.map(\.name) == ["Thinking", "AskUserQuestion", "Thinking", "AskUserQuestion"])
        #expect(run[0].title.hasPrefix("So the design is a cockpit view"))
        guard case .thought(let thought) = run[2].detail else { Issue.record("not a thought"); return }
        #expect(thought.hasPrefix("Sessions need to persist independently"))
        #expect(run[1].result != nil && run[3].result != nil)
        #expect(ChatTimeline.summary(run) == "Used 2 tools")
        guard case .reply(let text) = reply.kind else { return }
        #expect(text.hasPrefix("This next part might be easier if I show you"))
        #expect(chat.todos == nil)
    }
}
