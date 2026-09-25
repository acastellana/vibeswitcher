import Foundation

public enum SessionOrdering {
    /// Decides the order of the dots in the menu bar and the rows in the popover.
    /// The order also defines the 1–9 keyboard shortcuts, so it shapes muscle memory.
    ///
    /// Positions are stable: oldest session first, so "3" keeps meaning the same terminal and each
    /// menu bar dot stays put while its color changes. Urgency is handled elsewhere: opening the
    /// popover preselects the first red (then green) row, so ⌃⌥V ⏎ jumps to whoever needs you.
    public static func sort(_ sessions: [Session]) -> [Session] {
        sessions.sorted { ($0.startedAt, $0.tty) < ($1.startedAt, $1.tty) }
    }
}
