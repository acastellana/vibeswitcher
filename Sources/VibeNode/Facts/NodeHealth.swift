import Foundation
import VibeCore

/// The node's health digest (the app's health digest and freeze reports, `AppHealthWatcher.swift`, `AppHealth.swift`;
/// the parity table's row): what `vibeswitcher status --health` and the page's This node show beside the host's own
/// counts (server restarts, refused connections, how the server last ended: `HostNotes.ServerEnd`, the node's stand-in
/// for the app's crash reports) and the sessions left waiting or stuck (`NodeSessions.reminderNotices`).
///
/// - Freezes: a watchdog on a thread of its own pings the engine's queue every `beat` seconds; a ping not answered
///   within `stallAfter` is a stall, shown as under way while it lasts and kept as a freeze, with how long, once the
///   queue answers. The app's freeze report is a sample of the main thread, which a node can't take (no debugger, the
///   rule): a node reports when and how long.
/// - Slow refreshes: the engine's 3 s refresh taking longer than `slowRefresh` (its reads of the boards and the
///   transcripts), counted, with the slowest and the last.
/// - The last errors: the server's own log lines that say something failed (`problem(_:)`), the newest `kept`, as the
///   journal has them (the server's stderr is the unit's journal).
/// - Their causes (the app's digest of error kinds, `AppHealth.errorKind`): each failing line counted by its kind, the
///   part of the server that wrote it (its words before the first colon) and the failure word, never what else it
///   says; the most frequent first, so a cause that repeats stands out from one that happened once.
///
/// Freezes are kept in `<node root>/health.json` across restarts (the newest `kept`), so one that ended in a restart
/// still shows; the rest is this server's.
public final class NodeHealth: @unchecked Sendable {
    public static let beat: TimeInterval = 5
    public static let stallAfter: TimeInterval = 10
    public static let slowRefresh: TimeInterval = 5
    public static let kept = 10

    public struct Freeze: Codable, Equatable, Sendable {
        public var at: Date
        public var seconds: Double
    }

    public struct Problem: Codable, Equatable, Sendable {
        public var at: Date
        public var line: String
    }

    private let lock = NSLock()
    private let file: URL?
    private let clock: () -> TimeInterval
    private let date: () -> Date
    private let started: Date
    // Under `lock`:
    private var freezes: [Freeze] = []
    private var problems: [Problem] = []
    private var slow = 0
    private var slowest: Double = 0
    private var lastSlow: Date?
    private var causes: [String: (count: Int, last: Date)] = [:]
    /// The ping waiting for the queue: when it was sent (the monotonic clock) and the date then.
    private var pending: (sent: TimeInterval, at: Date)?
    private var timer: DispatchSourceTimer?
    private let watch = DispatchQueue(label: "vibenode.health-watchdog", qos: .utility)

    /// `file`: where freezes are kept (nil: nowhere). `clock`: seconds on a monotonic clock; `date`: the wall clock.
    public init(file: URL?, clock: @escaping () -> TimeInterval = { MacTime.real.awake() }, date: @escaping () -> Date = Date.init) {
        self.file = file
        self.clock = clock
        self.date = date
        started = date()
        if let file, let data = try? Data(contentsOf: file), data.count < 256 * 1024 {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            freezes = (try? decoder.decode([Freeze].self, from: data)) ?? []
        }
    }

    // MARK: The watchdog

    /// Pings `queue` every `beat` seconds from a thread of its own, until released.
    public func watch(_ queue: DispatchQueue) {
        let source = DispatchSource.makeTimerSource(queue: watch)
        source.schedule(deadline: .now() + Self.beat, repeating: Self.beat, leeway: .seconds(1))
        source.setEventHandler { [weak self] in self?.tick(queue) }
        source.resume()
        lock.withLock { timer = source }
    }

    deinit { timer?.cancel() }

    /// One beat: a ping sent when none waits (its answer ends any stall, kept as a freeze when it lasted `stallAfter`).
    func tick(_ queue: DispatchQueue) {
        let now = clock()
        let send: Bool = lock.withLock {
            guard pending == nil else { return false }
            pending = (now, date())
            return true
        }
        guard send else { return }
        queue.async { [weak self] in self?.answered() }
    }

    private func answered() {
        let now = clock()
        lock.withLock {
            guard let ping = pending else { return }
            pending = nil
            let waited = now - ping.sent
            guard waited >= Self.stallAfter else { return }
            freezes.append(Freeze(at: ping.at, seconds: waited))
            freezes = Array(freezes.suffix(Self.kept))
        }
        save()
    }

    /// How long the queue has left the waiting ping unanswered, when that's a stall (`stallAfter` or more).
    public var stalled: TimeInterval? {
        let now = clock()
        return lock.withLock { pending.map { now - $0.sent }.flatMap { $0 >= Self.stallAfter ? $0 : nil } }
    }

    private func save() {
        guard let file else { return }
        let kept = lock.withLock { freezes }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(kept) { try? VibePaths.writePrivate(data, to: file) }
    }

    // MARK: What else it hears

    /// One of the engine's refreshes took `seconds`.
    public func refreshed(in seconds: Double) {
        guard seconds >= Self.slowRefresh else { return }
        let at = date()
        lock.withLock {
            slow += 1
            slowest = max(slowest, seconds)
            lastSlow = at
        }
    }

    /// Whether a server log line says something failed.
    public static func problem(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["fail", "error", "couldn't", "can't", "not written", "not recorded", "not started", "refused", "didn't start", "timed out"]
            .contains { lower.contains($0) }
    }

    /// The failure words, in the order a line is judged by.
    static let failureWords = ["failed", "fail", "error", "couldn't", "can't", "not written", "not recorded", "not started", "refused",
                               "didn't start", "timed out"]

    /// A failing line's kind: the part of the server that wrote it (its words before the first colon, when they read as
    /// a name: letters, spaces and dots, at most 40) and the failure word; nil for a line that says nothing failed.
    public static func kind(_ line: String) -> String? {
        let lower = line.lowercased()
        guard let word = failureWords.first(where: { lower.contains($0) }) else { return nil }
        var part = "server"
        if let colon = lower.firstIndex(of: ":") {
            let name = lower[..<colon].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name.count <= 40, name.allSatisfy({ $0.isLetter || $0 == " " || $0 == "." || $0 == "-" }) { part = name }
        }
        return "\(part): \(word)"
    }

    /// A server log line: kept when it says something failed, and counted by its kind.
    public func heard(_ line: String) {
        guard Self.problem(line) else { return }
        let at = date()
        let kind = Self.kind(line) ?? "server: failed"
        lock.withLock {
            problems.append(Problem(at: at, line: String(line.prefix(300))))
            if problems.count > Self.kept { problems.removeFirst(problems.count - Self.kept) }
            let was = causes[kind]?.count ?? 0
            causes[kind] = (was + 1, at)
            // A bounded table: past 50 kinds, the least frequent goes.
            if causes.count > 50, let least = causes.min(by: { ($0.value.count, $0.value.last) < ($1.value.count, $1.value.last) }) { causes[least.key] = nil }
        }
    }

    // MARK: Saying

    /// The digest as `status` carries it (`health`): `restarts` and `refused` the host's counts, `waiting` the
    /// sessions' reminders (left waiting or stuck).
    public func value(serverRestarts: Int?, refusedConnections: Int?, hostRestartAt: Date?, waiting: [String],
                      serverEnd: HostNotes.ServerEnd? = nil) -> NodeWire.Value {
        let (freezes, problems, slow, slowest, lastSlow, causes) = lock.withLock {
            (self.freezes, self.problems, self.slow, self.slowest, self.lastSlow, self.causes)
        }
        let ranked = causes.sorted { ($0.value.count, $0.value.last, $1.key) > ($1.value.count, $1.value.last, $0.key) }.prefix(Self.kept)
        return .object([
            "since": .date(started),
            "stalled": stalled.map { .int(Int($0.rounded())) } ?? .null,
            "freezes": .array(freezes.reversed().map { .object(["at": .date($0.at), "seconds": .int(Int($0.seconds.rounded()))]) }),
            "slowRefreshes": .int(slow),
            "slowestRefresh": slow > 0 ? .int(Int(slowest.rounded())) : .null,
            "lastSlowRefresh": lastSlow.map(NodeWire.Value.date) ?? .null,
            "serverRestarts": serverRestarts.map { .int($0) } ?? .null,
            "refusedConnections": refusedConnections.map { .int($0) } ?? .null,
            "hostRestartAt": hostRestartAt.map(NodeWire.Value.date) ?? .null,
            "serverEnded": serverEnd.map { .object(["at": .date($0.at), "ran": .int(Int($0.ran.rounded())),
                                                    "cause": .string(ConfigSeal.inert($0.cause, limit: 120))]) } ?? .null,
            "waiting": .array(waiting.map(NodeWire.Value.string)),
            "errors": .array(problems.reversed().map { .object(["at": .date($0.at), "line": .string(ConfigSeal.inert($0.line, limit: 300))]) }),
            "causes": .array(ranked.map { .object(["kind": .string(ConfigSeal.inert($0.key, limit: 80)), "count": .int($0.value.count),
                                                    "last": .date($0.value.last)]) }),
        ])
    }

    /// The digest as the command line prints it (`status --health`), from `health` (`value`'s shape). Every line inert.
    /// "45 s", "12 min", "3 h", "2 days".
    static func duration(_ seconds: Int) -> String {
        seconds < 120 ? "\(seconds) s" : seconds < 7200 ? "\(seconds / 60) min" : seconds < 172_800 ? "\(seconds / 3600) h" : "\(seconds / 86_400) days"
    }

    public static func lines(_ health: NodeWire.Value) -> [String] {
        func inert(_ text: String?) -> String { ConfigSeal.inert(text ?? "?", limit: 300) }
        var out = ["health since the server started \(inert(health["since"]?.string)):"]
        if let stalled = health["stalled"]?.int { out.append("  the engine's queue hasn't answered for \(stalled) s: it is stalled now") }
        let freezes = health["freezes"]?.array ?? []
        out.append(freezes.isEmpty ? "  freezes: none" : "  freezes (the engine's queue not answering for \(Int(stallAfter)) s or more), newest first:")
        for freeze in freezes { out.append("    \(inert(freeze["at"]?.string)): \(freeze["seconds"]?.int ?? 0) s") }
        let slow = health["slowRefreshes"]?.int ?? 0
        out.append(slow == 0 ? "  slow refreshes: none (over \(Int(slowRefresh)) s)"
                   : "  slow refreshes (over \(Int(slowRefresh)) s): \(slow), the slowest \(health["slowestRefresh"]?.int ?? 0) s, the last at \(inert(health["lastSlowRefresh"]?.string))")
        if let restarts = health["serverRestarts"]?.int { out.append("  server restarts by the host: \(restarts)") }
        if let refused = health["refusedConnections"]?.int { out.append("  connections the host refused: \(refused)") }
        if let at = health["hostRestartAt"]?.string { out.append("  the host last restarted at \(inert(at))") }
        if let ended = health["serverEnded"], ended["at"] != nil {
            out.append("  the server last ended on its own at \(inert(ended["at"]?.string)): \(inert(ended["cause"]?.string)), after \(Self.duration(ended["ran"]?.int ?? 0))")
        }
        let waiting = health["waiting"]?.array ?? []
        out.append(waiting.isEmpty ? "  sessions left waiting or stuck: none" : "  sessions left waiting or stuck:")
        for line in waiting { out.append("    " + inert(line.string)) }
        let causes = health["causes"]?.array ?? []
        if !causes.isEmpty {
            out.append("  causes, the most frequent first:")
            for cause in causes { out.append("    \(inert(cause["kind"]?.string)) ×\(cause["count"]?.int ?? 0), the last at \(inert(cause["last"]?.string))") }
        }
        let errors = health["errors"]?.array ?? []
        out.append(errors.isEmpty ? "  the server's last errors: none" : "  the server's last errors, newest first:")
        for error in errors { out.append("    \(inert(error["at"]?.string)): \(inert(error["line"]?.string))") }
        return out
    }
}
