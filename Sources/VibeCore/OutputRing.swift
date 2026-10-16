import Foundation

/// What a session printed recently, replayed when a view (re)attaches: the last `capacity` bytes, and
/// where in them the screen was last wiped (a replay starting there draws a whole screen instead of
/// the middle of an escape sequence). The program is asked to redraw after a replay anyway.
public struct OutputRing: Sendable {
    public let capacity: Int
    private var bytes = Data()
    /// Stream offset of `bytes[0]`.
    private var base = 0
    /// Stream offsets where a clear-screen, alternate-screen switch or terminal reset starts.
    private var resets: [Int] = []
    /// The stream's last few bytes, to find a sequence split across two appends.
    private var tail: [UInt8] = []

    static let resetSequences: [[UInt8]] = [
        "\u{1b}[2J", "\u{1b}c", "\u{1b}[?1049h", "\u{1b}[?1047h", "\u{1b}[?47h",
    ].map { Array($0.utf8) }
    static let longestReset = 8

    public init(capacity: Int) {
        self.capacity = capacity
    }

    /// Everything ever appended, in bytes.
    public var totalWritten: Int { base + bytes.count }

    public mutating func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        let window = tail + [UInt8](chunk)
        let windowStart = totalWritten - tail.count
        for i in window.indices where window[i] == 0x1b {
            for sequence in Self.resetSequences {
                let end = i + sequence.count
                // Only matches that end in the new chunk: the others were counted already (or can't be complete).
                guard end <= window.count, end > tail.count else { continue }
                if window[i..<end].elementsEqual(sequence) {
                    resets.append(windowStart + i)
                    break
                }
            }
        }
        bytes.append(chunk)
        tail = Array(window.suffix(Self.longestReset - 1))
        // Trim in batches: dropping the front of `Data` copies it.
        if bytes.count > capacity + capacity / 4 {
            let drop = bytes.count - capacity
            bytes = Data(bytes.dropFirst(drop))
            base += drop
            resets.removeAll { $0 < base }
        }
    }

    /// From the latest reset still held; else, once older output was dropped, from the first line start;
    /// else everything. At most `limit` bytes: beyond that it starts at the first line start inside the
    /// last `limit` bytes (the program redraws its screen after a re-attach, so older output only feeds
    /// scrollback, and feeding megabytes to a view takes seconds).
    public func replay(limit: Int = .max) -> Data {
        var start = 0
        if let reset = resets.last {
            start = reset - base
        } else if base > 0 {
            guard let newline = bytes.firstIndex(of: 0x0a) else { return Data() }
            start = newline + 1
        }
        if bytes.count - start > limit {
            let cut = bytes.count - limit
            guard let newline = bytes[cut...].firstIndex(of: 0x0a), newline + 1 < bytes.count else { return Data() }
            start = newline + 1
        }
        return Data(bytes[start...])
    }
}
