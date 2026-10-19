import Foundation

/// The inspector's Activity tab: what the chat doesn't say at a glance. Files the agent changed with their +/− line
/// counts, the commands it ran with exit code and duration, and each turn's tokens and cost, from a transcript tail.
///
/// Tool calls are the chat's own (`ChatReader`, line by line), so a row's icon and words are the chat's; what the chat
/// doesn't keep is read here from the same lines: Claude Code's `toolUseResult` patch and its per-message `usage`
/// (and `costUSD`, which older versions wrote), Codex's `token_count` events, exit codes and wall times, and the cwd
/// paths are shown relative to.
public struct ActivityFeed: Equatable, Sendable {
    public struct FileChange: Equatable, Sendable {
        public enum Action: Equatable, Sendable { case created, edited, written, deleted }
        public var id: String
        /// Relative to the session's folder when it's inside it.
        public var path: String
        public var action: Action
        public var added: Int
        public var removed: Int
        /// How many calls changed it in this turn.
        public var edits: Int
        /// The latest call that changed it.
        public var tool: ChatTool
    }

    public struct Command: Equatable, Sendable {
        public var id: String
        public var tool: ChatTool
        /// What the agent said it does ("Run the tests"), in plain text; nil when its title is just the command.
        public var title: String?
        /// The command's first line.
        public var command: String
        public var moreLines: Bool
        /// Nil when the transcript doesn't say (still running, sent to the background, timed out).
        public var exitCode: Int?
        /// What the agent reported (Codex's wall time), else from the call's and the result's timestamps.
        public var duration: TimeInterval?
        public var background: Bool
        public var running: Bool { tool.result == nil }
        public var failed: Bool { tool.result?.failed == true || (exitCode ?? 0) != 0 }
    }

    public struct Tokens: Equatable, Sendable {
        /// Everything the requests sent, cached included.
        public var input: Int
        public var cached: Int
        public var output: Int

        public init(input: Int, cached: Int, output: Int) {
            self.input = input
            self.cached = cached
            self.output = output
        }
    }

    public struct Turn: Equatable, Sendable {
        public var id: String
        /// When its prompt was sent.
        public var at: Date?
        /// It began before the part of the transcript that was read: its counts are only the part read.
        public var partial: Bool
        /// Nil when the transcript has no usage for it.
        public var tokens: Tokens?
        /// In US dollars; nil when the transcript doesn't carry it.
        public var cost: Double?
        public var files: Int
        public var commands: Int
    }

    public enum Row: Equatable, Sendable, Identifiable {
        case file(FileChange)
        case command(Command)
        case turn(Turn)

        public var id: String {
            switch self {
            case .file(let file): return "file|" + file.id
            case .command(let command): return "command|" + command.id
            case .turn(let turn): return "turn|" + turn.id
            }
        }
    }

    /// Oldest first; each turn's files and commands come before its summary.
    public var rows: [Row]

    public var isEmpty: Bool { rows.isEmpty }

    /// What an empty feed says.
    public static let emptyExplanation = "No files changed, commands run or token counts in this transcript yet."

    /// The feed from complete transcript lines in `data` (a partial last line is left out). `startsMidFile`: `data`
    /// starts somewhere inside the file, so its first, partial line is skipped and the turn before its first prompt is
    /// marked partial. At most `limit` rows, the newest.
    public static func read(_ data: Data, format: TranscriptReader.Format, startsMidFile: Bool, limit: Int = 80) -> ActivityFeed {
        var data = data
        if startsMidFile { data = data.subdata(in: (data.startIndex + TranscriptReader.tailStart(data))..<data.endIndex) }
        var builder = Builder(format: format, startsMidFile: startsMidFile)
        if let lastNewline = data.lastIndex(of: 0x0A) {
            for line in data[data.startIndex..<lastNewline].split(separator: 0x0A) where !TranscriptReader.skippable(line) {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                builder.add(object, lineID: ChatReader.stableID(line))
            }
        }
        return ActivityFeed(rows: Array(builder.rows().suffix(limit)))
    }

    /// Text without its markdown: emphasis, code spans and links as their words, no heading, quote or list marks.
    /// On one line.
    public static func plain(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var out = (try? AttributedString(markdown: line, options: options)).map { String($0.characters) } ?? line
        // What inline parsing leaves: a leading "# ", "> ", "- ", and stray emphasis or code marks.
        out = out.replacing(#/^\s*(#{1,6}|>|[-*+])\s+/#, with: "")
        out = out.replacing(#/\*\*|__|`/#, with: "")
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Building

    private struct TurnState {
        var id: String
        var at: Date?
        var toolIDs: [String] = []
        /// Claude: usage by message id, in the order first seen (a message's lines repeat its usage).
        var messages: [String] = []
        var usage: [String: (tokens: Tokens, cost: Double?)] = [:]
        /// Codex: the turn's sum of `last_token_usage`.
        var codexTokens: Tokens?
    }

    private struct Builder {
        let format: TranscriptReader.Format
        let startsMidFile: Bool
        var cwd: String?
        var turns: [TurnState] = [TurnState(id: "start")]
        var tools: [String: ChatTool] = [:]
        /// Claude's `toolUseResult` for an edit: the lines its patch added and removed, and whether it made the file.
        var patches: [String: (added: Int, removed: Int, created: Bool)] = [:]
        /// Exit codes and durations the agent reported, by call id.
        var reported: [String: (exit: Int?, duration: Double?)] = [:]
        var background: Set<String> = []
        var lastCodexTotal: [String: Int]?

        init(format: TranscriptReader.Format, startsMidFile: Bool) {
            self.format = format
            self.startsMidFile = startsMidFile
        }

        mutating func add(_ line: [String: Any], lineID: String) {
            let events = format == .claude ? ChatReader.claude(line, lineID: lineID) : ChatReader.codex(line, lineID: lineID)
            for event in events {
                switch event {
                case .entry(let entry):
                    switch entry.kind {
                    case .prompt: turns.append(TurnState(id: entry.id, at: entry.at))
                    case .tool(let tool) where tool.name != "Thinking":
                        guard tools[tool.id] == nil else { continue }
                        tools[tool.id] = tool
                        turns[turns.count - 1].toolIDs.append(tool.id)
                    default: break
                    }
                case .result(let id, let result):
                    // A result whose call is before the part read adds nothing.
                    tools[id]?.result = result
                case .usage:
                    break
                }
            }
            if format == .claude { claudeRecords(line, lineID: lineID) } else { codexRecords(line) }
        }

        private mutating func claudeRecords(_ line: [String: Any], lineID: String) {
            if line["isSidechain"] as? Bool == true { return }
            if let cwd = line["cwd"] as? String { self.cwd = cwd }
            guard let message = line["message"] as? [String: Any] else { return }
            if line["type"] as? String == "assistant", let usage = message["usage"] as? [String: Any] {
                func count(_ key: String) -> Int { usage[key] as? Int ?? 0 }
                let id = message["id"] as? String ?? line["uuid"] as? String ?? lineID
                let cached = count("cache_read_input_tokens")
                let tokens = Tokens(input: count("input_tokens") + count("cache_creation_input_tokens") + cached, cached: cached,
                                    output: count("output_tokens"))
                let index = turns.lastIndex { $0.usage[id] != nil } ?? turns.count - 1
                if turns[index].usage[id] == nil { turns[index].messages.append(id) }
                turns[index].usage[id] = (tokens, line["costUSD"] as? Double ?? turns[index].usage[id]?.cost)
            }
            guard line["type"] as? String == "user", let result = line["toolUseResult"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return }
            let ids = blocks.filter { $0["type"] as? String == "tool_result" }.compactMap { $0["tool_use_id"] as? String }
            guard ids.count == 1, let id = ids.first else { return }
            if result["backgroundTaskId"] != nil { background.insert(id) }
            if let hunks = result["structuredPatch"] as? [[String: Any]] {
                var added = 0, removed = 0
                for hunk in hunks {
                    for text in hunk["lines"] as? [String] ?? [] {
                        if text.hasPrefix("+") { added += 1 } else if text.hasPrefix("-") { removed += 1 }
                    }
                }
                let created = result["type"] as? String == "create"
                if created, hunks.isEmpty, let content = result["content"] as? String { added = Self.lineCount(content) }
                patches[id] = (added, removed, created)
            }
        }

        private mutating func codexRecords(_ line: [String: Any]) {
            guard let payload = line["payload"] as? [String: Any] else { return }
            switch (line["type"] as? String, payload["type"] as? String) {
            case ("turn_context", _):
                if let cwd = payload["cwd"] as? String { self.cwd = cwd }
            case ("event_msg", "token_count"?):
                guard let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] else { return }
                // The same count is written again when only the rate limits changed.
                let total = info["total_token_usage"] as? [String: Int]
                if let total, total == lastCodexTotal { return }
                lastCodexTotal = total
                let tokens = Tokens(input: last["input_tokens"] as? Int ?? 0, cached: last["cached_input_tokens"] as? Int ?? 0,
                                    output: last["output_tokens"] as? Int ?? 0)
                let sum = turns[turns.count - 1].codexTokens
                turns[turns.count - 1].codexTokens = Tokens(input: (sum?.input ?? 0) + tokens.input, cached: (sum?.cached ?? 0) + tokens.cached,
                                                            output: (sum?.output ?? 0) + tokens.output)
            case ("event_msg", "exec_command_end"?):
                guard let id = payload["call_id"] as? String else { return }
                var duration: Double?
                if let parts = payload["duration"] as? [String: Any] {
                    duration = Double(parts["secs"] as? Int ?? 0) + Double(parts["nanos"] as? Int ?? 0) / 1e9
                } else {
                    duration = payload["duration"] as? Double
                }
                report(id, exit: payload["exit_code"] as? Int, duration: duration)
            case ("response_item", "function_call_output"?), ("response_item", "custom_tool_call_output"?),
                 ("response_item", "local_shell_call_output"?):
                guard let id = payload["call_id"] as? String, let output = payload["output"] as? String else { return }
                // Older Codex: {"output": "…", "metadata": {"exit_code": 1, "duration_seconds": 0.4}}.
                if let wrapped = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
                   let metadata = wrapped["metadata"] as? [String: Any] {
                    report(id, exit: metadata["exit_code"] as? Int, duration: metadata["duration_seconds"] as? Double)
                } else {
                    let wall = output.firstMatch(of: #/Wall time: ([0-9.]+) seconds/#).flatMap { Double($0.1) }
                    report(id, exit: ChatReader.exitCode(output), duration: wall)
                }
            default:
                break
            }
        }

        /// `exec_command_end` and the call's output may each say some of it, in either order.
        private mutating func report(_ id: String, exit: Int?, duration: Double?) {
            reported[id] = (exit ?? reported[id]?.exit, duration ?? reported[id]?.duration)
        }

        func rows() -> [Row] {
            var rows: [Row] = []
            for (index, turn) in turns.enumerated() {
                var items: [Row] = []
                var files: [String: Int] = [:]   // path → index in items
                var commands = 0
                for id in turn.toolIDs {
                    guard let tool = tools[id] else { continue }
                    if let command = command(tool) {
                        items.append(.command(command))
                        commands += 1
                        continue
                    }
                    // An edit that failed changed nothing.
                    guard tool.result?.failed != true else { continue }
                    for change in fileChanges(tool) {
                        let id = "\(turn.id)|\(change.path)"
                        if let at = files[change.path], case .file(var file) = items[at] {
                            file.added += change.added
                            file.removed += change.removed
                            file.edits += 1
                            file.tool = tool
                            if change.action == .deleted { file.action = .deleted }
                            else if file.action == .deleted { file.action = change.action }
                            items[at] = .file(file)
                        } else {
                            files[change.path] = items.count
                            items.append(.file(FileChange(id: id, path: change.path, action: change.action, added: change.added,
                                                          removed: change.removed, edits: 1, tool: tool)))
                        }
                    }
                }
                let tokens: Tokens?
                var cost: Double?
                if format == .claude {
                    let usage = turn.messages.compactMap { turn.usage[$0] }
                    tokens = usage.isEmpty ? nil : usage.map(\.tokens).reduce(Tokens(input: 0, cached: 0, output: 0)) {
                        Tokens(input: $0.input + $1.input, cached: $0.cached + $1.cached, output: $0.output + $1.output)
                    }
                    let costs = usage.compactMap(\.cost)
                    cost = costs.isEmpty ? nil : costs.reduce(0, +)
                } else {
                    tokens = turn.codexTokens
                }
                guard !items.isEmpty || tokens != nil else { continue }
                rows += items
                rows.append(.turn(Turn(id: turn.id, at: turn.at, partial: index == 0 && startsMidFile, tokens: tokens, cost: cost,
                                       files: files.count, commands: commands)))
            }
            return rows
        }

        private func command(_ tool: ChatTool) -> Command? {
            guard case .command(let text) = tool.detail else { return nil }
            let lines = text.split(whereSeparator: \.isNewline)
            let report = reported[tool.id]
            var exit = report?.exit
            if exit == nil, let result = tool.result, format == .claude {
                // Claude Code says "Exit code N" on a failed command; one that didn't fail exited 0 (unless it was
                // sent to the background, timed out or was interrupted: then the transcript doesn't say).
                if let match = result.output.firstMatch(of: #/^(?:Error: )?Exit code (-?\d+)/#) { exit = Int(match.1) }
                else if !result.failed, !background.contains(tool.id) { exit = 0 }
            }
            let first = lines.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            let title = tool.title == ToolActivity.clip(first) ? nil : ActivityFeed.plain(tool.title)
            return Command(id: tool.id, tool: tool, title: title?.isEmpty == false ? title : nil, command: first,
                           moreLines: lines.count > 1, exitCode: exit, duration: report?.duration ?? tool.duration,
                           background: background.contains(tool.id))
        }

        private func fileChanges(_ tool: ChatTool) -> [(path: String, action: FileChange.Action, added: Int, removed: Int)] {
            let patch = patches[tool.id]
            switch tool.detail {
            case .edit(let path, let changes):
                if let patch { return [(relative(path), .edited, patch.added, patch.removed)] }
                var added = 0, removed = 0
                for change in changes {
                    for line in LineDiff.lines(old: change.old, new: change.new) {
                        if line.kind == .added { added += 1 } else if line.kind == .removed { removed += 1 }
                    }
                }
                return [(relative(path), .edited, added, removed)]
            case .write(let path, let content):
                if let patch { return [(relative(path), patch.created ? .created : .edited, patch.added, patch.removed)] }
                return [(relative(path), .written, Self.lineCount(content), 0)]
            case .patch(let text):
                return Self.patchFiles(text).map { (relative($0.path), $0.action, $0.added, $0.removed) }
            default:
                return []
            }
        }

        private func relative(_ path: String) -> String {
            guard let cwd, !cwd.isEmpty else { return path }
            let root = cwd.hasSuffix("/") ? cwd : cwd + "/"
            return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
        }

        static func lineCount(_ text: String) -> Int {
            guard !text.isEmpty else { return 0 }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            return text.hasSuffix("\n") ? lines - 1 : lines
        }

        /// The files of a Codex `apply_patch` (`*** Add File:`, `*** Update File:` with `*** Move to:`, `*** Delete File:`)
        /// and the lines each adds and removes.
        static func patchFiles(_ patch: String) -> [(path: String, action: FileChange.Action, added: Int, removed: Int)] {
            var files: [(path: String, action: FileChange.Action, added: Int, removed: Int)] = []
            for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("*** Add File: ") {
                    files.append((String(line.dropFirst("*** Add File: ".count)).trimmingCharacters(in: .whitespaces), .created, 0, 0))
                } else if line.hasPrefix("*** Update File: ") {
                    files.append((String(line.dropFirst("*** Update File: ".count)).trimmingCharacters(in: .whitespaces), .edited, 0, 0))
                } else if line.hasPrefix("*** Delete File: ") {
                    files.append((String(line.dropFirst("*** Delete File: ".count)).trimmingCharacters(in: .whitespaces), .deleted, 0, 0))
                } else if line.hasPrefix("*** Move to: "), !files.isEmpty {
                    files[files.count - 1].path = String(line.dropFirst("*** Move to: ".count)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("***") || files.isEmpty {
                    continue
                } else if line.hasPrefix("+") {
                    files[files.count - 1].added += 1
                } else if line.hasPrefix("-") {
                    files[files.count - 1].removed += 1
                }
            }
            return files
        }
    }
}
