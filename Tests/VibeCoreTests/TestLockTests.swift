import Darwin
import Foundation
import Testing
@testable import VibeCore

/// One build or test run at a time on this Mac, for every project: `vs-heavy` runs its command under a flock (every
/// session the app starts has it on PATH; scripts/test.sh and scripts/build-app.sh run swift build and swift test under
/// it), and merge's and an audit's test runs take the same one (`TestLock`). The second run waits, saying who holds it;
/// the kernel lets go of it when its holder exits, however it ends. Here every lock is in a scratch folder
/// (VIBESWITCHER_TEST_LOCK_DIR), never the Mac-wide one other runs hold.
struct TestLockTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let vsHeavyScript = repo.appendingPathComponent("Resources/bin/vs-heavy")

    /// `vs-heavy arguments` on the lock in `lockDirectory`, in a process group of its own (as a terminal runs it, so
    /// Ctrl-C reaches all of it), its output (both streams) to `output`.
    static func runVsHeavy(_ arguments: [String], lockDirectory: String, output: String, environment extra: [String: String] = [:],
                           in directory: String? = nil) throws -> Process {
        try FileManager.default.createDirectory(atPath: (output as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: output, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "setpgrp(0, 0); exec @ARGV or die", vsHeavyScript.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment[TestLock.directoryVariable] = lockDirectory
        environment[TestLock.heldVariable] = nil
        // One slot unless the test gives more: each test says how many it counts on.
        environment[TestLock.slotsVariable] = "1"
        environment.merge(extra) { $1 }
        process.environment = environment
        let handle = try #require(FileHandle(forWritingAtPath: output))
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        try process.run()
        return process
    }

    static func lines(_ path: String) -> [String] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    let temp = Scratch()
    /// This test's folder: every path below is in it (`Scratch.url` gives a new one each call).
    let root: URL
    init() { root = temp.url("test-lock") }

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    var lock: TestLock { TestLock(directory: url("locks").path) }

    /// A process that takes the lock (its slot `slot`) with perl's flock, says "held", and sleeps: another program
    /// holding it.
    func outsideHolder(_ lock: TestLock, slot: Int = 1) throws -> Process {
        try Self.outsideHolder(path: lock.slotPath(slot))
    }

    static func outsideHolder(path: String) throws -> Process {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-MFcntl=:flock", "-e", #"open(F, ">>", $ARGV[0]) or die; flock(F, LOCK_EX) or die; $| = 1; print "held\n"; sleep 60"#, path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        _ = pipe.fileHandleForReading.availableData
        return process
    }

    /// `body` in `seconds`, on a thread of its own: a busy run's queues can start it many seconds late.
    static func after(_ seconds: Double, _ body: @escaping @Sendable () -> Void) {
        Thread {
            Thread.sleep(forTimeInterval: seconds)
            body()
        }.start()
    }

    // MARK: TestLock (merge and audits)

    @Test func theSecondWaitsSayingWhoHoldsItAndTakesItOnceItsLetGo() throws {
        guard case .held(let first, let waited, let after) = lock.acquire(as: "merge of a", timeout: 5) else { Issue.record("not taken"); return }
        #expect(waited < 1 && after.isEmpty)
        #expect(lock.holder(1).note?.contains("pid \(getpid()), merge of a, since") == true)
        guard case .busy(let holders) = lock.acquire(as: "merge of b", timeout: 1) else { Issue.record("taken twice"); return }
        #expect(holders.count == 1 && holders.first?.note?.contains("merge of a") == true)
        Self.after(1) { first.release() }
        guard case .held(let second, let waitedAgain, let behind) = lock.acquire(as: "merge of b", timeout: hangGuard) else { Issue.record("not taken"); return }
        #expect(waitedAgain >= 0.5 && behind.first?.note?.contains("merge of a") == true)
        #expect(lock.holder(1).note?.contains("merge of b") == true)
        second.release()
    }

    @Test func aWaitStopsWhenCancelled() throws {
        guard case .held(let held, _, _) = lock.acquire(as: "a", timeout: 5) else { Issue.record("not taken"); return }
        let cancel = ShellCancel()
        cancel.cancel()
        guard case .cancelled = lock.acquire(as: "b", timeout: 30, cancel: cancel) else { Issue.record("not cancelled"); return }
        held.release()
    }

    @Test func aLockWhoseHolderDiedIsTakenAtOnce() throws {
        let holder = try outsideHolder(lock)
        guard case .busy = lock.acquire(as: "b", timeout: 0.5) else { Issue.record("taken while held"); return }
        // It dies without letting go: kill -9, and a note naming it left behind.
        try "pid \(holder.processIdentifier), a run that died, since 01:00:00\n".write(toFile: lock.slotPath(1) + ".holder", atomically: true, encoding: .utf8)
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        guard case .held(let held, let waited, _) = lock.acquire(as: "b", timeout: 5) else { Issue.record("not taken"); return }
        #expect(waited < 1)
        #expect(lock.holder(1).note?.contains(", b, since") == true)
        held.release()
    }

    @Test func theMergesTestRunHoldsTheLockAndNamesItToTheCommand() throws {
        let lock = self.lock
        let home = url("home").path
        let worktree = url("worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        // A suite of another worker holds it for a second.
        let other = try outsideHolder(lock)
        Self.after(1) { kill(other.processIdentifier, SIGTERM) }
        let seen = worktree.appendingPathComponent("seen").path
        let (stopped, outputs) = Worktrees.runChecks(setup: nil, test: "echo \"$\(TestLock.heldVariable)\" > \(RecentProjects.shellQuote(seen))",
                                                     in: worktree.path, home: home, timeout: hangGuard, lock: lock, as: "merge of x")
        other.waitUntilExit()
        #expect(stopped == nil, "\(outputs)")
        #expect(try String(contentsOfFile: seen, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == lock.path)
        #expect(outputs.first?.output.contains("Waited ") == true && outputs.first?.output.contains("for a slot of the Mac-wide test and build lock, its one slot held") == true, "\(outputs)")
        // Let go after: the next one takes it at once.
        guard case .held(let held, let waited, _) = lock.acquire(as: "next", timeout: 2) else { Issue.record("still held"); return }
        #expect(waited < 1)
        held.release()
        // Held by someone else past the timeout: nothing runs, and it says who held it.
        let stuck = try outsideHolder(lock)
        try "pid \(stuck.processIdentifier), scripts/test.sh in /r, since 01:00:00\n".write(toFile: lock.slotPath(1) + ".holder", atomically: true, encoding: .utf8)
        let (refused, ran) = Worktrees.runChecks(setup: nil, test: "true", in: worktree.path, home: home, timeout: 1, lock: lock)
        kill(stuck.processIdentifier, SIGKILL)
        stuck.waitUntilExit()
        guard case .error(let text)? = refused else { Issue.record("ran: \(String(describing: refused))"); return }
        #expect(text.contains("scripts/test.sh in /r") && text.contains("Nothing was tested") && ran.isEmpty, "\(text)")
    }

    @Test func underItsHolderTheLockIsntTakenAgain() {
        let path = TestLock(directory: "/l").path
        #expect(TestLock.standard([TestLock.directoryVariable: "/l"])?.path == path)
        #expect(TestLock.standard([TestLock.directoryVariable: "/l", TestLock.heldVariable: path]) == nil)
        // Mac-wide: one folder per user.
        #expect(TestLock.standard([TestLock.heldVariable: path])?.path.hasSuffix("tmp/vibeswitcher-\(getuid())/test-build.lock") == true)
        // Any of the folder's slots, whatever the count: a run under slot 3 of a project with more doesn't wait either.
        #expect(TestLock.standard([TestLock.directoryVariable: "/l", TestLock.heldVariable: "/l/test-build-3.lock"]) == nil)
        #expect(TestLock.standard([TestLock.directoryVariable: "/l", TestLock.heldVariable: "/l/test-build-x.lock"]) != nil)
        #expect(TestLock.standard([TestLock.directoryVariable: "/l", TestLock.heldVariable: "/m/test-build-2.lock"]) != nil)
        // The count: the variable, else the cores ÷ 4, at least 1.
        #expect(TestLock.standard([TestLock.directoryVariable: "/l", TestLock.slotsVariable: "2"])?.slots == 2)
        #expect(TestLock.standard([TestLock.directoryVariable: "/l", TestLock.slotsVariable: "0"])?.slots == TestLock.defaultSlots)
        #expect(TestLock.standard([TestLock.directoryVariable: "/l"])?.slots == max(1, ProcessInfo.processInfo.processorCount / 4))
    }

    // MARK: vs-heavy (any project's heavy work)

    /// `vs-heavy --as name sh -c '<log start>; sleep; <log end>'` on this test's scratch lock; its output in `<name>.out`.
    func heavy(_ name: String, sleep: Int = 1, log: String, extra: [String: String] = [:]) throws -> (process: Process, output: String) {
        let output = url("\(name).out").path
        let q = RecentProjects.shellQuote
        let script = "echo \(name) start >> \(q(log)); sleep \(sleep); echo \(name) end >> \(q(log))"
        return (try Self.runVsHeavy(["--as", name, "/bin/sh", "-c", script], lockDirectory: url("heavy-locks").path, output: output, environment: extra), output)
    }

    @Test func twoVsHeavyRunsGoOneAfterTheOtherTheSecondSayingWhoHoldsIt() throws {
        let log = url("heavy.log").path
        let a = try heavy("project-c-suite", log: log)
        #expect(eventually { lines(log) == ["project-c-suite start"] })
        let b = try heavy("tge-build", log: log)
        a.process.waitUntilExit()
        b.process.waitUntilExit()
        #expect(a.process.terminationStatus == 0 && b.process.terminationStatus == 0, "\(lines(a.output)) \(lines(b.output))")
        #expect(lines(log) == ["project-c-suite start", "project-c-suite end", "tge-build start", "tge-build end"])
        let said = lines(b.output).joined(separator: "\n")
        #expect(said.contains("vs-heavy: tge-build: waiting for the Mac-wide test and build lock"), "\(said)")
        #expect(said.contains("held by pid ") && said.contains(", project-c-suite in "), "\(said)")
        #expect(said.contains("vs-heavy: tge-build: took the test and build lock (slot 1 of 1) after"), "\(said)")
        #expect(lines(a.output).isEmpty, "\(lines(a.output))")
        // The command's status is vs-heavy's.
        let failing = try Self.runVsHeavy(["/bin/sh", "-c", "exit 7"], lockDirectory: url("heavy-locks").path, output: url("failing.out").path)
        failing.waitUntilExit()
        #expect(failing.terminationStatus == 7)
    }

    @Test func ctrlCOnVsHeavyLetsGoOfTheLock() throws {
        let log = url("heavy.log").path
        let a = try heavy("a", sleep: 60, log: log)
        #expect(eventually { lines(log) == ["a start"] })
        let b = try heavy("b", log: log)
        #expect(eventually { lines(b.output).joined().contains("waiting for") })
        let interrupted = Date()
        kill(-a.process.processIdentifier, SIGINT)
        a.process.waitUntilExit()
        b.process.waitUntilExit()
        #expect(a.process.terminationStatus != 0)
        #expect(b.process.terminationStatus == 0, "\(lines(b.output))")
        #expect(Date().timeIntervalSince(interrupted) < 30, "b waited for a's sleep instead")
        #expect(lines(log) == ["a start", "b start", "b end"])
    }

    @Test func aVsHeavyRunKilledOutrightLeavesNoStaleLock() throws {
        let log = url("heavy.log").path
        let a = try heavy("a", sleep: 60, log: log)
        #expect(eventually { lines(log) == ["a start"] })
        kill(-a.process.processIdentifier, SIGKILL)
        a.process.waitUntilExit()
        let note = url("heavy-locks/test-build.lock.holder").path
        #expect(lines(note).first?.contains(", a in ") == true)
        // Its supervisor ends its command (in a group of its own), then the slot is let go.
        #expect(eventually { TestLock(directory: url("heavy-locks").path).holders().isEmpty })
        #expect(lines(log) == ["a start"])
        let b = try heavy("b", log: log)
        b.process.waitUntilExit()
        #expect(b.process.terminationStatus == 0 && !lines(b.output).joined().contains("waiting for"), "\(lines(b.output))")
        // b wrote its own over it, and took it with it when done.
        #expect(lines(note).isEmpty)
    }

    /// A holder's note goes with its run (on 2026-10-22 test-build.lock.holder still named pid 56668, of a worktree
    /// cleaned up long before): vs-heavy's when it exits, its command's status kept, and on Ctrl-C; merge's and an
    /// audit's at release.
    @Test func aRunsHolderNoteGoesWithIt() throws {
        let log = url("heavy.log").path
        let note = url("heavy-locks/test-build.lock.holder").path
        let exists = { FileManager.default.fileExists(atPath: note) }
        let a = try heavy("a", sleep: 0, log: log)
        a.process.waitUntilExit()
        #expect(a.process.terminationStatus == 0 && lines(log) == ["a start", "a end"])
        #expect(!exists())
        let failing = try Self.runVsHeavy(["/bin/sh", "-c", "exit 7"], lockDirectory: url("heavy-locks").path, output: url("failing.out").path)
        failing.waitUntilExit()
        #expect(failing.terminationStatus == 7 && !exists())
        let b = try heavy("b", sleep: 60, log: log)
        #expect(eventually { lines(log).contains("b start") })
        #expect(lines(note).first?.contains(", b in ") == true)
        kill(-b.process.processIdentifier, SIGINT)
        b.process.waitUntilExit()
        #expect(!exists())
        guard case .held(let held, _, _) = lock.acquire(as: "merge of a", timeout: 5) else { Issue.record("not taken"); return }
        #expect(lock.holder(1).note?.contains("merge of a") == true)
        held.release()
        #expect(!FileManager.default.fileExists(atPath: lock.path + ".holder"))
    }

    func pid(in file: String) -> Int32? {
        (try? String(contentsOfFile: file, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Killed by its pid (how workers stop what they started) or outright, vs-heavy ends its command before its slot
    /// is let go: on 2026-10-22 the slot went with the script while its suite ran on, unlocked (process audit, #4).
    @Test(arguments: [SIGTERM, SIGKILL]) func killingVsHeavyEndsItsCommandBeforeTheSlotIsLetGo(_ signal: Int32) throws {
        let log = url("heavy.log").path, sleeper = url("sleep.pid").path, locks = url("heavy-locks").path
        let q = RecentProjects.shellQuote
        let a = try Self.runVsHeavy(["--as", "a", "/bin/sh", "-c", "echo $$ > \(q(sleeper)); exec sleep 5"], lockDirectory: locks, output: url("a.out").path)
        #expect(eventually { pid(in: sleeper) != nil })
        let sleep = try #require(pid(in: sleeper))
        // In line behind it: when it gets the slot, it says whether a's sleep is still there.
        let check = "if kill -0 \(sleep) 2> /dev/null; then echo b: the sleep runs; else echo b: the sleep is gone; fi >> \(q(log))"
        let b = try Self.runVsHeavy(["--as", "b", "/bin/sh", "-c", check], lockDirectory: locks, output: url("b.out").path)
        #expect(eventually { lines(url("b.out").path).joined().contains("waiting for") })
        kill(a.processIdentifier, signal)
        a.waitUntilExit()
        if signal == SIGTERM {
            // It exits once its command has: 128 + TERM.
            #expect(a.terminationStatus == 128 + SIGTERM, "\(lines(url("a.out").path))")
            #expect(kill(sleep, 0) != 0)
        }
        b.waitUntilExit()
        #expect(b.terminationStatus == 0, "\(lines(url("b.out").path))")
        #expect(lines(log) == ["b: the sleep is gone"])
        #expect(kill(sleep, 0) != 0)
    }

    /// Past --timeout, vs-heavy ends its command's group (what it started too) and exits 124; no holder keeps a slot
    /// for good (a pytest held the only one 3 h 23 min at 0 % CPU, 2026-10-22).
    @Test func pastItsTimeoutVsHeavyEndsItsCommandsGroupAndExits124() throws {
        let sleeper = url("sleep.pid").path, locks = url("heavy-locks").path
        let q = RecentProjects.shellQuote
        let started = Date()
        let run = try Self.runVsHeavy(["--as", "hung", "--timeout", "1s", "/bin/sh", "-c", "sleep 60 & echo $! > \(q(sleeper)); wait"],
                                      lockDirectory: locks, output: url("hung.out").path)
        run.waitUntilExit()
        #expect(run.terminationStatus == 124)
        #expect(Date().timeIntervalSince(started) < 30, "it waited for the sleep")
        #expect(lines(url("hung.out").path).joined().contains("vs-heavy: hung: ran past 1 s (--timeout): stopping it, with everything it started (exit 124)."),
                "\(lines(url("hung.out").path))")
        let sleep = try #require(pid(in: sleeper))
        #expect(eventually { kill(sleep, 0) != 0 })
        #expect(TestLock(directory: locks).holders().isEmpty)
        // Its own status within the time; the environment's when none is given; a bad one refused.
        let quick = try Self.runVsHeavy(["--timeout", "5m", "/bin/sh", "-c", "exit 3"], lockDirectory: locks, output: url("quick.out").path)
        quick.waitUntilExit()
        #expect(quick.terminationStatus == 3)
        let set = try Self.runVsHeavy(["/bin/sh", "-c", "sleep 60"], lockDirectory: locks, output: url("set.out").path,
                                      environment: ["VIBESWITCHER_HEAVY_TIMEOUT": "1s"])
        set.waitUntilExit()
        #expect(set.terminationStatus == 124)
        let bad = try Self.runVsHeavy(["--timeout", "soon", "/usr/bin/true"], lockDirectory: locks, output: url("bad.out").path)
        bad.waitUntilExit()
        #expect(bad.terminationStatus == 2)
    }

    /// Past its timeout a hung run's own group ends, and nothing else: not a process it started in a group of its own (a
    /// daemon), not another program beside it, not the run waiting in line, which takes the slot and runs.
    @Test func pastItsTimeoutOnlyTheHungRunsGroupEnds() throws {
        let locks = url("heavy-locks").path, q = RecentProjects.shellQuote
        let sleeper = url("sleep.pid").path, daemon = url("daemon.pid").path, ran = url("next.ran").path
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = ["60"]
        try bystander.run()
        defer { kill(bystander.processIdentifier, SIGKILL); bystander.waitUntilExit() }
        let hung = "sleep 60 & echo $! > \(q(sleeper)); /usr/bin/perl -e 'setpgrp(0, 0); exec \"sleep\", 60' & echo $! > \(q(daemon)); wait"
        let run = try Self.runVsHeavy(["--as", "hung", "--timeout", "2s", "/bin/sh", "-c", hung], lockDirectory: locks, output: url("hung.out").path)
        #expect(eventually { pid(in: daemon) != nil })
        let next = try Self.runVsHeavy(["--as", "next", "/bin/sh", "-c", "echo ran > \(q(ran))"], lockDirectory: locks, output: url("next.out").path)
        #expect(eventually { lines(url("next.out").path).joined().contains("waiting for") }, "\(lines(url("next.out").path))")
        run.waitUntilExit()
        #expect(run.terminationStatus == 124, "\(lines(url("hung.out").path))")
        let sleep = try #require(pid(in: sleeper)), started = try #require(pid(in: daemon))
        defer { kill(started, SIGKILL) }
        #expect(eventually { kill(sleep, 0) != 0 })
        next.waitUntilExit()
        #expect(next.terminationStatus == 0 && lines(ran) == ["ran"], "\(lines(url("next.out").path))")
        #expect(kill(started, 0) == 0, "the daemon it started in a group of its own was killed")
        #expect(kill(bystander.processIdentifier, 0) == 0 && bystander.isRunning, "a process beside it was killed")
    }

    /// A holder whose work has used almost no CPU for a while says so, to waiters and to status: "idle 40 min" (from
    /// its .active note, when that's its own); vs-heavy touches the note only while its command's group uses CPU.
    @Test func aHolderThatUsedNoCPUForLongSaysIdle() throws {
        let lock = TestLock(directory: url("heavy-locks").path)
        let holder = try outsideHolder(lock)
        defer { kill(holder.processIdentifier, SIGKILL); holder.waitUntilExit() }
        try note(lock, "pid \(holder.processIdentifier), .venv/bin/python -m pytest -q in /Users/a/dev/TGE-ANALYSIS, since 02:53:22", ago: 45 * 60)
        let active = lock.slotPath(1) + ".active"
        try "pid \(holder.processIdentifier)\n".write(toFile: active, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-(40 * 60 + 5))], ofItemAtPath: active)
        let held = lock.holder(1)
        #expect(held.isIdle() && held.text().hasSuffix("(TGE-ANALYSIS), for 45 min, long, idle 40 min"), "\(held.text())")
        #expect(held.short() == "TGE-ANALYSIS (.venv/bin/python -m pytest -q) for 45 min, idle 40 min")
        let log = url("heavy.log").path
        let waiting = try heavy("build", sleep: 0, log: log)
        #expect(eventually { lines(waiting.output).joined().contains("waiting for") })
        let said = lines(waiting.output).joined(separator: "\n")
        #expect(said.contains("(TGE-ANALYSIS), for 45 min, long, idle 40 min."), "\(said)")
        // Under 10 min it isn't idle; a note another holder left (another pid) says nothing.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9 * 60)], ofItemAtPath: active)
        #expect(!lock.holder(1).isIdle() && !lock.holder(1).text().contains("idle"))
        try "pid 1\n".write(toFile: active, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 60)], ofItemAtPath: active)
        #expect(lock.holder(1).active == nil && !lock.holder(1).isIdle())
        kill(holder.processIdentifier, SIGKILL)
        waiting.process.waitUntilExit()
        #expect(waiting.process.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: active), "the run's own .active stayed")

        // vs-heavy's own: written when it takes the slot, then touched only while its command's group uses CPU.
        let fast = [TestLock.sampleVariable: "0.2"]
        let idle = try Self.runVsHeavy(["--as", "idle", "/bin/sh", "-c", "sleep 2"], lockDirectory: lock.directory, output: url("idle.out").path, environment: fast)
        #expect(eventually { FileManager.default.fileExists(atPath: active) })
        let written = try #require(lock.holder(1).active)
        #expect(lines(active) == ["pid \(idle.processIdentifier)"])
        Thread.sleep(forTimeInterval: 1)
        #expect(lock.holder(1).active == written, "touched while its command slept")
        idle.waitUntilExit()
        #expect(idle.terminationStatus == 0 && !FileManager.default.fileExists(atPath: active))
        var touched = false
        // Most of a core for 0.8 s.
        let busy = try Self.runVsHeavy(["--as", "busy", "/usr/bin/perl", "-MTime::HiRes=time", "-e", "my $end = time + 0.8; 1 while time < $end; sleep 1"], lockDirectory: lock.directory,
                                       output: url("busy.out").path, environment: fast)
        #expect(eventually { FileManager.default.fileExists(atPath: active) })
        let first = lock.holder(1).active
        while busy.isRunning {
            if let now = lock.holder(1).active, let first, now > first { touched = true }
            usleep(50_000)
        }
        #expect(touched, "never touched while it used CPU")
    }

    /// A note naming a process that has ended (killed outright, or the slot held by something its run left running)
    /// says nothing: not to a vs-heavy waiter, nor status's and the witness's long holders.
    @Test func aNoteNamingAProcessThatsGoneSaysNothing() throws {
        let lock = TestLock(directory: url("heavy-locks").path)
        let holder = try outsideHolder(lock)
        defer { kill(holder.processIdentifier, SIGKILL); holder.waitUntilExit() }
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        try note(lock, "pid \(gone.processIdentifier), vs-heavy swift build in /Users/a/dev/p/.vibeswitcher/worktrees/cleaned, since 01:00:00",
                 ago: 40 * 60)
        #expect(lock.holder(1).note == nil && lock.holder(1).since == nil)
        let holders = lock.holders()
        #expect(holders.map(\.slot) == [1] && holders.allSatisfy { !$0.isLong() })
        #expect(TestLock.text(holders) == "slot 1 held by a run that didn't say who it is")
        var watch = LeadWitness.HeavySlots(lock: lock)
        #expect(watch.look() == nil)
        let log = url("heavy.log").path
        let waiting = try heavy("build", sleep: 0, log: log)
        #expect(eventually { lines(waiting.output).joined().contains("waiting for") })
        let said = lines(waiting.output).joined(separator: "\n")
        #expect(said.contains("slot 1 held by a run that did not say who it is.") && !said.contains("pid \(gone.processIdentifier)"), "\(said)")
        kill(holder.processIdentifier, SIGKILL)
        waiting.process.waitUntilExit()
        #expect(waiting.process.terminationStatus == 0 && lines(log) == ["build start", "build end"])
    }

    /// A holder's note records who holds the slot: its pid and when that process started, when it took the slot, and the
    /// project and task it runs for (a worktree of VibeSwitcher's: the repository's and the slug), vs-heavy's and
    /// merge's alike.
    @Test func aHoldersNoteRecordsItsPidStartProjectAndTask() throws {
        let worktree = url("alpha/.vibeswitcher/worktrees/fix-x/Sources").path
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        let before = Int(Date().timeIntervalSince1970)
        guard case .held(let held, _, _) = lock.acquire(as: "merge of x", in: worktree, timeout: 5) else { Issue.record("not taken"); return }
        let note = Self.lines(lock.path + ".holder")
        #expect(note.count == 5 && note[0].hasPrefix("pid \(getpid()), merge of x in \(worktree), since "), "\(note)")
        let taken = try #require(note[1].hasPrefix("taken ") ? Int(note[1].dropFirst(6)) : nil)
        #expect(taken >= before && taken <= Int(Date().timeIntervalSince1970))
        let own = try #require(TestLock.startTime(of: getpid()))
        #expect(note[2] == "pid started \(Int(own))", "\(note)")
        #expect(Array(note[3...]) == ["project alpha", "task fix-x"])
        let holder = lock.holder(1)
        #expect(holder.project == "alpha" && holder.task == "fix-x" && holder.who == "alpha/fix-x" && holder.since == Date(timeIntervalSince1970: TimeInterval(taken)))
        held.release()
        // vs-heavy's, from the folder it runs in; its pid's start from ps, near enough to be taken as its own.
        let locks = url("heavy-locks").path, go = url("go").path
        let a = try Self.runVsHeavy(["--as", "suite", "/bin/sh", "-c", "while [ ! -f \(RecentProjects.shellQuote(go)) ]; do sleep 0.05; done"],
                                    lockDirectory: locks, output: url("a.out").path, in: worktree)
        let heavyLock = TestLock(directory: locks)
        #expect(eventually { Self.lines(heavyLock.path + ".holder").count == 5 })
        let heavy = Self.lines(heavyLock.path + ".holder")
        #expect(heavy[0].hasPrefix("pid \(a.processIdentifier), suite in "), "\(heavy)")
        let started = try #require(heavy[2].hasPrefix("pid started ") ? TimeInterval(heavy[2].dropFirst(12)) : nil)
        #expect(abs(started - (try #require(TestLock.startTime(of: a.processIdentifier)))) <= 3, "\(heavy)")
        #expect(Array(heavy[3...]) == ["project alpha", "task fix-x"])
        let holding = heavyLock.holder(1)
        #expect(holding.note != nil && holding.who == "alpha/fix-x" && holding.held() < 60, "\(holding)")
        FileManager.default.createFile(atPath: go, contents: nil)
        a.waitUntilExit()
        #expect(a.terminationStatus == 0)
        // Elsewhere: the folder's name, and no task.
        #expect(TestLock.whose("/Users/a/dev/TGE").project == "TGE" && TestLock.whose("/Users/a/dev/TGE/").task == nil)
        #expect(TestLock.whose("/Users/a/dev/p/.vibeswitcher/worktrees/s").project == "p" && TestLock.whose("/Users/a/dev/p/.vibeswitcher/worktrees/s").task == "s")
    }

    /// A note naming a live pid that's another process's now (given again since its holder ended: its start time isn't
    /// the one recorded) says nothing, as one naming a pid that's gone.
    @Test func aNoteNamingAPidGivenAgainSaysNothing() throws {
        let holder = try outsideHolder(lock)
        defer { kill(holder.processIdentifier, SIGKILL); holder.waitUntilExit() }
        let started = try #require(TestLock.startTime(of: holder.processIdentifier))
        let line = "pid \(holder.processIdentifier), scripts/test.sh in /Users/a/dev/p/.vibeswitcher/worktrees/old, since 01:00:00"
        try "\(line)\npid started \(Int(started) - 3600)\nproject p\ntask old\n".write(toFile: lock.path + ".holder", atomically: true, encoding: .utf8)
        #expect(lock.holder(1).note == nil)
        #expect(TestLock.text(lock.holders()) == "slot 1 held by a run that didn't say who it is")
        try "\(line)\npid started \(Int(started))\nproject p\ntask old\n".write(toFile: lock.path + ".holder", atomically: true, encoding: .utf8)
        #expect(lock.holder(1).note == line && lock.holder(1).who == "p/old")
    }

    /// A holder that dies is taken over: the run in line takes its slot at once and writes its own note over the dead
    /// one's; while it waited, its folder's wait named whom it waited for.
    @Test func aWaiterTakesOverFromADeadHolder() throws {
        let locks = url("heavy-locks").path, lock = TestLock(directory: locks), q = RecentProjects.shellQuote
        let first = url("p/.vibeswitcher/worktrees/slug-a").path, second = url("p/.vibeswitcher/worktrees/slug-b").path
        for folder in [first, second] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        let started = url("b.started").path, go = url("go").path
        let a = try Self.runVsHeavy(["--as", "a", "/bin/sleep", "60"], lockDirectory: locks, output: url("a.out").path, in: first)
        #expect(eventually { lock.holder(1).task == "slug-a" })
        let b = try Self.runVsHeavy(["--as", "b", "/bin/sh", "-c", "touch \(q(started)); while [ ! -f \(q(go)) ]; do sleep 0.05; done"],
                                    lockDirectory: locks, output: url("b.out").path, in: second)
        #expect(eventually { lock.waits(for: ["b": second])["b"] != nil })
        let wait = try #require(lock.waits(for: ["b": second, "a": first])["b"])
        #expect(lock.waits(for: ["a": first])["a"] == nil)
        #expect(wait.ahead == 0 && wait.text().hasPrefix("waiting for the Mac-wide test lock (held by p/slug-a for "), "\(wait.text())")
        // a dies outright, its note left behind.
        kill(-a.processIdentifier, SIGKILL)
        a.waitUntilExit()
        #expect(eventually { FileManager.default.fileExists(atPath: started) }, "\(Self.lines(url("b.out").path))")
        let holder = lock.holder(1)
        #expect(holder.task == "slug-b" && holder.note?.hasPrefix("pid \(b.processIdentifier), b in ") == true, "\(holder)")
        #expect(lock.waits(for: ["b": second]).isEmpty)
        FileManager.default.createFile(atPath: go, contents: nil)
        b.waitUntilExit()
        #expect(b.terminationStatus == 0)
    }

    @Test func underAHolderOfTheSameLockVsHeavyRunsAtOnce() throws {
        let log = url("heavy.log").path
        let a = try heavy("outer", sleep: 2, log: log)
        #expect(eventually { lines(log) == ["outer start"] })
        // A test script the merge's test command runs (or a suite under a wrapped build): its own ancestor holds it.
        let lock = TestLock(directory: url("heavy-locks").path)
        let inner = try heavy("inner", sleep: 0, log: log, extra: [TestLock.heldVariable: lock.path])
        inner.process.waitUntilExit()
        #expect(inner.process.terminationStatus == 0 && lines(inner.output).isEmpty, "\(lines(inner.output))")
        #expect(lines(log) == ["outer start", "inner start", "inner end"])
        a.process.waitUntilExit()
        // The lock the Swift side takes is the one vs-heavy takes: merge waits for it too.
        let held = try heavy("held", sleep: 2, log: log)
        #expect(eventually { lines(log).last == "held start" })
        guard case .busy(let holders) = lock.acquire(as: "merge", timeout: 0.5) else { Issue.record("taken beside vs-heavy"); return }
        #expect(holders.first?.note?.contains(", held in ") == true)
        held.process.waitUntilExit()
    }

    // MARK: scripts/test.sh

    /// A folder with a fake `swift` (it logs "<RUN> <verb> start|end" around a sleep of SWIFT_SLEEP seconds) and a
    /// fake `node` in bin/, and the log they write.
    func fakes() throws -> (bin: String, log: String) {
        let bin = url("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = url("swift.log").path
        let swift = """
            #!/bin/bash
            echo "$TMPDIR" > \(RecentProjects.shellQuote(log)).$RUN.tmpdir
            echo "$RUN $1 start" >> \(RecentProjects.shellQuote(log))
            sleep "${SWIFT_SLEEP:-1}"
            echo "$RUN $1 end" >> \(RecentProjects.shellQuote(log))
            """
        try swift.write(to: bin.appendingPathComponent("swift"), atomically: true, encoding: .utf8)
        try "#!/bin/bash\nexit 0\n".write(to: bin.appendingPathComponent("node"), atomically: true, encoding: .utf8)
        for name in ["swift", "node"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent(name).path)
        }
        return (bin.path, log)
    }

    /// `scripts/test.sh` as run `name`, in a process group of its own (as a terminal runs it, so Ctrl-C reaches all of
    /// it), with the fakes first on PATH and the lock in this test's scratch, given `arguments`; its output goes to
    /// `<name>.out`.
    func start(_ name: String, sleep: Int = 1, bin: String, arguments: [String] = []) throws -> (process: Process, output: String) {
        let output = url("\(name).out").path
        FileManager.default.createFile(atPath: output, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "setpgrp(0, 0); exec @ARGV or die", "/bin/bash", Self.repo.appendingPathComponent("scripts/test.sh").path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = bin + ":/usr/bin:/bin"
        environment["RUN"] = name
        environment["SWIFT_SLEEP"] = String(sleep)
        environment[TestLock.directoryVariable] = url("script-locks").path
        environment[TestLock.heldVariable] = nil
        environment[TestLock.slotsVariable] = "1"
        process.environment = environment
        let handle = try #require(FileHandle(forWritingAtPath: output))
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return (process, output)
    }

    func lines(_ path: String) -> [String] { Self.lines(path) }

    @Test func twoRunsOfTheScriptRunOneAfterTheOtherTheSecondSayingWhoHoldsTheLock() throws {
        let (bin, log) = try fakes()
        let a = try start("A", bin: bin)
        #expect(eventually { lines(log).contains("A build start") })
        let b = try start("B", bin: bin)
        a.process.waitUntilExit()
        b.process.waitUntilExit()
        #expect(a.process.terminationStatus == 0 && b.process.terminationStatus == 0, "\(lines(a.output)) \(lines(b.output))")
        // Never side by side: all of A's swift, then all of B's.
        #expect(lines(log) == ["A build start", "A build end", "A test start", "A test end", "B build start", "B build end", "B test start", "B test end"])
        let said = lines(b.output).joined(separator: "\n")
        #expect(said.contains("vs-heavy: scripts/test.sh: waiting for the Mac-wide test and build lock"), "\(said)")
        #expect(said.contains(", scripts/test.sh in \(Self.repo.path) ("), "\(said)")
        #expect(said.contains("vs-heavy: scripts/test.sh: took the test and build lock (slot 1 of 1) after"), "\(said)")
        #expect(!lines(a.output).joined().contains("waiting for"))
    }

    /// `--perf` (the benches alone) takes the same lock: a default run waits for it, and it runs no web tests.
    @Test func aPerfRunHoldsTheLockToo() throws {
        let (bin, log) = try fakes()
        let a = try start("A", bin: bin, arguments: ["--perf"])
        #expect(eventually { lines(log).contains("A build start") })
        let b = try start("B", bin: bin)
        a.process.waitUntilExit()
        b.process.waitUntilExit()
        #expect(a.process.terminationStatus == 0 && b.process.terminationStatus == 0, "\(lines(a.output)) \(lines(b.output))")
        #expect(lines(log) == ["A build start", "A build end", "A test start", "A test end", "B build start", "B build end", "B test start", "B test end"])
        #expect(lines(a.output).contains { $0.hasPrefix("perf run: the benches alone") }, "\(lines(a.output))")
        #expect(!lines(a.output).contains { $0.hasPrefix("web tests: ") }, "\(lines(a.output))")
        let said = lines(b.output).joined(separator: "\n")
        #expect(said.contains("vs-heavy: scripts/test.sh: waiting for the Mac-wide test and build lock"), "\(said)")
        #expect(said.contains(", scripts/test.sh in \(Self.repo.path) ("), "\(said)")
        #expect(said.contains("vs-heavy: scripts/test.sh: took the test and build lock (slot 1 of 1) after"), "\(said)")
        #expect(!lines(a.output).joined().contains("waiting for"))
    }

    @Test func ctrlCLetsGoOfTheLock() throws {
        let (bin, log) = try fakes()
        let a = try start("A", sleep: 60, bin: bin)
        #expect(eventually { lines(log).contains("A build start") })
        let b = try start("B", bin: bin)
        #expect(eventually { lines(b.output).joined().contains("waiting for") })
        let interrupted = Date()
        kill(-a.process.processIdentifier, SIGINT)
        a.process.waitUntilExit()
        b.process.waitUntilExit()
        #expect(a.process.terminationStatus != 0)
        #expect(b.process.terminationStatus == 0, "\(lines(b.output))")
        #expect(Date().timeIntervalSince(interrupted) < 30, "B waited for A's sleep instead")
        #expect(!lines(log).contains("A test start") && lines(log).contains("B test end"))
    }

    @Test func aRunKilledOutrightLeavesNoStaleLock() throws {
        let (bin, log) = try fakes()
        let a = try start("A", sleep: 60, bin: bin)
        #expect(eventually { lines(log).contains("A build start") })
        kill(-a.process.processIdentifier, SIGKILL)
        a.process.waitUntilExit()
        // Killed outright, it couldn't remove its scratch folder (TMPDIR is <scratch>/tmp/): this test does.
        if let tmpdir = lines(log + ".A.tmpdir").first, tmpdir.hasSuffix("tmp/") {
            try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: tmpdir).deletingLastPathComponent().path)
        }
        // Its note still names it; the lock went with it.
        let note = url("script-locks/test-build.lock.holder").path
        #expect(lines(note).first?.contains(", scripts/test.sh in \(Self.repo.path)") == true)
        let killed = lines(note).first
        // vs-heavy's supervisor ends the swift it ran (in a group of its own), then the slot is let go.
        #expect(eventually { TestLock(directory: url("script-locks").path).holders().isEmpty })
        let b = try start("B", bin: bin)
        b.process.waitUntilExit()
        #expect(b.process.terminationStatus == 0, "\(lines(b.output))")
        #expect(!lines(b.output).joined().contains("waiting for"), "\(lines(b.output))")
        // B wrote its own over it, and took it with it when done.
        #expect(killed != nil && lines(note).isEmpty)
    }

    // MARK: Slots

    /// A note for slot `slot` of `lock` as a holder writes it, written `ago` seconds back.
    func note(_ lock: TestLock, slot: Int = 1, _ line: String, ago: TimeInterval = 0) throws {
        let path = lock.slotPath(slot) + ".holder"
        try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ago)], ofItemAtPath: path)
    }

    @Test func withTwoSlotsTwoRunsHoldOneEachAndAThirdWaitsNamingBoth() throws {
        let lock = TestLock(directory: url("locks").path, slots: 2)
        guard case .held(let first, _, let none) = lock.acquire(as: "merge of a", in: "/Users/a/dev/alpha", timeout: 5) else { Issue.record("not taken"); return }
        guard case .held(let second, _, _) = lock.acquire(as: "audit run of b", in: "/Users/a/dev/beta/.vibeswitcher/worktrees/x", timeout: 5) else { Issue.record("second not taken"); return }
        #expect(none.isEmpty && first.path == lock.slotPath(1) && second.path == lock.slotPath(2))
        #expect(lock.holders().map(\.slot) == [1, 2])
        #expect(lock.holders().map(\.project) == ["alpha", "beta"])
        #expect(lock.holders().map(\.what) == ["merge of a", "audit run of b"])
        // The third waits, hearing who holds both at once and then every `every`, and gives up at its timeout.
        let heard = Heard()
        guard case .busy(let holders) = lock.acquire(as: "merge of c", timeout: 1, every: 0.2, waiting: { holders, _, _ in heard.add(holders) }) else {
            Issue.record("taken past two"); return
        }
        #expect(holders.map(\.project) == ["alpha", "beta"])
        #expect(heard.count >= 3, "\(heard.count)")
        #expect(heard.first?.map(\.slot) == [1, 2])
        #expect(TestLock.text(holders).hasPrefix("slot 1 held by pid \(getpid()), merge of a in /Users/a/dev/alpha (alpha), for "), "\(TestLock.text(holders))")
        // For a repo's records: its own run as it is, another project's only as that.
        let forAlpha = TestLock.text(holders, for: "/Users/a/dev/alpha")
        #expect(forAlpha.hasPrefix("slot 1 held by pid \(getpid()), merge of a in /Users/a/dev/alpha (alpha), for "), "\(forAlpha)")
        #expect(forAlpha.contains("; slot 2 held by another project's run, for ") && !forAlpha.contains("beta"), "\(forAlpha)")
        let forBeta = TestLock.text(holders, for: "/Users/a/dev/beta/")
        #expect(forBeta.hasPrefix("slot 1 held by another project's run, for ") && !forBeta.contains("alpha"), "\(forBeta)")
        #expect(forBeta.contains("; slot 2 held by pid \(getpid()), audit run of b in /Users/a/dev/beta/.vibeswitcher/worktrees/x (beta), for "), "\(forBeta)")
        // One lets go: the third takes its slot, having waited for both.
        Self.after(0.5) { second.release() }
        guard case .held(let third, let waited, let behind) = lock.acquire(as: "merge of c", timeout: hangGuard) else { Issue.record("not taken"); return }
        #expect(third.path == lock.slotPath(2) && waited >= 0.3 && behind.count == 2)
        #expect(lock.holder(2).what == "merge of c" && lock.holder(2).project == nil)
        #expect(lock.holder(2).text().hasPrefix("pid \(getpid()), merge of c, for "), "\(lock.holder(2).text())")
        first.release()
        third.release()
        #expect(lock.holders().isEmpty)
    }

    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[TestLock.Holder]] = []
        func add(_ holders: [TestLock.Holder]) { lock.withLock { all.append(holders) } }
        var count: Int { lock.withLock { all.count } }
        var first: [TestLock.Holder]? { lock.withLock { all.first } }
    }

    @Test func aHolderOverThirtyMinutesIsLongAndADeadOneIsntCounted() throws {
        let lock = TestLock(directory: url("locks").path, slots: 3)
        let pytest = try outsideHolder(lock, slot: 2)
        defer { kill(pytest.processIdentifier, SIGKILL); pytest.waitUntilExit() }
        try note(lock, slot: 2, "pid \(pytest.processIdentifier), .venv/bin/python -m pytest -q in /Users/a/dev/TGE-ANALYSIS/.vibeswitcher/worktrees/redesign, since 02:53:22",
                 ago: 38 * 60 + 5)
        // Slot 1's note is left by a run that died: its slot is free.
        try note(lock, slot: 1, "pid 1, a run that died in /Users/a/dev/gone, since 01:00:00", ago: 90 * 60)
        let holders = lock.holders()
        #expect(holders.map(\.slot) == [2])
        let held = try #require(holders.first)
        #expect(held.isLong() && held.project == "TGE-ANALYSIS")
        #expect(held.text().hasSuffix("(TGE-ANALYSIS), for 38 min, long"), "\(held.text())")
        #expect(held.short() == "TGE-ANALYSIS (.venv/bin/python -m pytest -q) for 38 min")
        // Under 30 min it isn't.
        try note(lock, slot: 2, "pid \(pytest.processIdentifier), make in /Users/a/dev/p, since 02:53:22", ago: 29 * 60)
        #expect(lock.holders().first?.isLong() == false && lock.holders().first?.text().hasSuffix("(p), for 29 min") == true)
        // A slot past this lock's count (another project's heavy_slots) is seen too.
        let other = try outsideHolder(lock, slot: 5)
        defer { kill(other.processIdentifier, SIGKILL); other.waitUntilExit() }
        #expect(lock.holders().map(\.slot) == [2, 5])
    }

    @Test func theWitnessTellsALongHolderOnceAndForgetsItWhenItsLetGo() throws {
        let lock = TestLock(directory: url("locks").path, slots: 2)
        var watch = LeadWitness.HeavySlots(lock: lock)
        let quick = try outsideHolder(lock, slot: 1)
        defer { kill(quick.processIdentifier, SIGKILL); quick.waitUntilExit() }
        try note(lock, slot: 1, "pid \(quick.processIdentifier), swift build in /Users/a/dev/p, since 03:00:00", ago: 60)
        #expect(watch.look() == nil)
        let long = try outsideHolder(lock, slot: 2)
        try note(lock, slot: 2, "pid \(long.processIdentifier), pytest in /Users/a/dev/TGE-ANALYSIS, since 02:53:22", ago: 38 * 60)
        let looked = watch.look()
        let told = try #require(looked)
        #expect(told.contains("held long: slot 2 held by pid \(long.processIdentifier), pytest in /Users/a/dev/TGE-ANALYSIS (TGE-ANALYSIS), for 38 min, long"), "\(told)")
        #expect(told.contains("Nothing ends it"))
        #expect(watch.look() == nil)
        // Let go, and another run holds the slot long later: told afresh.
        kill(long.processIdentifier, SIGKILL)
        long.waitUntilExit()
        #expect(watch.look() == nil && watch.told.isEmpty)
        let again = try outsideHolder(lock, slot: 2)
        defer { kill(again.processIdentifier, SIGKILL); again.waitUntilExit() }
        try note(lock, slot: 2, "pid \(again.processIdentifier), pytest in /Users/a/dev/TGE-ANALYSIS, since 04:00:00", ago: 31 * 60)
        let again31 = watch.look()
        #expect(again31?.contains("for 31 min, long") == true)
    }

    @Test func withTwoSlotsThreeVsHeavyRunsGiveTwoRunningAndOneWaitingThatNamesBoth() throws {
        let log = url("heavy.log").path
        let two = [TestLock.slotsVariable: "2"]
        let a = try heavy("project-c-suite", sleep: 60, log: log, extra: two)
        let b = try heavy("tge-pytest", sleep: 60, log: log, extra: two)
        #expect(eventually { Set(lines(log)) == ["project-c-suite start", "tge-pytest start"] })
        // The Swift side sees the same two slots held.
        let lock = TestLock(directory: url("heavy-locks").path, slots: 2)
        guard case .busy(let holders) = lock.acquire(as: "merge", timeout: 0.3) else { Issue.record("a third slot taken"); return }
        #expect(Set(holders.compactMap(\.what)) == ["project-c-suite", "tge-pytest"])
        let c = try heavy("tge-build", sleep: 0, log: log, extra: two)
        #expect(eventually { lines(c.output).joined().contains("waiting for") })
        let said = lines(c.output).joined(separator: "\n")
        #expect(said.contains("vs-heavy: tge-build: waiting for the Mac-wide test and build lock (all 2 slots held"), "\(said)")
        #expect(said.contains(", project-c-suite in \(Self.repo.path)") && said.contains(", tge-pytest in \(Self.repo.path)"), "\(said)")
        // Which project: the repository a worktree of VibeSwitcher's belongs to, else the folder.
        let project = Self.repo.path.components(separatedBy: "/.vibeswitcher/worktrees/").first.map { URL(fileURLWithPath: $0).lastPathComponent }!
        #expect(said.contains("in \(Self.repo.path) (\(project)), for "), "\(said)")
        #expect(!lines(log).contains("tge-build start"))
        // kill -9 of a holder frees its slot: the waiter runs at once, not after the sleep.
        let killed = Date()
        kill(-a.process.processIdentifier, SIGKILL)
        a.process.waitUntilExit()
        c.process.waitUntilExit()
        #expect(c.process.terminationStatus == 0, "\(lines(c.output))")
        #expect(Date().timeIntervalSince(killed) < 30, "c waited for a's sleep instead")
        #expect(lines(c.output).joined().contains("took the test and build lock (slot "), "\(lines(c.output))")
        #expect(lines(log).suffix(2) == ["tge-build start", "tge-build end"])
        kill(-b.process.processIdentifier, SIGINT)
        b.process.waitUntilExit()
    }

    @Test func aVsHeavyWaiterMarksAHolderOverThirtyMinutesLong() throws {
        let lock = TestLock(directory: url("heavy-locks").path)
        let holder = try outsideHolder(lock)
        defer { kill(holder.processIdentifier, SIGKILL); holder.waitUntilExit() }
        try note(lock, "pid \(holder.processIdentifier), .venv/bin/python -m pytest -q in /Users/a/dev/TGE-ANALYSIS/.vibeswitcher/worktrees/r, since 02:53:22",
                 ago: 38 * 60 + 5)
        let log = url("heavy.log").path
        let waiting = try heavy("build", sleep: 0, log: log)
        #expect(eventually { lines(waiting.output).joined().contains("waiting for") })
        let said = lines(waiting.output).joined(separator: "\n")
        #expect(said.contains("(its one slot held, in \(url("heavy-locks").path)): 1st in line; slot 1 held by pid \(holder.processIdentifier), .venv/bin/python -m pytest -q in /Users/a/dev/TGE-ANALYSIS/.vibeswitcher/worktrees/r (TGE-ANALYSIS), for 38 min, long."), "\(said)")
        // Not ended: the holder still runs while it waits.
        #expect(kill(holder.processIdentifier, 0) == 0)
        kill(holder.processIdentifier, SIGKILL)
        waiting.process.waitUntilExit()
        #expect(waiting.process.terminationStatus == 0 && lines(log) == ["build start", "build end"])
    }

    // MARK: The line (first come, first served)

    /// Who took a slot, in order, and the places in line they were told.
    final class Taken: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        private var told: [String: String] = [:]
        func add(_ name: String) { lock.withLock { all.append(name) } }
        func tell(_ name: String, _ place: String) { lock.withLock { told[name] = place } }
        var names: [String] { lock.withLock { all } }
        func place(_ name: String) -> String? { lock.withLock { told[name] } }
    }

    /// `acquire` as `name` on a thread of its own, looking every `every` (its place in line noted in `taken`): once it
    /// holds a slot, it notes it in `taken` (and "<name> start" in `log`), holds it a moment and lets go.
    func waiter(_ lock: TestLock, _ name: String, every: TimeInterval = 30, log: String? = nil, taken: Taken) {
        Thread {
            guard case .held(let held, _, _) = lock.acquire(as: name, timeout: hangGuard, every: every, waiting: { _, ahead, _ in
                taken.tell(name, TestLock.place(behind: ahead))
            }) else { taken.add("\(name) not taken"); return }
            taken.add(name)
            if let log, let file = FileHandle(forWritingAtPath: log) {
                file.seekToEndOfFile()
                file.write(Data("\(name) start\n".utf8))
                try? file.close()
            }
            Thread.sleep(forTimeInterval: 0.3)
            held.release()
        }.start()
    }

    @Test func waitersTakeTheSlotInTheOrderTheyCameEvenOneThatLooksMoreOften() throws {
        let lock = self.lock
        let holder = try outsideHolder(lock)
        let taken = Taken()
        // A and B look twice a second; C, last, every 10 ms: without a line it would take the slot each time it's let go.
        for (index, (name, every)) in [("a", 30.0), ("b", 30.0), ("c", 0.02)].enumerated() {
            waiter(lock, name, every: every, taken: taken)
            #expect(eventually { lock.waiters().count == index + 1 })
        }
        #expect(lock.waiters().map(\.who.what) == ["a", "b", "c"])
        #expect(lock.waiters().map(\.slots) == [1, 1, 1])
        #expect(eventually { taken.place("c") == "3rd in line, behind a and b" }, "\(String(describing: taken.place("c")))")
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        #expect(eventually { taken.names.count == 3 })
        #expect(taken.names == ["a", "b", "c"])
        // Out of line once served: no ticket is left, and no number is given twice.
        #expect(eventually { lock.holders().isEmpty })
        #expect(lock.waiters().isEmpty && !FileManager.default.fileExists(atPath: lock.ticketPath(3)))
        #expect(try String(contentsOfFile: lock.queuePath, encoding: .utf8) == "3\n")
    }

    @Test func vsHeavyAndTheSwiftSideKeepOneLine() throws {
        let lock = TestLock(directory: url("heavy-locks").path)
        let holder = try outsideHolder(lock)
        try note(lock, "pid \(holder.processIdentifier), pytest -q in /Users/a/dev/TGE-ANALYSIS, since 01:00:00")
        let log = url("heavy.log").path
        let a = try heavy("a", log: log)
        #expect(eventually { lock.waiters().count == 1 })
        let b = try heavy("b", log: log)
        #expect(eventually { lock.waiters().count == 2 })
        // C, the Swift side (a merge), comes last and looks every 10 ms.
        let taken = Taken()
        waiter(lock, "c", every: 0.02, log: log, taken: taken)
        #expect(eventually { lock.waiters().count == 3 })
        let project = Self.repo.path.components(separatedBy: "/.vibeswitcher/worktrees/").first.map { URL(fileURLWithPath: $0).lastPathComponent }!
        #expect(eventually { taken.place("c") == "3rd in line, behind a (\(project)) and b (\(project))" }, "\(String(describing: taken.place("c")))")
        #expect(eventually { lines(b.output).joined().contains("its one slot held, in \(url("heavy-locks").path)): 2nd in line, behind a (\(project)); slot 1 held by pid \(holder.processIdentifier), pytest -q in /Users/a/dev/TGE-ANALYSIS (TGE-ANALYSIS), for ") },
                "\(lines(b.output))")
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        a.process.waitUntilExit()
        b.process.waitUntilExit()
        #expect(a.process.terminationStatus == 0 && b.process.terminationStatus == 0)
        #expect(eventually { taken.names == ["c"] })
        #expect(lines(log) == ["a start", "a end", "b start", "b end", "c start"])
        // B was told again as its place changed: first in line once A was served.
        #expect(lines(b.output).joined(separator: "\n").contains("still waiting (its one slot held): 1st in line; slot 1 held by pid "), "\(lines(b.output))")
    }

    @Test func aWaiterThatDiedLeavesATicketThatDoesntHoldUpTheLine() throws {
        let lock = TestLock(directory: url("heavy-locks").path)
        let holder = try outsideHolder(lock)
        let log = url("heavy.log").path
        // Killed outright: one vs-heavy alone (its perl, left waiting, notices), one with its whole group (its ticket's
        // file is left behind, let go).
        let alone = try heavy("alone", log: log)
        #expect(eventually { lock.waiters().count == 1 })
        let group = try heavy("group", log: log)
        #expect(eventually { lock.waiters().count == 2 })
        kill(alone.process.processIdentifier, SIGKILL)
        alone.process.waitUntilExit()
        kill(-group.process.processIdentifier, SIGKILL)
        group.process.waitUntilExit()
        #expect(FileManager.default.fileExists(atPath: lock.ticketPath(2)))
        #expect(eventually { !FileManager.default.fileExists(atPath: lock.ticketPath(1)) }, "the orphaned waiter kept its place")
        // The next waiter takes the slot once it's let go, passing the dead ticket over (and removing it).
        Self.after(0.5) { kill(holder.processIdentifier, SIGKILL) }
        guard case .held(let held, let waited, _) = lock.acquire(as: "next", timeout: 60) else { Issue.record("held up by a dead ticket"); return }
        holder.waitUntilExit()
        #expect(waited < 30)
        #expect(!FileManager.default.fileExists(atPath: lock.ticketPath(2)) && lock.waiters().isEmpty)
        held.release()
        #expect(lines(log).isEmpty)
    }

    @Test func anOlderVsHeavyWithoutTicketsCantStickTheLine() throws {
        // An older vs-heavy (or app) takes no ticket and waits on the slots alone, as this perl does: it may take a
        // slot ahead of the line, but waits on nothing in it and holds a slot only while its command runs, so the
        // waiter in line still gets one after it.
        let lock = self.lock
        let holder = try outsideHolder(lock)
        let taken = Taken()
        waiter(lock, "new", taken: taken)
        #expect(eventually { lock.waiters().count == 1 })
        let old = Process()
        old.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        old.arguments = ["-MFcntl=:flock", "-e", #"open(F, ">>", $ARGV[0]) or die; flock(F, LOCK_EX) or die; sleep 1"#, lock.slotPath(1)]
        try old.run()
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        old.waitUntilExit()
        #expect(old.terminationStatus == 0)
        #expect(eventually { taken.names == ["new"] })
        #expect(eventually { lock.holders().isEmpty && lock.waiters().isEmpty })
    }

    @Test func aPlaceInLineNamesWhoIsBefore() {
        func waiter(_ number: Int, _ note: String?) -> TestLock.Waiter {
            TestLock.Waiter(number: number, slots: 1, who: TestLock.Holder(slot: 0, note: note, since: nil))
        }
        #expect(TestLock.place(behind: []) == "1st in line")
        let merge = waiter(4, "pid 7, merge of x in /Users/a/dev/vibeswitcher/.vibeswitcher/worktrees/x, since 01:00:00")
        #expect(TestLock.place(behind: [merge]) == "2nd in line, behind merge of x (vibeswitcher)")
        let pytest = waiter(5, "pid 8, pytest -q in /Users/a/dev/TGE-ANALYSIS, since 01:00:00")
        #expect(TestLock.place(behind: [merge, pytest]) == "3rd in line, behind merge of x (vibeswitcher) and pytest -q (TGE-ANALYSIS)")
        let odd = waiter(6, "something else"), silent = waiter(7, nil)
        #expect(TestLock.place(behind: [merge, pytest, odd, silent]) == "5th in line, behind merge of x (vibeswitcher), pytest -q (TGE-ANALYSIS), something else and 1 more")
        #expect(TestLock.place(behind: Array(repeating: silent, count: 10)).hasPrefix("11th in line, behind a run that didn't say who it is"))
        #expect(TestLock.place(behind: Array(repeating: silent, count: 21)).hasPrefix("22nd in line"))
    }
}
