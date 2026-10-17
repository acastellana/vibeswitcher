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

    @Test func aSuggestionInTheBoxIsNotADraft() {
        // Claude's dim suggestion fills an empty box; the cursor sits before it. Typed text puts the cursor after.
        let screen = """
        ✻ Sautéed for 33s · done 10:34 AM
        ────────────────────────────────────────────
        ❯ pushed, check the deploy
        ────────────────────────────────────────────
        """
        #expect(TerminalInput.isEmpty(screen) == false)
        #expect(TerminalInput.isEmpty(screen, cursor: (row: 2, column: 2)) == true)
        #expect(TerminalInput.isEmpty(screen, cursor: (row: 2, column: 26)) == false)
        // A cursor somewhere else (a menu): only the text decides.
        #expect(TerminalInput.isEmpty(screen, cursor: (row: 0, column: 0)) == false)
    }

    @Test func theInputBoxIsReadFromTheBottom() {
        #expect(TerminalInput.isEmpty(empty) == true)
        #expect(TerminalInput.isEmpty(busy) == false)
        // A ❯ in the conversation above doesn't count; only the box between the last two rules.
        #expect(TerminalInput.isEmpty("❯ old prompt\n" + empty) == true)
        // No box on screen (a menu, a dialog): unknown, so not empty.
        #expect(TerminalInput.isEmpty("Enter to select · Esc to cancel") == false)
    }
}

struct PaletteDecodingTests {
    @Test func aShortPaletteIsFilledToSixteenColors() throws {
        let json = "{\"foreground\":\"#FFFFFF\",\"background\":\"#000000\",\"cursor\":\"#FFFFFF\",\"selection\":\"#333333\",\"ansi\":[\"#111111\",\"#222222\"]}"
        let palette = try JSONDecoder().decode(Palette.self, from: Data(json.utf8))
        #expect(palette.ansi.count == 16)
        #expect(Array(palette.ansi.prefix(2)) == ["#111111", "#222222"])
        let many = Array(repeating: "\"#010101\"", count: 20).joined(separator: ",")
        let long = "{\"foreground\":\"#FFFFFF\",\"background\":\"#000000\",\"cursor\":\"#FFFFFF\",\"selection\":\"#333333\",\"ansi\":[" + many + "]}"
        #expect(try JSONDecoder().decode(Palette.self, from: Data(long.utf8)).ansi.count == 16)
    }
}
