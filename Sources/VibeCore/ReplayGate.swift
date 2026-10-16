import Foundation

/// Whether a terminal view's automatic answers to queries may reach the program. While the view is being
/// fed a replay of earlier output, the queries in it were already answered when they first ran.
public struct ReplayGate: Sendable {
    public private(set) var allowsReplies = true

    public init() {}

    /// An attach (or re-attach after a resync) was requested: a replay comes first.
    public mutating func attaching() { allowsReplies = false }

    /// The host says the replay is over; what follows is live.
    public mutating func attached() { allowsReplies = true }
}
