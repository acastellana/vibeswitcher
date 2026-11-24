import Foundation
import VibeCore

/// A chat's items as the live wire carries them (the live plan's B4, the live wire contract's §6): `ChatTimeline.items`
/// of a transcript, each `ChatItem` of the cases `prompt`, `reply`, `tools` and `team` one wire item. `newMarker` is the
/// client's view state; `question` and `updates` are placed by stage 5's Team slice: neither is written. `allDone` is
/// the lead's board's all-done card, which `ChatStore` places in the lead's chat (2026-11-21).
///
/// Every text an agent, a tool or a lead wrote (marked † in the contract) is data: the page shows it as text nodes, and
/// renders a reply's markdown to nodes itself. An image is its type and its size, never its bytes (LW-D11: what an agent
/// produced is served from a separate origin, which stage 5 builds).
public enum ChatValue {
    /// `item` as the wire's, or nil for a case the wire doesn't carry. No URL's credentials reach a page in it
    /// (`PushText.scrub` on every string: a remote's `https://user:token@…` that a tool's reply, a command or the lead's
    /// push_remote quotes, a token in a URL's query); nothing else is rewritten.
    public static func value(_ item: ChatItem) -> NodeWire.Value? {
        unscrubbed(item).map(scrubbed)
    }

    /// `value` with every string scrubbed of URL credentials and of pairing codes (`PairingMask`: a `!vibeswitcher web`
    /// in a transcript never gives a page the address).
    static func scrubbed(_ value: NodeWire.Value) -> NodeWire.Value {
        switch value {
        case .string(let text): return .string(PairingMask.mask(PushText.scrub(text)))
        case .array(let values): return .array(values.map(scrubbed))
        case .object(let fields): return .object(fields.mapValues(scrubbed))
        default: return value
        }
    }

    private static func unscrubbed(_ item: ChatItem) -> NodeWire.Value? {
        switch item {
        case .prompt(let entry): return prompt(entry)
        case .reply(let entry):
            guard case .reply(let text) = entry.kind else { return nil }
            return .object(head(entry.id, "reply", entry.at).merging(["text": .string(text)]) { $1 })
        case .tools(let id, let tools):
            return .object(head(id, "tools", tools.first?.at).merging([
                "summary": .string(ChatTimeline.summary(tools)), "tools": .array(tools.map(tool)),
            ]) { $1 })
        case .team(let entry, let message): return team(entry, message)
        // Where the lead's board cleared (the app's `AllDoneCard`): placed in the lead's chat by `ChatStore`, from the
        // engine's marks (`LeadEngine.chatExtras`), never read from a transcript.
        case .allDone(let mark):
            return .object(head(item.id, "allDone", Date(timeIntervalSince1970: mark.at)).merging(BoardValue.allDoneFields(mark)) { $1 })
        case .newMarker, .question, .updates: return nil
        }
    }

    /// The wire's items for `items`, in order, each with its id; the cases the wire doesn't carry left out.
    public static func values(_ items: [ChatItem]) -> [(id: String, value: NodeWire.Value)] {
        items.compactMap { item in value(item).map { (item.id, $0) } }
    }

    private static func head(_ id: String, _ type: String, _ at: Date?) -> [String: NodeWire.Value] {
        ["id": .string(id), "type": .string(type), "at": at.map(NodeWire.Value.date) ?? .null]
    }

    private static func prompt(_ entry: ChatEntry) -> NodeWire.Value? {
        let fields: [String: NodeWire.Value]
        switch entry.kind {
        case .prompt(let text, let images):
            fields = ["text": .string(text), "steered": .bool(false), "fromLead": .bool(false), "images": .array(images.map(image))]
        case .steered(let text, let fromLead):
            fields = ["text": .string(text), "steered": .bool(true), "fromLead": .bool(fromLead), "images": .array([])]
        case .reply, .tool:
            return nil
        }
        return .object(head(entry.id, "prompt", entry.at).merging(fields) { $1 })
    }

    /// A message VibeSwitcher handed over (`TeamMessage`): the sender's words, the chat's title for it, who sent it and
    /// what it is, the task it's about, and which part of a long one it is.
    private static func team(_ entry: ChatEntry, _ message: TeamMessage) -> NodeWire.Value {
        let sender: [String: NodeWire.Value]
        switch message.sender {
        case .user: sender = ["kind": .string("user"), "name": .null, "task": .null]
        case .lead(let name): sender = ["kind": .string("lead"), "name": .string(name), "task": .null]
        case .vibeSwitcher(let about): sender = ["kind": .string("vibeSwitcher"), "name": .string(about), "task": .null]
        case .teammate(let member, let task): sender = ["kind": .string("teammate"), "name": .string(member), "task": .string(task)]
        }
        return .object(head(entry.id, "team", entry.at).merging([
            "text": .string(message.body), "title": .string(message.title), "sender": .object(sender),
            "message": .string(message.kind.rawValue), "task": message.task.map(NodeWire.Value.string) ?? .null,
            "part": message.part.map { NodeWire.Value.object(["index": .int($0.index), "count": .int($0.count)]) } ?? .null,
        ]) { $1 })
    }

    static func tool(_ tool: ChatTool) -> NodeWire.Value {
        .object(["id": .string(tool.id), "name": .string(tool.name), "title": .string(tool.title),
                 "at": tool.at.map(NodeWire.Value.date) ?? .null, "detail": detail(tool.detail),
                 "result": tool.result.map(result) ?? .null])
    }

    static func result(_ result: ChatResult) -> NodeWire.Value {
        .object(["output": .string(result.output), "truncated": .bool(result.truncated), "failed": .bool(result.failed),
                 "at": result.at.map(NodeWire.Value.date) ?? .null, "images": .array(result.images.map(image))])
    }

    /// An image as its id, its type and its size: no bytes (LW-D11).
    static func image(_ image: ChatImage) -> NodeWire.Value {
        .object(["id": .string(image.id), "mediaType": .string(image.mediaType), "bytes": .int(image.data.count)])
    }

    static func detail(_ detail: ToolDetail) -> NodeWire.Value {
        func typed(_ type: String, _ fields: [String: NodeWire.Value]) -> NodeWire.Value {
            .object(fields.merging(["type": .string(type)]) { $1 })
        }
        switch detail {
        case .thought(let text): return typed("thought", ["text": .string(text)])
        case .todos(let todos):
            return typed("todos", ["todos": .array(todos.map { todo in
                let status: String
                switch todo.status {
                case .pending: status = "pending"
                case .active: status = "active"
                case .done: status = "done"
                }
                return .object(["text": .string(todo.text), "status": .string(status)])
            })])
        case .plan(let text): return typed("plan", ["text": .string(text)])
        case .command(let command): return typed("command", ["command": .string(command)])
        case .edit(let path, let changes):
            return typed("edit", ["path": .string(path),
                                  "changes": .array(changes.map { .object(["old": .string($0.old), "new": .string($0.new)]) })])
        case .write(let path, let content): return typed("write", ["path": .string(path), "content": .string(content)])
        case .read(let path): return typed("read", ["path": .string(path)])
        case .patch(let text): return typed("patch", ["text": .string(text)])
        case .questions(let questions):
            return typed("questions", ["questions": .array(questions.map { question in
                var fields: [String: NodeWire.Value] = [
                    "question": .string(question.question), "options": .array(question.options.map(NodeWire.Value.string)),
                    "descriptions": .array(question.descriptions.map { $0.map(NodeWire.Value.string) ?? .null }),
                    "multiSelect": .bool(question.multiSelect),
                ]
                if let header = question.header { fields["header"] = .string(header) }
                return .object(fields)
            })])
        case .agent(let description, let prompt): return typed("agent", ["description": .string(description), "prompt": .string(prompt)])
        case .fields(let fields):
            return typed("fields", ["fields": .array(fields.map { .object(["name": .string($0.name), "value": .string($0.value)]) })])
        }
    }
}
