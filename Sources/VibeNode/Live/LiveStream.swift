import Foundation

// The live protocol's numbered streams (the live plan's B1 and B3, the live wire contract's §4): one per collection,
// each change of it one `seq` up, and enough kept to answer a resume with one delta and no journal.

extension NodeWire {
    /// One entry of a keyed collection: its id and its value now; `null`: it is gone (a delta's only).
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var value: Value

        public init(id: String, value: Value) {
            self.id = id
            self.value = value
        }
    }

    /// The event that says: this is the stream at `seq` (the contract's §4, "Snapshots"). The client reconciles it by
    /// id, never painting over what it holds.
    public struct Snapshot: Codable, Equatable, Sendable {
        public var v: Int
        public var kind: String
        public var sub: String
        public var collection: String
        public var epoch: String
        public var seq: Int
        public var entries: [Entry]
        /// Some entries left out, so the message fits a line (`LiveHub.fitted`, for a client that didn't ask for parts);
        /// absent otherwise.
        public var truncated: Bool?
        /// A snapshot in parts (`LiveHub.parted`, for a client that asked for them): this message's place, from 0, and
        /// whether it is the last. The client holds the parts' entries and takes them together, as one snapshot, when
        /// the last comes. Absent: the snapshot is this one message.
        public var part: Int?
        public var final: Bool?
        /// The ids of entries past `NodeWire.entryBytes`, left out of a snapshot in parts: they exist, too large to send.
        public var withheld: [String]?

        public init(sub: String, collection: String, epoch: String, seq: Int, entries: [Entry]) {
            v = NodeWire.version
            kind = "snapshot"
            self.sub = sub
            self.collection = collection
            self.epoch = epoch
            self.seq = seq
            self.entries = entries
        }
    }

    /// The event that takes a subscription's stream from `prev` to `seq` (the contract's §4, "Deltas"): each entry
    /// changed in that range, once, as it is now. `prev` is always the `seq` of the event sent before it on the same
    /// subscription.
    public struct Delta: Codable, Equatable, Sendable {
        public var v: Int
        public var kind: String
        public var sub: String
        public var prev: Int
        public var seq: Int
        /// When the server took the newest change in it.
        public var at: String
        public var changes: [Entry]

        public init(sub: String, prev: Int, seq: Int, at: Date, changes: [Entry]) {
            v = NodeWire.version
            kind = "delta"
            self.sub = sub
            self.prev = prev
            self.seq = seq
            self.at = NodeWire.dateText(at)
            self.changes = changes
        }
    }

    /// `value` as one message: compact JSON, no newline (what a `LiveTransport` takes).
    public static func message<T: Encodable>(_ value: T) -> Data {
        var data = line(value)
        data.removeLast()
        return data
    }
}

/// One keyed collection as the live protocol numbers it (the contract's §4): every entry's value and the `seq` at which
/// it last changed, the last `removalsKept` removals with theirs, and the stream's `seq`, one up at each change. On the
/// hub's queue (the engine's): it is read and changed only there.
///
/// What it keeps is bounded by the collection's own size and `removalsKept`: no journal. A resume from a `seq` is one
/// delta, every entry changed after it and every id removed after it, as long as no removal after it was forgotten.
public final class LiveStream: @unchecked Sendable {
    /// How a snapshot orders its entries (the contract: sessions by terminal, leads by root, cards by `at` then id).
    public enum Order: Sendable {
        /// By id.
        case id
        /// By these string fields of the value, in turn, then by id.
        case fields([String])

        public static func field(_ name: String) -> Order { .fields([name]) }
    }

    /// One entry as the stream holds it.
    public struct Held: Equatable, Sendable {
        public var value: NodeWire.Value
        /// The `seq` of its last change.
        public var changed: Int
    }

    /// How many removals a stream remembers (the contract's §4, LW-D7).
    public static let removalsKept = 256

    public let collection: String
    public let order: Order
    public let removalsKept: Int
    /// The stream's sequence number: 0 when made, one up at each change.
    public private(set) var seq = 0
    /// Every entry now, by id.
    public private(set) var entries: [String: Held] = [:]
    /// The last removals, oldest first, each with the `seq` of its removal; an id added again is no longer among them.
    public private(set) var removed: [(id: String, seq: Int)] = []
    /// The `seq` of the newest removal no longer kept (0: none forgotten). A resume from before it can't be told what
    /// went.
    public private(set) var forgotten = 0
    /// When the newest change was taken.
    public private(set) var changedAt: Date?
    /// Told after each change, or batch of changes (the hub's).
    var onChange: (() -> Void)?

    private let now: @Sendable () -> Date

    public init(collection: String, order: Order = .id, removalsKept: Int = LiveStream.removalsKept,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.collection = collection
        self.order = order
        self.removalsKept = max(1, removalsKept)
        self.now = now
    }

    /// `id` is now `value` (nil: removed). False, and nothing changes, when it is that already.
    @discardableResult
    public func apply(id: String, value: NodeWire.Value?) -> Bool {
        guard take(id: id, value: value) else { return false }
        onChange?()
        return true
    }

    /// Each change of `batch` in turn; the hub is told once, after them all. Whether any changed anything.
    @discardableResult
    public func apply(_ batch: [(id: String, value: NodeWire.Value?)]) -> Bool {
        var any = false
        for change in batch where take(id: change.id, value: change.value) { any = true }
        if any { onChange?() }
        return any
    }

    private func take(id: String, value: NodeWire.Value?) -> Bool {
        if let value, value != .null {
            guard entries[id]?.value != value else { return false }
            seq += 1
            entries[id] = Held(value: value, changed: seq)
            if let index = removed.firstIndex(where: { $0.id == id }) { removed.remove(at: index) }
        } else {
            guard entries[id] != nil else { return false }
            seq += 1
            entries[id] = nil
            removed.append((id, seq))
            if removed.count > removalsKept { forgotten = removed.removeFirst().seq }
        }
        changedAt = now()
        return true
    }

    /// Every entry now, in the stream's order, and the `seq` it is at.
    public func snapshot() -> (seq: Int, entries: [NodeWire.Entry]) {
        let sorted = entries.sorted { left, right in
            if case .fields(let names) = order {
                for name in names {
                    let (a, b) = (Self.key(left.value.value[name]), Self.key(right.value.value[name]))
                    if a != b { return a < b }
                }
            }
            return left.key < right.key
        }
        return (seq, sorted.map { NodeWire.Entry(id: $0.key, value: $0.value.value) })
    }

    /// What changed after `since`, as one delta's range and changes: each entry changed after it as it is now, each id
    /// removed after it as `null`, in the order of their last change. Nil when the stream can't say: `since` is ahead
    /// of it, below 0, or older than a removal it has forgotten. Empty changes when `since` is the stream's `seq`.
    public func changes(since: Int) -> (prev: Int, seq: Int, changes: [NodeWire.Entry])? {
        guard since >= forgotten, since >= 0, since <= seq else { return nil }
        guard since < seq else { return (since, seq, []) }
        var changed: [(seq: Int, entry: NodeWire.Entry)] = []
        for (id, held) in entries where held.changed > since { changed.append((held.changed, NodeWire.Entry(id: id, value: held.value))) }
        for removal in removed.reversed() {
            guard removal.seq > since else { break }
            changed.append((removal.seq, NodeWire.Entry(id: removal.id, value: .null)))
        }
        changed.sort { $0.seq < $1.seq }
        return (since, seq, changed.map(\.entry))
    }

    private static func key(_ value: NodeWire.Value?) -> String {
        switch value {
        case .string(let text): return text
        case .int(let number): return String(format: "%020d", number)
        default: return ""
        }
    }
}
