import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// What the app does with the host that welcomed it.
struct HostClientPlanTests {
    let current = HostProtocol.version

    @Test func theBundledBuildIsUsed() {
        #expect(HostClient.plan(version: current, build: 9, bundled: 9, sessions: 3, canHandOver: true, handedOverTo: nil) == .use)
        // No bundled host to compare with (a build folder): whatever runs.
        #expect(HostClient.plan(version: current, build: 9, bundled: 0, sessions: 3, canHandOver: false, handedOverTo: nil) == .use)
    }

    @Test func anEmptyOutdatedHostIsReplaced() {
        #expect(HostClient.plan(version: current, build: 8, bundled: 9, sessions: 0, canHandOver: true, handedOverTo: nil) == .replace)
        #expect(HostClient.plan(version: current, build: 8, bundled: 9, sessions: 0, canHandOver: false, handedOverTo: nil) == .replace)
    }

    @Test func anOutdatedHostWithSessionsHandsOverWhenItCan() {
        #expect(HostClient.plan(version: current, build: 8, bundled: 9, sessions: 2, canHandOver: true, handedOverTo: nil) == .handOver)
        // Across a protocol change too: the request is the same in every host that lists the capability.
        #expect(HostClient.plan(version: current + 1, build: 8, bundled: 9, sessions: 2, canHandOver: true, handedOverTo: nil) == .handOver)
        // Asked for this build already (it failed): not again by itself; the window's restart asks once more.
        #expect(HostClient.plan(version: current, build: 8, bundled: 9, sessions: 2, canHandOver: true, handedOverTo: 9) == .keepOutdated)
        // A newer bundled build is asked for once more.
        #expect(HostClient.plan(version: current, build: 8, bundled: 10, sessions: 2, canHandOver: true, handedOverTo: 9) == .handOver)
    }

    /// A host older than the handover keeps today's behaviour: it serves its sessions until they're gone.
    @Test func anOlderHostKeepsItsSessionsUntilTheyEnd() {
        #expect(HostClient.plan(version: current, build: 8, bundled: 9, sessions: 2, canHandOver: false, handedOverTo: nil) == .keepOutdated)
        #expect(HostClient.plan(version: current + 1, build: 8, bundled: 9, sessions: 2, canHandOver: false, handedOverTo: nil) == .keepOutdated)
    }

    /// The window's restart, asked for: the handover when the host has it; else, even when it speaks our protocol and
    /// has live sessions (which the welcome's plan keeps), the replace, ending them.
    @Test func aRestartOfACompatibleHostWithSessionsReplacesItUnlessItCanHandOver() {
        #expect(HostClient.plan(version: current, build: 8, bundled: 9, sessions: 2, canHandOver: false, handedOverTo: nil) == .keepOutdated)
        #expect(HostClient.restartPlan(canHandOver: false, live: 2) == .endAndReplace(live: 2))
        #expect(HostClient.restartPlan(canHandOver: true, live: 2) == .handOver)
        // Its sessions all ended: nothing to end, it's replaced at once.
        #expect(HostClient.restartPlan(canHandOver: false, live: 0) == .endAndReplace(live: 0))
    }

    /// Nothing to restart unless the host is outdated.
    @Test func noRestartIsOfferedWithoutAnOutdatedHost() {
        #expect(HostClient().restartOffer == nil)
    }
}
