import Foundation

/// A code block in a reply that's a shell command, as the prompt that runs it in the session (`! command`: Claude
/// Code runs it in its shell and the output joins the conversation).
public enum RunnableCommand {
    static let shells: Set<String> = ["bash", "sh", "zsh", "shell", "console", "terminal"]

    public static func prompt(code: String, language: String?) -> String? {
        let language = language?.lowercased()
        let lines = code.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let first = lines.first { !$0.isEmpty } ?? ""
        let marked = first.hasPrefix("!") || first.hasPrefix("$ ")
        guard language.map(shells.contains) ?? false || (language == nil && marked) else { return nil }
        // A heredoc spans lines that mean something only together.
        guard !code.contains("<<") else { return nil }
        let console = language == "console" || language == "terminal"
        var commands: [String] = []
        var pending = ""
        for line in lines {
            var command = line
            if console, pending.isEmpty {
                guard command.hasPrefix("$ ") else { continue }
            }
            for prompt in ["$ ", "% ", "!"] where command.hasPrefix(prompt) {
                command = String(command.dropFirst(prompt.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            if pending.isEmpty, command.isEmpty || command.hasPrefix("#") { continue }
            if command.hasSuffix("\\") {
                pending += String(command.dropLast()).trimmingCharacters(in: .whitespaces) + " "
                continue
            }
            commands.append(pending + command)
            pending = ""
        }
        if !pending.isEmpty { commands.append(pending.trimmingCharacters(in: .whitespaces)) }
        guard !commands.isEmpty else { return nil }
        return "! " + commands.joined(separator: " && ")
    }
}
