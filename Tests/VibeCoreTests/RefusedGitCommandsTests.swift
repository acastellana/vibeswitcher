import Foundation
import Testing
@testable import VibeCore

/// A refused git command behind a harmless global option (`git -P push` matches no `Bash(git push:*)`), and git's
/// own settings through its environment (`GIT_DIR=x git status` reaches no option the hook reads): the role's
/// `PreToolUse` hook refuses both, in every permission mode.
struct RefusedGitCommandsTests {
    let temp = Scratch()

    /// The reported symptoms, as the contract quotes them.
    @Test func theWorkersGuardRefusesPushBehindAGlobalOptionAndGitDirInTheEnvironment() throws {
        let worker = try RefusedGitSpellingsTests.Guard(.worker, temp: temp)
        #expect(try worker.refuses("git -P push origin main"))
        #expect(try worker.refuses("GIT_DIR=/x git status"))
    }
}
