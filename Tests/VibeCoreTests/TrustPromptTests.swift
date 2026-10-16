import Foundation
import Testing
@testable import VibeCore

struct TrustPromptTests {
    let screen = """
    Accessing workspace:

    /private/tmp/vs-scratch/lead-demo/.vibeswitcher/worktrees/add-greet

    Quick safety check: Is this a project you created or one you trust?

     ❯ No, exit
       Yes, I trust this folder

    Enter to confirm · Esc to cancel
    """

    @Test func recognizesTheQuestionForThatFolderOnly() {
        #expect(TrustPrompt.isAsking(screen, about: "/tmp/vs-scratch/lead-demo/.vibeswitcher/worktrees/add-greet"))
        #expect(TrustPrompt.isAsking(screen, about: "/private/tmp/vs-scratch/lead-demo/.vibeswitcher/worktrees/add-greet"))
        #expect(!TrustPrompt.isAsking(screen, about: "/tmp/elsewhere"))
        #expect(!TrustPrompt.isAsking("Welcome to Claude Code", about: "/tmp/vs-scratch/lead-demo"))
    }

    @Test func answersYes() {
        #expect(TrustPrompt.yesKeys.map(\.bytes) == [[27, 91, 66], [13]])
    }
}
