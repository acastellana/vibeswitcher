import Foundation
import Testing
import VibeCore

/// This target's load-time guard ran, and let the run go on: its root isn't the account's own ~/.vibeswitcher (see
/// `refuseTheAccountRoot` in TestSupport.swift, and VibeCoreTests' `HomeIsolationTests`).
struct TestHomeGuardTests {
    @Test func theGuardRanAndTheRootIsntTheAccountsOwn() {
        #expect(homeGuardRan)
        #expect(!VibePaths.isAccountRoot(VibePaths.root, accountHome: VibePaths.accountHome))
    }

    /// This target's run reads a roomy disk, never the Mac's own (see `fakeTheDisk` in TestSupport.swift, and
    /// VibeCoreTests' `DiskSpaceTests.noTestReadsTheMacsOwnFreeSpace`).
    @Test func theRunReadsARoomyDiskNotTheMacs() {
        #expect(DiskSpace.testRun.map { $0.free >= 100 * DiskSpace.gigabyte } == true)
        #expect(DiskSpace.free(at: "/") == DiskSpace.testRun?.free)
    }

    /// This target's load-time handler for SIGPIPE ran (see `catchBrokenPipes` in TestSupport.swift, and VibeCoreTests'
    /// `BrokenPipeTests`): a write to a pipe whose reader has gone fails in its test, and doesn't end the run.
    @Test func theRunCatchesSIGPIPE() {
        var current = sigaction()
        sigaction(SIGPIPE, nil, &current)
        // Neither its default (0), which ends the run, nor a moment's ignoring by a test (HostedSessionTests) matters here.
        // On Linux the run ignores it (TestSupport.swift's `refuseTheAccountRootOnLinux`): SIG_IGN, not the default.
        #if canImport(Darwin)
        let handler = current.__sigaction_u.__sa_handler
        #else
        let handler = current.__sigaction_handler.sa_handler
        #endif
        #expect((handler.map { unsafeBitCast($0, to: Int.self) } ?? 0) != 0)
    }
}
