import Foundation
import Testing
@testable import VibeCore

/// Incident 2026-11-08: "merge test runs stalled for tens of minutes on an idle Mac". Nothing had stalled: the Mac was
/// asleep. An app-wide-appearance's merge test ran from 17:50:48 to 18:42:34, 51.8 minutes on the wall clock and 4.9
/// awake (`pmset -g log`; the load recorder has no line from 17:54 to 18:27), and was called hung at the very second of
/// the DarkWake that let the app look at its clock: test_timeout_min had counted the sleep. The task failed its merge
/// and every merge behind it waited. A run's limits count the time the Mac was awake, as Swift Testing's and Dispatch's do.
///
/// A real command under `Worktrees.runChecks`, as merge's; only the clock is the test's, and each step waits on an event
/// (the command's mark, the run having read the clock since the Mac "slept"), never on a time.
struct MergeRunMacSleepTests {
    let temp = Scratch()

    /// A Mac whose sleep the test decides: the wall clock runs on while it sleeps, the awake clock doesn't. Counts the
    /// run's readings, so a test knows the run has looked since.
    final class Mac: @unchecked Sendable {
        private let lock = NSLock()
        private var slept: TimeInterval = 0, extraAwake: TimeInterval = 0, reads = 0, ended = false

        var time: MacTime {
            MacTime(wall: { [self] in
                lock.withLock { reads += 1; return Date().addingTimeInterval(slept + extraAwake) }
            }, awake: { [self] in
                lock.withLock { reads += 1; return MacTime.real.awake() + extraAwake }
            })
        }

        /// The Mac sleeps for `seconds`.
        func sleep(_ seconds: TimeInterval) { lock.withLock { slept += seconds } }
        /// The Mac stays awake for `seconds`, in a moment.
        func stayAwake(_ seconds: TimeInterval) { lock.withLock { extraAwake += seconds } }
        var readings: Int { lock.withLock { reads } }
        /// The run has ended: it reads the clock no more.
        func runEnded() { lock.withLock { ended = true } }
        var hasEnded: Bool { lock.withLock { ended } }
    }

    /// The run has read the clock a few times more since now, or ended: whatever it would do at this time, it has done.
    func runHasLooked(_ mac: Mac) async -> Bool {
        let then = mac.readings
        return await eventually { mac.readings >= then + 5 || mac.hasEnded }
    }

    /// A command that says it has started (`started` appears), stays quiet in one process until `go` appears, then exits 0.
    func gated(_ name: String) -> (command: String, started: String, go: String) {
        let started = temp.url(name + "-started").path, go = temp.url(name + "-go").path
        let wait = "my $go = shift; select(undef, undef, undef, 0.02) until -e $go"
        return ("touch \(RecentProjects.shellQuote(started)); exec /usr/bin/perl -e '\(wait)' \(RecentProjects.shellQuote(go))", started, go)
    }

    func runChecks(_ test: String, timeout: TimeInterval, watch: StallWatch? = nil, mac: Mac) -> Task<Worktrees.Check?, Never> {
        let folder = temp.url("run-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var lock = TestLock(directory: temp.url("locks-\(UUID().uuidString.prefix(8))").path)
        lock.watch = watch
        let chosen = lock, time = mac.time
        // The scratch home is the caller's to remove, as merge's is: `temp` does.
        let home = temp.url("home").path
        return Task.detached {
            let stopped = await offPool { Worktrees.runChecks(setup: nil, test: test, in: folder.path, home: home, timeout: timeout, lock: chosen, time: time).stopped }
            mac.runEnded()
            return stopped
        }
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// The incident: the Mac sleeps 51 minutes through a merge's 45-minute limit. Awake again, the run goes on and passes.
    @Test func aMergeRunTheMacSleepsThroughIsNotCalledHung() async throws {
        let mac = Mac(), (command, started, go) = gated("slept")
        let run = runChecks(command, timeout: 45 * 60, mac: mac)
        #expect(await eventually { exists(started) }, "the command never started")
        mac.sleep(51 * 60)
        #expect(await runHasLooked(mac))
        FileManager.default.createFile(atPath: go, contents: nil)
        let stopped = await run.value
        #expect(stopped == nil, "\(String(describing: stopped))")
    }

    /// Cycles of dark wakes (2.5–3 min apart on 2026-11-08, shorter than half a stall, so no look counts as "late") aren't
    /// silence either: a run with no awake time to make progress in isn't stopped at stall_min.
    @Test func aMergeRunThroughDarkWakesIsNotCalledStalled() async throws {
        let mac = Mac(), (command, started, go) = gated("dark")
        let watch = StallWatch(after: 600, every: 0.05, loadLimit: 24, load: { 4.2 })
        let run = runChecks(command, timeout: 45 * 60, watch: watch, mac: mac)
        #expect(await eventually { exists(started) }, "the command never started")
        for _ in 0..<8 {
            mac.sleep(170)
            #expect(await runHasLooked(mac))
        }
        FileManager.default.createFile(atPath: go, contents: nil)
        let stopped = await run.value
        #expect(stopped == nil, "\(String(describing: stopped))")
    }

    /// A run quiet for less than the no-progress limit, awake all the while, then finishing, isn't stopped: 510 awake
    /// seconds under a limit of 600, in steps too short for a look to count as late.
    @Test func aMergeRunQuietForLessThanTheLimitIsNotStopped() async throws {
        let mac = Mac(), (command, started, go) = gated("quiet")
        let watch = StallWatch(after: 600, every: 0.05, loadLimit: 24, load: { 4.2 })
        let run = runChecks(command, timeout: 45 * 60, watch: watch, mac: mac)
        #expect(await eventually { exists(started) }, "the command never started")
        for _ in 0..<3 {
            mac.stayAwake(170)
            #expect(await runHasLooked(mac))
        }
        FileManager.default.createFile(atPath: go, contents: nil)
        let stopped = await run.value
        #expect(stopped == nil, "\(String(describing: stopped))")
    }

    /// The run's report says how long the Mac slept in its window, by the clocks its limits use: most of it here.
    @Test func aRunStoppedAcrossASleepSaysTheMacSlept() async throws {
        let mac = Mac(), (command, started, _) = gated("slept-report")
        let run = runChecks(command, timeout: 45 * 60, mac: mac)
        #expect(await eventually { exists(started) }, "the command never started")
        mac.sleep(2 * 60 * 60)
        mac.stayAwake(46 * 60)
        guard case .hung(_, _, let output, _)? = await run.value else { Issue.record("not stopped as hung"); return }
        let why = try #require(MergeRerun.cause(in: output), "\(output)")
        #expect(why.hasPrefix("a live process with no output: its last line came "), "\(why)")
        #expect(why.contains("the Mac slept 120 min of the "), "\(why)")
    }

    /// Awake the whole run, stopped for no progress: the report names the live process and says the Mac was awake.
    @Test func aRunStoppedAwakeSaysWhichProcessWasSilent() async throws {
        let mac = Mac(), (command, started, _) = gated("awake-report")
        let watch = StallWatch(after: 600, every: 0.05, loadLimit: 24, load: { 4.2 })
        let run = runChecks(command, timeout: 45 * 60, watch: watch, mac: mac)
        #expect(await eventually { exists(started) }, "the command never started")
        for _ in 0..<4 {
            mac.stayAwake(170)
            #expect(await runHasLooked(mac))
        }
        guard case .hung(_, _, let output, let stall?)? = await run.value else { Issue.record("not stopped as hung"); return }
        let why = try #require(MergeRerun.cause(in: output), "\(output)")
        #expect(why.hasPrefix("a live process with no output for \(Worktrees.duration(stall.idle)) of awake time, its processes when stopped: "), "\(why)")
        #expect(why.contains("the Mac was awake the whole "), "\(why)")
    }

    /// The limit still holds: a run that really had its 45 awake minutes is stopped as hung, and says how long it was
    /// silent in awake time.
    @Test func aMergeRunPastItsLimitInAwakeTimeIsStillStopped() async throws {
        let mac = Mac(), (command, started, _) = gated("awake")
        let run = runChecks(command, timeout: 45 * 60, mac: mac)
        #expect(await eventually { exists(started) }, "the command never started")
        mac.sleep(2 * 60 * 60)
        mac.stayAwake(46 * 60)
        guard case .hung(let name, let after, let output, let stall)? = await run.value else { Issue.record("not stopped as hung"); return }
        #expect(name == "test command" && after == 45 * 60 && stall == nil)
        // 46 min of the jump plus the moments the run really took, rounded; the wall clock's would be 2 h 46 min.
        #expect(output.contains("Its last output line came 46 min before") || output.contains("Its last output line came 47 min before"), "\(output)")
    }
}
