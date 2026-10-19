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
    /// Its program's process (the agent), when the host says.
    public var pid: Int32?

    public init(id: String, cwd: String, label: String, live: Bool, status: String?, tty: String?, pid: Int32? = nil) {
        self.id = id
        self.cwd = cwd
        self.label = label
        self.live = live
        self.status = status
        self.tty = tty
        self.pid = pid
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
    /// Asks the host to end a session; throws what the host answered when it refused (or couldn't be asked).
    func kill(_ session: String) throws
    /// Has the host drop an ended session's record (it leaves the session list).
    func forget(_ session: String)
    /// Delivers a message (see `LeadDelivery`): steered in, typed as its prompt, or queued; `clearDraft` clears a
    /// draft left in an idle agent's input box first.
    func steer(_ target: LeadTarget, from sender: SteerMessage.Sender, text: String, clearDraft: Bool) throws -> LeadDelivery.Delivered
    /// Window sessions, each live one with what its agent is doing (see `LeadActivity`); throws when the session
    /// host can't be read (never "no sessions" then).
    func sessions() throws -> [LeadSessionInfo]
    /// Its transcript, found with or without its hooks (see `LeadObserver`); throws when the host can't be read.
    func transcript(of session: String) throws -> String?
    /// The agent this tool server belongs to (its parent process).
    func currentAgent() -> LeadAgent?
    /// That agent process is still the one running on its terminal.
    func isRunning(_ agent: LeadAgent) -> Bool
    /// The Mac's 1-minute load average (see `MacLoad.oneMinute`); nil when it can't be read.
    func loadAverage() -> Double?
}

/// The project lead's tools, and the few that workers and verifiers get, over the board and the runtime.
///
/// Who may use which tools comes from the session host (see `LeadVault`), never from the server's arguments or the
/// board: the host tells which session this server's process runs in, and which role and task that session holds.
/// Every call asks again. A server in no such session has no tools.
public final class LeadToolset: MCPToolset {
    /// The session's role; nil when it holds none (then nothing is served and `refusal` says why).
    let role: LeadLaunch.Role?
    let root: String
    let taskID: String?
    let runtime: LeadRuntime
    let store: BoardStore
    let vault: LeadVault
    /// The decision and progress logs, committed to the base branch (the lead's server only; see `keepRecords`).
    public let records: LeadRecords
    /// The grant the session held when the server started: a newer session for the role withdraws it.
    private let grant: String?
    let refusal: String?
    private var introduced = false
    private let introducing = NSLock()
    /// How long cleanup and stop_worker wait for a session's process to be gone (the host hangs up, then kills
    /// after 5 s).
    var stopWait: TimeInterval = 10
    /// The bytes free on the volume holding a path (see `DiskSpace.free`), and where Claude Code keeps its sessions'
    /// temporary folders (see `ClaudeScratch`). Faked in tests.
    var freeSpace: (String) -> Int64? = DiskSpace.free(at:)
    var scratchRoot = ClaudeScratch.root
    /// How often merge reads the load again while it waits for it to drop below load_threshold.
    var loadPoll: TimeInterval = 15

    /// The server for the session it runs in. `expected` and `expectedTask` are what it was started as (`--role`,
    /// `--task`): when they don't match the session's role, it serves nothing. `wait`: how long to wait for the
    /// session's role while VibeSwitcher is still binding it (the session can start first).
    public init(root: String, runtime: LeadRuntime, vault: LeadVault = .standard,
                expected: LeadLaunch.Role? = nil, expectedTask: String? = nil, unknownRole: String? = nil, wait: TimeInterval = 0) {
        self.root = root
        self.runtime = runtime
        self.vault = vault
        store = BoardStore(root: root)
        records = LeadRecords(store: store, vault: vault)
        var member: LeadVault.Member?
        var problem: String?
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            do {
                member = try vault.whoami(root: root)
                problem = nil
            } catch {
                problem = "\(error)"
            }
            if member != nil || Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while true
        var refusal: String?
        if let unknownRole {
            refusal = "There's no role \"\(unknownRole)\": the roles are lead, worker and verifier. Refused."
        } else if let problem, member == nil {
            refusal = "This tool server couldn't ask the session host which role its session holds: \(problem) Its tools are off."
        } else if member == nil {
            refusal = "This tool server doesn't run in a session VibeSwitcher started for a project lead's team (or its role went to a newer session), so it has no role, whatever --role says. Its tools are off."
        } else if let expected, expected != member?.role {
            refusal = "This tool server was started as the \(expected.rawValue), but its session is the \(member?.role.rawValue ?? "")'s. Refused."
        } else if let expectedTask, expectedTask != member?.task {
            refusal = "This tool server was started for task \(expectedTask), but its session is for \(member?.task ?? "no task"). Refused."
        }
        self.refusal = refusal
        grant = refusal == nil ? member?.id : nil
        role = refusal == nil ? member?.role : nil
        taskID = refusal == nil ? member?.task : nil
        if role == .lead, (try? authenticate()) != nil { introduceLead() }
    }

    /// The server as `vibeswitcher-mcp` starts it: `--root <repo>` (plus `--role`/`--task` as it was started).
    public convenience init(arguments: [String], runtime: LeadRuntime, vault: LeadVault = .standard, wait: TimeInterval = 0) {
        var root = FileManager.default.currentDirectoryPath
        var expected: LeadLaunch.Role?
        var task: String?
        var unknown: String?
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--role":
                let value = iterator.next() ?? ""
                expected = LeadLaunch.Role(rawValue: value)
                if expected == nil { unknown = value }
            case "--root": root = iterator.next() ?? root
            case "--task": task = iterator.next()
            default: break
            }
        }
        self.init(root: root, runtime: runtime, vault: vault, expected: expected, expectedTask: task, unknownRole: unknown, wait: wait)
    }

    /// The caller is still the session holding the role it started with: the session host tells (from this server's
    /// process, not from anything it says).
    @discardableResult
    func authenticate() throws -> LeadVault.Member {
        guard let grant, role != nil else { throw Problem(text: refusal ?? "This tool server has no role.") }
        let member: LeadVault.Member?
        do { member = try vault.whoami(root: root) } catch { throw Problem(text: "\(error)") }
        guard let member, member.id == grant else { throw Problem(text: withdrawn()) }
        return member
    }

    /// Why this session's role is gone, and where to go on: the session that holds it now, by name, or that none
    /// does. Reconnecting this server wouldn't bring the tools back (it'd ask the same host), so it isn't suggested.
    func withdrawn() -> String {
        let whose = role == .lead ? "the lead's role" : "task \(taskID ?? "?")'s \(role?.rawValue ?? "") role"
        let off = "Its tools are off here, and reconnecting them won't bring them back."
        guard let role, let holder = vault.current(role, root: root, task: taskID) else {
            return "This session no longer holds \(whose), and no other session does: the session host doesn't know it any more "
                + "(it began with an empty vault, after an install whose host couldn't carry it over, say). \(off) "
                + (role == .lead ? "Tell the user: to give this project a working lead, start one from VibeSwitcher (Project Lead); "
                    + "until then, say what you'd do with the tools." : "Tell the lead.")
        }
        let starter = role == .lead ? "VibeSwitcher started a new lead" : "The lead started another \(role.rawValue)"
        guard let session = holder.session else {
            return "This session no longer holds \(whose): \(starter) at \(LeadBoard.clock(holder.issuedAt)), still starting. \(off)"
        }
        let label = ((try? listed()) ?? []).first { $0.id == session }?.label
        let named = "session \(session.prefix(8))" + (label.map { " (‘\($0)’)" } ?? "")
        return "This session no longer holds \(whose): \(starter) at \(LeadBoard.clock(holder.issuedAt)), in \(named). \(off) "
            + (role == .lead ? "Tell the user to continue in that session. Messages typed into this session go to that lead now: "
                + "VibeSwitcher sends them on as the user's, and that lead read your last turns with the user as it started."
                : "Stop here: that session carries on with the task.")
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

    /// The lead's server commits the decision and progress logs every few minutes while it holds the role
    /// (`LeadRecords`), besides after each merge.
    public func keepRecords() {
        guard role == .lead else { return }
        records.start { [weak self] in
            guard let self, (try? self.authenticate()) != nil else { return nil }
            return self.base
        }
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
                MCPToolInfo(name: "progress", description: "Note a milestone in one line (a part working, checks passing, what's next). It shows on your task's lane in the lead's Team view; it doesn't message the lead. Call it at each milestone.",
                            properties: ["text": P(type: "string", description: "One line: what's done or under way")], required: ["text"]),
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
                MCPToolInfo(name: "status", description: "The board at a glance: tasks by state, workers and what they're doing, open questions, and each report that came in since you last asked, in one line (board(task) or read_session has the full text)."),
                MCPToolInfo(name: "board", description: "The board in one line per task, with the open questions and the latest updates; with task, that task in full: its contract, evidence, setback, reports, checkpoints and merge.",
                            properties: ["task": P(type: "string", description: "A task's slug (or id): that task in full")]),
                MCPToolInfo(name: "add_task", description: "Put a task on the board with its contract.",
                            properties: ["title": P(type: "string", description: "Short title"),
                                         "goal": P(type: "string", description: "What must be true when it's done"),
                                         "acceptance": P(type: "array", description: "Checks that can be run or seen", items: "string"),
                                         "boundaries": P(type: "array", description: "Files or areas it may touch; what it must not do", items: "string"),
                                         "context": P(type: "string", description: "What a fresh worker needs to know")],
                            required: ["title", "goal", "acceptance"]),
                MCPToolInfo(name: "update_task", description: "Change a task: its contract, or its state (planned, blocked, failed, or kept: deliberately not merged, which merge then refuses).",
                            properties: ["task": task, "title": P(type: "string", description: "New title"), "goal": P(type: "string", description: "New goal"),
                                         "acceptance": P(type: "array", description: "New checks (replaces them all)", items: "string"),
                                         "boundaries": P(type: "array", description: "New boundaries (replaces them all)", items: "string"),
                                         "context": P(type: "string", description: "Replaces the whole context; to add to it, use append_context"),
                                         "append_context": P(type: "string", description: "Added at the end of the context, which keeps what it had"),
                                         "status": P(type: "string", description: "New state", options: Self.settableStates.map(\.rawValue)),
                                         "reason": P(type: "string", description: "With status kept: what holds it back (a decision, the user's word); merge names it when it refuses")],
                            required: ["task"]),
                MCPToolInfo(name: "start_worker", description: "Start a worker on a task: a fresh Claude session in its own worktree on branch agent/<slug>, given the contract. A worktree stopped partway through a rebase or merge is described, not started; recover aborts it first. One left on another branch or a detached HEAD is put back on agent/<slug>, its uncommitted files carried along.",
                            properties: ["task": task,
                                         "recover": P(type: "boolean", description: "When its worktree stopped partway through a rebase or merge: abort it (back on agent/<slug> at the same commit, the branch's commits kept; what's staged in the middle of it is dropped), then start")],
                            required: ["task"]),
                MCPToolInfo(name: "stop_worker", description: "End a task's worker (the worktree stays).", properties: ["task": task], required: ["task"]),
                MCPToolInfo(name: "message", description: "Tell a task's worker something: while it works (or waits on a prompt) it gets it at its next step without stopping; between turns it's typed in as its next prompt.",
                            properties: ["task": task, "text": P(type: "string", description: "The message"),
                                         "clear_draft": P(type: "boolean", description: "If its input box holds a leftover draft, clear it first (the draft is lost)")],
                            required: ["task", "text"]),
                MCPToolInfo(name: "read_session", description: "A worker's or verifier's conversation, condensed (prompts, replies, tool runs, failures).",
                            properties: ["task": task, "who": P(type: "string", description: "worker (default) or verifier", options: ["worker", "verifier"])],
                            required: ["task"]),
                MCPToolInfo(name: "audit", description: "Start the read-only verifier on a task's branch. Its report, not the worker's, decides. A worktree left on another branch or a detached HEAD is put back on agent/<slug> first (refused, and its worker told what to run, when it holds uncommitted files or commits the branch lacks).",
                            properties: ["task": task], required: ["task"]),
                MCPToolInfo(name: "merge", description: "Merge a task whose audit passed: rebase onto the lead's branch (squashed when the worker merged it in), run the test command, fast-forward that branch.",
                            properties: ["task": task], required: ["task"]),
                MCPToolInfo(name: "cleanup", description: "End a task's sessions and remove its worktree and branch (after merging, or force to abandon it).",
                            properties: ["task": task, "force": P(type: "boolean", description: "Also discard unmerged work")], required: ["task"]),
                MCPToolInfo(name: "ask_user", description: "Ask the user something. It doesn't block: keep working; the answer arrives as a message. Your open questions are a queue the user answers in any order: revise one when you learn something (revise_question), withdraw one that no longer applies (withdraw_question). For a reversible choice, prefer proposing your answer with a timer (proposal, decide_in): the user can pick another option or hold it, and if no answer comes in time you get a message to go ahead with your proposal, recorded as your decision. Never a timer on a blocking question, on merging a sensitive path, on deleting or discarding work, or on anything outward-facing (publishing, pushing, sending): those are refused.",
                            properties: ["question": P(type: "string", description: "One clear question"),
                                         "options": P(type: "array", description: "Suggested answers (the user can also write their own)", items: "string"),
                                         "priority": P(type: "string", description: "blocking (work waits on it; it badges the Dock), important (the default), or whenever",
                                                       options: LeadQuestion.Priority.allCases.map(\.rawValue)),
                                         "why_now": P(type: "string", description: "One line: why you need it now (shown with the question)"),
                                         "proposal": P(type: "string", description: "Your proposed answer, one of the options: it starts a timer, and silence means you go ahead with it (reversible choices only)"),
                                         "decide_in": P(type: "integer", description: "Minutes until you go ahead with the proposal (default \(LeadQuestion.defaultDecideIn))")],
                            required: ["question"]),
                MCPToolInfo(name: "revise_question", description: "Reword an open question when you've learned something: it keeps its place and id, the user sees what changed and why, and an answer to the earlier wording says so.",
                            properties: ["id": P(type: "string", description: "The question's id (its first 8 characters will do)"),
                                         "text": P(type: "string", description: "The new wording"),
                                         "options": P(type: "array", description: "New suggested answers (an empty list removes them)", items: "string"),
                                         "note": P(type: "string", description: "What changed and why, in one line (shown on the card)")],
                            required: ["id", "note"]),
                MCPToolInfo(name: "withdraw_question", description: "Withdraw an open question that no longer applies (settled another way, overtaken): it stops waiting on the user.",
                            properties: ["id": P(type: "string", description: "The question's id (its first 8 characters will do)"),
                                         "reason": P(type: "string", description: "Why, in one line (the user sees it)")],
                            required: ["id", "reason"]),
                MCPToolInfo(name: "questions", description: "Your questions to the user: open ones (most important first), answered and withdrawn ones, each with its earlier wordings."),
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
                                         "max_workers": P(type: "integer", description: "How many workers may run at once (at least 1)"),
                                         "disk_warning_gb": P(type: "number", description: "Free space (GB) on the worktrees' volume below which you're told, once, what takes the space (default 10)"),
                                         "disk_floor_gb": P(type: "number", description: "Free space (GB) below which start_worker refuses (default 3)"),
                                         "test_timeout_min": P(type: "number", description: "Minutes merge lets init_command and test_command run before it takes them as hung and stops them (default 45)"),
                                         "merge_policy": P(type: "string", description: "How merges are handled, as the owner chose once: auto (audited work merges, the user gets an update afterwards), ask_sensitive (a commit touching sensitive_paths waits for the user's approval of that exact commit), ask_all (every merge waits)",
                                                           options: LeadWorkflow.MergePolicy.allCases.map(\.rawValue)),
                                         "sensitive_paths": P(type: "string", description: "The globs ask_sensitive holds back, comma-separated, as in .gitignore (empty: Claude's settings and instructions, .github, .env files, entitlements, keys)")]),
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
            case "board": return try MCPToolResult(text: boardText(task: arguments["task"] as? String))
            case "add_task": return try addTask(arguments)
            case "update_task": return try updateTask(arguments)
            case "start_worker": return try startWorker(try taskSlug(arguments), recover: arguments["recover"] as? Bool ?? false)
            case "stop_worker": return try stopWorker(try taskSlug(arguments))
            case "message": return try message(try taskSlug(arguments), arguments)
            case "read_session": return try readSession(try taskSlug(arguments), who: arguments["who"] as? String ?? "worker")
            case "audit": return try audit(try taskSlug(arguments))
            case "merge":
                let merged = try merge(try taskSlug(arguments))
                records.flush(base: base)
                return merged
            case "cleanup": return try cleanup(try taskSlug(arguments), force: arguments["force"] as? Bool ?? false)
            case "ask_user": return try askUser(arguments)
            case "revise_question": return try reviseQuestion(arguments)
            case "withdraw_question": return try withdrawQuestion(arguments)
            case "questions": return MCPToolResult(text: questionsText())
            case "post_update": return try postUpdate(arguments)
            case "record_decision": return try recordDecision(arguments)
            case "sessions": return MCPToolResult(text: sessionsText())
            case "configure": return try configure(arguments)
            case "report": return try report(arguments)
            case "ask_lead": return try askLead(arguments)
            case "progress": return try progress(arguments)
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
        // A worker or verifier acts on its own task only, whatever it passes: its session's, by slug, not
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

    /// The names callers often give a tool's text under instead of the one it asks for (workers sent progress and
    /// report as `message` and lost it).
    static let textAliases = ["text", "message", "summary", "content", "note"]

    /// The text a tool takes as `key`, else under one of `textAliases`; a list is joined into lines. Without any,
    /// the refusal names `key` and what was passed instead.
    private func text(_ arguments: [String: Any], _ key: String, missing: String) throws -> String {
        for name in [key] + Self.textAliases where arguments[name] != nil {
            let value = strings(arguments[name]).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        let others = arguments.keys.filter { !["task", "status", "clear_draft"].contains($0) }.sorted()
        throw Problem(text: "\(missing) Pass it as `\(key)`" + (others.isEmpty ? "." : " (this call had \(others.joined(separator: ", ")) and no \(key))."))
    }

    /// The states update_task sets (the rest come from the tools that do the work: start_worker, audit, merge).
    static let settableStates: [LeadTask.Status] = [.planned, .blocked, .failed, .kept]

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

    static let updateKeys: Set<String> = ["task", "title", "goal", "acceptance", "boundaries", "context", "append_context", "status", "reason"]

    private func updateTask(_ arguments: [String: Any]) throws -> MCPToolResult {
        let slug = try taskSlug(arguments)
        // Nothing passed is dropped unsaid: a name it doesn't take, or a state it doesn't set, is refused whole.
        let unknown = Set(arguments.keys).subtracting(Self.updateKeys)
        guard unknown.isEmpty else {
            throw Problem(text: "update_task doesn't take \(unknown.sorted().joined(separator: ", ")); it takes \(Self.updateKeys.sorted().joined(separator: ", ")). Nothing was changed.")
        }
        var status: LeadTask.Status?
        if let given = arguments["status"] as? String, !given.isEmpty {
            guard let wanted = LeadTask.Status(rawValue: given.lowercased()), Self.settableStates.contains(wanted) else {
                throw Problem(text: "update_task sets the state to \(Self.settableStates.map(\.rawValue).joined(separator: ", ")), not \(given). Nothing was changed.")
            }
            status = wanted
        }
        let reason = (arguments["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if status == .kept, reason.isEmpty {
            throw Problem(text: "Say what keeps it from merging (reason): a decision, the user's word. merge names it when it refuses. Nothing was changed.")
        }
        let appended = (arguments["append_context"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var changed: [String] = []
        try boardChange { board in
            guard let index = board.taskIndex(slug) else { return }
            if let status, board.tasks[index].status == .done {
                throw BoardError(text: "\(slug) is merged already\(board.tasks[index].merged.map { " (at \($0.commit.prefix(8)))" } ?? ""); it stays done, not \(status.rawValue). Nothing was changed.")
            }
            if !reason.isEmpty, (status ?? board.tasks[index].status) != .kept {
                throw BoardError(text: "reason goes with status kept (what holds the task back); \(slug) isn't being kept. Nothing was changed.")
            }
            if let title = arguments["title"] as? String { board.tasks[index].title = title; changed.append("title") }
            if let goal = arguments["goal"] as? String { board.tasks[index].contract.goal = goal; changed.append("goal") }
            if arguments["acceptance"] != nil { board.tasks[index].contract.acceptance = strings(arguments["acceptance"]); changed.append("acceptance") }
            if arguments["boundaries"] != nil { board.tasks[index].contract.boundaries = strings(arguments["boundaries"]); changed.append("boundaries") }
            if let context = arguments["context"] as? String { board.tasks[index].contract.context = context; changed.append("context (replaced)") }
            if !appended.isEmpty {
                let context = board.tasks[index].contract.context.trimmingCharacters(in: .whitespacesAndNewlines)
                board.tasks[index].contract.context = context.isEmpty ? appended : context + "\n\n" + appended
                changed.append("context (added to)")
            }
            if let status {
                board.tasks[index].status = status
                board.tasks[index].keptBecause = status == .kept ? reason : nil
                changed.append("state \(status.rawValue)")
            } else if !reason.isEmpty {
                board.tasks[index].keptBecause = reason
                changed.append("why it's kept")
            }
        }
        if status == .kept { try? store.appendProgress("Kept \(slug) unmerged: \(reason)") }
        return MCPToolResult(text: changed.isEmpty ? "Nothing to change on \(slug)." : "Updated \(slug): \(changed.joined(separator: ", ")).")
    }

    /// One start at a time, in this server and any other: each counts the workers running and starts its own before
    /// the next counts, so calls at once can't go past max_workers (or start two workers on one task).
    private func startWorker(_ slug: String, recover: Bool = false) throws -> MCPToolResult {
        try exclusively("start-worker") { try startWorkerAlone(slug, recover: recover) }
    }

    /// Runs `body` holding the lock `run/<name>.lock` in the project's folder, waiting for it while another thread or
    /// process holds it.
    private func exclusively<T>(_ name: String, _ body: () throws -> T) throws -> T {
        let path = (store.folder as NSString).appendingPathComponent("run/\(name).lock")
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Its own open file: flock locks are per open file, so another thread's open of it waits too.
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw Problem(text: "Couldn't open \(path) to take its lock: \(String(cString: strerror(errno))).") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Problem(text: "Couldn't take the lock \(path): \(String(cString: strerror(errno))).") }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func startWorkerAlone(_ slug: String, recover: Bool) throws -> MCPToolResult {
        let board = try store.read()
        guard let task = board.task(slug) else { throw Problem(text: "No task \(slug).") }
        // One worker per worktree: two sessions editing the same files would undo each other.
        let sessions = try hostSessions("whether \(slug)'s worker still runs isn't known; no worker was started")
        if let worker = task.worker, sessions.contains(where: { $0.id == worker && $0.live }) {
            throw Problem(text: "\(slug)'s worker is still running. Send it what to do with message, or stop_worker first.")
        }
        // A running task whose worker ended without reporting (killed, crashed) starts again as it is.
        guard [.planned, .failed, .blocked, .running].contains(task.status) else {
            throw Problem(text: "\(slug) is \(task.status.rawValue); start a worker only on a planned, failed or blocked task, or a running one whose worker ended.")
        }
        let workflow = self.workflow
        try checkSettings(workflow, not: "Not started")
        let running = board.tasks.filter { $0.status == .running && $0.id != task.id }.count
        let limit = workflow.maxWorkers
        guard running < limit else {
            throw Problem(text: "\(running) workers already run (max_workers is \(limit) in workflow.md). Wait for one to finish; you'll get a message.")
        }
        // The Mac is every project's: its load and their teams count, not only this one's. A session already in this
        // task's worktree (an ended worker's earlier verifier) is the one this worker replaces.
        let mac = MacLoad.count(sessions.map { ($0.label, $0.cwd, $0.live) }, load: runtime.loadAverage(),
                                except: Worktrees.path(root: root, slug: slug))
        if let refusal = macRefusal(mac, workflow, not: "Not started") { throw Problem(text: refusal) }
        // A worker on a full disk fails, and takes every other session with it (none can write its output).
        if let free = freeSpace(worktreesFolder), free < workflow.diskFloor {
            throw Problem(text: "Not started: only \(DiskSpace.text(free)) free on the volume holding the worktrees, under disk_floor_gb (\(Self.gb(workflow.diskFloorGB)) GB in workflow.md). A worker started now would fail once the disk fills. Free space first: cleanup finished tasks (status lists the biggest task folders), or tell the user.")
        }
        // A worktree left partway through a rebase or merge (a refused --continue): said what it's in, and undone
        // only when asked, back to the branch's head.
        let stuck = Worktrees.interrupted(root: root, slug: slug)
        // One on another branch or a detached HEAD (one its worker made for a review, a review flow's leftover) goes
        // back on agent/<slug> here (the worker's shell is denied `git switch`), its uncommitted files along as git
        // carries them; when git won't without overwriting some, the worker starts where it is, told to commit them.
        var offBranch = "", offSaid = "", stayed = false
        if let off = Worktrees.offBranch(root: root, slug: slug) {
            let was = "\(off.place) at \(off.commit.prefix(8))"
            do {
                try Worktrees.putBack(root: root, slug: slug, carry: true)
                try? store.appendProgress("Put \(slug)'s worktree back on \(off.branch) for its worker (it was on \(was))")
                let files = off.uncommitted.map(\.path).joined(separator: ", ")
                let commits = off.ahead.prefix(5).joined(separator: "; ") + (off.ahead.count > 5 ? "; …" : "")
                let ahead = off.ahead.isEmpty ? "" : " \(off.ahead.count) commit\(off.ahead.count == 1 ? "" : "s") there \(off.ahead.count == 1 ? "isn't" : "aren't") on \(off.branch): \(commits)."
                offSaid = "Put its worktree back on \(off.branch) (it was on \(was)\(files.isEmpty ? "" : "; its uncommitted files came along: \(files)")).\(ahead) "
                offBranch = " Your worktree was on \(was), not on your task's branch \(off.branch); the lead's tools put it back on \(off.branch)."
                    + (files.isEmpty ? "" : " Its uncommitted files came along as they were: \(files).")
                    + (off.ahead.isEmpty ? "" : "\(ahead) If they're your task's, bring them over first: `\(off.mergeCommand)`, on its own.")
            } catch {
                stayed = true
                offSaid = "Its worktree is on \(was), not on \(off.branch), and wasn't switched (\(error)); the worker was told to commit its files there. "
                offBranch = " Your worktree is on \(was), not on your task's branch \(off.branch), and switching it back would overwrite uncommitted files (\(off.uncommitted.map(\.path).joined(separator: ", "))). "
                    + "Commit them where you are: \(off.commitCommand), each command on its own; then report. Don't switch branches (you can't): the lead's next audit puts the worktree back on \(off.branch) and tells you how to bring the commit over."
            }
        }
        let worktree: String
        do {
            worktree = stayed ? Worktrees.path(root: root, slug: slug) : try Worktrees.open(root: root, slug: slug, base: base, recover: recover)
        } catch let stuck as Worktrees.Interrupted {
            let way = stuck.unsafe.map { "It can't be undone safely: \($0). Tell the user." }
                ?? "start_worker with recover: true runs `git \(stuck.kind.rawValue) --abort` there: the worktree goes back on \(stuck.branch) at \(stuck.head.prefix(8)) with all its commits (what's staged in the middle of the \(stuck.kind.rawValue) is dropped), then the worker starts."
            throw Problem(text: "Not started: \(stuck) \(way)")
        }
        // A merge into the branch that its last worker left unfinished: the new one finishes its resolution.
        let merging = recover ? nil : stuck.flatMap { $0.kind == .merge && !$0.detached ? $0 : nil }
        var finish = offBranch + (merging.map { " Your worktree is in the middle of a merge: \($0) Finish it first: resolve what's unresolved, `git add` the files, then `git commit`, each command on its own; `git merge --abort` starts the merge over." } ?? "")
        // A lock left in its worktree would stop the worker's first commit. A stale one goes (the folder is the
        // team's own); one a process holds stays, and is said.
        var locked = ""
        if let lock = IndexLock.find(in: worktree) {
            if lock.removeIfStale() {
                locked = "Removed a stale index.lock from its worktree (\(lock.size) bytes, last written \(Self.age(lock.age())) ago; no process held it). "
            } else {
                let wait = lock.holder != nil ? " git commands that change the index there wait until it's done."
                    : lock.stale ? " It's under a minute old, so it was left; if git still refuses because of it, remove it (`rm '\(lock.path)'`)."
                    : " It was left; remove it only once you've seen nothing runs git in this worktree (`lsof '\(lock.path)'`)."
                locked = "In its worktree, \(lock).\(wait) "
                finish += " In your worktree, \(lock).\(wait)"
            }
        }
        let session = try launch(.worker, task: slug, name: "worker-\(slug)", in: worktree, label: "Worker: \(task.title)", trust: true,
                                 prompt: LeadPrompts.worker(task: task, root: root, workflow: workflow),
                                 start: "Start on your task (it's in your instructions)." + finish + " Call progress at each milestone. When done, call report.", branch: base)
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            // A failed task started again is a new round of work; its setback stays to say why.
            let previous = board.tasks[index]
            let rounds = previous.attempts ?? (previous.worker == nil ? 0 : 1)
            board.tasks[index].attempts = rounds == 0 || previous.status == .failed ? rounds + 1 : rounds
            board.tasks[index].startedAt = previous.startedAt ?? Date().timeIntervalSince1970
            board.tasks[index].blocker = nil
            board.tasks[index].status = .running
            board.tasks[index].worker = session
            board.tasks[index].stopped = nil
            board.tasks[index].branch = Worktrees.branch(slug)
            board.tasks[index].worktree = worktree
            board.tasks[index].evidence = nil
        }
        try? store.appendProgress("Started a worker on \(slug)")
        let recovered = merging.map { "Its worktree is in the middle of a merge, which the worker was told to finish (start_worker with recover: true aborts it instead): \($0) " }
            ?? stuck.map { "Aborted the \($0.kind.rawValue) its worktree was stuck in; it's back on \($0.branch) at \($0.head.prefix(8)). " } ?? ""
        return MCPToolResult(text: offSaid + recovered + locked + "Worker started on \(slug) in \(worktree) (branch agent/\(slug)). You'll get a message when it reports, needs input or stalls.")
    }

    private func stopWorker(_ slug: String) throws -> MCPToolResult {
        guard let task = store.load().task(slug) else { throw Problem(text: "No task \(slug).") }
        let refused = "\(slug)'s worker wasn't stopped"
        // A session that's gone (ended, or lost with a replaced host) has nothing left to kill.
        let running = try task.worker.flatMap { worker in try hostSessions(refused).first { $0.id == worker && $0.live } }
        let ended = try running.map { try end([$0], refused: refused)[0] }
        if let ended, ended.failure != nil {
            throw Problem(text: "\(slug)'s worker wasn't stopped: \(ended.said). It's still running; if the host keeps refusing, tell the user (they can end it in VibeSwitcher).")
        }
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].stopped = task.worker
            if board.tasks[index].status == .running {
                board.tasks[index].status = .blocked
                board.tasks[index].blocker = "The lead stopped its worker."
            }
        }
        return MCPToolResult(text: (ended.map { "Stopped the worker on \(slug): \($0.said)." } ?? "\(slug)'s worker had already ended.")
                             + " Its worktree and commits stay; start_worker continues there.")
    }

    private func message(_ slug: String, _ arguments: [String: Any]) throws -> MCPToolResult {
        let text = try self.text(arguments, "text", missing: "Nothing to send.")
        guard let worker = store.load().task(slug)?.worker else { throw Problem(text: "\(slug) has no worker.") }
        let clear = arguments["clear_draft"] as? Bool ?? false
        let delivered = try runtime.steer(.session(worker), from: .lead("lead of \(project)"), text: text, clearDraft: clear)
        try store.update { board in
            guard let index = board.taskIndex(slug), board.tasks[index].worker == worker else { return }
            board.tasks[index].leadQuestionAt = nil
        }
        // Telling a failed or blocked task's live worker what to do sends it back to work: a failed one starts a
        // rework round (its setback stays to say why).
        // (Delivered already: a host that can't be read now only leaves the board's state as it was.)
        if (try? listed())?.contains(where: { $0.id == worker && $0.live }) == true {
            try store.update { board in
                guard let index = board.taskIndex(slug), board.tasks[index].worker == worker,
                      [.failed, .blocked].contains(board.tasks[index].status) else { return }
                if board.tasks[index].status == .failed {
                    board.tasks[index].attempts = (board.tasks[index].attempts ?? 1) + 1
                    board.tasks[index].evidence = nil
                }
                board.tasks[index].status = .running
                board.tasks[index].blocker = nil
            }
        }
        switch delivered {
        case .steered: return MCPToolResult(text: "Sent to \(slug)'s worker while it works; it gets it at its next step.")
        case .typed: return MCPToolResult(text: "Typed into \(slug)'s worker as its next prompt (it was between turns\(clear ? "; a leftover draft was cleared first" : "")).")
        case .awaitingAnswer(let asked):
            return MCPToolResult(text: "\(slug)'s worker is stopped on a prompt\(asked.map { " (\($0))" } ?? ""). The message is in its inbox and goes in at its next step, once that's answered: answer it yourself if it's yours to, or ask the user.")
        case .behindDraft(let draft):
            return MCPToolResult(text: "\(slug)'s worker is between turns, but its input box holds a draft: “\(Self.clip(draft))”. The message waits in its inbox (it goes in with the next prompt, or once the box is empty). To clear the draft and send now, message again with clear_draft: true.")
        case .draftStayed(let before, let after):
            // clear_draft was on already: asking for it again would do the same.
            let saw = after.map { $0.isEmpty ? "then read empty, but typing didn't go out" : "still showed “\(Self.clip($0))”" }
                ?? "couldn't be cleared (the ^C didn't go out, or its screen couldn't be read)"
            return MCPToolResult(text: "\(slug)'s worker is between turns with “\(Self.clip(before))” in its input box. clear_draft sent one ^C, and the box \(saw). The message waits in its inbox and goes in with its next prompt or once the box reads empty. Don't send it again; read_session to see where it is, or tell the user what's in its box.")
        case .queued:
            return MCPToolResult(text: "\(slug)'s worker is between turns, but its screen couldn't be read, so the message waits in its inbox; it goes in with its next prompt, or as soon as the box reads empty. read_session to see where it is.")
        }
    }

    private func readSession(_ slug: String, who: String) throws -> MCPToolResult {
        guard let task = store.load().task(slug), let session = who == "verifier" ? task.verifier : task.worker else {
            throw Problem(text: "\(slug) has no \(who).")
        }
        let found: String?
        do { found = try runtime.transcript(of: session) } catch {
            throw Problem(text: "The session host can't be read (\(error)), so \(slug)'s \(who) can't be found. Try again in a moment.")
        }
        guard let path = found, let (url, format) = TranscriptReader.checkedURL(path, home: NSHomeDirectory()),
              let data = try? Data(contentsOf: url) else {
            return MCPToolResult(text: "No conversation yet for \(slug)'s \(who).")
        }
        var log = ChatLog()
        let tail = data.count > 2_000_000 ? data.suffix(2_000_000) : data
        log.append(ChatReader.read(Data(tail), format: format).events)
        return MCPToolResult(text: SessionDigest.text(log, limit: 12_000))
    }

    /// Starts a worker or a verifier with a new grant (it replaces the role's earlier one), bound to its session once
    /// that's started; its launch files go in the vault's folder.
    private func launch(_ role: LeadLaunch.Role, task slug: String, name: String, in folder: String, label: String, trust: Bool,
                        prompt: String, start: String, model: String? = nil, branch: String? = nil, auditing: String? = nil) throws -> String {
        let grant: String
        do { grant = try vault.issue(role: role, root: root, task: slug, auditing: auditing) } catch { throw Problem(text: "\(error)") }
        do {
            let launch = try LeadLaunch.prepare(role: role, root: root, task: slug, base: runtime.claudeCommand(root: root), prompt: prompt,
                                                start: start, server: runtime.server, name: name, model: model, branch: branch,
                                                records: workflow.recordsDir, folder: vault.runFolder(root: root, name: name))
            let session = try runtime.spawn(cwd: folder, command: launch.command, label: label, agent: "claude", trust: trust)
            try vault.bind(grant, root: root, session: session)
            return session
        } catch {
            try? vault.revoke(grant, root: root)
            throw error
        }
    }

    private func audit(_ slug: String) throws -> MCPToolResult {
        // A worktree that left its branch goes back on it first (see putBackForAudit).
        let putBack = try store.load().task(slug).map { try putBackForAudit(slug, $0) } ?? ""
        // The task's own worktree (not whatever folder the board names) on the commit the branch is at now: that
        // commit is what this verifier's verdict covers.
        guard let task = store.load().task(slug), Worktrees.isWorktree(root: root, slug: slug), let head = branchHead(Worktrees.branch(slug)) else {
            throw Problem(text: "\(slug) has no worktree to check.")
        }
        let workflow = self.workflow
        try checkUpToDate(slug, head: head, base: workflow.base)
        // Not on a Mac every project's teams already load: the task's own worker (done) and earlier verifier aren't
        // counted, the verifier takes their place.
        let sessions = try hostSessions("whether the Mac has room for a verifier isn't known; no verifier was started")
        let mac = MacLoad.count(sessions.map { ($0.label, $0.cwd, $0.live) }, load: runtime.loadAverage(),
                                except: Worktrees.path(root: root, slug: slug))
        if let refusal = macRefusal(mac, workflow, not: "No verifier started") { throw Problem(text: refusal) }
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
            // A kept task stays kept through a new audit: what holds it back hasn't changed.
            if board.tasks[index].status != .kept { board.tasks[index].status = .review }
            board.tasks[index].evidence = nil
        }
        let flagged = config.isEmpty ? "" : " The branch changes Claude's settings or instructions (\(config.prefix(5).joined(separator: ", "))\(config.count > 5 ? ", …" : "")): the verifier runs with project settings off, and VibeSwitcher didn't answer its trust question; tell the user it waits for them to decide, and have the verifier look hard at those files."
        return MCPToolResult(text: putBack + "Verifier started on \(slug) (checking \(head.prefix(8))). Its verdict arrives as a message.\(flagged)")
    }

    /// A task's worktree on another branch (one its worker made for a review, a review flow's leftover) or a detached
    /// HEAD is put back on agent/<slug> from here, where git belongs: the worker's shell and the lead's are denied
    /// `git switch` on purpose, and the user was once asked to run it (2026-10-19, seven hours later). Clean, it's
    /// switched (recorded in progress.md) and the audit goes on, said in what this returns; with commits there the
    /// branch lacks, or uncommitted files, nothing is audited and the worker is told the one thing to run.
    private func putBackForAudit(_ slug: String, _ task: LeadTask) throws -> String {
        guard let off = Worktrees.offBranch(root: root, slug: slug) else { return "" }
        let branch = off.branch
        if !off.uncommitted.isEmpty {
            let files = off.uncommitted.map { "\($0.path) (\($0.state))" }.joined(separator: ", ")
            let told = tellWorker(task, "Your worktree is on \(off.place) at \(off.commit.prefix(8)), not on your task's branch \(branch), with uncommitted files: \(files). Commit them where you are: \(off.commitCommand), each command on its own; then report again. Don't switch branches (you can't): the lead's next audit puts the worktree back on \(branch) and tells you how to bring the commit over.")
            throw Problem(text: "Not audited, no verifier started: \(slug)'s worktree is on \(off.place) at \(off.commit.prefix(8)), not on \(branch), with uncommitted files: \(files). "
                          + "It wasn't switched, so nothing of them is lost. The worker should commit them where they are: \(off.commitCommand); "
                          + "the next audit puts the worktree back on \(branch) and has it bring that commit over. " + told)
        }
        do { try Worktrees.putBack(root: root, slug: slug) } catch {
            throw Problem(text: "Not audited, no verifier started: \(off) Putting it back on \(branch) failed: \(error)")
        }
        let was = "\(off.place) at \(off.commit.prefix(8))"
        try? store.appendProgress("Put \(slug)'s worktree back on \(branch) for its audit (it was on \(was))")
        guard off.ahead.isEmpty else {
            let commits = off.ahead.prefix(5).joined(separator: "; ") + (off.ahead.count > 5 ? "; …" : "")
            let told = tellWorker(task, "Your worktree was on \(was), not on your task's branch \(branch); the lead's tools put it back on \(branch). \(off.ahead.count) commit\(off.ahead.count == 1 ? "" : "s") there \(off.ahead.count == 1 ? "isn't" : "aren't") on \(branch): \(commits). If they're your task's, bring them over: `\(off.mergeCommand)` (on its own), run the tests, then report again.")
            throw Problem(text: "Put \(slug)'s worktree back on \(branch) (it was on \(was)). Not audited, no verifier started: \(off.ahead.count) commit\(off.ahead.count == 1 ? "" : "s") there \(off.ahead.count == 1 ? "isn't" : "aren't") on \(branch) "
                          + "(\(commits)), and a verifier would check \(branch) without them. The worker should run `\(off.mergeCommand)` in its worktree, then report; audit again then. " + told)
        }
        return "\(slug)'s worktree was on \(was), not on \(branch); it's back on \(branch) (nothing there that \(branch) lacks). "
    }

    /// Sends `text` to the task's worker when it runs; what the lead's result says about it.
    private func tellWorker(_ task: LeadTask, _ text: String) -> String {
        guard let worker = task.worker, (try? listed())?.contains(where: { $0.id == worker && $0.live }) == true else {
            return "Its worker isn't running: start_worker again, then message it this."
        }
        do {
            _ = try runtime.steer(.session(worker), from: .lead("lead of \(project)"), text: text, clearDraft: false)
            return "Its worker was sent this."
        } catch {
            return "Telling its worker failed (\(error)): message it this."
        }
    }

    /// A branch that hasn't taken in what the base did since to files it changes too breaks or conflicts once it's
    /// rebased at merge: refused before a verifier spends its runs on it (2026-10-19, twice: base commits that came
    /// after a worker's last `git merge` changed the test file it changed, and the merge's build failed).
    private func checkUpToDate(_ slug: String, head: String, base: String) throws {
        let since: Worktrees.BaseSince
        switch Worktrees.baseSince(root: root, base: base, commit: head) {
        case .success(let found): since = found
        case .failure(let error): throw Problem(text: "No verifier started: whether agent/\(slug) is up to date with \(base) can't be told (\(error)).")
        }
        let files = since.overlap
        guard !files.isEmpty else { return }
        let commits = since.commits(touching: files)
        let listed = commits.prefix(8).map { commit in
            "\(commit.line) (\(commit.files.filter(files.contains).joined(separator: ", ")))"
        }
        throw Problem(text: "Not audited, no verifier started: \(base) has \(commits.count) commit\(commits.count == 1 ? "" : "s") since agent/\(slug) last took it in (at \(since.mergeBase.prefix(8))) "
                      + "that change files the branch changes too, so it would break or conflict at merge. "
                      + "\(base)'s commits: \(listed.joined(separator: "; "))\(commits.count > 8 ? "; …" : ""). "
                      + "Files: \(files.prefix(12).joined(separator: ", "))\(files.count > 12 ? ", …" : ""). "
                      + Self.bringUpToDate(base))
    }

    /// What the lead tells a worker whose branch is behind the base where it matters.
    private static func bringUpToDate(_ base: String) -> String {
        "Message its worker to bring its branch up to date by merging, in its worktree: `git merge \(base)`, resolve the conflicts, `git add` the files, then `git commit`, each command on its own (no pipes, && or 2>&1); then run the tests and report again (start_worker again if it has stopped). Then audit again; merge puts the work on top of \(base) itself."
    }

    private func merge(_ slug: String) throws -> MCPToolResult {
        guard let task = store.load().task(slug) else { throw Problem(text: "No task \(slug).") }
        if task.status == .done {
            throw Problem(text: "\(slug) is already merged" + (task.merged.map { " at \($0.commit.prefix(8)) (\(LeadBoard.clock($0.at)))" } ?? "")
                          + ". Nothing to do but cleanup, if it isn't done yet.")
        }
        // Held back on purpose (a decision, the user's word): only the lead setting it back lets it merge.
        if task.status == .kept {
            throw Problem(text: "Not merged: \(slug) is kept unmerged (\(task.keptBecause ?? "no reason recorded")). If that no longer holds (the user said so, a newer decision), update_task(\(slug), status: planned) first, and say why with record_decision.")
        }
        // The verdict as the verifier's own tool server recorded it in the vault (the board's copy is for showing):
        // from the verifier VibeSwitcher started last for this task, on the commit it was started on.
        guard let verdict = vault.verdict(root: root, task: slug), verdict.passes else {
            throw Problem(text: vault.missingVerdictReason(root: root, task: slug)
                ?? "\(slug) has no passing audit. Run audit and wait for a complete, clean verdict.")
        }
        guard let verifier = vault.current(.verifier, root: root, task: slug), verifier.id == verdict.verifier,
              verifier.session == verdict.session, verifier.auditing == verdict.commit else {
            throw Problem(text: "\(slug)'s verdict isn't from the verifier last started on it. Run audit again.")
        }
        // The verdict covers the commit the verifier saw; anything committed since hasn't been checked.
        let head = Git.run(["rev-parse", Worktrees.branch(slug)], in: root).output
        guard verdict.commit == head else {
            throw Problem(text: "agent/\(slug) has commits the verifier didn't see (audited \(verdict.commit.prefix(8)), now \(head.prefix(8))). Run audit again.")
        }
        try checkMergePolicy(task, commit: verdict.commit)
        guard let lock = FileLock.attempt((store.folder as NSString).appendingPathComponent("run/merge-\(slug).lock")) else {
            throw Problem(text: "A merge of \(slug) is already running; wait for its result.")
        }
        defer { lock.release() }
        let workflow = self.workflow
        try checkSettings(workflow, not: "Not merged (nothing was tested)")
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
        // Except the user's own commits, which the vault takes when their sessions' hooks account for every one.
        if let known = vault.head(root: root, branch: base), known != current {
            let move = Result { try vault.acceptMove(root: root, branch: base) }
            guard case .success(let taken) = move, taken.accepted, taken.to == current else {
                let why: String
                switch move {
                case .success(let taken): why = (taken.reason.map { " \($0)" } ?? "") + (taken.waiting == true ? " A command of the user's is still running there: merge again in a moment." : "")
                case .failure(let error): why = " (\(error))"
                }
                throw Problem(text: "Not merged: \(base) moved since the lead last left it (\(known.prefix(8)) → \(current.prefix(8))), and not through merge.\(why) VibeSwitcher shows the user the commits that came in to accept (`git log \(known.prefix(8))..\(base)` shows them too); merge again once they have. Tell the user if it's not theirs.")
            }
            try? store.update { $0.updates.append(LeadUpdate(title: "Took \(taken.count) on \(base)", body: taken.acceptedLine)) }
            try? store.appendProgress(taken.acceptedLine)
        } else if vault.head(root: root, branch: base) == nil {
            try vault.setHead(current, root: root, branch: base)
        }
        // A lock in the main checkout stops the fast-forward at the end: said now, before the tests run.
        if let lock = Worktrees.indexLock(blocking: base, root: root) {
            throw Problem(text: "Not merged (nothing was tested): \(Worktrees.refusal(lock))")
        }
        // Timing-sensitive tests fail on a Mac every project's team is loading: the tests wait (a bounded time) for
        // the load to drop.
        let waited = try waitForLoad(workflow, slug: slug)
        // Exactly the audited commit, rebased and tested where no agent works.
        let tested: String
        switch Worktrees.rebaseAndTest(root: root, commit: verdict.commit, onto: current, setup: workflow.initCommand, test: workflow.testCommand,
                                       scratch: vault.scratch(root: root, "merge-\(slug)"), home: vault.scratch(root: root, "merge-\(slug)-home"),
                                       timeout: workflow.testTimeout) {
        case .passed(let commit): tested = commit
        case .cancelled:
            // Stopped by the caller: nothing is known about the work, and the task stays as it was.
            throw Problem(text: "The merge of \(slug) was cancelled; nothing was merged, and \(slug) stays as it was.")
        case .hung(let command, let after, let output):
            // Not a failure of the work as far as anyone knows: the task stays as it was, and the lead decides.
            let (what, they) = command == "init_command" ? ("init_command", "it was") : ("tests", "they were")
            let saved = saveMergeLog(output, slug: slug)
            throw Problem(text: "Not merged: the \(what) hung after \(Worktrees.duration(after)) on \(slug) rebased onto \(base); \(they) stopped, with everything started under them. \(slug) stays as it was. "
                          + (saved.map { "The output so far: \($0). " } ?? "(The output couldn't be saved.) ")
                          + "If they only need longer, raise test_timeout_min (\(Self.gb(workflow.testTimeoutMinutes)) in workflow.md) with configure; else have the worker find what hangs.")
        case .conflict:
            try setStatus(slug, .failed, setback: LeadSetback(stage: .merge, reason: "Conflicts with \(base): the branch needs bringing up to date."))
            throw Problem(text: "\(slug) conflicts with \(base). " + Self.bringUpToDate(base))
        case .failed(let output):
            // The setback names the failing tests; the output's last line only when none is named.
            let tests = TestFailures(output: output).tests.joined(separator: ", ")
            let last = tests.isEmpty ? output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "" : tests
            try setStatus(slug, .failed, setback: LeadSetback(stage: .merge, reason: "Tests fail rebased onto \(base)" + (last.isEmpty ? "." : ": \(last.prefix(200))")))
            throw Problem(text: testFailure(output, slug: slug, base: base, commit: verdict.commit, onto: current))
        case .error(let text):
            throw Problem(text: "Not merged: \(text)")
        }
        // Cancelled after its checks passed: it doesn't land. Past here, it lands whole or not at all.
        if ShellCancel.current?.isCancelled == true {
            throw Problem(text: "The merge of \(slug) was cancelled after its checks passed; nothing was merged, and \(slug) stays as it was.")
        }
        switch ShellCancel.with(nil, { Worktrees.fastForward(root: root, base: base, to: tested, from: current) }) {
        case .merged:
            try vault.setHead(tested, root: root, branch: base)
            try store.update { board in
                guard let index = board.taskIndex(slug) else { return }
                board.tasks[index].status = .done
                board.tasks[index].merged = LeadMergeRecord(commit: tested, tested: workflow.testCommand != nil)
            }
            // Nothing ran: say so, it isn't a pass.
            let untested = workflow.testCommand == nil
                ? " (merged without tests: no test_command\(workflow.problem.map { "; \($0)" } ?? ""). Set one with configure.)" : ""
            try? store.appendProgress("Merged \(slug): \(task.title)\(untested.isEmpty ? "" : " (without tests: no test_command)")")
            let patience = waited.map { " (The tests waited \(Worktrees.duration($0.after)) for the Mac's load to drop from \(MacLoad.number($0.from)) below load_threshold.)" } ?? ""
            return MCPToolResult(text: "Merged \(slug) into \(base)\(untested). Post an update for the user, then cleanup.\(patience)")
        case .refused(let reason):
            throw Problem(text: "Not merged: \(reason)")
        }
    }

    /// The owner's merge policy (workflow.md's merge_policy): a commit it holds back waits for the user's answer
    /// approving that exact commit (`LeadWorkflow.approves`), as the app recorded it on the board.
    private func checkMergePolicy(_ task: LeadTask, commit: String) throws {
        let workflow = self.workflow
        // The policy as the lead set it, not as a worker rewrote it.
        try checkSettings(workflow, not: "Not merged")
        guard workflow.mergePolicy != .auto else { return }
        let diff = Git.run(["diff", "--name-only", "\(workflow.base)...\(commit)"], in: root)
        guard diff.ok else { throw Problem(text: "Not merged: can't tell which files \(task.slug) changes (\(diff.error)), so the merge policy can't be checked.") }
        let changed = diff.output.split(whereSeparator: \.isNewline).map(String.init)
        guard let files = workflow.filesNeedingApproval(changed),
              !store.load().questions.contains(where: { LeadWorkflow.approves($0, commit: commit) }) else { return }
        let policy = workflow.mergePolicy?.rawValue ?? "ask_sensitive (no merge_policy is set yet: ask the owner once which one they want, then set it with configure)"
        let touches = files.isEmpty ? "" : " It touches " + files.prefix(8).joined(separator: ", ") + (files.count > 8 ? ", …" : "") + "."
        throw Problem(text: "Not merged yet: the merge policy is \(policy), so the user approves \(task.slug) at \(commit.prefix(8)) first.\(touches) "
            + "Ask once: ask_user(question: \"Merge \(task.slug) (\(task.title)) at \(commit.prefix(8))? …what it changes and the risk…\", "
            + "options: [\"\(LeadWorkflow.approval(of: commit))\", \"Not yet\"], priority: blocking), with no timer, and merge again when they approve. "
            + "The approval covers this commit only: a new commit needs a new one.")
    }

    /// A failed merge's test run, told by what failed: the failing tests and their lines first (the output's end
    /// is usually the build's warnings), with all of the output saved where the lead can read it.
    private func testFailure(_ output: String, slug: String, base: String, commit: String, onto current: String) -> String {
        let setup = output.hasPrefix("init_command failed:\n")
        let output = setup ? String(output.dropFirst("init_command failed:\n".count)) : output
        let saved = saveMergeLog(output, slug: slug)
        let failures = TestFailures(output: output)
        let found = failures.summary()
            ?? "Nothing in the output names a failing test or an error; it ends:\n" + String(output.suffix(1500))
        // The errors name files in the merge's own worktree (see rebaseAndTest).
        let place = vault.scratch(root: root, "merge-\(slug)")
        let inside = [place.path, place.resolvingSymlinksInPath().path].map { $0 + "/" }
        let files = failures.errorFiles.map { file in inside.first(where: file.hasPrefix).map { String(file.dropFirst($0.count)) } ?? file }
        let touched = baseCommits(touching: files, slug: slug, base: base, commit: commit, onto: current).map { $0 + "\n" } ?? ""
        return "The \(setup ? "init_command" : "test command") fails on \(slug) rebased onto \(base).\n\(found)\n\(touched)"
            + (saved.map { "Full output: \($0)" } ?? "(The full output couldn't be saved.)")
    }

    /// For each file in a build's errors, the base's commits since the branch last
    /// took it in that touched it: what the worker's `git merge` brings in, for the lead's message. Nil when the
    /// errors name no file.
    private func baseCommits(touching paths: [String], slug: String, base: String, commit: String, onto current: String) -> String? {
        guard !paths.isEmpty else { return nil }
        guard case .success(let since) = Worktrees.baseSince(root: root, base: current, commit: commit) else {
            return "(Which of \(base)'s commits touched the files in the errors couldn't be told.)"
        }
        // The repository's path each error's path ends with, the longest one (one the compiler wrote otherwise).
        let known = Set(since.baseFiles + since.branchFiles).sorted { $0.count > $1.count }
        var lines: [String] = []
        for path in paths {
            let file = known.first { path == $0 || path.hasSuffix("/" + $0) } ?? path
            guard !lines.contains(where: { $0.hasPrefix("- \(file):") }) else { continue }
            let commits = since.commits(touching: [file])
            lines.append("- \(file): " + (commits.isEmpty ? "no commit of \(base)'s since \(since.mergeBase.prefix(8))"
                : commits.prefix(6).map(\.line).joined(separator: "; ") + (commits.count > 6 ? "; …" : "")))
        }
        return "\(base)'s commits since agent/\(slug) last took it in (at \(since.mergeBase.prefix(8))), by file in the errors (its worker's `git merge \(base)` brings them in):\n"
            + lines.joined(separator: "\n")
    }

    /// Saves a merge's test output where the lead can read it; its path, or nil when it couldn't be saved.
    private func saveMergeLog(_ output: String, slug: String) -> String? {
        let log = vault.scratch(root: root, "\(slug)/merge-test.log")
        return (try? vault.ensurePrivate(log.deletingLastPathComponent())).flatMap {
            (try? Data(output.utf8).write(to: log, options: .atomic)).map { log.path }
        }
    }

    private func cleanup(_ slug: String, force: Bool) throws -> MCPToolResult {
        let board = store.load()
        guard let task = board.task(slug) else { throw Problem(text: "No task \(slug).") }
        guard task.status == .done || force else {
            throw Problem(text: "\(slug) isn't merged. Use force: true to abandon its work.")
        }
        // Only the ones still running are ended: a session that's gone (lost with a replaced host) has nothing to kill.
        // Its worker and verifier, and any earlier one still running in its worktree (a verifier a later audit
        // replaced is off the board, not ended).
        let refused = "\(slug)'s sessions can't be checked; nothing was cleaned up"
        let folder = (Worktrees.path(root: root, slug: slug) as NSString).standardizingPath
        let sessions = try hostSessions(refused).filter { session in
            session.live && ([task.worker, task.verifier].contains(session.id) || Self.isTeamSession(session, in: folder))
        }
        let endings = try end(sessions, refused: refused)
        // Not under a session that's still writing there (its next write would leave a stray folder behind).
        let failed = endings.filter { $0.failure != nil }
        guard failed.isEmpty else {
            throw Problem(text: "Not cleaned up: \(failed.map(\.said).joined(separator: "; ")). Its worktree stays while a session may still write there. If the host refuses, tell the user (they can end it in VibeSwitcher), then cleanup again.")
        }
        // Its sessions' temporary folders, found by the worktree's path while it's still there to resolve.
        let worktree = Worktrees.path(root: root, slug: slug)
        let temporary = ClaudeScratch.folders(for: worktree, in: scratchRoot)
        // Merged work is in main; leftovers in the worktree (build output) can go. Abandoned work goes only on request.
        // The build folder goes first and whatever git makes of the rest: it's most of the space.
        var freed = removeFolder((worktree as NSString).appendingPathComponent(".build"))
        if FileManager.default.fileExists(atPath: worktree) || branchHead(Worktrees.branch(slug)) != nil {
            try Worktrees.remove(root: root, slug: slug, force: true)
        }
        freed += temporary.reduce(0) { $0 + removeFolder($1.path) }
        freed += sweepFinished(board, except: slug)
        try? vault.retire(root: root, task: slug)
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].worktree = nil
            if board.tasks[index].status != .done { board.tasks[index].status = .failed }
        }
        // Its workers and verifiers, this one and any before it, are history now: off the session list.
        for session in (try? listed()) ?? [] where !session.live && Self.isTeamSession(session, in: folder) {
            runtime.forget(session.id)
        }
        let ended = endings.isEmpty ? "" : "; " + endings.map(\.said).joined(separator: ", ")
        return MCPToolResult(text: "Cleaned up \(slug)" + ended + (freed > 0 ? " (freed \(DiskSpace.text(freed)) of build output and temporary folders)." : "."))
    }

    /// A worker's or verifier's session in the worktree `folder` (standardized).
    private static func isTeamSession(_ session: LeadSessionInfo, in folder: String) -> Bool {
        (session.cwd as NSString).standardizingPath == folder && [.worker, .verifier].contains(LeadTeams.role(label: session.label))
    }

    /// load_threshold as said in a refusal: "24 in workflow.md", or "24, twice the 12 cores" when it isn't set.
    private static func loadLimitText(_ workflow: LeadWorkflow) -> String {
        "\(MacLoad.number(workflow.loadLimit))" + (workflow.loadThreshold == nil ? ", twice the \(MacLoad.processors) cores" : " in workflow.md")
    }

    /// The Mac's load and every project's team sessions, against this project's limits, in one line.
    private static func macText(_ mac: MacLoad, _ workflow: LeadWorkflow) -> String {
        "load \(mac.loadText) (load_threshold \(loadLimitText(workflow))), \(mac.sessionsText) (mac_max_sessions \(workflow.macMaxSessions))"
    }

    /// Why no worker or verifier may start now on the Mac as `mac` has it (`not`: what didn't happen); nil when one may.
    private func macRefusal(_ mac: MacLoad, _ workflow: LeadWorkflow, not: String) -> String? {
        var over: [String] = []
        if mac.isBusy(threshold: workflow.loadLimit) { over.append("its 1-minute load is above load_threshold") }
        if mac.isFull(max: workflow.macMaxSessions) { over.append("the team sessions of all its projects are at mac_max_sessions") }
        guard !over.isEmpty else { return nil }
        return "\(not): the Mac is shared by every project's team, and \(over.joined(separator: " and ")). Now: \(Self.macText(mac, workflow)). "
            + "Try again in about \(MacLoad.retryMinutes) minutes: other projects' sessions ending send you no message (your own do). "
            + "Meanwhile merge and cleanup finished tasks (cleanup ends their sessions), plan, or answer the user."
    }

    /// Waits while the Mac's 1-minute load is above load_threshold, reading it every `loadPoll`, for at most
    /// test_timeout_min; nil when it didn't wait, else how long and from what load. Throws, with the numbers, when the
    /// load didn't drop in time (nothing was tested).
    private func waitForLoad(_ workflow: LeadWorkflow, slug: String) throws -> (after: TimeInterval, from: Double)? {
        let start = Date()
        let deadline = start.addingTimeInterval(workflow.testTimeout)
        guard let first = runtime.loadAverage(), first > workflow.loadLimit else { return nil }
        var load: Double? = first
        while let current = load, current > workflow.loadLimit {
            if ShellCancel.current?.isCancelled == true {
                throw Problem(text: "The merge of \(slug) was cancelled while it waited for the Mac's load to drop; nothing was merged, and \(slug) stays as it was.")
            }
            guard Date() < deadline else {
                let mac = MacLoad.count(((try? listed()) ?? []).map { ($0.label, $0.cwd, $0.live) }, load: current)
                throw Problem(text: "Not merged (nothing was tested): the Mac's 1-minute load stayed above load_threshold for the \(Worktrees.duration(workflow.testTimeout)) merge waits (test_timeout_min). Now: \(Self.macText(mac, workflow)). "
                              + "Timing-sensitive tests fail on a Mac this busy, so \(slug) wasn't tested and stays as it was. Merge again in about \(MacLoad.retryMinutes) minutes; meanwhile start no workers or audits (they'd add to the load), and tell the user if it stays this busy.")
            }
            Thread.sleep(forTimeInterval: min(loadPoll, max(0, deadline.timeIntervalSinceNow)))
            load = runtime.loadAverage()
        }
        return (Date().timeIntervalSince(start), first)
    }

    /// What became of a session asked to end: `failure` nil when its process is gone.
    struct Ending {
        let session: LeadSessionInfo
        let failure: String?

        /// "ended pid N (label)", or "couldn't end pid N (label): why".
        var said: String {
            let which = session.pid.map { "pid \($0)" } ?? "session \(session.id.prefix(8))"
            return failure.map { "couldn't end \(which) (\(session.label)): \($0)" } ?? "ended \(which) (\(session.label))"
        }
    }

    /// Asks the host to end each of `sessions`, then waits (up to `stopWait`) until each one it took is gone. A refusal
    /// is said with the host's own words, never taken for an end.
    private func end(_ sessions: [LeadSessionInfo], refused: String) throws -> [Ending] {
        var failures: [String: String] = [:]
        for session in sessions {
            do { try runtime.kill(session.id) } catch { failures[session.id] = "\(error)" }
        }
        var running = Set(sessions.map(\.id)).subtracting(failures.keys)
        let deadline = Date().addingTimeInterval(stopWait)
        while !running.isEmpty {
            running.formIntersection(try hostSessions(refused).filter(\.live).map(\.id))
            guard !running.isEmpty, Date() < deadline else { break }
            usleep(200_000)
        }
        for id in running { failures[id] = "it's still running \(Int(stopWait.rounded(.up))) s after the host was asked to end it" }
        return sessions.map { Ending(session: $0, failure: failures[$0.id]) }
    }

    /// Removes a folder, if it's there; returns what it took.
    private func removeFolder(_ path: String) -> Int64 {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        let bytes = DiskSpace.size(of: path)
        return (try? FileManager.default.removeItem(atPath: path)) == nil ? 0 : bytes
    }

    /// The temporary folders other finished tasks left behind (cleaned up before cleanup removed them): only a task
    /// merged or abandoned whose worktree is gone, with no session running there.
    private func sweepFinished(_ board: LeadBoard, except slug: String) -> Int64 {
        // Which folders sessions still run in isn't known: nothing goes.
        guard let sessions = try? listed() else { return 0 }
        let live = Set(sessions.filter(\.live).map { ($0.cwd as NSString).standardizingPath })
        var freed: Int64 = 0
        for task in board.tasks where task.slug != slug && task.worktree == nil && [.done, .failed].contains(task.status) {
            let worktree = Worktrees.path(root: root, slug: task.slug)
            guard !FileManager.default.fileExists(atPath: worktree), !live.contains((worktree as NSString).standardizingPath) else { continue }
            freed += ClaudeScratch.folders(for: worktree, in: scratchRoot).reduce(0) { $0 + removeFolder($1.path) }
        }
        return freed
    }

    /// Where the worktrees go (the volume they fill).
    var worktreesFolder: String { (root as NSString).appendingPathComponent(".vibeswitcher/worktrees") }

    /// 10 → "10", 2.5 → "2.5".
    static func gb(_ value: Double) -> String { String(format: "%g", value) }

    /// Low disk space, with what takes it (status says it while it lasts; the witness tells it once).
    func diskWarning(_ workflow: LeadWorkflow, board: LeadBoard) -> [String] {
        guard let free = freeSpace(worktreesFolder), free < workflow.diskWarning else { return [] }
        return [LeadWitness.diskText(free: free, workflow: workflow, folders: TaskFolder.all(root: root, board: board, scratch: scratchRoot))]
    }

    private func askUser(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let question = arguments["question"] as? String, !question.isEmpty else { throw Problem(text: "Ask something.") }
        let priority = try self.priority(arguments["priority"])
        let whyNow = (arguments["why_now"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let options = strings(arguments["options"])
        var proposal = (arguments["proposal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if proposal?.isEmpty == true { proposal = nil }
        let decideIn = try minutes(arguments["decide_in"])
        if decideIn != nil, proposal == nil { throw Problem(text: "decide_in needs a proposal: the answer you'd go ahead with.") }
        if let given = proposal {
            if let refusal = LeadQuestion.timerRefusal(text: question, options: options, whyNow: whyNow, priority: priority) { throw Problem(text: refusal) }
            guard let option = options.first(where: { $0.caseInsensitiveCompare(given) == .orderedSame }) else {
                throw Problem(text: "The proposal must be one of the options (\(options.isEmpty ? "there are none" : options.joined(separator: " | "))).")
            }
            proposal = option
        }
        let asked = try store.update { board in
            board.ask(question, options: options, priority: priority, whyNow: whyNow, proposal: proposal, decideIn: decideIn)
        }
        let timer = asked.proposal.map { proposal in
            " You proposed ‘\(proposal)’: unless the user answers or holds it, a message at \(LeadBoard.clock(asked.decideBy ?? 0)) (in \(asked.decideInText)) "
                + "tells you to go ahead with it. Until then, don't act on it."
        } ?? ""
        return MCPToolResult(text: "Asked (\(asked.short), \(asked.rank.rawValue)).\(timer) Keep working; the answer arrives as a message. If it stops applying, withdraw_question(\(asked.short)); if you learn something, revise_question.")
    }

    /// A timer's length: whole minutes, at least 1, at most a day.
    private func minutes(_ value: Any?) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        let number: Double? = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard let number, number.rounded() == number, number >= 1, number <= 24 * 60 else {
            throw Problem(text: "decide_in is whole minutes, from 1 to \(24 * 60).")
        }
        return Int(number)
    }

    private func priority(_ value: Any?) throws -> LeadQuestion.Priority? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        guard let priority = LeadQuestion.Priority(rawValue: text.lowercased()) else {
            throw Problem(text: "priority must be blocking, important or whenever.")
        }
        return priority
    }

    private func reviseQuestion(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let id = arguments["id"] as? String, !id.isEmpty else { throw Problem(text: "Which question? Give its id.") }
        let note = (arguments["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { throw Problem(text: "Say what changed and why (note): the user sees it on the card.") }
        let text = arguments["text"] as? String
        let options = arguments["options"].map { strings($0) }
        guard text?.isEmpty == false || options != nil else { throw Problem(text: "Give the new text, new options, or both.") }
        let board = try store.read()
        let before = (try? board.questionIndex(id)).map { board.questions[$0] }
        let revised = try boardChange { board in try board.revise(id, text: text, options: options, note: note) }
        var timer = ""
        if revised.isCounting {
            timer = " Its timer starts again: you go ahead with ‘\(revised.proposal ?? "")’ at \(LeadBoard.clock(revised.decideBy ?? 0)) unless the user answers."
        } else if before?.isCounting == true, let proposal = before?.proposal, revised.options.contains(proposal),
                  let refusal = LeadQuestion.timerRefusal(text: revised.text, options: revised.options, whyNow: revised.whyNow, priority: revised.priority) {
            timer = " Its timer is off, it waits for the user's answer: \(refusal)"
        } else if before?.isCounting == true {
            timer = " Your proposal isn't one of the options any more, so its timer is off: it waits for the user's answer."
        }
        return MCPToolResult(text: "Revised \(revised.short) (now version \(revised.version)). The user sees the new wording and your note; an answer to an earlier wording says which one it was.\(timer)")
    }

    private func withdrawQuestion(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let id = arguments["id"] as? String, !id.isEmpty else { throw Problem(text: "Which question? Give its id.") }
        let reason = (arguments["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw Problem(text: "Say why (reason): the user sees it.") }
        let withdrawn = try boardChange { board in try board.withdraw(id, reason: reason) }
        return MCPToolResult(text: "Withdrew \(withdrawn.short) “\(withdrawn.text)”. It no longer waits on the user.")
    }

    /// A board change whose refusal (`BoardError`) is the lead's to read, not a failure.
    /// The host's sessions. One that can't be read is a refusal saying what didn't happen (`refused`), never "no
    /// sessions": a second worker started in a live worktree would undo the first's work.
    private func hostSessions(_ refused: String) throws -> [LeadSessionInfo] {
        do { return try listed() } catch {
            throw Problem(text: "The session host can't be read (\(error)), so \(refused). Try again in a moment; if it keeps failing, tell the user (VibeSwitcher may be restarting its session host).")
        }
    }

    /// The host's sessions, a live one whose process is gone (the host hadn't seen it end yet) as ended.
    private func listed() throws -> [LeadSessionInfo] {
        try runtime.sessions().map { session in
            var session = session
            if session.live, let pid = session.pid, Darwin.kill(pid, 0) != 0, errno == ESRCH { session.live = false }
            return session
        }
    }

    private func boardChange<T>(_ change: (inout LeadBoard) throws -> T) throws -> T {
        do { return try store.update(change) } catch let error as BoardError { throw Problem(text: error.text) }
    }

    private func postUpdate(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let title = arguments["title"] as? String, let body = arguments["body"] as? String else { throw Problem(text: "An update needs a title and a body.") }
        try store.update { board in board.updates.append(LeadUpdate(title: title, body: body, images: strings(arguments["images"]))) }
        // In the log too, so a later lead sees the updates, check-ins and retrospectives.
        let first = body.split(whereSeparator: \.isNewline).first.map { Self.clip(String($0), 200) }
        try? store.appendProgress("Update: \(Self.clip(title, 200))" + (first.map { " — \($0)" } ?? ""))
        return MCPToolResult(text: "Posted.")
    }

    private func recordDecision(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let decision = arguments["decision"] as? String, let why = arguments["why"] as? String else { throw Problem(text: "A decision needs a reason.") }
        try store.appendDecision(decision, why: why)
        return MCPToolResult(text: store.recordsDir.map { "Recorded in \($0)/decisions.md (committed to \(base) with the next batch)." } ?? "Recorded.")
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
            if key == "sensitive_paths", let list = given as? [Any] { value = list.compactMap { $0 as? String }.joined(separator: ", ") }
            else if let text = given as? String { value = text.trimmingCharacters(in: .whitespaces) }
            else if let number = given as? NSNumber { value = number.stringValue }
            else { throw Problem(text: "\(key) must be a string.") }
            guard !value.contains(where: \.isNewline) else { throw Problem(text: "\(key) must be one line.") }
            switch key {
            case "max_workers":
                guard let count = Int(value), count >= 1 else { throw Problem(text: "max_workers must be a whole number, at least 1.") }
                value = String(count)
            case "disk_warning_gb", "disk_floor_gb":
                guard !value.isEmpty else { break }
                guard let size = LeadWorkflow.gigabytes(value) else { throw Problem(text: "\(key) must be a number of GB, 0 or more.") }
                value = Self.gb(size)
            case "load_threshold":
                guard !value.isEmpty else { break }
                guard let load = LeadWorkflow.positive(value) else { throw Problem(text: "load_threshold must be a load average, more than 0 (empty: twice the cores).") }
                value = Self.gb(load)
            case "mac_max_sessions":
                guard !value.isEmpty else { break }
                guard let count = Int(value), count >= 1 else { throw Problem(text: "mac_max_sessions must be a whole number, at least 1.") }
                value = String(count)
            case "test_timeout_min":
                guard !value.isEmpty else { break }
                guard let minutes = LeadWorkflow.minutes(value) else { throw Problem(text: "test_timeout_min must be a number of minutes, more than 0.") }
                value = Self.gb(minutes)
            case "merge_policy" where !value.isEmpty:
                guard let policy = LeadWorkflow.MergePolicy(text: value) else {
                    throw Problem(text: "merge_policy is one of \(LeadWorkflow.MergePolicy.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                value = policy.rawValue
            case "sensitive_paths":
                value = LeadWorkflow.globs(value)?.joined(separator: ", ") ?? ""
            case "records_dir" where !value.isEmpty:
                guard let folder = LeadWorkflow.recordsFolder(value) else {
                    throw Problem(text: "records_dir is a folder inside the repository (e.g. docs/lead), not in .git or .vibeswitcher; empty keeps the logs in .vibeswitcher.")
                }
                value = folder
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
        let before = LeadWorkflow.load(from: path)
        try LeadWorkflow.updating(current, with: changes).write(to: URL(fileURLWithPath: path), options: .atomic)
        // What the next read sees is what counts.
        let after = LeadWorkflow.load(from: path)
        let read: [String: String] = ["test_command": after.testCommand ?? "", "init_command": after.initCommand ?? "",
                                      "base_branch": after.baseBranch ?? "", "verifier_model": after.verifierModel ?? "",
                                      "max_workers": String(after.maxWorkers),
                                      "disk_warning_gb": Self.gb(after.diskWarningGB), "disk_floor_gb": Self.gb(after.diskFloorGB),
                                      "test_timeout_min": Self.gb(after.testTimeoutMinutes),
                                      "load_threshold": after.loadThreshold.map(Self.gb) ?? "", "mac_max_sessions": String(after.macMaxSessions),
                                      "merge_policy": after.mergePolicy?.rawValue ?? "", "sensitive_paths": after.sensitivePaths?.joined(separator: ", ") ?? "",
                                      "records_dir": after.recordsDir ?? ""]
        // A limit cleared reads back as its default.
        let defaults = ["disk_warning_gb": Self.gb(LeadWorkflow().diskWarningGB), "disk_floor_gb": Self.gb(LeadWorkflow().diskFloorGB),
                        "test_timeout_min": Self.gb(LeadWorkflow().testTimeoutMinutes), "mac_max_sessions": String(LeadWorkflow().macMaxSessions)]
        for change in changes where read[change.key] != (change.value.isEmpty ? defaults[change.key] ?? "" : change.value) {
            throw Problem(text: "Wrote workflow.md, but \(change.key) reads back as \"\(read[change.key] ?? "")\", not \"\(change.value)\". Check the file.")
        }
        // The guard rails set here are the lead's; the others stay as recorded (any not recorded yet, as they were).
        let given = LeadVault.guardedHashes(after).filter { key, _ in changes.contains { $0.key == key } }
        do {
            let recorded = try vault.guardedSettings(root: root) ?? [:]
            let hashes = LeadVault.guardedHashes(before).filter { recorded[$0.key] == nil }.merging(given) { $1 }
            if !hashes.isEmpty { try vault.setGuardedSettings(hashes, root: root) }
        } catch {
            throw Problem(text: "Wrote workflow.md, but the session host didn't record its settings as yours (\(error)); merge and start_worker refuse them until it does. Run configure with them again.")
        }
        // A branch the lead hasn't merged into yet: its head now is where merges into it start from.
        let base = self.base
        if vault.head(root: root, branch: base) == nil, let head = branchHead(base) { try? vault.setHead(head, root: root, branch: base) }
        let set = changes.map { $0.value.isEmpty ? "cleared \($0.key)" : "\($0.key) = `\($0.value)`" }.joined(separator: ", ")
        try? store.appendProgress("Workflow: \(set)")
        return MCPToolResult(text: "Set \(set).\n\n\(workflowText())")
    }

    /// workflow.md's guard rails (`LeadVault.guardedKeys`: its commands run as the lead, its policy and limits hold
    /// the team) count only as the lead last set them with configure, since any session of the team can write the file.
    private func checkSettings(_ workflow: LeadWorkflow, not: String) throws {
        let changed: [(key: String, value: String)]
        do { changed = try vault.changedSettings(workflow, root: root) } catch {
            throw Problem(text: "\(not): the session host couldn't say what you last set workflow.md's guard rails to (\(error)).")
        }
        guard !changed.isEmpty else { return }
        let now = changed.map { $0.value.isEmpty ? "\($0.key) is now empty" : "\($0.key) is now `\($0.value)`" }.joined(separator: "; ")
        throw Problem(text: "\(not): workflow.md's \(now), not what you last set with configure. Its commands run as you, its policy and limits hold the team, and any session of the team can write the file: a worker may have changed it. If you or the user did, set it again with configure (as it should read) and try again; if not, set it back with configure and tell the user.")
    }

    private func setStatus(_ slug: String, _ status: LeadTask.Status, setback: LeadSetback? = nil) throws {
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].status = status
            if let setback { board.tasks[index].setback = setback }
        }
    }

    // MARK: Worker and verifier

    /// False when no lead is running to tell (it ended; a new one reads the board when it starts).
    private func tellLead(_ text: String, about: String) throws -> Bool {
        // On the board first: the lead's status lists it even if the message never reaches the lead.
        try store.update { board in
            board.reports = ((board.reports ?? []) + [LeadReport(about: about, text: text)]).suffix(LeadBoard.keptReports)
        }
        // Only the session holding the lead's role now: a replaced lead runs on, without it (see `LeadHandover`).
        let holder = vault.current(.lead, root: root, task: nil)?.session
        guard let lead = LeadHandover.current(store.load(), holder: holder, isRunning: runtime.isRunning) else { return false }
        _ = try runtime.steer(.agent(lead), from: .system(about), text: text, clearDraft: false)
        return true
    }

    private static let noLead = " (There's no lead running right now; it's on the board, and the next lead picks it up.)"

    private func report(_ arguments: [String: Any]) throws -> MCPToolResult {
        let slug = try taskSlug(arguments)
        let summary = try text(arguments, "summary", missing: "Say what changed and how you checked it, or what blocks you.")
        let done = (arguments["status"] as? String) != "blocked"
        // A report on the commit the last verdict covers (an answer, a note, a repeated "done") leaves that verdict
        // standing: only a new commit, or the lead's own audit, needs a new one.
        let head = branchHead(Worktrees.branch(slug))
        let standing = vault.verdict(root: root, task: slug).flatMap { $0.commit == head ? $0 : nil }
        if standing == nil { try vault.clearVerdict(root: root, task: slug) }
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            if board.tasks[index].status != .kept {
                board.tasks[index].status = !done ? .blocked : standing.map { $0.passes ? .review : .failed } ?? .review
            }
            if let standing {
                if board.tasks[index].evidence?.commit != standing.commit {
                    board.tasks[index].evidence = LeadEvidence(completion: standing.completion, integrity: standing.integrity,
                                                               summary: standing.summary, commit: standing.commit, at: standing.at)
                }
            } else {
                // Kept to show what was audited, for an older commit; merge goes by the vault, which has none now.
                if let earlier = board.tasks[index].evidence, earlier.commit != nil, earlier.commit != head {
                    board.tasks[index].outdatedEvidence = earlier
                }
                board.tasks[index].evidence = nil
            }
            if done { board.tasks[index].report = summary }
            board.tasks[index].blocker = done ? nil : (summary.isEmpty ? "The worker is blocked." : summary)
        }
        let stands = standing.map { verdict in
            "No new commit since its audit at \(verdict.commit.prefix(8)), which "
                + (verdict.passes ? "passed: that verdict stands" : "didn't pass (\(verdict.completion.rawValue), \(verdict.integrity.rawValue)): that verdict stands")
                + (!done ? "." : verdict.passes ? ". merge(\(slug)) when you're ready." : "; audit(\(slug)) to have it checked again.")
        }
        let text = done
            ? "The worker on \(slug) says it's done: \(summary)\n" + (stands ?? "Run audit(\(slug)); only the verifier's report counts.")
            : "The worker on \(slug) is blocked: \(summary)" + (stands.map { "\n\($0)" } ?? "")
        let told = try tellLead(text, about: "worker \(slug)")
        let kept = standing.map { " Your branch is still at \($0.commit.prefix(8)), the commit its audit covers, so that verdict stands." } ?? ""
        let reply = done
            ? (standing == nil ? "Reported. A verifier will check your branch; stay available for fixes." : "Reported." + kept)
            : "Reported. The lead will get back to you." + kept
        return MCPToolResult(text: reply + (told ? "" : Self.noLead))
    }

    private func askLead(_ arguments: [String: Any]) throws -> MCPToolResult {
        let slug = try taskSlug(arguments)
        let question = try text(arguments, "question", missing: "Ask something.")
        guard try tellLead("The worker on \(slug) asks: \(question)\nAnswer with message(\(slug), …).", about: "worker \(slug)") else {
            throw Problem(text: "There's no lead running to ask. Decide what you can within your contract, or report blocked.")
        }
        // Waiting on the answer isn't a stall (see `LeadStall`); the lead's next message answers it.
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].leadQuestionAt = Date().timeIntervalSince1970
        }
        return MCPToolResult(text: "Asked the lead. Keep working; the answer arrives as a message.")
    }

    private func progress(_ arguments: [String: Any]) throws -> MCPToolResult {
        let slug = try taskSlug(arguments)
        let text = try self.text(arguments, "text", missing: "Say what's done or under way.")
        // One line (several are joined), short enough for the lane; the board keeps the latest ones.
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let checkpoint = LeadCheckpoint(text: line.count > 300 ? String(line.prefix(300)) + "…" : line)
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].checkpoints = ((board.tasks[index].checkpoints ?? []) + [checkpoint]).suffix(LeadTask.keptCheckpoints)
        }
        return MCPToolResult(text: "Noted on your task's lane. Keep going.")
    }

    private func submitAudit(_ arguments: [String: Any], by member: LeadVault.Member) throws -> MCPToolResult {
        // Only from the verifier VibeSwitcher's lead started last for its task, about the commit it was started on:
        // the session host records it from this server's session, whatever it says.
        guard member.role == .verifier, let slug = member.task else {
            throw Problem(text: "Only the verifier VibeSwitcher started on a task can give its verdict.")
        }
        _ = try taskSlug(arguments)
        guard let completion = (arguments["completion"] as? String).flatMap(LeadEvidence.Completion.init(rawValue:)),
              let integrity = (arguments["integrity"] as? String).flatMap(LeadEvidence.Integrity.init(rawValue:)) else {
            throw Problem(text: "completion must be complete, incomplete or blocked; integrity clean, suspect or violation.")
        }
        let summary = arguments["summary"] as? String ?? ""
        let verdict: LeadVault.Verdict
        do { verdict = try vault.submitVerdict(root: root, completion: completion, integrity: integrity, summary: summary) } catch {
            throw Problem(text: "\(error)")
        }
        let audited = verdict.commit
        let evidence = LeadEvidence(completion: completion, integrity: integrity, summary: summary, commit: audited)
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].evidence = evidence
            board.tasks[index].outdatedEvidence = nil
            if board.tasks[index].status != .kept { board.tasks[index].status = evidence.passes ? .review : .failed }
            if !evidence.passes {
                board.tasks[index].setback = LeadSetback(stage: .review, reason: summary.isEmpty ? "The audit didn't pass (\(completion.rawValue), \(integrity.rawValue))." : summary,
                                                         evidence: evidence)
            }
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

    /// How many tasks status lists one per line in all (the rest by slug), and how many new reports.
    static let statusTasks = 24
    static let statusReports = 10

    private func status() -> String {
        let board = store.load()
        // nil: the host can't be read (what workers do isn't known), never "none running".
        let listing = try? listed()
        let sessions = listing.map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        let workflow = self.workflow
        var lines = ["Project \(project) on branch \(workflow.base) — \(board.tasks.count) task(s), max \(workflow.maxWorkers) workers at once."]
        lines += workflowWarnings(workflow)
        lines += diskWarning(workflow, board: board)
        if let line = records.statusLine { lines.append(line) }
        if let listing {
            let mac = MacLoad.count(listing.map { ($0.label, $0.cwd, $0.live) }, load: runtime.loadAverage())
            let full = macRefusal(mac, workflow, not: "") != nil
            lines.append("Mac (every project's team): \(Self.macText(mac, workflow)).\(full ? " start_worker and audit refuse until it eases; merge waits for the load." : "")")
        }
        if sessions == nil {
            lines.append("The session host can't be read right now: what the workers are doing isn't known; the states below are the board's.")
        }
        // Stalled workers first: VibeSwitcher's witness noticed them stop making progress, whatever their screens say.
        let stalled = board.stalled
        if !stalled.isEmpty {
            let now = Date()
            lines.append("\nStalled (\(stalled.count)):")
            lines += stalled.prefix(Self.statusTasks).map { task in
                Self.clip("- \(task.slug): \(task.stall!.text(now: now)). \(task.stall!.advice(slug: task.slug))", 300)
            }
        }
        // A task whose worker or verifier ended without a word, or whose session went with a replaced host, isn't
        // running: it's said apart, with what to do.
        let ended = sessions.map { sessions in board.tasks.compactMap { task in Self.endedMember(task, sessions).map { (task, $0) } } } ?? []
        let endedIDs = Set(ended.map(\.0.id))
        var budget = Self.statusTasks
        for state in LeadTask.Status.attentionOrder {
            var tasks = board.tasks.filter { $0.status == state && !endedIDs.contains($0.id) }
            guard !tasks.isEmpty else { continue }
            switch state {
            case .done:
                lines.append("\ndone (\(tasks.count)): " + Self.clip(tasks.map(\.slug).joined(separator: ", "), 600))
                continue
            case .failed:
                let abandoned = tasks.filter { $0.worktree == nil && $0.worker != nil }
                if !abandoned.isEmpty {
                    lines.append("\nabandoned (\(abandoned.count)): " + Self.clip(abandoned.map(\.slug).joined(separator: ", "), 600))
                }
                tasks.removeAll { abandoned.contains($0) }
                guard !tasks.isEmpty else { continue }
            default: break
            }
            lines.append("\n\(state.rawValue):")
            let shown = tasks.prefix(budget)
            budget -= shown.count
            lines += shown.map { taskLine($0, sessions) }
            if tasks.count > shown.count {
                lines.append(Self.clip("- … and \(tasks.count - shown.count) more: " + tasks.dropFirst(shown.count).map(\.slug).joined(separator: ", "), 600))
            }
        }
        if !ended.isEmpty {
            lines.append("\nworker ended (\(ended.count)), not running:")
            lines += ended.prefix(Self.statusTasks).map { task, who in
                Self.clip("- \(task.slug): \(Self.clip(task.title, 60)) — \(who)", 240)
            }
        }
        let open = board.openQuestions
        if !open.isEmpty {
            let now = Date().timeIntervalSince1970
            lines.append("\nWaiting on the user (\(open.count) question\(open.count == 1 ? "" : "s"), most important first):")
            lines += open.map { question in
                var line = "- \(question.short) [\(question.rank.rawValue), asked \(Self.age(now - question.askedAt)) ago"
                if question.version > 1 { line += ", revised \(Self.age(now - question.updatedAt)) ago" }
                line += "] \(question.text)"
                if question.isCounting, let proposal = question.proposal {
                    line += " — you go ahead with ‘\(proposal)’ at \(LeadBoard.clock(question.decideBy ?? now)) unless the user answers"
                } else if question.heldAt != nil {
                    line += " — the user is holding it (timer off): wait for their answer"
                }
                if !question.isCounting, now - question.updatedAt > LeadBoard.staleQuestion {
                    line += " — still relevant? Over an hour open: revise_question or withdraw_question if it's changed or settled."
                }
                return line
            }
        }
        if let reports = try? newReports(), !reports.isEmpty {
            // One line each: the full text is on the board (board(task)), and reports about finished work are a count.
            let finished = reports.filter { report in report.task.flatMap(board.task).map(LeadTeams.isFinished) ?? false }
            let current = reports.filter { !finished.contains($0) }
            lines.append("\nReports since your last status (\(reports.count)), each cut to its start (board(task) has a task's reports in full, read_session its conversation):")
            if current.count > Self.statusReports { lines.append("- \(current.count - Self.statusReports) earlier ones: board(task) has them.") }
            lines += current.suffix(Self.statusReports).map { "- \(LeadBoard.clock($0.at)) \($0.about): " + Self.clip($0.text, 200) }
            if !finished.isEmpty { lines.append("- \(finished.count) about tasks already merged or abandoned.") }
        }
        let answered = board.questions.filter { $0.state == .answered }.suffix(5)
        if !answered.isEmpty {
            lines.append("\nRecent answers:")
            lines += answered.map { question in
                let saw = question.answeredVersion ?? question.version
                let wording = question.wording(saw).text
                return "- \(wording) → \(question.answer ?? "")" + (saw < question.version ? " (to version \(saw) of \(question.version))" : "")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A task in one line (bounded): its title, what its worker does, its audit, rework, why it's kept, its last
    /// progress. `sessions` nil: the host can't be read.
    private func taskLine(_ task: LeadTask, _ sessions: [String: LeadSessionInfo]?) -> String {
        var line = "- \(task.slug): \(Self.clip(task.title, 60))"
        if task.status == .kept { line += " — kept: \(Self.clip(task.keptBecause ?? "no reason recorded", 80))" }
        if let worker = task.worker, let info = sessions?[worker] {
            line += " — worker \(info.live ? (info.status ?? "running") : task.stopped == worker ? "stopped" : "ended")"
        }
        if let evidence = task.evidence ?? task.outdatedEvidence { line += " — " + auditText(evidence, of: task) }
        if task.rework > 0 { line += " — rework \(task.rework)" }
        if let checkpoint = task.checkpoints?.last { line += " — last progress: \(Self.clip(checkpoint.text, 70))" }
        return Self.clip(line, 200)
    }

    /// "audit clean at <commit>" while the branch is still there; ", branch now at <head>" once it moved on, so the
    /// verdict no longer covers what would be merged.
    private func auditText(_ evidence: LeadEvidence, of task: LeadTask) -> String {
        var text = "audit " + (evidence.passes ? "clean" : "\(evidence.completion.rawValue)/\(evidence.integrity.rawValue)")
        guard let commit = evidence.commit else { return text }
        text += " at \(commit.prefix(8))"
        // A merged task's branch has done its part (cleanup may have removed it).
        guard task.status != .done else { return text }
        guard let head = branchHead(Worktrees.branch(task.slug)) else { return text + ", branch gone" }
        return head == commit ? text : text + ", branch now at \(head.prefix(8))"
    }

    /// Who of a running or reviewed task's team ended without a word, and what to do: its worker gone from the host
    /// (a replaced host takes every session with it) or ended without reporting, or its verifier ended without a
    /// verdict. nil when nothing ended (or the lead stopped it).
    static func endedMember(_ task: LeadTask, _ sessions: [String: LeadSessionInfo]) -> String? {
        switch task.status {
        case .running:
            guard let worker = task.worker, task.stopped != worker else { return nil }
            guard let info = sessions[worker] else {
                return "worker ended: its session is gone (the session host was replaced, or it was removed). start_worker continues in its worktree."
            }
            return info.live ? nil : "worker ended without reporting. read_session to see where it stopped; start_worker continues in its worktree."
        case .review where task.evidence == nil:
            guard let verifier = task.verifier else { return nil }
            guard let info = sessions[verifier] else { return "verifier ended: its session is gone, with no verdict. audit again." }
            return info.live ? nil : "verifier ended without a verdict. audit again."
        default:
            return nil
        }
    }

    /// At most `limit` characters, "…" when cut, on one line.
    static func clip(_ text: String, _ limit: Int = 300) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// "4 min", "2 h 5 min", "3 d".
    static func age(_ seconds: Double) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 24 * 60 { return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min" }
        return "\(minutes / (24 * 60)) d"
    }

    /// Every question, open first (as status orders them), then answered and withdrawn ones, each with its history.
    private func questionsText() -> String {
        let board = store.load()
        guard !board.questions.isEmpty else { return "No questions to the user yet." }
        let now = Date().timeIntervalSince1970
        func block(_ question: LeadQuestion) -> [String] {
            var lines = ["- \(question.short) [\(question.rank.rawValue), \(question.state.rawValue), asked \(Self.age(now - question.askedAt)) ago] \(question.text)"]
            if !question.options.isEmpty { lines.append("  options: \(question.options.joined(separator: " | "))") }
            if let why = question.whyNow { lines.append("  why now: \(why)") }
            for (index, revision) in (question.revisions ?? []).enumerated() {
                lines.append("  version \(index + 1) (until \(LeadBoard.clock(revision.at))): \(revision.text)"
                             + (revision.options.isEmpty ? "" : " [\(revision.options.joined(separator: " | "))]") + " — changed: \(revision.note)")
            }
            if let answer = question.answer {
                let saw = question.answeredVersion ?? question.version
                lines.append("  answered \(Self.age(now - (question.answeredAt ?? now))) ago" + (question.version > 1 ? " (to version \(saw) of \(question.version))" : "")
                             + (question.state == .withdrawn ? " after you withdrew it" : "") + ": \(answer)")
            }
            if question.state == .withdrawn {
                lines.append("  withdrawn \(Self.age(now - (question.withdrawnAt ?? now))) ago: \(question.withdrawReason ?? "")")
            }
            if let proposal = question.proposal {
                switch question.state {
                case .autoDecided:
                    lines.append("  no answer in \(question.decideInText): you went ahead with ‘\(proposal)’ \(Self.age(now - (question.autoDecidedAt ?? now))) ago"
                                 + (question.answer.map { "; the user answered later: \($0)" } ?? ""))
                case .open where question.heldAt != nil:
                    lines.append("  proposal ‘\(proposal)’; the user held it \(Self.age(now - (question.heldAt ?? now))) ago: no timer, wait for the answer")
                case .open:
                    lines.append("  proposal ‘\(proposal)’: you go ahead at \(LeadBoard.clock(question.decideBy ?? now)) unless the user answers")
                case .answered, .withdrawn:
                    lines.append("  proposal ‘\(proposal)’")
                }
            }
            return lines
        }
        var lines: [String] = []
        let open = board.openQuestions
        lines.append(open.isEmpty ? "Open: none." : "Open (\(open.count), most important first):")
        lines += open.flatMap(block)
        let answered = board.questions.filter { $0.state == .answered }
        if !answered.isEmpty { lines += ["", "Answered:"] + answered.reversed().flatMap(block) }
        let decided = board.questions.filter { $0.state == .autoDecided }
        if !decided.isEmpty { lines += ["", "Decided on your proposal (no answer in time):"] + decided.reversed().flatMap(block) }
        let withdrawn = board.questions.filter { $0.state == .withdrawn }
        if !withdrawn.isEmpty { lines += ["", "Withdrawn:"] + withdrawn.reversed().flatMap(block) }
        return lines.joined(separator: "\n")
    }

    /// The reports that came in since status last listed them, now marked seen.
    private func newReports() throws -> [LeadReport] {
        try store.update { board in
            let new = (board.reports ?? []).filter { $0.at > (board.reportsSeenAt ?? 0) }
            if let last = new.last { board.reportsSeenAt = last.at }
            return new
        }
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
                     "- max_workers: \(workflow.maxWorkers)",
                     "- disk_warning_gb: \(Self.gb(workflow.diskWarningGB)) (the lead is told below this much free space)",
                     "- disk_floor_gb: \(Self.gb(workflow.diskFloorGB)) (start_worker refuses below it)",
                     "- test_timeout_min: \(Self.gb(workflow.testTimeoutMinutes)) (merge stops init_command and test_command past it, as hung)",
                     "- load_threshold: \(Self.loadLimitText(workflow)) (above this 1-minute load, Mac-wide, start_worker and audit refuse and merge waits)",
                     "- mac_max_sessions: \(workflow.macMaxSessions) (workers and verifiers of all projects on this Mac; start_worker and audit refuse at it)"]
        let policy = workflow.mergePolicy.map { "\($0.rawValue) (\($0.meaning))" } ?? "not set: ask the owner once; until then merges are handled as ask_sensitive"
        lines.append("- merge_policy: \(policy)")
        lines.append("- sensitive_paths: \(workflow.sensitiveGlobs.joined(separator: ", "))\(workflow.sensitivePaths == nil ? " (the defaults)" : "")")
        let warnings = workflowWarnings(workflow)
        if !warnings.isEmpty { lines += [""] + warnings }
        return lines.joined(separator: "\n")
    }

    /// How many of the latest updates the board lists.
    static let boardUpdates = 5

    /// The board in one bounded line per task, with the open questions and the latest updates; with `task`, that task
    /// in full, with the reports about it.
    private func boardText(task wanted: String?) throws -> String {
        let board = store.load()
        let sessions = (try? listed()).map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        if let wanted, !wanted.isEmpty {
            guard let task = board.task(wanted) else { throw Problem(text: "No task \(wanted) on the board. board without task lists them.") }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var lines = [String(decoding: try encoder.encode(task), as: UTF8.self)]
            if let sessions, let ended = Self.endedMember(task, sessions) { lines.append("\nNow: \(ended)") }
            let reports = (board.reports ?? []).filter { $0.task == task.slug }
            lines.append(reports.isEmpty ? "\nNo reports about it on the board." : "\nReports about it (oldest first):")
            lines += reports.map { "- \(LeadBoard.clock($0.at)) \($0.about): \($0.text)" }
            return lines.joined(separator: "\n")
        }
        var counts: [LeadTask.Status: Int] = [:]
        for task in board.tasks { counts[task.status, default: 0] += 1 }
        let tally = LeadTask.Status.allCases.compactMap { state in counts[state].map { "\($0) \(state.rawValue)" } }.joined(separator: ", ")
        var lines = ["Board of \(project) (base \(workflow.base)): \(board.tasks.count) task(s)\(tally.isEmpty ? "" : ": \(tally)"). board(task) shows one in full."]
        lines += board.tasks.map { task in
            let ended = sessions.flatMap { Self.endedMember(task, $0) }
            // A running task whose worker ended reads so, not running.
            let state = ended.map { $0.hasPrefix("worker") ? "worker ended" : "verifier ended" } ?? task.status.rawValue
            return Self.clip("- \(task.slug) [\(state)] " + String(taskLine(task, sessions).dropFirst(task.slug.count + 4)), 200)
        }
        let open = board.openQuestions
        if !open.isEmpty {
            lines.append("\nOpen questions (\(open.count); questions has them in full):")
            lines += open.map { Self.clip("- \($0.short) [\($0.rank.rawValue)] \($0.text)", 200) }
        }
        if !board.updates.isEmpty {
            lines.append("\nLatest updates (\(board.updates.count) in all):")
            lines += board.updates.suffix(Self.boardUpdates).map { Self.clip("- \(LeadBoard.clock($0.at)) \($0.title)", 160) }
        }
        return lines.joined(separator: "\n")
    }

    private func sessionsText() -> String {
        let all: [LeadSessionInfo]
        do { all = try listed() } catch { return "The session host can't be read: \(error)" }
        let mine = all.filter { $0.cwd == root || $0.cwd.hasPrefix(root + "/") }
        guard !mine.isEmpty else { return "No window sessions in this project." }
        return mine.map { "- \($0.id): \($0.label) — \($0.live ? ($0.status ?? "running") : "ended") — \($0.cwd)" }.joined(separator: "\n")
    }
}
