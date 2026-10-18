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
