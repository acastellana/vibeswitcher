import Foundation
import Testing

/// The Mac's text lints, run on Linux (the Mac gate failed an hour after a push on a rule Linux never ran, 2026-11-24):
/// each reads its rule's lists from the Mac test file's own text (Tests/VibeSwitcherTests, never edited on v2), its
/// functions are verbatim copies held to the originals by CopiedFilesLintTests, and its sample lines, lifted from the
/// Mac test too, hold the two to each other.
enum MacText {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The text of a Mac test file.
    static func file(_ name: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent("Tests/VibeSwitcherTests/" + name), encoding: .utf8)
    }

    /// A Swift string literal's contents unescaped (`\"`, `\\`, `\n`, `\t`).
    static func unescaped(_ body: String) -> String {
        var out = ""
        var escaping = false
        for char in body {
            if escaping {
                switch char {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(char)
                }
                escaping = false
            } else if char == "\\" {
                escaping = true
            } else {
                out.append(char)
            }
        }
        return out
    }

    /// The Swift string literals in `text`, in order: raw (`#"…"#`, as written) or plain (unescaped).
    static func literals(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: ##"#"(.*?)"#|"((?:\\.|[^"\\])*)""##)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            if let raw = Range(match.range(at: 1), in: text) { return String(text[raw]) }
            return Range(match.range(at: 2), in: text).map { unescaped(String(text[$0])) }
        }
    }

    /// The text between `start` and the first `end` after it in `text`.
    static func between(_ text: String, _ start: String, _ end: String) throws -> String {
        let from = try #require(text.range(of: start), "\(start) isn't in the Mac test's text any more")
        let to = try #require(text.range(of: end, range: from.upperBound..<text.endIndex), "\(end) after \(start)")
        return String(text[from.upperBound..<to.lowerBound])
    }
}
