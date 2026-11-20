import Foundation
import Testing
@testable import VibeCore

/// A branch run's launcher (the session sandbox plan's SB6), without a kernel: what `BranchCode.wrapper` is wrapped in,
/// where it is left as it is, and the plan a launcher makes from its request. The runs themselves, in real boxes, are
/// `BranchRunHostTests` (VibeNodeTests).
struct BranchRunTests {
    private let scratch = Scratch()

    static let able = Platform.Sandbox.Facts(userNamespaces: true, overlay: true, landlockABI: 0, vsock: false, why: nil)
    static let unable = Platform.Sandbox.Facts(userNamespaces: false, overlay: true, landlockABI: 0, vsock: false,
                                               why: "AppArmor refuses unprivileged user namespaces")
    static let server = "/node/builds/abc/bin/vibeswitcher-mcp"

    /// A command under the wrapper, as `Shell.run(branchCode:)` and a verifier's prefix make it.
    static func wrapped(_ words: [String] = ["/bin/sh", "-c", "swift test"]) -> [String] { BranchCode.wrapper + words }

    /// An account's home shaped like a node's, in scratch: a key, a package cache, the node's folder with a merge's
    /// scratch worktree and home in it (`LeadVault.scratch`), and the project, whose git folder knows the worktree.
    /// Git's pointer files are written by hand: nothing here runs git.
    struct Layout {
        let account: String
        let root: String
        let worktree: String
        let home: String
        /// The folder the scratch worktree and home are in.
        let area: String

        init(_ scratch: Scratch, name: String = "merge-add-b") throws {
            let files = FileManager.default
            let made = scratch.url("account")
            try files.createDirectory(at: made, withIntermediateDirectories: true)
            account = SandboxPolicy.resolved(made.path)
            root = account + "/projects/app"
            area = account + "/.vibeswitcher/lead/scratch/0123456789abcdef0123"
            worktree = area + "/" + name
            home = worktree + "-home"
            let own = root + "/.git/worktrees/" + name
            for folder in [account + "/.ssh", account + "/.cache/org.swift.swiftpm", worktree + "/Sources", BranchRun.temporary(in: home), own] {
                try files.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
            // The folders a run's home and layers go in are their user's alone, as the vault makes its scratch space.
            for folder in [account, area, home] { chmod(folder, 0o700) }
            try "a key\n".write(toFile: account + "/.ssh/id_ed25519", atomically: true, encoding: .utf8)
            try "gitdir: \(own)\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
            try "../..\n".write(toFile: own + "/commondir", atomically: true, encoding: .utf8)
            try "\(worktree)/.git\n".write(toFile: own + "/gitdir", atomically: true, encoding: .utf8)
            try "0000000000000000000000000000000000000000\n".write(toFile: own + "/HEAD", atomically: true, encoding: .utf8)
        }

        func request(cwd: String? = nil, home: String? = nil, policy: SandboxPolicy = .standard) -> BranchRun.Request {
            BranchRun.Request(cwd: cwd ?? worktree, home: home ?? self.home, accountHome: account, policy: policy,
                              wrapped: BranchRunTests.wrapped())
        }

        /// Planned as the launcher plans it, the account's home standing for the real one too.
        func plan(_ request: BranchRun.Request, environment: [String: String] = [:]) -> Result<BranchRun.Planned, SandboxRefusal> {
            BranchRun.plan(request, environment: environment, image: BranchRunTests.server, realHome: account, run: "77-run")
        }
    }

    static func sources(_ plan: Platform.Sandbox.Plan) -> [String] {
        plan.mounts.flatMap { mount -> [String] in
            switch mount.kind {
            case .readOnly(let source), .readWrite(let source): return [source]
            case .overlay(let lower, let upper, let work): return [lower, upper, work]
            default: return []
            }
        }
    }

    @Test func aBranchRunsCommandGoesThroughTheLauncher() throws {
        // What is started is the launcher (the tool server's image), with the request in fixed places and the wrapped
        // command after it, word for word: a word of the command that looks like an option is still the command's.
        let policy = SandboxPolicy(read: ["/opt/sdk"], nesting: true)
        for words in [["/bin/sh", "-c", "swift test"], ["/bin/sh", "-c", "--", BranchRun.flag, "", "a b\n'c'"]] {
            let wrapped = Self.wrapped(words)
            let made = BranchRun.command(wrapped, cwd: "/w/tree", home: "/s/home", policy: policy, server: Self.server, facts: Self.able,
                                         accountHome: "/home/u", onTheMac: false)
            #expect(made.executable == Self.server)
            #expect(Array(made.arguments.prefix(2)) == [Self.server, BranchRun.flag])
            #expect(Array(made.arguments.suffix(wrapped.count)) == wrapped)
            #expect(made.keep == [])
            #expect(BranchRun.Request(arguments: made.arguments)
                == BranchRun.Request(cwd: "/w/tree", home: "/s/home", accountHome: "/home/u", policy: policy, wrapped: wrapped))
            // The wrapper is what runs inside: the host still knows what is under it (`BranchCode.isRunner`).
            #expect(BranchRun.Request(arguments: made.arguments).map { BranchCode.isRunner($0.wrapped) } == true)
        }

        // The hook: a process told its launcher wraps what it runs as branch code, in the run's scratch home.
        let layout = try Layout(scratch)
        let wrapped = Self.wrapped()
        let scope = BranchRun.Scope(launcher: Self.server, accountHome: layout.account)
        let hooked = BranchRun.with(scope) {
            BranchRun.launching(wrapped, in: layout.worktree, environment: ["CFFIXED_USER_HOME": layout.home, "TMPDIR": BranchRun.temporary(in: layout.home) + "/"],
                                facts: Self.able, onTheMac: false)
        }
        #expect(BranchRun.Request(arguments: hooked) == layout.request())
        #expect(hooked.first == Self.server)
        // A verifier's command has the account's home: its run's home is a folder of its own in the session's TMPDIR.
        let verifiers = BranchRun.with(scope) {
            BranchRun.launching(wrapped, in: layout.worktree, environment: ["HOME": layout.account, "CFFIXED_USER_HOME": layout.account,
                                                                            "TMPDIR": layout.area + "/session/"],
                                facts: Self.able, onTheMac: false)
        }
        #expect(BranchRun.Request(arguments: verifiers)?.home == layout.area + "/session/" + BranchRun.verifierHome)
        // A process that isn't the tool server, and was told no launcher, has none to start: the wrapper as it is.
        #expect(BranchRun.launching(wrapped, in: layout.worktree, environment: ["CFFIXED_USER_HOME": layout.home], facts: Self.able,
                                    onTheMac: false) == wrapped)

        // The plan the launcher makes: a branch run's, over the run's scratch worktree and home and nothing else of the
        // account's home.
        let lock = layout.area + "/slots/test-build.lock"
        let planned = try layout.plan(layout.request(cwd: layout.worktree + "/Sources"),
                                      environment: ["PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "SSH_AUTH_SOCK": "/run/user/1000/agent",
                                                    "HOME": layout.account, DoorProtocol.variable: "/run/vibeswitcher/door",
                                                    DoorProtocol.connectorVariable: "7", "SECRET_TOKEN": "x",
                                                    TestLock.heldVariable: lock, TestLock.coresVariable: "6",
                                                    TestLock.directoryVariable: layout.area + "/slots"]).get()
        let plan = planned.plan
        #expect(plan.network == .none && plan.door == nil && plan.terminal == .none && plan.nesting == false)
        #expect(plan.directory == layout.worktree + "/Sources")
        let own = layout.root + "/.git/worktrees/merge-add-b"
        #expect(plan.mounts.contains(.init(layout.worktree, .readWrite(source: layout.worktree))))
        #expect(plan.mounts.contains(.init(layout.home, .readWrite(source: layout.home))))
        #expect(plan.mounts.contains(.init(layout.root + "/.git", .readOnly(source: layout.root + "/.git"))))
        #expect(plan.mounts.contains(.init(own, .readWrite(source: own))))
        #expect(plan.mounts.contains(.init(layout.worktree + "/.git", .readOnly(source: layout.worktree + "/.git"))))
        // No door, no node's folder, no key, no checkout: only what the plan names is a source.
        #expect(!plan.mounts.contains { $0.target == SandboxPlanner.doorFolder || $0.target == SandboxPlanner.door })
        let sources = Self.sources(plan)
        #expect(!sources.contains { $0.hasPrefix(layout.account + "/.ssh") })
        #expect(!sources.contains(layout.root) && !sources.contains(layout.account))
        let node = layout.account + "/.vibeswitcher"
        #expect(sources.filter { $0 == node || $0.hasPrefix(node + "/") }.allSatisfy { $0.hasPrefix(layout.area + "/") },
                "\(sources)")
        // The package cache through a layer of the run's own, beside its home and never in it: a caller removes the
        // home when the run is over, and a layer's work folder is the kernel's to leave behind.
        let layers = layout.area + "/.branch-runs/77-run"
        #expect(planned.layers == layers)
        let cache = layout.account + "/.cache/org.swift.swiftpm"
        #expect(plan.mounts.contains(.init(cache, .overlay(lower: cache, upper: layers + "/layers/0/upper", work: layers + "/layers/0/work"))))
        #expect(planned.folders.contains(layers + "/layers/0/upper") && planned.folders.contains(layers + "/layers/0/work"))
        #expect(planned.folders.contains(BranchRun.temporary(in: layout.home)))
        #expect(!sources.contains { $0.hasPrefix(layout.home + "/") && $0 != BranchRun.temporary(in: layout.home) })
        // Its environment: the plan's own, the names a box passes on, and the slot its run holds. Nothing else.
        let environment = Dictionary(uniqueKeysWithValues: plan.environment.compactMap { entry -> (String, String)? in
            guard let equals = entry.firstIndex(of: "=") else { return nil }
            return (String(entry[..<equals]), String(entry[entry.index(after: equals)...]))
        })
        #expect(environment["HOME"] == layout.home && environment["CFFIXED_USER_HOME"] == layout.home)
        #expect(environment["TMPDIR"] == BranchRun.temporary(in: layout.home))
        #expect(environment["VIBESWITCHER_ROLE"] == SandboxRole.branchRun.rawValue)
        #expect(environment[TestLock.heldVariable] == lock && environment[TestLock.coresVariable] == "6")
        #expect(environment[TestLock.directoryVariable] == layout.area + "/slots")
        #expect(environment["LANG"] == "C.UTF-8")
        for name in ["SSH_AUTH_SOCK", "SECRET_TOKEN", DoorProtocol.variable, DoorProtocol.connectorVariable, DoorProtocol.hostSocketVariable] {
            #expect(environment[name] == nil, "\(name) reached a branch run")
        }
    }

    @Test func whereNoBoxCanBeBuiltTheWrapperIsTodays() throws {
        let wrapped = Self.wrapped()
        let made = BranchRun.command(wrapped, cwd: "/w/tree", home: "/s/home", policy: .standard, server: Self.server, facts: Self.unable,
                                     accountHome: "/home/u", onTheMac: false)
        #expect(made.executable == wrapped[0] && made.arguments == wrapped && made.keep == [])
        let layout = try Layout(scratch)
        let scope = BranchRun.Scope(launcher: Self.server, accountHome: layout.account)
        let hooked = BranchRun.with(scope) {
            BranchRun.launching(wrapped, in: layout.worktree, environment: ["CFFIXED_USER_HOME": layout.home], facts: Self.unable, onTheMac: false)
        }
        #expect(hooked == wrapped)

        // Only there. Where a box can be built, a run that can't have one has no command at all: the launcher is what
        // starts, and it refuses, naming why. None of these gives the wrapper back.
        let able = BranchRun.command(wrapped, cwd: "/nowhere", home: "/home/u", policy: .standard, server: Self.server, facts: Self.able,
                                     accountHome: "/home/u", onTheMac: false)
        #expect(able.executable == Self.server && able.arguments != wrapped)
        // The account's own home as the run's.
        #expect(throws: SandboxRefusal.self) { try layout.plan(layout.request(home: layout.account)).get() }
        // A folder in no worktree (the project's inventory script's), and the main checkout itself.
        let plain = layout.area + "/inventory/tree"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        #expect(throws: SandboxRefusal.self) { try layout.plan(layout.request(cwd: plain)).get() }
        #expect(throws: SandboxRefusal.self) { try layout.plan(layout.request(cwd: layout.root)).get() }
        // A home in a place no box shows.
        #expect(throws: SandboxRefusal.self) { try layout.plan(layout.request(home: layout.account + "/.ssh/home")).get() }
        // A home straight in the node's folder, or anywhere in it but the vault's scratch space for a project: the
        // node's folder isn't a run's own, whatever is beside the home.
        for inNode in [layout.account + "/.vibeswitcher/a-home", layout.account + "/.vibeswitcher/lead/a-home",
                       layout.account + "/.vibeswitcher/v2/boxes/x/a-home"] {
            try FileManager.default.createDirectory(atPath: BranchRun.temporary(in: inNode), withIntermediateDirectories: true)
            chmod((inNode as NSString).deletingLastPathComponent, 0o700)
            #expect(throws: SandboxRefusal.self) { try layout.plan(layout.request(home: inNode)).get() }
        }
        // A home in a folder others can write (a shared temporary folder as TMPDIR), or one that is a link.
        let shared = layout.account + "/shared"
        try FileManager.default.createDirectory(atPath: shared, withIntermediateDirectories: true)
        chmod(shared, 0o1777)
        #expect(throws: SandboxRefusal.self) { try layout.plan(layout.request(home: shared + "/" + BranchRun.verifierHome)).get() }
        try FileManager.default.createSymbolicLink(atPath: layout.area + "/linked-home", withDestinationPath: layout.home)
        #expect(BranchRun.isOwnFolder(layout.area) && !BranchRun.isOwnFolder(shared) && !BranchRun.isOwnFolder(layout.area + "/linked-home"))
        // A worktree in the node's folder with its home somewhere else: the worktree isn't the run's own to show.
        let elsewhere = layout.account + "/elsewhere-home"
        try FileManager.default.createDirectory(atPath: BranchRun.temporary(in: elsewhere), withIntermediateDirectories: true)
        #expect(throws: SandboxRefusal.self) { try layout.plan(layout.request(home: elsewhere)).get() }
        // A project's path the real account hides, whatever home the request names.
        let moved = BranchRun.plan(layout.request(policy: SandboxPolicy(read: [layout.account + "/.ssh"])), environment: [:],
                                   image: Self.server, realHome: layout.account, run: "77-run")
        #expect(throws: SandboxRefusal.self) { try moved.get() }
        // A launcher started with another home than the account's still shows nothing the account hides: a PATH folder
        // there is left out (as the planner leaves one out), and anything else there refuses the plan.
        var other = layout.request()
        other.accountHome = layout.account + "/projects"
        let judged = try BranchRun.plan(other, environment: ["PATH": layout.account + "/.ssh:/usr/bin"], image: Self.server,
                                        realHome: layout.account, run: "77-run").get()
        #expect(!Self.sources(judged.plan).contains { $0.hasPrefix(layout.account + "/.ssh") })
        other.policy = SandboxPolicy(read: [layout.account + "/.ssh"])
        let hidden = BranchRun.plan(other, environment: [:], image: Self.server, realHome: layout.account, run: "77-run")
        #expect(throws: SandboxRefusal.self) { try hidden.get() }
        // A launcher whose own executable is no file at a path (started from a sealed copy) knows no build folder:
        // never `/`, which would make the whole node's folder its build's. Another build's folder on its PATH is left out.
        let sealed = "/memfd:vibeswitcher-mcp (deleted)"
        #expect(BranchRun.build(sealed) == BranchRun.build(nil) && BranchRun.build(nil).hasPrefix("/nonexistent/"))
        #expect(BranchRun.build("/vibeswitcher-mcp") == BranchRun.build(nil) && BranchRun.build("/bin/sh") != "/")
        let tools = layout.account + "/.vibeswitcher/v2/builds/other/Resources/bin"
        try FileManager.default.createDirectory(atPath: tools, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(toFile: layout.account + "/.vibeswitcher/v2/builds/other/Resources/bin/tool", atomically: true, encoding: .utf8)
        let unsealed = try BranchRun.plan(layout.request(), environment: ["PATH": tools + ":/usr/bin"], image: sealed,
                                          realHome: layout.account, run: "77-run").get()
        #expect(!Self.sources(unsealed.plan).contains { $0.hasPrefix(layout.account + "/.vibeswitcher/v2") })
        // Its own build's is shown, read-only.
        let own = try BranchRun.plan(layout.request(), environment: ["PATH": tools + ":/usr/bin"],
                                     image: layout.account + "/.vibeswitcher/v2/builds/other/Resources/bin/tool",
                                     realHome: layout.account, run: "77-run").get()
        #expect(own.plan.mounts.contains(.init(tools, .readOnly(source: tools))))
        // A request that isn't whole is none: the launcher starts nothing from it.
        #expect(BranchRun.Request(arguments: [Self.server, BranchRun.flag]) == nil)
        #expect(BranchRun.Request(arguments: [Self.server, BranchRun.flag, "/w", "/h", "/a", "{}"]) == nil)
        #expect(BranchRun.Request(arguments: [Self.server, BranchRun.flag, "/w", "/h", "/a", "not json", "/bin/true"]) == nil)
        #expect(BranchRun.Request(arguments: [Self.server, "--role", "/w", "/h", "/a", "{}", "/bin/true"]) == nil)
    }

    @Test func onTheMacBranchCodeRunsAsBefore() async throws {
        let wrapped = Self.wrapped()
        // Whatever the facts say, the Mac's command is the wrapper, and its hook starts no launcher.
        for facts in [Self.able, Self.unable] {
            let made = BranchRun.command(wrapped, cwd: "/w/tree", home: "/s/home", policy: .standard, server: Self.server, facts: facts,
                                         accountHome: "/Users/u", onTheMac: true)
            #expect(made.executable == wrapped[0] && made.arguments == wrapped && made.keep == [])
            let scope = BranchRun.Scope(launcher: Self.server, accountHome: "/Users/u")
            let hooked = BranchRun.with(scope) {
                BranchRun.launching(wrapped, in: "/w/tree", environment: ["CFFIXED_USER_HOME": "/s/home"], facts: facts, onTheMac: true)
            }
            #expect(hooked == wrapped)
        }
        if Platform.CodeIdentity.isAvailable {
            // The Mac itself: no box can be built there, and the public form says the same.
            #expect(Platform.Sandbox.probe().why != nil)
            let made = BranchRun.command(wrapped, cwd: "/w/tree", home: "/s/home", policy: .standard, server: Self.server, facts: Self.able)
            #expect(made.executable == wrapped[0] && made.arguments == wrapped && made.keep == [])
        }
        // And a run in this process, which is no tool server, is under the wrapper, as it always was: its parent is
        // the wrapper, known by its arguments.
        let folder = scratch.url("mac")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let run = await offPool {
            Shell.run(executable: "/bin/sh", args: ["-c", "ps -o args= -p $PPID"], in: folder.path, timeout: 60, branchCode: true)
        }
        #expect(run.ok && run.output.contains("vibeswitcher-branch-code"), "\(run.output) \(run.error)")
        #expect(!run.output.contains(BranchRun.flag))
    }

    /// The project's `sandbox: off`, accepted: where a box could be built, the wrapper runs plain (as before SB6),
    /// saying so first, and is still known for the wrapper's; elsewhere it is as it always was.
    @Test func withSandboxOffTheWrapperRunsPlainSayingSoFirst() throws {
        let notice = "vibeswitcher: this branch run is in no box: the project's workflow.md says sandbox: off, as the user accepted it."
        let wrapped = Self.wrapped()
        let off = SandboxPolicy(enabled: false)
        let made = BranchRun.command(wrapped, cwd: "/w/tree", home: "/s/home", policy: off, server: Self.server, facts: Self.able,
                                     accountHome: "/home/u", onTheMac: false)
        #expect(made.executable != Self.server && !made.arguments.contains(BranchRun.flag), "\(made.arguments)")
        #expect(BranchCode.isRunner(made.arguments) && made.executable == made.arguments.first)
        #expect(made.arguments.contains(notice) && Array(made.arguments.suffix(3)) == Array(wrapped.suffix(3)), "\(made.arguments)")
        // What it runs: the notice on stderr, then the command, which has its arguments as they were.
        let folder = scratch.url("off")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let echoed = BranchRun.command(Self.wrapped(["/bin/sh", "-c", "echo \"ran $1\"", "sh", "a b"]), cwd: folder.path, home: "/s/home", policy: off,
                                       server: Self.server, facts: Self.able, accountHome: "/home/u", onTheMac: false)
        let run = Shell.run(executable: echoed.executable, args: Array(echoed.arguments.dropFirst()), in: folder.path, timeout: 60, interleaved: true)
        #expect(run.ok && run.output == notice + "\nran a b", "\(run.output)")
        // No box to be had, or the Mac: as always.
        for (facts, mac) in [(Self.unable, false), (Self.able, true)] {
            let plain = BranchRun.command(wrapped, cwd: "/w/tree", home: "/s/home", policy: off, server: Self.server, facts: facts,
                                          accountHome: "/home/u", onTheMac: mac)
            #expect(plain.arguments == wrapped)
        }
    }

    /// The project's `sandbox_env` (`SandboxPolicy.environment`, `path`): a run is told its variables and has its
    /// folders first on its PATH, shown read-only; nothing else the launcher has passes.
    @Test func aRunIsGivenTheVariablesAndPathItsSettingsNameAndNothingWider() throws {
        let layout = try Layout(scratch)
        let tool = layout.account + "/tools/made-up"
        for folder in ["bin", "share"] { try FileManager.default.createDirectory(atPath: tool + "/" + folder, withIntermediateDirectories: true) }
        let outside = ["PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "MADE_UP_TOKEN": "x", "XDG_CONFIG_HOME": layout.account + "/.config"]
        func planned(_ policy: SandboxPolicy) throws -> (environment: [String: String], plan: Platform.Sandbox.Plan) {
            let plan = try layout.plan(layout.request(policy: policy), environment: outside).get().plan
            return (Dictionary(uniqueKeysWithValues: plan.environment.compactMap { entry -> (String, String)? in
                guard let equals = entry.firstIndex(of: "=") else { return nil }
                return (String(entry[..<equals]), String(entry[entry.index(after: equals)...]))
            }), plan)
        }
        let given = try planned(SandboxPolicy(read: [tool], environment: ["MADE_UP_HOME": tool], path: [tool + "/bin"]))
        let standard = try planned(.standard)
        #expect(given.environment["MADE_UP_HOME"] == tool, "\(given.environment)")
        #expect(given.environment["PATH"]?.hasPrefix(tool + "/bin:") == true, "\(given.environment)")
        #expect(given.plan.mounts.contains(.init(tool + "/bin", .readOnly(source: tool + "/bin"))))
        // Nothing wider: only the name it gives is new, and the launcher's own others don't pass.
        #expect(Set(given.environment.keys).subtracting(standard.environment.keys) == ["MADE_UP_HOME"], "\(given.environment)")
        for name in ["MADE_UP_TOKEN", "XDG_CONFIG_HOME"] { #expect(given.environment[name] == nil, "\(name) reached a branch run") }
        #expect(standard.environment["PATH"]?.contains(tool) == false)

        // Unboxed, the same for a run this thread starts: its variables, and its folders first on the PATH given.
        let scope = BranchRun.Scope(policy: SandboxPolicy(environment: ["MADE_UP_HOME": tool], path: [tool + "/bin"]))
        let told = BranchRun.with(scope) { BranchRun.tools(["TMPDIR": "/t/"], inherited: ["PATH": "/usr/bin"]) }
        #expect(told == ["TMPDIR": "/t/", "MADE_UP_HOME": tool, "PATH": tool + "/bin:/usr/bin"])
        #expect(BranchRun.tools(["TMPDIR": "/t/"]) == ["TMPDIR": "/t/"])
    }

    /// What an ended run's layers left (a layer's work folder is the kernel's, mode 000) goes at the next run beside
    /// it; a run still going keeps its own.
    @Test func aRunsLayersLeftBehindGoAtTheNextRunBesideIt() throws {
        let area = scratch.url("area")
        let runs = area.appendingPathComponent(".branch-runs")
        let files = FileManager.default
        for name in ["101-gone", "202-live", "not-a-run"] {
            try files.createDirectory(at: runs.appendingPathComponent(name + "/layers/0/work/work"), withIntermediateDirectories: true)
            try "x".write(to: runs.appendingPathComponent(name + "/layers/0/upper"), atomically: true, encoding: .utf8)
            chmod(runs.appendingPathComponent(name + "/layers/0/work/work").path, 0)
        }
        // A link a run planted in its layer leads nowhere the sweep follows.
        let outside = scratch.url("outside")
        try files.createDirectory(at: outside, withIntermediateDirectories: true)
        try "kept".write(to: outside.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try files.createSymbolicLink(at: runs.appendingPathComponent("101-gone/layers/0/link"), withDestinationURL: outside)
        defer { for name in ["202-live", "not-a-run"] { chmod(runs.appendingPathComponent(name + "/layers/0/work/work").path, 0o700) } }
        // Not in a folder others can write: nothing there is this user's to remove by name.
        chmod(runs.path, 0o777)
        BranchRun.sweep(runs.path, alive: { $0 == 202 })
        #expect(files.fileExists(atPath: runs.appendingPathComponent("101-gone").path))
        chmod(runs.path, 0o700)
        BranchRun.sweep(runs.path, alive: { $0 == 202 })
        #expect(!files.fileExists(atPath: runs.appendingPathComponent("101-gone").path))
        #expect(files.fileExists(atPath: runs.appendingPathComponent("202-live/layers/0/upper").path))
        #expect(files.fileExists(atPath: runs.appendingPathComponent("not-a-run").path))
        #expect(files.fileExists(atPath: outside.appendingPathComponent("file").path))
    }

    /// A chain of `depth` folders in `folder`, each in the one before, made through descriptors: its whole path is
    /// longer than any the system takes.
    static func deepen(_ folder: String, depth: Int) throws {
        var fd = open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.ENOENT) }
        defer { close(fd) }
        for _ in 0..<depth {
            guard mkdirat(fd, "d", 0o700) == 0 else { throw POSIXError(.EIO) }
            let next = openat(fd, "d", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw POSIXError(.EIO) }
            close(fd)
            fd = next
        }
    }

    /// A launcher started with another home than the account's leaves out a PATH folder the account hides, judged by
    /// the spelling the planner shows it by (`SandboxPolicy.lexical`): not `standardizedFileURL`'s, which follows a
    /// link before a `..` here and drops `/private` on the Mac, so the folder passed the look and refused the plan.
    @Test func aPathFolderIsJudgedByTheSpellingItIsShownBy() throws {
        let layout = try Layout(scratch)
        // By its spelling `<account>/.ssh/out/..` is `<account>/.ssh`, which is what the planner would show.
        try FileManager.default.createSymbolicLink(atPath: layout.account + "/.ssh/out", withDestinationPath: layout.root)
        var other = layout.request()
        other.accountHome = layout.account + "/projects"
        let judged = try BranchRun.plan(other, environment: ["PATH": layout.account + "/.ssh/out/..:/usr/bin"], image: Self.server,
                                        realHome: layout.account, run: "77-run").get()
        #expect(!Self.sources(judged.plan).contains { $0.hasPrefix(layout.account + "/.ssh") })
    }

    /// A run can leave a tree thousands of folders deep in its layer (through its cache's), folders it made read-only
    /// (a module cache's) and names that are no text: the next sweep takes them all, through a few descriptors however
    /// deep the tree is, so the launcher that sweeps still has its own to start its run with.
    @Test func aLayerTreeTooDeepToWalkIsSweptThroughAFewDescriptors() throws {
        let files = FileManager.default
        let runs = scratch.url("deep").appendingPathComponent(".branch-runs")
        let upper = runs.appendingPathComponent("101-gone/layers/0/upper")
        try files.createDirectory(at: upper.appendingPathComponent("locked/in"), withIntermediateDirectories: true)
        chmod(runs.path, 0o700)
        let depth = 5000
        try Self.deepen(upper.path, depth: depth)
        try "x".write(to: upper.appendingPathComponent("locked/in/file"), atomically: true, encoding: .utf8)
        // A name that is no text, where the file system takes one (the Mac's refuses it).
        let odd: [CChar] = [CChar(bitPattern: 0xff), CChar(bitPattern: 0xfe), 0]
        let into = open(upper.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        let made = openat(into, odd, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
        if made >= 0 { close(made) }
        close(into)
        chmod(upper.appendingPathComponent("locked/in").path, 0o500)
        chmod(upper.appendingPathComponent("locked").path, 0o500)
        // And names in the run's folder that a sweep would give the folders it moves up there.
        try files.createDirectory(at: runs.appendingPathComponent("101-gone/moved-\(getpid())-1/kept"), withIntermediateDirectories: true)
        try "x".write(to: runs.appendingPathComponent("101-gone/moved-\(getpid())-2"), atomically: true, encoding: .utf8)
        let outside = scratch.url("outside")
        try files.createDirectory(at: outside, withIntermediateDirectories: true)
        try "kept".write(to: outside.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try files.createSymbolicLink(at: runs.appendingPathComponent("101-gone/moved-\(getpid())-3"), withDestinationURL: outside)

        // The descriptors this process holds as the folders go, looked at now and then: one a level, were the tree
        // walked down. Other tests' come and go meanwhile, far fewer than the tree is deep.
        func held() -> Int { (0..<Int32(depth * 2)).filter { fcntl($0, F_GETFD) >= 0 }.count }
        let before = held()
        var most = before, asked = 0
        let aside = BranchRun.sweep(runs.path, alive: { _ in false }, removing: { folder, name, flags in
            if flags & AT_REMOVEDIR != 0 {
                if asked % 500 == 0 { most = max(most, held()) }
                asked += 1
            }
            return unlinkat(folder, name, flags)
        })
        #expect(most - before < depth / 10, "\(most - before) more descriptors held while a tree \(depth) deep went")
        if files.fileExists(atPath: runs.appendingPathComponent("101-gone").path) {
            // Left for whoever cleans this scratch: its folders are its owner's to enter again.
            chmod(upper.appendingPathComponent("locked").path, 0o700)
            chmod(upper.appendingPathComponent("locked/in").path, 0o700)
            Issue.record("the tree wasn't swept")
        }
        #expect(aside == [])
        #expect((try? files.contentsOfDirectory(atPath: runs.path)) == [])
        // The link among them was removed as a link: what it led to is there.
        #expect(files.fileExists(atPath: outside.appendingPathComponent("file").path))
    }

    /// What a sweep can't remove doesn't stop the run it comes before: the run's folder is set aside under a name no
    /// sweep takes for a run's, said once, and the rest is swept as ever.
    @Test func layersThatCantBeRemovedAreSetAsideOnce() throws {
        let files = FileManager.default
        let runs = scratch.url("stuck").appendingPathComponent(".branch-runs")
        for name in ["101-gone", "303-gone"] {
            try files.createDirectory(at: runs.appendingPathComponent(name + "/layers/0/upper/a/b"), withIntermediateDirectories: true)
            try "x".write(to: runs.appendingPathComponent(name + "/layers/0/upper/a/b/file"), atomically: true, encoding: .utf8)
        }
        try "x".write(to: runs.appendingPathComponent("101-gone/layers/0/upper/a/b/stuck"), atomically: true, encoding: .utf8)
        chmod(runs.path, 0o700)
        var asked = 0
        let refusing: BranchRun.Removing = { folder, name, flags in
            asked += 1
            guard String(cString: name) != "stuck" else {
                errno = EPERM
                return -1
            }
            return unlinkat(folder, name, flags)
        }
        let aside = BranchRun.sweep(runs.path, alive: { _ in false }, removing: refusing)
        let kept = runs.appendingPathComponent(BranchRun.asidePrefix + "101-gone").path
        #expect(aside == [kept])
        #expect((try? files.contentsOfDirectory(atPath: runs.path)) == [BranchRun.asidePrefix + "101-gone"])
        // What it couldn't take is still there, somewhere in what was set aside.
        #expect(files.enumerator(atPath: kept)?.contains { ($0 as? String).map { ($0 as NSString).lastPathComponent } == "stuck" } == true)
        // The next sweep doesn't try it again: it is no run's by its name.
        asked = 0
        #expect(BranchRun.sweep(runs.path, alive: { _ in false }, removing: refusing) == [] && asked == 0)
        #expect(files.fileExists(atPath: kept))
    }

    /// Two launchers can start beside each other and sweep the same run's folder at once (a verifier's commands side
    /// by side). What the other took first is gone, which is what this one wanted: nothing is set aside for it.
    @Test func whatAnotherSweepTookFirstIsntSetAside() throws {
        let files = FileManager.default
        let runs = scratch.url("beside").appendingPathComponent(".branch-runs")
        try files.createDirectory(at: runs.appendingPathComponent("101-gone/layers/0/upper/a/b"), withIntermediateDirectories: true)
        try "x".write(to: runs.appendingPathComponent("101-gone/layers/0/upper/a/b/file"), atomically: true, encoding: .utf8)
        try "x".write(to: runs.appendingPathComponent("101-gone/layers/0/upper/file"), atomically: true, encoding: .utf8)
        chmod(runs.path, 0o700)
        // The other sweep, a step ahead every time: the thing has just gone when this one comes for it.
        let aside = BranchRun.sweep(runs.path, alive: { _ in false }, removing: { folder, name, flags in
            guard unlinkat(folder, name, flags) == 0 else { return -1 }
            errno = ENOENT
            return -1
        })
        #expect(aside == [])
        #expect((try? files.contentsOfDirectory(atPath: runs.path)) == [])

        // And what the other moved up into the run's folder after this one had listed it is found by looking again.
        let run = runs.appendingPathComponent("202-gone")
        try files.createDirectory(at: run.appendingPathComponent("layers/0/upper"), withIntermediateDirectories: true)
        try "x".write(to: run.appendingPathComponent("layers/0/upper/file"), atomically: true, encoding: .utf8)
        var late = false
        let after = BranchRun.sweep(runs.path, alive: { _ in false }, removing: { folder, name, flags in
            if !late {
                late = true
                try? files.createDirectory(at: run.appendingPathComponent("moved-1-1/in"), withIntermediateDirectories: true)
                try? "x".write(to: run.appendingPathComponent("moved-1-1/in/file"), atomically: true, encoding: .utf8)
            }
            return unlinkat(folder, name, flags)
        })
        #expect(late && after == [])
        #expect((try? files.contentsOfDirectory(atPath: runs.path)) == [])
    }
}
