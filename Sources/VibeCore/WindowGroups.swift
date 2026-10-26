import Foundation

/// How the window's session list is grouped.
public enum WindowGrouping: String, CaseIterable, Sendable {
    /// Needs you, Working, Done, Idle.
    case attention
    /// By project, in the store's order.
    case projects
}

/// The window's attention groups, in the order they're shown. `ready` is the Done group: finished turns.
public enum AttentionGroup: CaseIterable, Sendable {
    case needsYou, working, ready, idle

    /// The group's header, the glossary's word (`StateWord`).
    public var title: String {
        switch self {
        case .needsYou: return StateWord.needsYou.label
        case .working: return StateWord.working.label
        case .ready: return StateWord.done.label
        case .idle: return StateWord.idle.label
        }
    }
}

/// What a row says about its session right now, and since when: the glossary's word for its state (`StateWord`), what
/// it's running, or for a window session without an agent's state "starting" or "shell", and how it ended (`SessionEnd`).
public struct RowState: Equatable, Sendable {
    public var text: String
    public var since: Date?
    public var group: AttentionGroup
}

/// How a window session ended, as every row and bar says it: the hangup or terminate that ending a session sends
/// (exit 129, 143: VibeSwitcher ended it, or a signal did) reads "ended", 0 "finished", any other code "exit N", a
/// failure (orange, with a warning glyph). No real exit status (below 0: the app marks a session -1 when its host goes
/// away) reads "ended" too.
public struct SessionEnd: Equatable, Sendable {
    public var status: Int32

    public init(status: Int32) { self.status = status }

    /// Ended by VibeSwitcher or a signal, or with no exit status of its own.
    var isEnded: Bool { status < 0 || status == 129 || status == 143 }

    public var isFailure: Bool { status != 0 && !isEnded }

    public var text: String {
        if status == 0 { return "finished" }
        return isEnded ? "ended" : "exit \(status)"
    }

    /// The glyph beside it: a warning for a failure, else a neutral one.
    public var symbol: String {
        if status == 0 { return "checkmark.circle" }
        return isEnded ? "stop.circle" : "exclamationmark.circle"
    }
}

extension WindowRow {
    /// How its session ended; nil while it runs, and for scanned sessions (they leave the list when they end).
    public var end: SessionEnd? { hosted?.exit.map { SessionEnd(status: $0.status) } }

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
            if let exit = info.exit { return RowState(text: SessionEnd(status: exit.status).text, since: exit.at, group: .idle) }
            // No agent the scan knows, but a program that says what it's doing (OSC 7501): that, over its preset.
            if let program = info.liveProgramStatus { return Self.state(of: program) }
            if info.agent != nil {
                if agentQuit { return RowState(text: "agent ended · shell", since: nil, group: .idle) }
                if now.timeIntervalSince(info.startedAt) < WindowGroups.startingFor {
                    return RowState(text: "starting", since: info.startedAt, group: .working)
                }
                // A minute on, but no table read since says whether its agent is there (a loaded Mac): not known.
                return RowState(text: StateWord.unknown.text, since: nil, group: .idle)
            }
            return RowState(text: "shell", since: info.startedAt, group: .idle)
        case .agent(let session):
            if session.isPaused { return RowState(text: StateWord.paused.text, since: nil, group: .idle) }
            let since: Date? = session.statusSince
            // A worker or verifier asks its lead, not you: its team's work goes on.
            if session.waitsOnLead { return RowState(text: LeadTeams.waitsOnLead, since: since, group: .working) }
            // A lead with a question for you open needs you, its terminal on a prompt or not (`Session.shownStatus`).
            let status = session.shownStatus
            let text = status.word.text
            switch status {
            case .needsInput: return RowState(text: text, since: since, group: .needsYou)
            case .working, .background:
                if let activity = session.activity {
                    return RowState(text: activity, since: session.activitySince ?? since, group: .working)
                }
                return RowState(text: text, since: since, group: .working)
            case .done: return RowState(text: text, since: since, group: .ready)
            case .idle: return RowState(text: text, since: since, group: .idle)
            case .unknown: return RowState(text: text, since: nil, group: .idle)
            }
        }
    }

    /// A window session's row as its program reports it, since that report.
    static func state(of program: ProgramStatus) -> RowState {
        let since = program.since
        switch StatusRules.status(for: program) {
        case .needsInput: return RowState(text: StateWord.needsYou.text, since: since, group: .needsYou)
        case .working, .background: return RowState(text: program.title ?? StateWord.working.text, since: since, group: .working)
        case .done: return RowState(text: program.state == .error ? "error" : StateWord.done.text, since: since, group: .ready)
        case .idle, .unknown: return RowState(text: StateWord.idle.text, since: since, group: .idle)
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
        switch content {
        case .agent(let session): return session.statusSince
        case .hosted(let info): return info.liveProgramStatus?.since ?? startedAt
        }
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

/// The process table a scan's sessions come from: when it was read, and the terminals it couldn't tell an agent on or
/// not (see `SessionScanner.readAt`, `.undecided`).
public struct TableRead: Equatable, Sendable {
    /// nil until a table was read.
    public var at: Date?
    public var undecided: Undecided

    public init(at: Date? = nil, undecided: Undecided = Undecided()) {
        self.at = at
        self.undecided = undecided
    }

    /// A window session started for an agent that the scan doesn't have: its agent quit (`HostSession.agentQuit`) as
    /// of when this table was read, a minute on, not the clock's, and only from a table that could tell what runs on
    /// its terminal. While the table can't be read (a loaded Mac) the scan's sessions are an older table's, so a
    /// session started since, or less than a minute before it, is unknown, not ended; so is one whose process there
    /// couldn't be told (mid-exec). Never read: not quit.
    public func agentQuit(_ info: HostSession) -> Bool {
        guard let at, !undecided.contains(info.tty) else { return false }
        return info.agentQuit(now: at)
    }
}

public enum WindowGroups {
    /// How long a window session started for an agent counts as starting.
    public static let startingFor: TimeInterval = 60

    /// The rows of `sections` regrouped by what they need from you. Within a group: needs-you longest
    /// waiting first, working earliest started first (so rows don't jump each turn), done most recent
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

    /// The ended rows taken out of `sections`, in the order shown, for the "Ended (n)" fold at the list's end;
    /// sections left empty are dropped. Rows in `keep` stay where they are (a team member under its lead).
    public static func foldEnded(_ sections: [WindowSection], keep: Set<String> = []) -> (sections: [WindowSection], ended: [WindowRow]) {
        var ended: [WindowRow] = []
        let kept = sections.compactMap { section -> WindowSection? in
            let rows = section.rows.filter { row in
                guard row.end != nil, !keep.contains(row.id) else { return true }
                ended.append(row)
                return false
            }
            return rows.isEmpty ? nil : WindowSection(project: section.project, rows: rows)
        }
        return (kept, ended)
    }

    /// "2 need you · 3 working"; empty when nothing needs you and nothing works.
    public static func summary(_ rows: [WindowRow], now: Date = Date()) -> String {
        let groups = rows.map { $0.state(now: now).group }
        let needsYou = groups.filter { $0 == .needsYou }.count
        let working = groups.filter { $0 == .working }.count
        var parts: [String] = []
        if needsYou > 0 { parts.append(StateWord.needsYou.counted(needsYou)) }
        if working > 0 { parts.append(StateWord.working.counted(working)) }
        return parts.joined(separator: " · ")
    }
}
