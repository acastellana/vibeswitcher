import Foundation

/// Writes the activity ledgers (`ActivityLedger.save`) on a queue of its own: written as each scan landed, they held the
/// main thread on a loaded Mac (hang-20261028-171900). One at a time, in order; a day's ledger saved again before its
/// write began is written once, the latest.
public final class LedgerWriter: @unchecked Sendable {
    private let write: @Sendable (ActivityLedger) -> Void
    private let queue = DispatchQueue(label: "vibeswitcher.ledger", qos: .utility)
    private let lock = NSLock()
    /// Saved and not written yet, by day; and the one being written.
    private var waiting: [String: ActivityLedger] = [:]
    private var writing: ActivityLedger?

    /// `folder`: where the ledgers are kept (the app's is `VibePaths.statsDir`).
    public convenience init(folder: URL) {
        self.init { $0.save(in: folder) }
    }

    /// `write`: writes one ledger; tests pass their own.
    public init(write: @escaping @Sendable (ActivityLedger) -> Void) {
        self.write = write
    }

    public func save(_ ledger: ActivityLedger) {
        lock.lock()
        let queued = waiting.updateValue(ledger, forKey: ledger.day) != nil
        lock.unlock()
        // A write of that day is queued and not begun: it takes this one.
        guard !queued else { return }
        queue.async { [self] in
            lock.lock()
            let latest = waiting.removeValue(forKey: ledger.day)
            writing = latest
            lock.unlock()
            if let latest { write(latest) }
            lock.lock()
            writing = nil
            lock.unlock()
        }
    }

    /// The ledger of `day` saved and not written yet (its file is older).
    public func unwritten(day: String) -> ActivityLedger? {
        lock.lock()
        defer { lock.unlock() }
        return waiting[day] ?? writing.flatMap { $0.day == day ? $0 : nil }
    }

    /// Waits for the writes saved so far (at quit).
    public func flush() {
        queue.sync {}
    }
}
