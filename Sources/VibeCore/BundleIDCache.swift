import Foundation

/// Apps' bundle identifiers by pid. `NSRunningApplication.bundleIdentifier` asks another process (a synchronous XPC):
/// asked at every scan, it held the main thread on a loaded Mac (hang-20261028-171900). An app's bundle id doesn't
/// change while it runs, so each pid is asked once, and forgotten when it's gone (a pid used again is another app).
public final class BundleIDCache: @unchecked Sendable {
    private let alive: @Sendable (Int32) -> Bool
    private let lock = NSLock()
    private var ids: [Int32: String] = [:]

    /// `alive`: whether a pid still runs; tests pass their own.
    public init(alive: @escaping @Sendable (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        self.alive = alive
    }

    /// `pid`'s bundle id: known, else `lookup`'s (asked outside the lock; a nil one is asked again next time).
    public func bundleID(pid: Int32, lookup: () -> String?) -> String? {
        lock.lock()
        ids = ids.filter { alive($0.key) }
        let known = ids[pid]
        lock.unlock()
        if let known { return known }
        guard let id = lookup() else { return nil }
        lock.lock()
        ids[pid] = id
        lock.unlock()
        return id
    }

    /// The pids known (for tests).
    public var pids: Set<Int32> {
        lock.lock()
        defer { lock.unlock() }
        return Set(ids.keys)
    }
}
