import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The plain held-config card (2026-11-25, the user after `vibeswitcher approve`: "I don't understand why all this
/// notice has so much text … I just accepted them but I have no idea what I did"; and the review the same day: "collapse
/// only what is safe to not read"). Every held thing named by its path in neutral words (`HeldWhat`), only what the node
/// recognises as an update counted past three lines; whom it holds; the rules that would change, or on a first accept
/// those not at their default; never a hash, a mark or the node's words for its record. Today's real cases.
@Suite
struct HeldWhatTests {
    private let scratch = Scratch()
    static let commit = "3e9df41a" + String(repeating: "0", count: 32)
    static let facts = HeldWhat.Facts(claudeVersion: "2.1.332", pluginVersions: ["genlayernode@genlayerlabs": "0.4.1", "context7@claude-plugins-official": "1.0.2"],
                                      unitBuild: commit, unknownStartup: ["VibeSwitcher node.lnk"])
    static let startup = "/mnt/c/Users/kstel/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup"
    static let when = "2026-11-25T14:49:07Z"
    /// Words a default screen never says (the user's terms: accepted, the node, your last accept, rules, review rules).
    static let jargon = ["snapshot", "seal", "vault", "hash", "guard rail", "review floor"]

    static func file(_ path: String, _ change: ConfigSeal.HeldFile.Change = .changed) -> ConfigSeal.HeldFile {
        ConfigSeal.HeldFile(path: path, change: change, at: 1_795_600_000, kind: "f", before: nil, after: nil)
    }

    static func item(_ name: String, change: String? = nil, files: [ConfigSeal.HeldFile] = [], since: String? = "changed since your last accept (\(when))",
                     keys: [ConfigSeal.KeyChange]? = nil) -> ConfigHoldStore.Item {
        var item = ConfigHoldStore.Item(name: name, hash: "abcdef012345", change: change, outside: true, files: files, sinceAccept: since)
        item.keys = keys
        item.about = HeldWhat.describe(item, facts: facts)
        return item
    }

    static func rail(_ key: String, _ value: String, changed: ConfigHoldStore.Rail.Changed = .unknown, old: String? = nil, records: Bool? = false,
                     atDefault: Bool? = nil) -> ConfigHoldStore.Rail {
        var rail = ConfigHoldStore.Rail(key: key, value: value, sinceAccept: AcceptedSnapshot.unvouched(when))
        (rail.changed, rail.old, rail.records, rail.atDefault) = (changed, old, records, atDefault)
        return rail
    }

    static func card(root: String, items: [ConfigHoldStore.Item], rails: [ConfigHoldStore.Rail] = [], project: String?, recordsAll: Bool = false) -> NodeWire.Value {
        var card = CardStore.Card(root: root, kind: .configHeld)
        var shown = ConfigHoldStore.Shown(items: items, guarded: rails, lastAccept: Date(timeIntervalSince1970: 1_795_600_000))
        shown.summary = HeldWhat.summary(items: items)
        (shown.holds, shown.holdsEvery, shown.recordsAll) = (project, project == nil, recordsAll)
        card.config = shown
        return card.value
    }

    static func plain(_ card: NodeWire.Value) -> String { CardText.lines(card).joined(separator: "\n") }

    /// The main checkout's .git/config with these changed keys, as the vault keeps them (data, and the joined words).
    static func git(_ keys: [ConfigSeal.KeyChange]) -> ConfigHoldStore.Item {
        item(".git/config (main checkout)", change: keys.map { "\($0.key) \($0.change.rawValue)" }.joined(separator: ", "), keys: keys)
    }

    static func git(_ words: String) -> ConfigHoldStore.Item {
        git(words.components(separatedBy: ", ").map { part in
            let bits = part.split(separator: " ")
            return ConfigSeal.KeyChange(key: String(bits[0]), change: ConfigSeal.HeldFile.Change(rawValue: String(bits[1])) ?? .changed)
        })
    }

    static let install = item("~/.vibeswitcher/v2/builds", files: [file(commit + "/bin/vibeswitcher", .added), file(commit + "/build-info", .added)])

    static let claude = [item("~/.local/share/claude/versions", files: [file("2.1.332", .added)]), item("~/.local/bin", files: [file("claude")])]

    @Test func eachIsItsPathInNeutralWords() {
        let say = { (item: ConfigHoldStore.Item) in item.about.map { "\($0.kind.rawValue): \($0.what)" } ?? "" }
        #expect(say(Self.claude[0]) == "claude-update: ~/.local/share/claude/versions: 2.1.332 added (looks like Claude Code's own update)")
        #expect(say(Self.claude[1]) == "claude-update: ~/.local/bin/claude now points to 2.1.332 (looks like Claude Code's own update)")
        // The link's likeness needs the link among the files: no file list is no likeness.
        #expect(say(Self.item("~/.local/bin")) == "other: ~/.local/bin changed")
        #expect(say(Self.item("~/.local/bin", files: [Self.file("claude"), Self.file("passage")])) == "other: ~/.local/bin: claude, passage changed")
        #expect(say(Self.item("~/.claude/plugins: genlayernode@genlayerlabs", change: "version folder changed"))
                == "plugin-update: ~/.claude/plugins: genlayernode@genlayerlabs: now version 0.4.1 (looks like the plugin's own update)")
        // A plugin whose hooks changed without a new version isn't an update: said whole, named.
        #expect(say(Self.item("~/.claude/plugins: genlayernode@genlayerlabs", change: "hooks/hooks.json changed"))
                == "other: ~/.claude/plugins: genlayernode@genlayerlabs: hooks/hooks.json changed")
        #expect(say(Self.item("~/.config/systemd/user", files: [Self.file("vibeswitcher-node.service")]))
                == "build-switch: ~/.config/systemd/user/vibeswitcher-node.service now starts build 3e9df41a (looks like VibeSwitcher's own switch)")
        #expect(say(Self.install)
                == "build-switch: ~/.vibeswitcher/v2/builds: build 3e9df41a added (looks like VibeSwitcher's own install)")
        #expect(say(Self.git("branch.v2-usage.merge added, branch.v2-usage.remote added"))
                == "git-config: .git/config (main checkout): the tracking entry of branch v2-usage (branch.v2-usage.merge added, branch.v2-usage.remote added)")
        #expect(say(Self.git("core.hookspath added")) == "git-config: .git/config (main checkout): core.hookspath added")
        // A tracking entry beside another key is no tracking entry: every key named, the risky ones first.
        #expect(say(Self.git("branch.v2.merge added, core.hookspath added, user.name changed"))
                == "git-config: .git/config (main checkout): core.hookspath added, and 2 others")
        #expect(say(Self.item(Self.startup)) == "startup: \(Self.startup): VibeSwitcher node.lnk not on your list of known shortcuts")
        #expect(say(Self.item("~/.claude/settings.json", change: "model changed")) == "settings: ~/.claude/settings.json: model changed")
        #expect(say(Self.item("~/.zshrc")) == "other: ~/.zshrc changed")
    }

    /// A git config's keys, so a branch's tracking entry is named (`ConfigSeal.gitKeys`; names, never values).
    @Test func aGitConfigsChangedKeysAreNamed() {
        let before = "[core]\n\trepositoryformatversion = 0\n[remote \"origin\"]\n\turl = git@example.com:x/y.git\n"
        let after = before + "[branch \"v2-usage\"]\n\tremote = origin\n\tmerge = refs/heads/v2-usage\n"
        let change = ConfigSeal.changedKeys(from: ConfigSeal.encode(ConfigSeal.gitKeys(before) ?? [:]), to: ConfigSeal.encode(ConfigSeal.gitKeys(after) ?? [:]))
        #expect(change == "branch.v2-usage.merge added, branch.v2-usage.remote added", "\(String(describing: change))")
        #expect(HeldWhat.tracking(ConfigSeal.keyChanges(from: ConfigSeal.encode(ConfigSeal.gitKeys(before) ?? [:]), to: ConfigSeal.encode(ConfigSeal.gitKeys(after) ?? [:])) ?? [])
                == ["v2-usage"])
        #expect(!(change ?? "").contains("refs/heads"), "no value")
        let moved = before.replacingOccurrences(of: "x/y.git", with: "x/z.git")
        #expect(ConfigSeal.changedKeys(from: ConfigSeal.encode(ConfigSeal.gitKeys(before) ?? [:]), to: ConfigSeal.encode(ConfigSeal.gitKeys(moved) ?? [:]))
                == "remote.\(ConfigSeal.subsectionLabel("origin")).url changed", "a remote's name is a label too")
    }

    /// Five things that look like updates and one settings change: the settings change is named first, whatever the count.
    @Test func aSettingsChangeIsNeverFoldedBehindUpdates() {
        let items = Self.claude + [Self.item("~/.claude/plugins: genlayernode@genlayerlabs", change: "version folder changed"),
                                   Self.item("~/.claude/plugins: context7@claude-plugins-official", change: "version folder changed"),
                                   Self.install,
                                   Self.item("~/.claude/settings.json", change: "model changed")]
        let lines = CardText.plainConfig(Self.card(root: "/home/someone", items: items, project: nil))
        #expect(lines.first == "~/.claude/settings.json: model changed", "\(lines)")
        #expect(lines.contains("and 3 more that look like updates (--long lists them)"), "\(lines)")
        #expect(lines.filter { $0.contains("looks like") }.count == 2, "\(lines)")
    }

    /// A held thing that can't be compared with the last accept (its record not one this node vouches for) is named like
    /// any other, saying so; never counted, never blamed on a restart.
    @Test func aThingThatCantBeComparedIsNamed() {
        let unknown = Self.item("~/.zshrc", since: AcceptedSnapshot.unvouched(Self.when))
        let lines = CardText.plainConfig(Self.card(root: "/home/someone/projects/repo", items: [unknown], project: "repo"))
        #expect(lines == ["~/.zshrc changed (can't be compared with your last accept)", "holds repo (no new worker, verifier or merge until you accept)"], "\(lines)")
    }

    /// Today's home folder card: Claude Code updated itself, a plugin updated, the Startup folder, the model changed,
    /// VibeSwitcher switched (seven paths), eleven rules the node already holds: three things named, four counted.
    @Test func theSevenPathCard() {
        let items = Self.claude + [Self.item("~/.claude/plugins: genlayernode@genlayerlabs", change: "version folder changed"),
                                   Self.item(Self.startup),
                                   Self.item("~/.claude/settings.json", change: "model changed"),
                                   Self.item("~/.config/systemd/user", files: [Self.file("vibeswitcher-node.service")]),
                                   Self.install]
        let rails = (0..<11).map { Self.rail("rule\($0)", "\($0)") }
        let card = Self.card(root: "/home/someone", items: items, rails: rails, project: nil)
        #expect(CardText.plainConfig(card) == [
            "\(Self.startup): VibeSwitcher node.lnk not on your list of known shortcuts",
            "~/.claude/settings.json: model changed",
            "~/.local/share/claude/versions: 2.1.332 added (looks like Claude Code's own update)",
            "and 4 more that look like updates (--long lists them)",
            "holds every project (no new worker, verifier or merge until you accept)",
        ], "\(CardText.plainConfig(card))")
        let text = Self.plain(card).lowercased()
        for word in Self.jargon { #expect(!text.contains(word), "\(word): \(text)") }
        // `--long` is today's whole card: every path, hash and rule.
        let long = CardText.lines(card, long: true)
        #expect(long.filter { $0.contains("hash abcdef012345") }.count == 7 && long.filter { $0.hasPrefix("    rule") }.count == 11, "\(long)")
        #expect(CardText.acceptedLine(card, count: 7) == "accepted: your home folder's config, 7 changes")
        #expect(CardText.listLine(card).hasPrefix("your home folder's config: \(Self.startup): VibeSwitcher node.lnk"))
    }

    /// VibeSwitcher's own switch: its unit and its builds folder, holding the project; a line in `approve`'s list.
    @Test func theSwitchsTwo() {
        let items = [Self.item("~/.config/systemd/user", files: [Self.file("vibeswitcher-node.service")]),
                     Self.install]
        let card = Self.card(root: "/home/someone/projects/vibeswitcher-v2-lead", items: items, project: "vibeswitcher-v2-lead")
        #expect(CardText.plainConfig(card) == [
            "~/.config/systemd/user/vibeswitcher-node.service now starts build 3e9df41a (looks like VibeSwitcher's own switch)",
            "~/.vibeswitcher/v2/builds: build 3e9df41a added (looks like VibeSwitcher's own install)",
            "holds vibeswitcher-v2-lead (no new worker, verifier or merge until you accept)",
        ], "\(CardText.plainConfig(card))")
        #expect(CardText.acceptedLine(card, count: 2) == "accepted: vibeswitcher-v2-lead, 2 changes")
        #expect(CardText.acceptedLine(card, count: 1, waits: true) == "accepted: vibeswitcher-v2-lead, 1 change; it still waits on your home folder's card")
    }

    /// A rule that changed is its name, old → new; one the accept records anew is said with its value; at most five,
    /// the rest counted; the same and the uncomparable ones the node already holds say nothing.
    @Test func aChangedAutoAdvance() {
        var rails = [Self.rail("auto_advance", "true", changed: .changed, old: "false", records: true),
                     Self.rail("max_workers", "3", changed: .same), Self.rail("risk_lines", "400"),
                     Self.rail("heavy_slots", "1", changed: .changed, records: true)]
        let card = Self.card(root: "/home/someone/projects/vibeswitcher", items: [Self.git("branch.v2.merge added")],
                             rails: rails, project: "vibeswitcher")
        #expect(CardText.plainConfig(card) == [
            ".git/config (main checkout): the tracking entry of branch v2 (branch.v2.merge added)",
            "holds vibeswitcher (no new worker, verifier or merge until you accept)",
            "auto_advance: false → true",
            "heavy_slots: (not set) → 1",
        ], "\(CardText.plainConfig(card))")
        #expect(WireSchema.check(card, as: "card") == nil, "\(WireSchema.check(card, as: "card") ?? "")")
        let item = card["config"]?["items"]?.array?.first
        #expect(item?["kind"]?.string == "git-config" && item?["what"]?.string?.hasPrefix(".git/config (main checkout)") == true)
        rails += (0..<4).map { Self.rail("changed\($0)", "x", changed: .changed, old: "y", records: true) }
        let many = CardText.plainConfig(Self.card(root: "/r", items: [], rails: rails, project: "r"))
        #expect(many.filter { $0.contains(" → ") }.count == 5 && many.contains("and 1 more rules that would change (--long shows them)"), "\(many)")
    }

    /// A first accept (no rules recorded yet) names every rule not at its default, the sandbox's first, at most eight,
    /// and counts the ones at their defaults.
    @Test func aFirstAcceptNamesTheRulesNotAtTheirDefaults() {
        let rails = [Self.rail("test_command", "make test", records: nil, atDefault: false), Self.rail("max_workers", "3", records: nil, atDefault: true),
                     Self.rail("sandbox_read", "~/.local/share/swiftly", records: nil, atDefault: false),
                     Self.rail("audit_finders", "1", records: nil, atDefault: true)]
        let card = Self.card(root: "/r", items: [], rails: rails, project: "r", recordsAll: true)
        #expect(CardText.plainConfig(card) == [
            "nothing held: accepting records the rules workflow.md proposes",
            "rules this accept records:",
            "  sandbox_read: ~/.local/share/swiftly",
            "  test_command: make test",
            "and 2 rules at their defaults",
        ], "\(CardText.plainConfig(card))")
        let many = (0..<10).map { Self.rail("rule\($0)", "v", records: nil, atDefault: false) }
        let lines = CardText.plainConfig(Self.card(root: "/r", items: [], rails: many, project: "r", recordsAll: true))
        #expect(lines.filter { $0.hasPrefix("  rule") }.count == 8 && lines.contains("  and 2 more (--long shows them)"), "\(lines)")
    }

    /// The node couldn't say which rules it holds: no card is drawn (what the accept would record can't be told).
    @Test func aVaultThatCantBeAskedDrawsNoCard() throws {
        let asked = Locked(0)
        let vault = LeadVault(folder: scratch.url("vault")) { request in
            guard case .guarded = request else { throw LeadVault.Refused("not this") }
            asked.mutate { $0 += 1 }
            // The record first (what's held), then the rules: that one doesn't answer.
            if asked.value == 1 { return .guarded([:]) }
            throw LeadVault.Refused("the host didn't answer")
        }
        let held = ConfigHoldStore.held(root: scratch.url("repo").path, vault: vault, home: scratch.url("home").path, look: false)
        guard case .failure(let error) = held else { Issue.record("a card was drawn: \(held)"); return }
        #expect("\(error)".contains("didn't answer"), "\(error)")
        #expect(asked.value == 2)
    }

    /// The git config parser understands the whole file or nothing (the card then says only that it changed): a key on
    /// a header's own line, a continued line, an include.
    @Test func aGitConfigItCantFullyReadHasNoKeys() {
        #expect(ConfigSeal.gitKeys("[core]\n\tbare = false\n[branch \"v2\"]\n\tremote = origin\n")?.keys.sorted() == ["branch.v2.remote", "core.bare"])
        #expect(ConfigSeal.gitKeys("[core] sshCommand = ssh -i x\n") == nil, "a key after the header's ]")
        #expect(ConfigSeal.gitKeys("[alias]\n\tx = !echo \\\n\t\tdone\n") == nil, "a continued line")
        #expect(ConfigSeal.gitKeys("[include]\n\tpath = ~/elsewhere\n") == nil && ConfigSeal.gitKeys("[includeIf \"gitdir:~/w/\"]\n\tpath = x\n") == nil)
        #expect(ConfigSeal.gitKeys("[core.x]\n\tbare = false\n") == nil && ConfigSeal.gitKeys("bare = false\n") == nil)
        #expect(ConfigSeal.gitKeys("[core]\n\tbad_name = 1\n") == nil && ConfigSeal.gitKeys("[core]\n\t = 1\n") == nil)
        // No keys: the vault notes no change words, so the card says the file changed and nothing else.
        #expect(ConfigSeal.changedKeys(from: ConfigSeal.encode(ConfigSeal.gitKeys("[core]\n\tbare = false\n") ?? [:]), to: nil) == nil)
        #expect(Self.item(".git/config (main checkout)").about?.what == ".git/config (main checkout) changed")
    }

    /// An update is exactly one, or it's named as what it is: the unit's drop-in, a plugin's hooks beside its new
    /// version, a file changed inside an existing build, a version file replaced.
    @Test func onlyExactlyAnUpdateIsCalledOne() {
        let dropIn = Self.item("~/.config/systemd/user", files: [Self.file("vibeswitcher-node.service.d/x.conf", .added)])
        #expect(dropIn.about?.kind == .other && dropIn.about?.what == "~/.config/systemd/user: vibeswitcher-node.service.d/x.conf changed", "\(String(describing: dropIn.about))")
        let hooks = Self.item("~/.claude/plugins: genlayernode@genlayerlabs", change: "version folder changed, hooks/hooks.json changed")
        #expect(hooks.about?.kind == .other && hooks.about?.what.contains("hooks/hooks.json changed") == true, "\(String(describing: hooks.about))")
        let inside = Self.item("~/.vibeswitcher/v2/builds", files: [Self.file(Self.commit + "/bin/vibeswitcher")])
        #expect(inside.about?.kind == .other && inside.about?.what.contains(Self.commit + "/bin/vibeswitcher changed") == true, "\(String(describing: inside.about))")
        let other = "4f00a1b2" + String(repeating: "1", count: 32)
        let two = Self.item("~/.vibeswitcher/v2/builds", files: [Self.file(Self.commit + "/build-info", .added), Self.file(other + "/build-info", .added)])
        #expect(two.about?.kind == .other && two.about?.what == "~/.vibeswitcher/v2/builds: 2 builds added: 3e9df41a, 4f00a1b2", "\(String(describing: two.about))")
        let noInfo = Self.item("~/.vibeswitcher/v2/builds", files: [Self.file(Self.commit + "/bin/vibeswitcher", .added)])
        #expect(noInfo.about?.kind == .other, "an added file in a build folder with no new build-info")
        let replaced = Self.item("~/.local/share/claude/versions", files: [Self.file("2.1.332", .added), Self.file("2.1.331")])
        #expect(replaced.about?.kind == .other, "\(String(describing: replaced.about))")
        // Each is named on the default screen, beside whatever does look like an update.
        let lines = CardText.plainConfig(Self.card(root: "/home/someone", items: Self.claude + [dropIn, hooks, inside], project: nil))
        #expect(lines.filter { !$0.hasPrefix("holds") }.count == 4 && lines.contains("and 2 more that look like updates (--long lists them)"), "\(lines)")
    }

    /// Only who commits and a branch's tracking entry are harmless git keys; every other key may run a command and is
    /// named first, each whole, whatever stands beside it; more than six are counted (the review of 2026-11-25).
    @Test func everyGitKeyThatMayRunACommandIsNamed() {
        let what = { (change: String) in Self.git(change).about?.what ?? "" }
        let whatKeys = { (keys: [ConfigSeal.KeyChange]) in Self.git(keys).about?.what ?? "" }
        // The vault lists a git config's every key (`changedKeys` unbounded for it): a risky one after twenty harmless.
        let before = "[core]\n\tbare = false\n"
        let after = "[core]\n\tbare = false\n\thooksPath = ~/hooks\n" + (0..<20).map { "[branch \"b\($0)\"]\n\tmerge = refs/heads/b\($0)\n" }.joined()
        let changes = ConfigSeal.keyChanges(from: ConfigSeal.encode(ConfigSeal.gitKeys(before) ?? [:]), to: ConfigSeal.encode(ConfigSeal.gitKeys(after) ?? [:])) ?? []
        let change = ConfigSeal.changedKeys(from: ConfigSeal.encode(ConfigSeal.gitKeys(before) ?? [:]), to: ConfigSeal.encode(ConfigSeal.gitKeys(after) ?? [:]),
                                            shown: .max) ?? ""
        #expect(!change.contains(" more") && change.hasSuffix("core.hookspath added"), "\(change)")
        #expect(whatKeys(changes) == ".git/config (main checkout): core.hookspath added, and 20 others", "\(whatKeys(changes))")
        #expect(what("diff.x.textconv changed, user.name changed") == ".git/config (main checkout): diff.x.textconv changed, and 1 other")
        #expect(what("user.email changed, user.name changed") == ".git/config (main checkout): user.email changed, user.name changed")
        let eight = (0..<8).map { "alias.a\($0) added" }.joined(separator: ", ") + ", user.name changed"
        #expect(what(eight) == ".git/config (main checkout): 8 git settings that can run commands changed (--long lists them), and 1 other", "\(what(eight))")
        // A long key is never cut by its neighbours.
        let long = (0..<6).map { "remote.origin.uploadpack\(String(repeating: "x", count: 30))\($0) changed" }.joined(separator: ", ")
        #expect(what(long).components(separatedBy: ", ").count == 6 && what(long).hasSuffix("5 changed"), "\(what(long))")
    }

    /// A subsection's text reaches a key's name only for a plain branch name: a URL (a token in it) is a stable label,
    /// on the card's words and its wire value alike; a branch whose name holds a comma or a space gives no keys at all.
    @Test func aSubsectionsURLIsALabelAndAnOddBranchNameGivesNoKeys() throws {
        let before = "[core]\n\tbare = false\n"
        let after = before + "[url \"https://user:sekrit-token@git.example.com/\"]\n\tinsteadOf = gh:\n[branch \"v2-usage\"]\n\tremote = origin\n"
        let keys = try #require(ConfigSeal.gitKeys(after))
        let label = ConfigSeal.subsectionLabel("https://user:sekrit-token@git.example.com/")
        #expect(label.count == 10 && label.hasPrefix("<") && label.hasSuffix(">"), "\(label)")
        #expect(keys.keys.sorted() == ["branch.v2-usage.remote", "core.bare", "url.\(label).insteadof"], "\(keys.keys.sorted())")
        #expect(!keys.keys.contains { $0.contains("sekrit") || $0.contains("://") || $0.contains("@") })
        // The same entry changed again compares under its label.
        let moved = after.replacingOccurrences(of: "insteadOf = gh:", with: "insteadOf = hub:")
        #expect(ConfigSeal.changedKeys(from: ConfigSeal.encode(keys), to: ConfigSeal.encode(ConfigSeal.gitKeys(moved) ?? [:])) == "url.\(label).insteadof changed")
        let changes = try #require(ConfigSeal.keyChanges(from: ConfigSeal.encode(ConfigSeal.gitKeys(before) ?? [:]), to: ConfigSeal.encode(keys)))
        let card = Self.card(root: "/r", items: [Self.git(changes)], project: "r")
        let text = CardText.lines(card).joined(separator: "\n") + CardText.lines(card, long: true).joined(separator: "\n")
        let wire = String(decoding: NodeWire.line(card), as: UTF8.self)
        #expect(text.contains("url.\(label).insteadof added") && !text.contains("sekrit") && !wire.contains("sekrit"), "\(text)")
        // A branch's own name still shows.
        #expect(Self.git(changes.filter { $0.key.hasPrefix("branch.") }).about?.what.contains("branch v2-usage") == true)
        for odd in ["x, core.hookspath", "two words", "a\u{7}b", "me@host"] {
            #expect(ConfigSeal.gitKeys("[branch \"\(odd)\"]\n\tremote = origin\n") == nil, "\(odd)")
        }
        // No keys: the card says the file changed, nothing more.
        #expect(Self.item(".git/config (main checkout)", change: "branch.x, core.hookspath.remote added").about?.what == ".git/config (main checkout) changed")
    }

    /// The one command that settles a held-config card from a terminal, as the node gives it to the page: the card's
    /// own accept; none once it is closed.
    @Test func aCardCarriesTheCommandThatSettlesIt() {
        var card = CardStore.Card(root: "/r", kind: .configHeld)
        card.config = ConfigHoldStore.Shown(items: [Self.item("~/.zshrc")])
        #expect(card.value["config"]?["settle"]?.string == "vibeswitcher config accept \(card.id)")
        card.closed = "accepted"
        #expect(card.value["config"]?["settle"] == nil)
    }
}
