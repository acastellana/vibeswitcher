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
        // Terminal's zsh sources a saved session here when it restores a window (`/etc/zshrc_Apple_Terminal`): only
        // the `*.session` files, and not one that holds only the restore line zsh writes (`sessionsHash`, R5).
        (".zsh_sessions", .sessions),
    ]

    /// The startup files whose `.` and `source` targets are watched (`LinuxSealList.sourced`): zsh's, the Mac's shell.
    public static let startupFiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin"]

    /// The ending of a file `zcompile` makes, which zsh reads in place of the file it was compiled from: for a startup
    /// file, and for each `.` or `source`, zsh opens `<file>.zwc` first and runs it when it is there and as new as
    /// `<file>` or `<file>` is absent (zsh 5.9's `try_source_file`; probed in scratch homes 2026-11-26: a newer
    /// `~/.zshrc.zwc` runs in place of `~/.zshrc`, `~/.zlogin.zwc` with no `~/.zlogin` runs at a login shell, a twin of a
    /// sourced `~/.cargo/env` at every `zsh -c`, one of a restore-line `<id>.session` at that window's restore, one of a
    /// shell snapshot at its session's next `source`; an upper-case `.ZWC` too, the volume ignoring case). The re-check's N1.
    static let twinSuffix = ".zwc"

    /// Whether `name` ends in `twinSuffix`, in any case (the home's volume ignores it, so zsh's open of `<file>.zwc`
    /// finds `<file>.ZWC`).
    static func isTwin(_ name: String) -> Bool {
        (name as NSString).range(of: twinSuffix, options: [.anchored, .backwards, .caseInsensitive]).location != NSNotFound
    }

    /// The zsh startup files whose compiled twins are rows (`<file>.zwc`, by contents, absent included, so one appearing
    /// is a change): `ConfigSeal.homeFiles`' zsh files (`.zlogout` among them) and `startupFiles`.
    static var twinnedStartupFiles: [String] {
        var files: [String] = []
        for file in ConfigSeal.homeFiles.map(\.0).filter({ $0.hasPrefix(".z") }) + startupFiles where !files.contains(file) {
            files.append(file)
        }
        return files
    }

    /// The rows outside the home, by their own path (their names): read only for the account's own home.
    public static let outsideEntries: [(String, ConfigSeal.Watched.Kind)] = [
        // Each link's target's line too (`readsLinkTargets`): a Cellar file rewritten in place behind a link (R7).
        ("/opt/homebrew/bin", .listing), ("/opt/homebrew/sbin", .listing),
        // What every login shell runs by `.zprofile`'s `eval "$(brew shellenv)"`: `bin/brew` (the listing's) sources
        // `brew.sh`, which sources `utils/os.sh` and `cmd/shellenv.sh`, then exits (R7; read 2026-11-26, each
        // `albert:admin` 0644 on this Mac, so the user's to write). By contents.
        ("/opt/homebrew/Library/Homebrew/brew.sh", .file), ("/opt/homebrew/Library/Homebrew/utils/os.sh", .file),
        ("/opt/homebrew/Library/Homebrew/cmd/shellenv.sh", .file),
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
        // Each zsh startup file's compiled twin, which zsh runs in place of it (N1).
        items += twinnedStartupFiles.map { file in
            ConfigSeal.Watched(name: "~/" + file + twinSuffix, path: (home as NSString).appendingPathComponent(file + twinSuffix), kind: .file)
        }
        var names = Set(items.map(\.name))
        names.formUnion(ConfigSeal.homeFiles.map { "~/" + $0.0 })
        LinuxSealList.addSourced(from: startupFiles, home: home, names: &names, to: &items, twins: true)
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

    /// The listings whose links' targets are read too (`LinuxSealList.targetLine`): Homebrew's `bin` and `sbin`, about
    /// 1,200 links on this Mac, one `stat` each.
    static let linkTargetListings: Set<String> = ["/opt/homebrew/bin", "/opt/homebrew/sbin"]

    /// Whether the listing named `name` reads its links' targets (`linkTargetListings`); never a Linux row.
    static func readsLinkTargets(_ name: String) -> Bool { linkTargetListings.contains(name) }

    // MARK: Saved Terminal sessions (`ConfigSeal.Watched.Kind.sessions`)

    /// The restore line `/etc/zshrc_Apple_Terminal` writes first in each session file, around the save's time: its
    /// restore sources a file whose first line is exactly this form, and its save writes nothing else unless the user
    /// set save hooks (`shell_session_save_user_state`). Read from that file on this Mac (2026-11-26), never run.
    static let restorePrefix = "echo Restored session: \"$(/bin/date -r "
    static let restoreSuffix = ")\"\n"

    /// Whether `data` is a session file zsh writes with no save hooks: the restore line alone (its time in 1 to 20
    /// digits), which runs `echo` and `/bin/date` only.
    static func isRestoreLineOnly(_ data: Data) -> Bool {
        let bytes = [UInt8](data), prefix = Array(restorePrefix.utf8), suffix = Array(restoreSuffix.utf8)
        guard bytes.count > prefix.count + suffix.count, bytes.starts(with: prefix), bytes.suffix(suffix.count).elementsEqual(suffix) else { return false }
        let digits = bytes[prefix.count..<(bytes.count - suffix.count)]
        return (1...20).contains(digits.count) && digits.allSatisfy { (0x30...0x39).contains($0) }
    }

    /// The session files a sessions row reads: the folder's own state ("absent", "unreadable", "not a folder", or
    /// "folder" with its mode and owner, after "link <target> " when it is a link, read through it), and each entry
    /// whose name ends `.session` in any case (the volume ignores case, as zsh's open of `<id>.session` does), by name,
    /// in the order of their bytes, with what it is: a regular file by its bytes ("bytes <digest>"), nil when it holds
    /// only the restore line (`isRestoreLineOnly`: what a window's close writes, which comes and goes with every
    /// close and restore and runs nothing); anything else (a link, with its target, read through; a folder; another
    /// kind; unreadable) by what it is. `.history` files are left out: zsh reads them as history (`fc -R`), never runs them.
    static func sessionFiles(_ path: String) -> (folder: String, files: [(name: String, said: String?)]) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return ("absent", []) }
        var said = ""
        if (info.st_mode & S_IFMT) == S_IFLNK {
            said = linkSaid(path)
            guard stat(path, &info) == 0 else { return (said + "absent", []) }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return (said + "not a folder", []) }
        let folder = said + "folder \(info.st_mode & 0o7777) \(info.st_uid)"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return (folder + " unreadable", []) }
        let ends = { (name: String, suffix: String) in
            (name as NSString).range(of: suffix, options: [.anchored, .backwards, .caseInsensitive]).location != NSNotFound
        }
        // A saved session's compiled twin (`<id>.session.zwc`, N1) is what the restore's `.` runs in its place: read by
        // its bytes, never as the restore line, whatever it holds.
        let sessions = names.filter { ends($0, ".session") || ends($0, ".session" + twinSuffix) }
        var files: [(name: String, said: String?)] = []
        for name in sessions.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
            let file = (path as NSString).appendingPathComponent(name)
            var entry = stat()
            guard lstat(file, &entry) == 0 else { continue }
            var what = ""
            if (entry.st_mode & S_IFMT) == S_IFLNK {
                what = linkSaid(file)
            } else if !isTwin(name), (entry.st_mode & S_IFMT) == S_IFREG, let data = ConfigSeal.regularContents(file, limit: 4096, followLink: false),
                      isRestoreLineOnly(data) {
                files.append((name, nil))
                continue
            }
            switch ConfigSeal.contentsDigest(file, followLink: true) {
            case .digest(let digest): what += "bytes " + digest
            case .other: what += "other"
            case .unreadable: what += "unreadable"
            }
            files.append((name, what))
        }
        return (folder, files)
    }

    /// What a link at `path` is said as in a sessions or preferences hash: "link <length>:<target> ", its target's bytes
    /// as text with their count first (`linkTarget`), so no target's name can spell the lines after it (the re-check's
    /// N2: a target may hold newlines).
    static func linkSaid(_ path: String) -> String { "link " + linkTarget(path) + " " }

    /// The target of the link at `path`, unambiguous: "<count of its bytes>:<its text>" when its bytes are UTF-8, else
    /// "x<its bytes in hex>"; "?" when it can't be read (it was replaced between the `lstat` and this read).
    static func linkTarget(_ path: String) -> String {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            pointer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pointer.count) { readlink(path, $0, pointer.count) }
        }
        guard count >= 0 else { return "?" }
        let bytes = Array(buffer.prefix(count))
        guard let text = String(bytes: bytes, encoding: .utf8) else { return "x" + ConfigSeal.hex(bytes) }
        return "\(bytes.count):\(text)"
    }

    /// A sessions row's hash: the folder's state, then each session file that isn't the restore line alone, by name
    /// and bytes (`sessionFiles`). So a window's close or restore changes nothing, and a line added to a saved session,
    /// or a session file of another form coming, changing or going, is a change.
    static func sessionsHash(_ path: String) -> String {
        var hasher = SHA256()
        let (folder, files) = sessionFiles(path)
        hasher.update(data: Data("sessions \(folder)\n".utf8))
        for file in files {
            guard let said = file.said else { continue }
            hasher.update(data: Data("\(file.name.utf8.count):\(file.name) \(said)\n".utf8))
        }
        return ConfigSeal.hex(hasher.finalize())
    }

    /// A sessions row's per-key hashes, for the card: "folder", and each session file that isn't the restore line
    /// alone, by name.
    static func sessionKeys(_ path: String) -> [String: String] {
        let (folder, files) = sessionFiles(path)
        var keys = ["folder": folder]
        for file in files { if let said = file.said { keys[file.name] = said } }
        return keys
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

    /// Whether `key` (a top-level key) is left out of the hash: compared by its UTF-8 bytes, never by Swift's `==`,
    /// which takes canonically equal strings for one (the review's R3).
    static func isChurn(_ key: String) -> Bool {
        churnKeys.contains { $0.utf8.elementsEqual(key.utf8) } || key.utf8.starts(with: churnPrefix.utf8)
    }

    /// A preferences file read whole at most: past it, it's hashed by its bytes (`preferenceParts`).
    static let preferencesLimit = 16 << 20

    /// The files a preferences row reads: the domain's file at `path`, and each `ByHost/<domain>.*.plist` beside it,
    /// its name matched in any case and any Unicode form (the home's volume ignores both by default, so cfprefsd's open
    /// of the current host's file by the name it builds finds a file named in another case: the review's R1). Each
    /// with its label: "" for the file, the `ByHost/…` name for the others; and the ByHost folder's own state:
    /// "absent", "unreadable", "not a folder", or "folder", after "link <target> " when it is a link, read through
    /// it (R2: a linked folder's files are read, and its target is in the hash).
    static func preferenceFiles(_ path: String) -> (folder: String, files: [(label: String, path: String)]) {
        let folder = (path as NSString).deletingLastPathComponent
        let domain = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let byHost = (folder as NSString).appendingPathComponent("ByHost")
        var files: [(label: String, path: String)] = [("", path)]
        var info = stat()
        guard lstat(byHost, &info) == 0 else { return ("absent", files) }
        var said = ""
        if (info.st_mode & S_IFMT) == S_IFLNK {
            said = linkSaid(byHost)
            guard stat(byHost, &info) == 0 else { return (said + "absent", files) }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return (said + "not a folder", files) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: byHost) else { return (said + "unreadable", files) }
        let matching = names.filter { name in
            let text = name as NSString
            return text.range(of: domain + ".", options: [.anchored, .caseInsensitive]).location != NSNotFound
                && text.range(of: ".plist", options: [.anchored, .backwards, .caseInsensitive]).location != NSNotFound
        }
        for name in matching.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
            files.append(("ByHost/" + name, (byHost as NSString).appendingPathComponent(name)))
        }
        return (said + "folder", files)
    }

    /// One preferences file's top-level keys, each hashed in its canonical form (`canonical`), churn left out, in the
    /// order of their UTF-8 bytes (two keys that are canonically equal are two keys, as they are to CFPreferences:
    /// R3); or what it is instead: "absent", "unreadable", or a file read but not taken apart ("bytes <digest>" past
    /// `preferencesLimit`, "not a property list <digest>"), by its bytes, so every rewrite of it is a change (R2b);
    /// never nothing to compare. A link at `path` is said ("link <target>"), and read through.
    static func preferenceParts(_ path: String) -> (said: String, keys: [(key: String, form: String, hash: String)]?) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return ("absent", nil) }
        var said = ""
        if (info.st_mode & S_IFMT) == S_IFLNK {
            said = linkSaid(path)
        }
        let bytes = { () -> String in
            switch ConfigSeal.contentsDigest(path, followLink: true) {
            case .digest(let digest): return digest
            case .other: return "other"
            case .unreadable: return "unreadable"
            }
        }
        guard let data = ConfigSeal.regularContents(path, limit: preferencesLimit, followLink: true) else {
            let digest = bytes()
            return (said + (digest == "unreadable" || digest == "other" ? digest : "bytes " + digest), nil)
        }
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let top = object as? NSDictionary else {
            return (said + "not a property list " + ConfigSeal.hex(SHA256.hash(data: data)), nil)
        }
        let keys = pairs(top).filter { !isChurn($0.key) }.map { pair in
            (key: pair.key, form: pair.form, hash: ConfigSeal.hex(SHA256.hash(data: Data(canonical(pair.value).utf8))))
        }
        return (said + "plist", keys)
    }

    /// The per-key hashes of a preferences row (`ConfigSeal.keyHashes`): "<label>: <key>" for each file's keys ("" for
    /// the domain's own file, `ByHost/…` for the others), and "<label>" for one that isn't a property list now. A key
    /// canonically equal to one already named, or read the same (two that differ by a lone surrogate, N6), is named
    /// with its form's bytes after it (`form`), so the card names each (the hash has both anyway).
    static func preferenceKeys(_ path: String) -> [String: String] {
        var all: [String: String] = [:]
        let put = { (name: String, value: String, form: String?) in
            let unique = all[name] == nil ? name : name + " [" + ConfigSeal.hex(Data((form ?? name).utf8)) + "]"
            all[unique] = value
        }
        let (folder, files) = preferenceFiles(path)
        put("ByHost", folder, nil)
        for file in files {
            let (said, keys) = preferenceParts(file.path)
            let label = file.label.isEmpty ? "" : file.label + ": "
            guard let keys else {
                put(file.label.isEmpty ? "file" : file.label, said, nil)
                continue
            }
            if !said.hasPrefix("plist") { put((file.label.isEmpty ? "file" : file.label) + " link", said, nil) }
            for key in keys { put(label + key.key, key.hash, label + key.form) }
        }
        return all
    }

    /// A preferences row's hash: the ByHost folder's state, then each file's label, what it is and its keys' hashes in
    /// their bytes' order. Never nil: absent, unreadable and not a property list each hash as themselves. From the
    /// files alone, never through CFPreferences: a long-lived process keeps its first read of a domain (measured
    /// 2026-11-26: a path domain rewritten on disk read its old value a second later in the same process, after
    /// `CFPreferencesAppSynchronize`, and its new one in a new process), and the node's server and its vault each
    /// fingerprint the row in their own process.
    static func preferencesHash(_ path: String) -> String {
        var hasher = SHA256()
        let add = { (text: String) in hasher.update(data: Data((text + "\n").utf8)) }
        let (folder, files) = preferenceFiles(path)
        add("byhost \(folder)")
        for file in files {
            let (said, keys) = preferenceParts(file.path)
            add("file \(file.label.utf8.count):\(file.label) \(said)")
            for key in keys ?? [] { add("key \(key.form) \(key.hash)") }
        }
        return ConfigSeal.hex(hasher.finalize())
    }

    /// A dictionary's keys and values, in the order of the keys' UTF-8 bytes (then of their forms, for two keys that
    /// read the same: N6), each key with its form (`form`). Walked as `NSDictionary` with its own keys: bridged to
    /// `[String: Any]`, two keys that are canonically equal (an NFC and an NFD "Café", two keys to CFDictionary, which
    /// compares code points) would be one, and one value would be dropped (R3).
    static func pairs(_ dictionary: NSDictionary) -> [(key: String, form: String, value: Any)] {
        var pairs: [(key: String, form: String, value: Any, bytes: [UInt8])] = []
        dictionary.enumerateKeysAndObjects { key, value, _ in
            let text = (key as? NSString).map { $0 as String } ?? "?\(type(of: key))\(key)"
            let form = (key as? NSString).map(form) ?? "\(text.utf8.count):\(text)"
            pairs.append((text, form, value, Array(text.utf8)))
        }
        return pairs.sorted { $0.bytes == $1.bytes ? Array($0.form.utf8).lexicographicallyPrecedes(Array($1.form.utf8))
            : $0.bytes.lexicographicallyPrecedes($1.bytes) }.map { ($0.key, $0.form, $0.value) }
    }

    /// A string or key as the hash takes it, one form per string of UTF-16 code units (what a binary property list stores
    /// and CFString compares): "<count of its UTF-8 bytes>:<it>" when it is valid Unicode (the form before N6, so such a
    /// string hashes as it did), "u<count of its code units>:<them in hex>" when it holds a lone surrogate, which
    /// Swift's `String` reads as U+FFFD (the re-check's N6: `P\u{D800}` and `P\u{DC00}` would read the same).
    static func form(_ text: NSString) -> String {
        var units = [unichar](repeating: 0, count: text.length)
        text.getCharacters(&units, range: NSRange(location: 0, length: text.length))
        var index = 0, lone = false
        while index < units.count, !lone {
            if UTF16.isLeadSurrogate(units[index]), index + 1 < units.count, UTF16.isTrailSurrogate(units[index + 1]) {
                index += 2
            } else {
                lone = UTF16.isLeadSurrogate(units[index]) || UTF16.isTrailSurrogate(units[index])
                index += 1
            }
        }
        guard lone else {
            let string = text as String
            return "\(string.utf8.count):\(string)"
        }
        return "u\(units.count):" + units.map { String(format: "%04x", $0) }.joined()
    }

    /// A property list value as text, the same for the same value whatever its file's format or key order, and
    /// different for a different type: each value tagged by its type, a dictionary's keys in their bytes' order
    /// (`pairs`), a string or key by its length first (so no text passes for two), nested values whole.
    static func canonical(_ value: Any) -> String {
        if let dictionary = value as? NSDictionary {
            return "{" + pairs(dictionary).map { "k" + $0.form + "=" + canonical($0.value) }.joined(separator: ",") + "}"
        }
        if let text = value as? NSString { return "s" + form(text) }
        if let data = value as? Data { return "d" + ConfigSeal.hex(data) }
        if let date = value as? Date { return "t\(date.timeIntervalSince1970)" }
        if let number = value as? NSNumber {
            // A plist's boolean is CFBoolean, whose type is a char ("c"); an integer a long long ("q"), a real a double;
            // an unsigned 64-bit one ("Q") is tagged apart, so UInt64.max isn't -1 (R4).
            let type = String(cString: number.objCType)
            switch type {
            case "c", "B": return "b\(number.boolValue ? 1 : 0)"
            case "f", "d": return "r\(number.doubleValue)"
            case "Q": return "u\(number.uint64Value)"
            default: return "i\(number.int64Value)"
            }
        }
        if let array = value as? NSArray { return "[" + array.map(canonical).joined(separator: ",") + "]" }
        return "?\(type(of: value))"
    }
}
