import Foundation

/// Claude Code's native install as a process runs it (the first real node, 2026-11-19): `~/.local/bin/claude` links to
/// `~/.local/share/claude/versions/<version>`, and the node starts each lead, and its tool server each worker and
/// verifier, by that resolved path (EN-D13, `RoleProgram`), so the process's `comm` and `argv[0]` are its version
/// (`2.1.328`), never `claude`. `ProcessTable.identify` took such a process for no agent, and every message for the
/// lead was held ("no lead the vault binds runs there"), each worker's `ask_lead` told there's no lead running. One hook
/// in `identify` asks `isBinary(argv[0])`. As much as a name in argv says, no more: any process may name itself so.
public enum VersionedClaude {
    /// Whether `argument` (a process's `argv[0]`) names a file in a `claude/versions` folder.
    public static func isBinary(_ argument: String) -> Bool {
        let parts = argument.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return false }
        let version = parts[parts.count - 1]
        return parts[parts.count - 2] == "versions" && parts[parts.count - 3] == "claude" && version != "." && version != ".."
    }
}
