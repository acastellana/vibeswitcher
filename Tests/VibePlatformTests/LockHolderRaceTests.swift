import Foundation
import Testing
@testable import VibePlatform

/// A lock's holder read from `/proc/locks` while other processes' locks come and go (the load run of 2026-11-21: the
/// first command after a scratch node's start said no process held its lock): the list comes in page-sized reads, and a
/// line can be skipped by every read of one look when locks before it are dropped between the reads. The patient look
/// (`lockHolder(path:exclusiveFlock:patience:)`) looks again while it finds none, so a held lock is found; one not held
/// is said after the patience.
@Suite(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's /proc/locks"), .serialized)
struct LockHolderRaceTests {
    /// Locks held on `count` files of `folder`, more than a page of /proc/locks' lines, dropped and taken again by
    /// `threads` threads until `stop`: what moves the lines between two reads of one look.
    final class Churn: @unchecked Sendable {
        let stop = Atomic(false)
        let threads: [Thread]
        init(folder: URL, count: Int, threads: Int) {
            var made: [Thread] = []
            for index in 0..<threads {
                let paths = (0..<count).map { folder.appendingPathComponent("churn-\(index)-\($0)").path }
                let stop = self.stop
                let thread = Thread {
                    let fds = paths.map { open($0, O_RDWR | O_CREAT | O_CLOEXEC, 0o600) }
                    while !stop.value {
                        for fd in fds { _ = flock(fd, LOCK_EX) }
                        for fd in fds { _ = flock(fd, LOCK_UN) }
                    }
                    fds.forEach { close($0) }
                }
                made.append(thread)
            }
            self.threads = made
            made.forEach { $0.start() }
        }
        func end() { stop.value = true }
    }

    final class Atomic<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// With a lock held by this process and many others churning, a single look misses it some of the time (said,
    /// not required: how often depends on the machine); the patient look never does.
    @Test func aHeldLockIsFoundWhileOtherLocksComeAndGo() throws {
        let folder = try ProcessesTests.scratch("lock-race")
        defer { try? FileManager.default.removeItem(at: folder) }
        let held = folder.appendingPathComponent("held.lock").path
        let fd = open(held, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(fd >= 0 && flock(fd, LOCK_EX) == 0)
        defer { close(fd) }
        let churn = Churn(folder: folder, count: 40, threads: 6)
        defer { churn.end() }
        var missed = 0
        for _ in 0..<400 where Platform.Processes.lockHolder(path: held) == nil { missed += 1 }
        for attempt in 0..<200 {
            #expect(Platform.Processes.lockHolder(path: held, patience: 3) == getpid(), "patient look \(attempt) missed it")
        }
        print("lock-race: a single look missed the held lock \(missed) of 400 times; the patient look none of 200")
    }

    /// The patient look's own rule: it asks again until a holder shows, and gives up after its patience.
    @Test func thePatientLookAsksAgainUntilAHolderShowsOrItsPatienceEnds() {
        var asked = 0
        var clock = 0.0
        let found = Platform.Processes.patiently(patience: 3, pause: 0.5, now: { clock }, wait: { clock += $0 }) {
            asked += 1
            return asked == 3 ? 4242 : nil
        }
        #expect(found == 4242 && asked == 3)
        asked = 0
        clock = 0
        let none = Platform.Processes.patiently(patience: 3, pause: 0.5, now: { clock }, wait: { clock += $0 }) { asked += 1; return nil }
        #expect(none == nil && asked == 7 && clock >= 3, "asked \(asked) times by \(clock) s")
    }
}
