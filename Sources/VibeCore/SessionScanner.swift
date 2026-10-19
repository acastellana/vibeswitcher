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

/// The terminals of a process table's processes that couldn't be told (see `ProcInfo.identityUnknown`): whether an
/// agent runs on one isn't known from that table, so a session there hasn't ended and none has started.
public struct Undecided: Sendable, Equatable {
    public var ttys: Set<String>
    /// One whose terminal couldn't be read either: it could be on any.
    public var anywhere: Bool

    public init(ttys: Set<String> = [], anywhere: Bool = false) {
        self.ttys = ttys
        self.anywhere = anywhere
    }

    public init(_ table: [Int32: ProcInfo]) {
        self.init()
        for process in table.values where process.identityUnknown {
            if let tty = process.tty { ttys.insert(tty) } else { anywhere = true }
        }
    }

    public func contains(_ tty: String) -> Bool { anywhere || ttys.contains(tty) }
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
    /// When the process table the last scan found its sessions in was read (that scan's time); nil until one was.
    /// A scan whose table couldn't be read hands on the sessions found then, so a session missing from them had no
    /// agent at this time, not now.
    public private(set) var readAt: Date?
    /// The terminals that table couldn't tell an agent on or not (see `Undecided`).
    public private(set) var undecided = Undecided()

    private let processes: () -> [Int32: ProcInfo]?
    private let stateDir: () -> URL
    private let cwd: (Int32) -> String?
    private let arguments: (ProcInfo) -> [String]

    /// The defaults read this Mac; tests pass a fake process table and their own state folder.
    public init(processes: @escaping () -> [Int32: ProcInfo]? = { ProcessTable.trySnapshot() },
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

        let undecided = Undecided(procs)
        let hooks = loadHookStates(liveTTYs: Set(byTTY.keys), undecided: undecided, now: now)
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
        // A session whose agent couldn't be told this time (mid-exec on a busy Mac) is as it was: not ended, and not
        // another agent's.
        let found = Set(sessions.map(\.tty))
        sessions += last.filter { !found.contains($0.tty) && procs[$0.pid]?.identityUnknown == true }
        let live = { (key: ProcessKey) in procs[key.pid]?.startTime == key.start || procs[key.pid]?.identityUnknown == true }
        cwdCache = cwdCache.filter { live($0.key) }
        projectCache = projectCache.filter { live($0.key) }
        last = sessions
        readAt = now
        self.undecided = undecided
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

    /// Reads `~/.vibeswitcher/state/*.json`, deleting files for terminals that no longer run an agent (not those where
    /// whether one runs is `undecided`).
    private func loadHookStates(liveTTYs: Set<String>, undecided: Undecided, now: Date) -> [String: HookState] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: stateDir(),
                                                      includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [:] }
        var states: [String: HookState] = [:]
        for file in files where file.pathExtension == "json" {
            let tty = file.deletingPathExtension().lastPathComponent
            if !liveTTYs.contains(tty) {
                guard !undecided.contains(tty) else { continue }
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

/// What says Terminal.app's tabs may have changed, known without asking Terminal: which agents run in it (the process
/// table), what their hooks say, and whether Terminal is the active app and which of its windows is in front (a tab
/// picked there is another window in front).
public struct TerminalSignal: Equatable, Sendable {
    private struct Mark: Equatable, Sendable {
        let pid: Int32
        let startedAt: Date
        /// The status the hook gives (not its every event: a busy session writes several a second).
        let status: SessionStatus?
    }

    private var sessions: [String: Mark] = [:]
    private var terminalActive = false
    private var frontWindow: Int?

    public init() {}

    /// `frontWindow`: the window in front while Terminal is active.
    public init(sessions: [RawSession], terminalActive: Bool, frontWindow: Int?) {
        for session in sessions where session.inTerminalApp {
            self.sessions[session.tty] = Mark(pid: session.pid, startedAt: session.startedAt,
                                              status: session.hook.map { StatusRules.status(for: $0) })
        }
        self.terminalActive = terminalActive
        self.frontWindow = terminalActive ? frontWindow : nil
    }
}

/// When the scan asks Terminal.app for its tabs and screens, and what it keeps when an answer doesn't come.
///
/// Each read makes Terminal answer Apple Events, so Terminal is only asked while a session runs in it (window sessions
/// and other terminal apps don't need it), and then when the `TerminalSignal` changes, else every `fallback` seconds.
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

    /// With nothing changed, the tabs are still read this often: a hook-less session's title, a tab moved or renamed.
    public static var fallback: TimeInterval { 20 }
    /// Screen text is only needed for Claude's footer and is the most expensive read, so it's read less often.
    public static var screensInterval: TimeInterval { 60 }
    /// A change this soon after a read waits for a scan past it: hooks of a busy session change several times a second.
    public static var minimumGap: TimeInterval { 1.5 }

    /// Terminal's tabs by tty, as last read.
    public private(set) var tabs: [String: Tab] = [:]
    /// Background work in Claude's footer by tty (see `BackgroundWork`), as last read.
    public private(set) var backgroundWork: [String: String] = [:]
    private var lastTabsRead = Date.distantPast
    private var lastScreensRead = Date.distantPast
    /// The signal at the last tabs read, and the quiet sessions at the last screens read.
    private var lastSignal: TerminalSignal?
    private var lastQuiet: Set<String>?

    public init() {}

    /// Reads Terminal if `signal` changed since the last read, `interval` has passed, or `force`. `terminalTTYs`: the
    /// sessions running in Terminal.app (see `RawSession.inTerminalApp`); with none, nothing is read. `quiet`: Claude
    /// sessions whose turn looks over, whose footers are read for background work (again whenever they change).
    /// Returns the read, when one was made.
    @discardableResult
    public mutating func poll(now: Date, interval: TimeInterval = fallback, terminalTTYs: Set<String>, quiet: Set<String>,
                              signal: TerminalSignal = TerminalSignal(), force: Bool, bridge: Bridge) -> TerminalRead<Tab>? {
        guard !terminalTTYs.isEmpty else {
            tabs = [:]
            backgroundWork = [:]
            lastSignal = nil
            lastQuiet = nil
            return nil
        }
        let sinceTabs = now.timeIntervalSince(lastTabsRead)
        let changed = signal != lastSignal && sinceTabs >= Self.minimumGap - 0.05
        var read: TerminalRead<Tab>?
        if force || changed || sinceTabs >= interval - 0.05 {
            lastTabsRead = now
            lastSignal = signal
            let fresh = bridge.tabs()
            switch fresh {
            case .tabs(let fresh): tabs = fresh
            // A terminal can have changed hands since (closed tab, its tty reused by a window session).
            case .failed: tabs = tabs.filter { terminalTTYs.contains($0.key) }
            case .denied, .notRunning: tabs = [:]
            }
            read = fresh
        }
        let quiet = quiet.intersection(terminalTTYs)
        if force || changed || quiet != lastQuiet || now.timeIntervalSince(lastScreensRead) >= Self.screensInterval - 0.05 {
            if let screens = bridge.screens(quiet) {
                backgroundWork = screens.compactMapValues { BackgroundWork.summary(fromScreen: $0) }
            } else {
                backgroundWork = backgroundWork.filter { quiet.contains($0.key) }
            }
            lastScreensRead = now
            lastQuiet = quiet
        }
        return read
    }
}
