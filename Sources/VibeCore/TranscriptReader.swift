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
    ///
    /// Codex compresses cold rollouts in place (`rollout-….jsonl` → `rollout-….jsonl.zst`, and back when one is
    /// resumed), so either name finds whichever exists. A compressed one is read through a decompressed copy in
    /// `~/.vibeswitcher/transcripts` (made once per version of the file): callers keep reading plain JSONL by offset.
    public static func checkedURL(_ path: String, home: String) -> (URL, Format)? {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var candidates = [resolved]
        if resolved.pathExtension == "jsonl" {
            candidates.append(resolved.appendingPathExtension("zst"))
        } else if isCompressed(resolved) {
            candidates.append(resolved.deletingPathExtension())
        }
        for candidate in candidates {
            if let found = checkedFile(candidate.resolvingSymlinksInPath(), home: home) { return found }
        }
        return nil
    }

    private static func isCompressed(_ url: URL) -> Bool {
        url.pathExtension == "zst" && url.deletingPathExtension().pathExtension == "jsonl"
    }

    private static func checkedFile(_ resolved: URL, home: String) -> (URL, Format)? {
        let compressed = isCompressed(resolved)
        guard resolved.pathExtension == "jsonl" || compressed,
              // Not a directory, FIFO or device: reading one of those could block the reading queue.
              (try? FileManager.default.attributesOfItem(atPath: resolved.path)[.type] as? FileAttributeType) == .typeRegular
        else { return nil }
        let homeURL = URL(fileURLWithPath: home).standardizedFileURL
        let roots: [(String, Format)] = compressed ? [(".codex/sessions", .codex)]
            : [(".claude/projects", .claude), (".codex/sessions", .codex), (decompressedFolder, .codex)]
        for (folder, format) in roots {
            // ~/.claude may itself be a link (dotfiles setups): compare against where it really is.
            let root = homeURL.appendingPathComponent(folder).resolvingSymlinksInPath().path
            guard resolved.path.hasPrefix(root + "/") else { continue }
            if !compressed { return (resolved, format) }
            return decompressedCopy(of: resolved, home: homeURL).map { ($0, format) }
        }
        return nil
    }

    /// Decompressed copies of compressed rollouts, private to you like the rollouts themselves.
    static let decompressedFolder = ".vibeswitcher/transcripts"
    /// Bigger compressed files aren't opened (a rollout is a few MB; this is a guard, not a budget).
    static let compressedLimit = 64 << 20
    static let decompressedLimit = 512 << 20

    /// `<path hash>-<version hash>.jsonl`: a new version of the file (size, modification time) gets a new copy (so a
    /// reader's cursor in the old one is "another file") and the old copy goes.
    private static func decompressedCopy(of source: URL, home: URL) -> URL? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= compressedLimit,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let folder = home.appendingPathComponent(decompressedFolder)
        let key = fnv(Data(source.path.utf8))
        let target = folder.appendingPathComponent("\(key)-\(fnv(Data("\(size)|\(modified.timeIntervalSince1970)".utf8))).jsonl")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        guard let compressed = try? Data(contentsOf: source),
              let plain = try? Zstd.decompress(compressed, limit: decompressedLimit) else { return nil }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try plain.write(to: target, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch { return nil }
        for old in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        where old.hasPrefix(key + "-") && old != target.lastPathComponent {
            try? fm.removeItem(at: folder.appendingPathComponent(old))
        }
        return target
    }

    private static func fnv(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    // MARK: Codex's async questions

    /// The question a Codex rollout's `request_user_input_async` left open: asked (the call), and not answered since
    /// (a message you typed). Nil when there is none or it was answered.
    ///
    /// No real rollout with this call has been seen yet (Codex 0.160/0.163 TUIs don't offer the tool): the shapes are
    /// Codex's own: a `response_item` `function_call` like every tool call in its rollouts, arguments
    /// `{"questions": [{"title", "options"}]}` (codex-app-server-protocol 0.163.0, `AsyncUserInputQuestion`), and an
    /// `item_completed` agent message carrying `questions` (`AgentMessageThreadItem.questions`).
    public static func openAsyncQuestion(in data: Data) -> String? {
        var open: String?
        for line in data.split(separator: 0x0A) {
            // Cheap filter first: most lines are tool output.
            guard line.range(of: Data("questions".utf8)) != nil || line.range(of: Data("\"user".utf8)) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            switch (object["type"] as? String, payload["type"] as? String) {
            case ("response_item", "function_call"?), ("response_item", "custom_tool_call"?):
                guard payload["name"] as? String == StatusRules.asyncQuestionTool else { continue }
                let arguments = (payload["arguments"] as? String).flatMap {
                    (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
                } ?? [:]
                open = HookState.question(toolName: StatusRules.asyncQuestionTool, input: arguments) ?? "Asked you something"
            case ("event_msg", "item_completed"?):
                guard let item = payload["item"] as? [String: Any],
                      let questions = item["questions"] as? [[String: Any]], !questions.isEmpty else { continue }
                open = HookState.question(toolName: StatusRules.asyncQuestionTool, input: ["questions": questions]) ?? open
            case ("response_item", "message"?):
                guard payload["role"] as? String == "user" else { continue }
                let text = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                if humanText(text) != nil { open = nil }
            case ("event_msg", "user_message"?):
                open = nil
            default:
                continue
            }
        }
        return open
    }

    /// `openAsyncQuestion` over the end of a live (uncompressed) rollout, for the hook at a Codex Stop.
    public static func openAsyncQuestion(atPath path: String, home: String, tailBytes: Int = 256 << 10) -> String? {
        guard let (url, format) = checkedURL(path, home: home), format == .codex, url.pathExtension == "jsonl",
              !url.path.contains("/" + decompressedFolder + "/"),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return nil }
        if start > 0 { data = data.subdata(in: (data.startIndex + tailStart(data))..<data.endIndex) }
        return openAsyncQuestion(in: data)
    }

    /// The line kinds the readers act on: Claude Code's conversation, Codex's rollout items.
    static let conversationKinds: Set<String> = ["user", "assistant", "attachment", "system", "response_item", "event_msg", "turn_context"]
    private static let typeFirst = Array(#"{"type":""#.utf8)

    /// Whether a transcript line is a kind no reader uses, told by its first bytes without parsing it: it starts
    /// `{"type":"<kind>"` with a kind not in `conversationKinds`. Claude Code 2.1.300+ records each API request's
    /// system prompt, tools and parameters (`api-request`, `-blob`, `-shape`), half or more of a transcript's bytes, and
    /// titles, modes and file history the same way. Lines with another first key are read (Claude's conversation
    /// lines start with "parentUuid", Codex's with "timestamp").
    public static func skippable(_ line: Data.SubSequence) -> Bool {
        guard line.count > typeFirst.count, line.starts(with: typeFirst) else { return false }
        let kindStart = line.startIndex + typeFirst.count
        guard let quote = line[kindStart..<min(line.endIndex, kindStart + 40)].firstIndex(of: 0x22) else { return false }
        return !conversationKinds.contains(String(decoding: line[kindStart..<quote], as: UTF8.self))
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
        for line in data[data.startIndex..<lastNewline].split(separator: 0x0A) where !skippable(line) {
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
                                               text: Redaction.secrets(in: ToolActivity.describe(toolName: name, input: input)),
                                               tool: Redaction.secrets(in: name), at: at))
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
            return [TranscriptEntry(kind: .tool, id: payload["call_id"] as? String ?? id, text: Redaction.secrets(in: described),
                                    tool: Redaction.secrets(in: name), at: at)]
        case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
            let (output, truncated) = bounded(resultText(payload["output"]), limit: outputLimit)
            return [TranscriptEntry(kind: .toolResult, id: payload["call_id"] as? String ?? id, text: "",
                                    output: output, outputTruncated: truncated, at: at)]
        default:
            return []
        }
    }

    // MARK: Helpers

    /// Typed or pasted text only (see `TypedText`).
    private static func humanText(_ text: String) -> String? {
        guard let typed = TypedText.clean(text) else { return nil }
        return bounded(typed, limit: textLimit).0
    }

    static func humanTextForTesting(_ text: String) -> String? { humanText(text) }


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

    private static func time(_ value: Any?) -> Double? {
        guard let text = value as? String else { return nil }
        return ChatReader.date(text)?.timeIntervalSince1970
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

    public struct Chunk: Sendable {
        public var entries: [TranscriptEntry]
        /// Where the phone's next read continues: just after the last complete line read.
        public var cursor: Int
        /// A line is still being written (ask again shortly).
        public var pending: Bool
        /// The timeline doesn't start at the beginning of the transcript.
        public var truncatedBefore: Bool
    }

    /// Entries from `data`, the file's bytes from `plan.start` to its end (`fileSize`). A fresh read that
    /// starts mid-file skips the partial first line.
    public static func chunk(_ data: Data, plan: Plan, fileSize: Int, format: TranscriptReader.Format) -> Chunk {
        var data = data
        var skipped = 0
        if plan.fresh, plan.start > 0 {
            skipped = TranscriptReader.tailStart(data)
            data = data.subdata(in: (data.startIndex + skipped)..<data.endIndex)
        }
        let result = TranscriptReader.read(data, format: format)
        let cursor = plan.start + skipped + result.consumed
        return Chunk(entries: result.entries, cursor: cursor, pending: cursor < fileSize,
                     truncatedBefore: plan.fresh && plan.start > 0)
    }
}

/// Where a Claude Code conversation stands, from the end of its transcript: what the hooks say goes stale between
/// events (a tool that runs for minutes fires nothing), but the agent writes every step here as it takes it.
public struct TranscriptTail: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Mid-turn, waiting on a tool call it made (or on the user, when the hooks say a prompt is on screen).
        case toolCall
        /// Mid-turn otherwise: a prompt or a tool's result came in, the model is on it.
        case thinking
        /// The turn is over; `apiError` when it ended on one ("API Error: …") rather than on the model's reply.
        case turnOver(apiError: String?)
    }

    /// Work it started in the background (a `run_in_background` shell, a background agent) whose completion
    /// notification hasn't come yet: when its turn is over, it's waiting on these.
    public struct Background: Equatable, Sendable {
        /// Claude Code's id for it (the shell's task id, the agent's id), which its notification names.
        public var id: String
        /// What it is: the call's description, or its command.
        public var what: String
        public var startedAt: Double?

        public init(id: String, what: String, startedAt: Double?) {
            self.id = id
            self.what = what
            self.startedAt = startedAt
        }

        /// "Final swift test and two load runs, started 14:17".
        public var text: String {
            guard let startedAt else { return what }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "\(what), started \(formatter.string(from: Date(timeIntervalSince1970: startedAt)))"
        }
    }

    public var state: State
    /// When the line that says so was written.
    public var at: Double?
    /// Its background work still running, oldest first (only what the read window shows started).
    public var background: [Background] = []
    /// Mid-turn, the last call of the turn with no result yet, in full (see `PendingPrompt`): when the session waits
    /// for input, what it waits for; `since` is when the call was written.
    public var pending: PendingPrompt?

    public var midTurn: Bool { if case .turnOver = state { return false } else { return true } }

    /// What it waits on between turns, in words: "Final swift test and two load runs, started 14:17", nil for nothing.
    public var waitingOn: String? {
        guard let first = background.first else { return nil }
        return background.count == 1 ? first.text : "\(first.text), and \(background.count - 1) more"
    }

    /// How much of the file's end is read: the last few steps, whatever their size (a tool's result can be big).
    public static let window = 256 * 1024

    /// The tail of a Claude Code transcript, or nil when it has no main-thread step yet.
    public static func read(url: URL) -> TranscriptTail? {
        noteRead()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(window) ? size - UInt64(window) : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() else { return nil }
        if start > 0 { data = data.subdata(in: (data.startIndex + TranscriptReader.tailStart(data))..<data.endIndex) }
        return read(data)
    }

    /// How many times a transcript's end was read (a tail or its progress, see `TranscriptProgress`), in this
    /// process, and how many of those on the main thread. The app reads none there: a team's transcripts are a few
    /// hundred KB each to parse, and reading them there froze the window (`--board-bench` checks).
    public static var reads: (all: Int, onMainThread: Int) {
        counter.lock()
        defer { counter.unlock() }
        return counts
    }

    private static let counter = NSLock()
    nonisolated(unsafe) private static var counts = (all: 0, onMainThread: 0)

    static func noteRead() {
        let main = Thread.isMainThread
        counter.lock()
        counts.all += 1
        if main { counts.onMainThread += 1 }
        counter.unlock()
    }

    /// From complete transcript lines (a partial last line is skipped).
    public static func read(_ data: Data) -> TranscriptTail? {
        var lines = data.split(separator: 0x0A)
        if data.last != 0x0A, !lines.isEmpty { lines.removeLast() }
        guard var tail = state(lines) else { return nil }
        tail.background = background(lines)
        if tail.midTurn { tail.pending = pending(lines) }
        return tail
    }

    /// The turn's last tool call with no result yet, back to where the turn started.
    private static func pending(_ lines: [Data.SubSequence]) -> PendingPrompt? {
        var answered = Set<String>()
        for line in lines.reversed() where !TranscriptReader.skippable(line) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
                  object["isCompactSummary"] as? Bool != true, let kind = step(object) else { continue }
            let blocks = ((object["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            switch (object["type"] as? String, kind) {
            case ("user", .state(.thinking)) where blocks.contains(where: { $0["type"] as? String == "tool_result" }):
                answered.formUnion(blocks.compactMap { $0["tool_use_id"] as? String })
            case ("assistant", .state):
                guard let call = blocks.last(where: { $0["type"] as? String == "tool_use" && !answered.contains($0["id"] as? String ?? "") }),
                      let name = call["name"] as? String else { continue }
                return PendingPrompt(text: PendingPrompt.text(toolName: name, input: call["input"] as? [String: Any] ?? [:]),
                                     since: ChatReader.date(object["timestamp"])?.timeIntervalSince1970)
            default:
                // A prompt, a reply, a turn's end: the turn starts after it.
                return nil
            }
        }
        return nil
    }

    private static func state(_ lines: [Data.SubSequence]) -> TranscriptTail? {
        var ended: Double?
        for line in lines.reversed() where !TranscriptReader.skippable(line) {
            // A compaction's summary is written as a prompt, but it starts no turn: Claude compacts idle sessions too.
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
                  object["isCompactSummary"] as? Bool != true else { continue }
            let at = ChatReader.date(object["timestamp"])?.timeIntervalSince1970
            switch step(object) {
            case nil: continue
            case .over?:
                // The turn's end is written after its last reply: that reply says whether an API error ended it.
                if ended == nil { ended = at ?? 0 }
            case .apiError(let text)?:
                return TranscriptTail(state: .turnOver(apiError: text), at: ended ?? at)
            case .reply?:
                return TranscriptTail(state: .turnOver(apiError: nil), at: ended ?? at)
            case .state(let state)? where ended == nil:
                return TranscriptTail(state: state, at: at)
            case .state?:
                return TranscriptTail(state: .turnOver(apiError: nil), at: ended)
            }
        }
        return ended.map { TranscriptTail(state: .turnOver(apiError: nil), at: $0) }
    }

    /// The background work started on the main thread and not yet told complete. A shell's call returns at once
    /// with `backgroundTaskId` (an agent's with `async_launched` and its `agentId`); when it ends, Claude Code writes
    /// a `<task-notification>` naming its id: queued (`queue-operation`), as an attachment mid-turn, or as the prompt
    /// of the turn it starts.
    private static func background(_ lines: [Data.SubSequence]) -> [Background] {
        // Only the lines that can say so are parsed.
        let marks = ["backgroundTaskId", "async_launched", "task-notification"].map { Data($0.utf8) }
        var started: [(id: String, call: String?, what: String?, at: Double?)] = []
        var done = Set<String>()
        for line in lines where marks.contains(where: { line.range(of: $0) != nil }) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  object["isSidechain"] as? Bool != true else { continue }
            for text in notifications(in: object) {
                for tag in ["task-id", "tool-use-id"] {
                    if let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) {
                        done.insert(String(text[open.upperBound..<close.lowerBound]))
                    }
                }
            }
            guard object["type"] as? String == "user", let result = object["toolUseResult"] as? [String: Any] else { continue }
            let id = result["backgroundTaskId"] as? String ?? (result["status"] as? String == "async_launched" ? result["agentId"] as? String : nil)
            guard let id else { continue }
            let call = ((object["message"] as? [String: Any])?["content"] as? [[String: Any]])?
                .first { $0["type"] as? String == "tool_result" }?["tool_use_id"] as? String
            started.append((id, call, result["description"] as? String, ChatReader.date(object["timestamp"])?.timeIntervalSince1970))
        }
        let open = started.filter { !done.contains($0.id) && !($0.call.map(done.contains) ?? false) }
        return open.map { Background(id: $0.id, what: $0.what ?? $0.call.flatMap { description(of: $0, in: lines) } ?? "a background task",
                                     startedAt: $0.at) }
    }

    /// The texts of `<task-notification>`s a line carries.
    private static func notifications(in object: [String: Any]) -> [String] {
        let texts: [String?]
        switch object["type"] as? String {
        case "queue-operation": texts = [object["content"] as? String]
        case "attachment": texts = [(object["attachment"] as? [String: Any])?["prompt"] as? String]
        case "user":
            let content = (object["message"] as? [String: Any])?["content"]
            texts = [content as? String] + ((content as? [[String: Any]]) ?? []).map { $0["text"] as? String }
        default: texts = []
        }
        return texts.compactMap { $0 }.filter { $0.hasPrefix("<task-notification>") }
    }

    /// The description of the tool call `id` (its command when it has none), from the call itself.
    private static func description(of id: String, in lines: [Data.SubSequence]) -> String? {
        let mark = Data(id.utf8)
        for line in lines.reversed() where line.range(of: mark) != nil {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], object["type"] as? String == "assistant",
                  let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]],
                  let call = blocks.first(where: { $0["id"] as? String == id }) else { continue }
            let input = call["input"] as? [String: Any] ?? [:]
            if let text = input["description"] as? String, !text.isEmpty { return text }
            if let command = input["command"] as? String { return String(command.prefix(80)) }
            return call["name"] as? String
        }
        return nil
    }

    enum Step { case over, apiError(String), reply, state(State) }

    static func step(_ line: [String: Any]) -> Step? {
        switch line["type"] as? String {
        case "system":
            // A turn's end; the rest (away summaries, compaction, notices) aren't steps of the conversation.
            return ["turn_duration", "stop_hook_summary"].contains(line["subtype"] as? String ?? "") ? .over : nil
        case "assistant":
            guard let message = line["message"] as? [String: Any] else { return nil }
            let blocks = message["content"] as? [[String: Any]] ?? []
            if line["isApiErrorMessage"] as? Bool == true {
                let text = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
                return .apiError(text.isEmpty ? "API Error" : String(text.prefix(300)))
            }
            if blocks.contains(where: { $0["type"] as? String == "tool_use" }) { return .state(.toolCall) }
            if message["stop_reason"] as? String == "end_turn", blocks.contains(where: { $0["type"] as? String == "text" }) { return .reply }
            return .state(.thinking)
        case "user":
            guard let message = line["message"] as? [String: Any] else { return nil }
            let texts: [String]
            if let text = message["content"] as? String {
                texts = [text]
            } else {
                let blocks = message["content"] as? [[String: Any]] ?? []
                if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return .state(.thinking) }
                texts = blocks.compactMap { $0["text"] as? String }
            }
            let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("[Request interrupted by user") { return .reply }
            // Local slash commands and their output start no turn.
            if text.isEmpty || text.hasPrefix("<local-command-") || text.hasPrefix("<command-name>") || text.hasPrefix("<command-message>") { return nil }
            return .state(.thinking)
        default:
            return nil
        }
    }
}

/// Finds a session's Claude Code transcript without its hooks: in Claude's folder for the session's working
/// directory (`~/.claude/projects/<slug>`). The file is named by Claude's own session id, which is not the window
/// session's, so it's picked by the name the session was started with (`--name`, written into the transcript) and
/// by time: written to since the session started.
public enum TranscriptLocator {
    public static func claude(cwd: String, name: String?, startedAt: Date, home: String = VibePaths.home) -> String? {
        let projects = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
        // Claude names the folder after the path it was started in, as it resolves it.
        let paths = [cwd, (cwd as NSString).standardizingPath, URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path]
        var seen = Set<String>()
        var candidates: [(url: URL, modified: Date)] = []
        for path in paths where seen.insert(RecentProjects.claudeSlug(for: path)).inserted {
            let folder = projects.appendingPathComponent(RecentProjects.claudeSlug(for: path))
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                // A session's transcript is written from its first moments on; older files are earlier sessions'.
                if modified >= startedAt.addingTimeInterval(-5) { candidates.append((file, modified)) }
            }
        }
        candidates.sort { $0.modified > $1.modified }
        if let name {
            let needles = ["\"agentName\":\"\(name)\"", "\"customTitle\":\"\(name)\""].map { Data($0.utf8) }
            return candidates.first { candidate in
                guard let ends = edges(of: candidate.url) else { return false }
                return needles.contains { ends.range(of: $0) != nil }
            }?.url.path
        }
        return candidates.first?.url.path
    }

    /// The first and last 64 KB of a file, where Claude writes the session's name.
    private static func edges(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let limit = 64 * 1024
        guard var data = try? handle.read(upToCount: limit), let size = try? handle.seekToEnd() else { return nil }
        if size > UInt64(2 * limit), (try? handle.seek(toOffset: size - UInt64(limit))) != nil, let end = try? handle.readToEnd() {
            data.append(end)
        } else if size > UInt64(limit), (try? handle.seek(toOffset: UInt64(limit))) != nil, let rest = try? handle.readToEnd() {
            data.append(rest)
        }
        return data
    }
}

/// A replaced lead's last turns, for the lead that replaces it: what the user told it, and what it answered.
public enum LastTurns {
    public static let prompts = 10
    public static let limit = 12_000
    /// How much of the end of a transcript is read.
    public static let tailBytes = 4 << 20

    /// One of the user's prompts and the replies that followed it (tool calls left out).
    public struct Turn: Equatable, Sendable {
        public var prompt: TranscriptEntry
        public var replies: [TranscriptEntry]
        public var answered: Bool { !replies.isEmpty }
    }

    /// The last `prompts` of the user's prompts with their replies, and any earlier prompt that got no reply. The
    /// lead's start prompt isn't the user's: it's left out.
    public static func turns(_ entries: [TranscriptEntry], prompts: Int = prompts) -> [Turn] {
        var turns: [Turn] = []
        for entry in entries {
            switch entry.kind {
            case .prompt:
                if entry.text.hasPrefix(LeadPrompts.startOpening) { continue }
                turns.append(Turn(prompt: entry, replies: []))
            case .reply:
                if !turns.isEmpty { turns[turns.count - 1].replies.append(entry) }
            case .tool, .toolResult:
                continue
            }
        }
        let recent = max(0, turns.count - prompts)
        return turns.enumerated().filter { $0.offset >= recent || !$0.element.answered }.map(\.element)
    }

    /// The turns as a file for the new lead, at most about `limit` characters: the oldest answered turns go first,
    /// then long texts are cut; an unanswered prompt always stays. Nil when the user said nothing.
    public static func text(_ turns: [Turn], tty: String, limit: Int = limit) -> String? {
        guard !turns.isEmpty else { return nil }
        let header = "# The replaced lead's last turns\n\nThe lead on \(tty) held this project's role before you; its last turns "
            + "with the user, oldest first (tool calls left out). It had no tools: what it said it would do didn't happen, and "
            + "nothing it was told reached the board unless you put it there.\n"
        func render(_ turn: Turn, cut: Int?) -> String {
            func bounded(_ text: String) -> String {
                guard let cut, text.count > cut else { return text }
                return String(text.prefix(cut)) + " …(cut)"
            }
            var out = "\n## The user\(turn.prompt.at.map { ", \(LeadBoard.clock($0))" } ?? "")\n\n\(bounded(turn.prompt.text))\n"
            if turn.replies.isEmpty {
                out += "\n(No reply: act on this.)\n"
            } else {
                out += "\n## The replaced lead answered\n\n" + bounded(turn.replies.map(\.text).joined(separator: "\n\n")) + "\n"
            }
            return out
        }
        var kept = turns
        var cut: Int?
        while true {
            let body = kept.map { render($0, cut: cut) }.joined()
            if header.count + body.count <= limit { return header + body }
            if let oldest = kept.firstIndex(where: \.answered), kept.count > 1 {
                kept.remove(at: oldest)
                continue
            }
            // What's left is still too long: each text shorter, down to a floor.
            let next = (cut ?? 4000) / 2
            guard next >= 250 else { return header + body }
            cut = next
        }
    }

    /// The last turns in a session's transcript (a Claude Code or Codex one, checked as `TranscriptReader.checkedURL`
    /// checks it), read from its end.
    public static func read(transcript path: String, tty: String, home: String = VibePaths.home, prompts: Int = prompts,
                            limit: Int = limit) -> String? {
        guard let (url, format) = TranscriptReader.checkedURL(path, home: home),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() else { return nil }
        if start > 0 { data = data.dropFirst(TranscriptReader.tailStart(data)) }
        if data.last != 0x0A { data.append(0x0A) }
        let entries = TranscriptReader.read(data, format: format).entries
        return text(turns(entries, prompts: prompts), tty: tty, limit: limit)
    }
}
