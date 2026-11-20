import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The all-done mark on a node (`AllDoneLook.swift`, the app's `AllDoneWatch`): a board that goes from open work to none,
/// with a merge, is marked under its lock with the written summary, and `status` says it for a day; a board first read
/// already clear is no clear.
@Suite(NodeTraits.linuxOnly, .timeLimit(.minutes(5)))
struct AllDoneLookTests {
    private let scratch = Scratch()

    private func task(_ slug: String, _ status: LeadTask.Status) -> LeadTask {
        LeadTask(slug: slug, title: "Write the \(slug)", contract: LeadContract(goal: "A \(slug).", acceptance: [], boundaries: [], context: ""), status: status)
    }

    @Test func aBoardThatClearsIsMarkedAndSaidForADay() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let store = BoardStore(root: world.repo)
        try store.prepare()
        try store.update { $0.tasks = [self.task("parser", .running), self.task("lexer", .done)] }
        let open = try store.read()
        try store.update { board in board.tasks[0].status = .done }
        let cleared = try store.read()
        let now = Date()

        // First read already clear: nothing.
        world.queue.sync {
            world.engine.allDoneNow = { now }
            world.engine.noteAllDone(previous: [:], loaded: [world.repo: cleared])
        }

        // Open work to none: marked, with the written summary.
        world.queue.sync { world.engine.noteAllDone(previous: [world.repo: open], loaded: [world.repo: cleared]) }
        #expect(await eventually(timeout: 30) { (try? store.read())?.allDone?.first?.summary != nil })
        let board = try store.read()
        let mark = try #require(board.allDone?.first)
        #expect(board.allDone?.count == 1, "the first look, at a board already clear, made none")
        #expect(mark.tasks.map(\.slug).sorted() == ["lexer", "parser"] && mark.merged == 2, "\(mark)")
        #expect(mark.summary?.byModel == false && mark.summary?.headline == "All 2 tasks are finished; every one of them merged.", "\(String(describing: mark.summary))")

        world.queue.sync { world.engine.boards = [world.repo: board] }
        let notices = world.queue.sync { world.engine.allDoneNotices }
        #expect(notices.count == 1 && notices[0].contains("all done: the lead of repo cleared its board") && notices[0].contains("Done: Write the parser."),
                "\(notices)")
        world.queue.sync { world.engine.allDoneNow = { now + LeadEngine.allDoneShown + 1 } }
        #expect(world.queue.sync { world.engine.allDoneNotices }.isEmpty)
    }
}
