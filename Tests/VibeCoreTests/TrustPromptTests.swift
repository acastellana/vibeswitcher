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

}

struct TrustCursorTests {
    @Test func enterOnlyWhenTheCursorIsOnYes() {
        #expect(TrustPrompt.cursorOnYes(" ❯ No, exit\n   Yes, I trust this folder") == false)
        #expect(TrustPrompt.cursorOnYes("   No, exit\n ❯ Yes, I trust this folder") == true)
        #expect(TrustPrompt.cursorOnYes("nothing here") == false)
    }

    @Test func answeringWaitsForTheCursorBeforeEnter() {
        var screens = ["/tmp/x\n ❯ No, exit\n   Yes, I trust this folder",      // asked
                       "/tmp/x\n ❯ No, exit\n   Yes, I trust this folder",      // the first down was lost
                       "/tmp/x\n   No, exit\n ❯ Yes, I trust this folder"]      // second down took
        var sent: [[UInt8]] = []
        // No settling time: an unchanged screen means the key was lost. It ends on the screens; the timeout is a hang guard.
        let answered = TrustPrompt.answer(folder: "/tmp/x", timeout: hangGuard, pause: 0, settle: 0,
                                          readScreen: { screens.count > 1 ? screens.removeFirst() : screens.first },
                                          send: { sent += $0.map(\.bytes) })
        #expect(answered)
        #expect(sent == [[27, 91, 66], [27, 91, 66], [13]])
    }

    @Test func neverEnterOnNo() {
        let stuck = "/tmp/x\n ❯ No, exit\n   Yes, I trust this folder"
        // How long it keeps trying is the case: a busy Mac only gives it fewer tries, never an Enter.
        var sent: [[UInt8]] = []
        let answered = TrustPrompt.answer(folder: "/tmp/x", timeout: 1, pause: 0, readScreen: { stuck }, send: { sent += $0.map(\.bytes) })
        #expect(!answered)
        #expect(!sent.contains([13]))
    }

    @Test func noSecondKeyBeforeTheFirstShows() {
        // The screen lags: three reads still show the old cursor after the down was sent. However long those reads
        // take (settle, and the timeout, are hang guards), it must not press again.
        let no = "/tmp/x\n ❯ No, exit\n   Yes, I trust this folder"
        var screens = [no, no, no, no, "/tmp/x\n   No, exit\n ❯ Yes, I trust this folder"]
        var sent: [[UInt8]] = []
        let answered = TrustPrompt.answer(folder: "/tmp/x", timeout: hangGuard, pause: 0, settle: hangGuard,
                                          readScreen: { screens.count > 1 ? screens.removeFirst() : screens[0] },
                                          send: { sent += $0.map(\.bytes) })
        #expect(answered)
        #expect(sent == [[27, 91, 66], [13]])
    }
}

