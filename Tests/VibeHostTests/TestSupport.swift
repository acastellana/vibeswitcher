import Foundation

/// Polls `condition` until it holds or `timeout` passes. Host tests talk to real processes and sockets.
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
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
