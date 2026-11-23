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
    /// Whether the kernel gives the box a binfmt_misc of its own (`Platform.Sandbox.Facts.binfmt`): see
    /// `SandboxPlanner.hidesInterpreters`.
    public var binfmt: Bool

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
                agentConfig: Data? = nil, agentLogin: Bool = true, gitIdentity: GitIdentity? = nil,
                binfmt: Bool = Platform.Sandbox.probe().binfmt) {
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
        self.binfmt = binfmt
    }
}

/// A session's box, planned from its inputs (the session sandbox plan's tables, "What each role can read, write, run
/// and reach"): the same plan for the same inputs and files. The root starts empty, so whatever this doesn't name isn't
/// there. It reads files only to see what exists (an entry of the agent's config, a cache, a PATH folder) and a
/// worktree's git pointers (`GitRoots`); it writes nothing, and runs nothing.
///
/// Two names inside a folder a box writes stay read-only there, there or not (`cover`): the worktree's own git config
/// (`GitRoots.worktreeConfig`), which the node's git reads outside, and the agent's memory (`ClaudeFiles.memory`),
/// which a later session outside loads as instructions.
///
/// Every source is judged before the plan is given: none under the node's folder but its build, the installed hook and
/// the session's own folder; none under `/run`, `/mnt`, `/init`, `/proc`, `/sys`, `/dev` or the home's hidden folders
/// (`SandboxPolicy.hidden`) but the agent's named config entries. A PATH folder there is left out; anything else there
/// refuses the plan.
public enum SandboxPlanner {
    /// The door, inside (`DoorProtocol.path`: where the relays look for it), and the folder it is in (an empty one of
    /// the box's own).
    public static let door = DoorProtocol.path
    public static let doorFolder = (DoorProtocol.path as NSString).deletingLastPathComponent
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

    /// Where a box's own binfmt_misc is, inside (where the machine shows its own).
    public static let interpreters = "/proc/sys/fs/binfmt_misc"

    /// Whether `inputs`' box hides the machine's binfmt_misc entries behind an empty one of its own (`interpreters`):
    /// WSL's interop entry among them, which starts a Windows program through `/init`. With the entry's F flag the
    /// kernel opened `/init` when the entry was registered, so the box's missing `/init` doesn't stop it (kernel 6.18,
    /// measured 2026-11-20: `/init` ran inside a box on a two-byte `MZ` file). Only where the kernel gives a user
    /// namespace one (`SandboxInputs.binfmt`, from the probe); elsewhere the box tries the machine's entries, and only
    /// the missing `/run/WSL` and the filter's refusal of `AF_VSOCK` stand between a program and the Windows side. The
    /// one place a box would keep the machine's entries, for a session the user gave Windows.
    public static func hidesInterpreters(_ inputs: SandboxInputs) -> Bool { inputs.binfmt }

    public static func plan(_ inputs: SandboxInputs, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                            gitRoots: (String) -> Result<GitRoots.Roots, SandboxRefusal> = GitRoots.read,
                            entry: (String) -> Entry = SandboxPlanner.entry)
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
        /// `target`, a name in a folder the box writes (a real one, bound read-write: `source` is that name in it),
        /// read-only inside whether or not it is there: the real `source` bound over it, which the box can neither
        /// write, remove nor rename something onto (a mount point: EROFS, EBUSY). One that isn't there is made first,
        /// empty, through the folder's own mount (so it is the real one that is made: an empty file, or the point of an
        /// empty folder in memory that the cover then hides), since only what is there can be bound. A link, or a
        /// folder where a file belongs, can't be covered (the shim follows no link, and git or the agent would read
        /// what the box put there): why there is no box then, else nil.
        ///
        /// A cover holds while nothing outside the box renames the real name away or renames something over it: the
        /// kernel then lets go of the mount inside (measured), and the box finds the folder's own name again, writable.
        /// git outside writes a config by such a rename, and `LeadLaunch.setAsideMemory` renames a worktree's memory:
        /// neither is done to a live box's worktree by the node today but the second, at its verifier's start (SB6b).
        func cover(_ target: String, source: String, folder: Bool, what: String) -> SandboxRefusal? {
            switch (entry(source), folder) {
            case (.file, false), (.folder, true): break
            case (.absent, _): mounts.append(.init(target, folder ? .empty(mode: 0o555) : .file(contents: Data(), mode: 0o644)))
            default:
                return SandboxRefusal(value: source, reason: "\(what) must be \(folder ? "a folder" : "a file") (or not be there) to be read-only "
                                      + "in a box: a link or anything else there can't be covered")
            }
            mounts.append(.init(target, .readOnly(source: source)))
            return nil
        }

        // The machine's read-only part, and the box's own /proc, /dev, /tmp.
        for folder in system where exists(folder) { readOnly(folder) }
        for link in ["bin", "lib", "lib64", "sbin"] { mounts.append(.init("/" + link, .link(to: "usr/" + link))) }
        mounts.append(.init("/proc", .proc))
        if hidesInterpreters(inputs) { mounts.append(.init(interpreters, .binfmt)) }
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
            let spelled = SandboxPolicy.lexical(folder)
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
        // transcripts' real folder with the memory in it read-only, its login, its seeded `.claude.json`, and git's
        // config.
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
            if let refusal = cover(inputs.home + "/.claude" + transcripts + "/" + ClaudeFiles.memory,
                                   source: config + transcripts + "/" + ClaudeFiles.memory, folder: true, what: "the agent's memory") {
                return .failure(refusal)
            }
            mounts.append(.init(inputs.home + "/.claude.json",
                                .file(contents: ClaudeFiles.seededConfig(from: inputs.agentConfig ?? Data("{}".utf8), cwd: directory,
                                                                          login: inputs.agentLogin), mode: 0o600)))
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
                // Its own ref folder and its log, never the shared `refs/heads/agent` (git locks and renames a ref
                // beside it, so a branch is writable alone only in a folder of its own: `agent/<slug>/<name>`), and a
                // folder of objects of the session's own, the shared store read-only behind it (git's alternates):
                // no other worker's branch, and no object anyone else reads, is the worker's to write.
                guard let branch = GitRoots.branch(roots), branch.hasPrefix("refs/heads/agent/\(roots.slug)/") else {
                    return .failure(SandboxRefusal(value: worktree, reason: "a worker's branch must be agent/\(roots.slug)/<name>, "
                                                   + "so its ref folder is its own (its HEAD names \(GitRoots.branch(roots) ?? "no branch"))"))
                }
                for folder in ["refs/heads/agent/\(roots.slug)", "logs/refs/heads/agent/\(roots.slug)"] {
                    guard exists(roots.common + "/" + folder) else {
                        return .failure(SandboxRefusal(value: roots.common + "/" + folder, reason: "a worker's ref folder must be there before its box"))
                    }
                    readWrite(roots.common + "/" + folder)
                }
                readWrite(objectsFolder(inputs))
            }
            // The worktree's pointers, read-only over the folders that hold them; and its own git config, which git
            // reads once the repository's `extensions.worktreeConfig` is on (and `git sparse-checkout` turns it on).
            readOnly(worktree + "/.git")
            for pointer in ["commondir", "gitdir"] where exists(roots.own + "/" + pointer) { readOnly(roots.own + "/" + pointer) }
            let config = roots.own + "/" + GitRoots.worktreeConfig
            if let refusal = cover(config, source: config, folder: false, what: "a worktree's \(GitRoots.worktreeConfig)") {
                return .failure(refusal)
            }
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
        environment += ["HOME=\(inputs.home)", "PATH=\((toolchain.filter { inputs.pathFolders.map(SandboxPolicy.lexical).contains($0) } + ["/usr/local/bin", "/usr/bin", "/bin"]).joined(separator: ":"))",
                        "SHELL=/bin/bash", "TMPDIR=\(inputs.temporary)", "VIBESWITCHER_ROLE=\(role.rawValue)"]
        if agent {
            environment += ["\(DoorProtocol.variable)=\(door)", "DISABLE_AUTOUPDATER=1"]
        }
        if role == .worker, let common = try? gitRoots(inputs.worktree ?? "").get().common {
            environment += ["GIT_OBJECT_DIRECTORY=\(objectsFolder(inputs))", "GIT_ALTERNATE_OBJECT_DIRECTORIES=\(common)/objects"]
        }
        return .success(Platform.Sandbox.Plan(mounts: mounts, network: role == .branchRun && inputs.network == .shared ? .none : inputs.network,
                                              hostname: hostname, directory: directory, environment: environment,
                                              door: agent ? door : nil, terminal: agent ? .foreground : .none,
                                              nesting: inputs.policy.nesting))
    }

    /// A worker's own objects (`<box>/objects`): what its git writes. The lead and the merge read them only through an
    /// alternate, after checking them (`git fsck` of the worker's new objects before they are copied into the shared
    /// store: SB5's and the merge's to do).
    public static func objectsFolder(_ inputs: SandboxInputs) -> String { inputs.box + "/objects" }

    /// The folders the host makes before `inputs`' box is entered, each 0700: the session's own home, a worker's own
    /// objects, and each private layer's two (`SandboxPlanner.plan` names them as sources).
    public static func folders(for plan: Platform.Sandbox.Plan, inputs: SandboxInputs) -> [String] {
        var folders: [String] = []
        for mount in plan.mounts {
            switch mount.kind {
            case .readWrite(let source) where source == inputs.box + "/home" || source == objectsFolder(inputs): folders.append(source)
            case .overlay(_, let upper, let work): folders += [upper, work]
            default: break
            }
        }
        return folders
    }

    /// What is at a path, its last component not followed.
    public enum Entry: Equatable, Sendable {
        case absent, file, folder
        /// A link, a socket, a device, or a path that can't be looked at.
        case other
    }

    /// What is at `path` (`lstat`).
    public static func entry(_ path: String) -> Entry {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .absent : .other }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .folder
        default: return .other
        }
    }

    /// Why `source` may not be shown in a box; nil when it may.
    static func sourceRefusal(_ source: String, _ inputs: SandboxInputs) -> SandboxRefusal? {
        func refuse(_ reason: String) -> SandboxRefusal { SandboxRefusal(value: source, reason: reason) }
        let home = inputs.accountHome
        // Whichever way round: a source under a hidden place, or one that holds one (the home holds them all).
        func touches(_ hidden: String) -> Bool {
            source == hidden || SandboxPolicy.isBelow(source, hidden) || SandboxPolicy.isBelow(hidden, source)
        }
        for hidden in SandboxPolicy.hiddenRoots where touches(hidden) {
            return refuse("is, holds or is under \(hidden), which no box shows")
        }
        let node = home + "/.vibeswitcher"
        if SandboxPolicy.isBelow(node, source) { return refuse("holds the node's folder, which no box shows") }
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
        for name in SandboxPolicy.hidden where touches(home + "/" + name) {
            return refuse("is, holds or is under ~/\(name), which no box shows")
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
