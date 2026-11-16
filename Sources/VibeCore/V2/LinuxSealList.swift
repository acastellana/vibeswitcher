import Foundation

/// The config seal's Linux list (the start plan's S7; the bootstrap path's step 8; ST-D18 to ST-D20): what, besides the
/// Mac's `ConfigSeal.homeFiles`, a worker's shell can change on the node that the next session, the node's unit or its
/// tools run. One hook line in `ConfigSeal.homeWatched(home:)` appends it; it is empty on the Mac
/// (`Platform.CodeIdentity.isAvailable`), so the Mac's seal is today's.
///
/// - The home's entries (`homeEntries`), what the startup files source (`sourced`), and node's version folder (the
///   parent of the unit's node `bin`, else each of nvm's versions).
/// - Outside the home, only for the account's own home (the user database's; a scratch home's seal reads nothing
///   outside it): `/run/user/<uid>/systemd/transient` and `user.control` (the manager's drop-ins of the highest
///   priority, ST-D20), and while `/mnt/c` is a 9p or drvfs mount, each Windows user's `.wslconfig` and Startup folder.
/// - Every entry executes: none is in `ConfigSeal.instructions`, so a change waits for the user's accept whoever made it.
///
/// Large folders are read by their metadata (`Kind.listing`, ST-D18), never their contents; the folders every session's
/// start writes into take `Kind.entries` (ST-D19): an entry added or removed is no change (`cameOrWent`).
public enum LinuxSealList {
    /// The home's entries, by path under it.
    public static let homeEntries: [(String, ConfigSeal.Watched.Kind)] = [
        // What the startup files source here (Step 0's check, the Linux inventory), and swiftly's choice of toolchain.
        (".bash_aliases", .file), (".nvm/nvm.sh", .file), (".nvm/bash_completion", .file),
        ("projects/rally/.rally-aliases", .file), (".local/share/swiftly/env.sh", .file),
        (".local/share/swiftly/config.json", .file),
        // First on the PATH of the shells that read `.profile`.
        ("bin", .folder),
        // Each session writes its snapshot here, and sources it before each command (ST-D19).
        (".claude/shell-snapshots", .entries), (".codex/shell-snapshots", .entries),
        // The user manager's units, drop-ins, environment and autostart.
        (".config/systemd/user", .folder), (".config/systemd/user.control", .folder), (".config/systemd/user.conf.d", .folder),
        (".config/environment.d", .folder), (".config/autostart", .folder), (".config/systemd/user.conf", .file),
        (".local/share/systemd/user", .folder),
        // gh's config and token: by metadata, so the token is never read.
        (".config/gh", .listing),
        // The node's allowed projects, its installed builds, the roles' launch files and the lead's accepted hooks.
        (".vibeswitcher/v2/projects", .file),
        (".vibeswitcher/v2/builds", .listing),
        (".vibeswitcher/lead/run", .entries),
        (".vibeswitcher/lead/git-hooks", .entries),
        // On the PATH, and the tools team sessions run: Claude Code, swiftly's toolchains and proxies.
        (".local/bin", .listing),
        (".local/share/claude/versions", .listing),
        (".local/share/swiftly/toolchains", .listing),
        (".local/share/swiftly/bin", .listing),
    ]

    /// The startup files whose `.` and `source` targets are watched (`sourced`).
    public static let startupFiles = [".bashrc", ".profile", ".bash_profile", ".bash_login"]

    /// The unit `vs start` writes, whose PATH names node's `bin` (`NodeStarter.unitName`, in `VibeNode`).
    static let unitFile = ".config/systemd/user/vibeswitcher-node.service"

    /// Where nvm keeps node's versions.
    static let nvmVersions = ".nvm/versions/node"

    /// The Windows users not watched: shared folders, no one's own.
    static let notUsers: Set<String> = ["Public", "Default", "All Users"]

    /// Under a Windows user's folder: the files Windows runs at its sign-in, and WSL's own config.
    static let windowsStartup = "AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup"

    /// The list for `home` (the account `uid`'s), empty on the Mac. `mounts` tells whether `/mnt/c` is mounted.
    /// `outside`: where the entries outside the home are read (their names stay `/run/user/…` and `/mnt/c/…`); nil
    /// reads them at `/` for the account's own home (the user database's), and leaves them out for any other.
    public static func watched(home: String, uid: uid_t, mounts: String = "/proc/mounts", outside: String? = nil) -> [ConfigSeal.Watched] {
        guard !Platform.CodeIdentity.isAvailable else { return [] }
        var items = homeEntries.map { entry in item(home: home, relative: entry.0, kind: entry.1) }
        var names = Set(items.map(\.name))
        names.formUnion(ConfigSeal.homeFiles.map { "~/" + $0.0 })
        for file in startupFiles {
            guard let data = ConfigSeal.regularContents((home as NSString).appendingPathComponent(file), limit: 1 << 20) else { continue }
            for path in sourced(startupFile: String(decoding: data, as: UTF8.self), home: home) {
                let watched = ConfigSeal.Watched(name: ConfigSeal.shown(path, home: home), path: path, kind: .file)
                if names.insert(watched.name).inserted { items.append(watched) }
            }
        }
        items += nodeFolders(home: home).map { ConfigSeal.Watched(name: ConfigSeal.shown($0, home: home), path: $0, kind: .listing) }
        if let root = outside ?? (isAccountHome(home, uid: uid) ? "/" : nil) {
            items += outsideEntries(uid: uid, mounts: mounts, root: root)
        }
        return items
    }

    static func item(home: String, relative: String, kind: ConfigSeal.Watched.Kind) -> ConfigSeal.Watched {
        ConfigSeal.Watched(name: "~/" + relative, path: (home as NSString).appendingPathComponent(relative), kind: kind)
    }

    /// Whether `home` is the account's own (the user database's for `uid`), however it's spelled.
    static func isAccountHome(_ home: String, uid: uid_t) -> Bool {
        guard let own = getpwuid(uid).map({ String(cString: $0.pointee.pw_dir) }) else { return false }
        let resolved = { (path: String) in URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
        return resolved(home) == resolved(own)
    }

    /// Each `.` or `source` target in a startup file's `text` written `~/…`, `$HOME/…`, `${HOME}/…` or by `home`'s own
    /// path, quoted or not, as a path under `home`, in order, once each. What a variable other than HOME names (nvm's
    /// `$NVM_DIR`) is left to the static entries; a comment line's, and anything outside the home, are left out.
    public static func sourced(startupFile text: String, home: String) -> [String] {
        let homes = [#"~"#, #"\$HOME"#, #"\$\{HOME\}"#, NSRegularExpression.escapedPattern(for: home)].joined(separator: "|")
        let pattern = #"(?:^|[\s;&|(){}`])\\?(?:\.|source)[ \t]+["']?(?:"# + homes + #")(/[^\s"';&|()<>`$]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { continue }
            for match in expression.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let range = Range(match.range(at: 1), in: line) else { continue }
                let path = ((home as NSString).appendingPathComponent(String(line[range])) as NSString).standardizingPath
                guard path.hasPrefix(home + "/"), !found.contains(path) else { continue }
                found.append(path)
            }
        }
        return found
    }

    /// Node's version folder: the parent of each node `bin` under nvm's versions on the unit's PATH when the unit
    /// exists and names one, else each of nvm's versions (`v*`).
    static func nodeFolders(home: String) -> [String] {
        let versions = (home as NSString).appendingPathComponent(nvmVersions)
        if let data = ConfigSeal.regularContents((home as NSString).appendingPathComponent(unitFile), limit: 1 << 20) {
            var folders: [String] = []
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("Environment=") {
                let words = line.dropFirst("Environment=".count).replacingOccurrences(of: "\"", with: "").split(whereSeparator: \.isWhitespace)
                for word in words where word.hasPrefix("PATH=") {
                    for folder in word.dropFirst("PATH=".count).split(separator: ":").map(String.init)
                    where folder.hasPrefix(versions + "/") && folder.hasSuffix("/bin") {
                        let parent = (folder as NSString).deletingLastPathComponent
                        if !folders.contains(parent) { folders.append(parent) }
                    }
                }
            }
            if !folders.isEmpty { return folders }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: versions)) ?? []
        return names.filter { $0.hasPrefix("v") }.sorted().map { (versions as NSString).appendingPathComponent($0) }
    }

    /// The entries outside the home, read under `root` ("/" on the node): the manager's runtime drop-ins, and the
    /// Windows files while `/mnt/c` is mounted.
    static func outsideEntries(uid: uid_t, mounts: String, root: String) -> [ConfigSeal.Watched] {
        let at = { (name: String) in root == "/" ? name : (root as NSString).appendingPathComponent(name) }
        var items = ["transient", "user.control"].map { folder in
            let name = "/run/user/\(uid)/systemd/\(folder)"
            return ConfigSeal.Watched(name: name, path: at(name), kind: .folder)
        }
        guard windowsMounted(mounts) else { return items }
        let users = "/mnt/c/Users"
        for user in ((try? FileManager.default.contentsOfDirectory(atPath: at(users))) ?? []).sorted() where !notUsers.contains(user) {
            // Folders only: a junction (`Default User`) or a file (`desktop.ini`) is no user's.
            var info = stat()
            guard lstat(at(users + "/" + user), &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            let wslconfig = users + "/" + user + "/.wslconfig"
            let startup = users + "/" + user + "/" + windowsStartup
            items.append(ConfigSeal.Watched(name: wslconfig, path: at(wslconfig), kind: .file))
            // By metadata: read over 9p, and a shortcut's contents aren't what a change is told by.
            items.append(ConfigSeal.Watched(name: startup, path: at(startup), kind: .listing))
        }
        return items
    }

    /// Whether the mounts file at `path` (`/proc/mounts`' form) has `/mnt/c` as a 9p or drvfs mount.
    static func windowsMounted(_ path: String) -> Bool {
        guard let data = FileHandle(forReadingAtPath: path).map({ handle in
            defer { handle.closeFile() }
            return handle.readDataToEndOfFile()
        }) else { return false }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").contains { line in
            let fields = line.split(separator: " ")
            return fields.count >= 3 && fields[1] == "/mnt/c" && (fields[2] == "9p" || fields[2] == "drvfs")
        }
    }

    // MARK: Listings (ST-D18)

    /// A listing's hash: the thing at `path` and each entry under it (links never followed, every one, no cap), each
    /// by its relative name, type, mode, size, inode, mtime and ctime with nanoseconds, and a link's target; never a
    /// file's contents. A write changes ctime, which no one can set back. Absent: hashes as absent.
    static func listingHash(_ path: String) -> String {
        var hasher = SHA256()
        let add = { (text: String) in hasher.update(data: Data((text + "\n").utf8)) }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            hasher.update(data: Data("absent".utf8))
            return ConfigSeal.hex(hasher.finalize())
        }
        add("listing " + line(info, path: path, relative: ""))
        walk(path, relative: "", add)
        return ConfigSeal.hex(hasher.finalize())
    }

    /// One entry's line: its name (its length first, so no name can pass for two), type, mode, size, inode, times.
    private static func line(_ info: stat, path: String, relative: String) -> String {
        let type: String
        switch info.st_mode & S_IFMT {
        case S_IFDIR: type = "d"
        case S_IFLNK: type = "l"
        case S_IFREG: type = "f"
        default: type = "o"
        }
        let modified = Platform.Files.modified(info), changed = Platform.Files.changed(info)
        var text = "\(type) \(relative.utf8.count):\(relative) \(info.st_mode & 0o7777) \(info.st_size) \(info.st_ino) "
            + "\(modified.tv_sec).\(modified.tv_nsec) \(changed.tv_sec).\(changed.tv_nsec)"
        if type == "l" { text += " -> " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "") }
        return text
    }

    /// Each entry under `folder` in name order, depth first: folders entered, links never followed.
    private static func walk(_ folder: String, relative: String, _ add: (String) -> Void) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
            add("unreadable \(relative.utf8.count):\(relative)")
            return
        }
        for name in names.sorted() {
            let path = (folder as NSString).appendingPathComponent(name)
            let shown = relative.isEmpty ? name : relative + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            add(line(info, path: path, relative: shown))
            if (info.st_mode & S_IFMT) == S_IFDIR { walk(path, relative: shown, add) }
        }
    }

    // MARK: Entries (ST-D19)

    /// The names of the folders read as `.entries`.
    static var entriesNames: Set<String> { Set(homeEntries.filter { $0.1 == .entries }.map { "~/" + $0.0 }) }

    /// The lead's accepted hooks record (`GitGuard.Accepted`, `<git-hooks>/<repository key>/accepted.json`): its `told`
    /// flag, which the lead's tool server sets once it told the lead of a baseline, isn't a change of what runs.
    static let acceptedRecord = "accepted.json"

    /// A folder of `.entries`, read as `ConfigSeal.readFolder` reads a folder (its hash is that one's), with the hooks
    /// record's per-path hash taken without its `told` flag (`acceptedRecord`), so that alone is no change in place.
    static func readEntries(_ watched: ConfigSeal.Watched) -> ConfigSeal.FolderRead {
        var read = ConfigSeal.readFolder(watched)
        guard watched.name == "~/.vibeswitcher/lead/git-hooks" else { return read }
        for (path, entry) in read.entries {
            let parts = path.split(separator: "/")
            guard parts.count == 2, parts[1] == Substring(acceptedRecord), entry.split(separator: " ").dropFirst().first == "f" else { continue }
            let file = (watched.path as NSString).appendingPathComponent(path)
            var info = stat()
            guard lstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  let data = ConfigSeal.regularContents(file, limit: 1 << 20, followLink: false),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            object["told"] = nil
            guard let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { continue }
            let line = "f \(path) \(info.st_mode & 0o777) told-free " + ConfigSeal.hex(SHA256.hash(data: canonical))
            var words = entry.split(separator: " ").map(String.init)
            words[0] = ConfigSeal.hex(SHA256.hash(data: Data(line.utf8)).prefix(8))
            read.entries[path] = words.joined(separator: " ")
        }
        return read
    }

    /// For the vault's look (`LeadVault`'s `judge`): when `key` names a folder of `.entries` that `recorded` has sealed
    /// and that changed by entries added or removed only (none of the ones in both changed in place, by their
    /// `FolderRead.entries` hashes), the per-path hashes to record with `now`'s hash: `now`'s, with the removed ones
    /// kept, so one that comes back changed is a change. nil otherwise: judged as ever.
    static func cameOrWent(key: String, recorded: [String: String], now: [String: String]) -> String? {
        guard entriesNames.contains(ConfigSeal.name(ofKey: key)), let was = recorded[key], let hash = now[key], was != hash,
              let before = recorded[ConfigSeal.keysKey(of: key)], let after = now[ConfigSeal.keysKey(of: key)] else { return nil }
        let old = ConfigSeal.decode(before), new = ConfigSeal.decode(after)
        for (path, entry) in old {
            if let current = new[path], ConfigSeal.entryHash(current) != ConfigSeal.entryHash(entry) { return nil }
        }
        return ConfigSeal.encode(old.merging(new) { $1 })
    }
}
