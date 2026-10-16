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

/// What a tool call did, in the shape the chat shows it.
public enum ToolDetail: Equatable, Sendable {
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
        case reply(String)
        case tool(ChatTool)
    }

    public var id: String
    public var at: Date?
    public var kind: Kind
}

public enum ChatEvent: Sendable {
    case entry(ChatEntry)
    /// A tool's result, for a call in this read or an earlier one.
    case result(toolID: String, ChatResult)
}

/// The conversation so far: entries in order, tool calls completed by their results whenever those arrive.
public struct ChatLog: Equatable, Sendable {
    public private(set) var entries: [ChatEntry] = []
    private var toolIndex: [String: Int] = [:]
    /// Results whose call hasn't been read yet (it's in an earlier part of the file).
    private var orphans: [String: ChatResult] = [:]

    public init() {}

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
            }
        }
        let known = Set(entries.map(\.id))
        entries += added.filter { !known.contains($0.id) }
        reindex()
        results.forEach { complete($0.0, $0.1) }
    }

    /// Entries from earlier in the file.
    public mutating func prepend(_ events: [ChatEvent]) {
        var added: [ChatEntry] = []
        var results: [(String, ChatResult)] = []
        for event in events {
            switch event {
            case .entry(let entry): added.append(entry)
            case .result(let id, let result): results.append((id, result))
            }
        }
        let known = Set(entries.map(\.id))
        entries = added.filter { !known.contains($0.id) } + entries
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
        guard type == "user" || type == "assistant", let message = line["message"] as? [String: Any] else { return [] }
        let at = date(line["timestamp"])
        let uuid = line["uuid"] as? String ?? lineID
        if let text = message["content"] as? String {
            guard type == "user", let prompt = humanText(text) else { return [] }
            return [.entry(ChatEntry(id: uuid, at: at, kind: .prompt(text: prompt, images: [])))]
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var events: [ChatEvent] = []
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
            events.insert(.entry(ChatEntry(id: uuid, at: at, kind: .prompt(text: promptText.joined(separator: "\n"), images: promptImages))), at: 0)
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
        case "function_call", "custom_tool_call", "local_shell_call":
            let name = payload["name"] as? String ?? "shell"
            let callID = payload["call_id"] as? String ?? id
            var input: [String: Any] = [:]
            var detail: ToolDetail
            if let arguments = payload["arguments"] as? String,
               let parsed = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] {
                input = parsed
                let command = parsed["cmd"] ?? parsed["command"]
                if let command = command as? String { detail = .command(command) }
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

    /// Typed text only: injected context starts with a tag whose name has a `-` or `_`.
    static func humanText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("<"), let close = trimmed.firstIndex(of: ">") {
            let tag = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            if tag.contains("-") || tag.contains("_") { return nil }
        }
        return trimmed
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
