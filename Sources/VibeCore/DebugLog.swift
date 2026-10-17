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
    private var lastBeat: Date?
    private var stalledSince: Date?
    private var recovered: TimeInterval?

    public init(threshold: TimeInterval) { self.threshold = threshold }

    public mutating func beat(at now: Date = Date()) {
        if let since = stalledSince {
            recovered = now.timeIntervalSince(since)
            stalledSince = nil
        }
        lastBeat = now
    }

    public mutating func check(at now: Date = Date()) -> Event? {
        if let length = recovered {
            recovered = nil
            return .recovered(after: length)
        }
        guard stalledSince == nil, let last = lastBeat, now.timeIntervalSince(last) > threshold else { return nil }
        stalledSince = last
        return .stalled(since: last)
    }
}

/// What the app did lately, for reading after a hang or a crash: the newest lines in memory, all of them in a
/// small log file (rotated once it's full). Any thread.
public final class Breadcrumbs: @unchecked Sendable {
    public static let shared = Breadcrumbs(capacity: 400, file: VibePaths.root.appendingPathComponent("debug/app.log"))

    private let capacity: Int
    private let file: URL?
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
        self.file = file
        self.maxFileBytes = maxFileBytes
    }

    public func note(_ text: String) {
        lock.lock()
        let line = "\(stamp.string(from: Date())) \(text)"
        ring.append(line)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
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
        guard let file, !unwritten.isEmpty else { return }
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
