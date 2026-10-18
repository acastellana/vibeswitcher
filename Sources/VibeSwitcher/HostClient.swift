import AppKit
import Combine
import CryptoKit
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
    /// The running host can be updated without ending its sessions (`HostProtocol.Capability.handover`).
    @Published private(set) var canHandOver = false
    var onBell: ((UUID) -> Void)?
    /// Each live session's screen text by tty, refreshed by `refreshScreens` (the store reads Claude's footer from it).
    private(set) var screens: [String: String] = [:]

    private var connection: HostConnection?
    private var replies: [Int: (HostEvent) -> Void] = [:]
    private var sinks: [UUID: (sink: Sink, cols: Int, rows: Int)] = [:]
    private var whenReady: [(String?) -> Void] = []
    private var replacing = false
    /// A handover was asked of the running host; the bundled build's welcome follows.
    private var handingOver = false
    /// The bundled build a handover was last asked for: asked once per build, so a failing one isn't asked again
    /// and again (the window's restart asks once more).
    private var handedOverTo: Int?
    private var restartWhenEnded = false
    /// Hosts this app started, by pid, reaped when they exit (a replaced host can still be running when the new
    /// one starts).
    private var hostProcesses: [pid_t: DispatchSourceProcess] = [:]
    /// Reconnect attempts since the connection was lost; reset by a welcome.
    private var reconnectAttempt = 0
    /// The connection was lost before a welcome while sessions waited for the host: start it once more.
    private var restartedForWaiting = false
    /// What the connected host can do beyond the protocol version (see `HostProtocol.Capability`).
    private(set) var hostCapabilities: Set<String> = []
    /// Typed input sent, by seq, that the host could still refuse (it answers only input it refuses, and handles
    /// requests in order: a reply to a later request means these went in).
    private var sentInput: [Int: (id: UUID, count: Int)] = [:]
    /// Pieces of input the host refused, per session (the program wasn't reading and its buffer was full).
    private var refusedInput: [UUID: Int] = [:]

    /// The key the app proves itself with to the host (see `AppProof`), from the login Keychain; every connection
    /// the app makes answers its challenge with it (the lead's vault calls too).
    static let appKey: SymmetricKey? = {
        let key = AppProof.keychainKey()
        if key == nil { Breadcrumbs.shared.note("host: no app key from the Keychain; the host won't take this app as VibeSwitcher") }
        HostConnection.appKey = key
        return key
    }()

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
        // Connected to a host that can't serve us: say so now (waiting would wait forever).
        if case .outdated(_, false) = state { return ready("The session host is out of date. Restart it from the window.") }
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
        guard let connection = try? HostConnection(path: VibePaths.hostSocket.path, queue: .main, appKey: Self.appKey) else { return false }
        self.connection = connection
        state = .connecting
        connection.onEvent = { [weak self] in self?.handle($0) }
        connection.onOutput = { [weak self] id, bytes in self?.sinks[id]?.sink.output(bytes) }
        connection.onClose = { [weak self] in self?.connectionLost() }
        connection.onProofRefused = { [weak self] reason in self?.proofRefused(reason) }
        connection.send(.hello(protocolVersion: HostProtocol.version, app: "VibeSwitcher"))
        return true
    }

    /// The host didn't take this app as VibeSwitcher (see `AppProof`): the lead's tools, a handover and ending
    /// sessions are off until it does. Asked once per launch.
    private var offeredKeyReset = false

    private func proofRefused(_ reason: String) {
        Breadcrumbs.shared.note("host: proof refused: \(reason)")
        guard !offeredKeyReset, let key = Self.appKey else { return }
        offeredKeyReset = true
        let live = sessions.filter(\.isLive).count
        let alert = NSAlert()
        alert.messageText = "The session host doesn't recognise this VibeSwitcher."
        alert.informativeText = reason + " The project lead's tools, updating the host in place and ending sessions from the app are off until it does. "
            + (live > 0 ? "If VibeSwitcher's Keychain item was deleted, end every session (\(live) running) and reopen VibeSwitcher to teach the host this app's new key."
                : "If VibeSwitcher's Keychain item was deleted, teach the host this app's new key (it's logged in ~/.vibeswitcher/debug/host.log).")
        if live == 0 { alert.addButton(withTitle: "Teach It This App's Key") }
        alert.addButton(withTitle: live == 0 ? "Not Now" : "OK")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn, live == 0 else { return }
        request(.replaceAppKey(key: key.data)) { [weak self] event in
            guard let self else { return }
            guard case .ok = event else { return Breadcrumbs.shared.note("host: key not replaced: \(event)") }
            // A new connection, with a new challenge, answered with the key the host now holds.
            self.connection?.close()
            self.connectionLost()
        }
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
        // Stdin: the app's key, then nothing (see `HostStart`); the pipe holds it, so it's written before the spawn.
        var keyPipe: [Int32] = [-1, -1]
        if let key = Self.appKey, pipe(&keyPipe) == 0 {
            _ = key.data.withUnsafeBytes { write(keyPipe[1], $0.baseAddress, $0.count) }
            close(keyPipe[1])
            posix_spawn_file_actions_adddup2(&actions, keyPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        defer { if keyPipe[0] >= 0 { close(keyPipe[0]) } }
        posix_spawn_file_actions_addopen(&actions, 1, VibePaths.hostLog.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path)] + (keyPipe[0] >= 0 ? [strdup(AppProof.hostStdinFlag)] : []) + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        guard result == 0 else { throw HostClientError(message: String(cString: strerror(result))) }
        // Reap it when it exits (idle exit or replacement) so it doesn't linger as a zombie.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            self?.hostProcesses.removeValue(forKey: pid)?.cancel()
        }
        source.resume()
        hostProcesses[pid] = source
    }

    private func connectionLost() {
        let welcomed = state != .connecting
        Breadcrumbs.shared.note("host: connection lost (welcomed=\(welcomed), replacing=\(replacing), waiting=\(whenReady.count))")
        connection = nil
        hostCapabilities = []
        sentInput = [:]
        let pending = replies
        replies = [:]
        pending.values.forEach { $0(.error("The session host went away.")) }
        if replacing {
            replacing = false
            try? startHost()
            return retryConnect(attempts: 30)
        }
        // Closed before its welcome while a new session waits (an idle host quitting just as we connected): start
        // one and try again, rather than giving up.
        if !welcomed, !whenReady.isEmpty, !restartedForWaiting {
            restartedForWaiting = true
            try? startHost()
            return retryConnect(attempts: 30)
        }
        // Keep the sessions and their terminals as they are (the last output is what you want to read now) and
        // try to get back to the host; only when it's really gone are its sessions marked ended.
        state = .connecting
        reconnect()
    }

    private func reconnect() {
        let delays: [TimeInterval] = [0.2, 0.5, 1, 2, 3, 5]
        guard reconnectAttempt < delays.count else { return hostGone() }
        let delay = delays[reconnectAttempt]
        reconnectAttempt += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.connection == nil else { return }
            if !self.connect() { self.reconnect() }
        }
    }

    /// The host is gone and took its sessions with it: they stay listed as ended, with their last screen.
    private func hostGone() {
        Breadcrumbs.shared.note("host: gone; \(sessions.filter(\.isLive).count) sessions marked ended")
        reconnectAttempt = 0
        let now = Date()
        sessions = sessions.map { session in
            var ended = session
            if ended.isLive { ended.exit = HostSession.Exit(status: -1, at: now) }
            return ended
        }
        screens = [:]
        state = .notRunning
        finishWaiting("The session host stopped.")
    }

    private func handle(_ envelope: HostEventEnvelope) {
        if let seq = envelope.replyTo, let reply = replies.removeValue(forKey: seq) { reply(envelope.event) }
        if let seq = envelope.replyTo, !sentInput.isEmpty {
            if case .error(let message) = envelope.event, let input = sentInput[seq] {
                Breadcrumbs.shared.note("host: \(input.count) bytes of input refused: \(message)")
                refusedInput[input.id, default: 0] += 1
            }
            sentInput = sentInput.filter { $0.key > seq }
        }
        switch envelope.event {
        case .welcome(let version, let build, let list, let capabilities, let pid, _):
            Breadcrumbs.shared.note("host: welcome v\(version) build \(build) pid \(pid.map(String.init) ?? "?"), \(list.count) sessions")
            hostCapabilities = Set(capabilities ?? [])
            reconnectAttempt = 0
            restartedForWaiting = false
            handingOver = false
            sessions = list
            canHandOver = hostCapabilities.contains(HostProtocol.Capability.handover)
            let live = list.filter(\.isLive).count
            let bundled = HostBuild.id(ofExecutableAt: Self.hostExecutable.path)
            switch Self.plan(version: version, build: build, bundled: bundled, sessions: list.count,
                             canHandOver: canHandOver, handedOverTo: handedOverTo) {
            case .use:
                state = .connected
            case .replace:
                // Only an empty host is replaced: ended sessions stay listed (and resumable) for their day.
                return replaceHost()
            case .handOver:
                state = .outdated(live: live, compatible: version == HostProtocol.version)
                handOver()
            case .keepOutdated:
                state = .outdated(live: live, compatible: version == HostProtocol.version)
            }
            // A host that can't serve us but is becoming the bundled build: its welcome answers whoever waits.
            if !(handingOver && !isUsable) {
                finishWaiting(isUsable ? nil : "The session host is out of date. Restart it from the window.")
            }
            // Back after losing the connection: the views still show what they had; start them over from the
            // host's replay (views of sessions it no longer has are dropped with them).
            for (id, entry) in sinks {
                guard list.contains(where: { $0.id == id }) else { sinks[id] = nil; continue }
                entry.sink.resync()
                sendAttach(id, cols: entry.cols, rows: entry.rows)
            }
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
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            // Every change publishes the list, and everything that shows sessions redraws: not for a spinner frame.
            guard sessions[index] != session, !session.differsOnlyBySpinner(from: sessions[index]) else { return }
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        if !session.isLive { screens[session.tty] = nil }
        if case .outdated = state, sessions.isEmpty { replaceHost() }
        else if restartWhenEnded, !sessions.contains(where: \.isLive) { restartWhenEnded = false; replaceHost() }
    }

    enum Plan: Equatable {
        /// The host is the bundled build (or there's no bundled one to compare with).
        case use
        /// An outdated host with no sessions: quit it and start the bundled build.
        case replace
        /// An outdated host that can become the bundled build, keeping its sessions.
        case handOver
        /// An outdated host that can't: it serves its sessions (if it speaks our protocol) until they're gone.
        case keepOutdated
    }

    /// What to do with the host that sent this welcome.
    static func plan(version: Int, build: Int, bundled: Int, sessions: Int, canHandOver: Bool, handedOverTo: Int?) -> Plan {
        if version == HostProtocol.version, build == bundled || bundled == 0 { return .use }
        if sessions == 0 { return .replace }
        // Even across a protocol change: the request is understood by every host that lists the capability.
        return canHandOver && handedOverTo != bundled ? .handOver : .keepOutdated
    }

    /// Asks the running host to become the bundled build, keeping every session: it answers ok, the connection drops
    /// and the new build's welcome comes on the next one (`connectionLost` reconnects).
    private func handOver() {
        guard !handingOver else { return }
        Breadcrumbs.shared.note("host: handing over to the bundled build")
        handingOver = true
        handedOverTo = HostBuild.id(ofExecutableAt: Self.hostExecutable.path)
        request(.handover(executable: Self.hostExecutable.path)) { [weak self] event in
            guard let self, case .error(let message) = event, self.handingOver else { return }
            Breadcrumbs.shared.note("host: handover failed: \(message)")
            self.handingOver = false
            // Carry on with the old build, as without a handover.
            if !self.isUsable { self.finishWaiting("The session host is out of date. Restart it from the window.") }
        }
    }

    /// Asks an idle host to quit; `connectionLost` then starts the bundled one.
    private func replaceHost() {
        guard !replacing else { return }
        Breadcrumbs.shared.note("host: replacing an outdated host")
        replacing = true
        request(.shutdown) { [weak self] event in
            if case .error = event { self?.replacing = false }
        }
    }

    /// What restarting an outdated host does (`restartHost`), asked for from the window, the menu or Settings.
    enum RestartPlan: Equatable {
        /// It becomes the bundled build, every session kept.
        case handOver
        /// Its live sessions, in every project, are ended; then it's replaced like an empty host.
        case endAndReplace(live: Int)
    }

    /// Whatever the host speaks and however many sessions it has: the handover when it can, else the replace.
    static func restartPlan(canHandOver: Bool, live: Int) -> RestartPlan {
        canHandOver ? .handOver : .endAndReplace(live: live)
    }

    /// The restart on offer: nil unless the host is outdated.
    var restartOffer: RestartPlan? {
        guard case .outdated = state else { return nil }
        return Self.restartPlan(canHandOver: canHandOver, live: sessions.filter(\.isLive).count)
    }

    /// Updates an outdated host: a host that can hand over becomes the bundled build with every session kept; any
    /// other has every session (in every project) ended, then is replaced.
    func restartHost() {
        let live = sessions.filter(\.isLive)
        switch Self.restartPlan(canHandOver: canHandOver, live: live.count) {
        case .handOver:
            handedOverTo = nil
            handOver()
        case .endAndReplace:
            restartWhenEnded = true
            live.forEach { kill($0.id) }
            if live.isEmpty { restartWhenEnded = false; replaceHost() }
        }
    }

    private func request(_ request: HostRequest, reply: ((HostEvent) -> Void)? = nil) {
        guard let connection else {
            reply?(.error("Not connected to the session host."))
            return
        }
        let seq = connection.send(request)
        guard let reply else { return }
        replies[seq] = reply
        // A reply that never comes must not leave its caller (e.g. a phone request) waiting forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.replies.removeValue(forKey: seq)?(.error("The session host didn't answer."))
        }
    }

    func spawn(_ spawn: SpawnRequest, completion: @escaping (Result<HostSession, HostClientError>) -> Void) {
        Breadcrumbs.shared.note("host: spawn \(spawn.label) in \((spawn.cwd as NSString).lastPathComponent)")
        ensureHost { error in
            if let error { return completion(.failure(HostClientError(message: error))) }
            self.request(.spawn(spawn)) { event in
                switch event {
                case .spawned(let session):
                    self.upsert(session)
                    completion(.success(session))
                case .error(HostProtocol.shuttingDown) where self.replacing:
                    // Asked while the host we're replacing quits: the new one takes it.
                    self.whenReady.append { error in
                        if let error { return completion(.failure(HostClientError(message: error))) }
                        self.spawn(spawn, completion: completion)
                    }
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
        // A message has a size limit (a big paste is larger): send it in pieces, in order.
        let piece = 256 * 1024
        var start = bytes.startIndex
        repeat {
            let end = bytes.index(start, offsetBy: piece, limitedBy: bytes.endIndex) ?? bytes.endIndex
            if let seq = connection?.send(.input(id: id, bytes: bytes.subdata(in: start..<end), reply: reply)),
               !reply, hostCapabilities.contains(HostProtocol.Capability.inputRefusals) {
                sentInput[seq] = (id, end - start)
            }
            start = end
        } while start < bytes.endIndex
    }

    /// Writes these into the session, each after its delay, then tells `confirmed` whether the host took them. The
    /// host handles a connection's requests in order and answers only input it refuses, so the answer to a screen
    /// read sent after the last write is the receipt; no answer (not connected, gone, too slow) or a refusal is false.
    func send(_ id: UUID, writes: [HostInput.Write], confirmed: @escaping (Bool) -> Void) {
        let refusedBefore = refusedInput[id, default: 0]
        var at: TimeInterval = 0
        for write in writes {
            at += write.delay
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                self?.send(id, bytes: Data(write.bytes), reply: false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
            guard let self else { return confirmed(false) }
            self.request(.screen(id: id)) { [weak self] event in
                guard case .screenText = event else { return confirmed(false) }
                confirmed(self?.refusedInput[id, default: 0] == refusedBefore)
            }
        }
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

    /// The screen with how it's drawn; only its text from a host too old to say.
    func styledScreen(_ id: UUID, completion: @escaping (LeadDelivery.Screen?) -> Void) {
        request(.styledScreen(id: id)) { [weak self] event in
            switch event {
            case .styledScreenText(_, let text, let runs): completion(LeadDelivery.Screen(text: text, runs: runs))
            case .error: self?.screen(id) { completion($0.map { LeadDelivery.Screen(text: $0) }) } ?? completion(nil)
            default: completion(nil)
            }
        }
    }

    func history(_ id: UUID, lines: Int, completion: @escaping ((history: String, screen: String)?) -> Void) {
        request(.history(id: id, lines: lines)) { event in
            if case .historyText(_, let history, let screen) = event { completion((history, screen)) } else { completion(nil) }
        }
    }

    func kill(_ id: UUID) { request(.kill(id: id)) }

    func remove(_ id: UUID) {
        // Left over from a host that's gone: nothing to ask.
        guard connection != nil else {
            sessions.removeAll { $0.id == id }
            return
        }
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
