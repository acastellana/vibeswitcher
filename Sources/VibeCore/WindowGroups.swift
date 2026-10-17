import Foundation

/// How the window's session list is grouped.
public enum WindowGrouping: String, CaseIterable, Sendable {
    /// Needs you, Working, Ready, Idle.
    case attention
    /// By project, in the store's order.
    case projects
}

/// The window's attention groups, in the order they're shown.
public enum AttentionGroup: CaseIterable, Sendable {
    case needsYou, working, ready, idle

    public var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .ready: return "Ready"
        case .idle: return "Idle"
        }
    }
}

/// What a row says about its session right now, and since when.
public struct RowState: Equatable, Sendable {
    public var text: String
    public var since: Date?
    public var group: AttentionGroup
}

extension WindowRow {
    /// Headline: your name for it, else what it's working on, else the program's own title, else the project.
    public var title: String {
        switch content {
        case .agent(let session): return session.customName ?? session.task ?? session.project
        case .hosted(let info): return info.title.isEmpty ? info.label : info.title
        }
    }

    public func state(now: Date) -> RowState {
        switch content {
        case .hosted(let info):
            if let exit = info.exit { return RowState(text: "ended · exit \(exit.status)", since: exit.at, group: .idle) }
            if info.agent != nil {
                if info.agentQuit(now: now) { return RowState(text: "agent ended · shell", since: nil, group: .idle) }
                return RowState(text: "starting", since: info.startedAt, group: .working)
            }
            return RowState(text: "shell", since: info.startedAt, group: .idle)
        case .agent(let session):
            if session.isPaused { return RowState(text: "paused", since: nil, group: .idle) }
            let since: Date? = session.statusSince
            switch session.status {
            case .needsInput: return RowState(text: "waiting", since: since, group: .needsYou)
            case .working, .background:
                if let activity = session.activity {
                    return RowState(text: activity, since: session.activitySince ?? since, group: .working)
                }
                return RowState(text: session.status == .working ? "working" : "background jobs", since: since, group: .working)
            case .done: return RowState(text: "done", since: since, group: .ready)
            case .idle: return RowState(text: "idle", since: since, group: .idle)
            case .unknown: return RowState(text: "status unknown", since: nil, group: .idle)
            }
        }
    }

    /// When this row's session started (window sessions: when the host started it).
    var startedAt: Date {
        switch content {
        case .agent(let session): return session.startedAt
        case .hosted(let info): return info.startedAt
        }
    }

    /// When its current status began; the start time for rows that have no status.
    var statusSince: Date {
        if case .agent(let session) = content { return session.statusSince }
        return startedAt
    }

    var searchText: String {
        var parts = [title, project]
        if case .agent(let session) = content, let task = session.task { parts.append(task) }
        return parts.joined(separator: "\n")
    }
}

extension HostSession {
    /// Started for an agent that the scan doesn't find (so this is asked of a window session without one) a minute
    /// on: an agent shows up within seconds, so it has quit and left the session's shell running.
    public func agentQuit(now: Date) -> Bool {
        isLive && agent != nil && now.timeIntervalSince(startedAt) >= WindowGroups.startingFor
    }
}

public enum WindowGroups {
    /// How long a window session started for an agent counts as starting.
    public static let startingFor: TimeInterval = 60

    /// The rows of `sections` regrouped by what they need from you. Within a group: needs-you longest
    /// waiting first, working earliest started first (so rows don't jump each turn), ready most recent
    /// first, idle in the given order. Empty groups are left out.
    public static func attention(_ sections: [WindowSection], now: Date = Date()) -> [WindowSection] {
        let rows = sections.flatMap(\.rows).enumerated().map { (index: $0.offset, row: $0.element) }
        return AttentionGroup.allCases.compactMap { group in
            let members = rows.filter { $0.row.state(now: now).group == group }
            guard !members.isEmpty else { return nil }
            let sorted = members.sorted { a, b in
                let (x, y): (Date, Date)
                switch group {
                case .needsYou: (x, y) = (a.row.statusSince, b.row.statusSince)
                case .working: (x, y) = (a.row.startedAt, b.row.startedAt)
                case .ready: (x, y) = (b.row.statusSince, a.row.statusSince)
                case .idle: return a.index < b.index
                }
                return x != y ? x < y : a.index < b.index
            }
            return WindowSection(project: group.title, rows: sorted.map(\.row))
        }
    }

    /// Rows whose title, project or task contain `query` (ignoring case); sections left empty are dropped.
    public static func filter(_ sections: [WindowSection], query: String) -> [WindowSection] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return sections }
        return sections.compactMap { section in
            let rows = section.rows.filter { $0.searchText.localizedCaseInsensitiveContains(needle) }
            return rows.isEmpty ? nil : WindowSection(project: section.project, rows: rows)
        }
    }

    /// "2 need you · 3 working"; empty when nothing needs you and nothing works.
    public static func summary(_ rows: [WindowRow], now: Date = Date()) -> String {
        let groups = rows.map { $0.state(now: now).group }
        let waiting = groups.filter { $0 == .needsYou }.count
        let working = groups.filter { $0 == .working }.count
        var parts: [String] = []
        if waiting > 0 { parts.append(waiting == 1 ? "1 needs you" : "\(waiting) need you") }
        if working > 0 { parts.append("\(working) working") }
        return parts.joined(separator: " · ")
    }
}
