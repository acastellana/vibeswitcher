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
///   connections), and starts the child from `/proc/self/fd/<copy>`, the copy's mode put back first (as every start
///   from a sealed copy does: S2-D5), keeping only the copy and the connector, with
///   `--host-connector N --host-socket <the host's socket>` and the arguments `Launch` names. On the host's queue, in
///   the same turn as the spawn, the child's token is named as the connector's sender, then the child's end is closed
///   here: a request the child sends is read on that queue only after it.
/// - When the child ends: its connector is closed, which ends every connection made through it (so what the child
///   left open is no one's), then the child is reaped, then started again from the same copy with a fresh connector
///   after 1 s, doubling to 30 s, back to 1 s once a child had run 10 minutes. Each start and end is a line on stderr.
/// - When its connector closes on the host's side while the child runs (the child closed or shut its end, or the read
///   failed), the child can't reach the host again: it is ended at once (SIGKILL, `connectorClosed`), and a handover
///   meanwhile is refused (`handoverRefusal`). So **the server must never close or shut down its connector before it
///   exits**, not even on its way to a graceful exit: it would be killed mid-shutdown, and the host would log its
///   ordinary exit as "ended: its connector closed while it ran". It exits with the connector open, and the kernel
///   closes it (the engine plan's E1 says so too).
/// - While one runs, or is about to be started again, the host doesn't exit idle (`isRunning`, read by `tidy`).
/// - Across a handover (Task 8b, the document's S8) the child runs on: the state carries its record (`record`: its
///   pid and start ticks, the host's end of its connector, its sealed copy), and the new image takes it again only
///   once it has checked it (`restore`); otherwise it starts the server again.
/// - A handover to an installed build (Task 9d, S2-D8) carries that build's server too, a sealed copy checked against
///   its `build-info` (`State.images.server`): the new image takes it as the copy of every start from then on
///   (`carriedServer`), and when its bytes differ from the running child's, ends that child once idle (no connection
///   through its connector open, or `idleLimit` after it first looked) and starts it again from the new copy at once
///   (`replaceWhenIdle`), so the host and the server are the same build. A fallback closes the copy unused. Until then
///   the record a handover carries says what the running child runs (`runningImageSHA256`), so a second switch, or a
///   fallback to the build that was to replace it, still replaces a child of another build's bytes.
///
/// The Mac (the node on the Mac's step 3; the Mac app proves itself by its code, `AppProof`, and starts no server):
/// no sealed copies there. At the start the host reads the cdhash of the `--server` file (`Platform.CodeIdentity.cdhash`;
/// a file with none starts nothing) and keeps it, never the bytes: each start checks the file's cdhash is still that one
/// and starts the child from the file (`Image.checked`), and its connector, a stream pair, answers only that child's
/// pid as it runs that code (`HostServer.setAppConnectorChild`, Security's dynamic check), under the Hardened Runtime
/// (the Mac's non-dumpable: `Platform.CodeIdentity.isHardened`). So a file rewritten after the host loaded it starts
/// nothing that is the app, as on Linux. A handover carries no child there (`record` is nil: the Mac's process records
/// carry no start ticks): the new image starts the server again, and the old child, its connector closed by the exec,
/// exits. Nothing of this has run on a real Mac (docs/process/v2-mac-tasks.md).
public final class ServerChild {
    /// What a child is started from: Linux's sealed copy, or the Mac's file checked by the cdhash read at the start.
    enum Image {
        case sealed(Platform.ProcessSelf.SealedCopy)
        case checked(path: String, cdhash: Data)
    }

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
    private let image: Image
    private let launch: Launch

    private let lock = NSLock()
    /// The child that runs now: its pid, its token (taken in the spawn's turn; the pid can't be given again while
    /// this stands, as only `ended` and `stop` reap it, in the turn that clears this), its connector, when it started
    /// and the watch on its end; on `queue`.
    private var child: Running?
    private typealias Running = (pid: pid_t, token: Platform.PeerToken?, connector: Int32, startedAt: Date, watch: any Platform.Cancellable)
    private var restartPending = false
    /// The child being ended so that it starts again from a new build's server (`replaceWhenIdle`): started again at
    /// once when it ends, not after the wait.
    private var replacing: pid_t?
    /// The running child when it runs other bytes than `copy`'s (a switch carried another build's server, Task 9d): its
    /// pid and the SHA-256 of what it was started from (empty when not known), which a handover's record carries until
    /// it is started again from `copy`.
    private var due: (pid: pid_t, sha256: String)?
    private var stopped = false
    /// The web's listening sockets the host holds for its server (H1, `HostWebListeners`): asked for over the child's
    /// connector, held across the child's restarts and the host's handovers. Strict (the user's host's port alone)
    /// until `adopt` says the host is a scratch one.
    public let webListeners = HostWebListeners(usersHost: true, note: { _ in })
    private var delay = ServerChild.firstDelay
    private var restartCount = 0
    /// The children that ended stuck in a row (`stuckExit`); a child that ends any other way resets it. Under `lock`.
    private var stuckCount = 0
    private var lastEndRecord: HostNotes.ServerEnd?

    private convenience init(server: HostServer, copy: Platform.ProcessSelf.SealedCopy, launch: Launch) {
        self.init(server: server, image: .sealed(copy), launch: launch)
    }

    private init(server: HostServer, image: Image, launch: Launch) {
        self.server = server
        queue = server.queue
        self.image = image
        self.launch = launch
    }

    /// `main`'s hook, after the host has started: with `--server PATH` in `arguments`, the server child from it, as
    /// `launch(arguments:ownsLaunchers:socketPath:root:nodeRoot:environment:)` says, `nodeRoot` the host's install
    /// folder (`HostImages.Folders.installFolder`: `--node-root`'s, else its image's folder). The user's host
    /// (`ownsLaunchers`) refuses `--server-arg`, saying so; the Mac ignores `--server`, saying so (no server child there:
    /// the app proves itself by its code). `--server` stays in what a build this one hands over to is started with:
    /// without an install root (Task 9d) the new image's server is the same file.
    /// `restored`: the state a handover carried, if this image took over: its server child is taken again when
    /// `restore` finds it sound, and started again otherwise. `copy`: PATH's sealed copy when the host loaded it already
    /// (`HostImages.load`, which checked it against `build-info`): the one every start is from; nil: loaded here.
    ///
    /// The web's listening sockets a handover carried (H1, `State.webListeners`) are held on by the child's
    /// `webListeners`, checked first; with no child they are closed.
    @discardableResult
    public static func adopt(arguments: [String], ownsLaunchers: Bool, nodeRoot: String, config: HostServer.Config,
                             server: HostServer, restored: HostHandover.State? = nil,
                             copy: Platform.ProcessSelf.SealedCopy? = nil) -> ServerChild? {
        // On the host's queue, in one turn: the child's start or resume is queued behind it, so the carried sockets are
        // held before the child can ask for one (or let one go).
        var adopted: ServerChild?
        let work = {
            let child = adoptChild(arguments: arguments, ownsLaunchers: ownsLaunchers, nodeRoot: nodeRoot, config: config, server: server,
                                   restored: restored, copy: copy)
            var others = restored
            others?.webListeners = nil
            let otherDescriptors = Set(others?.descriptors ?? [])
            let carried = restored?.webListeners ?? []
            guard let child else {
                HostWebListeners.drop(carried, others: otherDescriptors)
                if !carried.isEmpty { say(server, "web listeners a handover carried closed: this image runs no server child") }
                return
            }
            child.webListeners.configure(usersHost: ownsLaunchers, note: { [weak server] line in if let server { say(server, line) } })
            child.webListeners.adopt(carried, others: otherDescriptors)
            adopted = child
        }
        if DispatchQueue.getSpecific(key: HostServer.queueKey) != nil { work() } else { server.queue.sync(execute: work) }
        return adopted
    }

    private static func adoptChild(arguments: [String], ownsLaunchers: Bool, nodeRoot: String, config: HostServer.Config,
                                   server: HostServer, restored: HostHandover.State?, copy: Platform.ProcessSelf.SealedCopy?) -> ServerChild? {
        // The new build's server a handover to an installed build carried (Task 9d): this image's when it is that build.
        let carried = carriedServer(restored)
        guard let (launch, refused) = Self.launch(arguments: arguments, ownsLaunchers: ownsLaunchers, socketPath: config.socketPath,
                                                  root: VibePaths.root.path, nodeRoot: nodeRoot,
                                                  environment: config.baseEnvironment) else {
            if let restored, let record = restored.serverChild {
                say(server, "server child record dropped: this image was started without --server")
                release(record, sessionPrograms: Self.programs(of: restored), otherDescriptors: Self.otherDescriptors(of: restored))
            }
            if let copy { Sys.close(copy.fd) }
            if let carried { Sys.close(carried.fd) }
            return nil
        }
        if !refused.isEmpty { say(server, "refused --server-arg: the user's host passes its server no test arguments") }
        if Platform.CodeIdentity.isAvailable {
            // The Mac: no sealed copy was loaded or carried, and no handover's record names a child (`record`).
            if let copy { Sys.close(copy.fd) }
            if let carried { Sys.close(carried.fd) }
            // The review of 2026-11-21: a child's connections are the app's, so only a scratch host runs one until the
            // Mac's node start is checked (`HostImages.macServerRefusal`).
            // A `--node` host runs one only from its checked start (`Config.checkedNode`, item 13), with that start's server.
            if arguments.contains(HostImages.nodeFlag) {
                guard let checked = config.checkedNode else {
                    say(server, "refused --server: a --node host on the Mac runs a server child only from a checked node start")
                    return nil
                }
                guard launch.image == checked.serverPath else {
                    say(server, "refused --server: \(launch.image) isn't the server its node start checked (\(checked.serverPath))")
                    return nil
                }
            } else if config.checkedNode == nil, let why = HostImages.macServerRefusal(lockPath: config.lockPath, ownsLaunchers: ownsLaunchers) {
                say(server, "refused --server: \(why)")
                return nil
            }
            return start(launch, server: server)
        }
        if let restored, let record = restored.serverChild {
            return restore(record, launch: launch, sessionPrograms: Self.programs(of: restored),
                           otherDescriptors: Self.otherDescriptors(of: restored), server: server, loaded: copy, carried: carried)
        }
        if let carried {
            if let copy { Sys.close(copy.fd) }
            return start(launch, server: server, loaded: carried)
        }
        return start(launch, server: server, loaded: copy)
    }

    /// The server's sealed copy `state` carried (`State.images.server`, Task 9d), adopted (`Platform.ProcessSelf.adopt`:
    /// all four seals, `0111`, made close-on-exec) only by the image it was carried for: the target, whose own copy is
    /// `images.own`. In a fallback (its own copy is `images.fallback`), or when it can't be adopted, closed when still
    /// inherited and no other descriptor of the state. Nil without one, and on the Mac.
    static func carriedServer(_ state: HostHandover.State?) -> Platform.ProcessSelf.SealedCopy? {
        guard !Platform.CodeIdentity.isAvailable, var others = state, let images = state?.images, let fd = images.server else { return nil }
        others.images?.server = nil
        guard isInherited(fd), !others.descriptors.contains(fd) else { return nil }
        if let own = HostImages.ownCopy?.fd, own == images.own, let copy = Platform.ProcessSelf.adopt(fd) { return copy }
        Sys.close(fd)
        return nil
    }

    /// The restored sessions' programs.
    private static func programs(of state: HostHandover.State) -> [pid_t] { state.sessions.map(\.info.childPID) }

    /// The descriptors `state` names besides the server child's own.
    private static func otherDescriptors(of state: HostHandover.State) -> Set<Int32> {
        var others = state
        others.serverChild = nil
        return Set(others.descriptors)
    }

    /// The server child a handover carried, taken again (on the host's queue) once `check` finds it sound: its
    /// connector's end adopted as the app's (`HostServer.adoptAppConnector`, its sender the child's token, still
    /// required non-dumpable), its sealed copy adopted for its next start, its end watched. The child runs on whatever
    /// `--server` it was started from: when the record names another path than this image's (a build that hands over
    /// to another passes that build's, S2-D7), or its copy is not one to take again (a copy this build wouldn't have
    /// made, a script's), its next start is from a fresh sealed copy of `launch.image`, and the copy it carried, when
    /// inherited and no other descriptor of the state, is closed. Whether the running child is started again at once
    /// from the new build's server is Task 9d's (`State.images`, by hash), not this check's. Otherwise the record is let
    /// go (`release`) and the server started again from a fresh sealed copy (`start`), saying why. Nil on the Mac, and
    /// where `start` is.
    /// `loaded`: `launch.image`'s copy the host loaded and checked already (`HostImages.load`), used in place of a fresh
    /// one, and closed when the carried copy is taken again instead.
    /// `carried`: the new build's server a handover to an installed build carried (`carriedServer`), the copy of every
    /// start from now on in place of `loaded` (closed); the running child, when its own copy's bytes differ from it, is
    /// ended once idle and started again from it (`replaceWhenIdle`).
    static func restore(_ record: HostHandover.ServerChildRecord, launch: Launch, sessionPrograms: [pid_t], otherDescriptors: Set<Int32>,
                        server: HostServer, loaded: Platform.ProcessSelf.SealedCopy? = nil,
                        carried: Platform.ProcessSelf.SealedCopy? = nil) -> ServerChild? {
        guard !Platform.CodeIdentity.isAvailable else { return nil }
        if let refusal = check(record, sessionPrograms: sessionPrograms, otherDescriptors: otherDescriptors) {
            say(server, "server child record refused: \(refusal); starting the server again")
            release(record, sessionPrograms: sessionPrograms, otherDescriptors: otherDescriptors)
            if let carried, let loaded { Sys.close(loaded.fd) }
            return start(launch, server: server, loaded: carried ?? loaded)
        }
        let carriedCopy = isInherited(record.image) && !otherDescriptors.contains(record.image) && record.image != record.connector
        if let carried {
            // What the running child runs: what the record says when a switch before left it to be replaced, else its
            // own copy's bytes (empty when they can't be read). Another build's when it differs from the carried copy.
            let running = record.runningImageSHA256
                ?? (carriedCopy ? Platform.ProcessSelf.adopt(record.image).map { BuildInfo.sha256(of: $0) } : nil) ?? ""
            let differs = running != BuildInfo.sha256(of: carried)
            if carriedCopy { Sys.close(record.image) }
            if let loaded { Sys.close(loaded.fd) }
            say(server, "server child pid \(record.pid) runs on; its next start is from the new build's server \(launch.image), carried"
                + (differs ? ", and it starts again from it once idle (another build's bytes)" : " (the same bytes)"))
            let child = ServerChild(server: server, copy: carried, launch: launch)
            server.queue.async {
                guard !server.stopped else {
                    return child.dropUnstarted(record, sessionPrograms: sessionPrograms, otherDescriptors: otherDescriptors)
                }
                server.serverChild = child
                child.resume(record, due: differs ? running : nil)
            }
            return child
        }
        let copy: Platform.ProcessSelf.SealedCopy
        if record.path == launch.image, carriedCopy, let adopted = Platform.ProcessSelf.adopt(record.image) {
            if let loaded { Sys.close(loaded.fd) }
            copy = adopted
        } else {
            switch loaded.map({ .success($0) }) ?? Platform.ProcessSelf.sealedCopy(of: launch.image, name: "vibeswitcher-server") {
            case .success(let fresh):
                if carriedCopy { Sys.close(record.image) }
                say(server, record.path == launch.image
                    ? "server child pid \(record.pid)'s sealed copy wasn't one to take again: \(launch.image) loaded again for its next start"
                    : "server child pid \(record.pid) runs on from \(record.path); its next start is from this image's --server \(launch.image)")
                copy = fresh
            case .failure(let error):
                say(server, "server child record refused: no sealed copy to start it again from (errno \(error.code)); starting the server again")
                release(record, sessionPrograms: sessionPrograms, otherDescriptors: otherDescriptors)
                return start(launch, server: server)
            }
        }
        // A switch before left the child to be started again from its build's server (a fallback to that build, or a
        // handover without an install root since): still due when this image's copy is other bytes than it runs.
        let due = record.runningImageSHA256.flatMap { $0 != BuildInfo.sha256(of: copy) ? $0 : nil }
        if due != nil {
            say(server, "server child pid \(record.pid) still runs another build's server: it starts again from \(launch.image) once idle")
        }
        let child = ServerChild(server: server, copy: copy, launch: launch)
        server.queue.async {
            guard !server.stopped else {
                return child.dropUnstarted(record, sessionPrograms: sessionPrograms, otherDescriptors: otherDescriptors)
            }
            server.serverChild = child
            child.resume(record, due: due)
        }
        return child
    }

    /// Why `record` is not the server child this image may take again, or nil when it is: `pid` is this process's
    /// child, started at `startTicks` (so it is the process the build before recorded, and its pid can't have been given
    /// again: this process hasn't reaped it), no restored session's program and no parser; and its connector is a
    /// `SOCK_SEQPACKET` socket this image inherited across the exec (not close-on-exec, which every descriptor this
    /// image makes is from its making) and no other descriptor of the state. The `--server` path it names is not asked
    /// (S2-D8: a handover to another build keeps the running child; `restore` starts the next one from this image's).
    /// `links` and `isParser`: how a process is read (tests give a table).
    static func check(_ record: HostHandover.ServerChildRecord, sessionPrograms: [pid_t], otherDescriptors: Set<Int32>,
                      links: (pid_t) -> Platform.Processes.Link? = Platform.Processes.link,
                      isParser: (pid_t) -> Bool = HostProcesses.isParser) -> String? {
        let pid = record.pid
        guard pid > 1, let link = links(pid) else { return "pid \(pid) is gone" }
        guard link.parent == getpid() else { return "pid \(pid) isn't this host's child" }
        guard link.startTicks == record.startTicks else { return "pid \(pid) isn't the process recorded (it started at another time)" }
        guard !sessionPrograms.contains(pid) else { return "pid \(pid) is a session's program" }
        guard !isParser(pid) else { return "pid \(pid) is a session's parser" }
        guard !otherDescriptors.contains(record.connector), isInherited(record.connector), isConnector(record.connector) else {
            return "its connector \(record.connector) isn't a connector handed over"
        }
        return nil
    }

    /// Whether `fd` is open, above 2, and not close-on-exec: a descriptor this image inherited across the exec
    /// (`keep:` unmarks what it keeps), as nothing this image made is.
    private static func isInherited(_ fd: Int32) -> Bool {
        guard fd > STDERR_FILENO else { return false }
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && flags & FD_CLOEXEC == 0
    }

    /// Whether `fd` is a `SOCK_SEQPACKET` socket, as a connector is.
    private static func isConnector(_ fd: Int32) -> Bool {
        var type: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) == 0 && type == Platform.Sockets.seqpacket
    }

    /// A record not taken: each of its descriptors this image inherited and the state names nothing else by, closed
    /// (never one this image made since, nor another part of the state's); its process ended and reaped only when it
    /// is what the record says, this host's child started then, and neither a session's program nor a parser (the
    /// old server, which can't be reached again without its connector). Anything else it names is left alone.
    private static func release(_ record: HostHandover.ServerChildRecord, sessionPrograms: [pid_t], otherDescriptors: Set<Int32>) {
        for fd in Set([record.connector, record.image]) where isInherited(fd) && !otherDescriptors.contains(fd) { Sys.close(fd) }
        guard let link = Platform.Processes.link(record.pid), link.parent == getpid(), link.startTicks == record.startTicks,
              !sessionPrograms.contains(record.pid), !HostProcesses.isParser(record.pid) else { return }
        kill(record.pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(record.pid, &status, 0) < 0, errno == EINTR {}
    }

    /// What `--server PATH` in `arguments` starts (nil without it): for the node's host (`--node` in `arguments`)
    /// `--node --node-root NODE-ROOT`, else `--root ROOT --node-root NODE-ROOT` (S2-D1; NODE-ROOT the host's install
    /// folder, `HostImages.Folders.installFolder`), then each `--server-arg X` as X, for a scratch host only. `refused`:
    /// the `--server-arg` values the user's host (`ownsLaunchers`) left out.
    static func launch(arguments: [String], ownsLaunchers: Bool, socketPath: String, root: String, nodeRoot: String,
                       environment: [String: String]) -> (launch: Launch, refused: [String])? {
        guard let at = arguments.firstIndex(of: "--server"), arguments.indices.contains(at + 1) else { return nil }
        let serverArguments = arguments.indices.dropLast().filter { arguments[$0] == "--server-arg" }.map { arguments[$0 + 1] }
        let place = arguments.contains(HostImages.nodeFlag) ? [HostImages.nodeFlag, "--node-root", nodeRoot] : ["--root", root, "--node-root", nodeRoot]
        let launch = Launch(image: arguments[at + 1], socketPath: socketPath,
                            arguments: place + (ownsLaunchers ? [] : serverArguments),
                            environment: environment)
        return (launch, ownsLaunchers ? serverArguments : [])
    }

    /// Loads `launch.image` into a sealed copy (or takes `loaded`, the host's checked copy of it) and starts the child
    /// from it on the host's queue (the host started already), unless the host has stopped by then. Nil, said on
    /// stderr, when the copy can't be made. The Mac: `launch.image`'s cdhash read instead (nil, said, when it has none),
    /// each start from the file once its cdhash is still that (`Image.checked`).
    public static func start(_ launch: Launch, server: HostServer, loaded: Platform.ProcessSelf.SealedCopy? = nil) -> ServerChild? {
        if Platform.CodeIdentity.isAvailable {
            // A checked Mac node start's child is checked by its row's server, as its start found it (`Config.checkedNode`).
            let pinned: Result<Data, HostImages.Refused> = server.config.checkedNode.map { .success($0.server) }
                ?? Platform.CodeIdentity.cdhash(atPath: launch.image).map { .success($0) }
                    ?? .failure(HostImages.Refused("\(launch.image) has no code signature to check it by (no cdhash)"))
            let cdhash: Data
            switch pinned {
            case .failure(let why):
                say(server, "no server child: \(why.description)")
                return nil
            case .success(let read): cdhash = read
            }
            let child = ServerChild(server: server, image: .checked(path: launch.image, cdhash: cdhash), launch: launch)
            server.queue.async {
                guard !server.stopped else { return child.dropUnstarted() }
                server.serverChild = child
                child.spawn()
            }
            return child
        }
        switch loaded.map({ .success($0) }) ?? Platform.ProcessSelf.sealedCopy(of: launch.image, name: "vibeswitcher-server") {
        case .failure(let error):
            say(server, "no server child: \(launch.image) couldn't be loaded (errno \(error.code))")
            return nil
        case .success(let copy):
            let child = ServerChild(server: server, copy: copy, launch: launch)
            server.queue.async {
                guard !server.stopped else { return child.dropUnstarted() }
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

    /// How many children in a row ended stuck: the server's watchdog's exit (`stuckExit`), its engine's queue
    /// unanswered for its limit. The host's notes carry it, and the next server's `status` says so past a few.
    public var stuckInARow: Int { lock.withLock { stuckCount } }

    /// The exit code of a server that ends itself stuck (`NodeHealth.exitStuck`): EX_SOFTWARE.
    public static let stuckExit: Int32 = 70
    /// How the child last ended on its own (`ended`, not a replacement's end), nil: none under this image.
    public var lastEnd: HostNotes.ServerEnd? { lock.withLock { lastEndRecord } }

    /// The child running now as a handover carries it (`HostHandover.State.serverChild`): nil when none runs, or its
    /// connector has closed (a handover then waits: `handoverRefusal`). On the host's queue.
    var record: HostHandover.ServerChildRecord? {
        guard case .sealed(let copy) = image, let server, let running = lock.withLock({ child }),
              let end = server.appConnectorEnd(running.connector), let link = Platform.Processes.link(running.pid) else { return nil }
        let due = lock.withLock { self.due }.flatMap { $0.pid == running.pid ? $0.sha256 : nil }
        return HostHandover.ServerChildRecord(pid: running.pid, startTicks: link.startTicks, connector: end, image: copy.fd,
                                              path: launch.image, runningImageSHA256: due)
    }

    /// Why a handover can't be made now, or nil: a child runs whose connector has closed, so it is being ended to start
    /// again (`replaceWhenIdle`, `connectorClosed`), and no record can name it (`record`): the new image would start a
    /// second server child beside it, and nothing would watch or reap the first. Asked by a handover before anything
    /// else and again in the turn it builds its state and executes the new image. On the host's queue.
    var handoverRefusal: String? {
        guard let server, let running = lock.withLock({ child }), server.appConnectorEnd(running.connector) == nil else { return nil }
        return "the server child pid \(running.pid) is being ended, to start again; try again in a moment"
    }

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
            if case .sealed(let copy) = self.image { Sys.close(copy.fd) }
            self.webListeners.closeAll()
        }
        if DispatchQueue.getSpecific(key: HostServer.queueKey) != nil { work() } else { queue.sync(execute: work) }
    }

    /// A server child the host stopped before it took it (`HostServer.stop` ran on the queue first, finding no
    /// `serverChild` to stop): started never, its copy closed (`stop`), and the carried child of `record`, when there is
    /// one, ended and reaped with its connector closed (`release`), so a host that stops and waits to exit
    /// (`--exit-with`'s, for its sessions' end) leaves no server child behind. On `queue`.
    private func dropUnstarted(_ record: HostHandover.ServerChildRecord? = nil, sessionPrograms: [pid_t] = [], otherDescriptors: Set<Int32> = []) {
        if let server { Self.say(server, "no server child: the host stopped before it was started" + (record.map { "; pid \($0.pid) ended" } ?? "")) }
        if let record { Self.release(record, sessionPrograms: sessionPrograms, otherDescriptors: otherDescriptors) }
        stop()
    }

    /// One start: the copy's mode put back (`Platform.ProcessSelf.restoreMode`: something that reached the copy may
    /// have changed it, and a child started from a readable image is dumpable from its exec), a fresh connector, the
    /// child from the copy, its token named, its end closed here. A copy whose mode can't be put back starts nothing:
    /// tried again after the wait. On `queue`.
    private func spawn() {
        guard let server, !server.stopped, !lock.withLock({ stopped }) else { return }
        lock.withLock { restartPending = false }
        // What runs: Linux's sealed copy, its mode put back and kept across the spawn, named to the image; the Mac's file,
        // still the code the host loaded.
        let prepared: (executable: String, kept: [Int32], named: [String], from: String)
        switch image {
        case .sealed(let copy):
            // Cleared first: restoreMode's refusals of a copy not fully sealed, or not a regular file, fail no call.
            errno = 0
            guard Platform.ProcessSelf.restoreMode(of: copy.fd) else {
                Self.say(server, "server child not started: the mode of \(launch.image)'s sealed copy couldn't be put back ("
                          + Self.whyModeWasntPutBack(errno: errno) + ")")
                return scheduleRestart()
            }
            prepared = (copy.path, [copy.fd], ["\(Platform.ProcessSelf.imageVariable)=\(copy.fd)"], "\(launch.image)'s sealed copy")
        case .checked(let path, let cdhash):
            guard Platform.CodeIdentity.cdhash(atPath: path) == cdhash else {
                Self.say(server, "server child not started: \(path) isn't the code the host loaded (its cdhash changed, or can't be read)")
                return scheduleRestart()
            }
            prepared = (path, [], [], "\(path), its cdhash checked")
        }
        let (executable, kept, named, from) = prepared
        guard let connector = server.openServerChildConnector(requireNonDumpable: true, onDumpable: { [weak self] pid in
            self?.endDumpable(pid)
        }, onClosed: { [weak self] number in
            self?.connectorClosed(number)
        }) else {
            Self.say(server, "no server child: no connector could be made (errno \(errno))")
            return scheduleRestart()
        }
        var spawn = Platform.Spawn(executable: executable,
                                   arguments: ["vibeswitcher-server", "--host-connector", String(connector), "--host-socket", launch.socketPath]
                                       + launch.arguments)
        spawn.environment = launch.environment.filter { $0.key != Platform.ProcessSelf.imageVariable }.map { "\($0.key)=\($0.value)" } + named
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.keep = kept + [connector]
        spawn.group = .ownGroup
        switch spawn.start() {
        case .failure(let error):
            server.closeAppConnector(connector)
            Sys.close(connector)
            Self.say(server, "server child didn't start from \(from) (errno \(error.code))")
            scheduleRestart()
        case .success(let pid):
            // In this turn: the connector's requests are read on this queue, so none is answered before its sender is.
            let token = Platform.Processes.token(pid)
            if case .checked(_, let cdhash) = image {
                server.setAppConnectorChild(pid, code: cdhash, for: connector)
            } else {
                server.setAppConnectorSender(token, for: connector)
            }
            Sys.close(connector)
            let watch = Platform.ProcessExit.watch(pid, queue: queue) { [weak self] in self?.ended(pid) }
            lock.withLock { child = (pid, token, connector, Platform.Clock.steadyDate(), watch) }
            Self.say(server, "server child pid \(pid) started from \(from), connector \(connector)")
        }
    }

    /// Why `Platform.ProcessSelf.restoreMode` gave false, from the errno it left after `spawn` cleared it: a call's
    /// errno (getting the seals, `fstat`, `pread` or `fchmod` failed), or, when none failed, that the copy isn't a fully
    /// sealed regular file (its refusals that fail no call, where an errno shown would be an older call's).
    static func whyModeWasntPutBack(errno code: Int32) -> String {
        code == 0 ? "it isn't a fully sealed regular file" : "errno \(code)"
    }

    /// The child a handover carried (`restore` checked it), taken again: its connector's end the app's, its sender its
    /// token, its end watched. `due`: the SHA-256 of what it runs when that isn't `copy`'s bytes (empty when not known):
    /// it is then started again from `copy` once idle (`replaceWhenIdle`). On `queue`.
    private func resume(_ record: HostHandover.ServerChildRecord, due: String? = nil) {
        guard let server, !server.stopped, !lock.withLock({ stopped }) else { return }
        let pid = record.pid
        let token = Platform.Processes.token(pid)
        guard server.adoptAppConnector(record.connector, sender: token, requireNonDumpable: true, onDumpable: { [weak self] pid in
            self?.endDumpable(pid)
        }, onClosed: { [weak self] number in
            self?.connectorClosed(number)
        }) else {
            Self.say(server, "server child pid \(pid) not taken again: its connector \(record.connector) couldn't be adopted; starting the server again")
            kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            return scheduleRestart()
        }
        let watch = Platform.ProcessExit.watch(pid, queue: queue) { [weak self] in self?.ended(pid) }
        lock.withLock {
            child = (pid, token, record.connector, Platform.Clock.steadyDate(), watch)
            self.due = due.map { (pid, $0) }
        }
        Self.say(server, "server child pid \(pid) carried over from the build before, connector \(record.connector)")
        if due != nil { replaceWhenIdle(pid, carriedAt: Platform.Clock.steadyDate()) }
    }

    /// The child `pid` ended: its connector closed (its connections with it), it reaped, and started again. On `queue`.
    private func ended(_ pid: pid_t) {
        guard let server, let running = lock.withLock({ child }), running.pid == pid else { return }
        running.watch.cancel()
        server.closeAppConnector(running.connector)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        let ran = Platform.Clock.steadyDate().timeIntervalSince(running.startedAt)
        let stuck = status & 0x7f == 0 && (status >> 8) & 0xff == Self.stuckExit
        let replaced = lock.withLock { () -> Bool in
            child = nil
            stuckCount = stuck ? stuckCount + 1 : 0
            if due?.pid == pid { due = nil }
            if ran >= Self.steadyRun { delay = Self.firstDelay }
            defer { if replacing == pid { replacing = nil } }
            return replacing == pid
        }
        if replaced {
            Self.say(server, "server child pid \(pid) ended for the new build's server: \(HostLog.waitStatus(status)); started again from it now")
            return spawn()
        }
        let inARow = lock.withLock { stuckCount }
        lock.withLock { lastEndRecord = HostNotes.ServerEnd(at: Date(), ran: ran, cause: HostNotes.ServerEnd.cause(status: status)) }
        Self.say(server, "server child pid \(pid) ended after \(Int(ran)) s: \(HostLog.waitStatus(status))"
                 + (stuck ? " (stuck: its engine's queue didn't answer; \(inARow) in a row)" : "") + "; started again in \(Int(lock.withLock { delay })) s")
        scheduleRestart()
    }

    /// The child `pid`, which a handover carried from the build before (`restore`) and which runs another build's
    /// server, ended once no connection through its connector is open (each `HostCall` is a connection of its own), or
    /// once `idleLimit` has gone by since the first look (a server keeps a connection open for the host's events, so
    /// "no connection open" may never come), looked at every `idleLook`: its connector closed and SIGTERM, SIGKILL if
    /// it still runs `replaceLimit` later. `ended` then starts it again at once from this child's copy, the new build's
    /// server. Nothing once `pid` isn't the child running (it ended meanwhile, and its start again was from `copy`).
    /// A scratch host's `replaceHoldTestFlag` holds the first look until its file exists. On `queue`.
    ///
    /// `carriedAt`: when `resume` took the child. The exec ended every connection it had, so "none open" doesn't say it
    /// is idle until it has connected again: a request it was answering may wait for its link's next welcome to reply
    /// (`build.switch`, which says how the switch went from the new image's welcome and notes: the start plan's S8b).
    /// The first look waits until a connection was made through its connector since, or `reconnectGrace`.
    func replaceWhenIdle(_ pid: pid_t, firstLook: Date? = nil, carriedAt: Date? = nil) {
        guard let server, !lock.withLock({ stopped }), let running = lock.withLock({ child }), running.pid == pid else { return }
        let again = { (since: Date?) in
            self.queue.asyncAfter(deadline: .now() + Self.idleLook) { [weak self] in self?.replaceWhenIdle(pid, firstLook: since, carriedAt: carriedAt) }
        }
        if let hold = Self.replaceHold, access(hold, F_OK) != 0 { return again(nil) }
        if firstLook == nil, let carriedAt, server.appConnectionsMade(through: running.connector) == 0,
           Platform.Clock.steadyDate().timeIntervalSince(carriedAt) < Self.reconnectGrace {
            return again(nil)
        }
        let since = firstLook ?? Platform.Clock.steadyDate()
        let open = server.appConnectionsOpen(through: running.connector)
        guard open == 0 || Platform.Clock.steadyDate().timeIntervalSince(since) >= Self.idleLimit else { return again(since) }
        lock.withLock { replacing = running.pid }
        Self.say(server, open == 0
                 ? "server child pid \(running.pid) idle: ended, to start again from the new build's server"
                 : "server child pid \(running.pid) still had \(open) connections open \(Int(Self.idleLimit)) s after the switch: ended, to start again from the new build's server")
        server.closeAppConnector(running.connector)
        kill(running.pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + Self.replaceLimit) { [weak self] in
            guard let self, self.lock.withLock({ self.child?.pid }) == running.pid else { return }
            kill(running.pid, SIGKILL)
        }
    }

    /// How often `replaceWhenIdle` looks again, how long it waits for no connection open before it ends the child
    /// anyway, and how long a child it ended may take to go before SIGKILL.
    static let idleLook: TimeInterval = 0.2
    static let idleLimit: TimeInterval = 30
    /// How long the first look at a child just carried over waits for it to connect again (`replaceWhenIdle`'s
    /// `carriedAt`): a server's link tries again 0.2 s after its connection was lost, and its request waits in the
    /// connector until this image takes it.
    static let reconnectGrace: TimeInterval = 10
    static let replaceLimit: TimeInterval = 10

    /// A scratch host's test flag: `replaceWhenIdle` doesn't look until PATH exists (a test's switch left pending).
    /// Carried across a scratch host's handovers, so the image a switch went to holds too.
    public static let replaceHoldTestFlag = "--server-test-replace-hold"

    /// `replaceHoldTestFlag`'s path, set by `HostHardening.afterConfig` for a scratch host on Linux; nil: none, the user's
    /// host's always.
    static var replaceHold: String? {
        get { holdLock.withLock { holdPath } }
        set { holdLock.withLock { holdPath = newValue } }
    }
    private static let holdLock = NSLock()
    nonisolated(unsafe) private static var holdPath: String?

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

    /// The connector `number` closed on the host's side by itself (its read failed, or its other end was closed or shut
    /// for writing: `AppConnector.onClosed`) while its child may still run: that child can't reach the host again, so
    /// it is ended (SIGKILL), and `ended` reaps it and starts it again. Otherwise it would run on as no one's app, keep
    /// the host from exiting idle, and be a child no handover's record can name. Nothing when it isn't the running
    /// child's connector, or the child has ended already (a child's end closes its connector's other end too: `ended`
    /// is on its way). On `queue`.
    private func connectorClosed(_ number: Int32) {
        guard let server, !lock.withLock({ stopped }), let running = lock.withLock({ child }), running.connector == number else { return }
        if case .brief(let brief) = Platform.Processes.brief(running.pid), brief.state == .zombie || brief.exiting { return }
        Self.say(server, "server child pid \(running.pid) ended: its connector \(number) closed while it ran")
        kill(running.pid, SIGKILL)
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
        Platform.Stdio.error("vibeswitcher-host: \(line)\n")
    }
}
