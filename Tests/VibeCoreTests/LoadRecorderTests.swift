import Foundation
import Testing
@testable import VibeCore

/// The once-a-minute load recorder (`LoadRecorder`, `LoadStats`): what a line holds and never holds, where and how it's
/// written, how long it's kept, and what it costs.
struct LoadRecorderTests {
    let temp = Scratch()

    /// Sources that read nothing of the Mac: a load of `load`, memory, two heavy slots (one held), and `processes`.
    func sources(load: Double, processes: @escaping () -> [LoadProcess]? = { [] }, cwd: @escaping (Int32) -> String? = { _ in nil },
                 project: @escaping (String) -> String? = { _ in nil },
                 holders: [TestLock.Holder] = []) -> LoadRecorder.Sources {
        LoadRecorder.Sources(averages: { [load, load - 1, load - 2] },
                             memory: { LoadSample.Memory(pressure: "warn", free: 31, swapUsedMb: 2048, swapTotalMb: 4096) },
                             heavy: { (2, holders) }, processes: processes, cwd: cwd, project: project, window: 2, sleep: { _ in })
    }

    static let census = [HostCensus(root: "/Users/me/dev/proj", role: .worker, sessions: 3),
                         HostCensus(root: "/Users/me/dev/proj", role: .lead, sessions: 1),
                         HostCensus(root: "/Users/me/dev/other", role: .verifier, sessions: 1)]

    func decode(_ line: Substring) throws -> LoadSample {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LoadSample.self, from: Data(line.utf8))
    }

    func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func aMinutesLineIsAppendedPrivateUnderStatsWithLoadMemorySessionsAndSlots() throws {
        let folder = temp.url("stats")
        let since = Date(timeIntervalSince1970: 1_793_000_000)
        let holder = TestLock.Holder(slot: 2, note: "pid 9, VibeSwitcher's merge test of abc in /Users/me/dev/proj, since 10:00",
                                     since: since, project: "proj")
        let recorder = LoadRecorder(folder: folder, sources: sources(load: 20, project: { $0 == "/Users/me/dev/proj" ? "proj" : nil },
                                                                   holders: [holder]))
        let now = since.addingTimeInterval(7 * 60 + 30)
        try recorder.write(census: Self.census, at: now)
        try recorder.write(census: [], at: now.addingTimeInterval(60))

        let file = folder.appendingPathComponent(LoadStats.fileName("load", for: now))
        #expect(file.lastPathComponent == "load-\(LoadStats.day(now)).jsonl")
        #expect(mode(file.path) == 0o600 && mode(folder.path) == 0o700, "\(String(mode(file.path), radix: 8))")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let sample = try decode(lines[0])
        #expect(sample.load == [20, 19, 18] && sample.cores == MacLoad.processors)
        #expect(sample.memory == LoadSample.Memory(pressure: "warn", free: 31, swapUsedMb: 2048, swapTotalMb: 4096))
        #expect(sample.sessions == [LoadSample.Sessions(project: "other", role: "verifier", n: 1),
                                    LoadSample.Sessions(project: "proj", role: "lead", n: 1),
                                    LoadSample.Sessions(project: "proj", role: "worker", n: 3)])
        #expect(sample.heavy == LoadSample.Heavy(slots: 2, held: [.init(slot: 2, project: "proj", task: nil, minutes: 7)]))
        // Under load 48: no process groups, and the processes weren't read.
        #expect(sample.top == nil)
        #expect(lines[0].contains("\"swap_used_mb\":2048") && lines[0].contains("\"cost_ms\":"), "\(lines[0])")
    }

    @Test func eachSampleSaysWhetherBoostWasOnAndOlderLinesDecodeWithout() throws {
        let folder = temp.url("stats")
        var boost: Bool? = true
        var sources = sources(load: 3)
        sources.boost = { boost }
        let recorder = LoadRecorder(folder: folder, sources: sources)
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        try recorder.write(census: [], at: now)
        boost = false
        try recorder.write(census: [], at: now.addingTimeInterval(60))
        boost = nil
        try recorder.write(census: [], at: now.addingTimeInterval(120))
        let lines = try String(contentsOf: folder.appendingPathComponent(LoadStats.fileName("load", for: now)), encoding: .utf8).split(separator: "\n")
        #expect(try lines.map { try decode($0).boost } == [true, false, nil])
        #expect(lines[0].contains("\"boost\":true") && lines[1].contains("\"boost\":false") && !lines[2].contains("boost"), "\(lines)")
        // A line from before the flag: decoded unchanged, boost unknown.
        let old = #"{"cores":16,"cost_ms":0.5,"heavy":{"held":[],"slots":2},"load":[3,2,1],"sessions":[],"t":"2026-11-01T14:02:00+01:00"}"#
        let sample = try decode(Substring(old))
        #expect(sample.boost == nil && sample.load == [3, 2, 1] && sample.cores == 16)
        #expect(try LoadStats.line(sample) == old)
        // A merges line from before a batched task's own first run was kept: read as before.
        let merge = #"{"batch":"b","batch_runs":2,"batch_tasks":2,"duration_s":30,"first_run":"failed","load":[1,1,1],"project":"p","result":"passed","t":"2026-11-01T14:02:00+01:00","task":"x","waited_s":0}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let line = try decoder.decode(MergeSample.self, from: Data(merge.utf8))
        #expect(line.taskFirstRun == nil && line.firstRun == "failed" && line.batchRuns == 2)
        #expect(try LoadStats.line(line) == merge)
    }

    @Test func leadsAreTalliedEveryFiveMinutesOnceMoreAfterTheirLeadEnds() throws {
        var tallies: [([String], Date)] = []
        var sources = sources(load: 3)
        sources.tallyLeads = { tallies.append(($0, $1)) }
        let recorder = LoadRecorder(folder: temp.url("stats"), sources: sources)
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let leads = [HostCensus(root: "/r/a", role: .lead, sessions: 1), HostCensus(root: "/r/b/../b", role: .lead, sessions: 1),
                     HostCensus(root: "/r/c", role: .worker, sessions: 2), HostCensus(root: "/r/d", role: .lead, sessions: 0)]
        try recorder.write(census: leads, at: now)
        // Within five minutes: not again.
        try recorder.write(census: leads, at: now.addingTimeInterval(60))
        #expect(tallies.map(\.0) == [["/r/a", "/r/b"]])
        // Five minutes on, b's lead ended: b once more (its last minutes), then no more.
        try recorder.write(census: [leads[0]], at: now.addingTimeInterval(LeadTokenLedger.every))
        try recorder.write(census: [leads[0]], at: now.addingTimeInterval(2 * LeadTokenLedger.every))
        try recorder.write(census: [], at: now.addingTimeInterval(3 * LeadTokenLedger.every))
        try recorder.write(census: [], at: now.addingTimeInterval(4 * LeadTokenLedger.every))
        #expect(tallies.map(\.0) == [["/r/a", "/r/b"], ["/r/a", "/r/b"], ["/r/a"], ["/r/a"]], "\(tallies.map(\.0))")
        #expect(tallies.map(\.1) == [now, now.addingTimeInterval(LeadTokenLedger.every), now.addingTimeInterval(2 * LeadTokenLedger.every),
                                     now.addingTimeInterval(3 * LeadTokenLedger.every)])
    }

    @Test func daysOlderThanFourteenArePrunedAndNothingElse() throws {
        let folder = temp.url("stats")
        try VibePaths.ensurePrivate(folder)
        let now = Date()
        func day(_ ago: Int) -> String { LoadStats.day(Calendar.current.date(byAdding: .day, value: -ago, to: now)!) }
        let old = ["load-\(day(14)).jsonl", "merges-\(day(20)).jsonl", "load-\(day(400)).jsonl"]
        let kept = ["load-\(day(13)).jsonl", "merges-\(day(13)).jsonl", "\(day(30)).json", "load-notes.txt"]
        for name in old + kept { try VibePaths.writePrivate(Data("x\n".utf8), to: folder.appendingPathComponent(name)) }

        let recorder = LoadRecorder(folder: folder, sources: sources(load: 3))
        try recorder.write(census: [], at: now)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(left == Set(kept + [LoadStats.fileName("load", for: now)]), "\(left.sorted())")
    }

    /// The app calls `record` from its Heartbeat on the main thread; the sample is taken and written on the recorder's
    /// own queue.
    @Test func aRecordIsTakenOffTheCallersThreadOnItsQueue() async throws {
        let folder = temp.url("stats")
        let label = Locked<String?>(nil)
        var fake = sources(load: 5)
        fake.averages = {
            label.set(String(cString: __dispatch_queue_get_label(nil)))
            return [5, 5, 5]
        }
        let recorder = LoadRecorder(folder: folder, sources: fake)
        let done = DispatchSemaphore(value: 0)
        let written = Locked<LoadSample?>(nil)
        recorder.record(census: Self.census) { sample in
            written.set(sample)
            done.signal()
        }
        #expect(await offPool { done.wait(timeout: .now() + 30) } == .success)
        #expect(label.get() == "vibeswitcher.load-recorder")
        #expect(written.get()?.sessions.count == 3)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(LoadStats.fileName("load", for: Date())).path))
    }

    /// Nothing but the command's own name and the project folder's: a fake process table whose names carry
    /// arguments (as a `ps` command column would), whose folders go below the project into secret-looking ones, and
    /// a heavy slot's note naming its command and arguments.
    @Test func noArgumentsPathsOrSecretsAreRecorded() throws {
        let folder = temp.url("stats")
        let home = "/Users/me"
        // Shaped like credentials only at run time: the files hold none (`SecretShapeLintTests`).
        let secrets = ["sk-" + "ant-api03-" + String(repeating: "Ab0", count: 12), "hunter2", "gh" + "p_" + String(repeating: "a1B", count: 12)]
        let table = [
            LoadProcess(pid: 100, ppid: 1, pgid: 100, comm: "/usr/bin/python3 train.py --api-key \(secrets[0])", cpuSeconds: 0),
            LoadProcess(pid: 101, ppid: 100, pgid: 100, comm: "python3 worker.py --password=\(secrets[1])", cpuSeconds: 0),
            LoadProcess(pid: 200, ppid: 1, pgid: 200, comm: "\(home)/bin/run-job --token \(secrets[2])", cpuSeconds: 0),
        ]
        let later = [
            LoadProcess(pid: 100, ppid: 1, pgid: 100, comm: table[0].comm, cpuSeconds: 60),
            LoadProcess(pid: 101, ppid: 100, pgid: 100, comm: table[1].comm, cpuSeconds: 30),
            LoadProcess(pid: 200, ppid: 1, pgid: 200, comm: table[2].comm, cpuSeconds: 50),
        ]
        let reads = Locked(0)
        let cwds: [Int32: String] = [100: "\(home)/dev/proj/clients/acme-\(secrets[1])/keys", 200: "\(home)/Documents/\(secrets[2])"]
        let holder = TestLock.Holder(slot: 1, note: "pid 7, pytest --token \(secrets[2]) in \(home)/dev/proj/private-\(secrets[1]), since 10:00",
                                     since: Date())
        let recorder = LoadRecorder(folder: folder, sources: sources(
            load: 60,
            processes: { reads.set(reads.get() + 1); return reads.get() == 1 ? table : later },
            cwd: { cwds[$0] },
            project: { LoadStats.project(ofFolder: $0, home: home, isRepository: { $0 == "\(home)/dev/proj" }) },
            holders: [holder]))
        let sample = try recorder.write(census: [HostCensus(root: "\(home)/dev/proj", role: .worker, sessions: 1)], at: Date())
        let text = try String(contentsOf: folder.appendingPathComponent(LoadStats.fileName("load", for: Date())), encoding: .utf8)

        for secret in secrets + ["--api-key", "--password", "--token", "train.py", "worker.py", "pytest", "/Users", "acme", "keys", "Documents", "private-"] {
            #expect(!text.contains(secret), "\(secret) in \(text)")
        }
        // Over load 48 it names the groups: their command names and the project folder, no more.
        let top = try #require(sample.top)
        #expect(top.map(\.command) == ["python3", "run-job"], "\(top)")
        #expect(top.map(\.project) == ["proj", nil])
        #expect(sample.heavy.held.map(\.project) == ["proj"])
    }

    /// A heavy slot held from a folder in no repository: its note's "project" line (vs-heavy's, the folder's own
    /// name) isn't recorded either, as a process group's folder isn't.
    @Test func aSlotHeldOutsideARepositoryNamesNoFolder() throws {
        let home = "/Users/me"
        let outside = TestLock.Holder(slot: 1, note: "pid 7, ./build.sh in \(home)/Documents/acme-acquisition, since 10:00",
                                      since: Date(), project: "acme-acquisition")
        let inside = TestLock.Holder(slot: 2, note: "pid 8, scripts/test.sh in \(home)/dev/proj, since 10:00", since: Date(), project: "proj")
        let recorder = LoadRecorder(folder: temp.url("stats"), sources: sources(
            load: 3, project: { LoadStats.project(ofFolder: $0, home: home, isRepository: { $0 == "\(home)/dev/proj" }) },
            holders: [outside, inside]))
        let sample = try recorder.write(census: [], at: Date())
        #expect(sample.heavy.held.map(\.project) == [nil, "proj"], "\(sample.heavy.held)")
        #expect(!(try LoadStats.line(sample)).contains("acme"))
    }

    @Test func overLoad48TheBusiestGroupsAreNamedByCommandAndProject() {
        // Over 60 s: a compiler group (leader bash) at 3 cores, a second one in the same project merged with it, a
        // test group in another project, and an idle one under 5 %.
        let before: [Int32: Double] = [10: 1, 11: 0, 12: 0, 20: 5, 30: 0, 40: 0]
        let now = [
            LoadProcess(pid: 10, ppid: 1, pgid: 10, comm: "bash", cpuSeconds: 1),
            LoadProcess(pid: 11, ppid: 10, pgid: 10, comm: "swift-frontend", cpuSeconds: 120),
            LoadProcess(pid: 12, ppid: 10, pgid: 10, comm: "swift-frontend", cpuSeconds: 60),
            LoadProcess(pid: 13, ppid: 10, pgid: 10, comm: "swift-frontend", cpuSeconds: 6), // started since
            LoadProcess(pid: 20, ppid: 1, pgid: 20, comm: "swift-frontend", cpuSeconds: 35),
            LoadProcess(pid: 30, ppid: 1, pgid: 30, comm: "pytest", cpuSeconds: 45),
            LoadProcess(pid: 40, ppid: 1, pgid: 40, comm: "zsh", cpuSeconds: 1),
        ]
        let folders: [Int32: String] = [10: "/r/proj", 20: "/r/proj/.vibeswitcher/worktrees/t/Sources", 30: "/r/tge/tests"]
        let groups = LoadRecorder.groups(now, previous: before, elapsed: 60, cwd: { folders[$0] },
                                         project: { $0.hasPrefix("/r/proj") ? "proj" : "tge" })
        #expect(groups == [
            LoadSample.Group(command: "swift-frontend", leader: "bash", project: "proj", cpu: 360, processes: 5),
            LoadSample.Group(command: "pytest", leader: nil, project: "tge", cpu: 75, processes: 1),
        ], "\(groups)")
    }

    @Test func aProjectIsTheRepositoryFoldersNameAndNoDeeper() {
        let home = "/Users/me"
        let repo = { (folder: String) in folder == "/Users/me/dev/proj" || folder == "/Users/me/dev/proj/vendor/lib" }
        #expect(LoadStats.project(ofFolder: "/Users/me/dev/proj/Sources/Deep", home: home, isRepository: repo) == "proj")
        #expect(LoadStats.project(ofFolder: "/Users/me/dev/proj/vendor/lib/x", home: home, isRepository: repo) == "lib")
        #expect(LoadStats.project(ofFolder: "/Users/me/dev/vs/.vibeswitcher/worktrees/task-a/Tests", home: home, isRepository: repo) == "vs")
        #expect(LoadStats.project(ofFolder: "/Users/me/Documents/taxes", home: home, isRepository: repo) == nil)
        #expect(LoadStats.project(ofFolder: home, home: home, isRepository: { _ in true }) == nil)
        #expect(LoadStats.project(ofFolder: "/opt/build/x", home: home, isRepository: repo) == nil)
        #expect(LoadStats.commandName("/opt/homebrew/bin/node --inspect secret.js") == "node")
        #expect(LoadStats.commandName("") == "?")
    }

    /// The minute's sample, read from this Mac's own process table, memory and slots, costs well under 50 ms of CPU:
    /// worst case, over load 48 (the process groups read), with no earlier look (two reads of the table).
    @Test func aSampleCostsUnder50MsOfCPU() throws {
        let folder = temp.url("stats")
        var mac = LoadRecorder.Sources.mac
        mac.sleep = { _ in }
        let quiet = LoadRecorder(folder: folder, sources: mac)
        var loaded = mac
        loaded.averages = { [60, 60, 60] }
        let busy = LoadRecorder(folder: folder, sources: loaded)
        // The first of each pays for one-time set-up (the formatter, the timebase): the next ones are the minute's.
        _ = quiet.take(census: Self.census)
        _ = busy.take(census: Self.census)
        var costs: [Double] = []
        for _ in 0..<3 {
            costs.append(quiet.take(census: Self.census).costMs)
            let sample = busy.take(census: Self.census)
            #expect(sample.top != nil)
            costs.append(sample.costMs)
        }
        print("load sample CPU cost (ms, quiet then over load 48, 3 times): \(costs)")
        #expect(costs.allSatisfy { $0 < 50 }, "\(costs)")
        // The Mac's own sources say something.
        #expect(LoadRecorder.averages()?.count == 3)
        #expect(LoadRecorder.memory()?.pressure != nil)
        #expect((LoadRecorder.processes()?.count ?? 0) > 1)
        #expect(LoadRecorder.cwd(getpid()) != nil)
    }
}

/// scripts/load-report.sh: the load profile and freezes per load bucket, from the recorder's files and the hang logs,
/// for a range of days.
struct LoadReportScriptTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let temp = Scratch()

    func report(_ arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repo.appendingPathComponent("scripts/load-report.sh").path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // The tool's run read to its end and waited for on a thread of its own, not the cooperative pool.
        let output = await offPool { () -> String in
            let read = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            waitForEnd(process)
            return read
        }
        return (process.terminationStatus, output)
    }

    @Test func itPrintsTheProfileAndFreezesPerLoadBucketForTheDays() async throws {
        let home = temp.url("home")
        let stats = home.appendingPathComponent("stats"), debug = home.appendingPathComponent("debug")
        try VibePaths.ensurePrivate(debug)
        // 2026-10-30 from 10:00 local: 60 minutes at load 10, 30 at load 30, 10 at load 60 naming a group; and a
        // sample the day after, outside the range.
        let start = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 10)))
        func sample(_ minute: Int, load: Double) -> LoadSample {
            LoadSample(t: LoadStats.stamp(start.addingTimeInterval(Double(minute) * 60)), load: [load, load, load], cores: 12,
                       memory: LoadSample.Memory(pressure: load > 50 ? "warn" : "normal", free: 40, swapUsedMb: Int(load), swapTotalMb: 1024),
                       sessions: [LoadSample.Sessions(project: "proj", role: "worker", n: Int(load / 10))],
                       heavy: LoadSample.Heavy(slots: 3, held: []),
                       top: load > 48 ? [LoadSample.Group(command: "swift-frontend", leader: nil, project: "proj", cpu: 900, processes: 9)] : nil,
                       costMs: 3)
        }
        var lines = (0..<60).map { sample($0, load: 10) } + (60..<90).map { sample($0, load: 30) } + (90..<100).map { sample($0, load: 60) }
        for item in lines { try LoadStats.append(try LoadStats.line(item), to: LoadStats.fileName("load", for: start), in: stats) }
        lines = [sample(24 * 60, load: 100)]
        try LoadStats.append(try LoadStats.line(lines[0]), to: LoadStats.fileName("load", for: start.addingTimeInterval(86_400)), in: stats)
        // Two merges: one at load 30 that failed its first run, one at load 10 that passed.
        var merges = [MergeSample(t: LoadStats.stamp(start.addingTimeInterval(70 * 60)), project: "proj", task: "a", load: [30, 30, 30],
                                  waitedS: 0, slotWaitS: 5, durationS: 600, firstRun: "failed", reran: ["x()"], rerunWhole: false, result: "passed_on_rerun"),
                      MergeSample(t: LoadStats.stamp(start.addingTimeInterval(5 * 60)), project: "proj", task: "b", load: [10, 10, 10],
                                  waitedS: 0, slotWaitS: 1, durationS: 300, firstRun: "passed", reran: nil, rerunWhole: nil, result: "passed")]
        // The first's run got 9 cores (vs-heavy's width); the second's line has none.
        merges[0].cores = 9
        for merge in merges { try merge.append(in: stats, at: start) }
        // Freezes: one at load 30 (its .txt and .log, counted once), two at load 60, one at 13:00 with no sample near.
        let names = DateFormatter()
        names.dateFormat = "yyyyMMdd-HHmmss"
        for (minute, kinds) in [(75.2, ["txt", "log"]), (91.5, ["log"]), (95.0, ["txt"]), (180.0, ["txt"])] {
            for kind in kinds {
                try VibePaths.writePrivate(Data(), to: debug.appendingPathComponent("hang-\(names.string(from: start.addingTimeInterval(minute * 60))).\(kind)"))
            }
        }

        let (status, output) = try await report(["--home", home.path, "2026-10-30", "2026-10-30"])
        #expect(status == 0, "\(output)")
        let rows = output.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        #expect(output.contains("Samples: 100 minutes"), "\(output)")
        #expect(rows.contains(["0-12", "60", "60%", "0", "0.00", "1", "5.0", "min", "0/1"]), "\(output)")
        #expect(rows.contains(["24-36", "30", "30%", "1", "2.00", "1", "10.0", "min", "1/1"]), "\(output)")
        #expect(rows.contains(["48-72", "10", "10%", "2", "12.00", "0", "-", "-"]), "\(output)")
        #expect(rows.contains { $0.first == "unsampled" && $0.dropFirst().first == "1" }, "\(output)")
        #expect(output.contains("Memory pressure: normal 90 min, warn 10 min"), "\(output)")
        #expect(output.contains("swift-frontend") && !output.contains("100.0"), "\(output)")
        // During the merge runs (70–80 min, with the freeze at 75.2; 5–10 min, none): 15 minutes, one freeze; by width.
        #expect(output.contains("During merge runs: 2 runs, 15 min, 1 freezes, 4.00 per hour"), "\(output)")
        #expect(output.contains("  width 9: 1 runs, 10 min, 1 freezes, 6.00 per hour"), "\(output)")
        #expect(output.contains("  width -: 1 runs, 5 min, 0 freezes, 0.00 per hour"), "\(output)")

        let bad = try await report(["--home", home.path, "30-10-2026"])
        #expect(bad.status == 2 && bad.output.contains("isn't a day"), "\(bad.output)")
    }
}
