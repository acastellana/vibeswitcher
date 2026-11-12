import Foundation

/// Tests a merge found red on the base itself: its rerun failed on them, and so did the same run on the base
/// (`MergeRerun.redOnBase`). They send no branch back. `all`: they were the whole failure, so a merge can't tell a
/// branch's failure from the base's while they're red, and auto_advance holds merges but their fixes' until the base
/// moves by more than the lead's records commits, or a fix lands (`holds`, `LeadToolset.mainRedLifted`).
public struct LeadMainRed: Codable, Equatable, Sendable {
    public var tests: [String]
    /// The base's commit the tests failed on.
    public var onto: String
    public var at: Double
    public var all: Bool
    /// The tasks planned (or open already) to fix them.
    public var fixes: [String]
    /// The first failing lines of the base's run, masked and capped (`MergeRerun.capped`).
    public var lines: [String]

    public init(tests: [String], onto: String, at: Double, all: Bool, fixes: [String], lines: [String]) {
        self.tests = tests
        self.onto = onto
        self.at = at
        self.all = all
        self.fixes = fixes
        self.lines = lines
    }

    /// Whether it holds a merge of `slug`: the whole failure, not lifted (`lifted`: a fix landed, or the base moved by
    /// more than the lead's records commits), and `slug` not one of the fixes.
    public func holds(_ slug: String, lifted: Bool) -> Bool { all && !lifted && !fixes.contains(slug) }

    /// "main is red: a(), b()" with its first failing lines, as the lead is told.
    public func text(base: String) -> String {
        "\(base) is red: \(tests.joined(separator: ", ")) failed a merge's run, its rerun and the same run on \(base) (\(onto.prefix(8))), so no branch is sent back for them."
            + (lines.isEmpty ? "" : " Their first failing lines on \(base):\n" + lines.map { "    " + $0 }.joined(separator: "\n") + "\n")
            + (fixes.isEmpty ? "" : " To fix first: \(fixes.joined(separator: ", ")) (at the front of the plan).")
            + (all ? " Until one lands (or \(base) moves), auto_advance merges only the fix: every other merge would fail on them too." : "")
    }
}

/// The pipeline watch: finished work that stops landing is seen within minutes, its cause named, and the lead told
/// once (again at most every `repeatEvery` while it lasts), rather than finding out from the user hours later. On
/// 2026-11-12 a lint failure in the lead's own record held every merge from about 11:00 to 13:45 while four tasks sat
/// ready to merge. A look is pure: the board, the clock and what VibeSwitcher sees of the Mac (`Signals`) in, what to say
/// out; the tool server gathers the signals (`LeadToolset.pipelineSignals`) and auto_advance arms the next look.
public enum LeadPipeline {
    /// How long a task may be ready to merge with no merge landing before the lead is told.
    public static let stallAfter: TimeInterval = 20 * 60
    /// The least time between two reports of one stall.
    public static let repeatEvery: TimeInterval = 30 * 60

    /// When the lead was last told, and the stall it was told of (when it began).
    public struct Told: Codable, Equatable, Sendable {
        public var at: Double
        public var since: Double
        public var cause: String

        public init(at: Double, since: Double, cause: String) {
            self.at = at
            self.since = since
            self.cause = cause
        }
    }

    /// What VibeSwitcher sees that may hold merges, gathered when the watch looks.
    public struct Signals: Equatable, Sendable {
        /// The base's head now.
        public var head: String?
        /// The board's `mainRed` still holds merges (`LeadToolset.mainRedLifted` says it isn't lifted).
        public var mainRedHolds = false
        /// What the lead's records fail on, by the lints that read them (`RecordLint`): "docs/lead/progress.md:12 (PrivateNamesLint)".
        public var records: [String] = []
        /// The test lock's slots and who holds each for how long (`TestLock.text(_:for:)`: another project's run named
        /// by no name, since the report may reach the records), when every one is held.
        public var slotsHeld: (slots: Int, said: String)?
        /// The Mac's load and load_threshold, while the load holds merges.
        public var loadHold: (load: Double, threshold: Double)?
        /// The gate code on the base the running build lacks (`LeadToolset.gateLag`), in words.
        public var gateLag: String?
        /// A merge under way: its tasks and when it started.
        public var merging: (tasks: [String], since: Date)?
        /// Recent merges' durations (seconds), for an estimate of when the one under way ends.
        public var recentDurations: [Double] = []
        /// When the last merge landed (any task's, archived ones too).
        public var lastMerge: Date?

        public init(head: String? = nil, records: [String] = [], slotsHeld: (slots: Int, said: String)? = nil,
                    loadHold: (load: Double, threshold: Double)? = nil, gateLag: String? = nil, merging: (tasks: [String], since: Date)? = nil,
                    recentDurations: [Double] = [], lastMerge: Date? = nil) {
            self.head = head
            self.records = records
            self.slotsHeld = slotsHeld
            self.loadHold = loadHold
            self.gateLag = gateLag
            self.merging = merging
            self.recentDurations = recentDurations
            self.lastMerge = lastMerge
        }

        public static func == (lhs: Signals, rhs: Signals) -> Bool {
            lhs.head == rhs.head && lhs.mainRedHolds == rhs.mainRedHolds && lhs.records == rhs.records && lhs.slotsHeld?.slots == rhs.slotsHeld?.slots
                && lhs.slotsHeld?.said == rhs.slotsHeld?.said && lhs.loadHold?.load == rhs.loadHold?.load
                && lhs.loadHold?.threshold == rhs.loadHold?.threshold && lhs.gateLag == rhs.gateLag
                && lhs.merging?.tasks == rhs.merging?.tasks && lhs.merging?.since == rhs.merging?.since
                && lhs.recentDurations == rhs.recentDurations && lhs.lastMerge == rhs.lastMerge
        }
    }

    /// What holds the merges, most decisive first.
    public enum Cause: String, Equatable, Sendable {
        case mainRed = "main red", records = "the lead's records failing a check", slots = "every test slot held",
             load = "the load hold", gate = "the gate not installed", merging = "a merge in progress", unknown = "nothing VibeSwitcher sees"
    }

    /// A look's result.
    public struct Look: Equatable, Sendable {
        /// The tasks ready to merge, with no merge landing, for `stallAfter` or longer, oldest first.
        public var stalled: [String]
        /// When the stall began: the oldest such task's ready time, or the last merge's landing when that's later.
        public var since: Date?
        public var cause: Cause?
        /// The report (and status line), naming the cause and the one action needed.
        public var text: String?
        /// Tell the lead now (first report of this stall, or `repeatEvery` since the last).
        public var tell: Bool
        /// When to look again: the next task's `stallAfter` mark, or the next report's due time; nil: nothing waits.
        public var next: Date?
    }

    /// When `task` became ready to merge, by the board: in review with a passing verdict (its time), or review none with
    /// its done report in and no audit needed (when it took the review status). Nil when it isn't ready.
    public static func readySince(_ task: LeadTask) -> Date? {
        guard task.status == .review else { return nil }
        if let evidence = task.evidence, evidence.passes { return Date(timeIntervalSince1970: evidence.at) }
        if task.reviewLevel == .none, task.verifier == nil, task.evidence == nil, task.auditNeeded == nil, task.riskRaised == nil {
            return Date(timeIntervalSince1970: task.since ?? task.createdAt)
        }
        return nil
    }

    /// The watch's look at `board` at `now` (see the type's comment).
    public static func look(_ board: LeadBoard, signals: Signals, base: String, now: Date) -> Look {
        let ready = board.tasks.compactMap { task in readySince(task).map { (task.slug, $0) } }.sorted { $0.1 < $1.1 }
        // Ready, with no merge landing, for at least `stallAfter`: from when it was ready or the last merge landed,
        // whichever is later. A task ready before a merge of others landed stalls 20 min after that merge.
        let waiting = { (ready: Date) -> Date in signals.lastMerge.map { max(ready, $0) } ?? ready }
        let stalled = ready.filter { _, since in now.timeIntervalSince(waiting(since)) >= stallAfter }
        guard let first = stalled.first else {
            // The next one to reach its mark (no merge landing meanwhile).
            let next = ready.map { waiting($0.1).addingTimeInterval(stallAfter) }.filter { $0 > now }.min()
            return Look(stalled: [], since: nil, cause: nil, text: nil, tell: false, next: next)
        }
        let since = waiting(first.1)
        let (cause, said) = cause(board, signals: signals, base: base, now: now)
        let names = stalled.map(\.0)
        let waited = Worktrees.duration(now.timeIntervalSince(since))
        let text = "Merges are held: \(names.joined(separator: ", ")) \(names.count == 1 ? "has" : "have") been ready to merge for \(waited) with no merge landing. Cause: \(cause.rawValue). " + said
        // One stall lasts until a merge lands: its oldest task changing (sent back, verified again, a batch's split) is
        // the same stall, told at most every `repeatEvery`. A merge landing after the last report ended that one.
        let told = board.pipeline.flatMap { told in (signals.lastMerge.map { $0.timeIntervalSince1970 > told.at } ?? false) ? nil : told }
        let tell = told.map { now.timeIntervalSince1970 - $0.at >= repeatEvery } ?? true
        let next = tell ? now.addingTimeInterval(repeatEvery) : Date(timeIntervalSince1970: told!.at + repeatEvery)
        return Look(stalled: names, since: since, cause: cause, text: text, tell: tell, next: next)
    }

    /// What holds the merges, and the one action needed, in words.
    static func cause(_ board: LeadBoard, signals: Signals, base: String, now: Date) -> (Cause, String) {
        if let red = board.mainRed, red.all, signals.mainRedHolds {
            let fix = red.fixes.first.map { "Get \($0) done first (it's at the front of the plan); merges wait on it." } ?? "Plan a task to fix them first."
            return (.mainRed, "\(base) is red: \(red.tests.joined(separator: ", ")) fail on \(base) itself (\(red.onto.prefix(8))), so every merge fails on them. " + fix)
        }
        if !signals.records.isEmpty {
            return (.records, "The lead's records fail the repository's lints, so every merge's test run fails: \(signals.records.prefix(5).joined(separator: "; ")). "
                    + "Clear each with redact_record(file, line, text); the records commit carries it before the next merge starts.")
        }
        if let (slots, held) = signals.slotsHeld {
            return (.slots, "Every one of the \(slots) Mac-wide test slot\(slots == 1 ? " is" : "s are") held: \(held). "
                    + "The merge waits for one; run fewer sessions at once (or stop a long run) to free one.")
        }
        if let (load, threshold) = signals.loadHold {
            return (.load, "The Mac's load (\(MacLoad.number(load))) is over load_threshold (\(MacLoad.number(threshold))), so merges wait for it to drop. "
                    + "Run fewer sessions at once, or raise load_threshold with configure if the Mac copes.")
        }
        if let (tasks, started) = signals.merging {
            let running = now.timeIntervalSince(started)
            let typical = median(signals.recentDurations)
            let eta = typical.map { typical -> String in
                let left = typical - running
                return left > 0 ? "; recent merges took about \(Worktrees.duration(typical)), so it should end in about \(Worktrees.duration(left))"
                    : "; recent merges took about \(Worktrees.duration(typical)), so it's past its usual time"
            } ?? ""
            return (.merging, "A merge of \(tasks.joined(separator: ", ")) has been running for \(Worktrees.duration(running))\(eta). The rest merge after it; nothing to do unless it hangs.")
        }
        if let lag = signals.gateLag {
            return (.gate, lag + " Ask the user to install the app from \(base) (scripts/build-app.sh --install).")
        }
        return (.unknown, "VibeSwitcher sees nothing holding them (no merge running, slots free, load low): status says each task's last merge refusal; merge one by hand to see why.")
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
}
