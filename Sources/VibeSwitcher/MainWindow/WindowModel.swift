import Combine
import Foundation
import VibeCore

/// The main window's list and selection.
final class WindowModel: ObservableObject {
    @Published private(set) var sections: [WindowSection] = []
    @Published var selectedID: String? {
        didSet { if selectedID != oldValue { UserDefaults.standard.set(selectedID, forKey: Self.selectionKey) } }
    }
    /// The agent's own session id last seen in each window session, so it can be resumed once it ends.
    private(set) var agentSessions: [UUID: (agent: Agent, sessionID: String)] = [:]
    private static let selectionKey = "windowSelection"

    init() {
        selectedID = UserDefaults.standard.string(forKey: Self.selectionKey)
    }

    var rows: [WindowRow] { sections.flatMap(\.rows) }
    var selectedRow: WindowRow? { rows.first { $0.id == selectedID } }

    func update(sessions: [Session], hosted: [HostSession]) {
        for session in sessions {
            if let host = session.hostID, let id = session.agentSessionID { agentSessions[host] = (session.agent, id) }
        }
        let known = Set(hosted.map(\.id))
        agentSessions = agentSessions.filter { known.contains($0.key) }
        let fresh = WindowRows.sections(sessions: sessions, hosted: hosted) { SessionNaming.name(forProjectRoot: $0) }
        if fresh != sections { sections = fresh }
        // Keep the selection while its row exists (or before anything has loaded).
        guard !rows.isEmpty, !rows.contains(where: { $0.id == selectedID }) else { return }
        selectedID = rows.first?.id
    }

    func select(hostID: UUID) { selectedID = "host:\(hostID)" }

    func select(tty: String) {
        if let row = rows.first(where: { $0.session?.tty == tty }) { selectedID = row.id }
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

    /// The next row after the selected one (wrapping) whose agent is waiting on you.
    func selectNextNeedingYou() {
        let rows = self.rows
        guard !rows.isEmpty else { return }
        let start = rows.firstIndex { $0.id == selectedID } ?? -1
        for step in 1...rows.count {
            let row = rows[(start + step) % rows.count]
            if row.session?.status == .needsInput, row.session?.isPaused == false {
                selectedID = row.id
                return
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
}
