import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// WitnessOffEngineQueueTests' CI failure (abf3c047, v2 linux core, 2026-11-24: 14 of 30 told after 120 s, the whole run
/// starved): held messages go one at a time (`deliverHeld`), and a post that didn't find the lead (`Delivery.target`:
/// the vault's lookup of the role's session, which answers nothing past `HostCall.vaultTimeout` under load; the board;
/// the lead's process) used to end the chain until the next refresh. Now it is tried again after a short wait, a few
/// times (`LeadEngine.heldRetryDelays`), and the project's notice is raised only once those are spent.
@Suite(NodeTraits.linuxOnly, .serialized, .timeLimit(.minutes(5)))
struct HeldDeliveryStallTests {
    private let scratch = Scratch()

    /// A lookup that fails for a moment: what was held goes once it answers, with no refresh, and no notice was raised.
    @Test func aPostThatFindsNoLeadForAMomentIsTriedAgainWithoutARefresh() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        // The node's own waits, long enough for the board to be put back while they last.
        world.queue.sync { world.engine.heldRetryDelays = [0.5, 1, 2, 4] }
        let lead = try await world.lead(idle: false)
        let root = world.repo
        let marker = "held-stall-\(UUID().uuidString.prefix(8))"
        func told() -> Int { world.pending(lead).filter { $0.text.contains(marker) }.count }

        // While the lookup fails (here: the board names another terminal for the lead, as a stale read would), five
        // messages are sent: the first is held, the rest queue behind it.
        let tty = try #require(BoardStore(root: root).load().leadTTY)
        try BoardStore(root: root).update { $0.leadTTY = "ttypts-elsewhere" }
        for index in 0..<5 { _ = await world.deliver("\(marker) \(index)", from: .system("witness")) }
        #expect(told() == 0)

        // The lookup answers again: the next try sends them all, with no refresh.
        try BoardStore(root: root).update { $0.leadTTY = tty }
        #expect(await eventually(timeout: 60) { told() == 5 }, "\(told())")
        #expect(world.queue.sync { world.engine.leads.leads[world.project]?.notice } == nil, "no notice for a moment's miss")
    }

    /// A lookup that keeps failing: the tries are spent, then the notice says why; the messages stay held.
    @Test func aLeadThatStaysUnfoundIsNoticedOnceTheTriesAreSpent() async throws {
        let world = try await DeliveryWorld.make(scratch)
        defer { world.stop() }
        world.queue.sync { world.engine.heldRetryDelays = [0.05, 0.05] }
        let lead = try await world.lead(idle: false)
        let root = world.repo
        try BoardStore(root: root).update { $0.leadTTY = "ttypts-elsewhere" }
        _ = await world.deliver("never told", from: .system("witness"))
        #expect(await eventually(timeout: 60) {
            world.queue.sync { world.engine.leads.leads[world.project]?.notice?.contains("what's sent to the lead is held") == true }
        })
        #expect(world.pending(lead).filter { $0.text.contains("never told") }.isEmpty)
    }
}
