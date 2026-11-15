import Foundation
import VibeCore

/// The engine's one clock (the app's `Heartbeat`, rebuilt off the main thread): the engine's 3 s refresh, the session
/// scan's 2 s and the room watch's 60 s, each a client run every so many whole seconds of the clock, all clients of
/// one period on the same second. The clock wakes only on a second some client is due (with clients every 2 and 3 s,
/// 4 times in the first 6 s, not 6), on a `DispatchSourceTimer`, never a run loop, and runs its clients on the queue it
/// was given, in the order they subscribed. It runs only while it has clients. The design's recorded exception to
/// "never from a timer" (the engine plan's Global Constraints): stage 3's stores remove it.
public final class NodeClock: @unchecked Sendable {
    /// Arms a one-shot wake `seconds` from now that calls `fire` on the clock's queue, and returns what disarms it.
    public typealias Schedule = (_ seconds: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void

    private let queue: DispatchQueue
    private let now: () -> TimeInterval
    private let schedule: Schedule
    private let lock = NSLock()
    private var clients: [Int: (every: Int, action: () -> Void)] = [:]
    private var nextID = 0
    /// The second of the clock last run, counted from `origin`.
    private var tick = 0
    private var origin: TimeInterval = 0
    /// Disarms the wake armed now (nil: none).
    private var disarm: (() -> Void)?
    /// Counts arms, so a wake armed before the latest does nothing when it comes.
    private var armed = 0
    private var wakeCount = 0

    /// `queue`: where the clients run. `now`: seconds on a monotonic clock (the system's awake time by default).
    /// `schedule`: how a wake is armed (a `DispatchSourceTimer` on `queue` by default); tests give their own, with `now`,
    /// to drive the clock second by second.
    public init(queue: DispatchQueue, now: (() -> TimeInterval)? = nil, schedule: Schedule? = nil) {
        self.queue = queue
        self.now = now ?? { MacTime.real.awake() }
        self.schedule = schedule ?? NodeClock.timer(on: queue)
    }

    /// How many times the clock woke.
    public var wakes: Int { lock.withLock { wakeCount } }

    /// How many clients it has now.
    public var clientCount: Int { lock.withLock { clients.count } }

    /// Runs `action` on the clock's queue every `seconds` (at least 1) whole seconds, until the subscription is
    /// cancelled or released. From any thread.
    public func every(_ seconds: Int, _ action: @escaping () -> Void) -> Subscription {
        let id = lock.withLock { () -> Int in
            nextID += 1
            if clients.isEmpty {
                origin = now()
                tick = 0
            }
            clients[nextID] = (max(1, seconds), action)
            rearm()
            return nextID
        }
        return Subscription { [weak self] in self?.remove(id) }
    }

    private func remove(_ id: Int) {
        lock.withLock {
            clients[id] = nil
            if clients.isEmpty {
                disarm?()
                disarm = nil
                armed += 1
            }
        }
    }

    /// Arms the wake for the first second, after the one run last and the one under way, at which a client is due.
    /// Under the lock.
    private func rearm() {
        disarm?()
        disarm = nil
        armed += 1
        guard !clients.isEmpty else { return }
        let elapsed = now() - origin
        let current = max(tick, Int(elapsed))
        let next = clients.values.map { (current / $0.every + 1) * $0.every }.min() ?? current + 1
        let arm = armed
        disarm = schedule(max(0, origin + TimeInterval(next) - now())) { [weak self] in self?.beat(arm) }
    }

    private func beat(_ arm: Int) {
        let due = lock.withLock { () -> [() -> Void] in
            guard arm == armed, !clients.isEmpty else { return [] }
            wakeCount += 1
            // The second it was armed for (it may come up to the leeway late).
            tick = max(tick + 1, Int((now() - origin).rounded()))
            // In id order, so what subscribed first (the scan) runs first.
            let due = clients.keys.sorted().compactMap { id -> (() -> Void)? in
                guard let client = clients[id], tick % client.every == 0 else { return nil }
                return client.action
            }
            rearm()
            return due
        }
        for action in due { action() }
    }

    /// The default `Schedule`: a one-shot `DispatchSourceTimer` on `queue`, with a quarter second of leeway.
    static func timer(on queue: DispatchQueue) -> Schedule {
        { seconds, fire in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + seconds, leeway: .milliseconds(250))
            timer.setEventHandler(handler: fire)
            timer.resume()
            return { timer.cancel() }
        }
    }
}
