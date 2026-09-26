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
}

public final class SessionScanner {
    private var cwdCache: [Int32: String] = [:]
    private var projectCache: [Int32: (workingDirectory: String?, root: String)] = [:]
    /// Decoded state files by path, re-read only when their modification date changes.
    private var stateCache: [String: (modified: Date, state: HookState)] = [:]

    public init() {}

    /// Finds every `claude`/`codex` process attached to a terminal, one session per TTY.
    public func scan(now: Date = Date()) -> [RawSession] {
        let procs = ProcessTable.snapshot()
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
            let launchDirectory = cachedCwd(root.pid)
            let cwd = hook?.cwd ?? launchDirectory
            let projectRoot = cachedProjectRoot(root.pid, launchDirectory: launchDirectory ?? cwd, workingDirectory: hook?.cwd)
            sessions.append(RawSession(tty: tty, agent: agent, pid: root.pid, startedAt: root.startTime,
                                       cwd: cwd, project: projectRoot.map { SessionNaming.name(forProjectRoot: $0) } ?? "?",
                                       projectRoot: projectRoot, hook: hook,
                                       backgroundJobs: agent == .claude ? BackgroundJobs.jobs(forAgent: root.pid, in: procs) {
                                           ProcessTable.arguments(pid: $0.pid, start: Int($0.startTime.timeIntervalSince1970))
                                       } : []))
        }
        cwdCache = cwdCache.filter { procs[$0.key] != nil }
        projectCache = projectCache.filter { procs[$0.key] != nil }
        return sessions
    }

    /// A state file belongs to the running session unless it was written by another (older) process on the same TTY.
    private func isCurrent(_ state: HookState, agent: Agent, root: ProcInfo, procs: [ProcInfo]) -> Bool {
        if state.agent != agent { return false }
        if state.lastEventAt < root.startTime.timeIntervalSince1970 - 2 { return false }
        if let pid = state.agentPid, !procs.contains(where: { $0.pid == pid }) { return false }
        return true
    }

    /// The agent's own cwd is where it was launched (its tools `cd` in subprocesses), so it is stable;
    /// the working directory only matters when that isn't a repo.
    private func cachedProjectRoot(_ pid: Int32, launchDirectory: String?, workingDirectory: String?) -> String? {
        if let cached = projectCache[pid], cached.workingDirectory == workingDirectory { return cached.root }
        guard let launchDirectory else { return nil }
        let root = SessionNaming.projectRoot(launchDirectory: launchDirectory, workingDirectory: workingDirectory)
        projectCache[pid] = (workingDirectory, root)
        return root
    }

    private func cachedCwd(_ pid: Int32) -> String? {
        if let cached = cwdCache[pid] { return cached }
        let cwd = ProcessTable.cwd(pid: pid)
        cwdCache[pid] = cwd
        return cwd
    }

    /// Reads `~/.vibeswitcher/state/*.json`, deleting files for terminals that no longer run an agent.
    private func loadHookStates(liveTTYs: Set<String>, now: Date) -> [String: HookState] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: VibePaths.stateDir,
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
