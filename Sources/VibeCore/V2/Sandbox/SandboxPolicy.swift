import Foundation

/// A project's settings for its boxes: guarded keys of its `workflow.md` (SB-D16), so a worker's edit of the file
/// changes nothing until the user accepts it (`LeadVault.guardedKeys`).
///
/// - `sandbox`: `off` asks for no box (whether the node grants that is the user's call, SB-D16; the planner never
///   reads it).
/// - `sandbox_read`: folders or files every role of the project sees read-only (an SDK, a shared cache).
/// - `sandbox_private`: folders a worker and a branch run read through a layer of their own (a package cache).
/// - `sandbox_hosts`, `sandbox_run_hosts`: the hosts a worker's proxy, and a branch run's, let through (slice 2).
/// - `sandbox_nesting`: whether a box may make user namespaces and mounts of its own (SB-D10).
///
/// Lists are comma-separated. A path is absolute or under the home (`~/…`) and is judged after its links are followed;
/// one under a hidden folder (`hidden`), the node's own folder, `/run`, `/mnt`, `/init`, `/proc`, `/sys` or `/dev`, or one
/// holding any of them, or one in or holding another project, is refused, naming it, whatever the key. A host is a name (`api.example.com`, `*.example.com`,
/// optionally `:port`): never a scheme, a path, a user or an address.
public struct SandboxPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var read: [String]
    public var privateFolders: [String]
    public var hosts: [String]
    public var runHosts: [String]
    public var nesting: Bool

    public init(enabled: Bool = true, read: [String] = [], privateFolders: [String] = [], hosts: [String] = [],
                runHosts: [String] = [], nesting: Bool = false) {
        self.enabled = enabled
        self.read = read
        self.privateFolders = privateFolders
        self.hosts = hosts
        self.runHosts = runHosts
        self.nesting = nesting
    }

    /// No setting: a box on, nothing added.
    public static let standard = SandboxPolicy()

    /// The keys, as `workflow.md` writes them; each is guarded (`LeadVault.guardedKeys`).
    public static let keys = ["sandbox", "sandbox_read", "sandbox_private", "sandbox_hosts", "sandbox_run_hosts", "sandbox_nesting"]

    /// The home's folders and files no key may name (they hold keys, logins, what runs later as the user, the node).
    public static let hidden = [".ssh", ".gnupg", ".config", ".vibeswitcher", ".aws", ".azure", ".gcloud", ".kube", ".docker",
                                ".codex", ".claude", ".claude.json", ".password-store", ".netrc", ".git-credentials", ".pki",
                                ".mozilla", ".local/share/keyrings", ".bashrc", ".profile", ".bash_profile", ".bash_login",
                                ".bash_logout", ".zshrc", ".zprofile", ".gitconfig"]

    /// The machine's folders no key may name.
    public static let hiddenRoots = ["/run", "/var/run", "/mnt", "/init", "/proc", "/sys", "/dev"]

    /// `workflow`'s settings for its boxes, every path judged after its links are followed (`resolve`) against
    /// `home` and, when given, the project's `root` (another repository is refused); the first refusal otherwise.
    public static func read(_ workflow: LeadWorkflow, home: String = VibePaths.accountHome, root: String? = nil,
                            resolve: (String) -> String = SandboxPolicy.resolved,
                            isRepository: (String) -> Bool = SandboxPolicy.holdsGit) -> Result<SandboxPolicy, SandboxRefusal> {
        var policy = SandboxPolicy()
        let settings = workflow.settings
        func flag(_ key: String, default value: Bool) -> Result<Bool, SandboxRefusal> {
            let text = (settings[key] ?? "").trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return .success(value) }
            guard let read = LeadWorkflow.flag(text) else {
                return .failure(SandboxRefusal(key: key, value: text, reason: "not on or off"))
            }
            return .success(read)
        }
        func list(_ key: String) -> [String] {
            (settings[key] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        do {
            policy.enabled = try flag("sandbox", default: true).get()
            policy.nesting = try flag("sandbox_nesting", default: false).get()
            policy.read = try list("sandbox_read").map { try path($0, key: "sandbox_read", home: home, root: root, resolve: resolve,
                                                                  isRepository: isRepository).get() }
            policy.privateFolders = try list("sandbox_private").map { try path($0, key: "sandbox_private", home: home, root: root,
                                                                               resolve: resolve, isRepository: isRepository).get() }
            policy.hosts = try list("sandbox_hosts").map { try host($0, key: "sandbox_hosts").get() }
            policy.runHosts = try list("sandbox_run_hosts").map { try host($0, key: "sandbox_run_hosts").get() }
        } catch let refusal as SandboxRefusal {
            return .failure(refusal)
        } catch {
            return .failure(SandboxRefusal(value: "\(error)", reason: "unreadable"))
        }
        return .success(policy)
    }

    /// One path of a key: absolute or `~/…`, its links followed, and outside everything `hidden` and `hiddenRoots`
    /// name, the home itself, a folder that holds the home, and another repository than `root`.
    public static func path(_ text: String, key: String, home: String, root: String?, resolve: (String) -> String = SandboxPolicy.resolved,
                            isRepository: (String) -> Bool = SandboxPolicy.holdsGit) -> Result<String, SandboxRefusal> {
        func refuse(_ reason: String) -> Result<String, SandboxRefusal> { .failure(SandboxRefusal(key: key, value: text, reason: reason)) }
        let spelled: String
        if text.hasPrefix("~/") {
            spelled = home + "/" + text.dropFirst(2)
        } else if text.hasPrefix("/") {
            spelled = text
        } else if text.hasPrefix("~") {
            return refuse("names a home that isn't this user's, or the home itself")
        } else {
            return refuse("a relative path: write it from / or from ~/")
        }
        let normalized = lexical(spelled)
        let resolvedPath = resolve(normalized)
        let realHome = resolve(home)
        for candidate in Set([normalized, resolvedPath]) {
            if candidate == "/" || candidate == realHome || candidate == home || isBelow(realHome, candidate) || isBelow(home, candidate) {
                return refuse("names the home, or a folder that holds it")
            }
            // Whichever way round: under a hidden place, or holding one.
            func touches(_ hidden: String) -> Bool { candidate == hidden || isBelow(candidate, hidden) || isBelow(hidden, candidate) }
            for hiddenRoot in hiddenRoots where touches(hiddenRoot) {
                return refuse("is, holds or is under \(hiddenRoot), which no box shows")
            }
            for name in hidden {
                for base in Set([home, realHome]) where touches(base + "/" + name) {
                    return refuse("is, holds or is under ~/\(name), which no box shows")
                }
            }
        }
        // Another project: a repository's working tree that isn't this project's, up to the home (or to `/` for a
        // path outside it).
        var folder = resolvedPath
        while folder != "/" && !folder.isEmpty && folder != realHome && folder != home {
            if isRepository(folder), folder != root.map(resolve) {
                return refuse("is in another repository (\(folder))")
            }
            folder = (folder as NSString).deletingLastPathComponent
        }
        // Nor one below it: a bounded look for `.git` under the path, links not followed.
        switch repositories(resolvedPath, root.map(resolve)) {
        case .none: break
        case .found(let repository): return refuse("holds another repository (\(repository))")
        case .tooBig: return refuse("holds more than \(scanLimit) folders, too many to look through for another repository")
        }
        return .success(resolvedPath)
    }

    /// One host of a key: a name of letters, digits and hyphens in two labels or more, optionally `*.` before it and
    /// `:port` after it, lower-cased.
    public static func host(_ text: String, key: String) -> Result<String, SandboxRefusal> {
        func refuse(_ reason: String) -> Result<String, SandboxRefusal> { .failure(SandboxRefusal(key: key, value: text, reason: reason)) }
        let lower = text.lowercased()
        if lower.contains("://") { return refuse("a host, not an address with a scheme") }
        if lower.contains("/") { return refuse("a host, not a path") }
        if lower.contains("@") { return refuse("a host, not a user at one") }
        if lower.contains("[") || lower.filter({ $0 == ":" }).count > 1 { return refuse("an address, not a name") }
        var name = Substring(lower)
        if let colon = name.lastIndex(of: ":") {
            guard let port = Int(name[name.index(after: colon)...]), (1...65535).contains(port) else { return refuse("a port that isn't one") }
            name = name[..<colon]
        }
        if name.hasPrefix("*.") { name = name.dropFirst(2) }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }
        }) else { return refuse("not a host name") }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return refuse("an address, not a name") }
        return .success(lower)
    }

    /// Whether `path` is strictly below `folder`.
    static func isBelow(_ path: String, _ folder: String) -> Bool {
        folder == "/" ? path != "/" : path.hasPrefix(folder + "/")
    }

    /// An absolute `path` with its `.`, `..` and empty components taken out by its spelling alone, links not followed
    /// (a relative one as it is). Not `standardizedFileURL`: on the Mac that also turns `/private/tmp/…` into `/tmp/…`,
    /// and a path judged against the home (`accountHome`, resolved) must keep the spelling it was given.
    public static func lexical(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `path` with its links followed (`realpath`), or as it is when it names nothing yet.
    public static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    /// What a vault records for guard rails it has nothing for (`LeadVault.changedSettings`' hook): `unrecorded` as it
    /// is, but where the vault already has a record (rails it set before these keys were guarded), each `sandbox*` key at
    /// its default (unset), so a value written since (a worker's `sandbox: off`) is a change held for the user's accept,
    /// never trusted on first sight.
    public static func baseline(_ unrecorded: [String: String], recorded: [String: String]) -> [String: String] {
        guard !recorded.isEmpty else { return unrecorded }
        return Dictionary(uniqueKeysWithValues: unrecorded.map { key, hash in (key, keys.contains(key) ? LeadVault.hash("") : hash) })
    }

    /// The most folders the look for a repository under a path goes through before it refuses the path.
    public static let scanLimit = 20_000

    public enum RepositoryScan: Equatable {
        case none
        case found(String)
        case tooBig
    }

    /// The first repository (a folder holding `.git`, file or folder) at or under `path` that isn't `root`, looked for
    /// through at most `limit` folders, links not followed and no `.git` entered.
    public static func repositories(_ path: String, _ root: String?, limit: Int = scanLimit) -> RepositoryScan {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { return .none }
        var pending = [path], seen = 0
        while let folder = pending.popLast() {
            seen += 1
            if seen > limit { return .tooBig }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            if names.contains(".git"), folder != root { return .found(folder) }
            for name in names where name != ".git" {
                let child = folder + "/" + name
                var info = stat()
                guard lstat(child, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
                pending.append(child)
            }
        }
        return .none
    }

    /// Whether `folder` is a repository's working tree: it holds `.git`.
    public static func holdsGit(_ folder: String) -> Bool {
        FileManager.default.fileExists(atPath: folder + "/.git")
    }
}
