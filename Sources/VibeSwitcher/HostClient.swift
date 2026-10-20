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
    /// The user's host; a test's scratch host instead (it never starts one: see `connectIfRunning`).
    private let socketPath: String
    private let proofKey: () -> SymmetricKey?
    private var replies: [Int: (HostEvent) -> Void] = [:]
    private var sinks: [UUID: (sink: Sink, cols: Int, rows: Int)] = [:]
    private var whenReady: [(String?) -> Void] = []
    private var replacing = false
    /// A handover asked of the running host: its pid then (the host re-executes itself, so the new build keeps it) and
    /// the bundled build asked for. The connection drops by design; the next welcome says whether it went through.
    private var handover: (pid: Int32?, build: Int)?
    private var handingOver: Bool { handover != nil }
    /// Each handover asked counts up: a wait or answer of an earlier one has nothing to say about a later one.
    private var handoverAsk = 0
    /// The host's answer to the handover asked didn't come in `handoverWait`: the connection stays open, and the next
    /// welcome says how it went.
    private var handoverWaitedOut = false
    /// The pid the connected host gave in its welcome (nil from an older host).
    private var hostPID: Int32?
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

    /// The key the app proves itself with to the host (see `AppProof`), from `store`, read once: the app's own client
    /// reads it from the login Keychain (AppDelegate passes `AppProof.KeychainStore()`), and every connection the app
    /// makes answers its challenge with it (the lead's vault calls too). Every other client (tests, benches) has its
    /// own key or none, so none reaches the Keychain (see `AppKeyStore`).
    static func appKey(from store: AppKeyStore) -> () -> SymmetricKey? {
        var read: SymmetricKey??
        return {
            if let read { return read }
            let key = store.key()
            if key == nil { Breadcrumbs.shared.note("host: no app key from the Keychain; the host won't take this app as VibeSwitcher") }
            HostConnection.appKey = key
            read = .some(key)
            return key
        }
    }

    /// What this client does, for app.log (a test's own list instead).
    private let note: (String) -> Void
    /// The bundled host's build (see `HostBuild`); a test's fake build instead.
    private let bundledBuild: () -> Int
    /// How long to wait before each attempt to get back to a host that dropped the connection; then it's gone.
    private let reconnectDelays: [TimeInterval]

    /// The reply every request still waiting gets when the connection drops.
    static let wentAway = "The session host went away."
    /// How long a request's reply is waited for (a handover's: `handoverWait`).
    static let replyWait: TimeInterval = 15
    /// How long the host gives the new build's probe (`HostHandover.probeLimit`, which a test holds this to): on a
    /// loaded Mac the new build's first exec waits on amfid, one new binary at a time for the whole Mac (on 2026-10-19
    /// it answered nothing for 108 s at load 200).
    static let hostProbeLimit: TimeInterval = 180
    /// How long the host's answer to a handover is waited for: its probe of the new build, then saving the sessions and
    /// the exec. Tests shorten it.
    var handoverWait: TimeInterval = hostProbeLimit + 30
    /// How often app.log is told the handover is still waiting for the new build's probe. Tests shorten it.
    var handoverBreadcrumb: TimeInterval = 15

    /// The bundled host a handover asks for; a test's scratch build instead.
    private let handoverExecutable: () -> String

    init(socketPath: String = VibePaths.hostSocket.path, appKey: @escaping () -> SymmetricKey? = { nil },
         bundledBuild: @escaping () -> Int = { HostBuild.id(ofExecutableAt: HostClient.hostExecutable.path) },
         handoverExecutable: @escaping () -> String = { HostClient.hostExecutable.path },
         reconnectDelays: [TimeInterval] = [0.2, 0.5, 1, 2, 3, 5], note: @escaping (String) -> Void = { Breadcrumbs.shared.note($0) }) {
        self.socketPath = socketPath
        self.handoverExecutable = handoverExecutable
        proofKey = appKey
        self.bundledBuild = bundledBuild
        self.reconnectDelays = reconnectDelays
        self.note = note
    }

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
        guard let connection = try? HostConnection(path: socketPath, queue: .main, appKey: proofKey()) else { return false }
        self.connection = connection
        state = .connecting
        connection.onEvent = { [weak self] in self?.handle($0) }
        connection.onOutput = { [weak self] id, bytes in self?.sinks[id]?.sink.output(bytes) }
        connection.onClose = { [weak self] in self?.connectionLost() }
        connection.onProofRefused = { [weak self] reason in self?.proofRefused(reason) }
        _ = try? connection.send(.hello(protocolVersion: HostProtocol.version, app: "VibeSwitcher"))
        return true
    }

    /// The host didn't take this app as VibeSwitcher (see `AppProof`): the lead's tools, a handover and ending
    /// sessions are off until it does. Asked once per launch.
    private var offeredKeyReset = false

    private func proofRefused(_ reason: String) {
        note("host: proof refused: \(reason)")
        guard !offeredKeyReset, let key = proofKey() else { return }
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
            guard case .ok = event else { return note("host: key not replaced: \(event)") }
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
        if let key = proofKey(), pipe(&keyPipe) == 0 {
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
        note("host: connection lost (welcomed=\(welcomed), replacing=\(replacing), waiting=\(whenReady.count))")
        connection = nil
        hostCapabilities = []
        sentInput = [:]
        let pending = replies
        replies = [:]
        pending.values.forEach { $0(.error(Self.wentAway)) }
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
        let delays = reconnectDelays
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
        if let asked = handover {
            note("host: handover failed: the host (pid \(asked.pid.map(String.init) ?? "?")) went away and no build answered")
            handover = nil
            handoverWaitedOut = false
        }
        note("host: gone; \(sessions.filter(\.isLive).count) sessions marked ended")
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
                note("host: \(input.count) bytes of input refused: \(message)")
                inputCut(input.id, 0, input.count, message)
            }
            sentInput = sentInput.filter { $0.key > seq }
        }
        switch envelope.event {
        case .welcome(let version, let build, let list, let capabilities, let pid, _):
            note("host: welcome v\(version) build \(build) pid \(pid.map(String.init) ?? "?"), \(list.count) sessions")
            hostCapabilities = Set(capabilities ?? [])
            reconnectAttempt = 0
            restartedForWaiting = false
            hostPID = pid
            if let asked = handover {
                note(Self.handoverOutcome(asked: asked, pid: pid, build: build, afterTheWait: handoverWaitedOut))
                handover = nil
                handoverWaitedOut = false
            }
            sessions = list
            // What ended while the app was away, or went with a host that's gone.
            removeSessionTemporaryFolders()
            canHandOver = hostCapabilities.contains(HostProtocol.Capability.handover)
            let live = list.filter(\.isLive).count
            let bundled = bundledBuild()
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
        if !session.isLive {
            screens[session.tty] = nil
            removeSessionTemporaryFolders(after: SessionTemp.settle + 1)
        }
        if case .outdated = state, sessions.isEmpty { replaceHost() }
        else if restartWhenEnded, !sessions.contains(where: \.isLive) { restartWhenEnded = false; replaceHost() }
    }

    /// The TMPDIRs of the lead's, workers' and verifiers' sessions (see `SessionTemp`) that no live session uses and that
    /// have settled, after `delay`: judged by the host's whole list then, so only while connected to it.
    private func removeSessionTemporaryFolders(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.connection != nil, ![.connecting, .notRunning].contains(self.state) else { return }
            let sessions = self.sessions
            DispatchQueue.global(qos: .utility).async {
                for folder in SessionTemp.removable(sessions: sessions) { try? FileManager.default.removeItem(at: folder) }
            }
        }
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

    /// The line for app.log when the first welcome after a handover was asked comes: handed over when the bundled build
    /// answers from the same process (the host re-executes itself in place), else a failure that says who answered.
    /// `afterTheWait`: the host's answer didn't come in `handoverWait`, and this welcome is how it went.
    static func handoverOutcome(asked: (pid: Int32?, build: Int), pid: Int32?, build: Int, afterTheWait: Bool = false) -> String {
        let shown = { (pid: Int32?) in pid.map(String.init) ?? "?" }
        if let was = asked.pid, pid != was {
            return "host: handover failed: a different host answered (pid \(shown(pid)), build \(build); was pid \(was))"
        }
        guard build == asked.build else {
            return "host: handover failed: the old build answered (pid \(shown(pid)), build \(build); asked for \(asked.build))"
        }
        return "host: handed over\(afterTheWait ? " after the wait" : "") (pid \(shown(pid)), build \(build))"
    }

    /// Asks the running host to become the bundled build, keeping every session: it answers ok, the connection drops
    /// and the new build's welcome comes on the next one (`connectionLost` reconnects). The host first probes the new
    /// build, for up to `hostProbeLimit`: its answer is waited for that long (`handoverWait`), not a request's 15 s.
    private func handOver() {
        // Asked again (the window's restart) once an earlier ask's answer was waited for in vain.
        guard !handingOver || handoverWaitedOut else { return }
        let bundled = bundledBuild()
        note("host: handing over to the bundled build \(bundled) (pid \(hostPID.map(String.init) ?? "?"))")
        handover = (hostPID, bundled)
        handoverWaitedOut = false
        handedOverTo = bundled
        handoverAsk += 1
        let ask = handoverAsk
        var answered = false
        request(.handover(executable: handoverExecutable()), wait: nil) { [weak self] event in
            answered = true
            guard let self, ask == self.handoverAsk, case .error(let message) = event, self.handingOver else { return }
            // The host re-executes itself: the connection drops by design (its ok can go with it). The next welcome
            // says how it went (`handoverOutcome`), or `hostGone` that no build came back.
            guard message != Self.wentAway else { return note("host: connection dropped for the handover; waiting for the new build") }
            note("host: handover failed: \(message)")
            self.handover = nil
            self.handoverWaitedOut = false
            // Carry on with the old build, as without a handover.
            if !self.isUsable { self.finishWaiting("The session host is out of date. Restart it from the window.") }
        }
        waitForHandover(ask, waited: 0, answered: { answered })
    }

    /// While the host's answer to handover `ask` hasn't come: a breadcrumb every `handoverBreadcrumb`, and once
    /// `handoverWait` is up, the wait ends without calling it failed (the host may still hand over: its next welcome
    /// says, see `handoverOutcome`). A refusal that comes later still fails it.
    private func waitForHandover(_ ask: Int, waited: TimeInterval, answered: @escaping () -> Bool) {
        let step = min(handoverBreadcrumb, handoverWait - waited)
        DispatchQueue.main.asyncAfter(deadline: .now() + step) { [weak self] in
            guard let self, ask == self.handoverAsk, self.handingOver, !answered() else { return }
            let waited = waited + step
            guard waited < self.handoverWait else {
                self.handoverWaitedOut = true
                self.note("host: handover: no answer in \(Int(waited)) s; the connection stays open and the next welcome says how it went")
                if !self.isUsable { self.finishWaiting("The session host is out of date. Restart it from the window.") }
                return
            }
            self.note("host: handover: waiting for the new build's probe, \(Int(waited)) s")
            self.waitForHandover(ask, waited: waited, answered: answered)
        }
    }

    /// Asks an idle host to quit; `connectionLost` then starts the bundled one.
    private func replaceHost() {
        guard !replacing else { return }
        note("host: replacing an outdated host")
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

    /// `wait`: how long the reply is waited for before it's taken as unanswered; nil waits until the connection drops.
    private func request(_ request: HostRequest, wait: TimeInterval? = HostClient.replyWait, reply: ((HostEvent) -> Void)? = nil) {
        guard let connection else {
            reply?(.error("Not connected to the session host."))
            return
        }
        let seq: Int
        do {
            seq = try connection.send(request)
        } catch {
            note("host: not sent: \(error)")
            reply?(.error("\(error)"))
            return
        }
        guard let reply else { return }
        replies[seq] = reply
        guard let wait else { return }
        // A reply that never comes must not leave its caller (e.g. a phone request) waiting forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.replies.removeValue(forKey: seq)?(.error("The session host didn't answer."))
        }
    }

    func spawn(_ spawn: SpawnRequest, completion: @escaping (Result<HostSession, HostClientError>) -> Void) {
        note("host: spawn \(spawn.label) in \((spawn.cwd as NSString).lastPathComponent)")
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

    /// Writes to the session's program. Keys and small writes go at once. A paste larger than a piece, input with
    /// `done`, and whatever follows either while one is going in, go in order through `pacedInput`: one piece at a
    /// time, each confirmed by the host before the next (its buffer for a program holds 1 MB, and refuses what
    /// doesn't fit: sent back to back, a big paste lost its end, or a piece from its middle). `done` says whether all
    /// of it went in; without one, what didn't is told (`inputCut`).
    func send(_ id: UUID, bytes: Data, reply: Bool, done: ((Bool) -> Void)? = nil) {
        guard !bytes.isEmpty else { done?(true); return }
        if reply {
            // The terminal's own answers to the program (cursor reports): small, and never paced.
            _ = try? connection?.send(.input(id: id, bytes: bytes, reply: true))
            return
        }
        // Taken on the way: none of it goes to the session (a replaced lead's, see `LeadController.takeInput`).
        if let inputGate, inputGate(id, bytes) { done?(true); return }
        if done == nil, pacedInput[id] == nil, bytes.count <= Self.inputPiece {
            guard let connection else {
                inputCut(id, 0, bytes.count, "VibeSwitcher isn't connected to the session host.")
                return
            }
            do {
                let seq = try connection.send(.input(id: id, bytes: bytes, reply: false))
                if hostCapabilities.contains(HostProtocol.Capability.inputRefusals) { sentInput[seq] = (id, bytes.count) }
            } catch {
                inputCut(id, 0, bytes.count, "\(error)")
            }
            return
        }
        pacedInput[id, default: PacedInput()].queue.append(PacedInput.Item(left: bytes, total: bytes.count, done: done))
        pumpInput(id)
    }

    /// Looks at input for a session before it's sent (not the terminal's answers to queries): true when it took it.
    var inputGate: ((UUID, Data) -> Bool)?

    /// Largest piece of input sent in one message (a frame holds ~768 KB of input once encoded).
    static let inputPiece = 256 * 1024
    /// Input going in piece by piece is given up when none of it went in for this long (the program stopped
    /// reading): what went in is told. Tests shorten it.
    var inputStallLimit: TimeInterval = 30
    /// What didn't go in, for input sent without `done`: session, bytes that went in, of how many, and why.
    var onInputCut: ((UUID, Int, Int, String) -> Void)?
    /// Cuts not shown yet: an alert is up, they follow it as one.
    private var unshownCuts: [(id: UUID, went: Int, total: Int, reason: String)] = []
    private var showingCut = false

    /// Input that didn't all go in: to `onInputCut` when set (tests), else the user is told how much did.
    private func inputCut(_ id: UUID, _ went: Int, _ total: Int, _ reason: String) {
        note("host: input to \(id.uuidString.prefix(8)) cut: \(went) of \(total) bytes went in: \(reason)")
        if let onInputCut { return onInputCut(id, went, total, reason) }
        unshownCuts.append((id, went, total, reason))
        guard !showingCut else { return }
        // Not from inside the call that found it: the alert runs its own loop.
        DispatchQueue.main.async { [weak self] in self?.showCuts() }
    }

    private func showCuts() {
        guard !showingCut, !unshownCuts.isEmpty else { return }
        let cuts = unshownCuts
        unshownCuts = []
        showingCut = true
        defer {
            showingCut = false
            showCuts()
        }
        let size = { (bytes: Int) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = cuts.allSatisfy({ $0.went == 0 }) ? "What you sent didn't go in." : "Not all of what you sent went in."
        alert.informativeText = cuts.map { cut in
            let name = sessions.first { $0.id == cut.id }?.label ?? "the session"
            let amount = cut.went == 0 ? "None of \(size(cut.total))" : "Only \(size(cut.went)) of \(size(cut.total))"
            return "\(amount) went into \(name): \(cut.reason)"
        }.joined(separator: "\n") + "\n\nThe rest was dropped, not sent later: send it again once the program is reading."
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    struct PacedInput {
        struct Item {
            var left: Data
            let total: Int
            let done: ((Bool) -> Void)?
        }
        var queue: [Item] = []
        var inFlight = false
        var lastProgress = Date()
    }

    /// Input going in piece by piece, per session (see `send(_:bytes:reply:done:)`).
    private var pacedInput: [UUID: PacedInput] = [:]

    /// Sends the next piece, then a screen read: the host handles a connection's requests in order and answers only
    /// input it refuses, so the read's answer is the piece's receipt. A refused piece is sent again once the host
    /// has room (it refuses everything until its buffer drained, so nothing later slips in ahead of it).
    private func pumpInput(_ id: UUID) {
        guard var paced = pacedInput[id], !paced.inFlight else { return }
        guard let item = paced.queue.first else {
            pacedInput[id] = nil
            return
        }
        guard let connection else { return giveUpInput(id, "VibeSwitcher isn't connected to the session host.") }
        let piece = item.left.prefix(Self.inputPiece)
        let seq: Int
        do {
            seq = try connection.send(.input(id: id, bytes: Data(piece), reply: false))
        } catch {
            return giveUpInput(id, "\(error)")
        }
        var refusal: String?
        replies[seq] = { event in if case .error(let message) = event { refusal = message } }
        paced.inFlight = true
        pacedInput[id] = paced
        request(.screen(id: id)) { [weak self] event in
            guard let self, var paced = self.pacedInput[id] else { return }
            if refusal == nil { self.replies[seq] = nil }
            paced.inFlight = false
            self.pacedInput[id] = paced
            guard case .screenText = event else {
                let why: String
                if case .error(let message) = event { why = message } else { why = "The session host didn't answer." }
                return self.giveUpInput(id, why)
            }
            if let refusal {
                guard Date().timeIntervalSince(paced.lastProgress) < self.inputStallLimit else {
                    return self.giveUpInput(id, "The program stopped reading its input (\(refusal))")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.pumpInput(id) }
                return
            }
            paced.lastProgress = Date()
            paced.queue[0].left = Data(paced.queue[0].left.dropFirst(piece.count))
            var finished: PacedInput.Item?
            if paced.queue[0].left.isEmpty { finished = paced.queue.removeFirst() }
            self.pacedInput[id] = paced
            finished?.done?(true)
            self.pumpInput(id)
        }
    }

    /// Drops what waits for the session: each with a `done` is told it didn't go in; how much of the rest did is told
    /// (`inputCut`).
    private func giveUpInput(_ id: UUID, _ reason: String) {
        guard let paced = pacedInput.removeValue(forKey: id) else { return }
        note("host: input to \(id.uuidString.prefix(8)) given up: \(reason)")
        let untold = paced.queue.filter { $0.done == nil }
        if !untold.isEmpty {
            let went = untold.reduce(0) { $0 + $1.total - $1.left.count }
            inputCut(id, went, untold.reduce(0) { $0 + $1.total }, reason)
        }
        paced.queue.forEach { $0.done?(false) }
    }

    /// Writes these into the session, each after its delay, then tells `confirmed` whether all of them went in (see
    /// `send(_:bytes:reply:done:)`). Once one didn't, the rest aren't sent: an Enter after a paste cut short would
    /// submit what did go in.
    func send(_ id: UUID, writes: [HostInput.Write], confirmed: @escaping (Bool) -> Void) {
        guard !writes.isEmpty else { return confirmed(true) }
        var ok = true
        var left = writes.count
        let settled = { (went: Bool) in
            ok = ok && went
            left -= 1
            if left == 0 { confirmed(ok) }
        }
        var at: TimeInterval = 0
        for write in writes {
            at += write.delay
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                guard let self, ok else { return settled(false) }
                self.send(id, bytes: Data(write.bytes), reply: false, done: settled)
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
