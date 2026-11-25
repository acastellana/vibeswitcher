import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The plain held-config card (2026-11-25, the user after `vibeswitcher approve`: "I don't understand why all this
/// notice has so much text … I just accepted them but I have no idea what I did"): per card what changed in the node's
/// own words (`HeldWhat`), whom it holds, only the rules that changed, one line for those that can't be compared; every
/// path, hash and the snapshot's words behind `--long`. Today's real cases, as the node's cards held them.
@Suite
struct HeldWhatTests {
    static let commit = "3e9df41a" + String(repeating: "0", count: 32)
    static let facts = HeldWhat.Facts(claudeVersion: "2.1.332", pluginVersions: ["genlayernode@genlayerlabs": "0.4.1"], unitBuild: commit,
                                      unknownStartup: ["VibeSwitcher node.lnk"])
    static let startup = "/mnt/c/Users/kstel/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup"
    static let when = "2026-11-25T14:49:07Z"

    static func file(_ path: String, _ change: ConfigSeal.HeldFile.Change = .changed) -> ConfigSeal.HeldFile {
        ConfigSeal.HeldFile(path: path, change: change, at: 1_795_600_000, kind: "f", before: nil, after: nil)
    }

    static func item(_ name: String, change: String? = nil, files: [ConfigSeal.HeldFile] = []) -> ConfigHoldStore.Item {
        var item = ConfigHoldStore.Item(name: name, hash: "abcdef012345", change: change, outside: true, files: files,
                                        sinceAccept: "changed since your last accept (\(when))")
        item.about = HeldWhat.describe(item, facts: facts)
        return item
    }

    /// After a restart: every rule's snapshot unsealed, so none can be compared.
    static func unknownRails(_ count: Int) -> [ConfigHoldStore.Rail] {
        (0..<count).map { index in
            var rail = ConfigHoldStore.Rail(key: LeadVault.guardedKeys[index % LeadVault.guardedKeys.count] + "\(index)", value: "\(index)",
                                            sinceAccept: AcceptedSnapshot.unvouched(when))
            rail.changed = .unknown
            rail.records = false
            return rail
        }
    }

    static func card(root: String, items: [ConfigHoldStore.Item], rails: [ConfigHoldStore.Rail], every: Bool, project: String? = nil) -> NodeWire.Value {
        var card = CardStore.Card(root: root, kind: .configHeld)
        var shown = ConfigHoldStore.Shown(items: items, guarded: rails, lastAccept: Date(timeIntervalSince1970: 1_795_600_000))
        shown.summary = HeldWhat.summary(items: items)
        shown.holdsEvery = every
        shown.holds = project
        card.config = shown
        return card.value
    }

    @Test func eachKindTheNodeSeesIsSaidPlainly() {
        let say = { (item: ConfigHoldStore.Item) in item.about.map { "\($0.kind.rawValue): \($0.what)" } ?? "" }
        #expect(say(Self.item("~/.local/share/claude/versions", files: [Self.file("2.1.332", .added)])) == "claude-update: Claude Code's update to 2.1.332, it looks like")
        #expect(say(Self.item("~/.local/bin", files: [Self.file("claude")])) == "claude-update: Claude Code's link moved to 2.1.332")
        #expect(say(Self.item("~/.local/bin", files: [Self.file("passage")])) == "other: ~/.local/bin: passage changed")
        #expect(say(Self.item("~/.claude/plugins: genlayernode@genlayerlabs", change: "version folder changed, hooks/hooks.json changed"))
                == "plugin-update: the plugin genlayernode from genlayerlabs updated to 0.4.1")
        #expect(say(Self.item("~/.config/systemd/user", files: [Self.file("vibeswitcher-node.service")])) == "build-switch: VibeSwitcher's unit: it starts build 3e9df41a now")
        #expect(say(Self.item("~/.vibeswitcher/v2/builds", files: [Self.file(Self.commit + "/bin/vibeswitcher", .added)]))
                == "build-switch: VibeSwitcher's builds folder: build 3e9df41a installed")
        #expect(say(Self.item(".git/config (main checkout)", change: "branch.v2-usage.merge added, branch.v2-usage.remote added"))
                == "git-config: .git/config: the tracking entry of branch v2-usage")
        #expect(say(Self.item(".git/config (main checkout)", change: "core.hookspath added")) == "git-config: .git/config: core.hookspath added")
        #expect(say(Self.item(".git/config (main checkout)")) == "git-config: .git/config changed")
        #expect(say(Self.item(Self.startup)) == "startup: the Windows Startup folder (kstel): VibeSwitcher node.lnk added")
        #expect(say(Self.item("~/.claude/settings.json", change: "model changed")) == "settings: ~/.claude/settings.json: model changed")
        #expect(say(Self.item("~/.zshrc")) == "other: ~/.zshrc")
        // From and to where known.
        #expect(Self.item("~/.claude/plugins: genlayernode@genlayerlabs", change: "version folder changed").about?.to == "0.4.1")
        #expect(Self.item("~/.local/share/claude/versions").about?.to == "2.1.332")
    }

    /// A git config's keys, so a branch's tracking entry is named (`ConfigSeal.gitKeys`; names, never values).
    @Test func aGitConfigsChangedKeysAreNamed() {
        let before = "[core]\n\trepositoryformatversion = 0\n[remote \"origin\"]\n\turl = git@example.com:x/y.git\n"
        let after = before + "[branch \"v2-usage\"]\n\tremote = origin\n\tmerge = refs/heads/v2-usage\n"
        let change = ConfigSeal.changedKeys(from: ConfigSeal.encode(ConfigSeal.gitKeys(before)), to: ConfigSeal.encode(ConfigSeal.gitKeys(after)))
        #expect(change == "branch.v2-usage.merge added, branch.v2-usage.remote added", "\(String(describing: change))")
        #expect(HeldWhat.tracking(change ?? "") == ["v2-usage"])
        #expect(!(change ?? "").contains("refs/heads"), "no value")
        let moved = before.replacingOccurrences(of: "x/y.git", with: "x/z.git")
        #expect(ConfigSeal.changedKeys(from: ConfigSeal.encode(ConfigSeal.gitKeys(before)), to: ConfigSeal.encode(ConfigSeal.gitKeys(moved)))
                == "remote.origin.url changed")
    }

    /// The home folder's card after Claude Code updated itself, a plugin updated, VibeSwitcher switched and installed
    /// its Startup shortcut, and the model changed (seven paths), with eleven rules after a restart: a few lines.
    @Test func theSevenPathCardIsAFewPlainLines() {
        let items = [Self.item("~/.local/share/claude/versions", files: [Self.file("2.1.332", .added)]),
                     Self.item("~/.local/bin", files: [Self.file("claude")]),
                     Self.item("~/.claude/plugins: genlayernode@genlayerlabs", change: "version folder changed"),
                     Self.item(Self.startup),
                     Self.item("~/.claude/settings.json", change: "model changed"),
                     Self.item("~/.config/systemd/user", files: [Self.file("vibeswitcher-node.service")]),
                     Self.item("~/.vibeswitcher/v2/builds", files: [Self.file(Self.commit + "/bin/vibeswitcher", .added)])]
        let card = Self.card(root: "/home/someone", items: items, rails: Self.unknownRails(11), every: true)
        let plain = CardText.plainConfig(card)
        #expect(plain == [
            "Claude Code's update to 2.1.332, it looks like; the plugin genlayernode from genlayerlabs updated to 0.4.1; "
                + "the Windows Startup folder (kstel): VibeSwitcher node.lnk added; ~/.claude/settings.json: model changed; and 2 more",
            "holds every project (no new worker, verifier or merge until accepted)",
            "11 rules can't be compared since the node restarted (--long shows them)",
        ], "\(plain)")
        let text = CardText.lines(card).joined(separator: "\n")
        #expect(!text.contains("hash") && !text.contains("?") && !text.contains("sealed by this host's vault") && !text.contains("snapshot"), "\(text)")
        // `--long` is today's whole card: every path, hash and rule, each with its word.
        let long = CardText.lines(card, long: true)
        #expect(long.filter { $0.contains("hash abcdef012345") }.count == 7, "\(long)")
        #expect(long.filter { $0.contains(AcceptedSnapshot.unvouchedPrefix) }.count == 11, "\(long)")
        // The receipt.
        #expect(CardText.acceptedLine(card).hasPrefix("accepted: Claude Code's update to 2.1.332, it looks like;")
                && CardText.acceptedLine(card).hasSuffix("; it holds no project now"))
    }

    /// VibeSwitcher's own switch: its unit and its builds folder, holding the project.
    @Test func theSwitchsTwoAreVibeSwitchersOwn() {
        let items = [Self.item("~/.config/systemd/user", files: [Self.file("vibeswitcher-node.service")]),
                     Self.item("~/.vibeswitcher/v2/builds", files: [Self.file(Self.commit + "/bin/vibeswitcher", .added)])]
        let card = Self.card(root: "/home/someone/projects/vibeswitcher-v2-lead", items: items, rails: [], every: false, project: "vibeswitcher-v2-lead")
        #expect(CardText.plainConfig(card) == [
            "VibeSwitcher's unit: it starts build 3e9df41a now; VibeSwitcher's builds folder: build 3e9df41a installed",
            "holds vibeswitcher-v2-lead (no new worker, verifier or merge until accepted)",
        ], "\(CardText.plainConfig(card))")
        #expect(CardText.acceptedLine(card) == "accepted: VibeSwitcher's unit: it starts build 3e9df41a now; VibeSwitcher's builds folder: build 3e9df41a installed; "
                + "it holds vibeswitcher-v2-lead no more")
        #expect(CardText.acceptedLine(card, waits: true).hasSuffix("vibeswitcher-v2-lead still waits on your home folder's card"))
    }

    /// A rule that changed since the last accept is its name, old → new; one the accept records is said with its value;
    /// the same ones say nothing.
    @Test func aChangedRuleIsOldToNew() {
        var advance = ConfigHoldStore.Rail(key: "auto_advance", value: "true", sinceAccept: "changed since your last accept (\(Self.when)), from “false”")
        (advance.changed, advance.old, advance.records) = (.changed, "false", true)
        var same = ConfigHoldStore.Rail(key: "max_workers", value: "3", sinceAccept: "the same as at your last accept (\(Self.when))")
        (same.changed, same.records) = (.same, false)
        var fresh = ConfigHoldStore.Rail(key: "heavy_slots", value: "1")
        (fresh.changed, fresh.records) = (.changed, true)
        let card = Self.card(root: "/home/someone/projects/vibeswitcher", items: [Self.item(".git/config (main checkout)", change: "branch.v2.merge added")],
                             rails: [advance, same, fresh], every: false, project: "vibeswitcher")
        #expect(CardText.plainConfig(card) == [
            ".git/config: the tracking entry of branch v2",
            "holds vibeswitcher (no new worker, verifier or merge until accepted)",
            "auto_advance: false → true",
            "heavy_slots: (not set) → 1",
        ], "\(CardText.plainConfig(card))")
        // The same ones as before the review: what the vault and the card are bound to is unchanged.
        let value = card["config"]?["guarded"]?.array?.first
        #expect(value?["changed"]?.string == "changed" && value?["old"]?.string == "false" && value?["records"]?.bool == true)
        #expect(WireSchema.check(card, as: "card") == nil, "\(WireSchema.check(card, as: "card") ?? "")")
        let item = card["config"]?["items"]?.array?.first
        #expect(item?["kind"]?.string == "git-config" && item?["what"]?.string == ".git/config: the tracking entry of branch v2")
    }

    /// After a restart on a fresh vault: what the snapshot lists as it is now is counted, not listed; the rules the
    /// accept records (the vault holds none) are counted too, `--long` showing each.
    @Test func whatCantBeComparedIsCountedInALine() {
        var same = ConfigHoldStore.Item(name: "~/.zshrc", hash: "abcdef012345", sinceAccept: AcceptedSnapshot.unvouched(Self.when))
        same.about = HeldWhat.describe(same, facts: Self.facts)
        let changed = Self.item("~/.claude/settings.json", change: "env changed")
        var rails = Self.unknownRails(3)
        for index in rails.indices { rails[index].records = nil }
        var card = CardStore.Card(root: "/home/someone/projects/repo", kind: .configHeld)
        var shown = ConfigHoldStore.Shown(items: [same, changed, same], guarded: rails, lastAccept: Date(timeIntervalSince1970: 1_795_600_000))
        shown.summary = HeldWhat.summary(items: shown.items)
        (shown.holds, shown.holdsEvery, shown.recordsAll) = ("repo", false, true)
        card.config = shown
        #expect(CardText.plainConfig(card.value) == [
            "~/.claude/settings.json: env changed",
            "and 2 held things that can't be compared since the node restarted (--long lists them)",
            "holds repo (no new worker, verifier or merge until accepted)",
            "this accept records workflow.md's 3 rules as they are (--long shows them)",
        ], "\(CardText.plainConfig(card.value))")
    }
}
