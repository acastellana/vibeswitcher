import Foundation
import Testing

// Whether this is Linux, for the trait below. The Mac's forms of these scripts have their own tests in VibeCoreTests
// (LeftoverCheckTests, TestLockTests, TestScriptWidthTests), which don't build on Linux yet.
#if os(Linux)
private let onLinux = true
#else
private let onLinux = false
#endif

/// scripts/test.sh's leftover check and Resources/bin/vs-heavy on Linux, where each asks the system in other words
/// than the Mac's: procps' ps for the processes and their environment, nproc for the cores, a ticket in line locked
/// without O_EXLOCK. Before they had them, the check said "skipped, no process could be listed here" and passed
/// whatever was left, and vs-heavy took no slot ("couldn't take a slot of the test and build lock").
@Suite(.enabled(if: onLinux, "Linux's forms; the Mac's are tested in VibeCoreTests"))
struct TestScriptLinuxTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// How long a command a test runs may go on before the test calls it hung and ends it (VibeCoreTests' `hangGuard`):
    /// only a guard, sized for a machine running several suites at once, never a measure of speed.
    static let hangGuard: TimeInterval = 300

    /// What a command a test ran came to: its exit status, its two outputs together, and whether it ended by itself
    /// inside its limit (past it, it was told to end).
    struct Ran {
        let status: Int32
        let output: String
        let inTime: Bool
    }

    /// Set once, from the timer's thread.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false
        func raise() { lock.withLock { set = true } }
        var raised: Bool { lock.withLock { set } }
    }

    /// Runs `work`, a blocking call, on a thread of its own and awaits what it returns: the test's task gives back its
    /// thread of the cooperative pool meanwhile.
    static func offPool<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
            let thread = Thread { done.resume(returning: work()) }
            thread.name = "offPool"
            thread.start()
        }
    }

    /// `process.run()` on a thread of its own with no signal blocked. A process started on Linux from a task's thread
    /// (libdispatch's, which blocks every signal it can) inherits that: TERM, INT and HUP would wait at its door for
    /// good, a `sleep` would end only by KILL, and vs-heavy would never hear that it's to stop.
    static func start(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let thread = Thread {
                var none = sigset_t()
                sigemptyset(&none)
                pthread_sigmask(SIG_SETMASK, &none, nil)
                done.resume(with: Result { try process.run() })
            }
            thread.name = "start"
            thread.start()
        }
    }

    /// `executable arguments` with `environment` (this process's when nil), read to its end and waited for. One still
    /// running after `limit` seconds is sent SIGTERM, and `inTime` is false.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                    within limit: TimeInterval = hangGuard) async throws -> Ran {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try await start(process)
        let late = Flag()
        let limitPassed = DispatchWorkItem {
            guard process.isRunning else { return }
            late.raise()
            kill(process.processIdentifier, SIGTERM)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: limitPassed)
        let output = await offPool { () -> Data in
            let read = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return read
        }
        limitPassed.cancel()
        return Ran(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self), inTime: !late.raised)
    }

    /// A new folder of one test's own: under the run's TMPDIR (scripts/test.sh's scratch), or the package's .build
    /// when the run was given none. The test removes it.
    static func scratch(_ name: String) throws -> URL {
        let given = ProcessInfo.processInfo.environment["TMPDIR"] ?? ""
        let root = given.hasPrefix("/") ? URL(fileURLWithPath: given, isDirectory: true)
            : repo.appendingPathComponent(".build/test-scratch", isDirectory: true)
        let folder = root.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// This process's environment for a vs-heavy of a test's own: without what the run's own vs-heavy gave it (its
    /// slot, its share of the cores, its settings for tests), the slots kept in `folder` (never the user's, where the
    /// run itself holds one), and TMPDIR there too. Then `extra`.
    static func heavyEnvironment(_ folder: URL, _ extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("VIBESWITCHER_HEAVY_") || key == "VS_HEAVY_CORES" || key == "VIBESWITCHER_TEST_LOCK" {
            environment[key] = nil
        }
        environment["VIBESWITCHER_TEST_LOCK_DIR"] = folder.appendingPathComponent("locks").path
        environment["TMPDIR"] = folder.path + "/"
        return environment.merging(extra) { $1 }
    }

    static let vsHeavy = repo.appendingPathComponent("Resources/bin/vs-heavy").path

    /// A process carrying the run's mark only in its environment (as a scratch host carries HOME and TMPDIR) is
    /// found there, named, ended, and fails the check.
    @Test func theLeftoverCheckFindsAProcessOfTheRun() async throws {
        let mark = "vs-test-leftover.\(UUID().uuidString.prefix(8))"
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["300"]
        sleeper.environment = ["VS_TEST_SCRATCH": "/somewhere/\(mark)/home"]
        sleeper.standardInput = FileHandle.nullDevice
        try await Self.start(sleeper)
        defer { if sleeper.isRunning { kill(sleeper.processIdentifier, SIGKILL) } }
        // The check gives a run's processes 10 s to end by themselves before it ends them.
        let check = try await Self.run("/bin/bash", [Self.repo.appendingPathComponent("scripts/test.sh").path, "--leftovers", mark])
        #expect(check.inTime)
        #expect(check.status == 1, "\(check.output)")
        #expect(check.output.contains("LEFTOVER PROCESSES"), "\(check.output)")
        // Named by its command alone, without the environment ps prints after it.
        #expect(check.output.contains("  \(sleeper.processIdentifier) /bin/sleep 300\n"), "\(check.output)")
        #expect(!check.output.contains("skipped"), "\(check.output)")
        // A check that named it has ended it before it returned (TERM, then KILL for what stayed): its end only has
        // to be collected. One that named nothing left it running, and the `defer` ends it.
        guard check.status == 1 else { return }
        await Self.offPool { sleeper.waitUntilExit() }
        #expect(sleeper.terminationReason == .uncaughtSignal && sleeper.terminationStatus == SIGTERM, "ended by \(sleeper.terminationStatus)")
        // With nothing of that mark left, the check passes and says nothing.
        let clean = try await Self.run("/bin/bash", [Self.repo.appendingPathComponent("scripts/test.sh").path, "--leftovers", mark])
        #expect(clean.status == 0 && clean.output.isEmpty, "\(clean.output)")
    }

    /// It takes its place in line and a slot, runs the command, and leaves nothing of its own in the slots' folder
    /// but the slot's and the line's lock files.
    @Test func vsHeavyRunsACommandInASlot() async throws {
        let folder = try Self.scratch("heavy-slot")
        defer { try? FileManager.default.removeItem(at: folder) }
        let ran = try await Self.run(Self.vsHeavy, ["--as", "test", "true"], environment: Self.heavyEnvironment(folder))
        #expect(ran.inTime, "\(ran.output)")
        #expect(ran.status == 0, "\(ran.output)")
        #expect(ran.output.isEmpty, "\(ran.output)")
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("locks").path).sorted()
        #expect(left.filter { $0.hasPrefix("ticket-") || $0.hasSuffix(".holder") || $0.hasSuffix(".active") } == [], "\(left)")
        #expect(left.contains("test-build.lock") && left.contains("queue.lock"), "\(left)")
        // The command's own status is the run's.
        let failing = try await Self.run(Self.vsHeavy, ["--as", "test", "bash", "-c", "exit 7"], environment: Self.heavyEnvironment(folder))
        #expect(failing.inTime && failing.status == 7, "\(failing.output)")
    }

    /// The command is told its share of the cores: a whole number, from 1 to the machine's (2 on a machine of one);
    /// with one slot, every core nproc counts.
    @Test func vsHeavyGivesItsShareOfTheCores() async throws {
        let folder = try Self.scratch("heavy-cores")
        defer { try? FileManager.default.removeItem(at: folder) }
        let counted = try await Self.run("/usr/bin/nproc", [], environment: Self.heavyEnvironment(folder))
        let machine = try #require(Int(counted.output.trimmingCharacters(in: .whitespacesAndNewlines)), "nproc: \(counted.output)")
        let ran = try await Self.run(Self.vsHeavy, ["bash", "-c", "echo $VS_HEAVY_CORES"], environment: Self.heavyEnvironment(folder))
        #expect(ran.inTime && ran.status == 0, "\(ran.output)")
        let text = ran.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let share = try #require(text.allSatisfy(\.isNumber) ? Int(text) : nil, "VS_HEAVY_CORES: \(ran.output)")
        #expect((1...max(2, machine)).contains(share), "\(share) of \(machine) cores")
        let alone = try await Self.run(Self.vsHeavy, ["bash", "-c", "echo $VS_HEAVY_CORES"],
                                       environment: Self.heavyEnvironment(folder, ["VIBESWITCHER_HEAVY_SLOTS": "1"]))
        #expect(alone.output == "\(max(2, machine))\n", "\(alone.output)")
    }
}
