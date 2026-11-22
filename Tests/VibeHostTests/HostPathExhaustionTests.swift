import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Out of descriptors, the host's path watch can't check its socket (no netlink socket for the kernel's answer, no
/// socket to connect through): that is "can't say now", never "not the host's", so it keeps the file it recorded and
/// never unlinks and binds again over its own socket (the review of the runtime hardening).
@Suite struct HostPathExhaustionTests {
    @Test func aCheckThatCantBeMadeKeepsTheRecordedSocket() throws {
        let path = scratchSocketPath()
        defer { unlink(path) }
        let listener = try UnixSocket.listen(path: path)
        defer { Sys.close(listener) }
        let named = try #require(HostPathWatch.identity(atPath: path))
        #expect(HostPathWatch.verifiedIdentity(of: path, kernel: .cantSay, leads: { _ in nil }) == named, "no descriptor to ask with")
        #expect(HostPathWatch.verifiedIdentity(of: path, kernel: .cantSay, leads: { _ in false }) == nil, "asked, and it isn't the host's")
        #expect(HostPathWatch.verifiedIdentity(of: path, kernel: .cantSay, leads: { _ in true }) == named)
        #expect(HostPathWatch.leadsHere(path) == true, "this process listens there")
    }
}
