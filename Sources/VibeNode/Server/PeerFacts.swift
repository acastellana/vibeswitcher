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

    /// The process `pid` as it reads now (Linux: `/proc`; the Mac reads no links, so every field there is unreadable
    /// and no peer is the user, which only Linux's server asks). `token`: the sender as the socket named it; when its
    /// pid now names another process (it ended and its number was given again), nothing is readable.
    public static func read(pid: pid_t, token: Platform.PeerToken? = nil) -> PeerFacts {
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
                let arguments = Platform.Processes.arguments(ancestor.pid)
                guard !arguments.isEmpty else { underRunner = nil; break }
                if BranchCode.isRunner(arguments) { underRunner = true; break }
            }
        } else {
            underRunner = nil
        }
        let environment = Platform.Processes.environment(pid)
        return PeerFacts(pid: pid, uid: uid, cgroup: Platform.Processes.cgroup(pid), ancestry: readable ? ancestry : nil,
                         terminal: readable ? terminal : .unreadable,
                         sessionMarker: environment.map { $0.contains { $0.hasPrefix(sessionMarkerName + "=") } },
                         underRunner: underRunner, commandLine: Platform.Processes.arguments(pid))
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
