import Combine
import Foundation

extension Publisher where Failure == Never {
    /// `receive(on: runLoop)`, holding only the newest value until it's delivered (the ones before it are dropped).
    /// RunLoop's scheduler delivers in the run loop's default mode only, and `receive(on:)` keeps every value in a block
    /// of its own until then. While End Session…'s alert ran modal (from about 20:48 until 07:07, 2026-10-27),
    /// each value of the leads' boards waited so, a copy of a day's boards each: the footprint went to 990 MB, and
    /// main froze 8.9 s freeing them all once the alert closed (hang-20261028-070849). A menu tracking holds it too.
    func receiveLatest(on runLoop: RunLoop) -> Publishers.ReceiveLatest<Self> {
        Publishers.ReceiveLatest(upstream: self, runLoop: runLoop)
    }
}

extension Publishers {
    /// See `Publisher.receiveLatest(on:)`.
    struct ReceiveLatest<Upstream: Publisher>: Publisher where Upstream.Failure == Never {
        typealias Output = Upstream.Output
        typealias Failure = Never

        let upstream: Upstream
        let runLoop: RunLoop

        func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Never {
            upstream.subscribe(ReceiveLatestInner(downstream: subscriber, runLoop: runLoop))
        }
    }
}

/// Takes all of the upstream's values, keeps the newest, and has the run loop deliver it: one delivery scheduled at a
/// time, whatever arrives meanwhile replacing the value it delivers.
private final class ReceiveLatestInner<Downstream: Subscriber>: Subscriber, Subscription where Downstream.Failure == Never {
    typealias Input = Downstream.Input
    typealias Failure = Never

    private let runLoop: RunLoop
    private let lock = NSLock()
    private var downstream: Downstream?
    private var upstream: Subscription?
    private var pending: Input?
    private var finished = false
    private var scheduled = false
    private var demand: Subscribers.Demand = .none

    init(downstream: Downstream, runLoop: RunLoop) {
        self.downstream = downstream
        self.runLoop = runLoop
    }

    func receive(subscription: Subscription) {
        lock.lock()
        guard upstream == nil, let downstream else {
            lock.unlock()
            return subscription.cancel()
        }
        upstream = subscription
        lock.unlock()
        downstream.receive(subscription: self)
        subscription.request(.unlimited)
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        lock.lock()
        guard downstream != nil else {
            lock.unlock()
            return .none
        }
        pending = input
        let schedule = takeSchedule()
        lock.unlock()
        if schedule { runLoop.schedule { self.deliver() } }
        return .none
    }

    func receive(completion: Subscribers.Completion<Never>) {
        lock.lock()
        finished = true
        let schedule = downstream != nil && takeSchedule()
        lock.unlock()
        if schedule { runLoop.schedule { self.deliver() } }
    }

    func request(_ more: Subscribers.Demand) {
        lock.lock()
        demand += more
        let schedule = pending != nil && downstream != nil && takeSchedule()
        lock.unlock()
        if schedule { runLoop.schedule { self.deliver() } }
    }

    func cancel() {
        lock.lock()
        let subscription = upstream
        upstream = nil
        downstream = nil
        pending = nil
        lock.unlock()
        subscription?.cancel()
    }

    /// Whether a delivery should be scheduled now (none is yet); under the lock.
    private func takeSchedule() -> Bool {
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    private func deliver() {
        lock.lock()
        scheduled = false
        guard let downstream else { return lock.unlock() }
        var value: Input?
        if demand > 0, let newest = pending {
            value = newest
            pending = nil
            demand -= 1
        }
        let done = finished && pending == nil
        if done { self.downstream = nil; upstream = nil }
        lock.unlock()
        if let value {
            let more = downstream.receive(value)
            if more > 0 { request(more) }
        }
        if done { downstream.receive(completion: .finished) }
    }
}
