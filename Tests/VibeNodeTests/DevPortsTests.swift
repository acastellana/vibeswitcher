import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// A session's dev servers (`DevPorts`, `session.ports`): the listening sockets of the kernel's tables (a scratch proc
/// folder here) matched to a session's processes' descriptors; loopback or every address only, 1024 and up, never the
/// node's own port.
struct DevPortsTests {
    private let scratch = Scratch()

    /// A proc folder with `tcp` and `tcp6` tables and, for each pid, its socket descriptors.
    private func proc(tcp: [String], tcp6: [String], sockets: [Int32: [UInt64]]) throws -> String {
        let root = scratch.url("proc")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("net"), withIntermediateDirectories: true)
        let head = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
        try (head + tcp.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("net/tcp"), atomically: true, encoding: .utf8)
        try (head + tcp6.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("net/tcp6"), atomically: true, encoding: .utf8)
        for (pid, inodes) in sockets {
            let fd = root.appendingPathComponent("\(pid)/fd")
            try FileManager.default.createDirectory(at: fd, withIntermediateDirectories: true)
            for (index, inode) in inodes.enumerated() {
                try FileManager.default.createSymbolicLink(atPath: fd.appendingPathComponent("\(index + 3)").path, withDestinationPath: "socket:[\(inode)]")
            }
            try FileManager.default.createSymbolicLink(atPath: fd.appendingPathComponent("0").path, withDestinationPath: "/dev/pts/4")
        }
        return root.path
    }

    private func row(_ local: String, state: String = "0A", inode: UInt64) -> String {
        "   0: \(local) 00000000:0000 \(state) 00000000:00000000 00:00000000 00000000  1000        0 \(inode) 1 0000000000000000 100 0 0 10 0"
    }

    @Test func aSessionsListeningPortsAreFound() throws {
        let root = try proc(tcp: [
            row("0100007F:1435", inode: 101),            // 127.0.0.1:5173, the session's
            row("00000000:1F90", inode: 102),            // 0.0.0.0:8080, its child's
            row("0100A8C0:2328", inode: 103),            // 192.168.0.1:9000: not loopback
            row("0100007F:0050", inode: 104),            // 127.0.0.1:80: privileged
            row("0100007F:BAD6", inode: 105),            // 127.0.0.1:47830: the node's own page
            row("0100007F:1F41", state: "01", inode: 106), // an established connection, not a listener
            row("0100007F:1389", inode: 107),            // 127.0.0.1:5001, another session's
        ], tcp6: [
            row("00000000000000000000000001000000:0BB8", inode: 201), // [::1]:3000
            row("0000000000000000FFFF00000100007F:0BB9", inode: 202), // [::ffff:127.0.0.1]:3001
        ], sockets: [10: [101, 103, 104, 105, 106, 201], 11: [102, 202], 99: [107]])
        let found = DevPorts.listening(pids: [10, 11], proc: root, program: { $0 == 10 ? "node" : nil })
        #expect(found.map(\.port) == [3000, 3001, 5173, 8080], "\(found)")
        #expect(found.first { $0.port == 5173 } == .init(port: 5173, address: "127.0.0.1", pid: 10, program: "node"))
        #expect(found.first { $0.port == 8080 }?.address == "0.0.0.0" && found.first { $0.port == 3000 }?.address == "::1")
        #expect(found.first { $0.port == 3001 }?.address == "127.0.0.1")
        #expect(found.first { $0.port == 5173 }?.url == "http://localhost:5173/")
        let value = DevPorts.value(found)
        #expect(WireSchema.check(value, as: "session.ports.result", strict: true) == nil, "\(value)")
        // Nothing listening: nothing; no proc folder: nothing.
        #expect(DevPorts.listening(pids: [99], proc: root).map(\.port) == [5001])
        #expect(DevPorts.listening(pids: [10], proc: scratch.url("none").path).isEmpty)
    }

    /// The live read on this machine: a listener this test opens on loopback is this process's, found by its pid.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/proc/net/tcp")))
    func thisProcesssOwnListenerIsFound() throws {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(bound == 0 && listen(fd, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = Int(UInt16(bigEndian: address.sin_port))
        let found = DevPorts.listening(pids: [getpid()])
        #expect(found.contains { $0.port == port && $0.address == "127.0.0.1" }, "\(port): \(found)")
    }
}
