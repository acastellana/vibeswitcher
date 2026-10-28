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

    /// A host carried on from a build that listened with a backlog of 16 (its socket survives the exec, and with it
    /// the backlog) takes a burst of 64 too.
    @Test func aHostCarriedOnFromAnOlderBuildTakesABurstOf64() throws {
        let path = scratchSocketPath()
        let lock = path + ".lock"
        defer { unlink(path); unlink(lock) }
        let lockFD = open(lock, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        #expect(flock(lockFD, LOCK_EX | LOCK_NB) == 0)
        let (_, listenFD) = try refusingSocket(path)
        #expect(Darwin.listen(listenFD, 16) == 0)
        UnixSocket.configure(listenFD)
        var config = HostServer.Config(socketPath: path, lockPath: lock, shell: "/bin/sh", launcher: hostLauncher,
                                       baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], hostBuild: 43)
        config.idleExit = nil
        let server = HostServer(config: config)
        _ = try server.start(restoring: HostHandover.State(fromBuild: 42, startedAt: Date(), lockFD: lockFD, listenFD: listenFD,
                                                          secretFD: nil, sessions: []))
        defer { server.stop(terminateSessions: true) }
        let results = server.queue.sync { () -> [Result<Int32, Error>] in
            let lock = NSLock()
            var results: [Result<Int32, Error>] = []
            DispatchQueue.concurrentPerform(iterations: 64) { _ in
                let result = Result { try UnixSocket.connect(path: path) }
                lock.lock(); results.append(result); lock.unlock()
            }
            return results
        }
        let fds = results.compactMap { try? $0.get() }
        fds.forEach { Darwin.close($0) }
        #expect(fds.count == 64)
    }

    /// A socket file bound but not listening: every connect to it is refused.
    private func refusingSocket(_ path: String = scratchSocketPath()) throws -> (path: String, fd: Int32) {
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
