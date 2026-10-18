import Foundation

/// One row of the window's session list.
public struct WindowRow: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// An agent session the scan found (in the window, in Terminal.app, or elsewhere).
        case agent(Session)
        /// A window session with no live agent: a shell, an ended session, or one that is still starting.
        case hosted(HostSession)
    }

    public var content: Content
    public var project: String

    public init(content: Content, project: String) {
        self.content = content
        self.project = project
    }

    /// Window sessions are keyed by their host id, so a row keeps its identity (and selection) when the
    /// agent in it ends.
    public var id: String {
        switch content {
        case .agent(let session): return session.hostID.map { "host:\($0)" } ?? "tty:\(session.tty)"
        case .hosted(let session): return "host:\(session.id)"
        }
    }

    /// What a composer draft is kept under: the window session (whatever agent runs in it), or for a Terminal
    /// session its conversation (a new agent on the same tab is someone else).
    public var draftKey: String {
        switch content {
        case .agent(let session) where session.hostID == nil: return "agent:\(session.agentSessionID ?? session.identity)"
        default: return id
        }
    }

    public var hostID: UUID? {
        switch content {
        case .agent(let session): return session.hostID
        case .hosted(let session): return session.id
        }
    }
}

public struct WindowSection: Identifiable, Equatable, Sendable {
    public var project: String
    public var rows: [WindowRow]
    public var id: String { project }
}

public enum WindowRows {
    /// Hosted sessions the scan didn't match to a live agent.
    public static func extras(hosted: [HostSession], agentTTYs: Set<String>) -> [HostSession] {
        hosted.filter { !($0.isLive && agentTTYs.contains($0.tty)) }
    }

    /// Sections by project, in the store's order; window-only rows (live first, newest first) after.
    public static func sections(sessions: [Session], hosted: [HostSession], projectName: (String) -> String) -> [WindowSection] {
        var order: [String] = []
        var rows: [String: [WindowRow]] = [:]
        // One row per id: a window session ended a moment ago (a host restart ends them one by one) is still the
        // scan's agent until the next scan, and the list can't show two rows with one id.
        var ids: Set<String> = []
        func add(_ row: WindowRow) {
            guard ids.insert(row.id).inserted else { return }
            if rows[row.project] == nil { order.append(row.project) }
            rows[row.project, default: []].append(row)
        }
        // The scan can list an agent before the store learns its tty is a window session's.
        let liveHosted = Dictionary(hosted.filter(\.isLive).map { ($0.tty, $0.id) }, uniquingKeysWith: { $1 })
        for var session in sessions {
            if session.hostID == nil { session.hostID = liveHosted[session.tty] }
            add(WindowRow(content: .agent(session), project: session.project))
        }
        let extras = extras(hosted: hosted, agentTTYs: Set(sessions.map(\.tty))).sorted {
            if $0.isLive != $1.isLive { return $0.isLive }
            return $0.startedAt < $1.startedAt
        }
        extras.forEach { add(WindowRow(content: .hosted($0), project: projectName($0.cwd))) }
        return order.map { WindowSection(project: $0, rows: rows[$0] ?? []) }
    }
}
