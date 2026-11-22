import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// Which ancestor of a sender is a branch code runner (`PeerFacts.runner`, v2-mac-tasks item 11): its arguments tell;
/// unreadable arguments tell nothing (nil, so the voice refuses), except for a process of root's above a sender who
/// isn't root: the Mac refuses `KERN_PROCARGS2` for root's `login` and `sshd-session`, and a runner is the user's own
/// code. Both systems: pure.
struct PeerRunnerTests {
    let ancestor = PeerFacts.Ancestor(pid: 50, startTicks: 9)
    /// The branch code wrapper's own arguments, then a command.
    var runner: [String] { BranchCode.wrapper + ["make", "test"] }

    @Test func anUnreadableAncestorTellsNothingUnlessItIsRootsAboveTheUser() {
        let root: (pid_t) -> uid_t? = { _ in 0 }
        let user: (pid_t) -> uid_t? = { _ in 501 }
        let unknown: (pid_t) -> uid_t? = { _ in nil }
        #expect(PeerFacts.runner(ancestor, peerUID: 501, arguments: [], runnersAbove: [], owner: root) == false)
        #expect(PeerFacts.runner(ancestor, peerUID: 501, arguments: [], runnersAbove: [], owner: user) == nil)
        #expect(PeerFacts.runner(ancestor, peerUID: 501, arguments: [], runnersAbove: [], owner: unknown) == nil)
        #expect(PeerFacts.runner(ancestor, peerUID: nil, arguments: [], runnersAbove: [], owner: root) == nil)
        #expect(PeerFacts.runner(ancestor, peerUID: 0, arguments: [], runnersAbove: [], owner: root) == nil)
        // Readable: its arguments decide, a runner above the scratch node not counted; the owner isn't asked.
        #expect(PeerFacts.runner(ancestor, peerUID: 501, arguments: runner, runnersAbove: [], owner: root) == true)
        #expect(PeerFacts.runner(ancestor, peerUID: 501, arguments: runner, runnersAbove: [ancestor], owner: root) == false)
        #expect(PeerFacts.runner(ancestor, peerUID: 501, arguments: ["/bin/zsh", "-l"], runnersAbove: [], owner: root) == false)
    }
}
