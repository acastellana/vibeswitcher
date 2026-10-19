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

    /// How long a refused lead is told to wait before trying again: the 1-minute average settles within a few
    /// minutes of the builds that raised it ending, and other projects' sessions ending send this lead no message.
    public static let retryMinutes = 5

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

    /// Above the threshold: builds and tests slow down for every project's team.
    public func isBusy(threshold: Double) -> Bool { load.map { $0 > threshold } ?? false }

    /// At the cap: one more session would go past it.
    public func isFull(max: Int) -> Bool { sessions >= max }

    /// 12.34 → "12.3"; unknown → "unknown".
    public var loadText: String { load.map { String(format: "%.1f", $0) } ?? "unknown" }

    /// "3 team sessions across 2 projects (vibeswitcher 2, genswap 1)".
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
    static func number(_ value: Double) -> String { String(format: "%g", value) }
}
