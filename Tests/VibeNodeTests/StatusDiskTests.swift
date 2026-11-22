import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// `status` reads no disk on the engine's queue (the architecture review's row 19): its `builds` (the install root's
/// folders and its `installs` file) are read on a queue of their own at each notes refresh, and `statusValue`, which
/// every change of the node's stream calls, gives them as last read.
struct StatusDiskTests {
    private let scratch = Scratch()

    private struct NoHost: HostDialer {
        func connect(queue: DispatchQueue, patience: TimeInterval) throws -> HostConnection { throw HostLink.Failure("no host in this test") }
    }

    @Test func theBuildsAreReadOffTheQueueAndGivenAsLastRead() async throws {
        let queue = DispatchQueue(label: "status-disk")
        let root = scratch.url("root")
        let installRoot = scratch.url("builds")
        let first = String(repeating: "a", count: 40), second = String(repeating: "b", count: 40)
        try FileManager.default.createDirectory(at: installRoot.appendingPathComponent(first), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let requests = Requests(link: HostLink(dialer: NoHost(), root: root, queue: queue), sessions: nil,
                                rule: VoiceRule(mode: .weaker, scopes: [], uid: getuid(), says: "a test's"),
                                root: root, hostSocket: scratch.url("h.sock").path, commit: "test", hostPID: 1)
        requests.installRoot = installRoot.path
        let installed = { queue.sync { requests.statusValue()["builds"]?["installed"]?.array?.compactMap(\.string) } }
        #expect(installed() == nil, "nothing read yet: statusValue reads no folder itself")

        let read = Locked(false)
        queue.async { requests.refreshBuilds { read.value = true } }
        #expect(await eventually(timeout: 30) { read.value })
        #expect(installed() == [first])

        // A build installed since: given at the next read, not before.
        try FileManager.default.createDirectory(at: installRoot.appendingPathComponent(second), withIntermediateDirectories: true)
        #expect(installed() == [first])
        read.value = false
        queue.async { requests.refreshBuilds { read.value = true } }
        #expect(await eventually(timeout: 30) { read.value })
        #expect(installed() == [first, second])
    }
}
