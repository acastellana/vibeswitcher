import Foundation

/// Notices the main thread not answering: `beat` from the main thread, `check` from another one.
public struct StallDetector: Sendable {
    public enum Event: Equatable, Sendable {
        /// Stuck since then (reported once per stall).
        case stalled(since: Date)
        /// Answering again after being stuck this long.
        case recovered(after: TimeInterval)
    }

    public let threshold: TimeInterval
    /// How late a beat is before the main thread counts as late (`lateSince`): its stack is worth catching then, in
    /// case it turns into a stall.
    public let early: TimeInterval
    private var lastBeat: Date?
    private var stalledSince: Date?
    private var recovered: TimeInterval?
    private var lastCheck: Date?
    /// The last beat, while the next one is more than `early` late (as of the last `check`); nil once it beats.
    public private(set) var lateSince: Date?

    public init(threshold: TimeInterval, early: TimeInterval = 0.5) {
        self.threshold = threshold
        self.early = min(early, threshold)
    }

    public mutating func beat(at now: Date = Date()) {
        if let since = stalledSince {
            recovered = now.timeIntervalSince(since)
            stalledSince = nil
        }
        lastBeat = now
        lateSince = nil
    }

    public mutating func check(at now: Date = Date()) -> Event? {
        if let length = recovered {
            recovered = nil
            return .recovered(after: length)
        }
        defer { lastCheck = now }
        // The checker didn't run either (the Mac slept, App Nap held the app): the whole process was suspended,
        // which isn't the main thread being stuck. Start over from now.
        if stalledSince == nil, let previous = lastCheck, now.timeIntervalSince(previous) > threshold {
            lastBeat = now
            lateSince = nil
            return nil
        }
        if lateSince == nil, let last = lastBeat, now.timeIntervalSince(last) > early { lateSince = last }
        guard stalledSince == nil, let last = lastBeat, now.timeIntervalSince(last) > threshold else { return nil }
        stalledSince = last
        return .stalled(since: last)
    }
}

/// What the app did lately, for reading after a hang or a crash: the newest lines in memory, all of them in a
/// small log file (rotated once it's full). Any thread.
public final class Breadcrumbs: @unchecked Sendable {
    /// The app's: in memory until the app turns its file on (`write(to:)` with `appLog`, first thing in its `main`),
    /// so a test process, whatever its HOME, never writes the user's ~/.vibeswitcher/debug/app.log.
    public static let shared = Breadcrumbs(capacity: 400)
    /// `debug/app.log` under the home this process has when it's written.
    public static var appLog: URL { VibePaths.root.appendingPathComponent("debug/app.log") }

    private let capacity: Int
    /// Where the lines go, looked up at each write (none: they're kept in memory only).
    private var location: (@Sendable () -> URL)?
    private let maxFileBytes: Int
    private let lock = NSLock()
    private var ring: [String] = []
    private var unwritten = ""
    private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public init(capacity: Int, file: URL? = nil, maxFileBytes: Int = 1_000_000) {
        self.capacity = capacity
        self.location = file.map { file in { file } }
        self.maxFileBytes = maxFileBytes
    }

    /// Writes the lines from now on to the file `file` gives, asked each time they're written.
    public func write(to file: @escaping @Sendable () -> URL) {
        lock.lock()
        location = file
        lock.unlock()
    }

    /// The file the next lines go to, if any.
    public var file: URL? {
        lock.lock()
        defer { lock.unlock() }
        return location?()
    }

    /// Bytes noted and not written yet.
    var pending: Int {
        lock.lock()
        defer { lock.unlock() }
        return unwritten.utf8.count
    }

    /// Every line noted while it's kept that `matching` takes, however far the ring rolls meanwhile. For a test that looks
    /// for its own lines: in a full suite the other tests in the process note theirs too, and the ring may roll past
    /// what it looks for before it looks (2026-11-19: an OpenAI dictation test's first two runs gone from the last 400).
    public final class Watch: @unchecked Sendable {
        private let matching: @Sendable (String) -> Bool
        private let lock = NSLock()
        private var seen: [String] = []

        fileprivate init(_ matching: @escaping @Sendable (String) -> Bool) { self.matching = matching }

        /// The lines it took, oldest first.
        public var lines: [String] { lock.withLock { seen } }

        fileprivate func take(_ line: String) {
            guard matching(line) else { return }
            lock.withLock { seen.append(line) }
        }
    }

    private struct Watching { weak var watch: Watch? }
    private var watches: [Watching] = []

    /// A watch on the lines noted from now on (`Watch`), until it's let go of. `matching` mustn't note a line itself.
    public func watch(_ matching: @escaping @Sendable (String) -> Bool) -> Watch {
        let watch = Watch(matching)
        lock.lock()
        watches.append(Watching(watch: watch))
        lock.unlock()
        return watch
    }

    public func note(_ text: String) {
        lock.lock()
        let line = "\(stamp.string(from: Date())) \(text)"
        ring.append(line)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        if !watches.isEmpty {
            watches.removeAll { $0.watch == nil }
            for watching in watches { watching.watch?.take(line) }
        }
        unwritten += line + "\n"
        let full = unwritten.utf8.count > 8_192
        lock.unlock()
        if full { flush() }
    }

    public var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return ring
    }

    /// Writes what's pending to the file.
    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard !unwritten.isEmpty else { return }
        guard let file = location?() else {
            unwritten = ""  // No file: the lines are only kept in memory.
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size + unwritten.utf8.count > maxFileBytes {
            let old = file.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: file, to: old)
        }
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(Redaction.secrets(in: String(unwritten.suffix(maxFileBytes))).utf8))
            try? handle.close()
        }
        unwritten = ""
    }
}
