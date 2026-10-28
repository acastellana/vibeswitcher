import Foundation

/// The whole Mac as every project's lead shares it: the 1-minute load average and the team sessions (workers and
/// verifiers) of every project the session host knows. A lead that counted only its own team believed it had the Mac
/// to itself: on 2026-10-19 three leads' teams together held it at load 100–190 for hours, a worker's build took 25
/// minutes and merges failed on timing-sensitive tests.
public struct MacLoad: Equatable, Sendable {
    /// One project's live team sessions.
    public struct Holder: Equatable, Sendable {
        /// The repository's folder name.
        public var project: String
        public var sessions: Int
    }

    /// The 1-minute load average; nil when it couldn't be read.
    public var load: Double?
    /// The projects holding live team sessions, most first.
    public var holders: [Holder]

    public var sessions: Int { holders.reduce(0) { $0 + $1.sessions } }

    /// The Mac's 1-minute load average; nil when the system doesn't say.
    public static func oneMinute() -> Double? {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) >= 1 ? loads[0] : nil
    }

    /// The cores the load is shared by.
    public static var processors: Int { ProcessInfo.processInfo.activeProcessorCount }

    /// The live workers and verifiers among `sessions` (told by their labels, see `LeadTeams.role`), by the project
    /// whose worktree they run in, leaving out those in the folder `except` (a task's own: the session about to start
    /// takes their place).
    public static func count(_ sessions: [(label: String?, cwd: String, live: Bool)], load: Double?, except folder: String? = nil) -> MacLoad {
        let excluded = folder.map { ($0 as NSString).standardizingPath }
        var counts: [String: Int] = [:]
        for session in sessions where session.live {
            guard let role = LeadTeams.role(label: session.label), role != .lead else { continue }
            let cwd = (session.cwd as NSString).standardizingPath
            if let excluded, cwd == excluded { continue }
            let root = LeadTeams.root(ofWorktree: cwd) ?? cwd
            counts[(root as NSString).lastPathComponent, default: 0] += 1
        }
        let holders = counts.map { Holder(project: $0.key, sessions: $0.value) }
            .sorted { $0.sessions != $1.sessions ? $0.sessions > $1.sessions : $0.project < $1.project }
        return MacLoad(load: load, holders: holders)
    }

    /// As `count`, from the host's census of every project's team (`HostCensus`): since PR #1 the host lists a lead
    /// only its own team, and a lead counting what it's listed saw the Mac emptier than it was (2026-10-28: 5 team
    /// sessions across 1 project, with 9 running across 3) and started past mac_max_sessions. `sessions`, what the
    /// host lists this caller, only tell which of the counted are in the folder `except`.
    public static func count(census: [HostCensus], sessions: [(label: String?, cwd: String, live: Bool)], load: Double?,
                             except folder: String? = nil) -> MacLoad {
        var counts: [String: Int] = [:]
        for entry in census where entry.role != .lead && entry.sessions > 0 {
            counts[(entry.root as NSString).lastPathComponent, default: 0] += entry.sessions
        }
        if let folder {
            let excluded = MacLoad.count(sessions, load: nil).holders
            let kept = MacLoad.count(sessions, load: nil, except: folder).holders
            for holder in excluded {
                let there = holder.sessions - (kept.first { $0.project == holder.project }?.sessions ?? 0)
                if there > 0 { counts[holder.project] = max(0, (counts[holder.project] ?? 0) - there) }
            }
        }
        let holders = counts.filter { $0.value > 0 }.map { Holder(project: $0.key, sessions: $0.value) }
            .sorted { $0.sessions != $1.sessions ? $0.sessions > $1.sessions : $0.project < $1.project }
        return MacLoad(load: load, holders: holders)
    }

    /// Above the threshold: builds and tests slow down for every project's team.
    public func isBusy(threshold: Double) -> Bool { load.map { $0 > threshold } ?? false }

    /// At the cap: one more session would go past it.
    public func isFull(max: Int) -> Bool { sessions >= max }

    /// 12.34 → "12.3"; unknown → "unknown".
    public var loadText: String { load.map { String(format: "%.1f", $0) } ?? "unknown" }

    /// "3 team sessions across 2 projects (vibeswitcher 2, project-c 1)".
    public var sessionsText: String {
        let projects = holders.count == 1 ? "1 project" : "\(holders.count) projects"
        let who = holders.isEmpty ? "" : " (" + holders.map { "\($0.project) \($0.sessions)" }.joined(separator: ", ") + ")"
        return "\(sessions) team session\(sessions == 1 ? "" : "s") across \(projects)\(who)"
    }

    /// The Team view's line: "Mac: load 12.3, 3 team sessions across 2 projects".
    public var line: String {
        let projects = holders.count == 1 ? "1 project" : "\(holders.count) projects"
        return "Mac: load \(loadText), \(sessions) team session\(sessions == 1 ? "" : "s") across \(projects)"
    }

    /// The line as VoiceOver reads it: what the numbers are, who holds the sessions, and against the lead's limits.
    public func spoken(threshold: Double, max: Int) -> String {
        let load = self.load.map { _ in "load average \(loadText) over the last minute" } ?? "load average unknown"
        var parts = ["Whole Mac, all projects: \(load)", sessionsText]
        if isBusy(threshold: threshold) { parts.append("over the load limit of \(Self.number(threshold)): new workers and audits wait") }
        if isFull(max: max) { parts.append("at the limit of \(max) team sessions: new workers and audits wait") }
        return parts.joined(separator: "; ")
    }

    /// 24 → "24", 2.5 → "2.5".
    public static func number(_ value: Double) -> String { String(format: "%g", value) }
}

/// The Mac-wide limits every project's lead starts teams under, set once for the Mac in Settings › Project lead and
/// kept in `~/.vibeswitcher/mac-limits.json` (the leads' tool servers read it at each call). They were keys in each
/// project's workflow.md: TGE-ANALYSIS had 20 there after a refusal suggested raising it while vibeswitcher had 10, so
/// the cap held no project back. A project's workflow.md values for them are ignored (see `LeadWorkflow.ignoredKeys`).
public struct MacLimits: Codable, Equatable, Sendable {
    public static let defaultMaxSessions = 10

    /// How many workers and verifiers may run at once across every project the session host knows; start_worker and
    /// audit refuse at it.
    public var maxSessions: Int
    /// The 1-minute load average above which start_worker and audit refuse, and merge waits before its tests; nil:
    /// twice the cores (`loadLimit`).
    public var loadThreshold: Double?

    public init(maxSessions: Int = MacLimits.defaultMaxSessions, loadThreshold: Double? = nil) {
        self.maxSessions = max(1, maxSessions)
        self.loadThreshold = loadThreshold.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(maxSessions: (try? container.decodeIfPresent(Int.self, forKey: .maxSessions)) ?? Self.defaultMaxSessions,
                  loadThreshold: try? container.decodeIfPresent(Double.self, forKey: .loadThreshold))
    }

    /// The load threshold in force: the one set, else twice the Mac's cores.
    public var loadLimit: Double { loadThreshold ?? Double(2 * MacLoad.processors) }

    /// load_threshold as said to a lead: "30 in Settings", or "24, twice the 12 cores" when it isn't set.
    public var loadLimitText: String {
        MacLoad.number(loadLimit) + (loadThreshold == nil ? ", twice the \(MacLoad.processors) cores" : " in Settings")
    }

    public static var file: URL { VibePaths.root.appendingPathComponent("mac-limits.json") }

    /// The limits as set; the defaults while there's no file (or it can't be read).
    public static func load(from file: URL = file) -> MacLimits {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(MacLimits.self, from: $0) } ?? MacLimits()
    }

    /// Writes them (0600).
    public func save(to file: URL = MacLimits.file) throws {
        try VibePaths.ensurePrivate(file.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try VibePaths.writePrivate(try encoder.encode(self), to: file)
    }
}
