import Darwin
import Foundation
import VibeCore

/// The session host: one per user (a lock file), serving the app over a Unix socket. Everything runs on `queue`.
public final class HostServer {
    public struct Config {
        public var socketPath: String
        public var lockPath: String
        public var shell: String
        /// Starts each session's program (see `PTYSpawn`); the host's own executable.
        public var launcher: String
        public var baseEnvironment: [String: String]
        public var hostBuild: Int
        public var ringCapacity = 8 << 20
        /// Quit after this long with no live session and no app connected; nil: never.
        public var idleExit: TimeInterval? = 600
        /// Ended sessions are forgotten after this long.
        public var keepEnded: TimeInterval = 24 * 3600
        public var housekeepingInterval: TimeInterval = 30
        /// What this host was started with after its executable (socket, lock, idle exit): a build it hands over to is
        /// started with the same.
        public var arguments: [String] = []
        /// The old build's own copy (see `HostHandover`): where a build this host hands over to goes back to if it
        /// can't restore. Nil: `launcher`.
        public var fallback: String?

        /// Where a handover leaves the sessions for the next build: beside the lock, so a scratch host's stays its own.
        public var handoverPath: String { lockPath + ".handover" }

        public init(socketPath: String, lockPath: String, shell: String, launcher: String, baseEnvironment: [String: String],
                    hostBuild: Int) {
            self.socketPath = socketPath
            self.launcher = launcher
            self.lockPath = lockPath
            self.shell = shell
            self.baseEnvironment = baseEnvironment
            self.hostBuild = hostBuild
        }
    }

    public enum Failure: Error, Equatable {
        case alreadyRunning
        case lock(Int32)
    }

    public let queue = DispatchQueue(label: "vibeswitcher.host")
    /// Called (on `queue`) after an idle exit or an accepted `shutdown`, once everything is closed.
    public var onExit: (() -> Void)?
    /// What this host keeps in memory that the next build must have too, never written to disk (see
    /// `HostHandover.SecretChannel`). Called on `queue` just before a handover.
    public var secretsForHandover: (() -> Data)?

    private let config: Config
    private var sessions: [UUID: HostedSession] = [:]
    private var order: [UUID] = []
    private var clients: [ObjectIdentifier: ClientConnection] = [:]
    /// Per session, the client whose terminal answers queries and sets the size: the last to attach or type.
    private var primary: [UUID: ObjectIdentifier] = [:]
    private var lockFD: Int32 = -1
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var housekeeping: DispatchSourceTimer?
    private var lastBusy = Date()
    private var stopped = false
    /// A `shutdown` was accepted: the host stops in a moment and starts nothing more.
    private var shuttingDown = false
    /// When this host started: a build it hands over to is the same host, started then.
    private var startedAt = Date()
    static let capabilities = [HostProtocol.Capability.styledScreen, HostProtocol.Capability.inputRefusals, HostProtocol.Capability.handover]
    private var handingOver = false

    public init(config: Config) {
        self.config = config
    }

    public func start() throws {
        queue.setSpecific(key: Self.queueKey, value: true)
        lockFD = open(config.lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw Failure.lock(errno) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD)
            lockFD = -1
            throw Failure.alreadyRunning
        }
        // Holding the lock: any socket file left behind is stale.
        listenFD = try UnixSocket.listen(path: config.socketPath)
        serve()
    }

    /// Carries on from the build that handed over (see `HostHandover`): its lock, socket and sessions, inherited.
    /// Returns its secrets. Throws, having changed nothing, when its lock or socket didn't survive the exec.
    public func start(restoring state: HostHandover.State) throws -> Data? {
        queue.setSpecific(key: Self.queueKey, value: true)
        for fd in [state.lockFD, state.listenFD] where !HostHandover.isOpen(fd) { throw HostHandover.Failure.badDescriptor(fd) }
        lockFD = state.lockFD
        startedAt = state.startedAt
        listenFD = state.listenFD
        for fd in [lockFD, listenFD] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let secrets = state.secretFD.flatMap { HostHandover.isOpen($0) ? HostHandover.SecretChannel.take($0) : nil }
        queue.sync {
            for saved in state.sessions {
                register(HostedSession.restore(saved, ringCapacity: config.ringCapacity, queue: queue))
            }
        }
        serve()
        return secrets
    }

    private func serve() {
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.resume()
        acceptSource = source

        let interval = config.idleExit.map { min(config.housekeepingInterval, max(0.5, $0 / 3)) } ?? config.housekeepingInterval
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.tidy() }
        timer.resume()
        housekeeping = timer
    }

    /// Closes everything. `terminateSessions`: also end the programs (tests); otherwise they lose their terminal anyway.
    public func stop(terminateSessions: Bool) {
        let work = {
            guard !self.stopped else { return }
            self.stopped = true
            self.acceptSource?.cancel()
            self.housekeeping?.cancel()
            self.clients.values.forEach { $0.close() }
            self.clients = [:]
            for session in self.sessions.values {
                if terminateSessions { session.terminate() }
                session.close()
            }
            self.sessions = [:]
            if self.listenFD >= 0 { Darwin.close(self.listenFD); unlink(self.config.socketPath) }
            if self.lockFD >= 0 { Darwin.close(self.lockFD) }
            self.listenFD = -1
            self.lockFD = -1
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { work() } else { queue.sync(execute: work) }
    }

    private static let queueKey = DispatchSpecificKey<Bool>()

    private func acceptAll() {
        while true {
            let fd = Darwin.accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            guard UnixSocket.peerUID(fd) == getuid() else {
                Darwin.close(fd)
                continue
            }
            UnixSocket.configure(fd)
            let client = ClientConnection(fd: fd, queue: queue)
            let key = ObjectIdentifier(client)
            client.onFrame = { [weak self, weak client] kind, payload in
                guard let self, let client else { return }
                self.handle(kind, payload, from: client)
            }
            client.onClose = { [weak self] in self?.dropClient(key) }
            clients[key] = client
            client.start()
        }
    }

    private var allInfo: [HostSession] { order.compactMap { sessions[$0]?.info } }

    private func handle(_ kind: HostFrame.Kind, _ payload: Data, from client: ClientConnection) {
        guard kind == .control else { return client.close() }
        guard let envelope = try? HostCoding.decode(HostRequestEnvelope.self, from: payload) else {
            // A request this host doesn't know (a newer app): say so, and keep the connection. Only what isn't a
            // request at all ends it.
            struct Numbered: Decodable { var seq: Int }
            guard let numbered = try? HostCoding.decode(Numbered.self, from: payload) else { return client.close() }
            return client.send(HostEventEnvelope(replyTo: numbered.seq, event: .error("This session host doesn't know that request; it may be older than the app.")))
        }
        let key = ObjectIdentifier(client)
        let reply: (HostEvent) -> Void = { client.send(HostEventEnvelope(replyTo: envelope.seq, event: $0)) }
        let missing = HostEvent.error("No such session.")
        switch envelope.request {
        case .hello:
            reply(.welcome(protocolVersion: HostProtocol.version, hostBuild: config.hostBuild, sessions: allInfo,
                           capabilities: Self.capabilities, pid: getpid(), startedAt: startedAt))
        case .spawn(let request):
            // Started now, it would be torn down with the host a moment later.
            guard !shuttingDown else { return reply(.error(HostProtocol.shuttingDown)) }
            do {
                let session = try HostedSession.spawn(request, shell: config.shell, launcher: config.launcher, baseEnvironment: config.baseEnvironment,
                                                      ringCapacity: config.ringCapacity, queue: queue)
                register(session)
                reply(.spawned(session.info))
                broadcast(.sessionChanged(session.info), except: key)
            } catch HostedSession.Failure.noSuchFolder(let path) {
                reply(.error("No such folder: \(path)"))
            } catch {
                reply(.error("Couldn't start the session."))
            }
        case .attach(let id, let cols, let rows):
            guard let session = sessions[id] else { return reply(missing) }
            client.attached.insert(id)
            primary[id] = key
            session.clientsAttached = true
            if !client.sendOutput(id, frames: HostFrame.output(session: id, bytes: session.replay())) {
                client.attached.remove(id)
                updateAttachment(id)
                return reply(.resync(id: id))
            }
            reply(.attached(id: id))
            session.resize(cols: cols, rows: rows)
            session.nudgeRedraw()
        case .detach(let id):
            client.attached.remove(id)
            updateAttachment(id)
            reply(.ok)
        case .input(let id, let bytes, let isReply):
            guard let session = sessions[id] else { return }
            if isReply {
                guard primary[id] == key else { return }
            } else if client.attached.contains(id) {
                // Typing makes a watching client the one whose size and replies count; a client that only sends
                // keys (the lead's tool server, one connection per call) doesn't take the session over.
                primary[id] = key
            }
            guard !session.write(bytes), session.info.isLive else { return }
            reply(.error("Input refused: the program isn't reading it and the host's buffer is full. None of these \(bytes.count) bytes went in."))
        case .resize(let id, let cols, let rows):
            guard let session = sessions[id], primary[id] == nil || primary[id] == key else { return }
            session.resize(cols: cols, rows: rows)
        case .screen(let id):
            reply(sessions[id].map { .screenText(id: id, text: $0.screenText()) } ?? missing)
        case .styledScreen(let id):
            guard let screen = sessions[id]?.styledScreen() else { return reply(missing) }
            reply(.styledScreenText(id: id, text: screen.text, runs: screen.runs))
        case .history(let id, let lines):
            guard let session = sessions[id] else { return reply(missing) }
            let text = session.historyText(lines: max(1, min(lines, 5_000)))
            reply(.historyText(id: id, history: Self.fitting(text.history, besides: text.screen), screen: text.screen))
        case .kill(let id):
            sessions[id]?.terminate()
            reply(.ok)
        case .remove(let id):
            guard let session = sessions[id] else { return reply(.ok) }
            guard !session.info.isLive else { return reply(.error("The session is still running.")) }
            forget(id)
            reply(.ok)
        case .handover(let executable):
            handOver(to: executable, reply: reply)
        case .shutdown:
            guard !sessions.values.contains(where: { $0.info.isLive }) else { return reply(.error("Sessions are running.")) }
            shuttingDown = true
            reply(.ok)
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.stop(terminateSessions: false)
                self?.onExit?()
            }
        }
    }

    /// Re-executes as `executable`, keeping every session (see `HostHandover`). The new build is probed first (off the
    /// queue, so the sessions carry on meanwhile); then, on the queue, the sessions are saved as they are at that moment
    /// and the process becomes the new build. Anything failing before the exec leaves this host as it was.
    private func handOver(to executable: String, reply: @escaping (HostEvent) -> Void) {
        guard !handingOver else { return reply(.error("A handover is under way.")) }
        guard !shuttingDown else { return reply(.error(HostProtocol.shuttingDown)) }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return reply(.error("Couldn't hand over: \(HostHandover.Failure.notExecutable(executable))."))
        }
        handingOver = true
        let path = config.handoverPath
        let fail: (Error) -> Void = { [weak self] error in
            unlink(path)
            self?.handingOver = false
            self?.log("handover to \(executable) failed: \(error)")
            reply(.error("Couldn't hand over: \(error)."))
        }
        do {
            try HostHandover.write(handoverState(secretFD: nil), to: path)
        } catch {
            return fail(error)
        }
        log("handing over to \(executable)")
        DispatchQueue.global().async { [weak self] in
            do {
                try HostHandover.probe(executable, statePath: path)
            } catch {
                self?.queue.async { fail(error) }
                return
            }
            self?.queue.async {
                guard let self else { return }
                var secretFD: Int32?
                do {
                    if let secrets = self.secretsForHandover?() { secretFD = try HostHandover.SecretChannel.make(secrets) }
                    let state = self.handoverState(secretFD: secretFD)
                    if let bad = state.descriptors.first(where: { !HostHandover.isOpen($0) }) { throw HostHandover.Failure.badDescriptor(bad) }
                    try HostHandover.write(state, to: path)
                    reply(.ok)
                    // The rest is the new build's: clients reconnect to the same socket.
                    let arguments = self.config.arguments + ["--handover", path, "--handover-fallback", self.config.fallback ?? self.config.launcher]
                    throw HostHandover.exec(executable, arguments: arguments, inherit: state.descriptors)
                } catch {
                    if let secretFD { Darwin.close(secretFD) }
                    // Answered ok already when the exec itself failed: the client sees the connection carry on.
                    fail(error)
                }
            }
        }
    }

    private func handoverState(secretFD: Int32?) -> HostHandover.State {
        HostHandover.State(fromBuild: config.hostBuild, startedAt: startedAt, lockFD: lockFD, listenFD: listenFD, secretFD: secretFD,
                           sessions: order.compactMap { sessions[$0]?.saved() })
    }

    private func log(_ text: String) {
        FileHandle.standardError.write(Data("vibeswitcher-host: \(text)\n".utf8))
    }

    /// The newest part of `history` that fits in one frame next to the screen (wide lines of box drawing
    /// can make 5,000 lines several megabytes; an oversized reply would never arrive).
    static func fitting(_ history: String, besides screen: String) -> String {
        let room = HostFrame.maxPayload - screen.utf8.count - 4_096   // JSON escaping and the envelope
        guard history.utf8.count > room else { return history }
        var lines = history.split(separator: "\n", omittingEmptySubsequences: false)
        var size = history.utf8.count
        // JSON escapes some characters; keep a margin by aiming at three quarters of the room.
        while size > room * 3 / 4, !lines.isEmpty {
            size -= lines.removeFirst().utf8.count + 1
        }
        return lines.joined(separator: "\n")
    }

    private func register(_ session: HostedSession) {
        let id = session.id
        sessions[id] = session
        order.append(id)
        session.onOutput = { [weak self] data in self?.deliver(data, of: id) }
        session.onChange = { [weak self] info in self?.broadcast(.sessionChanged(info)) }
        session.onBell = { [weak self] in self?.broadcast(.bell(id: id)) }
    }

    private func deliver(_ data: Data, of id: UUID) {
        let frames = HostFrame.output(session: id, bytes: data)
        for client in clients.values where client.attached.contains(id) {
            guard !client.sendOutput(id, frames: frames) else { continue }
            // Fell behind: stop sending it this session; it attaches again and gets a fresh replay.
            client.attached.remove(id)
            client.dropQueuedOutput(of: id)
            client.send(HostEventEnvelope(replyTo: nil, event: .resync(id: id)))
            updateAttachment(id)
        }
    }

    private func updateAttachment(_ id: UUID) {
        let watching = clients.filter { $0.value.attached.contains(id) }
        sessions[id]?.clientsAttached = !watching.isEmpty
        if let current = primary[id], watching[current] == nil { primary[id] = watching.keys.first }
    }

    private func broadcast(_ event: HostEvent, except: ObjectIdentifier? = nil) {
        for (key, client) in clients where key != except { client.send(HostEventEnvelope(replyTo: nil, event: event)) }
    }

    private func dropClient(_ key: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: key) else { return }
        client.attached.forEach(updateAttachment)
    }

    private func forget(_ id: UUID) {
        sessions.removeValue(forKey: id)?.close()
        order.removeAll { $0 == id }
        primary[id] = nil
        for client in clients.values { client.attached.remove(id) }
        broadcast(.sessionRemoved(id: id))
    }

    private func tidy() {
        let now = Date()
        for session in sessions.values {
            if let exit = session.info.exit, now.timeIntervalSince(exit.at) > config.keepEnded { forget(session.id) }
        }
        if !clients.isEmpty || sessions.values.contains(where: { $0.info.isLive }) {
            lastBusy = now
        } else if let idle = config.idleExit, now.timeIntervalSince(lastBusy) >= idle {
            stop(terminateSessions: false)
            onExit?()
        }
    }
}
