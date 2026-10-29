import Foundation
import Testing
import VibeCore

/// What the scan does at each landing on the main thread, done elsewhere (hang-20261028-171900): the ledger's writes
/// on the writer's queue, and the frontmost app's bundle id asked once a pid.
struct LedgerWriterTests {
    /// Holds whoever waits on it until opened, 5 s at most (a slow write or lookup); open, it holds no one.
    final class Gate: @unchecked Sendable {
        private let group = DispatchGroup()
        private let lock = NSLock()
        private var isOpen = false
        init() { group.enter() }
        func wait() { _ = group.wait(timeout: .now() + 5) }
        func open() { lock.lock(); isOpen = true; lock.unlock(); group.leave() }
        var opened: Bool { lock.lock(); defer { lock.unlock() }; return isOpen }
    }

    final class Log<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [T] = []
        func add(_ item: T) { lock.lock(); all.append(item); lock.unlock() }
        var items: [T] { lock.lock(); defer { lock.unlock() }; return all }
    }

    func ledger(_ day: String, working: Double) -> ActivityLedger {
        var ledger = ActivityLedger(day: day)
        ledger.agentsWorking = working
        return ledger
    }

    @Test func savesDontWaitAreWrittenInOrderAndADaysLatestWins() {
        let gate = Gate()
        let started = DispatchSemaphore(value: 0)
        let written = Log<ActivityLedger>()
        let writer = LedgerWriter { ledger in
            written.add(ledger)
            started.signal()
            gate.wait()
        }
        writer.save(ledger("2026-10-28", working: 1))
        #expect(started.wait(timeout: .now() + 300) == .success)
        // The first write takes 5 s; these return at once, with it still going.
        writer.save(ledger("2026-10-28", working: 2))
        writer.save(ledger("2026-10-29", working: 10))
        writer.save(ledger("2026-10-28", working: 3))
        #expect(!gate.opened)
        #expect(written.items == [ledger("2026-10-28", working: 1)])
        // Read back before they're written (a day begun again), the latest of each.
        #expect(writer.unwritten(day: "2026-10-28") == ledger("2026-10-28", working: 3))
        #expect(writer.unwritten(day: "2026-10-29") == ledger("2026-10-29", working: 10))
        gate.open()
        writer.flush()
        #expect(written.items == [ledger("2026-10-28", working: 1), ledger("2026-10-28", working: 3),
                                  ledger("2026-10-29", working: 10)])
        #expect(writer.unwritten(day: "2026-10-28") == nil)
        #expect(writer.unwritten(day: "2026-10-29") == nil)
    }

    @Test func aLedgerIsWrittenWhereItIsKeptPrivately() throws {
        let folder = scratchRoot.appendingPathComponent("ledger-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = LedgerWriter(folder: folder)
        writer.save(ledger("2026-10-28", working: 42))
        writer.flush()
        #expect(ActivityLedger.load(day: "2026-10-28", from: folder) == ledger("2026-10-28", working: 42))
        let mode = try FileManager.default.attributesOfItem(atPath: ActivityLedger.url(day: "2026-10-28", in: folder).path)[.posixPermissions]
        #expect(mode as? Int == 0o600)
    }

    @Test func bundleIDsAreAskedOncePerPidAndForgottenWhenItsGone() {
        final class Alive: @unchecked Sendable {
            private let lock = NSLock()
            private var pids: Set<Int32> = [10, 11]
            func has(_ pid: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; return pids.contains(pid) }
            func remove(_ pid: Int32) { lock.lock(); pids.remove(pid); lock.unlock() }
        }
        let alive = Alive()
        let cache = BundleIDCache(alive: { alive.has($0) })
        let lookups = Log<Int32>()
        #expect(cache.bundleID(pid: 10, lookup: { lookups.add(10); return "com.apple.Terminal" }) == "com.apple.Terminal")
        #expect(cache.bundleID(pid: 10, lookup: { lookups.add(10); return "other" }) == "com.apple.Terminal")
        #expect(lookups.items == [10])

        // A lookup that takes 5 s holds no one asking for a pid already known.
        let gate = Gate()
        let asking = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = cache.bundleID(pid: 11, lookup: { lookups.add(11); asking.signal(); gate.wait(); return "com.example.Slow" })
            done.signal()
        }
        #expect(asking.wait(timeout: .now() + 300) == .success)
        #expect(cache.bundleID(pid: 10, lookup: { lookups.add(10); return "other" }) == "com.apple.Terminal")
        #expect(!gate.opened)
        gate.open()
        #expect(done.wait(timeout: .now() + 300) == .success)
        #expect(cache.pids == [10, 11])

        // pid 10 quits: forgotten at the next ask, and a new app with that pid is asked again.
        alive.remove(10)
        #expect(cache.bundleID(pid: 11, lookup: { lookups.add(11); return "other" }) == "com.example.Slow")
        #expect(cache.pids == [11])
        #expect(cache.bundleID(pid: 10, lookup: { lookups.add(10); return "com.example.New" }) == "com.example.New")
        #expect(lookups.items == [10, 11, 10])

        // No bundle id: asked again next time.
        #expect(cache.bundleID(pid: 11, lookup: { nil }) == "com.example.Slow")
        alive.remove(11)
        #expect(cache.bundleID(pid: 12, lookup: { lookups.add(12); return nil }) == nil)
        #expect(cache.pids == [])
    }
}
