import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// A node lists no session that runs under another session host (`HostedAgents.underOtherHost`): on 2026-11-23 the real
/// node's page listed other agents' test sessions ("repo unknown", "write-the-parser unknown"), the fake `claude`s their
/// scratch hosts ran. Two scratch nodes side by side, the first listing what its host didn't start as the user's node
/// does (`listsUnhosted`): the other's agent isn't among its sessions, its own is.
struct ForeignSessionsTests {
    let scratch = Scratch()

    @Test(NodeTraits.linuxOnly) func aSessionUnderAnotherNodesHostIsntListed() async throws {
        let node = try await ScratchNode(scratch, listsUnhosted: true)
        defer { node.stop() }
        let other = try await ScratchNode(scratch)
        defer { other.stop() }
        // The other's first: a scan that finds this node's own agent (started after) sees the other's too.
        let theirs = try await HookedAgent.start(other, project: "theirs")
        let mine = try await HookedAgent.start(node, project: "mine")
        var terminals: [String] = []
        let listed = await node.eventuallyStatus { status in
            terminals = ((status["sessions"] as? [[String: Any]]) ?? []).compactMap { $0["terminal"] as? String }
            return terminals.contains(mine.session.tty)
        }
        #expect(listed, "\(terminals)\n\(node.said)")
        #expect(!terminals.contains(theirs.session.tty), "the other node's session \(theirs.session.tty) is listed: \(terminals)")
        // The other node lists its own (a scratch node lists only what its host started).
        let theirsListed = await other.eventuallyStatus { status in
            ((status["sessions"] as? [[String: Any]]) ?? []).contains { $0["terminal"] as? String == theirs.session.tty }
        }
        #expect(theirsListed, "\(other.said)")
    }
}
