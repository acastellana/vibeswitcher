import Foundation
import Testing
@testable import VibeCore

/// The config seal's Linux list (`LinuxSealList`, the start plan's S7): what a worker's shell can change on the node
/// that the next session or the node itself runs. Every home here is a scratch one; the entries outside a home
/// (`/run/user/<uid>/systemd/…`, `/mnt/c/…`) are read under a scratch root (`outside:`), never the real ones.
struct LinuxSealListTests {
    let temp = Scratch()

    static let linux: ConditionTrait = .enabled(if: !Platform.CodeIdentity.isAvailable, "the Linux list; the Mac's is empty")

    /// A scratch home, made.
    func home() throws -> String {
        let url = temp.url("seal-home")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    func write(_ text: String, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: false, encoding: .utf8)
    }

    /// A stand-in mounts file: `/mnt/c` a 9p mount when `windows`.
    func mounts(windows: Bool) throws -> String {
        let path = temp.url("mounts").path
        var text = "none / ext4 rw,relatime 0 0\nnone /run/user tmpfs rw,nosuid,nodev 0 0\n"
        if windows { text += #"C:\134 /mnt/c 9p rw,dirsync,noatime,aname=drvfs;path=C:\;uid=1000;gid=1000 0 0"# + "\n" }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Every fingerprint of `items`, by name.
    func prints(_ items: [ConfigSeal.Watched]) -> [String: String] {
        Dictionary(items.map { ($0.name, ConfigSeal.fingerprint($0) ?? "nil") }) { first, _ in first }
    }

    /// Waits (bounded) until a file changed now gets a later ctime than `path`'s: Linux's ctime is as coarse as the
    /// kernel's tick, and a change in the tick of the last one would keep it.
    func waitForTheNextTick(after path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        let last = Platform.Files.changed(info)
        let probe = (path as NSString).deletingLastPathComponent + "/.tick-probe-\(UUID().uuidString)"
        defer { unlink(probe) }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try write("t", probe)
            var now = stat()
            guard lstat(probe, &now) == 0 else { continue }
            let at = Platform.Files.changed(now)
            if at.tv_sec > last.tv_sec || (at.tv_sec == last.tv_sec && at.tv_nsec > last.tv_nsec) { return }
        }
        Issue.record("the change time never moved past \(path)'s")
    }

    /// A write that keeps a file's size and mtime: contents changed in place, then `touch -d` back.
    func rewriteKeepingSizeAndTime(_ path: String) throws {
        var info = stat()
        try #require(lstat(path, &info) == 0)
        let size = Int(info.st_size)
        let mtime = Platform.Files.modified(info)
        try waitForTheNextTick(after: path)
        let old = try Data(contentsOf: URL(fileURLWithPath: path))
        let new = Data(old.map { $0 == UInt8(ascii: "a") ? UInt8(ascii: "b") : UInt8(ascii: "a") })
        // In place: no truncation, no new inode.
        let handle = try #require(FileHandle(forWritingAtPath: path))
        handle.write(new)
        handle.closeFile()
        var times = [mtime, mtime]
        try #require(utimensat(AT_FDCWD, path, &times, 0) == 0)
        var after = stat()
        try #require(lstat(path, &after) == 0)
        #expect(Int(after.st_size) == size && Platform.Files.modified(after).tv_sec == mtime.tv_sec
                && Platform.Files.modified(after).tv_nsec == mtime.tv_nsec, "\(path) kept its size and mtime")
    }

    /// For every entry of the list, a write in a scratch home (or the scratch root outside it) changes that entry's
    /// fingerprint and no other's. A listing's write keeps size and mtime. Absent, each hashes as absent, and changes
    /// when created.
    @Test(Self.linux) func aWriteToEachItemOfTheLinuxListIsHeld() throws {
        let home = try home()
        let outside = temp.url("seal-outside").path
        let uid = getuid()
        // A user's Windows folders, so the `/mnt/c` entries are there to write.
        try FileManager.default.createDirectory(atPath: outside + "/mnt/c/Users/someone", withIntermediateDirectories: true)
        try write(". ~/x.sh\n", home + "/.bashrc")
        let mounts = try mounts(windows: true)
        let list = { LinuxSealList.watched(home: home, uid: uid, mounts: mounts, outside: outside) }
        let items = list()
        let names = Set(items.map(\.name))
        for (relative, _) in LinuxSealList.homeEntries { #expect(names.contains("~/" + relative), "\(relative) listed") }
        for name in ["~/x.sh", "/run/user/\(uid)/systemd/transient", "/run/user/\(uid)/systemd/user.control",
                     "/mnt/c/Users/someone/.wslconfig", "/mnt/c/Users/someone/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup"] {
            #expect(names.contains(name), "\(name) listed: \(names.sorted())")
        }
        #expect(items.allSatisfy { $0.executes }, "every entry executes")
        #expect(items.allSatisfy { ConfigSeal.executes(key: ConfigSeal.keyPrefix + $0.name) })
        #expect(items.allSatisfy { ConfigSeal.isHome(key: ConfigSeal.keyPrefix + $0.name) }, "each is the node-wide seal's")
        // Node's version folder, before the unit exists: each of nvm's.
        #expect(!names.contains { $0.hasPrefix("~/.nvm/versions/node/") })

        let absent = ConfigSeal.fingerprint(ConfigSeal.Watched(name: "absent", path: home + "/nothing-here", kind: .file))
        var before = prints(items + ConfigSeal.homeWatched(home: home))
        for item in items where item.name != "~/.bashrc" {
            let printed = try #require(before[item.name])
            #expect(printed == absent, "\(item.name) hashes as absent")
        }
        for item in items {
            switch item.kind {
            case .file: try write("planted \(item.name)\n", item.path)
            case .folder, .entries: try write("planted\n", item.path + "/planted")
            case .listing:
                // Created, then (seen as created) rewritten in place keeping its size and mtime.
                try write("aaaa\n", item.path + "/tool")
                let created = prints(items)
                #expect(created[item.name] != before[item.name], "\(item.name) changed when created")
                before[item.name] = created[item.name]
                try rewriteKeepingSizeAndTime(item.path + "/tool")
            default: Issue.record("\(item.name): a kind the list doesn't use")
            }
            let after = prints(list() + ConfigSeal.homeWatched(home: home))
            for (name, printed) in before where name != item.name {
                #expect(after[name] == printed, "a write to \(item.name) changed \(name)")
            }
            #expect(after[item.name] != before[item.name], "a write to \(item.name) held nothing")
            before = after
        }
    }

    /// Node's version folder: the parent of the unit's node `bin` when the unit exists, else each of nvm's versions.
    @Test(Self.linux) func nodesVersionFolderIsTheUnitsOrEachOfNvms() throws {
        let home = try home()
        let mounts = try mounts(windows: false)
        for version in ["v20.1.0", "v22.3.0"] {
            try FileManager.default.createDirectory(atPath: home + "/.nvm/versions/node/\(version)/bin", withIntermediateDirectories: true)
        }
        let nodes = { LinuxSealList.watched(home: home, uid: getuid(), mounts: mounts).filter { $0.name.hasPrefix("~/.nvm/versions/node/") } }
        #expect(nodes().map(\.name).sorted() == ["~/.nvm/versions/node/v20.1.0", "~/.nvm/versions/node/v22.3.0"])
        #expect(nodes().allSatisfy { $0.kind == .listing })
        try write("""
            [Service]
            Environment="HOME=\(home)"
            Environment="PATH=/usr/bin:/bin:\(home)/.local/share/swiftly/bin:\(home)/.nvm/versions/node/v22.3.0/bin"

            """, home + "/.config/systemd/user/vibeswitcher-node.service")
        #expect(nodes().map(\.name) == ["~/.nvm/versions/node/v22.3.0"])
        #expect(nodes().map(\.path) == [home + "/.nvm/versions/node/v22.3.0"])
    }

    /// What the startup files source, written `~/…`, `$HOME/…`, `${HOME}/…` or by the home's own path: each a file.
    @Test(Self.linux) func aSourcedFileIsWatched() throws {
        let home = try home()
        let text = """
            . ~/x.sh
            if true; then
                source "$HOME/y.sh"
            fi
            [ -f ${HOME}/z ] && source ${HOME}/z
            . '\(home)/w.sh'
            # . ~/commented.sh
            . /usr/share/bash-completion/bash_completion
            [ -s "$NVM_DIR/nvm.sh" ] && \\. "$NVM_DIR/nvm.sh"

            """
        #expect(LinuxSealList.sourced(startupFile: text, home: home) == [home + "/x.sh", home + "/y.sh", home + "/z", home + "/w.sh"])
        try write(text, home + "/.profile")
        let mounts = try mounts(windows: false)
        let list = { LinuxSealList.watched(home: home, uid: getuid(), mounts: mounts) }
        for name in ["~/x.sh", "~/y.sh", "~/z", "~/w.sh"] {
            let item = try #require(list().first { $0.name == name }, "\(name)")
            #expect(item.kind == .file && item.executes)
            let before = ConfigSeal.fingerprint(item)
            try write("planted\n", item.path)
            #expect(ConfigSeal.fingerprint(item) != before, "a write to \(name) held nothing")
        }
        // Listed once, beside the static entries.
        #expect(Set(list().map(\.name)).count == list().count)
    }

    /// On the Mac the list is empty, and `homeWatched` is today's.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's")) func theMacsListIsEmpty() throws {
        let home = try home()
        try write(". ~/x.sh\n", home + "/.bashrc")
        #expect(LinuxSealList.watched(home: home, uid: getuid()).isEmpty)
        let names = ConfigSeal.homeWatched(home: home).map(\.name)
        #expect(names == ConfigSeal.homeFiles.map { "~/" + $0.0 } + ["~/.claude/settings.json's scripts", "~/.claude/settings.local.json's scripts"])
    }

    /// A listing reads metadata only: a file it can't read still fingerprints, and its mode is part of it.
    @Test(Self.linux) func aListingNeverReadsContents() throws {
        let folder = temp.url("listing").path
        try write("secret\n", folder + "/hosts.yml")
        chmod(folder + "/hosts.yml", 0)
        let item = ConfigSeal.Watched(name: "~/.config/gh", path: folder, kind: .listing)
        let printed = try #require(ConfigSeal.fingerprint(item))
        #expect(ConfigSeal.fingerprint(item) == printed)
        try waitForTheNextTick(after: folder + "/hosts.yml")
        chmod(folder + "/hosts.yml", 0o600)
        #expect(ConfigSeal.fingerprint(item) != printed)
    }

    /// A listing has no cap: one of 25,000 entries changes its fingerprint when its last entry changes.
    @Test(Self.linux) func aListingIsNotCut() throws {
        let folder = temp.url("listing").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for index in 0..<25_000 {
            let fd = open(folder + String(format: "/e%05d", index), O_WRONLY | O_CREAT | O_EXCL, 0o644)
            try #require(fd >= 0)
            close(fd)
        }
        let item = ConfigSeal.Watched(name: "~/.local/share/claude/versions", path: folder, kind: .listing)
        let printed = try #require(ConfigSeal.fingerprint(item))
        try write("x", folder + "/e24999")
        #expect(ConfigSeal.fingerprint(item) != printed)
    }

    /// The Windows files only while `/mnt/c` is a 9p or drvfs mount, for each user but Public, Default and All Users.
    @Test(Self.linux) func theWindowsFilesAreWatchedOnlyWhileMounted() throws {
        let home = try home()
        let outside = temp.url("seal-outside").path
        for user in ["someone", "Public", "Default", "All Users", "another"] {
            try FileManager.default.createDirectory(atPath: outside + "/mnt/c/Users/" + user, withIntermediateDirectories: true)
        }
        try write("[.ShellClassInfo]\n", outside + "/mnt/c/Users/desktop.ini")
        let windows = { (mounted: Bool) throws -> [String] in
            LinuxSealList.watched(home: home, uid: getuid(), mounts: try mounts(windows: mounted), outside: outside)
                .map(\.name).filter { $0.hasPrefix("/mnt/") }.sorted()
        }
        let startup = "/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup"
        #expect(try windows(true) == ["/mnt/c/Users/another/.wslconfig", "/mnt/c/Users/another" + startup,
                                      "/mnt/c/Users/someone/.wslconfig", "/mnt/c/Users/someone" + startup])
        #expect(try windows(false) == [])
        // A drvfs mount counts as well.
        let drvfs = temp.url("mounts").path
        try "C: /mnt/c drvfs rw,noatime 0 0\n".write(toFile: drvfs, atomically: true, encoding: .utf8)
        #expect(LinuxSealList.watched(home: home, uid: getuid(), mounts: drvfs, outside: outside).contains { $0.name.hasPrefix("/mnt/c/") })
    }

    /// A scratch home's list reads nothing outside it: only the account's own home takes the `/run/user` and `/mnt/c`
    /// entries (so no test's seal reads the user's runtime folder or Windows).
    @Test(Self.linux) func aScratchHomeReadsNothingOutsideIt() throws {
        let home = try home()
        let names = LinuxSealList.watched(home: home, uid: getuid(), mounts: try mounts(windows: true)).map(\.name)
        #expect(!names.contains { $0.hasPrefix("/") }, "\(names)")
        #expect(ConfigSeal.homeWatched(home: home).allSatisfy { !$0.path.hasPrefix("/run/") && !$0.path.hasPrefix("/mnt/") })
    }

    /// ST-D19: in a folder of `.entries`, an entry added or removed is no change; one changed in place is, and so is a
    /// removed one that comes back changed.
    @Test(Self.linux) func anEntriesFolderCountsOnlyEntriesChangedInPlace() throws {
        let home = try home()
        let snapshots = home + "/.claude/shell-snapshots"
        try write("one\n", snapshots + "/snapshot-bash-1-a.sh")
        let item = try #require(LinuxSealList.watched(home: home, uid: getuid()).first { $0.name == "~/.claude/shell-snapshots" })
        #expect(item.kind == .entries)
        let key = ConfigSeal.keyPrefix + item.name
        var recorded = ConfigSeal.hashes(of: [item])
        func look() -> String? {
            let now = ConfigSeal.hashes(of: [item])
            guard let kept = LinuxSealList.cameOrWent(key: key, recorded: recorded, now: now) else { return nil }
            recorded[key] = now[key]
            recorded[ConfigSeal.keysKey(of: key)] = kept
            return kept
        }
        try write("two\n", snapshots + "/snapshot-bash-2-b.sh")
        #expect(look() != nil, "an entry added")
        try FileManager.default.removeItem(atPath: snapshots + "/snapshot-bash-1-a.sh")
        #expect(look() != nil, "an entry removed")
        try write("planted\n", snapshots + "/snapshot-bash-2-b.sh")
        #expect(look() == nil, "an entry changed in place")
        recorded = ConfigSeal.hashes(of: [item])
        try FileManager.default.removeItem(atPath: snapshots + "/snapshot-bash-2-b.sh")
        #expect(look() != nil)
        try write("planted again\n", snapshots + "/snapshot-bash-2-b.sh")
        #expect(look() == nil, "a removed entry back changed")
        // Not a folder of entries: judged as ever.
        let bin = ConfigSeal.Watched(name: "~/bin", path: home + "/bin", kind: .folder)
        let binKey = ConfigSeal.keyPrefix + bin.name
        let was = ConfigSeal.hashes(of: [bin])
        try write("x\n", home + "/bin/x")
        #expect(LinuxSealList.cameOrWent(key: binKey, recorded: was, now: ConfigSeal.hashes(of: [bin])) == nil)
    }

    /// The lead's accepted hooks (`~/.vibeswitcher/lead/git-hooks`, `.entries`): the baseline written is entries added,
    /// and its record's `told` flag set by the lead's tool server is no change; a hooks copy or a record changed
    /// otherwise is.
    @Test(Self.linux) func theHooksRecordsToldFlagIsNoChange() throws {
        let home = try home()
        let store = home + "/.vibeswitcher/lead/git-hooks/0123456789abcdef"
        let item = try #require(LinuxSealList.watched(home: home, uid: getuid()).first { $0.name == "~/.vibeswitcher/lead/git-hooks" })
        #expect(item.kind == .entries)
        let key = ConfigSeal.keyPrefix + item.name
        let record = { (told: Bool?, run: [String]) throws in
            var object: [String: Any] = ["folder": "/repo/.git/hooks", "files": [] as [Any], "run": run, "baseline": true]
            if let told { object["told"] = told }
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: URL(fileURLWithPath: store + "/accepted.json"))
        }
        let empty = ConfigSeal.hashes(of: [item])
        try write("#!/bin/sh\n", store + "/copy/hooks/pre-commit")
        try record(nil, [])
        let baseline = ConfigSeal.hashes(of: [item])
        #expect(LinuxSealList.cameOrWent(key: key, recorded: empty, now: baseline) != nil, "the baseline: entries added")
        try record(true, [])
        #expect(LinuxSealList.cameOrWent(key: key, recorded: baseline, now: ConfigSeal.hashes(of: [item])) != nil, "told set")
        try record(true, ["pre-commit"])
        #expect(LinuxSealList.cameOrWent(key: key, recorded: baseline, now: ConfigSeal.hashes(of: [item])) == nil, "the record changed")
        try record(nil, [])
        try write("#!/bin/sh\necho planted\n", store + "/copy/hooks/pre-commit")
        #expect(LinuxSealList.cameOrWent(key: key, recorded: baseline, now: ConfigSeal.hashes(of: [item])) == nil, "the copy changed")
    }

    /// Gated: one look at the list of the account's real home, read only and leaving out `~/.claude` and
    /// `~/.vibeswitcher`, timed for the inventory. Enabled only with `VIBESWITCHER_SEAL_TIMING_HOME` set to the home
    /// the user database gives on the run's command line.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBESWITCHER_SEAL_TIMING_HOME"] != nil, "times a look at the real home's list"))
    func aLookOfTheLinuxListIsTimed() throws {
        let given = try #require(ProcessInfo.processInfo.environment["VIBESWITCHER_SEAL_TIMING_HOME"])
        let account = try #require(getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) })
        try #require(given == account, "VIBESWITCHER_SEAL_TIMING_HOME must be the user database's home, \(account)")
        let items = LinuxSealList.watched(home: account, uid: getuid()).filter { item in
            !["/.claude", "/.vibeswitcher"].contains { item.path == account + $0 || item.path.hasPrefix(account + $0 + "/") }
        }
        let start = Date()
        let hashes = ConfigSeal.hashes(of: items)
        let seconds = Date().timeIntervalSince(start)
        print("seal timing: \(items.count) entries, \(hashes.filter { ConfigSeal.isWatchedKey($0.key) }.count) hashed, "
              + String(format: "%.2f s", seconds))
        for item in items { print("seal timing entry: \(item.name) (\(item.kind))") }
        #expect(hashes.filter { ConfigSeal.isWatchedKey($0.key) }.count == items.count)
    }
}
