import Foundation

/// Writes the activity ledgers (`ActivityLedger.save`).
public final class LedgerWriter: @unchecked Sendable {
    private let write: @Sendable (ActivityLedger) -> Void

    /// `folder`: where the ledgers are kept (the app's is `VibePaths.statsDir`).
    public convenience init(folder: URL) {
        self.init { $0.save(in: folder) }
    }

    /// `write`: writes one ledger; tests pass their own.
    public init(write: @escaping @Sendable (ActivityLedger) -> Void) {
        self.write = write
    }

    public func save(_ ledger: ActivityLedger) {
        write(ledger)
    }

    /// The ledger of `day` saved and not written yet.
    public func unwritten(day: String) -> ActivityLedger? { nil }

    /// Waits for the writes saved so far (at quit).
    public func flush() {}
}
