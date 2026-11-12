import Foundation
import Testing
import VibePlatform

// A stream socket's type as the Int32 `socket` takes: glibc's is an enum to Swift, the Mac's and musl's a number.
#if canImport(Glibc)
private let streamSocket = Int32(SOCK_STREAM.rawValue)
#else
private let streamSocket = SOCK_STREAM
#endif

/// `Sys`'s functions are the C library's own under names every system has: each does what the system's does and
/// returns what it returns.
struct SysTests {
    @Test func aPipeCarriesBytesAndClosesTwice() throws {
        var ends: [Int32] = [-1, -1]
        try #require(Sys.pipe(&ends) == 0)
        let sent: [UInt8] = [0x76, 0x73, 0x0A]
        #expect(Sys.write(ends[1], sent, sent.count) == 3)
        var received = [UInt8](repeating: 0, count: 8)
        #expect(Sys.read(ends[0], &received, received.count) == 3)
        #expect(Array(received.prefix(3)) == sent)
        #expect(Sys.close(ends[1]) == 0)
        // The end closed twice is first moved to a number far above the lowest free one, which is what the system
        // gives the next descriptor opened: no other test's, opened between the two, is closed in its place.
        // From 400: SpawnTests numbers its extra descriptors from 100, and one of those opened between the two closes
        // would be closed by the second.
        let high = fcntl(ends[0], F_DUPFD_CLOEXEC, 400)
        #expect(Sys.close(ends[0]) == 0)
        try #require(high >= 400)
        #expect(Sys.close(high) == 0)
        let again = Sys.close(high)
        let code = errno
        #expect(again == -1)
        #expect(code == EBADF)
    }

    @Test func aFileIsOpenedWithItsModeAndCutShort() throws {
        let folder = try TestScriptLinuxTests.scratch("sys-file")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("file").path

        let missing = Sys.open(path, O_RDONLY)
        let code = errno
        #expect(missing == -1)
        #expect(code == ENOENT)

        let made = Sys.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        try #require(made >= 0)
        #expect(Sys.write(made, "hello", 5) == 5)
        #expect(Sys.close(made) == 0)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)

        #expect(Sys.truncate(path, 2) == 0)
        let opened = Sys.open(path, O_RDONLY)
        try #require(opened >= 0)
        defer { Sys.close(opened) }
        var received = [UInt8](repeating: 0, count: 8)
        #expect(Sys.read(opened, &received, received.count) == 2)
        #expect(Array(received.prefix(2)) == Array("he".utf8))
        #expect(Sys.truncate(folder.appendingPathComponent("none").path, 0) == -1)
    }

    @Test func aSignalOfNoneAsksWhetherAProcessIsThere() {
        #expect(Sys.kill(getpid(), 0) == 0)
        // No process has the highest number there is: each system's own limit is far below it.
        let absent = Sys.kill(pid_t.max, 0)
        let code = errno
        #expect(absent == -1)
        #expect(code == ESRCH)
    }

    @Test func aSocketListensIsConnectedToAndAccepts() throws {
        let folder = try TestScriptLinuxTests.scratch("sys-socket")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("s").path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try #require(path.utf8.count < MemoryLayout.size(ofValue: address.sun_path), "\(path) is too long for a socket")
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)

        let listener = socket(AF_UNIX, streamSocket, 0)
        try #require(listener >= 0)
        defer { Sys.close(listener) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        try #require(bound == 0)
        #expect(Sys.listen(listener, 1) == 0)

        let client = socket(AF_UNIX, streamSocket, 0)
        try #require(client >= 0)
        defer { Sys.close(client) }
        // The connection waits in the listener's queue: the accept below finds it there and doesn't block.
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Sys.connect(client, $0, length) }
        }
        try #require(connected == 0)
        let served = Sys.accept(listener, nil, nil)
        try #require(served >= 0)
        defer { Sys.close(served) }

        #expect(Sys.write(client, [UInt8(7)], 1) == 1)
        var received: [UInt8] = [0]
        #expect(Sys.read(served, &received, 1) == 1)
        #expect(received == [7])

        // Nothing listens at a path with no socket.
        let other = socket(AF_UNIX, streamSocket, 0)
        try #require(other >= 0)
        defer { Sys.close(other) }
        var nowhere = sockaddr_un()
        nowhere.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &nowhere.sun_path) { $0.copyBytes(from: (path + "x").utf8) }
        let refused = withUnsafePointer(to: &nowhere) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Sys.connect(other, $0, length) }
        }
        #expect(refused == -1)
    }
}
