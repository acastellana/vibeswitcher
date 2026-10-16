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
        guard kind == .control, let envelope = try? HostCoding.decode(HostRequestEnvelope.self, from: payload) else {
            return client.close()
        }
        let key = ObjectIdentifier(client)
        let reply: (HostEvent) -> Void = { client.send(HostEventEnvelope(replyTo: envelope.seq, event: $0)) }
        let missing = HostEvent.error("No such session.")
        switch envelope.request {
        case .hello:
            reply(.welcome(protocolVersion: HostProtocol.version, hostBuild: config.hostBuild, sessions: allInfo))
        case .spawn(let request):
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
            } else {
                primary[id] = key
            }
            session.write(bytes)
        case .resize(let id, let cols, let rows):
            guard let session = sessions[id], primary[id] == nil || primary[id] == key else { return }
            session.resize(cols: cols, rows: rows)
        case .screen(let id):
            reply(sessions[id].map { .screenText(id: id, text: $0.screenText()) } ?? missing)
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
        case .shutdown:
            guard !sessions.values.contains(where: { $0.info.isLive }) else { return reply(.error("Sessions are running.")) }
            reply(.ok)
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.stop(terminateSessions: false)
                self?.onExit?()
            }
        }
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
