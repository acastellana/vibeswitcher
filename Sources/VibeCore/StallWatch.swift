import Foundation

/// A run that makes no progress is stopped in minutes, not at its 45–60 min timeout: no new output and almost no CPU in
/// its process tree for `after` while the Mac's 1-minute load is under `loadLimit` (load_threshold). Five test runs
/// in two days (2026-11-05 and 06) sat at 0 % CPU for 30–60 minutes, one at load 4.2 on 12 cores, each holding a
/// Mac-wide heavy slot and the merge queue until test_timeout_min or vs-heavy's --timeout ended them; the witness said
/// "idle N min" and nothing acted on it. A loaded Mac starving a run isn't a hang: while the load is at or above the
/// limit, the run's silence isn't counted. `Shell.run` looks every `every` (`Watch`); vs-heavy's supervisor does the
/// same for its command (`stall_min`, VIBESWITCHER_HEAVY_STALL).
public struct StallWatch: Sendable {
    /// No progress this long is a hang (stall_min).
    public var after: TimeInterval
    /// How often the run is looked at.
    public var every: TimeInterval
    /// At or above this 1-minute load the Mac is too loaded to judge: silence then isn't counted.
    public var loadLimit: Double
    /// The Mac's 1-minute load (tests give their own); nil when it can't be read, which judges as unloaded.
    public var load: @Sendable () -> Double?

    /// stall_min's default, in minutes.
    public static let defaultMinutes: Double = 10
    /// Less CPU than this share of a core, over a look's span, is no progress (vs-heavy's .active note uses the same).
    public static let cpuShare = 0.01

    public init(after: TimeInterval, every: TimeInterval = 30, loadLimit: Double,
                load: @escaping @Sendable () -> Double? = { MacLoad.oneMinute() }) {
        self.after = after
        self.every = max(0.05, min(every, after / 4))
        self.loadLimit = loadLimit
        self.load = load
    }

    /// What one look at the run saw.
    public struct Look: Equatable, Sendable {
        /// Bytes of output so far.
        public var output: Int
        /// CPU seconds of each process in its tree, by pid; nil when the process table couldn't be read.
        public var cpu: [Int32: Double]?
        /// The Mac's 1-minute load; nil when it couldn't be read.
        public var load: Double?

        public init(output: Int, cpu: [Int32: Double]?, load: Double?) {
            self.output = output
            self.cpu = cpu
            self.load = load
        }
    }

    /// The judgement, look by look: pure, so a test drives it with its own clock.
    public struct Judge: Sendable {
        public let after: TimeInterval
        public let loadLimit: Double
        /// When it last progressed (or was last too loaded to judge, or started).
        public private(set) var since: Date
        private var last: (at: Date, look: Look)?

        public init(after: TimeInterval, loadLimit: Double, start: Date) {
            self.after = after
            self.loadLimit = loadLimit
            since = start
        }

        /// Takes in a look at `now`; true once the run has made no progress for `after`. Progress: its output grew,
        /// its tree used `cpuShare` of a core or more since the last look, or a process appeared in it (CPU of one
        /// that came and went between looks isn't seen). A look whose process table couldn't be read counts as
        /// progress (nothing is stopped on what wasn't seen), and so do a load at or above `loadLimit` and a look
        /// half a stall after the last (the Mac slept through it).
        public mutating func observe(_ look: Look, at now: Date) -> Bool {
            defer { last = (now, look) }
            guard let last else { return now.timeIntervalSince(since) >= after }
            let span = max(0, now.timeIntervalSince(last.at))
            // A look half a stall late (the Mac slept, or the watcher was starved) saw nothing of the time between: a
            // fresh start, not silence. The watcher looks at least 4 times a stall (`StallWatch.every`).
            var progressed = span >= after / 2 || look.output != last.look.output || look.cpu == nil || last.look.cpu == nil
            if !progressed, let cpu = look.cpu, let before = last.look.cpu {
                let used = cpu.reduce(0.0) { $0 + max(0, $1.value - (before[$1.key] ?? 0)) }
                let appeared = cpu.keys.contains { before[$0] == nil }
                progressed = appeared || used >= StallWatch.cpuShare * span
            }
            if let load = look.load, load >= loadLimit { progressed = true }
            if progressed { since = now }
            return now.timeIntervalSince(since) >= after
        }

        /// How long it has made no progress, at `now`.
        public func idle(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(since)) }
    }

    /// A run it stopped: what it was stuck on, for the caller to report.
    public struct Stall: Equatable, Sendable {
        /// How long it had made no progress.
        public var idle: TimeInterval
        /// The Mac's 1-minute load when it was stopped (nil: unread), and the limit it was under.
        public var load: Double?
        public var loadLimit: Double
        /// The last test its output shows executing when it was stopped (`MergeRerun.running`); nil when none is or
        /// the output can't say. Never a test whose "started" is all that's known of it: Swift Testing prints that before
        /// a test gets a slot, so among several unfinished the last to print is likelier queued than stuck, and this
        /// name goes in the flake ledger, where three of them plan a task to fix an innocent test.
        public var lastTest: String?
        /// How many tests its output shows started and unfinished when it can't say which were executing; 0 when it can.
        public var unknownTests = 0
        /// Its processes when it was stopped: "pid ppid state cpu name" lines.
        public var processes: [String]
        /// Its output's last lines.
        public var tail: [String]

        /// "no progress for 10 min (no new output, under 1 % of a core, at load 4.2 under load_threshold 24; last test
        /// started: Suite/test())": what the caller says first.
        public var summary: String {
            let load = self.load.map { "at load \(MacLoad.number($0)) under load_threshold \(MacLoad.number(loadLimit))" }
                ?? "load unread, load_threshold \(MacLoad.number(loadLimit))"
            return "no progress for \(Worktrees.duration(idle)) (no new output and under 1 % of a core, \(load)); "
                + (lastTest.map { "last test started: \($0)" }
                    ?? (unknownTests > 0 ? MergeRerun.cantTell(unknownTests) : "no test in its output started and never finished"))
        }

        /// How the report's first line starts, which is how what reads a stopped run's output finds where the run's own
        /// ended (`MergeRerun.openTests`): the report repeats its last lines.
        public static let reportStart = "Stopped: no progress for "

        /// The whole report: the summary, its processes and its output's last lines.
        public var report: String {
            var text = "Stopped: \(summary).\n"
            if !processes.isEmpty {
                text += "Its processes when stopped (pid, parent, state, CPU seconds, name):\n" + processes.map { "    " + $0 }.joined(separator: "\n") + "\n"
            }
            if !tail.isEmpty {
                text += "Its output's last \(tail.count) lines:\n" + tail.map { "    " + $0 }.joined(separator: "\n") + "\n"
            }
            return text
        }
    }

    /// The last test `output` shows executing (`Stall.lastTest`), how many it can't tell apart (`Stall.unknownTests`),
    /// and its last `count` non-empty lines.
    static func stuck(in output: String, count: Int = MergeRerun.hungTail) -> (test: String?, unknown: Int, tail: [String]) {
        let lines = Platform.lines(output)
            .map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        let tail = Array(lines.reversed().drop { $0.isEmpty }.prefix(count).reversed())
        let running = MergeRerun.running(in: lines.joined(separator: "\n"))
        return (running.named.last, running.unknown, tail)
    }

    // MARK: A run's process tree

    /// One process of a run's tree.
    struct Member: Equatable {
        var pid: Int32
        var ppid: Int32
        var state: String
        var cpu: Double
        var name: String
    }

    /// The processes of `root`'s tree: its descendants and the members of its process group `group`, the user's
    /// own only, with their CPU seconds; nil when the process list couldn't be read. Never asks another process
    /// anything (no task port): the kernel's records only.
    static func tree(of root: Int32, group: Int32?) -> [Member]? {
        guard let pids = ProcessTable.allPids() else { return nil }
        let me = getuid()
        var all: [Int32: (ppid: Int32, pgid: Int32, state: String, name: String)] = [:]
        for pid in pids {
            guard case .record(let info) = Platform.Processes.record(pid), info.uid == me else { continue }
            all[pid] = (info.ppid, info.pgid, state(info.state), info.longName)
        }
        var family: [Int32] = all[root] == nil ? [] : [root], index = 0
        while index < family.count {
            let parent = family[index]
            family += all.filter { $0.value.ppid == parent && $0.key != parent && !family.contains($0.key) }.keys.sorted()
            index += 1
        }
        if let group { family += all.filter { $0.value.pgid == group && !family.contains($0.key) }.keys.sorted() }
        return family.compactMap { pid in
            guard let record = all[pid] else { return nil }
            let cpu = Platform.Processes.cpuSeconds(pid) ?? 0
            return Member(pid: pid, ppid: record.ppid, state: record.state, cpu: cpu, name: record.name)
        }
    }

    private static func state(_ status: Platform.Processes.State) -> String {
        switch status {
        case .starting: return "starting"
        case .running: return "running"
        case .sleeping: return "sleeping"
        case .stopped: return "stopped"
        case .zombie: return "zombie"
        case .unknown: return "?"
        }
    }

    /// The lines a stall's report lists its processes in.
    static func lines(_ members: [Member]) -> [String] {
        members.map { "\($0.pid) \($0.ppid) \($0.state) \(String(format: "%.1f", $0.cpu)) \($0.name)" }
    }
}
