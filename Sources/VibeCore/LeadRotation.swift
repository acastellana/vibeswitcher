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
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd(), start = size > 1024 * 1024 ? size - 1024 * 1024 : 0
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()
        if start > 0 { data = data.subdata(in: TranscriptReader.tailStart(data)..<data.count) }
        var log = ChatLog()
        log.append(ChatReader.read(data, format: .claude).events)
        return log
    }

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
