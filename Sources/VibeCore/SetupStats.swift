import Darwin
import Foundation

/// Statistics on the whole VibeSwitcher setup for a date range, from the data already on this Mac: per project (its
/// board and archive) and in total, and Mac-wide (the load recorder's files, the hang logs, boost and both accounts'
/// usage). What the statistics page shows. Read-only: nothing here writes, moves or locks a file.
///
/// The definitions are scripts/impact-metrics.sh's and scripts/load-report.sh's, so the page and the scripts agree:
/// - A merge is a task whose `merged.at` is in the range (reverted since or not); its start is its receipt's
///   `startedAt`, else the task's.
/// - An audited merge has audit rounds (`score.rounds`, else `audits.rounds`); Important findings are `score`'s.
/// - Worker hours, tokens and cost are those of the receipts that ended in the range (merged, folded, abandoned); a
///   receipt's cost is unknown when one of its roles' is.
/// - Folded and abandoned count by when they ended (the receipt's `endedAt`, else the status's `since`); failed counts
///   the tasks failed now whose failure (`since`) is in the range.
/// - A freeze is one hang report's stamp (`hang-<yyyyMMdd-HHmmss>.txt|.log`, a pair counted once), in the load bucket
///   of the sample nearest it within 2 minutes. The app prunes hang reports (a week), so the hours before the oldest
///   report left aren't counted as freeze-free.
///
/// A figure whose source is missing or unreadable is nil ("not recorded"), never a guess, and never stops the others.
/// The archive and the jsonl files are streamed a line at a time (a line over `SetupStatsCollector.maxLine` is passed
/// over), and every file's parsed lines are cached by its size and modification time.
public struct SetupStats: Equatable, Sendable {
    public var range: DateInterval
    /// When it was worked out.
    public var at: Date
    /// The projects with a board, by name.
    public var projects: [Project]
    /// Every project's figures summed (medians over all their merges); nil when no project's board could be read.
    public var total: ProjectFigures?
    public var mac: MacWide
    /// Quality, autonomy, time and cost of every project's merges in the range, by who did the work, with an 8-week
    /// trend (see `SetupQuality`); nil when no project's board could be read.
    public var quality: SetupQuality? = nil

    public struct Project: Equatable, Sendable {
        /// The repository's folder name, and its path.
        public var name: String
        public var root: String
        /// board-archive.jsonl was there (without it, tasks archived elsewhere aren't counted).
        public var hasArchive: Bool
        /// Nil when board.json couldn't be read.
        public var figures: ProjectFigures?
    }

    public struct MacWide: Equatable, Sendable {
        /// Nil: no load-<day>.jsonl for the range's days.
        public var load: LoadProfile?
        /// Nil: no merges-<day>.jsonl for the range's days.
        public var merges: MergeRate?
        /// Nil: no debug folder, or the range is before every hang report left.
        public var freezes: Freezes?
        /// Hours boosted in the range: the load recorder's samples (a minute each) that say boost was on; nil when no
        /// sample in the range says either way (lines from before the recorder kept it).
        public var hoursBoosted: Double?
        /// Boost as the app last decided it (boost.json); nil when unknown or stale.
        public var boostNow: BoostState?
        /// The Claude account's limits still holding now, with their pace; nil when none is known.
        public var claude: [UsageNow]?
        /// The Codex account's windows still holding now, with their pace; nil when none is known.
        public var codex: [UsageNow]?
        /// Codex tokens: every project's receipts' (`ProjectFigures.codexTokens`) summed; nil when none read any.
        public var codexTokens: Int?
    }
}

/// One project's figures for the range (or every project's, summed).
public struct ProjectFigures: Equatable, Sendable {
    public var merged = 0
    public var folded = 0
    public var abandoned = 0
    public var failed = 0
    /// Merges reverted in the range, by revert time, else merge time.
    public var reverts = 0

    /// Merges with audit rounds, their rounds summed, and the Important findings of every merge.
    public var audited = 0
    public var auditRounds = 0
    public var importantFindings = 0
    public var roundsPerAudited: Double? { audited > 0 ? Double(auditRounds) / Double(audited) : nil }
    public var importantPerMerge: Double? { merged > 0 ? Double(importantFindings) / Double(merged) : nil }

    /// Merges with a receipt, and those of them that passed only on the merge's rerun.
    public var mergesWithReceipt = 0
    public var mergeReruns = 0
    /// The share of merges with a receipt that passed only on the rerun.
    public var flakyMergeRate: Double? { mergesWithReceipt > 0 ? Double(mergeReruns) / Double(mergesWithReceipt) : nil }
    /// The flake ledger's entries in the range; nil when the board keeps no ledger.
    public var flakes: Flakes?

    /// The receipts that ended in the range: their workers' hours, both roles' tokens (nil: no receipt has that role's),
    /// and the estimated cost of those whose cost is known.
    public var ended = 0
    public var workerHours = 0.0
    /// Verifier hours: the receipts' verifier time (`LeadWaits.verifierTime`: each audit's time times its sessions);
    /// nil when no receipt in the range kept it (receipts from before it was recorded).
    public var verifierHours: Double?
    public var workerTokens: Int?
    public var verifierTokens: Int?
    public var cost = 0.0
    public var costed = 0
    public var costPerTask: Double? { costed > 0 ? cost / Double(costed) : nil }

    /// Of the tasks that ended, those a Codex worker worked on (`codexWorked`, or agent codex) and the rest (Claude).
    public var codexTasks = 0
    public var claudeTasks = 0
    public var codexShare: Double? { codexTasks + claudeTasks > 0 ? Double(codexTasks) / Double(codexTasks + claudeTasks) : nil }

    /// Start-to-merge of each merge with a start, in seconds, in merge order; and their median.
    public var startToMerge: [Double] = []
    public var medianStartToMerge: Double? { SetupStatsMath.median(startToMerge) }

    public struct Flakes: Equatable, Sendable {
        public var flakes = 0
        /// Distinct tests and merges (tasks) among them.
        public var tests = 0
        public var merges = 0
    }

    // Recorded since receipts kept them (each nil when nothing in the range did).
    /// The receipts that ended: the Codex tokens among their workers' (`LeadTokens.codex`).
    public var codexTokens: Int?
    /// The receipts that ended, their time between start and end by cause, in hours (`LeadWaits`): waiting for an
    /// audit to start, auditing, the merges' test runs waiting for the load and a heavy slot, and running; and the user's
    /// answers (`LeadReceipt.waitingOnUser`). Worker hours are `workerHours`.
    public var auditWaitHours: Double?
    public var auditingHours: Double?
    public var mergeWaitHours: Double?
    public var mergeTestHours: Double?
    public var userWaitHours: Double?
    /// The project lead's own tokens on the range's days (`LeadTokenLedger`), and the estimated cost of the days whose
    /// cost is known (`leadUnpricedDays`: those whose isn't); nil when it kept none for the range.
    public var leadTokens: Int?
    public var leadCost: Double?
    public var leadUnpricedDays = 0
    /// The lead's ledger began after the range started: the days before it aren't in `leadTokens` or `leadCost`.
    public var leadPartial = false

    public init() {}

    /// `self` and `other` summed (distinct tests and merges of flakes summed too: projects share none).
    public func adding(_ other: ProjectFigures) -> ProjectFigures {
        var sum = self
        sum.merged += other.merged
        sum.folded += other.folded
        sum.abandoned += other.abandoned
        sum.failed += other.failed
        sum.reverts += other.reverts
        sum.audited += other.audited
        sum.auditRounds += other.auditRounds
        sum.importantFindings += other.importantFindings
        sum.mergesWithReceipt += other.mergesWithReceipt
        sum.mergeReruns += other.mergeReruns
        if let theirs = other.flakes {
            var mine = sum.flakes ?? Flakes()
            mine.flakes += theirs.flakes
            mine.tests += theirs.tests
            mine.merges += theirs.merges
            sum.flakes = mine
        }
        sum.ended += other.ended
        sum.workerHours += other.workerHours
        sum.workerTokens = SetupStatsMath.add(sum.workerTokens, other.workerTokens)
        sum.verifierTokens = SetupStatsMath.add(sum.verifierTokens, other.verifierTokens)
        sum.cost += other.cost
        sum.costed += other.costed
        sum.codexTasks += other.codexTasks
        sum.claudeTasks += other.claudeTasks
        sum.startToMerge += other.startToMerge
        sum.verifierHours = SetupStatsMath.add(sum.verifierHours, other.verifierHours)
        sum.codexTokens = SetupStatsMath.add(sum.codexTokens, other.codexTokens)
        sum.auditWaitHours = SetupStatsMath.add(sum.auditWaitHours, other.auditWaitHours)
        sum.auditingHours = SetupStatsMath.add(sum.auditingHours, other.auditingHours)
        sum.mergeWaitHours = SetupStatsMath.add(sum.mergeWaitHours, other.mergeWaitHours)
        sum.mergeTestHours = SetupStatsMath.add(sum.mergeTestHours, other.mergeTestHours)
        sum.userWaitHours = SetupStatsMath.add(sum.userWaitHours, other.userWaitHours)
        sum.leadTokens = SetupStatsMath.add(sum.leadTokens, other.leadTokens)
        sum.leadCost = SetupStatsMath.add(sum.leadCost, other.leadCost)
        sum.leadUnpricedDays += other.leadUnpricedDays
        sum.leadPartial = sum.leadPartial || other.leadPartial
        return sum
    }
}

/// The 1-minute load over the range's samples.
public struct LoadProfile: Equatable, Sendable {
    /// Samples (one a minute).
    public var minutes: Int
    public var median: Double
    /// As load-report.sh takes it: the sorted loads' element at 90 % of their count.
    public var p90: Double
    public var max: Double
    /// Minutes at a load of 24 or more (load-report.sh's 24-36 bucket and up), and of 36 or more.
    public var minutesAt24: Int
    public var minutesAt36: Int
    /// The last sample's cores.
    public var cores: Int?
}

/// The merges the load recorder recorded in the range, Mac-wide.
public struct MergeRate: Equatable, Sendable {
    /// Its lines (every merge's test run: passed, failed, conflict…), and those that landed (passed, passed on rerun).
    public var recorded: Int
    public var landed: Int
    /// The range's hours gone so far (a range running into the future doesn't dilute the rate).
    public var hours: Double
    public var perHour: Double? { hours > 0 ? Double(landed) / hours : nil }
}

/// VibeSwitcher's freezes in the range, from its hang reports.
public struct Freezes: Equatable, Sendable {
    public var count: Int
    /// The hours counted: the range's gone so far, from the oldest report left when the app pruned the ones before.
    public var hours: Double
    /// The range starts before the oldest report left: the hours before it aren't counted.
    public var partial: Bool
    public var perHour: Double? { hours > 0 ? Double(count) / hours : nil }
    /// Freezes by local day ("2026-10-20"), only days with one.
    public var perDay: [String: Int]
    /// By the 1-minute load of the sample nearest each (within 2 minutes), the buckets sampled or frozen in, in
    /// order; nil when there's no load sample in the hours counted.
    public var byLoad: [LoadBucket]?
    /// Freezes with no load sample within 2 minutes.
    public var unsampled: Int

    public struct LoadBucket: Equatable, Sendable {
        /// "24-36", "150+".
        public var name: String
        public var minutes: Int
        public var freezes: Int
        public var perHour: Double? { minutes > 0 ? Double(freezes) / (Double(minutes) / 60) : nil }
    }
}

/// One usage limit now, with its pace.
public struct UsageNow: Equatable, Sendable {
    /// "seven_day", "five_hour" (Claude's names); "weekly", "5-hour" (Codex's windows).
    public var name: String
    /// The model family it holds for, when one (Claude's).
    public var model: String?
    public var usedPercent: Double
    public var resetsAt: Double?
    public var reached: Bool
    public var pace: UsagePace
}

enum SetupStatsMath {
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    static func add(_ a: Int?, _ b: Int?) -> Int? {
        guard a != nil || b != nil else { return nil }
        return (a ?? 0) + (b ?? 0)
    }

    static func add(_ a: Double?, _ b: Double?) -> Double? {
        guard a != nil || b != nil else { return nil }
        return (a ?? 0) + (b ?? 0)
    }

    /// load-report.sh's buckets of the 1-minute load.
    static let edges: [Double] = [0, 12, 24, 36, 48, 72, 100, 150]
    static var bucketNames: [String] {
        zip(edges, edges.dropFirst()).map { "\(Int($0))-\(Int($1))" } + ["\(Int(edges.last!))+"]
    }

    static func bucket(_ load: Double) -> String {
        for (low, high) in zip(edges, edges.dropFirst()) where load < high { return "\(Int(low))-\(Int(high))" }
        return "\(Int(edges.last!))+"
    }
}

/// Works out `SetupStats`, off the main thread, on its own queue; each file's parsed lines are kept until its size or
/// modification time changes.
public final class SetupStatsCollector: @unchecked Sendable {
    /// VibeSwitcher's folder (stats/, debug/, boost.json, account-usage.json are read in it).
    public let home: URL
    /// Codex's folder, for its usage; nil: none read.
    public let codexHome: URL?
    public let calendar: Calendar
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "vibeswitcher.setup-stats", qos: .utility)
    /// By path: the size and modification time it was parsed at, and what it parsed to. Only on `queue`.
    private var cache: [String: (size: Int64, changed: Double, value: Any)] = [:]
    private let codexReader: CodexUsageReader?
    private let counter = NSLock()
    private var parsed = 0
    private var onMain = 0
    /// By path: the `read(2)` calls the jsonl files took, their bytes, and the largest one (for the tests).
    private var readLog: [String: Reads] = [:]
    struct Reads: Equatable { var calls = 0, bytes = 0, largest = 0 }

    /// A jsonl line longer than this is passed over (read through, never held).
    public static let maxLine = 8 << 20
    /// The bytes a jsonl file is read in, a read at a time.
    static let readSize = 1 << 16
    /// A board.json larger than this isn't read (its figures: not recorded).
    public static let maxBoard: Int64 = 128 << 20

    /// `home`: VibeSwitcher's folder (`VibePaths.root`); `codexHome`: Codex's (`CodexUsageReader.standardHome`).
    public init(home: URL, codexHome: URL?, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home
        self.codexHome = codexHome
        self.calendar = calendar
        self.now = now
        self.codexReader = codexHome.map { CodexUsageReader(home: $0) }
    }

    /// The Mac's own: `VibePaths.root` and Codex's home, as they are now.
    public static func standard() -> SetupStatsCollector {
        SetupStatsCollector(home: VibePaths.root, codexHome: CodexUsageReader.standardHome)
    }

    /// The last 7 days, plus today: from the start of the day 7 days before `now`'s to the end of `now`'s day.
    public static func defaultRange(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -7, to: today) ?? today.addingTimeInterval(-7 * 86_400)
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    /// The statistics of `projects` (repository folders; a worktree counts as its repository; those without
    /// .vibeswitcher/board.json are left out) for `range` (nil: `defaultRange`). Works on the collector's queue.
    public func collect(projects: [String], range: DateInterval? = nil) async -> SetupStats {
        await withCheckedContinuation { continuation in
            collect(projects: projects, range: range) { continuation.resume(returning: $0) }
        }
    }

    /// As `collect(projects:range:)`, `done` called on the collector's queue.
    public func collect(projects: [String], range: DateInterval? = nil, done: @escaping @Sendable (SetupStats) -> Void) {
        queue.async { [self] in done(compute(projects: projects, range: range)) }
    }

    /// How many files were parsed (not served from the cache), and how many times the work ran on the main thread.
    public var parses: Int { counter.withLock { parsed } }
    public var mainThreadRuns: Int { counter.withLock { onMain } }
    /// The reads of the jsonl file at `path` so far, all collections together.
    func reads(of path: String) -> Reads { counter.withLock { readLog[path] ?? Reads() } }

    /// `jsonLines(path)`, its reads tallied in `readLog`.
    private func jsonLines(_ path: String) -> [[String: Any]]? {
        Self.jsonLines(path) { count in
            counter.withLock {
                var tally = readLog[path] ?? Reads()
                tally.calls += 1
                tally.bytes += count
                tally.largest = max(tally.largest, count)
                readLog[path] = tally
            }
        }
    }

    // MARK: - The work, on `queue`

    private func compute(projects candidates: [String], range: DateInterval?) -> SetupStats {
        if Thread.isMainThread { counter.withLock { onMain += 1 } }
        let at = now()
        let range = range ?? Self.defaultRange(now: at, calendar: calendar)
        let window = Window(t0: range.start.timeIntervalSince1970, t1: range.end.timeIntervalSince1970, now: at.timeIntervalSince1970)
        var projects: [SetupStats.Project] = []
        var sources: [(root: String, source: QualitySource)] = []
        for root in Self.roots(candidates) {
            let folder = (root as NSString).appendingPathComponent(".vibeswitcher")
            let archivePath = (folder as NSString).appendingPathComponent("board-archive.jsonl")
            let archive: [TaskView]? = cached(archivePath) { path in
                jsonLines(path).map { lines in
                let decoder = JSONDecoder()
                return lines.compactMap { TaskView($0, decoder: decoder) }
            }
            }
            let board: BoardView? = cached((folder as NSString).appendingPathComponent("board.json")) { path in BoardView(path: path) }
            let lead: LeadLedgerView? = cached((folder as NSString).appendingPathComponent(LeadTokenLedger.fileName)) { path in LeadLedgerView(path: path) }
            let figures = board.map { board in
                var figures = Self.figures(board: board, archive: archive ?? [], window: window)
                if let lead { Self.addLead(lead, to: &figures, window: window, calendar: calendar) }
                return figures
            }
            let name = (root as NSString).lastPathComponent
            projects.append(SetupStats.Project(name: name, root: root, hasArchive: archive != nil, figures: figures))
            if let board {
                sources.append((root, QualitySource(name: name, tasks: Self.tasks(board: board, archive: archive ?? []), questions: board.questions,
                                                   incidents: incidents(root: root), flakes: board.flakes?.map { ($0.task, $0.at) })))
            }
        }
        projects.sort { ($0.name, $0.root) < ($1.name, $1.root) }
        let known = projects.compactMap(\.figures)
        let total = known.isEmpty ? nil : known.dropFirst().reduce(known[0]) { $0.adding($1) }
        var mac = mac(range: range, window: window, at: at)
        mac.codexTokens = total?.codexTokens
        var stats = SetupStats(range: range, at: at, projects: projects, total: total, mac: mac)
        if !sources.isEmpty {
            sources.sort { $0.root < $1.root }
            stats.quality = SetupQualityMath.quality(sources.map(\.source), window: window, weeks: weeks(ending: range.end),
                                                     mergeLines: mergeLines(range))
            // A project with a board but no lead ledger for the range: its lead's spend isn't in the sum.
            let unledgered = projects.contains { $0.figures != nil && $0.figures?.leadTokens == nil }
            stats.quality?.all.lead = total?.leadTokens.map {
                LeadSpend(tokens: $0, cost: total?.leadCost, unpricedDays: total?.leadUnpricedDays ?? 0, partial: (total?.leadPartial ?? false) || unledgered)
            }
        }
        return stats
    }

    /// The trend's 8 weeks, 7 days each, the last ending at `end`; oldest first.
    func weeks(ending end: Date) -> [DateInterval] {
        (0..<8).reversed().map { back in
            let last = calendar.date(byAdding: .day, value: -7 * back, to: end) ?? end.addingTimeInterval(Double(-7 * back) * 86_400)
            let first = calendar.date(byAdding: .day, value: -7, to: last) ?? last.addingTimeInterval(-7 * 86_400)
            return DateInterval(start: first, end: last)
        }
    }

    /// The merges recorder's lines from 14 days before `range` to its end (a merge's first test run may come days
    /// before it lands), by project and task, oldest first; nil when it wrote no file for any of those days.
    private func mergeLines(_ range: DateInterval) -> [String: [String: [RecorderLine]]]? {
        let stats = home.appendingPathComponent("stats").path
        let start = calendar.date(byAdding: .day, value: -14, to: range.start) ?? range.start.addingTimeInterval(-14 * 86_400)
        let stamps = StampParser(calendar: calendar)
        var found: [String: [String: [RecorderLine]]] = [:], any = false
        for day in days(DateInterval(start: start, end: max(start, range.end))) {
            let lines: [RecorderLine]? = cached((stats as NSString).appendingPathComponent("merges-\(day).jsonl")) { path in
                jsonLines(path).map { $0.compactMap { RecorderLine($0, stamps: stamps) } }
            }
            guard let lines else { continue }
            any = true
            for line in lines where line.at < range.end.timeIntervalSince1970 {
                guard let project = line.project, let task = line.task else { continue }
                found[project, default: [:]][task, default: []].append(line)
            }
        }
        guard any else { return nil }
        return found.mapValues { $0.mapValues { $0.sorted { $0.at < $1.at } } }
    }

    /// The incidents a project's record names tasks in (where its records_dir keeps incidents.md, and the board's
    /// folder, before a move), by task slug. The lead's record_incident makes the file on the first one: none is none.
    private func incidents(root: String) -> [String: [Double]] {
        let store = BoardStore(root: root)
        let paths = Array(Set([store.recordPath("incidents.md"), (store.folder as NSString).appendingPathComponent("incidents.md")]))
        var found: [String: [Double]] = [:]
        for path in paths.sorted() {
            let parsed: [String: [Double]]? = cached(path) { path in
                (try? String(contentsOfFile: path, encoding: .utf8)).map(SetupQualityMath.incidents)
            }
            for (slug, times) in parsed ?? [:] { found[slug, default: []] += times }
        }
        return found
    }

    /// The range in epoch seconds, and now.
    struct Window {
        var t0: Double, t1: Double, now: Double
        func within(_ at: Double?) -> Bool { at.map { t0 <= $0 && $0 < t1 } ?? false }
        /// The hours gone in the range from `from` (at least its start).
        func hours(from: Double? = nil) -> Double { max(0, min(t1, now) - max(t0, from ?? t0)) / 3600 }
    }

    /// The candidates' repositories with a board: standardized, worktrees as their repository, each once.
    static func roots(_ candidates: [String]) -> [String] {
        var seen = Set<String>(), roots: [String] = []
        for candidate in candidates {
            var root = (candidate as NSString).standardizingPath
            if let marker = root.range(of: "/.vibeswitcher/worktrees/") { root = String(root[..<marker.lowerBound]) }
            guard !root.isEmpty, seen.insert(root).inserted else { continue }
            var info = stat()
            let board = (root as NSString).appendingPathComponent(".vibeswitcher/board.json")
            guard stat(board, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            roots.append(root)
        }
        return roots
    }

    /// What `path` parses to, from the cache while its size and modification time are as parsed; nil (and nothing
    /// kept) when it isn't a readable regular file or doesn't parse.
    private func cached<T>(_ path: String, parse: (String) -> T?) -> T? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { cache[path] = nil; return nil }
        let size = Int64(info.st_size)
        let changed = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        if let hit = cache[path], hit.size == size, hit.changed == changed { return hit.value as? T }
        counter.withLock { parsed += 1 }
        guard let value = parse(path) else { cache[path] = nil; return nil }
        cache[path] = (size, changed, value)
        return value
    }

    // MARK: Per project

    /// Each task once: the board's live copy over the archive's last line.
    static func tasks(board: BoardView, archive: [TaskView]) -> [TaskView] {
        var byID: [String: TaskView] = [:], order: [String] = []
        for task in archive + board.tasks {
            if byID.updateValue(task, forKey: task.id) == nil { order.append(task.id) }
        }
        return order.compactMap { byID[$0] }
    }

    static func figures(board: BoardView, archive: [TaskView], window: Window) -> ProjectFigures {
        let tasks = tasks(board: board, archive: archive)
        var f = ProjectFigures()

        let merged = tasks.filter { window.within($0.mergedAt) }.sorted { $0.mergedAt! < $1.mergedAt! }
        f.merged = merged.count
        for task in merged {
            if let began = task.receipt?.startedAt ?? task.startedAt { f.startToMerge.append(task.mergedAt! - began) }
            if task.rounds > 0 {
                f.audited += 1
                f.auditRounds += task.rounds
            }
            f.importantFindings += task.importantFindings
            if let receipt = task.receipt {
                f.mergesWithReceipt += 1
                if receipt.mergeReruns > 0 { f.mergeReruns += 1 }
            }
        }
        f.reverts = tasks.filter { $0.reverted && window.within($0.revertedAt ?? $0.mergedAt) }.count
        let endedAt: (TaskView) -> Double? = { $0.receipt?.endedAt ?? $0.since }
        f.folded = tasks.filter { $0.status == "folded" && window.within(endedAt($0)) }.count
        f.abandoned = tasks.filter { $0.status == "abandoned" && window.within(endedAt($0)) }.count
        f.failed = tasks.filter { $0.status == "failed" && window.within($0.since) }.count

        if let ledger = board.flakes {
            let inRange = ledger.filter { window.within($0.at) }
            f.flakes = ProjectFigures.Flakes(flakes: inRange.count, tests: Set(inRange.map(\.test)).count, merges: Set(inRange.map(\.task)).count)
        }

        for task in tasks {
            guard let receipt = task.receipt, window.within(receipt.endedAt) else { continue }
            f.ended += 1
            f.workerHours += receipt.worked / 3600
            f.workerTokens = SetupStatsMath.add(f.workerTokens, receipt.worker?.tokens)
            f.verifierTokens = SetupStatsMath.add(f.verifierTokens, receipt.verifier?.tokens)
            if let cost = receipt.cost {
                f.cost += cost
                f.costed += 1
            }
            if task.codex { f.codexTasks += 1 } else { f.claudeTasks += 1 }
            if let codex = receipt.worker?.codex { f.codexTokens = (f.codexTokens ?? 0) + codex }
            f.userWaitHours = (f.userWaitHours ?? 0) + receipt.waitingOnUser / 3600
            if let waits = receipt.waits {
                func hours(_ seconds: Double?, into sum: inout Double?) { if let seconds { sum = (sum ?? 0) + seconds / 3600 } }
                hours(waits.verifierTime, into: &f.verifierHours)
                hours(waits.auditWait, into: &f.auditWaitHours)
                hours(waits.auditing, into: &f.auditingHours)
                hours(SetupStatsMath.add(waits.mergeLoadWait, waits.mergeSlotWait), into: &f.mergeWaitHours)
                hours(waits.mergeTesting, into: &f.mergeTestHours)
            }
        }
        return f
    }

    /// The lead's tokens on the range's days (a day counts when its start is in the range) into `f`; none when the
    /// ledger began after the range ended (nothing recorded for it).
    static func addLead(_ lead: LeadLedgerView, to f: inout ProjectFigures, window: Window, calendar: Calendar) {
        guard let since = lead.since, since < window.t1 else { return }
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.timeZone = calendar.timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        var tokens = 0, cost: Double?, unpriced = 0
        for (day, tally) in lead.days {
            guard let start = parser.date(from: day), window.within(start.timeIntervalSince1970) else { continue }
            tokens += tally.tokens
            if tally.unpriced { unpriced += 1 } else { cost = (cost ?? 0) + tally.cost }
        }
        f.leadTokens = tokens
        f.leadCost = cost
        f.leadUnpricedDays = unpriced
        f.leadPartial = since > window.t0
    }

    // MARK: Mac-wide

    private func mac(range: DateInterval, window: Window, at: Date) -> SetupStats.MacWide {
        let stats = home.appendingPathComponent("stats").path, debug = home.appendingPathComponent("debug").path
        let days = days(range)
        let stamps = StampParser(calendar: calendar)
        // The load recorder's lines of `kind` in the range; nil when it wrote no file for any of its days.
        func recorder(_ kind: String) -> [RecorderLine]? {
            var found: [RecorderLine] = [], any = false
            for day in days {
                let lines: [RecorderLine]? = cached((stats as NSString).appendingPathComponent("\(kind)-\(day).jsonl")) { path in
                    jsonLines(path).map { $0.compactMap { RecorderLine($0, stamps: stamps) } }
                }
                guard let lines else { continue }
                any = true
                found += lines.filter { window.within($0.at) }
            }
            return any ? found : nil
        }
        let samples = recorder("load").map { $0.filter { !$0.load.isEmpty }.sorted { $0.at < $1.at } }
        let merges = recorder("merges")

        var mac = SetupStats.MacWide()
        if let samples, !samples.isEmpty {
            let loads = samples.map { $0.load[0] }.sorted()
            mac.load = LoadProfile(minutes: loads.count, median: SetupStatsMath.median(loads) ?? 0,
                                   p90: loads[min(loads.count - 1, Int(0.9 * Double(loads.count)))], max: loads.last ?? 0,
                                   minutesAt24: loads.filter { $0 >= 24 }.count, minutesAt36: loads.filter { $0 >= 36 }.count,
                                   cores: samples.last?.cores)
        }
        if let merges {
            mac.merges = MergeRate(recorded: merges.count, landed: merges.filter { ["passed", "passed_on_rerun"].contains($0.result) }.count,
                                   hours: window.hours())
        }
        if let samples {
            let said = samples.compactMap(\.boost)
            if !said.isEmpty { mac.hoursBoosted = Double(said.filter { $0 }.count) / 60 }
        }
        mac.freezes = freezes(debug: debug, samples: samples ?? [], window: window)
        mac.boostNow = BoostState.load(from: home.appendingPathComponent("boost.json"), now: at)
        let seconds = at.timeIntervalSince1970
        let claude = AccountUsageStore(file: home.appendingPathComponent("account-usage.json")).load().current(now: at).limits
        if !claude.isEmpty {
            mac.claude = claude.map { UsageNow(name: $0.name, model: $0.model, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt,
                                               reached: $0.reached, pace: UsageRouting.pace($0, now: seconds)) }
        }
        if let usage = codexReader?.read(now: at).usage {
            let windows = usage.current(now: at)
            if !windows.isEmpty {
                mac.codex = windows.map { UsageNow(name: $0.name.isEmpty ? "limit" : $0.name, model: nil, usedPercent: $0.usedPercent,
                                                   resetsAt: $0.resetsAt, reached: usage.reached != nil, pace: $0.pace(at: seconds)) }
            }
        }
        return mac
    }

    /// The range's local days, "2026-10-20", from its start's through the day of its last second.
    func days(_ range: DateInterval) -> [String] {
        var days: [String] = []
        var day = calendar.startOfDay(for: range.start)
        let last = range.end.addingTimeInterval(-1)
        while day <= last, days.count < 3_660 {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            days.append(String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    private func freezes(debug: String, samples: [RecorderLine], window: Window) -> Freezes? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: debug, isDirectory: &isFolder), isFolder.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: debug) else { return nil }
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.timeZone = calendar.timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyyMMdd-HHmmss"
        var stamps = Set<Double>()
        for name in names {
            guard let match = name.wholeMatch(of: #/hang-(\d{8}-\d{6})\.(txt|log)/#),
                  let at = parser.date(from: String(match.1)) else { continue }
            stamps.insert(at.timeIntervalSince1970)
        }
        // With no report at all, the last week is covered (the app keeps a week).
        let coveredFrom = stamps.min() ?? window.now - 7 * 86_400
        let start = max(window.t0, coveredFrom)
        let hours = window.hours(from: coveredFrom)
        guard hours > 0 else { return nil }
        let hangs = stamps.filter { window.within($0) }.sorted()
        let dayFormat = DateFormatter()
        dayFormat.calendar = calendar
        dayFormat.timeZone = calendar.timeZone
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"
        var perDay: [String: Int] = [:]
        for at in hangs { perDay[dayFormat.string(from: Date(timeIntervalSince1970: at)), default: 0] += 1 }

        var byLoad: [Freezes.LoadBucket]?
        var unsampled = 0
        let covered = samples.filter { $0.at >= start }
        if !covered.isEmpty {
            var rows = Dictionary(uniqueKeysWithValues: SetupStatsMath.bucketNames.map { ($0, (minutes: 0, freezes: 0)) })
            for sample in covered { rows[SetupStatsMath.bucket(sample.load[0])]!.minutes += 1 }
            for at in hangs {
                if let sample = Self.nearest(at, in: samples) { rows[SetupStatsMath.bucket(sample.load[0])]!.freezes += 1 } else { unsampled += 1 }
            }
            byLoad = SetupStatsMath.bucketNames.compactMap { name in
                let row = rows[name]!
                return row.minutes > 0 || row.freezes > 0 ? Freezes.LoadBucket(name: name, minutes: row.minutes, freezes: row.freezes) : nil
            }
        } else {
            unsampled = hangs.count
        }
        return Freezes(count: hangs.count, hours: hours, partial: start > window.t0, perDay: perDay, byLoad: byLoad, unsampled: unsampled)
    }

    /// The sample nearest `at` within 2 minutes (`samples` sorted by time), by binary search.
    static func nearest(_ at: Double, in samples: [RecorderLine]) -> RecorderLine? {
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].at < at { lo = mid + 1 } else { hi = mid }
        }
        var best: (gap: Double, sample: RecorderLine)?
        for i in [lo - 1, lo] where samples.indices.contains(i) {
            let gap = abs(samples[i].at - at)
            if gap <= 120, best.map({ gap < $0.gap }) ?? true { best = (gap, samples[i]) }
        }
        return best?.sample
    }

    // MARK: Reading

    /// The JSON objects of `path`'s lines, streamed: a line that doesn't parse (cut short by a crash) or is longer
    /// than `maxLine` is passed over. Nil when the file can't be opened. `onRead`: told each read's byte count.
    static func jsonLines(_ path: String, onRead: (Int) -> Void = { _ in }) -> [[String: Any]]? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var found: [[String: Any]] = []
        var line = Data(), skipping = false
        func finish() {
            defer { line.removeAll(keepingCapacity: true); skipping = false }
            guard !skipping, !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            found.append(object)
        }
        var buffer = [UInt8](repeating: 0, count: readSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            onRead(count)
            var start = 0
            // Bytes of the line under way: held up to `maxLine`, then dropped and the rest of the line read through.
            func take(_ bytes: UnsafeRawBufferPointer, _ range: Range<Int>) {
                guard !skipping, !range.isEmpty else { return }
                if line.count + range.count > maxLine {
                    skipping = true
                    line.removeAll(keepingCapacity: false)
                } else {
                    line.append(contentsOf: bytes[range])
                }
            }
            buffer.withUnsafeBytes { bytes in
                for i in 0..<count where bytes[i] == 0x0A {
                    take(bytes, start..<i)
                    finish()
                    start = i + 1
                }
                take(bytes, start..<count)
            }
        }
        finish()
        return found
    }
}

// MARK: - Lenient views of the files (as the scripts read them: a field missing or of another shape is absent)

private func number(_ value: Any?) -> Double? {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
    let double = value.doubleValue
    return double.isFinite ? double : nil
}

/// A whole number from a file, nil when it isn't one an Int holds (a hand-edited 1e300 never traps).
private func whole(_ value: Any?) -> Int? { number(value).flatMap { Int(exactly: $0.rounded(.towardZero)) } }

/// A number the scripts read with Python's `or`: 0 or absent is none.
private func given(_ value: Any?) -> Double? { number(value).flatMap { $0 == 0 ? nil : $0 } }

/// A dictionary the scripts read with `or {}`: an empty one is none.
private func object(_ value: Any?) -> [String: Any]? { (value as? [String: Any]).flatMap { $0.isEmpty ? nil : $0 } }

struct TaskView {
    var id: String
    /// The task as the board's own type, for the scorecard's definitions: only for a task merged or with a receipt
    /// (nil when it doesn't decode as one).
    var lead: LeadTask?
    var status: String
    var since: Double?
    var startedAt: Double?
    var mergedAt: Double?
    var revertedAt: Double?
    var reverted: Bool
    var rounds: Int
    var importantFindings: Int
    var receipt: ReceiptView?
    var codex: Bool

    init?(_ task: [String: Any], decoder: JSONDecoder? = nil) {
        guard let id = task["id"] as? String else { return nil }
        self.id = id
        if let decoder, object(task["merged"]) != nil || object(task["receipt"]) != nil {
            // A receipt of another shape (hand-edited, older) doesn't lose the task: its cost is read leniently below.
            lead = [task, task.filter { $0.key != "receipt" }].lazy.compactMap { shape in
                (try? JSONSerialization.data(withJSONObject: shape)).flatMap { try? decoder.decode(LeadTask.self, from: $0) }
            }.first
        }
        status = task["status"] as? String ?? ""
        since = number(task["since"])
        startedAt = given(task["startedAt"])
        let merged = object(task["merged"]), score = object(task["score"]), audits = object(task["audits"])
        mergedAt = number(merged?["at"])
        revertedAt = given(merged?["revertedAt"])
        reverted = merged?["revertedBy"] as? String != nil || score?["revertedBy"] as? String != nil || status == "reverted"
        rounds = whole(score?["rounds"]) ?? whole(audits?["rounds"]) ?? 0
        importantFindings = whole(score?["importantFindings"]) ?? 0
        receipt = object(task["receipt"]).map(ReceiptView.init)
        codex = task["codexWorked"] as? Bool == true || task["agent"] as? String == "codex"
    }
}

struct ReceiptView {
    var startedAt: Double?
    var endedAt: Double?
    var worked: Double
    var mergeReruns: Int
    var rerolls: Int
    var worker: Role?
    var verifier: Role?
    /// Seconds its questions waited on the user (0 when not said).
    var waitingOnUser: Double
    /// Its `LeadWaits`, seconds by cause; nil in receipts from before they were kept.
    var waits: Waits?

    struct Role {
        var cost: Double?
        /// Input, output, cache reads and writes, as `LeadTokens.total`; nil when none is said.
        var tokens: Int?
        /// Of them, Codex's (`LeadTokens.codex`); nil when not said.
        var codex: Int?
        /// The verifier's: it ran on the worker's model (`LeadTokens.sameModel`); nil when not said.
        var sameModel: Bool?

        init(_ role: [String: Any]) {
            cost = number(role["cost"])
            let parts = ["input", "output", "cacheRead", "cacheWrite"].compactMap { whole(role[$0]) }
            tokens = parts.isEmpty ? nil : parts.reduce(0, &+)
            codex = whole(role["codex"])
            sameModel = role["sameModel"] as? Bool
        }
    }

    struct Waits {
        var auditWait, auditing, verifierTime, mergeLoadWait, mergeSlotWait, mergeTesting: Double?

        init(_ waits: [String: Any]) {
            auditWait = number(waits["auditWait"])
            auditing = number(waits["auditing"])
            verifierTime = number(waits["verifierTime"])
            mergeLoadWait = number(waits["mergeLoadWait"])
            mergeSlotWait = number(waits["mergeSlotWait"])
            mergeTesting = number(waits["mergeTesting"])
        }
    }

    init(_ receipt: [String: Any]) {
        startedAt = given(receipt["startedAt"])
        endedAt = number(receipt["endedAt"])
        worked = number(receipt["worked"]) ?? 0
        mergeReruns = whole(receipt["mergeReruns"]) ?? 0
        rerolls = whole(receipt["rerolls"]) ?? 0
        worker = object(receipt["worker"]).map(Role.init)
        verifier = object(receipt["verifier"]).map(Role.init)
        waitingOnUser = number(receipt["waitingOnUser"]) ?? 0
        waits = object(receipt["waits"]).map(Waits.init)
    }

    /// Both roles' cost; nil when it has no role, or a role's is unknown (impact-metrics.sh's `receipt_cost`).
    var cost: Double? {
        let parts = [worker, verifier].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        let costs = parts.compactMap(\.cost)
        return costs.count == parts.count ? costs.reduce(0, +) : nil
    }
}

struct BoardView {
    var tasks: [TaskView]
    /// The flake ledger; nil when the board keeps none.
    var flakes: [(test: String, task: String, at: Double?)]?
    /// The lead's questions to the user (those that don't decode left out).
    var questions: [LeadQuestion]

    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0, Int64(info.st_size) <= SetupStatsCollector.maxBoard,
              let data = FileManager.default.contents(atPath: path),
              let board = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let decoder = JSONDecoder()
        tasks = (board["tasks"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap { TaskView($0, decoder: decoder) } }
        questions = (board["questions"] as? [Any] ?? []).compactMap { question in
            (try? JSONSerialization.data(withJSONObject: question)).flatMap { try? decoder.decode(LeadQuestion.self, from: $0) }
        }
        flakes = (board["flakes"] as? [Any]).map { entries in
            entries.compactMap { $0 as? [String: Any] }.map { ($0["test"] as? String ?? "", $0["task"] as? String ?? "", number($0["at"])) }
        }
        // The flake ledger's own file, where boards' flakes moved (`FlakeLedgerStore`): its flakes after the board's
        // (a board not moved yet still keeps some), each once.
        let ledger = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("flakes/ledger.jsonl")
        if FileManager.default.fileExists(atPath: ledger) {
            let kept = (board["flakes"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            let seen = Set(kept.map { "\($0["test"] as? String ?? "")\n\($0["task"] as? String ?? "")\n\($0["commit"] as? String ?? "")\n\(number($0["at"]) ?? 0)" })
            let moved = FlakeLedgerStore.read(ledger).flakes.filter { !seen.contains("\($0.test)\n\($0.task)\n\($0.commit)\n\($0.at)") }
            flakes = (flakes ?? []) + moved.map { ($0.test, $0.task, $0.at) }
        }
    }
}

/// A load or merges line of the load recorder: when, the load averages, cores and result.
struct RecorderLine {
    var at: Double
    var load: [Double]
    var cores: Int?
    var result: String?
    /// A load line's boost flag; nil when it doesn't say (lines from before it was recorded).
    var boost: Bool?
    /// A merges line's: the project's folder name, the task's slug, and its first test run ("passed", "failed"; a
    /// batched task's own where the line says it).
    var project: String?
    var task: String?
    var firstRun: String?

    init?(_ line: [String: Any], stamps: StampParser) {
        guard let stamp = line["t"] as? String, let at = stamps.date(stamp) else { return nil }
        self.at = at
        load = (line["load"] as? [Any] ?? []).compactMap(number)
        cores = whole(line["cores"])
        result = line["result"] as? String
        project = line["project"] as? String
        task = line["task"] as? String
        // A batched task's own first run where its line says it (`MergeSample.taskFirstRun`), else the run's: the
        // recorder writes snake_case keys (`first_run`); "firstRun" as hand-written lines have it.
        firstRun = line["task_first_run"] as? String ?? line["first_run"] as? String ?? line["firstRun"] as? String
        if let flag = line["boost"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() { boost = flag.boolValue }
    }
}

/// A project's lead-tokens.json (`LeadTokenLedger`): when it began, and each day's tokens and cost.
struct LeadLedgerView {
    var since: Double?
    var days: [String: (tokens: Int, cost: Double, unpriced: Bool)]

    init?(path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let ledger = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        since = number(ledger["since"])
        days = [:]
        for (day, value) in ledger["days"] as? [String: Any] ?? [:] {
            guard let tally = value as? [String: Any] else { continue }
            let tokens = ["input", "output", "cacheRead", "cacheWrite"].compactMap { whole(tally[$0]) }.reduce(0, &+)
            let unpriced = !((tally["unpriced"] as? [Any])?.isEmpty ?? true)
            days[day] = (tokens, number(tally["cost"]) ?? 0, unpriced)
        }
    }
}

/// Reads the load recorder's stamps: "2026-10-20T10:00:00+01:00" (with fractional seconds or not); one with no
/// offset is local (`calendar`'s zone). Its formatters made once, for a file's lines.
final class StampParser {
    private let iso = ISO8601DateFormatter()
    private let fractional = ISO8601DateFormatter()
    private let local = DateFormatter()

    init(calendar: Calendar) {
        iso.formatOptions = [.withInternetDateTime]
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = calendar.timeZone
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    }

    func date(_ stamp: String) -> Double? {
        (iso.date(from: stamp) ?? fractional.date(from: stamp) ?? local.date(from: stamp))?.timeIntervalSince1970
    }
}
