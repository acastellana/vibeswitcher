import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// F-P1: replies to window sessions ask `PhoneAccess.screenLocked` before every write. Built with Phone Access
/// off and never started: nothing is served, paired or written.
@MainActor
struct PhoneAccessLockTests {
    @Test func aLockedMacRefusesAWindowReplyThroughTheRealCheck() {
        let access = PhoneAccess(store: SessionStore())
        var asked = 0
        access.screenLocked = { asked += 1; return true }
        let verdict = access.windowInputVerdict(device: "phone", tty: "ttys999", sid: "s",
                                                agent: (pid: 1, startedAt: .distantPast))
        #expect(verdict == .locked)
        #expect(asked == 1)
        // Asked again each time (each write), and its answer decides: unlocked, the other rules speak (off here).
        access.screenLocked = { asked += 1; return false }
        #expect(access.windowInputVerdict(device: "phone", tty: "ttys999", sid: "s",
                                          agent: (pid: 1, startedAt: .distantPast)) == .notAllowed)
        #expect(asked == 2)
    }

    @Test func theDefaultCheckIsTheMacsOwnLock() {
        // Not replaced, it reads the session's real lock state (unlocked while tests run at the Mac or over SSH).
        let access = PhoneAccess(store: SessionStore())
        #expect(access.screenLocked() == RemoteInput.isScreenLocked)
    }
}
