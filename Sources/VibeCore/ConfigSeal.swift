import CryptoKit
import Foundation

/// What the agents load from outside a worktree, which a branch's code can write: Claude Code's own settings, hooks,
/// instructions, skills and MCP servers in your home, your shell's startup files, your git config, and the main
/// checkout's git config and hooks. The roles' deny rules (`LeadLaunch.claudeHome`) hold only their file tools: a
/// worker's shell, a verifier's command or a branch's tests (merge's, an audit's) runs as you and can write any of
/// them, and the next session would load what it wrote, the lead's included (audit of 2026-11-07).
///
/// No sandbox holds them: macOS refuses a sandbox inside a sandbox, and SwiftPM, many test suites and `ps` start one
/// of their own, so branch code under `sandbox-exec` would stop building. So the vault keeps a hash of each, as
/// VibeSwitcher last sealed it, with workflow.md's guard rails (`LeadVault.guardedKeys`, keys `keyPrefix`…), where no
/// session's shell reaches. Before a worker or verifier starts, and after a merge's tests, each is hashed again
/// (`LeadVault.checkConfig`). Your home's files are the Mac's, not a team's: one seal for them all, with its own time;
/// the main checkout's are sealed per team. A change made while its seal was quiet (no worker's or verifier's session
/// nor branch run of any team still in use since that seal) is yours, and sealed as it is when it only instructs; one
/// made while they ran, or code that runs whenever it changed, holds new workers, verifiers and merges, named to the
/// lead, until you accept it in the app (the app's only).
/// The lead's own start is never held. A detector, not a lock: what a shell wrote is on disk, but no worker or
/// verifier VibeSwitcher starts loads it unseen. Running sessions keep the hooks they started with (Claude Code
/// snapshots them).
///
/// Plugins and scripts: each enabled plugin (settings' `enabledPlugins`, at its version folder as
/// `~/.claude/plugins/installed_plugins.json` records it) is watched for what of it runs: its manifest, hooks, MCP and
/// LSP servers and the files their commands name, never the rest of a big cache. Each watched settings file's scripts
/// (what its hooks', status line's and helpers' commands name by path) are watched by contents. Both are sealed by a
/// quiet look (`sealsWhenQuiet`): only a change made while the team ran holds. A plugin whose version folder moved
/// (`isUpdate`: Claude Code's update, or a shell's forged one, alike on disk) always waits for your Accept, as does one
/// that comes back changed after a look didn't see it (`gonePrefix`), or is first seen after the seal's first look
/// that watched plugins (`comesAndGoesSince`: one enabled now, its cache written while nothing watched it). Not watched: what a command computes (`$(…)`, a
/// glob) or loads itself (a script's own `source`, an interpreter's modules), and plugins' skills and commands.
public enum ConfigSeal {
    /// One thing watched: its name as the lead and you are told it, where it is, and how it's read.
    public struct Watched: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// A file: its contents (a link followed, and where it points).
            case file
            /// A folder: every name under it, each file's contents and each link's target; links never followed. In
            /// `~/.claude/skills`, not Claude Code's sync bookkeeping (`isSyncBookkeeping`).
            case folder
            /// `~/.claude.json`: only its MCP servers, yours and each project's (the rest changes with every session).
            case mcpServers
            /// An enabled plugin's installs, each at its version folder (none when Claude Code's record has none, nil
            /// when the record can't be read): only what runs (`pluginParts`), never its skills, commands, agents or
            /// docs. `home` stands for `~` and `$HOME`. `path` is its first install's folder ("" with none).
            case plugin(home: String, installs: [PluginInstall]?)
            /// The scripts the settings file at `path` names by path (its hooks', status line's and helpers'
            /// commands), each by contents (`settingsScripts`); `project` stands for `$CLAUDE_PROJECT_DIR`, and what's
            /// at or under `skip` is watched already.
            case scripts(home: String, project: String?, skip: [String])
        }

        public var name: String
        public var path: String
        public var kind: Kind
        /// It carries code that runs (hooks, MCP servers, shell startup, git's commands, the hook binary, skills'
        /// scripts, commands' `!` lines): a change is never sealed silently, even made outside a team session. Not:
        /// instructions (CLAUDE.md, agents, output styles), which a quiet look seals as yours.
        public var executes = true
    }

    /// One install of a plugin as Claude Code records it: its version folder, and how its parts are labelled ("" for
    /// the only one; its scope and project when the plugin has several).
    public struct PluginInstall: Equatable, Sendable {
        public var path: String
        public var label: String
    }

    /// The watched things that only instruct (no code of theirs runs): sealed silently when changed while the team
    /// was quiet. Everything else executes. The gap this leaves: a process branch code left behind (a double fork,
    /// `nohup … sleep; write`) that writes one of these after the team went quiet is sealed as yours; one that writes
    /// code that runs is still held.
    static var instructions: Set<String> {
        // Not skills or commands: a skill bundles scripts, and a command's `!` lines run as it's invoked.
        ["~/.claude/CLAUDE.md", "~/.claude/agents", "~/.claude/output-styles", "~/.codex/AGENTS.md", "CLAUDE.local.md (main checkout)"]
    }

    /// Whether the thing `key` names executes (see `Watched.executes`).
    public static func executes(key: String) -> Bool { !instructions.contains(name(ofKey: key)) }

    /// Whether a change to the thing `key` names, made while its seal was quiet, is sealed as yours by the lead's
    /// look: instructions, and the code you change by hand without a card (an edit inside a plugin's version folder, a
    /// script settings name; never a plugin's update, `isUpdate`). Everything else that executes waits for your Accept
    /// whoever changed it. The gap is the same as `instructions`': a process branch code left behind that writes one
    /// after the team went quiet is sealed.
    public static func sealsWhenQuiet(key: String) -> Bool {
        let name = name(ofKey: key)
        return instructions.contains(name) || isPlugin(name: name) || isScripts(name: name)
    }

    /// The name of an enabled plugin as watched: "~/.claude/plugins: <plugin>@<marketplace>", your home's (the
    /// Mac-wide seal) when your settings enable it; "plugin <plugin>@<marketplace> (main checkout)", the team's, when
    /// only the main checkout's do (only that team's looks see it).
    static var pluginPrefix: String { "~/.claude/plugins: " }

    static let checkoutPluginPrefix = "plugin "

    static func isPlugin(name: String) -> Bool {
        name.hasPrefix(pluginPrefix) || (name.hasPrefix(checkoutPluginPrefix) && name.hasSuffix(" (main checkout)"))
    }

    /// The name of the scripts a settings file names: "<the settings' name>'s scripts".
    static let scriptsSuffix = "'s scripts"

    static func isScripts(name: String) -> Bool { name.hasSuffix(scriptsSuffix) }

    /// The per-key hash of a plugin's version folder (`keyHashes`): where it's installed, not what's in it.
    static let versionKey = "version folder"

    /// The same for a plugin whose record points outside Claude Code's cache: no update of Claude Code's, new code all the same.
    static let installKey = "install folder"

    /// Whether `key` (a watched one) is a plugin that came to new code: it's in a folder now (`versionKey`, `installKey`)
    /// and wasn't in that one between `recorded`'s per-key hashes and `now`'s: moved from another (Claude Code's update
    /// writes a new folder and moves its record there; a shell can do the same), or from no folder at all (a look that
    /// found it not installed, Claude Code's record unreadable, or the folder its record names gone, sealed nothing of
    /// what's there now). An edit inside the same folder isn't, nor an uninstall (no folder now). It always waits for
    /// your Accept, whoever made it.
    static func isUpdate(key: String, recorded: [String: String], now: [String: String]) -> Bool {
        guard isPlugin(name: name(ofKey: key)), let new = now[keysKey(of: key)] else { return false }
        let after = decode(new), before = recorded[keysKey(of: key)].map(decode) ?? [:]
        guard let to = after[versionKey] ?? after[installKey] else { return false }
        if to != before[versionKey] ?? before[installKey] { return true }
        return before.keys.contains { ($0 == "absent" || $0.hasSuffix(": absent")) && after[$0] == nil }
    }

    /// The prefix of a watched thing's key among the vault's guarded hashes.
    public static let keyPrefix = "config:"

    /// The key that marks a branch run begun (a merge's or an audit's tests) in the vault, never recorded.
    public static let runKey = keyPrefix + "#run"

    /// The key that marks a branch run ended (its value the id `runKey` gave), never recorded.
    public static let runEndKey = keyPrefix + "#runEnd"

    /// The key that asks the vault to look at the agents' config now (it hashes everything itself).
    public static let checkKey = keyPrefix + "#check"

    /// Where the vault keeps the names of what's held (one per line), for the app to show; set only by the vault.
    public static let heldKey = keyPrefix + "#held"

    /// What's held, by name, from the vault's guarded settings.
    public static func held(in guarded: [String: String]?) -> [String] {
        heldLines(in: guarded).keys.sorted().map(name(ofKey:))
    }

    /// What's held that changed outside a team session (none of its workers', verifiers' or branch runs since the
    /// last look): code that runs, which only your Accept seals whoever made it. By name.
    public static func heldOutside(in guarded: [String: String]?) -> [String] {
        heldLines(in: guarded).filter(\.value.outside).keys.sorted().map(name(ofKey:))
    }

    /// What changed in each held thing, by name: its keys (a JSON file's top-level keys, each hook event, each MCP
    /// server), as "hooks.SessionStart added, env changed", or a folder's relative paths, as "foo/SKILL.md changed";
    /// never a value or a file's contents. Only for what has keys or paths and was sealed with them.
    public static func heldChanges(in guarded: [String: String]?) -> [String: String] {
        var changes: [String: String] = [:]
        for (key, line) in heldLines(in: guarded) where !line.changes.isEmpty { changes[name(ofKey: key)] = line.changes }
        return changes
    }

    /// When a held folder's newest changed file was changed, by name (`changedFiles`). Not for a file: its own time
    /// says that.
    public static func heldTimes(in guarded: [String: String]?) -> [String: Date] {
        var times: [String: Date] = [:]
        for (key, line) in heldLines(in: guarded) { if let at = line.at { times[name(ofKey: key)] = Date(timeIntervalSince1970: at) } }
        return times
    }

    /// What's held, by key, with the hash it had when it was held (`heldKey`'s lines:
    /// "<key>\t<hash>\t<r|q>\t<keys>\t<at>", q: changed outside a team session; keys: `heldChanges`'; at: `heldTimes`', absent on
    /// a line an older version wrote).
    static func heldLines(in guarded: [String: String]?) -> [String: (hash: String, outside: Bool, changes: String, at: Double?)] {
        var held: [String: (hash: String, outside: Bool, changes: String, at: Double?)] = [:]
        for line in (guarded?[heldKey] ?? "").split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 2 { held[parts[0]] = (parts[1], parts.count > 2 && parts[2] == "q", parts.count > 3 ? parts[3] : "", parts.count > 4 ? Double(parts[4]) : nil) }
        }
        return held
    }

    static func heldHashes(in guarded: [String: String]?) -> [String: String] { heldLines(in: guarded).mapValues(\.hash) }

    /// `heldKey`'s value for these keys and hashes, `outside` the ones changed outside a team session, `changes` what
    /// changed in each (`changedKeys`, `changedFiles`), `times` when a folder's newest changed file was.
    static func heldValue(_ held: [String: String], outside: Set<String>, changes: [String: String] = [:], times: [String: Double] = [:]) -> String {
        held.keys.sorted().map { key in
            "\(key)\t\(held[key] ?? "")\t\(outside.contains(key) ? "q" : "r")\t\(clean(changes[key] ?? ""))\t\(times[key].map { String($0) } ?? "")"
        }.joined(separator: "\n")
    }

    /// `text` on one line with no tabs (a key name is anything JSON allows).
    static func clean(_ text: String) -> String {
        String(text.map { $0 == "\t" || $0 == "\n" || $0 == "\r" ? " " : $0 })
    }

    /// Whether the vault takes `key` as the agents' config's (`LeadVault.Book`), not one of workflow.md's guard rails.
    public static func isVaultKey(_ key: String) -> Bool { key.hasPrefix(keyPrefix) }

    /// Whether `key` is a watched thing's hash (not one of the marks, `heldKey`, or a thing's per-key hashes).
    public static func isWatchedKey(_ key: String) -> Bool { key.hasPrefix(keyPrefix) && !key.dropFirst(keyPrefix.count).hasPrefix("#") }

    /// Where the vault keeps a watched thing's per-key hashes (`keyHashes`), beside its hash: only the vault reads
    /// them (its `guarded` answer leaves them out), for the card's `heldChanges`.
    static let keysPrefix = keyPrefix + "#keys "

    /// Whether `key` (a watched thing's, or its per-key hashes') is in your home: the Mac's, sealed once for every team
    /// (`LeadVault.Book`); the rest is the main checkout's, sealed per team.
    public static func isHome(key: String) -> Bool {
        let rest = key.hasPrefix(keysPrefix) ? key.dropFirst(keysPrefix.count) : key.hasPrefix(gonePrefix) ? key.dropFirst(gonePrefix.count)
            : key.hasPrefix(keyPrefix) ? key.dropFirst(keyPrefix.count) : ""
        return rest.hasPrefix("~/")
    }

    /// The key of the per-key hashes of the thing `key` (a watched key) hashes.
    static func keysKey(of key: String) -> String { keysPrefix + name(ofKey: key) }

    /// Where the vault marks a thing a quiet look seals (`sealsWhenQuiet`) that a look didn't see (a plugin no
    /// settings enable now, the scripts of a settings file that doesn't read), until it's seen as sealed again: if it
    /// comes back changed, when it changed isn't known, so it waits for your Accept. Only the vault reads it.
    static let gonePrefix = keyPrefix + "#gone "

    static func goneKey(of key: String) -> String { gonePrefix + name(ofKey: key) }

    /// Whether the thing `key` names comes and goes with what settings say (a plugin they enable, the scripts of a
    /// settings file that reads), unlike a file, which hashes as absent when it's not there.
    static func comesAndGoes(key: String) -> Bool {
        let name = name(ofKey: key)
        return isPlugin(name: name) || isScripts(name: name)
    }

    /// Where a seal notes that it has watched plugins and scripts since (its first look that did): after it, one seen
    /// for the first time (a plugin enabled, or moved between your settings and the checkout's) waits for your Accept,
    /// since whatever wrote it while it was unwatched isn't known. At that first look, what's there is recorded as it is.
    static let comesAndGoesSince = keyPrefix + "#watched since"

    /// Whether `key` is one of the vault's own notes beside a watched thing's hash (`keysPrefix`, `gonePrefix`,
    /// `comesAndGoesSince`): never in its `guarded` answer.
    static func isVaultNote(_ key: String) -> Bool { key.hasPrefix(keysPrefix) || key.hasPrefix(gonePrefix) || key == comesAndGoesSince }

    /// Where a look's hashes say what a folder hashes to with the sync bookkeeping counted (`isSyncBookkeeping`), as
    /// versions before it was left out did: only to carry a seal they made over, never recorded.
    static let countingPrefix = keyPrefix + "#counting "

    /// The key of the hash, bookkeeping counted, of the folder `key` (a watched key) hashes. Only folders have one.
    static func countingKey(of key: String) -> String { countingPrefix + name(ofKey: key) }

    /// The two files Claude Code's skill sync rewrites in `~/.claude/skills/synced/<account folder>/` on its own
    /// schedule, with no skill's content in them: left out of that folder's hash, or every sync round would hold the team.
    static let syncBookkeeping: Set<String> = [".last-complete-round", "manifest.json"]

    /// Whether `relative`, a regular file under the watched thing `name`, is that bookkeeping: those two names at
    /// exactly that depth, in that folder. A link or a folder with one of the names stays watched, as does anything
    /// beside or under them, every skill in `synced/` and the same names anywhere else.
    static func isSyncBookkeeping(_ relative: String, in name: String) -> Bool {
        guard name == "~/.claude/skills" else { return false }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "synced" && syncBookkeeping.contains(String(parts[2]))
    }

    /// The key VibeSwitcher sends after writing watched things itself (`appWrite`): lines "<name>\t<before>\t<after>",
    /// the hashes around its write. For each team where a thing was sealed as `before`, the vault seals `after` (a
    /// chain of such writes in order counts, across asks): only hashes the app's writes left, so what anyone else
    /// wrote before or after the app is never sealed this way, and the next look holds it. The app's only.
    public static let wroteKey = keyPrefix + "#wrote"

    /// The vault's answer to a lead that seals a change made while the team's sessions ran.
    public static let heldRefusal = "The agents' config changed while the team's sessions ran: only you accept that, in VibeSwitcher."

    /// The files in your home every session or shell loads.
    static let homeFiles: [(String, Watched.Kind)] = [
        (".claude/settings.json", .file), (".claude/settings.local.json", .file), (".claude/CLAUDE.md", .file),
        (".claude/skills", .folder), (".claude/agents", .folder), (".claude/commands", .folder), (".claude/hooks", .folder),
        (".claude/output-styles", .folder), (".claude.json", .mcpServers),
        (".zshenv", .file), (".zprofile", .file), (".zshrc", .file), (".zlogin", .file), (".zlogout", .file),
        (".bashrc", .file), (".bash_profile", .file), (".bash_login", .file), (".profile", .file),
        (".gitconfig", .file), (".config/git/config", .file),
        // What every session's hooks run (`VibePaths.hookBinary`), and Codex workers' own config, hooks and instructions.
        (".vibeswitcher/bin", .folder),
        (".codex/config.toml", .file), (".codex/hooks.json", .file), (".codex/AGENTS.md", .file), (".codex/rules", .folder),
    ]

    /// The main checkout's own: what its git runs, and what the lead's session there loads that isn't in git.
    static let checkoutFiles: [(String, Watched.Kind)] = [
        (".claude/settings.json", .file), (".claude/settings.local.json", .file), ("CLAUDE.local.md", .file), (".mcp.json", .file),
    ]

    /// The settings files whose scripts (`Kind.scripts`) and enabled plugins (`enabledPlugins`) are watched: your
    /// home's, and the main checkout's (`checkoutFiles`).
    static let settingsFiles = [".claude/settings.json", ".claude/settings.local.json"]

    /// What's watched in your home at `home` (every team's alike): the files, the scripts your settings name, and the
    /// plugins they enable.
    public static func homeWatched(home: String) -> [Watched] {
        let files = homeFiles.map { file in
            let name = "~/" + file.0
            return Watched(name: name, path: (home as NSString).appendingPathComponent(file.0), kind: file.1, executes: !instructions.contains(name))
        }
        let skip = files.filter { $0.kind == .file || $0.kind == .folder }.map(\.path)
        let scripts = settingsFiles.map { file in
            Watched(name: "~/" + file + scriptsSuffix, path: (home as NSString).appendingPathComponent(file), kind: .scripts(home: home, project: nil, skip: skip))
        }
        return files + scripts + plugins(home: home, enabledIn: settingsFiles.map { (home as NSString).appendingPathComponent($0) })
    }

    /// Everything watched for the team of the repository at `root`, with your home at `home`: your home's, the main
    /// checkout's files, the scripts its settings name, and the plugins they enable that yours don't.
    public static func watched(home: String, root: String) -> [Watched] {
        let mine = homeWatched(home: home)
        var all = mine
        let checkout = URL(fileURLWithPath: (root as NSString).standardizingPath).resolvingSymlinksInPath().path
        all += checkoutFiles.map { Watched(name: $0.0 + " (main checkout)", path: (checkout as NSString).appendingPathComponent($0.0), kind: $0.1) }
        let git = gitFolder(checkout)
        all.append(Watched(name: ".git/config (main checkout)", path: (git as NSString).appendingPathComponent("config"), kind: .file))
        all.append(Watched(name: ".git/hooks (main checkout)", path: (git as NSString).appendingPathComponent("hooks"), kind: .folder))
        let skip = all.filter { $0.kind == .file || $0.kind == .folder }.map(\.path)
        let settings = settingsFiles.map { (checkout as NSString).appendingPathComponent($0) }
        all += zip(settingsFiles, settings).map { file, path in
            Watched(name: file + " (main checkout)" + scriptsSuffix, path: path, kind: .scripts(home: home, project: checkout, skip: skip))
        }
        // A plugin only the checkout enables is the team's: only its looks see it, so the Mac-wide seal never holds it.
        let yours = Set(mine.map(\.name).filter { $0.hasPrefix(pluginPrefix) }.map { String($0.dropFirst(pluginPrefix.count)) })
        all += plugins(home: home, enabledIn: settings, checkout: true, except: yours)
        return all.map { item in
            var item = item
            item.executes = !instructions.contains(item.name)
            return item
        }
    }

    /// The plugins the settings files at `settings` enable (`enabledPlugins`, Claude Code's own record: any that sets
    /// one true), one watched thing each under a name that stays (`pluginPrefix`; `checkout`: the team's), with each
    /// of its installs as Claude Code records them (`~/.claude/plugins/installed_plugins.json`). An enabled plugin with
    /// no install is watched as such (an install appearing is a change); while that record can't be read (three reads
    /// in a row) each is watched as "record unreadable", so it's a change, never left out.
    static func plugins(home: String, enabledIn settings: [String], checkout: Bool = false, except: Set<String> = []) -> [Watched] {
        var enabled = Set<String>()
        for path in settings {
            guard let data = regularContents(path, limit: jsonLimit),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for (id, on) in object["enabledPlugins"] as? [String: Any] ?? [:] where (on as? Bool) == true { enabled.insert(id) }
        }
        enabled.subtract(except)
        guard !enabled.isEmpty else { return [] }
        let record = (home as NSString).appendingPathComponent(".claude/plugins/installed_plugins.json")
        var installs = installedPlugins(record)
        for _ in 1..<3 where installs == nil {
            usleep(20_000)
            installs = installedPlugins(record)
        }
        return enabled.sorted().map { id in
            let name = checkout ? checkoutPluginPrefix + id + " (main checkout)" : pluginPrefix + id
            guard let installs else { return Watched(name: name, path: "", kind: .plugin(home: home, installs: nil)) }
            let each = (installs[id] ?? []).sorted { $0.path < $1.path }
            let labelled = each.map { install in
                PluginInstall(path: install.path, label: each.count == 1 ? "" : "\(install.scope ?? "user") \(install.project ?? "")".trimmingCharacters(in: .whitespaces) + ": ")
            }
            return Watched(name: name, path: each.first?.path ?? "", kind: .plugin(home: home, installs: labelled))
        }
    }

    /// Claude Code's record of the installed plugins, by "<plugin>@<marketplace>": each install's version folder,
    /// scope and project. Empty when there's none; nil when it doesn't read as JSON.
    static func installedPlugins(_ path: String) -> [String: [(path: String, scope: String?, project: String?)]]? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return [:] }
        guard let data = regularContents(path, limit: jsonLimit),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var installs: [String: [(path: String, scope: String?, project: String?)]] = [:]
        // Version 2 keeps a list of installs per plugin; version 1, one.
        for (id, value) in object["plugins"] as? [String: Any] ?? [:] {
            let list = value as? [[String: Any]] ?? (value as? [String: Any]).map { [$0] } ?? []
            installs[id] = list.compactMap { install in
                guard let path = install["installPath"] as? String, !path.isEmpty else { return nil }
                return (path, install["scope"] as? String, install["projectPath"] as? String)
            }
        }
        return installs
    }

    /// The checkout's git folder: `.git`, or where a `.git` file (`gitdir: …`) points.
    static func gitFolder(_ checkout: String) -> String {
        let dotGit = (checkout as NSString).appendingPathComponent(".git")
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &folder), !folder.boolValue,
              let text = try? String(contentsOfFile: dotGit, encoding: .utf8), text.hasPrefix("gitdir: ") else { return dotGit }
        let target = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return target.hasPrefix("/") ? target : (checkout as NSString).appendingPathComponent(target)
    }

    /// The hashes of everything watched, by key (`keyPrefix` + name).
    /// Something read mid-write (`~/.claude.json`, which Claude Code rewrites at every session's start and end) is
    /// left out: neither recorded nor compared, so it holds nothing until it reads whole.
    /// With each JSON one's per-key hashes (`keysKey`, `keyHashes`) and each folder's per-path ones (`FolderRead`), for
    /// the vault alone; and each folder's hash with the bookkeeping counted (`countingKey`), never kept.
    public static func hashes(home: String, root: String) -> [String: String] {
        hashes(of: watched(home: home, root: root))
    }

    /// `hashes` of `items`.
    static func hashes(of items: [Watched]) -> [String: String] {
        var all: [String: String] = [:]
        for item in items {
            // A plugin's or a settings' scripts: read once, for its hash and its per-key hashes.
            if let parts = parts(item) {
                all[keyPrefix + item.name] = partsHash(parts)
                all[keysPrefix + item.name] = encode(Dictionary(parts, uniquingKeysWith: { first, _ in first }))
                continue
            }
            if item.kind == .folder {
                let folder = readFolder(item)
                all[keyPrefix + item.name] = folder.hash
                all[keysPrefix + item.name] = encode(folder.entries)
                all[countingPrefix + item.name] = folder.countingHash
                continue
            }
            guard let hash = fingerprint(item) else { continue }
            all[keyPrefix + item.name] = hash
            if let keys = keyHashes(item) { all[keysPrefix + item.name] = encode(keys) }
        }
        return all
    }

    /// Each key of a JSON one (settings, hooks.json, .mcp.json, `~/.claude.json`'s MCP servers), hashed: its top-level
    /// keys, and under `hooks` and `mcpServers` each event and server. Absent: none. nil for what isn't JSON, or
    /// doesn't read as JSON now.
    static func keyHashes(_ watched: Watched) -> [String: String]? {
        if let parts = parts(watched) { return Dictionary(parts, uniquingKeysWith: { first, _ in first }) }
        guard watched.kind == .mcpServers || (watched.kind == .file && watched.path.hasSuffix(".json")) else { return nil }
        var info = stat()
        guard stat(watched.path, &info) == 0 else { return [:] }
        guard let data = regularContents(watched.path, limit: jsonLimit),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard watched.kind == .mcpServers else { return entries(object) }
        var keys: [String: String] = [:]
        for (server, value) in object["mcpServers"] as? [String: Any] ?? [:] { keys["mcpServers." + server] = valueHash(value) }
        for (project, settings) in object["projects"] as? [String: Any] ?? [:] {
            for (server, value) in (settings as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:] {
                keys["mcpServers.\(server) (\(project))"] = valueHash(value)
            }
        }
        return keys
    }

    /// `object`'s keys, hashed: a hook event or MCP server each its own.
    static func entries(_ object: [String: Any]) -> [String: String] {
        var keys: [String: String] = [:]
        for (key, value) in object {
            if ["hooks", "mcpServers"].contains(key), let inner = value as? [String: Any], !inner.isEmpty {
                for (sub, entry) in inner { keys[key + "." + sub] = valueHash(entry) }
            } else {
                keys[key] = valueHash(value)
            }
        }
        return keys
    }

    private static func valueHash(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data("\(value)".utf8)
        return hex(SHA256.hash(data: data))
    }

    /// Per-key hashes as the vault keeps them: "<key>\t<hash>" lines.
    static func encode(_ keys: [String: String]) -> String {
        keys.keys.sorted().map { clean($0) + "\t" + (keys[$0] ?? "") }.joined(separator: "\n")
    }

    static func decode(_ text: String) -> [String: String] {
        var keys: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let tab = line.lastIndex(of: "\t") else { continue }
            keys[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return keys
    }

    /// What changed between two per-key hashes (`encode`'s): "hooks.SessionStart added, env changed, model
    /// removed", the first `shown` of them and how many more. Names only, never a value. nil when either isn't known.
    static func changedKeys(from old: String?, to new: String?, shown: Int = 8) -> String? {
        guard let old, let new else { return nil }
        let before = decode(old), after = decode(new)
        var said: [String] = []
        // A plugin's version folder first: an update says so before what moved with it.
        for key in Set(before.keys).union(after.keys).sorted(by: { $0 == versionKey || ($1 != versionKey && $0 < $1) }) {
            switch (before[key], after[key]) {
            case (nil, _?): said.append("\(key) added")
            case (_?, nil): said.append("\(key) removed")
            case let (was?, now?) where was != now: said.append("\(key) changed")
            default: break
            }
        }
        guard !said.isEmpty else { return nil }
        return said.prefix(shown).joined(separator: ", ") + (said.count > shown ? " and \(said.count - shown) more" : "")
    }

    /// What changed in a held folder, between its per-path hashes as sealed and as they are (`FolderRead.entries`):
    /// its relative paths, "foo/SKILL.md changed, bar.sh added and 3 more", the first `shown` in name order (a folder
    /// only when nothing under it changed too), and the newest of the changed ones' times, the unshown included: a
    /// folder's own time moves with whatever is written in it, a removed path has none. Paths only, never contents.
    /// Sealed without them (by a version before them) or with no path changed: nothing to name, the folder's newest.
    static func changedFiles(from old: String?, to new: String?, shown: Int = 5) -> (said: String?, at: Double?) {
        guard let new else { return (nil, nil) }
        let after = decode(new)
        func hash(_ entry: String?) -> Substring? { entry?.split(separator: " ").first }
        func time(_ entry: String?) -> Double? { entry?.split(separator: " ").last.flatMap { Double($0) } }
        var changed: [(path: String, word: String)] = []
        if let old {
            let before = decode(old)
            for path in Set(before.keys).union(after.keys).sorted() {
                switch (hash(before[path]), hash(after[path])) {
                case (nil, _?): changed.append((path, "added"))
                case (_?, nil): changed.append((path, "removed"))
                case let (was?, now?) where was != now: changed.append((path, "changed"))
                default: break
                }
            }
        }
        var parents: Set<Substring> = []
        for (path, _) in changed {
            var rest = Substring(path)
            while let slash = rest.lastIndex(of: "/") {
                rest = rest[..<slash]
                parents.insert(rest)
            }
        }
        let listed = changed.filter { !parents.contains(Substring($0.path)) }
        guard !listed.isEmpty else { return (nil, after.values.compactMap { time($0) }.max()) }
        let said = listed.prefix(shown).map { "\($0.path) \($0.word)" }.joined(separator: ", ")
            + (listed.count > shown ? " and \(listed.count - shown) more" : "")
        return (said, listed.compactMap { time(after[$0.path]) }.max())
    }

    /// The name a key stands for.
    public static func name(ofKey key: String) -> String { String(key.dropFirst(keyPrefix.count)) }

    /// A folder's entries hashed at most: past them, the rest is named as cut (a folder that big is still watched for
    /// what's in the first ones).
    static let maxEntries = 20_000

    /// A JSON file read whole (`~/.claude.json`, settings) at most: past it, it's taken as unreadable.
    static let jsonLimit = 64 << 20

    /// What `watched` holds now, hashed (SHA-256, hex). Something absent hashes as such, never as an empty file. nil
    /// when it can't be told now (`~/.claude.json` that doesn't parse, three reads in a row).
    public static func fingerprint(_ watched: Watched) -> String? {
        switch watched.kind {
        case .plugin, .scripts: return parts(watched).map(partsHash)
        default: break
        }
        var hasher = SHA256()
        let add = { (text: String) in hasher.update(data: Data(text.utf8)) }
        var info = stat()
        guard lstat(watched.path, &info) == 0 else {
            add("absent")
            return hex(hasher.finalize())
        }
        switch watched.kind {
        case .file:
            if (info.st_mode & S_IFMT) == S_IFLNK {
                add("link\0" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: watched.path)) ?? "") + "\0")
            }
            switch contentsDigest(watched.path, followLink: true) {
            case .digest(let digest): add("file\0" + digest)
            case .other: add("other")
            case .unreadable: add("unreadable")
            }
        case .folder:
            return readFolder(watched).hash
        case .mcpServers:
            var servers = mcpServers(watched.path)
            for _ in 1..<3 where servers == nil {
                usleep(20_000)
                servers = mcpServers(watched.path)
            }
            guard let servers else { return nil }
            add(servers)
        case .plugin, .scripts:
            break
        }
        return hex(hasher.finalize())
    }

    /// The hash of a plugin's or a settings' scripts' parts, in order.
    static func partsHash(_ parts: [(String, String)]) -> String {
        var hasher = SHA256()
        for (label, digest) in parts { hasher.update(data: Data((label + "\0" + digest + "\n").utf8)) }
        return hex(hasher.finalize())
    }

    /// What a plugin or a settings' scripts holds now, part by part ("<label>", "<digest>"), in order; nil for the
    /// other kinds, or when it can't be told now (a settings file that doesn't read as JSON: the file itself is
    /// watched, and what's held stays held).
    static func parts(_ watched: Watched) -> [(String, String)]? {
        switch watched.kind {
        case .plugin(let home, let installs):
            guard let installs else { return [("record unreadable", "")] }
            guard !installs.isEmpty else { return [("not installed", "")] }
            // The version folders, all of them as one: Claude Code's update moves one (`isUpdate`). Only folders in
            // its own cache count as one: a record pointing elsewhere is no update of its.
            let cache = (home as NSString).appendingPathComponent(".claude/plugins/cache") + "/"
            let folders = installs.map { $0.label + $0.path }.joined(separator: "\n")
            let key = installs.allSatisfy { $0.path.hasPrefix(cache) } ? versionKey : installKey
            return [(key, hex(SHA256.hash(data: Data(folders.utf8))))] + installs.flatMap { install in
                pluginParts(install.path, home: home).map { (install.label + $0.0, $0.1) }
            }
        case .scripts(let home, let project, let skip): return settingsScripts(watched.path, home: home, project: project, skip: skip)
        default: return nil
        }
    }

    /// At most this many paths a plugin's or a settings file's commands name are hashed: past them, the rest is named
    /// as cut.
    static let maxNamed = 200

    /// A named script bigger than this (an interpreter's binary a command names, not a script) is told by its size,
    /// times (ctime too: a shell can set mtime back, not ctime) and inode, not read.
    static let scriptLimit = 8 << 20

    /// An enabled plugin's install at `root`, its version folder ("" or missing: "absent"), as parts: its manifest (`.claude-plugin/plugin.json`), its hooks
    /// (`hooks/hooks.json`, and the files the manifest names), its MCP and LSP servers (`.mcp.json`, `.lsp.json`, and
    /// the files the manifest names), and every file their commands and arguments name by path
    /// (`${CLAUDE_PLUGIN_ROOT}/…`, `~/…`, `/…`). Nothing else is read, so a big cache costs only what runs.
    static func pluginParts(_ root: String, home: String) -> [(String, String)] {
        var info = stat()
        guard !root.isEmpty, lstat(root, &info) == 0 else { return [("absent", "")] }
        var parts: [(String, String)] = []
        var listed = Set<String>()
        var configs: [Any] = []
        let label = { (path: String) -> String in
            path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : shown(path, home: home)
        }
        func json(_ path: String) {
            let path = URL(fileURLWithPath: path).standardized.path
            guard listed.insert(path).inserted else { return }
            let read = jsonPart(path)
            parts.append((label(path), read.digest))
            if let object = read.object { configs.append(object) }
        }
        let manifest = (root as NSString).appendingPathComponent(".claude-plugin/plugin.json")
        json(manifest)
        for file in ["hooks/hooks.json", ".mcp.json", ".lsp.json"] { json((root as NSString).appendingPathComponent(file)) }
        // The manifest may name more hooks, MCP or LSP files (a path, or a list of them), or carry them inline.
        if let object = configs.first as? [String: Any] {
            for key in ["hooks", "mcpServers", "lspServers"] {
                let named = (object[key] as? String).map { [$0] } ?? object[key] as? [String] ?? []
                for path in named { json(path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)) }
            }
        }
        let vars = ["CLAUDE_PLUGIN_ROOT": root, "HOME": home]
        var named: [String] = []
        for config in configs { for command in commands(in: config) { named += namedPaths(command, vars: vars, home: home, base: root) } }
        parts += scriptParts(named, skip: [], listed: &listed, label: label)
        return parts
    }

    /// The scripts the settings file at `path` names by path, as parts: each file its hooks', status line's and
    /// helpers' (`apiKeyHelper`…) commands name, by contents (`scriptDigest`), labelled by where it is. What's at or
    /// under `skip` is watched already, and what you can't write isn't watched (no branch code can write it either).
    /// None when there's no settings file; nil when it doesn't read as JSON.
    static func settingsScripts(_ path: String, home: String, project: String?, skip: [String]) -> [(String, String)]? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return [] }
        guard let data = regularContents(path, limit: jsonLimit),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var vars = ["HOME": home]
        if let project { vars["CLAUDE_PROJECT_DIR"] = project }
        var found = commands(in: object)
        for key in ["apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "otelHeadersHelper"] {
            if let command = object[key] as? String { found.append(.shell(command)) }
        }
        var listed = Set<String>()
        return scriptParts(found.flatMap { namedPaths($0, vars: vars, home: home, base: project) }, skip: skip, listed: &listed) { shown($0, home: home) }
    }

    /// Each of `paths` not yet `listed` nor at or under `skip`, hashed (`scriptDigest`), at most `maxNamed`.
    private static func scriptParts(_ paths: [String], skip: [String], listed: inout Set<String>, label: (String) -> String) -> [(String, String)] {
        var parts: [(String, String)] = []
        for path in paths where !skip.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            guard listed.insert(path).inserted else { continue }
            guard listed.count <= maxNamed else {
                parts.append(("cut", ""))
                break
            }
            // What isn't there is no part, so command text a word carried, not a file, is never a label. Created
            // later it's a part then, and that's a change.
            guard let digest = scriptDigest(path), digest != "absent" else { continue }
            parts.append((label(path), digest))
        }
        return parts
    }

    /// A JSON file's digest (as `file` hashes it: "absent", a link's target, its contents) and what it holds, when it
    /// reads as JSON.
    private static func jsonPart(_ path: String) -> (digest: String, object: Any?) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return ("absent", nil) }
        let link = (info.st_mode & S_IFMT) == S_IFLNK ? "link " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "") + " " : ""
        guard let data = regularContents(path, limit: jsonLimit) else {
            return (link + (contentsDigest(path, followLink: true) == .other ? "other" : "unreadable"), nil)
        }
        return (link + hex(SHA256.hash(data: data)), try? JSONSerialization.jsonObject(with: data))
    }

    /// A file a command names, as watched: "absent", or its link's target and its contents' hash (past
    /// `scriptLimit`, its size, times and inode). nil when it isn't watched: a folder, or something you can't change:
    /// neither it nor its folder is writable by you or yours (made read-only, you can make it writable again).
    static func scriptDigest(_ path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        var info = stat(), folder = stat()
        let yours = (lstat(path, &info) == 0 && info.st_uid == geteuid()) || (stat(parent, &folder) == 0 && folder.st_uid == geteuid())
        guard yours || access(path, W_OK) == 0 || access(parent, W_OK) == 0 else { return nil }
        info = stat()
        guard lstat(path, &info) == 0 else { return "absent" }
        var said = ""
        if (info.st_mode & S_IFMT) == S_IFLNK {
            said = "link " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "") + " "
            guard stat(path, &info) == 0 else { return said + "dangling" }
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return nil
        case S_IFREG where info.st_size > Int64(scriptLimit):
            return said + "big \(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) \(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec) \(info.st_ino)"
        default:
            switch contentsDigest(path, followLink: true) {
            case .digest(let digest): return said + digest
            case .other: return said + "other"
            case .unreadable: return said + "unreadable"
            }
        }
    }

    /// `path` as you're told it: under your home as `~/…`.
    static func shown(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") ? "~/" + path.dropFirst(home.count + 1) : path
    }

    /// A watched folder as it is now.
    struct FolderRead {
        /// Its hash: every entry but the sync bookkeeping (`isSyncBookkeeping`).
        var hash: String
        /// Its hash with the bookkeeping counted. Without any bookkeeping there, `hash`.
        var countingHash: String
        /// Each entry but the bookkeeping, by relative path: "<its line's hash> <mtime, seconds>". What a held folder's
        /// card names comes from these (`changedFiles`): paths, hashes and times, never contents.
        var entries: [String: String]
    }

    /// Reads the folder `watched` (`Kind.folder`). The lines are the hash's since before the bookkeeping was left out,
    /// so a folder without any hashes as it did.
    static func readFolder(_ watched: Watched) -> FolderRead {
        var hasher = SHA256(), counting = SHA256()
        var info = stat()
        guard lstat(watched.path, &info) == 0 else {
            hasher.update(data: Data("absent".utf8))
            let absent = hex(hasher.finalize())
            return FolderRead(hash: absent, countingHash: absent, entries: [:])
        }
        var entries: [String: String] = [:]
        var count = 0
        walk(watched.path, relative: "", name: watched.name, count: &count) { line in
            let text = Data((line.text + "\n").utf8)
            counting.update(data: text)
            guard !line.bookkeeping else { return }
            hasher.update(data: text)
            if let path = line.path { entries[path] = hex(SHA256.hash(data: text).prefix(8)) + " \(line.mtime)" }
        }
        return FolderRead(hash: hex(hasher.finalize()), countingHash: hex(counting.finalize()), entries: entries)
    }

    /// One of `walk`'s lines: what's hashed, and for an entry its path and mtime (`FolderRead.entries`).
    private struct FolderLine {
        var text: String
        var path: String?
        var mtime = 0
        var bookkeeping = false
    }

    /// Each entry under `folder` (of the watched thing `name`) in name order, one line each: links read, never followed.
    private static func walk(_ folder: String, relative: String, name watchedName: String, count: inout Int, line: (FolderLine) -> Void) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
            line(FolderLine(text: "unreadable \(relative)"))
            return
        }
        for name in names.sorted() where name != ".DS_Store" {
            count += 1
            guard count <= maxEntries else {
                line(FolderLine(text: "cut"))
                return
            }
            let path = (folder as NSString).appendingPathComponent(name)
            let shown = relative.isEmpty ? name : relative + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let mtime = Int(info.st_mtimespec.tv_sec)
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                line(FolderLine(text: "d \(shown)", path: shown, mtime: mtime))
                walk(path, relative: shown, name: watchedName, count: &count, line: line)
            case S_IFLNK:
                line(FolderLine(text: "l \(shown) -> " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""), path: shown, mtime: mtime))
            case S_IFREG:
                let digest: String
                switch contentsDigest(path, followLink: false) {
                case .digest(let hex): digest = hex
                case .other: digest = "other"
                case .unreadable: digest = "unreadable"
                }
                line(FolderLine(text: "f \(shown) \(info.st_mode & 0o777) \(digest)", path: shown, mtime: mtime,
                                bookkeeping: isSyncBookkeeping(shown, in: watchedName)))
            default:
                line(FolderLine(text: "o \(shown)", path: shown, mtime: mtime))
            }
        }
    }

    /// What reading a watched file's contents found.
    enum Contents: Equatable {
        /// A regular file: its contents' SHA-256, hex.
        case digest(String)
        /// Not a regular file (a FIFO, a device, a socket, a folder): never read, so it can't stall the look or fill
        /// memory.
        case other
        case unreadable
    }

    /// Opens `path` without waiting (a FIFO's open would wait for a writer), checks what it opened is a regular file,
    /// and hashes it as it reads, a chunk at a time. `followLink`: a link at `path` is followed (the file behind it is
    /// what loads); otherwise a link is refused (a folder's entries were told apart already).
    static func contentsDigest(_ path: String, followLink: Bool) -> Contents {
        var hasher = SHA256()
        switch readRegular(path, followLink: followLink, limit: nil, chunk: { hasher.update(data: $0) }) {
        case .digest: return .digest(hex(hasher.finalize()))
        case let other: return other
        }
    }

    /// A regular file's whole contents (a link at `path` followed), at most `limit` bytes: nil when it isn't a regular
    /// file, can't be read or is bigger.
    static func regularContents(_ path: String, limit: Int) -> Data? {
        var data = Data()
        guard case .digest = readRegular(path, followLink: true, limit: limit, chunk: { data.append($0) }) else { return nil }
        return data
    }

    /// `contentsDigest`'s and `regularContents`' read: `.digest("")` when it read it whole, each chunk handed on.
    private static func readRegular(_ path: String, followLink: Bool, limit: Int?, chunk: (Data) -> Void) -> Contents {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (followLink ? 0 : O_NOFOLLOW))
        guard fd >= 0 else { return errno == ELOOP ? .other : .unreadable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .unreadable }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .other }
        if let limit, info.st_size > Int64(limit) { return .unreadable }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var total = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return .unreadable }
            if count == 0 { return .digest("") }
            total += count
            if let limit, total > limit { return .unreadable }
            chunk(Data(buffer[0..<count]))
        }
    }

    /// `~/.claude.json`'s MCP servers, yours and each project's, as sorted JSON: nil when it isn't JSON (mid-write).
    static func mcpServers(_ path: String) -> String? {
        guard let data = regularContents(path, limit: jsonLimit) else { return "unreadable" }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var servers: [String: Any] = [:]
        if let own = object["mcpServers"] { servers["user"] = own }
        if let projects = object["projects"] as? [String: Any] {
            for (project, settings) in projects {
                if let own = (settings as? [String: Any])?["mcpServers"] as? [String: Any], !own.isEmpty { servers["project " + project] = own }
            }
        }
        guard let json = try? JSONSerialization.data(withJSONObject: servers, options: [.sortedKeys]) else { return "unreadable" }
        return String(decoding: json, as: UTF8.self)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// What the lead is told when `changed` (names) stopped something: `not` says what didn't happen. `outside`: those
    /// of them that changed outside a team session (code that runs, which only the user's Accept seals).
    public static func refusal(_ changed: [String], outside: [String] = [], not: String) -> String {
        let during = changed.filter { !outside.contains($0) }
        var said = "\(not): "
        if !during.isEmpty {
            said += "\(list(during)) changed while the team's sessions ran, since VibeSwitcher last sealed \(during.count == 1 ? "it" : "them"). "
                + "A worker's shell, a verifier's command or a branch's tests can write \(during.count == 1 ? "it" : "them") (the deny rules hold only the file tools), "
                + "and the next session would load what was written. "
        }
        if !outside.isEmpty {
            said += "\(list(outside)) changed outside a team session: \(outside.count == 1 ? "it carries" : "they carry") code that runs (hooks, MCP servers, "
                + "shell startup, git's commands), so only the user's Accept seals \(outside.count == 1 ? "it" : "them"), whoever made the change. "
        }
        return said + "New workers, verifiers and merges are held until the user accepts the change in VibeSwitcher (its notice names the files); you can't. "
            + "Tell the user which changed and ask them to look: if they made the change, they accept it there; if not, they set it back first."
    }

    /// The app's writes not yet sealed (`LeadVault.appWrite`), oldest first.
    final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        /// At most this many kept: an app whose host never answers doesn't grow it for ever.
        let limit = 200

        func add(_ new: [String]) {
            lock.lock()
            lines = Array((lines + new).suffix(limit))
            lock.unlock()
        }

        func take() -> [String]? {
            lock.lock()
            defer { lock.unlock() }
            guard !lines.isEmpty else { return nil }
            let taken = lines
            lines = []
            return taken
        }

        /// Asked and not answered: back in front of anything newer.
        func putBack(_ old: [String]) {
            lock.lock()
            lines = Array((old + lines).suffix(limit))
            lock.unlock()
        }
    }

    /// The app's writes not yet sealed, by vault (its folder: the app has one; each test its own).
    static func pending(for folder: URL) -> Pending {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        if let pending = pendingByVault[folder.path] { return pending }
        let pending = Pending()
        pendingByVault[folder.path] = pending
        return pending
    }

    private static let pendingLock = NSLock()
    nonisolated(unsafe) private static var pendingByVault: [String: Pending] = [:]

    /// Where the app's writes are sealed, one ask at a time, in the order they were made.
    static let flushes = DispatchQueue(label: "ConfigSeal.appWrites")

    static func list(_ names: [String]) -> String {
        names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}

extension LeadVault {
    /// What a look at the agents' config (`ConfigSeal`) found: what's held (changed while the team's sessions ran, until
    /// you accept it in the app), and what was sealed anew as it is (changed while the team was quiet: yours).
    public struct ConfigCheck: Equatable, Sendable {
        public var held: [String] = []
        public var resealed: [String] = []
        /// Of `held`, what changed outside a team session (code that runs: only your Accept seals it).
        public var outside: [String] = []
    }

    /// VibeSwitcher's own write of watched things (`paths`: files, or what's in a watched folder, in your home): runs
    /// `write`, and asks the vault to seal what it wrote (`ConfigSeal.wroteKey`), so the app's hook install or update
    /// never waits for your Accept. Only what was as sealed before the write is sealed so, and only as the write left
    /// it: a change someone else made before, or makes after, is still held. When the session host can't be asked now,
    /// it's asked again at the next look (`sealAppWrites`). The app's alone (the vault refuses anyone else).
    @discardableResult
    public func appWrite<T>(_ paths: [String], home: String = VibePaths.home, _ write: () throws -> T) rethrows -> T {
        // A plugin with no install has no path: no write is in it.
        let items = ConfigSeal.homeWatched(home: home).filter { item in
            !item.path.isEmpty && paths.contains { $0 == item.path || $0.hasPrefix(item.path + "/") }
        }
        let before = items.map(ConfigSeal.fingerprint)
        defer {
            var lines: [String] = []
            for (item, was) in zip(items, before) {
                guard let was, let now = ConfigSeal.fingerprint(item), now != was else { continue }
                lines.append("\(item.name)\t\(was)\t\(now)")
            }
            if !lines.isEmpty {
                ConfigSeal.pending(for: folder).add(lines)
                // Off the caller's thread (the app's launch writes the hook binary on the main one), in order.
                let vault = self
                ConfigSeal.flushes.async { vault.flushAppWrites() }
            }
        }
        return try write()
    }

    /// Asks the vault to seal the app's own writes not yet sealed (`appWrite`), in the order they were made; kept to
    /// be asked again when the host doesn't answer. Blocking.
    public func sealAppWrites() {
        ConfigSeal.flushes.sync { flushAppWrites() }
    }

    private func flushAppWrites() {
        let pending = ConfigSeal.pending(for: folder)
        guard let lines = pending.take() else { return }
        do { try setGuardedSettings([ConfigSeal.wroteKey: lines.joined(separator: "\n")], root: VibePaths.home) } catch let refused as Refused
            where !refused.description.hasPrefix("The session host didn't answer") {
            NSLog("VibeSwitcher: the vault didn't seal the app's own config writes: \(refused)")
        } catch {
            pending.putBack(lines)
        }
    }

    /// Asks the vault to look at the agents' config now: it hashes everything watched itself; what's as sealed is
    /// found so, what's new is recorded, and a change is sealed anew when the team was quiet and it doesn't execute,
    /// else held (`Book`'s rule). From the app (your click in its notice), what its card showed is sealed. The app's
    /// or the lead's.
    public func checkConfig(root: String) throws -> ConfigCheck {
        let before = try guardedRecord(root: root) ?? [:]
        var check = ConfigCheck()
        do { try setGuardedSettings([ConfigSeal.checkKey: "1"], root: root) } catch let refused as Refused where refused.description == ConfigSeal.heldRefusal {
            let record = try guardedRecord(root: root)
            check.held = ConfigSeal.held(in: record)
            check.outside = ConfigSeal.heldOutside(in: record)
        }
        let after = try guardedRecord(root: root) ?? [:]
        // Sealed anew: recorded before and changed, or held and first recorded now (a plugin first seen).
        let wasHeld = ConfigSeal.heldLines(in: before)
        check.resealed = after.keys.filter { key in
            ConfigSeal.isWatchedKey(key) && before[key] != after[key] && (before[key] != nil || wasHeld[key] != nil)
        }.sorted().map(ConfigSeal.name(ofKey:))
        return check
    }

    /// A branch's code is about to run outside any session (a merge's or an audit's tests): the team isn't quiet from now.
    /// It counts as running, at every look of every team, until `endBranchRun` with the id this gives.
    @discardableResult
    public func markBranchRun(root: String) throws -> String {
        let id = UUID().uuidString
        try setGuardedSettings([ConfigSeal.runKey: id], root: root)
        return id
    }

    /// The branch run `id` (`markBranchRun`'s) ended: what it wrote is still taken as written while it ran.
    public func endBranchRun(_ id: String, root: String) throws {
        try setGuardedSettings([ConfigSeal.runEndKey: id], root: root)
    }

    /// What's held now, by name (nothing when the host can't say).
    public func heldConfig(root: String) -> [String] {
        ConfigSeal.held(in: try? guardedRecord(root: root))
    }
}
