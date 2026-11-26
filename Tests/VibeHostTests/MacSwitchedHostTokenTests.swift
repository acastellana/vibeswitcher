import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// What the Mac's agent knows a host by (`MacAgent.see`, the node on the Mac's design, "The LaunchAgent"): a new
/// connection's audit token at the host's socket, run by Security's dynamic check against the record's hosts. After an
/// in-place switch the socket is the one the old image listened on, carried across the exec; this is whether a token
/// taken on a connection made after the switch still names a process whose code Security reads, and which: the new
/// image's (the measurement the design asked for before `status` and `stop` rely on it for a switched node).
@Suite(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's switch through a keeper: code identity"))
struct MacSwitchedHostTokenTests {
    @Test func aNewConnectionsTokenAfterASwitchRunsTheNewImage() async throws {
        let keeper = MacKeeperHandoverTests()
        let scene = try await keeper.scene { ["--handover-test-keeper", NodePins.hex($0.new)] }
        defer { scene.host.stop() }
        let old = try #require(Platform.CodeIdentity.cdhash(atPath: scene.host.oldBinary))
        func token() throws -> Platform.PeerToken {
            let fd = try UnixSocket.connect(path: scene.host.socket)
            defer { Sys.close(fd) }
            return try #require(Platform.Sockets.peerToken(fd))
        }
        let before = try token()
        #expect(before.pid == scene.host.pid && Platform.CodeIdentity.runs(before, cdhash: old))
        #expect(await keeper.handOver(scene.client, scene.host) == .ok, "\(scene.host.log)")
        #expect(await eventually { scene.host.log.contains("took over 1 sessions") }, "\(scene.host.log)")
        let after = try token()
        #expect(after.pid == scene.host.pid)
        #expect(Platform.CodeIdentity.runs(after, cdhash: scene.images.new), "a new connection's token after the switch doesn't run the new image")
        #expect(!Platform.CodeIdentity.runs(after, cdhash: old), "a new connection's token after the switch still runs the old image")
        #expect(Platform.CodeIdentity.isHardened(after) == true)
    }
}
