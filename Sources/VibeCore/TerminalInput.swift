import Foundation

/// Claude Code's input box, read off its screen: the line(s) between the last two horizontal rules, starting
/// with ❯. Typing into an agent is only safe when that box is empty (otherwise the user's draft is in it).
public enum TerminalInput {
    public static func isEmpty(_ screen: String) -> Bool {
        let lines = screen.replacingOccurrences(of: "\u{0}", with: " ").components(separatedBy: "\n")
        let rules = lines.indices.filter { isRule(lines[$0]) }
        guard rules.count >= 2 else { return false }
        let (top, bottom) = (rules[rules.count - 2], rules[rules.count - 1])
        let box = lines[(top + 1)..<bottom].map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = box.first, first.hasPrefix("❯") else { return false }
        let typed = ([String(first.dropFirst())] + box.dropFirst()).joined().trimmingCharacters(in: .whitespaces)
        return typed.isEmpty
    }

    /// A row of ─ (a session name may sit inside it).
    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.filter { $0 == "─" }.count >= 20
    }
}
