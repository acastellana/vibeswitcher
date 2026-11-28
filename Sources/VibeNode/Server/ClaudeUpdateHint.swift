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
    static var versionsName: String { "~/.local/share/claude/versions" }
    static var binName: String { "~/.local/bin" }

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

/// Claude Code's self-update switch (E8): `DISABLE_AUTOUPDATER=1` in the `env` of its own settings
/// (`<home>/.claude/settings.json`, `HookInstaller.configURL`), the one setting that stops the holds `ClaudeUpdateHint`
/// explains. Written as the hooks are: only the `env` member replaced, every other byte kept, the file behind a link
/// edited and a change made meanwhile started over from (`HookInstaller.edit(_:member:change:)`), inside `appWrite` so
/// the vault seals the app's own write. The `claude.autoupdate` kind's.
public enum ClaudeAutoUpdate {
    /// Claude Code's variable (`LeadLaunch.autoUpdaterVariable`, the one each team role's environment carries).
    public static var variable: String { LeadLaunch.autoUpdaterVariable }

    /// Claude Code's settings in `home`.
    public static func settingsPath(home: String) -> String { HookInstaller.configURL(for: .claude, home: home).path }

    /// Whether the settings at `home` leave the updater on (no `DISABLE_AUTOUPDATER` set to a value but "0" or "", as
    /// Claude Code reads it); nil when they can't be read as an object.
    public static func isOn(home: String) -> Bool? {
        let path = settingsPath(home: home)
        guard let data = FileManager.default.contents(atPath: path) else { return FileManager.default.fileExists(atPath: path) ? nil : true }
        if data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) { return true }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let env = object["env"] else { return true }
        guard let variables = env as? [String: Any] else { return nil }
        guard let value = variables[variable] else { return true }
        let text = (value as? String) ?? "\(value)"
        return text.isEmpty || text == "0"
    }

    /// Turns the updater `on` (the variable taken out of `env`, `env` gone when that leaves it empty) or off (set to
    /// "1"), through `appWrite` (`LeadVault.appWrite`, then sealed: the server's; a test's records the paths). True when
    /// the file changed; a refusal, nothing written, when it isn't a JSON object or its `env` isn't one.
    public static func set(on: Bool, home: String, appWrite: ([String], () throws -> Void) throws -> Void) -> Result<Bool, StartRefusal> {
        let path = settingsPath(home: home)
        guard let was = isOn(home: home) else {
            return .failure(StartRefusal("\(ConfigSeal.inert(path, limit: .max)) isn't a JSON object with an object `env`: nothing was changed", exitCode: 1))
        }
        guard was != on else { return .success(false) }
        do {
            try appWrite([path]) {
                try HookInstaller.edit(URL(fileURLWithPath: path), member: "env") { config in
                    var config = config
                    var env = config["env"] as? [String: Any] ?? [:]
                    env[variable] = on ? nil : "1"
                    config["env"] = env.isEmpty ? nil : env
                    return config
                }
            }
        } catch {
            return .failure(StartRefusal("\(ConfigSeal.inert(path, limit: .max)) wasn't changed: \(ConfigSeal.inert(HookInstaller.whyNot(error), limit: .max))", exitCode: 1))
        }
        guard isOn(home: home) == on else {
            return .failure(StartRefusal("\(ConfigSeal.inert(path, limit: .max)) doesn't say what was written: it changed meanwhile; try again", exitCode: 1))
        }
        return .success(true)
    }
}
