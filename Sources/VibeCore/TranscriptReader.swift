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

    /// Longest prompt or reply text sent to the phone (a pasted log shouldn't become a 1 MB bubble).
    public static let textLimit = 16 * 1024

    /// Only the lines that mention `id` as a JSON string (a tool call and its result), so "Show all" on
    /// a big transcript parses two lines instead of all of them.
    public static func lines(mentioning id: String, in data: Data) -> Data {
        let needle = Data("\"\(id)\"".utf8)
        var out = Data()
        var from = data.startIndex
        while from < data.endIndex, let found = data.range(of: needle, in: from..<data.endIndex) {
            let lineStart = data[data.startIndex..<found.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let lineEnd = data[found.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            out.append(data[lineStart..<lineEnd])
            out.append(0x0A)
            from = lineEnd
        }
        return out
    }

    /// The transcript file, if `path` really is a regular `.jsonl` file inside the agents' own folders
    /// (after resolving symlinks and `..`, the folders' own included), and which format it is.
    public static func checkedURL(_ path: String, home: String) -> (URL, Format)? {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.pathExtension == "jsonl",
              // Not a directory, FIFO or device: reading one of those could block the reading queue.
              (try? FileManager.default.attributesOfItem(atPath: resolved.path)[.type] as? FileAttributeType) == .typeRegular
        else { return nil }
        let homeURL = URL(fileURLWithPath: home).standardizedFileURL
        let roots: [(String, Format)] = [(".claude/projects", .claude), (".codex/sessions", .codex)]
        for (folder, format) in roots {
            // ~/.claude may itself be a link (dotfiles setups): compare against where it really is.
            let root = homeURL.appendingPathComponent(folder).resolvingSymlinksInPath().path
            if resolved.path.hasPrefix(root + "/") { return (resolved, format) }
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
            // For lines without an id: the same line gets the same id on every read.
            let lineID = stableID(line)
            let parsed = format == .claude ? claude(object, lineID: lineID, outputLimit: outputLimit)
                                           : codex(object, lineID: lineID, outputLimit: outputLimit)
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

    private static func claude(_ line: [String: Any], lineID: String, outputLimit: Int) -> [TranscriptEntry] {
        if line["isSidechain"] as? Bool == true || line["isMeta"] as? Bool == true { return [] }
        let type = line["type"] as? String
        guard type == "user" || type == "assistant", let message = line["message"] as? [String: Any] else { return [] }
        let at = time(line["timestamp"])
        let uuid = line["uuid"] as? String ?? lineID
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
                    entries.append(TranscriptEntry(kind: .reply, id: "\(uuid).\(index)", text: bounded(text, limit: textLimit).0, at: at))
                }
            case ("assistant", "tool_use"):
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any] ?? [:]
                entries.append(TranscriptEntry(kind: .tool, id: block["id"] as? String ?? "\(uuid).\(index)",
                                               text: ToolActivity.describe(toolName: name, input: input), tool: name, at: at))
            case ("user", "tool_result"):
                let (output, truncated) = bounded(resultText(block["content"]), limit: outputLimit)
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

    private static func codex(_ line: [String: Any], lineID: String, outputLimit: Int) -> [TranscriptEntry] {
        guard line["type"] as? String == "response_item", let payload = line["payload"] as? [String: Any] else { return [] }
        let at = time(line["timestamp"])
        let id = payload["id"] as? String ?? payload["call_id"] as? String ?? lineID
        switch payload["type"] as? String {
        case "message":
            let parts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            let text = parts.joined(separator: "\n")
            switch payload["role"] as? String {
            case "user": return humanText(text).map { [TranscriptEntry(kind: .prompt, id: id, text: $0, at: at)] } ?? []
            case "assistant":
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
                return [TranscriptEntry(kind: .reply, id: id, text: bounded(text, limit: textLimit).0, at: at)]
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
            let (output, truncated) = bounded(resultText(payload["output"]), limit: outputLimit)
            return [TranscriptEntry(kind: .toolResult, id: payload["call_id"] as? String ?? id, text: "",
                                    output: output, outputTruncated: truncated, at: at)]
        default:
            return []
        }
    }

    // MARK: Helpers

    /// Typed text only. Injected context starts with a tag whose name has a `-` or `_`
    /// (`<task-notification>`, `<environment_context>`, `<command-name>`, `<system-reminder>`); pasted
    /// HTML (`<div>`, `<!doctype html>`) is something the user typed.
    private static func humanText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isInjected(trimmed) else { return nil }
        return bounded(trimmed, limit: textLimit).0
    }

    private static func isInjected(_ text: String) -> Bool {
        guard text.hasPrefix("<") else { return false }
        let name = text.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let next = text.dropFirst(1 + name.count).first
        return (name.contains("-") || name.contains("_")) && (next == ">" || next == " ")
    }

    /// FNV-1a of the line: a short id that's the same for the same bytes.
    private static func stableID(_ line: Data.SubSequence) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in line { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "line-" + String(hash, radix: 16)
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

    /// Masked and at most `limit` bytes. Masking happens before the final cut (a secret on the cut can't
    /// leak half-matched), but only on a little more than will be kept, so a 10 MB output stays cheap.
    private static func bounded(_ text: String, limit: Int) -> (String, Bool) {
        let rawLimit = limit + 1024
        let cutRaw = text.utf8.count > rawLimit
        let masked = Redaction.secrets(in: cutRaw ? prefix(text, bytes: rawLimit) : text)
        guard cutRaw || masked.utf8.count > limit else { return (masked, false) }
        return (prefix(masked, bytes: limit) + "\n…", true)
    }

    private static func prefix(_ text: String, bytes: Int) -> String {
        var cut = text.utf8.prefix(bytes)
        while String(cut) == nil { cut = cut.dropLast() }   // don't split a character
        return String(cut)!
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

/// Where a conversation read starts: right after the phone's cursor when that cursor belongs to this
/// same file and isn't too far behind; otherwise a fresh tail (after /clear or /resume the session has
/// another transcript, and a phone back from hours away shouldn't pull megabytes).
public enum TranscriptWindow {
    public struct Plan: Equatable, Sendable {
        public var start: Int
        /// A new tail: the phone starts the timeline over, and a partial first line is skipped.
        public var fresh: Bool

        public init(start: Int, fresh: Bool) {
            self.start = start
            self.fresh = fresh
        }
    }

    public static func plan(fileSize: Int, after: Int?, sameFile: Bool, tailBytes: Int) -> Plan {
        if let after, sameFile, after >= 0, after <= fileSize, fileSize - after <= tailBytes {
            return Plan(start: after, fresh: false)
        }
        // One byte early: if that byte ends the previous line, skipping "the partial first line" skips
        // just that newline instead of a whole complete line.
        return Plan(start: max(0, fileSize - tailBytes - 1), fresh: true)
    }
}
