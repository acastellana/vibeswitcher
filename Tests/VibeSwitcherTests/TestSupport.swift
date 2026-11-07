import Foundation
import Testing
import VibeCore

/// Set when `refuseTheAccountRoot` has run (a test in each target checks it did).
var homeGuardRan = false

/// Runs as the test bundle loads (a Mach-O initializer, like a C constructor), before any test: a run whose VibeSwitcher
/// folder is the user's own ~/.vibeswitcher stops here, with one message and no test run. Tests write there (logs,
/// state, the lead's files); a run on a scratch HOME alone used to reach the user's app.log (E-30 + R10). A scratch
/// home under the user's home (a worktree's .build/scratchhome) runs: only that one folder is refused.
@_used @_section("__DATA,__mod_init_func")
private let refuseTheAccountRoot: @convention(c) () -> Void = {
    homeGuardRan = true
    guard let refusal = VibePaths.testRefusal() else { return }
    FileHandle.standardError.write(Data((refusal + "\n").utf8))
    exit(78)
}

/// Runs as the test bundle loads too: no test reads the Mac's own free disk space (see `DiskSpace.TestRun`). The run
/// reads 1 TB free where a test gives no reading of its own; a read of the volume itself fails the test it's in (the
/// run, when it's in none: a reader on another thread), naming the path.
@_used @_section("__DATA,__mod_init_func")
private let fakeTheDisk: @convention(c) () -> Void = {
    DiskSpace.testRun = DiskSpace.TestRun(free: 1_000 * DiskSpace.gigabyte) { path in
        Issue.record(Comment(rawValue: "A test read the Mac's own free disk space (the volume holding \(path)), so its result "
                             + "hangs on how full the disk is: give it a reading where it's read (see DiskSpace.TestRun)."))
    }
}

/// How long a wait may go on before the test calls it hung. Every wait ends as soon as what it waits for happens;
/// this is only a guard, sized for a Mac running several suites at once (load 100+), never a measure of speed.
let hangGuard: TimeInterval = 300

/// The longest a test that starts a scratch host process may run, its hang guards included (as VibeHostTests'
/// `hostTestLimit`): past it the test fails and its waits end (see `until`), rather than holding the run.
let hostTestLimit: TimeLimitTrait = .timeLimit(.minutes(10))

/// Ends a scratch host that a test's `HostClient` started (this process's child, leading a process group of its own,
/// its sessions in it): SIGKILL to the group and to it, then waits for it to end and reaps it. The client reaps the
/// hosts it starts on the main queue, and only while it lives: a test's client is gone by then, and its host stayed a
/// zombie of the test run (`ZombieWatch`). Done, too, when the client reaped it first.
///
/// Only while `pid` is still that host: `pidFile` is where it wrote its pid (`$$`, before it exec'd), `folder` the test's
/// folder its command line names. A host gone already was reaped (by its client), and in a full run, whose pids wrap
/// past 99,999, its pid may be another test's child by then: a SIGKILL and a waitpid on it killed and reaped that one,
/// whose `Process` then never saw it end, and its `waitUntilExit` held the run at 0 % CPU until vs-heavy's timeout
/// (2026-11-06: LongHistoryTests' scratch host, `TestHosts.end`).
func endClientHost(_ pid: pid_t, pidFile: String, folder: String) {
    guard isClientHost(pid, pidFile: pidFile, folder: folder) else { return }
    kill(-pid, SIGKILL)
    kill(pid, SIGKILL)
    _ = BenchHostTests.waitForExit(of: pid, timeout: hangGuard)
    // The exit is posted a moment before the process can be reaped.
    let deadline = Date().addingTimeInterval(hangGuard)
    var status: Int32 = 0
    while Date() < deadline {
        let reaped = waitpid(pid, &status, WNOHANG)
        if reaped == pid || (reaped < 0 && errno != EINTR) { return }
        usleep(10_000)
    }
}

/// Whether `pid` is still the scratch host that wrote it to `pidFile`: its command line names `folder` (the script it
/// started as, or the build it exec'd), or, a zombie whose command line is gone with it, it started before the file
/// was written (a reused pid's process starts after the host it replaces ended).
func isClientHost(_ pid: pid_t, pidFile: String, folder: String) -> Bool {
    guard pid > 0, let info = ProcessTable.info(pid: pid) else { return false }
    let arguments = ProcessTable.commandLine(pid: pid)
    if !arguments.isEmpty { return arguments.contains { $0.contains(folder) } }
    guard let written = (try? FileManager.default.attributesOfItem(atPath: pidFile))?[.modificationDate] as? Date else { return false }
    return info.startTime <= written.addingTimeInterval(0.05)
}

/// The Mac's two clocks: the wall clock (`Date`), which goes on while the Mac sleeps, and the time it has been awake
/// (`CLOCK_UPTIME_RAW`, mach_absolute_time: what Swift Testing times a test on, and Dispatch's timers), which doesn't.
struct MacTime {
    var wall: () -> Date
    /// Seconds awake, from any start.
    var awake: () -> TimeInterval
    static let real = MacTime(wall: Date.init, awake: { TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 })
}

/// Whether `condition` holds within `timeout` seconds (a hang guard), checked every 20 ms. Awaiting lets the main
/// thread run what's queued for it meanwhile. A cancelled test (past its time limit) waits no more: its sleep would
/// throw at once, and the loop spin until the deadline.
@MainActor
func until(timeout: TimeInterval = hangGuard, time: MacTime = .real, _ condition: () -> Bool) async -> Bool {
    let deadline = time.wall().addingTimeInterval(timeout)
    while time.wall() < deadline, !Task.isCancelled {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

// Swift Testing runs each test as a task on Swift's cooperative pool, one thread a core. A test that blocks its thread
// (a semaphore, a group, a sleep, a process's exit, a build) holds one of those few threads for as long as it waits,
// and a dozen such tests hold them all: every other test, async ones included, and any task the code under test
// starts, waits behind them. On 2026-11-05 a full run at load 119 sat near 0 % CPU for 5 minutes that way, until the
// hang guards expired, and 8 tests in other suites failed. So a test's waits are awaited (`until`, `pause`), and
// a blocking call that can take long goes through `offPool`.

/// Runs `work`, a blocking call (a semaphore's or a group's wait, a process's `waitUntilExit`, a build), on a thread of
/// its own and awaits what it returns: the test's task gives back its thread of the cooperative pool meanwhile. `work`
/// must end on its own (each wait in it bounded): cancelling the test doesn't stop it.
func offPool<T>(_ work: @escaping () -> T) async -> T {
    await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
        let thread = Thread { done.resume(returning: work()) }
        thread.name = "offPool"
        thread.start()
    }
}

/// `offPool` for a `work` that throws: what it throws, the caller's await throws.
func offPool<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
        let thread = Thread { done.resume(with: Result { try work() }) }
        thread.name = "offPool"
        thread.start()
    }
}

/// `process.waitUntilExit()`, bounded, for a test's sync code (a helper, a `defer`): whether it was seen to end. A child
/// gone from the process table (no zombie left) while its `Process` still says it runs was reaped by someone else,
/// and `waitUntilExit` never returns for it: a full run sat at 0 % CPU until vs-heavy's timeout so (2026-11-06,
/// LongHistoryTests' scratch host; then MCPHandoverTests' tool server). Past 2 s gone, or `timeout`, it records an
/// issue naming the process and returns.
@discardableResult
func waitForEnd(_ process: Process, within timeout: TimeInterval = hangGuard) -> Bool {
    let pid = process.processIdentifier
    let deadline = Date().addingTimeInterval(timeout)
    var goneSince: Date?
    while process.isRunning, Date() < deadline {
        if kill(pid, 0) != 0, errno == ESRCH {
            if let since = goneSince { if Date().timeIntervalSince(since) > 2 { break } } else { goneSince = Date() }
        } else {
            goneSince = nil
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard process.isRunning else { return true }
    let command = ([process.executableURL?.path ?? "?"] + (process.arguments ?? [])).joined(separator: " ")
    Issue.record(Comment(rawValue: "pid \(pid) (\(command.prefix(200))) never seen to end"
                         + (goneSince != nil ? ": gone, reaped by someone else" : " in \(Int(timeout)) s")))
    return false
}

/// Whether `process` (the test's own child) ended within `timeout` (a hang guard): `waitUntilExit`, awaited and bounded,
/// looked at every 10 ms on a thread of its own (`offPool`), a cancelled test's too. Past it, false, and the process is
/// killed and waited for (10 s more), so that what the caller reads of it next (`terminationStatus`) is there.
func exited(_ process: Process, within timeout: TimeInterval = hangGuard) async -> Bool {
    await offPool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard process.isRunning else { return true }
        kill(process.processIdentifier, SIGKILL)
        let killed = Date().addingTimeInterval(10)
        while process.isRunning, Date() < killed { Thread.sleep(forTimeInterval: 0.01) }
        return false
    }
}

/// A fixed pause of `seconds` (to show that something does *not* happen meanwhile, never to wait for something that
/// does), awaited: the pool thread is free while it lasts. Ends early when the test is cancelled.
func pause(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// Where tests put their scratch files: `$TMPDIR` when it's set, else the user's temporary folder (Foundation's
/// `temporaryDirectory` ignores `$TMPDIR` on macOS). scripts/test-under-load.sh points it at a private folder per run
/// and fails when a run leaves anything there, so every scratch file a test makes goes here and is removed by it.
let scratchRoot: URL = {
    guard let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty else { return FileManager.default.temporaryDirectory }
    return URL(fileURLWithPath: tmp, isDirectory: true)
}()

/// Scratch paths under `scratchRoot` that are removed, with everything in them, when this goes. A suite keeps one as
/// a stored property: Swift Testing makes a suite instance for each test, so what a test made goes away after it.
final class Scratch: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [URL] = []

    /// A new path `scratchRoot/<prefix>-<uuid>` (not created), removed with this.
    func url(_ prefix: String) -> URL {
        adopt(scratchRoot.appendingPathComponent("\(prefix)-\(UUID().uuidString)"))
    }

    /// Removes `url` with this too (something the code under test made beside a scratch path).
    @discardableResult
    func adopt(_ url: URL) -> URL {
        lock.lock()
        paths.append(url)
        lock.unlock()
        return url
    }

    deinit {
        for url in paths { try? FileManager.default.removeItem(at: url) }
    }
}

/// Where scratch sockets and the folders holding them go: `scratchRoot` when its path is short (scripts/test.sh's
/// is), else /tmp, since a Unix socket's path is limited to 104 bytes. The one place a test writes under /tmp itself
/// (scripts/temporary-folder-lint.txt allows it here alone), always in a `Scratch.shortFolder` removed with its Scratch.
let shortScratchRoot: String = scratchRoot.path.utf8.count <= 32 ? scratchRoot.path : "/tmp"

extension Scratch {
    /// A new folder `shortScratchRoot/<prefix>-<8 hex>` for a socket, made now and removed with this, socket and all.
    func shortFolder(_ prefix: String) throws -> String {
        let folder = adopt(URL(fileURLWithPath: "\(shortScratchRoot)/\(prefix)-\(UUID().uuidString.prefix(8))"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path
    }
}

extension Scratch {
    /// A UserDefaults of a test's own, empty, kept in `defaults.plist` in a new folder `scratchRoot/<prefix>-<uuid>`
    /// that goes with this. Its suite is named by that path, not by a domain: cfprefsd writes a named suite
    /// (`UserDefaults(suiteName: "x.y")`) to the real ~/Library/Preferences whatever HOME and CFFIXED_USER_HOME say,
    /// and leaves the file there after `removePersistentDomain`, so 8,012 dev.vibeswitcher.tests.<UUID>.plist and
    /// 11,000 more piled up by 2026-10-24. scripts/test.sh fails a run that adds one again (`check_preferences`).
    func defaults(_ prefix: String) -> UserDefaults {
        UserDefaults(suiteName: url(prefix).appendingPathComponent("defaults").path)!
    }
}

extension Tag {
    /// A bench: judged by wall-clock time or memory, so whether it passes depends on how busy the Mac is. Runs only in
    /// `scripts/test.sh --perf` (`perfRun`), for a task about speed or memory and before an install; the default run,
    /// a merge's included, skips it.
    @Tag static var perf: Self
}

/// Whether this is `scripts/test.sh --perf` (VIBESWITCHER_PERF=1), the one run a bench (`Tag.perf`) runs in: each takes
/// `.tags(.perf), .enabled(if: perfRun, perfOnly)`.
let perfRun = ProcessInfo.processInfo.environment["VIBESWITCHER_PERF"] == "1"
let perfOnly: Comment = "a bench, judged by time or memory: scripts/test.sh --perf"
