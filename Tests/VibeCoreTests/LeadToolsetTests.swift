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
        spawned.map { LeadSessionInfo(id: $0.id, cwd: $0.cwd, label: $0.label, live: !killed.contains($0.id), status: "working", tty: nil) }
    }
    func transcript(of session: String) -> String? { transcripts[session] }
    func currentAgent() -> LeadAgent? { me }
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
}

