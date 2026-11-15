import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The held-config card's data (`ConfigHoldStore`; the app's `ConfigHoldsTests`, ported: the engine plan's E6): a held
/// folder's paths and time come from what the vault holds, never the folder's own modification time; `config held
/// --diff` names a change and shows its difference; an accept seals only what its card showed; and what the card shows
/// reaches the terminal inert.
struct ConfigHoldStoreTests {
    private let scratch = Scratch()

    /// A vault that answers with `record` and refuses everything else.
    private func vault(answering record: [String: String]) -> LeadVault {
        LeadVault(folder: scratch.url("vault")) { request in
            guard case .guarded = request else { throw LeadVault.Refused("none") }
            return .guarded(record)
        }
    }

    @Test func aHeldFoldersPathsAndTimeAreWhatTheVaultHolds() throws {
        let key = ConfigSeal.keyPrefix + "~/.claude/skills"
        let line = "\(key)\tH\tr\ta/SKILL.md changed, b/run.sh added and 3 more\t1700000500"
        let shown = try ConfigHoldStore.held(root: "/r", vault: vault(answering: [ConfigSeal.heldKey: line]), home: scratch.url("home").path).get()
        #expect(shown.items.map(\.name) == ["~/.claude/skills"])
        #expect(shown.items.first?.change == "a/SKILL.md changed, b/run.sh added and 3 more")
        #expect(shown.items.first?.changedAt == Date(timeIntervalSince1970: 1_700_000_500))
        #expect(shown.items.first?.size == nil)
        #expect(shown.items.first?.hash == "H")
        #expect(shown.hashes == [key: "H"])
    }

    /// A folder's own time is never shown: only a file's.
    @Test func changedAtReadsFilesNeverAFoldersOwnTime() throws {
        let home = scratch.url("home").path
        try FileManager.default.createDirectory(atPath: home + "/.claude/skills", withIntermediateDirectories: true)
        try "x\n".write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)
        let times = ConfigHoldStore.changedAt(["~/.claude/skills", "~/.zshrc"], root: "/r", home: home)
        #expect(times["~/.claude/skills"] == nil)
        #expect(times["~/.zshrc"] != nil)
    }

    /// A plugin's or a settings file's scripts carry no time: their path's time isn't when the code that changed was.
    @Test func changedAtGivesAPluginOrASettingsScriptsNoTime() throws {
        let home = scratch.url("home").path
        let install = home + "/.claude/plugins/cache/m/p/1"
        try FileManager.default.createDirectory(atPath: install, withIntermediateDirectories: true)
        try #"{"enabledPlugins":{"p@m":true}}"#.write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
        try #"{"version":2,"plugins":{"p@m":[{"scope":"user","installPath":"\#(install)"}]}}"#
            .write(toFile: home + "/.claude/plugins/installed_plugins.json", atomically: true, encoding: .utf8)
        let times = ConfigHoldStore.changedAt(["~/.claude/settings.json's scripts", "~/.claude/plugins: p@m", "~/.claude/settings.json"], root: "/r", home: home)
        #expect(times["~/.claude/settings.json's scripts"] == nil)
        #expect(times["~/.claude/plugins: p@m"] == nil)
        #expect(times["~/.claude/settings.json"] != nil)
    }

    // MARK: The card's detail

    /// A vault's whole loop: a real book on a scratch home, a lead and a worker, and the sync's folder sealed.
    private func team() throws -> (home: String, root: String, app: LeadVault, asLead: LeadVault, skill: String, manifest: String) {
        let home = scratch.url("home").resolvingSymlinksInPath().path
        let folder = scratch.url("vault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = ((home as NSString).appendingPathComponent("repo") as NSString).standardizingPath
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let account = home + "/.claude/skills/synced/acct-1"
        try FileManager.default.createDirectory(atPath: account + "/built-in-browser", withIntermediateDirectories: true)
        let skill = account + "/built-in-browser/SKILL.md", manifest = account + "/manifest.json"
        try "name: browser\nold\nend\n".write(toFile: skill, atomically: true, encoding: .utf8)
        try #"{"round":1}"#.write(toFile: manifest, atomically: true, encoding: .utf8)
        let book = LeadVault.Book()
        book.configHome = home
        let app = book.vault(folder: folder, as: { .app })
        try app.bind(try app.startLead(root: root, branch: "main"), root: root, session: "lead-session")
        #expect(try app.checkConfig(root: root).held.isEmpty)
        let lead = book.vault(folder: folder, as: { .session("lead-session") })
        try lead.bind(try lead.issue(role: .worker, root: root, task: "sandbox-task"), root: root, session: "worker-session")
        return (home, root, app, lead, skill, manifest)
    }

    /// The reported change on the card: named by skill with its time, and its difference (`config held --diff NAME`).
    @Test func theHeldListNamesTheChangeAndCanShowItsDifference() throws {
        let team = try team()
        try "name: browser\nnew\nend\n".write(toFile: team.skill, atomically: true, encoding: .utf8)
        try #"{"round":2}"#.write(toFile: team.manifest, atomically: true, encoding: .utf8)
        #expect(try team.asLead.checkConfig(root: team.root).held == ["~/.claude/skills"])

        let shown = try ConfigHoldStore.held(root: team.root, vault: team.app, home: team.home, look: false).get()
        let item = try #require(shown.items.first { $0.name == "~/.claude/skills" })
        let file = try #require(item.files.first)
        #expect(ConfigSeal.fileLabel(file, in: "~/.claude/skills") == "skill built-in-browser, SKILL.md")
        #expect(file.at != nil)
        #expect(item.hash.count == 12)
        let difference = try #require(ConfigHoldStore.difference(shown, name: "~/.claude/skills", home: team.home))
        #expect(difference.contains("- old"), "\(difference)")
        #expect(difference.contains("+ new"), "\(difference)")
        #expect(ConfigHoldStore.difference(shown, name: "~/.nothing", home: team.home) == nil)
    }

    /// An accept seals what the card showed: a file that changed after the card was drawn, even one a look has held
    /// since, isn't sealed, and it says so; a card drawn again seals it.
    @Test func acceptOnAListDrawnBeforeAChangeSealsNothing() throws {
        let team = try team()
        try "name: browser\nnew\nend\n".write(toFile: team.skill, atomically: true, encoding: .utf8)
        #expect(try team.asLead.checkConfig(root: team.root).held == ["~/.claude/skills"])
        let card = try ConfigHoldStore.held(root: team.root, vault: team.app, home: team.home, look: false).get()

        try "name: browser\nnewer\nend\n".write(toFile: team.skill, atomically: true, encoding: .utf8)
        _ = try team.asLead.checkConfig(root: team.root)
        let stale = try ConfigHoldStore.accept(card, root: team.root, vault: team.app).get()
        #expect(stale == .changedSince(held: ["~/.claude/skills"]))
        #expect(ConfigSeal.held(in: try team.app.guardedRecord(root: team.root)) == ["~/.claude/skills"])

        let drawn = try ConfigHoldStore.held(root: team.root, vault: team.app, home: team.home, look: false).get()
        guard case .sealed(let names, _) = try ConfigHoldStore.accept(drawn, root: team.root, vault: team.app).get() else {
            Issue.record("the card drawn again didn't seal")
            return
        }
        #expect(names == ["~/.claude/skills"])
        #expect(ConfigSeal.held(in: try team.app.guardedRecord(root: team.root)).isEmpty)
    }

    /// The app's `theCardDrawsChangedFileTextVerbatim`: what the card shows of a changed file (its name, what changed,
    /// its files) reaches the terminal with control and bidirectional characters stripped (`ConfigSeal.inert`).
    @Test func heldTextIsPrintedInert() throws {
        let evil = "\u{1B}]0;owned\u{07}\u{1B}[2J\u{202E}gpj.exe"
        var card = CardStore.Card(root: "/r", kind: .configHeld)
        card.config = ConfigHoldStore.Shown(items: [ConfigHoldStore.Item(name: "~/.claude/skills\(evil)", hash: "abc\(evil)", change: "a/\(evil) changed")],
                                            baseBranch: "main\(evil)")
        let text = CardText.lines(card.value).joined(separator: "\n")
        #expect(text.contains("~/.claude/skills") && text.contains("changed"), "\(text)")
        let forbidden = text.unicodeScalars.filter { $0.value < 0x20 && $0 != "\n" || $0.value == 0x7F || (0x202A...0x202E).contains($0.value) }
        #expect(forbidden.isEmpty, "\(forbidden.map { String($0.value, radix: 16) })")
    }
}
