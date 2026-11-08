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
/// Not watched yet (a known gap, a follow-up task): `~/.claude/plugins` (enabled plugins' hooks, hook scripts and MCP
/// servers run in every session) and the scripts settings' hooks or status line name by a path outside what's watched
/// here. A branch's code that edits one of those isn't held.
public enum ConfigSeal {
    /// One thing watched: its name as the lead and you are told it, where it is, and how it's read.
    public struct Watched: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// A file: its contents (a link followed, and where it points).
            case file
            /// A folder: every name under it, each file's contents and each link's target; links never followed.
            case folder
            /// `~/.claude.json`: only its MCP servers, yours and each project's (the rest changes with every session).
            case mcpServers
        }

        public var name: String
        public var path: String
        public var kind: Kind
        /// It carries code that runs (hooks, MCP servers, shell startup, git's commands, the hook binary, skills'
        /// scripts, commands' `!` lines): a change is never sealed silently, even made outside a team session. Not:
        /// instructions (CLAUDE.md, agents, output styles), which a quiet look seals as yours.
        public var executes = true
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
    /// server), as "hooks.SessionStart added, env changed"; never a value. Only for what has keys and was sealed with
    /// them.
    public static func heldChanges(in guarded: [String: String]?) -> [String: String] {
        var changes: [String: String] = [:]
        for (key, line) in heldLines(in: guarded) where !line.changes.isEmpty { changes[name(ofKey: key)] = line.changes }
        return changes
    }

    /// What's held, by key, with the hash it had when it was held (`heldKey`'s lines: "<key>\t<hash>\t<r|q>\t<keys>",
    /// q: changed outside a team session; keys: `heldChanges`').
    static func heldLines(in guarded: [String: String]?) -> [String: (hash: String, outside: Bool, changes: String)] {
        var held: [String: (hash: String, outside: Bool, changes: String)] = [:]
        for line in (guarded?[heldKey] ?? "").split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 2 { held[parts[0]] = (parts[1], parts.count > 2 && parts[2] == "q", parts.count > 3 ? parts[3] : "") }
        }
        return held
    }

    static func heldHashes(in guarded: [String: String]?) -> [String: String] { heldLines(in: guarded).mapValues(\.hash) }

    /// `heldKey`'s value for these keys and hashes, `outside` the ones changed outside a team session, `changes` what
    /// changed in each (`changedKeys`).
    static func heldValue(_ held: [String: String], outside: Set<String>, changes: [String: String] = [:]) -> String {
        held.keys.sorted().map { key in
            "\(key)\t\(held[key] ?? "")\t\(outside.contains(key) ? "q" : "r")\t\(clean(changes[key] ?? ""))"
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
        let rest = key.hasPrefix(keysPrefix) ? key.dropFirst(keysPrefix.count) : key.hasPrefix(keyPrefix) ? key.dropFirst(keyPrefix.count) : ""
        return rest.hasPrefix("~/")
    }

    /// The key of the per-key hashes of the thing `key` (a watched key) hashes.
    static func keysKey(of key: String) -> String { keysPrefix + name(ofKey: key) }

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

    /// What's watched in your home at `home` (every team's alike).
    public static func homeWatched(home: String) -> [Watched] {
        homeFiles.map { file in
            let name = "~/" + file.0
            return Watched(name: name, path: (home as NSString).appendingPathComponent(file.0), kind: file.1, executes: !instructions.contains(name))
        }
    }

    /// Everything watched for the team of the repository at `root`, with your home at `home`.
    public static func watched(home: String, root: String) -> [Watched] {
        var all = homeWatched(home: home)
        let checkout = URL(fileURLWithPath: (root as NSString).standardizingPath).resolvingSymlinksInPath().path
        all += checkoutFiles.map { Watched(name: $0.0 + " (main checkout)", path: (checkout as NSString).appendingPathComponent($0.0), kind: $0.1) }
        let git = gitFolder(checkout)
        all.append(Watched(name: ".git/config (main checkout)", path: (git as NSString).appendingPathComponent("config"), kind: .file))
        all.append(Watched(name: ".git/hooks (main checkout)", path: (git as NSString).appendingPathComponent("hooks"), kind: .folder))
        return all.map { item in
            var item = item
            item.executes = !instructions.contains(item.name)
            return item
        }
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
    /// With each JSON one's per-key hashes (`keysKey`, `keyHashes`), for the vault alone.
    public static func hashes(home: String, root: String) -> [String: String] {
        hashes(of: watched(home: home, root: root))
    }

    /// `hashes` of `items`.
    static func hashes(of items: [Watched]) -> [String: String] {
        var all: [String: String] = [:]
        for item in items {
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
        for key in Set(before.keys).union(after.keys).sorted() {
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
            var count = 0
            walk(watched.path, relative: "", count: &count) { add($0 + "\n") }
        case .mcpServers:
            var servers = mcpServers(watched.path)
            for _ in 1..<3 where servers == nil {
                usleep(20_000)
                servers = mcpServers(watched.path)
            }
            guard let servers else { return nil }
            add(servers)
        }
        return hex(hasher.finalize())
    }

    /// Each entry under `folder` in name order, one line each: links read, never followed.
    private static func walk(_ folder: String, relative: String, count: inout Int, line: (String) -> Void) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
            line("unreadable \(relative)")
            return
        }
        for name in names.sorted() where name != ".DS_Store" {
            count += 1
            guard count <= maxEntries else {
                line("cut")
                return
            }
            let path = (folder as NSString).appendingPathComponent(name)
            let shown = relative.isEmpty ? name : relative + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                line("d \(shown)")
                walk(path, relative: shown, count: &count, line: line)
            case S_IFLNK:
                line("l \(shown) -> " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""))
            case S_IFREG:
                let digest: String
                switch contentsDigest(path, followLink: false) {
                case .digest(let hex): digest = hex
                case .other: digest = "other"
                case .unreadable: digest = "unreadable"
                }
                line("f \(shown) \(info.st_mode & 0o777) \(digest)")
            default:
                line("o \(shown)")
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
        let items = ConfigSeal.homeWatched(home: home).filter { item in
            paths.contains { $0 == item.path || $0.hasPrefix(item.path + "/") }
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
        check.resealed = after.keys.filter { key in
            ConfigSeal.isWatchedKey(key) && before[key] != nil && before[key] != after[key]
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
