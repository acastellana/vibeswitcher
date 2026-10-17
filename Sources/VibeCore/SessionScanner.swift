import Foundation

/// A live agent process joined with whatever the hooks recorded for its terminal.
public struct RawSession: Sendable {
    public let tty: String
    public let agent: Agent
    public let pid: Int32
    public let startedAt: Date
    public let cwd: String?
    /// Repo/folder name the agent was launched in (see `SessionNaming.project`).
    public let project: String
    /// Full path of that repo/folder.
    public let projectRoot: String?
    public let hook: HookState?
    /// Claude only: shells still running under the agent (background commands, monitor loops).
    public let backgroundJobs: [BackgroundJob]
    /// Runs in a Terminal.app tab (Terminal is among its ancestors), so Terminal's scripting can tell about it.
    public let inTerminalApp: Bool
}

public final class SessionScanner {
    /// Keyed on pid and start time, so a reused pid isn't mistaken for the process that had it.
    private struct ProcessKey: Hashable { let pid: Int32; let start: Date }
    private var cwdCache: [ProcessKey: String] = [:]
    private var projectCache: [ProcessKey: (workingDirectory: String?, root: String)] = [:]
    /// Decoded state files by path, re-read only when their modification date changes.
    private var stateCache: [String: (modified: Date, state: HookState)] = [:]

    /// The last scan, for when the process table can't be read.
    private var last: [RawSession] = []

    private let processes: () -> [Int32: ProcInfo]?
    private let stateDir: () -> URL
    private let cwd: (Int32) -> String?
    private let arguments: (ProcInfo) -> [String]

    /// The defaults read this Mac; tests pass a fake process table and their own state folder.
    public init(processes: @escaping () -> [Int32: ProcInfo]? = ProcessTable.trySnapshot,
                stateDir: @escaping () -> URL = { VibePaths.stateDir },
                cwd: @escaping (Int32) -> String? = ProcessTable.cwd(pid:),
                arguments: @escaping (ProcInfo) -> [String] = {
                    ProcessTable.arguments(pid: $0.pid, start: Int($0.startTime.timeIntervalSince1970), comm: $0.comm)
                }) {
        self.processes = processes
        self.stateDir = stateDir
        self.cwd = cwd
        self.arguments = arguments
    }

    /// Finds every `claude`/`codex` process attached to a terminal, one session per TTY.
    public func scan(now: Date = Date()) -> [RawSession] {
        // Unreadable this time: keep what was seen (an empty table would look like every session ended, and their
        // hook state would be deleted).
        guard let procs = processes() else { return last }
        var byTTY: [String: [ProcInfo]] = [:]
        for proc in procs.values where proc.agent != nil {
            guard let tty = proc.tty else { continue }
            byTTY[tty, default: []].append(proc)
        }

        let hooks = loadHookStates(liveTTYs: Set(byTTY.keys), now: now)
        var sessions: [RawSession] = []
        for (tty, agentProcs) in byTTY {
            // Several agent processes can share a TTY (Codex spawns helpers, Claude may run
            // `codex exec` as a tool). The session is the one that started first.
            guard let root = agentProcs.min(by: { $0.startTime < $1.startTime }),
                  let agent = root.agent else { continue }
            let hook = hooks[tty].flatMap { isCurrent($0, agent: agent, root: root, procs: agentProcs) ? $0 : nil }
            let key = ProcessKey(pid: root.pid, start: root.startTime)
            let launchDirectory = cachedCwd(key)
            let cwd = hook?.cwd ?? launchDirectory
            let projectRoot = cachedProjectRoot(key, launchDirectory: launchDirectory ?? cwd, workingDirectory: hook?.cwd)
            sessions.append(RawSession(tty: tty, agent: agent, pid: root.pid, startedAt: root.startTime,
                                       cwd: cwd, project: projectRoot.map { SessionNaming.name(forProjectRoot: $0) } ?? "?",
                                       projectRoot: projectRoot, hook: hook,
                                       backgroundJobs: agent == .claude
                                           ? BackgroundJobs.jobs(forAgent: root.pid, in: procs, arguments: arguments) : [],
                                       inTerminalApp: Self.runsInTerminalApp(root.pid, in: procs)))
        }
        let live = { (key: ProcessKey) in procs[key.pid]?.startTime == key.start }
        cwdCache = cwdCache.filter { live($0.key) }
        projectCache = projectCache.filter { live($0.key) }
        last = sessions
        return sessions
    }

    /// A state file belongs to the running session unless it was written by another (older) process on the same TTY.
    private func isCurrent(_ state: HookState, agent: Agent, root: ProcInfo, procs: [ProcInfo]) -> Bool {
        if state.agent != agent { return false }
        if state.lastEventAt < root.startTime.timeIntervalSince1970 - 2 { return false }
        if let pid = state.agentPid, !procs.contains(where: { $0.pid == pid }) { return false }
        return true
    }

    /// Terminal.app is among the process's ancestors (Terminal → login → shell → agent). Window sessions run
    /// under the session host, others under iTerm, VS Code, …: Terminal's scripting knows nothing about those.
    static func runsInTerminalApp(_ pid: Int32, in procs: [Int32: ProcInfo]) -> Bool {
        var current = procs[pid]?.ppid ?? 0
        for _ in 0..<32 {
            guard current > 1, let parent = procs[current] else { return false }
            if parent.comm == "Terminal" { return true }
            current = parent.ppid
        }
        return false
    }

    /// The agent's own cwd is where it was launched (its tools `cd` in subprocesses), so it is stable;
    /// the working directory only matters when that isn't a repo.
    private func cachedProjectRoot(_ key: ProcessKey, launchDirectory: String?, workingDirectory: String?) -> String? {
        if let cached = projectCache[key], cached.workingDirectory == workingDirectory { return cached.root }
        guard let launchDirectory else { return nil }
        let root = SessionNaming.projectRoot(launchDirectory: launchDirectory, workingDirectory: workingDirectory)
        projectCache[key] = (workingDirectory, root)
        return root
    }

    private func cachedCwd(_ key: ProcessKey) -> String? {
        if let cached = cwdCache[key] { return cached }
        let cwd = cwd(key.pid)
        cwdCache[key] = cwd
        return cwd
    }

    /// Reads `~/.vibeswitcher/state/*.json`, deleting files for terminals that no longer run an agent.
    private func loadHookStates(liveTTYs: Set<String>, now: Date) -> [String: HookState] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: stateDir(),
                                                      includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [:] }
        var states: [String: HookState] = [:]
        for file in files where file.pathExtension == "json" {
            let tty = file.deletingPathExtension().lastPathComponent
            if !liveTTYs.contains(tty) {
                // Give a just-started process a moment to show up in the process table.
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if now.timeIntervalSince(modified) > 15 {
                    try? fm.removeItem(at: file)
                    try? fm.removeItem(at: file.appendingPathExtension("lock"))
                }
                continue
            }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let cached = stateCache[file.path], cached.modified == modified {
                states[tty] = cached.state
            } else if let state = HookState.load(from: file) {
                stateCache[file.path] = (modified, state)
                states[tty] = state
            }
        }
        stateCache = stateCache.filter { entry in files.contains { $0.path == entry.key } }
        return states
    }
}

/// What one read of Terminal.app's tabs gave.
public enum TerminalRead<Tab> {
    case tabs([String: Tab])
    /// Timed out, script error, output that didn't parse: Terminal was busy (it answers Apple Events one at a time),
    /// its tabs didn't go anywhere.
    case failed
    /// The Automation permission was refused.
    case denied
    case notRunning
}

/// When the scan asks Terminal.app for its tabs and screens, and what it keeps when an answer doesn't come.
///
/// Each read spawns `osascript` and makes Terminal answer Apple Events, so Terminal is only asked while a session
/// runs in it (window sessions and other terminal apps don't need it).
///
/// One failed read must not wipe the tabs for a scan: every session would lose its title and position for a
/// cycle, the list and ⌃1–9 would reorder, and title-only sessions would flip done → unknown → done and announce
/// "done" again.
public struct TerminalPoll<Tab> {
    public struct Bridge {
        public var tabs: () -> TerminalRead<Tab>
        /// Screen text of the tabs on these ttys; nil when the read failed.
        public var screens: (Set<String>) -> [String: String]?
        public init(tabs: @escaping () -> TerminalRead<Tab>, screens: @escaping (Set<String>) -> [String: String]?) {
            self.tabs = tabs
            self.screens = screens
        }
    }

    /// Screen text is only needed for Claude's footer and is the most expensive read, so it's read less often.
    public static var screensInterval: TimeInterval { 6 }

    /// Terminal's tabs by tty, as last read.
    public private(set) var tabs: [String: Tab] = [:]
    /// Background work in Claude's footer by tty (see `BackgroundWork`), as last read.
    public private(set) var backgroundWork: [String: String] = [:]
    private var lastTabsRead = Date.distantPast
    private var lastScreensRead = Date.distantPast

    public init() {}

    /// Reads Terminal if `interval` has passed since the last read (or `force`). `terminalTTYs`: the sessions running
    /// in Terminal.app (see `RawSession.inTerminalApp`); with none, nothing is read. `quiet`: Claude sessions whose
    /// turn looks over, whose footers are read for background work. Returns the read, when one was made.
    @discardableResult
    public mutating func poll(now: Date, interval: TimeInterval, terminalTTYs: Set<String>, quiet: Set<String>,
                              force: Bool, bridge: Bridge) -> TerminalRead<Tab>? {
        guard !terminalTTYs.isEmpty else {
            tabs = [:]
            backgroundWork = [:]
            return nil
        }
        guard force || now.timeIntervalSince(lastTabsRead) >= interval - 0.05 else { return nil }
        lastTabsRead = now
        let read = bridge.tabs()
        switch read {
        case .tabs(let fresh): tabs = fresh
        // A terminal can have changed hands since (closed tab, its tty reused by a window session).
        case .failed: tabs = tabs.filter { terminalTTYs.contains($0.key) }
        case .denied, .notRunning: tabs = [:]
        }
        let quiet = quiet.intersection(terminalTTYs)
        if force || now.timeIntervalSince(lastScreensRead) >= Self.screensInterval {
            if let screens = bridge.screens(quiet) {
                backgroundWork = screens.compactMapValues { BackgroundWork.summary(fromScreen: $0) }
            } else {
                backgroundWork = backgroundWork.filter { quiet.contains($0.key) }
            }
            lastScreensRead = now
        }
        return read
    }
}
