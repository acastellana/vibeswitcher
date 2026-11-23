import Foundation
import Testing
@testable import VibeCore

/// Whether the code on this branch can run this project's own toolchain the way the node's gate will (incident
/// 2026-11-20 16:41): a build carrying the branch-run box was installed before anything let swift run in that box, and
/// every merge's, audit's and verifier's run failed at the build in 2 s ("Could not load swiftly's configuration file at
/// /tmp/vs-test.…/home/.local/share/swiftly/config.json"), while the merge that brought the box had passed under the
/// older gate. Here the branch's own launcher boxes the real compiler, with the settings a project like this one accepts
/// for its toolchain (`sandbox_read`, `sandbox_env`, `sandbox_nesting`), derived from where the compiler that built
/// these tests lives.
///
/// And a tree with no `.build` resolves its packages in that box, offline, from the cache the box layers under the run's
/// home (2026-11-21: a fresh merge worktree fetched, with no network, and failed: "Fetching
/// https://github.com/apple/swift-crypto.git … error"), through the branch's own `scripts/lib/swift-jobs.sh`.

/// The settings a project like this one gives its gate for its toolchain, as `workflow.md` writes them, from this
/// process's own facts: the `swift` its PATH finds first (that folder, and the folder its links lead to), the toolchain
/// whose runtime this binary runs on (`RealBox.runtime`), and the `SWIFTLY_*` variables it has. Only what is under the
/// account's home is named: the box shows the machine's own folders already, so a toolchain outside the home (hosted
/// CI) adds nothing.
struct ProjectToolchain {
    /// The account's home, its links followed: what `~/` spells.
    let home: String
    /// The `swift` this process's PATH finds first, as its PATH spells it; nil when none.
    let swift: String?
    /// The runtime folder of the toolchain that built this binary (`…/usr/lib/swift/linux`), its links followed, when
    /// it is under the home; else nil.
    let runtimeUnderHome: String?
    /// `sandbox_read`'s folders, each `~/…`.
    let read: [String]
    /// `sandbox_env`'s pairs: the `SWIFTLY_*` variables (a path under the home spelled `~/…`), and `PATH=` the folder
    /// `swift` is found in, when that is under the home.
    let env: [String]

    /// What swiftly's proxy marks its child with, not where anything is: never passed on.
    static let marks: Set<String> = ["SWIFTLY_PROXY_IN_PROGRESS"]

    init(environment: [String: String] = ProcessInfo.processInfo.environment, home given: String = VibePaths.accountHome,
         runtime: String? = RealBox.runtime) {
        let home = SandboxPolicy.resolved(given)
        self.home = home
        func mine(_ path: String) -> Bool { SandboxPolicy.isBelow(path, home) }
        func spelled(_ path: String) -> String { mine(path) ? "~/" + path.dropFirst(home.count + 1) : path }
        func expanded(_ value: String) -> String { value.hasPrefix("~/") ? home + "/" + value.dropFirst(2) : value }

        // swiftly's own folder for its `swift` first: the proxy that started this test (`swift test`) put its toolchain's
        // bin first on this PATH, and marked its child (`SWIFTLY_PROXY_IN_PROGRESS`); a shell's, and the gate's, `swift`
        // is swiftly's.
        let swiftlyBin = environment["SWIFTLY_BIN_DIR"].map(expanded).map { [$0] } ?? []
        let folders = (swiftlyBin + (environment["PATH"] ?? "").split(separator: ":").map(String.init)).filter { $0.hasPrefix("/") }
        swift = folders.lazy.map { SandboxPolicy.lexical($0) + "/swift" }.first { access($0, X_OK) == 0 }
        let suffix = "/usr/lib/swift/linux"
        let runtimeFolder = runtime.map(SandboxPolicy.resolved)
        runtimeUnderHome = runtimeFolder.flatMap { mine($0) ? $0 : nil }

        var toolchain: [String] = []
        var pathFolder: String?
        if let swift {
            let folder = SandboxPolicy.resolved((swift as NSString).deletingLastPathComponent)
            pathFolder = folder
            toolchain += [folder, (SandboxPolicy.resolved(swift) as NSString).deletingLastPathComponent]
        }
        if let runtimeFolder, runtimeFolder.hasSuffix(suffix) { toolchain.append(String(runtimeFolder.dropLast(suffix.count))) }
        let swiftly = environment.filter { $0.key.hasPrefix("SWIFTLY_") && !ProjectToolchain.marks.contains($0.key) }.sorted { $0.key < $1.key }
        for (_, value) in swiftly where value.hasPrefix("/") || value.hasPrefix("~/") {
            toolchain.append(SandboxPolicy.resolved(SandboxPolicy.lexical(expanded(value))))
        }
        let under = Array(Set(toolchain.filter(mine))).sorted()
        // The one folder that holds them all (swiftly's: its bin, its toolchains, its configuration beside them), when
        // that is below the home; else each, none inside another.
        func common(_ one: String, _ other: String) -> String {
            let a = one.split(separator: "/"), b = other.split(separator: "/")
            return "/" + zip(a, b).prefix { $0 == $1 }.map { String($0.0) }.joined(separator: "/")
        }
        if let first = under.first {
            let holder = under.dropFirst().reduce(first, common)
            read = (mine(holder) ? [holder] : under.filter { folder in !under.contains { SandboxPolicy.isBelow(folder, $0) } }).map(spelled)
        } else {
            read = []
        }
        env = swiftly.map { "\($0.key)=\(($0.value.hasPrefix("/") ? spelled(SandboxPolicy.lexical($0.value)) : $0.value))" }
            + (pathFolder.flatMap { mine($0) ? ["PATH=" + spelled($0)] : nil } ?? [])
    }

    /// The `workflow.md` these settings are in.
    var workflow: String {
        var lines: [String] = []
        if !read.isEmpty { lines.append("sandbox_read: " + read.joined(separator: ", ")) }
        if !env.isEmpty { lines.append("sandbox_env: " + env.joined(separator: ", ")) }
        lines.append("sandbox_nesting: on")
        return "---\n" + lines.joined(separator: "\n") + "\n---\n"
    }

    /// The settings as the gate reads an accepted `workflow.md` (`SandboxPolicy.read`), for the project at `root`.
    func policy(root: String = SandboxPolicy.resolved(packageFolder.path)) -> Result<SandboxPolicy, SandboxRefusal> {
        SandboxPolicy.read(LeadWorkflow.parse(workflow), home: home, root: root)
    }

    /// `policy`, or the refusal's text as the test's failure.
    func accepted(sourceLocation: SourceLocation = #_sourceLocation) throws -> SandboxPolicy {
        switch policy() {
        case .success(let policy): return policy
        case .failure(let refusal):
            Issue.record("this project's toolchain settings were refused, as the gate would refuse them: \(refusal)\n\(workflow)",
                         sourceLocation: sourceLocation)
            throw refusal
        }
    }
}

/// Scratch projects to run a branch's command in, as a merge's test command runs (`Worktrees.runChecks`): a scratch
/// account home, a repository per run, each run's scratch home beside them.
final class GatePlace: @unchecked Sendable {
    let base: String
    let account: String
    /// Kept, so its folders go only after this place's `deinit` took the runs' layers, which `Scratch` can't.
    private let scratch: Scratch

    init(_ scratch: Scratch) throws {
        self.scratch = scratch
        base = SandboxPolicy.resolved(try scratch.shortFolder("gt").path)
        account = base + "/home"
        try FileManager.default.createDirectory(atPath: account, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// A run's layers stay beside its home for the next run to take (`BranchRun.sweep`); a layer's work folder is the
    /// kernel's, mode 000, so this place takes them.
    deinit { BranchRun.sweep(base + "/" + BranchRun.runsFolder) }

    /// A new worktree `name` (a branch run's box is planned from a worktree's pointer file) of a scratch repository
    /// holding nothing but `files` (from this checkout, by their paths in it): no `.build`.
    func project(_ name: String, files: [String] = []) throws -> String {
        let repository = base + "/" + name + "-repository", root = base + "/" + name
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for file in files {
            let target = repository + "/" + file
            try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: packageFolder.appendingPathComponent(file).path, toPath: target)
        }
        try "\n".write(toFile: repository + "/README", atomically: true, encoding: .utf8)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["add", "-A"],
                          ["commit", "-q", "-m", "first"], ["worktree", "add", "-q", "--detach", root, "main"]] {
            let ran = Git.run(arguments, in: repository)
            guard ran.ok else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "git \(arguments): \(ran.error)"]) }
        }
        return root
    }

    /// `command` as a merge's test command, in `project` with the scratch home `<name>-home`, under `policy`:
    /// `boxed`, through the branch's own launcher (the built tool server); else on the unboxed scratch-home path, told
    /// the settings' `sandbox_env` (`BranchRun.tools`). Whether it passed, and all it said.
    func run(_ name: String, _ command: String, in project: String, policy: SandboxPolicy, boxed: Bool) async -> (passed: Bool, output: String) {
        let scope = BranchRun.Scope(launcher: boxed ? RealBox.products + "/vibeswitcher-mcp" : nil, accountHome: account, policy: policy)
        let home = base + "/" + name + "-home"
        // This test process stands where the gate's tool server does, but `swift test` started it through swiftly's
        // proxy, whose mark (`ProjectToolchain.marks`) the tool server never has: on the unboxed path a run inherits it,
        // and swiftly's `swift` then refuses ("Circular swiftly proxy invocation"). A box passes on no such name.
        let script = ProjectToolchain.marks.sorted().map { "unset \($0)\n" }.joined() + command
        let ran = await offPool {
            BranchRun.with(scope) { Worktrees.runChecks(setup: nil, test: script, in: project, home: home, timeout: 300) }
        }
        let output = ran.outputs.map(\.output).joined(separator: "\n") + (ran.stopped.map { "\n\($0)" } ?? "")
        return (ran.stopped == nil, output)
    }

    /// Whether `output` says it ran in a branch run's box: the box's own hostname (`version` and the other commands here
    /// say theirs as `hostname=`).
    static func boxed(_ output: String) -> Bool {
        output.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "hostname=" + SandboxPlanner.hostname }
    }

    /// The command that asks the compiler for its version, then says which box it ran in.
    static let version = "swift --version; status=$?; echo \"hostname=$(cat /proc/sys/kernel/hostname 2>/dev/null)\"; exit $status"
}

struct GateToolchainTests {
    private let scratch = Scratch()

    @Test func theSettingsComeFromThisProcesssOwnToolchainAndAreAccepted() throws {
        let toolchain = ProjectToolchain()
        let swift = try #require(toolchain.swift, "no swift on this process's PATH")
        let policy = try toolchain.accepted()
        #expect(policy.nesting && policy.enabled)
        let real = SandboxPolicy.resolved(swift)
        if SandboxPolicy.isBelow(real, toolchain.home) {
            // Under the home: the folder holding the compiler is shown, and the folder it's found in is first on PATH.
            #expect(policy.read.contains { SandboxPolicy.isBelow(real, $0) }, "\(toolchain.workflow)")
            #expect(policy.path.first == SandboxPolicy.resolved((swift as NSString).deletingLastPathComponent), "\(toolchain.workflow)")
        } else {
            // Outside it (hosted CI): the box shows the machine's own folders, and nothing is added for them.
            #expect(policy.path.isEmpty, "\(toolchain.workflow)")
        }
        for (name, _) in ProcessInfo.processInfo.environment where name.hasPrefix("SWIFTLY_") && !ProjectToolchain.marks.contains(name) {
            #expect(policy.environment[name] != nil, "\(name): \(toolchain.workflow)")
        }
    }

    /// The derivation, from facts shaped like this node's: swiftly in the home, its three variables, its bin on PATH.
    @Test func swiftlysFolderVariablesAndBinAreWhatAProjectLikeThisOneAccepts() throws {
        let place = try GatePlace(scratch)
        let home = place.account
        let swiftly = home + "/.local/share/swiftly"
        for folder in [swiftly + "/bin", swiftly + "/toolchains/6.4.2/usr/bin", swiftly + "/toolchains/6.4.2/usr/lib/swift/linux"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        for program in [swiftly + "/bin/swiftly", swiftly + "/toolchains/6.4.2/usr/bin/swift"] {
            try "#!/bin/sh\n".write(toFile: program, atomically: true, encoding: .utf8)
            chmod(program, 0o755)
        }
        try FileManager.default.createSymbolicLink(atPath: swiftly + "/bin/swift", withDestinationPath: "swiftly")
        // As `swift test` through swiftly's proxy starts this test: its toolchain's bin first on PATH, and its mark.
        let environment = ["PATH": "\(swiftly)/toolchains/6.4.2/usr/bin:/usr/bin:\(swiftly)/bin:/bin", "SWIFTLY_PROXY_IN_PROGRESS": "1", "SWIFTLY_HOME_DIR": "~/.local/share/swiftly",
                           "SWIFTLY_BIN_DIR": swiftly + "/bin", "SWIFTLY_TOOLCHAINS_DIR": swiftly + "/toolchains"]
        let toolchain = ProjectToolchain(environment: environment, home: home, runtime: swiftly + "/toolchains/6.4.2/usr/lib/swift/linux")
        #expect(toolchain.read == ["~/.local/share/swiftly"])
        #expect(toolchain.env == ["SWIFTLY_BIN_DIR=~/.local/share/swiftly/bin", "SWIFTLY_HOME_DIR=~/.local/share/swiftly",
                                  "SWIFTLY_TOOLCHAINS_DIR=~/.local/share/swiftly/toolchains", "PATH=~/.local/share/swiftly/bin"])
        let policy = try toolchain.policy(root: home + "/project").get()
        #expect(policy.read == [swiftly] && policy.path == [swiftly + "/bin"] && policy.nesting)
        #expect(policy.environment == ["SWIFTLY_HOME_DIR": swiftly, "SWIFTLY_BIN_DIR": swiftly + "/bin", "SWIFTLY_TOOLCHAINS_DIR": swiftly + "/toolchains"])

        // A toolchain outside the home (hosted CI): nothing added but the nesting.
        let outside = ProjectToolchain(environment: ["PATH": "/usr/bin:/bin"], home: home, runtime: "/usr/lib/swift/linux")
        #expect(outside.read.isEmpty && outside.env.isEmpty && outside.runtimeUnderHome == nil)
        #expect(try outside.policy(root: home + "/project").get() == SandboxPolicy(nesting: true))
    }

    @Test func swiftAnswersOnTheUnboxedScratchHomePath() async throws {
        let place = try GatePlace(scratch)
        let project = try place.project("unboxed")
        let run = await place.run("unboxed", GatePlace.version, in: project, policy: try ProjectToolchain().accepted(), boxed: false)
        #expect(!GatePlace.boxed(run.output), "\(run.output)")
        #expect(run.passed && run.output.contains("Swift version"), "\(run.output)")
    }
}

@Suite(.enabled(if: !Platform.CodeIdentity.isAvailable && RealBox.unavailable == nil,
                "needs a box: \(RealBox.unavailable ?? "the Mac has none")"), .timeLimit(.minutes(10)))
struct GateToolchainBoxTests {
    private let scratch = Scratch()

    @Test func swiftAnswersInABranchRunsBoxWithTheProjectsSettings() async throws {
        let place = try GatePlace(scratch)
        let project = try place.project("boxed")
        let toolchain = ProjectToolchain()
        let run = await place.run("boxed", GatePlace.version, in: project, policy: try toolchain.accepted(), boxed: true)
        #expect(GatePlace.boxed(run.output), "it didn't run in a box: \(run.output)")
        #expect(run.passed && run.output.contains("Swift version"), "\(toolchain.workflow)\n\(run.output)")
    }

    /// What makes the test above prove something: the standard box shows no toolchain under the home. Where the
    /// toolchain is outside the home (hosted CI) there is nothing to hide, and nothing is asked.
    @Test func theStandardBoxShowsNoToolchainUnderTheHome() async throws {
        let toolchain = ProjectToolchain()
        guard let runtime = toolchain.runtimeUnderHome else { return }
        let place = try GatePlace(scratch)
        let accepted = try toolchain.accepted()
        let probe = "if [ -e \(FakeClaude.quoted(runtime)) ]; then echo toolchain=shown; else echo toolchain=hidden; fi; " + GatePlace.version
        for (name, policy, shown) in [("standard", SandboxPolicy.standard, false), ("project", accepted, true)] {
            let run = await place.run(name, probe, in: try place.project(name), policy: policy, boxed: true)
            #expect(GatePlace.boxed(run.output), "\(name): it didn't run in a box: \(run.output)")
            #expect(run.output.contains(shown ? "toolchain=shown" : "toolchain=hidden"), "\(name): \(run.output)")
        }
    }

    /// A tree with no `.build`, as every merge's and audit's scratch worktree is, resolves its packages in the box with
    /// no network, from the account's SwiftPM cache the box layers under the run's home, because the branch's own
    /// `swiftpm_run_cache` names it to SwiftPM (`--cache-path`) once the scripts replace HOME (scripts/test.sh). Without
    /// that flag it fails, rather than fetch: the box has no network to fetch with. No compile but the manifest's.
    @Test func aTreeWithNoBuildFolderResolvesItsPackagesOfflineFromTheBoxsCache() async throws {
        let place = try GatePlace(scratch)
        // The account's SwiftPM cache: what this checkout's build fetched into its own .build, linked (the box shows it
        // through a layer of the run's, so nothing writes these files).
        let fetched = packageFolder.appendingPathComponent(".build/repositories").path
        let cache = place.account + "/.cache/org.swift.swiftpm"
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let linked = Shell.run(executable: "/bin/sh", args: ["-c", "cp -al \"$0\" \"$1\" || cp -R \"$0\" \"$1\"", fetched, cache + "/repositories"],
                               in: place.base, timeout: 120)
        try #require(linked.ok, "this checkout's build left no packages to stand for the account's cache: \(linked.output) \(linked.error)")
        let policy = try ProjectToolchain().accepted()
        let files = ["Package.swift", "Package.resolved", "scripts/lib/swift-jobs.sh"]
        // As scripts/test.sh: its swift-jobs.sh, `swiftpm_run_cache` before HOME is replaced, SwiftPM given its options.
        func resolve(flag: Bool) -> String {
            let script = """
                . scripts/lib/swift-jobs.sh
                \(flag ? "swiftpm_run_cache" : "unset swiftpm_cache")
                echo "cache=${swiftpm_cache:-}"
                echo "options=$(swiftpm_options | tr '\\n' ' ')"
                mkdir -p "$HOME/test-home" && export HOME="$HOME/test-home"
                swift package resolve $(swiftpm_options)
                status=$?
                echo "hostname=$(cat /proc/sys/kernel/hostname)"
                exit $status
                """
            return "bash -c " + FakeClaude.quoted(script)
        }

        let fresh = try place.project("fresh", files: files)
        #expect(!FileManager.default.fileExists(atPath: fresh + "/.build"))
        let run = await place.run("fresh", resolve(flag: true), in: fresh, policy: policy, boxed: true)
        #expect(GatePlace.boxed(run.output), "it didn't run in a box: \(run.output)")
        #expect(run.output.contains("cache=\(place.base)/fresh-home/.cache/org.swift.swiftpm\n"), "\(run.output)")
        #expect(run.output.contains("--cache-path \(place.base)/fresh-home/.cache/org.swift.swiftpm"), "\(run.output)")
        #expect(run.passed, "\(run.output)")
        #expect(FileManager.default.fileExists(atPath: fresh + "/.build/workspace-state.json"), "\(run.output)")

        let unflagged = try place.project("unflagged", files: files)
        let without = await place.run("unflagged", resolve(flag: false), in: unflagged, policy: policy, boxed: true)
        #expect(GatePlace.boxed(without.output) && without.output.contains("cache=\n"), "\(without.output)")
        #expect(!without.passed, "it resolved with no cache named and no network: \(without.output)")
    }
}
