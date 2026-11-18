import Foundation
import Testing
@testable import VibeNode

/// A subscription resumed (the live plan's B3, the live wire contract's §4 "Resume"): `subscribe` with `since` gets no
/// snapshot when the stream, in the same epoch, can still say what changed after the client's `seq`; one delta from it
/// catches the client up. Anything else (another epoch, a `seq` ahead of the stream, older than it remembers) is a
/// snapshot, which the client reconciles by id.
struct LiveResumeTests {
    private static func since(_ epoch: String, _ seq: Int) -> NodeWire.Value {
        .object(["epoch": .string(epoch), "seq": .int(seq)])
    }

    /// A world with entries a, b, c changed to `seq` 3, and a client that held `seq` 3 and went away.
    private func dropped() async throws -> LiveWorld {
        let world = LiveWorld()
        for id in ["a", "b", "c"] { world.store.send(id, .int(0)) }
        try await world.settled(3)
        let first = Recorder()
        world.subscribe(first, sub: "s1")
        world.hub.closed(first)
        return world
    }

    @Test func aResumeInTheSameEpochSendsNoSnapshot() async throws {
        let world = try await dropped()
        world.store.send("a", .int(1))
        try await world.settled(4)
        let client = Recorder()
        world.subscribe(client, id: "2", sub: "s1", since: Self.since(world.hub.epoch, 3))
        try #require(client.messages.count == 2, "\(client.messages)")
        #expect(client.messages[0] == .object(["v": .int(1), "re": .string("2"), "ok": .bool(true),
                                               "result": .object(["sub": .string("s1"), "mode": .string("resume")])]))
        #expect(client.messages[1]["kind"] == .string("delta"))
        #expect(client.messages[1]["prev"] == .int(3) && client.messages[1]["seq"] == .int(4))
        #expect(client.messages.allSatisfy { $0["kind"] != .string("snapshot") })
    }

    @Test func aResumeGetsExactlyWhatChangedSince() async throws {
        let world = try await dropped()
        world.store.send("a", .int(1))      // 4
        world.store.send("b", nil)          // 5
        world.store.send("d", .int(1))      // 6
        try await world.settled(6)
        world.store.send("d", nil)          // 7
        world.store.send("e", .int(1))      // 8
        try await world.settled(8)

        let client = Recorder()
        world.subscribe(client, sub: "s1", since: Self.since(world.hub.epoch, 3))
        let delta = try #require(client.events.first)
        #expect(delta["prev"] == .int(3) && delta["seq"] == .int(8))
        // a changed, b removed, d came and went, e new; c untouched since 3, so not in it.
        #expect(delta["changes"] == .array([.object(["id": .string("a"), "value": .int(1)]),
                                            .object(["id": .string("b"), "value": .null]),
                                            .object(["id": .string("d"), "value": .null]),
                                            .object(["id": .string("e"), "value": .int(1)])]), "\(delta)")

        // From a later `seq`: only what changed after it.
        let later = Recorder()
        world.subscribe(later, sub: "s1", since: Self.since(world.hub.epoch, 6))
        #expect(later.events.first?["changes"] == .array([.object(["id": .string("d"), "value": .null]),
                                                          .object(["id": .string("e"), "value": .int(1)])]))
        // And it goes on from there, live.
        world.store.send("c", .int(9))
        try await later.waitFor(events: 2)
        #expect(later.events[1]["prev"] == .int(8) && later.events[1]["seq"] == .int(9))
    }

    @Test func aResumeThatIsCurrentSendsNothingUntilAChange() async throws {
        let world = try await dropped()
        let client = Recorder()
        world.subscribe(client, sub: "s1", since: Self.since(world.hub.epoch, 3))
        #expect(client.messages.count == 1)
        #expect(client.messages[0]["result"]?["mode"] == .string("resume"))
        world.store.send("c", .int(5))
        try await client.waitFor(events: 1)
        #expect(client.events[0]["kind"] == .string("delta"))
        #expect(client.events[0]["prev"] == .int(3) && client.events[0]["seq"] == .int(4))
    }

    @Test func aResumeOlderThanTheStreamRemembersGetsASnapshot() async throws {
        let world = try await dropped()
        // 257 entries added, then removed: the stream keeps the last 256 removals, so the first is forgotten.
        for index in 0..<257 { world.store.send("x\(index)", .int(index)) }
        try await world.settled(3 + 257)
        for index in 0..<257 { world.store.send("x\(index)", nil) }
        try await world.settled(3 + 2 * 257)

        // From before the forgotten removal: a snapshot.
        let old = Recorder()
        world.subscribe(old, sub: "s1", since: Self.since(world.hub.epoch, 3))
        #expect(old.messages[0]["result"]?["mode"] == .string("snapshot"))
        #expect(old.events.first?["kind"] == .string("snapshot") && old.events.first?["seq"] == .int(3 + 2 * 257))
        #expect(LiveWorld.rows(of: try #require(old.events.first)).keys.sorted() == ["a", "b", "c"])

        // From at or after it: still a resume, every remembered removal in it.
        let recent = Recorder()
        world.subscribe(recent, sub: "s1", since: Self.since(world.hub.epoch, 3 + 257 + 1))
        #expect(recent.messages[0]["result"]?["mode"] == .string("resume"))
        #expect(recent.events.first?["changes"]?.array?.count == 256)
    }

    @Test func aSeqAheadOfTheStreamGetsASnapshot() async throws {
        let world = try await dropped()
        for since in [Self.since(world.hub.epoch, 4), Self.since(world.hub.epoch, 1_000)] {
            let client = Recorder()
            world.subscribe(client, sub: "s1", since: since)
            #expect(client.messages[0]["result"]?["mode"] == .string("snapshot"))
            #expect(client.events.first?["kind"] == .string("snapshot") && client.events.first?["seq"] == .int(3))
        }
        // A `since` out of form is no resume either.
        for since: NodeWire.Value in [.string("3"), .object(["epoch": .string(world.hub.epoch), "seq": .int(-1)]),
                                      .object(["seq": .int(3)])] {
            let client = Recorder()
            world.subscribe(client, sub: "s1", since: since)
            #expect(client.messages[0]["result"]?["mode"] == .string("snapshot"), "\(since)")
        }
    }

    @Test func aNewEpochGetsASnapshotNotAResume() async throws {
        // The server restarted: a new hub, a new epoch, its stream's `seq` counting again from 0. A client that held
        // `seq` 3 of the old epoch gets a snapshot, even where the new stream's `seq` is past 3.
        let world = LiveWorld(epoch: "epoch-2")
        for id in ["a", "b", "c", "d"] { world.store.send(id, .int(0)) }
        try await world.settled(4)
        let client = Recorder()
        world.subscribe(client, sub: "s1", since: Self.since("epoch-1", 3))
        #expect(client.messages[0]["result"]?["mode"] == .string("snapshot"))
        #expect(client.events.first?["kind"] == .string("snapshot"))
        #expect(client.events.first?["epoch"] == .string("epoch-2") && client.events.first?["seq"] == .int(4))
    }
}
