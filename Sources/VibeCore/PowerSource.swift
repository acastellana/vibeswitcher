import Foundation

/// The Mac's power source as the app reads it once a minute (IOKit, see `SystemPower.state`): on battery or on AC
/// power, the charge, and on battery the time the system estimates is left. On 2026-10-20 the Mac went on battery
/// three times in 12 hours while the lead ran merges and audits; the lead kept background `pmset` watches of its own
/// to pause and resume, which a lead after a handover wouldn't have. The witness tells a hold when the charge is under
/// the user's limit (see `PowerWatch`), and status says it's on battery while it lasts (from `file`, which the app
/// writes at each read).
public struct PowerState: Codable, Equatable, Sendable {
    public var onBattery: Bool
    /// The charge, 0–100.
    public var percent: Int
    public var charging: Bool
    /// On battery, the minutes left as the system estimates them; nil while it's still estimating (just unplugged).
    public var minutesLeft: Int?
    /// When it was read (seconds since 1970).
    public var at: Double

    public init(onBattery: Bool, percent: Int, charging: Bool = false, minutesLeft: Int? = nil, at: Double = Date().timeIntervalSince1970) {
        self.onBattery = onBattery
        self.percent = percent
        self.charging = charging
        self.minutesLeft = minutesLeft
        self.at = at
    }

    /// "On battery: 74 %, about 3:12 left" (the estimate left out while unknown); "On AC power: 80 %, charging".
    public var text: String {
        if onBattery { return "On battery: \(percent) %" + (minutesLeft.map { ", about \(Self.clock($0)) left" } ?? "") }
        return "On AC power: \(percent) %, \(charging ? "charging" : "not charging")"
    }

    /// The limit the witness told the leads the charge is under (see `PowerWatch`), as kept for status; nil while
    /// there's no hold.
    public var heldUnder: Int?

    /// Status's header: "on battery, 74 %", and while a hold lasts "on battery, 45 %, under your 50 % limit (no new
    /// starts or merges until AC power returns)"; nil on AC power.
    public var statusText: String? {
        guard onBattery else { return nil }
        return "on battery, \(percent) %" + (heldUnder.map { ", under your \($0) % limit (no new starts or merges until AC power returns)" } ?? "")
    }

    /// 192 → "3:12", 5 → "0:05".
    static func clock(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }

    /// Where the app keeps the last reading, for status (the lead's tool server runs in another process).
    public static var file: URL { VibePaths.root.appendingPathComponent("power.json") }

    /// A reading older than this is the app's from before it quit or the Mac slept: not told as now.
    public static let stale: TimeInterval = 5 * 60

    public func save(to url: URL = PowerState.file) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? VibePaths.writePrivate(data, to: url)
    }

    /// The app's last reading, unless it's `stale`; nil when there's none (a Mac without a battery, the app not running).
    public static func load(from url: URL = PowerState.file, now: Date = Date()) -> PowerState? {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(PowerState.self, from: data),
              now.timeIntervalSince1970 - state.at < stale else { return nil }
        return state
    }
}

/// When the lead holds its work on battery: only while the charge is under the user's limit (Settings, "On battery,
/// pause lead work below N %"; 0 never), not at every unplug. On 2026-10-20 the Mac was unplugged six times, mostly at
/// 85–100 %, and the witness told the lead to hold each time. A hold is told once: on battery under the limit (at the
/// first reading too), or the charge or a raised limit crossing it while on battery; AC power returning is told only
/// after a hold, and so is a limit lowered or turned off under one (the lead would wait on AC power for nothing). A
/// reading that fails changes nothing.
public struct PowerWatch: Equatable, Sendable {
    /// The limit in Settings until it's changed.
    public static let defaultLimit = 50
    /// The limits Settings offers besides 0 (never).
    public static let limits = 10...90

    /// What to tell the leads.
    public enum Event: Equatable, Sendable {
        /// On battery under `limit`: hold new starts, audits and merges.
        case hold(PowerState, limit: Int)
        /// AC power is back, or the limit was lowered under the charge or turned off (`limit`, 0), after a hold: resume.
        case resume(PowerState, limit: Int)
    }

    /// The limit a hold was told under; nil while there's none.
    public private(set) var heldUnder: Int?

    public init() {}

    /// A limit as kept: 0 (never) for 0 or less, else within `limits`.
    public static func clamp(_ limit: Int) -> Int { limit <= 0 ? 0 : min(max(limit, limits.lowerBound), limits.upperBound) }

    /// The event to tell now, if any, for `state` under `limit` (0: never hold).
    public mutating func check(_ state: PowerState?, limit: Int) -> Event? {
        guard let state else { return nil }
        let under = state.onBattery && limit > 0 && state.percent < limit
        guard let held = heldUnder else {
            guard under else { return nil }
            heldUnder = limit
            return .hold(state, limit: limit)
        }
        if !state.onBattery {
            heldUnder = nil
            return .resume(state, limit: limit)
        }
        // Still on battery: only the limit changing ends a hold, not the charge reading a point higher.
        if limit == held || under {
            heldUnder = limit
            return nil
        }
        heldUnder = nil
        return .resume(state, limit: limit)
    }
}
