import Foundation

/// The word being typed at the caret, when it asks for completion: `/command` at the start of the message, or
/// `@file` anywhere after a space.
public struct ComposerToken: Equatable, Sendable {
    public enum Kind: Sendable { case slash, mention }
    public var kind: Kind
    /// What follows the `/` or `@`.
    public var query: String
    /// The whole token, `/` or `@` included (UTF-16 offsets, as text views count).
    public var range: NSRange

    public init(kind: Kind, query: String, range: NSRange) {
        self.kind = kind
        self.query = query
        self.range = range
    }

    public static func at(_ text: String, caret: Int) -> ComposerToken? {
        let utf16 = Array(text.utf16)
        guard caret >= 0, caret <= utf16.count else { return nil }
        var start = caret
        while start > 0, let scalar = UnicodeScalar(utf16[start - 1]), !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            start -= 1
        }
        guard start < caret else { return nil }
        let token = String(utf16CodeUnits: Array(utf16[start..<caret]), count: caret - start)
        let range = NSRange(location: start, length: caret - start)
        if token.hasPrefix("/"), start == 0 { return ComposerToken(kind: .slash, query: String(token.dropFirst()), range: range) }
        if token.hasPrefix("@") { return ComposerToken(kind: .mention, query: String(token.dropFirst()), range: range) }
        return nil
    }
}

public struct SlashCommand: Equatable, Sendable, Identifiable {
    public var name: String
    public var description: String
    public var id: String { name }
    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// What `/` can complete to: the agent's built-in commands, your custom commands and your skills.
public enum SlashCatalog {
    public static func builtins(_ agent: Agent) -> [SlashCommand] {
        let list: [(String, String)]
        switch agent {
        case .claude:
            list = [("clear", "Start a new conversation"), ("compact", "Summarize the conversation to free context"),
                    ("context", "Show what fills the context"), ("cost", "Show token usage and cost"), ("model", "Switch model"),
                    ("resume", "Resume an earlier conversation"), ("rewind", "Go back to an earlier message"),
                    ("review", "Review the current changes"), ("init", "Write a CLAUDE.md for this project"),
                    ("memory", "Edit memory files"), ("agents", "Manage subagents"), ("mcp", "Manage MCP servers"),
                    ("hooks", "Manage hooks"), ("permissions", "Manage permissions"), ("config", "Open settings"),
                    ("status", "Show status"), ("usage", "Show plan usage"), ("todos", "Show the to-do list"),
                    ("export", "Export the conversation"), ("add-dir", "Add a working folder"), ("doctor", "Check the installation"),
                    ("help", "Show help"), ("exit", "Quit")]
        case .codex:
            list = [("model", "Switch model"), ("approvals", "Choose what runs without asking"), ("new", "Start a new conversation"),
                    ("compact", "Summarize the conversation to free context"), ("diff", "Show the changes"),
                    ("review", "Review the current changes"), ("status", "Show status and limits"), ("init", "Write an AGENTS.md"),
                    ("undo", "Undo the last turn"), ("mention", "Mention a file"), ("mcp", "List MCP tools"), ("quit", "Quit")]
        }
        return list.map { SlashCommand(name: $0.0, description: $0.1) }
    }

    /// Custom commands (`<dir>/**/name.md` → `/dir:name`) and skills (`<dir>/*/SKILL.md`), sorted by name.
    public static func scan(commandDirs: [URL], skillDirs: [URL]) -> [SlashCommand] {
        var found: [String: SlashCommand] = [:]
        let fileManager = FileManager.default
        for dir in commandDirs {
            guard let walker = fileManager.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            let base = dir.resolvingSymlinksInPath().path + "/"
            for case let url as URL in walker where url.pathExtension == "md" {
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(base) else { continue }
                let relative = path.dropFirst(base.count).dropLast(3)
                let name = relative.replacingOccurrences(of: "/", with: ":")
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                found[name] = SlashCommand(name: name, description: frontmatter(text)["description"] ?? firstLine(text))
            }
        }
        for dir in skillDirs {
            for folder in (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                let file = folder.appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let meta = frontmatter(text)
                let name = meta["name"] ?? folder.lastPathComponent
                found[name] = SlashCommand(name: name, description: meta["description"] ?? "")
            }
        }
        return found.values.sorted { $0.name < $1.name }
    }

    /// Names starting with the query first, then other fuzzy matches; everything for an empty query.
    public static func match(_ query: String, in commands: [SlashCommand], limit: Int = 12) -> [SlashCommand] {
        guard !query.isEmpty else { return Array(commands.prefix(limit * 4)) }
        let lower = query.lowercased()
        let prefixed = commands.filter { $0.name.lowercased().hasPrefix(lower) }
        let others = FuzzyMatch.rank(commands.filter { !$0.name.lowercased().hasPrefix(lower) }, query: query) { $0.name }
        return Array((prefixed + others).prefix(limit))
    }

    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            values[key] = value
        }
        return values
    }

    static func firstLine(_ text: String) -> String {
        let line = text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return line.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
    }
}

/// The project's files, for `@` mentions.
public enum FileIndex {
    static let skippedFolders: Set<String> = ["node_modules", "build", "dist", "DerivedData", "Pods", "target", "__pycache__",
                                              "venv", "coverage", "out"]

    /// Paths relative to `root`, skipping hidden files and folders and build output; at most `limit`.
    public static func files(in root: String, limit: Int = 20_000) -> [String] {
        let base = URL(fileURLWithPath: root)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let prefix = base.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var out: [String] = []
        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if skippedFolders.contains(url.lastPathComponent) || walker.level > 12 { walker.skipDescendants() }
                continue
            }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            out.append(full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : url.lastPathComponent)
            if out.count >= limit { break }
        }
        return out
    }

    /// Best matches: file names count more than folders.
    public static func match(_ query: String, in files: [String], limit: Int = 12) -> [String] {
        guard !query.isEmpty else { return Array(files.prefix(limit)) }
        let scored = files.compactMap { path -> (String, Int)? in
            let name = (path as NSString).lastPathComponent
            let byName = FuzzyMatch.score(query, name).map { $0 + 20 }
            let byPath = FuzzyMatch.score(query, path)
            guard let best = [byName, byPath].compactMap({ $0 }).max() else { return nil }
            return (path, best)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.count < $1.0.count }.prefix(limit).map(\.0)
    }
}
