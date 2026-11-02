import Foundation
import Testing
@testable import VibeSwitcher

/// The soak's census counts while the process's other threads keep allocating, as the app's do: it suspended them
/// with every zone force-locked, and this thread allocating under the zones' fork lock aborted the sandbox
/// (_os_unfair_lock_recursive_abort under _xzm_fork_lock_wait, 11-01).
struct HeapCensusTests {
    /// Objects of a class of its own, kept alive while the census counts: it finds them by class.
    final class Marker { var payload = [UInt8](repeating: 1, count: 48) }

    @Test func itCountsWhileOtherThreadsAllocate() throws {
        let kept = (0..<500).map { _ in Marker() }
        let stop = Stop()
        let threads = 4
        let started = DispatchSemaphore(value: 0)
        let ended = DispatchGroup()
        for _ in 0..<threads {
            ended.enter()
            Thread.detachNewThread {
                started.signal()
                var churn: [[Int]] = []
                while !stop.value {
                    churn.append(Array(repeating: churn.count, count: 1 + churn.count % 64))
                    if churn.count > 2_000 { churn.removeAll(keepingCapacity: false) }
                }
                ended.leave()
            }
        }
        for _ in 0..<threads { #expect(started.wait(timeout: .now() + hangGuard) == .success) }
        var results: [HeapCensus.Result] = []
        for _ in 0..<5 { results.append(HeapCensus.take()) }
        stop.set()
        #expect(ended.wait(timeout: .now() + hangGuard) == .success)
        // Every census came back (none aborted the process) with the heap's blocks; a zone being changed under one is
        // counted again, but it's still a close count: the markers are all found in most.
        for result in results { #expect(result.total.blocks > 1_000) }
        // By its exact name: other live classes have "Marker" in theirs (AppKit's _NSStateMarker, 3 or 4 blocks, and
        // more in a full run), and the first of a dictionary's that matches is any of them.
        let name = String(cString: class_getName(Marker.self))
        let found = results.map { $0.classes[name]?.blocks ?? 0 }
        #expect(found.filter { $0 >= kept.count }.count >= 1, "markers found by each census: \(found), of \(kept.count)")
        withExtendedLifetime(kept) {}
    }

    final class Stop: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var value: Bool { lock.withLock { stopped } }
        func set() { lock.withLock { stopped = true } }
    }
}
