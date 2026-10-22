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

/// The tail of a scratch program that must still be running while the test looks at it: longer than any test
/// waits, and ended by the test (or its host) when it's done.
let keepRunning = "sleep 3600"

/// Polls `condition` until it holds, or until `timeout` (a hang guard) passes. Host tests talk to real processes
/// and sockets.
func eventually(timeout: TimeInterval = hangGuard, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

/// A short, unique socket path (Unix socket paths are limited to 104 bytes).
func scratchSocketPath() -> String { "\(shortScratchRoot)/vsh-\(UUID().uuidString.prefix(8)).sock" }

/// The built `vibeswitcher-host`, which starts each session's program (`--pty-exec`).
let hostLauncher: String = {
    // The test bundle sits in the build folder, next to the executables it depends on.
    Bundle(for: TestBundleAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
}()

private final class TestBundleAnchor {}

/// Where tests put their scratch files: `$TMPDIR` when it's set, else the user's temporary folder (Foundation's
/// `temporaryDirectory` ignores `$TMPDIR` on macOS). scripts/test-under-load.sh points it at a private folder per run
/// and fails when a run leaves anything there, so every scratch file a test makes goes here and is removed by it.
let scratchRoot: URL = {
    guard let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty else { return FileManager.default.temporaryDirectory }
    return URL(fileURLWithPath: tmp, isDirectory: true)
}()

/// Where scratch sockets and the folders holding them go: `scratchRoot` when its path is short (the private folder
/// scripts/test-under-load.sh sets is), else /tmp, since a Unix socket's path is limited to 104 bytes.
let shortScratchRoot: String = scratchRoot.path.utf8.count <= 32 ? scratchRoot.path : "/tmp"

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

/// The numbers of the requests in `requests` (numbered from 2, after a hello) that the host answers: all but input
/// sent without asking for a reply, and enrolling the app's key (it says nothing either way).
func repliedTo(_ requests: [HostRequest]) -> [Int] {
    requests.enumerated().compactMap { index, request in
        switch request {
        case .input(_, _, false), .enrollApp: return nil
        default: return index + 2
        }
    }
}
