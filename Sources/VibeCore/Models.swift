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

    /// Its word in the glossary.
    public var word: StateWord {
        switch self {
        case .needsInput: return .needsYou
        case .working: return .working
        case .background: return .background
        case .done: return .done
        case .idle: return .idle
        case .unknown: return .unknown
        }
    }

    /// "Needs you", "Working"…: the glossary's label (`StateWord`).
    public var label: String { word.label }
}

/// The one word for each state a session can be in, used by every surface that names one: the window's rows, group
/// headers and status pill, the popover, the sidebar, the menu bar, the phone (`/api/state`'s `statusLabel`, and
/// `WORDS` in Web/app.js, which `GlossaryTests` holds to this) and the team summary. A word outside it for one of
/// these states fails `GlossaryTests`. How a window session ended is said by `SessionEnd` ("ended", "finished",
/// "exit N").
public enum StateWord: String, CaseIterable, Sendable {
    case needsYou, working, background, done, idle, paused, ended, unknown

    /// On its own, as a header, pill or badge says it: "Needs you".
    public var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .background: return "Background"
        case .done: return "Done"
        case .idle: return "Idle"
        case .paused: return "Paused"
        case .ended: return "Ended"
        case .unknown: return "Unknown"
        }
    }

    /// Inside a line of text: "needs you", "working"…
    public var text: String { label.lowercased() }

    /// After a count: "1 needs you", "2 need you", "1 in background", "3 working".
    public func counted(_ count: Int) -> String {
        switch self {
        case .needsYou: return count == 1 ? "1 needs you" : "\(count) need you"
        case .background: return "\(count) in background"
        default: return "\(count) \(text)"
        }
    }
}

/// One live agent session, identified by the terminal (TTY) it runs in.
public struct Session: Identifiable, Equatable, Sendable {
    public var id: String { tty }
    /// This session and no other: a tty can later hold another session (see `SessionIdentity`).
    public var identity: String { SessionIdentity.id(tty: tty, pid: pid, startedAt: startedAt) }
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
    /// Set while you've paused the session (`distantFuture`: until you resume it).
    public var pausedUntil: Date?
    public var isPaused: Bool { pausedUntil != nil }
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
    /// It's the visible tab of a window on the desktop you're looking at now.
    public var onCurrentDesktop = false
    /// Its Terminal window is on a desktop being shown (whichever tab is selected in it).
    public var windowOnCurrentDesktop = false
    /// Terminal.app window id (also its window-server id), when the tab was found.
    public var terminalWindowID: Int?
    /// The tool call it's running right now ("Run unit tests") and since when; nil between tool calls.
    public var activity: String?
    public var activitySince: Date?
    /// When the agent's last hook event arrived (the phone re-reads the conversation when it changes).
    public var eventAt: Double?
    /// The agent's transcript, already checked to be inside its folders (`TranscriptReader.checkedURL`).
    public var transcriptPath: String?
    /// The session host's id for it when it runs in VibeSwitcher's window; nil in Terminal.app or elsewhere.
    public var hostID: UUID?
    public var inWindow: Bool { hostID != nil }
    /// A lead, or a worker or verifier a lead started, from its window session's label (`LeadTeams.role`); nil for
    /// the rest of your sessions.
    public var teamRole: LeadLaunch.Role?
    /// A lead's worker or verifier: the lead's team, not one of your own sessions (see `SessionTeams`).
    public var isTeamMember: Bool { teamRole == .worker || teamRole == .verifier }
    /// The agent's own session id (from its hooks): what `--resume` takes.
    public var agentSessionID: String?
    /// Claude only: shells still running under the agent (background commands, monitor loops) as of the last scan,
    /// which reads the process table off the main thread; nobody on it should read that table again.
    public var backgroundJobs: [BackgroundJob] = []

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
