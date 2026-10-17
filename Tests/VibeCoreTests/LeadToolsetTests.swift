import Foundation
import Testing
@testable import VibeCore

final class FakeRuntime: LeadRuntime {
    var spawned: [(id: String, cwd: String, command: String, label: String)] = []
    var killed: [String] = []
    var delivery = LeadDelivery.Delivered.steered
    var steered: [(target: String, sender: SteerMessage.Sender, text: String)] = []
    var transcripts: [String: String] = [:]
    var me = LeadAgent(pid: 4242, tty: "ttys040", session: "lead-session")
    var leadRunning = true
    /// Sessions that don't end when killed.
    var stubborn: Set<String> = []

    let server = "/App/vibeswitcher-mcp"
    func claudeCommand(root: String) -> String { "claude --dangerously-skip-permissions" }
    func spawn(cwd: String, command: String, label: String, agent: String) throws -> String {
        let id = "session-\(spawned.count + 1)"
        spawned.append((id, cwd, command, label))
        return id
    }
    func kill(_ session: String) { killed.append(session) }
    func steer(_ target: LeadTarget, from sender: SteerMessage.Sender, text: String) throws -> LeadDelivery.Delivered {
        let name: String
        switch target {
        case .session(let id): name = id
        case .agent(let agent): name = "agent:\(agent.pid)"
        }
        steered.append((name, sender, text))
        return delivery
    }
    func sessions() -> [LeadSessionInfo] {
        spawned.map { LeadSessionInfo(id: $0.id, cwd: $0.cwd, label: $0.label, live: !killed.contains($0.id) || stubborn.contains($0.id), status: "working", tty: nil) }
    }
    func transcript(of session: String) -> String? { transcripts[session] }
    func currentAgent() -> LeadAgent? { me }
    func isRunning(_ agent: LeadAgent) -> Bool { leadRunning }
}

struct LeadToolsetTests {
    func repo() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func call(_ tools: LeadToolset, _ name: String, _ arguments: [String: Any] = [:]) -> MCPToolResult { tools.call(name, arguments) }

    @Test func eachRoleSeesItsOwnTools() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let names = { (role: LeadLaunch.Role) in Set(LeadToolset(role: role, root: root, task: "t", runtime: runtime).tools.map(\.name)) }
        #expect(names(.lead).isSuperset(of: ["status", "add_task", "start_worker", "audit", "merge", "cleanup", "ask_user", "post_update", "message"]))
        #expect(!names(.lead).contains("submit_audit"))
        #expect(names(.worker) == ["report", "ask_lead"])
        #expect(names(.verifier) == ["submit_audit"])
    }

    @Test func theWholeLoop() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        try "---\nmax_workers: 2\ntest_command: test -f b.txt\nverifier_model: sonnet\n---".write(
            toFile: root + "/.vibeswitcher-workflow-seed", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/.vibeswitcher", withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: root + "/.vibeswitcher-workflow-seed", toPath: root + "/.vibeswitcher/workflow.md")
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: runtime)
        // The lead records who it is, so answers and events can reach it.
        #expect(BoardStore(root: root).load().leadPid == 4242)

        let added = call(lead, "add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "boundaries": ["only b.txt"]])
        #expect(!added.isError)
        #expect(added.text.contains("add-b"))

        let started = call(lead, "start_worker", ["task": "add-b"])
        #expect(!started.isError, "\(started.text)")
        let worktree = Worktrees.path(root: root, slug: "add-b")
        #expect(runtime.spawned.first?.cwd == worktree)
        #expect(runtime.spawned.first?.command.contains("--name 'worker-add-b'") == true)
        #expect(BoardStore(root: root).load().task("add-b")?.status == .running)

        // The worker does the work and reports.
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b"], in: worktree)
        let worker = LeadToolset(role: .worker, root: root, task: "add-b", runtime: runtime)
        #expect(!call(worker, "report", ["status": "done", "summary": "added b.txt"]).isError)
        #expect(BoardStore(root: root).load().task("add-b")?.status == .review)
        #expect(runtime.steered.last?.target == "agent:4242")
        #expect(runtime.steered.last?.text.contains("audit") == true)

        // Merging before a passing audit is refused.
        #expect(call(lead, "merge", ["task": "add-b"]).isError)

        let audit = call(lead, "audit", ["task": "add-b"])
        #expect(!audit.isError, "\(audit.text)")
        #expect(runtime.spawned.last?.command.contains("--model 'sonnet'") == true)
        #expect(runtime.spawned.last?.cwd == worktree)
        let verifier = LeadToolset(role: .verifier, root: root, task: "add-b", runtime: runtime)
        #expect(!call(verifier, "submit_audit", ["completion": "complete", "integrity": "clean", "summary": "test -f b.txt passes"]).isError)
        #expect(BoardStore(root: root).load().task("add-b")?.evidence?.passes == true)
        #expect(runtime.steered.last?.text.contains("merge") == true)

        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(FileManager.default.fileExists(atPath: root + "/b.txt"))
        #expect(BoardStore(root: root).load().task("add-b")?.status == .done)

        #expect(!call(lead, "cleanup", ["task": "add-b"]).isError)
        #expect(!FileManager.default.fileExists(atPath: worktree))
        #expect(Set(runtime.killed) == Set(runtime.spawned.map(\.id)))
    }

    @Test func workersAreLimitedAndQuestionsDontBlock() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: runtime)
        for title in ["One", "Two", "Three", "Four"] {
            _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]])
        }
        for slug in ["one", "two", "three"] { #expect(!call(lead, "start_worker", ["task": slug]).isError) }
        let fourth = call(lead, "start_worker", ["task": "four"])
        #expect(fourth.isError)
        #expect(fourth.text.contains("3"))

        let asked = call(lead, "ask_user", ["question": "Postgres or SQLite?", "options": ["Postgres", "SQLite"]])
        #expect(!asked.isError)
        #expect(asked.text.contains("Keep working"))
        #expect(BoardStore(root: root).load().questions.first?.options == ["Postgres", "SQLite"])
    }

    @Test func aFailedAuditSendsTheTaskBackWithTheReasons() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: runtime)
        _ = call(lead, "add_task", ["title": "Fix", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "fix"])
        _ = call(lead, "audit", ["task": "fix"])
        let verifier = LeadToolset(role: .verifier, root: root, task: "fix", runtime: runtime)
        _ = call(verifier, "submit_audit", ["completion": "incomplete", "integrity": "suspect", "summary": "tests were deleted"])
        let task = BoardStore(root: root).load().task("fix")
        #expect(task?.status == .failed)
        #expect(runtime.steered.last?.text.contains("tests were deleted") == true)
        #expect(call(lead, "merge", ["task": "fix"]).isError)
    }

    @Test func statusSummarizesTheBoard() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: runtime)
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        _ = call(lead, "ask_user", ["question": "Which?"])
        let status = call(lead, "status").text
        #expect(status.contains("one") && status.contains("running") && status.contains("Which?"))
    }

    /// A task taken to a passing audit, with its worker's worktree.
    func audited(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String, slug: String = "add-b") throws -> String {
        _ = call(lead, "add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"]])
        _ = call(lead, "start_worker", ["task": slug])
        let worktree = Worktrees.path(root: root, slug: slug)
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b"], in: worktree)
        _ = call(LeadToolset(role: .worker, root: root, task: slug, runtime: runtime), "report", ["status": "done", "summary": "added"])
        _ = call(lead, "audit", ["task": slug])
        _ = call(LeadToolset(role: .verifier, root: root, task: slug, runtime: runtime), "submit_audit",
                 ["completion": "complete", "integrity": "clean", "summary": "checked"])
        return worktree
    }

    @Test func commitsTheVerifierDidntSeeAreNotMerged() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: runtime)
        let worktree = try audited(lead, runtime, root: root)
        #expect(BoardStore(root: root).load().task("add-b")?.evidence?.commit == Git.run(["rev-parse", "agent/add-b"], in: root).output)
        // After the audit the worker commits once more.
        try "unchecked\n".write(toFile: worktree + "/c.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "c.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "late"], in: worktree)
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(merged.isError)
        #expect(merged.text.contains("audit"))
        #expect(!FileManager.default.fileExists(atPath: root + "/c.txt"))
        #expect(!FileManager.default.fileExists(atPath: root + "/b.txt"))
    }

    @Test func aNewReportNeedsANewAudit() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: runtime)
        _ = try audited(lead, runtime, root: root)
        _ = call(LeadToolset(role: .worker, root: root, task: "add-b", runtime: runtime), "report", ["status": "done", "summary": "one more fix"])
        #expect(BoardStore(root: root).load().task("add-b")?.evidence == nil)
        #expect(call(lead, "merge", ["task": "add-b"]).isError)
    }

    @Test func workersAndVerifiersActOnlyOnTheirOwnTask() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: runtime)
        for title in ["One", "Two"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        for slug in ["one", "two"] { _ = call(lead, "start_worker", ["task": slug]) }
        _ = call(LeadToolset(role: .worker, root: root, task: "one", runtime: runtime), "report", ["task": "two", "status": "blocked", "summary": "x"])
        _ = call(LeadToolset(role: .verifier, root: root, task: "one", runtime: runtime), "submit_audit",
                 ["task": "two", "completion": "complete", "integrity": "clean", "summary": "x"])
        let board = BoardStore(root: root).load()
        #expect(board.task("two")?.status == .running)
        #expect(board.task("two")?.evidence == nil)
        #expect(board.task("one")?.evidence != nil)
    }

    @Test func aSecondWorkerIsNotStartedOverALiveOne() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: runtime)
        _ = call(lead, "add_task", ["title": "Fix", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "fix"])
        _ = call(lead, "update_task", ["task": "fix", "status": "failed"])
        let again = call(lead, "start_worker", ["task": "fix"])
        #expect(again.isError)
        #expect(runtime.spawned.count == 1)
        _ = call(lead, "stop_worker", ["task": "fix"])
        #expect(!call(lead, "start_worker", ["task": "fix"]).isError)
        #expect(BoardStore(root: root).load().task("fix")?.worker == "session-2")
    }

    @Test func messagesSayHowTheyWereDelivered() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: runtime)
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        runtime.delivery = .queued
        let queued = call(lead, "message", ["task": "one", "text": "1. Fix the test"])
        #expect(!queued.isError)
        #expect(queued.text.contains("waits"))
        runtime.delivery = .typed
        #expect(call(lead, "message", ["task": "one", "text": "go on"]).text.contains("prompt"))
        #expect(runtime.steered.count == 2)
    }

    @Test func oneMergeOfATaskAtATime() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: runtime)
        _ = try audited(lead, runtime, root: root)
        let held = FileLock.attempt(root + "/.vibeswitcher/run/merge-add-b.lock")
        #expect(held != nil)
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(merged.isError)
        #expect(merged.text.contains("already"))
        held?.release()
        #expect(!call(lead, "merge", ["task": "add-b"]).isError)
    }

    @Test func aReportWithNoLeadRunningSaysSo() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: runtime)
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        runtime.leadRunning = false
        let reported = call(LeadToolset(role: .worker, root: root, task: "one", runtime: runtime), "report", ["status": "done", "summary": "x"])
        #expect(!reported.isError)
        #expect(reported.text.contains("no lead"))
        #expect(runtime.steered.isEmpty)
        // It's on the board for the next lead.
        #expect(BoardStore(root: root).load().task("one")?.status == .review)
    }

    @Test func cleanupWaitsForItsSessionsToEnd() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: runtime)
        lead.stopWait = 0.3
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        runtime.stubborn = ["session-1"]
        // Its worker is still writing there: the worktree isn't removed under it.
        let cleaned = call(lead, "cleanup", ["task": "one", "force": true])
        #expect(cleaned.isError)
        #expect(FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: "one")))
        runtime.stubborn = []
        #expect(!call(lead, "cleanup", ["task": "one", "force": true]).isError)
        #expect(!FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: "one")))
    }

    @Test func theLeadWorksOnTheBranchThatWasCheckedOut() throws {
        let root = try repo()
        Git.run(["checkout", "-q", "-b", "feature"], in: root)
        try "f\n".write(toFile: root + "/f.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "f.txt"], in: root)
        Git.run(["commit", "-q", "-m", "feature work"], in: root)
        let runtime = FakeRuntime()
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: runtime)
        #expect(BoardStore(root: root).load().baseBranch == "feature")
        let worktree = try audited(lead, runtime, root: root)
        // The worker started from feature (it has feature's work).
        #expect(FileManager.default.fileExists(atPath: worktree + "/f.txt"))
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(merged.text.contains("feature"))
        #expect(FileManager.default.fileExists(atPath: root + "/b.txt"))
        #expect(Git.run(["rev-parse", "feature"], in: root).output == Git.run(["rev-parse", "agent/add-b"], in: root).output)
        // main didn't move.
        #expect(Git.run(["ls-tree", "--name-only", "main"], in: root).output == "a.txt")
        // Workers may not switch to it.
        #expect(runtime.spawned.first.map { _ in try? String(contentsOfFile: root + "/.vibeswitcher/run/worker-add-b/settings.json", encoding: .utf8) }??.contains("git switch feature") == true)
    }

    @Test func theWorkflowCanNameTheBranch() throws {
        let root = try repo()
        Git.run(["branch", "release"], in: root)
        try BoardStore(root: root).prepare()
        try "---\nbase_branch: release\n---".write(toFile: root + "/.vibeswitcher/workflow.md", atomically: true, encoding: .utf8)
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: FakeRuntime())
        #expect(lead.base == "release")
    }

    // MARK: The lead's own workflow

    @Test func onlyTheLeadConfiguresTheWorkflow() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        #expect(LeadToolset(role: .lead, root: root, task: nil, runtime: runtime).tools.contains { $0.name == "configure" })
        for role in [LeadLaunch.Role.worker, .verifier] {
            let tools = LeadToolset(role: role, root: root, task: "t", runtime: runtime)
            #expect(!tools.tools.contains { $0.name == "configure" })
            #expect(call(tools, "configure", ["test_command": "true"]).isError)
        }
        #expect(LeadWorkflow.load(from: root + "/.vibeswitcher/workflow.md").testCommand == nil)
    }

    @Test func statusSaysThereIsNoTestCommandAndSuggestsOne() throws {
        let root = try repo()
        try "// swift-tools-version:5.9\n".write(toFile: root + "/Package.swift", atomically: true, encoding: .utf8)
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: FakeRuntime())
        let status = call(lead, "status").text
        #expect(status.contains("No test_command"))
        #expect(status.contains("`swift build && swift test`"))
        #expect(status.contains("configure"))
        // Once it's set, status stops saying so.
        #expect(!call(lead, "configure", ["test_command": "swift build && swift test"]).isError)
        #expect(!call(lead, "status").text.contains("No test_command"))
    }

    @Test func statusReportsAWorkflowItCantRead() throws {
        let root = try repo()
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: FakeRuntime())
        try "test_command: true\nno front matter here".write(toFile: root + "/.vibeswitcher/workflow.md", atomically: true, encoding: .utf8)
        let status = call(lead, "status").text
        #expect(status.contains("front matter"))
        #expect(status.contains("No test_command"))
    }

    @Test func configureShowsAndSetsTheSettingsKeepingTheRestOfTheFile() throws {
        let root = try repo()
        Git.run(["branch", "dev"], in: root)
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: FakeRuntime())
        let path = root + "/.vibeswitcher/workflow.md"
        let original = LeadWorkflow.template.replacingOccurrences(of: "\n", with: "\r\n").replacingOccurrences(of: "worker_agent: claude", with: "worker_agent: claude\r\nteam_size_hint: 7")
            + "\r\nKeep the API stable.\r\n"
        try Data(original.utf8).write(to: URL(fileURLWithPath: path))

        let shown = call(lead, "configure")
        #expect(!shown.isError)
        #expect(shown.text.contains("test_command: not set"))
        #expect(shown.text.contains("max_workers: 3"))
        #expect(shown.text.contains("base_branch: not set: main"))

        let set = call(lead, "configure", ["test_command": "swift build && swift test", "init_command": "make deps", "base_branch": "dev",
                                           "verifier_model": "opus", "max_workers": 4])
        #expect(!set.isError, "\(set.text)")
        #expect(set.text.contains("test_command = `swift build && swift test`"))
        let workflow = LeadWorkflow.load(from: path)
        #expect(workflow.testCommand == "swift build && swift test" && workflow.initCommand == "make deps" && workflow.baseBranch == "dev"
                && workflow.verifierModel == "opus" && workflow.maxWorkers == 4 && workflow.problem == nil)
        #expect(lead.base == "dev")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        // Comments, the unknown key, the notes and the CRLF endings are untouched.
        #expect(text.contains("# The project's checks."))
        #expect(text.contains("team_size_hint: 7\r\n"))
        #expect(text.hasSuffix("Keep the API stable.\r\n"))
        #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(text.components(separatedBy: "\r\n").count == original.components(separatedBy: "\r\n").count)

        // An empty value clears one.
        #expect(!call(lead, "configure", ["verifier_model": ""]).isError)
        #expect(LeadWorkflow.load(from: path).verifierModel == nil)
    }

    @Test func configureRefusesWhatWouldBreakTheWorkflow() throws {
        let root = try repo()
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: FakeRuntime())
        let path = root + "/.vibeswitcher/workflow.md"
        let before = try String(contentsOfFile: path, encoding: .utf8)
        for arguments: [String: Any] in [["max_workers": 0], ["max_workers": "many"], ["base_branch": "no-such-branch"],
                                         ["test_command": "swift test\nrm x"], ["worker_agent": "codex"]] {
            #expect(call(lead, "configure", arguments).isError, "\(arguments)")
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == before)
    }

    @Test func aMergeWithoutATestCommandSaysSo() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: runtime)
        _ = try audited(lead, runtime, root: root)
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(merged.text.contains("merged without tests: no test_command"))
    }

    @Test func aCRLFWorkflowStillTestsTheMerge() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = LeadToolset(role: .lead, root: root, task: nil, runtime: runtime)
        // Written on Windows, with a BOM: the test command must still run (and here it fails).
        try (Data([0xEF, 0xBB, 0xBF]) + Data("---\r\ntest_command: test -f missing.txt\r\n---\r\n".utf8))
            .write(to: URL(fileURLWithPath: root + "/.vibeswitcher/workflow.md"))
        _ = try audited(lead, runtime, root: root)
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(merged.isError)
        #expect(merged.text.contains("test command fails"))
        #expect(!FileManager.default.fileExists(atPath: root + "/b.txt"))
    }
}

