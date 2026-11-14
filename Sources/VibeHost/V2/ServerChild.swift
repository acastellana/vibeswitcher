import Foundation
import VibeCore

/// The app on Linux (the stage 2 plan's S2-D1, Task 8a; the security architecture document's S2): the server child,
/// a process the host starts itself from a sealed copy of `--server PATH` and talks to through an app connector it
/// inherits (`AppConnector`). Every connection the host makes through that connector, and only those, is the app.
///
/// - At the host's start PATH is read once into a sealed copy (`Platform.ProcessSelf.sealedCopy`): what runs, and
///   every restart, is that copy, never the file again, so a file rewritten in place after the host loaded it is never
///   what the host runs; and the child, started from an image it can't read, is non-dumpable from its exec.
/// - Each start opens a fresh connector (`HostServer.openAppConnector`, the child's end close-on-exec here), asking
///   that the child stay non-dumpable (a dumpable child is refused and ended: any process of the user could take its
///   connections), and starts the child from `/proc/self/fd/<copy>` keeping only the copy and the connector, with
///   `--host-connector N --host-socket <the host's socket>` and the arguments `Launch` names. On the host's queue, in
///   the same turn as the spawn, the child's token is named as the connector's sender, then the child's end is closed
///   here: a request the child sends is read on that queue only after it.
/// - When the child ends: its connector is closed, which ends every connection made through it (so what the child
///   left open is no one's), then the child is reaped, then started again from the same copy with a fresh connector
///   after 1 s, doubling to 30 s, back to 1 s once a child had run 10 minutes. Each start and end is a line on stderr.
/// - While one runs, or is about to be started again, the host doesn't exit idle (`isRunning`, read by `tidy`).
///
/// The Mac has none: no sealed copies there, no connector (its app proves itself by its code, `AppProof`), and
/// `start` gives nil.
public final class ServerChild {
    /// What the child is started with besides its connector and the host's socket.
    public struct Launch {
        /// The `--server` path: its sealed copy is what runs.
        public var image: String
        /// The host's socket path, given as `--host-socket`.
        public var socketPath: String
        /// After `--host-connector N --host-socket PATH`: `--root` and `--node-root` (S2-D1), then each `--server-arg`.
        public var arguments: [String]
        /// The host's base environment: `VIBESWITCHER_IMAGE_FD` is added.
        public var environment: [String: String]

        public init(image: String, socketPath: String, arguments: [String], environment: [String: String]) {
            self.image = image
            self.socketPath = socketPath
            self.arguments = arguments
            self.environment = environment
        }
    }

    /// The first wait before a start again, and the longest.
    static let firstDelay: TimeInterval = 1
    static let longestDelay: TimeInterval = 30
    /// A child that ran this long resets the wait to `firstDelay`.
    static let steadyRun: TimeInterval = 600

    private weak var server: HostServer?
    private let queue: DispatchQueue
    private let copy: Platform.ProcessSelf.SealedCopy
    private let launch: Launch

    private let lock = NSLock()
    /// The child that runs now: its pid, its token (taken in the spawn's turn; the pid can't be given again while
    /// this stands, as only `ended` and `stop` reap it, in the turn that clears this), its connector, when it started
    /// and the watch on its end; on `queue`.
    private var child: Running?
    private typealias Running = (pid: pid_t, token: Platform.PeerToken?, connector: Int32, startedAt: Date, watch: any Platform.Cancellable)
    private var restartPending = false
    private var stopped = false
    private var delay = ServerChild.firstDelay
    private var restartCount = 0

    private init(server: HostServer, copy: Platform.ProcessSelf.SealedCopy, launch: Launch) {
        self.server = server
        queue = server.queue
        self.copy = copy
        self.launch = launch
    }

    /// `main`'s hook, after the host has started: with `--server PATH` in `arguments`, the server child from it, as
    /// `launch(arguments:ownsLaunchers:socketPath:root:nodeRoot:environment:)` says. The user's host (`ownsLaunchers`)
    /// refuses `--server-arg`, saying so; the Mac ignores `--server`, saying so (no server child there: the app proves
    /// itself by its code). `--server` stays in what a build this one hands over to is started with: without an
    /// install root (Task 9d) the new image's server is the same file.
    @discardableResult
    public static func adopt(arguments: [String], ownsLaunchers: Bool, executable: String, config: HostServer.Config,
                             server: HostServer) -> ServerChild? {
        guard let (launch, refused) = Self.launch(arguments: arguments, ownsLaunchers: ownsLaunchers, socketPath: config.socketPath,
                                                  root: VibePaths.root.path,
                                                  nodeRoot: URL(fileURLWithPath: executable).deletingLastPathComponent().path,
                                                  environment: config.baseEnvironment) else { return nil }
        guard !Platform.CodeIdentity.isAvailable else {
            say(server, "ignored --server: this system has no server child (the app proves itself by its code)")
            return nil
        }
        if !refused.isEmpty { say(server, "refused --server-arg: the user's host passes its server no test arguments") }
        return start(launch, server: server)
    }

    /// What `--server PATH` in `arguments` starts (nil without it): `--root ROOT --node-root NODE-ROOT` (S2-D1; until
    /// Task 9b the node root is the host's executable's folder), then each `--server-arg X` as X, for a scratch host
    /// only. `refused`: the `--server-arg` values the user's host (`ownsLaunchers`) left out.
    static func launch(arguments: [String], ownsLaunchers: Bool, socketPath: String, root: String, nodeRoot: String,
                       environment: [String: String]) -> (launch: Launch, refused: [String])? {
        guard let at = arguments.firstIndex(of: "--server"), arguments.indices.contains(at + 1) else { return nil }
        let serverArguments = arguments.indices.dropLast().filter { arguments[$0] == "--server-arg" }.map { arguments[$0 + 1] }
        let launch = Launch(image: arguments[at + 1], socketPath: socketPath,
                            arguments: ["--root", root, "--node-root", nodeRoot] + (ownsLaunchers ? [] : serverArguments),
                            environment: environment)
        return (launch, ownsLaunchers ? serverArguments : [])
    }

    /// Loads `launch.image` into a sealed copy and starts the child from it on the host's queue (the host started
    /// already). Nil, said on stderr, when the copy can't be made (the Mac has none: ENOTSUP), and on the Mac.
    public static func start(_ launch: Launch, server: HostServer) -> ServerChild? {
        guard !Platform.CodeIdentity.isAvailable else { return nil }
        switch Platform.ProcessSelf.sealedCopy(of: launch.image, name: "vibeswitcher-server") {
        case .failure(let error):
            say(server, "no server child: \(launch.image) couldn't be loaded (errno \(error.code))")
            return nil
        case .success(let copy):
            let child = ServerChild(server: server, copy: copy, launch: launch)
            server.queue.async {
                server.serverChild = child
                child.spawn()
            }
            return child
        }
    }

    /// Whether a child runs now or is about to be started again: the host isn't idle meanwhile.
    public var isRunning: Bool { lock.withLock { !stopped && (child != nil || restartPending) } }

    /// The child running now; nil between a child's end and its start again.
    public var pid: pid_t? { lock.withLock { child?.pid } }

    /// The token of the child running now (`Platform.Processes.token`: pid, uid, start ticks), recorded in the spawn's
    /// turn and named as its connector's sender; nil between a child's end and its start again.
    public var token: Platform.PeerToken? { lock.withLock { child?.token } }

    /// How many times a child was started again after one ended.
    public var restarts: Int { lock.withLock { restartCount } }

    /// No more starts: the child running is ended (SIGKILL) and reaped, its connector closed, and the copy closed.
    /// `HostServer.stop` calls it first, so a host that stops and then waits to exit (`--exit-with`'s, for its
    /// sessions' end) starts no child again meanwhile; a host whose process just exits leaves the child to see its
    /// connector close.
    public func stop() {
        let work = {
            let (first, running) = self.lock.withLock { () -> (Bool, Running?) in
                guard !self.stopped else { return (false, nil) }
                self.stopped = true
                defer { self.child = nil }
                return (true, self.child)
            }
            guard first else { return }
            if let running {
                running.watch.cancel()
                self.server?.closeAppConnector(running.connector)
                kill(running.pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(running.pid, &status, 0) < 0, errno == EINTR {}
            }
            Sys.close(self.copy.fd)
        }
        if DispatchQueue.getSpecific(key: HostServer.queueKey) != nil { work() } else { queue.sync(execute: work) }
    }

    /// One start: a fresh connector, the child from the copy, its token named, its end closed here. On `queue`.
    private func spawn() {
        guard let server, !lock.withLock({ stopped }) else { return }
        lock.withLock { restartPending = false }
        guard let connector = server.openAppConnector(expecting: nil, requireNonDumpable: true, onDumpable: { [weak self] pid in
            self?.endDumpable(pid)
        }) else {
            Self.say(server, "no server child: no connector could be made (errno \(errno))")
            return scheduleRestart()
        }
        var spawn = Platform.Spawn(executable: copy.path,
                                   arguments: ["vibeswitcher-server", "--host-connector", String(connector), "--host-socket", launch.socketPath]
                                       + launch.arguments)
        spawn.environment = launch.environment.filter { $0.key != Platform.ProcessSelf.imageVariable }.map { "\($0.key)=\($0.value)" }
            + ["\(Platform.ProcessSelf.imageVariable)=\(copy.fd)"]
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.keep = [copy.fd, connector]
        spawn.group = .ownGroup
        switch spawn.start() {
        case .failure(let error):
            server.closeAppConnector(connector)
            Sys.close(connector)
            Self.say(server, "server child didn't start from \(launch.image)'s sealed copy (errno \(error.code))")
            scheduleRestart()
        case .success(let pid):
            // In this turn: the connector's requests are read on this queue, so none is answered before its sender is.
            let token = Platform.Processes.token(pid)
            server.setAppConnectorSender(token, for: connector)
            Sys.close(connector)
            let watch = Platform.ProcessExit.watch(pid, queue: queue) { [weak self] in self?.ended(pid) }
            lock.withLock { child = (pid, token, connector, Date(), watch) }
            Self.say(server, "server child pid \(pid) started from \(launch.image)'s sealed copy, connector \(connector)")
        }
    }

    /// The child `pid` ended: its connector closed (its connections with it), it reaped, and started again. On `queue`.
    private func ended(_ pid: pid_t) {
        guard let server, let running = lock.withLock({ child }), running.pid == pid else { return }
        running.watch.cancel()
        server.closeAppConnector(running.connector)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        let ran = Date().timeIntervalSince(running.startedAt)
        lock.withLock {
            child = nil
            if ran >= Self.steadyRun { delay = Self.firstDelay }
        }
        Self.say(server, "server child pid \(pid) ended after \(Int(ran)) s: \(HostLog.waitStatus(status)); started again in \(Int(lock.withLock { delay })) s")
        scheduleRestart()
    }

    /// A start again after the wait, which then doubles (to `longestDelay`). On `queue`.
    private func scheduleRestart() {
        let wait = lock.withLock { () -> TimeInterval? in
            guard !stopped else { return nil }
            restartPending = true
            let wait = delay
            delay = min(delay * 2, Self.longestDelay)
            return wait
        }
        guard let wait else { return }
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.restartCount += 1 }
            self.spawn()
        }
    }

    /// The child asked for a connection while dumpable: refused already (the connector's log line says why); ended
    /// here, so it starts again non-dumpable. On `queue`.
    private func endDumpable(_ pid: pid_t) {
        guard let server, lock.withLock({ child?.pid }) == pid else { return }
        Self.say(server, "server child pid \(pid) ended: it was dumpable when it asked for a connection")
        kill(pid, SIGKILL)
    }

    /// A line in the host's log and on its stderr.
    private static func say(_ server: HostServer, _ line: String) {
        server.note("host: " + line)
        FileHandle.standardError.write(Data("vibeswitcher-host: \(line)\n".utf8))
    }
}
