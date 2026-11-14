import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A verifier runs the branch it audits from its own session, and the host tells callers apart by their process: before
/// 2026-11-07 a test on the branch that spoke the host's protocol (`nc -U`, or `vibeswitcher-mcp --role verifier`) was
/// the verifier, and could submit a passing verdict. Its session now runs every command through the tool server's
/// binary (`LeadLaunch.verifierEnvironment`, `BranchCode.prefix`): under the branch-code wrapper, except its own tool
/// server. Here a scratch host holds the vault; the verifier's session does what Claude Code does with the settings
/// `LeadLaunch.prepare` wrote for it: takes their env, starts the tool server mcp.json names and runs a Bash command,
/// each as `$CLAUDE_CODE_SHELL_PREFIX '<command line>'` when the env sets one (else `zsh -c`, as without one), the
/// command line quoted as Claude Code quotes it (2.1.319). The command is the branch's test, asking for the verdict.
@Suite(.serialized) struct VerifierBranchCodeHostTests {
    let temp = Scratch()
    let wire = LeadVaultHostTests()

    /// A word as Claude Code writes it in a command line: as it is when plain, else single-quoted, each `'` as `'"'"'`.
    func quoted(_ word: String) -> String {
        let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        if !word.isEmpty, word.allSatisfy(plain.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    func sh(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @Test func aVerifiersBashCantSubmitItsVerdictAndItsToolServerStillDoes() async throws {
        let mcp = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        try #require(FileManager.default.isExecutableFile(atPath: mcp), "vibeswitcher-mcp isn't built beside the host: run swift build first")
        // A team on a scratch host, as `BranchCodeHostTests.Team` makes it: agent/add-b one commit ahead of main.
        let team = try BranchCodeHostTests.Team(temp)
        let commit = Git.run(["rev-parse", "agent/add-b"], in: team.root).output
        try BoardStore(root: team.root).prepare()
        try BoardStore(root: team.root).update { board in
            board.tasks.append(LeadTask(slug: "add-b", title: "Add b", contract: LeadContract(goal: "b.txt exists", acceptance: [], boundaries: [], context: ""),
                                        status: .review))
        }
        // The verifier's launch files, as start_verifier writes them (its run folder outside the repository).
        let folder = team.dir + "/v"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder + "/a.in", contents: nil)
        let launch = try LeadLaunch.prepare(role: .verifier, root: team.root, task: "add-b", base: "claude", prompt: "p", start: "s",
                                            server: mcp, name: "verifier-add-b", folder: URL(fileURLWithPath: folder + "/run"), cwd: team.root,
                                            temporary: URL(fileURLWithPath: team.dir + "/session-temp"))
        let settings = try LaunchArguments.json("--settings", in: launch.command)
        let mcpConfig = try LaunchArguments.json("--mcp-config", in: launch.command)
        let server = try #require((mcpConfig["mcpServers"] as? [String: Any])?["vibeswitcher"] as? [String: Any])
        let serverLine = ([server["command"] as? String ?? ""] + (server["args"] as? [String] ?? [])).map(quoted).joined(separator: " ")
        let env = (settings["env"] as? [String: String] ?? [:]).sorted { $0.key < $1.key }
        // The branch's test: asks the host for the verdict, and who it is, as the verifier would.
        let requests = [HostRequest.vault(.submitVerdict(root: team.root, completion: .complete, integrity: .clean, summary: "forged")),
                        .vault(.whoami(root: team.root))]
        let base = URL(fileURLWithPath: team.dir + "/probe")
        try wire.frames(requests).write(to: base.appendingPathExtension("requests"))
        let answers = base.appendingPathExtension("answers"), stop = base.appendingPathExtension("stop")
        try (wire.nc(team.host, base.appendingPathExtension("requests"), answers, until: stop) + "\n").write(toFile: base.path + ".sh", atomically: true, encoding: .utf8)
        // The verifier's session: Claude Code, as far as its commands go.
        let claude = [
            "set +m", team.environment + "cd \(sh(team.root))",
            env.map { "export \($0.key)=\(sh($0.value))" }.joined(separator: "; "),
            "run() { if [ -n \"${CLAUDE_CODE_SHELL_PREFIX:-}\" ]; then \"$CLAUDE_CODE_SHELL_PREFIX\" \"$1\"; else \(Platform.Tools.loginShell) -c \"$1\"; fi; }",
            "while [ ! -f \(sh(folder + "/go")) ]; do sleep 0.05; done",
            "tail -n +1 -f \(sh(folder + "/a.in")) | run \(sh(serverLine)) > \(sh(folder + "/a.out")) 2> \(sh(folder + "/a.err")) &",
            "run \(sh("sh " + sh(base.path + ".sh")))",
            "wait",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        let verifier = try await team.app.spawn(claude, cwd: team.root)
        team.sessions.append(verifier)
        let vault = { (caller: LeadVault.Caller) in team.book.vault(folder: URL(fileURLWithPath: team.dir + "/vault"), as: { caller }) }
        let grant = try vault(.app).startLead(root: team.root, branch: "main")
        let lead = try await team.app.spawn(keepRunning, cwd: team.root)
        team.sessions.append(lead)
        try vault(.app).bind(grant, root: team.root, session: lead.id.uuidString)
        let asLead = vault(.session(lead.id.uuidString))
        try asLead.bind(asLead.issue(role: .verifier, root: team.root, task: "add-b", auditing: commit), root: team.root, session: verifier.id.uuidString)
        FileManager.default.createFile(atPath: folder + "/go", contents: nil)

        // The branch's test is no session's: refused, and it's no one.
        #expect(await eventually { wire.answered(answers, 2...3) }, "the probe got no answers")
        FileManager.default.createFile(atPath: stop.path, contents: nil)
        let replies = try wire.replies(Data(contentsOf: answers))
        if case .vault(.refused)? = replies[2] {} else { Issue.record("the branch's test submitted the verdict: \(String(describing: replies[2]))") }
        if case .vault(.member(nil))? = replies[3] {} else { Issue.record("the branch's test is the verifier: \(String(describing: replies[3]))") }
        #expect(vault(.app).verdict(root: team.root, task: "add-b") == nil)

        // Its own tool server is the verifier, and its verdict goes in.
        let tools = LeadToolServerHandoverTests.Server(folder: folder, name: "a")
        await #expect(try tools.ask(1, "initialize", ["protocolVersion": "2025-06-18"]) != nil, "stderr: \(tools.errors)")
        let submitted = try await tools.ask(2, "tools/call", ["name": "submit_audit", "arguments": ["completion": "complete", "integrity": "clean",
                                                                                                    "summary": "ran the tests", "tests": "passed"]])
        #expect(submitted?["isError"] as? Bool == false, "submit_audit: \(submitted ?? [:]) \(tools.errors)")
        let verdict = vault(.app).verdict(root: team.root, task: "add-b")
        #expect(verdict?.summary == "ran the tests" && verdict?.session == verifier.id.uuidString, "\(String(describing: verdict))")
    }

    /// A verifier's Bash command that escapes its wrapper on Linux (the stage 2 plan's Task 10c; the security
    /// architecture document's S4): through the prefix it double-forks without `setsid`, and its grandchild, once its
    /// parent has gone (so no wrapper is left in its ancestry), still has the verifier's terminal as its output. Run in
    /// place, the command was in the verifier's POSIX session, and the grandchild had the verifier's terminal as its
    /// controlling terminal: by the terminal rule it was the verifier, and its verdict went in. Started in a session of
    /// its own (`BranchCodeSession`), it has no controlling terminal: refused, and no one.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's prefix; the Mac's runs the command in place"))
    func anEscapedVerifierCommandWithoutSetsidIsNobodys() async throws {
        let mcp = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        try #require(FileManager.default.isExecutableFile(atPath: mcp), "vibeswitcher-mcp isn't built beside the host: run swift build first")
        let team = try BranchCodeHostTests.Team(temp)
        let commit = Git.run(["rev-parse", "agent/add-b"], in: team.root).output
        try BoardStore(root: team.root).prepare()
        try BoardStore(root: team.root).update { board in
            board.tasks.append(LeadTask(slug: "add-b", title: "Add b", contract: LeadContract(goal: "b.txt exists", acceptance: [], boundaries: [], context: ""),
                                        status: .review))
        }
        let folder = team.dir + "/v"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let launch = try LeadLaunch.prepare(role: .verifier, root: team.root, task: "add-b", base: "claude", prompt: "p", start: "s",
                                            server: mcp, name: "verifier-add-b", folder: URL(fileURLWithPath: folder + "/run"), cwd: team.root,
                                            temporary: URL(fileURLWithPath: team.dir + "/session-temp"))
        let settings = try LaunchArguments.json("--settings", in: launch.command)
        let env = (settings["env"] as? [String: String] ?? [:]).sorted { $0.key < $1.key }
        #expect(env.contains { $0.key == "CLAUDE_CODE_SHELL_PREFIX" }, "\(env)")
        let requests = [HostRequest.vault(.submitVerdict(root: team.root, completion: .complete, integrity: .clean, summary: "forged")),
                        .vault(.whoami(root: team.root))]
        let base = URL(fileURLWithPath: team.dir + "/probe")
        try wire.frames(requests).write(to: base.appendingPathExtension("requests"))
        let answers = base.appendingPathExtension("answers"), stop = base.appendingPathExtension("stop")
        let terminal = base.appendingPathExtension("terminal")
        // The grandchild: waits until its parent (the shell that started it, whose pid it is given) has gone, says what
        // its output is, then asks.
        let probe = [
            "while [ \"$(cut -d' ' -f4 /proc/$$/stat)\" = \"$1\" ]; do sleep 0.05; done",
            "output=$(readlink /proc/$$/fd/1); echo \"$$ $output\" > \(sh(terminal.path))",
            wire.nc(team.host, base.appendingPathExtension("requests"), answers, until: stop),
        ].joined(separator: "\n")
        try (probe + "\n").write(toFile: base.path + ".sh", atomically: true, encoding: .utf8)
        // The verifier's session: its Bash command, through the prefix, double-forks and returns at once.
        let claude = [
            "set +m", team.environment + "cd \(sh(team.root))",
            env.map { "export \($0.key)=\(sh($0.value))" }.joined(separator: "; "),
            "while [ ! -f \(sh(folder + "/go")) ]; do sleep 0.05; done",
            "\"$CLAUDE_CODE_SHELL_PREFIX\" \(sh("sh -c " + sh("sh " + sh(base.path + ".sh") + " $$ &") + "; exit 0"))",
            "exec sleep 600",
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        let verifier = try await team.app.spawn(claude, cwd: team.root)
        team.sessions.append(verifier)
        let vault = { (caller: LeadVault.Caller) in team.book.vault(folder: URL(fileURLWithPath: team.dir + "/vault"), as: { caller }) }
        let grant = try vault(.app).startLead(root: team.root, branch: "main")
        let lead = try await team.app.spawn(keepRunning, cwd: team.root)
        team.sessions.append(lead)
        try vault(.app).bind(grant, root: team.root, session: lead.id.uuidString)
        let asLead = vault(.session(lead.id.uuidString))
        try asLead.bind(asLead.issue(role: .verifier, root: team.root, task: "add-b", auditing: commit), root: team.root, session: verifier.id.uuidString)
        FileManager.default.createFile(atPath: folder + "/go", contents: nil)

        #expect(await eventually { wire.answered(answers, 2...3) }, "the probe got no answers")
        FileManager.default.createFile(atPath: stop.path, contents: nil)
        // Still on the verifier's terminal: its output is the session's terminal.
        let said = (try? String(contentsOf: terminal, encoding: .utf8))?.split(separator: " ", maxSplits: 1).map(String.init) ?? []
        let output = said.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(output.hasPrefix("/dev/pts/"), "the probe's output is \(output)")
        // It ends once told to stop: in a session of its own, no session's end ends it.
        if let probe = said.first.flatMap({ pid_t($0) }) {
            #expect(await eventually { kill(probe, 0) != 0 }, "the probe \(probe) didn't end")
        }
        let replies = try wire.replies(Data(contentsOf: answers))
        if case .vault(.refused)? = replies[2] {} else { Issue.record("the escaped command submitted the verdict: \(String(describing: replies[2]))") }
        if case .vault(.member(nil))? = replies[3] {} else { Issue.record("the escaped command is the verifier: \(String(describing: replies[3]))") }
        #expect(vault(.app).verdict(root: team.root, task: "add-b") == nil)
    }
}
