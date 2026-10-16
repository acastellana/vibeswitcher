import Foundation

/// Type-ahead matching for the command palette: the query's characters must appear in order.
public enum FuzzyMatch {
    /// Higher is better; nil when `query` doesn't match. Word starts and runs of consecutive characters
    /// count for more, and shorter candidates win ties.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let original = Array(candidate)
        let lowered = original.map { Character($0.lowercased()) }
        var score = 0
        var at = 0
        var previous = -2
        for wanted in needle {
            // Prefer the next word start holding this character; else its next occurrence.
            var found: Int?
            var first: Int?
            var index = at
            while index < lowered.count {
                if lowered[index] == wanted {
                    if first == nil { first = index }
                    if index == previous + 1 { found = index; break }
                    if isWordStart(original, index) { found = index; break }
                }
                index += 1
            }
            guard let match = found ?? first else { return nil }
            score += 1
            if isWordStart(original, match) { score += 8 }
            if match == previous + 1 { score += 5 }
            previous = match
            at = match + 1
        }
        return score - original.count / 10
    }

    /// The items matching `query`, best first; equal scores keep their order. An empty query keeps all.
    public static func rank<T>(_ items: [T], query: String, text: (T) -> String) -> [T] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items.enumerated()
            .compactMap { item in score(query, text(item.element)).map { (item.offset, $0, item.element) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map(\.2)
    }

    private static func isWordStart(_ characters: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let before = characters[index - 1]
        let current = characters[index]
        if !(before.isLetter || before.isNumber) { return true }
        return before.isLowercase && current.isUppercase
    }
}
