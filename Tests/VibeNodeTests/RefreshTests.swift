import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The engine's refresh (the engine plan's E7) runs what E6's cases call directly: the questions' timers.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct RefreshTests {
    private let scratch = Scratch()

    /// E6's `aTimerThatRunsOutTellsTheLeadOnce`, through the refresh: a question's timer runs out at the refresh after
    /// its time, the lead is told once (held: its lead runs only `sleep`), and its card says it was decided.
    @Test func aRefreshRunsTheTimers() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let asked = try await world.asked("Name it Parser?", options: ["Parser", "Reader"], proposal: "Parser", decideIn: 1, lead: lead)
        // Before its time: nothing.
        world.engine.refresh()
        await world.drained()
        #expect(!world.held().contains { $0.from == .system("timer") })
        #expect(world.card(asked.card.id)?.isOpen == true)
        // Past it.
        let later = Date().timeIntervalSince1970 + 120
        world.queue.sync { world.engine.timersNow = { later } }
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { world.held().contains { $0.from == .system("timer") } })
        world.queue.sync { world.engine.timersNow = { later + 10 } }
        world.engine.refresh()
        await world.drained()
        let told = world.held().filter { $0.from == .system("timer") }
        #expect(told.count == 1, "\(world.held())")
        #expect(told.first?.text.contains("going with your proposal ‘Parser’") == true)
        #expect(world.card(asked.card.id)?.closed == "decided by its timer: Parser")
    }
}
