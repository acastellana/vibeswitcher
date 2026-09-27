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

    /// The reminder due for a session right now: `episode` identifies what it's about (the caller sends
    /// one per episode), `dueAt` is when it became due. `lastSeen` is when you last looked at the tab
    /// (looking restarts the waiting clock). `lastActivity` is the last hook event, and only when the
    /// hooks themselves say the session is working: a "working" read off the title spinner says
    /// nothing about how old the hook data is, so it can't be judged stalled (nil: no stall check).
    public static func due(status: SessionStatus, statusSince: Date, lastSeen: Date?, lastActivity: Date?,
                           now: Date) -> (nudge: Nudge, episode: Date, dueAt: Date)? {
        switch status {
        case .needsInput:
            let dueAt = max(statusSince, lastSeen ?? .distantPast).addingTimeInterval(waitingAfter)
            guard now >= dueAt else { return nil }
            return (.stillWaiting(minutes: Int(now.timeIntervalSince(statusSince) / 60)), statusSince, dueAt)
        case .working:
            guard let lastActivity else { return nil }
            let dueAt = lastActivity.addingTimeInterval(stalledAfter)
            guard now >= dueAt else { return nil }
            return (.stalled(minutes: Int(now.timeIntervalSince(lastActivity) / 60)), lastActivity, dueAt)
        default:
            return nil
        }
    }
}

/// Where the day went: per project, how long agents worked and how long they waited on you.
/// Kept in `~/.vibeswitcher/stats/<yyyy-MM-dd>.json`.
public struct ActivityLedger: Codable, Equatable, Sendable {
    public enum Bucket: String, CaseIterable, Sendable {
        /// In a turn: thinking or running tools.
        case working
        /// Turn over, background jobs still running. Kept apart from `working`: a job can be a long
        /// computation the agent will resume on, or a dev server left running for days.
        case background
        /// Blocked on you: a question or permission prompt.
        case needsInput
        /// Finished, and you haven't looked yet (first `unseenDoneLimit` only).
        case unseenDone
    }

    public struct Entry: Sendable {
        public var project: String
        public var status: SessionStatus
        /// When the session entered `status`.
        public var since: Date
        public init(project: String, status: SessionStatus, since: Date) {
            self.project = project
            self.status = status
            self.since = since
        }
    }

    /// A finished session you haven't opened for this long was set aside, not waiting on you.
    public static let unseenDoneLimit: TimeInterval = 30 * 60

    public var day: String
    /// Project name → bucket → seconds.
    public var projects: [String: [String: Double]] = [:]
    /// Wall-clock time with at least one agent in a turn (sessions in parallel count once).
    public var agentsWorking: Double = 0
    /// Wall-clock time, while you were at the Mac, with at least one session waiting on you.
    public var waitingOnYou: Double = 0
    /// Same, while you were away. Kept apart: a question left overnight isn't a bottleneck in your day.
    public var waitedWhileAway: Double = 0

    public init(day: String) { self.day = day }

    static func bucket(for entry: Entry, now: Date) -> Bucket? {
        switch entry.status {
        case .working: return .working
        case .background: return .background
        case .needsInput: return .needsInput
        case .done: return now.timeIntervalSince(entry.since) <= unseenDoneLimit ? .unseenDone : nil
        case .idle, .unknown: return nil
        }
    }

    /// Books `seconds` (the time since the previous call) against each session's status.
    /// `userPresent`: you were at the Mac (screen unlocked, recent input); waiting only counts per
    /// project, and against you, while you were there to answer.
    public mutating func record(_ entries: [Entry], seconds: Double, now: Date, userPresent: Bool = true) {
        guard seconds > 0 else { return }
        var working = false
        var waiting = false
        for entry in entries {
            guard let bucket = Self.bucket(for: entry, now: now) else { continue }
            let isWait = bucket == .needsInput || bucket == .unseenDone
            if bucket == .working { working = true }
            if isWait { waiting = true }
            if !isWait || userPresent {
                projects[entry.project, default: [:]][bucket.rawValue, default: 0] += seconds
            }
        }
        if working { agentsWorking += seconds }
        if waiting { if userPresent { waitingOnYou += seconds } else { waitedWhileAway += seconds } }
    }

    private enum CodingKeys: String, CodingKey { case day, projects, agentsWorking, waitingOnYou, waitedWhileAway }

    /// Tolerates files written by other versions (missing counters start at zero).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(String.self, forKey: .day)
        projects = try container.decodeIfPresent([String: [String: Double]].self, forKey: .projects) ?? [:]
        agentsWorking = try container.decodeIfPresent(Double.self, forKey: .agentsWorking) ?? 0
        waitingOnYou = try container.decodeIfPresent(Double.self, forKey: .waitingOnYou) ?? 0
        waitedWhileAway = try container.decodeIfPresent(Double.self, forKey: .waitedWhileAway) ?? 0
    }

    public func seconds(_ buckets: [Bucket], project: String? = nil) -> Double {
        let rows = project.map { projects[$0].map { [$0] } ?? [] } ?? Array(projects.values)
        return rows.reduce(0) { sum, row in sum + buckets.reduce(0) { $0 + (row[$1.rawValue] ?? 0) } }
    }

    /// Per project: turn time, waiting-on-you time, background time; most active first.
    public func byProject() -> [(project: String, working: Double, waiting: Double, background: Double)] {
        projects.keys.map { name in
            (name, seconds([.working], project: name), seconds([.needsInput, .unseenDone], project: name),
             seconds([.background], project: name))
        }
        .filter { $0.working + $0.waiting >= 60 }
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
