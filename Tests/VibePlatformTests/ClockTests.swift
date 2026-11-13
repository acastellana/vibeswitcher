import Foundation
import Testing
import VibePlatform

struct ClockTests {
    @Test func awakeSecondsNeverGoesBack() {
        var last = Platform.Clock.awakeSeconds()
        #expect(last > 0)
        for _ in 0..<1000 {
            let now = Platform.Clock.awakeSeconds()
            #expect(now >= last)
            last = now
        }
    }

    /// The clock moves: read until it says a later time than the first reading. The bound is on readings, not on
    /// time: a clock that stood still would use them all up.
    @Test func awakeSecondsMovesOn() {
        let first = Platform.Clock.awakeSeconds()
        var readings = 0
        while Platform.Clock.awakeSeconds() <= first, readings < 50_000_000 { readings += 1 }
        #expect(Platform.Clock.awakeSeconds() > first, "the same time after \(readings) readings")
    }

    /// The thread's CPU time grows by the work it does: summing until the clock says a millisecond more was used.
    /// The bound is on the work (far more than a millisecond's on any machine), not on time.
    @Test func threadCPUGrowsWithWork() {
        let started = Platform.Clock.threadCPUNanoseconds()
        var sum: UInt64 = 0, rounds = 0
        while Platform.Clock.threadCPUNanoseconds() < started + 1_000_000, rounds < 2_000_000 {
            for number in 0..<1000 { sum = sum &* 31 &+ UInt64(number) }
            rounds += 1
        }
        let used = Platform.Clock.threadCPUNanoseconds() - started
        #expect(used >= 1_000_000, "\(used) ns after \(rounds) rounds (sum \(sum))")
    }

    /// It is the calling thread's own: a thread that has just started has used less than this one, which has run
    /// the test so far and then worked a millisecond more.
    @Test func threadCPUIsTheCallingThreadsOwn() async {
        let started = Platform.Clock.threadCPUNanoseconds()
        var sum: UInt64 = 0, rounds = 0
        while Platform.Clock.threadCPUNanoseconds() < started + 1_000_000, rounds < 2_000_000 {
            for number in 0..<1000 { sum = sum &* 31 &+ UInt64(number) }
            rounds += 1
        }
        let here = Platform.Clock.threadCPUNanoseconds()
        let there: UInt64 = await withCheckedContinuation { done in
            let thread = Thread { done.resume(returning: Platform.Clock.threadCPUNanoseconds()) }
            thread.start()
        }
        #expect(here >= 1_000_000, "\(here) ns after \(rounds) rounds (sum \(sum))")
        #expect(there < here, "a new thread's \(there) ns against this one's \(here) ns")
    }

    /// `later` runs the work on the queue it is given, once the wait is over. The test waits on the work's signal;
    /// the semaphore's bound only ends a run whose work never comes.
    @Test func laterRunsTheWorkOnItsQueueAfterTheWait() {
        let queue = DispatchQueue(label: "ClockTests.later")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        let ran = DispatchSemaphore(value: 0)
        var onQueue = false, waited: TimeInterval = 0
        let started = Platform.Clock.awakeSeconds()
        Platform.Clock.later(0.05, on: queue) {
            onQueue = DispatchQueue.getSpecific(key: key) == true
            waited = Platform.Clock.awakeSeconds() - started
            ran.signal()
        }
        #expect(ran.wait(timeout: .now() + 60) == .success)
        #expect(onQueue)
        #expect(waited >= 0.049, "ran after \(waited) s")
    }
}
