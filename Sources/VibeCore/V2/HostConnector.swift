import Foundation

/// The client's end of an app connector (the stage 2 plan's S2-D1, the security architecture document's S2): on Linux
/// the app is the session host's server child, and its connections to the host are the ones the host makes for it.
/// The child inherits one end of a `SOCK_SEQPACKET` pair, the connector; it asks for a connection by sending one byte
/// on it, and the host, once it has checked who sent the byte, hands back one end of a new stream pair whose other end
/// it holds as the app's (`HostServer.openAppConnector`). No connection made through the socket's path is ever the app
/// on Linux, so a socket put at the host's path never reaches the app.
///
/// `HostConnection` takes a path for which a connector is registered here (`HostConnection.register(connector:for:)`)
/// only through that connector, and never by its path, also when the connector fails. The registry is empty by
/// default, as it stays in the Mac app, which connects by path and proves itself by its code (`AppProof`). On the Mac
/// the node's server child has a connector too (the node on the Mac's step 3), a stream pair
/// (`Platform.Sockets.connectorType`) whose requests the host takes only from the child it started, running the code
/// whose cdhash it read at its start (`AppConnector`).
public enum HostConnector {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// No connector to ask over (none is said so today: the Mac's server child has one too).
        case unavailable
        /// The call named failed, with its errno: the host has closed its end (EPIPE), or the reply carried no
        /// descriptor (EBADMSG).
        case system(String, Int32)
        /// No reply within the time given: the host is busy, stopped or gone.
        case timedOut

        public var description: String {
            switch self {
            case .unavailable: return "this system has no connector to the session host"
            case .system(let call, let code): return "the connector to the session host: \(call): \(String(cString: strerror(code)))"
            case .timedOut: return "the session host didn't answer its connector"
            }
        }
    }

    /// How long `HostConnection` waits for the host's reply when its caller gives no patience (0, the app's own
    /// connection): the host answers on its one queue, which a burst of work can hold for a while. A caller's own
    /// patience (`HostCall`'s, at most half its timeout) is kept to as given, so its call stays within its timeout.
    public static let patience: TimeInterval = 30

    /// A new connection to the host, asked for over `connector`: one byte sent, the descriptor the host sends back
    /// taken, made nonblocking, close-on-exec and free of SIGPIPE as `UnixSocket.connect`'s are. One request at a time
    /// on each connector in this process (a lock), so each reply goes to its asker; one that came after its asker
    /// gave up goes to the next, which is harmless: every connection the host makes this way is alike. Throws when no
    /// connection came: the host's end closed, a reply without exactly one descriptor, or `timeout` passed.
    public static func connect(over connector: Int32, timeout: TimeInterval) throws -> Int32 {
        let lock = locks.lock(for: connector)
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        // A host gone is EPIPE, not SIGPIPE: on the Mac the socket's own switch (`SO_NOSIGPIPE`, which `send`'s write
        // relies on there), set by `Platform.Sockets.pair` as it makes the connector's pair: here only for a connector
        // made elsewhere, as the Mac takes it only while the host's end is open; nothing on Linux, whose `send` says so.
        Platform.Sockets.noSigPipe(socket: connector)
        var byte = UInt8(ascii: "c")
        while true {
            let sent = Platform.Sockets.send(connector, &byte, 1)
            if sent == 1 { break }
            if sent < 0, errno == EINTR { continue }
            // A connector made nonblocking whose buffer is full: wait until it takes the byte.
            guard sent < 0, errno == EAGAIN else { throw Failure.system("send", sent < 0 ? errno : EIO) }
            try wait(connector, for: Int16(POLLOUT), until: deadline)
        }
        while true {
            try wait(connector, for: Int16(POLLIN), until: deadline)
            if let fd = Platform.Sockets.receiveDescriptor(over: connector) {
                // A web listener's answer (`web`, H1) that came after its asker gave up: not a connection.
                guard isUnixSocket(fd) else {
                    Sys.close(fd)
                    continue
                }
                UnixSocket.configure(fd)
                return fd
            }
            // A nonblocking connector woken with nothing to read yet; a web answer carrying no descriptor (EBADMSG)
            // that came after its asker gave up, which is not this one's.
            guard errno == EAGAIN || errno == EINTR || errno == EBADMSG else { throw Failure.system("receive", errno) }
        }
    }

    /// Whether `fd` is a Unix-domain socket, as every connection the host hands back is.
    private static func isUnixSocket(_ fd: Int32) -> Bool {
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return named == 0 && Int32(address.ss_family) == AF_UNIX
    }

    /// What the host answered a web request (`HostWebListen`, H1).
    public enum WebAnswer: Equatable, Sendable {
        /// `listen`: the listening socket, close-on-exec, the caller's to close; `release`: nil.
        case ok(Int32?)
        /// The host's refusal, as it said it.
        case refused(String)
    }

    /// Sends `request` over `connector` and waits for the host's answer to it (`HostWebListen.answers`: `web ok WORDS`,
    /// a `listen`'s with its socket, or `web no WORDS: WHY`), under the same lock as `connect`'s requests. Every other
    /// message read meanwhile (a connection's, or a web answer to another request that came after its asker gave up) is
    /// closed and passed over, so a release never takes a listen's socket, nor one place's listen another's. A `listen`
    /// answered ok is refused unless its one socket listens on the address asked for, and on the port asked for (any,
    /// for 0). `timeout` bounds the whole call, the wait for the lock included. Throws as `connect` does.
    public static func web(_ request: HostWebListen.Request, over connector: Int32, timeout: TimeInterval) throws -> WebAnswer {
        // Messages with edges: Linux's `SOCK_SEQPACKET` connector only (the Mac's is a stream; its node's H1 is its own step).
        guard Platform.Sockets.connectorType == Platform.Sockets.seqpacket else {
            return .refused("this system's connector carries no web request (a stream)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        let lock = locks.lock(for: connector)
        // A connection asked for meanwhile holds it up to its own patience: never longer than this call's.
        guard lock.lock(before: deadline) else { throw Failure.timedOut }
        defer { lock.unlock() }
        Platform.Sockets.noSigPipe(socket: connector)
        let bytes = HostWebListen.bytes(request)
        while true {
            let sent = Platform.Sockets.send(bytes, with: [], over: connector)
            if sent == bytes.count { break }
            if sent < 0, errno == EINTR { continue }
            guard sent < 0, errno == EAGAIN else { throw Failure.system("send", sent < 0 ? errno : EIO) }
            try wait(connector, for: Int16(POLLOUT), until: deadline)
        }
        while true {
            try wait(connector, for: Int16(POLLIN), until: deadline)
            guard let got = Platform.Sockets.receive(over: connector, count: 512, room: 1) else {
                guard errno == EAGAIN || errno == EINTR else { throw Failure.system("receive", errno) }
                continue
            }
            if got.bytes.isEmpty, got.descriptors.isEmpty, Platform.Sockets.peerHasGone(connector) { throw Failure.system("receive", EPIPE) }
            guard let answer = HostWebListen.answers(request, got.bytes) else {
                got.descriptors.forEach { Sys.close($0) }
                continue
            }
            if let why = answer {
                got.descriptors.forEach { Sys.close($0) }
                return .refused(why)
            }
            switch request {
            case .release:
                got.descriptors.forEach { Sys.close($0) }
                return .ok(nil)
            case .listen(_, let address, let port):
                guard got.descriptors.count == 1, let fd = got.descriptors.first, Platform.TCP.isListening(fd),
                      Platform.TCP.localAddress(fd) == address, port == 0 || Platform.TCP.localPort(fd) == port else {
                    got.descriptors.forEach { Sys.close($0) }
                    return .refused("the host's answer carried no socket listening on \(address):\(port)")
                }
                return .ok(fd)
            }
        }
    }

    /// Waits until `fd` is ready for `events` (or has an error or hang-up to report, which the next call reads), or
    /// throws at `deadline`.
    private static func wait(_ fd: Int32, for events: Int16, until deadline: Date) throws {
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw Failure.timedOut }
            var waiting = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&waiting, 1, Int32(min(left * 1_000, Double(Int32.max)).rounded(.up)))
            if ready > 0 { return }
            if ready < 0, errno == EINTR { continue }
            if ready < 0 { throw Failure.system("poll", errno) }
        }
    }

    /// One lock per connector number, made when first asked for.
    private static let locks = Locks()

    private final class Locks: @unchecked Sendable {
        private let guarding = NSLock()
        private var byConnector: [Int32: NSLock] = [:]

        func lock(for connector: Int32) -> NSLock {
            guarding.lock()
            defer { guarding.unlock() }
            if let lock = byConnector[connector] { return lock }
            let lock = NSLock()
            byConnector[connector] = lock
            return lock
        }
    }

    /// The registry `HostConnection` reads (see `HostConnection.register(connector:for:)`): socket paths and the
    /// connector each is reached through. A registry, not one connector, because a test process runs many scratch
    /// hosts at once; the server registers one.
    fileprivate static let registry = Registry()

    fileprivate final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var connectors: [String: Int32] = [:]

        func set(_ connector: Int32?, for path: String) {
            lock.lock()
            defer { lock.unlock() }
            connectors[path] = connector
        }

        func connector(for path: String) -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            return connectors[path]
        }
    }
}

extension HostConnection {
    /// From now on a connection to the host at `path` is asked for over `connector` (see `HostConnector`), never made
    /// by the path, also when the connector fails. Replaces a connector registered for it before. The caller keeps
    /// `connector` open while it is registered.
    public static func register(connector: Int32, for path: String) { HostConnector.registry.set(connector, for: path) }

    /// A connection to the host at `path` is made by the path again, as before `register(connector:for:)`.
    public static func unregister(path: String) { HostConnector.registry.set(nil, for: path) }

    /// The connector registered for `path`; nil for none (the default, and always in the Mac app).
    public static func connector(for path: String) -> Int32? { HostConnector.registry.connector(for: path) }
}
