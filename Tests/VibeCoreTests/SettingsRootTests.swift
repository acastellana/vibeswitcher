import Foundation
import Testing
@testable import VibeCore
@testable import VibePlatform

/// The settings file's folder (VibePlatform's `Platform.settingsRoot`, which Linux's settings store asks) is the core's
/// (`VibePaths.root`): the platform is below the core, so it says the rule again, and this holds the two the same. The
/// environments are given, never this process's own: tests run in parallel, and every other test's `VibePaths.root`
/// would move with a change to it, perhaps out of the scratch home.
struct SettingsRootTests {
    static let environments: [[String: String]] = [
        ["VIBESWITCHER_HOME": "/scratch/own", "CFFIXED_USER_HOME": "/scratch/fixed", "HOME": "/scratch/home"],
        ["VIBESWITCHER_HOME": "/scratch/own/"],
        ["CFFIXED_USER_HOME": "/scratch/fixed", "HOME": "/scratch/home"],
        ["HOME": "/scratch/home"],
        // A variable that isn't an absolute path doesn't count: the next one does, or the fallback.
        ["VIBESWITCHER_HOME": "relative", "CFFIXED_USER_HOME": "/scratch/fixed", "HOME": "/scratch/home"],
        ["CFFIXED_USER_HOME": "", "HOME": "~/home"],
        [:],
    ]

    @Test(arguments: environments)
    func thePlatformsRootIsTheCoresRoot(_ environment: [String: String]) {
        let core = VibePaths.root(environment: environment, fallbackHome: "/scratch/fallback")
        let platform = Platform.settingsRoot(variable: { environment[$0] }, fallbackHome: "/scratch/fallback")
        #expect(platform == core, "\(environment)")
        #expect(platform.path == core.path, "\(environment)")
    }
}
