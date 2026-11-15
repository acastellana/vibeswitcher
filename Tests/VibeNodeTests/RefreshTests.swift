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

    /// The E7 review: an answer and a hold each refresh (the app's `LeadController.refresh` after each): the board as
    /// answered is read with no clock asking.
    @Test func anAnswerAndAHoldEachRefresh() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        let answered = try await world.asked("Name it?", options: ["A", "B"], lead: lead)
        let held = try await world.asked("Hold it?", options: ["A", "B"], proposal: "A", decideIn: 5, lead: lead)
        await world.drained()
        #expect(world.queue.sync { world.engine.boards.isEmpty }, "no refresh yet")
        #expect(try #require(await world.answer(answered.card, "A")).ok)
        #expect(await eventually(timeout: 60) {
            world.queue.sync { world.engine.boards[world.repo]?.questions.first { $0.id == answered.question.id }?.answer == "A" }
        }, "\(world.queue.sync { world.engine.boards })")
        await world.drained()
        world.queue.sync { world.engine.boards = [:] }
        #expect(try #require(await world.ask("hold", ["card": .string(held.card.id), "code": .string(held.card.code)])).ok)
        #expect(await eventually(timeout: 60) { world.queue.sync { world.engine.boards[world.repo] != nil } })
    }

    /// The app's `BaseMovesTests.aCommitOnABaseSwitchedSinceTheLastLookIsAskedAboutAndTheMergeSaysSo`, its alert half
    /// (`AlertRules.baseMoved`), as a `status` notice: a move asked about with no merge of the lead's refused for it is
    /// none; once one is, its merges wait on the user, who's told in `status`, once however many refreshes see it; once
    /// the move is taken, no longer.
    @Test func aBaseMoveThatRefusedTheLeadsMergeIsAStatusNoticeOnce() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.sleepingLead()
        #expect(await eventually(timeout: 60) { world.queue.sync { world.engine.leads.leads[world.project]?.session == lead.id } })
        // A commit on the base nothing accounts for.
        try await taskBranch(world.repo, task: "moved")
        #expect(Git.run(["merge", "-q", "--ff-only", "agent/moved"], in: world.repo).ok)
        let now = Git.run(["rev-parse", "main"], in: world.repo).output
        func baseCard() -> CardStore.Card? {
            world.queue.sync { world.engine.cards.list(project: world.project).first { $0.kind == .baseMove && $0.closed == nil } }
        }
        var asked = false
        for _ in 0..<300 where !asked {
            world.engine.refresh()
            await world.drained()
            asked = baseCard() != nil
            if !asked { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        try #require(asked, "the move was never asked about")
        func notices() -> [String] {
            world.queue.sync { world.requests.statusValue()["notices"]?.array?.compactMap(\.string) ?? [] }
                .filter { $0.contains("moved outside the lead's merges") }
        }
        // Asked about, but no merge of the lead's refused for it: no notice.
        world.engine.refresh()
        await world.drained()
        #expect(notices().isEmpty, "\(notices())")
        // The lead's merge refused for it: its merges wait on the user, who's told in `status`, once.
        try LeadVault.BaseMoveRefusal(branch: "main", to: now, at: 1).save(root: world.repo)
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { notices().count == 1 }, "\(notices())")
        for _ in 0..<3 {
            world.engine.refresh()
            await world.drained()
        }
        #expect(notices().count == 1, "\(notices())")
        #expect(notices().first?.contains("main moved outside the lead's merges: 1 commit in \(world.world.name)") == true, "\(notices())")
        // Taken: nothing waits on the user any more.
        let card = try #require(baseCard())
        #expect(try #require(await world.ask("base.accept", ["card": .string(card.id), "code": .string(NodeIds.code(card: card.id))])).ok)
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { notices().isEmpty }, "\(notices())")
    }
}
