import Foundation
import Testing
@testable import VibeCore

/// What the held config's card says (`ConfigSeal`, `ConfigSealDetails.swift`): which files, named as a person would,
/// what's different in them, and what most likely did it. Every home here is the fixture's scratch one.
extension ConfigSealTests {
    /// The change the user reported on 2026-11-09: Claude Code's sync rewrote one skill at 17:17 and its manifest at 17:28.
    static let syncFiles = [Self.account + "built-in-browser/SKILL.md": "name: browser\nold line\nend\n",
                            Self.account + "built-in-browser/LICENSE.txt": "licence one\n",
                            Self.account + "manifest.json": #"{"round":1}"#, Self.account + ".last-complete-round": "1"]
    static var skillsName: String { ConfigSeal.copiedFolder }
    /// A day past (2025-11-09 17:17 UTC, the reported clock time on a day before any test's session), and the manifest
    /// 11 minutes on, as really happened.
    static let at1717 = 1_762_708_620.0
    static let manifestLag = 660.0

    var syncFolder: String { home + "/" + Self.account }

    /// The sync's round as it really came: the skill's two files, then the manifest.
    func syncRound(manifestAt: Double? = at1717 + manifestLag) throws {
        try write("name: browser\nnew line\nend\n", syncFolder + "built-in-browser/SKILL.md")
        try write("licence two\n", syncFolder + "built-in-browser/LICENSE.txt")
        try setTime(Self.at1717, syncFolder + "built-in-browser/SKILL.md")
        try setTime(Self.at1717 + 1, syncFolder + "built-in-browser/LICENSE.txt")
        if let manifestAt {
            try write(#"{"round":2}"#, syncFolder + "manifest.json")
            try setTime(manifestAt, syncFolder + "manifest.json")
        }
    }

    func detail(_ root: String, _ name: String = skillsName) throws -> ConfigSeal.HeldDetail {
        try #require(ConfigSeal.heldDetails(in: try vault.guardedRecord(root: root))[name])
    }

    func file(_ detail: ConfigSeal.HeldDetail, _ suffix: String) throws -> ConfigSeal.HeldFile {
        try #require(detail.files.first { $0.path.hasSuffix(suffix) })
    }

    /// The symptom: a sync folder's skill gains a changed SKILL.md and LICENSE.txt. It's held, the card names the skill,
    /// never the account's folder, gives each file's time, and says what most likely did it and how sure that is.
    @Test func aSyncsChangeIsNamedBySkillAndAttributedOnlyAsMostLikely() throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam(Self.syncFiles, runtime: runtime)
        try syncRound()
        #expect(try asLead.checkConfig(root: root).held == [Self.skillsName])

        let detail = try detail(root)
        #expect(detail.files.map { ConfigSeal.fileLabel($0, in: Self.skillsName) }.sorted()
                == ["skill built-in-browser, LICENSE.txt", "skill built-in-browser, SKILL.md"])
        #expect(detail.files.allSatisfy { $0.change == .changed })
        #expect(try file(detail, "SKILL.md").at == Self.at1717)
        #expect(!detail.files.contains { ConfigSeal.fileLabel($0, in: Self.skillsName).contains("acct-1") })

        let source = ConfigSeal.likelySource(name: Self.skillsName, detail: detail, home: home)
        #expect(source == .likelySync)
        #expect(source.sentence == "Most likely Claude's own skill sync (in its account folder, its manifest updated at the same time). This can't be proved from the files.")
    }

    /// The sessions the card names: those the host says run, and of them only those that started before the change.
    @Test func theCardNamesTheTeamSessionsRunningThen() throws {
        let runtime = FakeRuntime()
        let (root, _) = try runningTeam(Self.syncFiles, runtime: runtime)
        try syncRound()
        let me = try #require(runtime.me.session)
        // The change was on a day past; the worker bound just now, after it, so it wasn't running then.
        guard case .refused = book.answer(.setGuarded(root: root, hashes: [ConfigSeal.checkKey: "1"]), from: .session(me), liveSessions: [me, "W1"]) else {
            Issue.record("not held")
            return
        }
        let held = try detail(root)
        #expect(held.sessionsKnown)
        #expect(!held.sessions.contains("worker t"), "\(held.sessions)")

        // A change at this moment, with the worker running: named.
        try write("again\n", syncFolder + "built-in-browser/SKILL.md")
        _ = book.answer(.setGuarded(root: root, hashes: [ConfigSeal.checkKey: "1"]), from: .session(me), liveSessions: ["W1"])
        let moved = try detail(root)
        #expect(moved.sessions == ["worker t"])
        let said = ConfigSeal.sessionsSaid([moved], allOutside: false)
        #expect(said.contains("worker t"))
        #expect(said.contains("None of them is shown to have made this change."))

        // What the host couldn't say isn't said as fact.
        #expect(ConfigSeal.sessionsSaid([ConfigSeal.HeldDetail(sessions: ["worker t"], sessionsKnown: false)], allOutside: false)
                .contains("isn't known"))
        #expect(ConfigSeal.sessionsSaid([], allOutside: false).contains("isn't known"))
    }

    /// Anything outside a sync folder says the source is unknown.
    @Test func aChangeOutsideASyncFolderHasNoLikelySource() throws {
        let runtime = FakeRuntime()
        var files = Self.syncFiles
        files[".claude/skills/mine/SKILL.md"] = "mine\n"
        let (root, asLead) = try runningTeam(files, runtime: runtime)
        try write("edited\n", home + "/.claude/skills/mine/SKILL.md")
        try syncRound()
        #expect(try asLead.checkConfig(root: root).held == [Self.skillsName])
        let source = ConfigSeal.likelySource(name: Self.skillsName, detail: try detail(root), home: home)
        #expect(source == .unknown("nothing in the files says what made this change."))
        #expect(source.sentence.hasPrefix("Source unknown"))
        #expect(ConfigSeal.fileLabel(try file(try detail(root), "mine/SKILL.md"), in: Self.skillsName) == "skill mine, SKILL.md")
    }

    /// A sync-folder change whose manifest didn't move, or moved too long after, says unknown. The manifest can land
    /// after the look that held it (the real round took 11 minutes), and the source is read at each look.
    @Test func aSyncChangeWithoutAManifestUpdateHasNoLikelySource() throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam(Self.syncFiles, runtime: runtime)
        try setTime(Self.at1717 - 90_000, syncFolder + "manifest.json")
        try syncRound(manifestAt: nil)
        #expect(try asLead.checkConfig(root: root).held == [Self.skillsName])
        let held = try detail(root)
        let unknown = ConfigSeal.likelySource(name: Self.skillsName, detail: held, home: home)
        #expect(unknown == .unknown("it's in Claude's sync folder, but the folder's manifest wasn't updated with it."))
        // Hours later is no round's manifest.
        try setTime(Self.at1717 + ConfigSeal.syncManifestLag + 10, syncFolder + "manifest.json")
        #expect(ConfigSeal.likelySource(name: Self.skillsName, detail: held, home: home) == unknown)
        // The round's manifest lands: most likely, read at this look.
        try setTime(Self.at1717 + Self.manifestLag, syncFolder + "manifest.json")
        #expect(ConfigSeal.likelySource(name: Self.skillsName, detail: held, home: home) == .likelySync)
        // A link where the manifest should be is no manifest.
        try FileManager.default.removeItem(atPath: syncFolder + "manifest.json")
        try FileManager.default.createSymbolicLink(atPath: syncFolder + "manifest.json", withDestinationPath: "/etc/hosts")
        #expect(ConfigSeal.likelySource(name: Self.skillsName, detail: held, home: home) == unknown)
    }

    /// What a sync-folder change can't be: a removal alone has no time, an unusual kind, or a file listed past the cap.
    @Test func unusualSyncChangesFailClosedToUnknown() throws {
        let row = { (path: String, kind: String?, at: Double?) in ConfigSeal.HeldFile(path: path, change: .changed, at: at, kind: kind) }
        let account = ".claude/skills/synced/acct-1/".dropFirst(".claude/skills/".count)
        try write("{}", home + "/" + Self.account + "manifest.json")
        try setTime(Self.at1717, syncFolder + "manifest.json")
        let at = Self.at1717
        func unknown(_ files: [ConfigSeal.HeldFile], more: Int = 0) -> Bool {
            if case .unknown = ConfigSeal.likelySource(name: Self.skillsName, detail: ConfigSeal.HeldDetail(files: files, more: more), home: home) { return true }
            return false
        }
        #expect(!unknown([row("\(account)skill/SKILL.md", "f", at)]))
        #expect(unknown([row("\(account)skill/SKILL.md", "f", nil)]), "a removal alone has no time")
        #expect(unknown([row("\(account)skill/SKILL.md", "l", at)]), "a link")
        #expect(unknown([row("\(account)skill/SKILL.md", nil, at)]), "no kind known")
        #expect(unknown([row("\(account)manifest.json", "f", at)]), "the bookkeeping's own name")
        #expect(unknown([row("\(account)skill/SKILL.md", "f", at)], more: 1), "not everything listed")
        #expect(unknown([]))
        #expect(unknown([row("synced/acct-1", "d", at)]), "the account folder itself")
        #expect(ConfigSeal.likelySource(name: "~/.claude/commands", detail: ConfigSeal.HeldDetail(files: [row("x", "f", at)]), home: home)
                == .unknown("nothing in the files says what made this change."))
    }

    /// Blind check: a sync-folder change that sat waiting isn't swept in by a later round's manifest, and a removal
    /// among the changes has no time to tie to the manifest.
    @Test func aLaterRoundsManifestDoesntCoverAnOlderChangeOrARemoval() throws {
        let at = Self.at1717
        try write("{}", syncFolder + "manifest.json")
        try setTime(at + 300, syncFolder + "manifest.json")
        let row = { (skill: String, time: Double?) in ConfigSeal.HeldFile(path: "synced/acct-1/\(skill)/SKILL.md", change: time == nil ? .removed : .changed, at: time, kind: "f") }
        let noManifest = ConfigSeal.Source.unknown("it's in Claude's sync folder, but the folder's manifest wasn't updated with it.")
        func source(_ files: [ConfigSeal.HeldFile]) -> ConfigSeal.Source {
            ConfigSeal.likelySource(name: Self.skillsName, detail: ConfigSeal.HeldDetail(files: files), home: home)
        }
        #expect(source([row("a", at), row("b", at + 60)]) == .likelySync)
        #expect(source([row("old", at - 4 * 3600), row("new", at)]) == noManifest, "the older edit had no manifest of its own")
        #expect(source([row("new", at), row("gone", nil)]) == noManifest)
    }

    /// A forged change in the sync folder that also rewrites the manifest still needs Accept, and is labelled only
    /// "most likely": the label never lets anything through.
    @Test func aForgedSyncThatRewritesTheManifestIsStillHeld() throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam(Self.syncFiles, runtime: runtime)
        try write("echo stolen\n", syncFolder + "built-in-browser/run.sh")
        try setTime(Self.at1717, syncFolder + "built-in-browser/run.sh")
        try write(#"{"round":9}"#, syncFolder + "manifest.json")
        try setTime(Self.at1717 + 5, syncFolder + "manifest.json")

        let check = try asLead.checkConfig(root: root)
        #expect(check.held == [Self.skillsName])
        #expect(check.outside.isEmpty)
        let source = ConfigSeal.likelySource(name: Self.skillsName, detail: try detail(root), home: home)
        #expect(source == .likelySync)
        #expect(source.sentence.hasPrefix("Most likely"))
        #expect(source.sentence.contains("can't be proved"))
        #expect(!source.sentence.lowercased().contains("safe"))
        #expect(vault.heldConfig(root: root) == [Self.skillsName], "the lead's look doesn't seal it")
        #expect(try asLead.checkConfig(root: root).held == [Self.skillsName])
    }

    /// The card's bug: Accept seals what the card showed. A file that changes after the card was drawn needs a new
    /// Accept, even when a look has held the new hash since: the vault then holds the new one, and its hash is what the
    /// app sealing "what's held" used to take.
    @Test func acceptSealsOnlyTheHashesItsCardShowedEvenAfterALookHeldNewOnes() throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam(Self.syncFiles, runtime: runtime)
        try syncRound()
        #expect(try asLead.checkConfig(root: root).held == [Self.skillsName])
        let drawn = ConfigSeal.heldHashes(in: try vault.guardedRecord(root: root))

        // A look re-holds what changed after the card was drawn: the held line now names the new file's hash.
        try write("name: browser\nchanged after the card\n", syncFolder + "built-in-browser/SKILL.md")
        #expect(try asLead.checkConfig(root: root).held == [Self.skillsName])
        #expect(ConfigSeal.heldHashes(in: try vault.guardedRecord(root: root)) != drawn)

        // The click on the old card seals nothing, and the card is held anew for what's there now.
        let click = try vault.checkConfig(root: root, shown: drawn)
        #expect(click.held == [Self.skillsName])
        #expect(click.resealed.isEmpty)
        #expect(vault.heldConfig(root: root) == [Self.skillsName])

        // Accepting what the card shows now seals it.
        let now = ConfigSeal.heldHashes(in: try vault.guardedRecord(root: root))
        let accepted = try vault.checkConfig(root: root, shown: now)
        #expect(accepted.held.isEmpty)
        #expect(accepted.resealed == [Self.skillsName])
        #expect(vault.heldConfig(root: root).isEmpty)
        #expect(try asLead.checkConfig(root: root) == LeadVault.ConfigCheck())
    }

    /// A held thing that the card didn't show (it came after the card was drawn) isn't sealed by its click.
    @Test func acceptDoesntSealAHeldThingItsCardNeverShowed() throws {
        let runtime = FakeRuntime()
        var files = Self.syncFiles
        files[".zshrc"] = "export A\n"
        let (root, asLead) = try runningTeam(files, runtime: runtime)
        try syncRound()
        _ = try asLead.checkConfig(root: root)
        let drawn = ConfigSeal.heldHashes(in: try vault.guardedRecord(root: root))
        try write("export B\n", home + "/.zshrc")
        #expect(Set(try asLead.checkConfig(root: root).held) == Set([Self.skillsName, "~/.zshrc"]))

        #expect(try vault.checkConfig(root: root, shown: drawn).held.contains("~/.zshrc"))
        #expect(vault.heldConfig(root: root).contains("~/.zshrc"))
    }

    /// The card can show the actual difference from what was last accepted: the changed line, with a little context.
    @Test func aChangedTextFileShowsItsDifferenceFromWhatWasLastAccepted() throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam(Self.syncFiles, runtime: runtime)
        try syncRound()
        _ = try asLead.checkConfig(root: root)
        let held = try file(try detail(root), "SKILL.md")

        guard case .lines(let lines, let more, let masked) = ConfigSeal.difference(of: held, in: Self.skillsName, home: home) else {
            Issue.record("no difference")
            return
        }
        #expect(more == 0)
        #expect(!masked)
        #expect(lines.contains { $0.kind == .removed && $0.text == "old line" })
        #expect(lines.contains { $0.kind == .added && $0.text == "new line" })
        #expect(lines.contains { $0.kind == .same && $0.text == "name: browser" })

        // After Accept, what was accepted is the earlier copy: the next change compares with it.
        #expect(try vault.checkConfig(root: root).resealed == [Self.skillsName])
        try write("name: browser\nthird line\nend\n", syncFolder + "built-in-browser/SKILL.md")
        #expect(try asLead.checkConfig(root: root).held == [Self.skillsName])
        guard case .lines(let next, _, _) = ConfigSeal.difference(of: try file(try detail(root), "SKILL.md"), in: Self.skillsName, home: home) else {
            Issue.record("no next difference")
            return
        }
        #expect(next.contains { $0.kind == .removed && $0.text == "new line" })
        #expect(next.contains { $0.kind == .added && $0.text == "third line" })
    }

    /// With no earlier copy, a binary file or an oversized one, the card says so plainly and shows no guess.
    @Test func noEarlierCopyBinaryAndOversizedSaySoPlainly() throws {
        let runtime = FakeRuntime()
        var files = Self.syncFiles
        files[Self.account + "bin/tool.dat"] = "was text\n"
        files[Self.account + "big/SKILL.md"] = String(repeating: "x", count: ConfigSeal.copyLimit + 10)
        let (root, asLead) = try runningTeam(files, runtime: runtime)
        // Sealed before this version: no copies yet, and none can be taken of what isn't as sealed.
        let copies = URL(fileURLWithPath: home).appendingPathComponent(".vibeswitcher/seal-copies")
        try? FileManager.default.removeItem(at: copies)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        try syncRound()
        try Data([0xFF, 0x00, 0x41]).write(to: URL(fileURLWithPath: syncFolder + "bin/tool.dat"))
        try write(String(repeating: "y", count: ConfigSeal.copyLimit + 20), syncFolder + "big/SKILL.md")
        #expect(try asLead.checkConfig(root: root).held == [Self.skillsName])
        let held = try detail(root)

        func said(_ suffix: String) throws -> String {
            guard case .unavailable(let why) = ConfigSeal.difference(of: try file(held, suffix), in: Self.skillsName, home: home) else {
                Issue.record("\(suffix): a difference was shown")
                return ""
            }
            return why
        }
        #expect(try said("SKILL.md").hasPrefix("No earlier copy was kept") || said("big/SKILL.md").contains("limit"))
        #expect(try said("built-in-browser/SKILL.md").hasPrefix("No earlier copy was kept"))
        #expect(try said("bin/tool.dat").contains("binary"))
        #expect(try said("big/SKILL.md").contains("256 KB"))
    }

    /// A file that changed after the card was drawn shows no difference: its text isn't what the card named.
    @Test func aFileChangedAfterTheCardWasDrawnShowsNoDifference() throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam(Self.syncFiles, runtime: runtime)
        try syncRound()
        _ = try asLead.checkConfig(root: root)
        let held = try file(try detail(root), "SKILL.md")
        try write("name: browser\nchanged since\nend\n", syncFolder + "built-in-browser/SKILL.md")
        guard case .unavailable(let why) = ConfigSeal.difference(of: held, in: Self.skillsName, home: home) else {
            Issue.record("showed text the card wasn't drawn from")
            return
        }
        #expect(why.contains("changed again"))
    }

    /// A planted copy (a worker's shell can write anywhere you can) is never shown as what was accepted.
    @Test func aPlantedCopyIsNeverShownAsTheEarlierText() throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam(Self.syncFiles, runtime: runtime)
        try syncRound()
        _ = try asLead.checkConfig(root: root)
        let held = try file(try detail(root), "SKILL.md")
        let folder = URL(fileURLWithPath: home).appendingPathComponent(".vibeswitcher/seal-copies")
        let name = SHA256.hash(data: Data(held.path.utf8)).map { String(format: "%02x", $0) }.joined()
        // The right header with the wrong text.
        let header = "420 \(held.before ?? "")\n"
        try VibePaths.writePrivate(Data(header.utf8) + Data("planted text\n".utf8), to: folder.appendingPathComponent(name))
        guard case .unavailable(let why) = ConfigSeal.difference(of: held, in: Self.skillsName, home: home) else {
            Issue.record("a planted copy was shown")
            return
        }
        #expect(why.hasPrefix("No earlier copy was kept"))
    }

    /// Text shown from a changed file is inert (no escape sequences, no bidirectional tricks, no Markdown taken as such
    /// by this layer), and secrets are masked.
    @Test func shownTextIsInertAndSecretsAreMasked() throws {
        let key = "sk-ant-api03-" + String(repeating: "A", count: 90)
        let before = "plain\nolder line\ntail\n"
        let after = "plain\n\u{1B}[31mred \u{202E}txet **bold** [link](https://example.invalid)\nexport TOKEN=\(key)\ntail\n"
        guard case .lines(let lines, _, _) = ConfigSeal.lines(before: before, after: after) else {
            Issue.record("no difference")
            return
        }
        let text = lines.map(\.text).joined(separator: "\n")
        #expect(!text.contains("\u{1B}"))
        #expect(!text.contains("\u{202E}"))
        #expect(text.contains("\u{FFFD}"))
        #expect(text.contains("**bold** [link](https://example.invalid)"), "kept as literal characters")
        #expect(!text.contains(key))
        #expect(!text.contains("AAAAAAAAAAAA"))

        // A secret that changed where nothing else did isn't reported as no change.
        let one = "token: " + "ghp_" + String(repeating: "a", count: 36) + "\n", two = "token: " + "ghp_" + String(repeating: "b", count: 36) + "\n"
        #expect(ConfigSeal.lines(before: one, after: two) == .sameText("The text is the same apart from a value masked as secret, which changed."))
        #expect(ConfigSeal.lines(before: "same\n", after: "same\n") == .sameText("The text is the same as last accepted: only the file's permissions or time changed."))
        guard case .lines(_, _, true) = ConfigSeal.lines(before: "other\n" + one, after: "changed\n" + two) else {
            Issue.record("a masked change went unmentioned")
            return
        }
        // A name is inert too.
        let inertName = ConfigSeal.fileLabel(ConfigSeal.HeldFile(path: "x\u{1B}[0m/SKILL\u{202E}.md", change: .changed, kind: "f"), in: Self.skillsName)
        #expect(!inertName.contains("\u{1B}"))
        #expect(!inertName.contains("\u{202E}"))
    }

    /// A long file shows only the changes with context, capped, and says how much more there is.
    @Test func aLongDifferenceIsCappedAndSaysSo() throws {
        let before = (0..<1000).map { "line \($0)" }.joined(separator: "\n")
        var lines = (0..<1000).map { "line \($0)" }
        for index in stride(from: 0, to: 1000, by: 2) { lines[index] = "changed \(index)" }
        guard case .lines(let shown, let more, _) = ConfigSeal.lines(before: before, after: lines.joined(separator: "\n")) else {
            Issue.record("no difference")
            return
        }
        #expect(shown.filter { $0.kind == .added || $0.kind == .removed }.count == ConfigSeal.shownLines)
        #expect(more > 0)
        // Far more differing lines than can be compared: not a guess.
        let huge = (0..<5000).map { "a\($0)" }.joined(separator: "\n"), other = (0..<5000).map { "b\($0)" }.joined(separator: "\n")
        #expect(ConfigSeal.lines(before: huge, after: other) == .unavailable("It's too long to compare (over \(ConfigSeal.comparedLines) changed lines)."))
    }

    /// Earlier copies are owner-only, capped, only of text under the watched skills, and go when superseded or removed.
    @Test func keptCopiesAreOwnerOnlyCappedAndCleanedUp() throws {
        let runtime = FakeRuntime()
        var files = Self.syncFiles
        files[".claude/skills/mine/SKILL.md"] = "mine\n"
        files[".claude/skills/mine/tool.bin"] = "x"
        files[".claude/commands/deploy.md"] = "a command\n"
        files[".claude/agents/one.md"] = "an agent\n"
        let (root, asLead) = try runningTeam(files, runtime: runtime)
        try Data([0, 1, 2]).write(to: URL(fileURLWithPath: home + "/.claude/skills/mine/tool.bin"))
        // The binary file is a change since the seal: held, then accepted, so what's sealed has one.
        #expect(try asLead.checkConfig(root: root).held == [Self.skillsName])
        #expect(try vault.checkConfig(root: root).resealed == [Self.skillsName])
        let folder = home + "/.vibeswitcher/seal-copies"
        var dir = stat()
        #expect(lstat(folder, &dir) == 0)
        #expect(dir.st_mode & 0o777 == 0o700)
        func copies() throws -> [String: Data] {
            try FileManager.default.contentsOfDirectory(atPath: folder).reduce(into: [:]) { $0[$1] = try Data(contentsOf: URL(fileURLWithPath: folder + "/" + $1)) }
        }
        var kept = try copies()
        #expect(!kept.isEmpty)
        for name in kept.keys {
            var info = stat()
            #expect(lstat(folder + "/" + name, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o600)
        }
        let all = kept.values.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(all.contains("mine\n"), "text under the skills is kept")
        #expect(!all.contains("a command"), "only the skill folders")
        #expect(!all.contains("an agent"))
        #expect(!all.contains(#"{"round":1}"#), "the sync's bookkeeping is no skill")
        #expect(!kept.values.contains { $0.contains(0) }, "a binary file is never copied")

        // Superseded: the accepted file's copy is the new one; a file removed goes with its copy.
        try write("mine two\n", home + "/.claude/skills/mine/SKILL.md")
        #expect(try asLead.checkConfig(root: root).held == [Self.skillsName])
        kept = try copies()
        #expect(kept.values.contains { String(decoding: $0, as: UTF8.self).contains("mine\n") }, "kept until accepted")
        #expect(try vault.checkConfig(root: root).resealed == [Self.skillsName])
        kept = try copies()
        #expect(!kept.values.contains { String(decoding: $0, as: UTF8.self).contains("mine\n") }, "superseded")
        #expect(kept.values.contains { String(decoding: $0, as: UTF8.self).contains("mine two\n") })
        try FileManager.default.removeItem(atPath: home + "/.claude/skills/mine")
        #expect(try asLead.checkConfig(root: root).held == [Self.skillsName])
        #expect(try vault.checkConfig(root: root).resealed == [Self.skillsName])
        #expect(!(try copies()).values.contains { String(decoding: $0, as: UTF8.self).contains("mine two") }, "gone with the file")

        #expect(ConfigSeal.copiesLimit <= 64 << 20)
        #expect(ConfigSeal.copyLimit <= 1 << 20)
    }

    /// Blind check: the cap holds for copies already kept, not only new ones, so the folder can't grow past it.
    @Test func theCopiesCapHoldsForWhatsAlreadyKept() throws {
        let folder = home + "/.claude/skills/"
        var sealed: [String: String] = [:]
        for name in ["aaa", "bbb", "ccc"] {
            try write(String(repeating: String(name.prefix(1)), count: 40) + "\n", folder + name + "/SKILL.md")
            var info = stat()
            #expect(lstat(folder + name + "/SKILL.md", &info) == 0)
            let digest = ConfigSeal.hex(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: folder + name + "/SKILL.md"))))
            sealed[name + "/SKILL.md"] = ConfigSeal.lineHash(path: name + "/SKILL.md", mode: info.st_mode & 0o777, digest: digest) + " f 1"
        }
        let copies = ConfigSeal.SealCopies(home: home)
        func kept() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: copies.folder.path)) ?? []).count }
        copies.reconcile(sealed: sealed, limit: 1000)
        #expect(kept() == 3)
        // A smaller cap, as when something earlier in name order grew: two fit, and the third copy goes.
        copies.reconcile(sealed: sealed, limit: 90)
        #expect(kept() == 2)
    }

    /// Blind check: however many files or however long their paths, a held line stays small enough for the one message
    /// the app reads it in (past `HostFrame.maxPayload` a hold would have no card and no Accept), and what's cut is counted.
    @Test func aHeldLineStaysWithinTheBudgetWhateverTheFolder() throws {
        func entries(_ count: Int, _ prefix: String) -> String {
            ConfigSeal.encode((0..<count).reduce(into: [:]) { $0["\(prefix)/\($1)"] = "aaaaaaaaaaaaaaaa f 100" })
        }
        let longName = String(repeating: "x", count: 900)
        let new = entries(1000, longName).replacingOccurrences(of: "aaaaaaaaaaaaaaaa", with: "bbbbbbbbbbbbbbbb")
        for name in [ConfigSeal.copiedFolder, "~/.claude/commands"] {
            let detail = ConfigSeal.heldDetail(name: name, from: entries(1000, longName), to: new, sessions: [], known: true)
            #expect(detail.written.utf8.count <= ConfigSeal.detailBudget(name) + 200, "\(detail.written.utf8.count)")
            #expect(detail.more > 0)
            #expect(detail.files.count + detail.more == 1000)
        }
        // Every watched home folder at once stays under the host's 1 MiB message.
        let folders = ConfigSeal.homeWatched(home: home).filter { $0.kind == .folder }.map(\.name)
        #expect(folders.reduce(0) { $0 + ConfigSeal.detailBudget($1) } < 900 << 10)
        // Not everything listed: the source can't be said.
        let cut = ConfigSeal.heldDetail(name: Self.skillsName, from: entries(2000, "synced/acct-1/a"),
                                        to: entries(2000, "synced/acct-1/a").replacingOccurrences(of: "aaaaaaaaaaaaaaaa", with: "bbbbbbbbbbbbbbbb"), sessions: [], known: true)
        #expect(cut.more > 0)
        #expect(ConfigSeal.likelySource(name: Self.skillsName, detail: cut, home: home) == .unknown("nothing in the files says what made this change."))
    }

    /// Many files are summarized by skill; the list on the line is capped; each file's name is still a person's.
    @Test func manyFilesAreSummarizedBySkill() {
        var files: [ConfigSeal.HeldFile] = []
        for skill in ["alpha", "beta"] {
            for index in 0..<4 { files.append(ConfigSeal.HeldFile(path: "synced/acct-1/\(skill)/f\(index).md", change: .changed, at: Double(100 + index), kind: "f")) }
        }
        files.append(ConfigSeal.HeldFile(path: "synced/acct-1/alpha/new.md", change: .added, at: 200, kind: "f"))
        files.append(ConfigSeal.HeldFile(path: "plain/SKILL.md", change: .removed, kind: "f"))
        let groups = ConfigSeal.groups(of: ConfigSeal.HeldDetail(files: files), in: ConfigSeal.copiedFolder)
        #expect(groups.map(\.label) == ["skill alpha", "skill beta", "skill plain"])
        #expect(groups[0].counts == "4 changed, 1 added")
        #expect(groups[0].at == 200)
        #expect(groups[2].counts == "1 removed")

        // Files named as the card will: a file straight in the account folder, the folder itself.
        let label = { (path: String, kind: String) in ConfigSeal.fileLabel(ConfigSeal.HeldFile(path: path, change: .changed, kind: kind), in: ConfigSeal.copiedFolder) }
        #expect(label("synced/acct-1/notes.txt", "f") == "Claude's sync folder, notes.txt")
        #expect(label("synced/acct-1/skill-a", "d") == "skill skill-a")
        #expect(label("synced/acct-1", "d") == "Claude's sync folder")
        #expect(label("loose.txt", "f") == "the skills folder, loose.txt")
        #expect(ConfigSeal.fileLabel(ConfigSeal.HeldFile(path: "deploy.md", change: .changed, kind: "f"), in: "~/.claude/commands") == "deploy.md")
    }

    /// Hook and settings changes behave as they did: the file's keys, no invented list of files or source.
    @Test func hookAndSettingsChangesStayAsTheyWere() throws {
        let runtime = FakeRuntime()
        let (root, asLead) = try runningTeam([".claude/settings.json": #"{"model":"opus"}"#], runtime: runtime)
        try write(#"{"model":"opus","hooks":{"SessionStart":[]}}"#, home + "/.claude/settings.json")
        #expect(try asLead.checkConfig(root: root).held == ["~/.claude/settings.json"])
        let record = try vault.guardedRecord(root: root)
        #expect(ConfigSeal.heldChanges(in: record)["~/.claude/settings.json"] == "hooks.SessionStart added")
        let detail = ConfigSeal.heldDetails(in: record)["~/.claude/settings.json"]
        #expect(detail?.files.isEmpty == true)
        #expect(ConfigSeal.likelySource(name: "~/.claude/settings.json", detail: detail, home: home) == .unknown("nothing in the files says what made this change."))
    }
}
