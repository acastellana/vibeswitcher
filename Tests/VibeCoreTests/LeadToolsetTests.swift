import Foundation
import Testing
@testable import VibeCore

final class FakeRuntime: LeadRuntime {
    var spawned: [(id: String, cwd: String, command: String, label: String, trust: Bool)] = []
    var killed: [String] = []
    /// Sessions the host was told to drop.
    var forgotten: [String] = []
    var delivery = LeadDelivery.Delivered.steered
    var steered: [(target: String, sender: SteerMessage.Sender, text: String)] = []
    var clearedDrafts = 0
    var transcripts: [String: String] = [:]
    var me = LeadAgent(pid: 4242, tty: "ttys040", session: "lead-session")
    var leadRunning = true
    /// Sessions that don't end when killed.
    var stubborn: Set<String> = []
    /// Sessions whose kill the host refuses, with what it answers.
    var refusals: [String: String] = [:]
    /// Each session's process; this test's own (it runs) unless set.
    var pids: [String: Int32] = [:]
    /// Set: the session host can't be read (the error it gives).
    var hostDown: String?

    let server = "/App/vibeswitcher-mcp"
    func claudeCommand(root: String) -> String { "claude --dangerously-skip-permissions" }
    func spawn(cwd: String, command: String, label: String, agent: String, trust: Bool) throws -> String {
        let id = "session-\(spawned.count + 1)"
        spawned.append((id, cwd, command, label, trust))
        return id
    }
    func kill(_ session: String) throws {
        if let refusal = refusals[session] { throw BoardError(text: refusal) }
        killed.append(session)
    }
    func forget(_ session: String) { forgotten.append(session) }
    func steer(_ target: LeadTarget, from sender: SteerMessage.Sender, text: String, clearDraft: Bool) throws -> LeadDelivery.Delivered {
        if clearDraft { clearedDrafts += 1 }
        let name: String
        switch target {
        case .session(let id): name = id
        case .agent(let agent): name = "agent:\(agent.pid)"
        }
        steered.append((name, sender, text))
        return delivery
    }
    func sessions() throws -> [LeadSessionInfo] {
        if let hostDown { throw BoardError(text: hostDown) }
        return spawned.filter { !forgotten.contains($0.id) }.map { LeadSessionInfo(id: $0.id, cwd: $0.cwd, label: $0.label, live: !killed.contains($0.id) || stubborn.contains($0.id), status: "working", tty: nil, pid: pids[$0.id] ?? getpid()) }
    }
    func transcript(of session: String) throws -> String? {
        if let hostDown { throw BoardError(text: hostDown) }
        return transcripts[session]
    }
    func currentAgent() -> LeadAgent? { me }
    func isRunning(_ agent: LeadAgent) -> Bool { leadRunning }
}

/// The same world, seen from another session's tool server: its own agent, everything else shared.
final class FakeSeat: LeadRuntime {
    let shared: FakeRuntime
    let agent: LeadAgent
    init(_ shared: FakeRuntime, agent: LeadAgent) {
        self.shared = shared
        self.agent = agent
    }
    var server: String { shared.server }
    func claudeCommand(root: String) -> String { shared.claudeCommand(root: root) }
    func spawn(cwd: String, command: String, label: String, agent: String, trust: Bool) throws -> String {
        try shared.spawn(cwd: cwd, command: command, label: label, agent: agent, trust: trust)
    }
    func kill(_ session: String) throws { try shared.kill(session) }
    func forget(_ session: String) { shared.forget(session) }
    func steer(_ target: LeadTarget, from sender: SteerMessage.Sender, text: String, clearDraft: Bool) throws -> LeadDelivery.Delivered {
        try shared.steer(target, from: sender, text: text, clearDraft: clearDraft)
    }
    func sessions() throws -> [LeadSessionInfo] { try shared.sessions() }
    func transcript(of session: String) throws -> String? { try shared.transcript(of: session) }
    func currentAgent() -> LeadAgent? { agent }
    func isRunning(_ agent: LeadAgent) -> Bool { shared.isRunning(agent) }
}

/// The team as VibeSwitcher starts it, with a vault of its own: the book a session host would hold, asked in
/// process. Where the host tells a caller from its process, here each tool server is the session its runtime's agent
/// runs in (`vault(for:)`); `vault` is the app.
protocol LeadTeamFixture {
    var vault: LeadVault { get }
}

private let booksLock = NSLock()
nonisolated(unsafe) private var books: [String: LeadVault.Book] = [:]

extension LeadTeamFixture {
    static func newVault(in temp: Scratch) -> LeadVault {
        let folder = temp.url("vault")
        let book = LeadVault.Book()
        booksLock.lock()
        books[folder.path] = book
        booksLock.unlock()
        return book.vault(folder: folder, as: { .app })
    }

    /// The vault's book, as the session host holds it.
    var book: LeadVault.Book {
        booksLock.lock()
        defer { booksLock.unlock() }
        return books[vault.folder.path]!
    }

    /// The vault as the session host answers a process running under `runtime`'s agent: its session, or unknown.
    func vault(for runtime: LeadRuntime) -> LeadVault {
        nonisolated(unsafe) let runtime = runtime
        return book.vault(folder: vault.folder, as: { runtime.currentAgent()?.session.map { .session($0) } ?? .unknown })
    }

    /// The lead, as the app starts it: a grant bound to the lead's session.
    func lead(_ root: String, _ runtime: FakeRuntime) throws -> LeadToolset {
        let grant = try vault.startLead(root: root, branch: Worktrees.currentBranch(root: root) ?? "main")
        try vault.bind(grant, root: root, session: try #require(runtime.me.session))
        return LeadToolset(root: root, runtime: runtime, vault: vault(for: runtime))
    }

    /// What the lead last started as `name` (worker-<slug>, verify-<slug>): its session and its tool server's arguments.
    func launched(_ name: String, _ runtime: FakeRuntime) throws -> (session: String, args: [String]) {
        let spawn = try #require(runtime.spawned.last { $0.command.contains("--name '\(name)'") })
        let range = try #require(spawn.command.range(of: #"--mcp-config '([^']+)'"#, options: .regularExpression))
        let path = String(spawn.command[range].dropFirst("--mcp-config '".count).dropLast())
        let mcp = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let entry = try #require((mcp["mcpServers"] as? [String: Any])?["vibeswitcher"] as? [String: Any])
        return (spawn.id, try #require(entry["args"] as? [String]))
    }

    /// That session's own tool server, started the way Claude Code starts it, running under that session.
    func seat(_ name: String, _ runtime: FakeRuntime) throws -> LeadToolset {
        let launch = try launched(name, runtime)
        let agent = LeadAgent(pid: 5000 + Int32(runtime.spawned.count), tty: "ttys09\(runtime.spawned.count % 10)", session: launch.session)
        let seat = FakeSeat(runtime, agent: agent)
        return LeadToolset(arguments: launch.args, runtime: seat, vault: vault(for: seat))
    }

    /// A role's tool server in a session of its own, which the app (a lead) or the repository's lead (a worker or
    /// verifier; a stand-in lead when none runs) granted the role to.
    func issued(_ role: LeadLaunch.Role, task: String?, root: String, _ runtime: FakeRuntime, session: String? = nil) throws -> LeadToolset {
        // A session holds one role in a repository.
        let session = session ?? "own-\(role.rawValue)-session"
        var issuer = vault
        if role != .lead {
            let lead = try vault.current(.lead, root: root, task: nil)?.session ?? {
                let grant = try vault.issue(role: .lead, root: root, task: nil)
                try vault.bind(grant, root: root, session: "stand-in-lead")
                return "stand-in-lead"
            }()
            issuer = book.vault(folder: vault.folder, as: { .session(lead) })
        }
        let grant = try issuer.issue(role: role, root: root, task: task)
        try issuer.bind(grant, root: root, session: session)
        let seat = FakeSeat(runtime, agent: LeadAgent(pid: 6000, tty: "ttys080", session: session))
        return LeadToolset(root: root, runtime: seat, vault: vault(for: seat))
    }
}

struct LeadToolsetTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("lead")
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
        let names = { (role: LeadLaunch.Role) in Set(((try? self.issued(role, task: role == .lead ? nil : "t", root: root, runtime))?.tools ?? []).map(\.name)) }
        #expect(names(.lead).isSuperset(of: ["status", "add_task", "start_worker", "audit", "merge", "cleanup", "ask_user", "post_update", "message"]))
        #expect(!names(.lead).contains("submit_audit"))
        #expect(names(.worker) == ["report", "ask_lead", "progress"])
        #expect(names(.verifier) == ["submit_audit"])
    }

    @Test func theWholeLoop() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        try "---\nmax_workers: 2\ntest_command: test -f b.txt\nverifier_model: sonnet\n---".write(
            toFile: root + "/.vibeswitcher-workflow-seed", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/.vibeswitcher", withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: root + "/.vibeswitcher-workflow-seed", toPath: root + "/.vibeswitcher/workflow.md")
        let lead = try lead(root, runtime)
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
        let worker = try seat("worker-add-b", runtime)
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
        let verifier = try seat("verify-add-b", runtime)
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
        // Its worker and verifier leave the session list with it.
        #expect(Set(runtime.forgotten) == Set(runtime.spawned.map(\.id)))
        #expect(try runtime.sessions().isEmpty)
    }

    /// A worktree left partway through a rebase (a refused `rebase --continue`) isn't a dead end: start_worker says
    /// what it's in, and with recover aborts it, back on the branch with its commits, and starts the worker.
    @Test func startWorkerRecoversAWorktreeStuckMidRebase() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "Fix", "goal": "g", "acceptance": ["a"], "boundaries": ["b"]])
        let worktree = try Worktrees.create(root: root, slug: "fix")
        for (file, text) in [("a.txt", "worker\n"), ("f.txt", "f\n")] {
            try text.write(toFile: worktree + "/" + file, atomically: true, encoding: .utf8)
            Git.run(["add", file], in: worktree)
            Git.run(["commit", "-q", "-m", file], in: worktree)
        }
        try "main\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["commit", "-q", "-am", "main"], in: root)
        let rebase = Shell.run(executable: "/usr/bin/git", args: ["rebase", "-i", "main"], in: worktree,
                               env: ["GIT_TERMINAL_PROMPT": "0", "GIT_SEQUENCE_EDITOR": "true", "GIT_EDITOR": "true"])
        #expect(!rebase.ok)
        try "both\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: worktree)
        let head = Git.run(["rev-parse", "refs/heads/agent/fix"], in: root).output

        let refused = call(lead, "start_worker", ["task": "fix"])
        #expect(refused.isError)
        #expect(refused.text.contains("rebasing agent/fix onto") && refused.text.contains("pick 1 of 2") && refused.text.contains("Staged: a.txt"))
        #expect(refused.text.contains("recover: true"))
        #expect(!refused.text.contains("isn't the worktree"))
        #expect(runtime.spawned.isEmpty)
        #expect(Git.run(["rev-parse", "refs/heads/agent/fix"], in: root).output == head)

        let started = call(lead, "start_worker", ["task": "fix", "recover": true])
        #expect(!started.isError, "\(started.text)")
        #expect(started.text.contains("Aborted the rebase"))
        #expect(runtime.spawned.first?.cwd == worktree)
        #expect(Git.run(["rev-parse", "refs/heads/agent/fix"], in: root).output == head)
        #expect(Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree).output == "agent/fix")
        #expect(Git.run(["rev-parse", "HEAD"], in: worktree).output == head)
        #expect(BoardStore(root: root).load().task("fix")?.status == .running)
    }

    /// A merge into agent/<slug> its last worker left unfinished is the next worker's to finish: started as it is,
    /// told (as is the lead) what's staged and unresolved. recover: true aborts it instead.
    @Test func startWorkerLeavesAMergeOnTheBranchForTheWorkerToFinish() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "Fix", "goal": "g", "acceptance": ["a"], "boundaries": ["b"]])
        let worktree = try Worktrees.create(root: root, slug: "fix")
        for (dir, text) in [(worktree, "worker\n"), (root, "main\n")] {
            for file in ["a.txt", "b.txt"] { try text.write(toFile: dir + "/" + file, atomically: true, encoding: .utf8) }
            Git.run(["add", "a.txt", "b.txt"], in: dir)
            Git.run(["commit", "-q", "-m", "both files"], in: dir)
        }
        let head = Git.run(["rev-parse", "HEAD"], in: worktree).output
        #expect(!Git.run(["merge", "main"], in: worktree).ok)
        // Half resolved: a.txt staged, b.txt still conflicted.
        try "resolved\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: worktree)

        let started = call(lead, "start_worker", ["task": "fix"])
        #expect(!started.isError, "\(started.text)")
        #expect(started.text.contains("middle of a merge") && started.text.contains("Staged: a.txt; unresolved: b.txt"))
        #expect(started.text.contains("recover: true"))
        let first = try #require(runtime.spawned.first)
        #expect(first.cwd == worktree)
        #expect(first.command.contains("in the middle of a merge") && first.command.contains("Staged: a.txt; unresolved: b.txt"))
        // Nothing undone: the merge and its resolution are there for the worker.
        #expect(try String(contentsOfFile: worktree + "/a.txt", encoding: .utf8) == "resolved\n")
        #expect(Worktrees.interrupted(root: root, slug: "fix")?.kind == .merge)

        // Started again with recover (its worker gone), the merge is aborted back to the branch's head.
        runtime.killed.append(first.id)
        let recovered = call(lead, "start_worker", ["task": "fix", "recover": true])
        #expect(!recovered.isError, "\(recovered.text)")
        #expect(recovered.text.contains("Aborted the merge"))
        #expect(runtime.spawned.last?.command.contains("middle of a merge") == false)
        #expect(Worktrees.interrupted(root: root, slug: "fix") == nil)
        #expect(Git.run(["rev-parse", "refs/heads/agent/fix"], in: root).output == head)
        #expect(Git.run(["rev-parse", "HEAD"], in: worktree).output == head)
    }

    /// A folder that's another repository is still refused, recover or not, and left as it is.
    @Test func startWorkerStillRefusesAFolderThatIsntTheTasks() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "Fix", "goal": "g", "acceptance": ["a"], "boundaries": ["b"]])
        let other = Worktrees.path(root: root, slug: "fix")
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try "mine\n".write(toFile: other + "/notes.txt", atomically: true, encoding: .utf8)
        for recover in [false, true] {
            let refused = call(lead, "start_worker", ["task": "fix", "recover": recover])
            #expect(refused.isError && refused.text.contains("isn't the worktree of agent/fix"))
        }
        #expect(runtime.spawned.isEmpty)
        #expect(FileManager.default.fileExists(atPath: other + "/notes.txt"))
    }

    @Test func workersAreLimitedAndQuestionsDontBlock() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
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
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "Fix", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "fix"])
        _ = call(lead, "audit", ["task": "fix"])
        let verifier = try seat("verify-fix", runtime)
        _ = call(verifier, "submit_audit", ["completion": "incomplete", "integrity": "suspect", "summary": "tests were deleted"])
        let task = BoardStore(root: root).load().task("fix")
        #expect(task?.status == .failed)
        #expect(runtime.steered.last?.text.contains("tests were deleted") == true)
        #expect(call(lead, "merge", ["task": "fix"]).isError)
    }

    @Test func statusSummarizesTheBoard() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
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
        _ = call(try seat("worker-\(slug)", runtime), "report", ["status": "done", "summary": "added"])
        _ = call(lead, "audit", ["task": slug])
        _ = call(try seat("verify-\(slug)", runtime), "submit_audit",
                 ["completion": "complete", "integrity": "clean", "summary": "checked"])
        return worktree
    }

    @Test func commitsTheVerifierDidntSeeAreNotMerged() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
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

    /// A report on a new commit needs a new audit, and the board says the one it had is for an older commit.
    @Test func aReportOnANewCommitNeedsANewAudit() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let worktree = try audited(lead, runtime, root: root)
        let audited = String(Git.run(["rev-parse", "agent/add-b"], in: root).output.prefix(8))
        #expect(call(lead, "status").text.contains("audit clean at \(audited)"))
        try "fix\n".write(toFile: worktree + "/c.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "c.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "one more fix"], in: worktree)
        let now = String(Git.run(["rev-parse", "agent/add-b"], in: root).output.prefix(8))
        // Committed, not reported yet: the verdict is still on the board, for the older commit.
        #expect(call(lead, "board").text.contains("audit clean at \(audited), branch now at \(now)"))
        _ = call(try seat("worker-add-b", runtime), "report", ["status": "done", "summary": "one more fix"])
        let task = BoardStore(root: root).load().task("add-b")
        #expect(task?.evidence == nil)
        #expect(task?.outdatedEvidence?.commit?.hasPrefix(audited) == true)
        #expect(vault.verdict(root: root, task: "add-b") == nil)
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(merged.isError)
        #expect(merged.text.contains("audit"))
        for text in [call(lead, "status").text, call(lead, "board").text] {
            #expect(text.contains("audit clean at \(audited), branch now at \(now)"), "\(text)")
        }
        // A new verdict replaces the older one.
        _ = call(lead, "audit", ["task": "add-b"])
        _ = call(try seat("verify-add-b", runtime), "submit_audit", ["completion": "complete", "integrity": "clean", "summary": "checked again"])
        #expect(BoardStore(root: root).load().task("add-b")?.outdatedEvidence == nil)
        #expect(call(lead, "board").text.contains("audit clean at \(now)"))
        #expect(!call(lead, "board").text.contains("branch now at"))
    }

    /// 2026-10-18: the lead asked a worker whose branch had passed its audit to clear a lock and report; it reported
    /// on the same commit, and the verdict was gone. A report on the commit the audit covers leaves it standing.
    @Test func aReportOnTheAuditedCommitKeepsItsAudit() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        let head = Git.run(["rev-parse", "agent/add-b"], in: root).output
        let before = try #require(BoardStore(root: root).load().task("add-b")?.evidence)
        let worker = try seat("worker-add-b", runtime)
        let reported = call(worker, "report", ["status": "done", "summary": "Removed the stale index.lock in the main checkout."])
        #expect(!reported.isError)
        #expect(reported.text.contains("stands"), "\(reported.text)")
        #expect(runtime.steered.last?.text.contains("merge(add-b)") == true)
        _ = call(worker, "report", ["status": "done", "summary": "done"])
        let task = BoardStore(root: root).load().task("add-b")
        #expect(task?.evidence == before)
        #expect(task?.status == .review)
        #expect(vault.verdict(root: root, task: "add-b")?.commit == head)
        #expect(call(lead, "status").text.contains("audit clean at \(head.prefix(8))"))
        #expect(!call(lead, "board").text.contains("branch now at"))
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(FileManager.default.fileExists(atPath: root + "/b.txt"))
    }

    /// The lead's own audit is a re-audit: it needs a new verdict whatever the commit.
    @Test func anAuditAgainOnTheSameCommitNeedsItsNewVerdict() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        _ = call(lead, "audit", ["task": "add-b"])
        _ = call(try seat("worker-add-b", runtime), "report", ["status": "done", "summary": "still done"])
        #expect(BoardStore(root: root).load().task("add-b")?.evidence == nil)
        #expect(call(lead, "merge", ["task": "add-b"]).isError)
    }

    @Test func workersAndVerifiersActOnlyOnTheirOwnTask() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for title in ["One", "Two"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        for slug in ["one", "two"] { _ = call(lead, "start_worker", ["task": slug]) }
        _ = call(try seat("worker-one", runtime), "report", ["task": "two", "status": "blocked", "summary": "x"])
        _ = call(lead, "audit", ["task": "one"])
        _ = call(try seat("verify-one", runtime), "submit_audit",
                 ["task": "two", "completion": "complete", "integrity": "clean", "summary": "x"])
        let board = BoardStore(root: root).load()
        #expect(board.task("two")?.status == .running)
        #expect(board.task("two")?.evidence == nil)
        #expect(board.task("one")?.evidence != nil)
    }

    @Test func aSecondWorkerIsNotStartedOverALiveOne() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
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

    /// 2026-10-17: workers killed from outside left their tasks running, and start_worker refused each until the
    /// lead set it to blocked. A running task whose worker is gone starts again straight away, at the worker limit too.
    @Test func aRunningTaskWhoseWorkerEndedStartsAgain() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for title in ["One", "Two", "Three"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        for slug in ["one", "two", "three"] { #expect(!call(lead, "start_worker", ["task": slug]).isError) }
        let live = call(lead, "start_worker", ["task": "one"])
        #expect(live.isError && live.text.contains("still running"))
        try runtime.kill("session-1")   // ended without reporting; the lead didn't stop it
        let again = call(lead, "start_worker", ["task": "one"])
        #expect(!again.isError, "\(again.text)")
        let task = BoardStore(root: root).load().task("one")
        #expect(task?.status == .running && task?.worker == "session-4" && task?.attempts == 1)
        #expect(runtime.spawned.count == 4)
    }

    @Test func messagesSayHowTheyWereDelivered() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
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
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        let held = FileLock.attempt(root + "/.vibeswitcher/run/merge-add-b.lock")
        #expect(held != nil)
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(merged.isError)
        #expect(merged.text.contains("already"))
        held?.release()
        #expect(!call(lead, "merge", ["task": "add-b"]).isError)
    }

    @Test func statusListsTheReportsThatCameInSinceItsLastCheck() throws {
        // Seen live: a report steered to the lead went into a subagent and the lead never saw it. Whatever happens
        // to the message, the lead's next status lists it.
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        #expect(!call(lead, "status").text.contains("Reports since"))
        _ = call(try seat("worker-one", runtime), "report", ["status": "done", "summary": "added b.txt"])
        _ = call(lead, "audit", ["task": "one"])
        _ = call(try seat("verify-one", runtime), "submit_audit", ["completion": "complete", "integrity": "clean", "summary": "checked it"])
        let status = call(lead, "status").text
        let listed = try #require(status.components(separatedBy: "Reports since your last status").last)
        #expect(listed.contains(" worker one: The worker on one says it's done: added b.txt"))
        #expect(listed.contains(" verifier one: The audit of one passed (complete, clean): checked it"))
        // Listed once: the next status has nothing new, until another report comes in.
        #expect(!call(lead, "status").text.contains("Reports since"))
        runtime.leadRunning = false
        _ = call(try seat("worker-one", runtime), "report", ["status": "blocked", "summary": "need a key"])
        let later = call(lead, "status").text
        #expect(later.contains(" worker one: The worker on one is blocked: need a key") && !later.contains("added b.txt"))
    }

    @Test func aReportWithNoLeadRunningSaysSo() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        runtime.leadRunning = false
        let reported = call(try seat("worker-one", runtime), "report", ["status": "done", "summary": "x"])
        #expect(!reported.isError)
        #expect(reported.text.contains("no lead"))
        #expect(runtime.steered.isEmpty)
        // It's on the board for the next lead.
        #expect(BoardStore(root: root).load().task("one")?.status == .review)
    }

    @Test func cleanupWaitsForItsSessionsToEnd() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.stopWait = 0.3
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        _ = call(lead, "start_worker", ["task": "one"])
        runtime.stubborn = ["session-1"]
        // Its worker is still writing there: the worktree isn't removed under it.
        let cleaned = call(lead, "cleanup", ["task": "one", "force": true])
        #expect(cleaned.isError)
        #expect(FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: "one")))
        #expect(runtime.forgotten.isEmpty)
        runtime.stubborn = []
        #expect(!call(lead, "cleanup", ["task": "one", "force": true]).isError)
        #expect(!FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: "one")))
        #expect(runtime.forgotten == ["session-1"])
    }

    @Test func cleanupForgetsEveryEndedSessionOfItsTaskOnly() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for title in ["One", "Two"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        // One's first worker was stopped and another started; two's worker was stopped and waits.
        _ = call(lead, "start_worker", ["task": "one"])
        _ = call(lead, "stop_worker", ["task": "one"])
        _ = call(lead, "start_worker", ["task": "one"])
        _ = call(lead, "start_worker", ["task": "two"])
        _ = call(lead, "stop_worker", ["task": "two"])
        #expect(runtime.spawned.map(\.label) == ["Worker: One", "Worker: One", "Worker: Two"])
        #expect(!call(lead, "cleanup", ["task": "one", "force": true]).isError)
        #expect(runtime.forgotten == ["session-1", "session-2"])
        #expect(try runtime.sessions().map(\.id) == ["session-3"])
    }

    @Test func theLeadWorksOnTheBranchThatWasCheckedOut() throws {
        let root = try repo()
        Git.run(["checkout", "-q", "-b", "feature"], in: root)
        try "f\n".write(toFile: root + "/f.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "f.txt"], in: root)
        Git.run(["commit", "-q", "-m", "feature work"], in: root)
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
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
        #expect(runtime.spawned.first.map { _ in try? String(contentsOf: vault.runFolder(root: root, name: "worker-add-b").appendingPathComponent("settings.json"), encoding: .utf8) }??.contains("git switch feature") == true)
    }

    @Test func theWorkflowCanNameTheBranch() throws {
        let root = try repo()
        Git.run(["branch", "release"], in: root)
        try BoardStore(root: root).prepare()
        try "---\nbase_branch: release\n---".write(toFile: root + "/.vibeswitcher/workflow.md", atomically: true, encoding: .utf8)
        let lead = try lead(root, FakeRuntime())
        #expect(lead.base == "release")
    }

    // MARK: The lead's own workflow

    @Test func onlyTheLeadConfiguresTheWorkflow() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        #expect(try lead(root, runtime).tools.contains { $0.name == "configure" })
        for role in [LeadLaunch.Role.worker, .verifier] {
            let tools = try issued(role, task: "t", root: root, runtime)
            #expect(!tools.tools.contains { $0.name == "configure" })
            #expect(call(tools, "configure", ["test_command": "true"]).isError)
        }
        #expect(LeadWorkflow.load(from: root + "/.vibeswitcher/workflow.md").testCommand == nil)
    }

    @Test func statusSaysThereIsNoTestCommandAndSuggestsOne() throws {
        let root = try repo()
        try "// swift-tools-version:5.9\n".write(toFile: root + "/Package.swift", atomically: true, encoding: .utf8)
        let lead = try lead(root, FakeRuntime())
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
        let lead = try lead(root, FakeRuntime())
        try "test_command: true\nno front matter here".write(toFile: root + "/.vibeswitcher/workflow.md", atomically: true, encoding: .utf8)
        let status = call(lead, "status").text
        #expect(status.contains("front matter"))
        #expect(status.contains("No test_command"))
    }

    @Test func configureShowsAndSetsTheSettingsKeepingTheRestOfTheFile() throws {
        let root = try repo()
        Git.run(["branch", "dev"], in: root)
        let lead = try lead(root, FakeRuntime())
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
        let lead = try lead(root, FakeRuntime())
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
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(merged.text.contains("merged without tests: no test_command"))
    }

    @Test func aCRLFWorkflowStillTestsTheMerge() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        // Written on Windows, with a BOM: the test command must still run (and here it fails).
        try (Data([0xEF, 0xBB, 0xBF]) + Data("---\r\ntest_command: test -f missing.txt\r\n---\r\n".utf8))
            .write(to: URL(fileURLWithPath: root + "/.vibeswitcher/workflow.md"))
        _ = try audited(lead, runtime, root: root)
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(merged.isError)
        #expect(merged.text.contains("test command fails"))
        #expect(!FileManager.default.fileExists(atPath: root + "/b.txt"))
    }

    @Test func aFailedMergeNamesTheFailingTestAndSavesTheOutput() throws {
        let root = try repo()
        // The run as a merge saw it: the test results on stdout, then the build's warnings on stderr last.
        let results = swiftTestingFailure.components(separatedBy: "Build complete! (0.93s)\n")[1]
        let warnings = swiftTestingFailure.components(separatedBy: "◇ Test run started.")[0]
        try results.write(toFile: root + "/results.txt", atomically: true, encoding: .utf8)
        try warnings.write(toFile: root + "/warnings.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "results.txt", "warnings.txt"], in: root)
        Git.run(["commit", "-q", "-m", "a run"], in: root)
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try "---\ntest_command: cat results.txt; cat warnings.txt >&2; exit 1\n---\n"
            .write(toFile: root + "/.vibeswitcher/workflow.md", atomically: true, encoding: .utf8)
        _ = try audited(lead, runtime, root: root)
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(merged.isError)
        let lines = merged.text.components(separatedBy: "\n")
        #expect(lines.first == "The test command fails on add-b rebased onto main.")
        #expect(lines.dropFirst().first == "Failing tests (3): recordsIssue(), param(n:), answerIsRight()")
        #expect(merged.text.contains("↳ the answer drifted"))
        #expect(!merged.text.contains("resumed"))
        let log = vault.scratch(root: root, "add-b/merge-test.log")
        #expect(lines.last == "Full output: \(log.path)")
        let saved = try String(contentsOf: log, encoding: .utf8)
        #expect(saved.contains("Test run with 5 tests failed") && saved.contains("captured var 'resumed'"))
        #expect(BoardStore(root: root).load().task("add-b")?.status == .failed)
    }
}

