import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Out of descriptors, the host's path watch can't check its socket (no netlink socket for the kernel's answer, no
/// socket to connect through): that is "can't say now". The file counts as the host's only when it is the one an
/// earlier verified check recorded; anything else, a worker's socket bound at the path meanwhile, is never recorded as
/// the host's; and the host's own recorded socket is never unlinked (the review of the runtime hardening).
@Suite struct HostPathExhaustionTests {
    /// The verdict alone: a socket at the path the check can't be made on is the host's only as the file recorded.
    @Test func cantSayIsTheHostsOnlyAsTheFileRecorded() throws {
        let path = scratchSocketPath()
        defer { unlink(path) }
        let listener = try UnixSocket.listen(path: path)
        defer { Sys.close(listener) }
        let named = try #require(HostPathWatch.identity(atPath: path))
        let other = HostPathWatch.FileIdentity(device: named.device, inode: named.inode ^ 1)
        let cantAsk: (String) -> Bool? = { _ in nil }
        #expect(HostPathWatch.verdict(of: path, kernel: .cantSay, leads: cantAsk, recorded: nil) == .cantSay, "nothing verified yet")
        #expect(HostPathWatch.verdict(of: path, kernel: .cantSay, leads: cantAsk, recorded: other) == .cantSay, "another file than the one recorded")
        #expect(HostPathWatch.verdict(of: path, kernel: .cantSay, leads: cantAsk, recorded: named) == .ours(named))
        #expect(HostPathWatch.verdict(of: path, kernel: .cantSay, leads: { _ in false }, recorded: named) == .notOurs, "asked, and it isn't")
        #expect(HostPathWatch.leadsHere(path) == true, "this process listens there")
    }

    /// A host whose checks can't be made: its own recorded socket stays at the path through a housekeeping's check; a
    /// socket another process bound at the path is never recorded as the host's.
    @Test func aHostOutOfDescriptorsKeepsItsSocketAndRecordsNoForeignOne() throws {
        let host = try TestHost(watchesItsPath: true)
        let server = host.server
        let watch = try #require(server.queue.sync { server.pathWatch })
        let own = try #require(server.queue.sync { watch.socketFile }, "verified at the start, descriptors to spare")
        // Out of descriptors: neither the kernel's answer (its netlink socket) nor a connection through the path can be had.
        server.queue.sync {
            watch.leads = { _ in nil }
            watch.kernel = { _, _ in .cantSay }
            watch.check(atHousekeeping: true)
        }
        #expect(HostPathWatch.identity(atPath: host.socket) == own, "the host's own socket not unlinked")
        #expect(server.queue.sync { watch.socketFile } == own)

        // Another socket put at the path while the checks still can't be made: bound beside it, then renamed over it
        // in one step (a bind at the path itself would unlink it first, and the host's folder watch races to bind there).
        let beside = host.socket + "-f"
        let foreign = try UnixSocket.listen(path: beside)
        defer { Sys.close(foreign); unlink(beside) }
        let foreignFile = try #require(HostPathWatch.identity(atPath: beside))
        try #require(rename(beside, host.socket) == 0, "errno \(errno)")
        server.queue.sync { watch.check(atHousekeeping: true) }
        let recorded = server.queue.sync { watch.socketFile }
        #expect(recorded != foreignFile, "a socket that couldn't be checked is never recorded as the host's")
        #expect(recorded == nil && server.queue.sync { watch.socketUnchecked }, "checked again at the next housekeeping")
    }
}
