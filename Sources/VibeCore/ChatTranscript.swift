import Foundation

/// An image in the conversation: one you pasted, or one a tool returned (a browser screenshot).
public struct ChatImage: Equatable, Sendable, Identifiable {
    public var id: String
    public var mediaType: String
    public var data: Data

    /// Identity, not bytes: comparing megabytes of image data on every view update would be wasteful.
    public static func == (a: ChatImage, b: ChatImage) -> Bool { a.id == b.id }
}

public struct ChatEditChange: Equatable, Sendable {
    public var old: String
    public var new: String
    public init(old: String, new: String) {
        self.old = old
        self.new = new
    }
}

public struct ChatQuestion: Equatable, Sendable {
    public var question: String
    public var options: [String]
    public init(question: String, options: [String]) {
        self.question = question
        self.options = options
    }
}

public struct ChatField: Equatable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct ChatTodo: Equatable, Sendable {
    public enum Status: Sendable { case pending, active, done }
    public var text: String
    public var status: Status
    public init(text: String, status: Status) {
        self.text = text
        self.status = status
    }

    init(text: String, statusName: String) {
        self.text = text
        switch statusName {
        case "completed", "done": status = .done
        case "in_progress", "in-progress", "active": status = .active
        default: status = .pending
        }
    }
}

/// Model and token counts, as of the latest reply.
public struct ChatUsage: Equatable, Sendable {
    public var model: String?
    /// Tokens the last request sent (what fills the context).
    public var contextTokens: Int?
    /// The model's context size, when the transcript says (Codex does).
    public var contextWindow: Int?
    /// Codex: share of the rate limit used.
    public var rateLimitPercent: Double?
    /// Output tokens of one reply (Claude; counted once per message id) …
    var outputTokens = 0
    var messageID: String?
    /// … or the conversation's running total (Codex).
    var outputTotal: Int?
}

/// What a tool call did, in the shape the chat shows it.
public enum ToolDetail: Equatable, Sendable {
    case thought(String)
    case todos([ChatTodo])
    case plan(String)
    case command(String)
    case edit(path: String, changes: [ChatEditChange])
    case write(path: String, content: String)
    case read(path: String)
    case patch(String)
    case questions([ChatQuestion])
    case agent(description: String, prompt: String)
    case fields([ChatField])
}

public struct ChatResult: Equatable, Sendable {
    public var output: String
    public var truncated: Bool
    public var failed: Bool
    public var at: Date?
    public var images: [ChatImage]
}

public struct ChatTool: Equatable, Sendable {
    public var id: String
    public var name: String
    /// One line: "Run tests", "Edit App.swift".
    public var title: String
    public var detail: ToolDetail
    public var at: Date?
    public var result: ChatResult?

    public var duration: TimeInterval? {
        guard let start = at, let end = result?.at else { return nil }
        return max(0, end.timeIntervalSince(start))
    }
}

public struct ChatEntry: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case prompt(text: String, images: [ChatImage])
        /// A message steered into a working agent (from you, or from the project lead).
        case steered(text: String, fromLead: Bool)
        case reply(String)
        case tool(ChatTool)
    }

    public var id: String
    public var at: Date?
    public var kind: Kind
}

public enum ChatEvent: Sendable {
    case entry(ChatEntry)
    case usage(ChatUsage)
    /// A tool's result, for a call in this read or an earlier one.
    case result(toolID: String, ChatResult)
}

/// The conversation so far: entries in order, tool calls completed by their results whenever those arrive.
public struct ChatLog: Equatable, Sendable {
    public private(set) var entries: [ChatEntry] = []
    private var toolIndex: [String: Int] = [:]
    /// Results whose call hasn't been read yet (it's in an earlier part of the file).
    private var orphans: [String: ChatResult] = [:]
    /// The latest model and context figures.
    public private(set) var usage: ChatUsage?
    /// Output tokens over the conversation (as far as it's loaded, for Claude).
    public private(set) var outputTokens = 0
    private var countedMessages: Set<String> = []

    public init() {}

    /// The latest to-do list or plan steps.
    public var todos: [ChatTodo]? {
        for entry in entries.reversed() {
            if case .tool(let tool) = entry.kind, case .todos(let todos) = tool.detail { return todos }
        }
        return nil
    }

    private mutating func record(_ new: ChatUsage) {
        var merged = usage ?? ChatUsage()
        if let model = new.model { merged.model = model }
        if let tokens = new.contextTokens { merged.contextTokens = tokens }
        if let window = new.contextWindow { merged.contextWindow = window }
        if let percent = new.rateLimitPercent { merged.rateLimitPercent = percent }
        usage = merged
        if let total = new.outputTotal {
            outputTokens = total
        } else if new.outputTokens > 0, let id = new.messageID, countedMessages.insert(id).inserted {
            outputTokens += new.outputTokens
        }
    }

    /// Your prompts, oldest first (for the composer's history).
    public var prompts: [String] {
        entries.compactMap { if case .prompt(let text, _) = $0.kind { return text } else { return nil } }
    }

    public mutating func append(_ events: [ChatEvent]) {
        var added: [ChatEntry] = []
        var results: [(String, ChatResult)] = []
        for event in events {
            switch event {
            case .entry(let entry): added.append(entry)
            case .result(let id, let result): results.append((id, result))
            case .usage(let usage): record(usage)
            }
        }
        var known = Set(entries.map(\.id))
        entries += added.filter { known.insert($0.id).inserted }
        reindex()
        results.forEach { complete($0.0, $0.1) }
    }

    /// Entries from earlier in the file.
    public mutating func prepend(_ events: [ChatEvent]) {
        var added: [ChatEntry] = []
        var results: [(String, ChatResult)] = []
        let latest = usage
        for event in events {
            switch event {
            case .entry(let entry): added.append(entry)
            case .result(let id, let result): results.append((id, result))
            // Earlier replies add to the token count but don't replace the latest figures.
            case .usage(let usage): record(usage)
            }
        }
        if let latest { usage = latest }
        var known = Set(entries.map(\.id))
        entries = added.filter { known.insert($0.id).inserted } + entries
        reindex()
        results.forEach { complete($0.0, $0.1) }
    }

    private mutating func reindex() {
        toolIndex = [:]
        for (index, entry) in entries.enumerated() {
            if case .tool(let tool) = entry.kind { toolIndex[tool.id] = index }
        }
        for (id, result) in orphans where toolIndex[id] != nil {
            orphans[id] = nil
            complete(id, result)
        }
    }

    private mutating func complete(_ id: String, _ result: ChatResult) {
        guard let index = toolIndex[id], case .tool(var tool) = entries[index].kind else {
            orphans[id] = result
            return
        }
        tool.result = result
        entries[index].kind = .tool(tool)
    }
}

/// Reads Claude Code and Codex transcripts into chat events. Unlike the phone's reader it keeps tool inputs
/// (commands, edits, questions) and images, and masks nothing: this is your own screen.
public enum ChatReader {
    public static let outputLimit = 16 * 1024
    static let contentLimit = 64 * 1024
    static let imageLimit = 8 * 1024 * 1024

    /// Complete lines of `data` (a partial last line is left for the next read) and how many bytes they took.
    public static func read(_ data: Data, format: TranscriptReader.Format) -> (events: [ChatEvent], consumed: Int) {
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], 0) }
        var events: [ChatEvent] = []
        for line in data[data.startIndex..<lastNewline].split(separator: 0x0A) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let lineID = stableID(line)
            events += format == .claude ? claude(object, lineID: lineID) : codex(object, lineID: lineID)
        }
        return (events, lastNewline - data.startIndex + 1)
    }

    // MARK: Claude Code

    static func claude(_ line: [String: Any], lineID: String) -> [ChatEvent] {
        if line["isSidechain"] as? Bool == true || line["isMeta"] as? Bool == true { return [] }
        let type = line["type"] as? String
        if type == "attachment", let attachment = line["attachment"] as? [String: Any] {
            let contents = (attachment["content"] as? [String]) ?? (attachment["content"] as? String).map { [$0] } ?? []
            let at = date(line["timestamp"])
            let uuid = line["uuid"] as? String ?? lineID
            return contents.flatMap(SteerReply.messages(inContext:)).enumerated().map { index, message in
                .entry(ChatEntry(id: "\(uuid).\(index)", at: at, kind: .steered(text: message.text, fromLead: message.fromLead)))
            }
        }
        guard type == "user" || type == "assistant", let message = line["message"] as? [String: Any] else { return [] }
        let at = date(line["timestamp"])
        let uuid = line["uuid"] as? String ?? lineID
        var usageEvents: [ChatEvent] = []
        if type == "assistant", let usage = message["usage"] as? [String: Any] {
            let context = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].compactMap { usage[$0] as? Int }.reduce(0, +)
            usageEvents.append(.usage(ChatUsage(model: message["model"] as? String, contextTokens: context > 0 ? context : nil,
                                                outputTokens: usage["output_tokens"] as? Int ?? 0,
                                                messageID: message["id"] as? String ?? uuid)))
        }
        if let text = message["content"] as? String {
            guard type == "user", let prompt = humanText(text) else { return [] }
            return [.entry(ChatEntry(id: uuid, at: at, kind: .prompt(text: prompt, images: [])))]
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return usageEvents }
        var events: [ChatEvent] = usageEvents
        var promptText: [String] = []
        var promptImages: [ChatImage] = []
        for (index, block) in blocks.enumerated() {
            switch (type, block["type"] as? String) {
            case ("user", "text"):
                if let text = (block["text"] as? String).flatMap(humanText) { promptText.append(text) }
            case ("user", "image"):
                if let image = claudeImage(block, id: "\(uuid).\(index)") { promptImages.append(image) }
            case ("assistant", "text"):
                if let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    events.append(.entry(ChatEntry(id: "\(uuid).\(index)", at: at, kind: .reply(text))))
                }
            case ("assistant", "thinking"):
                if let text = block["thinking"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    events.append(.entry(thought(text, id: "\(uuid).\(index)", at: at)))
                }
            case ("assistant", "tool_use"):
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any] ?? [:]
                let id = block["id"] as? String ?? "\(uuid).\(index)"
                let tool = ChatTool(id: id, name: name, title: ToolActivity.describe(toolName: name, input: input),
                                    detail: claudeDetail(name, input), at: at, result: nil)
                events.append(.entry(ChatEntry(id: id, at: at, kind: .tool(tool))))
            case ("user", "tool_result"):
                var texts: [String] = []
                var images: [ChatImage] = []
                if let text = block["content"] as? String {
                    texts.append(text)
                } else if let parts = block["content"] as? [[String: Any]] {
                    for (partIndex, part) in parts.enumerated() {
                        if part["type"] as? String == "text", let text = part["text"] as? String { texts.append(text) }
                        if part["type"] as? String == "image", let image = claudeImage(part, id: "\(uuid).\(index).\(partIndex)") {
                            images.append(image)
                        }
                    }
                }
                events.append(.result(toolID: block["tool_use_id"] as? String ?? "",
                                      result(texts.joined(separator: "\n"), failed: block["is_error"] as? Bool == true, at: at, images: images)))
            default:
                break
            }
        }
        if !promptText.isEmpty || !promptImages.isEmpty {
            events.insert(.entry(ChatEntry(id: uuid, at: at, kind: .prompt(text: promptText.joined(separator: "\n"), images: promptImages))),
                          at: usageEvents.count)
        }
        return events
    }

    static func claudeDetail(_ name: String, _ input: [String: Any]) -> ToolDetail {
        func text(_ key: String) -> String? { input[key] as? String }
        switch name {
        case "Bash":
            if let command = text("command") { return .command(command) }
        case "Edit":
            if let path = text("file_path") {
                return .edit(path: path, changes: [ChatEditChange(old: clip(text("old_string") ?? ""), new: clip(text("new_string") ?? ""))])
            }
        case "MultiEdit":
            if let path = text("file_path"), let edits = input["edits"] as? [[String: Any]] {
                return .edit(path: path, changes: edits.map {
                    ChatEditChange(old: clip($0["old_string"] as? String ?? ""), new: clip($0["new_string"] as? String ?? ""))
                })
            }
        case "Write":
            if let path = text("file_path") { return .write(path: path, content: clip(text("content") ?? "")) }
        case "Read":
            if let path = text("file_path") { return .read(path: path) }
        case "AskUserQuestion":
            if let questions = input["questions"] as? [[String: Any]] {
                return .questions(questions.map { question in
                    ChatQuestion(question: question["question"] as? String ?? "",
                                 options: (question["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String })
                })
            }
        case "Task", "Agent":
            return .agent(description: text("description") ?? "", prompt: clip(text("prompt") ?? ""))
        case "TodoWrite":
            if let todos = input["todos"] as? [[String: Any]] {
                return .todos(todos.map { ChatTodo(text: $0["content"] as? String ?? "", statusName: $0["status"] as? String ?? "") })
            }
        case "ExitPlanMode":
            if let plan = text("plan") { return .plan(clip(plan)) }
        default:
            break
        }
        return fields(input)
    }

    static func claudeImage(_ block: [String: Any], id: String) -> ChatImage? {
        guard let source = block["source"] as? [String: Any], source["type"] as? String == "base64",
              let encoded = source["data"] as? String, encoded.count <= imageLimit * 4 / 3 + 4,
              let data = Data(base64Encoded: encoded) else { return nil }
        return ChatImage(id: id, mediaType: source["media_type"] as? String ?? "image/png", data: data)
    }

    // MARK: Codex

    static func codex(_ line: [String: Any], lineID: String) -> [ChatEvent] {
        if line["type"] as? String == "turn_context", let model = (line["payload"] as? [String: Any])?["model"] as? String {
            return [.usage(ChatUsage(model: model))]
        }
        if line["type"] as? String == "event_msg", let payload = line["payload"] as? [String: Any], payload["type"] as? String == "token_count",
           let info = payload["info"] as? [String: Any] {
            let last = info["last_token_usage"] as? [String: Any]
            let total = info["total_token_usage"] as? [String: Any]
            let limits = (payload["rate_limits"] as? [String: Any])?["primary"] as? [String: Any]
            return [.usage(ChatUsage(contextTokens: last?["input_tokens"] as? Int, contextWindow: info["model_context_window"] as? Int,
                                     rateLimitPercent: limits?["used_percent"] as? Double, outputTotal: total?["output_tokens"] as? Int))]
        }
        guard line["type"] as? String == "response_item", let payload = line["payload"] as? [String: Any] else { return [] }
        let at = date(line["timestamp"])
        let id = payload["id"] as? String ?? payload["call_id"] as? String ?? lineID
        switch payload["type"] as? String {
        case "message":
            let parts = payload["content"] as? [[String: Any]] ?? []
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            switch payload["role"] as? String {
            case "user":
                let images = parts.enumerated().compactMap { index, part in
                    part["type"] as? String == "input_image" ? dataURLImage(part["image_url"], id: "\(id).\(index)") : nil
                }
                let prompt = humanText(text)
                guard prompt != nil || !images.isEmpty else { return [] }
                return [.entry(ChatEntry(id: id, at: at, kind: .prompt(text: prompt ?? "", images: images)))]
            case "assistant":
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
                return [.entry(ChatEntry(id: id, at: at, kind: .reply(text)))]
            default:
                return []
            }
        case "reasoning":
            let text = (payload["summary"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return [.entry(thought(text, id: id, at: at))]
        case "function_call", "custom_tool_call", "local_shell_call":
            let name = payload["name"] as? String ?? "shell"
            let callID = payload["call_id"] as? String ?? id
            var input: [String: Any] = [:]
            var detail: ToolDetail
            if let arguments = payload["arguments"] as? String,
               let parsed = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] {
                input = parsed
                let command = parsed["cmd"] ?? parsed["command"]
                if name == "update_plan", let steps = parsed["plan"] as? [[String: Any]] {
                    detail = .todos(steps.map { ChatTodo(text: $0["step"] as? String ?? "", statusName: $0["status"] as? String ?? "") })
                } else if let command = command as? String { detail = .command(command) }
                else if let argv = command as? [String] { detail = .command(argv.joined(separator: " ")) }
                else { detail = fields(parsed) }
            } else if let raw = payload["input"] as? String {
                if name == "apply_patch" || raw.hasPrefix("*** Begin Patch") {
                    detail = .patch(clip(raw))
                    input = ["patch": raw]
                } else {
                    let command = execCommand(raw) ?? raw
                    detail = .command(clip(command))
                    input = ["command": command]
                }
            } else {
                detail = .fields([])
            }
            let titleName: String
            if case .command = detail { titleName = "shell" } else { titleName = name }
            let tool = ChatTool(id: callID, name: name, title: ToolActivity.describe(toolName: titleName, input: input),
                                detail: detail, at: at, result: nil)
            return [.entry(ChatEntry(id: callID, at: at, kind: .tool(tool)))]
        case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
            let callID = payload["call_id"] as? String ?? id
            var texts: [String] = []
            var images: [ChatImage] = []
            var failed = false
            if let output = payload["output"] as? String {
                // Older Codex wraps it: {"output": "…", "metadata": {"exit_code": 1}}.
                if let wrapped = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
                   let inner = wrapped["output"] as? String {
                    texts.append(inner)
                    failed = ((wrapped["metadata"] as? [String: Any])?["exit_code"] as? Int).map { $0 != 0 } ?? false
                } else {
                    texts.append(output)
                }
            } else if let parts = payload["output"] as? [[String: Any]] {
                for (index, part) in parts.enumerated() {
                    if let text = part["text"] as? String { texts.append(text) }
                    if part["type"] as? String == "input_image", let image = dataURLImage(part["image_url"], id: "\(callID).\(index)") {
                        images.append(image)
                    }
                }
            }
            let text = texts.joined(separator: "\n")
            if let code = exitCode(text) { failed = failed || code != 0 }
            return [.result(toolID: callID, result(text, failed: failed, at: at, images: images))]
        default:
            return []
        }
    }

    /// The command inside Codex's `exec` tool script: `tools.exec_command({cmd:"…"})`.
    static func execCommand(_ script: String) -> String? {
        guard let start = script.range(of: "cmd:") else { return nil }
        var rest = script[start.upperBound...].drop { $0 == " " }
        guard rest.first == "\"" else { return nil }
        rest = rest.dropFirst()
        var out = ""
        var escaped = false
        for character in rest {
            if escaped {
                out.append(character == "n" ? "\n" : character == "t" ? "\t" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return out
            } else {
                out.append(character)
            }
        }
        return nil
    }

    static func exitCode(_ text: String) -> Int? {
        guard let range = text.range(of: "Process exited with code ") else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber || $0 == "-" })
    }

    static func dataURLImage(_ value: Any?, id: String) -> ChatImage? {
        guard let url = value as? String, url.hasPrefix("data:"), let comma = url.firstIndex(of: ","),
              url.count <= imageLimit * 4 / 3 + 100 else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64"), let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
        return ChatImage(id: id, mediaType: String(header.dropLast(";base64".count)), data: data)
    }

    // MARK: Helpers

    /// Thinking shows as a step of the tool run around it, already "done".
    static func thought(_ text: String, id: String, at: Date?) -> ChatEntry {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let title = first.trimmingCharacters(in: CharacterSet(charactersIn: "*# ").union(.whitespaces))
        let tool = ChatTool(id: id, name: "Thinking", title: String(title.prefix(120)), detail: .thought(clip(text)), at: at,
                            result: ChatResult(output: "", truncated: false, failed: false, at: at, images: []))
        return ChatEntry(id: id, at: at, kind: .tool(tool))
    }

    static func result(_ text: String, failed: Bool, at: Date?, images: [ChatImage]) -> ChatResult {
        let cut = text.count > outputLimit
        return ChatResult(output: cut ? String(text.prefix(outputLimit)) : text, truncated: cut, failed: failed, at: at, images: images)
    }

    static func fields(_ input: [String: Any]) -> ToolDetail {
        .fields(input.keys.sorted().map { key in
            let value = input[key]
            let text: String
            if let string = value as? String { text = string }
            else if let data = try? JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed, .sortedKeys]) {
                text = String(decoding: data, as: UTF8.self)
            } else { text = "\(value ?? "")" }
            return ChatField(name: key, value: String(text.prefix(600)))
        })
    }

    static func clip(_ text: String) -> String { text.count > contentLimit ? String(text.prefix(contentLimit)) : text }

    /// Typed (or pasted) text only; injected context and Claude's own notes are left out.
    static func humanText(_ text: String) -> String? {
        guard let typed = TypedText.clean(text) else { return nil }
        // Claude's own notes in the user's turn ("[Request interrupted by user]", "… for tool use]").
        if typed.hasPrefix("[Request interrupted by user") { return nil }
        return typed
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func stableID(_ line: Data.SubSequence) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in line { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}
