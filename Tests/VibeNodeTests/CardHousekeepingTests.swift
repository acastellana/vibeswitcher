import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// A node that runs for days (2026-11-19: 329 cards after a day, 1.4 MB, past a line's limit, and no card could be
/// answered): the closed cards are kept bounded, the held-config ones first; `questions --all` lists the newest closed
/// and says how many it left out; one card is found by its id however many the server holds; and no reply is a line the
/// other side would drop.
@Suite(.timeLimit(.minutes(5)))
struct CardHousekeepingTests {
    private let scratch = Scratch()

    /// A card of `kind`, closed when `closed` says why.
    private static func card(_ kind: CardStore.Kind, closed: String? = nil, at: Date) -> CardStore.Card {
        var card = CardStore.Card(root: "/scratch/repo", kind: kind, at: at)
        card.closed = closed
        return card
    }

    /// The held-config cards past the newest `keptClosedConfig` closed go first, then the oldest closed past
    /// `keptClosed`, then any closed longer than `closedLife` ago; an open card is never pruned, however old; a pruned
    /// card is told to the stream as removed.
    @Test func closedCardsAreKeptBoundedHeldConfigFirst() {
        let store = CardStore()
        let clock = Locked(Date(timeIntervalSince1970: 1_000_000))
        store.now = { clock.value }
        let tick = { clock.value = clock.value.addingTimeInterval(1) }
        let open = Self.card(.question, at: clock.value)
        store.put(open)

        var configs: [String] = []
        for _ in 0..<(CardStore.keptClosedConfig + 5) {
            tick()
            let card = Self.card(.configHeld, closed: "superseded by a newer card", at: clock.value)
            configs.append(card.id)
            store.put(card)
        }
        let closedConfig = { store.cards.values.filter { $0.kind == .configHeld && !$0.isOpen }.map(\.id) }
        #expect(Set(closedConfig()) == Set(configs.suffix(CardStore.keptClosedConfig)))
        #expect(store.changes.values[configs[0]] == nil, "a pruned card is told as removed")

        // Closed in place (`change`), as an answer closes a card: stamped when it closes, not when it was drawn.
        var questions: [String] = []
        for _ in 0..<(CardStore.keptClosed + 50) {
            tick()
            let card = Self.card(.question, at: clock.value)
            store.put(card)
            store.change(card.id) { $0.closed = "answered" }
            questions.append(card.id)
        }
        let closed = store.cards.values.filter { !$0.isOpen }
        #expect(closed.count == CardStore.keptClosed)
        #expect(Set(closed.map(\.id)) == Set(questions.suffix(CardStore.keptClosed)), "the newest closed are kept, all kinds together")
        #expect(store.cards[open.id] != nil, "an open card is never pruned")

        clock.value = clock.value.addingTimeInterval(CardStore.closedLife + 60)
        let late = Self.card(.approval, closed: "withdrawn", at: clock.value)
        store.put(late)
        #expect(store.cards.values.filter { !$0.isOpen }.map(\.id) == [late.id], "the closed past their life are gone")
        #expect(store.cards[open.id]?.isOpen == true)
        #expect(store.cards[late.id]?.closedAt == clock.value)
    }

    /// A card that closed long after it was drawn is kept by when it closed: a question open for a week, answered now,
    /// isn't pruned as old.
    @Test func aCardIsKeptByWhenItClosedNotWhenItWasDrawn() {
        let store = CardStore()
        let clock = Locked(Date(timeIntervalSince1970: 2_000_000))
        store.now = { clock.value }
        let card = Self.card(.question, at: clock.value)
        store.put(card)
        clock.value = clock.value.addingTimeInterval(7 * CardStore.closedLife)
        store.change(card.id) { $0.closed = "answered" }
        store.put(Self.card(.question, closed: "answered", at: clock.value))
        #expect(store.cards[card.id]?.closedAt == clock.value)
        #expect(store.cards.count == 2)
    }

    /// `questions --all` lists every open card and the newest closed (`closedListed`, or `limit`), `more` saying how many
    /// closed it left out; `card` finds one card alone, open or closed, by its id or a prefix only it has.
    @Test(NodeTraits.linuxOnly) func questionsAllListsTheNewestClosedAndFindsAnyCardAlone() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let start = Date(timeIntervalSince1970: 3_000_000)
        let closedCount = Requests.closedListed + 30
        let (opened, closed) = world.queue.sync { () -> ([String], [String]) in
            var closed: [String] = []
            for index in 0..<closedCount {
                var card = CardStore.Card(root: world.repo, kind: .question, at: start.addingTimeInterval(Double(index)))
                card.closed = "answered"
                world.engine.cards.put(card)
                closed.append(card.id)
            }
            let opened = (0..<2).map { index -> String in
                let card = CardStore.Card(root: world.repo, kind: .question, at: start.addingTimeInterval(Double(closedCount + index)))
                world.engine.cards.put(card)
                return card.id
            }
            return (opened, closed)
        }
        let ids = { (reply: NodeWire.Reply?) in reply?.result?["cards"]?.array?.compactMap { $0["id"]?.string } ?? [] }

        let all = try #require(await world.ask("questions", ["all": .bool(true)]))
        #expect(ids(all) == closed.suffix(Requests.closedListed) + opened, "\(all)")
        #expect(all.result?["more"]?.int == 30)

        let few = try #require(await world.ask("questions", ["all": .bool(true), "limit": .int(5)]))
        #expect(ids(few) == closed.suffix(5) + opened)
        #expect(few.result?["more"]?.int == closedCount - 5)

        let openOnly = try #require(await world.ask("questions"))
        #expect(ids(openOnly) == opened)
        #expect(openOnly.result?["more"]?.int == 0)

        let oldest = try #require(await world.ask("questions", ["card": .string(closed[0])]))
        #expect(ids(oldest) == [closed[0]], "a closed card --all leaves out is still found alone")
        let prefix = String(opened[1].dropFirst("\(NodeIds.node):card:".count).prefix(8))
        #expect(ids(try #require(await world.ask("questions", ["card": .string(prefix)]))) == [opened[1]])
        let none = try #require(await world.ask("questions", ["card": .string("\(NodeIds.node):card:nothing-like-it")]))
        #expect(none.ok && ids(none).isEmpty)
    }

    /// `questions --wait`: the open cards at once when there are; else no reply until a card opens (a closed card is
    /// no answer), then that card; with nothing opening, none after `seconds`, `waited` saying so.
    @Test(NodeTraits.linuxOnly) func questionsWaitAnswersWhenACardNeedsTheUser() async throws {
        let world = try await CardWorld.make(scratch)
        defer { world.stop() }
        let ids = { (reply: NodeWire.Reply?) in reply?.result?["cards"]?.array?.compactMap { $0["id"]?.string } ?? [] }

        let none = try #require(await world.ask("questions", ["wait": .bool(true), "seconds": .int(0)]))
        #expect(none.ok && ids(none).isEmpty && none.result?["waited"]?.bool == true, "\(none)")

        let reply = Locked<NodeWire.Reply?>(nil)
        let request = NodeWire.Request(id: "wait-1", kind: "questions", args: ["wait": .bool(true), "seconds": .int(120)])
        world.queue.async { world.requests.handle(request, from: CardWorld.user) { reply.value = $0 } }
        world.queue.sync {
            var closed = CardStore.Card(root: world.repo, kind: .question)
            closed.closed = "answered"
            world.engine.cards.put(closed)
        }
        await world.drained()
        world.queue.sync {}
        #expect(reply.value == nil, "a closed card isn't one that needs the user")
        let card = CardStore.Card(root: world.repo, kind: .approval)
        world.queue.async { world.engine.cards.put(card) }
        #expect(await eventually(timeout: 60) { reply.value != nil })
        #expect(ids(reply.value) == [card.id] && reply.value?.result?["waited"]?.bool == false, "\(String(describing: reply.value))")

        let atOnce = try #require(await world.ask("questions", ["wait": .bool(true), "seconds": .int(120)], timeout: 60))
        #expect(ids(atOnce) == [card.id], "an open card answers at once")
    }

    /// A reply whose line would pass `maxLine` is an `internal` failure under the same `re` that says how large it was
    /// (a line the reader takes), never a line the reader drops; one within the limit goes as it is.
    @Test func aReplyPastTheLineLimitIsAClearErrorNotADroppedLine() throws {
        let small = NodeWire.Reply(re: "r1", result: .object(["cards": .array([])]))
        #expect(NodeWire.replyLine(small) == NodeWire.line(small))

        let big = NodeWire.Reply(re: "r2", result: .object(["cards": .array([.string(String(repeating: "x", count: NodeWire.maxLine))])]))
        let line = NodeWire.replyLine(big)
        #expect(line.count - 1 <= NodeWire.maxLine)
        #expect(line.last == UInt8(ascii: "\n"))
        let reply = try #require(NodeWire.decode(NodeWire.Reply.self, line.dropLast()))
        #expect(reply.re == "r2" && !reply.ok)
        #expect(reply.error?.code == NodeWire.Code.internal.rawValue)
        #expect(reply.error?.message.contains("past the line's limit") == true, "\(String(describing: reply.error))")

        var lines = NodeWire.Lines()
        #expect(lines.append(line).count == 1 && !lines.tooLong)
    }
}
