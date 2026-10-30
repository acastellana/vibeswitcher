import Foundation
import Testing
@testable import VibeHost

/// Whether a session's program asked for focus events (DECSET 1004), read off its output: only then may it be told
/// its terminal has focus (`CSI I`), which any other program takes as Esc and typed text.
struct FocusEventsTests {
    func read(_ chunks: [String], from start: FocusEvents = FocusEvents()) -> FocusEvents {
        var focus = start
        for chunk in chunks { focus.feed(Array(chunk.utf8)) }
        return focus
    }

    @Test func setAndResetAreReadAmongOtherModesAndOutput() {
        #expect(!read([]).on)
        #expect(read(["\u{1b}[?1004h"]).on)
        #expect(!read(["\u{1b}[?1004h", "drawn \u{1b}[1mtext\u{1b}[0m", "\u{1b}[?1004l"]).on)
        // Several modes in one sequence, as Claude Code sets them.
        #expect(read(["\u{1b}[?2004;1004h"]).on)
        #expect(read(["\u{1b}[?1004;2004h"]).on)
        // Other modes, and a number that only contains 1004, aren't it.
        #expect(!read(["\u{1b}[?2004h\u{1b}[?10040h\u{1b}[?11004h"]).on)
        // Not private: ANSI mode 1004 isn't it.
        #expect(!read(["\u{1b}[1004h"]).on)
    }

    @Test func aSequenceSplitAcrossReadsIsStillRead() {
        #expect(read(["\u{1b}", "[?10", "04", "h"]).on)
        #expect(!read(["\u{1b}[?1004h", "\u{1b}[?100", "4l"]).on)
    }

    @Test func aFullResetTurnsThemOffAndAQueryChangesNothing() {
        #expect(!read(["\u{1b}[?1004h", "\u{1b}c"]).on)
        // A mode query (DECRQM) answers whether it's on; it doesn't set it.
        #expect(!read(["\u{1b}[?1004$p"]).on)
        #expect(read(["\u{1b}[?1004h", "\u{1b}[?1004$p"]).on)
        // An Esc mid-sequence starts a new one.
        #expect(read(["\u{1b}[?20\u{1b}[?1004h"]).on)
    }
}
