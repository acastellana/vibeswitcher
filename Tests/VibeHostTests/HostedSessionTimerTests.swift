import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The session's timers on a clock the test moves: each fires only when the test says, and says how it was scheduled.
final class FakeTimers {
    final class Timer: SessionTimer {
        let purpose: SessionTimers.Purpose
        let fire: () -> Void
        /// Each schedule: its delay and repeat.
        private(set) var schedules: [(after: TimeInterval, repeating: TimeInterval?, leeway: DispatchTimeInterval)] = []
        private(set) var cancelled = false

        init(_ purpose: SessionTimers.Purpose, fire: @escaping () -> Void) {
            self.purpose = purpose
            self.fire = fire
        }

        func schedule(after delay: TimeInterval, repeating: TimeInterval?, leeway: DispatchTimeInterval) {
            schedules.append((delay, repeating, leeway))
        }

        func cancel() { cancelled = true }
    }

    let queue: DispatchQueue
    private(set) var made: [Timer] = []

    init(queue: DispatchQueue) { self.queue = queue }

    var timers: SessionTimers {
        SessionTimers { purpose, _, fire in
            let timer = Timer(purpose, fire: fire)
            self.made.append(timer)
            return timer
        }
    }

    /// Those made for `purpose`, oldest first. On the session's queue, as everything here.
    func made(_ purpose: SessionTimers.Purpose) -> [Timer] { queue.sync { made.filter { $0.purpose == purpose } } }

    /// Its time came: it fires, on the session's queue.
    func fire(_ timer: Timer) { queue.sync { timer.fire() } }
}

/// The exit poll's backoff and the parser watchdog's stop and restart, on `FakeTimers`: no wait on their periods.
/// Real PTYs and parsers, scratch programs only.
struct HostedSessionTimerTests {
    func start(_ command: String, probe: SessionProbe, timers: FakeTimers) throws -> HostedSession {
        let request = SpawnRequest(cwd: scratchRoot.path, command: command, env: [:], cols: 80, rows: 24, keepShell: false, label: "Test", agent: nil)
        return try probe.queue.sync {
            let session = try HostedSession.spawn(request, shell: "/bin/sh", launcher: hostLauncher, baseEnvironment: ["PATH": "/usr/bin:/bin"],
                                                  ringCapacity: 1 << 20, queue: probe.queue, parser: ParserOptions(), timers: timers.timers)
            probe.attach(session)
            return session
        }
    }

    func end(_ session: HostedSession, probe: SessionProbe) {
        let pid = probe.queue.sync { session.info.childPID }
        kill(pid, SIGKILL)
        _ = eventually { probe.queue.sync { session.info.exit != nil } }
    }

    /// A look 50 ms in, then at 1 and 5 s, then every 30 s, each scheduled once the one before looked.
    @Test func theExitPollBacksOff() throws {
        let probe = SessionProbe()
        let timers = FakeTimers(queue: probe.queue)
        let session = try start("exec sleep 600", probe: probe, timers: timers)
        defer { end(session, probe: probe) }
        let poll = try #require(timers.made(.exitPoll).first)
        #expect(timers.made(.exitPoll).count == 1)
        for _ in 0..<5 { timers.fire(poll) }
        let schedules = probe.queue.sync { poll.schedules }
        #expect(schedules.map(\.after) == [0.05, 1, 5, 30, 30, 30])
        #expect(schedules.allSatisfy { $0.repeating == nil })
        #expect(schedules.map(\.leeway) == [.milliseconds(20), .milliseconds(100), .milliseconds(500), .milliseconds(3_000),
                                            .milliseconds(3_000), .milliseconds(3_000)])
        // The program runs on: each look found it running.
        #expect(probe.queue.sync { session.info.isLive && !poll.cancelled })
    }

    /// A program ending once the exit source is registered is reaped on its event, with no look of the poll's, which
    /// then stops. Under load the event can come a moment before the program can be reaped (see
    /// `anExitEventBeforeTheProgramCanBeReapedLooksAgainSoon`): the poll then looks again soon, here when the test
    /// fires it, its clock being the test's.
    @Test func theExitSourceReapsAtOnce() throws {
        let probe = SessionProbe()
        let timers = FakeTimers(queue: probe.queue)
        let session = try start("exec sleep 600", probe: probe, timers: timers)
        let poll = try #require(timers.made(.exitPoll).first)
        let pid = probe.queue.sync { session.info.childPID }
        #expect(eventually { (ProcessTable.info(pid: pid)?.comm ?? "") == "sleep" })
        kill(pid, SIGTERM)
        #expect(eventually {
            let (ended, early) = probe.queue.sync { (session.info.exit != nil, poll.schedules.count > 1) }
            if !ended, early { timers.fire(poll) }
            return ended
        })
        #expect(probe.queue.sync { session.info.exit?.signal } == SIGTERM)
        // The poll never looked on its own: only the event's early look (at 50 ms), if any, came after its first.
        #expect(probe.queue.sync { poll.cancelled && (poll.schedules.count == 1 || poll.schedules[1].after == 0.05) })
    }

    /// The exit source's event can come a moment before the program can be reaped (the kernel posts it first): the
    /// poll then looks again at its shortest delay, its backoff starting over, not at its next look up to 30 s off.
    @Test func anExitEventBeforeTheProgramCanBeReapedLooksAgainSoon() throws {
        let probe = SessionProbe()
        let timers = FakeTimers(queue: probe.queue)
        let session = try start("exec sleep 600", probe: probe, timers: timers)
        defer { end(session, probe: probe) }
        let poll = try #require(timers.made(.exitPoll).first)
        // The backoff well under way: the next look is 30 s off.
        for _ in 0..<4 { timers.fire(poll) }
        #expect(probe.queue.sync { poll.schedules.last?.after } == 30)
        // The event while the program can't be reaped (still running here, standing in for one still exiting).
        probe.queue.sync { session.exitEvent() }
        #expect(probe.queue.sync { session.info.isLive && !poll.cancelled })
        let soon = try #require(probe.queue.sync { poll.schedules.last })
        #expect(probe.queue.sync { poll.schedules.count } == 6)
        #expect(soon.after == 0.05 && soon.repeating == nil && soon.leeway == .milliseconds(20))
        // Its backoff starts over: a look finding it running schedules the next at 1 s.
        timers.fire(poll)
        #expect(probe.queue.sync { poll.schedules.last?.after } == 1)
    }

    /// The watchdog runs while the parser has work, stops at its first look that finds none, and starts again with
    /// the parser's next work.
    @Test func theParserWatchdogStopsWhileIdleAndStartsWhenBusy() throws {
        let probe = SessionProbe()
        let timers = FakeTimers(queue: probe.queue)
        let session = try start("printf 'ready\\n'; exec cat", probe: probe, timers: timers)
        defer { end(session, probe: probe) }
        let first = try #require(timers.made(.parserWatchdog).first)
        // A quarter of the stall limit (10 s), at most 1 s, repeated.
        let schedule = try #require(probe.queue.sync { first.schedules.first })
        #expect(schedule.after == 1 && schedule.repeating == 1 && schedule.leeway == .milliseconds(250))
        #expect(eventually { probe.text.contains("ready") })
        // Looks while the parser catches up keep it running; the first that finds it idle stops it.
        #expect(eventually { timers.fire(first); return probe.queue.sync { first.cancelled } })
        #expect(timers.made(.parserWatchdog).count == 1)

        // Output: the parser has work, and the watchdog runs again.
        session.write(Data("again\r".utf8), on: probe.queue)
        #expect(eventually { timers.made(.parserWatchdog).count == 2 }, "\(probe.diagnosis(session))")
        let second = try #require(timers.made(.parserWatchdog).last)
        #expect(probe.queue.sync { !second.cancelled && second.schedules.count == 1 })
        #expect(eventually { timers.fire(second); return probe.queue.sync { second.cancelled } })
        // Idle again, it stays stopped.
        #expect(timers.made(.parserWatchdog).count == 2)
    }
}

extension HostedSession {
    /// Input from a test, on the session's queue.
    func write(_ data: Data, on queue: DispatchQueue) { _ = queue.sync { write(data) } }
}
