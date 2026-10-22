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
        // One slot unless the test gives more: each test says how many it counts on.
        environment[TestLock.slotsVariable] = "1"
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
        let b = try start("B", bin: bin)
        b.process.waitUntilExit()
        #expect(b.process.terminationStatus == 0, "\(lines(b.output))")
        #expect(!lines(b.output).joined().contains("waiting for"), "\(lines(b.output))")
        #expect(lines(note).first != killed && lines(note).first?.contains(", scripts/test.sh in \(Self.repo.path)") == true)
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
        guard case .busy(let holders) = lock.acquire(as: "merge of c", timeout: 1, every: 0.2, waiting: { holders, _ in heard.add(holders) }) else {
            Issue.record("taken past two"); return
        }
        #expect(holders.map(\.project) == ["alpha", "beta"])
        #expect(heard.count >= 3, "\(heard.count)")
        #expect(heard.first?.map(\.slot) == [1, 2])
        #expect(TestLock.text(holders).hasPrefix("slot 1 held by pid \(getpid()), merge of a in /Users/a/dev/alpha (alpha), for "), "\(TestLock.text(holders))")
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
        let a = try heavy("genswap-suite", sleep: 60, log: log, extra: two)
        let b = try heavy("tge-pytest", sleep: 60, log: log, extra: two)
        #expect(eventually { Set(lines(log)) == ["genswap-suite start", "tge-pytest start"] })
        // The Swift side sees the same two slots held.
        let lock = TestLock(directory: url("heavy-locks").path, slots: 2)
        guard case .busy(let holders) = lock.acquire(as: "merge", timeout: 0.3) else { Issue.record("a third slot taken"); return }
        #expect(Set(holders.compactMap(\.what)) == ["genswap-suite", "tge-pytest"])
        let c = try heavy("tge-build", sleep: 0, log: log, extra: two)
        #expect(eventually { lines(c.output).joined().contains("waiting for") })
        let said = lines(c.output).joined(separator: "\n")
        #expect(said.contains("vs-heavy: tge-build: waiting for the Mac-wide test and build lock (all 2 slots held"), "\(said)")
        #expect(said.contains(", genswap-suite in \(Self.repo.path)") && said.contains(", tge-pytest in \(Self.repo.path)"), "\(said)")
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
        #expect(said.contains("(its one slot held, in \(url("heavy-locks").path)): slot 1 held by pid \(holder.processIdentifier), .venv/bin/python -m pytest -q in /Users/a/dev/TGE-ANALYSIS/.vibeswitcher/worktrees/r (TGE-ANALYSIS), for 38 min, long."), "\(said)")
        // Not ended: the holder still runs while it waits.
        #expect(kill(holder.processIdentifier, 0) == 0)
        kill(holder.processIdentifier, SIGKILL)
        waiting.process.waitUntilExit()
        #expect(waiting.process.terminationStatus == 0 && lines(log) == ["build start", "build end"])
    }
}
