import Foundation

/// A Terminal tab's scrollback for the phone: everything above the visible screen (which the phone
/// already shows live), addressed by absolute line number from the top of Terminal's history, so pages
/// stay put while new output arrives below them.
public enum Scrollback {
    public static let maxLines = 5000
    public static let pageLimit = 500

    public struct Page: Equatable, Sendable {
        public var lines: [String]
        /// Absolute number of `lines[0]`.
        public var start: Int
        /// Lines above the screen in total.
        public var total: Int
        /// Oldest line still reachable (`total - maxLines`, at least 0).
        public var first: Int

        public init(lines: [String], start: Int, total: Int, first: Int) {
            self.lines = lines
            self.start = start
            self.total = total
            self.first = first
        }
    }

    /// `history` minus the visible `screen` at its end (Terminal's history includes the screen).
    /// Trailing spaces and blank lines are ignored when matching; with no overlap nothing is removed.
    public static func lines(history: String, screen: String) -> [String] {
        var all = history.components(separatedBy: "\n").map { trimmedEnd($0) }
        while let last = all.last, last.isEmpty { all.removeLast() }
        var tail = screen.components(separatedBy: "\n").map { trimmedEnd($0) }
        while let last = tail.last, last.isEmpty { tail.removeLast() }
        if !tail.isEmpty, all.count >= tail.count, Array(all.suffix(tail.count)) == tail {
            all.removeLast(tail.count)
        }
        return all
    }

    public static func page(_ lines: [String], before: Int?, limit: Int) -> Page {
        let total = lines.count
        let first = max(0, total - maxLines)
        let end = min(before ?? total, total)
        let start = max(first, end - min(max(limit, 0), pageLimit))
        guard end > start else { return Page(lines: [], start: max(first, min(end, total)), total: total, first: first) }
        return Page(lines: Array(lines[start..<end]), start: start, total: total, first: first)
    }

    private static func trimmedEnd(_ line: String) -> String {
        var line = Substring(line)
        while let last = line.last, last == " " || last == "\t" || last == "\r" { line.removeLast() }
        return String(line)
    }
}
