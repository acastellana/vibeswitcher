import Foundation
import VibeCore

/// The command line's check of the server it reached (the engine plan's EN-D8, the security architecture document's
/// S3), as pure rules; `vibeswitcher-cli`'s `ServerCheck` reads the facts. Two forms:
/// - **The user's node**: the listener is non-dumpable, in the node unit's cgroup, and a child of the unit's `MainPID`
///   in that process's POSIX session.
/// - **A scratch node** (`VIBESWITCHER_HOME` set, resolving to a folder other than the account's own
///   `~/.vibeswitcher`, the home from `getpwuid`): non-dumpable, and a child of the process holding
///   `<root>/scratch-host.lock` (`Platform.Processes.lockHolder(path:)`) in that process's session. Every command then
///   says "scratch node at <root>" on stderr.
/// The session tells the server child from a session's program, which is a child of the host too: any process can make
/// itself non-dumpable (`PR_SET_DUMPABLE`), but the host starts each session's program in a session of its own
/// (`PTYSpawn`, `setsid`) and its server child in its own (`ServerChild`, a group of its own only), and a session
/// leader can never leave its session. So a session's program a worker ptraced or replaced, made non-dumpable and
/// listening, still fails (the security architecture document's S3).
/// `VIBESWITCHER_HOME` naming the account's own folder gets the user's node's check. No flag or pid is passed.
/// - **A node started detached** (the start plan's S3, ST-D6: the user's node on a machine whose pid 1 isn't systemd):
///   non-dumpable, a child of the host its record (`NodeRecord`, `<root>/v2/node.pid`) names, in that process's
///   session, with no cgroup line read. The record is honoured only while what it names is that host
///   (`recordedHost`): started at the recorded tick, with the installed host's command line, non-dumpable, and holding
///   the account's host lock (the one fact a process can't give itself while the host runs).
public enum NodeCheck {
    public enum Mode: Equatable, Sendable {
        case node
        case scratch(root: String)
        /// The user's node started detached, and its record when one could be read (S3).
        case detached(record: NodeRecord?)
    }

    /// A scratch host's lock in its root (`ScratchNode`'s `--lock`).
    public static let scratchLock = "scratch-host.lock"

    /// Which check: a scratch node when `vibeswitcherHome` is an absolute folder other than `accountHome`'s
    /// `.vibeswitcher` and the node's root (`NodeFolders.isUsersRoot`: however spelled, links resolved), the user's
    /// node otherwise.
    public static func mode(vibeswitcherHome: String?, accountHome: String) -> Mode {
        guard let home = vibeswitcherHome, home.hasPrefix("/") else { return .node }
        let root = URL(fileURLWithPath: home, isDirectory: true)
        return NodeFolders.isUsersRoot(root, accountHome: accountHome) ? .node : .scratch(root: root.standardizedFileURL.path)
    }

    /// The root the command line reads and connects under for `mode` (its socket, record, test folder): a scratch
    /// node's is the environment's (`environmentRoot`, `VibePaths.root`, which `VIBESWITCHER_HOME` names); the user's
    /// node's, started by the unit or detached, is always the account's (`NodeFolders.nodeRoot`, the home from the user
    /// database), where its host (`--node`, HOME from `getpwuid`) listens and records, whatever this process's `HOME`
    /// or `CFFIXED_USER_HOME` say (the start plan's Global Constraints: no environment variable moves these; the step 8
    /// sweep, 2026-11-17).
    public static func root(of mode: Mode, environmentRoot: String, accountHome: String) -> String {
        switch mode {
        case .scratch: return environmentRoot
        case .node, .detached: return NodeFolders.nodeRoot(accountHome: accountHome)
        }
    }

    /// The listening process as the command line read it.
    public struct Listener: Equatable, Sendable {
        public var pid: pid_t
        /// nil: can't be told.
        public var dumpable: Bool?
        public var parent: pid_t?
        /// Its cgroup lines; nil when unreadable.
        public var cgroup: [String]?
        /// Its POSIX session's id (`getsid`); nil when it can't be read.
        public var session: pid_t?
        /// The Mac's check in place of `dumpable` (which the Mac can't tell): whether the process its audit token names
        /// runs the installed build's server code (its cdhash, Security's dynamic check) with the Hardened Runtime; nil
        /// when it can't be told.
        public var code: Bool?
        /// Why `code` is false or nil, when the check said (the node's record refused, or the code it names no build).
        public var codeWhy: String?

        public init(pid: pid_t, dumpable: Bool?, parent: pid_t?, cgroup: [String]?, session: pid_t?, code: Bool? = nil) {
            self.pid = pid
            self.dumpable = dumpable
            self.parent = parent
            self.cgroup = cgroup
            self.session = session
            self.code = code
        }
    }

    /// Why the listener isn't the node's server, or nil when it passes. `expectedParent`: the unit's `MainPID` (the
    /// user's node) or the scratch lock's holder; nil when it couldn't be read, which fails. `parentSession`: that
    /// process's session (`getsid`); nil when it couldn't be read, which fails too.
    /// How long the command line looks again for a lock's holder before it says none holds it
    /// (`Platform.Processes.lockHolder(path:exclusiveFlock:patience:)`: one look at /proc/locks can miss a held lock).
    public static let lockPatience: TimeInterval = 3

    /// The server beside an installed build's host (the Mac's server check took it before the node's record; nothing
    /// chooses the server by it now), `<prefix>/<build>/bin/vibeswitcher-server`
    /// for the host `<prefix>/<build>/bin/vibeswitcher-host` (both paths resolved); nil for a host anywhere else.
    public static func installedServer(host: String, prefix: String) -> String? {
        let parts = host.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let base = prefix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == base.count + 3, Array(parts.prefix(base.count)) == base, prefix.hasPrefix("/"),
              parts[base.count] != "", parts[base.count] != ".", parts[base.count] != "..", parts[base.count] != SwitchFollowUp.currentLink,
              parts[base.count + 1] == "bin", parts[base.count + 2] == BuildInfo.host else { return nil }
        return (parts.dropLast() + [BuildInfo.server]).joined(separator: "/")
    }

    /// The Mac's answer about the listener's code (`macServerCode`).
    public enum MacCode: Equatable, Sendable {
        /// A server of an installed build, with the Hardened Runtime.
        case runs
        /// Not: why.
        case other(String)
        /// Can't be told: why.
        case unknown(String)

        /// As `Listener.code` holds it.
        public var told: Bool? {
            switch self {
            case .runs: return true
            case .other: return false
            case .unknown: return nil
            }
        }

        /// Why it isn't `.runs`.
        public var why: String? {
            switch self {
            case .runs: return nil
            case .other(let why), .unknown(let why): return why
            }
        }
    }

    /// The Mac: whether the process `token` names runs an installed build's server with the Hardened Runtime (the node on
    /// the Mac's design, "The anchor", check 1): its running code, by Security's dynamic check of the token (`runs`), must
    /// be the server of a build the node's record pins (`pins`, `NodePins.read`: root's to write, never the user's), and
    /// hardened (`hardened`). No path under the home chooses the build: not the builds folder, not the job's program
    /// (`job`, as `launchctl print` names it after a plist anyone of the user's can bootstrap; item 12: after an
    /// in-place switch it names the next build while this one's server still runs). `job` and `prefix` are taken so a
    /// caller's and a test's facts are the same; they choose nothing. A record that can't be taken: can't be told, why
    /// said. Every reader is a parameter, the system's by default.
    public static func macServerCode(token: Platform.PeerToken, job: NodeAgent.Printed?, prefix: String?,
                                     pins: Result<NodePins, NodePins.Refused>,
                                     runs: (Platform.PeerToken, Data) -> Bool = { Platform.CodeIdentity.runs($0, cdhash: $1) },
                                     hardened: (Platform.PeerToken) -> Bool? = Platform.CodeIdentity.isHardened) -> MacCode {
        let record: NodePins
        switch pins {
        case .failure(let why): return .unknown(why.description)
        case .success(let read): record = read
        }
        guard record.builds.contains(where: { runs(token, $0.server) }) else {
            return .other("it runs no server the node's record pins: not an installed build's server")
        }
        return hardened(token) == true ? .runs : .other("it doesn't run with the Hardened Runtime")
    }

    /// `path` with its links resolved (`realpath`); nil when it can't be.
    public static func resolved(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    /// `codeIdentity`: the Mac's form (`Platform.CodeIdentity.isAvailable`): the listener's code (`Listener.code`) in
    /// place of its dumpable state, and no cgroup (the Mac has none: the parent and the session hold it to the host).
    public static func refusal(_ listener: Listener, mode: Mode, expectedParent: pid_t?, parentSession: pid_t?,
                               codeIdentity: Bool = false) -> String? {
        if codeIdentity {
            switch listener.code {
            case true?: break
            case false?: return "the process listening on the server's socket (pid \(listener.pid)) doesn't run the installed build's server code with the Hardened Runtime: not the node's server"
                + (listener.codeWhy.map { " (\($0))" } ?? "")
            case nil: return "whether the process listening on the server's socket (pid \(listener.pid)) runs the installed build's server code can't be told"
                + (listener.codeWhy.map { ": \($0)" } ?? "")
            }
        } else {
            switch listener.dumpable {
            case true?: return "the process listening on the server's socket (pid \(listener.pid)) is dumpable: not the node's server"
            case nil: return "whether the process listening on the server's socket (pid \(listener.pid)) is dumpable can't be told"
            case false?: break
            }
        }
        if mode == .node, !codeIdentity {
            let path = listener.cgroup.flatMap { PeerFacts.unifiedPath($0) ?? PeerFacts.systemdPath($0) }
            guard let path, path.split(separator: "/").last.map(String.init) == VoiceRule.nodeUnit else {
                // The cgroup's name is the listener's to choose (any process of the user's can make one under its
                // manager): shown inert.
                return "the process listening on the server's socket (pid \(listener.pid)) isn't in \(VoiceRule.nodeUnit) (its cgroup is \(path.map { ConfigSeal.inert($0, limit: .max) } ?? "unreadable"))"
            }
        }
        guard let expectedParent else {
            switch mode {
            case .node: return "the node's unit has no main process to check the server against"
            case .scratch: return "no process holds the scratch node's lock, so the server can't be checked against its host"
            case .detached: return "the node's record names no host to check the server against"
            }
        }
        guard let parent = listener.parent, parent == expectedParent else {
            return "the process listening on the server's socket (pid \(listener.pid)) isn't a child of the node's host (pid \(expectedParent))"
        }
        guard let session = listener.session, let parentSession, session == parentSession else {
            return "the process listening on the server's socket (pid \(listener.pid)) isn't in the node's host's session "
                + "(\(listener.session.map(String.init) ?? "unreadable"), the host's \(parentSession.map(String.init) ?? "unreadable")): "
                + "a session's program, not the node's server"
        }
        return nil
    }

    /// The process `pid` as the command line reads it (`ServerCheck`): whether it is dumpable, its parent, its cgroup
    /// lines and its session.
    public static func listener(pid: pid_t, patience: TimeInterval = dumpablePatience) -> Listener {
        let session = getsid(pid)
        return Listener(pid: pid, dumpable: dumpable(pid, patience: patience), parent: Platform.Processes.link(pid)?.parent,
                        cgroup: Platform.Processes.cgroup(pid), session: session > 0 ? session : nil)
    }

    /// How long the command line reads the listener's dumpable state again while it can't be told
    /// (`Platform.Processes.isDumpable` nil: one of its /proc reads didn't answer). On a loaded CI runner one look came back
    /// unreadable and `settings --find` was refused (exit 77, 2026-11-22); a live server's state is there a moment later.
    public static let dumpablePatience: TimeInterval = 3

    /// The listener's dumpable state, read again every 50 ms while it can't be told, for at most `patience`; a process
    /// that has gone stays unreadable (nil), and is refused as before.
    static func dumpable(_ pid: pid_t, patience: TimeInterval, read: (pid_t) -> Bool? = Platform.Processes.isDumpable,
                         now: () -> Date = Date.init, wait: () -> Void = { usleep(50_000) }) -> Bool? {
        let deadline = now().addingTimeInterval(patience)
        while true {
            if let told = read(pid) { return told }
            guard now() < deadline, kill(pid, 0) == 0 || errno == EPERM else { return nil }
            wait()
        }
    }

    /// The Mac's listener (the review of 2026-11-21), every fact bound to the one audit token the socket gave
    /// (`token`): its pid must be `pid` (the peer the socket named), its link read (`link`), then its session
    /// (`session`) and its code (`code`, by the token), then its link read again, which must be the same process
    /// (pid, parent, start) and still the token's (`bound`: `Link.isProcess(of:)`, Security's check that the token's
    /// process lives unchanged, asked after every read). A pid given to another process between the reads fails it:
    /// parent and session are then unreadable, and the check refuses.
    public static func macListener(pid: pid_t, token: Platform.PeerToken?,
                                   link: (pid_t) -> Platform.Processes.Link? = Platform.Processes.link,
                                   session: (pid_t) -> pid_t? = { let s = getsid($0); return s > 0 ? s : nil },
                                   code: (Platform.PeerToken) -> Bool?,
                                   bound: (Platform.Processes.Link, Platform.PeerToken) -> Bool = { $0.isProcess(of: $1) }) -> Listener {
        var listener = Listener(pid: pid, dumpable: nil, parent: nil, cgroup: nil, session: nil, code: nil)
        guard let token, token.pid == pid, let first = link(pid) else { return listener }
        let read = session(pid)
        let runs = code(token)
        guard let again = link(pid), again == first, bound(again, token) else { return listener }
        listener.parent = first.parent
        listener.session = read
        listener.code = runs
        return listener
    }

    /// What a detached node's record names (S3).
    public enum Recorded: Equatable, Sendable {
        /// The node's host, by its pid.
        case host(pid_t)
        /// No host: no record, or the process it names has ended (the node isn't running). Why, said.
        case none(String)
        /// A process that isn't the node's host (another one given the number since, another command line, or a
        /// dumpable one). Why, said: nothing is checked against it or signalled.
        case other(String)
    }

    /// The host `record` names, or why it isn't one: the process must still run from the recorded tick (`startTicks`:
    /// nil when it has gone or is a zombie), its command line (`arguments`) must be the installed host's (`isHost`;
    /// the command line passes `isInstalledHost`, a test its scratch host's), it must be non-dumpable (`dumpable`), and
    /// it must hold the host's lock (`lock`, the account's `~/.vibeswitcher/host.lock`, a test its scratch host's), by
    /// an exclusive `flock` on the file the path names (`holder`, `/proc/locks` by inode). Every reader is a parameter,
    /// the system's by default.
    ///
    /// The tick, the command line and the dumpable flag are each the process's own to set: a worker's program run as
    /// `exec -a <prefix>/<commit>/bin/vibeswitcher-host … --node --node-root …` that makes itself non-dumpable, named
    /// in a record the worker wrote, passes all three (the step 8 sweep). The lock it can't hold while the host does,
    /// and the host takes back a lock path a file was renamed over (`HostPathWatch`). So they are hints; the lock decides.
    /// Not held (the security follow-ups' item 33, open): while no host runs, a worker's process holding a file it put at
    /// the lock's path passes. What would tie the candidate to the build (`/proc/<pid>/exe`, its `fd` and `fdinfo`) the
    /// kernel refuses to the same uid for a non-dumpable process (measured 2026-11-17), and the candidate must be one.
    public static func recordedHost(_ record: NodeRecord?, isHost: ([String]) -> Bool, lock: String,
                                    startTicks: (pid_t) -> UInt64? = NodeRecord.liveTicks,
                                    arguments: (pid_t) -> [String] = Platform.Processes.arguments,
                                    dumpable: (pid_t) -> Bool? = Platform.Processes.isDumpable,
                                    holder: (String) -> pid_t? = { Platform.Processes.lockHolder(path: $0, exclusiveFlock: true, patience: NodeCheck.lockPatience) })
        -> Recorded {
        guard let record else { return .none("no host is recorded") }
        let pid = record.pid
        guard let ticks = startTicks(pid) else { return .none("the recorded host (pid \(pid)) has ended") }
        guard ticks == record.startTicks else {
            return .other("the recorded pid now names another process (pid \(pid) started at tick \(ticks), the record says \(record.startTicks))")
        }
        let words = arguments(pid)
        guard isHost(words) else {
            return .other("the recorded pid now names another process (pid \(pid) runs \(ConfigSeal.inert(words.joined(separator: " "), limit: 512)), not the installed host)")
        }
        switch dumpable(pid) {
        case false?: break
        case true?: return .other("the recorded host (pid \(pid)) is dumpable: not the node's host")
        case nil: return .other("whether the recorded host (pid \(pid)) is dumpable can't be told")
        }
        guard holder(lock) == pid else {
            return .other("the recorded pid \(pid) doesn't hold the host's lock (\(ConfigSeal.inert(lock, limit: .max))): not the node's host")
        }
        return .host(pid)
    }

    /// Whether `arguments` (a process's command line) are the installed host's (ST-D7): argv[0]
    /// `<prefix>/<40 hex>/bin/vibeswitcher-host`, argv[1] `--node`, and exactly one `--node-root`, wherever it comes,
    /// naming that same `<prefix>/<commit>` (`--handover-fallback-node-root` is another word). The unit's start has it
    /// at argv[2]; after a handover (S8) the new image's argv holds the handover's flags first and its build's
    /// `--node-root` near the end (`HandoverMemory`'s `folderArguments`), and a fallback's its own back at the end (the
    /// review of S3: ST-D7's literal `--node --node-root` would refuse a detached host once it has switched builds).
    public static func isInstalledHost(_ arguments: [String], prefix: String) -> Bool {
        let top = prefix.hasSuffix("/") && prefix.count > 1 ? String(prefix.dropLast()) : prefix
        guard arguments.count >= 4, arguments[1] == "--node" else { return false }
        let roots = arguments.indices.dropFirst(2).filter { arguments[$0] == "--node-root" }
        guard roots.count == 1, let at = roots.first, at + 1 < arguments.count else { return false }
        let folder = arguments[at + 1]
        guard folder.hasPrefix(top + "/") else { return false }
        let commit = String(folder.dropFirst(top.count + 1))
        return NodeUnit.isCommit(commit) && arguments[0] == folder + "/bin/vibeswitcher-host"
    }
}
