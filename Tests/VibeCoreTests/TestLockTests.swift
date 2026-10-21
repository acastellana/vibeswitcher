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
    static func runVsHeavy(_ arguments: [String], lockDirectory: String, output: String, environment extra: [String: String] = [:]) throws -> Process {
        try FileManager.default.createDirectory(atPath: (output as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: output, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "setpgrp(0, 0); exec @ARGV or die", vsHeavyScript.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment[TestLock.directoryVariable] = lockDirectory
        environment[TestLock.heldVariable] = nil
        environment.merge(extra) { $1 }
        process.environment = environment
        let handle = try #require(FileHandle(forWritingAtPath: output))
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
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

    /// A process that takes the lock with perl's flock, says "held", and sleeps: another program holding it.
    func outsideHolder(_ lock: TestLock) throws -> Process {
        try FileManager.default.createDirectory(atPath: (lock.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-MFcntl=:flock", "-e", #"open(F, ">>", $ARGV[0]) or die; flock(F, LOCK_EX) or die; $| = 1; print "held\n"; sleep 60"#, lock.path]
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
        #expect(waited < 1 && after == nil)
        #expect(lock.holder()?.contains("pid \(getpid()), merge of a, since") == true)
        guard case .busy(let holder) = lock.acquire(as: "merge of b", timeout: 1) else { Issue.record("taken twice"); return }
        #expect(holder?.contains("merge of a") == true)
        Self.after(1) { first.release() }
        guard case .held(let second, let waitedAgain, let behind) = lock.acquire(as: "merge of b", timeout: hangGuard) else { Issue.record("not taken"); return }
        #expect(waitedAgain >= 0.5 && behind?.contains("merge of a") == true)
        #expect(lock.holder()?.contains("merge of b") == true)
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
        try "pid \(holder.processIdentifier), a run that died, since 01:00:00\n".write(toFile: lock.holderPath, atomically: true, encoding: .utf8)
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        guard case .held(let held, let waited, _) = lock.acquire(as: "b", timeout: 5) else { Issue.record("not taken"); return }
        #expect(waited < 1)
        #expect(lock.holder()?.contains(", b, since") == true)
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
        #expect(outputs.first?.output.contains("Waited ") == true && outputs.first?.output.contains("for the Mac-wide test and build lock") == true, "\(outputs)")
        // Let go after: the next one takes it at once.
        guard case .held(let held, let waited, _) = lock.acquire(as: "next", timeout: 2) else { Issue.record("still held"); return }
        #expect(waited < 1)
        held.release()
        // Held by someone else past the timeout: nothing runs, and it says who held it.
        let stuck = try outsideHolder(lock)
        try "pid \(stuck.processIdentifier), scripts/test.sh in /r, since 01:00:00\n".write(toFile: lock.holderPath, atomically: true, encoding: .utf8)
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
        let a = try heavy("genswap-suite", log: log)
        #expect(eventually { lines(log) == ["genswap-suite start"] })
        let b = try heavy("tge-build", log: log)
        a.process.waitUntilExit()
        b.process.waitUntilExit()
        #expect(a.process.terminationStatus == 0 && b.process.terminationStatus == 0, "\(lines(a.output)) \(lines(b.output))")
        #expect(lines(log) == ["genswap-suite start", "genswap-suite end", "tge-build start", "tge-build end"])
        let said = lines(b.output).joined(separator: "\n")
        #expect(said.contains("vs-heavy: tge-build: waiting for the Mac-wide test and build lock"), "\(said)")
        #expect(said.contains("held by pid ") && said.contains(", genswap-suite in "), "\(said)")
        #expect(said.contains("vs-heavy: tge-build: took the test and build lock after"), "\(said)")
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
        let b = try heavy("b", log: log)
        b.process.waitUntilExit()
        #expect(b.process.terminationStatus == 0 && !lines(b.output).joined().contains("waiting for"), "\(lines(b.output))")
        #expect(lines(note).first?.contains(", b in ") == true)
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
        guard case .busy(let holder) = lock.acquire(as: "merge", timeout: 0.5) else { Issue.record("taken beside vs-heavy"); return }
        #expect(holder?.contains(", held in ") == true)
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
    /// it), with the fakes first on PATH and the lock in this test's scratch; its output goes to `<name>.out`.
    func start(_ name: String, sleep: Int = 1, bin: String) throws -> (process: Process, output: String) {
        let output = url("\(name).out").path
        FileManager.default.createFile(atPath: output, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "setpgrp(0, 0); exec @ARGV or die", "/bin/bash", Self.repo.appendingPathComponent("scripts/test.sh").path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = bin + ":/usr/bin:/bin"
        environment["RUN"] = name
        environment["SWIFT_SLEEP"] = String(sleep)
        environment[TestLock.directoryVariable] = url("script-locks").path
        environment[TestLock.heldVariable] = nil
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
        #expect(said.contains(", scripts/test.sh in \(Self.repo.path), since"), "\(said)")
        #expect(said.contains("vs-heavy: scripts/test.sh: took the test and build lock after"), "\(said)")
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
        let b = try start("B", bin: bin)
        b.process.waitUntilExit()
        #expect(b.process.terminationStatus == 0, "\(lines(b.output))")
        #expect(!lines(b.output).joined().contains("waiting for"), "\(lines(b.output))")
        #expect(lines(note).first != killed && lines(note).first?.contains(", scripts/test.sh in \(Self.repo.path)") == true)
    }
}
