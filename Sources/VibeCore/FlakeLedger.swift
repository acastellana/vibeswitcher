import Foundation

/// A fix task's merge: the test it was planned for (`LeadFlake.planned`), now fixed by it. A later flake of that test
/// is a recurrence, and the lead is told once, naming the fix (`FlakeLedger.recordFlakes`). On 2026-11-07 4 of 16
/// fix-the-flaky-test merges had flaked again, and nobody noticed.
public struct LeadFlakeFix: Codable, Equatable, Sendable {
    public var test: String
    /// The task that fixed it, and the commit it merged as.
    public var fixedBy: String
    public var commit: String
    public var at: Double

    public init(test: String, fixedBy: String, commit: String, at: Double) {
        self.test = test
        self.fixedBy = fixedBy
        self.commit = commit
        self.at = at
    }
}

/// A merge whose first test run failed, so its failing tests (or the whole command) ran once more (`MergeRerun`):
/// what reran and whether it passed, and the paired run of the failing tests on the base it was rebased onto. Record
/// only: none of this decides a merge. It's what the lead decides from whether a filtered rerun is a coin flip (it
/// passes more often than a whole one) and whether a branch's red test is the branch's (green on the base) or flaky
/// (red there too).
public struct LeadRerunRecord: Codable, Equatable, Sendable {
    /// The paired base run's outcome.
    public enum Base: String, Codable, Sendable {
        /// The failing tests failed on the base too: flaky, or broken before the branch.
        case red
        /// They passed on the base: the branch's.
        case green
        /// The base doesn't have them (its filtered run showed none of them run): a branch's new tests.
        case absent
        /// Not run: why is in `baseNote` (the Mac over load_threshold, a whole rerun, the base's checkout failed).
        case skipped
        /// Stopped by the test timeout or for making no progress.
        case hung
    }

    /// The task whose merge it was (a batch's stack: its top), and the commit tested.
    public var task: String
    public var commit: String
    public var at: Double
    /// The failing tests, as the first run named them (empty when it named none).
    public var tests: [String]
    /// The rerun ran only them (`--filter`); false: the whole test command.
    public var filtered: Bool
    /// The rerun passed, so the merge went ahead on it.
    public var passed: Bool
    /// The Mac's 1-minute load average when the merge's run started.
    public var load: Double?
    /// The paired run on the base: its commit, how it went, and why it didn't run, when it didn't.
    public var baseCommit: String?
    public var base: Base?
    public var baseNote: String?

    public init(task: String, commit: String, at: Double, tests: [String], filtered: Bool, passed: Bool, load: Double? = nil,
                baseCommit: String? = nil, base: Base? = nil, baseNote: String? = nil) {
        self.task = task
        self.commit = commit
        self.at = at
        self.tests = tests
        self.filtered = filtered
        self.passed = passed
        self.load = load
        self.baseCommit = baseCommit
        self.base = base
        self.baseNote = baseNote
    }
}

/// The flake ledger, as `FlakeLedgerStore` reads it: its flakes, the fixes merged for them and the merges' reruns, each
/// oldest first. Uncapped: board.json kept the last 200 flakes, too few to tell how often a fixed test flakes again.
public struct FlakeLedger: Equatable, Sendable {
    public var flakes: [LeadFlake] = []
    public var fixes: [LeadFlakeFix] = []
    public var reruns: [LeadRerunRecord] = []

    public init(flakes: [LeadFlake] = [], fixes: [LeadFlakeFix] = [], reruns: [LeadRerunRecord] = []) {
        self.flakes = flakes
        self.fixes = fixes
        self.reruns = reruns
    }

    /// A test that flaked `flakeLimit` times within `flakeWindow` since a task was last planned for it.
    public typealias Due = (test: String, merges: [String], flakes: [LeadFlake])
    /// A test that flaked again after `fix` merged to fix it, told to the lead once (`LeadFlake.recurred`).
    public typealias Recurrence = (test: String, fix: LeadFlakeFix)

    /// Records each of `tests` as having flaked in `task`'s merge (tested at `commit`, the 1-minute `load` when its run
    /// started, its rerun `filtered` or whole), those in `logged` with the `log` that keeps their lines. Returns those
    /// that flaked `LeadBoard.flakeLimit` times within `LeadBoard.flakeWindow` since a task was last planned for them,
    /// each with the merges it held up and those flakes (oldest first): the caller plans one task each and marks it
    /// (`notePlanned`), so a test makes one task, not one per flake. And those that flaked for the first time since a
    /// fix for them merged (`fixes`): each is marked on its flake (`recurred`), so the lead is told once per fix. A
    /// flake recorded under `MergeRerun.unnamed` names no test, and plans and recurs nothing.
    public mutating func recordFlakes(_ tests: [String], task: String, commit: String, now: Double, logged: Set<String> = [],
                                      log: String? = nil, load: Double? = nil, filtered: Bool? = nil) -> (due: [Due], recurred: [Recurrence]) {
        var due: [Due] = []
        var recurred: [Recurrence] = []
        for test in tests {
            var flake = LeadFlake(test: test, task: task, commit: commit, at: now, log: logged.contains(test) ? log : nil)
            flake.load = load
            flake.filtered = filtered
            if test != MergeRerun.unnamed, let fix = fixes.last(where: { $0.test == test && $0.at <= now }),
               !flakes.contains(where: { $0.test == test && $0.recurred == fix.fixedBy }) {
                flake.recurred = fix.fixedBy
                recurred.append((test, fix))
            }
            flakes.append(flake)
            guard test != MergeRerun.unnamed else { continue }
            let since = flakes.last { $0.test == test && $0.planned != nil }?.at ?? -.infinity
            let counted = flakes.filter { $0.test == test && $0.at > since && now - $0.at <= LeadBoard.flakeWindow }
            if counted.count >= LeadBoard.flakeLimit { due.append((test, counted.map(\.task), counted)) }
        }
        return (due, recurred)
    }

    /// Marks `test`'s latest flake as the one `slug` was planned for.
    public mutating func notePlanned(_ slug: String, for test: String) {
        guard let index = flakes.lastIndex(where: { $0.test == test }) else { return }
        flakes[index].planned = slug
    }

    /// `slug` merged (as `commit`, at `now`): each test it was planned for (`notePlanned`) is fixed by it
    /// (`fixedBy`), once. Returns the fixes added.
    @discardableResult
    public mutating func noteFixed(_ slug: String, commit: String, now: Double) -> [LeadFlakeFix] {
        var added: [LeadFlakeFix] = []
        for flake in flakes where flake.planned == slug && !added.contains(where: { $0.test == flake.test })
            && !fixes.contains(where: { $0.test == flake.test && $0.fixedBy == slug }) {
            added.append(LeadFlakeFix(test: flake.test, fixedBy: slug, commit: commit, at: now))
        }
        fixes += added
        return added
    }

    /// For status: the tests that flaked within `flakeWindow` of `now`, the most flakes first, each with the merges
    /// it held up and the task planned for it (and fixed, flaked again since); nil when none did.
    public func flakeLine(now: Double) -> String? {
        let recent = flakes.filter { now - $0.at <= LeadBoard.flakeWindow }
        guard !recent.isEmpty else { return nil }
        var order: [String] = []
        for flake in recent.reversed() where !order.contains(flake.test) { order.append(flake.test) }
        let counts = Dictionary(grouping: recent, by: \.test)
        order.sort { counts[$0]!.count > counts[$1]!.count }
        let shown = order.prefix(8).map { test -> String in
            let found = counts[test]!
            let planned = flakes.last { $0.test == test && $0.planned != nil }?.planned
            let again = found.last { $0.recurred != nil }?.recurred.map { " (fixed by \($0), flaked again since)" } ?? ""
            return "\(test) ×\(found.count) (\(found.map(\.task).joined(separator: ", ")))" + (planned.map { " → task \($0)" } ?? "") + again
        }
        return "Flaky tests in the last \(Int(LeadBoard.flakeWindow / 86_400)) days (\(recent.count) flake\(recent.count == 1 ? "" : "s"): each failed a merge's test run, passed its rerun, and the merge went ahead; "
            + "\(LeadBoard.flakeLimit) of one test become a task to fix it): " + shown.joined(separator: "; ") + (order.count > 8 ? "; …" : "") + "."
    }

    /// For status: the merges that went to a rerun within `flakeWindow` of `now`, how often a filtered rerun passed
    /// against a whole one, and the paired base runs' results; nil when none went to a rerun.
    public func rerunLine(now: Double) -> String? {
        let recent = reruns.filter { now - $0.at <= LeadBoard.flakeWindow }
        guard !recent.isEmpty else { return nil }
        func rate(_ runs: [LeadRerunRecord]) -> String {
            guard !runs.isEmpty else { return "none ran" }
            let passed = runs.filter(\.passed).count
            return "\(passed) of \(runs.count) passed (\(Int((Double(passed) / Double(runs.count) * 100).rounded()))%)"
        }
        let filtered = recent.filter(\.filtered), whole = recent.filter { !$0.filtered }
        let red = recent.filter { $0.base == .red }.count, green = recent.filter { $0.base == .green }.count
        let unpaired = recent.count - red - green
        return "Merge reruns in the last \(Int(LeadBoard.flakeWindow / 86_400)) days (record only, nothing here decides a merge): \(recent.count) merge\(recent.count == 1 ? "" : "s") went to a rerun, \(recent.filter(\.passed).count) merged on it. "
            + "Filtered reruns (the failing tests only): \(rate(filtered)); whole reruns: \(rate(whole)). "
            + "The failing tests run once on the base: branch red/base green (the branch's) \(green), red on the base too (flaky) \(red)"
            + (unpaired > 0 ? ", not paired \(unpaired) (skipped, hung, or tests the base lacks)" : "") + "."
    }
}

/// The flake ledger on disk: `<repo>/.vibeswitcher/flakes/ledger.jsonl`, beside the flakes' evidence files, one entry
/// a line, only appended to: a flake (`LeadFlake`), a fix (`LeadFlakeFix`) or a merge's rerun (`LeadRerunRecord`),
/// each with its `kind`. Its own file, so a board rewrite never drops it and nothing caps it. Boards from before it
/// kept their flakes in board.json: `migrate` moves them here, once.
public final class FlakeLedgerStore: @unchecked Sendable {
    public static let path = ".vibeswitcher/flakes/ledger.jsonl"
    public let root: String
    public var file: String { (root as NSString).appendingPathComponent(Self.path) }
    var folder: String { (file as NSString).deletingLastPathComponent }
    let local = NSLock()

    public init(root: String) { self.root = root }

    /// The ledger; empty when there's none. A line that doesn't read (cut short by a crash, or a kind from a newer
    /// version) is skipped.
    public func load() -> FlakeLedger { Self.read(file) }

    /// The ledger at `file`, as `load` reads it.
    static func read(_ file: String) -> FlakeLedger {
        var ledger = FlakeLedger()
        guard let data = FileManager.default.contents(atPath: file) else { return ledger }
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            switch try? decoder.decode(Line.self, from: Data(line)) {
            case .flake(let flake): ledger.flakes.append(flake)
            case .fix(let fix): ledger.fixes.append(fix)
            case .rerun(let rerun): ledger.reruns.append(rerun)
            case nil: continue
            }
        }
        return ledger
    }

    /// Reads the ledger, changes it and appends what `change` added, under the ledger's lock (other processes too).
    /// Only appends: a change to an entry already there is lost, except `planned` on a flake `change` added.
    @discardableResult
    public func update<T>(_ change: (inout FlakeLedger) throws -> T) throws -> T {
        try locked {
            var ledger = load()
            let before = (ledger.flakes.count, ledger.fixes.count, ledger.reruns.count)
            let result = try change(&ledger)
            try write(flakes: Array(ledger.flakes.dropFirst(before.0)), fixes: Array(ledger.fixes.dropFirst(before.1)),
                      reruns: Array(ledger.reruns.dropFirst(before.2)))
            return result
        }
    }

    /// Appends `rerun`.
    public func append(_ rerun: LeadRerunRecord) throws {
        try locked { try write(reruns: [rerun]) }
    }

    /// Moves `board`'s flakes from before this file (board.json's `flakes`) here, once: those the file doesn't hold
    /// yet (a move cut short leaves no copies), and a fix for each test whose planned task (in `tasks`: the board's and
    /// the archive's) has merged. Then the board keeps none. Throws, the board as it was, when the file can't be written.
    public func migrate(_ board: inout LeadBoard, tasks: () -> [LeadTask]) throws {
        guard let legacy = board.flakes else { return }
        try update { ledger in
            let key = { (flake: LeadFlake) in "\(flake.test)\n\(flake.task)\n\(flake.commit)\n\(flake.at)" }
            let held = Set(ledger.flakes.map(key))
            // Lines a board kept from before evidence files are dropped on decode already; the rest move as they are.
            ledger.flakes += legacy.filter { !held.contains(key($0)) }
            let planned = Set(legacy.compactMap(\.planned)).sorted()
            let all = planned.isEmpty ? [] : board.tasks + tasks()
            for slug in planned {
                guard let merged = all.first(where: { $0.slug == slug && $0.merged != nil })?.merged,
                      merged.revertedBy == nil else { continue }
                ledger.noteFixed(slug, commit: merged.commit, now: merged.at)
            }
        }
        board.flakes = nil
    }

    private func write(flakes: [LeadFlake] = [], fixes: [LeadFlakeFix] = [], reruns: [LeadRerunRecord] = []) throws {
        let lines = flakes.map(Line.flake) + fixes.map(Line.fix) + reruns.map(Line.rerun)
        guard !lines.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for line in lines {
            data.append(try encoder.encode(line))
            data.append(0x0A)
        }
        let fd = open(file, O_RDWR | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { throw BoardError(text: "\(file) can't be opened to append (\(String(cString: strerror(errno)))); nothing was recorded.") }
        defer { close(fd) }
        // A line cut short by a crash ends before this one starts, so only it is lost.
        let end = lseek(fd, 0, SEEK_END)
        if end > 0 {
            var last: UInt8 = 0
            if pread(fd, &last, 1, end - 1) == 1, last != 0x0A { data.insert(0x0A, at: 0) }
        }
        var written = 0
        while written < data.count {
            let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + written, data.count - written) }
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { throw BoardError(text: "\(file) couldn't be appended to (\(String(cString: strerror(errno)))); nothing more was recorded.") }
            written += wrote
        }
        guard fsync(fd) == 0 else { throw BoardError(text: "\(file) couldn't be synced (\(String(cString: strerror(errno)))).") }
    }

    /// Runs `body` holding the ledger's lock (other processes too), its folder made private (0700) first.
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try VibePaths.ensurePrivate(URL(fileURLWithPath: folder, isDirectory: true),
                                    within: URL(fileURLWithPath: (root as NSString).appendingPathComponent(".vibeswitcher"), isDirectory: true))
        local.lock()
        defer { local.unlock() }
        let fd = open(file + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw BoardError(text: "\(file).lock can't be opened (\(String(cString: strerror(errno)))); nothing was recorded.") }
        flock(fd, LOCK_EX)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return try body()
    }

    /// One line of the file: the entry, with its kind.
    enum Line: Codable {
        case flake(LeadFlake)
        case fix(LeadFlakeFix)
        case rerun(LeadRerunRecord)

        private enum Keys: String, CodingKey { case kind }

        init(from decoder: Decoder) throws {
            switch try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .kind) {
            case "flake": self = .flake(try LeadFlake(from: decoder))
            case "fix": self = .fix(try LeadFlakeFix(from: decoder))
            case "rerun": self = .rerun(try LeadRerunRecord(from: decoder))
            case let other: throw DecodingError.dataCorrupted(.init(codingPath: [Keys.kind], debugDescription: "no kind \(other)"))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            switch self {
            case .flake(let flake):
                try container.encode("flake", forKey: .kind)
                try flake.encode(to: encoder)
            case .fix(let fix):
                try container.encode("fix", forKey: .kind)
                try fix.encode(to: encoder)
            case .rerun(let rerun):
                try container.encode("rerun", forKey: .kind)
                try rerun.encode(to: encoder)
            }
        }
    }
}
