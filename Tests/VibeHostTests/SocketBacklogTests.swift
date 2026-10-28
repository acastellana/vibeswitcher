import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A burst of callers connecting at once: the host's backlog takes them all, and a refused connect is retried.
@Suite struct SocketBacklogTests {
    @Test func aBurstOf64ConnectsIsNotRefused() throws {
        let host = try TestHost()
        // On the host's queue, which accepts nothing until this returns: every connect waits in the backlog.
        let results = host.server.queue.sync { () -> [Result<Int32, Error>] in
            let lock = NSLock()
            var results: [Result<Int32, Error>] = []
            DispatchQueue.concurrentPerform(iterations: 64) { _ in
                let result = Result { try UnixSocket.connect(path: host.socket) }
                lock.lock(); results.append(result); lock.unlock()
            }
            return results
        }
        let fds = results.compactMap { try? $0.get() }
        fds.forEach { Darwin.close($0) }
        #expect(fds.count == 64, "refused: \(results.compactMap { if case .failure(let e) = $0 { return "\(e)" } else { return nil } })")
    }

    /// A socket file bound but not listening: every connect to it is refused.
    private func refusingSocket() throws -> (path: String, fd: Int32) {
        let path = scratchSocketPath()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try UnixSocket.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        return (path, fd)
    }

    @Test func aRefusedConnectIsRetriedWithBackoffThenFails() throws {
        let (path, fd) = try refusingSocket()
        defer { Darwin.close(fd); unlink(path) }
        var pauses: [TimeInterval] = []
        #expect(throws: UnixSocket.Failure.system("connect", ECONNREFUSED)) {
            try UnixSocket.connect(path: path, patience: 1) { pauses.append($0) }
        }
        #expect(pauses.count > 2 && pauses.count < 12)
        #expect(abs(pauses.reduce(0, +) - 1) < 0.001)
        #expect(zip(pauses, pauses.dropFirst()).dropLast().allSatisfy { $0 < $1 || $1 == 0.2 })
    }

    @Test func aRefusedConnectSucceedsOnceTheHostListens() throws {
        let (path, fd) = try refusingSocket()
        defer { Darwin.close(fd); unlink(path) }
        var pauses = 0
        let client = try UnixSocket.connect(path: path, patience: 1) { _ in
            pauses += 1
            if pauses == 2 { Darwin.listen(fd, SOMAXCONN) }
        }
        Darwin.close(client)
        #expect(pauses == 2)
    }

    @Test func noPatienceFailsAtOnce() throws {
        let (path, fd) = try refusingSocket()
        defer { Darwin.close(fd); unlink(path) }
        var pauses = 0
        #expect(throws: UnixSocket.Failure.system("connect", ECONNREFUSED)) {
            try UnixSocket.connect(path: path) { _ in pauses += 1 }
        }
        #expect(pauses == 0)
    }
}
