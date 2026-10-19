import Foundation

/// How often a time on screen ("Working · 12m", "Going with A in 8 min") is drawn again. Every second only while the
/// seconds are what it shows, its first minute since a start or its last minute before a deadline, and never with
/// Reduce Motion or VoiceOver on (a number changing every second is motion, and VoiceOver reads it out again);
/// otherwise once a minute. Ticks fall on the start's or the deadline's own seconds and minutes, a hair after them,
/// so the text has turned over ("59s" to "1m") when it's drawn.
public enum ElapsedTicks {
    /// How far past the turn of a second or minute a tick lands: the text drawn then is the new one.
    static let margin: TimeInterval = 0.005

    /// Seconds between redraws of a time `elapsed` seconds since its start.
    public static func interval(elapsed: TimeInterval, reduceMotion: Bool, voiceOverRunning: Bool) -> TimeInterval {
        elapsed < 60 && !reduceMotion && !voiceOverRunning ? 1 : 60
    }

    /// Seconds between redraws of a countdown with `remaining` seconds to its deadline: the last minute is per second
    /// (from the tick at 1:00 on).
    public static func interval(remaining: TimeInterval, reduceMotion: Bool, voiceOverRunning: Bool) -> TimeInterval {
        remaining <= 60 && !reduceMotion && !voiceOverRunning ? 1 : 60
    }

    /// When a time counted from `start` is drawn next after `now`.
    public static func next(after now: Date, since start: Date, reduceMotion: Bool, voiceOverRunning: Bool) -> Date {
        let elapsed = now.timeIntervalSince(start)
        let step = interval(elapsed: max(0, elapsed), reduceMotion: reduceMotion, voiceOverRunning: voiceOverRunning)
        // The next whole step after now (a start in the future: its first one); one more if rounding put it on now.
        let turns = max(1, ((elapsed - margin) / step).rounded(.down) + 1)
        let tick = start.addingTimeInterval(turns * step + margin)
        return tick > now ? tick : tick.addingTimeInterval(step)
    }

    /// When a countdown to `deadline` is drawn next after `now`; once it has run out, once a minute (nothing changes).
    public static func next(after now: Date, until deadline: Date, reduceMotion: Bool, voiceOverRunning: Bool) -> Date {
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return now.addingTimeInterval(60) }
        let step = interval(remaining: remaining, reduceMotion: reduceMotion, voiceOverRunning: voiceOverRunning)
        // The next whole step down from what's left (just under it: its tick is still ahead).
        let left = ((remaining + margin) / step).rounded(.up) - 1
        let tick = deadline.addingTimeInterval(-left * step + margin)
        return tick > now ? tick : tick.addingTimeInterval(step)
    }

    /// When a view whose items fade out between `fadeStart` and `fadeEnd` is drawn next: every second during the fade,
    /// from its first second, and never with Reduce Motion on (nothing fades then); otherwise every `base` seconds, on
    /// the clock's own multiples of it (as `ticking(every:)`).
    public static func next(after now: Date, every base: TimeInterval, fadingFrom fadeStart: Date?, until fadeEnd: Date?,
                            reduceMotion: Bool) -> Date {
        let reference = now.timeIntervalSinceReferenceDate
        let tick = Date(timeIntervalSinceReferenceDate: ((reference / base).rounded(.down) + 1) * base)
        guard !reduceMotion, let fadeStart, let fadeEnd, now < fadeEnd else { return tick }
        if now < fadeStart { return min(tick, fadeStart) }
        let second = fadeStart.addingTimeInterval(now.timeIntervalSince(fadeStart).rounded(.down) + 1)
        return min(tick, second > now ? second : second.addingTimeInterval(1))
    }
}
