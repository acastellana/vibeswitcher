import Darwin
import Foundation
import Testing
@testable import VibeCore

/// The other waits a sleeping Mac could trip, after the merge's run (`MergeRunMacSleepTests`): a wait for a slot of the
/// Mac-wide lock and vs-heavy's --timeout and --stall count the time the Mac was awake, not the wall clock. (The wait for
/// the Mac's load is in `MacLoadTests`.) Only the clocks are the test's; each step waits on an event (the wait has read
/// the clock since the Mac "slept", the command's mark), never on a time. Every lock here is a scratch one.
struct MacSleepLimitsTests {
    typealias Mac = MergeRunMacSleepTests.Mac
    let temp = Scratch()

    /// The wait has read the clock a few times more since now, or ended: whatever it would do at this time, it has done.
    func hasLooked(_ mac: Mac) async -> Bool {
        let then = mac.readings
        return await eventually { mac.readings >= then + 5 || mac.hasEnded }
    }

    /// A wait for a slot of `lock`, up to `timeout`, on `mac`'s clocks, off the pool: what became of it.
    func waitForSlot(_ lock: TestLock, timeout: TimeInterval, mac: Mac) -> Task<String, Never> {
        let time = mac.time
        return Task.detached {
            let outcome = await offPool { () -> String in
                switch lock.acquire(as: "merge of b", timeout: timeout, cancel: nil, every: 0.02, time: time) {
                case .held(let held, _, _):
                    held.release()
                    return "held"
                case .busy: return "busy"
                case .cancelled: return "cancelled"
                case .failed(let why): return why
                }
            }
            mac.runEnded()
            return outcome
        }
    }

    /// The incident's shape for the lock: the Mac sleeps 2 hours through a 30-minute wait. Awake again, the wait goes on
    /// and takes the slot when it's let go.
    @Test func aWaitForASlotTheMacSleepsThroughIsNotOver() async throws {
        let lock = TestLock(directory: temp.url("locks").path), mac = Mac()
        guard case .held(let holder, _, _) = lock.acquire(as: "merge of a", timeout: hangGuard, cancel: nil) else { Issue.record("not taken"); return }
        defer { holder.release() }
        let waiter = waitForSlot(lock, timeout: 30 * 60, mac: mac)
        #expect(await eventually { lock.waiters().count == 1 }, "the wait never joined the line")
        mac.sleep(2 * 60 * 60)
        #expect(await hasLooked(mac))
        holder.release()
        let outcome = await waiter.value
        #expect(outcome == "held", "\(outcome)")
    }

    /// The limit still holds: a wait that really had its 30 awake minutes ends busy.
    @Test func aWaitForASlotPastItsLimitInAwakeTimeIsBusy() async throws {
        let lock = TestLock(directory: temp.url("locks").path), mac = Mac()
        guard case .held(let holder, _, _) = lock.acquire(as: "merge of a", timeout: hangGuard, cancel: nil) else { Issue.record("not taken"); return }
        defer { holder.release() }
        let waiter = waitForSlot(lock, timeout: 30 * 60, mac: mac)
        #expect(await eventually { lock.waiters().count == 1 }, "the wait never joined the line")
        mac.stayAwake(31 * 60)
        let outcome = await waiter.value
        #expect(outcome == "busy", "\(outcome)")
    }

    // MARK: vs-heavy

    /// A stand-in for the Mac's two clocks, as vs-heavy reads it (VIBESWITCHER_HEAVY_CLOCK): the wall clock runs on while
    /// the Mac sleeps, the awake clock doesn't. vs-heavy's readings are counted, so a test knows it has looked since.
    final class HeavyClock: @unchecked Sendable {
        let path: String
        private let lock = NSLock()
        private var wall: TimeInterval = 100_000, awake: TimeInterval = 50_000

        init(path: String) throws {
            self.path = path
            try write(wall, awake)
        }

        private func write(_ wall: TimeInterval, _ awake: TimeInterval) throws {
            try "\(wall) \(awake)\n".write(toFile: path, atomically: true, encoding: .utf8)
        }

        /// The Mac sleeps for `seconds`.
        func sleep(_ seconds: TimeInterval) throws { try lock.withLock { wall += seconds; try write(wall, awake) } }
        /// The Mac stays awake for `seconds`, in a moment.
        func stayAwake(_ seconds: TimeInterval) throws { try lock.withLock { wall += seconds; awake += seconds; try write(wall, awake) } }
        /// How many times vs-heavy has read it.
        var reads: Int { ((try? FileManager.default.attributesOfItem(atPath: path + ".reads"))?[.size] as? Int) ?? 0 }
    }

    /// A clock in this test's scratch, the readings vs-heavy notes beside it removed with it.
    func heavyClock() throws -> HeavyClock {
        let path = temp.url("clock").path
        temp.adopt(URL(fileURLWithPath: path + ".reads"))
        return try HeavyClock(path: path)
    }

    /// vs-heavy has read the clock a few times more since now, or ended.
    func hasLooked(_ clock: HeavyClock, _ run: Process) async -> Bool {
        let then = clock.reads
        return await eventually { clock.reads >= then + 5 || !run.isRunning }
    }

    /// A command that says it has started (`started` appears), stays quiet in one process until `go` appears, then exits 0.
    func gated() -> (arguments: [String], started: String, go: String) {
        let started = temp.url("started").path, go = temp.url("go").path
        let wait = "my $go = shift; select(undef, undef, undef, 0.02) until -e $go"
        let script = "touch \(RecentProjects.shellQuote(started)); exec /usr/bin/perl -e '\(wait)' \(RecentProjects.shellQuote(go))"
        return (["/bin/sh", "-c", script], started, go)
    }

    /// vs-heavy with `arguments` on `clock`, at a load under load_threshold, its looks a minute apart on that clock.
    func heavy(_ arguments: [String], clock: HeavyClock) throws -> (run: Process, output: String, locks: String) {
        let locks = temp.url("heavy-locks").path, output = temp.url("heavy.out").path
        let run = try TestLockTests.runVsHeavy(arguments, lockDirectory: locks, output: output,
                                               environment: [TestLock.sampleVariable: "60", "VIBESWITCHER_HEAVY_LOAD": "4.2", "VIBESWITCHER_HEAVY_CLOCK": clock.path])
        return (run, output, locks)
    }

    func text(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// --timeout: the Mac sleeps 3 hours through a 30-minute limit. Awake again, the run goes on and passes.
    @Test func vsHeavysTimeoutDoesntCountTheMacSleeping() async throws {
        let clock = try heavyClock(), (command, started, go) = gated()
        let (run, output, _) = try heavy(["--timeout", "30m", "--stall", "off"] + command, clock: clock)
        defer { kill(run.processIdentifier, SIGKILL); waitForEnd(run) }
        #expect(await eventually { exists(started) }, "the command never started")
        try clock.sleep(3 * 60 * 60)
        #expect(await hasLooked(clock, run))
        FileManager.default.createFile(atPath: go, contents: nil)
        #expect(await exited(run), "pid \(run.processIdentifier) still running")
        #expect(run.terminationStatus == 0 && !text(output).contains("ran past"), "\(text(output))")
    }

    /// --stall: dark wakes 170 s apart (shorter than half a stall, so no look counts as late) aren't silence: a run with
    /// no awake time to make progress in isn't stopped.
    @Test func vsHeavysStallDoesntCountDarkWakes() async throws {
        let clock = try heavyClock(), (command, started, go) = gated()
        let (run, output, _) = try heavy(["--timeout", "8h", "--stall", "10m"] + command, clock: clock)
        defer { kill(run.processIdentifier, SIGKILL); waitForEnd(run) }
        #expect(await eventually { exists(started) }, "the command never started")
        for _ in 0..<8 {
            try clock.sleep(170)
            #expect(await hasLooked(clock, run))
        }
        FileManager.default.createFile(atPath: go, contents: nil)
        #expect(await exited(run), "pid \(run.processIdentifier) still running")
        #expect(run.terminationStatus == 0 && !text(output).contains("no progress"), "\(text(output))")
    }

    /// The limits still hold: a run that really had its 30 awake minutes is stopped at --timeout, exit 124.
    @Test func vsHeavysTimeoutStillStopsARunPastItInAwakeTime() async throws {
        let clock = try heavyClock(), (command, started, _) = gated()
        let (run, output, locks) = try heavy(["--as", "long", "--timeout", "30m", "--stall", "off"] + command, clock: clock)
        defer { kill(run.processIdentifier, SIGKILL); waitForEnd(run) }
        #expect(await eventually { exists(started) }, "the command never started")
        try clock.stayAwake(31 * 60)
        #expect(await exited(run), "pid \(run.processIdentifier) still running")
        #expect(run.terminationStatus == 124 && text(output).contains("vs-heavy: long: ran past 30 min (--timeout)"), "\(text(output))")
        #expect(TestLock(directory: locks).holders().isEmpty)
    }

    /// And a run with 10 awake minutes of silence is stopped at --stall, saying so in awake time: steps too short for a
    /// look to count as late.
    @Test func vsHeavysStallStillStopsARunSilentInAwakeTime() async throws {
        let clock = try heavyClock(), (command, started, _) = gated()
        let (run, output, _) = try heavy(["--as", "quiet", "--timeout", "8h", "--stall", "10m"] + command, clock: clock)
        defer { kill(run.processIdentifier, SIGKILL); waitForEnd(run) }
        #expect(await eventually { exists(started) }, "the command never started")
        for _ in 0..<4 {
            try clock.stayAwake(170)
            #expect(await hasLooked(clock, run))
        }
        #expect(await exited(run), "pid \(run.processIdentifier) still running")
        #expect(run.terminationStatus == 125 && text(output).contains("vs-heavy: quiet: no progress for 11 min ("), "\(text(output))")
    }
}
