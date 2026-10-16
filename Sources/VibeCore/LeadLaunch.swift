import Foundation

/// How the lead, a worker or a verifier is started: the project's Claude command plus its role's prompt, the
/// VibeSwitcher tool server and its permission rules (kept as data, in files next to the board).
public enum LeadLaunch {
    public enum Role: String, Sendable { case lead, worker, verifier }

    public struct Prepared: Equatable, Sendable {
        public var command: String
        public var promptFile: String
        public var mcpFile: String
        public var settingsFile: String
    }

    static let readOnly = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    static let gitWrites = ["Bash(git commit:*)", "Bash(git add:*)", "Bash(git push:*)", "Bash(git merge:*)", "Bash(git rebase:*)",
                            "Bash(git reset:*)", "Bash(git checkout:*)", "Bash(git switch:*)", "Bash(git stash:*)", "Bash(git branch -D:*)",
                            "Bash(git branch -d:*)", "Bash(git worktree:*)", "Bash(git tag:*)"]

    /// What each role may not do.
    public static func deny(_ role: Role) -> [String] {
        switch role {
        case .lead, .verifier:
            return readOnly + gitWrites
        case .worker:
            // Edits and commits on its own branch; nothing that rewrites history or touches main.
            return ["Bash(git push:*)", "Bash(git merge:*)", "Bash(git rebase:*)", "Bash(git reset --hard:*)", "Bash(git checkout main:*)",
                    "Bash(git switch main:*)", "Bash(git checkout master:*)", "Bash(git switch master:*)", "Bash(git branch -D:*)",
                    "Bash(git branch -d:*)", "Bash(git worktree:*)", "Bash(git tag:*)", "Bash(git commit --amend:*)"]
        }
    }

    /// Writes the role's files under `<root>/.vibeswitcher/run/<name>/` and returns the command line to run.
    public static func prepare(role: Role, root: String, task: String?, base: String, prompt: String, start: String,
                               server: String, name: String, model: String? = nil) throws -> Prepared {
        let folder = (root as NSString).appendingPathComponent(".vibeswitcher/run/\(name)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let promptFile = (folder as NSString).appendingPathComponent("prompt.md")
        let mcpFile = (folder as NSString).appendingPathComponent("mcp.json")
        let settingsFile = (folder as NSString).appendingPathComponent("settings.json")
        try prompt.write(toFile: promptFile, atomically: true, encoding: .utf8)
        var args = ["--role", role.rawValue, "--root", root]
        if let task { args += ["--task", task] }
        let mcp: [String: Any] = ["mcpServers": ["vibeswitcher": ["command": server, "args": args]]]
        try JSONSerialization.data(withJSONObject: mcp, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: mcpFile))
        let settings: [String: Any] = ["permissions": ["deny": deny(role)]]
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: settingsFile))
        let quote = RecentProjects.shellQuote
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        var parts = [trimmed.isEmpty ? "claude" : trimmed]
        // From its file, so the prompt's length and characters never matter on the command line.
        parts.append("--append-system-prompt-file \(quote(promptFile))")
        parts.append("--mcp-config \(quote(mcpFile))")
        parts.append("--settings \(quote(settingsFile))")
        parts.append("--name \(quote(name))")
        if let model { parts.append("--model \(quote(model))") }
        parts.append("-- \(quote(start))")
        return Prepared(command: parts.joined(separator: " "), promptFile: promptFile, mcpFile: mcpFile, settingsFile: settingsFile)
    }
}
