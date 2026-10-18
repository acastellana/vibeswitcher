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
}
