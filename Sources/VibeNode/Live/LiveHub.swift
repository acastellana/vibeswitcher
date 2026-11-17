import Foundation

/// The live protocol's hub (the live plan's B1 and B3, the live wire contract's §3 and §4): the stores' streams, and
/// every connection's subscriptions to them, on whatever carries a line of JSON (`LiveTransport`: the server's Unix
/// socket, a WebSocket).
///
/// **No timer on the path** (the plan's LW-D14, "Seamless"): a stream is fed from its store's `Changes` on the engine's
/// queue, and the hub writes each subscriber's delta in the same turn as the change lands in the stream. The only wait
/// is a connection's own: while its transport can't take bytes (`writable` false) nothing is written to it, and when it
/// drains (`onWritable`) it gets one delta from the `seq` it was sent last to the stream's now, every entry as it is
/// now. A slow client is late, never wrong; nothing is queued for it but that `seq`, so a stalled client costs the hub
/// nothing (no buffer grows with it). A connection so late that its stream forgot a removal after its `seq` gets a
/// snapshot instead.
///
/// **Order** (the contract's §4, Review Focus 4): per subscription, the hub keeps the `seq` of the last event it wrote;
/// each delta's `prev` is that `seq`, and its `seq` the stream's. The reply to `subscribe` is written before the
/// subscription's first event, on the same transport.
///
/// On `queue` (the engine's): `handle`, `add` and `follow` are called there; the `WebSocketHandler` calls and a
/// transport's `onWritable` may come from any thread and are taken onto it, in the order they came.
public final class LiveHub: WebSocketHandler, @unchecked Sendable {
    public let queue: DispatchQueue
    /// The server's epoch (`Requests.epoch`): every `seq` the hub writes is scoped by it.
    public let epoch: String
    /// What a WebSocket's request of a kind that isn't the hub's (`subscribe`, `unsubscribe`) becomes: the integration's
    /// (I1: the rights, then `Requests`). It answers on the transport itself. None: `unknown-kind`. On `queue`.
    public var others: ((NodeWire.Request, LiveTransport, LiveRights) -> Void)?

    private let now: @Sendable () -> Date
    private let onQueue = DispatchSpecificKey<ObjectIdentifier>()
    private var streams: [String: LiveStream] = [:]
    private var follows: [Subscription] = []
    private var connections: [ObjectIdentifier: Connection] = [:]

    /// One connection: its transport, what it may do, and its subscriptions by the client's name for each.
    private final class Connection {
        let transport: LiveTransport
        var rights: LiveRights
        var subs: [String: Sub] = [:]

        init(transport: LiveTransport, rights: LiveRights) {
            self.transport = transport
            self.rights = rights
        }
    }

    /// One subscription: its stream, and the `seq` of the last event written for it.
    private struct Sub {
        var collection: String
        var sent: Int
    }

    /// `queue`: the engine's, where the stores send. `epoch`: the server's. `now`: when a change is taken (a delta's
    /// `at`); tests give a fixed one.
    public init(queue: DispatchQueue, epoch: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.queue = queue
        self.epoch = epoch
        self.now = now
        queue.setSpecific(key: onQueue, value: ObjectIdentifier(self))
    }

    // MARK: Streams

    /// `stream` serves `collection` from now on (one replacing another under the same name). On `queue`.
    public func add(collection: String, _ stream: LiveStream) {
        dispatchPrecondition(condition: .onQueue(queue))
        streams[collection]?.onChange = nil
        streams[collection] = stream
        stream.onChange = { [weak self, weak stream] in
            guard let self, let stream else { return }
            self.changed(stream)
        }
    }

    /// `stream` follows `changes`: what the store holds now, then each batch it sends, as `value` makes each entry
    /// (nil: the entry is gone), on `queue`, one `seq` a change and the subscribers told once a batch. Kept until the
    /// hub goes. On `queue`.
    public func follow<T>(_ changes: Changes<T>, into stream: LiveStream, value: @escaping (T) -> NodeWire.Value?) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Subscribed first, then what it holds read: a send in between is in both, and the second is equal (nothing).
        follows.append(changes.subscribe(on: queue) { [weak stream] batch in
            stream?.apply(batch.map { (id: $0.id, value: $0.value.flatMap(value)) })
        })
        stream.apply(changes.values.sorted { $0.key < $1.key }.map { (id: $0.key, value: value($0.value)) })
    }

    /// The `seq` `collection`'s stream is at (an action's `applied`, the contract's §8); 0 for none. On `queue`.
    public func seq(of collection: String) -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return streams[collection]?.seq ?? 0
    }

    /// How many connections the hub holds (one with a subscription, or opened by the listener). On `queue`.
    public var connectionCount: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return connections.count
    }

    // MARK: Requests

    /// Takes `request` when it is the hub's (`subscribe`, `unsubscribe`): writes its reply on `transport`, then, for a
    /// subscription, its first event, and returns true. False, writing nothing, for any other kind: the caller answers
    /// it. On `queue`.
    ///
    /// The hub writes the reply itself, not its caller, so the subscription's first event can't reach the transport
    /// before it (the contract's §3).
    public func handle(_ request: NodeWire.Request, on transport: LiveTransport, rights: LiveRights) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        switch request.kind {
        case "subscribe": subscribe(request, on: transport, rights: rights)
        case "unsubscribe": unsubscribe(request, on: transport)
        default: return false
        }
        return true
    }

    private func subscribe(_ request: NodeWire.Request, on transport: LiveTransport, rights: LiveRights) {
        let ask: LiveSubscribe
        switch LiveSubscribe.parse(request.args) {
        case .failure(let failure): return reply(.init(re: request.id, error: failure), on: transport)
        case .success(let parsed): ask = parsed
        }
        guard rights.contains(.read) else {
            return reply(.init(re: request.id, error: .init(.voice, "this connection may not read")), on: transport)
        }
        guard let stream = streams[ask.collection] else {
            return reply(.init(re: request.id, error: .init(.badArgs, "no such collection: \(ask.collection)")), on: transport)
        }
        let connection = connection(for: transport, rights: rights)
        // A resume (the contract's §4, B3): the same epoch, and the stream can still say what changed after the client's
        // `seq` (not ahead of it, not before a removal it forgot). Then no snapshot: one delta from that `seq`, or
        // nothing until a change when the client is current. Anything else is a snapshot, which the client reconciles.
        let resume = ask.since.flatMap { since in since.epoch == epoch ? stream.changes(since: since.seq) : nil }
        transport.send(NodeWire.message(NodeWire.Reply(re: request.id, result: .object([
            "sub": .string(ask.sub), "mode": .string(resume == nil ? "snapshot" : "resume"),
        ]))))
        if let resume {
            connection.subs[ask.sub] = Sub(collection: ask.collection, sent: resume.prev)
            if transport.writable { push(ask.sub, of: connection) }
        } else {
            connection.subs[ask.sub] = Sub(collection: ask.collection, sent: stream.seq)
            transport.send(snapshot(of: stream, sub: ask.sub))
        }
    }

    private func unsubscribe(_ request: NodeWire.Request, on transport: LiveTransport) {
        guard let sub = request.args?["sub"]?.string, LiveSubscribe.isSub(sub) else {
            return reply(.init(re: request.id, error: .init(.badArgs, "unsubscribe needs a sub")), on: transport)
        }
        connections[ObjectIdentifier(transport)]?.subs[sub] = nil
        transport.send(NodeWire.message(NodeWire.Reply(re: request.id, result: .object([:]))))
    }

    private func reply(_ reply: NodeWire.Reply, on transport: LiveTransport) {
        transport.send(NodeWire.message(reply))
    }

    /// The hub's record of `transport`, made on its first subscription (the Unix socket's) or when the listener opens
    /// it (a WebSocket's), with its drain told to the hub.
    private func connection(for transport: LiveTransport, rights: LiveRights) -> Connection {
        let key = ObjectIdentifier(transport)
        if let known = connections[key] {
            known.rights = rights
            return known
        }
        let connection = Connection(transport: transport, rights: rights)
        connections[key] = connection
        transport.onWritable = { [weak self, weak transport] in
            guard let self, let transport else { return }
            self.perform { self.flush(ObjectIdentifier(transport)) }
        }
        return connection
    }

    // MARK: Events

    /// A stream changed: every subscriber that can write gets its delta now; one that can't, when it drains.
    private func changed(_ stream: LiveStream) {
        for connection in connections.values where connection.transport.writable {
            for (name, sub) in connection.subs where sub.collection == stream.collection && sub.sent < stream.seq {
                guard connection.transport.writable else { break }
                push(name, of: connection)
            }
        }
    }

    /// Everything `transport`'s subscriptions are behind on, while it can write.
    private func flush(_ key: ObjectIdentifier) {
        guard let connection = connections[key] else { return }
        for name in connection.subs.keys.sorted() {
            guard connection.transport.writable else { return }
            push(name, of: connection)
        }
    }

    /// One event that brings subscription `name` to its stream's `seq`: a delta from the `seq` it was sent last, or a
    /// snapshot when the stream no longer remembers what changed after it. Nothing when it is current.
    private func push(_ name: String, of connection: Connection) {
        guard var sub = connection.subs[name], let stream = streams[sub.collection], sub.sent != stream.seq else { return }
        if let range = stream.changes(since: sub.sent) {
            connection.transport.send(NodeWire.message(NodeWire.Delta(sub: name, prev: range.prev, seq: range.seq,
                                                                      at: stream.changedAt ?? now(), changes: range.changes)))
        } else {
            connection.transport.send(snapshot(of: stream, sub: name))
        }
        sub.sent = stream.seq
        connection.subs[name] = sub
    }

    private func snapshot(of stream: LiveStream, sub: String) -> Data {
        let (seq, entries) = stream.snapshot()
        return NodeWire.message(NodeWire.Snapshot(sub: sub, collection: stream.collection, epoch: epoch, seq: seq, entries: entries))
    }

    /// `work` on `queue`: at once when this is it, else next, after what was asked before.
    private func perform(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: onQueue) == ObjectIdentifier(self) { work() } else { queue.async(execute: work) }
    }

    // MARK: WebSocketHandler (the listener's, from any thread)

    public func opened(_ transport: LiveTransport, rights: LiveRights) {
        perform { _ = self.connection(for: transport, rights: rights) }
    }

    /// One text message of an admitted WebSocket: a request. Not a JSON object: `bye` `not-object` and the close; not
    /// a request: `not-request`; a newer `v`: the `version` error, then `bye`. The hub's kinds are taken here; the rest
    /// go to `others`.
    public func text(_ message: Data, on transport: LiveTransport) {
        perform { self.take(message, on: transport) }
    }

    /// The terminal's frames (slice 4); nothing yet.
    public func binary(_ message: Data, on transport: LiveTransport) {}

    /// The connection is gone: its subscriptions with it.
    public func closed(_ transport: LiveTransport) {
        perform {
            guard let connection = self.connections.removeValue(forKey: ObjectIdentifier(transport)) else { return }
            connection.transport.onWritable = nil
        }
    }

    private func take(_ message: Data, on transport: LiveTransport) {
        guard let connection = connections[ObjectIdentifier(transport)] else { return }
        guard NodeWire.isObject(message) else { return refuse(transport, code: "not-object", reason: "a message that isn't a JSON object") }
        guard let request = NodeWire.decode(NodeWire.Request.self, message) else {
            return refuse(transport, code: "not-request", reason: "a message that isn't a request")
        }
        guard request.v <= NodeWire.version else {
            transport.send(NodeWire.message(NodeWire.Reply(re: request.id, error: .init(.version, "this server speaks v\(NodeWire.version)"))))
            return refuse(transport, code: "version", reason: "a newer protocol than the server's")
        }
        if handle(request, on: transport, rights: connection.rights) { return }
        if let others { return others(request, transport, connection.rights) }
        transport.send(NodeWire.message(NodeWire.Reply(re: request.id, error: .init(.unknownKind, "this server doesn't take \(request.kind)"))))
        if request.must == true { refuse(transport, code: "must", reason: "a kind this server doesn't take, which the client must have") }
    }

    private func refuse(_ transport: LiveTransport, code: String, reason: String) {
        connections[ObjectIdentifier(transport)]?.transport.onWritable = nil
        connections[ObjectIdentifier(transport)] = nil
        transport.close(code: code, reason: reason)
    }
}
