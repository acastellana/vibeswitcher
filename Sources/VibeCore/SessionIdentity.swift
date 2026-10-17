import CryptoKit
import Foundation

/// Which session a request means. A tty outlives its session: when an agent exits, the tab (or later a
/// new tab reusing the same ttysNNN) can hold another one. The agent process — its pid and start time —
/// is the session.
public enum SessionIdentity {
    public static func id(tty: String, pid: Int32, startedAt: Date) -> String {
        let key = "\(tty)|\(pid)|\(Int64((startedAt.timeIntervalSince1970 * 1000).rounded()))"
        return Base64URL.encode(Data(SHA256.hash(data: Data(key.utf8))).prefix(12))
    }

    /// Whether that agent process is still the one running (a pid can be reused by a later process).
    public static func isRunning(pid: Int32, startedAt: Date) -> Bool {
        guard let info = ProcessTable.info(pid: pid) else { return false }
        return abs(info.startTime.timeIntervalSince(startedAt)) < 1
    }
}

/// Which terminal's session a hook event is about.
///
/// Usually the nearest `claude`/`codex` ancestor of the hook: agents run hooks as their own children. Codex 0.157+
/// runs threads in a background app server instead (`codex app-server --listen unix:// --managed-daemon`), shared by
/// every TUI and reparented to launchd once the TUI that started it quits. A hook it runs has no terminal and no
/// session above it (or, while that first TUI lives, the wrong one), so its terminal is found from the payload.
public enum HookOwner {
    public enum Lineage: Equatable {
        /// The agent process the hook runs under.
        case agent(pid: Int32, tty: String)
        /// A second agent further up (Claude running `codex exec` as a tool): the outer session's state isn't ours.
        case nested
        /// Run by Codex's app server, for a session on another process.
        case detached
        /// No agent above the hook.
        case none
    }

    /// `ancestors`: the hook's, nearest first (`ProcessTable.ancestors`).
    public static func lineage(_ ancestors: [ProcInfo], arguments: (ProcInfo) -> [String]) -> Lineage {
        var agents: [ProcInfo] = []
        for proc in ancestors {
            // Whatever started the daemon (the first TUI that needed one) isn't the session the hook is for.
            if proc.comm == "codex", ProcessTable.isCodexAppServer(arguments(proc)) { return agents.isEmpty ? .detached : lineage(of: agents) }
            if proc.agent != nil { agents.append(proc) }
        }
        return agents.isEmpty ? .none : lineage(of: agents)
    }

    private static func lineage(of agents: [ProcInfo]) -> Lineage {
        guard agents.count == 1, let tty = agents[0].tty else { return .nested }
        return .agent(pid: agents[0].pid, tty: tty)
    }

    /// A Codex TUI: the first agent process on its terminal (as `SessionScanner` sees sessions).
    public struct CodexTerminal: Sendable {
        public let pid: Int32
        public let tty: String
        public let startTime: Date
        /// Where it works: its `-C`/`--cd` folder, else its cwd.
        public let directory: String?
        public let arguments: [String]
        /// What the hooks last recorded for its terminal.
        public let state: HookState?

        public init(pid: Int32, tty: String, startTime: Date, directory: String?, arguments: [String], state: HookState?) {
            self.pid = pid
            self.tty = tty
            self.startTime = startTime
            self.directory = directory
            self.arguments = arguments
            self.state = state
        }

        /// The session it runs now is known: recorded by its own process.
        var isBound: Bool { state?.agentPid == pid && state?.sessionId != nil }
    }

    public static func codexTerminals(processes: [Int32: ProcInfo], cwd: (Int32) -> String?,
                                      arguments: (ProcInfo) -> [String], state: (String) -> HookState?) -> [CodexTerminal] {
        var roots: [String: ProcInfo] = [:]
        for proc in processes.values where proc.agent != nil {
            guard let tty = proc.tty else { continue }
            if let root = roots[tty], root.startTime <= proc.startTime { continue }
            roots[tty] = proc
        }
        return roots.values.filter { $0.agent == .codex }.sorted { $0.pid < $1.pid }.map { root in
            let argv = arguments(root)
            return CodexTerminal(pid: root.pid, tty: root.tty!, startTime: root.startTime,
                                 directory: directory(arguments: argv, cwd: cwd(root.pid)), arguments: argv,
                                 state: state(root.tty!))
        }
    }

    /// `codex -C dir` / `--cd dir` / `--cd=dir` works there (relative to where it was started); otherwise in its cwd.
    static func directory(arguments: [String], cwd: String?) -> String? {
        var chosen: String?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-C" || argument == "--cd", index + 1 < arguments.count {
                chosen = arguments[index + 1]
                index += 1
            } else if argument.hasPrefix("--cd=") {
                chosen = String(argument.dropFirst(5))
            }
            index += 1
        }
        guard let chosen else { return cwd }
        if chosen.hasPrefix("/") { return chosen }
        guard let cwd else { return nil }
        return URL(fileURLWithPath: cwd).appendingPathComponent(chosen).path
    }

    /// The TUI a daemon-run Codex hook belongs to, from the payload's `session_id` and `cwd`; nil when that can't be
    /// told (better no status than another tab's).
    ///
    /// In order: the TUI that already recorded this session; one started with it (`codex resume <id>`); else the
    /// TUIs working in the payload's folder. A SessionStart there is the TUI's new session (`/new`, `/fork` and
    /// `/resume` start one in the same TUI), when only one TUI works there; any other event, or several TUIs, only
    /// goes to a TUI whose session isn't known yet. Several of those at a SessionStart: the thread's id is a UUIDv7,
    /// so its creation time picks the TUI started last before it.
    public static func codexTerminal(for payload: [String: Any], among terminals: [CodexTerminal]) -> CodexTerminal? {
        guard let session = payload["session_id"] as? String, !session.isEmpty else { return nil }
        if let known = terminals.first(where: { $0.isBound && $0.state?.sessionId == session }) { return known }
        if let resumed = terminals.first(where: { $0.arguments.dropFirst().contains(session) }) { return resumed }
        guard let cwd = payload["cwd"] as? String, !cwd.isEmpty else { return nil }
        let folder = canonical(cwd)
        let here = terminals.filter { $0.directory.map(canonical) == folder }
        let unknown = here.filter { !$0.isBound }
        let isStart = payload["hook_event_name"] as? String == "SessionStart"
        if isStart, here.count == 1 { return here[0] }
        if unknown.count == 1 { return unknown[0] }
        guard isStart, unknown.count > 1, let created = uuidV7Date(session) else { return nil }
        return unknown.filter { $0.startTime.timeIntervalSince(created) <= 1 }.max { $0.startTime < $1.startTime }
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// When a UUIDv7 was made (its first 48 bits are Unix milliseconds); nil for other ids.
    static func uuidV7Date(_ id: String) -> Date? {
        let hex = id.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, hex[hex.index(hex.startIndex, offsetBy: 12)] == "7",
              let millis = UInt64(hex.prefix(12), radix: 16) else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}
