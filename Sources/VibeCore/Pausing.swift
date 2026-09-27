import Foundation

/// Sessions you've parked: greyed out everywhere, no notifications or reminders, their waiting not
/// counted against you. Kept per session key (process and session id, like custom names), so a pause
/// survives app restarts and `--resume`.
public final class PauseStore {
    public enum Duration: Equatable, Sendable {
        case indefinitely
        case hours(Double)
        case untilTomorrowMorning
    }

    private let defaults: UserDefaults
    private let key = "pausedSessions"
    /// Session key → end of the pause (`distantFuture`: until resumed).
    private var pauses: [String: Date]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pauses = (defaults.dictionary(forKey: key) as? [String: Date]) ?? [:]
    }

    /// When the pause on these keys ends, if one is active.
    public func pausedUntil(for keys: [String], now: Date = Date()) -> Date? {
        keys.lazy.compactMap { self.pauses[$0] }.first { $0 > now }
    }

    public func pause(_ keys: [String], for duration: Duration, now: Date = Date(), calendar: Calendar = .current) {
        let end: Date
        switch duration {
        case .indefinitely: end = .distantFuture
        case .hours(let hours): end = now.addingTimeInterval(hours * 3600)
        case .untilTomorrowMorning: end = Self.nextMorning(after: now, calendar: calendar)
        }
        for key in keys { pauses[key] = end }
        save()
    }

    public func resume(_ keys: [String]) {
        for key in keys { pauses[key] = nil }
        save()
    }

    /// Drops ended pauses, and process keys whose process is gone (session-id keys stay for `--resume`).
    public func prune(liveKeys: Set<String>, now: Date = Date()) {
        let stale = pauses.filter { $0.value <= now || ($0.key.hasPrefix("proc:") && !liveKeys.contains($0.key)) }
        guard !stale.isEmpty else { return }
        stale.keys.forEach { pauses[$0] = nil }
        save()
    }

    /// 9:00 the next morning; after midnight but before 5:00, "tomorrow" means this morning.
    public static func nextMorning(after now: Date, calendar: Calendar = .current, hour: Int = 9) -> Date {
        let today = calendar.startOfDay(for: now)
        let morningDay = calendar.component(.hour, from: now) < 5 ? today : calendar.date(byAdding: .day, value: 1, to: today)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: morningDay)!
    }

    private func save() {
        defaults.set(pauses, forKey: key)
    }
}
