import Foundation
import VibeCore

/// One agent session on this machine, as the node lists it: its terminal, its agent, where it works, and its status
/// since when.
public struct LocalSession: Equatable, Sendable {
    /// The terminal's name (`ttys003` on the Mac, `ttypts3` on Linux: `Platform.Terminals.name(devicePath:)`).
    public var terminal: String
    public var agent: Agent
    public var pid: Int32
    /// The folder the hooks last reported, else the agent's own working directory.
    public var cwd: String?
    public var status: SessionStatus
    /// When the hooks last reported (the status holds since then at least), else when the agent started.
    public var since: Date

    public init(terminal: String, agent: Agent, pid: Int32, cwd: String?, status: SessionStatus, since: Date) {
        self.terminal = terminal
        self.agent = agent
        self.pid = pid
        self.cwd = cwd
        self.status = status
        self.since = since
    }

    /// This node's name for it: `local:<terminal>`, until nodes have names of their own.
    public var id: String { "\(LocalSessions.node):\(terminal)" }

    /// The status as one word of the glossary, in kebab case: `needs-you`, `working`, `background`, `done`, `idle`,
    /// `unknown`.
    public var statusWord: String {
        status.word.rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1-$2", options: .regularExpression).lowercased()
    }
}

/// The one list of the sessions on this machine, which `vibeswitcher status` reads (and the engine will): every
/// `claude` or `codex` on a terminal (`ProcessTable`), joined with what the hooks wrote for that terminal (`HookState`,
/// `VibePaths.stateDir`) by the terminal's name, the scan the app makes (`SessionScanner`), and resolved by
/// `StatusRules`. No terminal title is read here, so a session without hook state is `unknown`.
public final class LocalSessions {
    /// The node's name in a session's id, until nodes have names of their own.
    public static let node = "local"

    private let scanner: SessionScanner

    /// `scanner`: the app's scan of this machine by default; tests give one with a fake process table.
    public init(scanner: SessionScanner = SessionScanner()) {
        self.scanner = scanner
    }

    /// The sessions now, ordered by terminal; nil when the process table couldn't be read (not "no sessions").
    public func read(now: Date = Date()) -> [LocalSession]? {
        let raw = scanner.scan(now: now)
        guard scanner.readAt == now else { return nil }
        return raw.map { session in
            LocalSession(terminal: session.tty, agent: session.agent, pid: session.pid, cwd: session.cwd,
                         status: StatusRules.resolve(hook: session.hook, title: .none, now: now.timeIntervalSince1970),
                         since: session.hook.map { Date(timeIntervalSince1970: $0.lastEventAt) } ?? session.startedAt)
        }
        .sorted { ($0.terminal, $0.pid) < ($1.terminal, $1.pid) }
    }
}
