import Foundation
import VibeCore

/// Your names for sessions and the sessions you paused (the app's Rename… and Pause, `SessionListView`, `PauseStore`
/// and its custom names, for a node; parity: "Pause, rename, reset a session's name", 2026-11-20). Kept by the session's
/// keys (`SessionKeys`: its process and the agent's session id, so a name and a pause survive `--resume`; and its host
/// id for a session the host runs), in `<node root>/session-marks.json` (0600). A paused session reads greyed out, and
/// nothing reminds or notifies you of it (`NodeSessions.reminderNotices`, the page's notifications) until the pause ends.
/// Changed only by the user's voice (`session.rename`, `session.pause`); read by `NodeSessions` at each scan. Display
/// state: nothing here acts on a session.
public final class SessionMarks: @unchecked Sendable {
    struct Book: Codable, Equatable {
        var names: [String: String] = [:]
        /// Key → when the pause ends (seconds since 1970; `Double.greatestFiniteMagnitude`: until resumed).
        var pauses: [String: Double] = [:]
    }

    /// The longest name kept, in characters.
    public static let nameLimit = 120

    public let file: URL
    private let lock = NSLock()
    private var book: Book

    public init(root: URL) {
        file = root.appendingPathComponent("session-marks.json")
        book = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Book.self, from: $0) } ?? Book()
    }

    /// The keys a session's marks are kept by: the app's (`SessionKeys`), and its host id when the host runs it.
    public static func keys(of session: Session) -> [String] {
        SessionKeys.keys(pid: session.pid, startedAt: session.startedAt, sessionId: session.agentSessionID)
            + (session.hostID.map { ["host:\($0.uuidString.lowercased())"] } ?? [])
    }

    public func name(for keys: [String]) -> String? {
        lock.withLock { keys.lazy.compactMap { self.book.names[$0] }.first }
    }

    public func pausedUntil(for keys: [String], now: Date) -> Date? {
        lock.withLock {
            keys.lazy.compactMap { self.book.pauses[$0] }.first { $0 > now.timeIntervalSince1970 }
                .map { $0 == .greatestFiniteMagnitude ? Date.distantFuture : Date(timeIntervalSince1970: $0) }
        }
    }

    /// `name` (trimmed, on one line, at most `nameLimit`) under every key; nil or blank: the name reset, the automatic one
    /// back. Returns the name kept.
    @discardableResult
    public func rename(_ keys: [String], to name: String?) throws -> String? {
        let line = name.map { $0.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
        let kept = line.flatMap { $0.isEmpty ? nil : String($0.prefix(Self.nameLimit)) }
        try change { book in for key in keys { book.names[key] = kept } }
        return kept
    }

    /// Paused until `until` (`distantFuture`: until resumed) under every key; nil: resumed.
    public func pause(_ keys: [String], until: Date?) throws {
        let end = until.map { $0 == .distantFuture ? Double.greatestFiniteMagnitude : $0.timeIntervalSince1970 }
        try change { book in for key in keys { book.pauses[key] = end } }
    }

    /// Ended pauses dropped, and, while some session is live, the marks of process keys none has (the app's
    /// `PauseStore.prune`: the agent's session id keys stay, for `--resume`, and so do host ids). A scan that found no
    /// session (its process table unreadable) drops no name.
    public func prune(liveKeys: Set<String>, now: Date) {
        let at = now.timeIntervalSince1970
        let gone = { (key: String) in !liveKeys.isEmpty && key.hasPrefix("proc:") && !liveKeys.contains(key) }
        try? change { book in
            book.pauses = book.pauses.filter { $0.value > at && !gone($0.key) }
            book.names = book.names.filter { !gone($0.key) }
        }
    }

    private func change(_ edit: (inout Book) -> Void) throws {
        try lock.withLock {
            var next = book
            edit(&next)
            guard next != book else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try VibePaths.writePrivate(try encoder.encode(next), to: file)
            book = next
        }
    }
}
