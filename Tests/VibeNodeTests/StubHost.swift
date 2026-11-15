import Foundation
import VibeCore
import VibeNode

/// A stand-in session host on a socket of its own (no real host, no real sessions), for what a scratch host can't be
/// made to do on cue: a welcome without a capability, a reply that never comes, a session changed by its spinner only,
/// a host that's gone. It speaks the protocol's frames (as the app's `HostClientHandoverTests.FakeHost` does), welcomes
/// every hello with its sessions and capabilities, and answers the rest as told. Its dialer connects by its path: no
/// connector is registered for it.
final class StubHost: @unchecked Sendable {
    let path: String
    private let queue = DispatchQueue(label: "stub-host")
    private var listener: DispatchSourceRead?
    private var clients: [Int32: (source: DispatchSourceRead, decoder: HostFrameDecoder)] = [:]
    // On `queue`.
    private var asked: [HostRequest] = []
    private var accepted = 0
    private var welcomeCapabilities: [String]
    private var listed: [HostSession]
    private var screens = true
    let notes = HostNotes(startedAt: Date(timeIntervalSince1970: 1_800_000_000), serverRestarts: 2, replacedPaths: ["/x/host.sock"],
                          refusedAppConnections: 1)
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// The capabilities a host on Linux lists that the link needs (input units) by default.
    init(_ scratch: Scratch, capabilities: [String] = [HostProtocol.Capability.inputUnits], sessions: [HostSession] = []) throws {
        welcomeCapabilities = capabilities
        listed = sessions
        path = try scratch.shortFolder("vss").appendingPathComponent("h.sock").path
        let fd = try UnixSocket.listen(path: path)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(fd) }
        source.setCancelHandler { Sys.close(fd) }
        source.resume()
        listener = source
    }

    deinit { quit() }

    /// A live session as a host lists it.
    static func session(title: String = "", tty: String = "ttypts9") -> HostSession {
        HostSession(id: UUID(), tty: tty, childPID: 1, cwd: "/nonexistent/stub", command: "sleep 600", label: "Stub", agent: nil, title: title,
                    startedAt: Date(), cols: 80, rows: 24, exit: nil)
    }

    /// A dialer to this host, by its path.
    var dialer: HostDialer { Dialer(path: path) }

    private struct Dialer: HostDialer {
        let path: String
        func connect(queue: DispatchQueue) throws -> HostConnection {
            try HostConnection(path: path, queue: queue, appKey: nil, viaConnector: false)
        }
    }

    /// What every connection asked, in order.
    var requests: [HostRequest] { queue.sync { asked } }

    /// How many connections it took.
    var connections: Int { queue.sync { accepted } }

    /// Whether it answers `screen` (false: never, so the request's own wait ends it).
    var answersScreens: Bool {
        get { queue.sync { screens } }
        set { queue.sync { screens = newValue } }
    }

    /// The sessions the next welcome lists.
    var sessions: [HostSession] {
        get { queue.sync { listed } }
        set { queue.sync { listed = newValue } }
    }

    /// Sends `event` to every connection, as the host sends a session's change.
    func push(_ event: HostEvent) {
        queue.sync { for fd in clients.keys { send(event, replyTo: nil, on: fd) } }
    }

    /// Ends every connection; it still listens.
    func dropConnections() {
        queue.sync { Array(clients.keys).forEach(drop) }
    }

    /// Gone, socket and all.
    func quit() {
        queue.sync {
            Array(clients.keys).forEach(drop)
            listener?.cancel()
            listener = nil
        }
        unlink(path)
    }

    private func accept(_ listening: Int32) {
        while true {
            let fd = Platform.Sockets.accept(listening)
            guard fd >= 0 else { return }
            UnixSocket.configure(fd)
            accepted += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(fd) }
            source.setCancelHandler { Sys.close(fd) }
            clients[fd] = (source, HostFrameDecoder())
            source.resume()
        }
    }

    private func read(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = Sys.read(fd, &buffer, buffer.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else { return drop(fd) }
        clients[fd]?.decoder.append(Data(buffer[0..<count]))
        while let frame = try? clients[fd]?.decoder.next() {
            guard let envelope = try? HostCoding.decode(HostRequestEnvelope.self, from: frame.payload) else { continue }
            handle(envelope, on: fd)
        }
    }

    private func handle(_ envelope: HostRequestEnvelope, on fd: Int32) {
        asked.append(envelope.request)
        switch envelope.request {
        case .hello:
            send(.welcome(protocolVersion: HostProtocol.version, hostBuild: 42, sessions: listed, capabilities: welcomeCapabilities,
                          pid: 4242, startedAt: startedAt), replyTo: envelope.seq, on: fd)
        case .screen(let id):
            if screens { send(.screenText(id: id, text: "stub screen"), replyTo: envelope.seq, on: fd) }
        case .history(let id, _):
            send(.historyText(id: id, history: "stub history", screen: "stub screen"), replyTo: envelope.seq, on: fd)
        case .hostNotes:
            send(.hostNotes(notes), replyTo: envelope.seq, on: fd)
        default:
            send(.ok, replyTo: envelope.seq, on: fd)
        }
    }

    private func send(_ event: HostEvent, replyTo: Int?, on fd: Int32) {
        guard let payload = try? HostCoding.encode(HostEventEnvelope(replyTo: replyTo, event: event)) else { return }
        let frame = HostFrame.encode(.control, payload)
        _ = frame.withUnsafeBytes { Platform.Sockets.send(fd, $0.baseAddress, $0.count) }
    }

    private func drop(_ fd: Int32) {
        clients.removeValue(forKey: fd)?.source.cancel()
    }
}

/// A clock the test moves (no real time passes on it): what a link's waits are armed on (`HostLink.Timing`). Each
/// wake armed is kept, in order, so a test can fire one itself (`armed`).
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var pending: [(at: TimeInterval, order: Int, fire: () -> Void)] = []
    private var all: [() -> Void] = []

    /// Seconds moved so far.
    var now: TimeInterval { lock.withLock { time } }

    /// Every wake armed so far, in the order armed (fired or not).
    var armed: [() -> Void] { lock.withLock { all } }

    var schedule: HostLink.Later {
        { [self] seconds, fire in
            lock.withLock {
                pending.append((time + seconds, all.count, fire))
                all.append(fire)
            }
        }
    }

    /// Moves the clock on by `seconds` and fires, on this thread and in time order, every wake due by then.
    func advance(_ seconds: TimeInterval) {
        let due = lock.withLock { () -> [() -> Void] in
            time += seconds
            let due = pending.filter { $0.at <= time }.sorted { ($0.at, $0.order) < ($1.at, $1.order) }
            pending.removeAll { $0.at <= time }
            return due.map(\.fire)
        }
        due.forEach { $0() }
    }
}

/// A value several threads read and write (a link's callbacks run on its queue, the test reads on its own).
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
