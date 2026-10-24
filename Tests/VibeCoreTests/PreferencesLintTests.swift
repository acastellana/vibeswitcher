import Foundation
import Testing

/// No test makes a defaults suite cfprefsd keeps in the real ~/Library/Preferences. A suite named by a domain
/// (`UserDefaults(suiteName: "x.y")`) is written there whatever HOME and CFFIXED_USER_HOME say, and
/// `removePersistentDomain` leaves its file: by 2026-10-24 that folder held 8,012 dev.vibeswitcher.tests.<UUID>.plist
/// and 11,000 more from tests. scripts/test.sh fails a run that adds files under the names tests used
/// (`check_preferences`); this catches a suite under any name, before it runs.
struct PreferencesLintTests {
    /// A suite is made in one place, `Scratch.defaults`, which names it by a path under scratchRoot.
    @Test func onlyScratchMakesADefaultsSuite() {
        #expect(KeychainLintTests.files(in: "Tests", matching: #"UserDefaults\(suiteName:|CFPreferences\w*\("#)
            == ["Tests/VibeCoreTests/TestSupport.swift", "Tests/VibeSwitcherTests/TestSupport.swift"])
    }
}
