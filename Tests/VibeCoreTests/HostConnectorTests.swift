import Foundation
import Testing
@testable import VibeCore

/// The client's half of the app's connector (the stage 2 plan's Task 4b2, S2-D1): a path with a connector registered
/// for it is reached only through that connector, never by the path, also when the connector fails, so a socket put
/// at the host's path never reaches the app. Without one (the default, and always on the Mac) a connection is made by
/// the path as today. The host's half is `HostIdentitySeamTests`'.
struct HostConnectorTests {
    let temp = Scratch()

    /// A listener at a path of its own, short enough for a socket's (its folder goes with the test's `Scratch`).
    func listener() throws -> (path: String, fd: Int32) {
        var folder = temp.url("hc")
        if folder.path.utf8.count + 3 >= 100 {
            folder = temp.adopt(URL(fileURLWithPath: "\(Platform.Files.sharedTemporaryRoot)/vs-hc-\(UUID().uuidString.prefix(8))"))
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("s").path
        return (path, try UnixSocket.listen(path: path))
    }

    /// The connections waiting at `listener` now (it's nonblocking): each one taken, and closed.
    func connections(at listener: Int32) -> Int {
        var count = 0
        while case let fd = Platform.Sockets.accept(listener), fd >= 0 {
            Sys.close(fd)
            count += 1
        }
        return count
    }

    /// A connector registered for the path that can't give a connection: on Linux one whose far end has closed, on
    /// the Mac any number (it has no connector). The connection throws, and the listener at the path has none.
    @Test func aRegisteredPathIsNeverReachedByThePath() throws {
        let (path, listening) = try listener()
        defer { Sys.close(listening) }
        var connector: Int32 = 99_999
        if !Platform.CodeIdentity.isAvailable {
            let (mine, theirs) = try #require(Platform.Sockets.pair(type: Platform.Sockets.seqpacket))
            Sys.close(theirs)
            connector = mine
        }
        defer { if connector != 99_999 { Sys.close(connector) } }
        HostConnection.register(connector: connector, for: path)
        defer { HostConnection.unregister(path: path) }
        #expect(HostConnection.connector(for: path) == connector)

        let queue = DispatchQueue(label: "host-connector-test")
        #expect(throws: HostConnector.Failure.self) { _ = try HostConnection(path: path, queue: queue, appKey: nil) }
        #expect(throws: HostConnector.Failure.self) {
            _ = try HostCall.request(.hello(protocolVersion: HostProtocol.version, app: "test"), socket: path, appKey: nil, timeout: 5)
        }
        #expect(connections(at: listening) == 0)
    }

    /// Through a connector whose host never answers, a call keeps to its timeout: `HostCall`'s connect waits its own
    /// patience (at most half its timeout), not the connector's longer wait for a caller that gives none.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's connector; the Mac has none"))
    func aCallThroughAConnectorKeepsToItsTimeout() throws {
        let (path, listening) = try listener()
        defer { Sys.close(listening) }
        let (host, connector) = try #require(Platform.Sockets.pair(type: Platform.Sockets.seqpacket))
        defer {
            Sys.close(host)
            Sys.close(connector)
        }
        HostConnection.register(connector: connector, for: path)
        defer { HostConnection.unregister(path: path) }

        let started = Date()
        #expect(throws: HostConnector.Failure.timedOut) {
            _ = try HostCall.request(.hello(protocolVersion: HostProtocol.version, app: "test"), socket: path, appKey: nil, timeout: 1)
        }
        let took = Date().timeIntervalSince(started)
        #expect(took < 5, "took \(took) s with a timeout of 1 s")
        #expect(connections(at: listening) == 0)
    }

    /// With no connector registered, a connection is made by the path, as always; and with one, a connection asked
    /// not to use it (`viaConnector: false`: a test's other process) is made by the path too.
    @Test func anUnregisteredPathConnectsAsToday() throws {
        let (path, listening) = try listener()
        defer { Sys.close(listening) }
        #expect(HostConnection.connector(for: path) == nil)
        let queue = DispatchQueue(label: "host-connector-test")
        let plain = try HostConnection(path: path, queue: queue, appKey: nil)
        defer { queue.sync { plain.close() } }
        #expect(connections(at: listening) == 1)

        HostConnection.register(connector: 99_999, for: path)
        defer { HostConnection.unregister(path: path) }
        let byPath = try HostConnection(path: path, queue: queue, appKey: nil, viaConnector: false)
        defer { queue.sync { byPath.close() } }
        #expect(connections(at: listening) == 1)

        HostConnection.unregister(path: path)
        #expect(HostConnection.connector(for: path) == nil)
    }

    /// Through a connector, the connection is the one the host hands back: the byte asking for it arrives on the
    /// host's end with its sender, this process; and with an app key given and no hello sent, a request goes out at
    /// once, held for no proof (the host sends such a connection no challenge). This test plays the host.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's connector; the Mac has none"))
    func aConnectorsConnectionIsTheOneTheHostHandsBack() async throws {
        let (path, listening) = try listener()
        defer { Sys.close(listening) }
        let (host, connector) = try #require(Platform.Sockets.pair(type: Platform.Sockets.seqpacket))
        defer {
            Sys.close(host)
            Sys.close(connector)
        }
        Platform.Sockets.enableCredentials(host)
        HostConnection.register(connector: connector, for: path)
        defer { HostConnection.unregister(path: path) }

        // The host: one request read with its sender, a stream pair made, one end handed back.
        let served: Task<(sender: Platform.PeerToken?, end: Int32), Error> = Task.detached {
            var byte: UInt8 = 0
            let (count, sender) = withUnsafeMutableBytes(of: &byte) { Platform.Sockets.receive(host, into: $0) }
            guard count == 1, let (mine, theirs) = Platform.Sockets.pair(type: Platform.Sockets.stream) else { throw CancellationError() }
            defer { Sys.close(theirs) }
            UnixSocket.configure(mine)
            guard Platform.Sockets.sendDescriptor(theirs, over: host) else { throw CancellationError() }
            return (sender, mine)
        }
        let queue = DispatchQueue(label: "host-connector-test")
        let connection = try await offPool { try HostConnection(path: path, queue: queue, appKey: SymmetricKey(size: .bits256)) }
        defer { queue.sync { connection.close() } }
        let byPath = connections(at: listening)
        #expect(byPath == 0)
        // Made by the path, nothing asked the host: its read ends here rather than wait for good.
        if byPath != 0 { _ = shutdown(host, Int32(SHUT_RDWR)) }
        let (sender, end) = try await served.value
        defer { Sys.close(end) }
        let own = try #require(Platform.Processes.token(getpid()))
        #expect(sender.map { $0.sameImage(as: own) } == true, "\(String(describing: sender)), this process \(own)")

        // A request, no hello: it reaches the host's end at once.
        let seq = try connection.send(.census)
        var decoder = HostFrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var request: HostRequestEnvelope?
        #expect(await eventually {
            let count = Sys.read(end, &buffer, buffer.count)
            if count > 0 { decoder.append(Data(buffer[0..<count])) }
            if let frame = try? decoder.next() { request = try? HostCoding.decode(HostRequestEnvelope.self, from: frame.payload) }
            return request != nil
        })
        #expect(request == HostRequestEnvelope(seq: seq, request: .census))

        // What the host sends on it comes back as events.
        var events: [HostEventEnvelope] = []
        let lock = NSLock()
        queue.sync {
            connection.onEvent = { event in
                lock.lock()
                events.append(event)
                lock.unlock()
            }
        }
        let reply = HostFrame.encode(.control, try HostCoding.encode(HostEventEnvelope(replyTo: seq, event: .ok)))
        #expect(reply.withUnsafeBytes { Platform.Sockets.send(end, $0.baseAddress, $0.count) } == reply.count)
        #expect(await eventually {
            lock.lock()
            defer { lock.unlock() }
            return events.contains { $0.replyTo == seq }
        })
    }
}
