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
}
