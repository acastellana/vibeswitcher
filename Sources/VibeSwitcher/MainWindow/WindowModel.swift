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
    /// Window sessions' labels ("Lead · acme", "Worker: …"), by host id: they say who's on a lead's team.
    @Published private(set) var hostLabels: [UUID: String] = [:]
    /// Leads (row ids) whose team is shown under them.
    @Published var expandedTeams: Set<String> = []
    /// Leads another session of their project replaced (see `LeadController.replacedLeads`), by window session.
    @Published var replacedLeads: [UUID: ReplacedLead] = [:]
    /// The agent's own session id last seen in each window session, so it can be resumed once it ends.
    private(set) var agentSessions: [UUID: (agent: Agent, sessionID: String, transcript: String?)] = [:]
    /// The middle pane shows the conversation (Chat) rather than the terminal, where there is one.
    @Published var showsChat: Bool {
        didSet { UserDefaults.standard.set(showsChat, forKey: Self.showsChatKey) }
    }
    private static let showsChatKey = "middleShowsChat"
    /// Selected to show the start page instead of a session.
    static let homeID = "home"
    var showsHome: Bool { selectedID == Self.homeID }
    func showHome() { selectedID = Self.homeID }
    private static let selectionKey = "windowSelection"
    private static let groupingKey = "windowGrouping"

    init() {
        selectedID = UserDefaults.standard.string(forKey: Self.selectionKey)
        grouping = UserDefaults.standard.string(forKey: Self.groupingKey).flatMap(WindowGrouping.init(rawValue:)) ?? .attention
        showsChat = UserDefaults.standard.object(forKey: Self.showsChatKey) as? Bool ?? true
    }

    /// Every row, whatever the grouping and filter.
    var allRows: [WindowRow] { sections.flatMap(\.rows) }
    /// The sections as the sidebar shows them: grouped, then filtered.
    var displayedSections: [WindowSection] {
        WindowGroups.filter(arranged.sections, query: filter)
    }

    /// The list with each lead's team folded under it (the grunt work stays out of sight unless you open it).
    var arranged: LeadTeams.Arranged {
        LeadTeams.arrange(grouping == .attention ? WindowGroups.attention(sections) : sections, label: label(of:), expanded: expandedTeams)
    }

    func label(of row: WindowRow) -> String? {
        row.hosted?.label ?? row.hostID.flatMap { hostLabels[$0] }
    }

    func role(of row: WindowRow) -> LeadLaunch.Role? { LeadTeams.role(label: label(of: row)) }

    /// The lead that replaced this row's, if it's a replaced lead.
    func replaced(_ row: WindowRow) -> ReplacedLead? { row.hostID.flatMap { replacedLeads[$0] } }

    /// What the row says of its session: a replaced lead says where to continue, whatever its agent is doing.
    func state(of row: WindowRow, now: Date) -> RowState { replaced(row)?.rowState ?? row.state(now: now) }

    func toggleTeam(_ lead: String) {
        if expandedTeams.contains(lead) { expandedTeams.remove(lead) } else { expandedTeams.insert(lead) }
    }
    /// The rows in the order shown; what ⌘1–9 and ⌥⌘↑/↓ follow.
    var rows: [WindowRow] { displayedSections.flatMap(\.rows) }
    /// Stays selected while filtered out of view.
    var selectedRow: WindowRow? { allRows.first { $0.id == selectedID } }

    func focusFilter() { filterFocusRequests += 1 }

    /// The transcript the row's chat reads: the agent's, or for an ended window session the one it last had.
    func chatPath(for row: WindowRow) -> String? {
        row.session?.transcriptPath ?? row.hostID.flatMap { agentSessions[$0]?.transcript }
    }

    /// Whether the middle pane shows the selected row's chat right now.
    var chatShown: Bool { showsChat && selectedRow.map { chatPath(for: $0) != nil } == true }

    /// `hostAnswered`: false while the session host hasn't listed its sessions yet (at launch); a window
    /// session that was selected is kept until then.
    func update(sessions: [Session], hosted: [HostSession], hostAnswered: Bool = true) {
        for session in sessions {
            if let host = session.hostID, let id = session.agentSessionID {
                agentSessions[host] = (session.agent, id, session.transcriptPath ?? agentSessions[host]?.transcript)
            }
        }
        let known = Set(hosted.map(\.id))
        agentSessions = agentSessions.filter { known.contains($0.key) }
        let labels = Dictionary(uniqueKeysWithValues: hosted.map { ($0.id, $0.label) })
        if labels != hostLabels { hostLabels = labels }
        let fresh = WindowRows.sections(sessions: sessions, hosted: hosted) { SessionNaming.name(forProjectRoot: $0) }
        if fresh != sections { sections = fresh }
        // Keep the selection while its row exists (or before anything has loaded).
        let all = allRows
        guard !all.isEmpty, !showsHome, !all.contains(where: { $0.id == selectedID }) else { return }
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
                if state(of: row, now: Date()).group == .needsYou {
                    if clearsFilter { filter = "" }
                    selectedID = row.id
                    return
                }
            }
        }
    }
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
    /// Ends the agent in its Terminal tab and resumes the conversation in the window (asks first).
    var moveToWindow: (Session) -> Void
    /// Starts the project lead for the repository holding this folder (or shows the running one).
    var startLead: (String) -> Void
}
