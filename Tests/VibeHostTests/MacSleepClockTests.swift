import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The host's own limits count the time the Mac is awake, not the wall clock, which goes on while it sleeps: at a
/// wake (a dark wake too, a few seconds every 15 minutes) a wall-clock limit has passed though nothing had a moment to
/// run. Here the wall clock leaps an hour at each look, as across a sleep; the limits still hold.
@Suite(hostTestLimit) struct MacSleepClockTests {
    let temp = Scratch()

    /// Counts calls, from any thread.
    final class Looks: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    /// A wall clock an hour later at each look: the Mac slept between any two.
    static func sleepingWall() -> () -> Date {
        let looks = Looks()
        return { Date().addingTimeInterval(3_600 * Double(looks.next())) }
    }

    /// The new build's probe may take its limit awake: on 2026-11-15 the Mac slept the second a merge's handover test
    /// began, and at the next dark wake the probe, still waiting on the system's first check of the new build, was
    /// past its 180 s by the wall clock: "it didn't answer". This probe answers once the handover looked at its clock
    /// twice (its deadline, then its first look), so only a limit on the wall clock would give up on it.
    @Test func aSleepDoesntUseUpTheHandoverProbesLimit() async throws {
        let folder = temp.url("probe-sleep")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let go = folder.appendingPathComponent("go").path, build = folder.appendingPathComponent("build").path
        // Copied into place by a child (`installScript`): written by this process, the probe's exec of it failed with
        // "Text file busy" in a full run (2026-11-19), a child another test forked meanwhile holding it open for writing.
        try installScript("#!/bin/sh\nwhile [ ! -e '\(go)' ]; do sleep 0.01; done\necho '\(HostHandover.probeAnswer)'\n", atPath: build)
        let looks = Looks()
        let time = MacTime(wall: Self.sleepingWall(), awake: {
            if looks.next() == 2 { FileManager.default.createFile(atPath: go, contents: nil) }
            return MacTime.real.awake()
        })
        let failure = await offPool { () -> String? in
            do {
                try HostHandover.probe(build, statePath: folder.appendingPathComponent("state").path, time: time)
                return nil
            } catch { return "\(error)" }
        }
        #expect(failure == nil)
    }

    /// A parser busy across a sleep isn't stalled: on 2026-11-16 a merge's parser test saw the watchdog replace a
    /// parser "stalled for 1072.2 s" at a dark wake, 18 minutes of sleep after its last progress, its unparsed bytes
    /// dropped. This parser is stuck (a test hook) well short of its limit awake; the watchdog's look leaves it.
    @Test func aSleepIsntAParsersStall() async throws {
        let probe = SessionProbe()
        let timers = FakeTimers(queue: probe.queue, time: MacTime(wall: Self.sleepingWall(), awake: MacTime.real.awake))
        let request = SpawnRequest(cwd: scratchRoot.path, command: "printf 'before\\n\\033]7599;stall\\007after\\n'; exec sleep 600",
                                   env: [:], cols: 80, rows: 24, keepShell: false, label: "Test", agent: nil)
        let session = try probe.queue.sync {
            let session = try HostedSession.spawn(request, shell: "/bin/sh", launcher: hostLauncher, baseEnvironment: ["PATH": "/usr/bin:/bin"],
                                                  ringCapacity: 1 << 20, queue: probe.queue,
                                                  parser: ParserOptions(stallLimit: 600, testHooks: true), timers: timers.timers)
            probe.attach(session)
            return session
        }
        defer { HostedSessionTimerTests().end(session, probe: probe, timers: timers) }
        // What the watchdog says when it replaces a parser; on the session's queue.
        let said = NSMutableArray()
        probe.queue.sync { session.onParserTrouble = { said.add($0) } }
        // The hook's bytes went to the parser, which never gets past them: it has work for good.
        #expect(await eventually { probe.text.contains("after") }, "\(probe.diagnosis(session))")
        let watchdog = try #require(timers.made(.parserWatchdog).first)
        timers.fire(watchdog)
        #expect(probe.queue.sync { said.count } == 0, "\(said)")
        #expect(probe.queue.sync { !watchdog.cancelled }, "the watchdog stopped: the parser had no work")
    }
}
