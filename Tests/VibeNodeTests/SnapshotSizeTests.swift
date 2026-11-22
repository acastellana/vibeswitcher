import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// A snapshot fits a line by construction (the architecture review's row 14; the 1.4 MB cards incident of 2026-11-20):
/// the closed cards are kept under `CardStore.keptClosedBytes` as well as by count, and a snapshot still past
/// `NodeWire.maxLine` (open cards, or three leads' boards) leaves entries out, closed cards first, and says `truncated`.
struct SnapshotSizeTests {
    /// A question card for `/scratch/repo` with a question of `bytes` characters, closed when `closed`.
    static func card(bytes: Int, closed: Bool, at: Date) -> CardStore.Card {
        var card = CardStore.Card(root: "/scratch/repo", kind: .question, at: at)
        card.question = LeadQuestion(id: UUID().uuidString, text: String(repeating: "x", count: bytes), options: ["Yes", "No"])
        if closed { card.closed = "answered" }
        return card
    }

    @Test func closedCardsAreKeptUnderTheirBytes() {
        let store = CardStore()
        let clock = Locked(Date(timeIntervalSince1970: 1_000_000))
        store.now = { clock.value }
        var ids: [String] = []
        for _ in 0..<CardStore.keptClosed {
            clock.value = clock.value.addingTimeInterval(1)
            let card = Self.card(bytes: 8_000, closed: false, at: clock.value)
            store.put(card)
            store.change(card.id) { $0.closed = "answered" }
            ids.append(card.id)
        }
        let closed = store.cards.values.filter { !$0.isOpen }
        let bytes = closed.reduce(0) { $0 + NodeWire.message($1.value).count }
        #expect(bytes <= CardStore.keptClosedBytes, "\(bytes) bytes in \(closed.count) closed cards")
        #expect(closed.count < CardStore.keptClosed, "the bytes, not the count, bound these")
        #expect(Set(closed.map(\.id)) == Set(ids.suffix(closed.count)), "the newest closed are kept")
    }

    /// The worst case the cards stream holds: the closed cards at their bytes' bound, and open cards past a line on their
    /// own (nothing bounds a question's length but the post's line): the snapshot fits, every closed card left out
    /// before an open one, and says so.
    @Test func aCardsSnapshotPastALineFitsAndSaysItIsTruncated() throws {
        let at = Date(timeIntervalSince1970: 1_000_000)
        var entries: [NodeWire.Entry] = []
        var closedBytes = 0
        while closedBytes < CardStore.keptClosedBytes {
            let card = Self.card(bytes: 4_000, closed: true, at: at)
            closedBytes += NodeWire.message(card.value).count
            entries.append(.init(id: card.id, value: card.value))
        }
        let open = (0..<8).map { _ in Self.card(bytes: 100_000, closed: false, at: at) }
        entries += open.map { .init(id: $0.id, value: $0.value) }
        let snapshot = NodeWire.Snapshot(sub: "s", collection: "cards", epoch: "e", seq: 1, entries: entries)
        #expect(NodeWire.message(snapshot).count > NodeWire.maxLine, "the case passes a line whole")

        let fitted = LiveHub.fitted(snapshot)
        #expect(fitted.count <= NodeWire.maxLine, "\(fitted.count)")
        let read = try #require(NodeWire.decode(NodeWire.Snapshot.self, fitted))
        #expect(read.truncated == true)
        #expect(Set(open.map(\.id)).isSubset(of: Set(read.entries.map(\.id))), "every open card kept while the open ones fit")
        #expect(WireSchema.check(try #require(NodeWire.decode(NodeWire.Value.self, fitted)), as: "snapshot", strict: true) == nil)
    }

    /// Three leads' boards, each large: the boards' snapshot fits, the largest left out first, and says so; one that
    /// fits is sent whole, with no flag.
    @Test func aBoardsSnapshotPastALineFitsAndSaysItIsTruncated() throws {
        let board = { (size: Int) -> NodeWire.Value in .object(["tasks": .array((0..<(size / 1_000)).map { _ in .string(String(repeating: "t", count: 990)) })]) }
        let entries = [("a", 500_000), ("b", 400_000), ("c", 300_000)].map { NodeWire.Entry(id: $0.0, value: board($0.1)) }
        let snapshot = NodeWire.Snapshot(sub: "s", collection: "boards", epoch: "e", seq: 1, entries: entries)
        let fitted = try #require(NodeWire.decode(NodeWire.Snapshot.self, LiveHub.fitted(snapshot)))
        #expect(LiveHub.fitted(snapshot).count <= NodeWire.maxLine)
        #expect(fitted.truncated == true && fitted.entries.map(\.id) == ["b", "c"], "\(fitted.entries.map(\.id))")

        let small = NodeWire.Snapshot(sub: "s", collection: "boards", epoch: "e", seq: 1, entries: Array(entries.suffix(2)))
        #expect(LiveHub.fitted(small) == NodeWire.message(small))
        #expect(NodeWire.decode(NodeWire.Snapshot.self, LiveHub.fitted(small))?.truncated == nil)
    }
}
