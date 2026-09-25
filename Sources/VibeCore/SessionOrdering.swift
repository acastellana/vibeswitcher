import Foundation

public enum SessionOrdering {
    /// Decides the order of the dots in the menu bar and the rows in the popover.
    /// The order also defines the 1–9 keyboard shortcuts, so it shapes muscle memory.
    public static func sort(_ sessions: [Session]) -> [Session] {
        // TODO(you): choose the ordering policy. Placeholder: oldest session first (stable positions).
        sessions.sorted { $0.startedAt < $1.startedAt }
    }
}
