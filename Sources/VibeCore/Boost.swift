import Foundation

/// Boost mode (Settings › Project lead): higher Mac-wide limits while the user wants throughput more than a calm Mac.
/// The load study (2026-10-28 to 11-01) found freezes and suite time bend at load 24, throughput peaking around 36–48
/// and falling past 48, and going from ~4 to ~10 sessions gave about +50 % merges, mostly model wait rather than builds:
/// so boost raises load_threshold to 36, mac_max_sessions to 18 and max_workers to 7 per project, and leaves heavy_slots
/// at 3. Automatic boosts only while the Mac is on AC power and the user is away, so they don't feel the freezes. On
/// battery it's off whatever the mode, unless Settings' "Also on battery" is on (2026-11-02, the user's ask): then On
/// and Automatic work on battery as on AC until the charge drops below `Boost.batteryFloor` (30 %), so a boosted Mac
/// doesn't drain an unattended battery flat; the usage veto, the away rule and the leads' battery hold still apply.
///
/// The app decides (it has the power source, the user's presence and the usage watch) and keeps what it decided in
/// `~/.vibeswitcher/boost.json` (`BoostState`), rewritten at each change and at least every `BoostState.refresh`; every
/// project's lead tool server reads it with the Mac-wide limits at each call (`MacLimits.current`). A file older than
/// `BoostState.staleAfter` (the app quit or hung) is boost off: the normal limits hold.
public enum BoostMode: String, CaseIterable, Codable, Sendable {
    case off, on, automatic

    public var label: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .automatic: return "Automatic"
        }
    }
}

/// The limits boost raises the Mac-wide ones to (each editable in Settings). Heavy jobs share heavy_slots: each caps
/// its own parallelism to VS_HEAVY_CORES, the cores ÷ heavy_slots that vs-heavy gives it (4 on 12 cores), or one test
/// run on 9 cores and a build beside it fill the Mac inside the lock (2026-11-01: load 62 with 3 slots held).
public struct BoostLimits: Codable, Equatable, Sendable {
    public static let defaultLoadThreshold = 36.0
    public static let defaultMaxSessions = 18
    public static let defaultMaxWorkers = 7
    public static let defaultHeavySlots = 3

    /// The load (the greater of the 1- and 5-minute averages) above which leads start nothing while boosted.
    public var loadThreshold: Double
    /// Team sessions of every project at once while boosted.
    public var maxSessions: Int
    /// Workers per project at once while boosted (a project's own max_workers when that's higher).
    public var maxWorkers: Int
    /// Test runs at once (merges, audits, `vs-heavy`) while boosted (a project's own heavy_slots when that's higher).
    public var heavySlots: Int

    public init(loadThreshold: Double = BoostLimits.defaultLoadThreshold, maxSessions: Int = BoostLimits.defaultMaxSessions,
                maxWorkers: Int = BoostLimits.defaultMaxWorkers, heavySlots: Int = BoostLimits.defaultHeavySlots) {
        self.loadThreshold = loadThreshold.isFinite && loadThreshold > 0 ? min(loadThreshold, Self.loadCeiling) : Self.defaultLoadThreshold
        self.maxSessions = min(max(1, maxSessions), Self.countCeiling)
        self.maxWorkers = min(max(1, maxWorkers), Self.countCeiling)
        self.heavySlots = min(max(1, heavySlots), Self.slotCeiling)
    }

    /// The most each may be, in Settings and as read from boost.json (which a session could write if the rules
    /// refusing it failed): a load of 4× the cores, 4× the cores in sessions or workers, a slot per core.
    public static var loadCeiling: Double { Double(4 * MacLoad.processors) }
    public static var countCeiling: Int { 4 * MacLoad.processors }
    public static var slotCeiling: Int { max(1, MacLoad.processors) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(loadThreshold: (try? container.decodeIfPresent(Double.self, forKey: .loadThreshold)) ?? Self.defaultLoadThreshold,
                  maxSessions: (try? container.decodeIfPresent(Int.self, forKey: .maxSessions)) ?? Self.defaultMaxSessions,
                  maxWorkers: (try? container.decodeIfPresent(Int.self, forKey: .maxWorkers)) ?? Self.defaultMaxWorkers,
                  heavySlots: (try? container.decodeIfPresent(Int.self, forKey: .heavySlots)) ?? Self.defaultHeavySlots)
    }

    /// "load_threshold 36, mac_max_sessions 18, max_workers 7, heavy_slots 3".
    public var text: String {
        "load_threshold \(MacLoad.number(loadThreshold)), mac_max_sessions \(maxSessions), max_workers \(maxWorkers), heavy_slots \(heavySlots)"
    }
}

/// What the app decided about boost, for every lead: kept in `~/.vibeswitcher/boost.json`.
public struct BoostState: Codable, Equatable, Sendable {
    /// Boost is on now.
    public var on: Bool
    /// Why, as the parenthesis of `text`: "automatic: away, on AC", "automatic: you're at the Mac".
    public var why: String
    /// The limits in force while on.
    public var limits: BoostLimits
    /// The project the user last worked in (its root, standardized): while boosted, it gets first claim on room freed
    /// on the Mac (see `LeadWitness.RoomWaits.heldFor`).
    public var favored: String?
    /// When the app wrote it (seconds since 1970).
    public var at: Double

    public init(on: Bool, why: String, limits: BoostLimits = BoostLimits(), favored: String? = nil, at: Double = Date().timeIntervalSince1970) {
        self.on = on
        self.why = why
        self.limits = limits
        self.favored = favored.map { ($0 as NSString).standardizingPath }
        self.at = at
    }

    /// "boost: on (automatic: away, on AC)".
    public var text: String { "boost: \(on ? "on" : "off") (\(why))" }

    public static var file: URL { VibePaths.root.appendingPathComponent("boost.json") }
    /// How often the app rewrites the file while nothing changes, so a reader can tell it's still deciding.
    public static let refresh: TimeInterval = 60
    /// A file older than this is boost off: the app quit, or is hung, and no one watches the power or the user.
    public static let staleAfter: TimeInterval = 150

    /// What the app last decided; nil when there's no file, it can't be read, or it's older than `staleAfter`.
    public static func load(from file: URL = file, now: Date = Date()) -> BoostState? {
        guard let state = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode(BoostState.self, from: $0) }),
              now.timeIntervalSince1970 - state.at <= staleAfter, state.at <= now.timeIntervalSince1970 + staleAfter else { return nil }
        return state
    }

    /// The boost in force now: `load`'s when it's on, else nil.
    public static func active(from file: URL = file, now: Date = Date()) -> BoostState? {
        load(from: file, now: now).flatMap { $0.on ? $0 : nil }
    }

    /// Writes it (0600).
    public func save(to file: URL = BoostState.file) throws {
        try VibePaths.ensurePrivate(file.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try VibePaths.writePrivate(try encoder.encode(self), to: file)
    }

    /// The same decision (on, why, limits, project), whenever written.
    public func sameAs(_ other: BoostState?) -> Bool {
        guard let other else { return false }
        return on == other.on && why == other.why && limits == other.limits && favored == other.favored
    }
}

public enum Boost {
    /// At this share of an every-model usage limit (in percent) the usage watch keeps boost off: boost spends the
    /// account faster, so it stops before the leads' own back-off at `AccountUsage.threshold`.
    public static let vetoPercent = 70.0

    /// The usage limit that keeps boost off now: the most used every-model limit at or past `vetoPercent`; nil when
    /// none is (or none is known: unknown usage holds nothing back).
    public static func veto(_ usage: AccountUsage, now: Date = Date()) -> AccountUsage.Limit? {
        usage.hold(model: nil, now: now, threshold: vetoPercent)
    }

    /// With "Also on battery" (Settings), boost on battery stops when the charge is below this (in percent), so a
    /// boosted Mac doesn't drain an unattended battery flat.
    public static let batteryFloor = 30

    /// Whether boost is on, and why: `mode` as set, `onAC` the power source (nil: not read yet, taken as battery),
    /// `away` the user not at the Mac (see the app's `UserPresence`), `veto` the usage watch's (`veto(_:)`),
    /// `onBattery` Settings' "Also on battery", `percent` the charge (nil: not known). Without `onBattery` never on
    /// battery; with it, battery at `batteryFloor` % or more counts as AC, and below it (or the charge unknown) boost
    /// stays off. A veto is said only when boost would otherwise be on.
    public static func decide(mode: BoostMode, onAC: Bool?, away: Bool, veto: AccountUsage.Limit?,
                              onBattery: Bool = false, percent: Int? = nil, now: Date = Date()) -> (on: Bool, why: String) {
        // Power: whether it allows boost, and what to say ("on AC", "on battery (allowed, 86%)", or why not).
        let power: (ok: Bool, text: String)
        switch onAC {
        case true?: power = (true, "on AC")
        case nil: power = (false, "power source not known yet")
        case false?:
            if !onBattery { power = (false, "on battery") }
            else if let percent, percent >= batteryFloor { power = (true, "on battery (allowed, \(percent)%)") }
            else {
                let charge = percent.map { "on battery at \($0)%" } ?? "on battery, charge not known"
                power = (false, "\(charge): boost on battery stops below \(batteryFloor)%")
            }
        }
        switch mode {
        case .off:
            return (false, "off in Settings")
        case .on:
            guard power.ok else {
                guard onBattery else { return (false, "on in Settings, but \(power.text): boost never runs on battery") }
                return (false, onAC == nil ? "on in Settings, but \(power.text)" : "on in Settings, \(power.text)")
            }
            if let veto { return (false, vetoText(veto, now: now)) }
            return (true, "on in Settings, \(power.text)")
        case .automatic:
            var not: [String] = []
            if !power.ok { not.append(power.text) }
            if !away { not.append("you're at the Mac") }
            guard !not.isEmpty else {
                if let veto { return (false, vetoText(veto, now: now)) }
                return (true, "automatic: away, \(power.text)")
            }
            return (false, "automatic: " + not.joined(separator: ", "))
        }
    }

    /// The project a session's folder is in, as the leads' room waits name it: a task's worktree's repository, else
    /// the nearest folder up from it holding `.git`, else the folder itself. Reads the disk: off the main thread.
    public static func projectRoot(of folder: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let path = (folder as NSString).standardizingPath
        if let root = LeadTeams.root(ofWorktree: path + "/") { return root }
        var current = path
        while current != "/", !current.isEmpty {
            if exists((current as NSString).appendingPathComponent(".git")) { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return path
    }

    /// "held off by the usage watch: the weekly limit (every model): 74% used, resets …".
    static func vetoText(_ limit: AccountUsage.Limit, now: Date) -> String {
        "held off by the usage watch: \(limit.text)"
    }
}

extension MacLimits {
    /// The limits in force: these, raised to `boost`'s while it's on (never lowered: a normal limit set higher stays).
    public func boosted(by boost: BoostState?) -> MacLimits {
        guard let boost, boost.on else { return self }
        var raised = MacLimits(maxSessions: max(maxSessions, boost.limits.maxSessions),
                               loadThreshold: max(loadLimit, boost.limits.loadThreshold), heavySlots: heavySlots)
        raised.boost = boost
        raised.normal = Normal(maxSessions: maxSessions, loadLimitText: loadLimitText)
        return raised
    }

    /// The limits in force now, as every lead's tool server reads them at each call: Settings' (`load`), boosted when
    /// the app says boost is on (`BoostState.active`).
    public static func current(file: URL = MacLimits.file, boostFile: URL = BoostState.file, now: Date = Date()) -> MacLimits {
        load(from: file).boosted(by: BoostState.active(from: boostFile, now: now))
    }

    /// A project's max_workers in force: its own, raised to boost's while on.
    public func maxWorkers(_ own: Int) -> Int { boost.map { max(own, $0.limits.maxWorkers) } ?? own }

    /// The heavy slots in force: `own` (a project's heavy_slots, or VIBESWITCHER_HEAVY_SLOTS) else Settings'
    /// (`heavySlots`), raised to boost's while on. One count for every reader: the leads' merges and audits, `vs-heavy`
    /// (Resources/bin/vs-heavy reads the same two files the same way) and the load recorder (`TestLock.slotCount`).
    public func heavySlotsInForce(_ own: Int? = nil) -> Int {
        let base = own.map { max(1, $0) } ?? heavySlots
        return boost.map { max(base, $0.limits.heavySlots) } ?? base
    }

    /// mac_max_sessions as said to a lead: "18 while boosted (15 normally)", or "15".
    public var maxSessionsText: String {
        guard let normal, normal.maxSessions != maxSessions else { return "\(maxSessions)" }
        return "\(maxSessions) while boosted (\(normal.maxSessions) normally)"
    }
}
