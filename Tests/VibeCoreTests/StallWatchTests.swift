import Darwin
import Foundation
import Testing
@testable import VibeCore

/// Incident 2026-11-06: five test runs in two days sat at 0 % CPU for 30–60 minutes, one at load 4.2 on 12 cores, each
/// holding a Mac-wide heavy slot and the merge queue until test_timeout_min (45) or vs-heavy's --timeout (1 h) ended
/// them. A run that makes no progress (no new output, almost no CPU in its tree) for stall_min while the Mac is under
/// load_threshold is stopped then, saying what it was stuck on, and frees its slot; a slow but progressing run, or a
/// silent one on a loaded Mac, is never stopped. Every lock here is a scratch one, never the Mac-wide one.
struct StallWatchTests {
    let temp = Scratch()

    // MARK: The judgement, on an injected clock

    /// Looks every 30 s from `start` for `span`, each giving the look `at(seconds)` says; the first time it's judged
    /// hung, in seconds from the start (nil: never).
    func hungAt(after: TimeInterval = 600, limit: Double = 24, span: TimeInterval, _ at: (TimeInterval) -> StallWatch.Look) -> TimeInterval? {
        let start = Date(timeIntervalSince1970: 1_794_000_000)
        var judge = StallWatch.Judge(after: after, loadLimit: limit, start: start)
        for seconds in stride(from: 0.0, through: span, by: 30) where judge.observe(at(seconds), at: start.addingTimeInterval(seconds)) {
            return seconds
        }
        return nil
    }

    /// The incident's run: no new output, its tree's CPU flat, the Mac at load 4.2 under 24: hung at stall_min.
    @Test func aSilentRunAtZeroCPUIsHungAtStallMin() {
        let cpu: [Int32: Double] = [87373: 12.5, 87433: 3.0]
        #expect(hungAt(span: 3600) { _ in StallWatch.Look(output: 5000, cpu: cpu, load: 4.2) } == 600)
        // CPU under 1 % of a core (0.2 s each 30 s) is no progress either.
        #expect(hungAt(span: 3600) { s in StallWatch.Look(output: 5000, cpu: [1: s / 150], load: 4.2) } == 600)
    }

    /// A run printing a line every 9 minutes, at no CPU, is never hung; nor one silent but working (a link, 1 core).
    @Test func aSlowButProgressingRunIsNeverHung() {
        #expect(hungAt(span: 4 * 3600) { s in StallWatch.Look(output: Int(s / 540), cpu: [1: 0], load: 4.2) } == nil)
        #expect(hungAt(span: 4 * 3600) { s in StallWatch.Look(output: 0, cpu: [1: s], load: 4.2) } == nil)
        // A new process in its tree each look (CPU of short ones isn't seen) is progress too.
        #expect(hungAt(span: 4 * 3600) { s in StallWatch.Look(output: 0, cpu: [Int32(s): 0], load: 4.2) } == nil)
        // A process table it couldn't read is no ground to stop it.
        #expect(hungAt(span: 4 * 3600) { _ in StallWatch.Look(output: 0, cpu: nil, load: 4.2) } == nil)
    }

    /// A silent run while the Mac's load is at or above load_threshold isn't hung: the Mac starves it. Once the load
    /// drops, it's hung only a whole stall_min after its last loaded look (at 1770 s).
    @Test func aSilentRunOnALoadedMacIsntHung() {
        #expect(hungAt(span: 4 * 3600) { _ in StallWatch.Look(output: 0, cpu: [1: 0], load: 30) } == nil)
        #expect(hungAt(span: 4 * 3600) { _ in StallWatch.Look(output: 0, cpu: [1: 0], load: 24) } == nil)
        let dropped: TimeInterval? = hungAt(span: 4 * 3600) { s in StallWatch.Look(output: 0, cpu: [1: 0], load: s < 1800 ? 40 : 4) }
        #expect(dropped == 2370, "\(String(describing: dropped))")
    }

    /// A Mac that slept 20 minutes through a run doesn't call it hung on waking: the first look after is a fresh
    /// start, and it's hung only a whole stall_min of looked-at silence later.
    @Test func aSleepThroughTheRunIsntSilence() {
        let start = Date(timeIntervalSince1970: 1_794_000_000)
        var judge = StallWatch.Judge(after: 600, loadLimit: 24, start: start)
        let quiet = StallWatch.Look(output: 10, cpu: [1: 5], load: 2)
        // Looks 2 minutes apart, asleep from 240 s to 1500 s.
        let hung = [0.0, 120, 240, 1500, 1620, 1740, 1860, 1980, 2100].map { judge.observe(quiet, at: start.addingTimeInterval($0)) }
        #expect(hung == [false, false, false, false, false, false, false, false, true], "\(hung)")
    }

    // MARK: Merge's and audits' runs (runChecks)

    /// runChecks under `lock` watched with `stall` seconds and the given `load`, in a folder of its own.
    func check(_ test: String, stall: TimeInterval, load: Double, timeout: TimeInterval = hangGuard, lock name: String = "locks")
        async throws -> (stopped: Worktrees.Check?, lock: TestLock, took: TimeInterval) {
        let folder = temp.url("run-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var lock = TestLock(directory: temp.url(name).path)
        lock.watch = StallWatch(after: stall, every: 0.1, loadLimit: 24, load: { load })
        // The scratch home is the caller's to remove, as merge's is.
        let home = folder.path + "-home"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let started = Date()
        let stopped = await offPool { Worktrees.runChecks(setup: nil, test: test, in: folder.path, home: home, timeout: timeout, lock: lock).stopped }
        return (stopped, lock, Date().timeIntervalSince(started))
    }

    /// The incident in merge's test run: silent at 0 % CPU after starting a test, it's stopped at stall_min (here 2 s),
    /// not test_timeout_min, as hung with what it was stuck on (the test, its processes, its output), and the slot goes.
    @Test func aMergeRunThatMakesNoProgressIsStoppedAsHungAndFreesItsSlot() async throws {
        let marks = temp.url("marks").path
        try FileManager.default.createDirectory(atPath: marks, withIntermediateDirectories: true)
        let test = "echo '◇ Test stuckForever() started.'; echo waiting; sleep \(Int(hangGuard)) & echo $! > \(RecentProjects.shellQuote(marks))/sleep; wait"
        let (stopped, lock, took) = try await check(test, stall: 2, load: 4.2)
        guard case .hung(let command, let after, let output, let stall?) = stopped else { Issue.record("\(String(describing: stopped))"); return }
        #expect(command == "test command" && after < hangGuard && took < hangGuard)
        #expect(stall.lastTest == "stuckForever()" && stall.load == 4.2 && stall.loadLimit == 24 && stall.idle >= 2)
        #expect(stall.tail.suffix(2) == ["◇ Test stuckForever() started.", "waiting"], "\(stall.tail)")
        #expect(stall.processes.contains { $0.hasSuffix(" sleep") }, "\(stall.processes)")
        #expect(output.contains("Stopped: no progress for \(Worktrees.duration(stall.idle)) (no new output and under 1 % of a core, at load 4.2 under load_threshold 24); last test started: stuckForever()."), "\(output)")
        #expect(Worktrees.hung(after: after, stall: stall).hasPrefix("hung: no progress for \(Worktrees.duration(stall.idle)) ("))
        // Everything it started went with it, and the slot is free at once.
        let sleep = try #require((try? String(contentsOfFile: marks + "/sleep", encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        #expect(await eventually { kill(sleep, 0) != 0 })
        #expect(lock.holders().isEmpty)
        guard case .held(let held, _, let after) = lock.acquire(as: "next", timeout: hangGuard) else { Issue.record("the slot stayed held"); return }
        held.release()
        // Free at once: the first look found no holder.
        #expect(after.isEmpty, "\(after)")
    }

    /// A failing run is a failure and a hung one is hung: merge tells them apart (a hang leaves the task as it was).
    @Test func aStalledRunIsReportedApartFromAFailingOne() async throws {
        let (failed, _, _) = try await check("echo '✘ Test broken() failed after 0.1 seconds.'; exit 1", stall: 1, load: 4.2)
        guard case .failed(let output)? = failed else { Issue.record("\(String(describing: failed))"); return }
        #expect(output.contains("broken()") && !output.contains("Stopped: no progress"))
        let (stalled, _, _) = try await check("sleep \(Int(hangGuard))", stall: 2, load: 4.2)
        guard case .hung(_, _, _, let stall?)? = stalled else { Issue.record("\(String(describing: stalled))"); return }
        #expect(stall.lastTest == nil && stall.summary.hasSuffix("; no test in its output started and never finished"))
        #expect(Worktrees.AuditRun.Outcome.hung("test command", after: 70, stall: stall.summary).text.hasPrefix("test command hung, stopped after 1 min: no progress for "))
    }

    /// A run printing a line every 0.2 s at almost no CPU is never stopped, though its silence watch is 3 s.
    @Test func aMergeRunPrintingSlowlyIsNeverStopped() async throws {
        let printer = "/usr/bin/perl -e '$| = 1; for (1 .. 25) { print \"line $_\\n\"; select(undef, undef, undef, 0.2) }'"
        let (stopped, _, _) = try await check(printer, stall: 3, load: 4.2)
        #expect(stopped == nil, "\(String(describing: stopped))")
    }

    /// A silent run while the load is above load_threshold isn't stopped: it ends by itself and passes.
    @Test func aSilentMergeRunOnALoadedMacIsntStopped() async throws {
        let (stopped, _, _) = try await check("sleep 2", stall: 0.5, load: 99)
        #expect(stopped == nil, "\(String(describing: stopped))")
    }

    /// stall_min is a workflow.md key (default 10, 0: off), and the lead's lock watches with it and load_threshold.
    @Test func stallMinIsAWorkflowSetting() {
        #expect(LeadWorkflow().stallMinutes == 10 && LeadWorkflow().stall == 600)
        #expect(LeadWorkflow.parse("---\nstall_min: 3\n---\n").stall == 180)
        #expect(LeadWorkflow.parse("---\nstall_min: 0\n---\n").stall == nil)
        #expect(LeadWorkflow.parse("---\nstall_min: soon\n---\n").stallMinutes == 10)
        #expect(LeadWorkflow.configurable.contains("stall_min"))
    }

    // MARK: Which tests it names

    /// A Swift Testing run of 200 tests, `open` of them started and unfinished. Swift Testing prints "started" before a
    /// test gets a slot (seen at width 2 on 2026-11-08: 15 tests' lines at once, slots handed out in another order), so
    /// on that day about 2,800 tests only queued for a slot were listed as running.
    static func run(open: Int) -> String {
        let started = (1...200).map { "◇ Test test\($0)() started." }
        let passed = open == 200 ? [] : (1...(200 - open)).map { "✔ Test test\($0)() passed after 1.2 seconds." }
        return (["◇ Test run started."] + started + passed).joined(separator: "\n") + "\n"
    }

    static let cantTell150 = "150 tests printed their start and never finished, but Swift Testing prints that line before a test gets a slot to run in, so the output can't say which of them were running"

    /// A run stopped with tests queued names none of them: not as "the last test started" (the one the flake ledger
    /// would blame), not in the hung file or the failure's summary, and it says plainly that it can't tell.
    @Test func aRunStoppedWithTestsQueuedNamesNoneAndSaysItCantTell() throws {
        let output = Self.run(open: 150)
        let (test, unknown, _) = StallWatch.stuck(in: output)
        #expect(test == nil && unknown == 150, "\(String(describing: test)) \(unknown)")
        let stall = StallWatch.Stall(idle: 600, load: 4.2, loadLimit: 24, lastTest: test, unknownTests: unknown, processes: [], tail: [])
        #expect(stall.summary.hasSuffix("; " + Self.cantTell150), "\(stall.summary)")
        #expect(!stall.summary.contains("last test started") && !stall.summary.contains("test200()"), "\(stall.summary)")
        #expect(MergeRerun.phase(in: output) == .testingUnknown(open: 150))
        let capital = "1" + Self.cantTell150.dropFirst()
        #expect(MergeRerun.phaseText(output) == capital + ".", "\(MergeRerun.phaseText(output))")
        let file = MergeRerun.hungLog(task: "add-b", commit: "0123", command: "test command", after: 600, output: output)
        #expect(file.contains("\nIt was testing.\n" + Self.cantTell150 + ".\n") && !file.contains("Started and never finished"), "\(file)")
        let failures = TestFailures(output: output)
        #expect(failures.unfinished.count == 150 && failures.running.isEmpty)
        let summary = try #require(failures.summary())
        #expect(summary.hasPrefix(capital) && !summary.contains("test200()"), "\(summary)")
    }

    /// A crash with tests queued names none of them as failing, yet it stopped partway: the whole command runs again.
    @Test func aCrashWithTestsQueuedRerunsWholeNamingNone() throws {
        var workflow = LeadWorkflow()
        workflow.testCommand = "bash scripts/test.sh"
        let plan = try #require(MergeRerun.plan(after: Self.run(open: 150) + "Fatal error: boom\n", workflow: workflow))
        #expect(!plan.filtered && plan.tests.isEmpty && !plan.command.contains("--filter"), "\(plan)")
        #expect(MergeRerun.flakes(in: Self.run(open: 150) + "Fatal error: boom\n") == [MergeRerun.unnamed])
    }

    /// One unfinished test alone is named: a test waits for a slot only while others that haven't finished hold every
    /// one. XCTest's are named beside any number of Swift Testing's: it prints "started" as the test begins. Two suites may
    /// have a test of one name: one of two that started and ended once is still open, and alone.
    @Test func oneUnfinishedTestAloneIsNamedAndXCTestsAlways() {
        #expect(StallWatch.stuck(in: Self.run(open: 1)).test == "test200()")
        #expect(StallWatch.stuck(in: Self.run(open: 1)).unknown == 0)
        #expect(MergeRerun.phaseText(Self.run(open: 1)) == "Started and never finished: test200().")
        let mixed = "◇ Test a() started.\n◇ Test b() started.\nTest Case '-[VibeCoreTests.OldTests testHangs]' started.\n"
        #expect(MergeRerun.running(in: mixed) == MergeRerun.Running(named: ["OldTests.testHangs"], unknown: 2))
        let twins = "◇ Test same() started.\n◇ Test same() started.\n✔ Test same() passed after 0.1 seconds.\n"
        #expect(MergeRerun.running(in: twins) == MergeRerun.Running(named: ["same()"]))
        #expect(MergeRerun.hung(in: twins) == ["same()"])
        #expect(TestFailures(output: twins).running == ["same()"])
    }

    /// A stall's report repeats the output's last lines, and what's read afterwards is the output with the report after
    /// it: its lines aren't the run's a second time. A line like the report's earlier on is only output.
    @Test func aStallsReportIsntReadAsMoreOfTheRun() {
        let output = "◇ Test only() started.\nwaiting"
        let (test, unknown, tail) = StallWatch.stuck(in: output)
        let report = StallWatch.Stall(idle: 600, load: 4.2, loadLimit: 24, lastTest: test, unknownTests: unknown, processes: ["1 0 sleeping 0.0 sleep"], tail: tail).report
        let said = output + "\n\n" + report
        #expect(said.contains("    ◇ Test only() started."), "\(said)")
        #expect(MergeRerun.running(in: said) == MergeRerun.Running(named: ["only()"]), "\(MergeRerun.running(in: said))")
        #expect(MergeRerun.phaseText(said) == "Started and never finished: only().")
        #expect(MergeRerun.running(in: StallWatch.Stall.reportStart + "a line of its own\n" + said) == MergeRerun.Running(named: ["only()"]))
    }

    /// Stopped for real, by a merge run's watch: several tests open, the stall names none and says so.
    @Test func aMergeRunStoppedWithSeveralOpenBlamesNone() async throws {
        let test = "echo '◇ Test one() started.'; echo '◇ Test two() started.'; echo '◇ Test three() started.'; exec sleep \(Int(hangGuard))"
        let (stopped, _, _) = try await check(test, stall: 2, load: 4.2)
        guard case .hung(_, _, let output, let stall?) = stopped else { Issue.record("\(String(describing: stopped))"); return }
        #expect(stall.lastTest == nil && stall.unknownTests == 3, "\(stall)")
        #expect(stall.summary.contains("3 tests printed their start and never finished") && !stall.summary.contains("last test started"), "\(stall.summary)")
        #expect(output.contains("3 tests printed their start and never finished"), "\(output)")
    }

    // MARK: vs-heavy

    /// vs-heavy's report has the same rule: several Swift Testing tests open names none, and says it can't tell.
    @Test func vsHeavyNamesNoTestWhenSeveralMayBeQueued() async throws {
        let stuck = "$| = 1; print \"\\x{25C7} Test one() started.\\n\\x{25C7} Test two() started.\\n\\x{25C7} Test three() started.\\n\"; sleep \(Int(hangGuard))"
        let (status, output, _) = try await vsHeavy(["--as", "stuck", "--stall", "2s", "/usr/bin/perl", "-CS", "-e", stuck], load: "4.2", name: "queued")
        #expect(status == 125, "\(output)")
        #expect(output.contains("(exit 125); 3 tests printed their start and never finished, but Swift Testing prints that line before a test gets a slot to run in, so the output can't say which of them were running."), "\(output)")
        #expect(!output.contains("last test started"), "\(output)")
    }

    func vsHeavy(_ arguments: [String], load: String, name: String) async throws -> (status: Int32, output: String, locks: String) {
        let locks = temp.url("heavy-locks").path, out = temp.url(name + ".out").path
        let run = try TestLockTests.runVsHeavy(arguments, lockDirectory: locks, output: out,
                                               environment: [TestLock.sampleVariable: "0.1", "VIBESWITCHER_HEAVY_LOAD": load])
        #expect(await exited(run), "pid \(run.processIdentifier) still running")
        return (run.terminationStatus, (try? String(contentsOfFile: out, encoding: .utf8)) ?? "", locks)
    }

    /// The incident under vs-heavy: silent at 0 % CPU after starting a test, it's stopped at --stall (exit 125, its own:
    /// past --timeout is 124), saying the test, its processes and its output's tail, and the slot is let go. Its last
    /// line says what ended it, after the tail (2026-11-12: workers waited on runs they couldn't tell were over).
    @Test func vsHeavyStopsARunThatMakesNoProgressAndLetsGoOfItsSlot() async throws {
        let stuck = "$| = 1; print \"\\x{25C7} Test stuckForever() started.\\n\"; print \"waiting\\n\"; sleep \(Int(hangGuard))"
        let started = Date()
        let (status, output, locks) = try await vsHeavy(["--as", "stuck", "--stall", "2s", "/usr/bin/perl", "-CS", "-e", stuck], load: "4.2", name: "stuck")
        #expect(status == 125, "\(output)")
        #expect(Date().timeIntervalSince(started) < hangGuard)
        #expect(output.contains("vs-heavy: stuck: no progress for ") && output.contains(" s (no new output and under 1 % of a core, at load 4.2 under load_threshold "), "\(output)")
        #expect(output.contains("(exit 125); last test started: stuckForever()."), "\(output)")
        #expect(output.contains("vs-heavy: its processes (pid, parent, state, CPU time, name):\n") && output.contains("/usr/bin/perl"), "\(output)")
        #expect(output.contains("vs-heavy: its output's last 2 lines:\n    ◇ Test stuckForever() started.\n    waiting\n"), "\(output)")
        let last = output.split(separator: "\n").last.map(String.init) ?? ""
        #expect(last.hasPrefix("vs-heavy: stuck: ended: no progress for ") && last.hasSuffix(" s (--stall), stopped with everything it started (exit 125)."), "\(output)")
        let lock = TestLock(directory: locks)
        #expect(lock.holders().isEmpty)
        guard case .held(let held, _, _) = lock.acquire(as: "next", timeout: 5) else { Issue.record("the slot stayed held"); return }
        held.release()
        // VIBESWITCHER_HEAVY_STALL sets it too; "off" and a bad one.
        let set = try TestLockTests.runVsHeavy(["sleep", "\(Int(hangGuard))"], lockDirectory: locks, output: temp.url("set.out").path,
                                              environment: [TestLock.sampleVariable: "0.1", "VIBESWITCHER_HEAVY_LOAD": "1", TestLock.stallVariable: "2s"])
        #expect(await exited(set), "pid \(set.processIdentifier) still running")
        #expect(set.terminationStatus == 125)
        let off = try await vsHeavy(["--stall", "off", "sleep", "1"], load: "1", name: "off")
        #expect(off.status == 0, "\(off.output)")
        let bad = try await vsHeavy(["--stall", "soon", "true"], load: "1", name: "bad")
        #expect(bad.status == 2)
    }

    /// A short --stall is looked at often enough to see the work: a silent run busy on a core (a link, a release
    /// build) isn't stopped, though vs-heavy's own looks are a minute apart (VIBESWITCHER_HEAVY_SAMPLE unset).
    @Test func vsHeavyLooksOftenEnoughForAShortStall() async throws {
        let locks = temp.url("heavy-locks").path, out = temp.url("busy.out").path
        let busy = "my $end = time + 4; 1 while time < $end"
        let run = try TestLockTests.runVsHeavy(["--stall", "2s", "/usr/bin/perl", "-MTime::HiRes=time", "-e", busy], lockDirectory: locks, output: out,
                                               environment: [TestLock.sampleVariable: "", "VIBESWITCHER_HEAVY_LOAD": "1"])
        #expect(await exited(run), "pid \(run.processIdentifier) still running")
        let output = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
        #expect(run.terminationStatus == 0 && !output.contains("no progress"), "\(output)")
    }

    /// F1: progress is CPU anywhere in the run's tree, not only its process group: a silent run whose work is a
    /// grandchild in a group of its own (swift test's swiftpm-testing-helper), busy on a core, isn't stopped.
    @Test func vsHeavySeesWorkInAGrandchildInAGroupOfItsOwn() async throws {
        let locks = temp.url("heavy-locks").path, out = temp.url("helper-busy.out").path
        let helper = "/usr/bin/perl -MTime::HiRes=time -e 'setpgrp(0, 0); my $end = time + 4; 1 while time < $end' & wait"
        let run = try TestLockTests.runVsHeavy(["--stall", "2s", "/bin/sh", "-c", helper], lockDirectory: locks, output: out,
                                               environment: [TestLock.sampleVariable: "0.1", "VIBESWITCHER_HEAVY_LOAD": "1"])
        #expect(await exited(run), "pid \(run.processIdentifier) still running")
        let output = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
        #expect(run.terminationStatus == 0 && !output.contains("no progress"), "\(output)")
    }

    /// Stopping a run ends its whole tree: a grandchild in a process group of its own (swift test starts
    /// swiftpm-testing-helper so) that outlives its parent goes too; a process beside the run doesn't.
    @Test func vsHeavyStoppingARunEndsAGrandchildInAGroupOfItsOwn() async throws {
        let locks = temp.url("heavy-locks").path, out = temp.url("tree.out").path, mark = temp.url("helper.pid").path
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = ["\(Int(hangGuard))"]
        try bystander.run()
        defer { kill(bystander.processIdentifier, SIGKILL); waitForEnd(bystander) }
        // The helper: its own group, TERM ignored, its parent's end ignored.
        let helper = "/usr/bin/perl -e '$SIG{TERM} = \"IGNORE\"; setpgrp(0, 0); sleep \(Int(hangGuard))' & echo $! > \(RecentProjects.shellQuote(mark)); wait"
        let run = try TestLockTests.runVsHeavy(["--stall", "2s", "/bin/sh", "-c", helper], lockDirectory: locks, output: out,
                                               environment: [TestLock.sampleVariable: "0.1", "VIBESWITCHER_HEAVY_LOAD": "1"])
        #expect(await exited(run), "pid \(run.processIdentifier) still running")
        #expect(run.terminationStatus == 125, "\((try? String(contentsOfFile: out, encoding: .utf8)) ?? "")")
        let pid = try #require((try? String(contentsOfFile: mark, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        defer { kill(pid, SIGKILL) }
        #expect(kill(pid, 0) != 0, "the helper outlived its run")
        #expect(kill(bystander.processIdentifier, 0) == 0 && bystander.isRunning, "a process beside it was killed")
        #expect(TestLock(directory: locks).holders().isEmpty)
    }

    /// Under vs-heavy, a run printing a line every 0.2 s at almost no CPU is never stopped, though --stall is 3 s.
    @Test func vsHeavyNeverStopsARunPrintingSlowly() async throws {
        let (status, output, _) = try await vsHeavy(["--stall", "3s", "/usr/bin/perl", "-e", "$| = 1; for (1 .. 25) { print \"line $_\\n\"; select(undef, undef, undef, 0.2) }"],
                                              load: "4.2", name: "printer")
        #expect(status == 0 && output.contains("line 25") && !output.contains("no progress"), "\(output)")
    }

    /// Under vs-heavy, a silent run while the load is above load_threshold isn't stopped.
    @Test func vsHeavyDoesntStopASilentRunOnALoadedMac() async throws {
        let (status, output, _) = try await vsHeavy(["--stall", "1s", "sleep", "3"], load: "99", name: "loaded")
        #expect(status == 0 && !output.contains("no progress"), "\(output)")
    }
}
