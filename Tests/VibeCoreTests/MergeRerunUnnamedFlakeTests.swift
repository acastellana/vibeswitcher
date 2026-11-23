import Testing
@testable import VibeCore

/// The flake list's top entry over 2026-11-15..19, "(the test command, naming no test)" ×8, came only beside a named
/// test's ordinary expectation failure. Each of those merges' first runs was a whole `bash scripts/test.sh` that ran to
/// its end; `finished` then counted the closing line's issues ("with 5 issues (including 4 known issues)") against the
/// ✘ issue lines alone, and the 4 tests of this repository that pass with known issues mark theirs ━: every failed
/// whole run read as stopped partway, so each recorded the unnamed flake and reran whole (the ledger's 8 reruns, all
/// `filtered: false`). Fixed in f2a39ad4 (2026-11-19 11:49), after the last of them.
struct MergeRerunUnnamedFlakeTests {
    static let failing = "endedRowsFoldAwayAndTheListSkipsThemWhileFolded()"

    /// scripts/test.sh's output, from the build's end on, as a run of
    /// `bash scripts/test.sh --filter 'Failing|noTestReadsTheMacsOwnFreeSpace|aToolThatGivesNoAnswerIsEnded|aFailingTestsHostIsEnded|aFailingSceneIsEnded'`
    /// printed it on 2026-11-23 (stdout and stderr in one pipe, as the merge reads them), its failing scratch test
    /// replaced by receipts-fable-5-2's merge failure of 2026-11-18 (its 4 issue lines, from the flake log).
    static let wholeRun = """
        [559/560] Linking VibeSwitcherPackageTests
        Build complete! (240.25s)
        warning: '--build-system native' has been deprecated and will be removed in a future release; please report an issue at https://github.com/swiftlang/swift-package-manager/issues if you are unable to adopt the default build system.
        ◇ Test run started.
        ↳ Testing Library Version: 2403
        ↳ Target Platform: arm64e-apple-macos14.0
        ◇ Suite DiskSpaceTests started.
        ◇ Suite EndedFoldTests started.
        ◇ Suite ParserCostTests started.
        ◇ Suite TestHostsTests started.
        ◇ Test endedRowsFoldAwayAndTheListSkipsThemWhileFolded() started.
        ◇ Test noTestReadsTheMacsOwnFreeSpace() started.
        ◇ Test aToolThatGivesNoAnswerIsEnded() started.
        ◇ Test aFailingTestsHostIsEnded() started.
        ✘ Test endedRowsFoldAwayAndTheListSkipsThemWhileFolded() recorded an issue at EndedFoldTests.swift:48:13: Expectation failed: model.rows.count == 2
        ↳ model.rows.count == 2 → false
        ↳   model.rows.count → 1
        ✘ Test endedRowsFoldAwayAndTheListSkipsThemWhileFolded() recorded an issue at EndedFoldTests.swift:50:13: Expectation failed: model.rows.count == 5
        ↳ model.rows.count == 5 → false
        ↳   model.rows.count → 4
        ━ Test noTestReadsTheMacsOwnFreeSpace() recorded a known issue at TestSupport.swift:34:21: Issue recorded
        ↳ A test read the Mac's own free disk space (the volume holding /), so its result hangs on how full the disk is: give it a reading where it's read (see DiskSpace.TestRun).
        ↳ the guard: a read of the volume itself is a failure
        ━ Test noTestReadsTheMacsOwnFreeSpace() passed after 0.191 seconds with 1 known issue.
        ━ Suite DiskSpaceTests passed after 0.192 seconds with 1 known issue.
        ━ Test aToolThatGivesNoAnswerIsEnded() recorded a known issue at ParserCostTests.swift:52:36: Issue recorded
        ↳ /bin/sleep (pid 88399) gave no answer in 1 s and was ended. Is a Developer Tools Access password dialog waiting on the screen? An attach (lldb, sample) puts one up and it waits behind it.
        ━ Test aToolThatGivesNoAnswerIsEnded() passed after 1.004 seconds with 1 known issue.
        ━ Suite ParserCostTests passed after 1.004 seconds with 1 known issue.
        ━ Test aFailingTestsHostIsEnded() recorded a known issue at TestHostsTests.swift:39:29: Caught error: Failure()
        ↳ the body fails on purpose, its host still running
        ━ Test aFailingTestsHostIsEnded() passed after 1.123 seconds with 1 known issue.
        ◇ Test aFailingSceneIsEnded() started.
        ━ Test aFailingSceneIsEnded() recorded a known issue at TestHostsTests.swift:80:29: Caught error: Failure()
        ↳ the body fails on purpose
        ━ Test aFailingSceneIsEnded() passed after 1.813 seconds with 1 known issue.
        ━ Suite TestHostsTests passed after 2.936 seconds with 2 known issues.
        ✘ Test endedRowsFoldAwayAndTheListSkipsThemWhileFolded() recorded an issue at EndedFoldTests.swift:48:13: Expectation failed: model.rows.count == 2
        ↳ model.rows.count == 2 → false
        ↳   model.rows.count → 1
        ✘ Test endedRowsFoldAwayAndTheListSkipsThemWhileFolded() recorded an issue at EndedFoldTests.swift:50:13: Expectation failed: model.rows.count == 5
        ↳ model.rows.count == 5 → false
        ↳   model.rows.count → 4
        ✘ Test endedRowsFoldAwayAndTheListSkipsThemWhileFolded() failed after 137.651 seconds with 4 issues.
        ✘ Suite EndedFoldTests failed after 137.652 seconds with 4 issues.
        ✘ Test run with 6 tests in 4 suites failed after 137.653 seconds with 8 issues (including 4 known issues).
        Note: Some test targets reported failures:
          - VibeSwitcherPackageTests (Swift Testing)
        phone-briefing: ok
        phone-recovery: all checks passed
        web tests: 7 of 7 passed
        PASS: unknown processes cannot spawn, discover, read, attach, type, resize or shut down the scratch host.
        PASS: app and all three helpers reject DYLD injection with valid hardened signatures.
        web tests: 2 of 2 passed
        """

    /// A run before it in the same output that ran to its end: several swift test runs in one output.
    static let earlierRun = """
        ◇ Test run started.
        ◇ Test steady() started.
        ✔ Test steady() passed after 0.001 seconds.
        ✔ Test run with 1 test in 1 suite passed after 0.002 seconds.
        """

    @Test func aWholeRunThatFailedOnANamedTestRecordsOnlyThatTest() {
        #expect(MergeRerun.finished(Self.wholeRun))
        #expect(MergeRerun.flakes(in: Self.wholeRun) == [Self.failing])
        let several = Self.earlierRun + "\n" + Self.wholeRun
        #expect(MergeRerun.finished(several))
        #expect(MergeRerun.flakes(in: several) == [Self.failing])
    }

    /// Still unnamed beside it: a crash, a stop, and a failure naming no test.
    @Test func aCrashAStopOrAFailureNamingNoTestStillRecordsTheUnnamedFlake() {
        let lines = Self.wholeRun.components(separatedBy: "\n")
        let closing = lines.firstIndex { $0.hasPrefix("✘ Test run with ") }!
        // Crashed after its last test started: no closing line, a fatal error.
        let crashed = (lines[..<closing] + ["◇ Test late() started.", "Fatal error: boom", "error: Exited with unexpected signal code 5"]).joined(separator: "\n")
        #expect(MergeRerun.flakes(in: crashed) == [Self.failing, MergeRerun.unnamed])
        // Stopped partway: tests started, none ended, no closing line.
        let stopped = (lines[..<closing] + ["◇ Test late() started."]).joined(separator: "\n")
        #expect(MergeRerun.flakes(in: stopped) == [Self.failing, MergeRerun.unnamed])
        // A failure naming no test: the build failed.
        let unnamed = "Sources/VibeCore/A.swift:3:5: error: cannot find 'x' in scope\nerror: fatalError"
        #expect(MergeRerun.flakes(in: unnamed) == [MergeRerun.unnamed])
    }
}
