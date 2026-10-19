import Foundation
import Testing
@testable import VibeCore

/// An elapsed time on screen is drawn again every second only in its first minute, and only with neither Reduce
/// Motion nor VoiceOver on; after that (or with either on) once a minute, on the minute it turns over.
struct ElapsedTicksTests {
    @Test func perSecondOnlyInTheFirstMinuteWithNeitherSettingOn() {
        #expect(ElapsedTicks.interval(elapsed: 0, reduceMotion: false, voiceOverRunning: false) == 1)
        #expect(ElapsedTicks.interval(elapsed: 59, reduceMotion: false, voiceOverRunning: false) == 1)
        #expect(ElapsedTicks.interval(elapsed: 59.9, reduceMotion: false, voiceOverRunning: false) == 1)
        #expect(ElapsedTicks.interval(elapsed: 60, reduceMotion: false, voiceOverRunning: false) == 60)
        #expect(ElapsedTicks.interval(elapsed: 61, reduceMotion: false, voiceOverRunning: false) == 60)
        #expect(ElapsedTicks.interval(elapsed: 26 * 3600, reduceMotion: false, voiceOverRunning: false) == 60)
    }

    @Test func neverPerSecondUnderReduceMotionOrVoiceOver() {
        for elapsed: TimeInterval in [0, 59, 60, 61] {
            #expect(ElapsedTicks.interval(elapsed: elapsed, reduceMotion: true, voiceOverRunning: false) == 60)
            #expect(ElapsedTicks.interval(elapsed: elapsed, reduceMotion: false, voiceOverRunning: true) == 60)
            #expect(ElapsedTicks.interval(elapsed: elapsed, reduceMotion: true, voiceOverRunning: true) == 60)
        }
    }

    /// The ticks fall on the start's own seconds and minutes (a hair after, so "59s" turns into "1m" at the tick).
    @Test func ticksLandJustAfterTheStartsWholeSecondsThenMinutes() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000.37)
        func next(_ elapsed: TimeInterval, reduceMotion: Bool = false, voiceOver: Bool = false) -> TimeInterval {
            ElapsedTicks.next(after: start.addingTimeInterval(elapsed), since: start,
                              reduceMotion: reduceMotion, voiceOverRunning: voiceOver).timeIntervalSince(start)
        }
        #expect(abs(next(0) - 1) < 0.01)
        #expect(abs(next(12.5) - 13) < 0.01)
        #expect(abs(next(58.2) - 59) < 0.01)
        #expect(abs(next(59.2) - 60) < 0.01)
        #expect(abs(next(60.2) - 120) < 0.01)
        #expect(abs(next(61) - 120) < 0.01)
        #expect(abs(next(3_599) - 3_600) < 0.01)
        // Either setting: from the first second, minutes only.
        #expect(abs(next(0, reduceMotion: true) - 60) < 0.01)
        #expect(abs(next(59, voiceOver: true) - 60) < 0.01)
        #expect(abs(next(61, voiceOver: true) - 120) < 0.01)
        // The text drawn at each tick has already turned over.
        for elapsed: TimeInterval in [0, 0.5, 58.2, 59.2, 60.2, 119.999, 3_599.4] {
            let tick = next(elapsed)
            #expect(tick > elapsed)
            #expect(Durations.short(tick) != Durations.short(tick - 0.02), "tick at \(tick) s")
        }
    }

    /// A countdown (the lead's "Going with A in 8 min"): per second only in its last minute, from the tick at 1:00 on.
    @Test func aCountdownIsPerSecondOnlyInItsLastMinute() {
        #expect(ElapsedTicks.interval(remaining: 59, reduceMotion: false, voiceOverRunning: false) == 1)
        #expect(ElapsedTicks.interval(remaining: 60, reduceMotion: false, voiceOverRunning: false) == 1)
        #expect(ElapsedTicks.interval(remaining: 61, reduceMotion: false, voiceOverRunning: false) == 60)
        #expect(ElapsedTicks.interval(remaining: 480, reduceMotion: false, voiceOverRunning: false) == 60)
        for remaining: TimeInterval in [1, 59, 60, 61] {
            #expect(ElapsedTicks.interval(remaining: remaining, reduceMotion: true, voiceOverRunning: false) == 60)
            #expect(ElapsedTicks.interval(remaining: remaining, reduceMotion: false, voiceOverRunning: true) == 60)
        }
    }

    /// Its ticks fall a hair after the deadline's whole minutes, then seconds, so "in 8 min" turns to "in 7 min" at a
    /// tick (the countdown rounds up what's left).
    @Test func countdownTicksLandOnTheDeadlinesMinutesThenSeconds() {
        let deadline = Date(timeIntervalSinceReferenceDate: 50_000.61)
        func next(_ remaining: TimeInterval, reduceMotion: Bool = false, voiceOver: Bool = false) -> TimeInterval {
            deadline.timeIntervalSince(ElapsedTicks.next(after: deadline.addingTimeInterval(-remaining), until: deadline,
                                                         reduceMotion: reduceMotion, voiceOverRunning: voiceOver))
        }
        // On the whole minute itself, its tick is still 5 ms ahead; just past it, the next minute's.
        #expect(abs(next(480) - 480) < 0.01)
        #expect(abs(next(479.99) - 420) < 0.01)
        #expect(abs(next(479.9) - 420) < 0.01)
        #expect(abs(next(125) - 120) < 0.01)
        #expect(abs(next(61) - 60) < 0.01)
        #expect(abs(next(60.5) - 60) < 0.01)
        #expect(abs(next(60) - 60) < 0.01)
        #expect(abs(next(59.99) - 59) < 0.01)
        #expect(abs(next(59.5) - 59) < 0.01)
        #expect(abs(next(1.5) - 1) < 0.01)
        #expect(abs(next(0.5) - 0) < 0.01)
        // Either setting: minutes to the end.
        #expect(abs(next(61, reduceMotion: true) - 60) < 0.01)
        #expect(abs(next(60, voiceOver: true) - 60) < 0.01)
        #expect(abs(next(59.99, voiceOver: true) - 0) < 0.01)
        #expect(abs(next(59, reduceMotion: true) - 0) < 0.01)
        // Run out: nothing changes any more, once a minute is plenty.
        #expect(abs(next(-5) - -65) < 0.01)
        // Each tick is ahead of now, and it lands just under the whole minute or second.
        for remaining: TimeInterval in [480, 419.996, 300.0049, 60.001, 59.995, 0.002] {
            let tick = next(remaining)
            #expect(tick < remaining)
            #expect(tick == tick.rounded(.up) - 0.005 || abs(tick - (tick.rounded(.up) - 0.005)) < 0.0001, "tick at \(tick) s left")
        }
    }

    /// A start in the future (clocks disagreeing a little) or the far past still gives a tick after now.
    @Test func theNextTickIsAlwaysAfterNow() {
        let now = Date()
        for offset: TimeInterval in [-3, 0, 0.0005, 30, 7_200, 86_400 * 40] {
            let start = now.addingTimeInterval(-offset)
            let tick = ElapsedTicks.next(after: now, since: start, reduceMotion: false, voiceOverRunning: false)
            #expect(tick > now)
            #expect(tick.timeIntervalSince(now) <= 60.01)
        }
    }

    /// The Team view's fading decisions: drawn every second only while one fades, never with Reduce Motion; otherwise
    /// every 10 s on the clock's multiples of 10.
    @Test func aFadeIsPerSecondOnlyWhileItFades() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_003.4)
        let end = start.addingTimeInterval(60)
        func next(_ offset: TimeInterval, reduceMotion: Bool = false, fade: Bool = true) -> TimeInterval {
            ElapsedTicks.next(after: start.addingTimeInterval(offset), every: 10, fadingFrom: fade ? start : nil,
                              until: fade ? end : nil, reduceMotion: reduceMotion).timeIntervalSince(start)
        }
        // Before the fade: every 10 s (1_000_000, 1_000_010, …), and the fade's first second on time.
        #expect(abs(next(-30) - -23.4) < 0.001)
        #expect(abs(next(-2) - 0) < 0.001)
        // During it: every second, from its start.
        #expect(abs(next(0) - 1) < 0.001)
        #expect(abs(next(0.5) - 1) < 0.001)
        #expect(abs(next(30.2) - 31) < 0.001)
        #expect(abs(next(59.5) - 60) < 0.001)
        // After it, without one, or with Reduce Motion: every 10 s.
        #expect(abs(next(60) - 66.6) < 0.001)
        #expect(abs(next(30.2, fade: false) - 36.6) < 0.001)
        #expect(abs(next(30.2, reduceMotion: true) - 36.6) < 0.001)
        #expect(abs(next(-2, reduceMotion: true) - 6.6) < 0.001)
    }
}

