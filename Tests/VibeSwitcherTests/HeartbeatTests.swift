import Foundation
import Testing
@testable import VibeSwitcher

/// The app's one clock wakes only on a second some client is due: with clients every 2 and 3 s (the scan, the lead
/// controller), at 2, 3, 4 and 6 s of the first 6, not every second; each client still runs on its own period.
struct HeartbeatTests {
    @Test @MainActor func itWakesOnlyWhenAClientIsDue() {
        let clock = Heartbeat()
        var twos: [Int] = [], threes: [Int] = []
        let started = Date()
        let seconds = { Int(Date().timeIntervalSince(started).rounded()) }
        let two = clock.every(2) { twos.append(seconds()) }
        let three = clock.every(3) { threes.append(seconds()) }
        RunLoop.main.run(until: started.addingTimeInterval(6.6))
        // On a loaded Mac a wake can come late (and a second be skipped), never early or extra.
        #expect(clock.wakes <= 4, "woke \(clock.wakes) times in 6 s")
        #expect(twos.allSatisfy { $0 % 2 == 0 } && threes.allSatisfy { $0 % 3 == 0 }, "every 2 s at \(twos), every 3 s at \(threes)")
        #expect(!twos.isEmpty && !threes.isEmpty)
        two.cancel()
        three.cancel()
    }

    @Test @MainActor func aClientAddedLaterRunsOnItsOwnPeriod() {
        let clock = Heartbeat()
        var ones = 0, fives = 0
        let five = clock.every(5) { fives += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let one = clock.every(1) { ones += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(2.6))
        #expect(ones >= 1 && ones <= 3, "every 1 s: \(ones) times in 2.6 s")
        #expect(fives == 0)
        one.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        #expect(fives == 1)
        five.cancel()
    }
}
