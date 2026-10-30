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

/// Whether `condition` holds within `timeout` seconds (a hang guard), checked every 20 ms. Awaiting lets the main
/// thread run what's queued for it meanwhile. A cancelled test (past its time limit) waits no more: its sleep would
/// throw at once, and the loop spin until the deadline.
@MainActor
func until(timeout: TimeInterval = hangGuard, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline, !Task.isCancelled {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
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
