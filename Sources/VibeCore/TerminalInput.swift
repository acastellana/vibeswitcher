import Foundation

/// Claude Code's input box, read off its screen: the line(s) between the last two horizontal rules, starting
/// with ❯. Typing into an agent is only safe when that box is empty (otherwise the user's draft is in it).
public enum TerminalInput {
    /// `cursor` (row in `screen`, column): when it's on the box's first line, only what's before it counts. Claude
    /// shows a dim suggestion in an empty box, with the cursor before it; typed text leaves the cursor after it.
    public static func isEmpty(_ screen: String, cursor: (row: Int, column: Int)? = nil) -> Bool {
        let lines = screen.replacingOccurrences(of: "\u{0}", with: " ").components(separatedBy: "\n")
        let rules = lines.indices.filter { isRule(lines[$0]) }
        guard rules.count >= 2 else { return false }
        let (top, bottom) = (rules[rules.count - 2], rules[rules.count - 1])
        let box = lines[(top + 1)..<bottom].map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = box.first, first.hasPrefix("❯") else { return false }
        if let cursor, cursor.row == top + 1, bottom == top + 2 {
            let line = Array(lines[top + 1])
            guard let marker = line.firstIndex(of: "❯") else { return false }
            let before = String(line[(marker + 1)..<min(max(cursor.column, marker + 1), line.count)])
            return before.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let typed = ([String(first.dropFirst())] + box.dropFirst()).joined().trimmingCharacters(in: .whitespaces)
        return typed.isEmpty
    }

    /// A row of ─ (a session name may sit inside it).
    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.filter { $0 == "─" }.count >= 20
    }
}
