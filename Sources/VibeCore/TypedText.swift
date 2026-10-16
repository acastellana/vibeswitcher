import Foundation

/// The part of a user message that a person typed or pasted, as opposed to what the harness injected.
enum TypedText {
    /// Slash-command records Claude Code writes before the typed text (`/model` and its output).
    private static let commandBlock = try! NSRegularExpression(
        pattern: "<(command-name|command-message|command-args|local-command-stdout|local-command-stderr|local-command-caveat)>[\\s\\S]*?</\\1>")
    /// Pasted text is wrapped (`<pasted_content id="…">…</pasted_content id="…">`): it's the user's, so it stays.
    private static let pasted = try! NSRegularExpression(pattern: "<pasted_content[^>]*>\\n?([\\s\\S]*?)\\n?</pasted_content[^>]*>")

    static func clean(_ text: String) -> String? {
        var result = text
        result = commandBlock.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        result = pasted.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1")
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isInjected(trimmed) else { return nil }
        return trimmed
    }

    /// Injected context starts with a tag whose name has a `-` or `_` (`<system-reminder>`, `<task-notification>`,
    /// `<environment_context>`); pasted HTML (`<div>`, `<!doctype html>`) is something the user typed.
    static func isInjected(_ text: String) -> Bool {
        guard text.hasPrefix("<") else { return false }
        let name = text.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let next = text.dropFirst(1 + name.count).first
        return (name.contains("-") || name.contains("_")) && (next == ">" || next == " ")
    }
}
