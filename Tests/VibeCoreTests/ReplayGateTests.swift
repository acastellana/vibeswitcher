import Foundation
import Testing
@testable import VibeCore

/// A view re-attaching gets the session's earlier output again; terminal queries in it were answered when
/// they first ran, so the view's answers to them must not reach the program a second time.
struct ReplayGateTests {
    @Test func repliesAreHeldBackWhileReplaying() {
        var gate = ReplayGate()
        gate.attaching()
        #expect(!gate.allowsReplies)
        gate.attached()
        #expect(gate.allowsReplies)
    }

    @Test func aResyncReplaysAgain() {
        var gate = ReplayGate()
        gate.attaching()
        gate.attached()
        gate.attaching()
        #expect(!gate.allowsReplies)
    }

    @Test func aFreshGateAllowsReplies() {
        #expect(ReplayGate().allowsReplies)
    }
}
