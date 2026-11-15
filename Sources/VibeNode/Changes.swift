import Foundation
import VibeCore

/// Stops what it was handed out for (a `Changes` subscriber, a `NodeClock` client) when cancelled or released.
public final class Subscription: @unchecked Sendable {
    private let lock = NSLock()
    private var stop: (() -> Void)?

    init(_ stop: @escaping () -> Void) {
        self.stop = stop
    }

    /// Stops it; once only, from any thread.
    public func cancel() {
        let stop = lock.withLock { () -> (() -> Void)? in
            defer { self.stop = nil }
            return self.stop
        }
        stop?()
    }

    deinit { cancel() }
}

/// The change stream of a store keyed by id (the design's VibeNode: stores, not view models): each change is the id
/// and its new value, or nil for an entry removed. A value equal to the last sent for its id sends nothing. Each
/// subscriber is handed its deltas on a queue of its own, in batches; what was sent while its handler ran, or before
/// its queue got to it, is folded per id into the latest (one delta per id, in the order the ids first changed), so a
/// slow subscriber gets where each entry is now, never a backlog of where it was.
public final class Changes<Value: Equatable & Sendable>: @unchecked Sendable {
    public struct Delta: Equatable, Sendable {
        public var id: String
        /// The entry's value now; nil: it was removed.
        public var value: Value?

        public init(id: String, value: Value?) {
            self.id = id
            self.value = value
        }
    }

    private let lock = NSLock()
    /// The last value sent for each id still present.
    private var last: [String: Value] = [:]
    private var subscribers: [Int: Subscriber] = [:]
    private var nextID = 0

    public init() {}

    /// Every entry's last value sent, by id.
    public var values: [String: Value] { lock.withLock { last } }

    /// `handler` gets each batch of deltas from now on, on `queue` (one of its own when none is given, serial: one
    /// batch at a time), until the subscription is cancelled or released.
    public func subscribe(on queue: DispatchQueue? = nil, _ handler: @escaping ([Delta]) -> Void) -> Subscription {
        let subscriber = Subscriber(queue: queue ?? DispatchQueue(label: "vibenode.changes.subscriber"), handler: handler)
        let id = lock.withLock { () -> Int in
            nextID += 1
            subscribers[nextID] = subscriber
            return nextID
        }
        return Subscription { [weak self] in
            subscriber.end()
            self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) }
        }
    }

    /// `id` is now `value` (nil: removed). Nothing is sent when that is what was last sent for it.
    public func send(_ id: String, _ value: Value?) {
        // Handed to each subscriber under the lock, so sends from two threads reach every subscriber in the order
        // `last` took them (`add` only queues: it never runs a handler here).
        lock.withLock {
            guard last[id] != value else { return }
            last[id] = value
            for subscriber in subscribers.values { subscriber.add(Delta(id: id, value: value)) }
        }
    }

    /// One subscriber: its deltas not yet handed over, folded per id, and whether a hand-over is under way.
    private final class Subscriber: @unchecked Sendable {
        private let queue: DispatchQueue
        private let handler: ([Delta]) -> Void
        private let lock = NSLock()
        private var order: [String] = []
        private var pending: [String: Delta] = [:]
        private var scheduled = false
        private var ended = false

        init(queue: DispatchQueue, handler: @escaping ([Delta]) -> Void) {
            self.queue = queue
            self.handler = handler
        }

        func add(_ delta: Delta) {
            let start = lock.withLock { () -> Bool in
                guard !ended else { return false }
                if pending[delta.id] == nil { order.append(delta.id) }
                pending[delta.id] = delta
                guard !scheduled else { return false }
                scheduled = true
                return true
            }
            if start { queue.async { self.drain() } }
        }

        func end() {
            lock.withLock {
                ended = true
                order = []
                pending = [:]
            }
        }

        /// Hands over what is pending, then again whatever came meanwhile, until nothing is.
        private func drain() {
            while true {
                let batch = lock.withLock { () -> [Delta] in
                    let batch = order.compactMap { pending[$0] }
                    order = []
                    pending = [:]
                    if batch.isEmpty || ended { scheduled = false }
                    return ended ? [] : batch
                }
                guard !batch.isEmpty else { return }
                handler(batch)
            }
        }
    }
}
