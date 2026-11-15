import Foundation
import VibeCore

/// Whose voice a request is: the user's, or not, and why (the security architecture document's S3, the engine plan's
/// "The user's voice"). `judge` is a pure function of what was read of the sender (`PeerFacts`), the live sessions
/// (`LiveSessions`, from `HostLink`'s list) and the rule fixed at the server's start (`VoiceRule`).
public enum Voice: Equatable, Sendable {
    case user
    case notUser(String)

    /// The user's voice is a peer of the server's uid
    /// - whose cgroup (the `0::` line and, on a hybrid layout, the `name=systemd` line: each there must pass) is
    ///   outside `user@<uid>.service` and outside the node's unit, and is one of the rule's scopes (the systemd rule
    ///   only; the weaker rule has no cgroup to tell by);
    /// - whose ancestry holds no live session's program, not the host and not the server (a parser is the host's
    ///   child, so an ancestry under one holds the host);
    /// - whose controlling terminal is no live session's;
    /// - whose environment has no `VIBESWITCHER_SESSION`;
    /// - that isn't under a `BranchCode` runner.
    /// A field that can't be read fails the rule.
    public static func judge(_ facts: PeerFacts, live: LiveSessions, rule: VoiceRule) -> Voice {
        guard let uid = facts.uid else { return .notUser("its user can't be read") }
        guard uid == rule.uid else { return .notUser("it is another user's (uid \(uid))") }
        if rule.mode == .systemd {
            guard let lines = facts.cgroup else { return .notUser("its cgroup can't be read") }
            if let why = rule.cgroupRefusal(lines) { return .notUser(why) }
        }
        guard let ancestry = facts.ancestry else { return .notUser("its ancestry can't be read") }
        for ancestor in ancestry {
            if ancestor.pid == live.host { return .notUser("it runs under the session host (pid \(ancestor.pid))") }
            if ancestor.pid == live.server { return .notUser("it runs under the server (pid \(ancestor.pid))") }
            if live.programs.contains(ancestor.pid) { return .notUser("it runs under a live session's program (pid \(ancestor.pid))") }
        }
        switch facts.terminal {
        case .unreadable: return .notUser("its controlling terminal can't be read")
        case .named(let name) where live.terminals.contains(name): return .notUser("its terminal \(name) is a live session's")
        case .named, .none: break
        }
        guard let marker = facts.sessionMarker else { return .notUser("its environment can't be read") }
        guard !marker else { return .notUser("its environment carries \(PeerFacts.sessionMarkerName)") }
        guard let runner = facts.underRunner else { return .notUser("whether it runs under branch code can't be read") }
        guard !runner else { return .notUser("it runs under a branch code runner") }
        return .user
    }
}

/// The live sessions as the voice rule needs them: their programs (`HostSession.childPID`) and terminals, the host
/// and the server.
public struct LiveSessions: Equatable, Sendable {
    public var programs: Set<pid_t>
    public var terminals: Set<String>
    /// The session host (the server's parent).
    public var host: pid_t?
    /// The server itself.
    public var server: pid_t?

    public init(programs: Set<pid_t> = [], terminals: Set<String> = [], host: pid_t? = nil, server: pid_t? = nil) {
        self.programs = programs
        self.terminals = terminals
        self.host = host
        self.server = server
    }

    /// The live ones of `sessions` (`HostLink.sessions`), with `host` and `server`.
    public init(_ sessions: [HostSession], host: pid_t?, server: pid_t?) {
        let live = sessions.filter(\.isLive)
        self.init(programs: Set(live.map(\.childPID)), terminals: Set(live.map(\.tty)), host: host, server: server)
    }
}

/// The voice rule's mode, fixed once at the server's start from its own cgroup (`at(start:testScopes:uid:)`), never
/// from a file a worker could remove.
public struct VoiceRule: Equatable, Sendable {
    public enum Mode: String, Sendable {
        /// The cgroup rule: the server runs in the node's unit, under the user's systemd.
        case systemd
        /// No systemd to tell by: the other four lines only, and `status` says so.
        case weaker
    }

    /// A cgroup a user's terminal runs in: a path, `*` standing for one path component's characters (no `/`), `{uid}`
    /// for the user's id; and where the row comes from.
    public struct Scope: Equatable, Sendable {
        public var pattern: String
        /// "measured …", "documented …", or a scratch host's test's.
        public var basis: String

        public init(_ pattern: String, basis: String) {
            self.pattern = pattern
            self.basis = basis
        }

        /// Whether `path` is this scope for `uid`.
        public func matches(_ path: String, uid: uid_t) -> Bool {
            let wanted = Array(pattern.replacingOccurrences(of: "{uid}", with: String(uid)).utf8)
            let given = Array(path.utf8)
            // A glob with `*` inside one component.
            func match(_ w: Int, _ g: Int) -> Bool {
                if w == wanted.count { return g == given.count }
                if wanted[w] == UInt8(ascii: "*") {
                    var at = g
                    while true {
                        if match(w + 1, at) { return true }
                        guard at < given.count, given[at] != UInt8(ascii: "/") else { return false }
                        at += 1
                    }
                }
                return g < given.count && wanted[w] == given[g] && match(w + 1, g + 1)
            }
            return match(0, 0)
        }
    }

    /// The scopes a user's terminal runs in, as data (E1 Step 1, `docs/process/v2-linux-inventory.md`): the measured
    /// rows and the documented fixtures. A row the user's measurement (the bootstrap path's M4) finds is added here by
    /// one line, with a test in `VoiceRuleTests`. Anything else is refused.
    public static let terminalScopes: [Scope] = [
        Scope("/init.scope", basis: "measured 2026-11-15 on Linux 5.15.167.4-microsoft-standard-WSL2: the agent's Bash tool's child and the scratch host's children (WSL starts terminals there)"),
        Scope("/user.slice/user-{uid}.slice/session-*.scope", basis: "documented: a login over ssh (logind's session scope); not measured, no sshd here"),
    ]

    /// The node's unit (the bootstrap path's step 8).
    public static let nodeUnit = "vibeswitcher-node.service"

    public var mode: Mode
    public var scopes: [Scope]
    public var uid: uid_t
    /// Why this mode, for `status`.
    public var says: String

    public init(mode: Mode, scopes: [Scope], uid: uid_t, says: String) {
        self.mode = mode
        self.scopes = scopes
        self.uid = uid
        self.says = says
    }

    /// The rule, fixed once at the server's start from its own cgroup lines (`ownCgroup`): inside
    /// `…/user@<uid>.service/…/vibeswitcher-node.service`, the systemd rule with `terminalScopes`; given `testScopes`
    /// (a scratch host's `--server-arg --test-user-scopes=…`, never the user's server's), the cgroup rule with those;
    /// anything else, the weaker rule. No file decides it.
    public static func at(start ownCgroup: [String]?, testScopes: [String]?, uid: uid_t = getuid()) -> VoiceRule {
        if let testScopes {
            return VoiceRule(mode: .systemd, scopes: testScopes.map { Scope($0, basis: "a scratch host's test") }, uid: uid,
                             says: "the cgroup rule, on a scratch node's test scopes (\(testScopes.joined(separator: ", ")))")
        }
        let path = ownCgroup.flatMap { PeerFacts.unifiedPath($0) ?? PeerFacts.systemdPath($0) } ?? ""
        let components = path.split(separator: "/").map(String.init)
        if components.contains("user@\(uid).service"), components.last == nodeUnit {
            return VoiceRule(mode: .systemd, scopes: terminalScopes, uid: uid,
                             says: "the cgroup rule: the server runs in \(nodeUnit)")
        }
        return VoiceRule(mode: .weaker, scopes: [], uid: uid,
                         says: "the weaker rule: no systemd unit to tell by (the server's cgroup is \(path.isEmpty ? "unknown" : path)), so a peer's cgroup isn't checked")
    }

    /// Why the cgroup `lines` aren't a user's terminal's under this rule, or nil when they are: each of the unified
    /// and systemd paths that is there must be outside `user@<uid>.service` and the node's unit and match a scope;
    /// with neither there, the cgroup can't be read.
    public func cgroupRefusal(_ lines: [String]) -> String? {
        let paths = [PeerFacts.unifiedPath(lines), PeerFacts.systemdPath(lines)].compactMap { $0 }
        guard !paths.isEmpty else { return "its cgroup names no systemd or unified hierarchy" }
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            if components.contains("user@\(uid).service") {
                return components.contains(Self.nodeUnit) ? "its cgroup \(path) is the node's unit"
                    : "its cgroup \(path) is in the user's systemd manager (a user unit, systemd-run, a service)"
            }
            if components.contains(Self.nodeUnit) { return "its cgroup \(path) is the node's unit" }
            guard scopes.contains(where: { $0.matches(path, uid: uid) }) else {
                return "its cgroup \(path) is no terminal scope this node knows (\(scopes.map(\.pattern).joined(separator: ", ")))"
            }
        }
        return nil
    }
}
