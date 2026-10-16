import Foundation
import Testing
@testable import VibeCore

struct TerminalInputTests {
    let busy = """
    ✻ Cogitated for 10s · done 1:17 AM
    ──────────────────────────────────────────── lead-lead-demo ─
    ❯ merge add.sh once the audit passes and post the update
    ────────────────────────────────────────────────────────────
      [Fable 5.1] ███░░░░░░░ 30% | lead-demo git:(main)
    ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent
    """

    let empty = """
    ✻ Cogitated for 10s · done 1:17 AM
    ──────────────────────────────────────────── lead-lead-demo ─
    ❯ 
    ────────────────────────────────────────────────────────────
      [Fable 5.1] ███░░░░░░░ 30% | lead-demo git:(main)
    """

    @Test func theInputBoxIsReadFromTheBottom() {
        #expect(TerminalInput.isEmpty(empty) == true)
        #expect(TerminalInput.isEmpty(busy) == false)
        // A ❯ in the conversation above doesn't count; only the box between the last two rules.
        #expect(TerminalInput.isEmpty("❯ old prompt\n" + empty) == true)
        // No box on screen (a menu, a dialog): unknown, so not empty.
        #expect(TerminalInput.isEmpty("Enter to select · Esc to cancel") == false)
    }
}
