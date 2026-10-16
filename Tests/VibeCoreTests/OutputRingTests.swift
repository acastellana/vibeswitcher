import Foundation
import Testing
@testable import VibeCore

struct OutputRingTests {
    func data(_ s: String) -> Data { Data(s.utf8) }

    @Test func replaysEverythingWhileNothingWasDropped() {
        var ring = OutputRing(capacity: 1024)
        ring.append(data("hello "))
        ring.append(data("world"))
        #expect(ring.replay() == data("hello world"))
        #expect(ring.totalWritten == 11)
    }

    @Test func replayStartsAtTheLatestClearScreen() {
        var ring = OutputRing(capacity: 1024)
        ring.append(data("old stuff\u{1b}[2Jfirst screen"))
        ring.append(data("\u{1b}[?1049hsecond screen"))
        #expect(ring.replay() == data("\u{1b}[?1049hsecond screen"))
    }

    @Test func aResetSplitAcrossAppendsIsFound() {
        var ring = OutputRing(capacity: 1024)
        ring.append(data("before\u{1b}[?10"))
        ring.append(data("49hafter"))
        #expect(ring.replay() == data("\u{1b}[?1049hafter"))
    }

    @Test func terminalResetCounts() {
        var ring = OutputRing(capacity: 1024)
        ring.append(data("junk\u{1b}cclean"))
        #expect(ring.replay() == data("\u{1b}cclean"))
    }

    @Test func afterDroppingOldOutputReplayStartsAtALineStart() {
        var ring = OutputRing(capacity: 16)
        ring.append(data("aaaaaaaaaaaa\nbbbbbbbbbb\ncc"))   // 26 bytes > 16 + 4: trims to the last 16
        // Kept: "aa\nbbbbbbbbbb\ncc"; replay skips the partial first line.
        #expect(ring.replay() == data("bbbbbbbbbb\ncc"))
    }

    @Test func resetsInDroppedOutputAreForgotten() {
        var ring = OutputRing(capacity: 16)
        ring.append(data("\u{1b}[2Jxxxxxxxxxxxxxxxxxxxxxxxxx\nyy"))
        #expect(!ring.replay().starts(with: data("\u{1b}[2J")))
        #expect(ring.replay() == data("yy"))
    }

    @Test func aResetMatchedInsideTheTailIsNotCountedTwice() {
        var ring = OutputRing(capacity: 1024)
        ring.append(data("x\u{1b}c"))
        ring.append(data("y"))
        ring.append(data("z"))
        #expect(ring.replay() == data("\u{1b}cyz"))
    }
}
