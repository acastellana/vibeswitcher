import Foundation

/// The part of a user message that a person typed or pasted, as opposed to what the harness injected.
enum TypedText {
    /// Slash-command records Claude Code writes before the typed text (`/model` and its output).
    private static let commandBlock = try! NSRegularExpression(
        pattern: "<(command-name|command-message|command-args|local-command-stdout|local-command-stderr|local-command-caveat)>[\\s\\S]*?</\\1>")
    /// Pasted text is wrapped (`<pasted_content id="…">…</pasted_content id="…">`): it's the user's, so it stays.
    private static let pasted = try! NSRegularExpression(pattern: "<pasted_content[^>]*>\\n?([\\s\\S]*?)\\n?</pasted_content[^>]*>")

    /// A message another agent sent this session (a cross-session message, a subagent's report): not the user's
    /// words. Returns who sent it and its text.
    public static func agentMessage(_ text: String) -> (from: String, body: String)? {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Typed in by VibeSwitcher for an idle agent (see `LeadDelivery.typed`).
        if rest.hasPrefix(LeadDelivery.prefix), let close = rest.firstIndex(of: "]") {
            let from = rest[rest.index(rest.startIndex, offsetBy: LeadDelivery.prefix.count)..<close]
                .trimmingCharacters(in: CharacterSet(charactersIn: " ·"))
            return (from, rest[rest.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let intro = "Another Claude session sent a message:"
        if rest.hasPrefix(intro) { rest = rest.dropFirst(intro.count).trimmingCharacters(in: .whitespacesAndNewlines) }
        for tag in ["cross-session-message", "agent-message"] where rest.hasPrefix("<\(tag)") {
            guard let close = rest.firstIndex(of: ">") else { return nil }
            let header = rest[..<close]
            let from = attribute("from-name", in: header) ?? attribute("from", in: header) ?? "another agent"
            var body = rest[rest.index(after: close)...]
            if let end = body.range(of: "</\(tag)>") { body = body[..<end.lowerBound] }
            return (from, body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func attribute(_ name: String, in header: Substring) -> String? {
        guard let start = header.range(of: " \(name)=\"") else { return nil }
        let value = header[start.upperBound...]
        return value.firstIndex(of: "\"").map { String(value[..<$0]) }
    }

    static func clean(_ text: String) -> String? {
        if agentMessage(text) != nil { return nil }
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
