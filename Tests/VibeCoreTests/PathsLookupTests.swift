import Foundation
import Testing
@testable import VibeCore

/// `VibePaths.root` and `.home` read only the variables they need (each is asked at every hook state, inbox and
/// transcript path): the same answer as from the whole environment, here and as the environment changes.
struct PathsLookupTests {
    static func fromTheEnvironment() -> (root: URL, home: String) {
        let environment = ProcessInfo.processInfo.environment
        return (VibePaths.root(environment: environment, fallbackHome: NSHomeDirectory()),
                VibePaths.home(environment: environment, fallbackHome: NSHomeDirectory()))
    }

    @Test func theSameAsFromTheWholeEnvironment() {
        let expected = Self.fromTheEnvironment()
        #expect(VibePaths.root == expected.root)
        #expect(VibePaths.home == expected.home)
    }
}
