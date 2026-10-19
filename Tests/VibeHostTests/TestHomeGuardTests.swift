import Testing
import VibeCore

/// This target's load-time guard ran, and let the run go on: its root isn't the account's own ~/.vibeswitcher (see
/// `refuseTheAccountRoot` in TestSupport.swift, and VibeCoreTests' `HomeIsolationTests`).
struct TestHomeGuardTests {
    @Test func theGuardRanAndTheRootIsntTheAccountsOwn() {
        #expect(homeGuardRan)
        #expect(!VibePaths.isAccountRoot(VibePaths.root, accountHome: VibePaths.accountHome))
    }
}
