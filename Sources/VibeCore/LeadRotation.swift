import Foundation

/// Scheduled lead renewal. Unknown activity or context never counts as a quiet, full session.
public enum LeadRotationMode: String, CaseIterable, Sendable {
    case daily, context, never
    public var label: String {
        switch self {
        case .daily: "daily"
        case .context: "when its context is large"
        case .never: "never"
        }
    }
}

public enum LeadRotation {
    public static func gate(_ root: String) -> String { BoardStore(root: root).folder + "/run/lead-rotation.lock" }

    public static func reason(mode: LeadRotationMode, started: Date, percent: Int?, now: Date) -> String? {
        switch mode {
        case .never: return nil
        case .daily:
            return now.timeIntervalSince(started) >= 24 * 60 * 60 ? "the last session was over 24 hours old" : nil
        case .context:
            return percent.flatMap { $0 > 60 ? "the last one's context was \($0)% full" : nil }
        }
    }

    public static func quiet(activity: LeadActivity, queued: Bool, lastInput: Date, now: Date) -> Bool {
        activity == .idle(background: nil) && !queued && now.timeIntervalSince(lastInput) >= 120
    }

    /// The same conversation events as the chat, from a bounded, cached tail.
    private static let readings = UnchangedFiles<ChatLog?>()

    public static func reading(path: String) throws -> ChatLog {
        let cached = readings.value(at: path) { try? readLog(path: path) }
        guard let log = cached else {
            throw CocoaError(.fileReadUnknown)
        }
        return log
    }

    private static func readLog(path: String) throws -> ChatLog {
        var log = ChatLog()
        log.append(ChatReader.read(try tailData(path: path), format: .claude).events)
        return log
    }

    /// The transcript's last `bytes` (a megabyte), from its first whole line.
    static func tailData(path: String, bytes: UInt64 = 1024 * 1024) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd(), start = size > bytes ? size - bytes : 0
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()
        if start > 0 { data = data.subdata(in: TranscriptReader.tailStart(data)..<data.count) }
        return data
    }

    // MARK: Handover at a long idle

    /// A lead idle this long (minutes) with a large context hands over (`handover_idle_min:`): measured over the 7 days to
    /// 2026-11-18 (docs/process/reviews/cache-clock-and-mods.md), 50 minutes is while its 1-hour cache is still warm, so
    /// the note costs a cache read, and before Claude Code's own idle compaction (about 54 minutes at 200k tokens).
    public static let defaultIdleMinutes = 50
    /// From this context (tokens) an idle lead hands over (`handover_tokens:`): 8 handovers that week, about 81M
    /// cache-read tokens not carried after them.
    public static let defaultTokens = 150_000
    /// A setting under these reads as these: a shorter idle would cut into a conversation the user is still in, and a
    /// fresh lead starts near 80k tokens, so a lower threshold would hand over every idle hour all night.
    public static let minimumIdleMinutes = 10
    public static let minimumTokens = 100_000
    /// The lead's prompt cache lifetime (Claude Code writes its main sessions to the 1-hour bucket, measured). Past it,
    /// asking the old lead for a note re-sends its whole context, so VibeSwitcher writes the note itself.
    public static let cacheLifetime: TimeInterval = 60 * 60
    /// The note is asked for only this long before the cache's lifetime ends: its reply may take up to a minute, and a
    /// note that lands past the hour pays the whole re-send.
    public static let noteMargin: TimeInterval = 5 * 60
    /// How many times one idle stretch may ask a lead for its note (or hand over cold) before the rule gives up until
    /// the user types to it again: each failed ask is a turn in the user's chat, and its reply restarts the idle.
    public static let maxIdleAttempts = 2
    /// A question to the user this recent, still open, keeps the lead: the conversation is never cut mid-exchange.
    public static let recentQuestion: TimeInterval = 10 * 60

    /// A `handover_idle_min:` value as in force: 0 (or less) is off, anything else at least `minimumIdleMinutes`.
    public static func idleMinutes(_ value: Int) -> Int { value <= 0 ? 0 : max(value, minimumIdleMinutes) }
    /// A `handover_tokens:` value as in force: 0 (or less) is off, anything else at least `minimumTokens`.
    public static func tokens(_ value: Int) -> Int { value <= 0 ? 0 : max(value, minimumTokens) }

    /// The lead's last response and the context it sent, from its transcript's tail.
    public struct Tail: Equatable, Sendable {
        public var lastResponse: Date
        public var contextTokens: Int
        /// Claude Code compacted the conversation after that response: the context is no longer what it says.
        public var compacted: Bool
        public init(lastResponse: Date, contextTokens: Int, compacted: Bool = false) {
            self.lastResponse = lastResponse; self.contextTokens = contextTokens; self.compacted = compacted
        }
    }

    private static let tails = UnchangedFiles<Tail?>()

    /// The tail of the transcript at `path`, read again only when the file changed; nil when it has no response.
    public static func tail(path: String) -> Tail? {
        tails.value(at: path) { (try? tailData(path: path)).flatMap { tail($0) } }
    }

    /// Timestamps and token counts only: the main conversation's last response with usage, and whether a compaction
    /// followed it. A subagent's lines (`isSidechain`) are its own.
    static func tail(_ data: Data) -> Tail? {
        var found: Tail?
        for line in data.split(separator: 0x0A) {
            let usage = line.range(of: Data("\"usage\"".utf8)) != nil
            let compaction = line.range(of: Data("compact_boundary".utf8)) != nil
            guard usage || compaction,
                  let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  object["isSidechain"] as? Bool != true else { continue }
            let type = object["type"] as? String
            if type == "system", object["subtype"] as? String == "compact_boundary" {
                found?.compacted = true
            } else if type == "assistant", let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any], let at = ChatReader.date(object["timestamp"]) {
                let context = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                    .compactMap { usage[$0] as? Int }.reduce(0, +)
                if context > 0 { found = Tail(lastResponse: at, contextTokens: context) }
            }
        }
        return found
    }

    /// Whether the user's conversation with the lead is open: the lead's own question dialog waits for an answer, or a
    /// question it asked on the board is under `recentQuestion` old and unanswered. A handover then waits.
    public static func conversationOpen(openQuestionsAskedAt: [Double], asking: Bool, now: Date) -> Bool {
        asking || openQuestionsAskedAt.contains { now.timeIntervalSince1970 - $0 < recentQuestion }
    }

    /// Why a lead idle since its last response, with `tail`'s context, hands over now; nil while it stays. `idleMinutes`
    /// and `tokens` are the workflow's (0: off).
    public static func idle(tail: Tail?, idleMinutes: Int, tokens: Int, now: Date) -> String? {
        let minutes = Self.idleMinutes(idleMinutes), tokens = Self.tokens(tokens)
        guard minutes > 0, tokens > 0, let tail, !tail.compacted, tail.contextTokens >= tokens else { return nil }
        let idle = now.timeIntervalSince(tail.lastResponse)
        guard idle >= Double(minutes) * 60 else { return nil }
        return "the last one had been idle \(Int(idle / 60)) minutes with \(tail.contextTokens / 1000)k tokens of context"
            + ", past handover_idle_min \(minutes) and handover_tokens \(tokens / 1000)k"
    }

    /// Whether the lead's cache has expired by `now`, or will before an asked note lands (`noteMargin`): the note is
    /// then VibeSwitcher's (`coldNote`), not asked for.
    public static func cold(tail: Tail?, now: Date) -> Bool {
        tail.map { now.timeIntervalSince($0.lastResponse) > cacheLifetime - noteMargin } ?? false
    }

    /// The handover note when the old lead's cache had expired: asking it would have re-sent its whole context.
    public static func coldNote(_ tail: Tail?, now: Date) -> String {
        let idle = tail.map { " It had been idle \(Int(now.timeIntervalSince($0.lastResponse) / 60)) minutes with \($0.contextTokens / 1000)k tokens of context." } ?? ""
        return "VibeSwitcher wrote this note: the last lead's prompt cache had expired, so asking it for a note would have re-sent its whole context." + idle
            + " Continue from the board (its tasks and open questions), decisions.md and the last turns with the user: nothing there was changed by the handover."
    }

    /// The chat's status line for a handover: when, and why.
    public static func notice(reason: String, at: Date) -> String {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        return "Started a fresh lead session at \(clock.string(from: at)) (\(reason))"
    }

    /// What the line the old lead's note starts with begins with (a fresh id follows).
    public static let noteMarker = "VIBESWITCHER_HANDOVER_"

    public static let request = "VibeSwitcher is preparing a scheduled rotation to a fresh lead session. In your final reply within one minute, write a short handover note: open threads, promises made to the user, and timers due. Do no new work; finish this turn after the note. The board and its unanswered questions stay in place."
}


/// Claude's own context figures from the status line, keyed by transcript rather than a terminal that may be reused.
/// The window comes from Claude (200k and 1M sessions can report the same model name); it is never guessed.
public struct LeadContextStore: Sendable {
    private struct Reading: Codable {
        var transcript: String
        var at: Double
        var percent: Int
    }
    public var root: URL
    public var home: String

    public init(root: URL = VibePaths.root, home: String = VibePaths.home) {
        self.root = root; self.home = home
    }

    private func path(_ transcript: String) -> URL {
        root.appendingPathComponent("context").appendingPathComponent(LeadVault.hash(transcript) + ".json")
    }

    public func record(_ input: [String: Any], now: Date = Date()) {
        guard let transcript = input["transcript_path"] as? String,
              let (url, _) = TranscriptReader.checkedURL(transcript, home: home),
              let context = input["context_window"] as? [String: Any],
              let window = context["context_window_size"] as? Int, window > 0 else { return }
        let usage = context["current_usage"] as? [String: Any]
        let tokens = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            .compactMap { usage?[$0] as? Double }.reduce(0, +)
        guard let share = (context["used_percentage"] as? Double) ?? (tokens > 0 ? tokens / Double(window) * 100 : nil),
              share.isFinite, share >= 0 else { return }
        let reading = Reading(transcript: url.path, at: now.timeIntervalSince1970, percent: Int(min(100, share)))
        guard let data = try? JSONEncoder().encode(reading) else { return }
        let file = path(url.path)
        do {
            try VibePaths.ensurePrivate(file.deletingLastPathComponent())
            try LeadVault.writePrivate(data, to: file)
        } catch { return }
    }

    public func percent(transcript: String, started: Date) -> Int? {
        guard let (url, _) = TranscriptReader.checkedURL(transcript, home: home),
              let data = try? Data(contentsOf: path(url.path)), let reading = try? JSONDecoder().decode(Reading.self, from: data),
              reading.transcript == url.path, reading.at >= started.timeIntervalSince1970,
              (0...100).contains(reading.percent) else { return nil }
        return reading.percent
    }
}
