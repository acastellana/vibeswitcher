import Foundation

/// The config seal's Mac list (the node on macOS's step 8; the measurement record's row 13): what, besides the Mac's
/// `ConfigSeal.homeFiles` (the zsh startup files, `~/.gitconfig`, `~/.config/git/config` among them), a worker's shell
/// can change on a Mac node that the next session, the node's LaunchAgent or its tools run. The Mac counterpart of
/// `LinuxSealList`, the same shape (rows as data, the same `Watched` kinds, `sourced` shared), each row measured on a
/// real Mac (the design's "The seal's Mac list" has the table).
///
/// Off unless asked for: `ConfigSeal.homeWatched(home:macList:)` appends it only with `macList`, which the vault passes
/// from its book (`LeadVault.Book.watchesMacList`: set only by a checked Mac node host, beside `recordsActions`; never
/// the Mac app's host, never another book in the process), and the node's own code (the server, the command line)
/// passes on the Mac to name what the vault may hold. Empty on Linux whatever is asked.
///
/// - The home's rows (`homeEntries`): the LaunchAgents folder and the node's plist in it, Terminal's preferences, nvm
///   as on Linux, the folders on a session's PATH that the user owns (`~/bin`, `~/.local/bin`, Claude Code's
///   versions), and the agents' shell snapshots (`.entries`, Linux's names, so `LinuxSealList.cameOrWent` applies).
/// - What the zsh startup files source (`startupFiles`, by `LinuxSealList.sourced`).
/// - Outside the home, only for the account's own home (the user database's; a scratch home's seal reads nothing
///   outside it): Homebrew's `bin` and `sbin` (the user's to write on Apple Silicon, ahead of `/usr/bin` on PATH), and
///   the Xcode selection's link.
/// - Every row executes: none is in `ConfigSeal.instructions`, so a change waits for the user's accept whoever made it.
///
/// Folders are read as `.listing` (each entry's name, type, mode, size, inode, times and link target, never contents)
/// or `.entries`, never `.folder`: `ConfigSeal.readFolder` doesn't see a folder's mode (the security document's S11
/// item 8), these two do.
public enum MacSealList {
    /// The node's LaunchAgent plist under the home: `NodeAgent.Place`'s default (`~/Library/LaunchAgents`, label
    /// `dev.vibeswitcher.node`; `NodeAgentTests` checks the two agree).
    public static let plist = "Library/LaunchAgents/dev.vibeswitcher.node.plist"

    /// Terminal's preferences under the home (`terminalPreferences`' domain).
    public static let terminalPreferences = "Library/Preferences/com.apple.Terminal.plist"

    /// The home's rows, by path under it.
    public static let homeEntries: [(String, ConfigSeal.Watched.Kind)] = [
        // launchd loads every plist here at login (`RunAtLoad`): an agent added or changed runs as the user, before any
        // session; `launchctl setenv` made persistent is one of them. By metadata: a rewrite changes ctime.
        ("Library/LaunchAgents", .listing),
        // The node's own job (step 5: `start` believes only the plist it wrote; a switch rewrites it): by contents.
        (plist, .file),
        // A profile's startup command and Terminal's shell, every key but the ones Terminal rewrites as it runs.
        (terminalPreferences, .preferences),
        // nvm, as on Linux (`LinuxSealList.homeEntries`): `nvm.sh` and the default alias pick the node every shell runs.
        (".nvm/nvm.sh", .file), (".nvm/versions/node", .listing), (".nvm/alias", .listing),
        // The user's folders on a session's PATH (the login shell's), and Claude Code's versions behind `~/.local/bin/claude`.
        ("bin", .listing), (".local/bin", .listing), (".local/share/claude/versions", .listing),
        // gh's config and token, as on Linux: by metadata, so the token is never read; an alias there runs as `gh <alias>`.
        (".config/gh", .listing),
        // Each session writes its snapshot here, and sources it before each command (Linux's ST-D19).
        (".claude/shell-snapshots", .entries), (".codex/shell-snapshots", .entries),
    ]

    /// The startup files whose `.` and `source` targets are watched (`LinuxSealList.sourced`): zsh's, the Mac's shell.
    public static let startupFiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin"]

    /// The rows outside the home, by their own path (their names): read only for the account's own home.
    public static let outsideEntries: [(String, ConfigSeal.Watched.Kind)] = [
        ("/opt/homebrew/bin", .listing), ("/opt/homebrew/sbin", .listing),
        // `xcode-select -s` writes this link (root's); `swift`, `git` and `xcrun` in `/usr/bin` follow it.
        ("/var/db/xcode_select_link", .file),
    ]

    /// Whether the node's own code (its server's cards and refusals, `HeldChange`, `ConfigHoldStore`, `Answers`) names
    /// the Mac list's rows: on the Mac. A superset of what its vault holds: a book that doesn't watch them
    /// (`LeadVault.Book.watchesMacList` off) records and holds none of them, and a name with nothing recorded is no
    /// refusal and no card.
    public static var namedByTheNode: Bool { Platform.CodeIdentity.isAvailable }

    /// The list for `home` (the account `uid`'s), empty on Linux. `outside`: where the rows outside the home are read
    /// (their names stay their own paths); nil reads them at `/` for the account's own home (the user database's), and
    /// leaves them out for any other.
    public static func watched(home: String, uid: uid_t, outside: String? = nil) -> [ConfigSeal.Watched] {
        guard Platform.CodeIdentity.isAvailable else { return [] }
        var items = homeEntries.map { entry in
            ConfigSeal.Watched(name: "~/" + entry.0, path: (home as NSString).appendingPathComponent(entry.0), kind: entry.1)
        }
        var names = Set(items.map(\.name))
        names.formUnion(ConfigSeal.homeFiles.map { "~/" + $0.0 })
        for file in startupFiles {
            guard let data = ConfigSeal.regularContents((home as NSString).appendingPathComponent(file), limit: 1 << 20) else { continue }
            for path in LinuxSealList.sourced(startupFile: String(decoding: data, as: UTF8.self), home: home) {
                let watched = ConfigSeal.Watched(name: ConfigSeal.shown(path, home: home), path: path, kind: .file)
                if names.insert(watched.name).inserted { items.append(watched) }
            }
        }
        if let root = outside ?? (LinuxSealList.isAccountHome(home, uid: uid) ? "/" : nil) {
            items += outsideEntries.map { entry in
                ConfigSeal.Watched(name: entry.0, path: root == "/" ? entry.0 : (root as NSString).appendingPathComponent(entry.0), kind: entry.1)
            }
        }
        return items
    }

    /// Whether `name` is one of the rows outside the home: the node-wide seal's, as a home's (`ConfigSeal.isHome`).
    static func isOutsideName(_ name: Substring) -> Bool {
        outsideEntries.contains { $0.0 == name }
    }

    // MARK: Preferences (`ConfigSeal.Watched.Kind.preferences`)

    /// The top-level keys Terminal rewrites as it runs, left out of the hash (each measured on this Mac, 2026-11-26:
    /// between its preferences file and the `.bak` beside it, two weeks apart, these were the only keys that changed;
    /// the profiles' "Window Settings", "Default Window Settings" and "Startup Window Settings" were byte for byte the
    /// same). `LastTerminalStartTime` is written at each Terminal start.
    static let churnKeys: Set<String> = ["LastTerminalStartTime"]

    /// The prefix of the keys AppKit writes at each window move (`NSWindow Frame TTWindow Homebrew` changed; the
    /// others under it are the same kind of key, one per window type).
    static let churnPrefix = "NSWindow Frame "

    /// Whether `key` (a top-level key) is left out of the hash.
    static func isChurn(_ key: String) -> Bool { churnKeys.contains(key) || key.hasPrefix(churnPrefix) }

    /// A preferences file read whole at most: past it, it's unreadable.
    static let preferencesLimit = 16 << 20

    /// The files a preferences row reads: the domain's file at `path`, and each `ByHost/<domain>.*.plist` beside it,
    /// by name (CFPreferences reads the current host's domain first). Each with its label: "" for the file, the
    /// `ByHost/…` name for the others; the ByHost folder's own state ("ByHost": absent, unreadable, or a folder) too.
    static func preferenceFiles(_ path: String) -> (folder: String, files: [(label: String, path: String)]) {
        let folder = (path as NSString).deletingLastPathComponent
        let domain = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let byHost = (folder as NSString).appendingPathComponent("ByHost")
        var files: [(label: String, path: String)] = [("", path)]
        var info = stat()
        guard lstat(byHost, &info) == 0 else { return ("absent", files) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return ("not a folder", files) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: byHost) else { return ("unreadable", files) }
        for name in names.sorted() where name.hasPrefix(domain + ".") && name.hasSuffix(".plist") {
            files.append(("ByHost/" + name, (byHost as NSString).appendingPathComponent(name)))
        }
        return ("folder", files)
    }

    /// One preferences file's top-level keys, each hashed in its canonical form (`canonical`), churn left out; or what
    /// it is instead: "absent", "unreadable", "not a property list" (never nothing to compare). A link at `path` is
    /// said ("link <target>"), and read through.
    static func preferenceParts(_ path: String) -> (said: String, keys: [String: String]?) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return ("absent", nil) }
        var said = ""
        if (info.st_mode & S_IFMT) == S_IFLNK {
            said = "link " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "") + " "
        }
        guard let data = ConfigSeal.regularContents(path, limit: preferencesLimit, followLink: true) else { return (said + "unreadable", nil) }
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let top = object as? [String: Any] else { return (said + "not a property list", nil) }
        var keys: [String: String] = [:]
        for (key, value) in top where !isChurn(key) {
            keys[key] = ConfigSeal.hex(SHA256.hash(data: Data(canonical(value).utf8)))
        }
        return (said + "plist", keys)
    }

    /// The per-key hashes of a preferences row (`ConfigSeal.keyHashes`): "<label>: <key>" for each file's keys ("" for
    /// the domain's own file, `ByHost/…` for the others), and "<label>" for one that isn't a property list now.
    static func preferenceKeys(_ path: String) -> [String: String] {
        var all: [String: String] = [:]
        let (folder, files) = preferenceFiles(path)
        all["ByHost"] = folder
        for file in files {
            let (said, keys) = preferenceParts(file.path)
            let label = file.label.isEmpty ? "" : file.label + ": "
            guard let keys else {
                all[file.label.isEmpty ? "file" : file.label] = said
                continue
            }
            if !said.hasPrefix("plist") { all[(file.label.isEmpty ? "file" : file.label) + " link"] = said }
            for (key, hash) in keys { all[label + key] = hash }
        }
        return all
    }

    /// A preferences row's hash: the ByHost folder's state, then each file's label, what it is and its keys' hashes in
    /// key order. Never nil: absent, unreadable and not a property list each hash as themselves.
    static func preferencesHash(_ path: String) -> String {
        var hasher = SHA256()
        let add = { (text: String) in hasher.update(data: Data((text + "\n").utf8)) }
        let (folder, files) = preferenceFiles(path)
        add("byhost \(folder)")
        for file in files {
            let (said, keys) = preferenceParts(file.path)
            add("file \(file.label.utf8.count):\(file.label) \(said)")
            for key in (keys ?? [:]).keys.sorted() { add("key \(key.utf8.count):\(key) \(keys?[key] ?? "")") }
        }
        return ConfigSeal.hex(hasher.finalize())
    }

    /// A property list value as text, the same for the same value whatever its file's format or key order, and
    /// different for a different type: each value tagged by its type, a dictionary's keys sorted, a string or key by
    /// its length first (so no text passes for two), nested values whole.
    static func canonical(_ value: Any) -> String {
        if let dictionary = value as? [String: Any] {
            return "{" + dictionary.keys.sorted().map { key in "k\(key.utf8.count):\(key)=" + canonical(dictionary[key] as Any) }.joined(separator: ",") + "}"
        }
        if let array = value as? [Any] { return "[" + array.map(canonical).joined(separator: ",") + "]" }
        if let string = value as? String { return "s\(string.utf8.count):\(string)" }
        if let data = value as? Data { return "d" + ConfigSeal.hex(data) }
        if let date = value as? Date { return "t\(date.timeIntervalSince1970)" }
        if let number = value as? NSNumber {
            // A plist's boolean is CFBoolean, whose type is a char ("c"); an integer a long long ("q"), a real a double.
            let type = String(cString: number.objCType)
            switch type {
            case "c", "B": return "b\(number.boolValue ? 1 : 0)"
            case "f", "d": return "r\(number.doubleValue)"
            default: return "i\(number.int64Value)"
            }
        }
        return "?\(type(of: value))"
    }
}
