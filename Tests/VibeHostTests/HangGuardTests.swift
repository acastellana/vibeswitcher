import Foundation
import Testing

/// A test whose host stops answering meets one hang guard after another: each wait is bounded, the test isn't. On
/// 2026-10-28 a merge's full run hung 45 min (the gate's limit) on a scratch host. A test past its time limit
/// (`hostTestLimit`) is cancelled, and from then on its waits end at once.
struct HangGuardTests {
    /// A wait in a cancelled test ends at once rather than at its hang guard, and says the condition didn't hold.
    @Test func aWaitInACancelledTestEndsAtOnce() async {
        let waiting = Task.detached { () -> (held: Bool, took: TimeInterval) in
            let started = Date()
            let held = eventually { false }
            return (held, Date().timeIntervalSince(started))
        }
        waiting.cancel()
        let (held, took) = await waiting.value
        #expect(!held)
        #expect(took < hangGuard / 2, "the wait took \(Int(took)) s")
    }
}
