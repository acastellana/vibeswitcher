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
/// default, as it stays on the Mac, where the app connects by path and proves itself by its code (`AppProof`): the Mac
/// has no connector, and `connect(over:timeout:)` fails there at once.
public enum HostConnector {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// This system has no connector (the Mac).
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
    /// connection came: the host's end closed, a reply without exactly one descriptor, `timeout` passed, or the Mac.
    public static func connect(over connector: Int32, timeout: TimeInterval) throws -> Int32 {
        guard !Platform.CodeIdentity.isAvailable else { throw Failure.unavailable }
        let lock = locks.lock(for: connector)
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
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
                UnixSocket.configure(fd)
                return fd
            }
            // A nonblocking connector woken with nothing to read yet.
            guard errno == EAGAIN || errno == EINTR else { throw Failure.system("receive", errno) }
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

    /// The connector registered for `path`; nil for none (the default, and always on the Mac).
    public static func connector(for path: String) -> Int32? { HostConnector.registry.connector(for: path) }
}
