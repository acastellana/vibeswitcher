import Foundation

/// The Mac's power source as the app reads it once a minute (IOKit, see `SystemPower.state`): on battery or on AC
/// power, the charge, and on battery the time the system estimates is left. On 2026-10-20 the Mac went on battery
/// three times in 12 hours while the lead ran merges and audits; the lead kept background `pmset` watches of its own
/// to pause and resume, which a lead after a handover wouldn't have. The witness tells each switch, and status says
/// it while it's on battery (from `file`, which the app writes at each read).
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

    /// Status's header: "on battery, 74 %"; nil on AC power (nothing to hold back).
    public var statusText: String? { onBattery ? "on battery, \(percent) %" : nil }

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

/// Each switch between battery and AC power, told once: nothing while the source stays the same. The first reading
/// is told only when it's on battery (the lead can't know that otherwise); a reading that fails changes nothing.
public struct PowerWatch: Equatable, Sendable {
    /// On battery at the last reading; nil before the first.
    public private(set) var onBattery: Bool?

    public init() {}

    /// The reading to tell now, if any.
    public mutating func check(_ state: PowerState?) -> PowerState? {
        guard let state else { return nil }
        defer { onBattery = state.onBattery }
        guard let before = onBattery else { return state.onBattery ? state : nil }
        return before == state.onBattery ? nil : state
    }
}
