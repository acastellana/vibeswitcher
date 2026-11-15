import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The engine's one clock wakes only on a second some client is due: with clients every 2 and 3 s (the scan, the
/// refresh), at 2, 3, 4 and 6 s of the first 6, not every second; each client still runs on its own period. The app's
/// `HeartbeatTests`, both cases, on a clock the test drives second by second (`DrivenTime`) instead of the main run loop.
struct NodeClockTests {
    @Test func itWakesOnlyWhenAClientIsDue() {
        let time = DrivenTime()
        let clock = time.clock()
        var twos: [Int] = [], threes: [Int] = []
        let two = clock.every(2) { twos.append(time.second) }
        let three = clock.every(3) { threes.append(time.second) }
        time.run(until: 6.6)
        #expect(time.wokeAt == [2, 3, 4, 6], "woke at \(time.wokeAt)")
        #expect(clock.wakes == 4, "woke \(clock.wakes) times in 6 s")
        #expect(twos == [2, 4, 6] && threes == [3, 6], "every 2 s at \(twos), every 3 s at \(threes)")
        two.cancel()
        three.cancel()
        #expect(time.armed == nil, "a clock with no client still has a wake armed")
    }

    @Test func aClientAddedLaterRunsOnItsOwnPeriod() {
        let time = DrivenTime()
        let clock = time.clock()
        var ones = 0, fives = 0
        let five = clock.every(5) { fives += 1 }
        time.run(until: 1.5)
        let one = clock.every(1) { ones += 1 }
        time.run(until: 4.1)
        #expect(ones >= 1 && ones <= 3, "every 1 s: \(ones) times in 2.6 s")
        #expect(ones == 3 && time.wokeAt == [2, 3, 4], "woke at \(time.wokeAt)")
        #expect(fives == 0)
        one.cancel()
        time.run(until: 5.6)
        #expect(fives == 1)
        five.cancel()
    }

    /// A wake that comes late (its queue busy) still runs the clients due on the second it was armed for, and only
    /// those: none a second early, and none of a second it came too late for left out.
    @Test func aLateWakeRunsTheSecondItWasArmedFor() {
        let time = DrivenTime()
        let clock = time.clock()
        var twos: [Double] = [], threes: [Double] = []
        let two = clock.every(2) { twos.append(time.elapsed) }
        let three = clock.every(3) { threes.append(time.elapsed) }
        // The wake for second 2 runs at 2.6 s.
        time.hold(until: 2.6)
        time.run(until: 6.5)
        #expect(twos == [2.6, 4, 6] && threes == [3, 6], "every 2 s at \(twos), every 3 s at \(threes)")
        two.cancel()
        three.cancel()

        // Later than the next due second: the wake for 2 at 3.4 s runs both, once each.
        let late = DrivenTime()
        let lateClock = late.clock()
        var lateTwos: [Double] = [], lateThrees: [Double] = []
        let lateTwo = lateClock.every(2) { lateTwos.append(late.elapsed) }
        let lateThree = lateClock.every(3) { lateThrees.append(late.elapsed) }
        late.hold(until: 3.4)
        late.run(until: 6.5)
        #expect(lateTwos == [3.4, 4, 6] && lateThrees == [3.4, 6], "every 2 s at \(lateTwos), every 3 s at \(lateThrees)")
        lateTwo.cancel()
        lateThree.cancel()
    }

    /// A client that subscribes after a second has come but before its wake has run takes nothing from the clients
    /// already there: that second still runs.
    @Test func aClientAddedWhileAWakeIsPendingLosesNoSecond() {
        let time = DrivenTime()
        let clock = time.clock()
        var twos: [Double] = [], sixties = 0
        let two = clock.every(2) { twos.append(time.elapsed) }
        time.hold(until: 2.05)
        let sixty = clock.every(60) { sixties += 1 }
        time.run(until: 4.5)
        #expect(twos == [2.05, 4], "every 2 s at \(twos)")
        #expect(sixties == 0)
        two.cancel()
        sixty.cancel()
    }

    /// The clock's own timer (a `DispatchSourceTimer`, no run loop) runs a client on the queue it was given.
    @Test func theRealClockRunsItsClientsOnItsQueue() async {
        let queue = DispatchQueue(label: "node-clock-test")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        let clock = NodeClock(queue: queue)
        let ran = Ran()
        let client = clock.every(1) { ran.note(onQueue: DispatchQueue.getSpecific(key: key) == true) }
        #expect(await eventually { ran.count > 0 })
        client.cancel()
        #expect(ran.allOnQueue, "a client ran off the clock's queue")
    }

    private final class Ran: @unchecked Sendable {
        private let lock = NSLock()
        private var runs: [Bool] = []
        func note(onQueue: Bool) { lock.withLock { runs.append(onQueue) } }
        var count: Int { lock.withLock { runs.count } }
        var allOnQueue: Bool { lock.withLock { runs.allSatisfy { $0 } } }
    }
}

/// A clock's time, driven by the test: `now` is what the test set, and the one wake the clock arms fires when the test
/// moves time past it (`run(until:)`).
final class DrivenTime: @unchecked Sendable {
    private(set) var now: TimeInterval = 100
    private let start: TimeInterval = 100
    /// The wake the clock armed: when, by `now`, and what it calls. Nil: none armed.
    private(set) var armed: (at: TimeInterval, fire: () -> Void)?
    /// The seconds (from the start) at which the clock woke.
    private(set) var wokeAt: [Int] = []

    /// The whole seconds since the start.
    var second: Int { Int((now - start).rounded()) }

    func clock() -> NodeClock {
        NodeClock(queue: DispatchQueue(label: "driven-clock"), now: { [unowned self] in now }) { [unowned self] seconds, fire in
            let at = now + seconds
            armed = (at, fire)
            return { [weak self] in
                if self?.armed?.at == at { self?.armed = nil }
            }
        }
    }

    /// The seconds since the start, to the hundredth (what a client late by a fraction of a second sees).
    var elapsed: Double { ((now - start) * 100).rounded() / 100 }

    /// Moves time on to `seconds` after the start without firing anything: the clock's queue is busy meanwhile, so a
    /// wake due on the way runs late, at the next `run(until:)`.
    func hold(until seconds: TimeInterval) {
        now = start + seconds
    }

    /// Moves time on to `seconds` after the start, firing each wake the clock arms on the way, at the time it was armed
    /// for (or now, for one that was due while time was held).
    func run(until seconds: TimeInterval) {
        let end = start + seconds
        while let wake = armed, wake.at <= end {
            now = max(now, wake.at)
            armed = nil
            wokeAt.append(second)
            wake.fire()
        }
        now = end
    }
}
