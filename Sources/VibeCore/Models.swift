import Foundation

public enum Agent: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    /// Maps a process `comm` (executable name, max 16 chars) to an agent.
    public init?(comm: String) {
        switch comm {
        case "claude": self = .claude
        case "codex": self = .codex
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

public enum SessionStatus: String, Codable, Sendable {
    /// Blocked on you: permission prompt, question, plan approval.
    case needsInput
    /// Model is thinking or running tools.
    case working
    /// Turn ended, but background shells/agents are still running; it will resume by itself.
    case background
    /// Finished a turn you haven't looked at yet.
    case done
    /// Finished and already seen (or never started a turn).
    case idle
    /// No hooks and no readable terminal title, so the state can't be told.
    case unknown

    public var label: String {
        switch self {
        case .needsInput: return "Needs input"
        case .working: return "Working"
        case .background: return "Background"
        case .done: return "Done"
        case .idle: return "Idle"
        case .unknown: return "Unknown"
        }
    }
}

/// One live agent session, identified by the terminal (TTY) it runs in.
public struct Session: Identifiable, Equatable, Sendable {
    public var id: String { tty }
    public let tty: String
    public var agent: Agent
    public var pid: Int32
    public var startedAt: Date
    public var cwd: String?
    /// Headline: the repo/folder the session was started in, e.g. "acme-site".
    public var project: String
    /// What it's working on, e.g. "Website redesign concepts". Nil when nothing useful is known.
    public var task: String?
    /// Name you gave the session (right-click › Rename); replaces the project as the headline.
    public var customName: String?
    /// Keys the custom name is stored under (see `SessionKeys`).
    public var nameKeys: [String] = []
    public var status: SessionStatus
    public var statusSince: Date
    public var detail: String?
    public var hasHooks: Bool
    /// True when the session's tab was found in Terminal.app (so we can focus that exact tab).
    public var inTerminalApp: Bool
    /// The Terminal tab you're looking at right now (Terminal frontmost, this tab selected in its front window).
    public var isCurrent = false
    /// Window frame and tab index in Terminal, used to order sessions like the screen.
    public var screenPosition: ScreenPosition?
    /// Its window is on the desktop you're looking at now.
    public var onCurrentDesktop = false
    /// Terminal.app window id (also its window-server id), when the tab was found.
    public var terminalWindowID: Int?
    /// The tool call it's running right now ("Run unit tests") and since when; nil between tool calls.
    public var activity: String?
    public var activitySince: Date?

    public init(tty: String, agent: Agent, pid: Int32, startedAt: Date, cwd: String?, project: String, task: String?,
                status: SessionStatus, statusSince: Date, detail: String?, hasHooks: Bool, inTerminalApp: Bool) {
        self.tty = tty
        self.agent = agent
        self.pid = pid
        self.startedAt = startedAt
        self.cwd = cwd
        self.project = project
        self.task = task
        self.status = status
        self.statusSince = statusSince
        self.detail = detail
        self.hasHooks = hasHooks
        self.inTerminalApp = inTerminalApp
    }

    /// Headline: your custom name if you gave one, else the project.
    public var displayName: String { customName ?? project }

    /// One-line label for tooltips and notifications: "acme-site — Website redesign concepts".
    public var title: String {
        guard let task else { return displayName }
        return "\(displayName) — \(task)"
    }

    /// `~/dev/project` style path for display.
    public var shortCwd: String? {
        guard let cwd else { return nil }
        let home = NSHomeDirectory()
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }
}
