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

        public init(commit: String, pid: pid_t, startedAt: Date?) {
            self.commit = commit
            self.pid = pid
            self.startedAt = startedAt
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

    /// What the node's server said of `stop` (`Steps.serverStop`).
    public enum ServerStop: Equatable, Sendable {
        /// It took the stop: the leads and every session end, and the host shuts down, in order.
        case stopped
        /// It answered and refused, or its answer couldn't be read: why, in the user's words.
        case refused(StartRefusal)
        /// No server answered: why.
        case none(String)
    }

    /// What asking the node's server for `status` came to, before a stop.
    public enum ServerSeen: Equatable, Sendable {
        /// It answered, and runs this many sessions (`host.liveSessions`).
        case answered(sessions: Int)
        /// It answered and refused, or its answer couldn't be read: why. Nothing is stopped then.
        case refused(StartRefusal)
        /// Nothing answered as the node's server (nothing listens, no hello, a listener that fails the server check): why.
        case none(String)
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
        /// The server's own stop, `what` shown, asked under the rule the other commands use (the typed code, or the Mac's
        /// dialog), and its answer.
        public var serverStop: (_ what: String) -> ServerStop
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
        /// A process's command line as the kernel gives it to its user (`Platform.Processes.arguments`).
        public var arguments: (pid_t) -> [String]
        /// The job for a build of the record, as `start` writes its plist (the user's node: `NodeAgent.Job.node`, a checked
        /// node's command line; a test's scratch job: its own), `RunAtLoad` as `start` without `--at-login` writes it;
        /// nil for a build it has none for.
        public var job: (NodePins.Build) -> NodeAgent.Job?
        /// Every process in these POSIX sessions, by pid and start (`Platform.Processes.allPids`, `getsid`).
        public var inSessions: (Set<pid_t>) -> [Platform.Processes.Link] = MacAgent.processes(inSessions:)
        /// The node's server asked for `status` (its `host.liveSessions`: the host's own welcome lists only the sessions
        /// its caller may end, none for the command line).
        public var server: () -> ServerSeen
        /// The session id (`VIBESWITCHER_SESSION`) in a process's environment, where it can be read.
        public var sessionID: (pid_t) -> String? = MacAgent.sessionID(of:)
        /// The user's processes carrying one of these session ids (`SessionStrays.carrying`), by pid and start.
        public var carrying: (Set<String>) -> [Platform.Processes.Link] = MacAgent.carrying
        /// The file a process runs (`Platform.Processes.executable`: the kernel's path of its image).
        public var executable: (pid_t) -> String? = Platform.Processes.executable

        public init(launchctl: @escaping ([String]) -> Ran?, pins: @escaping () -> Result<NodePins, NodePins.Refused>,
                    cdhashOf: @escaping (String) -> Data?,
                    see: @escaping (_ socket: String, _ pid: pid_t, _ builds: [NodePins.Build]) -> Seen,
                    say: @escaping (String) -> Void, confirm: @escaping (_ what: String) -> Result<Void, StartRefusal>,
                    serverStop: @escaping (_ what: String) -> ServerStop, children: @escaping (pid_t) -> [Platform.Processes.Link],
                    alive: @escaping (Platform.Processes.Link) -> Bool, lockFree: @escaping (String) -> Bool,
                    patience: TimeInterval = 30, now: @escaping () -> Date = Platform.Clock.steadyDate, pause: @escaping () -> Void = { usleep(50_000) },
                    arguments: @escaping (pid_t) -> [String] = Platform.Processes.arguments,
                    job: @escaping (NodePins.Build) -> NodeAgent.Job? = { _ in nil }, server: @escaping () -> ServerSeen = { .none("no server is asked") }) {
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
            self.arguments = arguments
            self.job = job
            self.server = server
        }
    }

    public let place: NodeAgent.Place
    public let steps: Steps

    public init(place: NodeAgent.Place, steps: Steps) {
        self.place = place
        self.steps = steps
    }

    /// `start` for `job`, the build `build` of the record in `folder` (`<builds>/<commit>`), in the design's order: the
    /// record pins the build and its files; a job of the label already there (the node's host: it runs already; another
    /// program: refused, left alone; loaded and not running: unloaded); the plist written when there is none, else
    /// checked; `launchctl getenv` refusing a loader variable; then `bootstrap` (and `kickstart`), and the wait for the
    /// host by token and code. Every refusal after the load boots out what it loaded.
    public func start(_ job: NodeAgent.Job, build: NodePins.Build, folder: String) -> Result<String, StartRefusal> {
        let pins: NodePins
        switch steps.pins() {
        case .failure(let why): return .failure(StartRefusal("the node's record can't be read: \(why.description); nothing was started", exitCode: 1))
        case .success(let read): pins = read
        }
        guard pins.builds.contains(build) else {
            return .failure(StartRefusal("the node's record doesn't pin build \(build.commit): nothing was started", exitCode: 1))
        }
        for (name, cdhash) in [(BuildInfo.host, build.host), (BuildInfo.server, build.server)] {
            let path = NodeFolders.join(folder, "bin/" + name)
            guard steps.cdhashOf(path) == cdhash else {
                return .failure(StartRefusal("\(ConfigSeal.inert(path, limit: .max)) isn't the \(name) the node's record pins for build \(build.commit): nothing was started", exitCode: 1))
            }
        }
        // A job of the label already there, judged by launchd's whole word (the design's "The re-check's round").
        switch judge(candidates(pins.builds)) {
        case .notLoaded: break
        case .notOurs(let why):
            return .failure(StartRefusal("a job labelled \(place.label) is loaded that isn't the node's: \(why); it was left as it is", exitCode: 77))
        case .ours(let printed, let loaded):
            if let pid = printed.pid {
                switch node(pid, builds: pins.builds) {
                case .success(let host): return .success(say("the node runs already: \(Self.describe(host))"))
                case .failure(let why):
                    return .failure(StartRefusal("a job labelled \(place.label) runs pid \(pid), which isn't the node's host: \(why.text); it was left as it is", exitCode: 77))
                }
            }
            // The agent's own job, not running: unloaded, so the plist checked below is what launchd loads.
            _ = loaded
            if let why = bootout() { return .failure(why) }
        }
        for name in NodeAgent.refusedManagerNames {
            if let ran = steps.launchctl(["getenv", name]), ran.status == 0, !ran.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failure(StartRefusal("the user's launchd gives every job \(name) (launchctl setenv): `launchctl unsetenv \(name)` first; nothing was started", exitCode: 1))
            }
        }
        // The plist checked, its descriptor held: what launchd reads next must be this file, unchanged (the review's I1).
        let held: HeldPlist
        switch writtenPlist(job) {
        case .failure(let why): return .failure(why)
        case .success(let checked): held = checked
        }
        defer { Sys.close(held.fd) }
        // A bootstrap that failed with an answer loaded nothing of this start's: what is there (another start's job, a
        // login's) is left alone. One that didn't finish (no answer within its limit, or ended by a signal) may have loaded
        // start's own job: judged, and booted out when it is start's (the final re-check's note E).
        let bootstrapped = steps.launchctl(["bootstrap", place.domain, place.plistPath])
        guard let bootstrapped, bootstrapped.status == 0 else {
            if bootstrapped == nil || (bootstrapped?.status ?? 0) >= 128 {
                let what: String
                switch judge([job], held: held.fd) {
                case .notLoaded: what = "nothing of it is loaded"
                case .ours: what = unloaded(bootout())
                case .notOurs(let why): what = "a job of the label that isn't start's is loaded (\(why)): it was left as it is"
                }
                return .failure(StartRefusal("launchctl bootstrap \(place.domain) \(ConfigSeal.inert(place.plistPath, limit: .max)) didn't finish: \(what)", exitCode: 1))
            }
            return .failure(StartRefusal("launchctl bootstrap \(place.domain) \(ConfigSeal.inert(place.plistPath, limit: .max)) failed (a job of the label may have been loaded meanwhile): nothing of it was touched", exitCode: 1))
        }
        if !job.atLogin, steps.launchctl(["kickstart", place.target])?.status != 0 {
            return .failure(StartRefusal("launchctl kickstart \(place.target) failed: \(unloaded(bootout()))", exitCode: 1))
        }
        let deadline = steps.now().addingTimeInterval(steps.patience)
        var last = "no host took a connection"
        while true {
            switch judge([job], held: held.fd) {
            case .notLoaded:
                return .failure(StartRefusal("the job \(place.target) went from launchd while start waited for its host", exitCode: 1))
            case .notOurs(let why):
                // Not yet while nothing answers (launchd's transient states are placed, measured); once a host answers at
                // the socket the job is up, and a word that isn't the job's is refused now. The pid read here decides
                // only when to stop waiting, never an accept.
                if let pid = printed()?.pid, case .host = steps.see(place.socket, pid, [build]) {
                    return .failure(StartRefusal("launchd's word for the job it loaded isn't the job start wrote: \(why); \(unloaded(bootout()))", exitCode: 77))
                }
                last = why
            case .ours(let printed, _):
                if let pid = printed.pid {
                    switch steps.see(place.socket, pid, [build]) {
                    case .host(let host):
                        // Its code is the pinned host's; its command line and program the job's; the file launchd read the
                        // one start checked and holds, unchanged; launchd's word the job's (placed above).
                        if let why = runsTheJob(pid, build: build, switched: false) ?? runsTheProgram(pid, build: build) ?? held.changed(place: place) {
                            return .failure(StartRefusal("the job's process (pid \(pid)) isn't the host start meant: \(why); \(unloaded(bootout()))", exitCode: 77))
                        }
                        return .success(say("the node runs: \(Self.describe(host))"))
                    case .other(let why):
                        return .failure(StartRefusal("the job's process (pid \(pid)) isn't the host start meant: \(why); \(unloaded(bootout()))", exitCode: 77))
                    case .nothing(let why): last = why
                    }
                } else if printed.state == "not running", (printed.runs ?? 0) > 0 {
                    let ended = printed.lastExit ?? "it ended"
                    return .failure(StartRefusal("the node's host ended at its start (\(ended)); \(unloaded(bootout())). Its log, \(place.log), ends: \(logTail())", exitCode: 1))
                }
            }
            guard steps.now() < deadline else {
                return .failure(StartRefusal("no host came within \(Int(steps.patience)) s (\(last)); \(unloaded(bootout()))", exitCode: 1))
            }
            steps.pause()
        }
    }

    /// `stop`: the job of the label judged by launchd's whole word, its host checked (another program refused and left
    /// alone); everything the host started taken at each look (its descendants, the sessions they lead, the session ids
    /// they carry); with a server that answers, its own stop asked once, by its rule, and its answer kept (refused:
    /// nothing is stopped); with none, what ends said and the typed code asked, then the bootout; then the wait until no
    /// job, none of those processes and no socket is left, or what is left named.
    public func stop() -> Result<String, StartRefusal> {
        if notLoaded() { return .failure(StartRefusal("the node isn't running: no job labelled \(place.label) is loaded", exitCode: 69)) }
        let builds: [NodePins.Build]
        switch steps.pins() {
        case .failure(let why): return .failure(StartRefusal("the node's record can't be read: \(why.description); nothing was stopped", exitCode: 1))
        case .success(let read): builds = read.builds
        }
        let pid: pid_t
        switch judge(candidates(builds)) {
        case .notLoaded:
            return .failure(StartRefusal("the node isn't running: no job labelled \(place.label) is loaded", exitCode: 69))
        case .notOurs(let why):
            return .failure(StartRefusal("a job labelled \(place.label) is loaded that isn't the node's: \(why); nothing was stopped", exitCode: 77))
        case .ours(let printed, _):
            guard let running = printed.pid else {
                if let why = bootout() { return .failure(why) }
                removeStaleSocket()
                return .success(say("the node wasn't running (\(printed.lastExit ?? "not started")): its job was unloaded"))
            }
            pid = running
        }
        let host: Host
        switch node(pid, builds: builds) {
        case .success(let seen): host = seen
        case .failure(let why):
            return .failure(StartRefusal("a job labelled \(place.label) runs pid \(pid), which isn't the node's host: \(why.text); nothing was stopped", exitCode: 77))
        }
        // Everything the host started, taken while it runs and again after the prompts, with the session ids each look
        // reads (a process that leaves its session between two looks still carries one): after the bootout its sessions
        // and server are launchd's children, outside the job's group.
        var processes: [Platform.Processes.Link] = []
        var ids = Set<String>()
        func look() {
            let found = descendants(of: pid)
            processes = Self.union(processes, found)
            ids.formUnion(found.compactMap { steps.sessionID($0.pid) })
        }
        look()
        var ordered = false
        var withoutServer: String?
        switch steps.server() {
        case .refused(let why):
            return .failure(StartRefusal("the node's server answered and refused (\(why.text)): nothing was stopped; if it is wedged, `launchctl bootout \(place.target)` ends it by hand", exitCode: why.exitCode))
        case .none(let why):
            withoutServer = why
        case .answered(let live):
            let what = "stop ends the node's host (pid \(host.pid), build \(host.commit)), its server and its \(live) session\(live == 1 ? "" : "s") "
                + "in order, through its server, and unloads \(place.label)"
            look()
            switch steps.serverStop(what) {
            case .stopped: ordered = true
            case .refused(let why):
                return .failure(StartRefusal("the node's server didn't take the stop: \(why.text); nothing was stopped", exitCode: why.exitCode))
            case .none(let why): withoutServer = why
            }
        }
        if let why = withoutServer {
            let what = "nothing listens at the node's server's socket (\(why)): stop ends the node's host (pid \(host.pid), build \(host.commit)) by launchd's bootout, "
                + "its sessions lose their terminal (a hangup) and end, and \(place.label) is unloaded"
            if case .failure(let refused) = steps.confirm(what) { return .failure(refused) }
            look()
        }
        if let why = bootout() { return .failure(why) }
        let deadline = steps.now().addingTimeInterval(steps.patience)
        while true {
            let left = Self.union(processes.filter(steps.alive), ids.isEmpty ? [] : steps.carrying(ids).filter(steps.alive))
            if left.isEmpty, !listening() {
                removeStaleSocket()
                return .success(say(ordered ? "the node stopped: its server ended its sessions in order, the host shut down, every process of it stop could find has ended, and \(place.label) is unloaded"
                                            : "the node stopped: its host ended by launchd's bootout, every process of it stop could find has ended, and \(place.label) is unloaded"))
            }
            guard steps.now() < deadline else {
                let names = left.map { "pid \($0.pid)" }.joined(separator: ", ")
                return .failure(StartRefusal("\(place.label) is unloaded, but after \(Int(steps.patience)) s \(names.isEmpty ? "something still listens on \(place.socket)" : "still running: \(names)")", exitCode: 1))
            }
            steps.pause()
        }
    }

    /// `status`, from the host itself: not loaded or not running (69, with launchd's last exit), a job of the label that
    /// isn't the node's (77), or the job's host checked as `node` checks it.
    public func status() -> Result<String, StartRefusal> {
        runningHost().map { say("the node runs: \(Self.describe($0))") }
    }

    /// The node's host as `status` finds it, said to no one: the job of the label judged by launchd's whole word, its
    /// process the node's host by the connection's audit token and running code (`node`). The command line's server
    /// check takes the host's pid from this (`ServerCheck`), never from `launchctl print`'s text alone.
    public func runningHost() -> Result<Host, StartRefusal> {
        if notLoaded() { return .failure(StartRefusal("the node isn't running: no job labelled \(place.label) is loaded", exitCode: 69)) }
        let builds: [NodePins.Build]
        switch steps.pins() {
        case .failure(let why): return .failure(StartRefusal("the node's record can't be read: \(why.description)", exitCode: 1))
        case .success(let read): builds = read.builds
        }
        switch judge(candidates(builds)) {
        case .notLoaded:
            return .failure(StartRefusal("the node isn't running: no job labelled \(place.label) is loaded", exitCode: 69))
        case .notOurs(let why):
            return .failure(StartRefusal("a job labelled \(place.label) is loaded that isn't the node's: \(why)", exitCode: 77))
        case .ours(let printed, _):
            guard let pid = printed.pid else {
                return .failure(StartRefusal("the node isn't running: its job is loaded and not running (\(printed.lastExit ?? "never started"))", exitCode: 69))
            }
            switch node(pid, builds: builds) {
            case .success(let host): return .success(host)
            case .failure(let why):
                return .failure(StartRefusal("a job labelled \(place.label) runs pid \(pid), which isn't the node's host: \(why.text)", exitCode: 77))
            }
        }
    }

    /// The switch's follow-up on the Mac (`vibeswitcher switch`, once the host handed over): the agent's plist rewritten
    /// for the build `target` (in `folder`) the host now runs. The seam: not built yet, so a switch rewrites no plist.
    public func switched(to target: NodePins.Build, folder: String) -> Result<String, StartRefusal> {
        .failure(StartRefusal("the Mac's switch rewrites no plist yet", exitCode: 1))
    }

    /// The build the command line `own` (its running code) is in the record `pins` (the row whose `cli` it is), and its
    /// folder under `prefix`: no path chooses it.
    public static func ownBuild(own: Data?, pins: Result<NodePins, NodePins.Refused>, prefix: String) -> Result<(build: NodePins.Build, folder: String), StartRefusal> {
        let record: NodePins
        switch pins {
        case .failure(let why): return .failure(StartRefusal("the node's record can't be read: \(why.description); \(NodePins.remedy)", exitCode: 1))
        case .success(let read): record = read
        }
        guard let own else { return .failure(StartRefusal("this command line's own code can't be read", exitCode: 1)) }
        guard let build = record.builds.first(where: { $0.cli == own }) else {
            return .failure(StartRefusal("this command line (\(NodePins.hex(own))) is no build's the node's record pins; \(NodePins.remedy)", exitCode: 1))
        }
        return .success((build, NodeFolders.join(prefix, build.commit)))
    }

    /// What is at `socket` for the job's process `pid` (the design's "How start knows the host is the one it meant"):
    /// the connection's audit token, its pid the job's, running (Security's dynamic check) a host of `builds`, hardened,
    /// the same process before and after the reads, and then its welcome, whose pid is the token's. Every reader is a
    /// parameter.
    public static func see(socket: String, pid: pid_t, builds: [NodePins.Build],
                           connect: (String) -> Int32? = { try? UnixSocket.connect(path: $0) },
                           token: (Int32) -> Platform.PeerToken? = Platform.Sockets.peerToken,
                           link: (pid_t) -> Platform.Processes.Link? = Platform.Processes.link,
                           runs: (Platform.PeerToken, Data) -> Bool = { Platform.CodeIdentity.runs($0, cdhash: $1) },
                           hardened: (Platform.PeerToken) -> Bool? = Platform.CodeIdentity.isHardened,
                           bound: (Platform.Processes.Link, Platform.PeerToken) -> Bool = { $0.isProcess(of: $1) },
                           welcome: (Int32) -> Welcome? = MacAgent.welcome,
                           close: (Int32) -> Void = { Sys.close($0) }) -> Seen {
        guard let fd = connect(socket) else { return .nothing("nothing takes a connection at \(socket)") }
        defer { close(fd) }
        guard let peer = token(fd) else { return .other("the process at \(socket) can't be told (no audit token)") }
        guard peer.pid == pid else { return .other("the process at \(socket) is pid \(peer.pid), not the job's process (pid \(pid))") }
        guard let first = link(pid) else { return .other("pid \(pid) can't be read") }
        guard let build = builds.first(where: { runs(peer, $0.host) }) else {
            return .other("pid \(pid) doesn't run a host the node's record pins")
        }
        guard hardened(peer) == true else { return .other("pid \(pid) doesn't run with the Hardened Runtime") }
        guard let again = link(pid), again == first, bound(again, peer) else { return .other("pid \(pid) changed while it was read") }
        guard let said = welcome(fd) else { return .other("pid \(pid) sent no welcome") }
        if let told = said.pid, told != pid { return .other("pid \(pid)'s welcome names pid \(told)") }
        return .host(Host(commit: build.commit, pid: pid, startedAt: said.startedAt))
    }

    /// Says hello on `fd` and reads the host's welcome, within 5 s; nil without one.
    public static func welcome(_ fd: Int32) -> Welcome? {
        guard let payload = try? HostCoding.encode(HostRequestEnvelope(seq: 1, request: .hello(protocolVersion: HostProtocol.version, app: "vibeswitcher"))) else { return nil }
        let frame = [UInt8](HostFrame.encode(.control, payload))
        var sent = 0
        while sent < frame.count {
            let wrote = frame[sent...].withUnsafeBytes { Platform.Sockets.send(fd, $0.baseAddress, $0.count) }
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { return nil }
            sent += wrote
        }
        var decoder = HostFrameDecoder()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = Platform.Clock.steadyDate().addingTimeInterval(5)
        while Platform.Clock.steadyDate() < deadline {
            var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let woke = poll(&watched, 1, 200)
            if woke < 0, errno == EINTR { continue }
            if woke == 0 { continue }
            let got = Sys.read(fd, &chunk, chunk.count)
            if got < 0, errno == EINTR || errno == EAGAIN { continue }
            guard got > 0 else { return nil }
            decoder.append(Data(chunk[0..<got]))
            while let next = try? decoder.next() {
                guard next.kind == .control, let envelope = try? HostCoding.decode(HostEventEnvelope.self, from: next.payload) else { continue }
                if case .welcome(_, _, _, _, let pid, let startedAt) = envelope.event {
                    return Welcome(pid: pid, startedAt: startedAt)
                }
            }
        }
        return nil
    }

    /// The agent's plist as launchd prints it: the folder's links resolved (`realpath`), then the file's name.
    public static func canonicalPlistPath(_ place: NodeAgent.Place) -> String {
        guard let real = realpath(place.plistFolder, nil) else { return place.plistPath }
        defer { free(real) }
        return (String(cString: real) as NSString).appendingPathComponent("\(place.label).plist")
    }

    /// How a connection to the node's server failed, as the command line's client says it.
    public enum ConnectFailure: Equatable, Sendable {
        /// Nothing listens at the server's socket.
        case noListener(String)
        /// What listens fails the server check.
        case notTheServer(String)
        /// What listens took the connection and sent no hello, or garbage, or one too late.
        case noHello(String)
    }

    /// What a connection that failed so says of the server before a stop (the re-check's note 6): only no listener at all
    /// is no server (the typed code and the bootout follow); a listener that fails the server check, or a hello that is
    /// garbage or late, stops nothing.
    public static func serverSeen(_ failure: ConnectFailure) -> ServerSeen {
        switch failure {
        case .noListener(let why): return .none(why)
        case .notTheServer(let why): return .refused(StartRefusal("what listens isn't the node's server (\(why))", exitCode: 77))
        case .noHello(let why): return .refused(StartRefusal("the node's server sent no hello that could be read (\(why))", exitCode: 1))
        }
    }

    /// Whether `status` checks the node's host first (the user's node on the Mac, past its refusal), with `--json` too.
    public static func statusChecksHost(onTheMac: Bool, isScratch: Bool, refused: Bool, json: Bool) -> Bool {
        onTheMac && !isScratch && !refused
    }

    // MARK: Helpers

    /// The node's host in the job of the label running at `pid` (the review's I2, the job already judged ours by
    /// launchd's whole word): the process at the socket runs a pinned host by token and code (`see`), its command line
    /// that build's job's (a switched one with the keeper's two flags after it) and its program that job's program by
    /// device and inode.
    func node(_ pid: pid_t, builds: [NodePins.Build]) -> Result<Host, StartRefusal> {
        switch steps.see(place.socket, pid, builds) {
        case .nothing(let why), .other(let why): return .failure(StartRefusal(why))
        case .host(let host):
            guard let build = builds.first(where: { $0.commit == host.commit }) else { return .failure(StartRefusal("its build isn't the record's")) }
            if let why = runsTheJob(pid, build: build, switched: true) ?? runsTheProgram(pid, build: build) { return .failure(StartRefusal(why)) }
            return .success(host)
        }
    }

    /// What launchd's word for the job of the label came to (the design's "The re-check's round": one reader).
    enum Judged {
        /// `print` said "Could not find service" (exit 113, measured): no job of the label.
        case notLoaded
        /// The whole output placed as `job`'s, its plist the agent's by `lstat` and file.
        case ours(NodeAgent.Printed, NodeAgent.Job)
        /// Loaded, and not placed as any job start writes (or `print` failed otherwise): why.
        case notOurs(String)
    }

    /// The jobs a job of the label may be of ours: start's for a pinned build whose bytes the agent's plist on disk is
    /// (`RunAtLoad` either way); none when the plist is another's or unreadable.
    func candidates(_ builds: [NodePins.Build]) -> [NodeAgent.Job] {
        guard let data = Self.readPlist(place.plistPath) else { return [] }
        return builds.compactMap(steps.job).flatMap { job -> [NodeAgent.Job] in
            var other = job
            other.atLogin = !job.atLogin
            return [job, other]
        }.filter { NodeAgent.check(data, job: $0) == nil }
    }

    /// The job of the label judged by launchd's whole word against `candidates`, its plist's path then compared by
    /// `lstat` (no link followed) with the file `held` (start's descriptor) or the agent's plist, by device and inode.
    func judge(_ candidates: [NodeAgent.Job], held: Int32? = nil) -> Judged {
        guard let ran = steps.launchctl(["print", place.target]) else { return .notOurs("launchctl print couldn't run") }
        if ran.status == 113 { return .notLoaded }
        guard ran.status == 0 else { return .notOurs("launchctl print exited \(ran.status)") }
        guard !candidates.isEmpty else {
            return .notOurs("the agent's plist isn't the one start writes for any build the node's record pins (if it is an earlier install's or "
                            + "another build's: `launchctl bootout \(place.target)`, remove \(ConfigSeal.inert(place.plistPath, limit: .max)), and run `vibeswitcher start` again)")
        }
        let path = Self.canonicalPlistPath(place)
        var first: String?
        for job in candidates {
            switch NodeAgent.placed(Data(ran.output.utf8), job: job, plistPath: path, uid: place.uid) {
            case .success(let printed):
                if let why = pathIsTheAgents(path, held: held) { return .notOurs(why) }
                return .ours(printed, job)
            case .failure(let why): first = first ?? why.description
            }
        }
        return .notOurs(first ?? "launchd's print isn't the job start wrote")
    }

    /// Why `path` (launchd's, already the agent's plist's text) isn't the agent's plist file, or nil: by `lstat` (no link
    /// followed) a regular file, the same device and inode as the descriptor `held` or the agent's plist by `lstat`.
    func pathIsTheAgents(_ path: String, held: Int32?) -> String? {
        var named = stat(), ours = stat()
        guard lstat(path, &named) == 0, named.st_mode & S_IFMT == S_IFREG else { return "launchd's plist \(ConfigSeal.inert(path, limit: .max)) isn't a regular file (a link, or gone)" }
        if let held {
            guard fstat(held, &ours) == 0 else { return "the plist start holds can't be read" }
        } else {
            guard lstat(place.plistPath, &ours) == 0, ours.st_mode & S_IFMT == S_IFREG else { return "the agent's plist isn't a regular file" }
        }
        guard named.st_dev == ours.st_dev, named.st_ino == ours.st_ino else { return "launchd's plist isn't the agent's plist file" }
        return nil
    }

    /// Why `pid` doesn't run the job's command line for `build` (`Steps.job`), or nil: exactly that, or, where it may
    /// have switched in place, that followed by the keeper's two flags and their numbers (a checked node's next image
    /// is started so: `NodeAgent.keeperFlags`).
    func runsTheJob(_ pid: pid_t, build: NodePins.Build, switched: Bool) -> String? {
        guard let expected = steps.job(build)?.programArguments else { return "the job has no command line for build \(build.commit)" }
        let given = steps.arguments(pid)
        if given == expected { return nil }
        let rest = Array(given.dropFirst(expected.count))
        if switched, Array(given.prefix(expected.count)) == expected, rest.count == 4, rest[0] == NodeAgent.keeperFlags.channel,
           rest[2] == NodeAgent.keeperFlags.pid, [rest[1], rest[3]].allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return nil }
        return "pid \(pid) runs \(ConfigSeal.inert(given.joined(separator: " "), limit: 512)), not the job's command line"
    }

    /// Why `pid`'s program (the kernel's path of its image) isn't the job's program for `build` by device and inode, or
    /// nil: a byte copy of the pinned host elsewhere is another file (the review's I2).
    func runsTheProgram(_ pid: pid_t, build: NodePins.Build) -> String? {
        guard let expected = steps.job(build)?.programArguments.first else { return "the job has no program for build \(build.commit)" }
        guard let running = steps.executable(pid) else { return "pid \(pid)'s program can't be read" }
        var a = stat(), b = stat()
        guard stat(running, &a) == 0, stat(expected, &b) == 0, a.st_dev == b.st_dev, a.st_ino == b.st_ino else {
            return "pid \(pid) runs \(ConfigSeal.inert(running, limit: 512)), not the job's program \(ConfigSeal.inert(expected, limit: 512))"
        }
        return nil
    }

    /// The host and everything it started, by pid and start: its descendants by parent links, every level, and every
    /// process in a POSIX session one of them leads (a session's program that forked and lost its parent but kept its
    /// session). A process that left its session and lost its parent before this look can't be found.
    func descendants(of pid: pid_t) -> [Platform.Processes.Link] {
        var found: [Platform.Processes.Link] = Platform.Processes.link(pid).map { [$0] } ?? []
        var seen: Set<pid_t> = [pid]
        var queue = [pid]
        while let next = queue.first {
            queue.removeFirst()
            for child in steps.children(next) where seen.insert(child.pid).inserted {
                found.append(child)
                queue.append(child.pid)
            }
        }
        for member in steps.inSessions(seen) where seen.insert(member.pid).inserted { found.append(member) }
        return found
    }

    /// `a` and the processes of `b` it doesn't hold (by pid and start).
    static func union(_ a: [Platform.Processes.Link], _ b: [Platform.Processes.Link]) -> [Platform.Processes.Link] {
        a + b.filter { link in !a.contains { $0.pid == link.pid && $0.startTicks == link.startTicks } }
    }

    /// The `VIBESWITCHER_SESSION` in `pid`'s environment (the kernel's, to its own user; not for Apple's platform
    /// binaries), nil without one.
    public static func sessionID(of pid: pid_t) -> String? {
        (Platform.Processes.environment(pid) ?? []).first { $0.hasPrefix("VIBESWITCHER_SESSION=") }.map { String($0.dropFirst("VIBESWITCHER_SESSION=".count)) }
    }

    /// The user's processes carrying one of `ids` (`SessionStrays.carrying`), by pid and start.
    public static func carrying(_ ids: Set<String>) -> [Platform.Processes.Link] {
        ids.compactMap(UUID.init(uuidString:)).flatMap { SessionStrays.carrying(session: $0) }.compactMap { Platform.Processes.link($0.pid) }
    }

    /// Every process whose POSIX session is one of `leaders` (`getsid`), by pid and start.
    public static func processes(inSessions leaders: Set<pid_t>) -> [Platform.Processes.Link] {
        (Platform.Processes.allPids() ?? []).filter { leaders.contains(getsid($0)) }.compactMap(Platform.Processes.link)
    }

    /// Something takes a connection at the host's socket.
    func listening() -> Bool { (try? UnixSocket.connect(path: place.socket)).map { Sys.close($0); return true } ?? false }

    /// The socket's file removed when it is a socket nothing listens on and the host's lock is free (the review's N3).
    func removeStaleSocket() {
        var status = stat()
        if lstat(place.socket, &status) == 0, status.st_mode & S_IFMT == S_IFSOCK, !listening(), steps.lockFree(place.lock) { unlink(place.socket) }
    }

    /// What launchd says of the job read leniently, for what decides nothing (a test's look); nil while none is loaded.
    func printed() -> NodeAgent.Printed? {
        guard let ran = steps.launchctl(["print", place.target]), ran.status == 0 else { return nil }
        return NodeAgent.printed(ran.output)
    }

    /// Whether launchd holds no job of the label: only `print`'s measured "Could not find service" (exit 113) says so.
    func notLoaded() -> Bool { steps.launchctl(["print", place.target])?.status == 113 }

    /// Boots the job out and waits until launchd says it has none of the label; why not, or nil.
    func bootout() -> StartRefusal? {
        _ = steps.launchctl(["bootout", place.target])
        let deadline = steps.now().addingTimeInterval(steps.patience)
        while !notLoaded() {
            guard steps.now() < deadline else {
                return StartRefusal("\(place.target) couldn't be unloaded: launchd still holds a job of the label after \(Int(steps.patience)) s", exitCode: 1)
            }
            steps.pause()
        }
        return nil
    }

    /// What a refusal says of its bootout: unloaded, or why it couldn't be.
    func unloaded(_ failed: StartRefusal?) -> String { failed.map { "and the job couldn't be unloaded (\($0.text))" } ?? "the job was unloaded" }

    /// The plist `start` checked, its descriptor held open until the host is seen (the review's I1): the file's and its
    /// folder's facts as they were after start's own write and read-back.
    struct HeldPlist {
        let fd: Int32
        let file: stat
        let folder: stat
        let bytes: Data

        /// Why what launchd read may not have been this file as start checked it, or nil: the path still names its
        /// inode, its ctime and size unchanged (a rename away and back, a link, a write and a write back all move the
        /// ctime), its bytes read again from the descriptor the same, and its folder the same with its ctime unchanged (a
        /// folder swapped away and back). A folder above it is not checked (its ctime moves with every file made in it).
        func changed(place: NodeAgent.Place) -> String? {
            var now = stat(), named = stat(), folderNow = stat()
            guard fstat(fd, &now) == 0, lstat(place.plistPath, &named) == 0, named.st_dev == now.st_dev, named.st_ino == now.st_ino else {
                return "the agent's plist was replaced while launchd read it"
            }
            let before = Platform.Files.changed(file), after = Platform.Files.changed(now)
            guard before.tv_sec == after.tv_sec, before.tv_nsec == after.tv_nsec, Platform.Files.byteSize(file) == Platform.Files.byteSize(now) else {
                return "the agent's plist was changed while launchd read it (its ctime or size moved)"
            }
            var again = [UInt8](repeating: 0, count: bytes.count + 1)
            let got = again.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
            guard got == bytes.count, Data(again[0..<got]) == bytes else { return "the agent's plist's bytes changed while launchd read it" }
            let folderWas = Platform.Files.changed(folder)
            guard lstat(place.plistFolder, &folderNow) == 0, folderNow.st_dev == folder.st_dev, folderNow.st_ino == folder.st_ino,
                  Platform.Files.changed(folderNow).tv_sec == folderWas.tv_sec, Platform.Files.changed(folderNow).tv_nsec == folderWas.tv_nsec else {
                return "the agent's plist folder was changed while launchd read it"
            }
            return nil
        }
    }

    /// The agent's plist for `job`, checked and held (`HeldPlist`), or why not: its folder a real folder (no link) of
    /// the user's that neither group nor others can write (made `0755` when there is none: the review's N4); the plist
    /// written when there is none (a new file, `0644`, `O_EXCL`), else read as it is (no link followed, a regular file of
    /// the user's that neither group nor others can write, at most 64 KiB) and never replaced; its bytes exactly start's.
    func writtenPlist(_ job: NodeAgent.Job) -> Result<HeldPlist, StartRefusal> {
        let path = place.plistPath, folder = place.plistFolder
        func refused(_ why: String, _ code: Int32 = 1) -> Result<HeldPlist, StartRefusal> { .failure(StartRefusal("\(why): nothing was started", exitCode: code)) }
        var folderStatus = stat()
        if lstat(folder, &folderStatus) != 0 {
            guard errno == ENOENT else { return refused("the agent's folder \(ConfigSeal.inert(folder, limit: .max)) can't be read (errno \(errno))") }
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            guard lstat(folder, &folderStatus) == 0 else { return refused("the agent's folder \(ConfigSeal.inert(folder, limit: .max)) couldn't be made") }
        }
        guard folderStatus.st_mode & S_IFMT == S_IFDIR, folderStatus.st_uid == place.uid, folderStatus.st_mode & 0o022 == 0, !Self.hasACL(folder) else {
            return refused("the agent's folder \(ConfigSeal.inert(folder, limit: .max)) isn't a folder of the user's that only the user can write (a link, another owner, writable by group or others, or an access control list)", 77)
        }
        var status = stat()
        if lstat(path, &status) != 0 {
            guard errno == ENOENT else { return refused("the agent's file \(ConfigSeal.inert(path, limit: .max)) can't be read (errno \(errno))") }
            let data: Data
            switch NodeAgent.plist(job) {
            case .failure(let why): return .failure(why)
            case .success(let made): data = made
            }
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return refused("the agent's file \(ConfigSeal.inert(path, limit: .max)) couldn't be made (errno \(errno))") }
            let wrote = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            let synced = fsync(fd) == 0
            Sys.close(fd)
            guard wrote == data.count, synced else { return refused("the agent's file \(ConfigSeal.inert(path, limit: .max)) couldn't be written") }
        }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return refused("the agent's file \(ConfigSeal.inert(path, limit: .max)) can't be opened (a link, or errno \(errno))") }
        var file = stat()
        guard fstat(fd, &file) == 0, file.st_mode & S_IFMT == S_IFREG, file.st_size <= 64 * 1024 else {
            Sys.close(fd)
            return refused("the agent's file \(ConfigSeal.inert(path, limit: .max)) isn't a regular file of at most 64 KiB")
        }
        guard file.st_uid == place.uid, file.st_mode & 0o022 == 0, Platform.Files.hasExtendedACL(fd) == false else {
            Sys.close(fd)
            return refused("the agent's file \(ConfigSeal.inert(path, limit: .max)) is another user's, writable by group or others (launchd refuses such a plist) or carries an access control list: `chmod 644` it if it is start's", 77)
        }
        var read = [UInt8](repeating: 0, count: Int(file.st_size) + 1)
        let got = read.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        let bytes = got >= 0 ? Data(read[0..<got]) : Data()
        if let why = NodeAgent.check(bytes, job: job) {
            Sys.close(fd)
            return refused("the agent's file \(ConfigSeal.inert(path, limit: .max)) isn't the one start writes for this build: \(why). If it is an earlier install's "
                           + "(its environment holds HOME and PATH) or another build's, remove it (`rm \(ConfigSeal.inert(path, limit: .max))`) and run `vibeswitcher start` again: start writes its own; it was left as it is", 77)
        }
        // Its folder looked at again, after the write: the same folder as checked, still a real folder of the user's.
        var after = stat()
        guard lstat(folder, &after) == 0, after.st_dev == folderStatus.st_dev, after.st_ino == folderStatus.st_ino,
              after.st_mode & S_IFMT == S_IFDIR, after.st_uid == place.uid, after.st_mode & 0o022 == 0, !Self.hasACL(folder) else {
            Sys.close(fd)
            return refused("the agent's folder \(ConfigSeal.inert(folder, limit: .max)) changed while start wrote the plist", 77)
        }
        return .success(HeldPlist(fd: fd, file: file, folder: after, bytes: bytes))
    }

    /// Whether the folder at `path` carries an extended access control list (or that can't be told): no link followed.
    static func hasACL(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return true }
        defer { Sys.close(fd) }
        return Platform.Files.hasExtendedACL(fd) != false
    }

    /// The file at `path` when it is a regular file (no link followed) of at most 64 KiB, read from the descriptor checked.
    static func readPlist(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Sys.close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size <= 64 * 1024 else { return nil }
        var data = [UInt8](repeating: 0, count: Int(status.st_size) + 1)
        var total = 0
        while total < data.count {
            let got = data[total...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { break }
            total += got
        }
        return total <= 64 * 1024 ? Data(data[0..<total]) : nil
    }

    /// The last lines of the host's log (its stderr), inert.
    func logTail() -> String {
        guard let data = FileManager.default.contents(atPath: place.log), !data.isEmpty else { return "(nothing)" }
        let text = String(decoding: data.suffix(2_000), as: UTF8.self)
        return ConfigSeal.inert(text.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " / "), limit: 600)
    }

    @discardableResult
    func say(_ line: String) -> String {
        steps.say(line)
        return line
    }

    static func describe(_ host: Host) -> String {
        "build \(host.commit), host pid \(host.pid)" + (host.startedAt.map { " since \(ISO8601DateFormatter().string(from: $0))" } ?? "")
    }

    /// The host's welcome, as `see` reads it.
    public struct Welcome: Equatable, Sendable {
        public var pid: pid_t?
        public var startedAt: Date?
        public init(pid: pid_t?, startedAt: Date?) {
            self.pid = pid
            self.startedAt = startedAt
        }
    }
}

// MARK: This Mac's readers

extension MacAgent.Steps {
    /// This Mac's readers for `place`: its `launchctl` (no environment of this process's), Security's cdhash of a
    /// file, the host checked by `MacAgent.see`, the process table and the lock; the record (`pins`), what is said, the
    /// confirmation and the server's stop as the caller gives them.
    public static func system(place: NodeAgent.Place, pins: @escaping () -> Result<NodePins, NodePins.Refused>, say: @escaping (String) -> Void,
                              confirm: @escaping (_ what: String) -> Result<Void, StartRefusal>, serverStop: @escaping (_ what: String) -> MacAgent.ServerStop,
                              job: @escaping (NodePins.Build) -> NodeAgent.Job?, server: @escaping () -> MacAgent.ServerSeen = { .none("no server is asked") }) -> MacAgent.Steps {
        MacAgent.Steps(
            launchctl: { arguments in
                NodeStarter.run(place.launchctl, arguments, environment: ["PATH=/usr/bin:/bin"], timeout: 30).map { MacAgent.Ran(status: $0.status, output: $0.output) }
            },
            pins: pins, cdhashOf: { Platform.CodeIdentity.cdhash(atPath: $0) },
            see: { socket, pid, builds in MacAgent.see(socket: socket, pid: pid, builds: builds) },
            say: say, confirm: confirm, serverStop: serverStop,
            children: { pid in Platform.Processes.children(pid).compactMap(Platform.Processes.link) },
            alive: { link in Platform.Processes.link(link.pid).map { $0.startTicks == link.startTicks } ?? false },
            lockFree: { path in
                let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { return errno == ENOENT }
                defer { Sys.close(fd) }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
                flock(fd, LOCK_UN)
                return true
            }, job: job, server: server)
    }
}
