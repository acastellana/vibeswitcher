import Foundation
import Testing
@testable import VibeCore

/// A box of the planner's own plan, entered for real over `SandboxPlannerTests`' scratch world, by this test binary in
/// its launcher mode. That mode is VibePlatformTests' (`ShimBox`, SandboxShimTests.swift: every test target is one
/// binary on Linux, and the launcher runs before any test of it): started again with `requestVariable` naming a
/// request file, it enters the plan the file holds and runs its program. The file's lines are written here as
/// `ShimBox.Request.lines` writes them: tab-separated fields, each in hex.
enum PlannedBox {
    /// `ShimBox.requestVariable`.
    static let requestVariable = "VIBE_SANDBOX_TEST_REQUEST"

    /// Why no box can be built here; nil when one can.
    static let unavailable: String? = Platform.Sandbox.probe().why

    static func request(_ plan: Platform.Sandbox.Plan, _ program: [String]) -> String {
        func hex(_ text: String) -> String { text.utf8.map { String(format: "%02x", $0) }.joined() }
        var lines: [[String]] = []
        for mount in plan.mounts {
            switch mount.kind {
            case .readOnly(let source): lines.append(["ro", mount.target, source])
            case .readWrite(let source): lines.append(["rw", mount.target, source])
            case .overlay(let lower, let upper, let work): lines.append(["overlay", mount.target, lower, upper, work])
            case .empty(let mode): lines.append(["empty", mount.target, String(mode)])
            case .proc: lines.append(["proc", mount.target])
            case .devpts: lines.append(["devpts", mount.target])
            case .sysfs: lines.append(["sysfs", mount.target])
            case .device(let name): lines.append(["device", mount.target, name])
            case .link(let text): lines.append(["link", mount.target, text])
            case .file(let contents, let mode): lines.append(["file", mount.target, String(decoding: contents, as: UTF8.self), String(mode)])
            }
        }
        switch plan.network {
        case .shared: lines.append(["network", "shared"])
        case .none: lines.append(["network", "none"])
        case .proxied(let port): lines.append(["network", "proxied", String(port)])
        }
        lines.append(["hostname", plan.hostname])
        lines.append(["directory", plan.directory])
        lines += plan.environment.map { ["env", $0] }
        if let door = plan.door { lines.append(["door", door]) }
        lines.append(["terminal", plan.terminal.rawValue])
        lines.append(["nesting", plan.nesting ? "1" : "0"])
        lines += program.map { ["program", $0] }
        return lines.map { $0.map(hex).joined(separator: "\t") }.joined(separator: "\n") + "\n"
    }

    /// `sh -c script` in a box of `plan`, to its end (killed after `limit`): its wait status, nil when it was never
    /// collected, and what it and the launcher wrote on stdout and stderr together. A blocking call: off the pool.
    static func shell(_ script: String, _ plan: Platform.Sandbox.Plan, in scratch: URL, limit: TimeInterval = 120) throws -> (status: Int32?, output: String) {
        try #require(getenv(requestVariable) == nil)
        let file = scratch.appendingPathComponent("request-\(UUID().uuidString.prefix(8)).txt")
        let output = scratch.appendingPathComponent("launcher-\(UUID().uuidString.prefix(8)).out")
        try Data(request(plan, ["/bin/sh", "-c", script]).utf8).write(to: file)
        let binary = try #require(Bundle.main.executablePath)
        var spawn = Platform.Spawn(executable: binary, arguments: ProcessInfo.processInfo.arguments)
        spawn.environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" } + ["\(requestVariable)=\(file.path)"]
        spawn.group = .ownGroup
        spawn.stdin = .path("/dev/null", flags: O_RDONLY)
        spawn.stdout = .path(output.path, flags: O_WRONLY | O_CREAT | O_APPEND, mode: 0o600)
        spawn.stderr = .path(output.path, flags: O_WRONLY | O_CREAT | O_APPEND, mode: 0o600)
        let pid = try spawn.start().get()
        var raw: Int32 = 0
        var status: Int32?
        var deadline = MacTime.real.awake() + limit, killed = false
        while true {
            let found = waitpid(pid, &raw, WNOHANG)
            if found == pid {
                status = raw
                break
            }
            if found < 0, errno != EINTR { break }
            if MacTime.real.awake() >= deadline {
                guard !killed else { break }
                Sys.kill(pid, SIGKILL)
                killed = true
                deadline = MacTime.real.awake() + 10
            }
            if found == 0 { usleep(2_000) }
        }
        return (status, (try? String(contentsOf: output, encoding: .utf8)) ?? "")
    }
}

/// The review of 2026-11-19, in a real box: a worker's plan as `SandboxPlanner` gives it (its door and its terminal
/// left out, which need a porter and a pty and aren't what this checks), entered over the scratch world, with a shell
/// standing for the agent and for a worker that turned on it. Inside, the worktree's `config.worktree` and the
/// transcripts' `memory/` can't be written, made, removed or replaced; the transcript beside the memory still is; and
/// the worker's own git still commits. Outside, afterwards, nothing was planted.
@Suite(.enabled(if: !Platform.CodeIdentity.isAvailable && PlannedBox.unavailable == nil,
                "needs a box: \(PlannedBox.unavailable ?? "the Mac has none")"), .timeLimit(.minutes(5)))
struct SandboxPlannerBoxTests {
    let planner = SandboxPlannerTests()

    /// What the shell in the box tries: each line of its output is `<what>: ok` or `<what>: refused: <the error>`.
    static func probe(own: String, transcripts: String, worktree: String) -> String {
        func attempt(_ name: String, _ command: String) -> String {
            "if said=$( { \(command) ; } 2>&1 ); then echo '\(name): ok'; else echo \"\(name): refused: $said\"; fi"
        }
        let config = own + "/config.worktree"
        let memory = transcripts + "/memory"
        return [
            // A worker that turned on its lead: a program for the node's git, each way it could get there.
            attempt("config write", "printf '[core]\\n\\tfsmonitor = /planted\\n' > '\(config)'"),
            attempt("config append", "printf '[core]\\n\\tfsmonitor = /planted\\n' >> '\(config)'"),
            attempt("config remove", "rm -f '\(config)' && test ! -e '\(config)'"),
            attempt("config replace", "printf '[core]\\n\\tfsmonitor = /planted\\n' > '\(own)/planted' && mv '\(own)/planted' '\(config)'"),
            attempt("config by git", "git config --file '\(config)' core.hooksPath /planted"),
            attempt("config mode", "chmod u+w '\(config)' && printf x >> '\(config)'"),
            // The agent, as Claude Code keeps its memory: the folder made if it isn't there, a file written in it.
            attempt("memory folder", "mkdir -p '\(memory)'"),
            attempt("memory write", "printf 'planted\\n' > '\(memory)/MEMORY.md'"),
            attempt("memory new file", "printf 'planted\\n' > '\(memory)/x'"),
            attempt("memory subfolder", "mkdir '\(memory)/team'"),
            attempt("memory remove", "rm -rf '\(memory)' && test ! -e '\(memory)'"),
            attempt("memory replace", "mkdir '\(transcripts)/planted' && printf 'planted\\n' > '\(transcripts)/planted/MEMORY.md' && mv -T '\(transcripts)/planted' '\(memory)'"),
            attempt("memory mode", "chmod u+w '\(memory)' && printf x > '\(memory)/y'"),
            "echo \"memory holds: $(ls '\(memory)' | tr '\\n' ' ')\"",
            // The transcript beside it, as Claude Code writes one and a subagent's.
            attempt("transcript write", "printf '{\"type\":\"user\"}\\n' >> '\(transcripts)/0b1c.jsonl'"),
            attempt("subagent transcript", "mkdir -p '\(transcripts)/0b1c/subagents' && printf '{}\\n' > '\(transcripts)/0b1c/subagents/agent-1.jsonl'"),
            // The worker's own git, which reads that config: still its own.
            attempt("git status", "git -C '\(worktree)' status --porcelain"),
            attempt("git commit", "git -C '\(worktree)' commit -q --allow-empty -m 'in the box'"),
        ].joined(separator: "\n")
    }

    /// The lines of `output` by their name: what came after `<name>: `.
    static func answers(_ output: String) -> [String: String] {
        var answers: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let colon = line.range(of: ": ") else { continue }
            answers[String(line[..<colon.lowerBound])] = String(line[colon.upperBound...])
        }
        return answers
    }

    /// A worker's plan over `world`, ready to enter: the folders the host makes made, no door and no terminal, and
    /// the private layers only where this kernel has them.
    func entered(_ world: SandboxPlannerTests.World, _ script: String) async throws -> (status: Int32?, output: String) {
        let inputs = world.inputs(.worker)
        var plan = try SandboxPlanner.plan(inputs).get()
        for folder in SandboxPlanner.folders(for: plan, inputs: inputs) {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        plan.door = nil
        plan.terminal = .none
        if !Platform.Sandbox.probe().overlay {
            plan.mounts.removeAll { if case .overlay = $0.kind { return true } else { return false } }
        }
        let scratch = URL(fileURLWithPath: (world.home as NSString).deletingLastPathComponent)
        // overlayfs leaves each layer's `work/work` with no permission at all (mode 000): opened up afterwards, or the
        // scratch world can't be removed.
        let layers = plan.mounts.compactMap { mount -> String? in
            if case .overlay(_, _, let work) = mount.kind { return work + "/work" }
            return nil
        }
        defer { for layer in layers { chmod(layer, 0o700) } }
        return try await offPool { try PlannedBox.shell(script, plan, in: scratch) }
    }

    static let refusedWrites = ["config write", "config append", "config remove", "config replace", "config by git", "config mode",
                                "memory write", "memory new file", "memory subfolder", "memory remove", "memory replace", "memory mode"]

    /// A worktree as the node made it: no `config.worktree`, no `memory/`.
    @Test func aRealBoxCantMakeItsWorktreesGitConfigOrTheAgentsMemory() async throws {
        let world = try planner.world()
        let own = world.root + "/.git/worktrees/w1"
        let transcripts = world.home + "/.claude/projects/" + ClaudeFiles.projectFolder(cwd: world.worktree)
        let (status, output) = try await entered(world, Self.probe(own: own, transcripts: transcripts, worktree: world.worktree))
        #expect(status == 0, "\(output)")
        let answers = Self.answers(output)
        for name in Self.refusedWrites {
            #expect(answers[name]?.hasPrefix("refused") == true, "\(name): \(answers[name] ?? "nothing") in \(output)")
        }
        #expect(answers["config write"]?.contains("Read-only file system") == true && answers["memory write"]?.contains("Read-only file system") == true, "\(output)")
        // Claude Code's `mkdir -p` of a memory folder that is there finds it there.
        #expect(answers["memory folder"] == "ok" && answers["memory holds"] == "", "\(output)")
        for name in ["transcript write", "subagent transcript", "git status", "git commit"] {
            #expect(answers[name] == "ok", "\(name): \(answers[name] ?? "nothing") in \(output)")
        }
        // Outside, afterwards: the config is the empty file the box was built over, the memory an empty folder, and
        // the transcript and the commit are there.
        #expect(try String(contentsOfFile: own + "/config.worktree", encoding: .utf8) == "")
        #expect(try FileManager.default.contentsOfDirectory(atPath: transcripts + "/memory") == [])
        #expect(try String(contentsOfFile: transcripts + "/0b1c.jsonl", encoding: .utf8) == "{\"type\":\"user\"}\n")
        #expect(FileManager.default.fileExists(atPath: transcripts + "/0b1c/subagents/agent-1.jsonl"))
        let log = Git.run(["log", "-1", "--format=%s", "agent/w1/head"], in: world.root, env: ["GIT_ALTERNATE_OBJECT_DIRECTORIES": world.box + "/objects"])
        #expect(log.output == "in the box", "\(log.output) \(log.error)")
    }

    /// A repository with `extensions.worktreeConfig` on, a worktree with a config of its own and a project with a
    /// memory: both are read inside as they are, and written by nothing there.
    @Test func aRealBoxCantChangeAWorktreeConfigThatGitReadsOrAMemoryThatIsThere() async throws {
        let world = try planner.world()
        let own = world.root + "/.git/worktrees/w1"
        let transcripts = world.home + "/.claude/projects/" + ClaudeFiles.projectFolder(cwd: world.worktree)
        for (key, value) in [("core.repositoryFormatVersion", "1"), ("extensions.worktreeConfig", "true")] {
            #expect(Git.run(["config", key, value], in: world.root).ok)
        }
        #expect(Git.run(["config", "--worktree", "vibeswitcher.mark", "the worktree's own"], in: world.worktree).ok)
        let config = try String(contentsOfFile: own + "/config.worktree", encoding: .utf8)
        try FileManager.default.createDirectory(atPath: transcripts + "/memory", withIntermediateDirectories: false)
        try "- [how the user works](user.md)\n".write(toFile: transcripts + "/memory/MEMORY.md", atomically: true, encoding: .utf8)
        let script = Self.probe(own: own, transcripts: transcripts, worktree: world.worktree) + "\n"
            + "echo \"git reads: $(git -C '\(world.worktree)' config --get vibeswitcher.mark)\"\n"
            + "echo \"memory reads: $(cat '\(transcripts)/memory/MEMORY.md')\"\n"
            + "if said=$( { git -C '\(world.worktree)' config --worktree core.fsmonitor /planted ; } 2>&1 ); then echo 'config --worktree: ok'; else echo \"config --worktree: refused: $said\"; fi"
        let (status, output) = try await entered(world, script)
        #expect(status == 0, "\(output)")
        let answers = Self.answers(output)
        for name in Self.refusedWrites + ["config --worktree"] {
            #expect(answers[name]?.hasPrefix("refused") == true, "\(name): \(answers[name] ?? "nothing") in \(output)")
        }
        #expect(answers["git reads"] == "the worktree's own" && answers["memory reads"] == "- [how the user works](user.md)", "\(output)")
        #expect(answers["memory holds"] == "MEMORY.md ", "\(output)")
        for name in ["memory folder", "transcript write", "git status", "git commit"] {
            #expect(answers[name] == "ok", "\(name): \(answers[name] ?? "nothing") in \(output)")
        }
        // Outside, afterwards: both as they were, and the node's git finds no program in the worktree's config.
        #expect(try String(contentsOfFile: own + "/config.worktree", encoding: .utf8) == config)
        #expect(try FileManager.default.contentsOfDirectory(atPath: transcripts + "/memory") == ["MEMORY.md"])
        #expect(try String(contentsOfFile: transcripts + "/memory/MEMORY.md", encoding: .utf8) == "- [how the user works](user.md)\n")
        #expect(!Git.run(["config", "--worktree", "--get", "core.fsmonitor"], in: world.worktree).ok)
        #expect(!Git.run(["config", "--worktree", "--get", "core.hooksPath"], in: world.worktree).ok)
    }
}
