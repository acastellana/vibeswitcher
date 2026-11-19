import Foundation
import Testing
@testable import VibeCore

/// `SandboxPlanner`: what each role's box shows, from a scratch world (a scratch account home with decoys where the
/// user's keys and the node's state would be, a scratch repository with a worktree, a second project). Pure: nothing
/// here builds a box, so it runs on both systems.
struct SandboxPlannerTests {
    let scratch = Scratch()

    /// A scratch account: its home, a project with a worker's worktree, the node's folders, decoys.
    struct World {
        let home: String
        let root: String
        let worktree: String
        let other: String
        let box: String
        let temporary: String
        let build: String
        let slots: String
        let pathFolders: [String]
        let agent: String
        /// A branch run's scratch home (outside the account's, as `BranchCode`'s runs have).
        let runHome: String

        func inputs(_ role: SandboxRole, policy: SandboxPolicy = .standard, worktree given: String? = nil) -> SandboxInputs {
            let tree: String? = switch role {
            case .lead: nil
            default: given ?? worktree
            }
            return SandboxInputs(role: role, home: role == .branchRun ? runHome : home, accountHome: home, uid: 1000, gid: 1000,
                                 root: root, worktree: tree, temporary: role == .branchRun ? runHome + "/scratch-tmp" : temporary, build: build, pathFolders: pathFolders, agentProgram: role == .branchRun ? nil : agent,
                                 box: box, policy: policy, network: .shared, slots: slots,
                                 environment: ["TERM=xterm-256color", "LANG=C.UTF-8", "LC_ALL=C", "VIBESWITCHER_SESSION=s1",
                                               "AWS_SECRET_ACCESS_KEY=decoy", "SSH_AUTH_SOCK=/run/user/1000/ssh", "VIBESWITCHER_HEAVY_SLOTS=2",
                                               "HOME=/somewhere/else"],
                                 agentConfig: Data(#"{"userID":"u","projects":{"/other":{"hasTrustDialogAccepted":true}},"mcpServers":{"s":{"command":"x"}}}"#.utf8),
                                 gitIdentity: .init(name: "T", email: "t@t"))
        }
    }

    func world() throws -> World {
        func make(_ path: String) throws { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        // Made, then resolved by realpath, as the planner resolves a worktree's git folders: the Mac's
        // `resolvingSymlinksInPath` gives /private/tmp back as /tmp.
        let made = scratch.url("planner").path
        try make(made)
        let base = SandboxPolicy.resolved(made)
        let home = base + "/home"
        func write(_ text: String, _ path: String) throws {
            try make((path as NSString).deletingLastPathComponent)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        // Decoys where the user's keys, logins and the node's state would be. Never a real one.
        try write("decoy", home + "/.ssh/id_ed25519")
        try write("decoy", home + "/.config/gh/hosts.yml")
        try write("decoy", home + "/.config/systemd/user/decoy.service")
        try write("decoy", home + "/.gnupg/pubring.kbx")
        try write("{}", home + "/.vibeswitcher/state/pts-1.json")
        try write("decoy", home + "/.vibeswitcher/host.sock")
        try write("#!/bin/sh\n", home + "/.vibeswitcher/bin/vibeswitcher-hook")
        // The agent's config: entries to show read-only, a login (a decoy), and entries of its own.
        try write("{}", home + "/.claude/settings.json")
        try make(home + "/.claude/skills")
        try write("decoy", home + "/.claude/.credentials.json")
        try write("decoy", home + "/.claude/history.jsonl")
        try make(home + "/.claude/shell-snapshots")
        try write("{}", home + "/.claude.json")
        let agent = home + "/.local/share/claude/versions/2.1.326"
        try write("binary", agent)
        // The toolchain and the caches.
        try make(home + "/.local/share/swiftly/bin")
        try make(home + "/.cache/org.swift.swiftpm")
        try make(home + "/.swiftpm")
        let build = home + "/.vibeswitcher/v2/builds/abc123"
        try make(build + "/bin")
        try make(build + "/Resources/bin")
        // A project with a worker's worktree, and another project.
        let root = home + "/projects/app"
        try make(root)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"],
                          ["commit", "-q", "--allow-empty", "-m", "first"],
                          ["worktree", "add", "-q", "-b", "agent/w1/head", ".vibeswitcher/worktrees/w1"],
                          ["branch", "agent/w2/head"]] {
            #expect(Git.run(arguments, in: root).ok, "git \(arguments)")
        }
        try write("---\nmax_workers: 3\n---\n", root + "/.vibeswitcher/workflow.md")
        try make(root + "/.git/logs/refs/heads/agent")
        let other = home + "/projects/other"
        try make(other)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] {
            #expect(Git.run(arguments, in: other).ok)
        }
        try make(home + "/.claude/projects/" + ClaudeFiles.projectFolder(cwd: root + "/.vibeswitcher/worktrees/w1"))
        let box = home + "/.vibeswitcher/v2/boxes/session-1"
        try make(box + "/home")
        let temporary = base + "/session-tmp/vibeswitcher-1000/session-1"
        try make(temporary)
        let slots = base + "/session-tmp/vibeswitcher-1000/slots"
        try make(slots)
        let runHome = base + "/run-home"
        try make(runHome + "/scratch-tmp")
        return World(home: home, root: root, worktree: root + "/.vibeswitcher/worktrees/w1", other: other, box: box,
                     temporary: temporary, build: build, slots: slots,
                     pathFolders: [build + "/Resources/bin", home + "/.local/share/swiftly/bin", "/usr/local/bin", "/usr/bin", "/bin",
                                   "/mnt/c/Windows/system32", home + "/.vibeswitcher/state"],
                     agent: agent, runHome: runHome)
    }

    func plan(_ inputs: SandboxInputs) throws -> Platform.Sandbox.Plan {
        try SandboxPlanner.plan(inputs).get()
    }

    /// Each mount's target, by what it is.
    static func writable(_ plan: Platform.Sandbox.Plan) -> Set<String> {
        Set(plan.mounts.compactMap { mount in
            switch mount.kind {
            case .readWrite: return mount.target
            default: return nil
            }
        })
    }

    static func readOnly(_ plan: Platform.Sandbox.Plan) -> Set<String> {
        Set(plan.mounts.compactMap { mount in
            if case .readOnly = mount.kind { return mount.target }
            return nil
        })
    }

    static func layered(_ plan: Platform.Sandbox.Plan) -> Set<String> {
        Set(plan.mounts.compactMap { mount in
            if case .overlay = mount.kind { return mount.target }
            return nil
        })
    }

    /// Every source a plan reads from outside: binds' and layers' lower folders.
    static func sources(_ plan: Platform.Sandbox.Plan) -> [String] {
        plan.mounts.flatMap { mount -> [String] in
            switch mount.kind {
            case .readOnly(let source), .readWrite(let source): return [source]
            case .overlay(let lower, let upper, let work): return [lower, upper, work]
            default: return []
            }
        }
    }

    /// The mount a program in the box finds at `path`: the last one at it or above it.
    static func over(_ path: String, _ plan: Platform.Sandbox.Plan) -> Platform.Sandbox.Mount? {
        plan.mounts.last { within(path, $0.target) }
    }

    /// Whether `path` is `folder` or below it.
    static func within(_ path: String, _ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }

    @Test func aWorkerWritesItsWorktreeItsGitFolderItsOwnObjectsAndItsOwnRefOnly() throws {
        let world = try world()
        let plan = try plan(world.inputs(.worker))
        let git = world.root + "/.git"
        // Of the repository, it writes exactly these: its own ref folder and its log, never the shared ones.
        let repository = Self.writable(plan).filter { Self.within($0, world.root) }
        #expect(repository == [world.worktree, git + "/worktrees/w1", git + "/refs/heads/agent/w1", git + "/logs/refs/heads/agent/w1"],
                "\(repository)")
        // Elsewhere: its own home (the session's folder), its own objects, its TMPDIR, the slots, the transcripts' folder.
        let elsewhere = Self.writable(plan).subtracting(repository)
        #expect(elsewhere == [world.home, world.box + "/objects", world.temporary, world.slots,
                              world.home + "/.claude/projects/" + ClaudeFiles.projectFolder(cwd: world.worktree)], "\(elsewhere)")
        // Its home is the session's own folder, not the account's.
        #expect(plan.mounts.contains { $0.target == world.home && $0.kind == .readWrite(source: world.box + "/home") })
        #expect(plan.directory == world.worktree && plan.terminal == .foreground && plan.door == SandboxPlanner.door)
    }

    @Test func theBasesRefTheConfigTheHooksAndTheTagsAreReadOnlyToAWorker() throws {
        let world = try world()
        let plan = try plan(world.inputs(.worker))
        let git = world.root + "/.git"
        #expect(Self.readOnly(plan).contains(git))
        // The last mount over each of the base's ref, packed-refs, HEAD, config, hooks, info and the tags is the
        // common folder's, read-only.
        for path in ["refs/heads/main", "packed-refs", "HEAD", "config", "hooks", "hooks/pre-commit", "info", "refs/tags"].map({ git + "/" + $0 }) {
            #expect(Self.over(path, plan)?.kind == .readOnly(source: git), "\(path): \(String(describing: Self.over(path, plan)))")
        }
    }

    @Test func aWorktreesGitFileAndItsFoldersPointersAreReadOnly() throws {
        let world = try world()
        for role in [SandboxRole.worker, .verifier, .branchRun] {
            let plan = try plan(world.inputs(role))
            let ownGit = world.root + "/.git/worktrees/w1"
            // Each is read-only, mounted after the writable folder that holds it, so it covers it.
            for pointer in [world.worktree + "/.git", ownGit + "/commondir", ownGit + "/gitdir"] {
                let index = plan.mounts.lastIndex { $0.target == pointer }
                #expect(index.map { plan.mounts[$0].kind == .readOnly(source: pointer) } == true, "\(role): \(pointer)")
                let holder = plan.mounts.lastIndex { $0.target != pointer && Self.within(pointer, $0.target) }
                #expect((holder ?? -1) < (index ?? -1), "\(role): \(pointer)")
            }
        }
    }

    /// The index of the last mount at `target` of `kind`; nil when there is none.
    static func index(of target: String, _ kind: Platform.Sandbox.Mount.Kind, in plan: Platform.Sandbox.Plan) -> Int? {
        plan.mounts.lastIndex { $0.target == target && $0.kind == kind }
    }

    /// The review of 2026-11-19: with `extensions.worktreeConfig` on, git reads `<own>/config.worktree`, so a worker
    /// that could write it would set a program (core.fsmonitor, core.hooksPath, a filter) for the node's git, which
    /// runs outside on that worktree. Whoever writes its own git folder finds the file read-only there, there or not:
    /// one that isn't there is made empty first (in the folder, as the worktree's git made it), then covered, so it
    /// can't be created either.
    @Test func aWorkerCantWriteItsWorktreesGitConfig() throws {
        let world = try world()
        let own = world.root + "/.git/worktrees/w1"
        let config = own + "/config.worktree"
        for present in [false, true] {
            if present { try "[core]\n\tsparseCheckout = false\n".write(toFile: config, atomically: true, encoding: .utf8) }
            for role in [SandboxRole.worker, .verifier, .branchRun] {
                let plan = try plan(world.inputs(role))
                // What a program in the box finds there is the real file, read-only: never the writable folder's.
                #expect(Self.over(config, plan)?.kind == .readOnly(source: config), "\(role), present \(present): \(String(describing: Self.over(config, plan)))")
                let folder = try #require(Self.index(of: own, .readWrite(source: own), in: plan))
                let cover = try #require(Self.index(of: config, .readOnly(source: config), in: plan))
                #expect(folder < cover, "\(role)")
                // One that isn't there is made between the two, empty; one that is there is never made again.
                let made = Self.index(of: config, .file(contents: Data(), mode: 0o644), in: plan)
                #expect(present ? made == nil : made.map { folder < $0 && $0 < cover } == true, "\(role), present \(present): \(String(describing: made))")
                // Nothing else of the plan writes there.
                #expect(!Self.writable(plan).contains { Self.within($0, config) }, "\(role)")
            }
        }
        // A lead writes no git folder at all, so it has nothing to cover.
        #expect(Self.over(world.root + "/.git/config.worktree", try plan(world.inputs(.lead)))?.kind == .readOnly(source: world.root + "/.git"))
    }

    /// With `extensions.worktreeConfig` on, the worktree's config is covered as it is everywhere, whatever it holds;
    /// and where no cover can be made over it (a link, a folder: a mount covers neither a link nor what git then
    /// reads), the box is refused, the extension on or not.
    @Test func aWorktreeWithWorktreeConfigOnIsCoveredOrRefused() throws {
        let world = try world()
        let config = world.root + "/.git/worktrees/w1/config.worktree"
        for (key, value) in [("core.repositoryFormatVersion", "1"), ("extensions.worktreeConfig", "true")] {
            #expect(Git.run(["config", key, value], in: world.root).ok)
        }
        // Not there yet: covered. Then with what a worker would plant: covered as it is, by the real file.
        #expect(Self.over(config, try plan(world.inputs(.worker)))?.kind == .readOnly(source: config))
        #expect(Git.run(["config", "--worktree", "core.fsmonitor", world.worktree + "/planted"], in: world.worktree).ok)
        #expect(FileManager.default.fileExists(atPath: config))
        for role in [SandboxRole.worker, .verifier, .branchRun] {
            #expect(Self.over(config, try plan(world.inputs(role)))?.kind == .readOnly(source: config), "\(role)")
        }
        // A link (to a file of the worker's own, say) or a folder there: refused, naming it.
        for extension_ in ["true", "false"] {
            #expect(Git.run(["config", "extensions.worktreeConfig", extension_], in: world.root).ok)
            for folder in [false, true] {
                try FileManager.default.removeItem(atPath: config)
                if folder {
                    try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: false)
                } else {
                    try "[core]\n".write(toFile: world.worktree + "/planted.cfg", atomically: true, encoding: .utf8)
                    try FileManager.default.createSymbolicLink(atPath: config, withDestinationPath: world.worktree + "/planted.cfg")
                }
                for role in [SandboxRole.worker, .verifier, .branchRun] {
                    let refused = SandboxPlanner.plan(world.inputs(role))
                    guard case .failure(let refusal) = refused else {
                        Issue.record("\(role), extension \(extension_), folder \(folder): planned")
                        continue
                    }
                    #expect(refusal.value == config && refusal.reason.contains("config.worktree"), "\(refusal)")
                }
            }
        }
    }

    /// The review of 2026-11-19: Claude Code keeps its memory in `projects/<folder>/memory/`, and a later session,
    /// outside any box, loads it as instructions. The transcripts' folder stays the real one, read-write; its
    /// `memory/` is read-only inside, there or not, so no boxed session writes what the user's or the lead's next
    /// session is told.
    @Test func theAgentsMemoryIsntWritableInABox() throws {
        let world = try world()
        try FileManager.default.createDirectory(atPath: world.home + "/.claude/projects/" + ClaudeFiles.projectFolder(cwd: world.root),
                                                withIntermediateDirectories: true)
        let audit = world.root + "/.vibeswitcher/audits/a1"
        #expect(Git.run(["worktree", "add", "-q", "--detach", audit], in: world.root).ok)
        try FileManager.default.createDirectory(atPath: world.home + "/.claude/projects/" + ClaudeFiles.projectFolder(cwd: audit),
                                                withIntermediateDirectories: true)
        for present in [false, true] {
            for (role, directory) in [(SandboxRole.worker, world.worktree), (.verifier, audit), (.lead, world.root)] {
                let transcripts = world.home + "/.claude/projects/" + ClaudeFiles.projectFolder(cwd: directory)
                let memory = transcripts + "/memory"
                if present { try "- [a](a.md)\n".write(toFile: memory + "/MEMORY.md", atomically: true, encoding: .utf8) }
                let plan = try plan(world.inputs(role, worktree: directory))
                for path in [memory, memory + "/MEMORY.md", memory + "/planted.md", memory + "/team/x.md"] {
                    #expect(Self.over(path, plan)?.kind == .readOnly(source: memory), "\(role), present \(present), \(path): \(String(describing: Self.over(path, plan)))")
                }
                // The transcript beside it is still the real folder's, read-write.
                for path in [transcripts + "/0b1c.jsonl", transcripts + "/0b1c/subagents/agent-1.jsonl"] {
                    #expect(Self.over(path, plan)?.kind == .readWrite(source: transcripts), "\(role): \(path)")
                }
                let folder = try #require(Self.index(of: transcripts, .readWrite(source: transcripts), in: plan))
                let cover = try #require(Self.index(of: memory, .readOnly(source: memory), in: plan))
                #expect(folder < cover, "\(role)")
                // One that isn't there is made first (an empty folder, which the cover then hides), so there is
                // something to cover; one that is there is covered as it is.
                let made = Self.index(of: memory, .empty(mode: 0o555), in: plan)
                #expect(present ? made == nil : made.map { folder < $0 && $0 < cover } == true, "\(role), present \(present): \(String(describing: made))")
                #expect(!Self.writable(plan).contains { Self.within($0, memory) }, "\(role)")
                if !present { try FileManager.default.createDirectory(atPath: memory, withIntermediateDirectories: false) }
            }
        }
        // A link there (to a folder of the session's own making, say) or a file: no cover can be made, so no box.
        let memory = world.home + "/.claude/projects/" + ClaudeFiles.projectFolder(cwd: world.worktree) + "/memory"
        for link in [false, true] {
            try FileManager.default.removeItem(atPath: memory)
            if link {
                try FileManager.default.createSymbolicLink(atPath: memory, withDestinationPath: world.worktree)
            } else {
                try "planted".write(toFile: memory, atomically: true, encoding: .utf8)
            }
            guard case .failure(let refusal) = SandboxPlanner.plan(world.inputs(.worker)) else {
                Issue.record("planned over a memory that is \(link ? "a link" : "a file")")
                continue
            }
            #expect(refusal.value == memory && refusal.reason.contains("memory"), "\(refusal)")
        }
        // A branch run has no agent, so no transcripts and no memory at all.
        #expect(!Self.sources(try plan(world.inputs(.branchRun))).contains { Self.within($0, world.home + "/.claude") })
    }

    /// The home's sources a role's plan may name, worked out here from the tables, apart from the planner.
    func named(_ world: World, _ role: SandboxRole, _ policy: SandboxPolicy) -> [String] {
        var named = [world.box, world.temporary, world.runHome, world.build, world.home + "/.vibeswitcher/bin",
                     world.home + "/.local/share/swiftly/bin", world.root] + policy.read + policy.privateFolders
        if role != .lead { named += [world.home + "/.cache/org.swift.swiftpm", world.home + "/.swiftpm"] }
        if role != .branchRun {
            named += [world.agent, world.home + "/.claude/settings.json", world.home + "/.claude/skills",
                      world.home + "/.claude/.credentials.json", world.home + "/.claude/projects"]
        }
        return named
    }

    @Test func nothingOfTheHomeIsASourceThatThePlanDoesntName() throws {
        let world = try world()
        let shared = world.home + "/shared-sdk"
        try FileManager.default.createDirectory(atPath: shared, withIntermediateDirectories: true)
        let cache = world.home + "/.gradle"
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        let policies = [SandboxPolicy.standard, SandboxPolicy(read: [shared]), SandboxPolicy(privateFolders: [cache]),
                        SandboxPolicy(read: [shared], privateFolders: [cache], nesting: true)]
        for role in SandboxRole.allCases {
            for policy in policies {
                let plan = try plan(world.inputs(role, policy: policy))
                for source in Self.sources(plan) where Self.within(source, world.home) {
                    #expect(named(world, role, policy).contains { Self.within(source, $0) }, "\(role) \(policy): \(source)")
                }
                // None of the decoys, whatever the role or the policy.
                for decoy in [".ssh", ".config", ".gnupg", ".vibeswitcher/state", ".vibeswitcher/host.sock", "projects/other"] {
                    #expect(!Self.sources(plan).contains { Self.within($0, world.home + "/" + decoy) }, "\(role): \(decoy)")
                }
                #expect(!Self.sources(plan).contains(world.home), "\(role): the whole home")
            }
        }
    }

    /// A source that holds a hidden place is refused as one under it is: the home, `~/.local` (which holds the
    /// keyrings), `/var` (which holds `/var/run`), the node's folder's parent.
    @Test func aSourceThatHoldsAHiddenFolderIsRefused() throws {
        let world = try world()
        for held in [world.home, world.home + "/.local", "/var", world.home + "/.config/..", world.home + "/projects/.."] {
            var inputs = world.inputs(.worker)
            inputs.policy = SandboxPolicy(read: [SandboxPolicy.lexical(held)])
            #expect(throws: SandboxRefusal.self, "\(held)") { try SandboxPlanner.plan(inputs).get() }
        }
        // A PATH folder that holds one is left out rather than shown.
        var inputs = world.inputs(.worker)
        inputs.pathFolders.append(world.home + "/.local")
        let plan = try SandboxPlanner.plan(inputs).get()
        #expect(!Self.sources(plan).contains(world.home + "/.local"))
    }

    @Test func theNodesFolderIsNeverASourceButForItsBuildAndTheHook() throws {
        let world = try world()
        let node = world.home + "/.vibeswitcher"
        for role in SandboxRole.allCases {
            let plan = try plan(world.inputs(role))
            for source in Self.sources(plan) where Self.within(source, node) {
                #expect(Self.within(source, world.build) || source == node + "/bin" || Self.within(source, world.box), "\(role): \(source)")
            }
        }
        // A PATH folder in the node's state is left out; a project setting there is refused.
        var inputs = world.inputs(.worker)
        inputs.policy = SandboxPolicy(read: [node + "/state"])
        #expect(throws: SandboxRefusal.self) { try SandboxPlanner.plan(inputs).get() }
    }

    @Test func theRuntimeFolderTheJournalInteropAndTheWindowsDrivesAreNeverASource() throws {
        let world = try world()
        for role in SandboxRole.allCases {
            let plan = try plan(world.inputs(role))
            for source in Self.sources(plan) {
                for hidden in ["/run", "/var/run", "/mnt", "/init", "/proc", "/sys", "/dev"] { #expect(!Self.within(source, hidden), "\(role): \(source)") }
            }
            // The PATH's Windows folder is left out, not mounted and not on PATH.
            #expect(!plan.environment.contains { $0.hasPrefix("PATH=") && $0.contains("/mnt/") })
        }
        var inputs = world.inputs(.worker)
        inputs.pathFolders.append("/run/user/1000")
        #expect((try? SandboxPlanner.plan(inputs).get()) != nil)
        inputs.policy = SandboxPolicy(read: ["/run/user/1000/bus"])
        #expect(throws: SandboxRefusal.self) { try SandboxPlanner.plan(inputs).get() }
    }

    @Test func everyUserWritableFolderOnThePathIsReadOnly() throws {
        let world = try world()
        for role in SandboxRole.allCases {
            let plan = try plan(world.inputs(role))
            for folder in [world.build + "/Resources/bin", world.home + "/.local/share/swiftly/bin", world.build + "/bin",
                           world.home + "/.vibeswitcher/bin"] {
                #expect(Self.readOnly(plan).contains(folder), "\(role): \(folder)")
                #expect(!Self.writable(plan).contains { Self.within(folder, $0) && $0 != world.home }, "\(role): \(folder)")
            }
            let path = plan.environment.first { $0.hasPrefix("PATH=") } ?? ""
            #expect(path == "PATH=\(world.build)/Resources/bin:\(world.home)/.local/share/swiftly/bin:/usr/local/bin:/usr/bin:/bin", "\(path)")
            if role != .branchRun { #expect(Self.readOnly(plan).contains(world.agent), "\(role)") }
        }
    }

    @Test func theAgentsConfigIsTheSessionsOwnWithNamedReadOnlyEntries() throws {
        let world = try world()
        let plan = try plan(world.inputs(.worker))
        let config = world.home + "/.claude"
        // The named entries that exist, read-only from the user's; the login read-only; nothing else of the user's.
        let fromConfig = plan.mounts.filter { mount in
            switch mount.kind {
            case .readOnly(let source), .readWrite(let source): return Self.within(source, config)
            default: return false
            }
        }
        #expect(Set(fromConfig.map(\.target)) == [config + "/settings.json", config + "/skills", config + "/.credentials.json",
                                                   config + "/projects/" + ClaudeFiles.projectFolder(cwd: world.worktree)])
        for mount in fromConfig where !mount.target.contains("/projects/") {
            #expect(mount.kind == .readOnly(source: mount.target), "\(mount)")
        }
        // history.jsonl and shell-snapshots stay the session's own: not mounted.
        #expect(!plan.mounts.contains { $0.target.hasSuffix("history.jsonl") || $0.target.hasSuffix("shell-snapshots") })
        #expect(ClaudeFiles.ownEntries.contains("history.jsonl") && ClaudeFiles.ownEntries.contains("shell-snapshots"))
        #expect(Set(ClaudeFiles.readOnlyEntries).isDisjoint(with: ClaudeFiles.ownEntries))
        // The login can be left out (SB-D8's other answer).
        var inputs = world.inputs(.worker)
        inputs.agentLogin = false
        #expect(!(try SandboxPlanner.plan(inputs).get()).mounts.contains { $0.target.hasSuffix(ClaudeFiles.login) })
        // Updates off; the door named; the spawn's environment only through the allow-list.
        let environment = Set(plan.environment)
        #expect(environment.isSuperset(of: ["DISABLE_AUTOUPDATER=1", "VIBESWITCHER_DOOR=\(SandboxPlanner.door)", "HOME=\(world.home)",
                                            "TERM=xterm-256color", "LC_ALL=C", "VIBESWITCHER_SESSION=s1", "VIBESWITCHER_HEAVY_SLOTS=2",
                                            "VIBESWITCHER_ROLE=worker", "TMPDIR=\(world.temporary)"]), "\(environment)")
        #expect(!environment.contains { $0.hasPrefix("AWS_") || $0.hasPrefix("SSH_AUTH_SOCK") || $0 == "HOME=/somewhere/else" }, "\(environment)")
    }

    @Test func theSeededConfigHasThisFoldersEntryAndNoToolServers() throws {
        let world = try world()
        let plan = try plan(world.inputs(.worker))
        let seeded = try #require(plan.mounts.first { $0.target == world.home + "/.claude.json" })
        guard case .file(let contents, let mode) = seeded.kind else {
            Issue.record("not a file: \(seeded)")
            return
        }
        #expect(mode == 0o600)
        let object = try #require(try JSONSerialization.jsonObject(with: contents) as? [String: Any])
        #expect(object["userID"] as? String == "u")
        #expect(object["mcpServers"] == nil)
        #expect(Set(object.keys) == ["userID", "projects"], "\(object.keys)")
        let projects = try #require(object["projects"] as? [String: Any])
        #expect(Array(projects.keys) == [world.worktree])
        let entry = try #require(projects[world.worktree] as? [String: Any])
        #expect(entry["hasTrustDialogAccepted"] as? Bool == true)
        // Not JSON: this folder's entry alone.
        let fallback = try #require(try JSONSerialization.jsonObject(with: ClaudeFiles.seededConfig(from: Data("not json".utf8), cwd: "/w", login: true)) as? [String: Any])
        #expect(Array(fallback.keys) == ["projects"])
        #expect(ClaudeFiles.projectFolder(cwd: "/scratch/vs-test.IJGOvE/sb0-D91C5045/work_tree") == "-scratch-vs-test-IJGOvE-sb0-D91C5045-work-tree")
    }

    /// The box's `.claude.json` is an allow-list of the account's: a key nobody named, a key or token, a value of
    /// another kind, never reach it; the account's description only with the login, and only its named fields.
    @Test func theSeededConfigTakesOnlyWhatItsAllowListNames() throws {
        let given = Data("""
            {"userID": "u1", "hasCompletedOnboarding": true, "lastOnboardingVersion": "2.1.326", "migrationVersion": 11,
             "installMethod": ["not", "text"], "hasSeenAutoDefaultNotice": "yes", "numStartups": 1,
             "primaryApiKey": "decoy-primary-api-key", "customApiKeyResponses": {"approved": ["decoy-key-tail"]},
             "aFutureKey": {"anything": "decoy-future"}, "projects": {"/other": {"hasTrustDialogAccepted": true}},
             "mcpServers": {"s": {"command": "x", "env": {"TOKEN": "decoy-server-token"}}},
             "oauthAccount": {"accountUuid": "a1", "emailAddress": "t@t", "accessToken": "decoy-access-token",
                              "refreshToken": "decoy-refresh-token", "organizationUuid": "o1"}}
            """.utf8)
        let decoys = ["decoy-primary-api-key", "decoy-key-tail", "decoy-future", "decoy-server-token", "decoy-access-token",
                      "decoy-refresh-token", "aFutureKey", "primaryApiKey", "customApiKeyResponses", "numStartups", "/other"]
        for login in [true, false] {
            let seeded = ClaudeFiles.seededConfig(from: given, cwd: "/w", login: login)
            let text = String(decoding: seeded, as: UTF8.self)
            for decoy in decoys { #expect(!text.contains(decoy), "login \(login): \(decoy) in \(text)") }
            let object = try #require(try JSONSerialization.jsonObject(with: seeded) as? [String: Any])
            let expected: Set<String> = ["userID", "hasCompletedOnboarding", "lastOnboardingVersion", "migrationVersion", "projects"]
            #expect(Set(object.keys) == (login ? expected.union(["oauthAccount"]) : expected), "login \(login): \(object.keys)")
            #expect(object["hasCompletedOnboarding"] as? Bool == true && object["migrationVersion"] as? Int == 11)
            if login {
                let account = try #require(object["oauthAccount"] as? [String: Any])
                #expect(Set(account.keys) == ["accountUuid", "emailAddress", "organizationUuid"], "\(account.keys)")
            } else {
                #expect(!text.contains("t@t") && !text.contains("a1"), "\(text)")
            }
        }
        // The planner passes the login's answer on: with no login, no account in the box's copy.
        let world = try world()
        var inputs = world.inputs(.worker)
        inputs.agentConfig = given
        inputs.agentLogin = false
        let seeded = try #require(try plan(inputs).mounts.first { $0.target == world.home + "/.claude.json" })
        guard case .file(let contents, _) = seeded.kind else { return }
        #expect(!String(decoding: contents, as: UTF8.self).contains("oauthAccount"))
    }

    /// A worker's git writes its own ref folder and its own objects: another agent's ref, a new ref beside them, the
    /// shared objects and their packs are read-only to it. Its git is told where its objects go and where the shared
    /// ones are (alternates). A branch that isn't in a ref folder of its own refuses the box.
    @Test func aWorkerCantCreateOrMoveAnotherAgentsRef() throws {
        let world = try world()
        let plan = try plan(world.inputs(.worker))
        let git = world.root + "/.git"
        for path in ["refs/heads/agent/w2/head", "refs/heads/agent/w3", "refs/heads/agent/w2", "refs/heads/main", "logs/refs/heads/agent/w2/head",
                     "objects/ab/cdef", "objects/pack", "objects/info/alternates", "packed-refs"].map({ git + "/" + $0 }) {
            #expect(Self.over(path, plan)?.kind == .readOnly(source: git), "\(path): \(String(describing: Self.over(path, plan)))")
        }
        #expect(Self.over(git + "/refs/heads/agent/w1/head", plan)?.kind == .readWrite(source: git + "/refs/heads/agent/w1"))
        #expect(plan.environment.contains("GIT_OBJECT_DIRECTORY=\(world.box)/objects"))
        #expect(plan.environment.contains("GIT_ALTERNATE_OBJECT_DIRECTORIES=\(git)/objects"))
        #expect(SandboxPlanner.folders(for: plan, inputs: world.inputs(.worker)).contains(world.box + "/objects"))
        // Today's names (`agent/<slug>`, a ref beside every other worker's) refuse a worker's box.
        #expect(Git.run(["checkout", "-q", "-b", "agent/w1-flat"], in: world.worktree).ok)
        let refused = SandboxPlanner.plan(world.inputs(.worker))
        guard case .failure(let refusal) = refused else {
            Issue.record("planned: \(refused)")
            return
        }
        #expect(refusal.reason.contains("agent/w1/<name>"), "\(refusal)")
        // A verifier and a branch run write no ref and no object at all.
        for role in [SandboxRole.verifier, .branchRun] {
            let other = try SandboxPlanner.plan(world.inputs(role)).get()
            #expect(!Self.writable(other).contains { Self.within($0, git + "/refs") || Self.within($0, git + "/objects") }, "\(role)")
        }
    }

    /// The two lanes' seam: the door the planner gives a box is the one the relays look for and the porter answers
    /// (`DoorProtocol`), and a role gets a door exactly when the porter has helpers for it.
    @Test func everyRoleWithADoorHasHelpersAndABranchRunHasNone() throws {
        let world = try world()
        for role in SandboxRole.allCases {
            let plan = try plan(world.inputs(role))
            let helpers = Porter.modes[role.rawValue]
            if role == .branchRun {
                #expect(plan.door == nil && helpers == nil)
                #expect(Porter.allowed(.init(mode: .mcp, args: []), for: SessionHelper(role: role.rawValue, root: world.root, task: "t1")) != nil)
            } else {
                #expect(plan.door == DoorProtocol.path)
                #expect(plan.environment.contains("\(DoorProtocol.variable)=\(DoorProtocol.path)"))
                // The folder the door is bound in is the box's own, and only its user's.
                #expect(plan.mounts.contains { $0.target == (DoorProtocol.path as NSString).deletingLastPathComponent && $0.kind == .empty(mode: 0o700) })
                #expect(helpers?.contains(.mcp) == true && helpers?.contains(.hook) == true, "\(role)")
            }
        }
        // And no role the porter serves is one the planner doesn't know.
        #expect(Set(Porter.modes.keys).isSubset(of: Set(SandboxRole.allCases.map(\.rawValue))))
    }

    @Test func aBranchRunHasNoDoorNoTerminalNoAgentAndNoNetwork() throws {
        let world = try world()
        let plan = try plan(world.inputs(.branchRun))
        #expect(plan.door == nil && plan.terminal == .none && plan.network == .none)
        #expect(!plan.mounts.contains { $0.target == SandboxPlanner.doorFolder })
        #expect(!Self.sources(plan).contains { Self.within($0, world.home + "/.claude") || $0 == world.agent })
        #expect(!Self.writable(plan).contains(world.slots))
        #expect(!plan.environment.contains { $0.hasPrefix("VIBESWITCHER_DOOR=") })
        // Its home is the run's scratch home, as it is: no session folder.
        #expect(plan.mounts.contains { $0.target == world.runHome && $0.kind == .readWrite(source: world.runHome) })
        #expect(!plan.mounts.contains { $0.target == world.home })
        // A proxied network stays proxied (slice 2); the machine's never reaches a branch run.
        var proxied = world.inputs(.branchRun)
        proxied.network = .proxied(port: 3128)
        #expect(try SandboxPlanner.plan(proxied).get().network == .proxied(port: 3128))
    }

    @Test func aLeadReadsItsCheckoutPrivatelyAndWritesNoWorktree() throws {
        let world = try world()
        let plan = try plan(world.inputs(.lead))
        #expect(Self.layered(plan).contains(world.root))
        #expect(Self.readOnly(plan).isSuperset(of: [world.root + "/.git", world.root + "/.vibeswitcher"]))
        #expect(!Self.writable(plan).contains { Self.within($0, world.root) }, "\(Self.writable(plan))")
        #expect(plan.directory == world.root)
        // Its layer is in the session's own folder, and its package caches aren't shown.
        let layer = try #require(plan.mounts.first { $0.target == world.root })
        guard case .overlay(_, let upper, let work) = layer.kind else { return }
        #expect(Self.within(upper, world.box) && Self.within(work, world.box))
        #expect(SandboxPlanner.folders(for: plan, inputs: world.inputs(.lead)).contains(upper))
        #expect(!Self.layered(plan).contains(world.home + "/.cache/org.swift.swiftpm"))
    }

    @Test func aVerifierIsNeverGivenTheWorkersWorktree() throws {
        let world = try world()
        let audit = world.root + "/.vibeswitcher/audits/a1"
        #expect(Git.run(["worktree", "add", "-q", "--detach", audit], in: world.root).ok)
        let plan = try plan(world.inputs(.verifier, worktree: audit))
        #expect(!Self.sources(plan).contains { Self.within($0, world.worktree) || Self.within($0, world.root + "/.git/worktrees/w1") })
        #expect(Self.writable(plan).contains(audit) && Self.writable(plan).contains(world.root + "/.git/worktrees/a1"))
        // A verifier writes its own git folder alone: not the objects, not the agent refs.
        #expect(!Self.writable(plan).contains(world.root + "/.git/objects"))
        #expect(!Self.writable(plan).contains(world.root + "/.git/refs/heads/agent"))
    }

    @Test func aWorktreeWhoseGitFileLeavesItsRepositoryIsRefused() throws {
        let world = try world()
        let rogue = world.home + "/rogue"
        try FileManager.default.createDirectory(atPath: rogue + "/gitdir", withIntermediateDirectories: true)
        // A .git file aiming at a folder of the worker's own making.
        try "gitdir: \(rogue)/gitdir\n".write(toFile: world.worktree + "/.git", atomically: true, encoding: .utf8)
        #expect(throws: SandboxRefusal.self) { try SandboxPlanner.plan(world.inputs(.worker)).get() }
        // One aiming at another repository's worktree folder.
        #expect(Git.run(["commit", "-q", "--allow-empty", "-m", "x"], in: world.other).ok)
        #expect(Git.run(["worktree", "add", "-q", "-b", "agent/x", world.other + "/wt"], in: world.other).ok)
        try "gitdir: \(world.other)/.git/worktrees/wt\n".write(toFile: world.worktree + "/.git", atomically: true, encoding: .utf8)
        let refused = SandboxPlanner.plan(world.inputs(.worker))
        guard case .failure(let refusal) = refused else {
            Issue.record("planned: \(refused)")
            return
        }
        #expect(refusal.reason.contains("worktree"), "\(refusal)")
        // A .git that is a link.
        try FileManager.default.removeItem(atPath: world.worktree + "/.git")
        try FileManager.default.createSymbolicLink(atPath: world.worktree + "/.git", withDestinationPath: world.root + "/.git")
        #expect(throws: SandboxRefusal.self) { try SandboxPlanner.plan(world.inputs(.worker)).get() }
    }

    @Test func theSameInputsGiveTheSamePlan() throws {
        let world = try world()
        for role in SandboxRole.allCases {
            let first = try plan(world.inputs(role, policy: SandboxPolicy(nesting: true)))
            let second = try plan(world.inputs(role, policy: SandboxPolicy(nesting: true)))
            #expect(first == second, "\(role)")
            #expect(first.nesting)
        }
    }
}
