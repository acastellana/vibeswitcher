import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The watchdog acts (the architecture review's row 3): a scratch node's server whose engine queue is blocked for good
/// exits once its watchdog has waited `--test-stall=` seconds (120 on the user's node), the host starts it again, the
/// sessions run on in the host, and the freeze is in `health.json`, saved by the watchdog before the exit.
struct WatchdogRestartTests {
    private let scratch = Scratch()

    @Test func aServerWhoseQueueIsStuckExitsAndTheHostStartsItAgainWithTheSessionsKept() async throws {
        let node = try await ScratchNode(scratch, hostArguments: ["--server-arg", ServerArguments.testStallFlag + "3"])
        defer { node.stop() }
        let session = try await node.spawn("sleep 600")
        let old = try WireClient(node).hello.server.pid
        FileManager.default.createFile(atPath: node.root.appendingPathComponent("test-block-engine").path, contents: nil)
        var again: NodeWire.Hello?
        let back = await eventually(timeout: 120) {
            again = try? WireClient(node).hello
            return again.map { $0.server.pid != old } == true
        }
        try #require(back, "\(node.said)")
        #expect(node.said.contains("the engine's queue hasn't answered for"), "\(node.said)")
        #expect(node.said.contains("server child pid \(old) ended"), "\(node.said)")
        let kept = try node.sessions().first { $0.id == session.id }
        #expect(kept?.isLive == true && kept?.childPID == session.childPID, "\(String(describing: kept))")
        let freezes = NodeHealth(file: node.root.appendingPathComponent("health.json")).value(serverRestarts: nil, refusedConnections: nil,
                                                                                               hostRestartAt: nil, waiting: [])["freezes"]?.array ?? []
        #expect(freezes.contains { ($0["seconds"]?.int ?? 0) >= 3 }, "\(freezes)")
    }

    /// The refresh's lane blocked: said as a refresh under way in `status --health`; the server runs on.
    @Test func aBlockedRefreshIsSaidUnderWayAndTheServerRunsOn() async throws {
        let node = try await ScratchNode(scratch, hostArguments: ["--server-arg", ServerArguments.testStallFlag + "3"])
        defer { node.stop() }
        let old = try WireClient(node).hello.server.pid
        FileManager.default.createFile(atPath: node.root.appendingPathComponent("test-block-reads").path, contents: nil)
        var health = ""
        let deadline = MacTime.real.awake() + 60
        while !health.contains("refresh under way"), MacTime.real.awake() < deadline, !Task.isCancelled {
            health = try await node.run(["status", "--health"]).output
        }
        #expect(health.contains("refresh under way"), "\(health)\n\(node.said)")
        #expect(try WireClient(node).hello.server.pid == old, "\(node.said)")
    }
}
