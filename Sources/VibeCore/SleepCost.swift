import Foundation

/// What the Mac's sleep paused: the in-flight task time (tasks running or in review) that fell in sleep, by the
/// witness's sleep log (`MacSleepLog`, the awake clock), per day and project. The 2026-11-12 speed review found 114 of
/// 343 in-flight task-hours in 7 days fell in sleep, most of it at night on battery or with the lid closed: a cost the
/// user can win back (power, the lid open) only if they see it. The app records each wake (`record`, see `SleepWatch`)
/// into `file`; the day's app-health digest (`digestText`) and the lead's status (`statusLine`) read it there, and a
/// long sleep with work in flight tells the user on waking (`notice`).
public struct SleepCost: Codable, Equatable, Sendable {
    /// What sleep paused of one project's work on one day.
    public struct Project: Codable, Equatable, Sendable {
        /// Task-seconds: each in-flight task's share of each sleep, summed.
        public var taskSeconds: Double = 0
        /// The sleeps that paused some of its work.
        public var sleeps = 0
        /// The longest of them, whole.
        public var longest: TimeInterval = 0
        /// Task-seconds by task slug.
        public var tasks: [String: Double] = [:]

        public init() {}
    }

    /// By day (yyyy-MM-dd, this Mac's time zone, as `AppHealth.Watch.day`), then project root.
    public var days: [String: [String: Project]] = [:]
    /// The wall clock of the latest look the app counted in (seconds since 1970): a day's figure is whole once this is
    /// past its end (the digest waits for it, see `AppHealth.Watch.look`). Nil in a ledger no look wrote.
    public var seen: Double?

    public init() {}

    /// A sleep this long or longer with work in flight is told on waking; a shorter one says nothing.
    public static let noticeAfter: TimeInterval = 10 * 60
    /// The days kept: the digest's day and status's week.
    static let keepDays = 8

    /// Where the app keeps it (the lead's tool server reads it for status, in another process).
    public static var file: URL { VibePaths.root.appendingPathComponent("sleep-cost.json") }

    /// The tasks a sleep pauses: those running or in review.
    public static func inFlight(_ board: LeadBoard) -> [LeadTask] {
        board.tasks.filter { $0.status == .running || $0.status == .review }
    }

    // MARK: Recording

    /// Counts `wake` against the in-flight tasks (by slug) of each project (by root). A sleep across midnight is
    /// shared between the days by the wall time of each it spans. `continuing`: it goes on a sleep already counted,
    /// a dark wake between them (one sleep, not two), `episode` long so far.
    public mutating func record(_ wake: MacSleepLog.Wake, inFlight: [String: [String]], continuing: Bool = false, episode: TimeInterval? = nil) {
        seen = max(seen ?? wake.to, wake.to)
        let busy = inFlight.filter { !$0.value.isEmpty }
        guard wake.slept > 0, !busy.isEmpty else { return }
        for (day, share) in Self.shares(from: wake.from, to: wake.to) {
            let slept = wake.slept * share
            for (root, slugs) in busy {
                let root = Self.key(root)
                let known = days[day]?[root]
                var project = known ?? Project()
                project.taskSeconds += slept * Double(slugs.count)
                if !continuing || known == nil { project.sleeps += 1 }
                project.longest = max(project.longest, episode ?? wake.slept)
                for slug in slugs { project.tasks[slug, default: 0] += slept }
                days[day, default: [:]][root] = project
            }
        }
    }

    /// The days `from` to `to` spans, each with its share of the wall time between them (summing to 1).
    static func shares(from: Double, to: Double) -> [(day: String, share: Double)] {
        let total = to - from
        guard total > 0 else { return [(AppHealth.Watch.day(Date(timeIntervalSince1970: to)), 1)] }
        var shares: [(String, Double)] = []
        var start = from
        let calendar = Calendar.current
        while start < to {
            let next = calendar.startOfDay(for: Date(timeIntervalSince1970: start)).addingTimeInterval(86_400 + 3_600)
            let end = min(to, calendar.startOfDay(for: next).timeIntervalSince1970)
            guard end > start else { break }
            shares.append((AppHealth.Watch.day(Date(timeIntervalSince1970: start)), (end - start) / total))
            start = end
        }
        return shares
    }

    /// Drops the days older than `keepDays` before `now`'s.
    public mutating func prune(now: Date) {
        guard let oldest = AppHealth.Watch.day(AppHealth.Watch.day(now), offset: -Self.keepDays) else { return }
        days = days.filter { $0.key >= oldest }
    }

    public static func load(from url: URL = SleepCost.file) -> SleepCost {
        guard let data = try? Data(contentsOf: url), let cost = try? JSONDecoder().decode(SleepCost.self, from: data) else { return SleepCost() }
        return cost
    }

    public func save(to url: URL = SleepCost.file) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? VibePaths.ensurePrivate(url.deletingLastPathComponent())
        try? VibePaths.writePrivate(data, to: url)
    }

    // MARK: What's told

    /// "4 min", "2 h 5 min", "3 d".
    public static func duration(_ seconds: TimeInterval) -> String { LeadToolset.age(seconds) }

    /// "5.2 task-hours"; "under 0.1 task-hours".
    static func hours(_ seconds: Double) -> String {
        let hours = seconds / 3_600
        return hours < 0.05 ? "under 0.1 task-hours" : String(format: "%.1f task-hours", hours)
    }

    static func name(_ root: String) -> String { (root as NSString).lastPathComponent }

    /// A project's root as kept: the app's and the lead's tool server's spellings of one folder meet.
    static func key(_ root: String) -> String { (root as NSString).standardizingPath }

    /// What keeps work running while the user is away, said with each figure.
    public static let advice = "Work runs on through the night only on AC power with the lid open (or an external display); a closed lid sleeps whatever Keep Awake says."

    /// The day's app-health digest's line: each project's in-flight task time that fell in sleep, most first; nil
    /// when sleep paused nothing that day.
    public func digestText(day: String) -> String? {
        let projects = (days[day] ?? [:]).filter { $0.value.taskSeconds > 0 }
            .sorted { $0.value.taskSeconds != $1.value.taskSeconds ? $0.value.taskSeconds > $1.value.taskSeconds : $0.key < $1.key }
        guard !projects.isEmpty else { return nil }
        let parts = projects.map { root, project in
            let most = project.tasks.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3)
                .map { "\($0.key) \(Self.hours($0.value).replacingOccurrences(of: " task-hours", with: " h"))" }
            return "\(Self.name(root)) \(Self.hours(project.taskSeconds)) in \(project.sleeps) \(project.sleeps == 1 ? "sleep" : "sleeps") "
                + "(longest \(LeadToolset.age(project.longest)); most: \(most.joined(separator: ", ")))"
        }
        return "Sleep paused in-flight work (tasks running or in review), by the Mac's awake clock: " + parts.joined(separator: "; ") + ". " + Self.advice
    }

    /// Status's line for the project at `root`: today's, yesterday's and the last 7 days' in-flight task time that
    /// fell in sleep; nil when there's none in those 7 days.
    public func statusLine(root: String, now: Date) -> String? {
        let root = Self.key(root)
        let today = AppHealth.Watch.day(now)
        let week = (0..<7).compactMap { AppHealth.Watch.day(today, offset: -$0) }.compactMap { days[$0]?[root] }
        let total = week.reduce(0) { $0 + $1.taskSeconds }
        guard total > 0 else { return nil }
        func said(_ day: String?) -> String {
            guard let day, let project = days[day]?[root], project.taskSeconds > 0 else { return "none" }
            return "\(Self.hours(project.taskSeconds)) in \(project.sleeps) \(project.sleeps == 1 ? "sleep" : "sleeps") (longest \(LeadToolset.age(project.longest)))"
        }
        return "Sleep paused in-flight work (running or in review), by the Mac's awake clock: today \(said(today)); "
            + "yesterday \(said(AppHealth.Watch.day(today, offset: -1))); 7 days \(Self.hours(total)). " + Self.advice
    }

    /// The notification on waking from `wake`: how long the Mac slept and which tasks it paused, by project (`inFlight`
    /// by root). Nil after a short sleep or with nothing in flight.
    public static func notice(_ wake: MacSleepLog.Wake, inFlight: [String: [LeadTask]]) -> (title: String, body: String)? {
        let busy = inFlight.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
        let count = busy.reduce(0) { $0 + $1.value.count }
        guard wake.slept >= noticeAfter, count > 0 else { return nil }
        let shown = 6
        var named = 0
        let lists = busy.map { root, tasks -> String in
            let slugs = tasks.map(\.slug)
            let room = max(0, shown - named)
            named += min(room, slugs.count)
            let more = slugs.count - min(room, slugs.count)
            let listed = slugs.prefix(room).joined(separator: ", ")
            return "\(name(root)): " + (listed.isEmpty ? "\(more) more" : listed + (more > 0 ? " and \(more) more" : ""))
        }
        return ("The Mac slept \(LeadToolset.age(wake.slept)): \(count) \(count == 1 ? "task" : "tasks") paused",
                lists.joined(separator: "; ") + ". On AC power with the lid open, work runs on while you're away.")
    }

    // MARK: The battery hold

    /// The tasks a battery hold keeps from moving by themselves: planned ones it doesn't start, and those in review it
    /// doesn't audit or merge (running work finishes).
    public static func pausedByHold(_ board: LeadBoard) -> (planned: Int, review: Int) {
        let moving = board.tasks.filter { $0.autoAdvance != false }
        return (moving.filter { $0.status == .planned }.count, moving.filter { $0.status == .review }.count)
    }

    /// "3 tasks paused since 14:02 (2 planned, 1 in review)"; "no task paused yet, since 14:02".
    public static func pausedText(_ board: LeadBoard, since: Double) -> String {
        let paused = pausedByHold(board)
        let count = paused.planned + paused.review
        guard count > 0 else { return "no task paused yet, since \(LeadBoard.clock(since))" }
        return "\(count) \(count == 1 ? "task" : "tasks") paused since \(LeadBoard.clock(since)) (\(paused.planned) planned, \(paused.review) in review)"
    }

    /// The hold's end, as the progress log keeps it: "Released: on AC power, after 45 min."
    public static func releasedText(onBattery: Bool, after: TimeInterval) -> String {
        "Released: \(onBattery ? "no longer under your battery limit" : "on AC power"), after \(LeadToolset.age(after))."
    }
}
