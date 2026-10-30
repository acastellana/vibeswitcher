import Foundation
import Testing
@testable import VibeCore

/// scripts/test-under-load.sh's refusals, through `--check-only` (it starts nothing) with fake readings; its waits, its
/// one load run at a time in a heavy-work slot and its top-up, with the fake burner (busy loops that sleep) and a fake
/// load read from a file; and the workers' and verifiers' prompts sending every load test through it. Its cleanup (the
/// busy loops gone after Ctrl-C, a failing command, a dead owner, SIGKILL) is scripts/test-under-load-selfcheck.sh's.
/// Each test's slots and load-run lock are in a folder of its own: a test run under the harness (whose suites run this
/// one) must not wait for the very run it's in.
@Suite struct LoadHarnessTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let cores = ProcessInfo.processInfo.processorCount
    let temp = Scratch()

    /// This test's own folder of heavy-work slots and load-run lock (VIBESWITCHER_TEST_LOCK_DIR).
    let locks: URL

    init() throws {
        locks = temp.url("load-locks")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// The harness with `arguments`, not started; `fake` readings (load, memory, disk, owner name, burner, tick) go in
    /// its environment, `output` takes what it says.
    func process(_ arguments: [String], fake: [String: String] = [:], claudeCode: Bool = false, heldSlot: Bool = false) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repo.appendingPathComponent("scripts/test-under-load.sh").path] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("TEST_UNDER_LOAD_") }
        environment["CLAUDECODE"] = claudeCode ? "1" : nil
        // heldSlot: run under a holder of one of this folder's slots (`vs-heavy bash scripts/test-under-load.sh`, a
        // merge's test command), where vs-heavy runs it at once in its own process.
        environment["VIBESWITCHER_TEST_LOCK"] = heldSlot ? locks.appendingPathComponent("test-build.lock").path : nil
        environment["VIBESWITCHER_TEST_LOCK_DIR"] = locks.path
        for (name, value) in fake { environment["TEST_UNDER_LOAD_\(name)"] = value }
        process.environment = environment
        return process
    }

    /// Runs the harness with `arguments` to its end.
    func harness(_ arguments: [String], fake: [String: String] = [:], claudeCode: Bool = false) throws -> (status: Int32, output: String) {
        let process = process(arguments, fake: fake, claudeCode: claudeCode)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    /// A harness run in the background, saying what it says into the file `output`.
    final class Run {
        let process: Process
        let output: URL

        init(_ process: Process, output: URL) throws {
            self.process = process
            self.output = output
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
        }

        var said: String { (try? String(contentsOf: output, encoding: .utf8)) ?? "" }

        /// Its status, once it has ended.
        func ended() -> Int32 {
            process.waitUntilExit()
            return process.terminationStatus
        }

        /// Ends it (vs-heavy hands the TERM on, and the harness ends its runs and loops) if a failed check left it.
        func stop() {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
    }

    /// Waits until `condition` holds, looking every 50 ms for at most `seconds`: the event is a file a run writes.
    @discardableResult
    func until(_ seconds: TimeInterval = 120, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }

    /// How many of the pids in `file` are running.
    func live(_ file: URL) -> Int {
        let pids = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { pid_t($0) }
        return pids.filter { kill($0, 0) == 0 }.count
    }

    /// Readings under every threshold.
    let idle = ["FAKE_LOAD": "0.5", "FAKE_MEMORY": "80", "FAKE_DISK_GB": "100"]

    @Test func anIdleMacIsOkUpToTwoLoadProcessesPerCore() throws {
        let run = try harness(["--load", "\(2 * cores)", "--check-only"], fake: idle)
        #expect(run.status == 0, "\(run.output)")
        #expect(run.output.contains("ok to start"))
    }

    @Test func moreThanTwoLoadProcessesPerCoreAreRefused() throws {
        let run = try harness(["--load", "\(2 * cores + 1)", "--check-only"], fake: idle)
        #expect(run.status != 0)
        #expect(run.output.contains("at most \(2 * cores) load processes"), "\(run.output)")
    }

    @Test func theThresholdCanOnlyBeLowered() throws {
        let run = try harness(["--max-load", "\(2 * cores + 1)", "--check-only"], fake: idle)
        #expect(run.status != 0)
        #expect(run.output.contains("can only lower"), "\(run.output)")
    }

    @Test func aMacAlreadyLoadedIsRefusedSayingWhatToWaitFor() throws {
        let run = try harness(["--load", "2", "--check-only"], fake: idle.merging(["FAKE_LOAD": "\(2 * cores).5"]) { $1 })
        #expect(run.status != 0)
        #expect(run.output.contains("already loaded"), "\(run.output)")
        #expect(run.output.contains("Wait until the first of `uptime`'s load averages is under \(2 * cores)"), "\(run.output)")
    }

    @Test func memoryUnderTheFloorIsRefused() throws {
        let low = idle.merging(["FAKE_MEMORY": "24"]) { $1 }
        let run = try harness(["--check-only"], fake: low)
        #expect(run.status != 0)
        #expect(run.output.contains("under the floor of 25 %"), "\(run.output)")
        #expect(try harness(["--memory-floor", "20", "--check-only"], fake: low).status == 0)
    }

    @Test func aSessionWithNoLiveClaudeIsRefused() throws {
        let run = try harness(["--check-only"], fake: idle.merging(["OWNER_NAME": "no-such-process"]) { $1 }, claudeCode: true)
        #expect(run.status != 0)
        #expect(run.output.contains("no live owner"), "\(run.output)")
    }

    /// Without --check-only or the fake burner the fake load (0) is ignored: the real one, never 0.01 or less on a Mac
    /// running a suite, is over --max-load 0.01, so nothing starts (--wait 0: it refuses rather than wait).
    @Test func fakeReadingsNeverStartLoad() throws {
        let pids = temp.url("load-pids")
        let run = try harness(["--load", "1", "--max-load", "0.01", "--wait", "0", "--pid-file", pids.path, "--", "true"], fake: ["FAKE_LOAD": "0"])
        #expect(run.status != 0)
        #expect(run.output.contains("already loaded"), "\(run.output)")
        #expect(!FileManager.default.fileExists(atPath: pids.path))
    }

    /// The fake burner (loops that sleep) and a fake load read from `load` at each look, every 0.1 s: nothing burns.
    func fakeMac(_ load: URL, _ value: String = "0") throws -> [String: String] {
        try value.write(to: load, atomically: true, encoding: .utf8)
        return idle.merging(["FAKE_BURNER": "1", "FAKE_LOAD": load.path, "TICK": "0.1"]) { $1 }
    }

    /// A command that says it started in `log`, waits for the file `go` and says it ended: a run that holds on until
    /// the test lets it go.
    func held(_ name: String, log: URL, go: URL) -> [String] {
        ["--", "/bin/bash", "-c", "echo start-\(name) >> \(log.path); until [[ -e \(go.path) ]]; do sleep 0.05; done; echo end-\(name) >> \(log.path)"]
    }

    /// 2026-10-28: two load runs of 24 loops each beside two full suites took the Mac to load 150 on 12 cores. One
    /// load run burns at a time on this Mac: a second waits, saying for whose, and starts once the first is over; each
    /// holds a heavy-work slot of vs-heavy's, its note naming the loops, while it runs. Run under a slot held already
    /// (`vs-heavy bash scripts/test-under-load.sh`), the first keeps the lock in its own process all the same.
    @Test(arguments: [false, true]) func twoLoadRunsBurnOneAfterTheOtherEachInAHeavySlot(heldSlot: Bool) throws {
        let fake = try fakeMac(temp.url("load"))
        let log = temp.url("log"), first = temp.url("go-a"), second = temp.url("go-b")
        let a = try Run(process(["--load", "2", "--max-time", "300"] + held("a", log: log, go: first), fake: fake, heldSlot: heldSlot),
                        output: temp.url("a.out"))
        defer { a.stop() }
        let starts = { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        #expect(until { starts() == ["start-a"] }, "\(a.said)")
        let b = try Run(process(["--load", "2", "--max-time", "300"] + held("b", log: log, go: second), fake: fake), output: temp.url("b.out"))
        defer { b.stop() }
        #expect(until { b.said.contains("waiting for the other load run to end") }, "\(b.said)")
        #expect(b.said.contains("pid \(a.process.processIdentifier), test-under-load in "), "\(b.said)")
        // a holds a slot (vs-heavy's note; under a held slot, its holder's), and b, waiting, doesn't start its command.
        let notes = try FileManager.default.contentsOfDirectory(atPath: locks.path).filter { $0.hasSuffix(".lock.holder") && $0.hasPrefix("test-build") }
        let holders = notes.compactMap { try? String(contentsOf: locks.appendingPathComponent($0), encoding: .utf8) }
        if !heldSlot {
            #expect(holders.count == 1 && holders[0].contains("test-under-load: up to 2 busy loops (target load 2)"), "\(holders)")
        }
        #expect(starts() == ["start-a"])
        try Data().write(to: first)
        #expect(a.ended() == 0, "\(a.said)")
        #expect(until { starts().count == 3 }, "\(b.said)")
        #expect(starts() == ["start-a", "end-a", "start-b"])
        #expect(b.said.contains("the other load run is over"), "\(b.said)")
        try Data().write(to: second)
        #expect(b.ended() == 0, "\(b.said)")
        #expect(starts() == ["start-a", "end-a", "start-b", "end-b"])
        #expect(!FileManager.default.fileExists(atPath: locks.appendingPathComponent("load-run.lock.holder").path))
    }

    /// --load N is the load to top up to: the loops make up what the others' load leaves short of N (2 of 3 at load 1),
    /// stop while the others' alone are over it, and start again once they ease; it says how many ran on average.
    @Test func theLoadIsToppedUpToTheTargetNotAddedTo() throws {
        let load = temp.url("load")
        let fake = try fakeMac(load, "1")
        let pids = temp.url("pids"), step = temp.url("step")
        let run = try Run(process(["--load", "3", "--max-time", "300", "--pid-file", pids.path,
                                   "--", "/bin/bash", "-c", "until [[ -e \(step.path) ]]; do sleep 0.05; done"], fake: fake),
                          output: temp.url("out"))
        defer { run.stop() }
        #expect(until { run.said.contains("busy loops: 2 (1-minute load 1, target 3,") }, "\(run.said)")
        #expect(until { live(pids) == 2 }, "\(run.said)")
        try "10".write(to: load, atomically: true, encoding: .utf8)
        #expect(until { run.said.contains("busy loops: 0 (1-minute load 10,") && live(pids) == 0 }, "\(run.said)")
        try "0".write(to: load, atomically: true, encoding: .utf8)
        #expect(until { run.said.contains("busy loops: 3 (1-minute load 0,") && live(pids) == 3 }, "\(run.said)")
        try Data().write(to: step)
        #expect(run.ended() == 0, "\(run.said)")
        #expect(run.said.range(of: #"busy loops: [0-9.]+ on average \(target load 3, over [0-9]+ looks every 0.1 s\)"#, options: .regularExpression) != nil, "\(run.said)")
        #expect(live(pids) == 0)
    }

    /// On a loaded Mac it waits (saying so) rather than refuse once, and burns once the load is under --max-load;
    /// past --wait it gives up, having started nothing.
    @Test func aLoadedMacIsWaitedForThenItBurns() throws {
        let load = temp.url("load")
        let fake = try fakeMac(load, "\(2 * cores + 1)")
        let pids = temp.url("pids")
        let run = try Run(process(["--load", "2", "--max-time", "300", "--pid-file", pids.path, "--", "true"], fake: fake), output: temp.url("out"))
        defer { run.stop() }
        #expect(until { run.said.contains("waiting: the Mac's 1-minute load is \(2 * cores + 1), over \(2 * cores)") }, "\(run.said)")
        #expect(!run.said.contains("busy loops"))
        try "1".write(to: load, atomically: true, encoding: .utf8)
        #expect(run.ended() == 0, "\(run.said)")
        #expect(run.said.contains("busy loops: 1 (1-minute load 1, target 2,"), "\(run.said)")

        let late = temp.url("late-pids")
        try "\(2 * cores + 1)".write(to: load, atomically: true, encoding: .utf8)
        let gaveUp = try harness(["--load", "2", "--wait", "1", "--pid-file", late.path, "--", "true"], fake: fake)
        #expect(gaveUp.status != 0)
        // Whether it said it waits first depends on how soon vs-heavy handed over, on a busy Mac after the second.
        #expect(gaveUp.output.contains("already loaded"), "\(gaveUp.output)")
        #expect(!FileManager.default.fileExists(atPath: late.path))
    }

    /// Its waits hold the load-run lock or a slot: once the shell that started it is gone, it stops waiting, having
    /// started nothing, rather than hold them for nobody up to --wait.
    @Test func aRunWaitingForTheLoadStopsOnceItsOwnerIsGone() throws {
        let fake = try fakeMac(temp.url("load"), "\(2 * cores + 1)")
        let out = temp.url("out"), pidFile = temp.url("harness-pid"), pids = temp.url("pids")
        let script = Self.repo.appendingPathComponent("scripts/test-under-load.sh").path
        let owner = process([], fake: fake)
        owner.arguments = ["-c", "/bin/bash \(script) --load 2 --pid-file \(pids.path) -- true > \(out.path) 2>&1 & echo $! > \(pidFile.path); wait"]
        try owner.run()
        let said = { (try? String(contentsOf: out, encoding: .utf8)) ?? "" }
        #expect(until { said().contains("waiting: the Mac's 1-minute load") }, "\(said())")
        let harness = pid_t(((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(harness > 0)
        // Gone outright, as a turn's shell can be: no signal of its reaches the harness.
        kill(owner.processIdentifier, SIGKILL)
        owner.waitUntilExit()
        #expect(until { said().contains("stopped waiting: its owner (pid \(owner.processIdentifier)) is gone") }, "\(said())")
        #expect(until { kill(harness, 0) != 0 }, "\(said())")
        #expect(!said().contains("busy loops"))
        #expect(!FileManager.default.fileExists(atPath: pids.path))
    }

    /// The test process's home is the one its environment names. Under the harness (each run on a home of its own),
    /// it says where that was in the file TEST_UNDER_LOAD_HOME_REPORT names, for scripts/test-under-load-selfcheck.sh.
    @Test func aRunsHomeIsTheOneItsEnvironmentNames() throws {
        let environment = ProcessInfo.processInfo.environment
        // Resolved: Foundation says /tmp/… for a home given as /private/tmp/….
        let resolved = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        if let fixed = environment["CFFIXED_USER_HOME"] { #expect(resolved(NSHomeDirectory()) == resolved(fixed)) }
        if let report = environment["TEST_UNDER_LOAD_HOME_REPORT"] {
            let text = "home=\(NSHomeDirectory()) HOME=\(environment["HOME"] ?? "") CFFIXED_USER_HOME=\(environment["CFFIXED_USER_HOME"] ?? "")"
            try text.write(toFile: report, atomically: true, encoding: .utf8)
        }
    }

    @Test func workersAndVerifiersRunLoadTestsOnlyThroughTheHarness() {
        let task = LeadTask(slug: "t", title: "T", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        for prompt in [LeadPrompts.worker(task: task, root: "/r", workflow: LeadWorkflow()),
                       LeadPrompts.verifier(task: task, root: "/r", workflow: LeadWorkflow())] {
            #expect(prompt.contains(LeadPrompts.loadTests))
        }
        for words in ["only through scripts/test-under-load.sh", "never more than 2×ncpu load processes",
                      "never when the Mac is already loaded"] {
            #expect(LeadPrompts.loadTests.contains(words), "\(words)")
        }
    }

    /// On 2026-10-23 three new tests passed in their workers and failed in a loaded merge run (a SIGTERM racing a
    /// handler, a 1 s wall-clock window, a pid read before its state file existed). A worker proves the tests it adds
    /// under load before reporting done, with the result line in its report, and is told what a test waits on; the
    /// verifier (a panel's first finder only) runs them under load once.
    @Test func newTestsAreProvenUnderLoadBeforeDone() {
        let task = LeadTask(slug: "t", title: "T", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        let worker = LeadPrompts.worker(task: task, root: "/r", workflow: LeadWorkflow())
        #expect(worker.contains(LeadPrompts.newTests))
        for words in ["every test your branch adds or changes under load", "scripts/test-under-load.sh", "Before you report done",
                      "result line in your report", "-r 3 -f '<those tests>'", "waits on the real event",
                      "a file, a reply, a semaphore, an injected clock", "never on a fixed sleep or a wall-clock window"] {
            #expect(LeadPrompts.newTests.contains(words), "\(words)")
        }
        #expect(LeadPrompts.newTests.contains("--load \(2 * ProcessInfo.processInfo.activeProcessorCount) "))

        let finder = { (index: Int) in
            LeadPrompts.Finder(index: index, size: 3, focus: .contract, commit: "abc", logs: [], run: "passed", sensitive: [], nitCap: 5)
        }
        for verifier in [LeadPrompts.verifier(task: task, root: "/r", workflow: LeadWorkflow()),
                         LeadPrompts.verifier(task: task, root: "/r", workflow: LeadWorkflow(), finder: finder(1))] {
            #expect(verifier.contains(LeadPrompts.newTestsChecked))
        }
        #expect(!LeadPrompts.verifier(task: task, root: "/r", workflow: LeadWorkflow(), finder: finder(2)).contains(LeadPrompts.newTestsChecked))
        for words in ["under load once", "scripts/test-under-load.sh", "result line in your summary", "Important finding"] {
            #expect(LeadPrompts.newTestsChecked.contains(words), "\(words)")
        }
    }
}
