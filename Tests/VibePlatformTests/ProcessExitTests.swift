import Foundation
import Testing
@testable import VibePlatform

/// `Platform.ProcessExit`: the end of a child and of a process that isn't one, told once on the watch's queue. The
/// processes are `cat` held on a pipe the test has the other end of (`SpawnTests.held`): each ends when the test
/// closes its end, and is collected, or killed and collected when its test fails before that.
///
/// "Not told" is shown without waiting for nothing: a second process is watched on the same serial queue after the
/// first, and once its end is told the first's reports are counted.
struct ProcessExitTests {
    static let hangGuard = TestScriptLinuxTests.hangGuard

    /// The calls of a watch's `ended`.
    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let came = DispatchSemaphore(value: 0)

        func report() {
            lock.withLock { calls += 1 }
            came.signal()
        }

        var count: Int { lock.withLock { calls } }

        /// Waits for one report; false when none came within the hang guard.
        func wait() -> Bool {
            came.wait(timeout: .now() + ProcessExitTests.hangGuard) == .success
        }
    }

    /// A child of the test's that stays until `end()`.
    final class Held {
        let pid: pid_t
        private var release: Int32
        private var collected = false

        init() throws {
            (pid, release) = try SpawnTests.held(.inherit)
        }

        /// Lets it go: it reads the end of its input and exits.
        func end() {
            guard release >= 0 else { return }
            close(release)
            release = -1
        }

        /// Waits for its exit and collects it: whether it was there to collect (no one else had). Killed when it
        /// hasn't exited within the hang guard.
        @discardableResult
        func collect() -> Bool {
            guard !collected else { return false }
            collected = true
            let guardian = DispatchWorkItem { [pid] in kill(pid, SIGKILL) }
            DispatchQueue.global().asyncAfter(deadline: .now() + ProcessExitTests.hangGuard, execute: guardian)
            defer { guardian.cancel() }
            var status: Int32 = 0
            var found: pid_t
            repeat { found = waitpid(pid, &status, 0) } while found < 0 && errno == EINTR
            return found == pid
        }

        /// At a test's end, whatever it came to: gone and collected.
        func finish() {
            end()
            if !collected { kill(pid, SIGKILL) }
            collect()
        }
    }

    /// A process that ends, watched on `queue` and told: every report `queue` was due before it has been made.
    static func afterAnotherEnd(on queue: DispatchQueue) throws {
        let other = try Held()
        defer { other.finish() }
        let reports = Reports()
        let watch = Platform.ProcessExit.watch(other.pid, queue: queue) { reports.report() }
        defer { watch.cancel() }
        other.end()
        #expect(reports.wait(), "the end of pid \(other.pid) wasn't told")
        queue.sync {}
    }

    @Test func aChildsExitIsReportedOnce() throws {
        let queue = DispatchQueue(label: "process-exit-tests.child")
        let child = try Held()
        defer { child.finish() }
        let reports = Reports()
        let mark = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: mark, value: true)
        let onQueue = FolderWatchTests.Box(false)
        let watch = Platform.ProcessExit.watch(child.pid, queue: queue) {
            onQueue.value = DispatchQueue.getSpecific(key: mark) == true
            reports.report()
        }
        defer { watch.cancel() }
        #expect(reports.count == 0)
        child.end()
        #expect(reports.wait())
        #expect(onQueue.value)
        // Told at its exit, and still the test's to collect: the watch collects nothing.
        #expect(child.collect())

        try Self.afterAnotherEnd(on: queue)
        #expect(reports.count == 1)
        // Told isn't called off: HostServer asks this of its watch when the owner is gone.
        #expect(!watch.isCancelled)
        watch.cancel()
        #expect(watch.isCancelled)
    }

    /// A grandchild: a shell the test starts runs a second shell, which says its pid and becomes `cat` on the pipe
    /// the test holds. The watch has no claim on it as a parent has.
    @Test func anotherProcesssExitIsReported() throws {
        let queue = DispatchQueue(label: "process-exit-tests.other")
        let input = try SpawnTests.newPipe(), output = try SpawnTests.newPipe()
        var spawn = SpawnTests.shell("sh -c 'echo $$; exec cat > /dev/null'; true")
        spawn.stdin = .descriptor(input.reading)
        spawn.stdout = .descriptor(output.writing)
        let started = spawn.start()
        close(input.reading)
        close(output.writing)
        var release = input.writing
        guard case .success(let shell) = started else {
            close(release)
            close(output.reading)
            Issue.record("the shell didn't start: \(started)")
            return
        }
        // In every case the pipe is closed, and the shell, which ends when its `cat` does, collected.
        var collected = false
        defer {
            if release >= 0 { close(release) }
            close(output.reading)
            if !collected { _ = SpawnTests.ended(shell) }
        }

        // The pid's line: all the shell ever prints.
        var line = [UInt8]()
        var byte: UInt8 = 0
        while read(output.reading, &byte, 1) == 1, byte != UInt8(ascii: "\n") { line.append(byte) }
        let other = try #require(pid_t(String(decoding: line, as: UTF8.self)), "no pid from the shell: \(line)")
        #expect(other != shell)
        guard case .brief(let brief) = Platform.Processes.brief(other) else {
            Issue.record("pid \(other) can't be read")
            return
        }
        #expect(brief.ppid == shell, "pid \(other) is the child of \(brief.ppid), not of the shell \(shell)")
        #expect(brief.ppid != getpid())

        let reports = Reports()
        let watch = Platform.ProcessExit.watch(other, queue: queue) { reports.report() }
        defer { watch.cancel() }
        #expect(reports.count == 0)
        close(release)
        release = -1
        #expect(reports.wait())
        let ended = SpawnTests.ended(shell)
        collected = true
        #expect(ended.exit == 0)
        try Self.afterAnotherEnd(on: queue)
        #expect(reports.count == 1)
    }

    @Test func cancelBeforeTheExitMeansNoReport() throws {
        let queue = DispatchQueue(label: "process-exit-tests.cancel")
        let child = try Held()
        defer { child.finish() }
        let reports = Reports()
        let watch = Platform.ProcessExit.watch(child.pid, queue: queue) { reports.report() }
        #expect(!watch.isCancelled)
        watch.cancel()
        watch.cancel()
        #expect(watch.isCancelled)
        child.end()
        child.collect()
        try Self.afterAnotherEnd(on: queue)
        #expect(reports.count == 0)
    }

    /// Letting go of the watch calls it off, as letting go of a dispatch source does.
    @Test func aWatchLetGoMeansNoReport() throws {
        let queue = DispatchQueue(label: "process-exit-tests.let-go")
        let child = try Held()
        defer { child.finish() }
        let reports = Reports()
        _ = Platform.ProcessExit.watch(child.pid, queue: queue) { reports.report() }
        child.end()
        child.collect()
        try Self.afterAnotherEnd(on: queue)
        #expect(reports.count == 0)
    }

    /// Ended and collected before the watch begins: no such process any more. Told all the same, once.
    @Test func aProcessAlreadyGoneIsReported() throws {
        let queue = DispatchQueue(label: "process-exit-tests.gone")
        let pid = try SpawnTests.shell("exit 0").start().get()
        #expect(SpawnTests.ended(pid).exit == 0)
        #expect(kill(pid, 0) == -1)
        let reports = Reports()
        let watch = Platform.ProcessExit.watch(pid, queue: queue) { reports.report() }
        defer { watch.cancel() }
        #expect(reports.wait())
        try Self.afterAnotherEnd(on: queue)
        #expect(reports.count == 1)

        // And not when the watch was called off first.
        let silent = Reports()
        queue.sync {
            let called = Platform.ProcessExit.watch(pid, queue: queue) { silent.report() }
            called.cancel()
        }
        try Self.afterAnotherEnd(on: queue)
        #expect(silent.count == 0)
    }

    #if os(Linux)
    /// Whether `pid` has exited and waits to be collected.
    static func isZombie(_ pid: pid_t) -> Bool {
        if case .brief(let brief) = Platform.Processes.brief(pid) { return brief.state == .zombie }
        return false
    }

    /// Exited before the watch begins and not collected yet: its descriptor reads as ready from the start.
    @Test func aChildThatEndedUncollectedIsReported() throws {
        let queue = DispatchQueue(label: "process-exit-tests.zombie")
        let child = try Held()
        defer { child.finish() }
        child.end()
        #expect(FolderWatchTests.eventually { Self.isZombie(child.pid) })
        let reports = Reports()
        let watch = Platform.ProcessExit.watch(child.pid, queue: queue) { reports.report() }
        defer { watch.cancel() }
        #expect(reports.wait())
        child.collect()
        try Self.afterAnotherEnd(on: queue)
        #expect(reports.count == 1)
    }

    /// Where a process can't be opened (a kernel before 5.3, no descriptor left), its end is still told, by asking:
    /// an exit, one that came before the watch, and a process that is gone. Never for one that runs.
    @Test func withoutADescriptorTheEndIsStillTold() throws {
        let queue = DispatchQueue(label: "process-exit-tests.asked")
        let refused: (pid_t) -> Int32 = { _ in
            errno = ENOSYS
            return -1
        }
        let child = try Held()
        defer { child.finish() }
        let reports = Reports()
        let watch = Platform.ProcessExit.System.watch(child.pid, queue: queue, opening: refused) { reports.report() }
        defer { watch.cancel() }
        // Asked at once, and it runs: nothing told.
        queue.sync {}
        #expect(reports.count == 0)
        child.end()
        #expect(reports.wait())
        #expect(Self.isZombie(child.pid))

        let early = Reports()
        let late = Platform.ProcessExit.System.watch(child.pid, queue: queue, opening: refused) { early.report() }
        defer { late.cancel() }
        #expect(early.wait())
        child.collect()

        let gone = Reports()
        let after = Platform.ProcessExit.System.watch(child.pid, queue: queue, opening: refused) { gone.report() }
        defer { after.cancel() }
        #expect(gone.wait())
        try Self.afterAnotherEnd(on: queue)
        #expect(reports.count == 1 && early.count == 1 && gone.count == 1, "\(reports.count) \(early.count) \(gone.count)")
    }
    #endif
}
