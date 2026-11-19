import Darwin
import Foundation

/// The memory benches, run by the app itself once a day on a calm Mac (books-patterns shortlist item 5, approved
/// 2026-11-18): memory growth needed 9 tasks from October to November, each found in the field a day late, while the
/// budgets that would have caught it ran only by hand (`scripts/test.sh --perf`). A deterministic job, no agent or model:
/// main's head checked out in a scratch worktree under VibeSwitcher's own folder (`Run`), the benches run there under
/// `vs-heavy` with a timeout, one JSON line appended to `~/.vibeswitcher/stats/memory-bench.jsonl` (`Record`), and a failing
/// budget told in the app-health report (`AppHealth.Watch`), with the commits since the last pass.
///
/// When (`decide`): at most once a day (a later local day and at least `minimumGap` since the last run began), only
/// with the Mac on AC power, awake (`awakeAfterWake` past its last wake), calm (its 1- and 5-minute load both under
/// `calmLoad`: the load recorder's nights, 02:00–06:00, sit at 2–3 on 12 cores), a heavy slot free, and no merge's tests
/// running or waiting for one. A run under way is given up when that changes (power, a merge, sleep, the setting
/// turned off; `stillFine`): nothing is recorded, and it's tried again `retryAfter` later, once the conditions hold.
public enum MemoryBench {
    /// The benches it runs: `scripts/test.sh --perf` with this filter (the two that judge the app's footprint).
    public static let filter = "FootprintBenchTests|SandboxSoakBenchTests"
    /// `--perf` puts its own filter of every bench before ours, and Swift Testing runs a test any filter matches: this
    /// skips every test whose name has neither suite's.
    public static let skip = "^(?!.*(FootprintBenchTests|SandboxSoakBenchTests))"
    /// Both the 1- and the 5-minute load under this is calm.
    public static let calmLoad = 4.0
    /// A run gives way to the next only on a later day and this long after it began.
    public static let minimumGap: TimeInterval = 12 * 3600
    /// After a run given up, the next try waits at least this long.
    public static let retryAfter: TimeInterval = 30 * 60
    /// After a wake, the Mac is taken as awake once this has passed (the load averages still carry the sleep).
    public static let awakeAfterWake: TimeInterval = 10 * 60
    /// vs-heavy's --timeout for the run (a build from nothing, the footprint bench and the soak's ~15 of its 18 minutes
    /// took about 18 on 2026-11-19; the soak's guard is ~34 at most).
    public static let timeoutMinutes = 90
    /// The stats file, in `VibePaths.statsDir`: one line a run, kept (a few hundred bytes a day).
    public static let statsName = "memory-bench.jsonl"
    /// The folder of its own under VibeSwitcher's (`VibePaths.root`): the scratch worktree, the last run's output and
    /// the schedule's state.
    public static let folderName = "memory-bench"

    // MARK: Budgets

    /// One budget as a bench judged it, printed as a line of its output (`line`) and read back here (`parse`): the
    /// limits stay in the benches, and what the run records is what the code that ran judged.
    public struct Budget: Codable, Equatable, Sendable {
        /// "footprint-window-closed-mb".
        public var name: String
        /// nil: the bench gave no number.
        public var value: Double?
        public var limit: Double
        /// "MB", "%", "MB/h", "count".
        public var unit: String
        /// nil: not judged (the Mac too loaded for the bench to judge it).
        public var pass: Bool?

        public init(name: String, value: Double?, limit: Double, unit: String, pass: Bool?) {
            self.name = name
            self.value = value
            self.limit = limit
            self.unit = unit
            self.pass = pass
        }

        /// A judged budget: `pass` when `value` is there and `within` says so.
        public init(name: String, value: Double?, limit: Double, unit: String, judged: Bool, within: (Double) -> Bool) {
            self.init(name: name, value: value, limit: limit, unit: unit, pass: judged ? value.map(within) ?? false : nil)
        }

        enum CodingKeys: String, CodingKey { case name, value, limit, unit, pass }

        /// `pass` is always written: null for a budget not judged, so every budget says pass, fail or neither.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(value, forKey: .value)
            try container.encode(limit, forKey: .limit)
            try container.encode(unit, forKey: .unit)
            try container.encode(pass, forKey: .pass)
        }

        static let prefix = "BUDGET "

        /// "BUDGET footprint-window-closed-mb 72.4 150 MB pass" (or "n/a" for no value, "unjudged" for no verdict).
        public var line: String {
            Self.prefix + [name, value.map(Self.number) ?? "n/a", Self.number(limit), unit, pass.map { $0 ? "pass" : "fail" } ?? "unjudged"]
                .joined(separator: " ")
        }

        /// The budgets in a run's output, the last line of each name kept.
        public static func parse(_ output: String) -> [Budget] {
            var found: [String: Budget] = [:]
            var order: [String] = []
            for raw in output.split(whereSeparator: \.isNewline) {
                guard let start = raw.range(of: prefix) else { continue }
                let words = raw[start.upperBound...].split(separator: " ").map(String.init)
                guard words.count == 5, safeName(words[0]), safeName(words[3]), let limit = Double(words[2]),
                      words[1] == "n/a" || Double(words[1]) != nil, ["pass", "fail", "unjudged"].contains(words[4]) else { continue }
                let budget = Budget(name: words[0], value: Double(words[1]), limit: limit, unit: words[3],
                                    pass: words[4] == "unjudged" ? nil : words[4] == "pass")
                if found[budget.name] == nil { order.append(budget.name) }
                found[budget.name] = budget
            }
            return order.compactMap { found[$0] }
        }

        /// Names and units are a few plain characters: nothing else of the output reaches the record.
        static func safeName(_ word: String) -> Bool {
            !word.isEmpty && word.count <= 48 && word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_/%".contains($0)) }
        }

        /// To 2 decimals at most, without trailing zeros: "150", "72.4", "12.35".
        static func number(_ value: Double) -> String {
            guard value.isFinite, abs(value) < 1e12 else { return "n/a" }
            var text = String(format: "%.2f", value)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return text == "-0" ? "0" : text
        }

        /// "footprint-window-closed-mb 162.4 MB, limit 150 MB".
        public var text: String {
            let unit = self.unit == "count" ? "" : " " + self.unit
            return "\(name) \(value.map(Self.number) ?? "no number")\(unit), limit \(Self.number(limit))\(unit)"
        }
    }

    // MARK: The record

    /// One run's line of `memory-bench.jsonl`.
    public struct Record: Codable, Equatable, Sendable {
        /// When it began (`LoadStats.stamp`) and its local day.
        public var t: String
        public var day: String
        /// The commit benched: main's head as it began.
        public var commit: String
        /// "pass" (every budget judged and within), "fail" (one judged over), "unjudged" (none over, one or more not
        /// judged), "error" (no budgets, the tests failed otherwise, or it ran past its time).
        public var result: String
        public var durationS: Int
        public var budgets: [Budget]
        /// The 1-, 5- and 15-minute load as it began.
        public var load: [Double]?
        /// Why it's an error, in a few words.
        public var note: String?
        /// On a fail: the last passing run's commit, and the subjects of the commits since it (newest first, at most
        /// `sinceLimit`); nil when no run has passed yet.
        public var lastPass: String?
        public var sincePass: [String]?

        public init(t: String, day: String, commit: String, result: String, durationS: Int, budgets: [Budget], load: [Double]? = nil,
                    note: String? = nil, lastPass: String? = nil, sincePass: [String]? = nil) {
            self.t = t
            self.day = day
            self.commit = commit
            self.result = result
            self.durationS = durationS
            self.budgets = budgets
            self.load = load
            self.note = note
            self.lastPass = lastPass
            self.sincePass = sincePass
        }

        /// What the budgets and the run's end make it.
        public static func result(budgets: [Budget], exitStatus: Int32, timedOut: Bool) -> (result: String, note: String?) {
            if timedOut { return ("error", "ran past \(MemoryBench.timeoutMinutes) min and was stopped") }
            if budgets.contains(where: { $0.pass == false }) { return ("fail", nil) }
            if budgets.isEmpty { return ("error", "the benches printed no budget (exit \(exitStatus))") }
            if exitStatus != 0 { return ("error", "the benches' tests failed otherwise (exit \(exitStatus))") }
            return budgets.contains(where: { $0.pass == nil }) ? ("unjudged", nil) : ("pass", nil)
        }

        public var failing: [Budget] { budgets.filter { $0.pass == false } }

        public func line() throws -> String { try LoadStats.line(self) }

        public static func decode(_ line: Substring) -> Record? {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode(Record.self, from: Data(line.utf8))
        }

        /// The records of a stats file, oldest first (lines that don't read as one are passed over).
        public static func all(in file: URL) -> [Record] {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline).compactMap(decode)
        }
    }

    /// How many commit subjects a failing record carries at most.
    public static let sinceLimit = 30

    // MARK: When

    /// What the Mac is doing now, as the schedule needs it.
    public struct Conditions: Equatable, Sendable {
        /// nil: the power source didn't say (taken as battery).
        public var onAC: Bool?
        /// The 1-, 5- and 15-minute load; nil when unread.
        public var load: [Double]?
        /// Awake for `awakeAfterWake` or more, and not going to sleep.
        public var awake: Bool
        /// A heavy slot nobody holds.
        public var slotFree: Bool
        /// A merge's tests holding a slot or waiting for one: who, as their note says.
        public var merge: String?

        public init(onAC: Bool?, load: [Double]?, awake: Bool, slotFree: Bool, merge: String?) {
            self.onAC = onAC
            self.load = load
            self.awake = awake
            self.slotFree = slotFree
            self.merge = merge
        }
    }

    /// What's kept across launches (`state.json` in its folder).
    public struct State: Codable, Equatable, Sendable {
        /// When the last run that finished (recorded) began.
        public var lastRun: Double?
        /// When a run was last given up.
        public var gaveUp: Double?
        public init(lastRun: Double? = nil, gaveUp: Double? = nil) {
            self.lastRun = lastRun
            self.gaveUp = gaveUp
        }
    }

    public enum Decision: Equatable, Sendable {
        case run
        /// Not now, and why ("not on AC power").
        case wait(String)
    }

    /// Whether to start a run now.
    public static func decide(now: Date, state: State, conditions: Conditions, calendar: Calendar = .current) -> Decision {
        if let last = state.lastRun.map(Date.init(timeIntervalSince1970:)) {
            if calendar.isDate(last, inSameDayAs: now) { return .wait("ran today") }
            if now.timeIntervalSince(last) < minimumGap { return .wait("ran under \(Int(minimumGap / 3600)) h ago") }
        }
        if let gaveUp = state.gaveUp, now.timeIntervalSince1970 - gaveUp < retryAfter {
            return .wait("gave up under \(Int(retryAfter / 60)) min ago")
        }
        if let why = unfit(conditions) { return .wait(why) }
        guard let load = conditions.load, load.count >= 2 else { return .wait("the load wasn't read") }
        guard load[0] < calmLoad, load[1] < calmLoad else {
            return .wait(String(format: "not calm: load %.2f, %.2f (calm is under %.0f)", load[0], load[1], calmLoad))
        }
        guard conditions.slotFree else { return .wait("no heavy slot free") }
        return .run
    }

    /// Why a run under way stops (nil: it goes on). The load and the slots aren't looked at: the run makes the load and
    /// holds a slot itself.
    public static func stillFine(_ conditions: Conditions) -> String? { unfit(conditions) }

    private static func unfit(_ conditions: Conditions) -> String? {
        if conditions.onAC != true { return conditions.onAC == nil ? "the power source didn't say AC" : "on battery" }
        if !conditions.awake { return "the Mac isn't awake (or woke under \(Int(awakeAfterWake / 60)) min ago)" }
        if let merge = conditions.merge { return "a merge's tests run: \(merge)" }
        return nil
    }

    /// The prefixes of what merges' runs call themselves in their slot's note (`Worktrees.runChecks`' holder).
    static let mergeRuns = ["VibeSwitcher's merge test of ", "VibeSwitcher's batch merge test of ", "VibeSwitcher's revert test of "]

    /// A merge's tests among a lock's holders and waiters: who, or nil.
    public static func merge(holders: [TestLock.Holder], waiters: [TestLock.Waiter]) -> String? {
        let whats = holders.compactMap(\.what) + waiters.compactMap(\.who.what)
        return whats.first { what in mergeRuns.contains { what.hasPrefix($0) } }
    }
}
