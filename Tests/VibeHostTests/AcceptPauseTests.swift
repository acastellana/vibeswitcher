import Foundation
import Testing
import VibeCore
@testable import VibeHost

/// The host's accept paused per source (the review of the runtime hardening): a listener replaced while its source is
/// paused has a source of its own, and an accept that fails on it pauses that one too, not the one before's flag. A
/// pause cancels its source (never leaves one suspended, whose cancel would wait for its resume while `stop` closes and
/// another file reuses the descriptor) and makes a new one a second later.
struct AcceptPauseTests {
    @Test func aPausedAcceptStartsAgainOnItsListener() async throws {
        let host = try TestHost()
        let server = host.server
        let listener = server.queue.sync { server.listenFD }
        server.queue.sync { server.acceptFailed(EMFILE) }
        #expect(server.queue.sync { server.acceptSource == nil }, "the source cancelled, not suspended")
        #expect(await eventually(timeout: 30) { server.queue.sync { server.acceptSource != nil && server.acceptsPaused.isEmpty } })
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
    }
}
