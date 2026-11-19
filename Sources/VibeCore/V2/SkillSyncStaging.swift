import Foundation

/// Claude Code's skill sync (2.1.3xx, measured on the node 2026-11-19) makes `~/.claude/skills/synced/<bucket>/.staging`
/// for a round and removes it once the round is done, many times a day. The seal's walk of `~/.claude/skills` counted
/// the folder's coming and going as a change, so each round held every worker until the user accepted it, with nothing
/// changed that runs.
///
/// The rule (S7): that one entry is left out of the walk while it is an **empty folder**. An empty folder holds no
/// file, link or folder, so nothing in it can run, be loaded as a skill or be read as an instruction; its appearing and
/// vanishing leave the folder's hash, its per-path hashes and the held card as they were. Anything else at that name is
/// walked and hashed as ever, and held as ever: a `.staging` holding any entry (a file, a link, an empty folder of its
/// own), a link or a file named `.staging`, the name at any other depth or outside `synced/`, and the same path under
/// any other watched folder. The look is at the walk's own time, `lstat` and a read of the folder, never a link
/// followed: a file written into it after the look is seen by the next look and held.
public enum SkillSyncStaging {
    /// The watched thing whose walk the rule is for, as `ConfigSeal.homeWatched(home:)` names it.
    public static var watchedName: String { "~/.claude/skills" }
    /// The folder the sync stages a round in, straight under a bucket's folder.
    public static let name = ".staging"

    /// Whether the entry `entry` of `folder` (at `relative` under the watched thing `watched`, "" for its top) is the
    /// sync's empty staging folder, which the seal's walk leaves out: `synced/<bucket>/.staging`, the bucket a name that
    /// isn't empty or a dot name, and the entry a folder (not a link) with nothing in it.
    public static func leftOut(_ entry: String, in folder: String, relative: String, watched: String) -> Bool {
        guard watched == watchedName, entry == name else { return false }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "synced", !parts[1].isEmpty, !parts[1].hasPrefix(".") else { return false }
        let path = (folder as NSString).appendingPathComponent(entry)
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let inside = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return inside.isEmpty
    }
}
