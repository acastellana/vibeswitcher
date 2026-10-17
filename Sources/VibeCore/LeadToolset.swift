import Foundation

/// An agent process (to steer messages into it).
public struct LeadAgent: Equatable, Sendable {
    public var pid: Int32
    public var tty: String
    /// Its window session's id, when it runs in the window.
    public var session: String?

    public init(pid: Int32, tty: String, session: String?) {
        self.pid = pid
        self.tty = tty
        self.session = session
    }
}

public enum LeadTarget: Equatable, Sendable {
    case session(String)
    case agent(LeadAgent)
}

public struct LeadSessionInfo: Equatable, Sendable {
    public var id: String
    public var cwd: String
    public var label: String
    public var live: Bool
    /// What its hooks say ("working", "needs input", "done"…), when known.
    public var status: String?
    public var tty: String?

    public init(id: String, cwd: String, label: String, live: Bool, status: String?, tty: String?) {
        self.id = id
        self.cwd = cwd
        self.label = label
        self.live = live
        self.status = status
        self.tty = tty
    }
}

/// What the lead's tools need from the outside world (the session host, steering, transcripts). Faked in tests.
public protocol LeadRuntime: AnyObject {
    /// The `vibeswitcher-mcp` binary the roles are started with.
    var server: String { get }
    /// The project's Claude command (from its launch presets), flags included.
    func claudeCommand(root: String) -> String
    /// Starts a window session; with `trust`, answers Claude's trust question for `cwd` in it.
    func spawn(cwd: String, command: String, label: String, agent: String, trust: Bool) throws -> String
    func kill(_ session: String)
    /// Delivers a message (see `LeadDelivery`): steered in, typed as its prompt, or queued.
    func steer(_ target: LeadTarget, from sender: SteerMessage.Sender, text: String) throws -> LeadDelivery.Delivered
    func sessions() -> [LeadSessionInfo]
    func transcript(of session: String) -> String?
    /// The agent this tool server belongs to (its parent process).
    func currentAgent() -> LeadAgent?
    /// That agent process is still the one running on its terminal.
    func isRunning(_ agent: LeadAgent) -> Bool
}

/// The project lead's tools, and the few that workers and verifiers get, over the board and the runtime.
///
/// Who may use which tools comes from the session's capability (see `LeadVault`), never from the server's arguments
/// or the board: the role and task are the capability's, and every call checks that the server runs in the session
/// VibeSwitcher started for it. A server without a current capability has no tools.
public final class LeadToolset: MCPToolset {
    /// The capability's role; nil when there's none (then nothing is served and `refusal` says why).
    let role: LeadLaunch.Role?
    let root: String
    let taskID: String?
    let runtime: LeadRuntime
    let store: BoardStore
    let vault: LeadVault
    private let capability: String?
    let refusal: String?
    private var introduced = false
    private let introducing = NSLock()
    /// How long cleanup waits for a task's sessions to end (the host hangs up, then kills after 5 s).
    var stopWait: TimeInterval = 8

    /// The server for the session holding `capability`. `expected` and `expectedTask` are what it was started as
    /// (`--role`, `--task`): when they don't match the capability, it serves nothing.
    public init(capability: String?, root: String, runtime: LeadRuntime, vault: LeadVault = .standard,
                expected: LeadLaunch.Role? = nil, expectedTask: String? = nil) {
        self.root = root
        self.runtime = runtime
        self.vault = vault
        store = BoardStore(root: root)
        let member = capability.flatMap { vault.member($0, root: root) }
        var refusal: String?
        if capability?.isEmpty ?? true {
            refusal = "This tool server has no VibeSwitcher capability, so it has no role: only sessions VibeSwitcher starts for a project lead get one (whatever --role says)."
        } else if member == nil {
            refusal = "This tool server's capability isn't current in \(root) (VibeSwitcher started another session for its role since, or never issued it). Its tools are off."
        } else if let expected, expected != member?.role {
            refusal = "This tool server was started as the \(expected.rawValue), but its capability is the \(member?.role.rawValue ?? "")'s. Refused."
        } else if let expectedTask, expectedTask != member?.task {
            refusal = "This tool server was started for task \(expectedTask), but its capability is for \(member?.task ?? "no task"). Refused."
        }
        self.refusal = refusal
        self.capability = refusal == nil ? capability : nil
        role = refusal == nil ? member?.role : nil
        taskID = refusal == nil ? member?.task : nil
        if role == .lead, (try? authenticate()) != nil { introduceLead() }
    }

    /// The server as `vibeswitcher-mcp` starts it: `--root <repo>` (plus `--role`/`--task` as it was started), its
    /// capability in the environment.
    public convenience init(arguments: [String], environment: [String: String], runtime: LeadRuntime, vault: LeadVault = .standard) {
        var root = FileManager.default.currentDirectoryPath
        var expected: LeadLaunch.Role?
        var task: String?
        var invalid = false
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--role":
                let value = iterator.next() ?? ""
                expected = LeadLaunch.Role(rawValue: value)
                invalid = invalid || expected == nil
            case "--root": root = iterator.next() ?? root
            case "--task": task = iterator.next()
            default: break
            }
        }
        self.init(capability: invalid ? nil : environment[LeadVault.environmentKey], root: root, runtime: runtime, vault: vault,
                  expected: expected, expectedTask: task)
    }

    /// The caller is the session this capability was issued for: the agent this server runs under (its parent
    /// process, found from the process table, not from anything the caller says) is that session's.
    @discardableResult
    func authenticate() throws -> LeadVault.Member {
        guard let capability, role != nil else { throw Problem(text: refusal ?? "This tool server has no role.") }
        guard let member = vault.member(capability, root: root) else {
            throw Problem(text: "This session's capability was withdrawn (VibeSwitcher started another session for its role). Its tools are off.")
        }
        guard let session = member.session else {
            throw Problem(text: "VibeSwitcher is still starting this session; try again in a moment.")
        }
        guard runtime.currentAgent()?.session == session else {
            throw Problem(text: "This tool server doesn't run in the session VibeSwitcher started for its capability. Refused.")
        }
        return member
    }

    /// The workflow notes, with the lead's branch resolved.
    var workflow: LeadWorkflow {
        var workflow = LeadWorkflow.load(from: workflowPath)
        workflow.baseBranch = workflow.baseBranch ?? store.load().baseBranch ?? Worktrees.mainBranch(root: root)
        return workflow
    }

    var workflowPath: String { (store.folder as NSString).appendingPathComponent("workflow.md") }

    /// The branch workers start from and verified work is merged into.
    public var base: String { workflow.base }

    var project: String { (root as NSString).lastPathComponent }

    /// The lead records where it runs, so answers and worker events reach it; it also sets up the folder, and the
    /// head of its branch when VibeSwitcher has none yet (merges check that nothing else moves it).
    private func introduceLead() {
        introducing.lock()
        defer { introducing.unlock() }
        guard !introduced, let me = runtime.currentAgent() else { return }
        introduced = true
        try? store.prepare()
        try? store.update { board in
            board.leadPid = me.pid
            board.leadTTY = me.tty
            board.leadSession = me.session ?? board.leadSession
        }
        let base = self.base
        if vault.head(root: root, branch: base) == nil, let head = branchHead(base) { try? vault.setHead(head, root: root, branch: base) }
    }

    private func branchHead(_ branch: String) -> String? {
        let head = Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: root)
        return head.ok && !head.output.isEmpty ? head.output : nil
    }

    // MARK: Tools

    public var tools: [MCPToolInfo] {
        typealias P = MCPToolInfo.Property
        let task = P(type: "string", description: "The task's slug (or id) from the board")
        switch role {
        case nil:
            return []
        case .worker?:
            return [
                MCPToolInfo(name: "report", description: "Tell the lead you're done (everything committed, checks passing) or blocked (say what you need). A verifier then checks your branch.",
                            properties: ["status": P(type: "string", description: "done or blocked", options: ["done", "blocked"]),
                                         "summary": P(type: "string", description: "What changed and how you checked it, or what blocks you")],
                            required: ["status", "summary"]),
                MCPToolInfo(name: "ask_lead", description: "Ask the project lead something without stopping your work; the answer arrives as a message.",
                            properties: ["question": P(type: "string", description: "The question")], required: ["question"]),
            ]
        case .verifier?:
            return [MCPToolInfo(name: "submit_audit", description: "Your verdict on the worker's branch, with evidence. Only this moves a task to done.",
                                properties: ["completion": P(type: "string", description: "Does the branch do what the contract asks?", options: ["complete", "incomplete", "blocked"]),
                                             "integrity": P(type: "string", description: "clean; suspect (not sure); violation (edits outside the boundaries, weakened or deleted tests, faked results)",
                                                            options: ["clean", "suspect", "violation"]),
                                             "summary": P(type: "string", description: "The evidence: what you ran and what you saw")],
                                required: ["completion", "integrity", "summary"])]
        case .lead?:
            return [
                MCPToolInfo(name: "status", description: "The board at a glance: tasks by state, workers and what they're doing, open questions."),
                MCPToolInfo(name: "board", description: "Everything on the board: tasks with their contracts and evidence, questions and answers, updates."),
                MCPToolInfo(name: "add_task", description: "Put a task on the board with its contract.",
                            properties: ["title": P(type: "string", description: "Short title"),
                                         "goal": P(type: "string", description: "What must be true when it's done"),
                                         "acceptance": P(type: "array", description: "Checks that can be run or seen", items: "string"),
                                         "boundaries": P(type: "array", description: "Files or areas it may touch; what it must not do", items: "string"),
                                         "context": P(type: "string", description: "What a fresh worker needs to know")],
                            required: ["title", "goal", "acceptance"]),
                MCPToolInfo(name: "update_task", description: "Change a task: its contract, or its state (planned, blocked, failed).",
                            properties: ["task": task, "title": P(type: "string", description: "New title"), "goal": P(type: "string", description: "New goal"),
                                         "acceptance": P(type: "array", description: "New checks", items: "string"),
                                         "boundaries": P(type: "array", description: "New boundaries", items: "string"),
                                         "context": P(type: "string", description: "New context"),
                                         "status": P(type: "string", description: "New state", options: ["planned", "blocked", "failed"])],
                            required: ["task"]),
                MCPToolInfo(name: "start_worker", description: "Start a worker on a task: a fresh Claude session in its own worktree on branch agent/<slug>, given the contract.",
                            properties: ["task": task], required: ["task"]),
                MCPToolInfo(name: "stop_worker", description: "End a task's worker (the worktree stays).", properties: ["task": task], required: ["task"]),
                MCPToolInfo(name: "message", description: "Tell a task's worker something: while it works it gets it at its next step without stopping; while it's idle it's typed in as its next prompt.",
                            properties: ["task": task, "text": P(type: "string", description: "The message")],
                            required: ["task", "text"]),
                MCPToolInfo(name: "read_session", description: "A worker's or verifier's conversation, condensed (prompts, replies, tool runs, failures).",
                            properties: ["task": task, "who": P(type: "string", description: "worker (default) or verifier", options: ["worker", "verifier"])],
                            required: ["task"]),
                MCPToolInfo(name: "audit", description: "Start the read-only verifier on a task's branch. Its report, not the worker's, decides.",
                            properties: ["task": task], required: ["task"]),
                MCPToolInfo(name: "merge", description: "Merge a task whose audit passed: rebase onto the lead's branch, run the test command, fast-forward that branch.",
                            properties: ["task": task], required: ["task"]),
                MCPToolInfo(name: "cleanup", description: "End a task's sessions and remove its worktree and branch (after merging, or force to abandon it).",
                            properties: ["task": task, "force": P(type: "boolean", description: "Also discard unmerged work")], required: ["task"]),
                MCPToolInfo(name: "ask_user", description: "Ask the user something. It doesn't block: keep working; the answer arrives as a message.",
                            properties: ["question": P(type: "string", description: "One clear question"),
                                         "options": P(type: "array", description: "Suggested answers (the user can also write their own)", items: "string")],
                            required: ["question"]),
                MCPToolInfo(name: "post_update", description: "Show the user a result: what changed, how it was checked, screenshots.",
                            properties: ["title": P(type: "string", description: "One line"), "body": P(type: "string", description: "Markdown"),
                                         "images": P(type: "array", description: "Absolute paths of screenshots", items: "string")],
                            required: ["title", "body"]),
                MCPToolInfo(name: "record_decision", description: "Write a decision and its reason to decisions.md.",
                            properties: ["decision": P(type: "string", description: "The decision"), "why": P(type: "string", description: "The reason")],
                            required: ["decision", "why"]),
                MCPToolInfo(name: "sessions", description: "This project's window sessions, live or ended."),
                MCPToolInfo(name: "configure", description: "The project's workflow settings (workflow.md's front matter): without arguments, shows them with suggestions from the repository; with some, sets those (an empty string clears one) and keeps the rest of the file as it is.",
                            properties: ["test_command": P(type: "string", description: "The project's checks; merge runs it on each rebased branch and merges only when it passes"),
                                         "init_command": P(type: "string", description: "What a fresh worktree needs before work starts (install, build)"),
                                         "base_branch": P(type: "string", description: "The branch workers start from and verified work is merged into (an existing local branch)"),
                                         "verifier_model": P(type: "string", description: "The verifier's model (e.g. sonnet, opus); a different one than the workers' gives a second opinion"),
                                         "max_workers": P(type: "integer", description: "How many workers may run at once (at least 1)")]),
            ]
        }
    }

    public func call(_ name: String, _ arguments: [String: Any]) -> MCPToolResult {
        guard let role else { return fail(refusal ?? "This tool server has no role.") }
        guard tools.contains(where: { $0.name == name }) else { return fail("No tool \(name) for the \(role.rawValue).") }
        do {
            let member = try authenticate()
            if role == .lead { introduceLead() }
            switch name {
            case "status": return MCPToolResult(text: status())
            case "board": return MCPToolResult(text: boardText())
            case "add_task": return try addTask(arguments)
            case "update_task": return try updateTask(arguments)
            case "start_worker": return try startWorker(try taskSlug(arguments))
            case "stop_worker": return try stopWorker(try taskSlug(arguments))
            case "message": return try message(try taskSlug(arguments), arguments)
            case "read_session": return try readSession(try taskSlug(arguments), who: arguments["who"] as? String ?? "worker")
            case "audit": return try audit(try taskSlug(arguments))
            case "merge": return try merge(try taskSlug(arguments))
            case "cleanup": return try cleanup(try taskSlug(arguments), force: arguments["force"] as? Bool ?? false)
            case "ask_user": return try askUser(arguments)
            case "post_update": return try postUpdate(arguments)
            case "record_decision": return try recordDecision(arguments)
            case "sessions": return MCPToolResult(text: sessionsText())
            case "configure": return try configure(arguments)
            case "report": return try report(arguments)
            case "ask_lead": return try askLead(arguments)
            case "submit_audit": return try submitAudit(arguments, by: member)
            default: return fail("No tool \(name).")
            }
        } catch let error as Problem {
            return fail(error.text)
        } catch {
            return fail("\(error)")
        }
    }

    struct Problem: Error { var text: String }

    private func fail(_ text: String) -> MCPToolResult { MCPToolResult(text: text, isError: true) }

    private func taskSlug(_ arguments: [String: Any]) throws -> String {
        // A worker or verifier acts on its own task only, whatever it passes: its capability's, by slug, not
        // whatever the board (which anyone can edit) says that slug is.
        if role != .lead {
            guard let taskID, try store.read().taskIndex(taskID) != nil else { throw Problem(text: "Your task isn't on the board any more.") }
            return taskID
        }
        guard let wanted = arguments["task"] as? String, let task = try store.read().task(wanted) else {
            throw Problem(text: "No such task on the board. Use status to see the tasks.")
        }
        return task.slug
    }

    private func strings(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        if let text = value as? String { return text.isEmpty ? [] : [text] }
        return []
    }

    // MARK: Lead

    private func addTask(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let title = arguments["title"] as? String, !title.isEmpty, let goal = arguments["goal"] as? String else {
            throw Problem(text: "A task needs a title and a goal.")
        }
        let contract = LeadContract(goal: goal, acceptance: strings(arguments["acceptance"]), boundaries: strings(arguments["boundaries"]),
                                    context: arguments["context"] as? String ?? "")
        guard !contract.acceptance.isEmpty else { throw Problem(text: "Give at least one acceptance check: something that can be run or seen.") }
        let task = try store.update { board -> LeadTask in
            let task = LeadTask(slug: Slug.make(title, taken: Set(board.tasks.map(\.slug))), title: title, contract: contract)
            board.tasks.append(task)
            return task
        }
        try? store.appendProgress("Planned \(task.slug): \(title)")
        return MCPToolResult(text: "Added task \(task.slug) (\(title)). Start it with start_worker when it doesn't depend on unfinished work.")
    }

    private func updateTask(_ arguments: [String: Any]) throws -> MCPToolResult {
        let slug = try taskSlug(arguments)
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            if let title = arguments["title"] as? String { board.tasks[index].title = title }
            if let goal = arguments["goal"] as? String { board.tasks[index].contract.goal = goal }
            if arguments["acceptance"] != nil { board.tasks[index].contract.acceptance = strings(arguments["acceptance"]) }
            if arguments["boundaries"] != nil { board.tasks[index].contract.boundaries = strings(arguments["boundaries"]) }
            if let context = arguments["context"] as? String { board.tasks[index].contract.context = context }
            if let status = (arguments["status"] as? String).flatMap(LeadTask.Status.init(rawValue:)), [.planned, .blocked, .failed].contains(status) {
                board.tasks[index].status = status
            }
        }
        return MCPToolResult(text: "Updated \(slug).")
    }

    private func startWorker(_ slug: String) throws -> MCPToolResult {
        let board = try store.read()
        guard let task = board.task(slug) else { throw Problem(text: "No task \(slug).") }
        guard [.planned, .failed, .blocked].contains(task.status) else {
            throw Problem(text: "\(slug) is \(task.status.rawValue); start a worker only on a planned, failed or blocked task.")
        }
        // One worker per worktree: two sessions editing the same files would undo each other.
        if let worker = task.worker, runtime.sessions().contains(where: { $0.id == worker && $0.live }) {
            throw Problem(text: "\(slug)'s worker is still running. Send it what to do with message, or stop_worker first.")
        }
        let running = board.tasks.filter { $0.status == .running }.count
        let limit = workflow.maxWorkers
        guard running < limit else {
            throw Problem(text: "\(running) workers already run (max_workers is \(limit) in workflow.md). Wait for one to finish; you'll get a message.")
        }
        let worktree = try Worktrees.open(root: root, slug: slug, base: base)
        let session = try launch(.worker, task: slug, name: "worker-\(slug)", in: worktree, label: "Worker: \(task.title)", trust: true,
                                 prompt: LeadPrompts.worker(task: task, root: root, workflow: workflow),
                                 start: "Start on your task (it's in your instructions). When done, call report.", branch: base)
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].status = .running
            board.tasks[index].worker = session
            board.tasks[index].branch = Worktrees.branch(slug)
            board.tasks[index].worktree = worktree
            board.tasks[index].evidence = nil
        }
        try? store.appendProgress("Started a worker on \(slug)")
        return MCPToolResult(text: "Worker started on \(slug) in \(worktree) (branch agent/\(slug)). You'll get a message when it reports, needs input or stalls.")
    }

    private func stopWorker(_ slug: String) throws -> MCPToolResult {
        guard let task = store.load().task(slug) else { throw Problem(text: "No task \(slug).") }
        if let worker = task.worker { runtime.kill(worker) }
        try store.update { board in
            if let index = board.taskIndex(slug), board.tasks[index].status == .running { board.tasks[index].status = .blocked }
        }
        return MCPToolResult(text: "Stopped the worker on \(slug). Its worktree and commits stay; start_worker continues there.")
    }

    private func message(_ slug: String, _ arguments: [String: Any]) throws -> MCPToolResult {
        guard let text = arguments["text"] as? String, !text.isEmpty else { throw Problem(text: "Nothing to send.") }
        guard let worker = store.load().task(slug)?.worker else { throw Problem(text: "\(slug) has no worker.") }
        switch try runtime.steer(.session(worker), from: .lead("lead of \(project)"), text: text) {
        case .steered: return MCPToolResult(text: "Sent to \(slug)'s worker; it gets it at its next step.")
        case .typed: return MCPToolResult(text: "Typed into \(slug)'s idle worker as its next prompt.")
        case .queued:
            return MCPToolResult(text: "\(slug)'s worker is idle but its input box isn't free (a question, a permission prompt or a draft is on screen), so the message waits; it's typed in as soon as the box is empty. read_session to see what it's waiting on.")
        }
    }

    private func readSession(_ slug: String, who: String) throws -> MCPToolResult {
        guard let task = store.load().task(slug), let session = who == "verifier" ? task.verifier : task.worker else {
            throw Problem(text: "\(slug) has no \(who).")
        }
        guard let path = runtime.transcript(of: session), let (url, format) = TranscriptReader.checkedURL(path, home: NSHomeDirectory()),
              let data = try? Data(contentsOf: url) else {
            return MCPToolResult(text: "No conversation yet for \(slug)'s \(who).")
        }
        var log = ChatLog()
        let tail = data.count > 2_000_000 ? data.suffix(2_000_000) : data
        log.append(ChatReader.read(Data(tail), format: format).events)
        return MCPToolResult(text: SessionDigest.text(log, limit: 12_000))
    }

    /// Starts a worker or a verifier with a new capability (it replaces the role's earlier one), bound to its session
    /// once that's started; its launch files go in the vault.
    private func launch(_ role: LeadLaunch.Role, task slug: String, name: String, in folder: String, label: String, trust: Bool,
                        prompt: String, start: String, model: String? = nil, branch: String? = nil, auditing: String? = nil) throws -> String {
        let capability = try vault.issue(role: role, root: root, task: slug, auditing: auditing)
        do {
            let launch = try LeadLaunch.prepare(role: role, root: root, task: slug, base: runtime.claudeCommand(root: root), prompt: prompt,
                                                start: start, server: runtime.server, name: name, model: model, branch: branch,
                                                capability: capability, folder: vault.runFolder(root: root, name: name))
            let session = try runtime.spawn(cwd: folder, command: launch.command, label: label, agent: "claude", trust: trust)
            try vault.bind(capability, root: root, session: session)
            return session
        } catch {
            try? vault.revoke(capability, root: root)
            throw error
        }
    }

    private func audit(_ slug: String) throws -> MCPToolResult {
        // The task's own worktree (not whatever folder the board names) on the commit the branch is at now: that
        // commit is what this verifier's verdict covers.
        guard let task = store.load().task(slug), Worktrees.isWorktree(root: root, slug: slug), let head = branchHead(Worktrees.branch(slug)) else {
            throw Problem(text: "\(slug) has no worktree to check.")
        }
        let workflow = self.workflow
        // Settings, hooks or MCP servers the branch brings would run in the verifier: it starts with project settings
        // off (see LeadLaunch), and VibeSwitcher doesn't say yes to Claude's trust question for that folder.
        let config = Worktrees.agentConfigChanges(root: root, slug: slug, base: workflow.base)
        let session = try launch(.verifier, task: slug, name: "verify-\(slug)", in: Worktrees.path(root: root, slug: slug),
                                 label: "Verifier: \(task.title)", trust: config.isEmpty,
                                 prompt: LeadPrompts.verifier(task: task, root: root, workflow: workflow),
                                 start: "Verify the task now, then call submit_audit.", model: workflow.verifierModel, auditing: head)
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].verifier = session
            board.tasks[index].status = .review
            board.tasks[index].evidence = nil
        }
        let flagged = config.isEmpty ? "" : " The branch changes Claude's settings or instructions (\(config.prefix(5).joined(separator: ", "))\(config.count > 5 ? ", …" : "")): the verifier runs with project settings off, and VibeSwitcher didn't answer its trust question; tell the user it waits for them to decide, and have the verifier look hard at those files."
        return MCPToolResult(text: "Verifier started on \(slug) (checking \(head.prefix(8))). Its verdict arrives as a message.\(flagged)")
    }

    private func merge(_ slug: String) throws -> MCPToolResult {
        guard let task = store.load().task(slug) else { throw Problem(text: "No task \(slug).") }
        // The verdict as the verifier's own tool server recorded it in the vault (the board's copy is for showing):
        // from the verifier VibeSwitcher started last for this task, on the commit it was started on.
        guard let verdict = vault.verdict(root: root, task: slug), verdict.passes else {
            throw Problem(text: "\(slug) has no passing audit. Run audit and wait for a complete, clean verdict.")
        }
        guard let verifier = vault.current(.verifier, root: root, task: slug), verifier.tokenHash == verdict.verifier,
              verifier.session == verdict.session, verifier.auditing == verdict.commit else {
            throw Problem(text: "\(slug)'s verdict isn't from the verifier last started on it. Run audit again.")
        }
        // The verdict covers the commit the verifier saw; anything committed since hasn't been checked.
        let head = Git.run(["rev-parse", Worktrees.branch(slug)], in: root).output
        guard verdict.commit == head else {
            throw Problem(text: "agent/\(slug) has commits the verifier didn't see (audited \(verdict.commit.prefix(8)), now \(head.prefix(8))). Run audit again.")
        }
        guard let lock = FileLock.attempt((store.folder as NSString).appendingPathComponent("run/merge-\(slug).lock")) else {
            throw Problem(text: "A merge of \(slug) is already running; wait for its result.")
        }
        defer { lock.release() }
        let workflow = self.workflow
        let base = workflow.base
        // One merge into a branch at a time: each checks the head the other one moves.
        let baseLock = vault.scratch(root: root, "merge-into-\(LeadVault.hash(base).prefix(16)).lock")
        try vault.ensurePrivate(baseLock.deletingLastPathComponent())
        guard let held = FileLock.attempt(baseLock.path) else {
            throw Problem(text: "Another merge into \(base) is running; merge \(slug) when it's done.")
        }
        defer { held.release() }
        guard let current = branchHead(base) else { throw Problem(text: "There's no branch \(base) to merge into.") }
        // The branch moves only through these merges: anything else that moved it (a worker's git, a hand-made
        // commit) is something nobody audited.
        if let known = vault.head(root: root, branch: base), known != current {
            throw Problem(text: "Not merged: \(base) moved since the lead last left it (\(known.prefix(8)) → \(current.prefix(8))), and not through merge. Tell the user (`git log \(known.prefix(8))..\(base)` shows what came in). If they moved it themselves, starting the lead again from VibeSwitcher takes \(base) as it is.")
        } else if vault.head(root: root, branch: base) == nil {
            try vault.setHead(current, root: root, branch: base)
        }
        // Exactly the audited commit, rebased and tested where no agent works.
        let tested: String
        switch Worktrees.rebaseAndTest(root: root, commit: verdict.commit, onto: current, setup: workflow.initCommand, test: workflow.testCommand,
                                       scratch: vault.scratch(root: root, "merge-\(slug)")) {
        case .passed(let commit): tested = commit
        case .conflict:
            try setStatus(slug, .failed)
            throw Problem(text: "\(slug) conflicts with \(base). Message its worker to bring its branch up to date with \(base) and resolve, then audit again.")
        case .failed(let output):
            try setStatus(slug, .failed)
            throw Problem(text: "The test command fails on \(slug) rebased onto \(base):\n\(output)")
        case .error(let text):
            throw Problem(text: text)
        }
        switch Worktrees.fastForward(root: root, base: base, to: tested, from: current) {
        case .merged:
            try vault.setHead(tested, root: root, branch: base)
            try setStatus(slug, .done)
            // Nothing ran: say so, it isn't a pass.
            let untested = workflow.testCommand == nil
                ? " (merged without tests: no test_command\(workflow.problem.map { "; \($0)" } ?? ""). Set one with configure.)" : ""
            try? store.appendProgress("Merged \(slug): \(task.title)\(untested.isEmpty ? "" : " (without tests: no test_command)")")
            return MCPToolResult(text: "Merged \(slug) into \(base)\(untested). Post an update for the user, then cleanup.")
        case .refused(let reason):
            throw Problem(text: "Not merged: \(reason)")
        }
    }

    private func cleanup(_ slug: String, force: Bool) throws -> MCPToolResult {
        guard let task = store.load().task(slug) else { throw Problem(text: "No task \(slug).") }
        guard task.status == .done || force else {
            throw Problem(text: "\(slug) isn't merged. Use force: true to abandon its work.")
        }
        let sessions = [task.worker, task.verifier].compactMap { $0 }
        sessions.forEach(runtime.kill)
        // Not under a session that's still writing there (its next write would leave a stray folder behind).
        let deadline = Date().addingTimeInterval(stopWait)
        var running = sessions
        while true {
            let live = Set(runtime.sessions().filter(\.live).map(\.id))
            running = sessions.filter(live.contains)
            guard !running.isEmpty, Date() < deadline else { break }
            usleep(200_000)
        }
        guard running.isEmpty else {
            throw Problem(text: "\(slug)'s sessions haven't ended yet; cleanup again in a moment.")
        }
        // Merged work is in main; leftovers in the worktree (build output) can go. Abandoned work goes only on request.
        try Worktrees.remove(root: root, slug: slug, force: true)
        try? vault.retire(root: root, task: slug)
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].worktree = nil
            if board.tasks[index].status != .done { board.tasks[index].status = .failed }
        }
        return MCPToolResult(text: "Cleaned up \(slug).")
    }

    private func askUser(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let question = arguments["question"] as? String, !question.isEmpty else { throw Problem(text: "Ask something.") }
        let asked = try store.update { board -> LeadQuestion in
            let asked = LeadQuestion(text: question, options: strings(arguments["options"]))
            board.questions.append(asked)
            return asked
        }
        return MCPToolResult(text: "Asked (\(asked.id.prefix(8))). Keep working; the answer arrives as a message.")
    }

    private func postUpdate(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let title = arguments["title"] as? String, let body = arguments["body"] as? String else { throw Problem(text: "An update needs a title and a body.") }
        try store.update { board in board.updates.append(LeadUpdate(title: title, body: body, images: strings(arguments["images"]))) }
        return MCPToolResult(text: "Posted.")
    }

    private func recordDecision(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let decision = arguments["decision"] as? String, let why = arguments["why"] as? String else { throw Problem(text: "A decision needs a reason.") }
        try store.appendDecision(decision, why: why)
        return MCPToolResult(text: "Recorded.")
    }

    private func configure(_ arguments: [String: Any]) throws -> MCPToolResult {
        let unknown = Set(arguments.keys).subtracting(LeadWorkflow.configurable)
        guard unknown.isEmpty else {
            throw Problem(text: "configure sets only \(LeadWorkflow.configurable.joined(separator: ", ")); not \(unknown.sorted().joined(separator: ", ")).")
        }
        var changes: [(key: String, value: String)] = []
        for key in LeadWorkflow.configurable {
            guard let given = arguments[key], !(given is NSNull) else { continue }
            var value: String
            if let text = given as? String { value = text.trimmingCharacters(in: .whitespaces) }
            else if let number = given as? NSNumber { value = number.stringValue }
            else { throw Problem(text: "\(key) must be a string.") }
            guard !value.contains(where: \.isNewline) else { throw Problem(text: "\(key) must be one line.") }
            switch key {
            case "max_workers":
                guard let count = Int(value), count >= 1 else { throw Problem(text: "max_workers must be a whole number, at least 1.") }
                value = String(count)
            case "base_branch" where !value.isEmpty:
                guard Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(value)"], in: root).ok else {
                    throw Problem(text: "There's no local branch \(value) to work on.")
                }
            default: break
            }
            changes.append((key, value))
        }
        guard !changes.isEmpty else { return MCPToolResult(text: workflowText()) }
        try store.prepare()
        let path = workflowPath
        let current = FileManager.default.contents(atPath: path) ?? Data(LeadWorkflow.template.utf8)
        try LeadWorkflow.updating(current, with: changes).write(to: URL(fileURLWithPath: path), options: .atomic)
        // What the next read sees is what counts.
        let after = LeadWorkflow.load(from: path)
        let read: [String: String] = ["test_command": after.testCommand ?? "", "init_command": after.initCommand ?? "",
                                      "base_branch": after.baseBranch ?? "", "verifier_model": after.verifierModel ?? "",
                                      "max_workers": String(after.maxWorkers)]
        for change in changes where read[change.key] != change.value {
            throw Problem(text: "Wrote workflow.md, but \(change.key) reads back as \"\(read[change.key] ?? "")\", not \"\(change.value)\". Check the file.")
        }
        // A branch the lead hasn't merged into yet: its head now is where merges into it start from.
        let base = self.base
        if vault.head(root: root, branch: base) == nil, let head = branchHead(base) { try? vault.setHead(head, root: root, branch: base) }
        let set = changes.map { $0.value.isEmpty ? "cleared \($0.key)" : "\($0.key) = `\($0.value)`" }.joined(separator: ", ")
        try? store.appendProgress("Workflow: \(set)")
        return MCPToolResult(text: "Set \(set).\n\n\(workflowText())")
    }

    private func setStatus(_ slug: String, _ status: LeadTask.Status) throws {
        try store.update { board in if let index = board.taskIndex(slug) { board.tasks[index].status = status } }
    }

    // MARK: Worker and verifier

    /// False when no lead is running to tell (it ended; a new one reads the board when it starts).
    private func tellLead(_ text: String, about: String) throws -> Bool {
        let board = store.load()
        guard let pid = board.leadPid, let tty = board.leadTTY else { return false }
        let lead = LeadAgent(pid: pid, tty: tty, session: board.leadSession)
        guard runtime.isRunning(lead) else { return false }
        _ = try runtime.steer(.agent(lead), from: .system(about), text: text)
        return true
    }

    private static let noLead = " (There's no lead running right now; it's on the board, and the next lead picks it up.)"

    private func report(_ arguments: [String: Any]) throws -> MCPToolResult {
        let slug = try taskSlug(arguments)
        let summary = arguments["summary"] as? String ?? ""
        let done = (arguments["status"] as? String) != "blocked"
        // A new report means new work: an earlier verdict doesn't cover it.
        try vault.clearVerdict(root: root, task: slug)
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].status = done ? .review : .blocked
            board.tasks[index].evidence = nil
        }
        let text = done
            ? "The worker on \(slug) says it's done: \(summary)\nRun audit(\(slug)); only the verifier's report counts."
            : "The worker on \(slug) is blocked: \(summary)"
        let told = try tellLead(text, about: "worker \(slug)")
        return MCPToolResult(text: (done ? "Reported. A verifier will check your branch; stay available for fixes." : "Reported. The lead will get back to you.")
                             + (told ? "" : Self.noLead))
    }

    private func askLead(_ arguments: [String: Any]) throws -> MCPToolResult {
        let slug = try taskSlug(arguments)
        guard let question = arguments["question"] as? String, !question.isEmpty else { throw Problem(text: "Ask something.") }
        guard try tellLead("The worker on \(slug) asks: \(question)\nAnswer with message(\(slug), …).", about: "worker \(slug)") else {
            throw Problem(text: "There's no lead running to ask. Decide what you can within your contract, or report blocked.")
        }
        return MCPToolResult(text: "Asked the lead. Keep working; the answer arrives as a message.")
    }

    private func submitAudit(_ arguments: [String: Any], by member: LeadVault.Member) throws -> MCPToolResult {
        // Only from the verifier VibeSwitcher started last for its task (checked in `authenticate`), about the commit
        // it was started on.
        guard member.role == .verifier, let slug = member.task, let session = member.session, let audited = member.auditing,
              vault.current(.verifier, root: root, task: slug)?.tokenHash == member.tokenHash else {
            throw Problem(text: "Only the verifier VibeSwitcher started on a task can give its verdict.")
        }
        _ = try taskSlug(arguments)
        guard let completion = (arguments["completion"] as? String).flatMap(LeadEvidence.Completion.init(rawValue:)),
              let integrity = (arguments["integrity"] as? String).flatMap(LeadEvidence.Integrity.init(rawValue:)) else {
            throw Problem(text: "completion must be complete, incomplete or blocked; integrity clean, suspect or violation.")
        }
        let summary = arguments["summary"] as? String ?? ""
        let verdict = LeadVault.Verdict(task: slug, completion: completion, integrity: integrity, summary: summary, commit: audited,
                                        verifier: member.tokenHash, session: session, at: Date().timeIntervalSince1970)
        try vault.record(verdict, root: root)
        let evidence = LeadEvidence(completion: completion, integrity: integrity, summary: summary, commit: audited)
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].evidence = evidence
            board.tasks[index].status = evidence.passes ? .review : .failed
        }
        try? store.appendProgress("Audit of \(slug): \(completion.rawValue), \(integrity.rawValue)")
        let head = branchHead(Worktrees.branch(slug))
        let moved = head == audited ? "" : "\nagent/\(slug) moved during the audit (now \(head?.prefix(8) ?? "gone")): this verdict covers \(audited.prefix(8)) only, and merge refuses newer commits until they're audited."
        let text = evidence.passes
            ? "The audit of \(slug) passed (complete, clean): \(evidence.summary)\nmerge(\(slug)) when you're ready.\(moved)"
            : "The audit of \(slug) did not pass (\(completion.rawValue), \(integrity.rawValue)): \(evidence.summary)\nSend the worker the findings with message, or re-plan the task."
        let told = try tellLead(text, about: "verifier \(slug)")
        return MCPToolResult(text: "Verdict recorded. You're done; the lead takes it from here." + (told ? "" : Self.noLead))
    }

    // MARK: Text

    private func status() -> String {
        let board = store.load()
        let live = Dictionary(uniqueKeysWithValues: runtime.sessions().map { ($0.id, $0) })
        let workflow = self.workflow
        var lines = ["Project \(project) on branch \(workflow.base) — \(board.tasks.count) task(s), max \(workflow.maxWorkers) workers at once."]
        lines += workflowWarnings(workflow)
        for state in LeadTask.Status.allCases {
            let tasks = board.tasks.filter { $0.status == state }
            guard !tasks.isEmpty else { continue }
            lines.append("\n\(state.rawValue):")
            for task in tasks {
                var line = "- \(task.slug): \(task.title)"
                if let worker = task.worker, let info = live[worker] {
                    line += " — worker \(info.live ? (info.status ?? "running") : "ended")"
                }
                if let evidence = task.evidence { line += " — audit \(evidence.completion.rawValue)/\(evidence.integrity.rawValue)" }
                lines.append(line)
            }
        }
        let open = board.questions.filter { $0.answer == nil }
        if !open.isEmpty {
            lines.append("\nWaiting on the user:")
            lines += open.map { "- \($0.text)" }
        }
        let answered = board.questions.filter { $0.answer != nil }.suffix(5)
        if !answered.isEmpty {
            lines.append("\nRecent answers:")
            lines += answered.map { "- \($0.text) → \($0.answer ?? "")" }
        }
        return lines.joined(separator: "\n")
    }

    /// What's missing from the workflow, with what to set (status and configure say it; nothing stays silent).
    private func workflowWarnings(_ workflow: LeadWorkflow) -> [String] {
        var lines: [String] = []
        if let problem = workflow.problem { lines.append("workflow.md: \(problem). Fix it with configure.") }
        if workflow.testCommand == nil {
            lines.append("No test_command: merges run no tests. " + (LeadWorkflow.detectTestCommand(root: root).map {
                "Suggested from the repository: `\($0)`; set it with configure (test_command)."
            } ?? "Set one with configure (test_command)."))
        }
        return lines
    }

    private func workflowText() -> String {
        let workflow = self.workflow
        let raw = LeadWorkflow.load(from: workflowPath)
        let fallback = store.load().baseBranch ?? Worktrees.mainBranch(root: root)
        let detectedInit = LeadWorkflow.detectInitCommand(root: root)
        var lines = ["Workflow settings (.vibeswitcher/workflow.md):",
                     "- test_command: " + (workflow.testCommand.map { "`\($0)`" } ?? "not set: merges run no tests"),
                     "- init_command: " + (workflow.initCommand.map { "`\($0)`" } ?? "not set" + (detectedInit.map { " (suggested from the repository: `\($0)`)" } ?? "")),
                     "- base_branch: " + (raw.baseBranch ?? "not set: \(fallback) (the branch the lead first started on)"),
                     "- verifier_model: " + (workflow.verifierModel ?? "not set: the workers' model"),
                     "- max_workers: \(workflow.maxWorkers)"]
        let warnings = workflowWarnings(workflow)
        if !warnings.isEmpty { lines += [""] + warnings }
        return lines.joined(separator: "\n")
    }

    private func boardText() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(store.load())).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private func sessionsText() -> String {
        let mine = runtime.sessions().filter { $0.cwd == root || $0.cwd.hasPrefix(root + "/") }
        guard !mine.isEmpty else { return "No window sessions in this project." }
        return mine.map { "- \($0.id): \($0.label) — \($0.live ? ($0.status ?? "running") : "ended") — \($0.cwd)" }.joined(separator: "\n")
    }
}
