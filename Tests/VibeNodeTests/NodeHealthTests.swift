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

    /// Beats long enough that a case's single step of the clock is all counted (each tick counts two beats at most).
    static let wide = NodeHealth.Timing(beat: 1_000)

    /// A process stopped (SIGSTOP, a freezer) and continued: the monotonic clock ran on meanwhile, but a tick counts two
    /// beats at most, so the first tick after the continue doesn't end a healthy server; a queue that stays stuck
    /// still does, once the ticks have counted `exitAfter`.
    @Test func aStoppedProcessIsntTakenForAStuckQueue() {
        let clock = Clock()
        let ended = Lines()
        let health = NodeHealth(file: nil, clock: { clock.now }, stuck: { ended.add($0) })
        let queue = DispatchQueue(label: "health-test-queue")
        let release = DispatchSemaphore(value: 0)
        defer {
            release.signal()
            queue.sync {}
        }
        queue.async { release.wait() }
        health.tick(queue)
        clock.advance(3_600)
        health.tick(queue)
        #expect(ended.all.isEmpty, "an hour stopped is two beats counted")
        #expect(health.stalled.map { $0 <= 2 * NodeHealth.beat + 0.001 } == true || health.stalled == nil)
        for _ in 0..<Int(NodeHealth.exitAfter / NodeHealth.beat) + 2 {
            clock.advance(NodeHealth.beat)
            health.tick(queue)
        }
        #expect(ended.all.count == 1, "a queue that stays stuck still ends it")
    }

    /// What `stuck` was called with.
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        var all: [String] { lock.withLock { lines } }
        func add(_ line: String) { lock.withLock { lines.append(line) } }
    }

    private func value(_ health: NodeHealth) -> NodeWire.Value {
        health.value(serverRestarts: 1, refusedConnections: 0, hostRestartAt: nil, waiting: ["reminder: waiting on you, on ttypts4"])
    }

    @Test func aStalledQueueIsSeenAndKeptAsAFreezeOnceItAnswers() async throws {
        let clock = Clock()
        let file = scratch.url("health.json")
        let health = NodeHealth(file: file, clock: { clock.now }, timing: Self.wide)
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
        let again = NodeHealth(file: file, clock: { clock.now }, timing: Self.wide)
        #expect(value(again)["freezes"]?.array?.count == 1)
    }

    /// A stall is kept, and saved, once it passes `stallAfter`, while it still lasts (a stall that ends in an exit still
    /// shows after the restart); the queue's answer brings its length up to date, one freeze, not two.
    @Test func aStallIsSavedWhileItLastsAndUpdatedOnceItAnswers() async throws {
        let clock = Clock()
        let file = scratch.url("health.json")
        let health = NodeHealth(file: file, clock: { clock.now }, timing: Self.wide)
        let queue = DispatchQueue(label: "health-test-queue")
        let release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }
        health.tick(queue)
        clock.advance(NodeHealth.stallAfter + 1)
        health.tick(queue)
        let saved = NodeHealth(file: file, clock: { clock.now }, timing: Self.wide)
        #expect(value(saved)["freezes"]?.array?.first?["seconds"]?.int == Int(NodeHealth.stallAfter + 1), "saved while the stall lasts")
        clock.advance(4)
        health.tick(queue)
        release.signal()
        queue.sync {}
        let freezes = value(health)["freezes"]?.array ?? []
        #expect(freezes.count == 1 && freezes.first?["seconds"]?.int == Int(NodeHealth.stallAfter + 5), "\(freezes)")
        #expect(value(NodeHealth(file: file, clock: { clock.now }, timing: Self.wide))["freezes"]?.array?.first?["seconds"]?.int == Int(NodeHealth.stallAfter + 5))
    }

    /// A ping unanswered for `exitAfter` calls `stuck`, once, with the freeze saved first with its length.
    @Test func aQueueStuckForExitAfterEndsTheServerOnce() throws {
        let clock = Clock()
        let file = scratch.url("health.json")
        let ended = Lines()
        let health = NodeHealth(file: file, clock: { clock.now }, timing: Self.wide, stuck: { ended.add($0) })
        let queue = DispatchQueue(label: "health-test-queue")
        let release = DispatchSemaphore(value: 0)
        // Its answer saves the freeze again: waited for, so nothing is written after the scratch goes.
        defer {
            release.signal()
            queue.sync {}
        }
        queue.async { release.wait() }
        health.tick(queue)
        clock.advance(NodeHealth.exitAfter - 1)
        health.tick(queue)
        #expect(ended.all.isEmpty, "a long stall, not yet stuck")
        clock.advance(1)
        health.tick(queue)
        clock.advance(5)
        health.tick(queue)
        let lines = ended.all
        #expect(lines == ["the engine's queue hasn't answered for \(Int(NodeHealth.exitAfter)) s: exiting, for the host to start the server again (the sessions run on)"], "\(lines)")
        let saved = NodeHealth(file: file, clock: { clock.now }, timing: Self.wide)
        #expect(value(saved)["freezes"]?.array?.first?["seconds"]?.int == Int(NodeHealth.exitAfter))
    }

    /// The refresh's reads lane, pinged beside the engine's queue: left waiting `stallAfter`, said as a refresh under way,
    /// never acted on.
    @Test func aLongRefreshIsSaidUnderWay() throws {
        let clock = Clock()
        let stuck = Lines()
        let health = NodeHealth(file: nil, clock: { clock.now }, timing: Self.wide, stuck: { stuck.add($0) })
        let queue = DispatchQueue(label: "health-test-queue"), reads = DispatchQueue(label: "health-test-reads")
        let release = DispatchSemaphore(value: 0)
        reads.async { release.wait() }
        health.tick(queue, reads: reads)
        queue.sync {}
        clock.advance(NodeHealth.exitAfter + 3)
        health.tick(queue, reads: reads)
        queue.sync {}
        #expect(health.stalled == nil)
        #expect(health.refreshing == NodeHealth.exitAfter + 3)
        let digest = value(health)
        #expect(digest["refreshing"]?.int == Int(NodeHealth.exitAfter + 3))
        #expect(WireSchema.check(digest, as: "node.health", strict: true) == nil, "\(digest)")
        #expect(NodeHealth.lines(digest).contains("  refresh under way \(Int(NodeHealth.exitAfter + 3)) s (the boards' and transcripts' reads)"))
        #expect(stuck.all.isEmpty)
        release.signal()
        reads.sync {}
        #expect(health.refreshing == nil)
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
