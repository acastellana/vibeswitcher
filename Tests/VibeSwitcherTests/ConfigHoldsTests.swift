import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The card's data (`ConfigHolds`): a held folder's paths and time come from what the vault holds, never from the
/// folder's own modification time (which moves with whatever is written in it).
struct ConfigHoldsTests {
    private let scratch = Scratch()

    /// A vault that answers with `record`, and holds that look inline.
    func holds(answering record: [String: String]) -> ConfigHolds {
        let vault = LeadVault(folder: scratch.url("vault")) { request in
            guard case .guarded = request else { throw LeadVault.Refused("none") }
            return .guarded(record)
        }
        return ConfigHolds(vault: vault, background: { $0() }, main: { $0() })
    }

    @Test func aHeldFoldersPathsAndTimeAreWhatTheVaultHolds() {
        let key = ConfigSeal.keyPrefix + "~/.claude/skills"
        let line = "\(key)\tH\tr\ta/SKILL.md changed, b/run.sh added and 3 more\t1700000500"
        let holds = holds(answering: [ConfigSeal.heldKey: line])
        holds.look(["/r"])
        #expect(holds.held["/r"] == ["~/.claude/skills"])
        #expect(holds.changes["/r"]?["~/.claude/skills"] == "a/SKILL.md changed, b/run.sh added and 3 more")
        #expect(holds.changedAt["/r"]?["~/.claude/skills"] == Date(timeIntervalSince1970: 1_700_000_500))
    }

    /// A folder's own time is never shown: only a file's.
    @Test func changedAtReadsFilesNeverAFoldersOwnTime() throws {
        let home = scratch.url("home").path
        try FileManager.default.createDirectory(atPath: home + "/.claude/skills", withIntermediateDirectories: true)
        try "x\n".write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)
        let times = ConfigHolds.changedAt(["~/.claude/skills", "~/.zshrc"], root: "/r", home: home)
        #expect(times["~/.claude/skills"] == nil)
        #expect(times["~/.zshrc"] != nil)
    }

    /// Blind check: a plugin's or a settings file's scripts carry no time on the card: their path's time (the version
    /// folder's, settings.json's) isn't when the code that changed was changed.
    @Test func changedAtGivesAPluginOrASettingsScriptsNoTime() throws {
        let home = scratch.url("home").path
        let install = home + "/.claude/plugins/cache/m/p/1"
        try FileManager.default.createDirectory(atPath: install, withIntermediateDirectories: true)
        try #"{"enabledPlugins":{"p@m":true}}"#.write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
        try #"{"version":2,"plugins":{"p@m":[{"scope":"user","installPath":"\#(install)"}]}}"#
            .write(toFile: home + "/.claude/plugins/installed_plugins.json", atomically: true, encoding: .utf8)
        let times = ConfigHolds.changedAt(["~/.claude/settings.json's scripts", "~/.claude/plugins: p@m", "~/.claude/settings.json"], root: "/r", home: home)
        #expect(times["~/.claude/settings.json's scripts"] == nil)
        #expect(times["~/.claude/plugins: p@m"] == nil)
        #expect(times["~/.claude/settings.json"] != nil)
    }

    // MARK: The card's detail

    /// A vault's whole loop: a real book on a scratch home, a lead and a worker, and the sync's folder sealed; the app's
    /// card reads from the vault and home, one look inline.
    func team() throws -> (home: String, root: String, card: ConfigHolds, asLead: LeadVault, skill: String, manifest: String) {
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
        let card = ConfigHolds(vault: app, home: home, background: { $0() }, main: { $0() })
        return (home, root, card, lead, skill, manifest)
    }

    /// The reported change, on the card's data: named by skill with its time, most likely the sync, its difference
    /// read on request.
    @Test func theCardNamesTheChangeAndCanShowItsDifference() throws {
        let team = try team()
        try "name: browser\nnew\nend\n".write(toFile: team.skill, atomically: true, encoding: .utf8)
        try #"{"round":2}"#.write(toFile: team.manifest, atomically: true, encoding: .utf8)
        #expect(try team.asLead.checkConfig(root: team.root).held == ["~/.claude/skills"])

        team.card.look([team.root])
        let detail = try #require(team.card.details[team.root]?["~/.claude/skills"])
        let file = try #require(detail.files.first)
        #expect(ConfigSeal.fileLabel(file, in: "~/.claude/skills") == "skill built-in-browser, SKILL.md")
        #expect(file.at != nil)
        #expect(team.card.sources[team.root]?["~/.claude/skills"] == .likelySync)

        team.card.toggleDifference(root: team.root, name: "~/.claude/skills", file: file)
        guard case .lines(let lines, _, _)? = team.card.differences[ConfigHolds.differenceKey(root: team.root, name: "~/.claude/skills", file: file)] else {
            Issue.record("no difference")
            return
        }
        #expect(lines.contains { $0.kind == .removed && $0.text == "old" })
        #expect(lines.contains { $0.kind == .added && $0.text == "new" })
    }

    /// Accept seals what the card showed: a file that changes after the card was drawn, even one a look has held since,
    /// isn't sealed by the click, which says so; the redrawn card's Accept seals it.
    @Test func acceptOnACardDrawnBeforeAChangeSealsNothing() throws {
        let team = try team()
        try "name: browser\nnew\nend\n".write(toFile: team.skill, atomically: true, encoding: .utf8)
        #expect(try team.asLead.checkConfig(root: team.root).held == ["~/.claude/skills"])
        team.card.look([team.root])

        // Changes after the card was drawn, and a look holds it again before the click.
        try "name: browser\nnewer\nend\n".write(toFile: team.skill, atomically: true, encoding: .utf8)
        _ = try team.asLead.checkConfig(root: team.root)
        var accepted: [String] = []
        team.card.onAccepted = { _, names in accepted = names }
        team.card.accept(team.root)
        #expect(accepted.isEmpty)
        #expect(team.card.held[team.root] == ["~/.claude/skills"])
        #expect(team.card.notices[team.root]?.contains("nothing was accepted") == true)

        // The redrawn card's Accept seals what's there now.
        team.card.accept(team.root)
        #expect(accepted == ["~/.claude/skills"])
        #expect(team.card.held[team.root] == nil)
        #expect(team.card.notices[team.root] == nil)
    }

    /// Text shown from a changed file is drawn inert: the card's difference and file names go through `Text(verbatim:)`,
    /// which takes no Markdown (`ConfigSeal.inert` has already stripped control and bidirectional characters).
    @Test func theCardDrawsChangedFileTextVerbatim() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VibeSwitcher/MainWindow/Lead/LeadViews.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        #expect(source.contains("Text(verbatim: Self.marker(line.kind) + line.text)"))
        #expect(source.contains("Text(verbatim: ConfigSeal.fileLabel(file, in: name))"))
    }
}
