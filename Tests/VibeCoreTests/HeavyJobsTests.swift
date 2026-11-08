import Darwin
import Foundation
import Testing
@testable import VibeCore

/// Heavy jobs outside vs-heavy are noticed (the boost release, 2026-11-01): the Wallet Manager's hour-long Stryker
/// runs (up to 14 node processes) and another project's VMs took the Mac to load 72–193 outside the Mac-wide slots. A
/// process group in a project's folder above ~3 cores for more than 5 minutes, its project holding no slot, is told
/// once to that project's lead with how to run it under vs-heavy; vs-heavy's commands and VibeSwitcher's own merges and
/// audits never are. A fake process table, fake slot holders and an injected clock: nothing here reads the real Mac.
struct HeavyJobsTests {
    static let wallet = "/Users/someone/dev/wallet-manager"
    static let other = "/Users/someone/dev/project-c"
    static let worktree = wallet + "/.vibeswitcher/worktrees/stryker-pass"
    static let t0 = Date(timeIntervalSince1970: 1_793_500_000)

    /// A fake process table: processes by pid, each burning `rate` cores, and their folders and argv.
    struct Table {
        struct Process {
            var pid: Int32, ppid: Int32, pgid: Int32
            var rate: Double
            var started: Date = HeavyJobsTests.t0.addingTimeInterval(-3600)
            var name: String
            var cwd: String? = nil
            var argv: [String] = []
        }
        var processes: [Process] = []

        /// The table at `now`: each process has used `rate` cores since it started.
        func usage(at now: Date) -> [ProcUsage] {
            processes.filter { $0.started <= now }.map {
                ProcUsage(pid: $0.pid, ppid: $0.ppid, pgid: $0.pgid, cpu: max(0, now.timeIntervalSince($0.started)) * $0.rate,
                          started: $0.started, name: $0.name)
            }
        }
        func cwd(_ pid: Int32) -> String? { processes.first { $0.pid == pid }?.cwd }
        func command(_ pid: Int32) -> String? {
            processes.first { $0.pid == pid }?.argv.first.flatMap(ProcessTable.commandName(argv0:))
        }

        /// A Stryker-shaped job: a shell (its leader) in `folder` and `count` node workers at `rate` cores each.
        static func stryker(pgid: Int32 = 500, parent: Int32 = 90, count: Int = 4, rate: Double = 1, folder: String = HeavyJobsTests.worktree,
                            secret: String = "--token=sk-ant-api03-SECRETSECRETSECRET") -> [Process] {
            [Process(pid: pgid, ppid: parent, pgid: pgid, rate: 0.01, name: "zsh", cwd: folder, argv: ["-zsh"])]
                + (1...count).map { index in
                    Process(pid: pgid + Int32(index), ppid: pgid, pgid: pgid, rate: rate, name: "node", cwd: folder,
                            argv: ["/opt/homebrew/bin/node", "node_modules/.bin/stryker", "run", secret])
                }
        }
    }

    /// The session host and a worker's agent, whose shell started the job (pid 90).
    static let session: [Table.Process] = [
        .init(pid: 80, ppid: 1, pgid: 80, rate: 0.05, name: "vibeswitcher-hos"),
        .init(pid: 90, ppid: 80, pgid: 90, rate: 0.2, name: "claude", cwd: worktree),
    ]

    /// Looks every minute from t0 for `minutes` minutes; what each look told.
    static func looks(_ table: Table, minutes: Int, every step: TimeInterval = 60, holders: [TestLock.Holder] = [],
                      roots: [String] = [wallet, other], jobs: inout HeavyJobs) -> [[HeavyJobs.Job]] {
        stride(from: 0, through: TimeInterval(minutes) * 60, by: step).map { offset in
            let now = t0.addingTimeInterval(offset)
            return jobs.look(table.usage(at: now), now: now, holders: holders, roots: roots, cwd: table.cwd, command: table.command)
        }
    }

    // MARK: Found and told once

    @Test func aGroupAboveThreeCoresForFiveMinutesIsToldToItsProjectOnce() throws {
        var jobs = HeavyJobs()
        let table = Table(processes: Self.session + Table.stryker(count: 4, rate: 1))
        let told = Self.looks(table, minutes: 15, jobs: &jobs)
        // Nothing for the first five minutes; at five, once; never again while it runs.
        #expect(told.prefix(5).allSatisfy { $0.isEmpty })
        #expect(told[5].count == 1)
        #expect(told.dropFirst(6).allSatisfy { $0.isEmpty })
        let job = try #require(told[5].first)
        #expect(job.root == Self.wallet && job.project == "wallet-manager" && job.task == "stryker-pass")
        #expect(job.pgid == 500 && job.processes == 5 && job.name == "node" && job.minutes == 5)
        #expect(abs(job.cores - 4.01) < 0.01)
        let text = LeadWitness.heavyJobText(job)
        #expect(text.contains("`node`") && text.contains("task stryker-pass") && text.contains("vs-heavy --timeout 2h <its command>"))
        #expect(text.contains("4.0 cores") && text.contains("5 min") && text.contains("stops nothing"))
    }

    @Test func belowThreeCoresOrUnderFiveMinutesIsNeverTold() {
        // Three node workers at 0.95 cores: 2.85 (plus the shell's 0.01) on average, never "above ~3".
        var calm = HeavyJobs()
        #expect(Self.looks(Table(processes: Self.session + Table.stryker(count: 3, rate: 0.95)), minutes: 30, jobs: &calm).allSatisfy { $0.isEmpty })
        // Heavy for 4 minutes, then gone: never told; the same group number later is a new job, watched afresh.
        var brief = HeavyJobs()
        var table = Table(processes: Self.session + Table.stryker(count: 8))
        #expect(Self.looks(table, minutes: 4, jobs: &brief).allSatisfy { $0.isEmpty })
        table.processes = Self.session
        let gone = Self.t0.addingTimeInterval(5 * 60)
        #expect(brief.look(table.usage(at: gone), now: gone, holders: [], roots: [Self.wallet], cwd: table.cwd, command: table.command).isEmpty)
        #expect(brief.told.isEmpty)
    }

    @Test func aJobOfShortLivedProcessesIsMeasuredByTheCPUTheyUsed() throws {
        // Stryker's mutant runs: each node process lives under a minute, so no instant shows a long-running heavy one;
        // each look sees new ones, started since the last, whose whole CPU time counts.
        var jobs = HeavyJobs()
        var told: [HeavyJobs.Job] = []
        for minute in 0...8 {
            let now = Self.t0.addingTimeInterval(TimeInterval(minute) * 60)
            var processes = Self.session + [Table.Process(pid: 500, ppid: 90, pgid: 500, rate: 0.01, name: "zsh", cwd: Self.worktree)]
            // Six workers started 50 s ago, each at 0.8 cores so far (40 s of CPU), new pids each minute.
            for index in 0..<6 {
                processes.append(.init(pid: Int32(1000 + minute * 10 + index), ppid: 500, pgid: 500, rate: 0.8,
                                       started: now.addingTimeInterval(-50), name: "node", cwd: Self.worktree, argv: ["node"]))
            }
            let table = Table(processes: processes)
            told += jobs.look(table.usage(at: now), now: now, holders: [], roots: [Self.wallet], cwd: table.cwd, command: table.command)
        }
        let job = try #require(told.first)
        #expect(told.count == 1 && job.pgid == 500 && job.name == "node" && job.cores > 3.5)
    }

    @Test func aJobIsToldOncePerGroupEachToItsOwnProject() {
        var jobs = HeavyJobs()
        let table = Table(processes: Self.session + Table.stryker(pgid: 500)
                          + Table.stryker(pgid: 700, count: 6, folder: Self.other + "/sim"))
        let told = Self.looks(table, minutes: 10, jobs: &jobs).flatMap { $0 }
        #expect(told.map { $0.pgid } == [500, 700])
        #expect(told.map { $0.project } == ["wallet-manager", "project-c"])
        #expect(told.last?.task == nil)
        #expect(LeadWitness.heavyJobText(told[1]).contains("in this project's folder"))
    }

    // MARK: Never told

    /// A slot holder's note, as vs-heavy writes it (`TestLock.record`).
    static func holder(pid: Int32, what: String, in folder: String, slot: Int = 1) -> TestLock.Holder {
        TestLock.Holder(slot: slot, note: "pid \(pid), \(what) in \(folder), since 10:00:00", since: t0.addingTimeInterval(-600))
    }

    @Test func aProjectHoldingAHeavySlotIsNotTold() {
        var jobs = HeavyJobs()
        let table = Table(processes: Self.session + Table.stryker(count: 8))
        // The wallet's worker holds a slot (its suite, under vs-heavy): its other heavy work isn't told meanwhile.
        let held = [Self.holder(pid: 4000, what: "swift test", in: Self.worktree)]
        #expect(Self.looks(table, minutes: 10, holders: held, jobs: &jobs).allSatisfy { $0.isEmpty })
        // Another project's slot doesn't cover it.
        var others = HeavyJobs()
        let elsewhere = [Self.holder(pid: 4000, what: "pytest -q", in: Self.other)]
        #expect(Self.looks(table, minutes: 10, holders: elsewhere, jobs: &others).flatMap { $0 }.map { $0.pgid } == [500])
    }

    @Test func vsHeavyCommandsAreNeverTold() {
        // vs-heavy (pid 400, the holder its note names) → its supervisor (perl, 401, a group of its own) → the command's
        // group (500). The note names another folder (`--as`, a run started from elsewhere): its ancestry tells it.
        let wrapped = [Table.Process(pid: 400, ppid: 90, pgid: 90, rate: 0, name: "bash", cwd: Self.worktree),
                       .init(pid: 401, ppid: 400, pgid: 401, rate: 0, name: "perl", cwd: Self.worktree)]
            + Table.stryker(pgid: 500, parent: 401, count: 10)
        var jobs = HeavyJobs()
        let held = [Self.holder(pid: 400, what: "npx stryker run", in: "/Users/someone/scratch")]
        #expect(Self.looks(Table(processes: Self.session + wrapped), minutes: 20, holders: held, jobs: &jobs).allSatisfy { $0.isEmpty })
        // The same job with the slot let go (vs-heavy ended, its daemon left running): told.
        var unheld = HeavyJobs()
        #expect(Self.looks(Table(processes: Self.session + wrapped), minutes: 10, jobs: &unheld).flatMap { $0 }.map { $0.pgid } == [500])
    }

    @Test func vibeSwitchersOwnMergesAndAuditsAreNeverTold() {
        // The lead's tool server (vibeswitcher-mcp) runs a merge's suite in the project's folder: between its slot's
        // holder note going and the run's last processes ending, or with no note readable, it's still VibeSwitcher's.
        let lead: [Table.Process] = [.init(pid: 60, ppid: 80, pgid: 60, rate: 0.1, name: "claude", cwd: Self.wallet),
                                     .init(pid: 61, ppid: 60, pgid: 60, rate: 0.01, name: "vibeswitcher-mcp", cwd: Self.wallet)]
        let merge = Table.stryker(pgid: 600, parent: 61, count: 8, folder: Self.wallet + "/.vibeswitcher/merge")
        var jobs = HeavyJobs()
        #expect(Self.looks(Table(processes: Self.session + lead + merge), minutes: 20, jobs: &jobs).allSatisfy { $0.isEmpty })
    }

    @Test func aJobOutsideEveryProjectsFolderIsNotTold() {
        var jobs = HeavyJobs()
        let vm = Table.stryker(pgid: 800, count: 8, folder: "/Users/someone")
        #expect(Self.looks(Table(processes: Self.session + vm), minutes: 10, jobs: &jobs).allSatisfy { $0.isEmpty })
    }

    @Test func projectRootsAreRepositoriesNeverHomeOrAboveIt() {
        let home = "/Users/someone"
        let repos: Set<String> = [Self.wallet, Self.other, home, "/Users", "/"]
        let roots = HeavyJobs.projectRoots([Self.worktree, Self.wallet, Self.other + "/", home, "/Users", "/", "/Users/someone/notes"],
                                           home: home, isRepository: repos.contains)
        #expect(roots == [Self.wallet, Self.other])
        #expect(HeavyJobs.root(of: Self.worktree + "/src", in: roots) == Self.wallet)
        #expect(HeavyJobs.root(of: Self.wallet + "-old/src", in: roots) == nil)
    }

    // MARK: Only the command's name, never its arguments

    @Test func argumentsNeverReachAReport() throws {
        let secret = "sk-ant-api03-SECRETSECRETSECRET"
        var jobs = HeavyJobs()
        let table = Table(processes: Self.session + Table.stryker(count: 6, secret: "--token=\(secret)"))
        let job = try #require(Self.looks(table, minutes: 6, jobs: &jobs).flatMap { $0 }.first)
        let banner = LeadWitness.heavyJobBanner(job)
        for text in [LeadWitness.heavyJobText(job), banner.title, banner.body, "\(job)"] {
            #expect(!text.contains(secret) && !text.contains("stryker run") && !text.contains("--token"))
        }
        #expect(banner.title == "Heavy job outside vs-heavy in wallet-manager" && banner.body.contains("`node`"))
        // An argv[0] rewritten into a title with arguments in it isn't a name: the kernel's name is said instead.
        #expect(ProcessTable.commandName(argv0: "/opt/homebrew/bin/node") == "node")
        #expect(ProcessTable.commandName(argv0: "postgres: app password=\(secret)") == nil)
        var titled = HeavyJobs()
        var renamed = Table(processes: Self.session + Table.stryker(count: 6))
        for index in renamed.processes.indices where renamed.processes[index].name == "node" {
            renamed.processes[index].argv = ["node: worker \(secret)"]
        }
        let named = try #require(Self.looks(renamed, minutes: 6, jobs: &titled).flatMap { $0 }.first)
        #expect(named.name == "node" && !LeadWitness.heavyJobText(named).contains(secret))
    }

    // MARK: The kernel reads

    @Test func usageCwdAndCommandNameReadARealProcess() async throws {
        let temp = Scratch()
        let folder = temp.url("heavy-jobs-cwd")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let secret = "sk-ant-api03-REALSECRETREALSECRET"
        // A shell that waits on its stdin, a secret-looking argument as its $0.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "cat >/dev/null; exit 0", secret]
        process.currentDirectoryURL = folder
        let input = Pipe()
        process.standardInput = input
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            #expect(await exited(process), "pid \(process.processIdentifier) still running")
        }
        let pid = process.processIdentifier
        let usage = try #require(ProcessTable.usage(of: pid))
        #expect(usage.pid == pid && usage.ppid == getpid() && usage.uid == getuid() && usage.cpu >= 0)
        #expect(usage.name == "sh" || usage.name == "bash")
        #expect(ProcessTable.commandName(of: pid) == "sh")
        let cwd = try #require(ProcessTable.cwd(of: pid))
        #expect((cwd as NSString).resolvingSymlinksInPath == (folder.path as NSString).resolvingSymlinksInPath)
        // The whole table: this test's own process is in it, with its group and the CPU it has used.
        let all = try #require(ProcessTable.usage())
        let own = try #require(all.first { $0.pid == getpid() })
        #expect(own.pgid == getpgrp() && own.cpu > 0)
        #expect(all.contains { $0.pid == pid })
        #expect(!"\(all)".contains(secret))
    }
}
