import Foundation

// Public makers of `SetupStats`' values (their memberwise initializers are internal, and an extension can't redeclare
// them), so the app can make one of its own: the sandbox's made-up statistics. They only set the fields.

extension SetupStats {
    public static func make(range: DateInterval, at: Date, projects: [Project], total: ProjectFigures?, mac: MacWide,
                            quality: SetupQuality? = nil) -> Self {
        Self(range: range, at: at, projects: projects, total: total, mac: mac, quality: quality)
    }
}

extension SetupStats.Project {
    public static func make(name: String, root: String, hasArchive: Bool, figures: ProjectFigures?) -> Self {
        Self(name: name, root: root, hasArchive: hasArchive, figures: figures)
    }
}

extension SetupStats.MacWide {
    public static func make(load: LoadProfile? = nil, merges: MergeRate? = nil, freezes: Freezes? = nil, hoursBoosted: Double? = nil,
                            boostNow: BoostState? = nil, claude: [UsageNow]? = nil, codex: [UsageNow]? = nil, codexTokens: Int? = nil) -> Self {
        Self(load: load, merges: merges, freezes: freezes, hoursBoosted: hoursBoosted, boostNow: boostNow, claude: claude, codex: codex, codexTokens: codexTokens)
    }
}

extension ProjectFigures.Flakes {
    public static func make(flakes: Int, tests: Int, merges: Int) -> Self {
        Self(flakes: flakes, tests: tests, merges: merges)
    }
}

extension LoadProfile {
    public static func make(minutes: Int, median: Double, p90: Double, max: Double, minutesAt24: Int, minutesAt36: Int, cores: Int?) -> Self {
        Self(minutes: minutes, median: median, p90: p90, max: max, minutesAt24: minutesAt24, minutesAt36: minutesAt36, cores: cores)
    }
}

extension MergeRate {
    public static func make(recorded: Int, landed: Int, hours: Double) -> Self {
        Self(recorded: recorded, landed: landed, hours: hours)
    }
}

extension Freezes {
    public static func make(count: Int, hours: Double, partial: Bool, perDay: [String: Int], byLoad: [LoadBucket]?, unsampled: Int) -> Self {
        Self(count: count, hours: hours, partial: partial, perDay: perDay, byLoad: byLoad, unsampled: unsampled)
    }
}

extension UsageNow {
    public static func make(name: String, model: String?, usedPercent: Double, resetsAt: Double?, reached: Bool, pace: UsagePace) -> Self {
        Self(name: name, model: model, usedPercent: usedPercent, resetsAt: resetsAt, reached: reached, pace: pace)
    }
}
