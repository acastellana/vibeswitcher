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

    /// `item` described.
    public static func describe(_ item: ConfigHoldStore.Item, facts: Facts) -> Described {
        let name = item.name
        let files = paths(item)
        let change = item.change.map(inert)
        switch name {
        case versions:
            let added = files.filter { isVersion(($0 as NSString).lastPathComponent) }.map { ($0 as NSString).lastPathComponent }
            let to = facts.claudeVersion ?? added.max(by: { $0.compare($1, options: .numeric) == .orderedAscending })
            return Described(kind: .claudeUpdate, what: to.map { "Claude Code's update to \(inert($0)), it looks like" } ?? "a new file in Claude Code's versions folder",
                             to: to.map(inert))
        case bin:
            // Only the claude link moved, to a version in its own folder: Claude Code's.
            if let version = facts.claudeVersion, files.allSatisfy({ $0 == "claude" }) {
                return Described(kind: .claudeUpdate, what: "Claude Code's link moved to \(inert(version))", to: inert(version))
            }
            let entries = files.isEmpty ? "an entry" : listed(files)
            return Described(kind: .other, what: "~/.local/bin: \(entries) changed")
        case builds:
            let commits = files.map { String($0.split(separator: "/").first ?? "") }.filter(NodeUnit.isCommit)
            let to = commits.first.map { String($0.prefix(8)) }
            return Described(kind: .buildSwitch, what: "VibeSwitcher's builds folder: " + (to.map { "build \($0) installed" } ?? "a build installed or removed"),
                             to: to)
        case units:
            guard files.allSatisfy({ $0.hasPrefix(unitFile) }) else {
                return Described(kind: .other, what: "~/.config/systemd/user: \(listed(files)) changed")
            }
            let to = facts.unitBuild.map { String($0.prefix(8)) }
            return Described(kind: .buildSwitch, what: "VibeSwitcher's unit: " + (to.map { "it starts build \($0) now" } ?? "it changed"), to: to)
        case StartupShortcuts.listFile.withHome:
            return Described(kind: .startup, what: "your list of known Windows Startup shortcuts")
        default: break
        }
        if name.hasPrefix(pluginPrefix) || (name.hasPrefix(checkoutPluginPrefix) && name.hasSuffix(" (main checkout)")) {
            var id = name.hasPrefix(pluginPrefix) ? String(name.dropFirst(pluginPrefix.count)) : String(name.dropFirst(checkoutPluginPrefix.count))
            if let checkout = id.range(of: " (main checkout)") { id = String(id[..<checkout.lowerBound]) }
            let parts = id.split(separator: "@", maxSplits: 1).map(String.init)
            let plugin = inert(parts.first ?? id), marketplace = parts.count > 1 ? inert(parts[1]) : nil
            let updated = item.change?.contains("version folder") == true || item.change?.contains("install folder") == true
            let to = facts.pluginVersions[id].map(inert)
            let from = marketplace.map { " from \($0)" } ?? ""
            return Described(kind: .pluginUpdate, what: "the plugin \(plugin)\(from) " + (updated ? "updated" + (to.map { " to \($0)" } ?? "") : "changed"),
                             to: updated ? to : nil)
        }
        if name.hasPrefix(".git/config") || name == "~/.gitconfig" || name == "~/.config/git/config" {
            let file = name.hasPrefix(".git/config") ? ".git/config" : name
            guard let keys = item.change else { return Described(kind: .gitConfig, what: "\(inert(file)) changed") }
            let branches = tracking(keys)
            if !branches.isEmpty {
                let named = branches.map(inert).joined(separator: ", ")
                return Described(kind: .gitConfig, what: "\(inert(file)): the tracking entry of branch \(named)")
            }
            return Described(kind: .gitConfig, what: "\(inert(file)): \(change ?? "changed")")
        }
        if name.contains("/Start Menu/Programs/Startup") {
            let user = name.split(separator: "/").dropFirst(3).first.map(String.init)
            let names = facts.unknownStartup
            let whose = user.map { " (\(inert($0)))" } ?? ""
            return Described(kind: .startup, what: names.isEmpty ? "the Windows Startup folder\(whose) changed"
                                                  : "the Windows Startup folder\(whose): \(listed(names)) added")
        }
        if name.contains("settings.json") || name.contains("settings.local.json") {
            return Described(kind: .settings, what: inert(name) + (change.map { ": \($0)" } ?? " changed"))
        }
        return Described(kind: .other, what: inert(name) + (change.map { ": \($0)" } ?? ""))
    }

    /// The branches whose tracking entry (`branch.<name>.remote`, `.merge`, `.rebase`, `.pushRemote`) is all that
    /// changed, from `ConfigSeal.changedKeys`' words ("branch.v2.merge added, branch.v2.remote added"); empty when
    /// anything else changed, or more were cut.
    static func tracking(_ change: String) -> [String] {
        guard !change.contains(" and ") || !change.hasSuffix(" more") else { return [] }
        var branches: [String] = []
        for part in change.components(separatedBy: ", ") {
            let words = part.split(separator: " ")
            guard words.count == 2, ["added", "changed", "removed"].contains(words[1]) else { return [] }
            let key = String(words[0])
            guard key.hasPrefix("branch."), let dot = key.lastIndex(of: "."), key.index(after: key.startIndex) < dot else { return [] }
            let field = key[key.index(after: dot)...].lowercased()
            guard ["remote", "merge", "rebase", "pushremote"].contains(field) else { return [] }
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

    /// Whether a held item is known to have changed since the last accept (or no accept is known): not one the snapshot
    /// lists as it is now, sealed or not (`AcceptedSnapshot.since`).
    public static func changedSinceAccept(_ sinceAccept: String?) -> Bool {
        guard let since = sinceAccept else { return true }
        return !since.hasPrefix(AcceptedSnapshot.unvouchedPrefix) && !since.hasPrefix("the same as at your last accept")
    }

    /// The card's line of what changed: its items that changed since the last accept, described; nil when none did.
    public static func summary(items: [ConfigHoldStore.Item]) -> String? {
        let changed = items.filter { changedSinceAccept($0.sinceAccept) }.compactMap(\.about)
        return changed.isEmpty ? nil : summary(changed)
    }

    /// The card's own line (what changed, the items' `what`s): Claude Code's two halves of one update said once.
    public static func summary(_ described: [Described]) -> String {
        var said: [String] = []
        var claude = false
        for item in described {
            if item.kind == .claudeUpdate {
                guard !claude else { continue }
                claude = true
                said.append(item.to.map { "Claude Code's update to \($0), it looks like" } ?? item.what)
                continue
            }
            if !said.contains(item.what) { said.append(item.what) }
        }
        guard !said.isEmpty else { return "nothing held" }
        return said.prefix(4).joined(separator: "; ") + (said.count > 4 ? "; and \(said.count - 4) more" : "")
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
