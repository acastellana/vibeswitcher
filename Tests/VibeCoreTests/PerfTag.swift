import Foundation
import Testing

extension Tag {
    /// A bench: judged by wall-clock time or memory, so whether it passes depends on how busy the Mac is. Runs only in
    /// `scripts/test.sh --perf` (`perfRun`); the default run, a merge's included, skips it. The same tag as
    /// VibeSwitcherTests' (Tests/VibeSwitcherTests/TestSupport.swift), for this module's benches.
    @Tag static var perf: Self
}

/// Whether this is `scripts/test.sh --perf` (VIBESWITCHER_PERF=1), the one run a bench (`Tag.perf`) runs in.
let perfRun = ProcessInfo.processInfo.environment["VIBESWITCHER_PERF"] == "1"
let perfOnly: Comment = "a bench, judged by time or memory: scripts/test.sh --perf"
