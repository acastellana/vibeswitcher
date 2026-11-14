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
    /// kernel matched.
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
        #expect(HostPathWatch.verifiedIdentity(of: path, kernel: .sharesLowBits(device: named.device, inode: named.inode)) == nil)
        #expect(HostPathWatch.verifiedIdentity(of: path, kernel: .another) == nil)
    }
}
