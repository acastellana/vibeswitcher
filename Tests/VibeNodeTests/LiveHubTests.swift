import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The live hub (the live plan's B1, the live wire contract's §3 and §4): a store's changes numbered into a stream, and
/// each subscription served a snapshot, then deltas whose `prev` is always the `seq` it was sent last, written on the
/// engine queue's next turn, folded only while its connection can't take bytes. On a recording transport: no socket.
struct LiveHubTests {
    // MARK: subscribe

    @Test func subscribeGetsAReplyThenASnapshot() async throws {
        let world = LiveWorld()
        world.store.send("a", .int(1))
        world.store.send("b", .int(2))
        try await world.settled(2)
        let client = Recorder()
        world.subscribe(client, id: "7", sub: "s1")

        let messages = client.messages
        try #require(messages.count == 2, "\(messages)")
        #expect(messages[0] == .object(["v": .int(1), "re": .string("7"), "ok": .bool(true),
                                        "result": .object(["sub": .string("s1"), "mode": .string("snapshot")])]))
        let snapshot = messages[1]
        #expect(snapshot["kind"] == .string("snapshot") && snapshot["sub"] == .string("s1"))
        #expect(snapshot["collection"] == .string("things") && snapshot["epoch"] == .string(world.hub.epoch))
        #expect(snapshot["seq"] == .int(2))
        #expect(snapshot["entries"] == .array([.object(["id": .string("a"), "value": .int(1)]),
                                               .object(["id": .string("b"), "value": .int(2)])]))
    }

    @Test func aChangeIsOneDeltaWithPrevAndSeq() async throws {
        let world = LiveWorld()
        world.store.send("a", .int(1))
        try await world.settled(1)
        let client = Recorder()
        world.subscribe(client, sub: "s1")
        world.store.send("b", .string("new"))
        try await client.waitFor(events: 2)

        let delta = client.events[1]
        #expect(delta["kind"] == .string("delta") && delta["sub"] == .string("s1"))
        #expect(delta["prev"] == .int(1) && delta["seq"] == .int(2))
        #expect(delta["changes"] == .array([.object(["id": .string("b"), "value": .string("new")])]))
        #expect(delta["at"] == .string(NodeWire.dateText(LiveWorld.fixed)))
        #expect(delta["v"] == .int(1) && delta["ops"] == nil && delta["entries"] == nil)
    }

    @Test func everyDeltasPrevIsTheLastSeqSent() async throws {
        let world = LiveWorld()
        for index in 0..<5 { world.store.send("e\(index)", .int(0)) }
        try await world.settled(5)
        let client = Recorder()
        world.subscribe(client, sub: "s1")
        // Changes one at a time, in bursts the hub folds or doesn't as it finds them, and removals.
        for round in 1...40 {
            world.store.send("e\(round % 7)", round % 9 == 0 ? nil : .int(round))
            if round % 5 == 0 { _ = try await world.mark() }
        }
        let last = try await world.mark()
        #expect(await eventually { client.events.last?["seq"] == .int(last) })

        var held: Int?
        for event in client.events {
            if event["kind"] == .string("snapshot") { held = event["seq"]?.int; continue }
            let (prev, seq) = (try #require(event["prev"]?.int), try #require(event["seq"]?.int))
            #expect(prev == held, "a delta from \(prev) after \(String(describing: held)): \(client.events)")
            #expect(seq > prev)
            held = seq
        }
        #expect(held == last)
    }

    @Test func aRemovalIsAValueOfNull() async throws {
        let world = LiveWorld()
        world.store.send("a", .int(1))
        try await world.settled(1)
        let client = Recorder()
        world.subscribe(client, sub: "s1")
        world.store.send("a", nil)
        try await client.waitFor(events: 2)
        #expect(client.events[1]["changes"] == .array([.object(["id": .string("a"), "value": .null])]))
        #expect(world.queue.sync { world.stream.entries["a"] } == nil)
    }

    @Test func anEqualValueSendsNothing() async throws {
        let world = LiveWorld()
        world.store.send("a", .int(1))
        try await world.settled(1)
        let client = Recorder()
        world.subscribe(client, sub: "s1")
        // Past the store's own rule (`Changes` sends nothing equal): the stream's, for a value set on it by hand, and a
        // removal of what isn't there.
        let changed = world.queue.sync {
            [world.stream.apply(id: "a", value: .int(1)), world.stream.apply(id: "never", value: nil)]
        }
        #expect(changed == [false, false])
        #expect(world.queue.sync { world.stream.seq } == 1)
        world.store.send("b", .int(2))
        try await client.waitFor(events: 2)
        #expect(client.events[1]["prev"] == .int(1) && client.events[1]["seq"] == .int(2), "\(client.events)")
        #expect(client.events.count == 2)
    }

    @Test func aChangeIsWrittenWithNoTimerBetween() async throws {
        // The hub's only clock is `now`, which says one instant and never moves; no `NodeClock` is anywhere. The frame
        // still comes, from the store's send alone, on the engine queue's next turn.
        let world = LiveWorld()
        let client = Recorder()
        world.subscribe(client, sub: "s1")
        let written = DispatchSemaphore(value: 0)
        client.onSend = { written.signal() }
        world.store.send("a", .int(1))
        #expect(await offPool { written.wait(timeout: .now() + hangGuard) } == .success)
        #expect(client.events.last?["kind"] == .string("delta"))
        #expect(client.events.last?["at"] == .string(NodeWire.dateText(LiveWorld.fixed)))
    }

    // MARK: a slow client

    @Test func aConnectionThatCantWriteGetsOneFoldedDelta() async throws {
        let world = LiveWorld()
        world.store.send("a", .int(1))
        world.store.send("b", .int(1))
        try await world.settled(2)
        let client = Recorder()
        world.subscribe(client, sub: "s1")
        client.writable = false
        world.store.send("a", .int(2))
        world.store.send("b", .int(3))
        try await world.settled(4)
        world.store.send("a", .int(4))
        try await world.settled(5)
        #expect(client.events.count == 1, "nothing is written while the connection can't take it: \(client.events)")

        client.drain()
        try await client.waitFor(events: 2)
        let delta = client.events[1]
        #expect(delta["prev"] == .int(2) && delta["seq"] == .int(5))
        #expect(delta["changes"] == .array([.object(["id": .string("b"), "value": .int(3)]),
                                            .object(["id": .string("a"), "value": .int(4)])]), "\(delta)")
        try await world.settled(5)
        #expect(client.events.count == 2)
    }

    @Test func aFoldedDeltaCoversItsRange() async throws {
        let world = LiveWorld()
        for id in ["before", "a", "b"] { world.store.send(id, .int(0)) }
        try await world.settled(3)
        let client = Recorder()
        world.subscribe(client, sub: "s1")
        client.writable = false
        world.store.send("a", .int(1))      // 4
        world.store.send("b", nil)          // 5
        world.store.send("c", .int(1))      // 6
        try await world.settled(6)
        world.store.send("c", nil)          // 7
        world.store.send("a", .int(2))      // 8
        try await world.settled(8)
        client.drain()
        try await client.waitFor(events: 2)

        let delta = client.events[1]
        #expect(delta["prev"] == .int(3) && delta["seq"] == .int(8))
        // Every id that changed in (3, 8], once, as it is now; `before`, untouched since 3, isn't in it.
        let changes = try #require(delta["changes"]?.array)
        #expect(changes == [.object(["id": .string("b"), "value": .null]), .object(["id": .string("c"), "value": .null]),
                            .object(["id": .string("a"), "value": .int(2)])], "\(changes)")
    }

    @Test func nothingIsDroppedForASlowClient() async throws {
        let world = LiveWorld()
        for index in 0..<20 { world.store.send("e\(index)", .int(-1)) }
        try await world.settled(20)
        let client = Recorder()
        world.subscribe(client, sub: "s1")
        var rows = LiveWorld.rows(of: client.events[0])

        // A few hundred changes and removals while it can't write, in batches: one folded delta brings it to now.
        client.writable = false
        var generator = SeededGenerator(seed: 7)
        for round in 0..<300 {
            let id = "e\(Int.random(in: 0..<30, using: &generator))"
            world.store.send(id, Bool.random(using: &generator) ? .int(round) : nil)
            if round % 50 == 49 { _ = try await world.mark() }
        }
        let caught = try await world.mark()
        client.drain()
        #expect(await eventually { client.events.last?["seq"] == .int(caught) })
        #expect(client.events.count == 2)
        LiveWorld.apply(client.events[1], to: &rows)
        #expect(rows == world.queue.sync { world.stream.entries.mapValues(\.value) })

        // More removals than the stream remembers while it can't write: it gets the stream whole, as a snapshot.
        client.writable = false
        for index in 0..<300 { world.store.send("gone\(index)", .int(index)) }
        _ = try await world.mark()
        for index in 0..<300 { world.store.send("gone\(index)", nil) }
        let now = try await world.mark()
        client.drain()
        #expect(await eventually { client.events.last?["seq"] == .int(now) })
        let last = try #require(client.events.last)
        #expect(last["kind"] == .string("snapshot"), "\(last)")
        #expect(LiveWorld.rows(of: last) == world.queue.sync { world.stream.entries.mapValues(\.value) })
    }

    // MARK: connections

    @Test func twoClientsSeeTheSameSeq() async throws {
        let world = LiveWorld()
        world.store.send("a", .int(1))
        try await world.settled(1)
        let first = Recorder(), second = Recorder()
        world.subscribe(first, sub: "mine")
        world.store.send("a", .int(2))
        try await world.settled(2)
        world.subscribe(second, sub: "theirs")
        world.store.send("b", .int(1))
        try await first.waitFor(events: 3)
        try await second.waitFor(events: 2)
        #expect(first.events.map { $0["seq"] } == [.int(1), .int(2), .int(3)])
        #expect(second.events.map { $0["seq"] } == [.int(2), .int(3)])
        #expect(first.events[2]["changes"] == second.events[1]["changes"])
        #expect(first.events[2]["sub"] == .string("mine") && second.events[1]["sub"] == .string("theirs"))
    }

    @Test func subscribingAgainUnderALiveSubReplacesIt() async throws {
        let world = LiveWorld()
        let leads = Changes<NodeWire.Value>()
        let leadStream = LiveStream(collection: "leads")
        world.queue.sync {
            world.hub.add(collection: "leads", leadStream)
            world.hub.follow(leads, into: leadStream) { $0 }
        }
        let client = Recorder()
        world.subscribe(client, sub: "s1")
        world.subscribe(client, id: "2", sub: "s1", collection: "leads")
        #expect(client.messages.count == 4)
        #expect(client.events[1]["collection"] == .string("leads"))

        world.store.send("thing", .int(1))
        try await world.settled(1)
        leads.send("lead", .int(1))
        try await client.waitFor(events: 3)
        #expect(client.events[2]["changes"] == .array([.object(["id": .string("lead"), "value": .int(1)])]), "\(client.events)")
        #expect(client.events.allSatisfy { $0["changes"]?.array?.first?["id"] != .string("thing") })
    }

    @Test func unsubscribeStopsTheEvents() async throws {
        let world = LiveWorld()
        let client = Recorder()
        world.subscribe(client, sub: "s1")
        world.queue.sync {
            _ = world.hub.handle(NodeWire.Request(id: "9", kind: "unsubscribe", args: ["sub": .string("s1")]), on: client, rights: .read)
        }
        #expect(client.messages.last == .object(["v": .int(1), "re": .string("9"), "ok": .bool(true), "result": .object([:])]))
        world.store.send("a", .int(1))
        try await world.settled(1)
        // A marker on a second client, subscribed after: once its delta is out, any for the first would have been.
        let marker = Recorder()
        world.subscribe(marker, sub: "m")
        world.store.send("b", .int(1))
        try await marker.waitFor(events: 2)
        #expect(client.events.count == 1, "\(client.events)")
    }

    @Test func aClosedConnectionIsForgotten() async throws {
        let world = LiveWorld()
        let client = Recorder()
        world.subscribe(client, sub: "s1")
        #expect(world.queue.sync { world.hub.connectionCount } == 1)
        world.hub.closed(client)
        #expect(await eventually { world.queue.sync { world.hub.connectionCount } == 0 })
        #expect(client.onWritable == nil, "the hub lets go of the transport's drain")
        let marker = Recorder()
        world.subscribe(marker, sub: "m")
        world.store.send("a", .int(1))
        try await marker.waitFor(events: 2)
        #expect(client.events.count == 1)
    }

    @Test func aConnectionWithoutReadIsRefused() {
        let world = LiveWorld()
        let client = Recorder()
        world.subscribe(client, sub: "s1", rights: .draft)
        #expect(client.messages.count == 1)
        #expect(client.messages[0]["ok"] == .bool(false))
        #expect(client.messages[0]["error"]?["code"] == .string(NodeWire.Code.voice.rawValue))
        #expect(client.events.isEmpty)
    }

    @Test func anUnknownCollectionIsBadArgs() {
        let world = LiveWorld()
        let client = Recorder()
        let asks: [[String: NodeWire.Value]] = [
            ["sub": .string("s1"), "collection": .string("nope")],
            ["sub": .string("s1"), "collection": .string("chat"), "key": .string("local:pts/1")],
            ["sub": .string("s1")],
            ["collection": .string("things")],
            ["sub": .string("a b"), "collection": .string("things")],
            ["sub": .string(String(repeating: "s", count: 33)), "collection": .string("things")],
            ["sub": .string(""), "collection": .string("things")],
            ["sub": .int(1), "collection": .string("things")],
        ]
        for (index, args) in asks.enumerated() {
            world.queue.sync {
                #expect(world.hub.handle(NodeWire.Request(id: "\(index)", kind: "subscribe", args: args), on: client, rights: .read))
            }
            let reply = client.messages.last
            #expect(reply?["re"] == .string("\(index)") && reply?["error"]?["code"] == .string("bad-args"), "\(args): \(String(describing: reply))")
        }
        #expect(client.events.isEmpty)
        // A kind that isn't the hub's is left to the caller.
        #expect(world.queue.sync { world.hub.handle(NodeWire.Request(id: "x", kind: "status"), on: client, rights: .read) } == false)
    }

    @Test func theSessionsSnapshotIsEverySessionOnce() async throws {
        let queue = DispatchQueue(label: "engine")
        let hub = LiveHub(queue: queue, epoch: "e1")
        let sessions = Changes<Session>()
        let stream = LiveStream(collection: "sessions", order: .field("terminal"))
        queue.sync {
            hub.add(collection: "sessions", stream)
            hub.follow(sessions, into: stream) { Requests.value($0) }
        }
        var hosted = LiveWorld.session("pts/9")
        hosted.hostID = UUID()
        let all = [LiveWorld.session("pts/2"), hosted, LiveWorld.session("pts/10")]
        for session in all { sessions.send(NodeSessions.id(of: session), session) }
        hosted.status = .done
        sessions.send(NodeSessions.id(of: hosted), hosted)
        // The store folds what a subscriber hasn't taken yet (`Changes`), so the stream is waited on for what it holds.
        #expect(await eventually {
            queue.sync { stream.entries.count == 3 && stream.entries[NodeSessions.id(of: hosted)]?.value["status"] == .string("done") }
        })

        let client = Recorder()
        queue.sync {
            _ = hub.handle(NodeWire.Request(id: "1", kind: "subscribe", args: ["sub": .string("s"), "collection": .string("sessions")]),
                           on: client, rights: .read)
        }
        let entries = try #require(client.events.first?["entries"]?.array)
        #expect(entries.compactMap { $0["id"]?.string } == ["local:pts/10", "local:pts/2", NodeSessions.id(of: hosted)])
        #expect(entries.compactMap { $0["value"]?["terminal"]?.string } == ["pts/10", "pts/2", "pts/9"])
        #expect(entries[2]["value"]?["status"] == .string("done"))
    }

    // MARK: the WebSocket's side

    @Test func aWebConnectionsTextIsARequest() async throws {
        let world = LiveWorld()
        let client = Recorder()
        world.hub.opened(client, rights: [.read, .draft])
        world.hub.text(Data(#"{"v":1,"id":"1","kind":"subscribe","args":{"sub":"s0","collection":"things"}}"#.utf8), on: client)
        #expect(await eventually { client.messages.count == 2 })
        #expect(client.messages[0]["result"]?["mode"] == .string("snapshot"))
        // A kind the hub doesn't take goes to `others`; with none, it is `unknown-kind`.
        world.hub.text(Data(#"{"v":1,"id":"2","kind":"status"}"#.utf8), on: client)
        #expect(await eventually { client.messages.count == 3 })
        #expect(client.messages[2]["error"]?["code"] == .string("unknown-kind"))
        // A newer protocol is `version`, then the close.
        world.hub.text(Data(#"{"v":2,"id":"3","kind":"status"}"#.utf8), on: client)
        #expect(await eventually { client.closes == ["version"] })
        #expect(client.messages.last?["error"]?["code"] == .string("version"))
    }

    @Test func aTextThatIsntARequestCloses() async {
        let world = LiveWorld()
        for (text, code) in [("[1,2]", "not-object"), ("nonsense", "not-object"), (#"{"v":1,"kind":"status"}"#, "not-request")] {
            let client = Recorder()
            world.hub.opened(client, rights: .read)
            world.hub.text(Data(text.utf8), on: client)
            #expect(await eventually { client.closes == [code] }, "\(text): \(client.closes)")
            #expect(await eventually { world.queue.sync { world.hub.connectionCount } == 0 })
        }
    }
}

// MARK: - The world the hub's tests share

/// A hub on an engine queue of its own, with one stream, `things`, following one store.
struct LiveWorld {
    static let fixed = Date(timeIntervalSince1970: 1_800_000_000.25)

    let queue = DispatchQueue(label: "engine")
    let hub: LiveHub
    let store = CountingChanges()
    let stream: LiveStream

    init(epoch: String = "epoch-1", removalsKept: Int = LiveStream.removalsKept) {
        hub = LiveHub(queue: queue, epoch: epoch, now: { LiveWorld.fixed })
        stream = LiveStream(collection: "things", removalsKept: removalsKept, now: { LiveWorld.fixed })
        queue.sync { [hub, stream, store] in
            hub.add(collection: "things", stream)
            hub.follow(store.changes, into: stream) { $0 }
        }
    }

    /// Waits for everything the store sent so far to be in the stream (a marker sent after it, in), and returns the
    /// stream's `seq` then. The store folds what its subscriber hasn't taken yet, so `seq` can be under the count sent.
    func mark() async throws -> Int {
        let marked = NodeWire.Value.string(UUID().uuidString)
        store.send("~mark", marked)
        try #require(await eventually { queue.sync { stream.entries["~mark"]?.value } == marked }, "the marker never reached the stream")
        return queue.sync { stream.seq }
    }

    /// Waits for the stream to reach `seq`: for a test whose changes the store can't fold (each id waited on before it
    /// changes again).
    func settled(_ seq: Int) async throws {
        try #require(await eventually { queue.sync { stream.seq } >= seq }, "the stream never reached \(seq)")
        queue.sync {}
    }

    func subscribe(_ client: Recorder, id: String = "1", sub: String, collection: String = "things",
                   since: NodeWire.Value? = nil, rights: LiveRights = .read) {
        var args: [String: NodeWire.Value] = ["sub": .string(sub), "collection": .string(collection)]
        if let since { args["since"] = since }
        queue.sync { _ = hub.handle(NodeWire.Request(id: id, kind: "subscribe", args: args), on: client, rights: rights) }
    }

    /// A snapshot's rows, by id.
    static func rows(of snapshot: NodeWire.Value) -> [String: NodeWire.Value] {
        var rows: [String: NodeWire.Value] = [:]
        for entry in snapshot["entries"]?.array ?? [] { if let id = entry["id"]?.string, let value = entry["value"] { rows[id] = value } }
        return rows
    }

    /// `delta` applied to `rows`, as the contract's client applies one.
    static func apply(_ delta: NodeWire.Value, to rows: inout [String: NodeWire.Value]) {
        for change in delta["changes"]?.array ?? [] {
            guard let id = change["id"]?.string else { continue }
            rows[id] = change["value"] == .null ? nil : change["value"]
        }
    }

    static func session(_ tty: String) -> Session {
        Session(tty: tty, agent: .claude, pid: 100, startedAt: Date(timeIntervalSince1970: 1_700_000_000), cwd: "/work/\(tty)",
                project: "p", task: nil, status: .working, statusSince: Date(timeIntervalSince1970: 1_700_000_100), detail: nil,
                hasHooks: true, inTerminalApp: false)
    }
}

/// A store of JSON values that counts the changes it sent (an equal value isn't one), so a test knows the `seq` its
/// stream reaches.
final class CountingChanges: @unchecked Sendable {
    let changes = Changes<NodeWire.Value>()
    private let count = Locked(0)

    var sent: Int { count.value }

    func send(_ id: String, _ value: NodeWire.Value?) {
        if changes.values[id] != value { count.mutate { $0 += 1 } }
        changes.send(id, value)
    }
}

/// A `LiveTransport` that keeps what it was sent, and can be told it can't write until `drain()`.
final class Recorder: LiveTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Data] = []
    private var canWrite = true
    private var drained: (() -> Void)?
    private var closed: [String] = []
    private var sendHook: (() -> Void)?

    func send(_ message: Data) {
        let hook = lock.withLock { () -> (() -> Void)? in
            sent.append(message)
            return sendHook
        }
        hook?()
    }

    var writable: Bool {
        get { lock.withLock { canWrite } }
        set { lock.withLock { canWrite = newValue } }
    }

    var onWritable: (() -> Void)? {
        get { lock.withLock { drained } }
        set { lock.withLock { drained = newValue } }
    }

    var onSend: (() -> Void)? {
        get { lock.withLock { sendHook } }
        set { lock.withLock { sendHook = newValue } }
    }

    func close(code: String, reason: String) {
        let hook = lock.withLock { () -> (() -> Void)? in
            closed.append(code)
            return closeHook
        }
        hook?()
    }

    private var closeHook: (() -> Void)?
    /// Called at each close (tests that check what came before it).
    var onClose: (() -> Void)? {
        get { lock.withLock { closeHook } }
        set { lock.withLock { closeHook = newValue } }
    }

    var closes: [String] { lock.withLock { closed } }

    /// Its buffer drained: it can write again, and says so.
    func drain() {
        writable = true
        onWritable?()
    }

    /// Everything sent, each as JSON; a message that isn't one JSON object (no newline in it) fails the test.
    var messages: [NodeWire.Value] {
        lock.withLock { sent }.map { data in
            #expect(!data.contains(UInt8(ascii: "\n")), "a message with a newline in it")
            return NodeWire.decode(NodeWire.Value.self, data) ?? .string("not JSON: \(String(decoding: data, as: UTF8.self))")
        }
    }

    /// The events: snapshots and deltas.
    var events: [NodeWire.Value] { messages.filter { $0["kind"] == .string("snapshot") || $0["kind"] == .string("delta") } }

    func waitFor(events count: Int) async throws {
        try #require(await eventually { self.events.count >= count }, "\(count) events never came: \(events)")
    }
}

/// The same numbers on every run (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
