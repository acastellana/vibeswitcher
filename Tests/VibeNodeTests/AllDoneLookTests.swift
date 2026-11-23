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
            world.engine.allDone.now = { now }
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
        world.queue.sync { world.engine.allDone.now = { now + LeadEngine.allDoneShown + 1 } }
        #expect(world.queue.sync { world.engine.allDoneNotices }.isEmpty)
    }

    /// While the AI summaries may run and a batch model is given (the user's node's headless Claude; a fake here), the
    /// mark's summary is the model's (`byModel`), asked once; the board carries the card (`BoardValue.allDone`) with its
    /// summary, tasks and seen mark; a page's `seen` with the project marks it seen, once.
    @Test func theModelWritesTheSummaryAndAPageMarksItSeen() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let store = BoardStore(root: world.repo)
        try store.prepare()
        try store.update { $0.tasks = [self.task("parser", .running), self.task("lexer", .done)] }
        let open = try store.read()
        try store.update { board in board.tasks[0].status = .done }
        let cleared = try store.read()
        let now = Date()
        let prompts = Locked<[String]>([])
        let engine = world.engine
        world.queue.sync {
            engine.allDone.now = { now }
            engine.batchModel = { prompt in
                prompts.mutate { $0.append(prompt) }
                return "The parser and lexer are written\n- The parser reads every statement\n- The lexer splits the words"
            }
            engine.summariesAllowed = true
            engine.noteAllDone(previous: [world.repo: open], loaded: [world.repo: cleared])
        }
        #expect(await eventually(timeout: 30) { (try? store.read())?.allDone?.first?.summary != nil })
        let mark = try #require(try store.read().allDone?.first)
        #expect(mark.summary?.byModel == true && mark.summary?.headline == "The parser and lexer are written", "\(String(describing: mark.summary))")
        #expect(prompts.value.count == 1 && prompts.value[0].contains("Write the parser"))

        let value = BoardValue.value(project: "p", root: world.repo, board: try store.read(), now: now)
        let card = try #require(value["allDone"])
        #expect(card["summary"]?["bullets"]?.array?.count == 2 && card["merged"] == .int(2) && card["seen"] == .bool(false), "\(card)")
        #expect(WireSchema.check(value, as: "board") == nil)
        #expect(BoardText.allDoneLines(card, now: now).first == "All tasks finished 0s ago · 2 tasks · 2 merged")

        let changed = Locked<[Bool]>([])
        world.queue.sync { engine.seeAllDone(root: world.repo) { ok in changed.mutate { $0.append(ok) } } }
        #expect(await eventually(timeout: 30) { changed.value.count == 1 })
        #expect(changed.value == [true] && (try? store.read())?.allDone?.first?.seenAt != nil)
        world.queue.sync { engine.seeAllDone(root: world.repo) { ok in changed.mutate { $0.append(ok) } } }
        #expect(await eventually(timeout: 30) { changed.value.count == 2 })
        #expect(changed.value == [true, false], "seen once")
        // A project no lead runs is gone.
        let gone = try #require(await world.ask("seen", ["project": .string("local:project:nowhere")], action: nil))
        #expect(gone.error?.code == NodeWire.Code.gone.rawValue, "\(gone)")
    }

    // MARK: The card in the lead's chat (2026-11-21)

    /// The running lead's board's marks go to its chat (`chatExtras`, under the lead's chat session id), oldest first,
    /// as `allDone` items; none once the board has none.
    @Test func aRunningLeadsMarksGoToItsChat() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let lead = try await world.world.lead()
        let store = BoardStore(root: world.repo)
        try store.update { board in
            board.allDone = [LeadAllDone(id: "m1", at: 1_763_000_000, since: 0, tasks: [LeadAllDone.Task(slug: "a", title: "A", outcome: .merged)]),
                             LeadAllDone(id: "m2", at: 1_763_000_600, since: 1_763_000_000, tasks: [])]
        }
        let id = NodeIds.session(host: lead.session.id)
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { world.queue.sync { world.engine.chatExtras.values[id]?.count } == 2 })
        let cards = try #require(world.queue.sync { world.engine.chatExtras.values[id] })
        #expect(cards.map { $0["id"]?.string } == ["all-done:m1", "all-done:m2"] && cards[0]["type"] == .string("allDone"), "\(cards)")
        #expect(cards.allSatisfy { WireSchema.check($0, as: "chat.item") == nil })
        try store.update { $0.allDone = nil }
        world.engine.refresh()
        #expect(await eventually(timeout: 60) { world.queue.sync { world.engine.chatExtras.values[id] } == nil })
    }

    /// A chat places each card by its time among the transcript's items (before the first later one; one with no time
    /// stays after the item before it), the rest at the end, never twice.
    @Test func aChatPlacesTheCardsByTheirTime() {
        func item(_ id: String, _ at: String?) -> (id: String, value: NodeWire.Value) {
            (id, .object(["id": .string(id), "at": at.map(NodeWire.Value.string) ?? .null]))
        }
        func card(_ id: String, _ at: String) -> NodeWire.Value { .object(["id": .string(id), "at": .string(at), "type": .string("allDone")]) }
        let items = [item("p1", "2026-11-17T09:00:00.000Z"), item("r1", nil), item("p2", "2026-11-17T10:00:00.000Z")]
        let placed = ChatStore.placed(items, extras: [card("late", "2026-11-17T11:00:00.000Z"), card("mid", "2026-11-17T09:30:00.000Z"),
                                                      card("p1", "2026-11-17T08:00:00.000Z")])
        #expect(placed.map(\.id) == ["p1", "r1", "mid", "p2", "late"])
        #expect(ChatStore.placed(items, extras: []).map(\.id) == ["p1", "r1", "p2"])
    }
}
