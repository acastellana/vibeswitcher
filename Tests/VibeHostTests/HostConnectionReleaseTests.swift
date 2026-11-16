import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A connection to the host is freed once it's closed, even when its handlers hold it (10-26): `HostCall`'s one-shot
/// calls (the app's vault calls, screen reads and typed input, several a second with a few leads) send from their
/// `onEvent`, which held each connection for good, with the host's whole session list and the reply it captured.
@Suite struct HostConnectionReleaseTests {
    @Test func aClosedConnectionLetsGoOfHandlersThatHoldIt() async throws {
        let host = try TestHost()
        let queue = DispatchQueue(label: "connection-release")
        let answered = DispatchSemaphore(value: 0)
        weak var released: HostConnection?
        try queue.sync {
            let connection = try HostConnection(path: host.socket, queue: queue, appKey: host.appKey)
            var asked: Int?
            // As `HostCall.exchange` does: the request goes out from the handler, on the connection itself.
            connection.onEvent = { envelope in
                if case .welcome = envelope.event {
                    asked = try? connection.send(.screen(id: UUID()))
                } else if let asked, envelope.replyTo == asked {
                    answered.signal()
                }
            }
            connection.onClose = { _ = connection }
            _ = try connection.send(.hello(protocolVersion: HostProtocol.version, app: "vibeswitcher-mcp"))
            released = connection
        }
        #expect(await offPool { answered.wait(timeout: .now() + hangGuard) } == .success)
        queue.sync { released?.close() }
        // The reader holds the connection for the rest of its turn (`self?.readAvailable()`), which goes on past handing
        // over the answer: a reader thread put off just then (linux CI 43840361847, 4 cores) still held it after the
        // close. Its turn ends on its own; only handlers that hold it hold it for good.
        #expect(await eventually { queue.sync { released } == nil }, "the closed connection is still held by its handlers")
    }
}
