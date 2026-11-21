import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The node's health digest (`NodeHealth`): the watchdog sees the engine's queue stall and keeps the freeze with how long
/// once it answers; slow refreshes and failing log lines are kept; freezes survive a restart; the digest reads as the
/// wire's `node.health` and prints inert. The clock is a test's: no test waits ten seconds.
struct NodeHealthTests {
    private let scratch = Scratch()

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 1_000
        var now: TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    private func value(_ health: NodeHealth) -> NodeWire.Value {
        health.value(serverRestarts: 1, refusedConnections: 0, hostRestartAt: nil, waiting: ["reminder: waiting on you, on ttypts4"])
    }

    @Test func aStalledQueueIsSeenAndKeptAsAFreezeOnceItAnswers() async throws {
        let clock = Clock()
        let file = scratch.url("health.json")
        let health = NodeHealth(file: file, clock: { clock.now })
        let queue = DispatchQueue(label: "health-test-queue")
        // A queue that answers at once: no stall, no freeze.
        health.tick(queue)
        queue.sync {}
        #expect(health.stalled == nil)
        // Held: the ping waits; past `stallAfter` it is a stall under way.
        let release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }
        health.tick(queue)
        clock.advance(NodeHealth.stallAfter + 2)
        #expect(health.stalled.map { $0 >= NodeHealth.stallAfter } == true)
        #expect(value(health)["stalled"]?.int == Int(NodeHealth.stallAfter + 2))
        release.signal()
        queue.sync {}
        #expect(health.stalled == nil)
        let freezes = value(health)["freezes"]?.array ?? []
        #expect(freezes.count == 1 && freezes.first?["seconds"]?.int == Int(NodeHealth.stallAfter + 2), "\(freezes)")
        // Kept across a restart.
        #expect(await eventually(timeout: 30) { FileManager.default.fileExists(atPath: file.path) })
        let again = NodeHealth(file: file, clock: { clock.now })
        #expect(value(again)["freezes"]?.array?.count == 1)
    }

    @Test func slowRefreshesAndFailingLinesAreKept() throws {
        let health = NodeHealth(file: nil)
        health.refreshed(in: 1)
        health.refreshed(in: NodeHealth.slowRefresh + 3)
        health.refreshed(in: NodeHealth.slowRefresh + 1)
        health.heard("started, pid 4, root /r")
        health.heard("set boost: not changed: disk full")
        health.heard("update check: couldn't look (offline)\u{1B}[2J")
        for index in 0..<(NodeHealth.kept + 3) { health.heard("prompt audit: not written \(index)") }
        let digest = value(health)
        #expect(digest["slowRefreshes"]?.int == 2 && digest["slowestRefresh"]?.int == Int(NodeHealth.slowRefresh + 3))
        let errors = digest["errors"]?.array?.compactMap { $0["line"]?.string } ?? []
        #expect(errors.count == NodeHealth.kept && errors.first == "prompt audit: not written \(NodeHealth.kept + 2)")
        #expect(!errors.contains { $0.contains("started, pid") })
        #expect(WireSchema.check(digest, as: "node.health", strict: true) == nil, "\(digest)")

        // The causes: by kind (the part that wrote it and the failure word), the most frequent first.
        let causes = digest["causes"]?.array ?? []
        #expect(causes.first?["kind"]?.string == "prompt audit: not written" && causes.first?["count"]?.int == NodeHealth.kept + 3, "\(causes)")
        #expect(causes.contains { $0["kind"]?.string == "update check: couldn't" && $0["count"]?.int == 1 })
        #expect(NodeHealth.kind("set boost: not changed: disk full") == nil)
        #expect(NodeHealth.kind("lead: couldn't post to /a/b: x") == "lead: couldn't")
        #expect(NodeHealth.kind("shell request 1234-abcd: not recorded") == "server: not recorded")
        let lines = NodeHealth.lines(digest)
        #expect(lines.contains { $0.contains("slow refreshes (over 5 s): 2") })
        #expect(lines.contains("    reminder: waiting on you, on ttypts4"))
        #expect(lines.contains("  server restarts by the host: 1"))
        #expect(!lines.joined().contains("\u{1B}"))
        #expect(lines.contains { $0.hasPrefix("    prompt audit: not written ×\(NodeHealth.kept + 3)") })
    }
}
