import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VibeCore

/// The app's connection to the host lives on the main thread, and it decoded every event there: 255 of 1396
/// main-thread samples in hang-20261107-115721 were JSON decoding (`HostEventEnvelope`, `HostSession.init(from:)`). A
/// connection now reads and decodes on a queue of its own and hands its caller's queue only the decoded events, in the
/// order they came, with the proof and the close as before. The host is a scratch stand-in here.
@Suite struct HostConnectionDeliveryTests {
    typealias StandIn = HostConnectionWriteTests.StandIn

    static let callers = DispatchSpecificKey<Bool>()

    private func callersQueue() -> DispatchQueue {
        let queue = DispatchQueue(label: "host-connection-delivery")
        queue.setSpecific(key: Self.callers, value: true)
        return queue
    }

    enum Seen: Equatable {
        case event(HostEventEnvelope)
        case output(UUID, Data)
        case refused(String)
        case closed
        /// A handler called anywhere but the caller's queue.
        case offQueue
    }

    /// What reached the handlers, in order.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Seen] = []
        var items: [Seen] { lock.withLock { seen } }
        func note(_ item: Seen) {
            let onCallers = DispatchQueue.getSpecific(key: HostConnectionDeliveryTests.callers) == true
            lock.withLock { seen.append(onCallers ? item : .offQueue) }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() -> Int { lock.withLock { count += 1; return count } }
    }

    private func frame(_ envelope: HostEventEnvelope) throws -> Data {
        HostFrame.encode(.control, try HostCoding.encode(envelope))
    }

    /// Every handler notes what it got in `log`; `closed` is signalled by `onClose`.
    private func watch(_ connection: HostConnection, on queue: DispatchQueue, log: Log, closed: DispatchSemaphore? = nil) {
        queue.sync {
            connection.onEvent = { log.note(.event($0)) }
            connection.onOutput = { log.note(.output($0, $1)) }
            connection.onProofRefused = { log.note(.refused($0)) }
            connection.onClose = {
                log.note(.closed)
                closed?.signal()
            }
        }
    }

    /// Holds `queue` (as a loaded Mac holds the main thread) until `release` is signalled, then runs `then` there.
    private func hold(_ queue: DispatchQueue, until release: DispatchSemaphore, then: @escaping @Sendable () -> Void = {}) async {
        let held = DispatchSemaphore(value: 0)
        queue.async {
            held.signal()
            _ = release.wait(timeout: .now() + hangGuard)
            then()
        }
        _ = await offPool { held.wait(timeout: .now() + hangGuard) }
    }

    private func screens(_ count: Int, of session: UUID) -> [HostEventEnvelope] {
        (0..<count).map { HostEventEnvelope(replyTo: nil, event: .screenText(id: session, text: "screen \($0)")) }
    }

    /// The handshake as the host makes it (challenge, a welcome to the hello sent before proof, the proof's answer, the
    /// welcome to the hello repeated after it), then 1,000 frames and the end: the caller sees one welcome, every frame
    /// in the order sent, and one close after them.
    @Test func aBurstArrivesInOrderAfterOneWelcomeAndEndsInOneClose() async throws {
        let host = try StandIn()
        let queue = callersQueue()
        let log = Log()
        let closed = DispatchSemaphore(value: 0)
        let connection = try HostConnection(path: host.path, queue: queue, appKey: SymmetricKey(size: .bits256))
        watch(connection, on: queue, log: log, closed: closed)
        try queue.sync { _ = try connection.send(.hello(protocolVersion: HostProtocol.version, app: "VibeSwitcher")) }
        host.accept()
        let challenge = HostEventEnvelope(replyTo: nil, event: .challenge(Data(repeating: 7, count: 32), keyless: false))
        #expect(host.write([try frame(challenge)]))
        let opening = host.requests(2)
        guard opening.map(\.seq) == [1, 2], case .hello? = opening.first?.request, case .proveApp? = opening.last?.request else {
            Issue.record("not a hello and its proof: \(opening.map(\.request))")
            return queue.sync { connection.close() }
        }
        // The welcome to the hello sent before proof isn't the app's to see; the one to the hello after it is.
        let early = HostEventEnvelope(replyTo: 1, event: .welcome(protocolVersion: HostProtocol.version, hostBuild: 1, sessions: []))
        let proved = HostEventEnvelope(replyTo: 2, event: .ok)
        #expect(host.write([try frame(early), try frame(proved)]))
        let again = host.requests(1)
        guard case .hello? = again.first?.request else {
            Issue.record("the hello wasn't repeated after the proof: \(again.map(\.request))")
            return queue.sync { connection.close() }
        }
        let welcome = HostEventEnvelope(replyTo: 1, event: .welcome(protocolVersion: HostProtocol.version, hostBuild: 2, sessions: []))
        let session = UUID()
        var frames = [try frame(welcome)]
        var expected: [Seen] = [.event(challenge), .event(proved), .event(welcome)]
        for (index, screen) in screens(1_000, of: session).enumerated() {
            if index % 10 == 9 {
                let bytes = Data("output \(index)".utf8)
                frames += HostFrame.output(session: session, bytes: bytes)
                expected.append(.output(session, bytes))
            } else {
                frames.append(try frame(screen))
                expected.append(.event(screen))
            }
        }
        expected.append(.closed)
        #expect(await offPool { host.write(frames) })
        host.hangUp()
        #expect(await offPool { closed.wait(timeout: .now() + hangGuard) } == .success, "no close")
        // Whatever was handed to the queue before this is in by now.
        queue.sync {}
        let seen = log.items
        #expect(seen.count == expected.count)
        #expect(seen == expected)
        #expect(seen.filter { if case .event(let envelope) = $0, case .welcome = envelope.event { return true } else { return false } }.count == 1)
    }

    /// The host challenges a connection as it takes it, and the reader answers before the caller's hello (the app's
    /// connection: its main thread is busy, or slow on a loaded Mac): the hello goes once, after the proof, and the
    /// caller sees one welcome.
    @Test func aHelloSentAfterTheChallengeGoesOnceAfterTheProof() async throws {
        let host = try StandIn()
        let queue = callersQueue()
        let log = Log()
        let closed = DispatchSemaphore(value: 0)
        let connection = try HostConnection(path: host.path, queue: queue, appKey: SymmetricKey(size: .bits256))
        watch(connection, on: queue, log: log, closed: closed)
        let marker = UUID()
        queue.sync {
            // Once the proof's answer is in, a request of its own: everything sent before it arrives first.
            connection.onEvent = { envelope in
                log.note(.event(envelope))
                if case .ok = envelope.event { _ = try? connection.send(.screen(id: marker)) }
            }
        }
        host.accept()
        let challenge = HostEventEnvelope(replyTo: nil, event: .challenge(Data(repeating: 5, count: 32), keyless: false))
        #expect(host.write([try frame(challenge)]))
        let proof = await offPool { host.requests(1) }
        guard case .proveApp? = proof.first?.request, let proofSeq = proof.first?.seq else {
            Issue.record("the challenge wasn't answered: \(proof.map(\.request))")
            return queue.sync { connection.close() }
        }
        let helloSeq = try queue.sync { try connection.send(.hello(protocolVersion: HostProtocol.version, app: "VibeSwitcher")) }
        let proved = HostEventEnvelope(replyTo: proofSeq, event: .ok)
        #expect(host.write([try frame(proved)]))
        var arrived: [HostRequestEnvelope] = []
        while true {
            let next = await offPool { host.requests(1) }
            guard let request = next.first else { break }
            arrived.append(request)
            if case .screen(let id) = request.request, id == marker { break }
        }
        let hellos = arrived.filter { if case .hello = $0.request { return true } else { return false } }
        #expect(hellos.map(\.seq) == [helloSeq], "hellos: \(arrived.map(\.request))")
        // Each hello the host got, welcomed.
        let welcome = HostEventEnvelope(replyTo: helloSeq, event: .welcome(protocolVersion: HostProtocol.version, hostBuild: 3, sessions: []))
        #expect(host.write(try hellos.map { _ in try frame(welcome) }))
        host.hangUp()
        #expect(await offPool { closed.wait(timeout: .now() + hangGuard) } == .success, "no close")
        queue.sync {}
        #expect(log.items == [.event(challenge), .event(proved)] + hellos.map { _ in .event(welcome) } + [.closed])
    }

    /// The challenge is decoded and answered on the reader's queue: a caller's queue held the whole time (the main thread
    /// of a loaded Mac) doesn't hold up the proof, and gets the events once it's free.
    @Test func theChallengeIsAnsweredWhileTheCallersQueueIsHeld() async throws {
        let host = try StandIn()
        let queue = callersQueue()
        let log = Log()
        let connection = try HostConnection(path: host.path, queue: queue, appKey: SymmetricKey(size: .bits256))
        watch(connection, on: queue, log: log)
        host.accept()
        let release = DispatchSemaphore(value: 0)
        await hold(queue, until: release)
        let challenge = HostEventEnvelope(replyTo: nil, event: .challenge(Data(repeating: 9, count: 32), keyless: false))
        #expect(host.write([try frame(challenge)]))
        let asked = await offPool { host.requests(1) }
        release.signal()
        guard case .proveApp? = asked.first?.request else {
            Issue.record("the challenge wasn't answered while the caller's queue was held: \(asked.map(\.request))")
            return queue.sync { connection.close() }
        }
        queue.sync {}
        #expect(log.items == [.event(challenge)])
        queue.sync { connection.close() }
    }

    /// Every frame is decoded off the caller's queue, and all 1,000 are while it's held; it then gets each, in order.
    @Test func decodingGoesOnWhileTheCallersQueueIsHeld() async throws {
        let host = try StandIn()
        let queue = callersQueue()
        let log = Log()
        let closed = DispatchSemaphore(value: 0)
        let decodedOnCallers = Counter()
        let decoded = Counter()
        let allDecoded = DispatchSemaphore(value: 0)
        let burst = screens(1_000, of: UUID())
        let connection = try HostConnection(path: host.path, queue: queue, appKey: nil, write: { Darwin.write($0, $1, $2) }) { tap in
            guard case .decoded = tap else { return }
            if DispatchQueue.getSpecific(key: Self.callers) == true { _ = decodedOnCallers.add() }
            if decoded.add() == burst.count { allDecoded.signal() }
        }
        watch(connection, on: queue, log: log, closed: closed)
        host.accept()
        let release = DispatchSemaphore(value: 0)
        await hold(queue, until: release)
        let frames = try burst.map(frame)
        #expect(await offPool { host.write(frames) })
        #expect(await offPool { allDecoded.wait(timeout: .now() + hangGuard) } == .success, "decoding waited on the caller's queue")
        #expect(log.items.isEmpty, "handed over while the caller's queue was held")
        release.signal()
        host.hangUp()
        #expect(await offPool { closed.wait(timeout: .now() + hangGuard) } == .success, "no close")
        queue.sync {}
        #expect(decodedOnCallers.value == 0, "decoded on the caller's queue")
        #expect(log.items == burst.map { .event($0) } + [.closed])
    }

    /// The host hangs up while the caller's queue is held, and the caller closes the connection before it hears of it:
    /// nothing is called after its close, neither the events still on their way nor `onClose`.
    @Test func nothingIsCalledAfterTheCallersClose() async throws {
        let host = try StandIn()
        let queue = callersQueue()
        let log = Log()
        let ended = DispatchSemaphore(value: 0)
        let connection = try HostConnection(path: host.path, queue: queue, appKey: nil, write: { Darwin.write($0, $1, $2) }) { tap in
            if case .ended = tap { ended.signal() }
        }
        watch(connection, on: queue, log: log)
        host.accept()
        let release = DispatchSemaphore(value: 0)
        await hold(queue, until: release) { connection.close() }
        #expect(host.write(try screens(3, of: UUID()).map(frame)))
        host.hangUp()
        #expect(await offPool { ended.wait(timeout: .now() + hangGuard) } == .success, "the reader didn't see the end")
        release.signal()
        queue.sync {}
        #expect(log.items.isEmpty)
        #expect(throws: HostConnection.SendFailure.closed) { try connection.send(.screen(id: UUID())) }
    }

    /// A write fails (the host went away) and the reader sees the end at once, each on its own queue: one `onClose`.
    @Test func twoEndsAtOnceCloseOnce() async throws {
        let host = try StandIn()
        let queue = callersQueue()
        let log = Log()
        let ended = DispatchSemaphore(value: 0)
        let writeFailed = DispatchSemaphore(value: 0)
        let connection = try HostConnection(path: host.path, queue: queue, appKey: nil, write: { _, _, _ in
            writeFailed.signal()
            errno = EPIPE
            return -1
        }) { tap in
            if case .ended = tap { ended.signal() }
        }
        watch(connection, on: queue, log: log)
        host.accept()
        let release = DispatchSemaphore(value: 0)
        await hold(queue, until: release)
        // From a thread of its own, as a held key's repeats are sent.
        _ = try await offPool { try connection.send(.screen(id: UUID())) }
        #expect(await offPool { writeFailed.wait(timeout: .now() + hangGuard) } == .success)
        host.hangUp()
        #expect(await offPool { ended.wait(timeout: .now() + hangGuard) } == .success, "the reader didn't see the end")
        release.signal()
        queue.sync {}
        #expect(log.items == [.closed])
    }

    /// A small bound, so a few MB from the host are many times it.
    static let smallBacklog = HostConnection.Backlog(bytes: 64 << 10, batches: 64)

    /// The most the reader may hand over past the bound: what one read (64 KB) completes, a frame at most.
    static let overshoot = 65_536 + HostFrame.maxPayload

    /// About 4 MB of screens, each a few KB: 64 times the small bound.
    private func flood(of session: UUID) -> [HostEventEnvelope] {
        let text = String(repeating: "x", count: 2_000)
        return (0..<2_000).map { HostEventEnvelope(replyTo: nil, event: .screenText(id: session, text: "\($0) \(text)")) }
    }

    /// The caller's queue held (a loaded Mac's main thread) while the host sends 64 times the bound: the reader stops
    /// with no more than the bound and a read handed over, the rest waits in the socket (the host's write with it), and
    /// once the queue is free everything arrives, in order, the reader going on as it's delivered.
    @Test func aHeldQueueStopsTheReaderAndThenGetsEverythingInOrder() async throws {
        let host = try StandIn()
        let queue = callersQueue()
        let log = Log()
        let closed = DispatchSemaphore(value: 0)
        let paused = DispatchSemaphore(value: 0)
        let decoded = Counter()
        let burst = flood(of: UUID())
        let frames = try burst.map(frame)
        let connection = try HostConnection(path: host.path, queue: queue, appKey: nil, write: { Darwin.write($0, $1, $2) },
                                            backlog: Self.smallBacklog) { tap in
            switch tap {
            case .decoded: _ = decoded.add()
            case .paused: paused.signal()
            case .ended: break
            }
        }
        watch(connection, on: queue, log: log, closed: closed)
        host.accept()
        let release = DispatchSemaphore(value: 0)
        await hold(queue, until: release)
        let written = DispatchSemaphore(value: 0)
        let wrote = Counter()
        DispatchQueue.global().async {
            if host.write(frames) { _ = wrote.add() }
            written.signal()
        }
        #expect(await offPool { paused.wait(timeout: .now() + hangGuard) } == .success, "the reader didn't stop for the backlog")
        // Stopped: what it decoded is about the bound, far from all the host sent, which waits in the socket.
        let decodedWhenPaused = decoded.value
        #expect(decodedWhenPaused < burst.count / 4, "decoded \(decodedWhenPaused) of \(burst.count) before stopping")
        #expect(connection.peakBacklog <= Self.smallBacklog.bytes + Self.overshoot)
        #expect(wrote.value == 0, "the host wrote all of it with the caller's queue held")
        #expect(log.items.isEmpty)
        release.signal()
        #expect(await offPool { written.wait(timeout: .now() + hangGuard) } == .success, "the host's write didn't finish")
        #expect(wrote.value == 1)
        host.hangUp()
        #expect(await offPool { closed.wait(timeout: .now() + hangGuard) } == .success, "no close")
        queue.sync {}
        let seen = log.items
        #expect(seen.count == burst.count + 1)
        #expect(seen == burst.map { .event($0) } + [.closed])
        // Never more held than the bound and a read, with the reader stopping and going on.
        #expect(connection.peakBacklog <= Self.smallBacklog.bytes + Self.overshoot, "peak \(connection.peakBacklog)")
    }

    /// Closed while the reader is stopped for the backlog: the socket is let go (the host's write fails), and nothing
    /// is delivered after the close.
    @Test func closingWhileTheReaderIsStoppedLetsTheSocketGo() async throws {
        let host = try StandIn()
        let queue = callersQueue()
        let log = Log()
        let paused = DispatchSemaphore(value: 0)
        let frames = try flood(of: UUID()).map(frame)
        let connection = try HostConnection(path: host.path, queue: queue, appKey: nil, write: { Darwin.write($0, $1, $2) },
                                            backlog: Self.smallBacklog) { tap in
            if case .paused = tap { paused.signal() }
        }
        watch(connection, on: queue, log: log)
        host.accept()
        var on: Int32 = 1
        setsockopt(host.peer, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let release = DispatchSemaphore(value: 0)
        await hold(queue, until: release) { connection.close() }
        let written = DispatchSemaphore(value: 0)
        let wrote = Counter()
        DispatchQueue.global().async {
            if host.write(frames) { _ = wrote.add() }
            written.signal()
        }
        #expect(await offPool { paused.wait(timeout: .now() + hangGuard) } == .success, "the reader didn't stop for the backlog")
        release.signal()
        #expect(await offPool { written.wait(timeout: .now() + hangGuard) } == .success, "the socket wasn't let go")
        #expect(wrote.value == 0, "the host wrote all of it to a closed connection")
        queue.sync {}
        #expect(log.items.isEmpty)
    }

    /// Let go of without a close while the reader is stopped (freeing a suspended source is a crash): it's freed, and
    /// so is the socket.
    @Test func lettingGoWhileTheReaderIsStoppedFreesIt() async throws {
        let host = try StandIn()
        let queue = callersQueue()
        let log = Log()
        let paused = DispatchSemaphore(value: 0)
        let frames = try flood(of: UUID()).map(frame)
        var connection: HostConnection? = try HostConnection(path: host.path, queue: queue, appKey: nil, write: { Darwin.write($0, $1, $2) },
                                                             backlog: Self.smallBacklog) { tap in
            if case .paused = tap { paused.signal() }
        }
        weak var freed = connection
        watch(connection!, on: queue, log: log)
        host.accept()
        var on: Int32 = 1
        setsockopt(host.peer, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let release = DispatchSemaphore(value: 0)
        await hold(queue, until: release)
        let written = DispatchSemaphore(value: 0)
        let wrote = Counter()
        DispatchQueue.global().async {
            if host.write(frames) { _ = wrote.add() }
            written.signal()
        }
        #expect(await offPool { paused.wait(timeout: .now() + hangGuard) } == .success, "the reader didn't stop for the backlog")
        connection = nil
        #expect(freed == nil, "still held")
        #expect(await offPool { written.wait(timeout: .now() + hangGuard) } == .success, "the socket wasn't let go")
        #expect(wrote.value == 0)
        release.signal()
        queue.sync {}
        #expect(log.items.isEmpty)
    }
}

extension HostConnectionWriteTests.StandIn {
    /// `frames`, written whole (the connection reads them as they come); false when the connection went away first.
    func write(_ frames: [Data]) -> Bool {
        var bytes = Data()
        for frame in frames { bytes.append(frame) }
        return bytes.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(peer, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// The end of what the host sends: the connection reads to its end.
    func hangUp() { shutdown(peer, SHUT_WR) }
}
