import Foundation

/// One row of the phone's Conversation tab.
public struct TranscriptEntry: Equatable, Sendable {
    public enum Kind: String, Sendable { case prompt, reply, tool, toolResult }

    public var kind: Kind
    /// The tool call id for `tool`/`toolResult` (a later result updates the row with that id).
    public var id: String
    /// Prompt or reply text; for a tool, its one-line description.
    public var text: String
    public var tool: String?
    public var output: String?
    public var outputTruncated = false
    public var failed = false
    public var at: Double?
    public var duration: Double?

    public var json: [String: Any] {
        var object: [String: Any] = ["kind": kind.rawValue, "id": id, "text": text]
        if let tool { object["tool"] = tool }
        if let output { object["output"] = output }
        if outputTruncated { object["outputTruncated"] = true }
        if failed { object["failed"] = true }
        if let at { object["at"] = at }
        if let duration { object["duration"] = duration }
        return object
    }
}

/// Reads Claude Code (`~/.claude/projects/…/<session>.jsonl`) and Codex (`~/.codex/sessions/…/rollout-*.jsonl`)
/// transcripts into timeline entries. Thinking, meta lines, sidechains and system lines are skipped.
/// Everything is masked.
public enum TranscriptReader {
    public enum Format: Sendable { case claude, codex }

    /// The transcript file, if `path` really is a `.jsonl` file inside the agents' own folders (after
    /// resolving symlinks and `..`), and which format it is.
    public static func checkedURL(_ path: String, home: String) -> (URL, Format)? {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let homeURL = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.pathExtension == "jsonl" else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        let roots: [(String, Format)] = [(".claude/projects/", .claude), (".codex/sessions/", .codex)]
        for (folder, format) in roots where resolved.path.hasPrefix(homeURL.path + "/" + folder) {
            return (resolved, format)
        }
        return nil
    }

    /// For a read that starts in the middle of a file: the offset of the first complete line.
    public static func tailStart(_ data: Data) -> Int {
        guard let newline = data.firstIndex(of: 0x0A) else { return data.count }
        return newline - data.startIndex + 1
    }

    /// Entries from the complete lines in `data` (which starts at a line boundary), and how many bytes
    /// those lines took: a trailing partial line is left for the next read.
    public static func read(_ data: Data, format: Format, outputLimit: Int = 4096) -> (entries: [TranscriptEntry], consumed: Int) {
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], 0) }
        let consumed = lastNewline - data.startIndex + 1
        var entries: [TranscriptEntry] = []
        var toolIndex: [String: Int] = [:]
        for line in data[data.startIndex..<lastNewline].split(separator: 0x0A) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let parsed = format == .claude ? claude(object, outputLimit: outputLimit) : codex(object, outputLimit: outputLimit)
            for entry in parsed {
                // A result for a call in this same read completes that row.
                if entry.kind == .toolResult, let index = toolIndex[entry.id] {
                    entries[index].output = entry.output
                    entries[index].outputTruncated = entry.outputTruncated
                    entries[index].failed = entry.failed
                    if let start = entries[index].at, let end = entry.at { entries[index].duration = max(0, end - start) }
                    continue
                }
                if entry.kind == .tool { toolIndex[entry.id] = entries.count }
                entries.append(entry)
            }
        }
        return (entries, consumed)
    }

    // MARK: Claude Code

    private static func claude(_ line: [String: Any], outputLimit: Int) -> [TranscriptEntry] {
        if line["isSidechain"] as? Bool == true || line["isMeta"] as? Bool == true { return [] }
        let type = line["type"] as? String
        guard type == "user" || type == "assistant", let message = line["message"] as? [String: Any] else { return [] }
        let at = time(line["timestamp"])
        let uuid = line["uuid"] as? String ?? UUID().uuidString
        if let text = message["content"] as? String {
            guard type == "user", let prompt = humanText(text) else { return [] }
            return [TranscriptEntry(kind: .prompt, id: uuid, text: prompt, at: at)]
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var entries: [TranscriptEntry] = []
        for (index, block) in blocks.enumerated() {
            switch (type, block["type"] as? String) {
            case ("user", "text"):
                if let text = (block["text"] as? String).flatMap(humanText) {
                    entries.append(TranscriptEntry(kind: .prompt, id: "\(uuid).\(index)", text: text, at: at))
                }
            case ("assistant", "text"):
                if let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    entries.append(TranscriptEntry(kind: .reply, id: "\(uuid).\(index)", text: Redaction.secrets(in: text), at: at))
                }
            case ("assistant", "tool_use"):
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any] ?? [:]
                entries.append(TranscriptEntry(kind: .tool, id: block["id"] as? String ?? "\(uuid).\(index)",
                                               text: ToolActivity.describe(toolName: name, input: input), tool: name, at: at))
            case ("user", "tool_result"):
                let (output, truncated) = clipped(resultText(block["content"]), limit: outputLimit)
                entries.append(TranscriptEntry(kind: .toolResult, id: block["tool_use_id"] as? String ?? "", text: "",
                                               output: output, outputTruncated: truncated,
                                               failed: block["is_error"] as? Bool == true, at: at))
            default:
                break
            }
        }
        return entries
    }

    // MARK: Codex

    private static func codex(_ line: [String: Any], outputLimit: Int) -> [TranscriptEntry] {
        guard line["type"] as? String == "response_item", let payload = line["payload"] as? [String: Any] else { return [] }
        let at = time(line["timestamp"])
        let id = payload["id"] as? String ?? payload["call_id"] as? String ?? UUID().uuidString
        switch payload["type"] as? String {
        case "message":
            let parts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            let text = parts.joined(separator: "\n")
            switch payload["role"] as? String {
            case "user": return humanText(text).map { [TranscriptEntry(kind: .prompt, id: id, text: $0, at: at)] } ?? []
            case "assistant":
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
                return [TranscriptEntry(kind: .reply, id: id, text: Redaction.secrets(in: text), at: at)]
            default: return []
            }
        case "function_call", "custom_tool_call", "local_shell_call":
            let name = payload["name"] as? String ?? "shell"
            var input: [String: Any] = [:]
            if let arguments = payload["arguments"] as? String,
               let parsed = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] {
                input = parsed
            } else if let raw = payload["input"] as? String {
                input = ["command": raw]
            }
            let described = ToolActivity.describe(toolName: input["command"] != nil ? "shell" : name, input: input)
            return [TranscriptEntry(kind: .tool, id: payload["call_id"] as? String ?? id, text: described, tool: name, at: at)]
        case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
            let (output, truncated) = clipped(resultText(payload["output"]), limit: outputLimit)
            return [TranscriptEntry(kind: .toolResult, id: payload["call_id"] as? String ?? id, text: "",
                                    output: output, outputTruncated: truncated, at: at)]
        default:
            return []
        }
    }

    // MARK: Helpers

    /// Typed text only: injected context (`<task-notification>`, `<environment_context>`, command
    /// caveats) starts with a tag.
    private static func humanText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return Redaction.secrets(in: trimmed)
    }

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.map { block -> String in
                if let text = block["text"] as? String { return text }
                return "[\(block["type"] as? String ?? "attachment")]"
            }.joined(separator: "\n")
        }
        if let object = content as? [String: Any], let output = object["output"] as? String { return output }
        return ""
    }

    private static func clipped(_ text: String, limit: Int) -> (String, Bool) {
        let masked = Redaction.secrets(in: text)
        guard masked.utf8.count > limit else { return (masked, false) }
        var cut = masked.utf8.prefix(limit)
        while String(cut) == nil { cut = cut.dropLast() }   // don't split a character
        return (String(cut)! + "\n…", true)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func time(_ value: Any?) -> Double? {
        guard let text = value as? String else { return nil }
        return (isoFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text))?.timeIntervalSince1970
    }
}
