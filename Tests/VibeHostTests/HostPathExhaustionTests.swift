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

    /// A host whose checks can't be made (the kernel's answer and a connection through the path both failing, as under
    /// ENFILE): its own recorded socket stays at the path through a housekeeping's check; a socket another process puts
    /// at the path is replaced at the next change, with a listener of the host's own, and never recorded; the spare
    /// descriptor is back after each check.
    @Test func aHostThatCantCheckKeepsItsSocketAndReplacesAForeignOne() throws {
        let host = try TestHost(watchesItsPath: true)
        let server = host.server
        let watch = try #require(server.queue.sync { server.pathWatch })
        let own = try #require(server.queue.sync { watch.socketFile }, "verified at the start")
        #expect(server.queue.sync { watch.holdsSpare })
        server.queue.sync {
            watch.leads = { _ in nil }
            watch.kernel = { _, _ in .cantSay }
            watch.check(atHousekeeping: true)
        }
        #expect(HostPathWatch.identity(atPath: host.socket) == own, "the host's own socket not unlinked")
        #expect(server.queue.sync { watch.socketFile } == own)
        #expect(server.queue.sync { watch.holdsSpare }, "the spare back after the check")

        // Another socket put at the path (bound beside it, renamed over it in one step) while the checks can't be made:
        // the change is checked at once, and the path given back to a listener of the host's own.
        let beside = host.socket + "-f"
        let foreign = try UnixSocket.listen(path: beside)
        defer { Sys.close(foreign); unlink(beside) }
        let foreignFile = try #require(HostPathWatch.identity(atPath: beside))
        try #require(rename(beside, host.socket) == 0, "errno \(errno)")
        server.queue.sync { watch.check() }
        let recorded = server.queue.sync { watch.socketFile }
        let named = HostPathWatch.identity(atPath: host.socket)
        #expect(recorded != foreignFile && named != foreignFile, "the foreign socket replaced, never recorded")
        #expect(recorded != nil && recorded == named, "the host's fresh listener recorded")
        #expect(server.queue.sync { watch.holdsSpare })
        // The checks able again: the path leads to this process, the host.
        server.queue.sync {
            watch.leads = HostPathWatch.leadsHere
            watch.kernel = { Platform.Sockets.boundFile(of: $0, at: $1) }
        }
        #expect(HostPathWatch.leadsHere(host.socket) == true)
        _ = try TestClient(host)
    }

    /// A foreign socket recorded as the host's while the checks couldn't run (the bind-then-lstat race, S11 item 5)
    /// stays only until the checks work again: the first housekeeping then asks the kernel, finds the path isn't the
    /// listener's, and binds the host's own over it.
    @Test func aForeignFileRecordedWhileChecksFailIsReplacedOnceTheyWork() throws {
        let host = try TestHost(watchesItsPath: true)
        let server = host.server
        let watch = try #require(server.queue.sync { server.pathWatch })
        let beside = host.socket + "-f"
        let foreign = try UnixSocket.listen(path: beside)
        defer { Sys.close(foreign); unlink(beside) }
        let foreignFile = try #require(HostPathWatch.identity(atPath: beside))
        server.queue.sync {
            watch.leads = { _ in nil }
            watch.kernel = { _, _ in .cantSay }
        }
        // The rename and the record in one turn of the host's queue: its folder watch's check of the rename comes after.
        let renamed = server.queue.sync { () -> Bool in
            guard rename(beside, host.socket) == 0 else { return false }
            watch.socketFile = foreignFile
            return true
        }
        try #require(renamed, "errno \(errno)")
        server.queue.sync { watch.check(atHousekeeping: true) }
        #expect(server.queue.sync { watch.socketFile } == foreignFile, "the residual: kept while nothing can be checked")
        server.queue.sync {
            watch.leads = HostPathWatch.leadsHere
            watch.kernel = { Platform.Sockets.boundFile(of: $0, at: $1) }
            watch.check(atHousekeeping: true)
        }
        let recorded = server.queue.sync { watch.socketFile }
        #expect(recorded != foreignFile && HostPathWatch.identity(atPath: host.socket) != foreignFile, "replaced at the first housekeeping that could check")
        #expect(recorded != nil && recorded == HostPathWatch.identity(atPath: host.socket))
        #expect(HostPathWatch.leadsHere(host.socket) == true)
    }
}

