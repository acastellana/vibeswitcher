import Foundation
import VibeCore

/// One session's chat as the live protocol numbers it (the live plan's B4, the live wire contract's §4 and §6): its
/// items in order, the stream's `seq`, one up at each op, and the last `opsKept` ops, which answer a resume with one
/// delta and no journal. On the hub's queue (the engine's): read and changed only there.
///
/// **Ops by difference.** Each new list of items is compared with the one held: an item gone is `remove`; an item whose
/// value differs from the one held only in `text`, the old text a prefix of the new in UTF-16 code units, is `text`
/// with what was appended (`at`: the old length); any other changed item is `set`; new items at the end are `add`. A new
/// item anywhere but the end (which a transcript, appended to, doesn't make) removes what follows the first item out of
/// place and adds it again, in order: a client applying the ops always holds the list the server holds.
///
/// **No `seq` is reused for a session.** A stream starts at the `seq` after the last one its session's stream reached
/// before it was dropped (`ChatStore`), and remembers nothing before it: a client that held the old stream gets a tail
/// or a snapshot, never another stream's ops.
public final class ChatStream: @unchecked Sendable {
    /// How many ops a stream remembers (the contract's §4).
    public static let opsKept = 512
    /// A snapshot's items when the client says none (the contract's §3), and the most it may ask for.
    public static let snapshotItems = 200
    public static let mostItems = 500

    /// One item as the stream holds it: its id, its wire value, and its `text` when it has one (a prompt's, a reply's,
    /// a team message's).
    public struct Item: Equatable, Sendable {
        public var id: String
        public var value: NodeWire.Value
    }

    /// One op as the stream remembers it.
    struct Op {
        var seq: Int
        var value: NodeWire.Value
        /// The item a `text` op appends to (consecutive ones of one item are joined in a delta).
        var textOf: String?
        var at: Int?
        var append: String?
    }

    /// The session's id (the subscription's `key`).
    public let session: String
    public let opsKept: Int
    /// The stream's sequence number: one up at each op.
    public private(set) var seq: Int
    /// Every item now, oldest first.
    public private(set) var items: [Item] = []
    /// Whether the transcript has been read once (before that the stream has no items to say).
    public private(set) var loaded = false
    /// When the newest op was taken.
    public private(set) var changedAt: Date?
    /// The `seq` before the oldest op kept: a resume is answered from it on.
    public private(set) var floor: Int
    private var ops: [Op] = []
    private var index: [String: Int] = [:]
    private var waiting: [() -> Void] = []
    private let now: @Sendable () -> Date
    /// Told after each batch of ops (the hub's).
    var onChange: (() -> Void)?

    /// `start`: the `seq` it starts at, which it remembers nothing before.
    public init(session: String, start: Int = 0, opsKept: Int = ChatStream.opsKept, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        seq = start
        floor = start
        self.opsKept = max(1, opsKept)
        self.now = now
    }

    /// `work` once the stream is loaded: now when it is.
    func whenLoaded(_ work: @escaping () -> Void) {
        if loaded { work() } else { waiting.append(work) }
    }

    /// The items read now: the first list loads the stream (no op, its `seq` stays), each later one is ops by
    /// difference. Whether anything changed.
    @discardableResult
    public func take(_ new: [(id: String, value: NodeWire.Value)]) -> Bool {
        guard loaded else {
            items = new.map { Item(id: $0.id, value: $0.value) }
            reindex()
            loaded = true
            let ready = waiting
            waiting = []
            ready.forEach { $0() }
            return true
        }
        let made = Self.ops(from: items, to: new)
        guard !made.isEmpty else { return false }
        for op in made {
            seq += 1
            var kept = op
            kept.seq = seq
            ops.append(kept)
        }
        if ops.count > opsKept {
            let dropped = ops.count - opsKept
            floor = ops[dropped - 1].seq
            ops.removeFirst(dropped)
        }
        items = new.map { Item(id: $0.id, value: $0.value) }
        reindex()
        changedAt = now()
        onChange?()
        return true
    }

    private func reindex() {
        index = [:]
        for (position, item) in items.enumerated() { index[item.id] = position }
    }

    /// The ops that take `old` to `new`, in order, their `seq` not yet given.
    static func ops(from old: [Item], to new: [(id: String, value: NodeWire.Value)]) -> [Op] {
        var made: [Op] = []
        let newIDs = Set(new.map(\.id))
        for item in old where !newIDs.contains(item.id) {
            made.append(Op(seq: 0, value: .object(["op": .string("remove"), "id": .string(item.id)])))
        }
        let kept = old.filter { newIDs.contains($0.id) }
        var position = 0
        while position < kept.count, position < new.count, new[position].id == kept[position].id {
            let (before, after) = (kept[position].value, new[position].value)
            if before != after {
                if let grown = appended(before, after) {
                    made.append(Op(seq: 0, value: .object(["op": .string("text"), "id": .string(new[position].id), "at": .int(grown.at),
                                                           "append": .string(grown.append)]),
                                   textOf: new[position].id, at: grown.at, append: grown.append))
                } else {
                    made.append(Op(seq: 0, value: .object(["op": .string("set"), "item": after])))
                }
            }
            position += 1
        }
        // Out of place from here: what was held is removed, and the rest added in order.
        for item in kept[position...] { made.append(Op(seq: 0, value: .object(["op": .string("remove"), "id": .string(item.id)]))) }
        for item in new[position...] { made.append(Op(seq: 0, value: .object(["op": .string("add"), "item": item.value]))) }
        return made
    }

    /// What `after` appends to `before`'s text, when that is all that changed: the old text's length in UTF-16 code
    /// units, and the rest. A Swift string never holds half a surrogate pair, so the old text never ends inside one,
    /// and the cut, at its end, never falls inside one in the new text.
    static func appended(_ before: NodeWire.Value, _ after: NodeWire.Value) -> (at: Int, append: String)? {
        guard case .object(var old) = before, case .object(var new) = after,
              case .string(let oldText)? = old.removeValue(forKey: "text"), case .string(let newText)? = new.removeValue(forKey: "text"),
              old == new else { return nil }
        let (oldUnits, newUnits) = (oldText.utf16, newText.utf16)
        guard newUnits.count > oldUnits.count, newUnits.starts(with: oldUnits) else { return nil }
        let cut = newUnits.index(newUnits.startIndex, offsetBy: oldUnits.count)
        guard let rest = String(newUnits[cut...]) else { return nil }
        return (oldUnits.count, rest)
    }

    /// The newest `limit` items, and whether older ones exist before them.
    public func snapshot(limit: Int = ChatStream.snapshotItems) -> (items: [NodeWire.Value], more: Bool) {
        let count = min(max(limit, 1), Self.mostItems)
        let start = max(0, items.count - count)
        return (items[start...].map(\.value), start > 0)
    }

    /// The item `after` as it is now and everything after it (a `tail`, the contract's §4), and whether older items
    /// exist before it; nil when the stream has no such item.
    public func tail(after: String) -> (items: [NodeWire.Value], more: Bool)? {
        guard let start = index[after] else { return nil }
        return (items[start...].map(\.value), start > 0)
    }

    /// The `limit` items just before `before`, oldest first, and whether more exist before them; nil when the stream
    /// has no such item.
    public func page(before: String, limit: Int = ChatStream.snapshotItems) -> (items: [NodeWire.Value], more: Bool)? {
        guard let end = index[before] else { return nil }
        let start = max(0, end - min(max(limit, 1), Self.mostItems))
        return (items[start..<end].map(\.value), start > 0)
    }

    /// The ops after `since`, as one delta's range: consecutive `text` ops of one item joined. Nil when the stream can't
    /// say: `since` is ahead of it, or before the oldest op it keeps. Empty when `since` is the stream's `seq`.
    public func changes(since: Int) -> (prev: Int, seq: Int, ops: [NodeWire.Value])? {
        guard since >= floor, since <= seq else { return nil }
        var joined: [Op] = []
        for op in ops where op.seq > since {
            if let id = op.textOf, let last = joined.last, last.textOf == id, let lastAt = last.at, let lastAppend = last.append,
               let append = op.append {
                let together = lastAppend + append
                joined[joined.count - 1] = Op(seq: op.seq, value: .object(["op": .string("text"), "id": .string(id), "at": .int(lastAt),
                                                                           "append": .string(together)]),
                                              textOf: id, at: lastAt, append: together)
            } else {
                joined.append(op)
            }
        }
        return (since, seq, joined.map(\.value))
    }
}

extension NodeWire {
    /// A chat's snapshot (the contract's §6): the newest items, or a `tail` from `after` on.
    static func chatSnapshot(sub: String, key: String, epoch: String, seq: Int, after: String?, more: Bool,
                             items: [Value]) -> Value {
        .object(["v": .int(version), "kind": .string("snapshot"), "sub": .string(sub), "collection": .string("chat"), "key": .string(key),
                 "epoch": .string(epoch), "seq": .int(seq), "after": after.map(Value.string) ?? .null, "more": .bool(more),
                 "items": .array(items)])
    }

    /// A chat's delta (the contract's §4 and §6): its ops in order.
    static func chatDelta(sub: String, prev: Int, seq: Int, at: Date, ops: [Value]) -> Value {
        .object(["v": .int(version), "kind": .string("delta"), "sub": .string(sub), "prev": .int(prev), "seq": .int(seq),
                 "at": .string(dateText(at)), "ops": .array(ops)])
    }
}

/// Each session's chat, while some client follows it (the live plan's B4, the live wire contract's §6): the session's
/// transcript read by `ChatReader` into a `ChatLog`, its `ChatTimeline.items` as wire items (`ChatValue`), and a
/// `ChatStream` that numbers their changes. The hub opens one when a client subscribes, and the store drops it 60 s after
/// its last follower left.
///
/// - **Which file.** The session's `transcriptPath` (`NodeSessions`' read of its hook), checked again here by
///   `TranscriptReader.checkedURL`: a regular `.jsonl` inside the agents' own folders of the node's home, after links
///   and `..`. A session with no transcript, or one outside them, is `gone`.
/// - **When it is read.** At once when it is written (`Platform.FileWatch` on the file), when its session changes (a
///   hook writes as the agent works), and at each of the clock's looks (every `lookEvery` s), for a file that can't be
///   watched or a write the watch missed. Each read takes only the bytes after the last one's, off the engine's queue
///   (`reads`); a file that shrank or was replaced is read again from its start. A read that finds nothing new changes
///   nothing.
/// - **No timer between a write and its delta** but the read itself: the watch's change, the read, the ops, the hub's
///   frame, each on the next turn of its queue.
///
/// On `queue` (the engine's): `open`, `follow`, `unfollow`, `sweep` and the reads' results.
public final class ChatStore: @unchecked Sendable {
    /// How long a stream nobody follows is kept (the contract's §4).
    public static let idleDrop: TimeInterval = 60
    /// How often the clock looks: each file read again (nothing when it didn't grow), and the streams nobody followed
    /// for `idleDrop` dropped.
    public static let lookEvery = 2

    public let queue: DispatchQueue
    private let home: String
    private let sessions: Changes<Session>
    private let now: @Sendable () -> TimeInterval
    private let date: @Sendable () -> Date
    private let note: @Sendable (String) -> Void
    private let reads = DispatchQueue(label: "vibenode.chat.reads", qos: .utility)
    private var feeds: [String: Feed] = [:]
    /// The last `seq` each session's dropped stream reached: a new one starts after it.
    private var reached: [String: Int] = [:]
    private var watching: Subscription?
    private var ticks: [Subscription] = []

    /// One session's chat: its stream, the file it is read from, and who follows it.
    private final class Feed {
        let session: String
        let stream: ChatStream
        /// Touched on `reads` only, but for being replaced (on `queue`, between reads).
        var follow: TranscriptFollow
        var watch: Platform.FileWatch?
        var followers = 0
        /// Since when nobody follows it (nil: someone does).
        var idleSince: TimeInterval?
        var reading = false
        var again = false

        init(session: String, stream: ChatStream, follow: TranscriptFollow) {
            self.session = session
            self.stream = stream
            self.follow = follow
        }
    }

    /// `home`: the node's (whose agents' folders hold the transcripts). `sessions`: the sessions store's changes (each
    /// session's `transcriptPath`). `now`: seconds, for the idle drop; `date`: an op's `at`.
    public init(queue: DispatchQueue, home: String, sessions: Changes<Session>,
                now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
                date: @escaping @Sendable () -> Date = { Date() }, note: @escaping @Sendable (String) -> Void = { _ in }) {
        self.queue = queue
        self.home = home
        self.sessions = sessions
        self.now = now
        self.date = date
        self.note = note
        watching = sessions.subscribe(on: queue) { [weak self] batch in
            guard let self else { return }
            for change in batch { if let feed = self.feeds[change.id] { self.look(feed) } }
        }
    }

    /// The clock's looks, from now on. On any thread.
    public func start(clock: NodeClock) {
        ticks.append(clock.every(Self.lookEvery) { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in self?.lookAll() }
        })
    }

    public func stop() {
        ticks = []
        watching = nil
        queue.async { [self] in
            for feed in feeds.values { feed.watch?.stop() }
            feeds = [:]
        }
    }

    /// How many chats are held now. On `queue`.
    public var count: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return feeds.count
    }

    /// For the reads beside the chat (`ChatReads.swift`): the sessions as the store has them, the node's home, the
    /// queue the files are read on, and the follow a held chat is read by. On `queue`.
    var sessionsValues: [String: Session] { sessions.values }
    var homeFolder: String { home }
    var readsQueue: DispatchQueue { reads }
    func follow(of session: String) -> TranscriptFollow? { feeds[session]?.follow }
    /// `session.usage`'s: the asks waiting on a read under way, by session (one read a session at a time), and each
    /// session's last answer with when it came (`ChatReads.usageKeep`). On `queue`.
    var usageWaiting: [String: [(Read) -> Void]] = [:]
    var usageKept: [String: (at: TimeInterval, read: Read)] = [:]
    var clock: TimeInterval { now() }
    /// How many usage reads ran (tests).
    var usageReadsRun = 0

    /// Whether `session`'s chat is held now. On `queue`.
    public func holds(_ session: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return feeds[session] != nil
    }

    /// `session`'s chat stream, held from now on (its first read under way when it is new), or why there is none:
    /// `gone` for a session the store doesn't know, one with no transcript, or one whose transcript isn't in the agents'
    /// folders. A stream nobody follows is dropped `idleDrop` after it was opened. On `queue`.
    public func open(_ session: String) -> Opened {
        dispatchPrecondition(condition: .onQueue(queue))
        if let feed = feeds[session] { return .opened(feed.stream) }
        guard let path = sessions.values[session]?.transcriptPath else {
            return .refused(.init(.gone, "no such session, or it has no transcript"))
        }
        guard let (url, format) = TranscriptReader.checkedURL(path, home: home) else {
            return .refused(.init(.gone, "that session's transcript isn't in the agents' own folders"))
        }
        let stream = ChatStream(session: session, start: reached[session].map { $0 + 1 } ?? 0, now: date)
        let feed = Feed(session: session, stream: stream, follow: TranscriptFollow(url: url, format: format))
        feed.idleSince = now()
        feeds[session] = feed
        watch(feed)
        read(feed)
        return .opened(stream)
    }

    /// What `open` found: the stream, or why there is none.
    public enum Opened {
        case opened(ChatStream)
        case refused(NodeWire.Failure)
    }

    /// What `page` found: the items and whether more exist before them, or why there are none.
    enum Paged {
        case page(items: [NodeWire.Value], more: Bool)
        case refused(NodeWire.Failure)
    }

    /// A client follows `session`'s chat (a subscription to it). On `queue`.
    public func follow(_ session: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let feed = feeds[session] else { return }
        feed.followers += 1
        feed.idleSince = nil
    }

    /// A client stopped following it. On `queue`.
    public func unfollow(_ session: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let feed = feeds[session], feed.followers > 0 else { return }
        feed.followers -= 1
        if feed.followers == 0 { feed.idleSince = now() }
    }

    /// The streams nobody followed for `idleDrop` dropped. On `queue`.
    public func sweep() {
        dispatchPrecondition(condition: .onQueue(queue))
        let at = now()
        for (session, feed) in feeds {
            guard let idle = feed.idleSince, at - idle >= Self.idleDrop else { continue }
            feed.watch?.stop()
            reached[session] = feed.stream.seq
            feeds[session] = nil
        }
    }

    private func lookAll() {
        sweep()
        for feed in feeds.values { look(feed) }
    }

    /// The session's file checked again (the session may have a new transcript, or its file was replaced), the watch
    /// made again when it has none, and the file read.
    private func look(_ feed: Feed) {
        if let path = sessions.values[feed.session]?.transcriptPath, let (url, format) = TranscriptReader.checkedURL(path, home: home),
           url != feed.follow.url, !feed.reading {
            feed.follow = TranscriptFollow(url: url, format: format)
            feed.watch?.stop()
            feed.watch = nil
        }
        if feed.watch == nil { watch(feed) }
        read(feed)
    }

    private func watch(_ feed: Feed) {
        guard let made = Platform.FileWatch(path: feed.follow.url.path) else { return }
        feed.watch = made
        made.deliver(on: queue) { [weak self, weak feed, weak made] change in
            guard let self, let feed else { return }
            if change.contains(.gone) {
                made?.stop()
                if feed.watch === made { feed.watch = nil }
                self.look(feed)
            } else {
                self.read(feed)
            }
        }
    }

    /// The bytes written since the last read, read off the engine's queue, and the items they make given to the
    /// stream. One read at a time a feed; a change during one reads again after it.
    private func read(_ feed: Feed) {
        guard !feed.reading else {
            feed.again = true
            return
        }
        feed.reading = true
        let follow = feed.follow
        let queue = self.queue
        reads.async { [weak self] in
            let items = follow.read()
            queue.async { [weak self] in
                guard let self else { return }
                feed.reading = false
                if let items, self.feeds[feed.session] === feed, follow === feed.follow { feed.stream.take(items) }
                if feed.again {
                    feed.again = false
                    if self.feeds[feed.session] === feed { self.read(feed) }
                }
            }
        }
    }

    /// The items just before `before` in `session`'s chat, opened for it if no client follows it (and dropped after,
    /// as any stream nobody follows), once it is read: `chat.page`'s reply. On `queue`; `reply` on `queue`.
    func page(_ session: String, before: String, limit: Int, reply: @escaping (Paged) -> Void) {
        switch open(session) {
        case .refused(let failure): reply(.refused(failure))
        case .opened(let stream):
            stream.whenLoaded {
                guard let page = stream.page(before: before, limit: limit) else {
                    return reply(.refused(.init(.badArgs, "no item \(ConfigSeal.inert(before, limit: 80)) in that chat")))
                }
                reply(.page(items: page.items, more: page.more))
            }
        }
    }
}

/// One transcript as a chat follows it: the bytes read so far, the conversation they make, and its wire items. On the
/// store's `reads` queue only.
final class TranscriptFollow: @unchecked Sendable {
    let url: URL
    let format: TranscriptReader.Format
    private var offset = 0
    /// The file read (its device and inode): another one at the path is read from its start.
    private var file: (device: UInt64, inode: UInt64)?
    private var log = ChatLog()
    /// Each item as last read, with its wire value: one that reads the same isn't written again.
    private var made: [String: (item: ChatItem, value: NodeWire.Value)] = [:]
    private var values: [(id: String, value: NodeWire.Value)] = []
    private var readOnce = false

    init(url: URL, format: TranscriptReader.Format) {
        self.url = url
        self.format = format
    }

    /// The chat's items as last read (each a wire item's), in no order.
    var items: [ChatItem] { made.values.map(\.item) }

    /// The chat's wire items after reading what was written since the last read; nil when nothing new was read (the
    /// first read always says its items, none when the file can't be read).
    func read() -> [(id: String, value: NodeWire.Value)]? {
        let first = !readOnce
        readOnce = true
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else { return first ? [] : nil }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let same = file.map { $0.device == device && $0.inode == inode } ?? false
        if !same || size < offset {
            // Another file, or one cut short: read from its start.
            offset = 0
            log = ChatLog()
            file = (device, inode)
        }
        guard size > offset else { return first ? values : nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return first ? values : nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil, let data = try? handle.readToEnd(), !data.isEmpty else {
            return first ? values : nil
        }
        let (events, consumed) = ChatReader.read(data, format: format)
        guard consumed > 0 else { return first ? values : nil }
        offset += consumed
        log.append(events)
        var next: [String: (item: ChatItem, value: NodeWire.Value)] = [:]
        var list: [(id: String, value: NodeWire.Value)] = []
        for item in ChatTimeline.items(log.entries, newAfter: nil) {
            let value: NodeWire.Value
            if let known = made[item.id], known.item == item {
                value = known.value
            } else if let fresh = ChatValue.value(item) {
                value = fresh
            } else {
                continue
            }
            next[item.id] = (item, value)
            list.append((item.id, value))
        }
        made = next
        values = list
        return list
    }
}
