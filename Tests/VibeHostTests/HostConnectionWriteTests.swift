import Foundation
import Testing
@testable import VibeCore

/// The app's connection to the host lives on the main thread, and its writes went out there: a host slow to read (a
/// loaded Mac) held the main thread in write(2) for seconds (hang-20261031-182840: 363 of 968 samples, from
/// `SessionStore.refresh` → `HostClient.refreshScreens` → `HostConnection.send`). A connection's queue now only hands
/// its bytes on; they're written elsewhere, in order, when the socket has room. The host is a scratch stand-in here.
@Suite struct HostConnectionWriteTests {
    /// A listener on a scratch socket that takes one connection and reads only when asked.
    final class StandIn {
        let path = scratchSocketPath()
        private let listener: Int32
        private(set) var peer: Int32 = -1
        private var decoder = HostFrameDecoder()

        init() throws { listener = try UnixSocket.listen(path: path) }

        /// Takes the connection already made to it (the client's connect returned, so it's in the backlog).
        func accept() {
            peer = Sys.accept(listener, nil, nil)
            _ = fcntl(peer, F_SETFL, fcntl(peer, F_GETFL) & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: Int(hangGuard), tv_usec: 0)
            setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }

        /// The next `count` requests, as they arrive; fewer when the connection ends or stays quiet past the hang guard.
        func requests(_ count: Int) -> [HostRequestEnvelope] {
            var got: [HostRequestEnvelope] = []
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while got.count < count {
                if let frame = try? decoder.next() {
                    if let envelope = try? HostCoding.decode(HostRequestEnvelope.self, from: frame.payload) { got.append(envelope) }
                    continue
                }
                let read = Sys.read(peer, &buffer, buffer.count)
                guard read > 0 else { break }
                decoder.append(Data(buffer[0..<read]))
            }
            return got
        }

        deinit {
            if peer >= 0 { close(peer) }
            close(listener)
            unlink(path)
        }
    }

    /// Where each write(2) ran, from any thread.
    final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var onCallers = 0
        var onCallersQueue: Int { lock.withLock { onCallers } }
        func note(onCallersQueue: Bool) { if onCallersQueue { lock.withLock { onCallers += 1 } } }
    }

    static let callers = DispatchSpecificKey<Bool>()

    private func callersQueue() -> DispatchQueue {
        let queue = DispatchQueue(label: "host-connection-callers")
        queue.setSpecific(key: Self.callers, value: true)
        return queue
    }

    private func screenID(_ envelope: HostRequestEnvelope) -> UUID? {
        if case .screen(let id) = envelope.request { return id }
        return nil
    }

    /// A write the kernel holds (the hang reports' case): the caller's queue goes on answering, and both requests
    /// arrive, in order, once it's let go.
    @Test func aStalledWriteLeavesTheCallersQueueFree() async throws {
        let host = try StandIn()
        let queue = callersQueue()
        let writes = Writes()
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let connection = try HostConnection(path: host.path, queue: queue, appKey: nil) { fd, bytes, count in
            let onCallers = DispatchQueue.getSpecific(key: Self.callers) == true
            writes.note(onCallersQueue: onCallers)
            entered.signal()
            // Held as a loaded Mac's kernel holds it; on the caller's queue it isn't (it would hang the test, not fail it).
            if !onCallers { _ = gate.wait(timeout: .now() + hangGuard) }
            return Sys.write(fd, bytes, count)
        }
        host.accept()
        let first = UUID(), second = UUID()
        queue.async {
            _ = try? connection.send(.screen(id: first))
            _ = try? connection.send(.screen(id: second))
        }
        #expect(await offPool { entered.wait(timeout: .now() + hangGuard) } == .success)
        let answered = DispatchSemaphore(value: 0)
        queue.async { answered.signal() }
        #expect(await offPool { answered.wait(timeout: .now() + hangGuard) } == .success, "the caller's queue waits on a write")
        #expect(writes.onCallersQueue == 0, "write(2) ran on the caller's queue")
        for _ in 0..<8 { gate.signal() }
        #expect(host.requests(2).map(screenID) == [first, second])
        queue.sync { connection.close() }
    }

    /// A host that stops reading fills the socket: what's sent meanwhile waits, the caller's queue goes on answering,
    /// and every request arrives in the order sent once the host reads again.
    @Test func requestsSentWhileTheHostStopsReadingArriveInOrder() async throws {
        let host = try StandIn()
        let queue = callersQueue()
        let writes = Writes()
        let full = DispatchSemaphore(value: 0)
        let connection = try HostConnection(path: host.path, queue: queue, appKey: nil) { fd, bytes, count in
            writes.note(onCallersQueue: DispatchQueue.getSpecific(key: Self.callers) == true)
            let written = Sys.write(fd, bytes, count)
            let code = errno
            if written < 0, code == EAGAIN { full.signal() }
            errno = code
            return written
        }
        host.accept()
        // Far more than a local socket's buffers hold (8 KB each way by default).
        let session = UUID()
        let big = HostRequest.input(id: session, bytes: Data(repeating: 0x61, count: 512 << 10), reply: false)
        queue.async { _ = try? connection.send(big) }
        #expect(await offPool { full.wait(timeout: .now() + hangGuard) } == .success, "the socket never filled")
        let first = UUID(), second = UUID()
        queue.async {
            _ = try? connection.send(.screen(id: first))
            _ = try? connection.send(.screen(id: second))
        }
        let answered = DispatchSemaphore(value: 0)
        queue.async { answered.signal() }
        #expect(await offPool { answered.wait(timeout: .now() + hangGuard) } == .success, "the caller's queue waits on a write")
        let arrived = host.requests(3)
        #expect(arrived.count == 3)
        if case .input(let id, let bytes, _)? = arrived.first?.request {
            #expect(id == session && bytes.count == 512 << 10)
        } else {
            Issue.record("the big request didn't arrive first: \(arrived.map(\.request))")
        }
        #expect(arrived.dropFirst().map(screenID) == [first, second])
        #expect(arrived.map(\.seq) == arrived.map(\.seq).sorted())
        #expect(writes.onCallersQueue == 0, "write(2) ran on the caller's queue")
        queue.sync { connection.close() }
    }
}
