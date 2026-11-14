import Foundation
import Testing

/// What a role's command line (`LeadLaunch.prepare`'s) gives `claude`, read as the shell reads it: the settings, the
/// MCP configuration and the prompt, each from the file it names (the Mac, and a Linux prompt too long for one
/// argument) or from the JSON or text it carries itself (Linux, `Platform.Tools.roleSettingsInline`). A copy of
/// VibeCoreTests' own: test targets share no code.
enum LaunchArguments {
    /// The words of a shell command line: single quotes, double quotes and a backslash outside quotes, as a POSIX
    /// shell takes them; no expansions.
    static func words(_ command: String) -> [String] {
        var words: [String] = []
        var word = "", inWord = false
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                word.append(character)
                escaped = false
            } else if quote == "'" {
                if character == "'" { quote = nil } else { word.append(character) }
            } else if quote == "\"" {
                if character == "\"" { quote = nil } else if character == "\\" { escaped = true } else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character == "\\" {
                escaped = true
                inWord = true
            } else if character == " " || character == "\t" || character == "\n" {
                if inWord { words.append(word) }
                word = ""
                inWord = false
            } else {
                word.append(character)
                inWord = true
            }
        }
        if inWord { words.append(word) }
        return words
    }

    /// The word after `flag` in `command`; nil when it has no such flag.
    static func value(_ flag: String, in command: String) -> String? {
        let words = words(command)
        guard let index = words.firstIndex(of: flag), index + 1 < words.count else { return nil }
        return words[index + 1]
    }

    /// What `flag` (`--settings`, `--mcp-config`) gives: its JSON, or the file it names.
    static func data(_ flag: String, in command: String) throws -> Data {
        let value = try #require(value(flag, in: command), "no \(flag) in \(command.prefix(300))")
        if value.hasPrefix("{") { return Data(value.utf8) }
        return try Data(contentsOf: URL(fileURLWithPath: value))
    }

    /// `data(flag, in:)` as a JSON object.
    static func json(_ flag: String, in command: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data(flag, in: command)) as? [String: Any])
    }

    /// The prompt `command` appends: `--append-system-prompt`'s text, or the file `--append-system-prompt-file` names.
    static func prompt(in command: String) throws -> String {
        if let text = value("--append-system-prompt", in: command) { return text }
        let file = try #require(value("--append-system-prompt-file", in: command), "no prompt in \(command.prefix(300))")
        return try String(contentsOfFile: file, encoding: .utf8)
    }
}
