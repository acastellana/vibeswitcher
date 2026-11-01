import Foundation
import Testing
@testable import VibeCore

/// Codex workers for bounded tasks (boost release 3b, 2026-11-01: two Claude limits stopped work, and the user asked to
/// spread usage across accounts): a task's `agent` codex starts the Codex CLI in its worktree with the same brief, the
/// VibeSwitcher tool server and a sandbox; a Claude verifier always audits it. Fake sessions, and a fake Codex binary
/// (a script that keeps the arguments it was given) where the command line itself is run.
struct CodexWorkerTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("codex")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func task(_ slug: String, _ root: String) -> LeadTask? { BoardStore(root: root).load().task(slug) }

    /// A stand-in for Codex: writes each argument it was given, NUL-separated, to `log`, and exits.
    func fakeCodex(log: String) throws -> String {
        let path = temp.url("bin/codex").path
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s\\0' \"$@\" > '\(log)'\n".write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    /// The `-c key=value` overrides in `arguments`, by key, and the rest of the options.
    func overrides(_ arguments: [String]) -> [String: String] {
        var found: [String: String] = [:]
        for (index, word) in arguments.enumerated() where word == "-c" && index + 1 < arguments.count {
            let pair = arguments[index + 1]
            guard let equals = pair.firstIndex(of: "=") else { continue }
            found[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        return found
    }

    func json<T>(_ text: String?) throws -> T {
        let text = try #require(text)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) as? T)
    }

    @Test func aCodexTaskStartsCodexInItsWorktreeWithTheBriefTheToolServerAndTheSandbox() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let log = temp.url("codex-args").path
        runtime.codex = try fakeCodex(log: log) + " --yolo -s danger-full-access --model o3 -c model_reasoning_effort=high"
        let lead = try lead(root, runtime)
        let added = lead.call("add_task", ["title": "Rename x", "goal": "x is y", "acceptance": ["grep -q y a.txt"], "agent": "codex",
                                           "model": "gpt-5.5"])
        #expect(!added.isError && added.text.contains("review audit") && added.text.contains("Its worker is Codex"), "\(added.text)")
        #expect(task("rename-x", root)?.agent == .codex && task("rename-x", root)?.reviewLevel == .audit)
        let kept = try vault.unaudited(root: root, task: "rename-x").review
        #expect(kept == .audit)

        let started = lead.call("start_worker", ["task": "rename-x"])
        #expect(!started.isError, "\(started.text)")
        #expect(started.text.contains("Codex implements it; a Claude verifier audits it"), "\(started.text)")
        let worktree = Worktrees.path(root: root, slug: "rename-x")
        let spawn = try #require(runtime.spawned.last)
        #expect(spawn.cwd == worktree && spawn.label == "Worker: Rename x")
        #expect(runtime.agents[spawn.id] == "codex")
        // Codex is told the worktree is trusted on its command line: no trust question answered on its screen.
        #expect(!spawn.trust)
        #expect(task("rename-x", root)?.codexWorked == true && task("rename-x", root)?.launchedModels?[spawn.id] == "codex:gpt-5.5")

        // The command line, run as the session host runs it, reaches Codex as these arguments.
        let shell = Shell.run(executable: "/bin/sh", args: ["-c", spawn.command], in: worktree, env: [:], timeout: 60)
        #expect(shell.status == 0, "\(shell.error)")
        let arguments = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\0", omittingEmptySubsequences: false).map(String.init).dropLast()
        let words = Array(arguments)
        // The project's flags that would loosen the sandbox, or clash with the worker's, are gone; its others stay.
        #expect(!words.contains("--yolo") && !words.contains("danger-full-access") && !words.contains("o3"), "\(words)")
        #expect(words.filter { $0 == "--sandbox" || $0 == "-s" }.count == 1 && words.filter { $0 == "--model" || $0 == "-m" }.count == 1)
        for (flag, value) in [("--sandbox", "workspace-write"), ("--ask-for-approval", "never"), ("--cd", worktree), ("--model", "gpt-5.5")] {
            let index = try #require(words.firstIndex(of: flag), "\(flag) in \(words)")
            #expect(words[index + 1] == value)
        }
        #expect(words.contains("--no-daemon"))
        #expect(words.last?.hasPrefix("Start on your task (it's in your instructions).") == true && words[words.count - 2] == "--")
        let config = overrides(words)
        #expect(config["model_reasoning_effort"] == "high")
        // The brief, whole, as Codex's developer instructions, with its Codex part.
        let brief: String = try json(config["developer_instructions"])
        #expect(brief == LeadPrompts.worker(task: try #require(task("rename-x", root)), root: root, workflow: lead.workflow), "brief differs")
        #expect(brief.contains("You run in the Codex CLI") && brief.contains("agent/rename-x"))
        // The tool server: the worker's role, scoped to this repository and task, as a Claude worker's.
        let server: String = try json(config["mcp_servers.vibeswitcher.command"])
        let serverArgs: [String] = try json(config["mcp_servers.vibeswitcher.args"])
        #expect(server == runtime.server)
        #expect(serverArgs == [MCPKeeper.flag, "--role", "worker", "--root", root, "--task", "rename-x"])
        // The sandbox: the worktree, its git folder, the objects and the agent/ refs, its TMPDIR; no network.
        let common = root + "/.git"
        let writable: [String] = try json(config["sandbox_workspace_write.writable_roots"])
        let tmp = try #require(runtime.environments[spawn.id]?["TMPDIR"]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        #expect(writable.contains(common + "/worktrees/rename-x") && writable.contains(common + "/objects")
                && writable.contains(common + "/refs/heads/agent") && writable.contains("/" + tmp), "\(writable)")
        #expect(!writable.contains(common) && !writable.contains(common + "/refs/heads") && !writable.contains(root), "\(writable)")
        #expect(config["sandbox_workspace_write.network_access"] == "false")
        #expect(config["projects.\"\(worktree)\".trust_level"] == "\"trusted\"")
        // The worker's environment, as a Claude worker's.
        #expect(runtime.environments[spawn.id]?["GIT_EDITOR"] == "true" && runtime.environments[spawn.id]?[SessionNote.roleVariable] == "worker")
    }

    @Test func aCodexWorkerReportsAndAutoAdvanceAuditsItWithAClaudeVerifierAndSendsFindingsBack() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.power = { nil }
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "true"]).isError)
        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "agent": "codex"])
        #expect(advancing.until { task("add-b", root)?.status == .running })
        let worker = try #require(task("add-b", root)?.worker)
        #expect(runtime.agents[worker] == "codex")
        // The Codex worker's own tool server: progress and report, as any worker's.
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b"], in: worktree)
        let seat = try seat("worker-add-b", runtime)
        #expect(!seat.call("progress", ["text": "b.txt added"]).isError)
        let report = seat.call("report", doneReport("added b.txt"))
        #expect(!report.isError, "\(report.text)")
        // Audited, by a Claude verifier, though nobody set review audit.
        #expect(advancing.until { vault.current(.verifier, root: root, task: "add-b") != nil })
        let verifier = try #require(task("add-b", root)?.verifier)
        #expect(runtime.agents[verifier] == "claude")
        #expect(try #require(runtime.spawned.first { $0.id == verifier }).command.hasPrefix("claude"))
        // Its findings go back to the Codex worker.
        let finding: [String: Any] = ["severity": "Important", "file": "b.txt", "line": 1, "evidence": "b.txt says bee, the contract wants b",
                                      "failure_scenario": "cat b.txt gives bee where the contract wants b", "status": "open"]
        let verdict = try self.seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "one problem",
                                                                                    "tests": "passed", "findings": [finding]])
        #expect(!verdict.isError, "\(verdict.text)")
        #expect(advancing.until {
            runtime.calls.lock()
            defer { runtime.calls.unlock() }
            return runtime.steered.contains { $0.target == worker && $0.text.contains("F1") }
        })
        #expect(task("add-b", root)?.status == .running && !Git.run(["show", "main:b.txt"], in: root).ok)
    }

    @Test func mergeRefusesACodexTaskWithoutAPassingAuditAndItsReviewCantBeLowered() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.power = { nil }
        #expect(!lead.call("configure", ["test_command": "true"]).isError)
        // Review none isn't taken for a Codex task.
        let refused = lead.call("add_task", ["title": "Add b", "goal": "g", "acceptance": ["a"], "agent": "codex", "review": "none"])
        #expect(refused.isError && refused.text.contains("always audited"), "\(refused.text)")
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        #expect(task("add-b", root)?.reviewLevel == LeadTask.Review.none)
        let switched = lead.call("update_task", ["task": "add-b", "agent": "codex"])
        #expect(!switched.isError && switched.text.contains("agent codex"), "\(switched.text)")
        let kept = try vault.unaudited(root: root, task: "add-b").review
        #expect(task("add-b", root)?.reviewLevel == .audit && kept == .audit)
        let lowered = lead.call("update_task", ["task": "add-b", "review": "none"])
        #expect(lowered.isError && lowered.text.contains("Its worker is Codex"), "\(lowered.text)")
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b"], in: worktree)
        #expect(!(try seat("worker-add-b", runtime)).call("report", doneReport("added b.txt")).isError)
        // Back on Claude, even its review lowered in the vault by hand: Codex worked on it, so it's audited.
        #expect(!lead.call("update_task", ["task": "add-b", "agent": "claude"]).isError)
        let stillLocked = lead.call("update_task", ["task": "add-b", "review": "none"])
        #expect(stillLocked.isError && stillLocked.text.contains("A Codex worker worked on it"), "\(stillLocked.text)")
        try vault(for: runtime).setReview(.none, root: root, task: "add-b")
        try BoardStore(root: root).update { board in board.tasks[board.taskIndex("add-b")!].review = LeadTask.Review.none }
        let merge = lead.call("merge", ["task": "add-b"])
        #expect(merge.isError && merge.text.contains("A Codex worker worked on it"), "\(merge.text)")
        #expect(!Git.run(["show", "main:b.txt"], in: root).ok)
    }

    @Test func statusAndBoardNameEachTasksAgentAndTheMacsLimitCountsCodexWorkers() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "By codex", "goal": "g", "acceptance": ["a"], "agent": "codex"])
        _ = lead.call("add_task", ["title": "By claude", "goal": "g", "acceptance": ["a"]])
        let status = lead.call("status", [:]).text
        #expect(status.contains("by-codex: By codex — worker: Codex") && status.contains("by-claude: By claude — worker: Claude"), "\(status)")
        let board = lead.call("board", [:]).text
        #expect(board.contains("worker: Codex") && board.contains("worker: Claude"), "\(board)")
        let detail = lead.call("board", ["task": "by-codex"]).text
        #expect(detail.contains("Worker: Codex (Its worker is Codex, so a Claude verifier audits it"), "\(detail)")
        // One Mac-wide place: the Codex worker takes it, and the Claude one waits.
        lead.macLimits = { MacLimits(maxSessions: 1) }
        #expect(!lead.call("start_worker", ["task": "by-codex"]).isError)
        let census = try runtime.census()
        #expect(census?.first { $0.role == .worker }?.sessions == 1)
        let full = lead.call("start_worker", ["task": "by-claude"])
        #expect(full.isError && full.text.contains("mac_max_sessions"), "\(full.text)")
    }

    @Test func nearAClaudeLimitACodexTaskStillStartsAndTheRefusalSuggestsCodex() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        UsageStatusLine.run(input: Data(AccountUsageTests.statusLine(weekly: 90, resets: Date().timeIntervalSince1970 + 86_400).utf8),
                            store: usageStore, home: temp.url("no-home").path) { _ in }
        _ = lead.call("add_task", ["title": "On claude", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("add_task", ["title": "On codex", "goal": "g", "acceptance": ["a"], "agent": "codex"])
        let refused = lead.call("start_worker", ["task": "on-claude"])
        #expect(refused.isError && refused.text.contains("update_task(on-claude, agent: codex)"), "\(refused.text)")
        let started = lead.call("start_worker", ["task": "on-codex"])
        #expect(!started.isError, "\(started.text)")
    }

    @Test func aClaudeWorkersBriefHasNoCodexPartAndACodexOnesListsWhatCodexCantEnforce() throws {
        let root = try repo()
        var task = LeadTask(slug: "t", title: "T", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        let claude = LeadPrompts.worker(task: task, root: root, workflow: LeadWorkflow(), policy: "", lints: [], screenshots: .some(nil))
        #expect(!claude.contains("Codex"))
        task.agent = .codex
        let codex = LeadPrompts.worker(task: task, root: root, workflow: LeadWorkflow(), policy: "", lints: [], screenshots: .some(nil))
        #expect(codex.contains("You run in the Codex CLI"))
        for rule in LeadLaunch.codexUnenforced { #expect(codex.contains(rule.rule)) }
    }

    @Test func theWritableRootsAreTheWorktreesOwnGitFoldersNeverTheRepositorysOthers() throws {
        let root = try repo()
        let worktree = try Worktrees.open(root: root, slug: "w", base: "main")
        try FileManager.default.createDirectory(atPath: root + "/.vibeswitcher/module-cache", withIntermediateDirectories: true)
        let roots = LeadLaunch.codexWritableRoots(cwd: worktree, slug: "w", temporary: "/tmp/x", root: root)
        #expect(roots == [root + "/.git/worktrees/w", root + "/.git/objects", root + "/.git/refs/heads/agent", root + "/.git/logs/refs/heads/agent",
                          "/tmp/x", root + "/.vibeswitcher/module-cache"], "\(roots)")
    }
}
