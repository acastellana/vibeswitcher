import Foundation

/// Which one-liners are due, and the ones written so far: for each key (a task's agent, a decision), the last line
/// written, what it was written from (a fingerprint of its input: the transcript's size and time, a decision's
/// text) and when it was asked for. A new one is asked for only when the input changed, at most once per `interval`,
/// never while one is being written.
public struct SummaryCache: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// The last line written, if any.
        public var text: String?
        /// The input the last request was for.
        public var fingerprint: String
        public var requestedAt: Double
        public var running: Bool
        /// The last request gave nothing (no Claude, an error, out of time): show the fallback.
        public var failed: Bool
    }

    /// At most one request per key this often (seconds).
    public static let interval: Double = 3 * 60

    public private(set) var entries: [String: Entry] = [:]
    public var interval: Double

    public init(interval: Double = Self.interval) { self.interval = interval }

    /// Whether to ask for a new line for `key` now: there's none yet, or its input changed and the last request is
    /// `interval` old; never while one runs.
    public func isDue(_ key: String, fingerprint: String, now: Double) -> Bool {
        guard let entry = entries[key] else { return true }
        return !entry.running && entry.fingerprint != fingerprint && now - entry.requestedAt >= interval
    }

    public mutating func begin(_ key: String, fingerprint: String, now: Double) {
        let text = entries[key]?.text
        entries[key] = Entry(text: text, fingerprint: fingerprint, requestedAt: now, running: true, failed: entries[key]?.failed ?? false)
    }

    /// A request ended: the line, or nil when it gave none.
    public mutating func end(_ key: String, text: String?) {
        guard var entry = entries[key] else { return }
        entry.running = false
        entry.failed = text == nil
        if let text { entry.text = text }
        entries[key] = entry
    }

    /// The line to show: the last one written, unless the last request failed (nil: show the fallback).
    public func line(_ key: String) -> String? {
        guard let entry = entries[key], !entry.failed else { return nil }
        return entry.text
    }
}

/// Plain-language one-liners for the Team view, written by a small model: what a task's agent is doing now, what a
/// long decision of the lead's means. Requests run off the main thread (`run`), one per key at a time, throttled by
/// `SummaryCache`; `changed` is called (on `deliver`'s queue) when a line arrives. The model is injected: tests give
/// a fake, the app gives `ClaudeHeadless.summarize`.
public final class Summarizer: @unchecked Sendable {
    /// Writes the line for a prompt, blocking; nil when it can't.
    public typealias Generate = @Sendable (_ prompt: String) -> String?

    private let generate: Generate
    private let now: @Sendable () -> Double
    private let run: (@escaping @Sendable () -> Void) -> Void
    private let deliver: (@escaping @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private var cache: SummaryCache
    public var changed: @Sendable () -> Void = {}

    public init(generate: @escaping Generate, interval: Double = SummaryCache.interval,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                run: @escaping (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) },
                deliver: @escaping (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.generate = generate
        self.now = now
        self.run = run
        self.deliver = deliver
        cache = SummaryCache(interval: interval)
    }

    /// The line for `key` as written so far (nil: none yet, or the last request failed), asking for a new one when
    /// it's due. `prompt` is built off the main thread, only when a request goes out; nil skips it.
    @discardableResult
    public func line(_ key: String, fingerprint: String, prompt: @escaping @Sendable () -> String?) -> String? {
        lock.lock()
        let due = cache.isDue(key, fingerprint: fingerprint, now: now())
        if due { cache.begin(key, fingerprint: fingerprint, now: now()) }
        let line = cache.line(key)
        lock.unlock()
        if due {
            run { [self] in
                let text = prompt().flatMap(generate).flatMap(Self.clean)
                lock.lock()
                cache.end(key, text: text)
                lock.unlock()
                deliver { [self] in changed() }
            }
        }
        return line
    }

    /// The line written for `key`, without asking for one.
    public func cached(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache.line(key)
    }

    /// The longest line shown.
    public static let limit = 90

    /// The model's answer as one line: its first non-empty line, unquoted, at most `limit` characters.
    public static func clean(_ text: String) -> String? {
        guard var line = text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else { return nil }
        let quotes = CharacterSet(charactersIn: "\"'“”‘’`*")
        line = line.trimmingCharacters(in: quotes).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return clip(line, limit)
    }

    /// At most `count` characters, cut at a word with "…" when it's longer.
    public static func clip(_ text: String, _ count: Int) -> String {
        guard text.count > count else { return text }
        let cut = text.prefix(count - 1)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.-—")) + "…"
    }
}

/// The prompts the Team view's one-liners are written from.
public enum SummaryPrompts {
    /// The system prompt: one plain line, for someone glancing at a list.
    public static let system = """
        You write one short line, at most 90 characters, in plain language a non-programmer understands. No jargon, \
        no file or function names unless essential, no quotes, no preamble, no trailing period.
        """

    /// What a task's agent is doing now, from its title, its latest checkpoints and its last steps.
    public static func task(title: String, role: String, checkpoints: [LeadCheckpoint], steps: [TranscriptEntry]) -> String {
        var text = "Say what this \(role) is doing right now, starting with a verb (e.g. \"Making the credential masker fast on huge inputs\").\n\n"
        text += "Task: \(title)\n"
        if !checkpoints.isEmpty {
            text += "\nLatest milestones, oldest first:\n" + checkpoints.suffix(3).map { "- \(Summarizer.clip($0.text, 200))" }.joined(separator: "\n") + "\n"
        }
        if !steps.isEmpty {
            text += "\nIts last steps, oldest first:\n" + steps.map(step).joined(separator: "\n") + "\n"
        }
        return text
    }

    /// What a decision of the lead's means, from the decision and why.
    public static func decision(_ decision: String, why: String) -> String {
        "Restate this decision a project lead took, as what was decided (no \"Decided:\" prefix).\n\n"
            + "Decision: \(Summarizer.clip(decision, 1_000))\n\nWhy: \(Summarizer.clip(why, 1_000))\n"
    }

    static func step(_ entry: TranscriptEntry) -> String {
        let text = Summarizer.clip(entry.text.replacingOccurrences(of: "\n", with: " "), 240)
        switch entry.kind {
        case .prompt: return "- Told: \(text)"
        case .reply: return "- Said: \(text)"
        case .tool, .toolResult: return "- \(entry.tool.map { "\($0): " } ?? "")\(text)"
        }
    }

    /// The last `count` steps of a Claude Code transcript (prompts, replies, tool calls), from its last 64 KB.
    public static func steps(transcript path: String, count: Int = 6) -> [TranscriptEntry] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let window: UInt64 = 64 * 1024
        let start = size > window ? size - window : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() else { return [] }
        if start > 0 { data = data.subdata(in: (data.startIndex + TranscriptReader.tailStart(data))..<data.endIndex) }
        return Array(TranscriptReader.read(data, format: .claude, outputLimit: 0).entries.suffix(count))
    }

    /// A transcript's identity for change detection: its size and when it was last written.
    public static func fingerprint(transcript path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber, let date = attributes[.modificationDate] as? Date else { return nil }
        return "\(size.int64Value)@\(date.timeIntervalSince1970)"
    }
}

/// Headless Claude Code (`claude -p`) with a small model and no tools, settings, hooks, MCP servers or saved session:
/// a plain completion, through the login shell so `claude` is found where the user's terminal finds it.
public enum ClaudeHeadless {
    public static let model = "haiku"
    public static let timeout: TimeInterval = 30

    /// The program and arguments that write one line for `prompt`.
    public static func command(prompt: String, system: String = SummaryPrompts.system, model: String = model) -> (executable: String, args: [String]) {
        ("/bin/zsh", ["-lc", "exec claude \"$@\"", "zsh", "-p", "--model", model, "--tools", "", "--no-session-persistence",
                      "--setting-sources", "", "--strict-mcp-config", "--system-prompt", system, prompt])
    }

    /// The line, or nil when Claude isn't there, fails or takes longer than `timeout`. Blocks: call it off the main
    /// thread.
    public static func summarize(_ prompt: String) -> String? {
        let command = command(prompt: prompt)
        return run(executable: command.executable, args: command.args, timeout: timeout)
    }

    /// Runs it in a scratch folder (no project's CLAUDE.md), its output when it exits cleanly in time.
    static func run(executable: String, args: [String], timeout: TimeInterval) -> String? {
        let result = Shell.run(executable: executable, args: args, in: NSTemporaryDirectory(), timeout: timeout, grace: 1)
        return result.ok && !result.output.isEmpty ? result.output : nil
    }
}
