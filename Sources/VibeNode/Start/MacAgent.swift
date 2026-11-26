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
        // A job of the label already there.
        if let printed = printed() {
            if let pid = printed.pid {
                switch steps.see(place.socket, pid, pins.builds) {
                case .host(let host): return .success(say("the node runs already: \(Self.describe(host))"))
                case .nothing(let why), .other(let why):
                    return .failure(StartRefusal("a job labelled \(place.label) runs pid \(pid), which isn't the node's host: \(why); it was left as it is", exitCode: 77))
                }
            }
            // Nothing of it runs: unloaded, so the checked plist is what launchd loads.
            if let why = bootout() { return .failure(why) }
        }
        if let why = plistRefusal(job) { return .failure(why) }
        for name in NodeAgent.refusedManagerNames {
            if let ran = steps.launchctl(["getenv", name]), ran.status == 0, !ran.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failure(StartRefusal("the user's launchd gives every job \(name) (launchctl setenv): `launchctl unsetenv \(name)` first; nothing was started", exitCode: 1))
            }
        }
        guard let loaded = steps.launchctl(["bootstrap", place.domain, place.plistPath]), loaded.status == 0 else {
            _ = bootout()
            return .failure(StartRefusal("launchctl bootstrap \(place.domain) \(ConfigSeal.inert(place.plistPath, limit: .max)) failed: nothing was started", exitCode: 1))
        }
        if !job.atLogin, steps.launchctl(["kickstart", place.target])?.status != 0 {
            _ = bootout()
            return .failure(StartRefusal("launchctl kickstart \(place.target) failed: the job was unloaded", exitCode: 1))
        }
        let deadline = steps.now().addingTimeInterval(steps.patience)
        var last = "no host took a connection"
        while true {
            if let printed = printed() {
                if let pid = printed.pid {
                    switch steps.see(place.socket, pid, [build]) {
                    case .host(let host): return .success(say("the node runs: \(Self.describe(host))"))
                    case .other(let why):
                        _ = bootout()
                        return .failure(StartRefusal("the job's process (pid \(pid)) isn't the host start meant: \(why); the job was unloaded", exitCode: 77))
                    case .nothing(let why): last = why
                    }
                } else if printed.state == "not running", (printed.runs ?? 0) > 0 {
                    let ended = printed.lastExit ?? "it ended"
                    _ = bootout()
                    return .failure(StartRefusal("the node's host ended at its start (\(ended)); the job was unloaded. Its log, \(place.log), ends: \(logTail())", exitCode: 1))
                }
            } else {
                return .failure(StartRefusal("the job \(place.target) went from launchd while start waited for its host", exitCode: 1))
            }
            guard steps.now() < deadline else {
                _ = bootout()
                return .failure(StartRefusal("no host came within \(Int(steps.patience)) s (\(last)); the job was unloaded", exitCode: 1))
            }
            steps.pause()
        }
    }

    /// `stop`: the job's host checked (another program refused and left alone), what ends said and confirmed, the
    /// server's stop, the host's children taken, the job booted out, and the wait until no job, no process of the
    /// snapshot and no socket is left.
    public func stop() -> Result<String, StartRefusal> {
        guard let printed = printed() else {
            return .failure(StartRefusal("the node isn't running: no job labelled \(place.label) is loaded", exitCode: 69))
        }
        guard let pid = printed.pid else {
            if let why = bootout() { return .failure(why) }
            return .success(say("the node wasn't running (\(printed.lastExit ?? "not started")): its job was unloaded"))
        }
        let builds: [NodePins.Build]
        switch steps.pins() {
        case .failure(let why): return .failure(StartRefusal("the node's record can't be read: \(why.description); nothing was stopped", exitCode: 1))
        case .success(let read): builds = read.builds
        }
        let host: Host
        switch steps.see(place.socket, pid, builds) {
        case .host(let seen): host = seen
        case .nothing(let why), .other(let why):
            return .failure(StartRefusal("a job labelled \(place.label) runs pid \(pid), which isn't the node's host: \(why); nothing was stopped", exitCode: 77))
        }
        let what = "stop ends the node's host (pid \(host.pid), build \(host.commit)), its server and its \(host.sessions) session\(host.sessions == 1 ? "" : "s"), and unloads \(place.label)"
        if case .failure(let why) = steps.confirm(what) { return .failure(why) }
        // The host and its children as they are now (pid and start): after the bootout its sessions and server are
        // launchd's children, outside the job's group, and are waited for by these.
        let snapshot = Platform.Processes.link(pid).map { [$0] } ?? []
        let processes = snapshot + steps.children(pid)
        steps.serverStop()
        if let why = bootout() { return .failure(why) }
        let deadline = steps.now().addingTimeInterval(steps.patience)
        while true {
            let left = processes.filter(steps.alive)
            let listening = (try? UnixSocket.connect(path: place.socket)).map { Sys.close($0); return true } ?? false
            if left.isEmpty, !listening {
                var status = stat()
                if lstat(place.socket, &status) == 0, status.st_mode & S_IFMT == S_IFSOCK, steps.lockFree(place.lock) { unlink(place.socket) }
                return .success(say("the node stopped: its host, its server and its sessions have ended, and \(place.label) is unloaded"))
            }
            guard steps.now() < deadline else {
                let names = left.map { "pid \($0.pid)" }.joined(separator: ", ")
                return .failure(StartRefusal("\(place.label) is unloaded, but after \(Int(steps.patience)) s \(names.isEmpty ? "something still listens on \(place.socket)" : "still running: \(names)")", exitCode: 1))
            }
            steps.pause()
        }
    }

    /// `status`, from the host itself: not loaded or not running (69, with launchd's last exit), or the host at the
    /// socket checked by token and code against every build the record pins, with its welcome.
    public func status() -> Result<String, StartRefusal> {
        guard let printed = printed() else {
            return .failure(StartRefusal("the node isn't running: no job labelled \(place.label) is loaded", exitCode: 69))
        }
        guard let pid = printed.pid else {
            return .failure(StartRefusal("the node isn't running: its job is loaded and not running (\(printed.lastExit ?? "never started"))", exitCode: 69))
        }
        switch steps.pins() {
        case .failure(let why): return .failure(StartRefusal("the node's record can't be read: \(why.description)", exitCode: 1))
        case .success(let pins):
            switch steps.see(place.socket, pid, pins.builds) {
            case .host(let host): return .success(say("the node runs: \(Self.describe(host))"))
            case .nothing(let why), .other(let why):
                return .failure(StartRefusal("a job labelled \(place.label) runs pid \(pid), which isn't the node's host: \(why)", exitCode: 77))
            }
        }
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
        return .host(Host(commit: build.commit, pid: pid, startedAt: said.startedAt, sessions: said.sessions))
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
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
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
                if case .welcome(_, _, let sessions, _, let pid, let startedAt) = envelope.event {
                    return Welcome(pid: pid, startedAt: startedAt, sessions: sessions.filter { $0.isLive }.count)
                }
            }
        }
        return nil
    }

    // MARK: Helpers

    /// What launchd says of the job; nil while none of the label is loaded.
    func printed() -> NodeAgent.Printed? {
        guard let ran = steps.launchctl(["print", place.target]), ran.status == 0 else { return nil }
        return NodeAgent.printed(ran.output)
    }

    /// Boots the job out and waits until launchd has none of the label; why not, or nil.
    func bootout() -> StartRefusal? {
        _ = steps.launchctl(["bootout", place.target])
        let deadline = steps.now().addingTimeInterval(steps.patience)
        while printed() != nil {
            guard steps.now() < deadline else { return StartRefusal("launchctl bootout \(place.target) didn't unload it", exitCode: 1) }
            steps.pause()
        }
        return nil
    }

    /// Why the plist at the agent's path isn't `job`'s, or nil once it is: written when there is none (a new file, the
    /// user's, `0644`), then read back and checked; when there is one, read (no link followed, a regular file, at most
    /// 64 KiB) and checked, never replaced.
    func plistRefusal(_ job: NodeAgent.Job) -> StartRefusal? {
        let path = place.plistPath
        var status = stat()
        if lstat(path, &status) != 0 {
            guard errno == ENOENT else { return StartRefusal("the agent's file \(ConfigSeal.inert(path, limit: .max)) can't be read (errno \(errno)): nothing was started", exitCode: 1) }
            let data: Data
            switch NodeAgent.plist(job) {
            case .failure(let why): return why
            case .success(let made): data = made
            }
            try? FileManager.default.createDirectory(atPath: place.plistFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return StartRefusal("the agent's file \(ConfigSeal.inert(path, limit: .max)) couldn't be made (errno \(errno)): nothing was started", exitCode: 1) }
            let wrote = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            let synced = fsync(fd) == 0
            Sys.close(fd)
            guard wrote == data.count, synced else { return StartRefusal("the agent's file \(ConfigSeal.inert(path, limit: .max)) couldn't be written: nothing was started", exitCode: 1) }
        }
        guard let read = Self.readPlist(path) else {
            return StartRefusal("the agent's file \(ConfigSeal.inert(path, limit: .max)) isn't a regular file of at most 64 KiB: nothing was started", exitCode: 1)
        }
        if let why = NodeAgent.check(read, job: job) {
            return StartRefusal("the agent's file \(ConfigSeal.inert(path, limit: .max)) isn't the one start writes for build \(job.programArguments.first.map { ConfigSeal.inert($0, limit: 512) } ?? "?"): \(why); nothing was loaded, and the file was left as it is", exitCode: 77)
        }
        return nil
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
            + ", \(host.sessions) session\(host.sessions == 1 ? "" : "s")"
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
}

// MARK: This Mac's readers

extension MacAgent.Steps {
    /// This Mac's readers for `place`: its `launchctl` (no environment of this process's), Security's cdhash of a
    /// file, the host checked by `MacAgent.see`, the process table and the lock; the record (`pins`), what is said, the
    /// confirmation and the server's stop as the caller gives them.
    public static func system(place: NodeAgent.Place, pins: @escaping () -> Result<NodePins, NodePins.Refused>, say: @escaping (String) -> Void,
                              confirm: @escaping (_ what: String) -> Result<Void, StartRefusal>, serverStop: @escaping () -> Void) -> MacAgent.Steps {
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
            })
    }
}
