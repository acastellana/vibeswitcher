import CryptoKit
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
        /// The project lead's vault (see `LeadVault`): the teams' roles, verdicts and the user's sealing key, kept in
        /// this process. Nil: this host keeps none (it refuses vault requests).
        public var vault: LeadVault.Book?
        /// The app's executable: a process running its code (by cdhash, see `AppCode`), outside every session, is the
        /// app to the vault.
        public var appExecutable: String?
        /// The key the app proves itself with (see `AppProof`) for a host that keeps no vault; with one, the vault's.
        public var appKey: SymmetricKey?
        /// The session log (see `HostLog`); nil: none (a scratch host).
        public var logPath: String?
        /// What this host was started with after its executable (socket, lock, idle exit): a build it hands over to is
        /// started with the same.
        public var arguments: [String] = []
        /// The old build's own copy (see `HostHandover`): where a build this host hands over to goes back to if it
        /// can't restore. Nil: `launcher`.
        public var fallback: String?
        /// Each session's output is parsed in a process of its own (see `SessionParser`), watched for stalls.
        public var parser = ParserOptions()

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
    /// `HostHandover.SecretChannel`): any bytes, up to a few megabytes (more fails the handover, and this host carries
    /// on). Called on `queue` just before the exec. The new build gets exactly these bytes from
    /// `HostHandover.takeSecrets(from:)` (before it makes its server) or from `start(restoring:)`.
    public var secretsForHandover: (() -> Data)?

    private let config: Config
    private let log: HostLog
    private var sessions: [UUID: HostedSession] = [:]
    private var order: [UUID] = []
    private var clients: [ObjectIdentifier: ClientConnection] = [:]
    /// Per session, the session whose process asked for it (see `mayKill`).
    private var startedBy: [UUID: UUID] = [:]
    /// The sessions the app asked for: the user's own (the lead's among them, which its team tells apart). The git
    /// commands their hooks record count as the user's (see `LeadVault.judge`); a session's own sessions' don't.
    private var openedByApp: Set<UUID> = []
    /// Where input to a session came from: the app (your keys, the phone, the composer, its replies to the terminal's
    /// queries), the session itself (a process on its own terminal), or another process (a session's, or one
    /// outside them all: a worker's Bash can type into any session outside a team).
    enum InputSource: Equatable {
        case app, itself
        case another(LeadVault.Caller)
    }
    /// Per session, where its last input came from: what its agent runs counts as the user's only while that's the
    /// app or itself (see `isYours`). Once another process typed into it, that stays, whatever comes after: the
    /// session typing into itself may be running what it was sent (a shell runs it), and your keys may follow theirs
    /// while its agent still works on what they typed.
    private var lastInput: [UUID: InputSource] = [:]
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
    static let capabilities = [HostProtocol.Capability.styledScreen, HostProtocol.Capability.inputRefusals, HostProtocol.Capability.handover,
                               HostProtocol.Capability.leadVault, HostProtocol.Capability.appProof]
    private var handingOver = false

    public init(config: Config) {
        self.config = config
        log = HostLog(path: config.logPath)
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
        var state = state
        let secrets = HostHandover.takeSecrets(from: &state)
        queue.sync {
            for saved in state.sessions {
                register(HostedSession.restore(saved, launcher: config.launcher, parser: config.parser, ringCapacity: config.ringCapacity,
                                               queue: queue))
                startedBy[saved.info.id] = saved.startedBy
                if saved.openedByApp == true { openedByApp.insert(saved.info.id) }
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
        log.note("host: started, build \(config.hostBuild), socket \(config.socketPath)")
    }

    /// A line in the session log (see `HostLog`).
    public func note(_ text: String) { log.note(text) }

    /// Closes everything. `terminateSessions`: also end the programs (tests); otherwise they lose their terminal anyway.
    public func stop(terminateSessions: Bool) {
        let work = {
            guard !self.stopped else { return }
            self.stopped = true
            self.log.note("host: stopping, \(self.sessions.values.filter { $0.info.isLive }.count) sessions live\(terminateSessions ? ", ending them" : "")")
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
            client.peer = UnixSocket.peerToken(fd)
            // The app's code is the app only once it answers the challenge.
            switch identify(client.peer) {
            case .app: client.runsAppCode = true
            case let caller: client.caller = caller
            }
            let key = ObjectIdentifier(client)
            client.onRead = { [weak self, weak client] in
                guard let self, let client else { return }
                self.checkPeer(client)
            }
            client.onFrame = { [weak self, weak client] kind, payload in
                guard let self, let client else { return }
                self.handle(kind, payload, from: client)
            }
            client.onClose = { [weak self] in self?.dropClient(key) }
            clients[key] = client
            client.send(HostEventEnvelope(replyTo: nil, event: .challenge(client.challenge, keyless: appKey == nil)))
            client.start()
        }
    }

    /// The key the app proves itself with: the vault's, or (a host that keeps none) the configured or enrolled one.
    private var appKey: SymmetricKey? { config.vault?.appKey ?? looseAppKey }
    private lazy var looseAppKey: SymmetricKey? = config.appKey

    /// The app's answer to its connection's challenge: from then on the connection is the app's, while nothing
    /// else sends on it.
    private func prove(_ answer: Data, from client: ClientConnection) -> HostEvent {
        let refusal: String
        if !client.runsAppCode {
            refusal = "This connection isn't VibeSwitcher's: its process doesn't run the app's code outside every session, or something else sent on it."
        } else if let key = appKey {
            if AppProof.isValid(answer, to: client.challenge, key: key) {
                client.caller = .app
                return .ok
            }
            refusal = "That isn't the key this session host knows for VibeSwitcher."
        } else {
            refusal = "This session host holds no key for VibeSwitcher yet."
        }
        log("pid \(client.peer?.pid ?? 0) didn't prove it's the app")
        return .error(refusal)
    }

    /// A host with no app key takes the first one the app's code gives it (a build before challenges handed over).
    private func enroll(_ key: Data, from client: ClientConnection) {
        guard client.runsAppCode, appKey == nil, key.count == AppProof.keySize else { return }
        if let vault = config.vault { vault.adoptAppKey(key) } else { looseAppKey = SymmetricKey(data: key) }
        log.note("host: took the app's first key (it held none), \(HostLog.peer(client.peerPID))")
    }

    /// The app lost its key: a new one replaces the one held, from the app's code, while no session runs (no worker or
    /// verifier is there to race it).
    private func replaceAppKey(_ key: Data, from client: ClientConnection) -> HostEvent {
        let live = sessions.values.filter { $0.info.isLive }.count
        guard client.runsAppCode, live == 0, key.count == AppProof.keySize else {
            log.note("host: refused to replace the app's key (\(client.runsAppCode ? "\(live) sessions live" : "not the app's code")), \(HostLog.peer(client.peerPID))")
            return .error(client.runsAppCode ? "End every session first: the session host replaces VibeSwitcher's key only while none runs."
                : "Only VibeSwitcher replaces its key.")
        }
        if let vault = config.vault { vault.adoptAppKey(key, replacing: true) } else { looseAppKey = SymmetricKey(data: key) }
        log.note("host: replaced the app's key at the app's request, no session running, \(HostLog.peer(client.peerPID))")
        return .ok
    }

    /// Whether `caller` may end `id`: the app; a session itself or one started from it, all the way down; a team's
    /// lead, its team's sessions.
    private func mayKill(_ id: UUID, from caller: LeadVault.Caller) -> Bool {
        switch caller {
        case .app: return true
        case .unknown: return false
        case .session(let from):
            var current: UUID? = id
            var seen: Set<UUID> = []
            while let session = current, seen.insert(session).inserted {
                if session.uuidString == from { return true }
                current = startedBy[session]
            }
            return config.vault?.leads(id.uuidString, caller: caller) == true
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
                                                      ringCapacity: config.ringCapacity, queue: queue, parser: config.parser)
                register(session)
                switch caller(of: client) {
                case .session(let from): startedBy[session.id] = UUID(uuidString: from)
                case .app: openedByApp.insert(session.id)
                case .unknown: break
                }
                let info = session.info
                log.note("spawn \(Self.short(info.id)) pid \(info.childPID) label '\(info.label)' cwd '\(info.cwd)'\(info.agent.map { " agent \($0)" } ?? ""), \(HostLog.peer(client.peerPID))")
                reply(.spawned(session.info))
                broadcast(.sessionChanged(session.info), except: key)
            } catch HostedSession.Failure.noSuchFolder(let path) {
                log.note("spawn failed: no such folder '\(path)', \(HostLog.peer(client.peerPID))")
                reply(.error("No such folder: \(path)"))
            } catch {
                log.note("spawn failed: \(error) in '\(request.cwd)', \(HostLog.peer(client.peerPID))")
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
            // A session in a lead's team takes keys only from the app, itself or its lead: a worker's Bash can't
            // type into the lead (as you).
            if let vault = config.vault, !vault.mayType(into: id.uuidString, from: caller(of: client)) {
                return log("refused input to \(id.uuidString.prefix(8)) from pid \(client.peer?.pid ?? 0)")
            }
            let from = caller(of: client)
            let source: InputSource = from == .app ? .app : from == .session(id.uuidString) ? .itself : .another(from)
            switch (lastInput[id], source) {
            case (.another?, .app), (.another?, .itself): break
            default:
                if case .another(let typist) = source, isYours(id) {
                    let who = if case .session(let other) = typist { "session \(other.prefix(8))" } else { "a process outside the sessions" }
                    log.note("input to \(Self.short(id)) from \(who), not the app: its git commands no longer count as the user's, \(HostLog.peer(client.peerPID))")
                }
                lastInput[id] = source
            }
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
        // Answered once the session's parser got there (see `HostedSession.view`): the queue never waits on it.
        case .screen(let id):
            guard let session = sessions[id] else { return reply(missing) }
            session.view(historyLines: nil) { reply(.screenText(id: id, text: $0.screen)) }
        case .styledScreen(let id):
            guard let session = sessions[id] else { return reply(missing) }
            session.view(historyLines: nil) { reply(.styledScreenText(id: id, text: $0.screen, runs: $0.runs)) }
        case .history(let id, let lines):
            guard let session = sessions[id] else { return reply(missing) }
            session.view(historyLines: max(1, min(lines, 5_000))) { view in
                reply(.historyText(id: id, history: Self.fitting(view.history ?? "", besides: view.screen), screen: view.screen))
            }
        case .kill(let id):
            guard mayKill(id, from: caller(of: client)) else {
                log.note("kill \(Self.short(id)) refused: not the app, the session itself or its lead, \(HostLog.peer(client.peerPID))")
                return reply(.error("Only VibeSwitcher, the session itself (or the one that started it) or its team's lead ends a session."))
            }
            if let session = sessions[id] {
                log.note("kill \(Self.short(id)) pid \(session.info.childPID) label '\(session.info.label)'\(session.info.isLive ? "" : " (already ended)"), \(HostLog.peer(client.peerPID))")
            } else {
                log.note("kill \(Self.short(id)): no such session, \(HostLog.peer(client.peerPID))")
            }
            sessions[id]?.terminate(by: client.peerPID)
            reply(.ok)
        case .remove(let id):
            guard let session = sessions[id] else { return reply(.ok) }
            guard !session.info.isLive else { return reply(.error("The session is still running.")) }
            forget(id)
            reply(.ok)
        case .vault(let request):
            guard let vault = config.vault else { return reply(.vault(.refused("This session host keeps no lead vault."))) }
            let from = caller(of: client)
            let opened: Bool = {
                guard case .session(let id) = from, let id = UUID(uuidString: id) else { return false }
                return isYours(id)
            }()
            var answer = vault.answer(request, from: from, userOpened: opened)
            if case .move(var move) = answer, move.from != move.to {
                move.labels = move.sessions.map { id in UUID(uuidString: id).flatMap { sessions[$0]?.info.label } ?? String(id.prefix(8)) }
                log.note(move.accepted ? "vault: \(move.acceptedLine) (\(move.from.prefix(8)) → \(move.to.prefix(8))), \(HostLog.peer(client.peerPID))"
                    : "vault: didn't take \(move.branch) at \(move.to.prefix(8)) (left at \(move.from.prefix(8))): \(move.reason ?? "")\(move.waiting == true ? " (a command is still running)" : ""), \(HostLog.peer(client.peerPID))")
                answer = .move(move)
            }
            reply(.vault(answer))
        case .handover(let executable):
            // The new build inherits every session's terminal and the socket: only the app picks it.
            guard caller(of: client) == .app else {
                log.note("handover refused: not the app, \(HostLog.peer(client.peerPID))")
                return reply(.error("Only VibeSwitcher hands the session host over."))
            }
            handOver(to: executable, reply: reply)
        case .proveApp(let answer):
            reply(prove(answer, from: client))
        case .enrollApp(let key):
            enroll(key, from: client)
        case .replaceAppKey(let key):
            reply(replaceAppKey(key, from: client))
        case .shutdown:
            let live = sessions.values.filter { $0.info.isLive }.count
            guard live == 0 else {
                log.note("shutdown refused: \(live) sessions live, \(HostLog.peer(client.peerPID))")
                return reply(.error("Sessions are running."))
            }
            log.note("shutdown accepted, \(HostLog.peer(client.peerPID))")
            shuttingDown = true
            reply(.ok)
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.stop(terminateSessions: false)
                self?.onExit?()
            }
        }
    }

    /// Whether what `id`'s agent runs is the user's say: a session the app opened, that no session started, whose
    /// last input came from the app or itself (or that nothing typed into yet).
    private func isYours(_ id: UUID) -> Bool {
        openedByApp.contains(id) && startedBy[id] == nil && !Self.another(lastInput[id])
    }

    private static func another(_ source: InputSource?) -> Bool {
        if case .another? = source { return true }
        return false
    }

    /// Who the process on `client` is to the lead's vault (see `identify`).
    func caller(of client: ClientConnection) -> LeadVault.Caller { client.caller }

    /// The kernel names whichever process last used the client's socket, not the one that connected: after a
    /// connector forks a child to write and execs the app's binary (or anything else), the token names the child,
    /// or the new image. Anything but the process accepted makes the connection nobody's.
    private func checkPeer(_ client: ClientConnection) {
        guard client.caller != .unknown || client.runsAppCode else { return }
        if let accepted = client.peer, let now = UnixSocket.peerToken(client.fd), now.sameImage(as: accepted) { return }
        log("pid \(client.peer?.pid ?? 0) is no longer the one sending on its connection: it's no one to the vault now")
        client.caller = .unknown
        client.runsAppCode = false
    }

    /// Who the process `token` names is: a process in one of the live sessions (its program or anything under it,
    /// by parent processes, or with the session's terminal), else the app's code, outside every session (the app once
    /// it answers its connection's challenge, see `prove`), else
    /// unknown. Told once, when the connection is accepted: a process can leave its session's tree, never join
    /// another's.
    func identify(_ token: audit_token_t?) -> LeadVault.Caller {
        guard let token, token.pid > 1, let ancestry = ProcessTable.ancestry(of: token.pid) else { return .unknown }
        let live = sessions.values.filter { $0.info.isLive }
        let chain = Set([token.pid] + ancestry.map(\.pid))
        if let session = live.first(where: { chain.contains($0.info.childPID) }) { return .session(session.id.uuidString) }
        if let tty = ProcessTable.info(pid: token.pid)?.tty, let session = live.first(where: { $0.info.tty == tty }) {
            return .session(session.id.uuidString)
        }
        if let app = config.appExecutable, AppCode.runs(token, executable: app) { return .app }
        return .unknown
    }

    static func executable(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
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
                var parsersStopped = false
                do {
                    if let secrets = self.secretsForHandover?() { secretFD = try HostHandover.SecretChannel.make(secrets) }
                    // A session that just ended is saved as ended, with the screen its parser showed last.
                    self.sessions.values.forEach { $0.finishNow() }
                    let state = self.handoverState(secretFD: secretFD)
                    if let bad = state.descriptors.first(where: { !HostHandover.isOpen($0) }) { throw HostHandover.Failure.badDescriptor(bad) }
                    try HostHandover.write(state, to: path)
                    reply(.ok)
                    // The new build starts its own parsers, from the replays; none of these is left running.
                    self.sessions.values.forEach { $0.suspendParser() }
                    parsersStopped = true
                    // The rest is the new build's: clients reconnect to the same socket.
                    let arguments = self.config.arguments + ["--handover", path, "--handover-fallback", self.config.fallback ?? self.config.launcher]
                    throw HostHandover.exec(executable, arguments: arguments, inherit: state.descriptors)
                } catch {
                    if parsersStopped { self.sessions.values.forEach { $0.resumeParser() } }
                    if let secretFD { Darwin.close(secretFD) }
                    fail(error)
                    // Answered ok already when the exec itself failed: clients waiting for the new build come back to
                    // this one's welcome.
                    if case HostHandover.Failure.exec = error { self.clients.values.forEach { $0.close() } }
                }
            }
        }
    }

    private func handoverState(secretFD: Int32?) -> HostHandover.State {
        HostHandover.State(fromBuild: config.hostBuild, startedAt: startedAt, lockFD: lockFD, listenFD: listenFD, secretFD: secretFD,
                           sessions: order.compactMap { id in
                               sessions[id].map { session in
                                   var saved = session.saved()
                                   saved.startedBy = startedBy[id]
                                   saved.openedByApp = openedByApp.contains(id) && !Self.another(lastInput[id])
                                   return saved
                               }
                           })
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
        session.onParserTrouble = { [weak self] text in
            self?.log.note("watchdog: session \(Self.short(id))'s \(text)")
            self?.log("session \(id.uuidString)'s \(text)")
        }
        session.onEnd = { [weak self, weak session] status in
            guard let self, let info = session?.info else { return }
            let asked = info.exit?.killedBy.map { ", after a kill from peer pid \($0)" } ?? ""
            self.log.note("exit \(Self.short(id)) pid \(info.childPID) label '\(info.label)': \(HostLog.waitStatus(status))\(asked)")
        }
    }

    /// A session's id in the log: its first 8 characters.
    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

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
        startedBy[id] = nil
        openedByApp.remove(id)
        lastInput[id] = nil
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
            log.note("host: idle \(Int(idle)) s with no session and no app, exiting")
            stop(terminateSessions: false)
            onExit?()
        }
    }
}
