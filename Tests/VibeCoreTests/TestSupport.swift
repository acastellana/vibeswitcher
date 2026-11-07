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

// Swift Testing runs each test as a task on Swift's cooperative pool, one thread a core. A test that blocks its thread
// (a semaphore, a group, a sleep, a process's exit, a build) holds one of those few threads for as long as it waits,
// and a dozen such tests hold them all: every other test, async ones included, and any task the code under test
// starts, waits behind them. On 2026-11-05 a full run at load 119 sat near 0 % CPU for 5 minutes that way, until the
// hang guards expired, and 8 tests in other suites failed. So a test's waits are awaited (`eventually`, `pause`), and
// a blocking call that can take long goes through `offPool`.

/// Polls `condition` every 20 ms until it holds, or until `timeout` (a hang guard) passes; at once when the test is
/// cancelled (past its time limit). Awaited, so the test gives back its pool thread between looks (see `offPool`);
/// `condition` runs on the caller's actor, as the caller's own code would.
func eventually(timeout: TimeInterval = hangGuard, isolation: isolated (any Actor)? = #isolation,
                _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline, !Task.isCancelled {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

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

/// `eventually` for a condition that itself awaits (a request and its reply, each look a round trip).
func eventuallyAsync(timeout: TimeInterval = hangGuard, isolation: isolated (any Actor)? = #isolation,
                     _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline, !Task.isCancelled {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
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
