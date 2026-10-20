import Foundation

/// One clock for the app's periodic work (the session scan, the menu bar icon check, the lead boards, the chat), so
/// the app wakes once for all of it instead of once per timer. A client runs every `seconds` whole seconds of the clock,
/// all clients of the same period on the same second. The clock wakes only on a second some client is due (with clients
/// every 2 and 3 s, 8 times in 12 s, not 12): each wake costs the system a timer, a run loop pass and a CoreAnimation
/// commit. Each allows a quarter second of leeway, so the system can run it together with the hang watchdog's beat.
/// Main thread only; it runs only while it has clients.
final class Heartbeat {
    static let shared = Heartbeat()

    /// Stops its client when cancelled or released.
    final class Subscription {
        fileprivate weak var heartbeat: Heartbeat?
        fileprivate let id: Int

        fileprivate init(heartbeat: Heartbeat, id: Int) {
            self.heartbeat = heartbeat
            self.id = id
        }

        func cancel() { heartbeat?.remove(id) }

        deinit { cancel() }
    }

    private var clients: [Int: (every: Int, action: () -> Void)] = [:]
    private var nextID = 0
    /// The second of the clock last run, counted from `origin`.
    private var tick = 0
    private var origin = Date()
    private var timer: Timer?
    /// How many times the clock woke (for tests).
    private(set) var wakes = 0

    /// Runs `action` every `seconds` (at least 1) whole seconds, until the subscription is cancelled or released.
    func every(_ seconds: Int, _ action: @escaping () -> Void) -> Subscription {
        nextID += 1
        clients[nextID] = (max(1, seconds), action)
        if timer == nil {
            origin = Date()
            tick = 0
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.beat() }
            timer.tolerance = 0.25
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        schedule()
        return Subscription(heartbeat: self, id: nextID)
    }

    private func remove(_ id: Int) {
        clients[id] = nil
        if clients.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// The clock set for the first second, after the one run last and the one under way, at which a client is due.
    private func schedule() {
        guard let timer else { return }
        let now = max(tick, Int(Date().timeIntervalSince(origin)))
        let next = clients.values.map { (now / $0.every + 1) * $0.every }.min() ?? now + 1
        timer.fireDate = origin.addingTimeInterval(TimeInterval(next))
    }

    private func beat() {
        wakes += 1
        // The second it was set for (it may run up to the leeway late).
        tick = max(tick + 1, Int(Date().timeIntervalSince(origin).rounded()))
        // In id order, so what subscribed first (the scan) runs first.
        for id in clients.keys.sorted() {
            guard let client = clients[id], tick % client.every == 0 else { continue }
            client.action()
        }
        schedule()
    }
}
