import Foundation

/// What a session's box is planned from: who it is for, where things are, and the project's settings. Paths are as
/// the node sees them, and keep their spelling inside the box.
public struct SandboxInputs: Equatable, Sendable {
    public var role: SandboxRole
    /// The home inside: the account's home for an agent's box (`<home>`, a folder of the session's own there), the
    /// run's scratch home for a branch run.
    public var home: String
    /// The account's own home: where the agent's config, the caches and the installed hook are, and what is never shown.
    public var accountHome: String
    public var uid: uid_t
    public var gid: gid_t
    /// The project's main checkout.
    public var root: String
    /// A worker's worktree, a verifier's audit checkout, a branch run's scratch worktree; nil for the lead.
    public var worktree: String?
    /// The session's TMPDIR.
    public var temporary: String
    /// The node's build folder (`<prefix>/<commit>`): its `bin` and `Resources/bin` are read-only inside.
    public var build: String
    /// The folders of the session's PATH, in order.
    public var pathFolders: [String]
    /// The agent's binary (the version file the lead resolved); nil for a branch run.
    public var agentProgram: String?
    /// The session's own folder outside (`<home>/.vibeswitcher/v2/boxes/<id>`, 0700): `home/` is its home and
    /// `layers/<n>/` its private layers, each made by the host before the box is entered (`SandboxPlanner.folders`).
    public var box: String
    public var policy: SandboxPolicy
    public var network: Platform.Sandbox.Network
    /// The heavy-work slots' folder (SB-D14); nil: none.
    public var slots: String?
    /// The spawn's environment, "NAME=value" each: only the names `SandboxPlanner.allowed` passes reach the box.
    public var environment: [String]
    /// The account's `~/.claude.json`, from which the box's seeded copy is made; nil: none.
    public var agentConfig: Data?
    /// Whether the agent's login is bound read-only into its config folder (SB-D8: slices 1 to 3; the user's call).
    public var agentLogin: Bool
    /// The user's git name and email for the box's generated `~/.gitconfig`; nil: no file.
    public var gitIdentity: GitIdentity?

    public struct GitIdentity: Equatable, Sendable {
        public var name: String
        public var email: String

        public init(name: String, email: String) {
            self.name = name
            self.email = email
        }
    }

    public init(role: SandboxRole, home: String, accountHome: String, uid: uid_t, gid: gid_t, root: String, worktree: String?,
                temporary: String, build: String, pathFolders: [String], agentProgram: String?, box: String,
                policy: SandboxPolicy = .standard, network: Platform.Sandbox.Network, slots: String?, environment: [String] = [],
                agentConfig: Data? = nil, agentLogin: Bool = true, gitIdentity: GitIdentity? = nil) {
        self.role = role
        self.home = home
        self.accountHome = accountHome
        self.uid = uid
        self.gid = gid
        self.root = root
        self.worktree = worktree
        self.temporary = temporary
        self.build = build
        self.pathFolders = pathFolders
        self.agentProgram = agentProgram
        self.box = box
        self.policy = policy
        self.network = network
        self.slots = slots
        self.environment = environment
        self.agentConfig = agentConfig
        self.agentLogin = agentLogin
        self.gitIdentity = gitIdentity
    }
}

/// A session's box, planned from its inputs (the session sandbox plan's tables, "What each role can read, write, run
/// and reach"): the same plan for the same inputs and files. The root starts empty, so whatever this doesn't name isn't
/// there. It reads files only to see what exists (an entry of the agent's config, a cache, a PATH folder) and a
/// worktree's git pointers (`GitRoots`); it writes nothing, and runs nothing.
///
/// Every source is judged before the plan is given: none under the node's folder but its build, the installed hook and
/// the session's own folder; none under `/run`, `/mnt`, `/init`, `/proc`, `/sys`, `/dev` or the home's hidden folders
/// (`SandboxPolicy.hidden`) but the agent's named config entries. A PATH folder there is left out; anything else there
/// refuses the plan.
public enum SandboxPlanner {
    /// The folder the door is in, inside (an empty one of the box's own) and the door.
    public static let doorFolder = "/run/vibeswitcher"
    public static let door = doorFolder + "/door"
    public static let hostname = "vibeswitcher"

    /// The package caches a worker and a branch run read through a layer of their own, under the account's home.
    public static let caches = [".cache/org.swift.swiftpm", ".swiftpm", ".npm"]

    /// The environment names a box passes on from its spawn (S12 item 17): these, `LC_*` and `VIBESWITCHER_HEAVY_*`.
    /// `HOME`, `PATH`, `SHELL`, `TMPDIR`, `VIBESWITCHER_ROLE` and `VIBESWITCHER_DOOR` are the plan's own.
    public static let allowed: Set<String> = ["USER", "LOGNAME", "LANG", "TERM", "COLORTERM", "TERM_PROGRAM", "VIBESWITCHER_SESSION",
                                              "GIT_OPTIONAL_LOCKS"]
    static let allowedPrefixes = ["LC_", "VIBESWITCHER_HEAVY_"]

    /// The machine's folders every box shows read-only, where they exist.
    static let system = ["/usr", "/etc", "/opt"]

    public static func plan(_ inputs: SandboxInputs, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                            gitRoots: (String) -> Result<GitRoots.Roots, SandboxRefusal> = GitRoots.read)
        -> Result<Platform.Sandbox.Plan, SandboxRefusal> {
        let role = inputs.role
        let agent = role != .branchRun
        // The project's paths are judged whether or not they exist yet.
        for path in inputs.policy.read + inputs.policy.privateFolders {
            if let refusal = sourceRefusal(path, inputs) { return .failure(refusal) }
        }
        var mounts: [Platform.Sandbox.Mount] = []
        func readOnly(_ path: String) { mounts.append(.init(path, .readOnly(source: path))) }
        func readWrite(_ path: String) { mounts.append(.init(path, .readWrite(source: path))) }
        var layers = 0
        func layered(_ path: String) {
            let layer = "\(inputs.box)/layers/\(layers)"
            layers += 1
            mounts.append(.init(path, .overlay(lower: path, upper: layer + "/upper", work: layer + "/work")))
        }

        // The machine's read-only part, and the box's own /proc, /dev, /tmp.
        for folder in system where exists(folder) { readOnly(folder) }
        for link in ["bin", "lib", "lib64", "sbin"] { mounts.append(.init("/" + link, .link(to: "usr/" + link))) }
        mounts.append(.init("/proc", .proc))
        mounts.append(.init("/dev", .empty(mode: 0o755)))
        mounts += ["null", "zero", "full", "random", "urandom", "tty"].map { .init("/dev/" + $0, .device($0)) }
        mounts += [.init("/dev/pts", .devpts), .init("/dev/ptmx", .link(to: "pts/ptmx")), .init("/dev/shm", .empty(mode: 0o1777)),
                   .init("/tmp", .empty(mode: 0o1777)), .init("/var/tmp", .empty(mode: 0o1777))]

        // The home: the session's own (an agent's), or the run's scratch one.
        if agent {
            mounts.append(.init(inputs.home, .readWrite(source: inputs.box + "/home")))
        } else {
            readWrite(inputs.home)
        }
        readWrite(inputs.temporary)

        // The toolchain: every PATH folder outside the machine's read-only part and the hidden places, the node's
        // build, the installed hook.
        var toolchain: [String] = []
        for folder in inputs.pathFolders + [inputs.build + "/bin", inputs.build + "/Resources/bin", inputs.accountHome + "/.vibeswitcher/bin"] {
            let spelled = URL(fileURLWithPath: folder).standardizedFileURL.path
            guard folder.hasPrefix("/"), exists(spelled), !toolchain.contains(spelled),
                  !(system + ["/bin", "/sbin", "/lib", "/lib64"]).contains(where: { spelled == $0 || SandboxPolicy.isBelow(spelled, $0) }),
                  sourceRefusal(spelled, inputs) == nil else { continue }
            toolchain.append(spelled)
        }
        toolchain.forEach(readOnly)

        // The package caches, through layers of the session's own.
        if role != .lead {
            for cache in caches.map({ inputs.accountHome + "/" + $0 }) + inputs.policy.privateFolders where exists(cache) { layered(cache) }
        }

        // The agent: its binary, its config folder (the session's own, with the user's entries read-only), its
        // transcripts' real folder, its login, its seeded `.claude.json`, and git's config.
        let directory = role == .lead ? inputs.root : (inputs.worktree ?? inputs.root)
        if agent {
            if let program = inputs.agentProgram { readOnly(program) }
            let config = inputs.accountHome + "/.claude"
            for entry in ClaudeFiles.readOnlyEntries where exists(config + "/" + entry) {
                mounts.append(.init(inputs.home + "/.claude/" + entry, .readOnly(source: config + "/" + entry)))
            }
            if inputs.agentLogin, exists(config + "/" + ClaudeFiles.login) {
                mounts.append(.init(inputs.home + "/.claude/" + ClaudeFiles.login, .readOnly(source: config + "/" + ClaudeFiles.login)))
            }
            let transcripts = "/projects/" + ClaudeFiles.projectFolder(cwd: directory)
            mounts.append(.init(inputs.home + "/.claude" + transcripts, .readWrite(source: config + transcripts)))
            mounts.append(.init(inputs.home + "/.claude.json",
                                .file(contents: ClaudeFiles.seededConfig(from: inputs.agentConfig ?? Data("{}".utf8), cwd: directory), mode: 0o600)))
            if let identity = inputs.gitIdentity {
                mounts.append(.init(inputs.home + "/.gitconfig", .file(contents: gitConfig(identity), mode: 0o644)))
            }
        }

        // The role's own part of the repository.
        switch role {
        case .lead:
            layered(inputs.root)
            if exists(inputs.root + "/.vibeswitcher") { readOnly(inputs.root + "/.vibeswitcher") }
            readOnly(inputs.root + "/.git")
        case .worker, .verifier, .branchRun:
            guard let worktree = inputs.worktree else {
                return .failure(SandboxRefusal(value: inputs.root, reason: "a \(role.rawValue)'s box needs its worktree"))
            }
            let roots: GitRoots.Roots
            switch gitRoots(worktree) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let found): roots = found
            }
            guard roots.common == SandboxPolicy.resolved(inputs.root + "/.git") else {
                return .failure(SandboxRefusal(value: worktree, reason: "isn't a worktree of \(inputs.root): its git folder is in \(roots.common)"))
            }
            readWrite(worktree)
            readOnly(roots.common)
            readWrite(roots.own)
            if role == .worker {
                for folder in ["objects", "refs/heads/agent", "logs/refs/heads/agent"] where exists(roots.common + "/" + folder) {
                    readWrite(roots.common + "/" + folder)
                }
            }
            // The worktree's pointers, read-only over the folders that hold them.
            readOnly(worktree + "/.git")
            for pointer in ["commondir", "gitdir"] where exists(roots.own + "/" + pointer) { readOnly(roots.own + "/" + pointer) }
        }

        // What the project names; the slots; the door.
        inputs.policy.read.filter(exists).forEach(readOnly)
        if agent, let slots = inputs.slots { readWrite(slots) }
        if agent { mounts.append(.init(doorFolder, .empty(mode: 0o700))) }

        // Every source judged.
        for mount in mounts {
            let sources: [String]
            switch mount.kind {
            case .readOnly(let source), .readWrite(let source): sources = [source]
            case .overlay(let lower, let upper, let work): sources = [lower, upper, work]
            default: sources = []
            }
            for source in sources {
                if let refusal = sourceRefusal(source, inputs) { return .failure(refusal) }
            }
        }

        var environment = inputs.environment.filter { entry in
            guard let equals = entry.firstIndex(of: "=") else { return false }
            let name = String(entry[..<equals])
            return allowed.contains(name) || allowedPrefixes.contains { name.hasPrefix($0) }
        }
        environment += ["HOME=\(inputs.home)", "PATH=\((toolchain.filter { inputs.pathFolders.map { URL(fileURLWithPath: $0).standardizedFileURL.path }.contains($0) } + ["/usr/local/bin", "/usr/bin", "/bin"]).joined(separator: ":"))",
                        "SHELL=/bin/bash", "TMPDIR=\(inputs.temporary)", "VIBESWITCHER_ROLE=\(role.rawValue)"]
        if agent {
            environment += ["VIBESWITCHER_DOOR=\(door)", "DISABLE_AUTOUPDATER=1"]
        }
        return .success(Platform.Sandbox.Plan(mounts: mounts, network: role == .branchRun && inputs.network == .shared ? .none : inputs.network,
                                              hostname: hostname, directory: directory, environment: environment,
                                              door: agent ? door : nil, terminal: agent ? .foreground : .none,
                                              nesting: inputs.policy.nesting))
    }

    /// The folders the host makes before `inputs`' box is entered, each 0700: the session's own home and each private
    /// layer's two (`SandboxPlanner.plan` names them as sources).
    public static func folders(for plan: Platform.Sandbox.Plan, inputs: SandboxInputs) -> [String] {
        var folders: [String] = []
        for mount in plan.mounts {
            switch mount.kind {
            case .readWrite(let source) where source == inputs.box + "/home": folders.append(source)
            case .overlay(_, let upper, let work): folders += [upper, work]
            default: break
            }
        }
        return folders
    }

    /// Why `source` may not be shown in a box; nil when it may.
    static func sourceRefusal(_ source: String, _ inputs: SandboxInputs) -> SandboxRefusal? {
        func refuse(_ reason: String) -> SandboxRefusal { SandboxRefusal(value: source, reason: reason) }
        let home = inputs.accountHome
        for hidden in SandboxPolicy.hiddenRoots where source == hidden || SandboxPolicy.isBelow(source, hidden) {
            return refuse("is under \(hidden), which no box shows")
        }
        let node = home + "/.vibeswitcher"
        if source == node || SandboxPolicy.isBelow(source, node) {
            let allowed = [inputs.build, node + "/bin", inputs.box]
            guard allowed.contains(where: { source == $0 || SandboxPolicy.isBelow(source, $0) }) else {
                return refuse("is in the node's folder, which no box shows but its build, the installed hook and the session's own folder")
            }
            return nil
        }
        let config = home + "/.claude"
        let agentEntries = (ClaudeFiles.readOnlyEntries + [ClaudeFiles.login]).map { config + "/" + $0 } + [config + "/projects"]
        if agentEntries.contains(where: { source == $0 || SandboxPolicy.isBelow(source, $0) }) { return nil }
        for name in SandboxPolicy.hidden where source == home + "/" + name || SandboxPolicy.isBelow(source, home + "/" + name) {
            return refuse("is under ~/\(name), which no box shows")
        }
        if source == home || source == "/" { return refuse("is the whole home, or more") }
        return nil
    }

    static func gitConfig(_ identity: SandboxInputs.GitIdentity) -> Data {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ") + "\""
        }
        return Data("[user]\n\tname = \(quoted(identity.name))\n\temail = \(quoted(identity.email))\n[gc]\n\tauto = 0\n".utf8)
    }
}
