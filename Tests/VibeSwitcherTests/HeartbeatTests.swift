import Foundation
import Testing
@testable import VibeSwitcher

/// The app's one clock wakes only on a second some client is due: with clients every 2 and 3 s (the scan, the lead
/// controller), at 2, 3, 4 and 6 s of the first 6, not every second; each client still runs on its own period.
///
/// What's judged is taken by a timer on the main run loop at the window's end, not after `RunLoop.main.run(until:)`
/// returns: other @MainActor tests' jobs run nested inside that run and can keep it from returning for many seconds
/// (a merge's full suite once held it 30 s), while the clock went on waking. Timers fire in the order they were due,
/// so a wake after the window is never counted in it, however late the run loop gets to them.
struct HeartbeatTests {
    @Test @MainActor func itWakesOnlyWhenAClientIsDue() {
        let clock = Heartbeat()
        var twos: [Int] = [], threes: [Int] = []
        let started = Date()
        let seconds = { Int(Date().timeIntervalSince(started).rounded()) }
        let two = clock.every(2) { twos.append(seconds()) }
        let three = clock.every(3) { threes.append(seconds()) }
        var wakes = 0
        runMainLoop(until: started.addingTimeInterval(6.6)) {
            wakes = clock.wakes
            two.cancel()
            three.cancel()
        }
        // On a loaded Mac a wake can come late (and a second be skipped), never early or extra.
        #expect(wakes <= 4, "woke \(wakes) times in 6 s")
        #expect(twos.allSatisfy { $0 % 2 == 0 } && threes.allSatisfy { $0 % 3 == 0 }, "every 2 s at \(twos), every 3 s at \(threes)")
        #expect(!twos.isEmpty && !threes.isEmpty)
    }

    @Test @MainActor func aClientAddedLaterRunsOnItsOwnPeriod() {
        let clock = Heartbeat()
        var ones = 0, fives = 0
        let started = Date()
        let five = clock.every(5) { fives += 1 }
        var one: Heartbeat.Subscription?
        runMainLoop(until: started.addingTimeInterval(1.5)) { one = clock.every(1) { ones += 1 } }
        var onesSeen = 0, fivesSeen = 0
        runMainLoop(until: started.addingTimeInterval(4.1)) {
            onesSeen = ones
            fivesSeen = fives
            one?.cancel()
        }
        #expect(onesSeen >= 1 && onesSeen <= 3, "every 1 s: \(onesSeen) times in 2.6 s")
        #expect(fivesSeen == 0)
        runMainLoop(until: started.addingTimeInterval(5.6)) {
            fivesSeen = fives
            five.cancel()
        }
        #expect(fivesSeen == 1)
    }

    /// Runs the main run loop until `deadline`, where `atDeadline` runs from a timer on that loop (in every mode the
    /// clock's own timer runs in), then returns.
    @MainActor private func runMainLoop(until deadline: Date, _ atDeadline: @escaping () -> Void) {
        var done = false
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { atDeadline() }
            done = true
        }
        RunLoop.main.add(timer, forMode: .common)
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
}
