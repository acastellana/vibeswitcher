import Foundation

/// A one-off reminder about a session that has quietly been left alone.
public enum Nudge: Equatable, Sendable {
    /// Needs your input and nobody has looked at it for a while.
    case stillWaiting(minutes: Int)
    /// Says it's working, but no hook event has arrived for a long time: likely hung.
    case stalled(minutes: Int)
}

public enum Nudges {
    public static let waitingAfter: TimeInterval = 10 * 60
    public static let stalledAfter: TimeInterval = 15 * 60

    /// The reminder due for a session right now, with the moment its episode began: the caller sends
    /// each episode's reminder once. `lastSeen` is when you last looked at the tab (looking restarts
    /// the waiting clock), `lastActivity` the last hook event (nil without hooks: no stall detection).
    public static func due(status: SessionStatus, statusSince: Date, lastSeen: Date?, lastActivity: Date?,
                           now: Date) -> (nudge: Nudge, episode: Date)? {
        switch status {
        case .needsInput:
            let clock = max(statusSince, lastSeen ?? .distantPast)
            guard now.timeIntervalSince(clock) >= waitingAfter else { return nil }
            return (.stillWaiting(minutes: Int(now.timeIntervalSince(statusSince) / 60)), statusSince)
        case .working:
            guard let lastActivity, now.timeIntervalSince(lastActivity) >= stalledAfter else { return nil }
            return (.stalled(minutes: Int(now.timeIntervalSince(lastActivity) / 60)), lastActivity)
        default:
            return nil
        }
    }
}

/// Where the day went: per project, how long agents worked and how long they waited on you.
/// Kept in `~/.vibeswitcher/stats/<yyyy-MM-dd>.json`.
public struct ActivityLedger: Codable, Equatable, Sendable {
    public enum Bucket: String, CaseIterable, Sendable {
        case working, background
        /// Blocked on you: a question or permission prompt.
        case needsInput
        /// Finished, and you haven't looked yet.
        case unseenDone

        init?(_ status: SessionStatus) {
            switch status {
            case .working: self = .working
            case .background: self = .background
            case .needsInput: self = .needsInput
            case .done: self = .unseenDone
            case .idle, .unknown: return nil
            }
        }
    }

    public var day: String
    /// Project name → bucket → seconds.
    public var projects: [String: [String: Double]] = [:]
    /// Wall-clock time with at least one agent working (sessions in parallel count once).
    public var agentsBusy: Double = 0
    /// Wall-clock time when something waited on you and no agent was doing anything: you were the bottleneck.
    public var blockedOnYou: Double = 0

    public init(day: String) { self.day = day }

    public mutating func record(_ sessions: [(project: String, status: SessionStatus)], seconds: Double) {
        guard seconds > 0 else { return }
        var busy = false
        var waiting = false
        for session in sessions {
            guard let bucket = Bucket(session.status) else { continue }
            projects[session.project, default: [:]][bucket.rawValue, default: 0] += seconds
            if bucket == .working || bucket == .background { busy = true } else { waiting = true }
        }
        if busy { agentsBusy += seconds }
        if waiting, !busy { blockedOnYou += seconds }
    }

    public func seconds(_ buckets: [Bucket], project: String? = nil) -> Double {
        let rows = project.map { projects[$0].map { [$0] } ?? [] } ?? Array(projects.values)
        return rows.reduce(0) { sum, row in sum + buckets.reduce(0) { $0 + (row[$1.rawValue] ?? 0) } }
    }

    /// Agent time and waiting-on-you time per project, busiest first.
    public func byProject() -> [(project: String, working: Double, waiting: Double)] {
        projects.keys.map { name in
            (name, seconds([.working, .background], project: name), seconds([.needsInput, .unseenDone], project: name))
        }
        .sorted { ($0.working + $0.waiting, $1.project) > ($1.working + $1.waiting, $0.project) }
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func url(day: String) -> URL {
        VibePaths.statsDir.appendingPathComponent("\(day).json")
    }

    public static func load(day: String) -> ActivityLedger {
        guard let data = try? Data(contentsOf: url(day: day)),
              let ledger = try? JSONDecoder().decode(ActivityLedger.self, from: data), ledger.day == day
        else { return ActivityLedger(day: day) }
        return ledger
    }

    /// Readable by you only: it names your projects.
    public func save() {
        let fm = FileManager.default
        try? fm.createDirectory(at: VibePaths.statsDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: VibePaths.statsDir.path)
        let url = Self.url(day: day)
        guard let data = try? JSONEncoder().encode(self), (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
