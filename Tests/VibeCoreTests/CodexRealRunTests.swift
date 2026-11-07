import Foundation
import Testing
@testable import VibeCore

/// One small real task run end to end by the real Codex CLI, on demand only (it spends the Codex account's usage):
/// `VIBESWITCHER_REAL_CODEX_HOME=<your Codex home> bash scripts/test.sh --filter CodexRealRunTests`. A scratch repository
/// and worktree; the command line `LeadLaunch.prepareCodex` makes, run as `codex exec` (see below); a stub MCP
/// server standing in for VibeSwitcher's tool server that keeps each tool call. Codex is asked to commit a file, try two
/// things its sandbox must refuse (moving main, a tag), call progress, then report.
struct CodexRealRunTests {
    let temp = Scratch()

    static let codexHome = ProcessInfo.processInfo.environment["VIBESWITCHER_REAL_CODEX_HOME"]

    /// A minimal MCP server over stdio: tools progress and report; each call's arguments appended to `log`, one JSON line.
    static func stub(log: String) -> String {
        """
        import json, sys
        log = \(LeadLaunch.toml(log))
        tools = [{"name": n, "description": d, "inputSchema": {"type": "object", "properties": p, "required": list(p)[:1]}} for n, d, p in [
            ("progress", "Note a milestone in one line.", {"text": {"type": "string"}}),
            ("report", "Tell the lead you're done or blocked.", {"status": {"type": "string"}, "summary": {"type": "string"}, "blind_check": {"type": "string"}, "evidence": {"type": "array", "items": {"type": "object"}}}),
        ]]
        for line in sys.stdin:
            try: message = json.loads(line)
            except Exception: continue
            method, ident = message.get("method"), message.get("id")
            if ident is None: continue
            if method == "initialize":
                result = {"protocolVersion": message["params"].get("protocolVersion", "2025-06-18"), "capabilities": {"tools": {}}, "serverInfo": {"name": "vibeswitcher", "version": "0"}}
            elif method == "tools/list":
                result = {"tools": tools}
            elif method == "tools/call":
                with open(log, "a") as f: f.write(json.dumps(message["params"]) + "\\n")
                result = {"content": [{"type": "text", "text": "Noted."}]}
            else:
                result = {}
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": ident, "result": result}) + "\\n"); sys.stdout.flush()
        """
    }

    @Test(.enabled(if: codexHome != nil, "spends Codex usage: set VIBESWITCHER_REAL_CODEX_HOME to run it"))
    func aSmallTaskRunsEndToEndInTheRealCodex() async throws {
        // Not under /tmp, which Codex's sandbox lets every command write (its refusals would prove nothing there): in
        // this checkout's git-ignored .build folder, removed after.
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = checkout.appendingPathComponent(".build/codex-e2e/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        let main = Git.run(["rev-parse", "main"], in: root).output
        let worktree = try Worktrees.open(root: root, slug: "hello", base: "main")
        let log = temp.url("calls.jsonl").path
        let server = temp.url("stub-mcp").path
        try ("#!/usr/bin/python3\n" + Self.stub(log: log)).write(toFile: server, atomically: true, encoding: .utf8)
        chmod(server, 0o755)
        var task = LeadTask(slug: "hello", title: "Add hello.txt", contract: LeadContract(
            goal: "hello.txt holds the line `hi`, committed on this branch.",
            acceptance: ["`git show HEAD:hello.txt` prints hi",
                         "Run `git tag codex-probe` and `git update-ref refs/heads/main HEAD`, each on its own: both must fail; put what each printed in your report"],
            boundaries: ["hello.txt only"], context: "A scratch repository: no tests, no lints, no load runs. Skip the blind check: say so in blind_check."))
        task.agent = .codex
        let prompt = LeadPrompts.worker(task: task, root: root, workflow: LeadWorkflow(), policy: "", lints: [], screenshots: .some(nil))
        let prepared = try LeadLaunch.prepareCodex(root: root, task: "hello", base: "/opt/homebrew/bin/codex", prompt: prompt,
                                                   start: "Start on your task (it's in your instructions). Call progress at each milestone. When done, call report.",
                                                   server: server, name: "worker-hello", folder: temp.url("run"), cwd: worktree,
                                                   temporary: temp.url("tmp"))
        // Non-interactive (`codex exec`): the TUI waits on a terminal's answers to its color queries, which the session
        // host's emulator gives and a bare pty doesn't. The rest of the command line as start_worker gives it; exec
        // takes no `--no-daemon` (it runs in-process) and never asks for approval.
        let command = prepared.command.replacingOccurrences(of: "/opt/homebrew/bin/codex --no-daemon ", with: "/opt/homebrew/bin/codex exec ")
            .replacingOccurrences(of: " --ask-for-approval never", with: "")
        #expect(command != prepared.command && command.contains(" exec --cd "), "\(prepared.command.prefix(200))")
        let output = temp.url("codex-output.log").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command + " > '\(output)' 2>&1 < /dev/null"]
        process.currentDirectoryURL = URL(fileURLWithPath: worktree)
        var environment = ProcessInfo.processInfo.environment.merging(prepared.environment) { $1 }
        environment["CODEX_HOME"] = Self.codexHome
        environment["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        // Until it exits (its turn over), 15 minutes at most.
        if await offPool({ ended.wait(timeout: .now() + 900) }) == .timedOut { process.terminate() }
        let calls = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        let transcript = (try? String(contentsOfFile: output, encoding: .utf8)) ?? ""
        print("CODEX CALLS:\n\(calls)\nCODEX COMMITS:\n\(Git.run(["log", "--oneline", "main..agent/hello"], in: root).output)\nCODEX OUTPUT TAIL:\n\(transcript.suffix(4000))")
        #expect(calls.contains("\"name\": \"progress\""), "no progress call")
        #expect(calls.contains("\"name\": \"report\""), "no report call")
        #expect(Git.run(["show", "agent/hello:hello.txt"], in: root).output == "hi")
        #expect(Git.run(["rev-parse", "main"], in: root).output == main, "main moved")
        #expect(!Git.run(["rev-parse", "--verify", "--quiet", "refs/tags/codex-probe"], in: root).ok, "the tag was made")
    }

    /// The project's own checks inside a real Codex worker's sandbox, on demand only (it spends Codex usage):
    /// `VIBESWITCHER_REAL_CODEX_HOME=<your Codex home> bash scripts/test.sh --filter CodexRealRunTests/theProjectsChecks`.
    /// This checkout's HEAD (its agent files left out) in a scratch repository, with a worktree as the lead makes them; Codex, on the command line
    /// `LeadLaunch.prepareCodex` makes (as `codex exec`, above), in a scratch Codex home holding only your sign-in
    /// (auth.json, copied: nothing is written to yours), runs `bash scripts/test.sh --filter LeftoverCheckTests`, the
    /// lint filter and `scripts/test-under-load.sh --check-only` as written, each into a log in its TMPDIR. The worktree is
    /// built first, outside Codex: the build isn't what's checked, and Codex would spend turns waiting on it; SwiftPM
    /// compiles the manifest again in each run (its cache is in the run's scratch home), under its own sandbox-exec
    /// unless told not to. Until 2026-11-02 the first failed there before compiling ("sandbox-exec: sandbox_apply:
    /// Operation not permitted", task wallet-results-tests) and its leftover check said "env: /bin/ps: Operation not
    /// permitted".
    @Test(.enabled(if: codexHome != nil, "spends Codex usage: set VIBESWITCHER_REAL_CODEX_HOME to run it"))
    func theProjectsChecksRunInARealCodexWorkersSandbox() async throws {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // This checkout's HEAD, exported without its agent files into a scratch repository outside the worktree (an
        // export inside it would hold AGENTS.md and CLAUDE.md for the audit to take as a worker's: AgentExportLintTests).
        let root = temp.url("codex-checks").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let export = Process()
        export.executableURL = URL(fileURLWithPath: "/bin/sh")
        export.arguments = ["-c", "/usr/bin/git archive HEAD | tar -x -C '\(root)' --exclude AGENTS.md --exclude 'CLAUDE*.md' --exclude .claude --exclude .mcp.json"]
        export.currentDirectoryURL = checkout
        try export.run()
        #expect(await exited(export), "pid \(export.processIdentifier) still running")
        try #require(export.terminationStatus == 0, "git archive of this checkout failed")
        // A stand-in where the docs link to it (DocLinksLint), not the checkout's.
        try "# A scratch export: the checkout's AGENTS.md is left out.\n".write(toFile: root + "/AGENTS.md", atomically: true, encoding: .utf8)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["add", "-A"], ["commit", "-q", "-m", "export"]] {
            Git.run(args, in: root)
        }
        // The worktrees' shared module cache, as the lead's repository has one (a writable root of the worker's).
        try FileManager.default.createDirectory(atPath: root + "/.vibeswitcher/module-cache", withIntermediateDirectories: true)
        let worktree = try Worktrees.open(root: root, slug: "checks", base: "main")
        // Without Claude Code's or Codex's marks: a Codex worker's commands have neither.
        var plain = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("CODEX_") }
        plain["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/bash")
        build.arguments = ["scripts/test.sh", "--filter", "LeftoverCheckTests/aRunThatLeftNothingPasses"]
        build.currentDirectoryURL = URL(fileURLWithPath: worktree)
        build.environment = plain
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.nullDevice
        try build.run()
        #expect(await exited(build), "pid \(build.processIdentifier) still running")
        try #require(build.terminationStatus == 0, "the worktree's build failed outside Codex")

        let codexHome = temp.url("codex-home").path
        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: try #require(Self.codexHome) + "/auth.json", toPath: codexHome + "/auth.json")
        chmod(codexHome + "/auth.json", 0o600)
        let log = temp.url("calls.jsonl").path
        let server = temp.url("stub-mcp").path
        try ("#!/usr/bin/python3\n" + Self.stub(log: log)).write(toFile: server, atomically: true, encoding: .utf8)
        chmod(server, 0o755)
        let lints = LeadPrompts.Policy.lintTests(in: worktree).joined(separator: "|")
        var task = LeadTask(slug: "checks", title: "Run the project's checks", contract: LeadContract(
            goal: "Run the project's checks below, each exactly as written, one after the other, and report what each printed.",
            acceptance: ["`bash scripts/test.sh --filter LeftoverCheckTests > \"$TMPDIR/focused.log\" 2>&1; echo \"exit $?\" >> \"$TMPDIR/focused.log\"`",
                         "`bash scripts/test.sh --filter '\(lints)' > \"$TMPDIR/lints.log\" 2>&1; echo \"exit $?\" >> \"$TMPDIR/lints.log\"`",
                         "`scripts/test-under-load.sh --check-only > \"$TMPDIR/load.log\" 2>&1; echo \"exit $?\" >> \"$TMPDIR/load.log\"` (it may refuse a loaded Mac: that's fine)",
                         "Your report's summary: the last 3 lines of each log"],
            boundaries: ["change no file and commit nothing"],
            context: "A check of the checks: nothing to build or fix. No full suite, no load run, no screenshots. Skip the blind check: say so in blind_check."))
        task.agent = .codex
        var workflow = LeadWorkflow()
        workflow.testCommand = "bash scripts/test.sh"
        let prompt = LeadPrompts.worker(task: task, root: root, workflow: workflow, policy: "", screenshots: .some(nil))
        let prepared = try LeadLaunch.prepareCodex(root: root, task: "checks", base: "/opt/homebrew/bin/codex", prompt: prompt,
                                                   start: "Start on your task (it's in your instructions). Call progress at each milestone. When done, call report.",
                                                   server: server, name: "worker-checks", folder: temp.url("run"), cwd: worktree,
                                                   temporary: temp.url("tmp"))
        let tmp = try #require(prepared.environment["TMPDIR"])
        let command = prepared.command.replacingOccurrences(of: "/opt/homebrew/bin/codex --no-daemon ", with: "/opt/homebrew/bin/codex exec ")
            .replacingOccurrences(of: " --ask-for-approval never", with: "")
        let output = temp.url("codex-output.log").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command + " > '\(output)' 2>&1 < /dev/null"]
        process.currentDirectoryURL = URL(fileURLWithPath: worktree)
        var environment = plain.merging(prepared.environment) { $1 }
        environment["CODEX_HOME"] = codexHome
        process.environment = environment
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        // Until it exits (its turn over), 30 minutes at most.
        if await offPool({ ended.wait(timeout: .now() + 1800) }) == .timedOut { process.terminate() }
        let read = { (name: String) in (try? String(contentsOfFile: (tmp as NSString).appendingPathComponent(name), encoding: .utf8)) ?? "" }
        let (focused, lintRun, load) = (read("focused.log"), read("lints.log"), read("load.log"))
        let calls = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        print("CODEX CHECKS: focused.log:\n\(focused.suffix(3000))\nlints.log:\n\(lintRun.suffix(3000))\nload.log:\n\(load)\nCODEX CALLS:\n\(calls)")
        for (name, text) in [("focused", focused), ("lints", lintRun)] {
            #expect(text.hasSuffix("exit 0\n"), "\(name): \(text.suffix(2000))")
            #expect(text.contains("Test run with ") && text.contains(" passed after "), "\(name): \(text.suffix(2000))")
        }
        for text in [focused, lintRun, load] {
            #expect(!text.contains("sandbox_apply") && !text.contains("/bin/ps") && !text.contains("sysctl"), "\(text.suffix(2000))")
        }
        // Ready to start, or refusing a loaded Mac or low memory: its checks ran either way.
        #expect(load.contains("ok to start") || load.contains("not starting:"), "\(load)")
        #expect(calls.contains("\"name\": \"report\""), "no report call")
    }
}
