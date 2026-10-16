import AppKit
import Combine
import VibeCore

struct HostClientError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// The app's link to `vibeswitcher-host`: one connection, the host started when a window session is first
/// needed, the hosted sessions published, each session's output routed to the view that attached it.
/// Main thread only.
final class HostClient: ObservableObject {
    enum State: Equatable {
        case notRunning
        case connecting
        case connected
        /// The running host is an older build; it keeps serving its live sessions (if the protocol matches)
        /// and is replaced once none are left.
        case outdated(live: Int, compatible: Bool)
        case failed(String)
    }

    struct Sink {
        var output: (Data) -> Void
        /// Replay is over; live output follows.
        var attached: () -> Void
        /// The host dropped this view's stream: clear it; it's attached again with a fresh replay.
        var resync: () -> Void
    }

    @Published private(set) var sessions: [HostSession] = []
    @Published private(set) var state: State = .notRunning
    var onBell: ((UUID) -> Void)?
    /// Each live session's screen text by tty, refreshed by `refreshScreens` (the store reads Claude's footer from it).
    private(set) var screens: [String: String] = [:]

    private var connection: HostConnection?
    private var replies: [Int: (HostEvent) -> Void] = [:]
    private var sinks: [UUID: (sink: Sink, cols: Int, rows: Int)] = [:]
    private var whenReady: [(String?) -> Void] = []
    private var replacing = false
    private var restartWhenEnded = false
    private var hostProcess: DispatchSourceProcess?

    static var hostExecutable: URL {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host")
    }

    var isUsable: Bool {
        switch state {
        case .connected, .outdated(_, true): return true
        default: return false
        }
    }

    /// At launch: reattach to a host that's already running; don't start one.
    func connectIfRunning() {
        _ = connect()
    }

    /// Connects (starting the host if it isn't running) and calls `ready` with nil, or why it couldn't.
    func ensureHost(_ ready: @escaping (String?) -> Void) {
        if isUsable { return ready(nil) }
        whenReady.append(ready)
        guard connection == nil else { return }   // a welcome is on its way
        if connect() { return }
        do {
            try startHost()
        } catch {
            return finishWaiting("Couldn't start the session host: \(error.localizedDescription)")
        }
        retryConnect(attempts: 30)
    }

    private func retryConnect(attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard self.connection == nil else { return }
            if self.connect() { return }
            if attempts > 0 { return self.retryConnect(attempts: attempts - 1) }
            self.state = .failed("The session host didn't start. See ~/.vibeswitcher/host.log.")
            self.finishWaiting("The session host didn't start. See ~/.vibeswitcher/host.log.")
        }
    }

    private func finishWaiting(_ error: String?) {
        let waiting = whenReady
        whenReady = []
        waiting.forEach { $0(error) }
    }

    @discardableResult
    private func connect() -> Bool {
        if connection != nil { return true }
        guard let connection = try? HostConnection(path: VibePaths.hostSocket.path, queue: .main) else { return false }
        self.connection = connection
        state = .connecting
        connection.onEvent = { [weak self] in self?.handle($0) }
        connection.onOutput = { [weak self] id, bytes in self?.sinks[id]?.sink.output(bytes) }
        connection.onClose = { [weak self] in self?.connectionLost() }
        connection.send(.hello(protocolVersion: HostProtocol.version, app: "VibeSwitcher"))
        return true
    }

    /// Detached (own session, not our child for signals), stdout/stderr appended to host.log.
    private func startHost() throws {
        let path = Self.hostExecutable.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw HostClientError(message: "vibeswitcher-host is missing from the app")
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, VibePaths.hostLog.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        guard result == 0 else { throw HostClientError(message: String(cString: strerror(result))) }
        // Reap it when it exits (idle exit or replacement) so it doesn't linger as a zombie.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            self?.hostProcess?.cancel()
            self?.hostProcess = nil
        }
        source.resume()
        hostProcess = source
    }

    private func connectionLost() {
        connection = nil
        let pending = replies
        replies = [:]
        pending.values.forEach { $0(.error("The session host went away.")) }
        if replacing {
            replacing = false
            try? startHost()
            return retryConnect(attempts: 30)
        }
        // A host that's gone took its sessions with it.
        sessions = []
        screens = [:]
        state = .notRunning
        sinks.values.forEach { $0.sink.resync() }
        finishWaiting("The session host stopped.")
    }

    private func handle(_ envelope: HostEventEnvelope) {
        if let seq = envelope.replyTo, let reply = replies.removeValue(forKey: seq) { reply(envelope.event) }
        switch envelope.event {
        case .welcome(let version, let build, let list):
            sessions = list
            let live = list.filter(\.isLive).count
            let bundled = HostBuild.id(ofExecutableAt: Self.hostExecutable.path)
            if version == HostProtocol.version, build == bundled || bundled == 0 {
                state = .connected
            } else if list.isEmpty {
                // Only an empty host is replaced: ended sessions stay listed (and resumable) for their day.
                return replaceHost()
            } else {
                state = .outdated(live: live, compatible: version == HostProtocol.version)
            }
            finishWaiting(isUsable ? nil : "The session host is out of date. Restart it from the window.")
            for (id, entry) in sinks { sendAttach(id, cols: entry.cols, rows: entry.rows) }
        case .spawned(let session), .sessionChanged(let session):
            upsert(session)
        case .sessionRemoved(let id):
            sessions.removeAll { $0.id == id }
            sinks[id] = nil
            if case .outdated = state, sessions.isEmpty { replaceHost() }
        case .resync(let id):
            guard let entry = sinks[id] else { return }
            entry.sink.resync()
            sendAttach(id, cols: entry.cols, rows: entry.rows)
        case .bell(let id):
            onBell?(id)
        default:
            break
        }
    }

    private func upsert(_ session: HostSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session } else { sessions.append(session) }
        if !session.isLive { screens[session.tty] = nil }
        if case .outdated = state, sessions.isEmpty { replaceHost() }
        else if restartWhenEnded, !sessions.contains(where: \.isLive) { restartWhenEnded = false; replaceHost() }
    }

    /// Asks an idle host to quit; `connectionLost` then starts the bundled one.
    private func replaceHost() {
        guard !replacing else { return }
        replacing = true
        request(.shutdown) { [weak self] event in
            if case .error = event { self?.replacing = false }
        }
    }

    /// Ends every window session, then replaces the host (for an incompatible, outdated host).
    func restartHost() {
        restartWhenEnded = true
        sessions.filter(\.isLive).forEach { kill($0.id) }
        if !sessions.contains(where: \.isLive) { restartWhenEnded = false; replaceHost() }
    }

    private func request(_ request: HostRequest, reply: ((HostEvent) -> Void)? = nil) {
        guard let connection else {
            reply?(.error("Not connected to the session host."))
            return
        }
        let seq = connection.send(request)
        if let reply { replies[seq] = reply }
    }

    func spawn(_ spawn: SpawnRequest, completion: @escaping (Result<HostSession, HostClientError>) -> Void) {
        ensureHost { error in
            if let error { return completion(.failure(HostClientError(message: error))) }
            self.request(.spawn(spawn)) { event in
                switch event {
                case .spawned(let session):
                    self.upsert(session)
                    completion(.success(session))
                case .error(let message):
                    completion(.failure(HostClientError(message: message)))
                default:
                    completion(.failure(HostClientError(message: "Unexpected reply from the session host.")))
                }
            }
        }
    }

    func attach(_ id: UUID, cols: Int, rows: Int, sink: Sink) {
        sinks[id] = (sink, cols, rows)
        sendAttach(id, cols: cols, rows: rows)
    }

    private func sendAttach(_ id: UUID, cols: Int, rows: Int) {
        request(.attach(id: id, cols: cols, rows: rows)) { [weak self] event in
            if case .attached = event { self?.sinks[id]?.sink.attached() }
        }
    }

    func detach(_ id: UUID) {
        guard sinks.removeValue(forKey: id) != nil else { return }
        request(.detach(id: id))
    }

    func send(_ id: UUID, bytes: Data, reply: Bool) {
        request(.input(id: id, bytes: bytes, reply: reply))
    }

    func resize(_ id: UUID, cols: Int, rows: Int) {
        if sinks[id] != nil { sinks[id]?.cols = cols; sinks[id]?.rows = rows }
        request(.resize(id: id, cols: cols, rows: rows))
    }

    func screen(_ id: UUID, completion: @escaping (String?) -> Void) {
        request(.screen(id: id)) { event in
            if case .screenText(_, let text) = event { completion(text) } else { completion(nil) }
        }
    }

    func history(_ id: UUID, lines: Int, completion: @escaping ((history: String, screen: String)?) -> Void) {
        request(.history(id: id, lines: lines)) { event in
            if case .historyText(_, let history, let screen) = event { completion((history, screen)) } else { completion(nil) }
        }
    }

    func kill(_ id: UUID) { request(.kill(id: id)) }

    func remove(_ id: UUID) {
        request(.remove(id: id)) { [weak self] event in
            guard let self, case .ok = event else { return }
            self.sessions.removeAll { $0.id == id }
            if case .outdated = self.state, self.sessions.isEmpty { self.replaceHost() }
        }
    }

    /// Re-reads the screens of these live sessions (by tty) into `screens`.
    func refreshScreens(ttys: Set<String>) {
        screens = screens.filter { ttys.contains($0.key) }
        for session in sessions where session.isLive && ttys.contains(session.tty) {
            screen(session.id) { [weak self] text in self?.screens[session.tty] = text }
        }
    }
}
