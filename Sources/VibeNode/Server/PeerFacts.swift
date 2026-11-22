import Foundation
import VibeCore

/// What the server reads of the process that sent a request, for the user's voice (the security architecture
/// document's S3; `Voice.judge`): its cgroup, its ancestry, its controlling terminal, whether its environment carries a
/// session's marker, and whether a `BranchCode` runner is among its ancestors. Each read from `/proc` for each request,
/// and each `nil` (or `.unreadable`) when it can't be read: an unreadable field counts as "not the user's voice". A
/// non-dumpable peer's environment is root's to read, so such a peer is never the user.
public struct PeerFacts: Equatable, Sendable {
    /// One process of the peer's ancestry: the peer first, then its parent, up to the first process whose parent is 0
    /// or 1 (init is never listed).
    public struct Ancestor: Equatable, Sendable {
        public var pid: pid_t
        public var startTicks: UInt64
        public init(pid: pid_t, startTicks: UInt64) {
            self.pid = pid
            self.startTicks = startTicks
        }
    }

    /// The peer's controlling terminal.
    public enum Terminal: Equatable, Sendable {
        case none
        case named(String)
        case unreadable
    }

    public var pid: pid_t
    /// Its effective user; nil when it can't be read.
    public var uid: uid_t?
    /// Its `/proc/<pid>/cgroup` lines; nil when they can't be read.
    public var cgroup: [String]?
    /// Its ancestry, itself first; nil when a link can't be read.
    public var ancestry: [Ancestor]?
    public var terminal: Terminal
    /// Whether its environment holds `VIBESWITCHER_SESSION`; nil when it can't be read.
    public var sessionMarker: Bool?
    /// Whether it, or one of its ancestors, is a `BranchCode` runner; nil when one's arguments can't be read.
    public var underRunner: Bool?
    /// Its command line, for the accepted list (shown only through `ConfigSeal.inert`); empty when unreadable.
    public var commandLine: [String]

    public init(pid: pid_t, uid: uid_t?, cgroup: [String]?, ancestry: [Ancestor]?, terminal: Terminal, sessionMarker: Bool?,
                underRunner: Bool?, commandLine: [String] = []) {
        self.pid = pid
        self.uid = uid
        self.cgroup = cgroup
        self.ancestry = ancestry
        self.terminal = terminal
        self.sessionMarker = sessionMarker
        self.underRunner = underRunner
        self.commandLine = commandLine
    }

    /// The variable every session's program carries (`HostedSession.environment`).
    public static let sessionMarkerName = "VIBESWITCHER_SESSION"

    /// The longest ancestry read: past it, the chain counts as unreadable (a loop the reads made of reused pids).
    static let deepest = 256

    /// The process `pid` as it reads now (Linux: `/proc`; the Mac: `proc_pidinfo`'s links, each bound to the peer's
    /// audit token by Security's check after the read, `Platform.Processes.Link.isProcess(of:)`; its environment and
    /// cgroup unread there). `token`: the sender as the socket named it; when its
    /// pid now names another process (it ended and its number was given again), nothing is readable. `cgroupRoot`: a
    /// scratch server's test's (`ServerArguments.testCgroupRoot`), from which its cgroup lines are read (`rerooted`);
    /// nil, as the user's node's server always has it: the lines as `/proc` gives them. `runnersAbove`: the runners a
    /// scratch server's test runs under (`ServerArguments.testRunnerAbove`: the server's own, `runners(above:)`),
    /// which aren't counted as this process's; none, as the user's node's server always has it: every runner counts.
    public static func read(pid: pid_t, token: Platform.PeerToken? = nil, cgroupRoot: String? = nil, runnersAbove: [Ancestor] = []) -> PeerFacts {
        var uid: uid_t?
        if case .record(let record) = Platform.Processes.record(pid) { uid = record.uid }
        var ancestry: [Ancestor] = []
        var terminal = Terminal.unreadable
        var readable = true
        var next = pid
        while next > 1 {
            guard ancestry.count < deepest, let link = Platform.Processes.link(next) else {
                readable = false
                break
            }
            if next == pid {
                terminal = link.terminal.map(Terminal.named) ?? .none
                // The process its token named, not one given its pid since.
                if let token, !link.isProcess(of: token) { readable = false; break }
            }
            ancestry.append(Ancestor(pid: link.pid, startTicks: link.startTicks))
            next = link.parent
        }
        var underRunner: Bool? = false
        if readable {
            for ancestor in ancestry {
                switch runner(ancestor, peerUID: uid, arguments: Platform.Processes.arguments(ancestor.pid), runnersAbove: runnersAbove,
                              owner: { brief in if case .brief(let read) = Platform.Processes.brief(brief) { read.uid } else { nil } }) {
                case true?: underRunner = true
                case nil: underRunner = nil
                case false?: continue
                }
                break
            }
        } else {
            underRunner = nil
        }
        let environment = Platform.Processes.environment(pid)
        let cgroup = Platform.Processes.cgroup(pid).map { lines in cgroupRoot.map { rerooted(lines, at: $0) } ?? lines }
        return PeerFacts(pid: pid, uid: uid, cgroup: cgroup, ancestry: readable ? ancestry : nil,
                         terminal: readable ? terminal : .unreadable,
                         sessionMarker: environment.map { $0.contains { $0.hasPrefix(sessionMarkerName + "=") } },
                         underRunner: underRunner, commandLine: Platform.Processes.arguments(pid))
    }

    /// Whether `ancestor` is a branch code runner (`BranchCode.isRunner`) a sender runs under: true, false, or nil when
    /// that can't be told. Its arguments (`arguments`) tell; one above the whole scratch node (`runnersAbove`, by pid and
    /// start) doesn't count. Arguments that can't be read (the Mac refuses `KERN_PROCARGS2` for another user's process:
    /// root's `login` under Terminal, `sshd-session` under ssh; v2-mac-tasks item 11) tell nothing, unless its owner
    /// (`owner`, the short record any user's process gives) is root while the sender (`peerUID`) isn't: a runner is the
    /// user's own code, started as the user, and a process of root's is none (the runner, if any, is below it in the
    /// chain, the user's again, and read). Any other unreadable ancestor: nil, as before.
    static func runner(_ ancestor: Ancestor, peerUID: uid_t?, arguments: [String], runnersAbove: [Ancestor],
                       owner: (pid_t) -> uid_t?) -> Bool? {
        if arguments.isEmpty {
            guard let peerUID, peerUID != 0, owner(ancestor.pid) == 0 else { return nil }
            return false
        }
        return BranchCode.isRunner(arguments) && !runnersAbove.contains(ancestor)
    }

    /// The branch code runners `pid` runs under (`BranchCode.isRunner`), nearest first, each by its pid and its start:
    /// what a scratch server given `--test-runner-above` reads of itself, once, at its start. Its ancestors are read
    /// as a sender's are (itself first, up to init); where a link can't be read the walk ends there, with the runners
    /// found so far, and one whose arguments can't be read isn't one: fewer runners here is more senders refused.
    public static func runners(above pid: pid_t) -> [Ancestor] {
        var runners: [Ancestor] = []
        var next = pid
        var steps = 0
        while next > 1, steps < deepest, let link = Platform.Processes.link(next) {
            if BranchCode.isRunner(Platform.Processes.arguments(link.pid)) { runners.append(Ancestor(pid: link.pid, startTicks: link.startTicks)) }
            next = link.parent
            steps += 1
        }
        return runners
    }

    /// Whether `path` can be a test's cgroup root: a cgroup's path as the kernel writes one, below the hierarchy's root
    /// (absolute, not `/` itself, no empty, `.` or `..` component, so no `/` at its end).
    public static func isCgroupRoot(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/" else { return false }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// `lines` (a `/proc/<pid>/cgroup`'s) as a process in a cgroup namespace rooted at `root` would read them: in each
    /// hierarchy's line a path that is `root` reads `/`, and a path under it (by whole components: `root` and then a
    /// `/`) reads from there. Every other path stays as it is, so a process outside `root` is where the machine says
    /// it is, and a root that isn't one (`isCgroupRoot`) changes nothing. Only a scratch server's test gives a root
    /// (`ServerArguments.testCgroupRoot`).
    public static func rerooted(_ lines: [String], at root: String) -> [String] {
        guard isCgroupRoot(root) else { return lines }
        return lines.map { line in
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return line }
            let path = parts[2]
            if path == root { return "\(parts[0]):\(parts[1]):/" }
            if path.hasPrefix(root + "/") { return "\(parts[0]):\(parts[1]):\(path.dropFirst(root.count))" }
            return line
        }
    }

    /// The path of the unified hierarchy (`0::PATH`) in `lines`; nil without one.
    public static func unifiedPath(_ lines: [String]) -> String? {
        lines.first { $0.hasPrefix("0::") }.map { String($0.dropFirst(3)) }
    }

    /// The path of systemd's v1 hierarchy (`N:name=systemd:PATH`) in `lines`; nil without one.
    public static func systemdPath(_ lines: [String]) -> String? {
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3, parts[1] == "name=systemd" { return String(parts[2]) }
        }
        return nil
    }
}
