import Foundation

/// The inspector's Activity rows, from a transcript tail.
public enum ActivityFeed {
    /// The newest `limit` entries. A tool result whose call was before the tail is dropped (results of
    /// calls inside the tail were already merged into their call by `TranscriptReader`).
    public static func rows(_ entries: [TranscriptEntry], limit: Int) -> [TranscriptEntry] {
        Array(entries.filter { $0.kind != .toolResult }.suffix(limit))
    }
}
