import Combine
import Foundation
import VibeCore

/// The main window's list and selection.
final class WindowModel: ObservableObject {
    @Published private(set) var sections: [WindowSection] = []
    @Published var selectedID: String? {
        didSet { if selectedID != oldValue { UserDefaults.standard.set(selectedID, forKey: Self.selectionKey) } }
    }
    @Published var grouping: WindowGrouping {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: Self.groupingKey) }
    }
    /// The sidebar's filter text.
    @Published var filter = ""
    /// Bumped to move the keyboard focus to the filter field (⌥⌘F).
    @Published private(set) var filterFocusRequests = 0
    /// Folders you've recently run agents in, most recent first (for the start page and the palette).
    @Published var recentProjects: [String] = []
    /// The agent's own session id last seen in each window session, so it can be resumed once it ends.
    private(set) var agentSessions: [UUID: (agent: Agent, sessionID: String)] = [:]
    private static let selectionKey = "windowSelection"
    private static let groupingKey = "windowGrouping"

    init() {
        selectedID = UserDefaults.standard.string(forKey: Self.selectionKey)
        grouping = UserDefaults.standard.string(forKey: Self.groupingKey).flatMap(WindowGrouping.init(rawValue:)) ?? .attention
    }

    /// Every row, whatever the grouping and filter.
    var allRows: [WindowRow] { sections.flatMap(\.rows) }
    /// The sections as the sidebar shows them: grouped, then filtered.
    var displayedSections: [WindowSection] {
        WindowGroups.filter(grouping == .attention ? WindowGroups.attention(sections) : sections, query: filter)
    }
    /// The rows in the order shown; what ⌘1–9 and ⌥⌘↑/↓ follow.
    var rows: [WindowRow] { displayedSections.flatMap(\.rows) }
    /// Stays selected while filtered out of view.
    var selectedRow: WindowRow? { allRows.first { $0.id == selectedID } }

    func focusFilter() { filterFocusRequests += 1 }

    /// `hostAnswered`: false while the session host hasn't listed its sessions yet (at launch); a window
    /// session that was selected is kept until then.
    func update(sessions: [Session], hosted: [HostSession], hostAnswered: Bool = true) {
        for session in sessions {
            if let host = session.hostID, let id = session.agentSessionID { agentSessions[host] = (session.agent, id) }
        }
        let known = Set(hosted.map(\.id))
        agentSessions = agentSessions.filter { known.contains($0.key) }
        let fresh = WindowRows.sections(sessions: sessions, hosted: hosted) { SessionNaming.name(forProjectRoot: $0) }
        if fresh != sections { sections = fresh }
        // Keep the selection while its row exists (or before anything has loaded).
        let all = allRows
        guard !all.isEmpty, !all.contains(where: { $0.id == selectedID }) else { return }
        if selectedID?.hasPrefix("host:") == true, !hostAnswered { return }
        selectedID = (rows.first ?? all.first)?.id
    }

    func select(hostID: UUID) { selectedID = "host:\(hostID)" }

    func select(tty: String) {
        if let row = allRows.first(where: { $0.session?.tty == tty }) { selectedID = row.id }
    }

    func select(index: Int) {
        if rows.indices.contains(index) { selectedID = rows[index].id }
    }

    func move(by delta: Int) {
        let rows = self.rows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : 0)
        selectedID = rows[((current + delta) % rows.count + rows.count) % rows.count].id
    }

    /// The next row after the selected one (wrapping) whose agent is waiting on you. One the filter hides
    /// is still found: the filter is cleared to show it.
    func selectNextNeedingYou() {
        for (rows, clearsFilter) in [(self.rows, false), (allRows, true)] where !rows.isEmpty {
            let start = rows.firstIndex { $0.id == selectedID } ?? -1
            for step in 1...rows.count {
                let row = rows[(start + step) % rows.count]
                if row.state(now: Date()).group == .needsYou {
                    if clearsFilter { filter = "" }
                    selectedID = row.id
                    return
                }
            }
        }
    }
}

extension WindowRow {
    var session: Session? {
        if case .agent(let session) = content { return session }
        return nil
    }

    var hosted: HostSession? {
        if case .hosted(let session) = content { return session }
        return nil
    }

    var cwd: String? { session?.cwd ?? hosted?.cwd }
}

/// What the window asks the app to do.
struct WindowActions {
    var newSession: (_ preset: LaunchPreset?, _ folder: String?) -> Void
    var endSession: (WindowRow) -> Void
    var resume: (WindowRow) -> Void
    var remove: (WindowRow) -> Void
    var rename: (Session) -> Void
    var pause: (Session, PauseStore.Duration) -> Void
    var resumePaused: (Session) -> Void
    var openInTerminal: (Session) -> Void
    var presets: (_ folder: String?) -> [LaunchPreset]
    var isLive: (WindowRow) -> Bool
    var canResume: (WindowRow) -> Bool
    /// A command line that resumes the row's agent conversation in its folder; nil when its id isn't known.
    var resumeCommand: (WindowRow) -> String?
    var settings: () -> Void
}
