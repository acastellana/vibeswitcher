import Foundation
import Testing
@testable import VibeNode

/// A store's change stream: what changed, by id, and nothing for what didn't; a slow subscriber gets where each entry
/// is now, not every step on the way.
struct ChangesTests {
    @Test func anUnchangedValueSendsNothing() async {
        let changes = Changes<Int>()
        let got = Got<Int>()
        let subscription = changes.subscribe { got.add($0) }
        changes.send("a", 1)
        changes.send("a", 1)
        changes.send("b", 2)
        changes.send("b", 2)
        changes.send("a", 1)
        // A marker after them: once it's in, everything sent before it has been handed over.
        changes.send("end", 0)
        #expect(await eventually { got.deltas.contains { $0.id == "end" } })
        #expect(got.deltas == [.init(id: "a", value: 1), .init(id: "b", value: 2), .init(id: "end", value: 0)], "\(got.deltas)")
        // Removing what isn't there sends nothing either.
        changes.send("never", nil)
        changes.send("end", 1)
        #expect(await eventually { got.deltas.count == 4 })
        #expect(got.deltas.last == .init(id: "end", value: 1), "\(got.deltas)")
        #expect(changes.values == ["a": 1, "b": 2, "end": 1])
        subscription.cancel()
    }

    @Test func aSlowSubscribersDeltasForOneEntryAreFoldedIntoTheLatest() async {
        let changes = Changes<String>()
        let got = Got<String>()
        let inFirst = DispatchSemaphore(value: 0), letGo = DispatchSemaphore(value: 0)
        let subscription = changes.subscribe { deltas in
            got.add(deltas)
            // The first batch holds the subscriber until the test has sent the rest.
            if got.batches.count == 1 {
                inFirst.signal()
                letGo.wait()
            }
        }
        changes.send("a", "one")
        #expect(await offPool { inFirst.wait(timeout: .now() + hangGuard) } == .success)
        changes.send("a", "two")
        changes.send("b", "first")
        changes.send("a", "three")
        changes.send("c", "gone soon")
        changes.send("c", nil)
        letGo.signal()
        #expect(await eventually { got.batches.count == 2 })
        #expect(got.batches.first == [.init(id: "a", value: "one")])
        // One delta an id, the latest, in the order the ids first changed while it was held.
        #expect(got.batches.last == [.init(id: "a", value: "three"), .init(id: "b", value: "first"), .init(id: "c", value: nil)],
                "\(got.batches)")
        subscription.cancel()
    }

    @Test func aRemovalIsADeltaWithNoValue() async {
        let changes = Changes<Int>()
        let got = Got<Int>()
        let subscription = changes.subscribe { got.add($0) }
        changes.send("a", 1)
        #expect(await eventually { got.deltas.count == 1 })
        changes.send("a", nil)
        #expect(await eventually { got.deltas.count == 2 })
        #expect(got.deltas.last == .init(id: "a", value: nil))
        #expect(changes.values.isEmpty)
        // Back again: a value once more.
        changes.send("a", 2)
        #expect(await eventually { got.deltas.count == 3 })
        #expect(got.deltas.last == .init(id: "a", value: 2))
        subscription.cancel()
    }

    @Test func aCancelledSubscriberGetsNothingMore() async {
        let changes = Changes<Int>()
        let gone = Got<Int>(), kept = Got<Int>()
        let first = changes.subscribe { gone.add($0) }
        let second = changes.subscribe { kept.add($0) }
        changes.send("a", 1)
        #expect(await eventually { gone.deltas.count == 1 && kept.deltas.count == 1 })
        first.cancel()
        changes.send("a", 2)
        #expect(await eventually { kept.deltas.count == 2 })
        #expect(gone.deltas.count == 1)
        second.cancel()
    }
}

/// What a subscriber was handed, batch by batch, from its queue.
final class Got<Value: Equatable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [[Changes<Value>.Delta]] = []

    func add(_ batch: [Changes<Value>.Delta]) { lock.withLock { all.append(batch) } }
    var batches: [[Changes<Value>.Delta]] { lock.withLock { all } }
    var deltas: [Changes<Value>.Delta] { batches.flatMap { $0 } }
}
