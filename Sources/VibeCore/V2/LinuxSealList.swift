import Foundation

/// The config seal's Linux list (the start plan's S7; the bootstrap path's step 8; ST-D18 to ST-D20): what, besides the
/// Mac's `ConfigSeal.homeFiles`, a worker's shell can change on the node that the next session, the node's unit or its
/// tools run. One hook line in `ConfigSeal.homeWatched(home:)` appends it; it is empty on the Mac
/// (`Platform.CodeIdentity.isAvailable`), so the Mac's seal is today's.
///
/// - The home's entries (`homeEntries`, nvm's node versions and its alias among them) and what the startup files source
///   (`sourced`).
/// - Outside the home, only for the account's own home (the user database's; a scratch home's seal reads nothing
///   outside it): `/run/user/<uid>/systemd/transient`, `user.control` and `user` (the manager's runtime units and
///   drop-ins, on its search path ahead of `~/.local/share/systemd/user`, ST-D20), and while `/mnt/c` is a 9p or drvfs
///   mount, each Windows user's `.wslconfig` and Startup folder.
///   The `transient` folder takes `.entries`: a scope's unit file comes and goes with an app's scope
///   (`transientEntryMayCome`); anything else in it is a change.
/// - Every entry executes: none is in `ConfigSeal.instructions`, so a change waits for the user's accept whoever made it.
///
/// Large folders are read by their metadata (`Kind.listing`, ST-D18), never their contents; the folders every session's
/// start writes into take `Kind.entries` (ST-D19): an entry added or removed is no change (`cameOrWent`), but in the
/// lead's accepted hooks only a fresh repository's baseline comes so (`hookEntryMayCome`), and in the roles' launch
/// folders only a launch the vault recorded (`launchEntryMayCome`).
public enum LinuxSealList {
    /// The home's entries, by path under it.
    public static let homeEntries: [(String, ConfigSeal.Watched.Kind)] = [
        // What the startup files source here (Step 0's check, the Linux inventory), and swiftly's choice of toolchain.
        (".bash_aliases", .file), (".nvm/nvm.sh", .file), (".nvm/bash_completion", .file),
        // nvm's node versions, all of them (a new one is a change), and its alias: `nvm.sh` uses `alias/default`'s in
        // every new shell, so it picks the node, npm and global CLIs each session runs.
        (".nvm/versions/node", .listing), (".nvm/alias", .listing),
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
        // The launch presets (`SessionPresets`, the composer's lane, 2026-11-20): a variable or argument planted in one
        // runs in the session the user later starts from it; while a change is held, no preset starts.
        (".vibeswitcher/presets.json", .file),
        // The user's known Startup shortcuts (`StartupShortcuts`): a line added is a held change.
        (StartupShortcuts.listFile, .file),
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

    /// The entries outside the home, read under `root` ("/" on the node): the manager's runtime units and drop-ins, and
    /// the Windows files while `/mnt/c` is mounted. Its generator folders aren't: the manager empties them at each reload.
    static func outsideEntries(uid: uid_t, mounts: String, root: String) -> [ConfigSeal.Watched] {
        let at = { (name: String) in root == "/" ? name : (root as NSString).appendingPathComponent(name) }
        // `transient` takes `.entries`: the manager writes a scope's unit file there each time an app registers its
        // own scope (a browser's start), and removes it as the app exits (`transientEntryMayCome`).
        var items = ["transient", "user.control", "user"].map { folder in
            let name = "/run/user/\(uid)/systemd/\(folder)"
            return ConfigSeal.Watched(name: name, path: at(name), kind: folder == "transient" ? .entries : .folder)
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
    /// file's contents. A write changes ctime, which no one can set back. Absent: hashes as absent. A Windows user's
    /// Startup folder the user's known-startup list names shortcuts of: each known shortcut by its line, and the
    /// folder's own line without its times (`StartupShortcuts`).
    static func listingHash(_ path: String) -> String {
        var hasher = SHA256()
        let add = { (text: String) in hasher.update(data: Data((text + "\n").utf8)) }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            hasher.update(data: Data("absent".utf8))
            return ConfigSeal.hex(hasher.finalize())
        }
        var known: [String: StartupShortcuts.Known] = [:]
        if let startup = StartupShortcuts.startupFolder(path), let list = StartupShortcuts.list(root: startup.root),
           list.contains(where: { $0.user == startup.user }), (info.st_mode & S_IFMT) == S_IFDIR {
            known = StartupShortcuts.knownEntries(in: path, user: startup.user, list: list)
            add("listing known-startup d \(info.st_mode & 0o7777)")
        } else {
            add("listing " + line(info, path: path, relative: ""))
        }
        walk(path, relative: "", known: known, add)
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

    /// Each entry under `folder` in name order, depth first: folders entered, links never followed; a top-level entry
    /// `known` names by its known line.
    private static func walk(_ folder: String, relative: String, known: [String: StartupShortcuts.Known] = [:], _ add: (String) -> Void) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
            add("unreadable \(relative.utf8.count):\(relative)")
            return
        }
        for name in names.sorted() {
            let path = (folder as NSString).appendingPathComponent(name)
            let shown = relative.isEmpty ? name : relative + "/" + name
            if let line = known[name] {
                add(line.hashLine)
                continue
            }
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            add(line(info, path: path, relative: shown))
            if (info.st_mode & S_IFMT) == S_IFDIR { walk(path, relative: shown, add) }
        }
    }

    // MARK: Entries (ST-D19)

    /// The names of the folders read as `.entries` in the home (the manager's `transient` folder is one too:
    /// `isTransient`).
    static var entriesNames: Set<String> { Set(homeEntries.filter { $0.1 == .entries }.map { "~/" + $0.0 }) }

    /// Whether `name` is the manager's runtime units folder, `/run/user/<uid>/systemd/transient` (`outsideEntries`).
    static func isTransient(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 6 && parts[0].isEmpty && parts[1] == "run" && parts[2] == "user" && !parts[3].isEmpty
            && parts[3].allSatisfy(\.isASCII) && parts[3].allSatisfy(\.isNumber) && parts[4] == "systemd" && parts[5] == "transient"
    }

    /// The lead's accepted hooks (`GitGuard.store`): `<repository key>/accepted.json` and `<repository key>/copy/`.
    static var hooksName: String { "~/.vibeswitcher/lead/git-hooks" }

    /// The lead's accepted hooks record (`GitGuard.Accepted`, `<git-hooks>/<repository key>/accepted.json`): its `told`
    /// flag, which the lead's tool server sets once it told the lead of a baseline, isn't a change of what runs.
    static let acceptedRecord = "accepted.json"

    /// The per-path entry a read cut at `ConfigSeal.maxEntries` carries (no relative path starts with "/"): past the
    /// cut an entry is unseen, so a folder read so is judged as ever (`cameOrWent`), never as entries come and gone.
    static let cutEntry = "/cut"

    /// The per-path entry a folder that couldn't be listed carries, followed by its relative path (`/unreadable/` for
    /// the watched folder itself): what's under it is unseen, as past a cut (a worker's `chmod 000` hides it, then puts
    /// the mode back), so it's judged as ever too.
    static let unreadablePrefix = "/unreadable/"

    /// The per-path entry of the watched folder itself (no entry is named "."): its mode, so a change of it is a change in
    /// place.
    static let ownEntry = "."

    /// Whether the per-path entry `path` marks a read that didn't see everything (`cutEntry`, `unreadablePrefix`).
    static func isUnseen(_ path: String) -> Bool { path == cutEntry || path.hasPrefix(unreadablePrefix) }

    /// A folder of `.entries`, read as `ConfigSeal.readFolder` reads a folder, in one walk that also says when it was cut
    /// (`cutEntry`) or a folder in it couldn't be listed (`unreadablePrefix`); unlike that read, the folder's own mode
    /// (`ownEntry`) and each folder's are in its lines (`walkEntries`); the hooks record's per-path hash is taken as `GitGuard` reads
    /// it, without its `told` flag (`acceptedRecord`), so that alone is no change in place. A scope's file in the
    /// manager's runtime units folder takes `scopeKind` when the bytes the walk hashed have the manager's form, judged in
    /// the walk itself (never on a second read). `afterWalk`: a test's, run between the walk and the entries' marking.
    static func readEntries(_ watched: ConfigSeal.Watched, afterWalk: (() -> Void)? = nil) -> ConfigSeal.FolderRead {
        var hasher = SHA256()
        var info = stat()
        guard lstat(watched.path, &info) == 0 else {
            hasher.update(data: Data("absent".utf8))
            let absent = ConfigSeal.hex(hasher.finalize())
            return ConfigSeal.FolderRead(hash: absent, countingHash: absent, entries: [:])
        }
        var entries: [String: String] = [:]
        var count = 0
        var unreadable: [String] = []
        let add = { (text: String, path: String?, mtime: Int) in
            let line = Data((text + "\n").utf8)
            hasher.update(data: line)
            if let path { entries[path] = ConfigSeal.hex(SHA256.hash(data: line).prefix(8)) + " \(text.prefix(1)) \(mtime)" }
        }
        add("d \(ownEntry) \(info.st_mode & 0o7777)", ownEntry, Int(Platform.Files.modified(info).tv_sec))
        var scopes: Set<String>? = isTransient(watched.name) ? [] : nil
        let cut = walkEntries(watched.path, relative: "", count: &count, unreadable: &unreadable, scopes: &scopes, add)
        afterWalk?()
        for path in scopes ?? [] where ConfigSeal.entryKind(entries[path]) == "f" {
            var words = (entries[path] ?? "").split(separator: " ").map(String.init)
            words[1] = scopeKind
            entries[path] = words.joined(separator: " ")
        }
        if cut { entries[cutEntry] = ConfigSeal.hex(SHA256.hash(data: Data("cut".utf8)).prefix(8)) + " o 0" }
        for relative in unreadable {
            entries[unreadablePrefix + relative] = ConfigSeal.hex(SHA256.hash(data: Data("unreadable \(relative)".utf8)).prefix(8)) + " o 0"
        }
        let hash = ConfigSeal.hex(hasher.finalize())
        var read = ConfigSeal.FolderRead(hash: hash, countingHash: hash, entries: entries)
        guard watched.name == hooksName else { return read }
        for (path, entry) in read.entries {
            let parts = path.split(separator: "/")
            guard parts.count == 2, parts[1] == Substring(acceptedRecord), ConfigSeal.entryKind(entry) == "f" else { continue }
            let file = (watched.path as NSString).appendingPathComponent(path)
            var info = stat()
            guard lstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  let data = ConfigSeal.regularContents(file, limit: 1 << 20, followLink: false),
                  var record = try? JSONDecoder().decode(GitGuard.Accepted.self, from: data) else { continue }
            // What GitGuard reads (a key given twice: its decoder's choice, not another parser's), told left out.
            record.told = nil
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let canonical = try? encoder.encode(record) else { continue }
            let line = "f \(path) \(info.st_mode & 0o777) told-free " + ConfigSeal.hex(SHA256.hash(data: canonical))
            var words = entry.split(separator: " ").map(String.init)
            words[0] = ConfigSeal.hex(SHA256.hash(data: Data(line.utf8)).prefix(8))
            read.entries[path] = words.joined(separator: " ")
        }
        return read
    }

    /// `ConfigSeal.readFolder`'s walk: each entry under `folder` in name order (`.DS_Store` left out), one line each,
    /// links read and never followed, at most `ConfigSeal.maxEntries`; true when it was cut there. A folder's line also
    /// carries its mode (`st_mode & 0o7777`, as `listingHash`'s), and each folder that can't be listed is added to
    /// `unreadable`. With `scopes` (the manager's runtime units folder), each top-level scope's regular file
    /// (`isScopeFile`) of at most `scopeLimit` bytes is read whole once (no link followed): its line's digest is of
    /// those bytes, and it's added to `scopes` when those same bytes have the manager's form (`hasScopeForm`).
    private static func walkEntries(_ folder: String, relative: String, count: inout Int, unreadable: inout [String],
                                    scopes: inout Set<String>?, _ line: (String, String?, Int) -> Void) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
            line("unreadable \(relative)", nil, 0)
            unreadable.append(relative)
            return false
        }
        for name in names.sorted() where name != ".DS_Store" {
            count += 1
            guard count <= ConfigSeal.maxEntries else {
                line("cut", nil, 0)
                return true
            }
            let path = (folder as NSString).appendingPathComponent(name)
            let shown = relative.isEmpty ? name : relative + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let mtime = Int(Platform.Files.modified(info).tv_sec)
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                line("d \(shown) \(info.st_mode & 0o7777)", shown, mtime)
                if walkEntries(path, relative: shown, count: &count, unreadable: &unreadable, scopes: &scopes, line) { return true }
            case S_IFLNK:
                line("l \(shown) -> " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""), shown, mtime)
            case S_IFREG:
                let digest: String
                if scopes != nil, relative.isEmpty, isScopeFile(name),
                   let data = ConfigSeal.regularContents(path, limit: scopeLimit, followLink: false) {
                    digest = ConfigSeal.hex(SHA256.hash(data: data))
                    if hasScopeForm(data) { scopes?.insert(shown) }
                    line("f \(shown) \(info.st_mode & 0o777) \(digest)", shown, mtime)
                    continue
                }
                switch ConfigSeal.contentsDigest(path, followLink: false) {
                case .digest(let hex): digest = hex
                case .other: digest = "other"
                case .unreadable: digest = "unreadable"
                }
                line("f \(shown) \(info.st_mode & 0o777) \(digest)", shown, mtime)
            default:
                line("o \(shown)", shown, mtime)
            }
        }
        return false
    }

    /// For the vault's look (`LeadVault`'s `judge`): when `key` names a folder of `.entries` that `recorded` has sealed
    /// and that changed by entries added or removed only (none of the ones in both changed in place, by their
    /// `FolderRead.entries` hashes; in the accepted hooks, only what `hookEntryMayCome` lets come; in the launch folders,
    /// only what `launchEntryMayCome` lets come, by the launches `now` names under `launchesKey`), the per-path hashes
    /// to record with `now`'s hash: `now`'s, with the removed ones kept, so one that comes back changed is a change. nil
    /// otherwise, and for a read that didn't see everything on either side (`isUnseen`: cut, or a folder unreadable):
    /// judged as ever.
    static func cameOrWent(key: String, recorded: [String: String], now: [String: String]) -> String? {
        let name = ConfigSeal.name(ofKey: key)
        guard entriesNames.contains(name) || isTransient(name), let was = recorded[key], let hash = now[key], was != hash,
              let before = recorded[ConfigSeal.keysKey(of: key)], let after = now[ConfigSeal.keysKey(of: key)] else { return nil }
        let old = ConfigSeal.decode(before), new = ConfigSeal.decode(after)
        guard !old.keys.contains(where: isUnseen), !new.keys.contains(where: isUnseen) else { return nil }
        for (path, entry) in old {
            if let current = new[path], ConfigSeal.entryHash(current) != ConfigSeal.entryHash(entry) { return nil }
        }
        if name == hooksName {
            for (path, entry) in new where old[path] == nil {
                guard hookEntryMayCome(path, entry: entry, old: old, new: new) else { return nil }
            }
        }
        if name == runName {
            let launches = Set((now[launchesKey] ?? "").split(separator: "\n").map(String.init))
            for (path, entry) in new where old[path] == nil {
                guard launchEntryMayCome(path, entry: entry, launches: launches) else { return nil }
            }
        }
        var kept = old.merging(new) { $1 }
        if isTransient(name) {
            for (path, entry) in new where old[path] == nil {
                guard transientEntryMayCome(path, entry: entry) else { return nil }
            }
            // A scope gone is kept as a tombstone of its last hash (`tombstone`), so one back under its name changed is
            // held (the first loop above), for `tombstoneLooks` looks; then it goes, so the folder doesn't keep every
            // app's start for good. A look that would keep more than `maxTombstones` is judged as ever.
            var tombstones = 0
            for (path, entry) in old where new[path] == nil && isScopeFile(path) {
                kept[path] = tombstone(entry)
                if kept[path] != nil { tombstones += 1 }
            }
            guard tombstones <= maxTombstones else { return nil }
        }
        return ConfigSeal.encode(kept)
    }

    /// Whether `path`, an entry of the manager's runtime units folder (`transient`) that wasn't there, comes as no
    /// change: a scope's unit file at its top, which the manager writes when an app registers a scope of its own (a
    /// browser's `app-<id>-<pid>.scope`, measured on the node 2026-11-17) and removes when the scope goes, and only in
    /// the form the manager writes for one (`scopeKind`, `hasScopeForm`: its header, and no dependency or trigger the
    /// manager would act on at its next reload). A scope is never started from its file (the manager makes scopes
    /// only through its API). Anything else (a file in another form, a service, a timer, a drop-in folder, a link, a
    /// file deeper down, a scope's file changed in place) holds, as the folder's change did. What bounds the rest (the
    /// step 8 sweep's review): the worker could make a scope with `OnFailure=` through the manager's API (`systemd-run
    /// --user --scope -p OnFailure=…`), which writes a file of that form that holds here, or none the seal reads if the
    /// scope is gone by the next look; `/run` is emptied at reboot.
    static func transientEntryMayCome(_ path: String, entry: String) -> Bool {
        isScopeFile(path) && ConfigSeal.entryKind(entry) == scopeKind
    }

    /// The per-path entry's kind (in place of `f`) of a top-level scope's file in the manager's runtime units folder
    /// whose contents, the very bytes the walk hashed, have the form the manager writes for a scope (`hasScopeForm`,
    /// judged in `walkEntries`).
    static let scopeKind = "s"

    /// A scope's file read whole at most (the manager's are a few hundred bytes).
    static let scopeLimit = 64 << 10

    /// The first line the manager writes in each transient unit's file (`unit_make_transient`, systemd 255; read on
    /// the node 2026-11-17).
    static let transientHeader = "# This is a transient unit file, created programmatically via the systemd API. Do not edit."

    /// The keys, by section, the manager writes in a scope's file for the properties an app may give a scope it makes
    /// through the manager's API (systemd 255's `bus_unit_set_transient_property` and `bus_scope_set_property`, with
    /// systemd.resource-control(5)'s resource-control keys and systemd.kill(5)'s): what describes the scope, its slice
    /// (a slice runs nothing), its delegation, its limits and accounting, how it's stopped, and the ordering lines
    /// (`After=`, `Before=`, which start and stop nothing). Never a dependency or a trigger (`Wants=`, `Requires=`,
    /// `Requisite=`, `Upholds=`, `BindsTo=`, `PartOf=`, `Conflicts=`, `OnFailure=`, `OnSuccess=`, `PropagatesStopTo=`,
    /// `StopPropagatedFrom=`, `JoinsNamespaceOf=`, `RequiresMountsFor=`), an action (`FailureAction=`, `SuccessAction=`,
    /// `JobTimeoutAction=`), a condition, or a key that loads a program or names a path (`BPFProgram=`,
    /// `IPIngressFilterPath=`, `IPEgressFilterPath=`, `NFTSet=`, `SocketBind*=`).
    static let scopeKeys: [String: Set<String>] = [
        "Unit": ["Description", "Documentation", "SourcePath", "DefaultDependencies", "CollectMode", "SurviveFinalKillSignal",
                 "After", "Before"],
        "Scope": [
            "Slice", "Delegate", "DelegateControllers", "DelegateSubgroup", "OOMPolicy", "RuntimeMaxSec", "RuntimeRandomizedExtraSec",
            "KillMode", "KillSignal", "RestartKillSignal", "SendSIGHUP", "SendSIGKILL", "FinalKillSignal", "WatchdogSignal",
            "CPUAccounting", "CPUWeight", "StartupCPUWeight", "CPUShares", "StartupCPUShares", "CPUQuota", "CPUQuotaPeriodSec",
            "AllowedCPUs", "StartupAllowedCPUs", "AllowedMemoryNodes", "StartupAllowedMemoryNodes",
            "MemoryAccounting", "MemoryMin", "MemoryLow", "StartupMemoryLow", "MemoryHigh", "StartupMemoryHigh", "MemoryMax",
            "StartupMemoryMax", "MemorySwapMax", "StartupMemorySwapMax", "MemoryZSwapMax", "StartupMemoryZSwapMax",
            "MemoryZSwapWriteback", "MemoryLimit", "TasksAccounting", "TasksMax",
            "IOAccounting", "IOWeight", "StartupIOWeight", "IODeviceWeight", "IOReadBandwidthMax", "IOWriteBandwidthMax",
            "IOReadIOPSMax", "IOWriteIOPSMax", "IODeviceLatencyTargetSec", "BlockIOAccounting", "BlockIOWeight",
            "StartupBlockIOWeight", "BlockIODeviceWeight", "BlockIOReadBandwidth", "BlockIOWriteBandwidth",
            "IPAccounting", "IPAddressAllow", "IPAddressDeny", "DevicePolicy", "DeviceAllow", "DisableControllers",
            "ManagedOOMSwap", "ManagedOOMMemoryPressure", "ManagedOOMMemoryPressureLimit", "ManagedOOMPreference",
            "MemoryPressureWatch", "MemoryPressureThresholdSec",
        ],
    ]

    /// Whether `data` has the form the manager writes for a scope: UTF-8 with no carriage return or NUL (which its
    /// reader ends a line at), `transientHeader` first, then only empty lines, `[Unit]` or `[Scope]`, and `Key=value`
    /// lines of `scopeKeys` for the section they're in, the key as written (no whitespace around it), no line
    /// continued (a trailing backslash) and no other comment.
    static func hasScopeForm(_ data: Data) -> Bool {
        guard !data.contains(0x0D), !data.contains(0), let text = String(data: data, encoding: .utf8) else { return false }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        guard lines.first == Substring(transientHeader) else { return false }
        var section: String?
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard !line.hasSuffix("\\") else { return false }
            if line.hasPrefix("[") {
                guard line == "[Unit]" || line == "[Scope]" else { return false }
                section = String(line.dropFirst().dropLast())
                continue
            }
            guard let section, let equals = line.firstIndex(of: "="), scopeKeys[section]?.contains(String(line[..<equals])) == true else { return false }
        }
        return true
    }

    /// How many looks that record the manager's runtime units folder a scope gone stays as a tombstone of its last
    /// hash (`cameOrWent`).
    static let tombstoneLooks = 64

    /// The most tombstones the folder's record keeps: a look that would keep more is judged as ever.
    static let maxTombstones = 1024

    /// The per-path entry's kind of a scope gone (`tombstone`): its hash, and the looks it has left in place of a time.
    static let goneKind = "g"

    /// What a look that doesn't see a scope keeps of its recorded `entry`: a tombstone of its hash with
    /// `tombstoneLooks` looks left when it was there, one look fewer when it was a tombstone, nil past its last.
    static func tombstone(_ entry: String) -> String? {
        let words = entry.split(separator: " ").map(String.init)
        guard words.count == 3 else { return nil }
        let left = words[1] == goneKind ? (Int(words[2]) ?? 0) - 1 : tombstoneLooks
        return left > 0 ? "\(words[0]) \(goneKind) \(left)" : nil
    }

    /// A top-level name `<unit>.scope`, not hidden.
    static func isScopeFile(_ path: String) -> Bool {
        !path.contains("/") && !path.hasPrefix(".") && path.hasSuffix(".scope") && path.count > ".scope".count
    }

    /// The vault's look: each `.entries` key of `now` not `held` whose change is entries added or removed only
    /// (`cameOrWent`) is recorded in `recorded` as it is, its removed entries kept, and its per-path hashes in `hashes`
    /// set the same, so what the rest of the look seals from `hashes` keeps them too.
    static func recordCameOrWent(_ now: [String: String], hashes: inout [String: String], recorded: inout [String: String], held: Set<String>) {
        for key in now.keys where !held.contains(key) {
            guard let kept = cameOrWent(key: key, recorded: recorded, now: hashes) else { continue }
            recorded[key] = now[key]
            recorded[ConfigSeal.keysKey(of: key)] = kept
            hashes[ConfigSeal.keysKey(of: key)] = kept
        }
    }

    /// Whether `path`, an entry of the accepted hooks that wasn't there (`old`, as sealed), comes as no change. Git takes
    /// the lead's hooks from `<key>/copy/hooks` (`GitGuard.command`'s core.hooksPath): a file there that isn't a shim
    /// would run as the lead's tool server. So only GitGuard's baseline of a repository the seal hasn't seen comes (its
    /// folders, its copies in `run`, which a shim runs as branch code, its shims, and its record), and only whole: with
    /// its record in the same look (`new`), as GitGuard puts a store in place by one rename (`GitGuard.staging`); and
    /// the record of one already there (a store sealed without one, whose copy a baseline then swaps, as it was, and
    /// whose record it adds). Anything else added under a repository's folder waits for the user.
    static func hookEntryMayCome(_ path: String, entry: String, old: [String: String], new: [String: String]) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let kind = ConfigSeal.entryKind(entry)
        if path == ownEntry { return kind == "d" }  // The folder itself, made.
        guard let store = parts.first, !store.isEmpty, !parts.contains("") else { return false }
        if parts.count == 2, parts[1] == acceptedRecord { return kind == "f" }
        guard !old.keys.contains(where: { $0 == store || $0.hasPrefix(store + "/") }) else { return false }
        guard ConfigSeal.entryKind(new[store + "/" + acceptedRecord]) == "f" else { return false }
        let rest = Array(parts.dropFirst())
        switch rest.count {
        case 0: return kind == "d"
        case 1: return rest[0] == "copy" && kind == "d"
        case 2: return rest[0] == "copy" && (rest[1] == "hooks" || rest[1] == "run") && kind == "d"
        default:
            guard rest[0] == "copy" else { return false }
            if rest[1] == "run" { return true }
            return rest[1] == "hooks" && rest.count == 3 && kind == "f"
                && shimHashes(store: store, hook: rest[2], path: path).contains(ConfigSeal.entryHash(entry) ?? "")
        }
    }

    /// The per-path hashes (`FolderRead.entries`') a shim GitGuard writes at `path` for `hook` of repository `store`
    /// would have: `GitGuard.shim` running that hook's copy (`GitGuard.runCopy`, under this process's `VibePaths.root`,
    /// as written or with its links resolved), mode 0700. Whatever a shim runs, it runs as branch code.
    static func shimHashes(store: String, hook: String, path: String) -> Set<String> {
        let roots = [VibePaths.root, VibePaths.root.resolvingSymlinksInPath()]
        return Set(roots.map { root in
            let runs = root.appendingPathComponent("lead/git-hooks/\(store)", isDirectory: true).appendingPathComponent("copy", isDirectory: true)
                .appendingPathComponent("run", isDirectory: true).appendingPathComponent(hook).path
            let digest = ConfigSeal.hex(SHA256.hash(data: Data(GitGuard.shim(running: runs).utf8)))
            return ConfigSeal.hex(SHA256.hash(data: Data("f \(path) \(0o700) \(digest)\n".utf8)).prefix(8))
        })
    }

    // MARK: Launch folders

    /// The roles' launch folders (`LeadVault.runFolder`: `run/<repository key>/<name>/`).
    static var runName: String { "~/.vibeswitcher/lead/run" }

    /// Where the vault's look puts the launches it recorded (`withLaunches`), beside the hashes it made itself: one
    /// `<repository key>/<name>` per line. A vault key (`#`), so never a watched thing, never sealed.
    static let launchesKey = ConfigSeal.keyPrefix + "#launches"

    /// What `LeadLaunch.prepare` and `prepareCodex` write in a launch folder (on Linux `prepare` then removes the ones it
    /// gave inline).
    static let launchFiles: Set<String> = ["prompt.md", "mcp.json", "settings.json", "codex-config.json"]

    /// The vault's hook (`LeadVault`'s `sealConfig`): `hashes` with the launches `teams` recorded under `launchesKey`
    /// when it holds the launch folders' hash (Linux's list; never on the Mac), and without that key otherwise, whoever
    /// sent it.
    static func withLaunches(_ hashes: [String: String], teams: [String: LeadVault.Book.Team]) -> [String: String] {
        var hashes = hashes
        hashes[launchesKey] = nil
        guard hashes[ConfigSeal.keyPrefix + runName] != nil else { return hashes }
        hashes[launchesKey] = launches(teams).sorted().joined(separator: "\n")
        return hashes
    }

    /// Each launch folder (`<repository key>/<name>`) the vault's records name, by the names the launchers give: the
    /// lead's `lead-<the project's slug>` (`LeadStart`), a worker's `worker-<task>`, a verifier's `verify-<task>` and an
    /// audit's other finders' `finder<n>-<task>` (`LeadToolset`). Each member holding its role, and each former one
    /// (`Team.formerRoles`, its finder not kept: any of an audit's). The vault records a grant before its launch writes
    /// its folder (`LeadToolset.launch`, `LeadStart`), and only a lead or the app is granted one.
    static func launches(_ teams: [String: LeadVault.Book.Team]) -> Set<String> {
        var names = Set<String>()
        for (key, team) in teams {
            let former = (team.formerRoles ?? [:]).values.map { ($0.role, $0.task, [1] + Array(2...LeadWorkflow.maxFinders)) }
            for (role, task, finders) in team.members.map({ ($0.role, $0.task, [$0.finder?.index ?? 1]) }) + former {
                switch role {
                case .lead: names.insert(key + "/lead-" + Slug.make(LeadMail.project(of: team.root), taken: []))
                case .worker: if let task { names.insert(key + "/worker-" + task) }
                case .verifier:
                    guard let task else { continue }
                    for index in finders { names.insert(key + (index <= 1 ? "/verify-" : "/finder\(index)-") + task) }
                }
            }
        }
        return names
    }

    /// Whether `path`, an entry of the launch folders that wasn't there, comes as no change: a repository's folder that
    /// holds a recorded launch, a recorded launch's folder (`launches`), or a file a launcher writes in one (or
    /// `VibePaths.writePrivate`'s temporary file for it, there until its rename). Anything else (a launch no launch
    /// made, another file, a link, a folder deeper down) holds the team, as a `.folder`'s change would.
    static func launchEntryMayCome(_ path: String, entry: String, launches: Set<String>) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let kind = ConfigSeal.entryKind(entry)
        if path == ownEntry { return kind == "d" }  // The folder itself, made.
        guard !parts.contains(""), !parts.contains("."), !parts.contains("..") else { return false }
        switch parts.count {
        case 1: return kind == "d" && launches.contains { $0.hasPrefix(parts[0] + "/") }
        case 2: return kind == "d" && launches.contains(path)
        case 3: return kind == "f" && launches.contains(parts[0] + "/" + parts[1]) && isLaunchFile(parts[2])
        default: return false
        }
    }

    /// A file a launcher writes, or `VibePaths.writePrivate`'s temporary one for it (`.<name>.<UUID>`).
    static func isLaunchFile(_ name: String) -> Bool {
        if launchFiles.contains(name) { return true }
        guard name.hasPrefix(".") else { return false }
        let rest = name.dropFirst()
        return launchFiles.contains { file in
            rest.hasPrefix(file + ".") && UUID(uuidString: String(rest.dropFirst(file.count + 1))) != nil
        }
    }
}
