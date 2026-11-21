import Foundation
import VibeCore

/// What a held-config card adds when what it holds looks like Claude Code's own update (the 2026-11-21 follow-up): only
/// `~/.local/share/claude/versions` (a new version's file) and `~/.local/bin` (the `claude` link moved to it) changed,
/// and the link now names a file in that folder named by a version (`2.1.331`). It is a hint, never an accept: the hold
/// stays.
///
/// **Why it isn't let through unheld.** A same-uid process (any worker) can write a file named `2.1.331` there and move
/// the link to it, exactly as the updater does: the next session of every team, and the user's own, would run that
/// file as Claude Code. On Linux the binary carries no signature the node could check, and the updater keeps no local
/// record of the checksum it verified (it checks Anthropic's manifest on download and writes nothing beside the file).
/// The only proof is that manifest's SHA-256, which the node would have to fetch from Anthropic's release bucket (a new
/// outbound call; the node talks to GitHub alone today) and hash the ~380 MB file against. Until that's decided, the
/// card says what it likely is and the user accepts it; turning the updater off (`DISABLE_AUTOUPDATER=1` in Claude
/// Code's settings) removes the holds altogether.
public enum ClaudeUpdateHint {
    static let versionsName = "~/.local/share/claude/versions"
    static let binName = "~/.local/bin"

    /// The hint for a held card's item names, with `home`'s `claude` link read; nil when it isn't only those, or the link
    /// doesn't name a version's file there.
    public static func hint(names: [String], home: String) -> String? {
        let held = Set(names)
        guard held.contains(versionsName), held.isSubset(of: [versionsName, binName]) else { return nil }
        let link = (home as NSString).appendingPathComponent(".local/bin/claude")
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { return nil }
        let versions = (home as NSString).appendingPathComponent(".local/share/claude/versions")
        let resolved = target.hasPrefix("/") ? target : ((link as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
        let standard = (resolved as NSString).standardizingPath
        guard (standard as NSString).deletingLastPathComponent == versions else { return nil }
        let version = (standard as NSString).lastPathComponent
        guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return "this looks like Claude Code's own update to \(version) (a new file in its versions folder, and the claude link moved to it). "
            + "VibeSwitcher can't tell it from a file a session put there: accept it if Claude Code updated itself; "
            + "DISABLE_AUTOUPDATER=1 in Claude Code's settings stops these holds"
    }
}
