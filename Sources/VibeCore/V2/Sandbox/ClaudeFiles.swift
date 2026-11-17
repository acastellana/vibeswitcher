import Foundation

/// What Claude Code finds of its config inside a box (the session sandbox plan's "The agent itself", as SB0 measured
/// Claude Code 2.1.326: the inventory's "The session sandbox, measured"). The config folder (`~/.claude`) is the
/// session's own; the user's entries that say how the agent behaves are bound into it read-only, so a session can't
/// change what the next one loads; the transcript's folder is the real one; the login is read-only (SB-D8); everything
/// else Claude Code writes there starts empty and goes with the box. `~/.claude.json` is a seeded copy in the session's
/// own home, since Claude Code rewrites it by a rename beside it (six times in one turn, measured).
///
/// A new Claude Code version changes these lists and their test (`SandboxPlannerTests`), nothing else.
public enum ClaudeFiles {
    /// The config folder's entries bound read-only from the user's, each where it exists.
    public static let readOnlyEntries = ["settings.json", "settings.local.json", "CLAUDE.md", "skills", "agents", "commands",
                                         "plugins", "keybindings.json", "statusline.sh", "policy-limits.json",
                                         "remote-settings.json", "output-styles"]

    /// What Claude Code writes in its config folder in a box, measured: each the session's own, empty at start.
    public static let ownEntries = ["backups", "debug", "history.jsonl", "mcp-needs-auth-cache.json", "projects", "session-env",
                                    "sessions", "shell-snapshots", "jobs", "file-history", "paste-cache", "cache", "tasks",
                                    "teams", "todos", "state", "statsig", "ide"]

    /// The login, read-only in slices 1 to 3 (SB-D8), never copied.
    public static let login = ".credentials.json"

    /// The folder of `cwd`'s transcripts under the config folder's `projects/`: Claude Code's own name for it, every
    /// character but a letter or a digit made `-` (SB0: `/tmp/sb0/worktree` is `-tmp-sb0-worktree`).
    public static func projectFolder(cwd: String) -> String {
        String(cwd.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)) ? Character(scalar) : "-"
        })
    }

    /// The seeded `~/.claude.json` for a session in `cwd`: the account's file with every key but `projects` and
    /// `mcpServers` (the user's other projects and their tool servers, whose keys may be in it: SB-D9), and one project,
    /// `cwd`, trusted and onboarded, which spares the trust question (measured). A file that isn't a JSON object gives
    /// that project alone.
    public static func seededConfig(from data: Data, cwd: String) -> Data {
        var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        object["mcpServers"] = nil
        object["projects"] = [cwd: ["hasTrustDialogAccepted": true, "hasCompletedProjectOnboarding": true,
                                    "allowedTools": [String]()] as [String: Any]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
