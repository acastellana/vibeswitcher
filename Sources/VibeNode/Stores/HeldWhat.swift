import Foundation
import VibeCore

/// What a held thing is, in plain words (2026-11-25, the user after `vibeswitcher approve`: "I just accepted them but I
/// have no idea what I did"). Each held item of a config card gets a `kind`, a short `what`, and where known `from` and
/// `to`, from the node's own reading of the names it holds and the disk now: Claude Code's own update, a plugin's
/// update, VibeSwitcher's own switch or install, a checkout's `.git/config`, the Windows Startup folder, a settings
/// file's key; anything else is its name. A description, never a judgement: what is held, sealed and asked is the same.
/// Every word taken from the disk (a version, a commit, a file's name) goes through `ConfigSeal.inert`.
public enum HeldWhat {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case claudeUpdate = "claude-update"
        case pluginUpdate = "plugin-update"
        case buildSwitch = "build-switch"
        case gitConfig = "git-config"
        case startup
        case settings
        case other
    }

    public struct Described: Codable, Equatable, Sendable {
        public var kind: Kind
        public var what: String
        public var from: String?
        public var to: String?

        public init(kind: Kind, what: String, from: String? = nil, to: String? = nil) {
            self.kind = kind
            self.what = what
            self.from = from
            self.to = to
        }
    }

    /// What the disk says now, read once per card (`facts(home:)`); a test gives its own.
    public struct Facts: Sendable {
        /// The version Claude Code's `~/.local/bin/claude` link names in its versions folder.
        public var claudeVersion: String?
        /// A plugin's installed version, by "<plugin>@<marketplace>".
        public var pluginVersions: [String: String]
        /// The build VibeSwitcher's unit starts (`ExecStart`'s builds folder).
        public var unitBuild: String?
        /// The Windows Startup shortcuts not on the known list, by name.
        public var unknownStartup: [String]

        public init(claudeVersion: String? = nil, pluginVersions: [String: String] = [:], unitBuild: String? = nil, unknownStartup: [String] = []) {
            self.claudeVersion = claudeVersion
            self.pluginVersions = pluginVersions
            self.unitBuild = unitBuild
            self.unknownStartup = unknownStartup
        }
    }

    static var versions: String { "~/.local/share/claude/versions" }
    static var bin: String { "~/.local/bin" }
    static var pluginPrefix: String { "~/.claude/plugins: " }
    static let checkoutPluginPrefix = "plugin "
    static var builds: String { "~/.vibeswitcher/v2/builds" }
    static var units: String { "~/.config/systemd/user" }
    static let unitFile = "vibeswitcher-node.service"

    static func inert(_ text: String) -> String { ConfigSeal.inert(text, limit: 120) }

    static func isVersion(_ name: String) -> Bool { name.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil }

    /// The paths a held item's files name (`ConfigSeal.HeldFile.path`), changed, added or removed.
    static func paths(_ item: ConfigHoldStore.Item) -> [String] { item.files.map(\.path) }

    /// `item` described: always its path, in neutral words. What the disk says now (a link's target, a plugin's record,
    /// the unit's build) is any process's to write, so a likeness to an update is said as one ("looks like …"), never as
    /// a fact, and nothing here is ever why a thing is left out, folded unread or accepted (the review of 2026-11-25).
    public static func describe(_ item: ConfigHoldStore.Item, facts: Facts) -> Described {
        let name = item.name
        let files = paths(item)
        let change = item.change.map(inert)
        switch name {
        case versions:
            // Only new files, each named as a version: anything changed or removed beside them isn't an update.
            let added = item.files.filter { $0.change == .added }.map { ($0.path as NSString).lastPathComponent }
            guard !added.isEmpty, added.count == item.files.count, added.allSatisfy(isVersion) else {
                return Described(kind: .other, what: versions + (files.isEmpty ? " changed" : ": \(listed(files)) changed"))
            }
            let to = added.max { $0.compare($1, options: .numeric) == .orderedAscending }.map(inert)
            return Described(kind: .claudeUpdate, what: "\(versions): \(listed(added)) added (looks like Claude Code's own update)", to: to)
        case bin:
            // Only the claude link, now naming a version in Claude Code's own folder: looks like its update.
            if let version = facts.claudeVersion, !files.isEmpty, files.allSatisfy({ $0 == "claude" }) {
                return Described(kind: .claudeUpdate, what: "~/.local/bin/claude now points to \(inert(version)) (looks like Claude Code's own update)",
                                 to: inert(version))
            }
            return Described(kind: .other, what: bin + (files.isEmpty ? " changed" : ": \(listed(files)) changed"))
        case builds:
            // An install only when every file is new and under a commit's folder, each such folder with its own new
            // build-info (a new build's): anything changed, removed or beside them is named as it is.
            let commits = Set(files.map { String($0.split(separator: "/").first ?? "") })
            let installs = !files.isEmpty && item.files.allSatisfy { $0.change == .added } && commits.allSatisfy(NodeUnit.isCommit)
                && files.allSatisfy { $0.contains("/") } && commits.allSatisfy { files.contains($0 + "/" + BuildInfo.fileName) }
            // More than one new build at once isn't one install: each named, never folded.
            if installs, commits.count > 1 {
                return Described(kind: .other, what: "\(builds): \(commits.count) builds added: " + commits.sorted().map { inert(String($0.prefix(8))) }.joined(separator: ", "))
            }
            guard installs, commits.count == 1, let first = commits.first else {
                return Described(kind: .other, what: builds + (files.isEmpty ? " changed" : ": \(listed(files)) changed"))
            }
            let short = String(first.prefix(8))
            return Described(kind: .buildSwitch, what: "\(builds): build \(short) added (looks like VibeSwitcher's own install)", to: short)
        case units:
            // The unit file itself and nothing else: a drop-in (`.d/`) or any other file is named as it is.
            guard files == [unitFile], let build = facts.unitBuild else {
                return Described(kind: .other, what: units + (files.isEmpty ? " changed" : ": \(listed(files)) changed"))
            }
            let short = String(build.prefix(8))
            return Described(kind: .buildSwitch, what: "\(units)/\(unitFile) now starts build \(short) (looks like VibeSwitcher's own switch)", to: short)
        case StartupShortcuts.listFile.withHome:
            return Described(kind: .startup, what: "~/\(StartupShortcuts.listFile) (your list of known Windows Startup shortcuts) changed")
        default: break
        }
        if name.hasPrefix(pluginPrefix) || (name.hasPrefix(checkoutPluginPrefix) && name.hasSuffix(" (main checkout)")) {
            var id = name.hasPrefix(pluginPrefix) ? String(name.dropFirst(pluginPrefix.count)) : String(name.dropFirst(checkoutPluginPrefix.count))
            if let checkout = id.range(of: " (main checkout)") { id = String(id[..<checkout.lowerBound]) }
            // Moved to a new version folder and nothing else said: looks like the plugin's update; anything else, said.
            let updated = item.change == "version folder changed"
            let to = facts.pluginVersions[id].map(inert)
            guard updated else { return Described(kind: .other, what: inert(name) + (change.map { ": \($0)" } ?? " changed")) }
            return Described(kind: .pluginUpdate, what: inert(name) + (to.map { ": now version \($0)" } ?? ": a new version folder") + " (looks like the plugin's own update)",
                             to: to)
        }
        if name.hasPrefix(".git/config") || name == "~/.gitconfig" || name == "~/.config/git/config" {
            // Its keys only when the node read the whole file (`ConfigSeal.gitKeys`); a branch's tracking entry the
            // plain phrase only when that is every key that changed; any other key named, the riskiest first.
            guard let keys = item.change else { return Described(kind: .gitConfig, what: "\(inert(name)) changed") }
            let branches = tracking(keys)
            if !branches.isEmpty {
                return Described(kind: .gitConfig, what: "\(inert(name)): the tracking entry of branch \(branches.map(inert).joined(separator: ", ")) (\(change ?? ""))")
            }
            return Described(kind: .gitConfig, what: "\(inert(name)): \(inert(riskiestFirst(keys)))")
        }
        if name.contains("/Start Menu/Programs/Startup") {
            let names = facts.unknownStartup
            return Described(kind: .startup, what: inert(name) + (names.isEmpty ? " changed" : ": \(listed(names)) not on your list of known shortcuts"))
        }
        if name.contains("settings.json") || name.contains("settings.local.json") {
            return Described(kind: .settings, what: inert(name) + (change.map { ": \($0)" } ?? " changed"))
        }
        return Described(kind: .other, what: inert(name) + (change.map { ": \($0)" } ?? " changed"))
    }

    /// Whether `kind` is one of what the node recognises as an update (Claude Code's, a plugin's, VibeSwitcher's own):
    /// only those may be counted instead of named on a default screen; everything else is always named.
    public static func looksLikeUpdate(_ kind: Kind) -> Bool { [.claudeUpdate, .pluginUpdate, .buildSwitch].contains(kind) }

    /// A branch's tracking entry's keys: what `git push -u`, `git branch --set-upstream-to` and an editor's merge base
    /// write, nothing that runs.
    static let trackingFields: Set<String> = ["remote", "merge", "rebase", "pushremote", "vscode-merge-base"]

    /// The key prefixes that run something or pull in other config: named first.
    static let riskyKeys = ["include.", "includeif.", "core.", "alias.", "url.", "filter.", "credential."]

    /// `ConfigSeal.changedKeys`' words reordered: the risky keys first, the rest as they came, any "and N more" last.
    static func riskiestFirst(_ change: String) -> String {
        var parts = change.components(separatedBy: ", ")
        var tail = ""
        if let last = parts.last, let and = last.range(of: " and ", options: .backwards), last.hasSuffix(" more") {
            tail = String(last[and.lowerBound...])
            parts[parts.count - 1] = String(last[..<and.lowerBound])
        }
        let risky = parts.filter { part in riskyKeys.contains { part.lowercased().hasPrefix($0) } }
        return (risky + parts.filter { !risky.contains($0) }).joined(separator: ", ") + tail
    }

    /// The branches whose tracking entry (`trackingFields`) is all that changed, from `ConfigSeal.changedKeys`' words
    /// ("branch.v2.merge added, branch.v2.remote added"); empty when anything else changed, or more were cut.
    static func tracking(_ change: String) -> [String] {
        guard !change.contains(" and ") || !change.hasSuffix(" more") else { return [] }
        var branches: [String] = []
        for part in change.components(separatedBy: ", ") {
            let words = part.split(separator: " ")
            guard words.count == 2, ["added", "changed", "removed"].contains(words[1]) else { return [] }
            let key = String(words[0])
            guard key.hasPrefix("branch."), let dot = key.lastIndex(of: "."), key.index(after: key.startIndex) < dot else { return [] }
            let field = key[key.index(after: dot)...].lowercased()
            guard trackingFields.contains(field) else { return [] }
            let branch = String(key[key.index(key.startIndex, offsetBy: "branch.".count)..<dot])
            if !branches.contains(branch) { branches.append(branch) }
        }
        return branches
    }

    static func listed(_ names: [String]) -> String {
        guard !names.isEmpty else { return "something" }
        let shown = names.prefix(3).map(inert).joined(separator: ", ")
        return shown + (names.count > 3 ? " and \(names.count - 3) more" : "")
    }

    /// What a card names by default, in order: everything that isn't a recognised update (settings, git config, shell
    /// files, anything unknown), each named, never capped; then the updates, named while fewer than `named` lines are
    /// said, the rest counted (`folded`). Each named with what it is against the last accept when it can't be compared.
    public static func shown(_ items: [ConfigHoldStore.Item], named: Int = 3) -> (lines: [String], folded: Int) {
        let described = items.map { item -> (what: String, update: Bool) in
            let about = item.about ?? Described(kind: .other, what: inert(item.name))
            let uncompared = (item.sinceAccept ?? "").hasPrefix(AcceptedSnapshot.unvouchedPrefix)
            return (about.what + (uncompared ? " (can't be compared with your last accept)" : ""), looksLikeUpdate(about.kind))
        }
        return self.named(described, room: named)
    }

    /// The rule both a card's lines and the page follow: every entry that isn't an update named, in order; then the
    /// updates while fewer than `room` lines are said; the rest counted.
    public static func named(_ entries: [(what: String, update: Bool)], room: Int = 3) -> (lines: [String], folded: Int) {
        var lines = entries.filter { !$0.update }.map(\.what)
        let updates = entries.filter(\.update).map(\.what)
        let left = max(0, room - lines.count)
        lines += updates.prefix(left)
        return (lines, max(0, updates.count - left))
    }

    /// The card's line for a receipt or a title: the first thing named, and how many more.
    public static func summary(items: [ConfigHoldStore.Item]) -> String? {
        let said = shown(items, named: 1)
        guard let first = said.lines.first else { return nil }
        let more = items.count - 1
        return first + (more > 0 ? "; and \(more) more" : "")
    }

    /// The disk read for `home`: Claude Code's link, the plugins' record, VibeSwitcher's unit, the Startup folders.
    public static func facts(home: String) -> Facts {
        var facts = Facts()
        let link = (home as NSString).appendingPathComponent(".local/bin/claude")
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) {
            let resolved = target.hasPrefix("/") ? target : ((link as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
            let standard = (resolved as NSString).standardizingPath
            let folder = (home as NSString).appendingPathComponent(".local/share/claude/versions")
            let version = (standard as NSString).lastPathComponent
            if (standard as NSString).deletingLastPathComponent == folder, isVersion(version) { facts.claudeVersion = version }
        }
        let record = (home as NSString).appendingPathComponent(".claude/plugins/installed_plugins.json")
        if let data = small(record, limit: 4 << 20),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let plugins = object["plugins"] as? [String: Any] {
            for (id, installs) in plugins {
                if let version = ((installs as? [[String: Any]])?.first?["version"] as? String) { facts.pluginVersions[id] = version }
            }
        }
        let unit = (home as NSString).appendingPathComponent(".config/systemd/user/" + unitFile)
        if let data = small(unit, limit: 64 << 10) {
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n") where line.hasPrefix("ExecStart=") {
                for part in line.split(separator: "/") where NodeUnit.isCommit(String(part)) { facts.unitBuild = String(part) }
            }
        }
        facts.unknownStartup = StartupShortcuts.report().compactMap { line in
            guard line.hasPrefix("unknown: ") else { return nil }
            let fields = line.dropFirst("unknown: ".count).components(separatedBy: " | ")
            return fields.count > 1 ? fields[1] : nil
        }
        return facts
    }
}

extension HeldWhat {
    /// A regular file's bytes, at most `limit` (a description only: anything else reads as nothing).
    static func small(_ path: String, limit: Int) -> Data? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: limit)
    }
}

private extension String {
    /// A home-relative path as the seal names it ("~/…").
    var withHome: String { "~/" + self }
}
