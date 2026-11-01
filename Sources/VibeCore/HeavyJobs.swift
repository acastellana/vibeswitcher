import Foundation

/// CPU-heavy work that bypasses `vs-heavy`: a process group in a project's folder that has used more than `cores` cores
/// on average for `sustained` or longer, holding no Mac-wide heavy slot (see `TestLock`). The load study (2026-10-31)
/// found the worst spikes (load 72–193 on 12 cores) came from jobs outside the shared slots: the Wallet Manager's
/// hour-long Stryker runs with up to 14 node processes, and another project's colima VMs and simulations. Each job is
/// told once to its project's lead (the user, when no lead runs) with how to run it under `vs-heavy`. Only said:
/// nothing here stops or signals any process.
///
/// Measured by CPU-time growth (`ProcUsage.cpu`) between looks, not by an instant's %cpu: a group's use is what its
/// processes used since the last look (a process started since counts whole), so a job of short-lived processes
/// (Stryker's mutant runs) is still seen. A process that ended between looks takes its last stretch with it: the use is
/// a floor, never more than was used.
public struct HeavyJobs: Sendable {
    /// Above this many cores on average…
    public static let defaultCores: Double = 3
    /// …for this long (and longer) is a heavy job.
    public static let defaultSustained: TimeInterval = 5 * 60

    /// The programs VibeSwitcher's own work runs under: the lead's tool server runs merges and audits' shared runs
    /// (each holding a slot meanwhile, see `Worktrees`). What runs under them is never told. Not the app nor the
    /// session host: every session runs under the host, and the host under the app that started it while that app runs.
    public static let ownPrograms: Set<String> = ["vibeswitcher-mcp"]

    public let cores: Double
    public let sustained: TimeInterval

    /// A process group as it has been watched: since when, and the CPU seconds its processes used since then, at each
    /// look within the window (and the last one before it, where the window starts).
    struct Group: Sendable {
        var since: Date
        var used: Double = 0
        var history: [(at: Date, used: Double)]
    }

    private var groups: [Int32: Group] = [:]
    /// Each process's CPU seconds at the last look, by pid and start time, and when that look was.
    private var last: (at: Date, cpu: [String: Double])?
    /// The jobs told, by group and since when it was watched: a group that ends is forgotten.
    public private(set) var told: Set<String> = []

    public init(cores: Double = defaultCores, sustained: TimeInterval = defaultSustained) {
        self.cores = cores
        self.sustained = sustained
    }

    /// A heavy job outside the slots, to tell `root`'s lead.
    public struct Job: Equatable, Sendable {
        /// The project's folder.
        public var root: String
        /// The task whose worktree it runs in; nil in the project's own folder.
        public var task: String?
        public var pgid: Int32
        /// The command's name (its busiest process's argv[0], last path component): never its arguments.
        public var name: String
        /// How many processes its group has now.
        public var processes: Int
        /// Its average use over the window, in cores.
        public var cores: Double
        /// The window it was measured over.
        public var minutes: Int

        public init(root: String, task: String?, pgid: Int32, name: String, processes: Int, cores: Double, minutes: Int) {
            self.root = root
            self.task = task
            self.pgid = pgid
            self.name = name
            self.processes = processes
            self.cores = cores
            self.minutes = minutes
        }

        /// The project's folder name.
        public var project: String { ((root as NSString).standardizingPath as NSString).lastPathComponent }
    }

    /// A look at the processes (`ProcessTable.usage`), the slots' holders now (`TestLock.holders`), and the projects'
    /// folders (`projectRoots`): the jobs to tell now, each once. `cwd` and `command` read a process's folder and name
    /// (`ProcessTable.cwd`, `commandName`), only for the groups found heavy.
    public mutating func look(_ processes: [ProcUsage], now: Date = Date(), holders: [TestLock.Holder], roots: [String],
                              cwd: (Int32) -> String? = ProcessTable.cwd(of:),
                              command: (Int32) -> String? = ProcessTable.commandName(of:)) -> [Job] {
        // What each process used since the last look.
        var cpu: [String: Double] = [:]
        var used: [Int32: Double] = [:]
        cpu.reserveCapacity(processes.count)
        for process in processes {
            let key = "\(process.pid)|\(process.started.timeIntervalSince1970)"
            cpu[key] = process.cpu
            guard let last else { continue }
            if let before = last.cpu[key] {
                used[process.pid] = max(0, process.cpu - before)
            } else if process.started > last.at {
                used[process.pid] = process.cpu
            }
        }
        let first = last == nil
        last = (now, cpu)

        let members = Dictionary(grouping: processes, by: \.pgid)
        groups = groups.filter { members[$0.key] != nil }
        for (pgid, group) in members {
            guard var state = groups[pgid] else {
                groups[pgid] = Group(since: now, history: [(now, 0)])
                continue
            }
            guard !first else { continue }
            state.used += group.reduce(0) { $0 + (used[$1.pid] ?? 0) }
            state.history.append((now, state.used))
            // The window: the looks within `sustained`, and the last one before them, where it starts.
            if let start = state.history.lastIndex(where: { now.timeIntervalSince($0.at) >= sustained }), start > 0 {
                state.history.removeFirst(start)
            }
            groups[pgid] = state
        }
        told.formIntersection(groups.map { Self.key($0.key, $0.value) })

        let table = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { $1 })
        let holderPids = Set(holders.compactMap(\.pid))
        let holding = Set(holders.compactMap(\.project))
        let roots = roots.map { ($0 as NSString).standardizingPath }
        var jobs: [Job] = []
        for (pgid, state) in groups.sorted(by: { $0.key < $1.key }) {
            guard let start = state.history.first, let end = state.history.last else { continue }
            let window = end.at.timeIntervalSince(start.at)
            guard window >= sustained, window > 0 else { continue }
            let average = (end.used - start.used) / window
            guard average > cores, !told.contains(Self.key(pgid, state)) else { continue }
            let group = members[pgid] ?? []
            // Under a slot's holder (vs-heavy's command, a merge's or audit's run) or VibeSwitcher's own work.
            guard !group.contains(where: { Self.isWrapped($0, holders: holderPids, in: table) }) else { continue }
            // Its busiest process (this look's), then its leader, says where it runs.
            let busiest = group.max { (used[$0.pid] ?? 0, $0.cpu) < (used[$1.pid] ?? 0, $1.cpu) }
            let folders = [busiest?.pid, pgid].compactMap { $0 }.lazy.compactMap(cwd)
            guard let (root, folder) = folders.lazy.compactMap({ folder in Self.root(of: folder, in: roots).map { ($0, folder) } }).first
            else { continue }
            let job = Job(root: root, task: LeadTeams.task(ofWorktree: folder), pgid: pgid,
                          name: busiest.flatMap { command($0.pid) ?? ($0.name.isEmpty ? nil : $0.name) } ?? "a process",
                          processes: group.count, cores: average, minutes: Int(window / 60))
            // Its project holds a slot: its heavy work is under the lock already (the contract's line).
            guard !holding.contains(job.project) else { continue }
            told.insert(Self.key(pgid, state))
            jobs.append(job)
        }
        return jobs
    }

    static func key(_ pgid: Int32, _ group: Group) -> String { "\(pgid)|\(group.since.timeIntervalSince1970)" }

    /// `process` is a slot's holder or runs under one, or under VibeSwitcher's own programs.
    static func isWrapped(_ process: ProcUsage, holders: Set<Int32>, in table: [Int32: ProcUsage]) -> Bool {
        var current: ProcUsage? = process
        var steps = 0
        while let each = current, steps < 64 {
            if holders.contains(each.pid) || ownPrograms.contains(each.name) { return true }
            guard each.ppid > 1, each.ppid != each.pid else { return false }
            current = table[each.ppid]
            steps += 1
        }
        return false
    }

    /// The project folder among `roots` that `folder` is in (the deepest), as given.
    static func root(of folder: String, in roots: [String]) -> String? {
        let folder = (folder as NSString).standardizingPath
        let resolved = (folder as NSString).resolvingSymlinksInPath
        return roots.filter { root in
            [root, (root as NSString).resolvingSymlinksInPath].contains { root in
                [folder, resolved].contains { $0 == root || $0.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
            }
        }.max { $0.count < $1.count }
    }

    /// The projects' folders among `candidates` (the leads', the boards', the sessions' repositories): each a
    /// repository's own (with a .git), never the home folder, "/" or a folder above home, where every process would be
    /// "in" it.
    public static func projectRoots(_ candidates: [String], home: String = NSHomeDirectory(),
                                    isRepository: (String) -> Bool = { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(".git")) }) -> [String] {
        let home = (home as NSString).standardizingPath
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let root = LeadTeams.root(ofWorktree: (candidate as NSString).standardizingPath) ?? (candidate as NSString).standardizingPath
            guard root != "/", root != home, !(home + "/").hasPrefix(root.hasSuffix("/") ? root : root + "/"),
                  seen.insert(root).inserted, isRepository(root) else { return nil }
            return root
        }
    }
}

extension LeadWitness {
    /// What a project's lead is told of a heavy job of its own outside the slots (`HeavyJobs`): what runs, where, how
    /// hard and how long, and how to run it under `vs-heavy`. Only the command's name, never its arguments.
    public static func heavyJobText(_ job: HeavyJobs.Job) -> String {
        let place = job.task.map { "in task \($0)'s worktree" } ?? "in this project's folder"
        return "A heavy job runs outside vs-heavy \(place): `\(job.name)` (process group \(job.pgid), \(job.processes) "
            + "process\(job.processes == 1 ? "" : "es")) has used about \(coresText(job.cores)) cores for the last \(job.minutes) min, "
            + "and this project holds no Mac-wide heavy slot. Long or many-core jobs (mutation testing, fuzzing, VMs, load, "
            + "simulation and perf runs) starve every project's builds, suites and merges unless they take a slot: run it under "
            + "vs-heavy, `vs-heavy --timeout 2h <its command>` (it waits its turn, then runs; past the timeout it ends the job). "
            + "If a worker started it, tell it so; if it's yours or the user's, say so to the user. Told once per job; VibeSwitcher "
            + "stops nothing."
    }

    /// The banner the user gets when no lead runs for the job's project: (title, body).
    public static func heavyJobBanner(_ job: HeavyJobs.Job) -> (title: String, body: String) {
        ("Heavy job outside vs-heavy in \(job.project)",
         "`\(job.name)` (\(job.processes) process\(job.processes == 1 ? "" : "es"), group \(job.pgid)) has used about "
            + "\(coresText(job.cores)) cores for \(job.minutes) min without a Mac-wide heavy slot. Run it as "
            + "`vs-heavy --timeout 2h <its command>` so other projects' work isn't starved.")
    }

    /// 9.24 → "9.2".
    static func coresText(_ cores: Double) -> String { String(format: "%.1f", cores) }
}
