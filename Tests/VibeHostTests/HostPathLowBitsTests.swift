import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

@Suite struct HostPathLowBitsTests {
    /// The kernel matching the socket path's file with the host's listener on the low 32 bits of an inode number past
    /// them (`.sharesLowBits`: btrfs, XFS's `inode64`, tmpfs's `inode64`) is not taken on its word: the watch's check
    /// also connects through the path, as where the kernel can't say, and keeps the file only when that connection
    /// reaches this process and the path named the kernel's file before and after it. A socket file nobody listens on
    /// is the host's on a conclusive match (`.bound`), and not on a low-bits one; nor is a file that isn't the one the
    /// kernel matched. The file nobody listens on is one bound and never listening, not a closed listener's: a
    /// listener lives on while any descriptor table holds it (another test's spawn in flight copies this process's),
    /// and a connection to it still names this process.
    @Test func aMatchOnTheLowBitsOfAnInodeIsCheckedByAConnection() throws {
        let path = scratchSocketPath()
        defer { unlink(path) }
        let listener = try UnixSocket.listen(path: path)
        var closed = false
        defer { if !closed { Sys.close(listener) } }
        let named = try #require(HostPathWatch.identity(atPath: path))

        #expect(HostPathWatch.verifiedIdentity(of: path, kernel: .sharesLowBits(device: named.device, inode: named.inode)) == named)
        #expect(HostPathWatch.verifiedIdentity(of: path, kernel: .sharesLowBits(device: named.device, inode: named.inode ^ 1)) == nil)
        #expect(HostPathWatch.verifiedIdentity(of: path, kernel: .sharesLowBits(device: named.device ^ 1, inode: named.inode)) == nil)

        Sys.close(listener)
        closed = true
        #expect(HostPathWatch.identity(atPath: path) == named, "the socket's file stays after its listener closes")
        #expect(HostPathWatch.verifiedIdentity(of: path, kernel: .bound(device: named.device, inode: named.inode)) == named)
        #expect(HostPathWatch.verifiedIdentity(of: path, kernel: .another) == nil)

        // A socket file nobody listens on: bound, never listening, so every connect is refused, whoever holds a copy
        // (`held`, as a spawn in flight would).
        let quiet = scratchSocketPath()
        defer { unlink(quiet) }
        let bound = Platform.Sockets.makeSocket(type: Platform.Sockets.stream)
        try #require(bound >= 0)
        defer { Sys.close(bound) }
        try #require(Platform.Sockets.bindOwnerOnly(bound, to: try UnixSocket.address(quiet), path: quiet, mode: 0o600) == nil)
        let held = dup(bound)
        try #require(held >= 0)
        defer { Sys.close(held) }
        let file = try #require(HostPathWatch.identity(atPath: quiet))
        #expect(HostPathWatch.verifiedIdentity(of: quiet, kernel: .bound(device: file.device, inode: file.inode)) == file)
        #expect(HostPathWatch.verifiedIdentity(of: quiet, kernel: .sharesLowBits(device: file.device, inode: file.inode)) == nil)
    }
}
