import Foundation

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
func scratchSocketPath() -> String { "/tmp/vsh-\(UUID().uuidString.prefix(8)).sock" }

/// The built `vibeswitcher-host`, which starts each session's program (`--pty-exec`).
let hostLauncher: String = {
    // The test bundle sits in the build folder, next to the executables it depends on.
    Bundle(for: TestBundleAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-host").path
}()

private final class TestBundleAnchor {}
