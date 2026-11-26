import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The host's `--lock` is opened with no link followed (the re-check's note 5): a lock that is a symbolic link, dangling
/// or not, refuses the host's start, and nothing is made where it points.
struct HostLockLinkTests {
    let scratch = Scratch()

    /// A dangling link at the lock's path: the start refuses (ELOOP), and the file it names isn't made. Red before:
    /// `open(O_CREAT)` followed the link and made, then held, the file it named.
    @Test func aLockThatIsALinkRefusesTheStart() throws {
        let dir = scratch.url("vshl").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let target = dir + "/elsewhere.lock", lock = dir + "/h.lock"
        #expect(symlink(target, lock) == 0)
        let config = HostServer.Config(socketPath: scratchSocketPath(), lockPath: lock, shell: "/bin/sh",
                                       launcher: hostLauncher, baseEnvironment: [:], hostBuild: 1)
        defer { unlink(config.socketPath) }
        let server = HostServer(config: config)
        #expect(throws: (any Error).self) { try server.start() }
        #expect(!FileManager.default.fileExists(atPath: target), "the lock's link was followed and its target made")
    }
}
