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
    /// What a WebSocket's request of a kind that isn't the hub's (`subscribe`, `unsubscribe`, `chat.page`) becomes: the
    /// integration's (I1: the rights, then `Requests`). It answers on the transport itself. None: `unknown-kind`. On
    /// `queue`.
    public var others: ((NodeWire.Request, LiveTransport, LiveRights) -> Void)?
    /// The terminals (slice 4; `TerminalRelay.Mode`: the user's node's watched, a scratch server's typed into):
    /// `term.open` and `term.close` are the hub's while it has one, and so are the binary frames. None: neither. Set
    /// on `queue`, before the listener starts.
    public var terminals: TerminalRelay?
    /// The sessions' chats (slice 2, B4): a `chat` subscription's stream, opened for it, and `chat.page`. None: `chat`
    /// is no collection here. On `queue`.
    public var chats: ChatStore?

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

    /// One subscription: its stream, and the `seq` of the last event written for it. A chat's names its session
    /// (`chat`), is `ready` once its first event was written (its stream is read first), and carries how many items a
    /// snapshot of it holds.
    private struct Sub {
        var collection: String
        var sent: Int
        var chat: String? = nil
        var ready = true
        var limit = ChatStream.snapshotItems
        var serial = 0
    }

    /// Tells one chat subscription from the one that replaced it under the same name.
    private var serials = 0
    /// The chat streams the hub was told of, by session: their changes reach their subscribers.
    private var chatStreams: [String: ChatStream] = [:]

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

    /// The kinds `handle` takes on any server: the Unix socket hands these, and only these, to the hub. A server with
    /// terminals takes `NodeLive.terminalKinds` here too (a page's only).
    public static let kinds: Set<String> = ["subscribe", "unsubscribe", "chat.page", "chat.image", "session.usage"]

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
        case "term.open" where terminals != nil: terminals?.open(request, on: transport, rights: rights)
        case "term.close" where terminals != nil: terminals?.close(request, on: transport)
        case "chat.page": page(request, on: transport, rights: rights)
        case "chat.image": chatRead(request, on: transport, rights: rights)
        case "session.usage": chatRead(request, on: transport, rights: rights)
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
        if ask.collection == "chat", let chats { return subscribeChat(ask, request, on: transport, rights: rights, chats: chats) }
        guard let stream = streams[ask.collection] else {
            return reply(.init(re: request.id, error: .init(.badArgs, "no such collection: \(ask.collection)")), on: transport)
        }
        let connection = connection(for: transport, rights: rights)
        release(connection.subs[ask.sub])
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
        release(connections[ObjectIdentifier(transport)]?.subs.removeValue(forKey: sub))
        transport.send(NodeWire.message(NodeWire.Reply(re: request.id, result: .object([:]))))
    }

    /// A subscription that ends (replaced, unsubscribed, its connection gone): a chat's follower leaves its stream.
    private func release(_ sub: Sub?) {
        if let session = sub?.chat { chats?.unfollow(session) }
    }

    // MARK: Chats

    /// A `chat` subscription (the contract's §3, §4 and §6): the session's stream opened (or `gone`), followed, and once
    /// it is read, the reply and the first event: a delta from the client's `seq` when the stream still has what changed
    /// after it (`resume`), else the item `after` and what followed it (`tail`), else the newest items (`snapshot`).
    private func subscribeChat(_ ask: LiveSubscribe, _ request: NodeWire.Request, on transport: LiveTransport, rights: LiveRights,
                               chats: ChatStore) {
        guard let session = ask.key else {
            return reply(.init(re: request.id, error: .init(.badArgs, "a chat subscription needs the session's id as its key")), on: transport)
        }
        let stream: ChatStream
        switch chats.open(session) {
        case .refused(let failure): return reply(.init(re: request.id, error: failure), on: transport)
        case .opened(let opened): stream = opened
        }
        attach(stream)
        let connection = connection(for: transport, rights: rights)
        release(connection.subs[ask.sub])
        chats.follow(session)
        serials += 1
        let serial = serials
        let limit = min(max(ask.limit ?? ChatStream.snapshotItems, 1), ChatStream.mostItems)
        connection.subs[ask.sub] = Sub(collection: "chat", sent: stream.seq, chat: session, ready: false, limit: limit, serial: serial)
        let key = ObjectIdentifier(transport)
        stream.whenLoaded { [weak self] in
            guard let self, let connection = self.connections[key], var sub = connection.subs[ask.sub], sub.serial == serial else { return }
            let resume = ask.since.flatMap { since in since.epoch == self.epoch ? stream.changes(since: since.seq) : nil }
            let tail = resume == nil ? ask.after.flatMap { stream.tail(after: $0) } : nil
            let mode = resume != nil ? "resume" : tail != nil ? "tail" : "snapshot"
            transport.send(NodeWire.message(NodeWire.Reply(re: request.id, result: .object(["sub": .string(ask.sub), "mode": .string(mode)]))))
            sub.ready = true
            if let resume {
                sub.sent = resume.prev
                connection.subs[ask.sub] = sub
                if transport.writable { self.push(ask.sub, of: connection) }
                return
            }
            let shown = tail ?? stream.snapshot(limit: limit)
            sub.sent = stream.seq
            connection.subs[ask.sub] = sub
            transport.send(NodeWire.message(NodeWire.chatSnapshot(sub: ask.sub, key: session, epoch: self.epoch, seq: stream.seq,
                                                                  after: tail == nil ? nil : ask.after, more: shown.more, items: shown.items)))
        }
    }

    /// The hub hears `stream`'s changes from now on (once a stream: the store hands the same one while it holds it).
    private func attach(_ stream: ChatStream) {
        guard chatStreams[stream.session] !== stream else { return }
        chatStreams[stream.session]?.onChange = nil
        chatStreams[stream.session] = stream
        stream.onChange = { [weak self, weak stream] in
            guard let self, let stream else { return }
            self.changed(stream)
        }
    }

    /// `chat.image` and `session.usage` (`ChatReads.swift`): reads of a session's own transcript beside its chat, with
    /// no place in any stream's sequence.
    private func chatRead(_ request: NodeWire.Request, on transport: LiveTransport, rights: LiveRights) {
        guard rights.contains(.read) else {
            return reply(.init(re: request.id, error: .init(.voice, "this connection may not read")), on: transport)
        }
        guard let chats else { return reply(.init(re: request.id, error: .init(.unknownKind, "this server has no chats")), on: transport) }
        guard let session = request.args?["session"]?.string, !session.isEmpty else {
            return reply(.init(re: request.id, error: .init(.badArgs, "\(request.kind) needs a session")), on: transport)
        }
        let answer: (ChatStore.Read) -> Void = { [weak self] read in
            switch read {
            case .refused(let failure): self?.reply(.init(re: request.id, error: failure), on: transport)
            case .value(let value): transport.send(NodeWire.message(NodeWire.Reply(re: request.id, result: value)))
            }
        }
        if request.kind == "session.usage" { return chats.usage(session, reply: answer) }
        guard let id = request.args?["id"]?.string, !id.isEmpty, id.utf8.count <= 200 else {
            return reply(.init(re: request.id, error: .init(.badArgs, "chat.image needs an image's id")), on: transport)
        }
        chats.image(session, id: id, offset: request.args?["offset"]?.int ?? 0, reply: answer)
    }

    /// `chat.page` (the contract's §6): the items just before `before`, oldest first, and whether more exist before them;
    /// a read with no place in the stream's sequence.
    private func page(_ request: NodeWire.Request, on transport: LiveTransport, rights: LiveRights) {
        guard rights.contains(.read) else {
            return reply(.init(re: request.id, error: .init(.voice, "this connection may not read")), on: transport)
        }
        guard let chats else { return reply(.init(re: request.id, error: .init(.unknownKind, "this server has no chats")), on: transport) }
        guard let session = request.args?["session"]?.string, let before = request.args?["before"]?.string else {
            return reply(.init(re: request.id, error: .init(.badArgs, "chat.page needs a session and an item to page before")), on: transport)
        }
        let limit = min(max(request.args?["limit"]?.int ?? ChatStream.snapshotItems, 1), ChatStream.mostItems)
        chats.page(session, before: before, limit: limit) { [weak self] result in
            switch result {
            case .refused(let failure): self?.reply(.init(re: request.id, error: failure), on: transport)
            case .page(let items, let more):
                transport.send(NodeWire.message(NodeWire.Reply(re: request.id, result: .object([
                    "items": .array(items), "more": .bool(more),
                ]))))
            }
        }
    }

    /// A chat stream changed: every subscriber that can write gets its delta now; one that can't, when it drains.
    private func changed(_ stream: ChatStream) {
        for connection in connections.values where connection.transport.writable {
            for (name, sub) in connection.subs where sub.chat == stream.session && sub.ready && sub.sent < stream.seq {
                guard connection.transport.writable else { break }
                push(name, of: connection)
            }
        }
    }

    private func reply(_ reply: NodeWire.Reply, on transport: LiveTransport) {
        transport.send(NodeWire.message(reply))
    }

    /// Whether `transport` holds a subscription the hub accepted and still serves (`subscribe`, not since
    /// `unsubscribe`d or ended). On the hub's queue.
    public func subscribes(_ transport: LiveTransport) -> Bool {
        connections[ObjectIdentifier(transport)].map { !$0.subs.isEmpty } ?? false
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
            self.perform {
                self.flush(ObjectIdentifier(transport))
                self.terminals?.drained(transport)
            }
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
        if let session = connection.subs[name]?.chat { return pushChat(name, session: session, of: connection) }
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

    /// The same for a chat: its ops from the `seq` it was sent last, or its newest items when the stream no longer
    /// remembers what changed after it.
    private func pushChat(_ name: String, session: String, of connection: Connection) {
        guard var sub = connection.subs[name], sub.ready, let stream = chatStreams[session], sub.sent != stream.seq else { return }
        if let range = stream.changes(since: sub.sent) {
            connection.transport.send(NodeWire.message(NodeWire.chatDelta(sub: name, prev: range.prev, seq: range.seq,
                                                                          at: stream.changedAt ?? now(), ops: range.ops)))
        } else {
            let shown = stream.snapshot(limit: sub.limit)
            connection.transport.send(NodeWire.message(NodeWire.chatSnapshot(sub: name, key: session, epoch: epoch, seq: stream.seq,
                                                                             after: nil, more: shown.more, items: shown.items)))
        }
        sub.sent = stream.seq
        connection.subs[name] = sub
    }

    private func snapshot(of stream: LiveStream, sub: String) -> Data {
        let (seq, entries) = stream.snapshot()
        return Self.fitted(NodeWire.Snapshot(sub: sub, collection: stream.collection, epoch: epoch, seq: seq, entries: entries))
    }

    /// The headroom a fitted snapshot leaves under the line's limit, for its envelope.
    static let snapshotHeadroom = 16 * 1024

    /// `snapshot` as a message, which fits a line (`NodeWire.maxLine`, the Unix socket's and a WebSocket message's
    /// limit: one past it is never delivered, and its subscriber would ask again for good). When it doesn't, entries
    /// are left out until it does, and it says `truncated` (the architecture review's row 14): a closed card first
    /// (`open` false), the largest first, then any entry, the largest first. The deltas after it go on as ever.
    static func fitted(_ snapshot: NodeWire.Snapshot) -> Data {
        let whole = NodeWire.message(snapshot)
        guard whole.count > NodeWire.maxLine else { return whole }
        let budget = NodeWire.maxLine - snapshotHeadroom
        var sized = snapshot.entries.enumerated().map { (index: $0.offset, entry: $0.element, bytes: NodeWire.message($0.element).count + 1) }
        var total = sized.reduce(0) { $0 + $1.bytes }
        // The order they go in: closed ones before open ones, larger before smaller.
        let going = sized.sorted { one, other in
            let (oneClosed, otherClosed) = (one.entry.value["open"] == .bool(false), other.entry.value["open"] == .bool(false))
            return oneClosed != otherClosed ? oneClosed : one.bytes > other.bytes
        }
        var dropped = Set<Int>()
        for candidate in going where total > budget {
            dropped.insert(candidate.index)
            total -= candidate.bytes
        }
        sized.removeAll { dropped.contains($0.index) }
        var fitted = snapshot
        fitted.entries = sized.map(\.entry)
        fitted.truncated = true
        return NodeWire.message(fitted)
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

    /// The terminal's frames (slice 4): the relay's, on a server that has one; dropped otherwise.
    public func binary(_ message: Data, on transport: LiveTransport) {
        perform {
            guard self.connections[ObjectIdentifier(transport)] != nil else { return }
            self.terminals?.binary(message, on: transport)
        }
    }

    /// The connection is gone: its subscriptions with it.
    public func closed(_ transport: LiveTransport) {
        perform {
            self.terminals?.closed(transport)
            guard let connection = self.connections.removeValue(forKey: ObjectIdentifier(transport)) else { return }
            connection.transport.onWritable = nil
            connection.subs.values.forEach { self.release($0) }
        }
    }

    private func take(_ message: Data, on transport: LiveTransport) {
        guard let connection = connections[ObjectIdentifier(transport)] else { return }
        let request: NodeWire.Request
        switch NodeWire.unwrap(message) {
        case .request(let unwrapped): request = unwrapped
        case .refused(let reply, let code, let reason):
            if let reply { transport.send(NodeWire.message(reply)) }
            return refuse(transport, code: code, reason: reason)
        }
        if handle(request, on: transport, rights: connection.rights) { return }
        if let others { return others(request, transport, connection.rights) }
        let (reply, end) = NodeWire.unknownKind(request)
        transport.send(NodeWire.message(reply))
        if let end { refuse(transport, code: end.code, reason: end.reason) }
    }

    private func refuse(_ transport: LiveTransport, code: String, reason: String) {
        terminals?.closed(transport)
        connections[ObjectIdentifier(transport)]?.subs.values.forEach { release($0) }
        connections[ObjectIdentifier(transport)]?.transport.onWritable = nil
        connections[ObjectIdentifier(transport)] = nil
        transport.close(code: code, reason: reason)
    }
}
