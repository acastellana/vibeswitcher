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
