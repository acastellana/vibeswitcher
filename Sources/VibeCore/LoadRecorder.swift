import Darwin
import Foundation

/// The Mac's working conditions, once a minute, and each merge's test run, kept so the leads' limits and the boost
/// settings can be tuned from what happened rather than from a reconstruction: a study of 4 days' transcripts and hang
/// logs (2026-10-28..31, about half the hours covered) found freezes and suite time bending at load 24, throughput
/// peaking around 36–48 and falling past it, and the 150+ spikes coming from heavy jobs run outside vs-heavy.
///
/// `~/.vibeswitcher/stats/load-<yyyy-MM-dd>.jsonl` gets one line a minute (`LoadSample`, written by the app off its
/// main thread) and `merges-<yyyy-MM-dd>.jsonl` one line per merge in any project (`MergeSample`, written by the merging
/// lead's tool server). Both 0600, kept `keepDays` days. `scripts/load-report.sh` reads them.
///
/// What's recorded is `ps`-level and no more: load averages, memory pressure and swap, the host's census of team
/// sessions, the heavy slots' project and task, and above `topLoad` the busiest process groups by command name (the
/// kernel's, never arguments) and the project folder's name of their cwd (never the path, nor any folder below it).
public enum LoadStats {
    /// Files older than this many days are removed.
    public static let keepDays = 14
    /// Above this 1-minute load a sample names the busiest process groups.
    public static let topLoad = 48.0
    /// How many process groups it names at most.
    public static let topCount = 5
    /// A group under this share of a core isn't named.
    public static let topMinimumCPU = 5.0

    /// "load-2026-11-01.jsonl" or "merges-2026-11-01.jsonl" for the local day of `date`.
    public static func fileName(_ kind: String, for date: Date) -> String { "\(kind)-\(day(date)).jsonl" }

    /// The local day of `date`, "2026-11-01".
    public static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The local time with its offset, "2026-11-01T14:02:00+01:00".
    public static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Appends `line` and a newline to `folder`/`name` in one write, the file 0600 and the folder 0700. One write with
    /// O_APPEND: two tool servers' merges ending together don't interleave their lines.
    public static func append(_ line: String, to name: String, in folder: URL) throws {
        try VibePaths.ensurePrivate(folder)
        let path = folder.appendingPathComponent(name).path
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        fchmod(fd, 0o600)
        let data = Array((line + "\n").utf8)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The JSON line of `value`, keys sorted.
    static func line<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Removes the load and merge files of days before the `keepDays` days ending with `now`'s; nothing else in the
    /// folder (the activity ledgers live there too). The names removed.
    @discardableResult
    public static func prune(_ folder: URL, now: Date = Date()) -> [String] {
        guard let first = Calendar.current.date(byAdding: .day, value: -(keepDays - 1), to: now) else { return [] }
        let oldest = day(first)
        var removed: [String] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            guard let match = name.wholeMatch(of: #/(load|merges)-(\d{4}-\d{2}-\d{2})\.jsonl/#), String(match.2) < oldest else { continue }
            if unlink(folder.appendingPathComponent(name).path) == 0 { removed.append(name) }
        }
        return removed.sorted()
    }

    /// The command name of a process as recorded: the executable's own name, never its arguments or folder. The kernel
    /// gives only that (`p_comm`); a name read from elsewhere (a `ps` command column) is cut to its first word's last
    /// path component, and to 32 characters.
    public static func commandName(_ raw: String) -> String {
        let first = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        let name = first.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? "?" : String(name.prefix(32))
    }

    /// The project folder's name a process working in `cwd` is in: a VibeSwitcher worktree's repository, else the
    /// nearest folder above it (up to, not including, `home`) that `isRepository` says is one; nil when there's none
    /// (the home, a system folder, a folder in no repository). Never a folder below the project's.
    public static func project(ofFolder cwd: String, home: String = VibePaths.accountHome,
                               isRepository: (String) -> Bool = LoadStats.isRepository) -> String? {
        let folder = (cwd as NSString).standardizingPath
        if folder.contains("/.vibeswitcher/worktrees/") { return TestLock.whose(folder).project }
        let stop = (home as NSString).standardizingPath
        var current = folder
        while current != "/", current != stop, !current.isEmpty {
            if isRepository(current) { return (current as NSString).lastPathComponent }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Whether `folder` is a repository's top (a `.git` folder or file in it).
    public static func isRepository(_ folder: String) -> Bool {
        var info = stat()
        return lstat((folder as NSString).appendingPathComponent(".git"), &info) == 0
    }
}

/// One minute's line of `load-<day>.jsonl`.
public struct LoadSample: Codable, Equatable, Sendable {
    /// When it was taken (`LoadStats.stamp`).
    public var t: String
    /// The 1-, 5- and 15-minute load averages, to 2 decimals; empty when the system didn't say.
    public var load: [Double]
    public var cores: Int
    public var memory: Memory?
    /// Live team sessions by project and role, as the host counts them.
    public var sessions: [Sessions]
    public var heavy: Heavy
    /// The busiest process groups, only when the 1-minute load is over `LoadStats.topLoad`.
    public var top: [Group]?
    /// The CPU time this sample took to take, in milliseconds.
    public var costMs: Double

    public struct Memory: Codable, Equatable, Sendable {
        /// "normal", "warn" or "critical" (the kernel's memory pressure level).
        public var pressure: String?
        /// The share of memory the kernel counts as available, in percent.
        public var free: Int?
        public var swapUsedMb: Int?
        public var swapTotalMb: Int?

        public init(pressure: String?, free: Int?, swapUsedMb: Int?, swapTotalMb: Int?) {
            self.pressure = pressure
            self.free = free
            self.swapUsedMb = swapUsedMb
            self.swapTotalMb = swapTotalMb
        }
    }

    public struct Sessions: Codable, Equatable, Sendable {
        /// The repository's folder name.
        public var project: String
        /// "lead", "worker" or "verifier".
        public var role: String
        public var n: Int
    }

    public struct Heavy: Codable, Equatable, Sendable {
        /// The slots there are.
        public var slots: Int
        public var held: [Holder]

        public struct Holder: Codable, Equatable, Sendable {
            public var slot: Int
            /// The project and task it runs for, as its note says; never its command.
            public var project: String?
            public var task: String?
            /// How long it has held the slot, in minutes.
            public var minutes: Int?
        }
    }

    public struct Group: Codable, Equatable, Sendable {
        /// The command name of its busiest process (`LoadStats.commandName`).
        public var command: String
        /// The command name of the group's leader, when it's another (a script running a compiler).
        public var leader: String?
        /// The project folder's name of its cwd (`LoadStats.project(ofFolder:)`); nil when it's in none.
        public var project: String?
        /// Its CPU over the window, in percent of one core.
        public var cpu: Double
        public var processes: Int
    }
}

/// One merge's line of `merges-<day>.jsonl`.
public struct MergeSample: Codable, Equatable, Sendable {
    /// When its test run started.
    public var t: String
    /// The repository's folder name, and the task merged.
    public var project: String
    public var task: String
    /// The 1-, 5- and 15-minute load averages when its test run started.
    public var load: [Double]
    /// How long it waited for the load to drop before its tests, in seconds (0: no wait).
    public var waitedS: Int
    /// How long it waited for a slot of the Mac-wide test and build lock (and set up its worktree), in seconds; nil
    /// when its commands never started.
    public var slotWaitS: Int?
    /// How long its commands took (init_command, the tests, regression_command, and a rerun), in seconds.
    public var durationS: Int
    /// "passed" or "failed": the first run of the tests; nil when they didn't run (a conflict, an error).
    public var firstRun: String?
    /// The tests the rerun ran (the failing ones when filtered; empty for the whole command), nil when there was no rerun.
    public var reran: [String]?
    /// Whether the rerun ran the whole test command, nil when there was no rerun.
    public var rerunWhole: Bool?
    /// "passed", "passed_on_rerun", "failed", "hung", "conflict", "cancelled" or "error".
    public var result: String

    public init(t: String, project: String, task: String, load: [Double], waitedS: Int, slotWaitS: Int?, durationS: Int,
                firstRun: String?, reran: [String]?, rerunWhole: Bool?, result: String) {
        self.t = t
        self.project = project
        self.task = task
        self.load = load
        self.waitedS = waitedS
        self.slotWaitS = slotWaitS
        self.durationS = durationS
        self.firstRun = firstRun
        self.reran = reran
        self.rerunWhole = rerunWhole
        self.result = result
    }

    /// A merge's line from how its test run went (`check`), the rerun planned after its first run failed (`rerun`),
    /// its commands' start (`started`, the load then), the load wait before it, and the slot wait.
    public init(check: Worktrees.Check, rerun: MergeRerun.Plan?, project: String, task: String, started: Date, load: [Double],
                waited: TimeInterval, slotWait: TimeInterval?, ended: Date) {
        let firstRun: String?, result: String
        // A rerun was planned only after the first run failed; it ran unless the run stopped before it.
        var reran = rerun.map(\.tests)
        switch check {
        case .passed: (firstRun, result) = ("passed", "passed")
        case .passedOnRerun: (firstRun, result) = ("failed", "passed_on_rerun")
        case .failed(let output):
            firstRun = "failed"
            result = "failed"
            if !output.hasPrefix(Worktrees.rerunHeader) { reran = nil }
        case .hung: (firstRun, result) = (rerun == nil ? nil : "failed", "hung")
        case .conflict: (firstRun, result) = (nil, "conflict")
        case .cancelled: (firstRun, result) = (rerun == nil ? nil : "failed", "cancelled")
        case .error: (firstRun, result) = (nil, "error")
        }
        self.init(t: LoadStats.stamp(started), project: project, task: task, load: load.map { ($0 * 100).rounded() / 100 },
                  waitedS: Int(waited.rounded()), slotWaitS: slotWait.map { Int(max(0, $0).rounded()) },
                  durationS: Int(max(0, ended.timeIntervalSince(started)).rounded()), firstRun: firstRun, reran: reran,
                  rerunWhole: reran == nil ? nil : rerun.map { !$0.filtered }, result: result)
    }

    /// Appends it to its day's file in `folder`.
    public func append(in folder: URL, at date: Date) throws {
        try LoadStats.append(try LoadStats.line(self), to: LoadStats.fileName("merges", for: date), in: folder)
    }
}

/// A process as the sampler reads it: `ps`-level fields only. Its cwd is read apart, for the few named (`cwd`).
public struct LoadProcess: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var pgid: Int32
    /// The kernel's name for it (`p_comm`, at most 16 characters).
    public var comm: String
    /// The CPU time it has used, user and system, in seconds.
    public var cpuSeconds: Double

    public init(pid: Int32, ppid: Int32, pgid: Int32, comm: String, cpuSeconds: Double) {
        self.pid = pid
        self.ppid = ppid
        self.pgid = pgid
        self.comm = comm
        self.cpuSeconds = cpuSeconds
    }
}

/// Takes the minute's sample and writes it. One at a time, off the main thread (the app calls `record` from its
/// Heartbeat and it runs on its own queue); every source is injectable for tests.
public final class LoadRecorder: @unchecked Sendable {
    public struct Sources {
        /// The 1-, 5- and 15-minute load averages.
        public var averages: () -> [Double]?
        public var memory: () -> LoadSample.Memory?
        /// The heavy slots there are, and who holds them.
        public var heavy: () -> (slots: Int, holders: [TestLock.Holder])
        /// Every process this user can read; nil when the table couldn't be read.
        public var processes: () -> [LoadProcess]?
        /// A process's cwd; nil when it can't be read.
        public var cwd: (Int32) -> String?
        /// A cwd's project folder name (`LoadStats.project(ofFolder:)`).
        public var project: (String) -> String?
        /// How long to wait for a second look at the processes when there's no recent first one.
        public var window: TimeInterval
        public var sleep: (TimeInterval) -> Void

        public init(averages: @escaping () -> [Double]?, memory: @escaping () -> LoadSample.Memory?,
                    heavy: @escaping () -> (slots: Int, holders: [TestLock.Holder]), processes: @escaping () -> [LoadProcess]?,
                    cwd: @escaping (Int32) -> String?, project: @escaping (String) -> String?, window: TimeInterval = 2,
                    sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
            self.averages = averages
            self.memory = memory
            self.heavy = heavy
            self.processes = processes
            self.cwd = cwd
            self.project = project
            self.window = window
            self.sleep = sleep
        }

        /// The Mac's own.
        public static var mac: Sources {
            Sources(averages: LoadRecorder.averages, memory: LoadRecorder.memory, heavy: LoadRecorder.heavySlots,
                    processes: LoadRecorder.processes, cwd: LoadRecorder.cwd, project: { LoadStats.project(ofFolder: $0) })
        }
    }

    /// Where the files go, looked up at each write (the app's home, as `VibePaths` says then).
    private let folder: () -> URL
    private let sources: Sources
    private let queue = DispatchQueue(label: "vibeswitcher.load-recorder", qos: .utility)
    /// The last look at the processes' CPU time, and when (for the next sample's CPU shares).
    private var lastLook: (at: Date, cpu: [Int32: Double])?
    /// The day last pruned.
    private var pruned: String?
    /// A sample is under way: the next minute's is skipped rather than queued behind it.
    private var busy = false
    private let lock = NSLock()

    /// `folder`: where the files go; nil: `VibePaths.statsDir`, as it is at each write.
    public init(folder: URL? = nil, sources: Sources = .mac) {
        self.folder = { folder ?? VibePaths.statsDir }
        self.sources = sources
    }

    /// Takes and writes a sample on the recorder's queue, with the census of the host's live team sessions; `done`
    /// hears the sample (tests). Skipped while the previous one is still under way.
    public func record(census: [HostCensus], at date: Date = Date(), done: ((LoadSample?) -> Void)? = nil) {
        lock.lock()
        if busy { lock.unlock(); done?(nil); return }
        busy = true
        lock.unlock()
        queue.async { [self] in
            let sample = try? write(census: census, at: date)
            lock.lock()
            busy = false
            lock.unlock()
            done?(sample)
        }
    }

    /// Takes the sample, appends it to its day's file and prunes old days (once a day). On the caller's thread.
    @discardableResult
    public func write(census: [HostCensus], at date: Date = Date()) throws -> LoadSample {
        let sample = take(census: census, at: date)
        try LoadStats.append(try LoadStats.line(sample), to: LoadStats.fileName("load", for: date), in: folder())
        let today = LoadStats.day(date)
        if pruned != today {
            LoadStats.prune(folder(), now: date)
            pruned = today
        }
        return sample
    }

    /// The sample as of `date`, its own CPU cost measured. On the caller's thread.
    public func take(census: [HostCensus], at date: Date = Date()) -> LoadSample {
        let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let averages = sources.averages() ?? []
        let heavy = sources.heavy()
        var sample = LoadSample(
            t: LoadStats.stamp(date), load: averages.map { ($0 * 100).rounded() / 100 }, cores: MacLoad.processors,
            memory: sources.memory(), sessions: Self.sessions(census),
            heavy: LoadSample.Heavy(slots: heavy.slots, held: heavy.holders.map { holder in
                // Its folder's project (a run in a subfolder is the repository's), else what its note says.
                LoadSample.Heavy.Holder(slot: holder.slot, project: holder.directory.flatMap(sources.project) ?? holder.recordedProject,
                                        task: holder.task,
                                        minutes: holder.since.map { _ in Int(holder.held(now: date) / 60) })
            }),
            top: nil, costMs: 0)
        if let one = averages.first, one > LoadStats.topLoad {
            sample.top = topGroups(at: date)
        } else {
            lastLook = nil
        }
        sample.costMs = (Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started) / 1e4).rounded() / 100
        return sample
    }

    /// The census as recorded: project folder names, roles, counts, sorted.
    static func sessions(_ census: [HostCensus]) -> [LoadSample.Sessions] {
        var counts: [String: Int] = [:]
        for entry in census where entry.sessions > 0 {
            counts["\((entry.root as NSString).lastPathComponent)\t\(entry.role.rawValue)", default: 0] += entry.sessions
        }
        return counts.map { key, n in
            let parts = key.split(separator: "\t", maxSplits: 1).map(String.init)
            return LoadSample.Sessions(project: parts[0], role: parts.count > 1 ? parts[1] : "", n: n)
        }.sorted { ($0.project, $0.role) < ($1.project, $1.role) }
    }

    /// The busiest process groups since the last look (the previous minute's, when it was taken then; else a look
    /// `window` ago), by command name and project folder.
    func topGroups(at date: Date) -> [LoadSample.Group]? {
        var previous = lastLook
        if previous == nil || date.timeIntervalSince(previous!.at) > 180 || date <= previous!.at {
            guard let first = sources.processes() else { return nil }
            previous = (date.addingTimeInterval(-sources.window), Dictionary(first.map { ($0.pid, $0.cpuSeconds) }, uniquingKeysWith: max))
            sources.sleep(sources.window)
        }
        guard let previous, let now = sources.processes() else { return nil }
        lastLook = (date, Dictionary(now.map { ($0.pid, $0.cpuSeconds) }, uniquingKeysWith: max))
        let elapsed = max(1, date.timeIntervalSince(previous.at))
        return Self.groups(now, previous: previous.cpu, elapsed: elapsed, cwd: sources.cwd, project: sources.project)
    }

    /// `processes`' groups (by process group) whose CPU over `elapsed` seconds since `previous` (pid → CPU seconds; a
    /// pid not in it started since) is the most, merged by command name and project, at most `LoadStats.topCount`.
    static func groups(_ processes: [LoadProcess], previous: [Int32: Double], elapsed: TimeInterval,
                       cwd: (Int32) -> String?, project: (String) -> String?) -> [LoadSample.Group] {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [Int32: [(process: LoadProcess, cpu: Double)]] = [:]
        for process in processes {
            let used = max(0, process.cpuSeconds - (previous[process.pid] ?? 0))
            groups[process.pgid > 0 ? process.pgid : process.pid, default: []].append((process, used / elapsed * 100))
        }
        let ranked = groups.map { pgid, members in (pgid: pgid, members: members, cpu: members.reduce(0) { sum, member in sum + member.cpu }) }
            .filter { $0.cpu >= LoadStats.topMinimumCPU }
            .sorted { $0.cpu > $1.cpu }
            .prefix(LoadStats.topCount * 2)
        var merged: [String: LoadSample.Group] = [:]
        var order: [String] = []
        for group in ranked {
            let busiest = group.members.max { $0.cpu < $1.cpu }!.process
            let leader = byPid[group.pgid]
            let command = LoadStats.commandName(busiest.comm)
            let leaderName = leader.map { LoadStats.commandName($0.comm) }
            // The leader's cwd says where the group was started; the busiest's when the leader is gone.
            let folder = cwd(leader?.pid ?? busiest.pid) ?? cwd(busiest.pid)
            let name = folder.flatMap(project)
            let key = "\(command)\t\(name ?? "")"
            if merged[key] == nil {
                order.append(key)
                merged[key] = LoadSample.Group(command: command, leader: leaderName == command ? nil : leaderName, project: name,
                                               cpu: 0, processes: 0)
            }
            merged[key]!.cpu += group.cpu
            merged[key]!.processes += group.members.count
        }
        return order.compactMap { merged[$0] }
            .map { var group = $0; group.cpu = (group.cpu * 10).rounded() / 10; return group }
            .sorted { $0.cpu > $1.cpu }
            .prefix(LoadStats.topCount).map { $0 }
    }

    // MARK: The Mac's sources

    public static func averages() -> [Double]? {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : nil
    }

    public static func memory() -> LoadSample.Memory? {
        func int(_ name: String) -> Int32? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
        }
        let pressure = int("kern.memorystatus_vm_pressure_level").map { level -> String in
            switch level { case 1: "normal"; case 2: "warn"; case 4: "critical"; default: "level \(level)" }
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapRead = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        let memory = LoadSample.Memory(pressure: pressure, free: int("kern.memorystatus_level").map(Int.init),
                                       swapUsedMb: swapRead ? Int(swap.xsu_used / 1_048_576) : nil,
                                       swapTotalMb: swapRead ? Int(swap.xsu_total / 1_048_576) : nil)
        return memory == LoadSample.Memory(pressure: nil, free: nil, swapUsedMb: nil, swapTotalMb: nil) ? nil : memory
    }

    /// The Mac-wide heavy slots (`TestLock`'s folder and count as vs-heavy finds them) and who holds them.
    public static func heavySlots() -> (slots: Int, holders: [TestLock.Holder]) {
        let environment = ProcessInfo.processInfo.environment
        let lock = TestLock(directory: environment[TestLock.directoryVariable] ?? "/private/tmp/vibeswitcher-\(getuid())",
                            slots: TestLock.slotCount(environment))
        return (lock.slots, lock.holders())
    }

    /// Mach time units to seconds (the task info's CPU times are in them on Apple silicon).
    private static let machSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    /// Every process of this user's whose records can be read: pid, parent, group, name and CPU time (one
    /// PROC_PIDTASKALLINFO each). Another user's process is left out (its CPU time can't be read).
    public static func processes() -> [LoadProcess]? {
        guard let pids = ProcessTable.allPids() else { return nil }
        var found: [LoadProcess] = []
        found.reserveCapacity(pids.count)
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        for pid in pids {
            var info = proc_taskallinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size else { continue }
            let comm = withUnsafeBytes(of: info.pbsd.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let cpu = Double(info.ptinfo.pti_total_user + info.ptinfo.pti_total_system) * machSeconds
            found.append(LoadProcess(pid: pid, ppid: Int32(info.pbsd.pbi_ppid), pgid: Int32(info.pbsd.pbi_pgid), comm: comm, cpuSeconds: cpu))
        }
        return found
    }

    /// A process's current folder; nil when it can't be read (another user's, or gone).
    public static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }
}
