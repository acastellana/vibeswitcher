import Darwin
import Foundation

/// What a session's agent started that would outlive it: a Bash-tool command in a process group of its own, a
/// `run_in_background` server, a setsid'd child that launchd took over. Two ways to know one, and nothing else: it
/// carries the session's `VIBESWITCHER_SESSION=<id>` (every session's program has it, see `HostedSession.environment`,
/// and what it starts inherits it), or, when a worktree is removed, its working folder is inside that worktree. Only
/// the user's own processes, never this one or what runs it.
/// Apple's own programs (perl, zsh, sleep…) hide their environment from every other process, the user's too: one of
/// those is the session's when it descends from the session's program (`of(session:started:)`).
public enum SessionStrays {
    /// A process found, and when it started: a pid reused meanwhile is someone else's.
    public struct Found: Equatable, Sendable {
        public var pid: pid_t
        public var group: pid_t
        public var start: UInt64
    }

    /// The user's processes carrying `VIBESWITCHER_SESSION=<id>`.
    public static func carrying(session id: UUID, user: uid_t = geteuid()) -> [Found] {
        let entry = "VIBESWITCHER_SESSION=" + id.uuidString
        return processes(user: user) { ProcessTable.environment(pid: $0)?.contains(entry) == true }
    }

    /// The session's processes: those carrying its id, and those of `started` (what its program started, see
    /// `descendants`) still running whose environment can't be read. One whose environment names another session, or
    /// none, isn't.
    public static func of(session id: UUID, started: [Found], user: uid_t = geteuid()) -> [Found] {
        let carrying = carrying(session: id, user: user)
        let known = Set(carrying.map(\.pid))
        return carrying + started.filter { found in
            !known.contains(found.pid) && isRunning(found) && ProcessTable.environment(pid: found.pid)?.isEmpty != false
        }
    }

    /// Ends the session's processes (`of(session:started:)`) but those in `groups` (signalled by the caller): SIGTERM,
    /// then SIGKILL after `grace` to whatever of the session's still runs. On a thread of its own, not a dispatch
    /// queue's: on a busy Mac every thread of the global queues can be taken, and the ending would wait for one.
    public static func end(session id: UUID, started: [Found], sparing groups: Set<pid_t> = [], grace: TimeInterval = 5) {
        let thread = Thread {
            let begun = Date()
            for stray in of(session: id, started: started) where !groups.contains(stray.group) { kill(stray.pid, SIGTERM) }
            Thread.sleep(until: begun.addingTimeInterval(grace))
            of(session: id, started: started).forEach { kill($0.pid, SIGKILL) }
        }
        thread.name = "SessionStrays.end"
        thread.start()
    }

    /// What `pid` started that runs now, their children too, the user's only: to be found before it's asked to end
    /// (once it ended they're launchd's, as anyone's are).
    public static func descendants(of pid: pid_t, user: uid_t = geteuid()) -> [Found] {
        var found: [Found] = [], next = [pid], seen: Set<pid_t> = [pid]
        while let parent = next.popLast() {
            for child in children(of: parent) where seen.insert(child).inserted {
                guard let record = record(child), record.uid == user else { continue }
                found.append(Found(pid: child, group: record.group, start: record.start))
                next.append(child)
            }
        }
        return found
    }

    /// The processes `pid` started that run now.
    public static func children(of pid: pid_t) -> [pid_t] {
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 16)
        let listed = pids.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(0, listed)))).filter { $0 > 0 }
    }

    /// The user's processes whose working folder is `folder` or inside it.
    public static func inside(folder: String, user: uid_t = geteuid()) -> [Found] {
        let folder = resolved(folder)
        return processes(user: user) { ProcessTable.cwd(pid: $0).map { isInside($0, folder: folder) } ?? false }
    }

    /// Ends what's inside `folder` before it's removed: SIGTERM, then SIGKILL to whichever is still the same process
    /// after `grace`. Waits at most that long, less when they're gone sooner. The ones found.
    @discardableResult
    public static func endInside(folder: String, grace: TimeInterval = 5) -> [Found] {
        let found = inside(folder: folder)
        guard !found.isEmpty else { return [] }
        found.forEach { kill($0.pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        var running = found
        while true {
            running = running.filter(isRunning)
            guard !running.isEmpty, Date() < deadline else { break }
            usleep(50_000)
        }
        running.forEach { kill($0.pid, SIGKILL) }
        return found
    }

    /// Whether the process found still runs (not one that took its pid since).
    public static func isRunning(_ found: Found) -> Bool { record(found.pid)?.start == found.start }

    /// `path` is `folder` or under it, both resolved.
    static func isInside(_ path: String, folder: String) -> Bool {
        let folder = folder.hasSuffix("/") && folder.count > 1 ? String(folder.dropLast()) : folder
        return path == folder || path.hasPrefix(folder + "/")
    }

    /// Symlinks resolved (/tmp is /private/tmp), as the kernel reports a working folder.
    static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(real) }
        return String(cString: real)
    }

    /// The user's processes `matches` says yes to, leaving out this process and its ancestors.
    private static func processes(user: uid_t, matching matches: (pid_t) -> Bool) -> [Found] {
        let spared = Set([getpid()] + ProcessTable.ancestors(of: getpid()).map(\.pid))
        return (ProcessTable.allPids() ?? []).compactMap { pid in
            guard pid > 1, !spared.contains(pid), let found = record(pid), found.uid == user, matches(pid) else { return nil }
            return Found(pid: pid, group: found.group, start: found.start)
        }
    }

    private static func record(_ pid: pid_t) -> (uid: uid_t, group: pid_t, start: UInt64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != SZOMB else { return nil }
        return (info.pbi_uid, pid_t(info.pbi_pgid), info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }
}
