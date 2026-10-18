import Foundation

/// How long a wait may go on before the test calls it hung. Every wait ends as soon as what it waits for happens;
/// this is only a guard, sized for a Mac running several suites at once (load 100+), never a measure of speed.
let hangGuard: TimeInterval = 300

/// Whether `condition` holds within `timeout` seconds (a hang guard), checked every 20 ms. Awaiting lets the main
/// thread run what's queued for it meanwhile.
@MainActor
func until(timeout: TimeInterval = hangGuard, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
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
