import Foundation
import VibeCore

/// `vibeswitcher start`, `stop` and `status` on the Mac, as the user's LaunchAgent (the node on the Mac's design, "The
/// LaunchAgent: start, stop and status"), with every step injected: the command line wires `Steps` for the user's node
/// (`Place.user`, refused before it by `NodeSystem.macUnbuilt`), and the tests give a scratch label, plist folder and
/// data root, a scratch record, and this Mac's real `launchctl`.
public struct MacAgent {
    /// What `launchctl` printed and its exit status.
    public struct Ran: Equatable, Sendable {
        public var status: Int32
        public var output: String
        public init(status: Int32, output: String) {
            self.status = status
            self.output = output
        }
    }

    /// The node's host as its socket showed it: the connection's audit token running a host the record pins.
    public struct Host: Equatable, Sendable {
        /// The record's build whose host its running code is.
        public var commit: String
        public var pid: pid_t
        public var startedAt: Date?
        /// Its live sessions, from its welcome.
        public var sessions: Int

        public init(commit: String, pid: pid_t, startedAt: Date?, sessions: Int) {
            self.commit = commit
            self.pid = pid
            self.startedAt = startedAt
            self.sessions = sessions
        }
    }

    /// What is at the node's host socket, for the job's pid.
    public enum Seen: Equatable, Sendable {
        /// The node's host, by token and code.
        case host(Host)
        /// Nothing takes a connection there: why.
        case nothing(String)
        /// Something that isn't the node's host: why.
        case other(String)
    }

    public struct Steps {
        /// Runs `/bin/launchctl` with these arguments (the place's `launchctl` first); nil when it couldn't run.
        public var launchctl: ([String]) -> Ran?
        /// The node's root-owned record (`NodePins.read`).
        public var pins: () -> Result<NodePins, NodePins.Refused>
        /// A file's cdhash for this Mac's slice (`Platform.CodeIdentity.cdhash(atPath:)`).
        public var cdhashOf: (String) -> Data?
        /// What is at `socket` for the job's process `pid`, checked against `builds` (`MacAgent.see`).
        public var see: (_ socket: String, _ pid: pid_t, _ builds: [NodePins.Build]) -> Seen
        /// Says a line to the user.
        public var say: (String) -> Void
        /// `stop`'s confirmation, `what` shown (the typed code); a failure stops nothing.
        public var confirm: (_ what: String) -> Result<Void, StartRefusal>
        /// The server's own stop, when one answers (it ends the leads and every session, and the host shuts down).
        public var serverStop: () -> Void
        /// A process's children, by pid and start (`Platform.Processes.children` and `link`).
        public var children: (pid_t) -> [Platform.Processes.Link]
        /// The process `link` names still runs (the same pid and start).
        public var alive: (Platform.Processes.Link) -> Bool
        /// No process holds the lock at this path.
        public var lockFree: (String) -> Bool
        /// How long a start waits for its host, and a stop for its processes to go.
        public var patience: TimeInterval
        public var now: () -> Date
        /// Between two looks.
        public var pause: () -> Void

        public init(launchctl: @escaping ([String]) -> Ran?, pins: @escaping () -> Result<NodePins, NodePins.Refused>,
                    cdhashOf: @escaping (String) -> Data?,
                    see: @escaping (_ socket: String, _ pid: pid_t, _ builds: [NodePins.Build]) -> Seen,
                    say: @escaping (String) -> Void, confirm: @escaping (_ what: String) -> Result<Void, StartRefusal>,
                    serverStop: @escaping () -> Void, children: @escaping (pid_t) -> [Platform.Processes.Link],
                    alive: @escaping (Platform.Processes.Link) -> Bool, lockFree: @escaping (String) -> Bool,
                    patience: TimeInterval = 30, now: @escaping () -> Date = Date.init, pause: @escaping () -> Void = { usleep(50_000) }) {
            self.launchctl = launchctl
            self.pins = pins
            self.cdhashOf = cdhashOf
            self.see = see
            self.say = say
            self.confirm = confirm
            self.serverStop = serverStop
            self.children = children
            self.alive = alive
            self.lockFree = lockFree
            self.patience = patience
            self.now = now
            self.pause = pause
        }

        /// This Mac's readers for `place`: its `launchctl`, Security's cdhash of a file, the host checked by `see`,
        /// the process table and the lock; the record (`pins`), what is said, the confirmation and the server's stop
        /// as the caller gives them.
        public static func system(place: NodeAgent.Place, pins: @escaping () -> Result<NodePins, NodePins.Refused>, say: @escaping (String) -> Void,
                                  confirm: @escaping (_ what: String) -> Result<Void, StartRefusal>, serverStop: @escaping () -> Void) -> Steps {
            Steps(launchctl: { _ in nil }, pins: pins, cdhashOf: { _ in nil }, see: { _, _, _ in .other("not built") }, say: say, confirm: confirm,
                  serverStop: serverStop, children: { _ in [] }, alive: { _ in false }, lockFree: { _ in false })
        }
    }

    public let place: NodeAgent.Place
    public let steps: Steps

    public init(place: NodeAgent.Place, steps: Steps) {
        self.place = place
        self.steps = steps
    }

    static let unbuilt = StartRefusal("the Mac's agent isn't built yet", exitCode: 1)

    /// `start` for `job`, the build `build` of the record in `folder` (`<builds>/<commit>`): what it said, or why not.
    public func start(_ job: NodeAgent.Job, build: NodePins.Build, folder: String) -> Result<String, StartRefusal> { .failure(Self.unbuilt) }

    /// `stop`: what it said, or why not.
    public func stop() -> Result<String, StartRefusal> { .failure(Self.unbuilt) }

    /// `status`: the node runs (what it said), or why not (69: it doesn't run).
    public func status() -> Result<String, StartRefusal> { .failure(Self.unbuilt) }

    /// The build the command line `own` (its running code) is in the record `pins`, and its folder under `prefix`.
    public static func ownBuild(own: Data?, pins: Result<NodePins, NodePins.Refused>, prefix: String) -> Result<(build: NodePins.Build, folder: String), StartRefusal> {
        .failure(unbuilt)
    }

    /// What is at `socket` for the job's process `pid` (the design's "How start knows the host is the one it meant"):
    /// the connection's audit token, its pid the job's, running (Security's dynamic check) a host of `builds`, hardened,
    /// the same process before and after the reads, and then its welcome. Every reader is a parameter.
    public static func see(socket: String, pid: pid_t, builds: [NodePins.Build],
                           connect: (String) -> Int32? = { try? UnixSocket.connect(path: $0) },
                           token: (Int32) -> Platform.PeerToken? = Platform.Sockets.peerToken,
                           link: (pid_t) -> Platform.Processes.Link? = Platform.Processes.link,
                           runs: (Platform.PeerToken, Data) -> Bool = { Platform.CodeIdentity.runs($0, cdhash: $1) },
                           hardened: (Platform.PeerToken) -> Bool? = Platform.CodeIdentity.isHardened,
                           bound: (Platform.Processes.Link, Platform.PeerToken) -> Bool = { $0.isProcess(of: $1) },
                           welcome: (Int32) -> Welcome? = MacAgent.welcome,
                           close: (Int32) -> Void = { Sys.close($0) }) -> Seen {
        .other("not built")
    }

    /// The host's welcome, as `see` reads it.
    public struct Welcome: Equatable, Sendable {
        public var pid: pid_t?
        public var startedAt: Date?
        public var sessions: Int
        public init(pid: pid_t?, startedAt: Date?, sessions: Int) {
            self.pid = pid
            self.startedAt = startedAt
            self.sessions = sessions
        }
    }

    /// Says hello on `fd` and reads the host's welcome, within 5 s; nil without one.
    public static func welcome(_ fd: Int32) -> Welcome? { nil }
}
