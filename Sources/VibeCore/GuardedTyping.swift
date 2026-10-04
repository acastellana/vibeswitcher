import Foundation

/// Typing into a Terminal tab that keeps checking it's still typing into that tab.
///
/// Keystrokes can only be posted to Terminal as a whole, not to one tab, so whatever is in front gets
/// them. The tab is verified before typing starts; this keeps verifying while it types: a cheap check
/// (Terminal still frontmost, same window) before every chunk, the full check (the selected tab is
/// still the session's) at least every `fullCheckEvery` seconds and always right before Enter or a
/// key, which is what would approve something. On any change it stops: a cut-off message may be left
/// in a box, but it is never sent anywhere else.
public enum GuardedTyping {
    public enum Outcome: Equatable, Sendable {
        case done
        /// The focus moved. `typed`: some text was already typed (into the right tab, up to the check before it).
        case stopped(typed: Bool)
    }

    /// Text as UTF-16 chunks for key events, never splitting a surrogate pair.
    public static func chunks(_ text: String, size: Int = 16) -> [[UInt16]] {
        let units = Array(text.utf16)
        var chunks: [[UInt16]] = []
        var start = 0
        while start < units.count {
            var end = min(start + size, units.count)
            if end < units.count, end - start > 1, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            chunks.append(Array(units[start..<end]))
            start = end
        }
        return chunks
    }

    /// `finish`: what follows the text (Enter, a key), each guarded by both checks.
    public static func run(chunks: [[UInt16]], finish: [() -> Void], stillFocused: () -> Bool, stillFrontTab: () -> Bool,
                           clock: () -> TimeInterval, fullCheckEvery: TimeInterval,
                           post: ([UInt16]) -> Void, pause: (TimeInterval) -> Void) -> Outcome {
        var typed = false
        var lastFullCheck = clock()
        for chunk in chunks {
            guard stillFocused() else { return .stopped(typed: typed) }
            if clock() - lastFullCheck >= fullCheckEvery {
                guard stillFrontTab() else { return .stopped(typed: typed) }
                lastFullCheck = clock()
            }
            post(chunk)
            typed = true
            pause(0.01)
        }
        for step in finish {
            // A separate, slightly later Enter: sent with the text it would count as part of a paste.
            if typed { pause(0.12) }
            guard stillFocused(), stillFrontTab() else { return .stopped(typed: typed) }
            step()
        }
        return .done
    }
}
