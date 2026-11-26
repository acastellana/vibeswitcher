import Foundation
import Testing
@testable import VibeCore

/// The second fix round's own tests (v2-mac-seal-fix2): what the re-check's tests (`MacSealRecheckTests.swift`) don't
/// reach. The ones without the Mac trait are the shared code's (`LinuxSealList`), for Linux to run too. Scratch homes
/// only; no zsh is run here (the probes are in the spec's second fix round).
struct MacSealFix2Tests {
    let temp = Scratch()

    func home(_ name: String = "fix2-home") throws -> String {
        let url = temp.url(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    // MARK: N1

    /// A saved session's twin whose bytes are exactly the restore line is still a change: the restore-line exception is
    /// the text file's alone (zsh runs a twin's compiled code, whatever bytes stand in for it here).
    @Test(MacSealListTests.mac) func aSessionTwinHoldingTheRestoreLineIsStillAChange() throws {
        let home = try home()
        let folder = home + "/.zsh_sessions"
        try MacSealListTests.write(MacSealRecheckTests.restore, folder + "/A.session")
        let before = MacSealList.sessionsHash(folder)
        try MacSealListTests.write(MacSealRecheckTests.restore, folder + "/A.SESSION.ZWC")
        #expect(MacSealList.sessionsHash(folder) != before)
        #expect(MacSealList.sessionKeys(folder)["A.SESSION.ZWC"] != nil, "the card names the twin")
    }

    /// Every zsh startup file's twin is a row, `.zlogout`'s and `.zprofile`'s included, absent hashed as absent; on the
    /// Mac a sourced file's twin is one; the Linux list's sourcing (no twins) adds none.
    @Test(MacSealListTests.mac) func eachZshStartupFilesTwinIsARow() throws {
        let home = try home()
        try MacSealListTests.write(". ~/.cargo/env\n", home + "/.zshenv")
        let names = Set(MacSealList.watched(home: home, uid: getuid()).map(\.name))
        for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"] { #expect(names.contains("~/\(file).zwc"), "~/\(file).zwc") }
        #expect(names.contains("~/.cargo/env.zwc"))
        var linux: [ConfigSeal.Watched] = []
        var seen: Set<String> = []
        LinuxSealList.addSourced(from: [".zshenv"], home: home, names: &seen, to: &linux)
        #expect(linux.map(\.name) == ["~/.cargo/env"])
    }

    /// A compiled twin coming into (or going from) a folder of `.entries` is held: `cameOrWent` judges it as ever.
    /// Another entry coming is still no change. The shared code's (Linux's snapshot rows are the same rows).
    @Test func aTwinComingIntoAnEntriesFolderIsHeld() throws {
        let key = ConfigSeal.keyPrefix + "~/.claude/shell-snapshots"
        let keys = ConfigSeal.keysKey(of: key)
        let old = [key: "a", keys: ConfigSeal.encode(["snapshot-zsh-1-a.sh": "00000000 f 1"])]
        let snapshot = [key: "b", keys: ConfigSeal.encode(["snapshot-zsh-1-a.sh": "00000000 f 1", "snapshot-zsh-2-b.sh": "11111111 f 2"])]
        #expect(LinuxSealList.cameOrWent(key: key, recorded: old, now: snapshot) != nil, "the premise: a snapshot comes as no change")
        for twin in ["snapshot-zsh-1-a.sh.zwc", "snapshot-zsh-1-a.sh.ZWC"] {
            let now = [key: "c", keys: ConfigSeal.encode(["snapshot-zsh-1-a.sh": "00000000 f 1", twin: "22222222 f 3"])]
            #expect(LinuxSealList.cameOrWent(key: key, recorded: old, now: now) == nil, "\(twin) came unheld")
            #expect(LinuxSealList.cameOrWent(key: key, recorded: [key: "c", keys: now[keys]!], now: old) == nil, "\(twin) went unheld")
        }
    }

    // MARK: N2

    /// A sessions or preferences link's target is said with its length: two links whose targets differ only in where a
    /// newline falls read apart, and a target's newline never ends the line.
    @Test(MacSealListTests.mac) func aLinkTargetIsSaidWithItsLength() throws {
        let dir = try home("links")
        try FileManager.default.createSymbolicLink(atPath: dir + "/a", withDestinationPath: "x\ny")
        #expect(MacSealList.linkSaid(dir + "/a") == "link 3:x\ny ")
        #expect(MacSealList.linkTarget(dir + "/none") == "?")
    }

    /// A listing's link whose target holds a newline is said in hex, on one line; any other target is said as before
    /// (the listing hash bytes are unchanged: `MacSealRecheckTests.aListingsHashBytesAreUnchanged`). The shared code's.
    @Test func aListingLinksNewlineCantSpellALine() throws {
        let dir = try home("listing")
        try FileManager.default.createSymbolicLink(atPath: dir + "/odd", withDestinationPath: "b\nf 1:c")
        try FileManager.default.createSymbolicLink(atPath: dir + "/plain", withDestinationPath: "/usr/bin/true")
        var info = stat()
        #expect(lstat(dir + "/odd", &info) == 0)
        let odd = LinuxSealList.line(info, path: dir + "/odd", relative: "odd")
        #expect(!odd.contains("\n") && odd.hasSuffix(" ->x " + ConfigSeal.hex(Array("b\nf 1:c".utf8))), "\(odd)")
        #expect(lstat(dir + "/plain", &info) == 0)
        // f4b22149's `line` for a link, written out: the bytes `MacSealRecheckTests.aListingsHashBytesAreUnchanged` relies on.
        let modified = Platform.Files.modified(info), changed = Platform.Files.changed(info)
        let old = "l 5:plain \(info.st_mode & 0o7777) \(info.st_size) \(info.st_ino) "
            + "\(modified.tv_sec).\(modified.tv_nsec) \(changed.tv_sec).\(changed.tv_nsec)" + " -> " + "/usr/bin/true"
        #expect(LinuxSealList.line(info, path: dir + "/plain", relative: "plain") == old)
    }

    // MARK: N6

    /// Two top-level keys that differ only by a lone surrogate are two keys: a binary plist keeps their UTF-16, the hash
    /// reads them apart, and the card names both.
    @Test(MacSealListTests.mac) func topLevelKeysWithLoneSurrogatesAreEachHashed() throws {
        let home = try home()
        let prefs = home + "/Library/Preferences/com.apple.Terminal.plist"
        let write = { (keys: [NSString]) in
            let top = NSMutableDictionary()
            for key in keys { top[key] = "x" }
            let data = try PropertyListSerialization.data(fromPropertyList: top, format: .binary, options: 0)
            try FileManager.default.createDirectory(atPath: (prefs as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: prefs))
        }
        let one = NSString(characters: [0x50, 0xD800], length: 2), two = NSString(characters: [0x50, 0xDC00], length: 2)
        try write([one])
        let first = MacSealList.preferencesHash(prefs)
        let read = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: prefs)), format: nil) as? NSDictionary)
        try #require((read.allKeys.first as? NSString)?.isEqual(one) == true, "the premise: the file keeps the lone surrogate")
        try write([two])
        #expect(MacSealList.preferencesHash(prefs) != first, "P\\u{D800} and P\\u{DC00} hashed as one key")
        try write([one, two])
        #expect(MacSealList.preferenceKeys(prefs).count == 3, "\(MacSealList.preferenceKeys(prefs).keys.sorted())")
        // A valid string's form is the one before (its UTF-8 count and text), so such a file hashes as it did.
        #expect(MacSealList.form("Caf\u{E9}" as NSString) == "5:Caf\u{E9}")
        #expect(MacSealList.form(one) == "u2:0050d800")
    }

    // MARK: N5, N4

    /// A startup file of 100,000 `. ~/aN` lines (the re-check's: it ran 30 minutes and more) returns within the hang
    /// guard, with at most `maxSourcedRows` rows and the cap's row, which hashes as a change. The shared code's.
    @Test func aHundredThousandSourceLinesAreBounded() async throws {
        let home = try home()
        try MacSealListTests.write((0..<100_000).map { ". ~/a\($0)\n" }.joined(), home + "/.zshrc")
        let done = DispatchSemaphore(value: 0)
        final class Rows: @unchecked Sendable {
            let lock = NSLock()
            var items: [ConfigSeal.Watched] = []
        }
        let rows = Rows()
        Thread {
            var items: [ConfigSeal.Watched] = []
            var names: Set<String> = []
            LinuxSealList.addSourced(from: [".zshrc"], home: home, names: &names, to: &items, twins: true)
            rows.lock.withLock { rows.items = items }
            done.signal()
        }.start()
        let returned = await offPool { done.wait(timeout: .now() + hangGuard) == .success }
        try #require(returned, "addSourced didn't return within the hang guard")
        let items = rows.lock.withLock { rows.items }
        #expect(items.count == LinuxSealList.maxSourcedRows + 1, "\(items.count) rows")
        let cap = try #require(items.last)
        #expect(cap.name == LinuxSealList.capName && cap.kind == .capped("more than \(LinuxSealList.maxSourcedRows) rows"))
        #expect(ConfigSeal.fingerprint(cap) != nil)
    }

    /// A sparse file of 1 TB (no disk used: `ftruncate`) as a twin row is hashed by its metadata within the hang guard,
    /// never read whole; a write to it is still a change; a file under the limit hashes by its contents as ever. The
    /// shared code's (the blind check's: every `.file` row, session file and ByHost fallback read through `contentsDigest`).
    @Test func aSparseFilesRowIsBoundedAndStillSeesAWrite() async throws {
        let home = try home()
        let path = home + "/.zshrc.zwc"
        try MacSealListTests.write("small\n", path)
        let row = ConfigSeal.Watched(name: "~/.zshrc.zwc", path: path, kind: .file)
        let small = try #require(ConfigSeal.fingerprint(row))
        #expect(ConfigSeal.contentsDigest(path, followLink: true) == .digest(ConfigSeal.hex(SHA256.hash(data: Data("small\n".utf8)))))
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.truncate(atOffset: 1 << 40)
        try handle.close()
        let print = { () async -> String? in
            let done = DispatchSemaphore(value: 0)
            final class Box: @unchecked Sendable {
                let lock = NSLock()
                var value: String?
            }
            let box = Box()
            Thread {
                let value = ConfigSeal.fingerprint(row)
                box.lock.withLock { box.value = value }
                done.signal()
            }.start()
            guard await offPool({ done.wait(timeout: .now() + hangGuard) == .success }) else { return nil }
            return box.lock.withLock { box.value }
        }
        let sparse = try #require(await print(), "a 1 TB sparse file wasn't hashed within the hang guard")
        #expect(sparse != small)
        let writer = try #require(FileHandle(forWritingAtPath: path))
        try writer.write(contentsOf: Data("evil".utf8))
        try writer.close()
        let written = try #require(await print())
        #expect(written != sparse, "a write to a file past the limit changed nothing")
    }

    /// Each cap holds: no cap row under it; a cap row (a change) past the rows, at a file past 16 MB, and past the
    /// bytes read in all. The shared code's.
    @Test func eachSourcingCapAddsAHeldRow() throws {
        let home = try home()
        let rows = { () -> [ConfigSeal.Watched] in
            var items: [ConfigSeal.Watched] = []
            var names: Set<String> = []
            LinuxSealList.addSourced(from: [".zshrc"], home: home, names: &names, to: &items)
            return items
        }
        try MacSealListTests.write(". ~/a\n. ~/b\n", home + "/.zshrc")
        #expect(!rows().contains { $0.name == LinuxSealList.capName })
        let under = ConfigSeal.hashes(of: rows())
        // A sourced file past 16 MB: the cap's row comes, so the list's hashes hold a change.
        let big = String(repeating: "# pad\n", count: (LinuxSealList.startupLimit / 6) + 1)
        try MacSealListTests.write(big, home + "/a")
        let past = rows()
        #expect(past.last?.kind == .capped("a file past 16 MB: ~/a"), "\(past.map(\.name))")
        #expect(ConfigSeal.hashes(of: past)[ConfigSeal.keyPrefix + LinuxSealList.capName] != nil)
        #expect(ConfigSeal.hashes(of: past) != under)
        // Past the bytes read in all: three files of 12 MB each.
        let twelve = String(repeating: "# pad\n", count: (12 << 20) / 6)
        try MacSealListTests.write(". ~/b\n" + twelve, home + "/a")
        try MacSealListTests.write(". ~/c\n" + twelve, home + "/b")
        try MacSealListTests.write(twelve, home + "/c")
        #expect(rows().last?.kind == .capped("more than \(LinuxSealList.maxSourcedBytes >> 20) MB read"))
    }
}
