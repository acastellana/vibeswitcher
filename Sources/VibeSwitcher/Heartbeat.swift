import Foundation

/// One clock for the app's periodic work (the session scan, the menu bar icon check, the lead boards, the chat), so
/// the app wakes once for all of it instead of once per timer. A client runs every `seconds` ticks of one second, all
/// clients of the same period on the same tick. The tick allows a quarter second of leeway, so the system can run it
/// together with the hang watchdog's beat. Main thread only; it runs only while it has clients.
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
    private var tick = 0
    private var timer: Timer?

    /// Runs `action` every `seconds` (at least 1) whole seconds, until the subscription is cancelled or released.
    func every(_ seconds: Int, _ action: @escaping () -> Void) -> Subscription {
        nextID += 1
        clients[nextID] = (max(1, seconds), action)
        if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.beat() }
            timer.tolerance = 0.25
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        return Subscription(heartbeat: self, id: nextID)
    }

    private func remove(_ id: Int) {
        clients[id] = nil
        if clients.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func beat() {
        tick += 1
        // In id order, so what subscribed first (the scan) runs first.
        for id in clients.keys.sorted() {
            guard let client = clients[id], tick % client.every == 0 else { continue }
            client.action()
        }
    }
}
