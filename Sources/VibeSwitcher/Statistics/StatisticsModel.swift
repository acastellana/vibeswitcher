import Foundation
import VibeCore

/// The ranges the Statistics page offers: today, and the 7 or 30 days ending today (today included).
enum StatisticsRange: String, CaseIterable, Identifiable, Sendable {
    case today, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }

    /// The days it covers, ending with today's.
    var days: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    /// From the start of the first day to the end of `now`'s.
    func interval(now: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today.addingTimeInterval(-Double(days - 1) * 86_400)
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }
}

/// The Statistics page's state: the range picked, and the stats for it once they're worked out (off the main thread,
/// by `load`). A range picked while one loads wins: the earlier one's result is dropped. Used on the main thread.
final class StatisticsModel: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded(StatisticsPage)
    }

    @Published private(set) var state: State = .loading
    @Published var range: StatisticsRange { didSet { if range != oldValue { reload() } } }

    /// Works out the stats of these projects for a range; runs off the main thread (the collector's queue).
    typealias Load = @Sendable ([String], DateInterval) async -> SetupStats
    private let load: Load
    /// The projects to count (folders; a worktree counts as its repository), asked on the main thread at each load.
    private let projects: () -> [String]
    private let now: () -> Date
    private let calendar: Calendar
    private var generation = 0
    private var task: Task<Void, Never>?

    init(range: StatisticsRange = .week, calendar: Calendar = .current, now: @escaping () -> Date = { Date() },
         projects: @escaping () -> [String] = { [] }, load: @escaping Load) {
        self.range = range
        self.projects = projects
        self.calendar = calendar
        self.now = now
        self.load = load
    }

    /// The app's: `collector` (which works on its own queue) over the projects `projects` names.
    convenience init(collector: SetupStatsCollector, projects: @escaping () -> [String]) {
        self.init(projects: projects, load: { projects, range in await collector.collect(projects: projects, range: range) })
    }

    /// The stats for the range picked, worked out again (the page shows loading until they're in).
    func reload() {
        generation += 1
        let mine = generation
        let interval = range.interval(now: now(), calendar: calendar)
        let projects = projects()
        state = .loading
        task?.cancel()
        let load = self.load
        task = Task { @MainActor [weak self] in
            let stats = await load(projects, interval)
            guard let self, mine == self.generation else { return }
            self.state = .loaded(StatisticsPage(stats, calendar: self.calendar))
        }
    }

    /// Nothing more is shown: a load under way is let go (its result dropped).
    func stop() {
        generation += 1
        task?.cancel()
        task = nil
    }
}

/// What the page shows of a `SetupStats`, as text: the Mac-wide figures and the per-project table with its totals.
/// A figure whose source isn't there reads "Not recorded", never 0; one with nothing to count in the range reads "–".
struct StatisticsPage: Equatable {
    static let notRecorded = "Not recorded"
    static let none = "–"

    /// "Oct 27 – Nov 2" (the range's last day is the one before its end).
    var span: String
    var mac: [Figure]
    var projects: [ProjectRow]
    /// Nil when no project's board could be read.
    var total: ProjectRow?
    /// Quality, autonomy, time and cost, by who did the work, with the trend; nil when no project's board could be read.
    var quality: QualityPage?

    /// One Mac-wide figure: what it is, its value, a line under it, and a bar (usage) when it has one.
    struct Figure: Equatable, Identifiable {
        var label: String
        var value: String
        var detail: String?
        var meter: Meter?
        /// What it is, in one line: shown on hover.
        var help: String?
        var id: String { label }
        /// What VoiceOver reads for it.
        var spoken: String { [label + ": " + value, detail].compactMap { $0 }.joined(separator: ", ") }
    }

    /// A usage limit's bar: how much is used (0–1) and, when known, how much of its window has gone (the pace mark).
    struct Meter: Equatable {
        var used: Double
        var elapsed: Double?
        var reached: Bool
    }

    /// The table's columns, in order.
    static let columns = ["Merged", "Abandoned", "Audits · rounds", "Flakes", "Worker hours", "Cost", "Codex share", "Median to merge"]

    /// One project's row (or the totals'): a cell per column; `note` under its name.
    struct ProjectRow: Equatable, Identifiable {
        var name: String
        var note: String?
        var cells: [String]
        var id: String
        /// "Merged 3, Abandoned 1, …" for VoiceOver.
        var spoken: String {
            ([name] + (note.map { [$0] } ?? []) + zip(StatisticsPage.columns, cells).map { "\($0) \($1)" }).joined(separator: ", ")
        }
    }

    init(_ stats: SetupStats, calendar: Calendar = .current) {
        span = Self.span(stats.range, calendar: calendar)
        mac = Self.mac(stats.mac)
        projects = stats.projects.map { project in
            let note = project.figures == nil ? "board not readable" : project.hasArchive ? nil : "no archive: archived tasks not counted"
            return Self.row(name: project.name, note: note, project.figures, id: project.root)
        }
        total = stats.total.map { Self.row(name: "Total", note: nil, $0, id: "total") }
        quality = stats.quality.map { QualityPage($0, calendar: calendar) }
    }

    // MARK: Mac-wide

    static func mac(_ mac: SetupStats.MacWide) -> [Figure] {
        var figures: [Figure] = []
        if let load = mac.load {
            let cores = load.cores.map { " · \($0) cores" } ?? ""
            figures.append(Figure(label: "Load", value: "median \(number(load.median)) · p90 \(number(load.p90)) · max \(number(load.max))",
                                  detail: "\(minutes(load.minutesAt24)) at 24 or more, \(minutes(load.minutesAt36)) at 36 or more\(cores)"))
        } else {
            figures.append(Figure(label: "Load", value: notRecorded))
        }
        if let freezes = mac.freezes {
            let rate = freezes.perHour.map { " (\(number($0, digits: 2)) an hour)" } ?? ""
            var detail: [String] = []
            if freezes.partial { detail.append("hang reports kept for a week: the hours before the oldest aren't counted") }
            if freezes.unsampled > 0 { detail.append("\(freezes.unsampled) with no load sample near") }
            figures.append(Figure(label: "Freezes", value: "\(freezes.count)\(rate)", detail: detail.isEmpty ? nil : detail.joined(separator: "; ")))
        } else {
            figures.append(Figure(label: "Freezes", value: notRecorded))
        }
        let boostNowText = mac.boostNow.map { $0.on ? "on now (\($0.why))" : "off now" }
        figures.append(Figure(label: "Boost hours", value: mac.hoursBoosted.map { hours($0) } ?? notRecorded, detail: boostNowText))
        if let merges = mac.merges {
            figures.append(Figure(label: "Merges per hour", value: merges.perHour.map { number($0, digits: 2) } ?? none,
                                  detail: "\(merges.landed) landed of \(merges.recorded) merge runs"))
        } else {
            figures.append(Figure(label: "Merges per hour", value: notRecorded))
        }
        figures += usage("Claude", mac.claude)
        figures += usage("Codex", mac.codex)
        return figures
    }

    static func usage(_ account: String, _ limits: [UsageNow]?) -> [Figure] {
        guard let limits, !limits.isEmpty else { return [Figure(label: "\(account) usage", value: notRecorded)] }
        return limits.map { limit in
            let resets = limit.resetsAt.map { " · resets " + Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? ""
            return Figure(label: "\(account) \(limitName(limit))",
                          value: limit.reached ? "reached" : "\(Int(limit.usedPercent.rounded()))%",
                          detail: limit.pace.paceText + resets,
                          meter: Meter(used: min(1, max(0, limit.usedPercent / 100)), elapsed: limit.pace.elapsed.map { min(1, max(0, $0 / 100)) },
                                       reached: limit.reached))
        }
    }

    /// "weekly", "5-hour", "weekly Opus", "weekly (fable)": as the app names Claude's limits elsewhere.
    static func limitName(_ limit: UsageNow) -> String {
        let base: String
        switch limit.name {
        case "seven_day": base = "weekly"
        case "five_hour": base = "5-hour"
        case "seven_day_opus": base = "weekly Opus"
        case "seven_day_sonnet": base = "weekly Sonnet"
        default: base = limit.name.replacingOccurrences(of: "_", with: " ")
        }
        return base + (limit.model.map { " (\($0))" } ?? "")
    }

    // MARK: Projects

    static func row(name: String, note: String?, _ figures: ProjectFigures?, id: String) -> ProjectRow {
        guard let f = figures else {
            return ProjectRow(name: name, note: note, cells: Array(repeating: notRecorded, count: columns.count), id: id)
        }
        let audits = f.audited == 0 ? "0" : "\(f.audited) · \(f.auditRounds)"
        let flakes = f.flakes.map { "\($0.flakes)" } ?? notRecorded
        // Cost: only the receipts whose cost is known; none ended is $0 spent, ended but none costed isn't known, and
        // some costed is at least what they cost.
        let cost: String
        if f.ended == 0 { cost = money(0) }
        else if f.costed == 0 { cost = notRecorded }
        else { cost = (f.costed < f.ended ? "≥ " : "") + money(f.cost) }
        let share = f.codexShare.map { "\(Int(($0 * 100).rounded()))%" } ?? none
        let median = f.medianStartToMerge.map(duration) ?? none
        return ProjectRow(name: name, note: note,
                          cells: ["\(f.merged)", "\(f.abandoned)", audits, flakes, hours(f.workerHours), cost, share, median], id: id)
    }

    // MARK: Formatting

    static func number(_ value: Double, digits: Int = 1) -> String {
        let text = String(format: "%.\(digits)f", value)
        // "12.0" reads as "12".
        guard text.contains(".") else { return text }
        let trimmed = text.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return trimmed.isEmpty ? "0" : trimmed
    }

    static func hours(_ value: Double) -> String { "\(number(value)) h" }

    static func minutes(_ value: Int) -> String { value >= 60 ? "\(number(Double(value) / 60)) h" : "\(value) min" }

    static func money(_ value: Double) -> String { String(format: "$%.2f", value) }

    /// "45 min", "3.2 h", "2.5 days".
    static func duration(_ seconds: Double) -> String {
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min" }
        if seconds < 2 * 86_400 { return "\(number(seconds / 3600)) h" }
        return "\(number(seconds / 86_400)) days"
    }

    static func span(_ range: DateInterval, calendar: Calendar) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar,
                                     timeZone: calendar.timeZone)
        let first = range.start.formatted(style)
        let last = range.end.addingTimeInterval(-1).formatted(style)
        return first == last ? first : "\(first) – \(last)"
    }
}
