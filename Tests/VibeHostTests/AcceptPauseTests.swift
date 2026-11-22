import Foundation
import Testing
import VibeCore
@testable import VibeHost

/// The host's accept paused per source (the review of the runtime hardening): a listener replaced while its source is
/// paused has a source of its own, and an accept that fails on it pauses that one too, not the one before's flag. A
/// paused source is resumed once, by the pause's end or by `stop` first, never cancelled suspended with its descriptor
/// closed under it.
struct AcceptPauseTests {
    @Test func aPausedAcceptStartsAgainOnItsListener() async throws {
        let host = try TestHost()
        let server = host.server
        let listener = server.queue.sync { server.listenFD }
        server.queue.sync { server.acceptFailed(EMFILE) }
        #expect(server.queue.sync { server.acceptsPaused.count } == 1)
        #expect(await eventually(timeout: 30) { server.queue.sync { server.acceptsPaused.isEmpty } })
        #expect(server.queue.sync { server.listenFD } == listener)
        // Accepting again: a client gets in.
        _ = try TestClient(host)
    }

    @Test func aReplacedListenersSourceIsPausedInItsOwnTurn() throws {
        let host = try TestHost()
        let server = host.server
        let paused = { server.queue.sync { server.acceptsPaused.count } }
        server.queue.sync { server.acceptFailed(EMFILE) }
        #expect(paused() == 1)
        server.queue.sync { server.acceptFailed(EMFILE) }
        #expect(paused() == 1, "one pause a source at a time")
        // A fresh listener at the same path, as the path watch binds one: its own source.
        let fresh = try UnixSocket.listen(path: host.socket)
        server.queue.sync { server.replaceListener(fresh) }
        server.queue.sync { server.acceptFailed(EMFILE) }
        #expect(paused() == 2, "the new source paused too")
        server.queue.sync { server.acceptFailed(EINTR) }
        #expect(paused() == 2, "a failure that doesn't last pauses nothing")
        // Stopped while both are paused: each resumed once, now, and again by nothing when the pauses end.
        server.stop(terminateSessions: true)
        #expect(paused() == 2)
    }

    /// A host stopped while its accept is paused: the source resumed before its cancel, and the pause's own end, a
    /// second later, resumes nothing more (a second resume would trap).
    @Test func aHostStoppedWhilePausedResumesItsSourceOnce() async throws {
        let host = try TestHost()
        let server = host.server
        server.queue.sync { server.acceptFailed(EMFILE) }
        server.stop(terminateSessions: true)
        #expect(await eventually(timeout: 30) { server.queue.sync { server.acceptsPaused.isEmpty } }, "the pause ended without a trap")
    }

    /// `stop` closes the listener from its accept source's cancel handler, not right after the cancel: in the turn of
    /// the queue that stops the host the descriptor is still the listener's, and it is closed once the source has gone.
    @Test func stopClosesTheListenerOnlyOnceItsSourceHasGone() async throws {
        let host = try TestHost()
        let server = host.server
        let listener = server.queue.sync { server.listenFD }
        var info = stat()
        try #require(fstat(listener, &info) == 0)
        let inode = info.st_ino
        let sameFile = { () -> Bool in
            var now = stat()
            return fstat(listener, &now) == 0 && now.st_ino == inode
        }
        let openThen = server.queue.sync { () -> Bool in
            server.stop(terminateSessions: true)
            return sameFile()
        }
        #expect(openThen, "still the listener in the turn that cancelled its source")
        #expect(await eventually(timeout: 30) { !sameFile() }, "closed once the source has gone")
    }
}

