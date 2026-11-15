import Foundation
import VibeCore

/// The engine's one view of the session host (the engine plan's E2), rebuilt from the engine's part of the app's
/// `HostClient` (`Sources/VibeSwitcher/HostClient.swift`: the connection, the welcome and the events, requests with
/// their reply timers, held requests, spawn, input units, screens, history, kill and remove; the port map's row). One
/// connection, made through its dialer (in the server, `ConnectorDialer`: the connector it inherited, never the path),
/// and made again when it drops; the host's sessions as they change, on a change stream; the host's vault, asked on a
/// connection of its own for each call. It never starts, replaces or hands over a host (EN-D12): the server is the
/// host's child, and a host that's gone ends the link (`onGone`), and with it the server (E8).
///
/// Everything is on `queue`, the engine's: its state is read there, its callbacks run there, and its calls may be
/// made from any thread (made on `queue`, they run at once, in the caller's turn). The engine types only in units
/// (`HostRequest.inputUnit`), so a host that can't take them (its welcome doesn't list
/// `HostProtocol.Capability.inputUnits`) is refused, saying so: the link is gone.
public final class HostLink: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        /// Not welcomed yet: the first connection, or the next one after a drop.
        case connecting
        case connected
        /// The host is gone, or was refused: why. The link does nothing more.
        case gone(String)
    }

    /// Why a request the link was asked didn't go through.
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    /// Arms a one-shot wait: calls `fire` (from any thread) `seconds` from now.
    public typealias Later = (_ seconds: TimeInterval, _ fire: @escaping () -> Void) -> Void

    /// A unit's gate: asked right before the write at this index goes, it answers (once, from any thread, now or
    /// later) whether it still goes. No: the unit stops there, and what's left of it isn't written.
    public typealias Gate = (_ index: Int, _ go: @escaping (Bool) -> Void) -> Void

    /// What the link's waits are armed on and how long they are: real time by default, a test's clock instead.
    public struct Timing {
        /// A reply's wait (`replyWait`, a unit's `unitWait`). Nil: real time.
        public var reply: Later?
        /// The wait before each attempt at the next connection. Nil: real time.
        public var reconnect: Later?
        /// The wait before an ended session's TMPDIR is swept. Nil: real time.
        public var sweep: Later?
        /// How long to wait before each attempt to get back to a host that dropped the connection; then it's gone.
        public var reconnectDelays: [TimeInterval] = [0.2, 0.5, 1, 2, 3, 5]
        /// How long each attempt at a connection waits for the host's answer (its connector's): the engine's queue waits
        /// with it, so not the connector's own 30 s. A host busy longer is tried again, `reconnectDelays` apart.
        public var connectPatience: TimeInterval = 5

        public init() {}
    }

    /// The reply every request still waiting gets when the connection drops.
    public static let wentAway = "The session host went away."
    /// What a request gets while the link has no connection to send it on, and can't hold it for the next.
    public static let notConnected = "Not connected to the session host."
    /// Why a link is gone when the host went away and didn't come back.
    public static let stopped = "The session host stopped."
    /// Why a host that can't take input units is refused.
    public static let noInputUnits = "The session host doesn't take input units (its welcome doesn't list them): the engine types only in units, never piece by piece."
    /// How long a request's reply is waited for.
    public static let replyWait: TimeInterval = 15
    /// How long a spawn's reply is waited for: the host checks the session's identity before it answers, which a
    /// loaded machine can take a while over.
    public static let spawnWait: TimeInterval = 60
    /// How long a unit's part is waited for (`HostClient.unitWait`): the host answers each (written, refused, the
    /// session gone, the connection's end), but only once its turn came, behind other clients' units. This only
    /// catches a host that stopped answering.
    public static let unitWait: TimeInterval = 600
    /// Largest piece of a unit sent in one part (`HostClient.inputPiece`: a frame holds ~768 KB of input once encoded).
    public static let inputPiece = 256 * 1024
    /// How long after one unit of a session ended its next one starts (`HostClient.unitGap`, copied): a program that
    /// reads both at once takes them for one paste, with the Enter inside it. The host keeps a gap of its own too.
    public static let unitGap: TimeInterval = 0.1

    public let queue: DispatchQueue
    /// The host's sessions, as its last welcome listed them and its events changed them. On `queue`.
    public private(set) var sessions: [HostSession] = []
    /// Every change to `sessions`, by `NodeIds.session(host:)`: a session's new value, or nil once the host removed it.
    public let changes = Changes<HostSession>()
    /// On `queue`.
    public private(set) var state: State = .connecting
    /// What the connected host can do beyond the protocol (`HostProtocol.Capability`); none while not connected. On
    /// `queue`.
    public private(set) var capabilities: Set<String> = []
    /// When the host started, from its last welcome (nil from a host that doesn't say). On `queue`.
    public private(set) var hostStartedAt: Date?
    /// Called once, on `queue`, when the link is gone (the host went away and didn't come back, or was refused): why.
    public var onGone: ((String) -> Void)?
    /// Called on `queue` at each welcome the link takes (the first, and the next after each reconnect; not one refused
    /// for want of input units), once `state` is `.connected` and `sessions`, `capabilities` and `hostStartedAt` are
    /// the welcome's, before the requests held for it go out: when the host started, and its sessions. What waits for
    /// the host (the engine's pending starts, E4; its rebind after a host restart, E8) goes on here.
    public var onWelcome: ((_ hostStartedAt: Date?, _ sessions: [HostSession]) -> Void)?
    /// The host's lead vault, asked on a fresh connection through the dialer for each call (as `HostCall.vault` asks
    /// by a path); its launch files under `<root>/lead`.
    public let vault: LeadVault

    private let dialer: HostDialer
    private let timing: Timing
    private let sweeper: ([HostSession]) -> Void
    private let note: (String) -> Void
    private let clock: NodeClock?
    private let onQueue = DispatchSpecificKey<ObjectIdentifier>()
    // On `queue`.
    private(set) var connection: HostConnection?
    /// Counts the connections made. Each numbers its requests from 1, so a reply's timer speaks only for the connection
    /// it was armed on: on a later one its number is another request's.
    private var connectionsMade = 0
    private(set) var replies: [Int: (HostEvent) -> Void] = [:]
    /// Reconnect attempts since the connection was lost; reset by a welcome.
    private(set) var reconnectAttempt = 0
    private var held: [(request: HostRequest, wait: TimeInterval?, reply: ((HostEvent) -> Void)?)] = []
    private var units: [UUID: [Unit]] = [:]
    private var sweeps: Subscription?
    private var started = false

    /// `root`: the node's root, whose `lead` folder the vault's launch files go in and whose sessions' TMPDIRs are swept
    /// (`SessionTemp`), never this process's `VibePaths.root` unless given. `clock`: the engine's, which sweeps every
    /// `SessionTemp.sweepEvery` from the first welcome on (none: only at each welcome and session end). `sweep`: what a
    /// sweep does with the host's whole list (`SessionTemp.sweep` under `root`, off `queue`, by default); called on
    /// `queue`. `note`: the server's log.
    public init(dialer: HostDialer, root: URL, queue: DispatchQueue, clock: NodeClock? = nil, timing: Timing = Timing(),
                sweep: (([HostSession]) -> Void)? = nil, note: @escaping (String) -> Void = { _ in }) {
        self.dialer = dialer
        self.queue = queue
        self.clock = clock
        self.timing = timing
        self.note = note
        sweeper = sweep ?? Self.sweeper(root: root)
        vault = LeadVault(folder: root.appendingPathComponent("lead", isDirectory: true)) { [dialer] request in
            try Self.vault(request, through: dialer, timeout: HostCall.vaultTimeout)
        }
        queue.setSpecific(key: onQueue, value: ObjectIdentifier(self))
    }

    /// The default sweep: `SessionTemp.sweep` of `root`'s session folders (and, for the user's own root, the handover
    /// tests' leftovers in the shared temporary folder), on a utility queue.
    static func sweeper(root: URL) -> ([HostSession]) -> Void {
        let account = VibePaths.isAccountRoot(root, accountHome: VibePaths.accountHome)
        let folders = account ? URL(fileURLWithPath: "\(Platform.Files.sharedTemporaryRoot)/vibeswitcher-\(getuid())", isDirectory: true)
            : root.appendingPathComponent("tmp", isDirectory: true)
        let handovers = account ? URL(fileURLWithPath: Platform.Files.sharedTemporaryRoot, isDirectory: true) : nil
        return { sessions in
            DispatchQueue.global(qos: .utility).async { SessionTemp.sweep(sessions: sessions, in: folders, handovers: handovers) }
        }
    }

    /// Makes the first connection (once). A host that can't be reached now is tried again, `Timing.reconnectDelays`
    /// apart, and then the link is gone.
    public func start() {
        perform { [self] in
            guard !started else { return }
            started = true
            if !connect() { reconnect() }
        }
    }

    // MARK: The connection

    /// `work` on `queue`: now when called there, else after what's queued.
    private func perform(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: onQueue) == ObjectIdentifier(self) { work() } else { queue.async(execute: work) }
    }

    /// `work` on `queue`, `seconds` from now by `later` (real time when nil).
    private func after(_ seconds: TimeInterval, on later: Later?, _ work: @escaping () -> Void) {
        let fire = { [weak self] in self?.perform(work) ?? () }
        if let later { later(seconds, fire) } else { DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: fire) }
    }

    private var isGone: Bool {
        if case .gone = state { return true }
        return false
    }

    @discardableResult
    private func connect() -> Bool {
        if connection != nil { return true }
        guard !isGone else { return false }
        let made: HostConnection
        do { made = try dialer.connect(queue: queue, patience: timing.connectPatience) } catch {
            note("host link: no connection: \(error)")
            return false
        }
        connection = made
        connectionsMade += 1
        state = .connecting
        made.onEvent = { [weak self] in self?.handle($0) }
        made.onClose = { [weak self] in self?.connectionLost() }
        do { try made.send(.hello(protocolVersion: HostProtocol.version, app: "vibeswitcher-server")) } catch {
            note("host link: hello not sent: \(error)")
        }
        // A host that took the connection and never welcomes it (its queue stuck, or the hello lost) is one that didn't
        // answer: the connection is dropped and the next tried, so what's held for the welcome doesn't wait for good.
        let armedOn = connectionsMade
        after(Self.replyWait, on: timing.reply) { [weak self] in
            guard let self, self.connectionsMade == armedOn, self.state == .connecting, let connection = self.connection else { return }
            self.note("host link: no welcome in \(Int(Self.replyWait)) s: the connection is dropped")
            connection.close()
            self.connectionLost()
        }
        return true
    }

    /// Drops the connection and makes the next one, as a connection the host ended would be (tests).
    func connectAgain() {
        guard let connection else { return }
        connection.close()
        connectionLost()
    }

    private func connectionLost() {
        guard !isGone else { return }
        note("host link: connection lost (welcomed=\(state == .connected), held=\(held.count))")
        connection = nil
        capabilities = []
        let pending = replies
        replies = [:]
        pending.values.forEach { $0(.error(Self.wentAway)) }
        // The sessions stay as they are until the host is really gone; requests asked meanwhile wait for the next.
        state = .connecting
        reconnect()
    }

    private func reconnect() {
        guard reconnectAttempt < timing.reconnectDelays.count else { return end(Self.stopped) }
        let delay = timing.reconnectDelays[reconnectAttempt]
        reconnectAttempt += 1
        after(delay, on: timing.reconnect) { [weak self] in
            guard let self, self.connection == nil, !self.isGone else { return }
            if !self.connect() { self.reconnect() }
        }
    }

    /// The link is over: the host went away and didn't come back (every live session it listed is marked ended, exit
    /// -1, with its last state), or it was refused. What waits is answered as failed; `onGone` is told once.
    private func end(_ reason: String) {
        guard !isGone else { return }
        note("host link: gone: \(reason); \(sessions.filter(\.isLive).count) sessions marked ended")
        state = .gone(reason)
        if let connection {
            self.connection = nil
            connection.close()
        }
        capabilities = []
        sweeps = nil
        let now = Date()
        sessions = sessions.map { session in
            var ended = session
            if ended.isLive { ended.exit = HostSession.Exit(status: -1, at: now) }
            return ended
        }
        sessions.forEach { changes.send(NodeIds.session(host: $0.id), $0) }
        let pending = replies
        replies = [:]
        pending.values.forEach { $0(.error(reason)) }
        let failed = held
        held = []
        failed.forEach { $0.reply?(.error(reason)) }
        let waiting = units
        units = [:]
        waiting.values.flatMap { $0 }.forEach { $0.confirmed(false) }
        onGone?(reason)
    }

    private func handle(_ envelope: HostEventEnvelope) {
        if let seq = envelope.replyTo, let reply = replies.removeValue(forKey: seq) { reply(envelope.event) }
        switch envelope.event {
        case .welcome(let version, let build, let list, let listed, let pid, let startedAt):
            note("host link: welcome v\(version) build \(build) pid \(pid.map(String.init) ?? "?"), \(list.count) sessions")
            capabilities = Set(listed ?? [])
            guard capabilities.contains(HostProtocol.Capability.inputUnits) else { return end(Self.noInputUnits) }
            reconnectAttempt = 0
            hostStartedAt = startedAt
            let kept = Set(list.map(\.id))
            for session in sessions where !kept.contains(session.id) { changes.send(NodeIds.session(host: session.id), nil) }
            sessions = list
            list.forEach { changes.send(NodeIds.session(host: $0.id), $0) }
            state = .connected
            // What ended while the link was away, or went with a host that's gone; and then every while, what live
            // sessions' TMPDIRs can lose.
            sweepSessionFolders()
            if sweeps == nil, let clock {
                sweeps = clock.every(SessionTemp.sweepEvery) { [weak self] in self?.perform { self?.sweepSessionFolders() } }
            }
            onWelcome?(startedAt, list)
            resendHeld()
        case .spawned(let session), .sessionChanged(let session):
            upsert(session)
        case .sessionRemoved(let id):
            sessions.removeAll { $0.id == id }
            changes.send(NodeIds.session(host: id), nil)
        default:
            break
        }
    }

    private func upsert(_ session: HostSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            // A working agent's spinner changes its title many times a second, and reads the same everywhere.
            guard sessions[index] != session, !session.differsOnlyBySpinner(from: sessions[index]) else { return }
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        changes.send(NodeIds.session(host: session.id), session)
        if !session.isLive { after(SessionTemp.settle + 1, on: timing.sweep) { [weak self] in self?.sweepSessionFolders() } }
    }

    /// The TMPDIRs of the sessions that ended (see `SessionTemp`), judged by the host's whole list: so only while
    /// connected to it.
    private func sweepSessionFolders() {
        guard connection != nil, state == .connected else { return }
        sweeper(sessions)
    }

    // MARK: Requests

    /// Whether a request asked while the connection goes is asked again on the next one: what ends, starts or reads a
    /// session, never sent (the same request, once). Not a unit's part (the host's hold is the connection's) nor
    /// anything else.
    private static func isHeldForNextConnection(_ request: HostRequest) -> Bool {
        switch request {
        case .kill, .remove, .screen, .styledScreen, .history, .spawn, .hostNotes: return true
        default: return false
        }
    }

    /// What a request asks, for the log: the case's name, without the session it's about.
    private static func kind(of request: HostRequest) -> String {
        String("\(request)".prefix { $0 != "(" })
    }

    private func resendHeld() {
        let resend = held
        held = []
        for item in resend {
            // The notes are asked only of a host that lists them, and this one may not be the one they were asked of.
            if case .hostNotes = item.request, !capabilities.contains(HostProtocol.Capability.hostNotes) {
                item.reply?(.error("The session host doesn't list its notes."))
                continue
            }
            send(item.request, wait: item.wait, reply: item.reply)
        }
    }

    /// Sends `request`; `reply` gets the host's answer, or an error: the connection dropped, the link is gone, or
    /// nothing came in `wait` (nil: until the connection drops). On `queue`.
    private func send(_ request: HostRequest, wait: TimeInterval? = HostLink.replyWait, holdable: Bool = true, reply: ((HostEvent) -> Void)? = nil) {
        if case .gone(let reason) = state { reply?(.error(reason)); return }
        guard let connection, state == .connected else {
            if holdable, Self.isHeldForNextConnection(request) { held.append((request, wait, reply)); return }
            reply?(.error(Self.notConnected))
            return
        }
        let seq: Int
        do {
            seq = try connection.send(request)
        } catch {
            // The host closed this connection and the link hasn't been told yet: none of it went out.
            if case HostConnection.SendFailure.closed = error, holdable, Self.isHeldForNextConnection(request) {
                note("host link: \(Self.kind(of: request)) held for the next connection: the connection is closing")
                held.append((request, wait, reply))
                return
            }
            note("host link: not sent: \(Self.kind(of: request)): \(error)")
            reply?(.error("\(error)"))
            return
        }
        guard let reply else { return }
        replies[seq] = reply
        guard let wait else { return }
        // A dropped connection's waits are over (`connectionLost` answered them): its number now belongs to a request of
        // a later one.
        let armedOn = connectionsMade
        after(wait, on: timing.reply) { [weak self] in
            guard let self, self.connectionsMade == armedOn else { return }
            self.replies.removeValue(forKey: seq)?(.error("The session host didn't answer."))
        }
    }

    /// Starts a session. Asked before the welcome, it waits for it.
    public func spawn(_ request: SpawnRequest, completion: @escaping (Result<HostSession, Failure>) -> Void) {
        perform { [self] in
            note("host link: spawn \(request.label) in \((request.cwd as NSString).lastPathComponent)")
            send(.spawn(request), wait: Self.spawnWait) { [weak self] event in
                switch event {
                case .spawned(let session):
                    self?.upsert(session)
                    completion(.success(session))
                case .error(let message): completion(.failure(Failure(message)))
                default: completion(.failure(Failure("Unexpected reply from the session host.")))
                }
            }
        }
    }

    public func screen(_ id: UUID, completion: @escaping (String?) -> Void) {
        perform { [self] in
            send(.screen(id: id)) { event in
                if case .screenText(_, let text) = event { completion(text) } else { completion(nil) }
            }
        }
    }

    /// The screen with how it's drawn.
    public func styledScreen(_ id: UUID, completion: @escaping (LeadDelivery.Screen?) -> Void) {
        perform { [self] in
            send(.styledScreen(id: id)) { event in
                if case .styledScreenText(_, let text, let runs, let focusEvents) = event {
                    completion(LeadDelivery.Screen(text: text, runs: runs, focusEvents: focusEvents))
                } else {
                    completion(nil)
                }
            }
        }
    }

    public func history(_ id: UUID, lines: Int, completion: @escaping ((history: String, screen: String)?) -> Void) {
        perform { [self] in
            send(.history(id: id, lines: lines)) { event in
                if case .historyText(_, let history, let screen) = event { completion((history, screen)) } else { completion(nil) }
            }
        }
    }

    public func kill(_ id: UUID) {
        perform { [self] in send(.kill(id: id)) }
    }

    /// Forgets an ended session: the host's, and then the link's.
    public func remove(_ id: UUID) {
        perform { [self] in
            // Left over from a host that's gone: nothing to ask.
            if isGone {
                guard sessions.contains(where: { $0.id == id }) else { return }
                sessions.removeAll { $0.id == id }
                return changes.send(NodeIds.session(host: id), nil)
            }
            send(.remove(id: id)) { [weak self] event in
                guard let self, case .ok = event, self.sessions.contains(where: { $0.id == id }) else { return }
                self.sessions.removeAll { $0.id == id }
                self.changes.send(NodeIds.session(host: id), nil)
            }
        }
    }

    /// What the host saw that the server should show (`HostRequest.hostNotes`): asked only of a host whose welcome lists
    /// `HostProtocol.Capability.hostNotes`; nil from any other, or when it didn't answer. Asked while the link
    /// reconnects (or before the first welcome), it waits for the next welcome, which says whether they're listed; nil
    /// if the link goes.
    public func notes(completion: @escaping (HostNotes?) -> Void) {
        perform { [self] in
            if state == .connected, !capabilities.contains(HostProtocol.Capability.hostNotes) { return completion(nil) }
            send(.hostNotes) { event in
                if case .hostNotes(let notes) = event { completion(notes) } else { completion(nil) }
            }
        }
    }

    // MARK: Units

    /// One unit: a message's text and its Enter, an answer's keys.
    private final class Unit {
        let writes: [HostInput.Write]
        let gate: Gate?
        let confirmed: (Bool) -> Void
        /// The connection its first part went on (`connectionsMade` then): the host holds the session for the unit on
        /// that connection only, so the rest can't go on another.
        var connection: Int?

        init(writes: [HostInput.Write], gate: Gate?, confirmed: @escaping (Bool) -> Void) {
            self.writes = writes
            self.gate = gate
            self.confirmed = confirmed
        }
    }

    /// Writes these into the session as one unit (`HostRequest.inputUnit`: nothing anyone else types goes in between),
    /// each after its delay and once the one before went in, then tells `confirmed` (on `queue`) whether all of them
    /// did. Once one didn't, the rest aren't sent: an Enter after a paste cut short would submit what did go in. `gate`
    /// is asked right before each write (by its index) and may answer later: the session's next unit waits for it; no
    /// stops the unit there. A session's units go in one after another, in the order they were asked, `unitGap` apart.
    public func type(_ writes: [HostInput.Write], into id: UUID, gate: Gate? = nil, confirmed: @escaping (Bool) -> Void = { _ in }) {
        perform { [self] in
            guard !writes.isEmpty else { return confirmed(true) }
            guard !isGone else { return confirmed(false) }
            units[id, default: []].append(Unit(writes: writes, gate: gate, confirmed: confirmed))
            if units[id]?.count == 1 { runUnit(id) }
        }
    }

    /// A unit's writes with those longer than a piece cut into pieces (the rest of a write going at once), each first
    /// piece with the index `gate` is asked by (`HostClient.pieces(of:)`, copied).
    static func pieces(of writes: [HostInput.Write]) -> [(write: HostInput.Write, index: Int?)] {
        writes.enumerated().flatMap { index, write in
            stride(from: 0, to: max(write.bytes.count, 1), by: inputPiece).map { start in
                let bytes = Array(write.bytes[start..<min(start + inputPiece, write.bytes.count)])
                return (HostInput.Write(bytes: bytes, delay: start == 0 ? write.delay : 0), start == 0 ? index : nil)
            }
        }
    }

    private func runUnit(_ id: UUID) {
        guard let unit = units[id]?.first else { return }
        runPart(id, unit, pieces: Self.pieces(of: unit.writes), at: 0)
    }

    /// Sends the unit's pieces from `start` as parts the host writes whole: as many as fit a piece, up to the next one
    /// its gate is asked for. Between parts the host holds the session for this unit; a gate that says no ends the unit
    /// there, and the host lets the session go.
    private func runPart(_ id: UUID, _ unit: Unit, pieces: [(write: HostInput.Write, index: Int?)], at start: Int) {
        guard units[id]?.first === unit else { return }
        let send = { [weak self] in
            guard let self, self.units[id]?.first === unit else { return }
            if start == 0 {
                unit.connection = self.connectionsMade
            } else if unit.connection != self.connectionsMade {
                // Its connection dropped between its parts (a gate answered after the reconnect): the host let the session
                // go, and would take the rest (an Enter) for a unit of its own, after whatever went in meanwhile.
                self.note("host link: input unit to \(id.uuidString.prefix(8)) stopped: its connection dropped between its parts")
                return self.finishUnit(id, unit, ok: false)
            }
            var end = start + 1, size = pieces[start].write.bytes.count
            while end < pieces.count, unit.gate == nil || pieces[end].index == nil, size + pieces[end].write.bytes.count <= Self.inputPiece {
                size += pieces[end].write.bytes.count
                end += 1
            }
            let more = end < pieces.count
            self.send(.inputUnit(id: id, writes: pieces[start..<end].map(\.write), more: more), wait: Self.unitWait, holdable: false) { [weak self] event in
                guard let self else { return }
                guard case .ok = event else {
                    if case .error(let message) = event { self.note("host link: input unit to \(id.uuidString.prefix(8)) stopped: \(message)") }
                    return self.finishUnit(id, unit, ok: false)
                }
                more ? self.runPart(id, unit, pieces: pieces, at: end) : self.finishUnit(id, unit, ok: true)
            }
        }
        guard let gate = unit.gate, let index = pieces[start].index else { return send() }
        gate(index) { [weak self] go in
            self?.perform {
                guard let self, self.units[id]?.first === unit else { return }
                guard go else {
                    // The host holds the session for the part that won't come: let it go now (on its connection only; a
                    // dropped one let it go already).
                    if start > 0, unit.connection == self.connectionsMade {
                        self.send(.inputUnit(id: id, writes: [], more: false), holdable: false)
                    }
                    return self.finishUnit(id, unit, ok: false)
                }
                send()
            }
        }
    }

    private func finishUnit(_ id: UUID, _ unit: Unit, ok: Bool) {
        guard var queued = units[id], queued.first === unit else { return }
        queued.removeFirst()
        units[id] = queued.isEmpty ? nil : queued
        unit.confirmed(ok)
        guard !queued.isEmpty else { return }
        after(Self.unitGap, on: nil) { [weak self] in self?.runUnit(id) }
    }

    // MARK: The vault

    /// One vault request on a fresh connection through `dialer` (as `HostCall.vault` makes one by a path): hello, the
    /// welcome, the request, its reply. Throws when the host can't be asked or doesn't answer in `timeout` (the connect
    /// given half of it, as `HostCall` gives it); an error from the host is a refusal.
    static func vault(_ request: LeadVault.Request, through dialer: HostDialer, timeout: TimeInterval) throws -> LeadVault.Reply {
        switch try exchange(.vault(request), through: dialer, timeout: timeout) {
        case .vault(let reply): return reply
        case .error(let message): return .refused(message)
        default: return .refused("The session host answered something else.")
        }
    }

    private final class Exchange: @unchecked Sendable {
        var welcomed = false
        var seq: Int?
        var reply: HostEvent?
        var closed = false
        var unsent: Error?
    }

    private static func exchange(_ request: HostRequest, through dialer: HostDialer, timeout: TimeInterval) throws -> HostEvent {
        let queue = DispatchQueue(label: "vibenode.host-link.call")
        let done = DispatchSemaphore(value: 0)
        let state = Exchange()
        // Made on `queue`, with its handlers, in one go: nothing it hands over comes before them.
        let connection = try queue.sync { () throws -> HostConnection in
            let connection = try dialer.connect(queue: queue, patience: timeout / 2)
            connection.onClose = {
                state.closed = true
                done.signal()
            }
            connection.onEvent = { [weak connection] envelope in
                if case .welcome = envelope.event, !state.welcomed {
                    state.welcomed = true
                    do { state.seq = try connection?.send(request) } catch {
                        state.unsent = error
                        done.signal()
                    }
                } else if let seq = state.seq, envelope.replyTo == seq {
                    state.reply = envelope.event
                    done.signal()
                }
            }
            return connection
        }
        defer { queue.sync { connection.close() } }
        try queue.sync { _ = try connection.send(.hello(protocolVersion: HostProtocol.version, app: "vibeswitcher-server")) }
        guard done.wait(timeout: .now() + timeout) == .success else { throw Failure("The session host didn't answer in time.") }
        return try queue.sync {
            if let unsent = state.unsent { throw Failure("\(unsent)") }
            guard let reply = state.reply else {
                throw Failure("The session host closed the connection before answering (it may be restarting).")
            }
            return reply
        }
    }
}
