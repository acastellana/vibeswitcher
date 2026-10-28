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
    /// The prompt it waits on (a permission, a question), in full, and since when; nil when it waits on none.
    public var waiting: PendingPrompt?

    public init(id: String, cwd: String, label: String, live: Bool, status: String?, tty: String?, pid: Int32? = nil,
                waiting: PendingPrompt? = nil) {
        self.id = id
        self.cwd = cwd
        self.label = label
        self.live = live
        self.status = status
        self.tty = tty
        self.pid = pid
        self.waiting = waiting
    }

    /// What it's doing, in a few words, for sessions and status: "waiting for input (6 min): “Run: ls …”" while it
    /// waits on a prompt (read_session has the prompt in full), its status otherwise.
    public func state(now: Date = Date(), prompt limit: Int = 80) -> String {
        guard live else { return "ended" }
        guard let waiting else { return status ?? "running" }
        return waiting.marker(now: now) + ": “\(waiting.line(limit))”"
    }
}

/// What the lead's tools need from the outside world (the session host, steering, transcripts). Faked in tests.
public protocol LeadRuntime: AnyObject {
    /// The `vibeswitcher-mcp` binary the roles are started with.
    var server: String { get }
    /// The project's Claude command (from its launch presets), flags included.
    func claudeCommand(root: String) -> String
    /// Starts a window session, `env` added to its environment.
    func spawn(cwd: String, command: String, env: [String: String], label: String, agent: String) throws -> String
    /// Answers Claude's trust question for `folder` in the session, if it asks (see `TrustPrompt.answer`): after the
    /// session's role is bound, since that can take seconds and its tool server may ask who it is before.
    func answerTrust(session: String, folder: String)
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
    /// Every project's live team sessions, counted (see `HostRequest.census`): `sessions` lists only what this caller
    /// may reach, its own team. Nil when the host doesn't count them (older than that); throws when it can't be read.
    func census() throws -> [HostCensus]?
    /// Its transcript, found with or without its hooks (see `LeadObserver`); throws when the host can't be read.
    func transcript(of session: String) throws -> String?
    /// The agent this tool server belongs to (its parent process).
    func currentAgent() -> LeadAgent?
    /// That agent process is still the one running on its terminal.
    func isRunning(_ agent: LeadAgent) -> Bool
    /// The Mac's 1- and 5-minute load averages (see `MacLoad.averages`); nil when they can't be read.
    func loadAverages() -> MacLoad.Averages?
    /// The model the project's workers run on, as `claude --model` names it (nil: Claude's default, not known).
    func workerModel(root: String) -> String?
    /// How a session's agent ended, in the witness's words (see `LeadWitness.verifierEnding`): its session's ending
    /// ("killed by SIGTERM"), or that its agent quit and left the session's shell open; nil while its agent runs, or
    /// when that can't be told.
    func agentEnding(_ session: LeadSessionInfo) -> String?
    /// What this Mac lacks to start a session with `command` (the agent's CLI, git, the Command Line Tools, the tool
    /// server): see `LaunchPreflight`. Blocks while the login shell answers.
    func preflight(command: String) -> LaunchPreflight.Problem?
}

public extension LeadRuntime {
    /// The load start_worker, audit, merge and auto_advance judge room by: the greater of the 1- and 5-minute
    /// averages (`MacLoad.Averages.steady`), so a dip of the 1-minute after a spike isn't taken for room.
    func steadyLoad() -> Double? { loadAverages()?.steady }

    /// None: the Mac-wide limits count the sessions `sessions` lists.
    func census() throws -> [HostCensus]? { nil }

    /// Nothing looked at: a runtime that starts no real agent (the tests') lacks nothing.
    func preflight(command: String) -> LaunchPreflight.Problem? { nil }

    /// From the Claude command's own --model only; the app's runtime also reads Claude's settings (see `HostRuntime`).
    func workerModel(root: String) -> String? { LeadWorkflow.claudeModel(command: claudeCommand(root: root)) }

    /// From the session host's record and the process table, as the app's witness tells it: quit when its agent's
    /// process has exited a minute after it started (`LeadWitness.agentQuitEnding`), by a table read whole.
    func agentEnding(_ session: LeadSessionInfo) -> String? {
        let hosted = (try? HostCall.sessions())?.first { $0.id.uuidString == session.id }
        guard session.live, hosted?.isLive ?? true else { return hosted?.exit?.cause ?? "its session ended" }
        guard let hosted, hosted.agentQuit(now: Date()) else { return nil }
        return LeadWitness.agentQuitEnding(hosted, table: ProcessTable.trySnapshot())
    }
}

/// The project lead's tools, and the few that workers and verifiers get, over the board and the runtime.
///
/// Who may use which tools comes from the session host (see `LeadVault`), never from the server's arguments or the
/// board: the host tells which session this server's process runs in, and which role and task that session holds.
/// Every call asks again. A server in no such session has no tools.
public final class LeadToolset: MCPToolset {
    /// The session's role; nil when it holds none (then nothing is served and `refusal` says why).
    let role: LeadLaunch.Role?
    /// The session host answered that the session holds no role (yet): VibeSwitcher or the lead may still be binding
    /// it, so the tool server asks again for a while (see vibeswitcher-mcp).
    public let awaitsRole: Bool
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
    /// A session's processes cleanup may end itself when the host didn't: the user's carrying its
    /// `VIBESWITCHER_SESSION` id (decision 2026-10-23 02:44; see `SessionStrays.carrying`). Faked in tests.
    var sessionProcesses: (String) -> [SessionStrays.Found] = { id in UUID(uuidString: id).map { SessionStrays.carrying(session: $0) } ?? [] }
    /// The bytes free on the volume holding a path (see `DiskSpace.free`), and where Claude Code keeps its sessions'
    /// temporary folders (see `ClaudeScratch`). Faked in tests.
    var freeSpace: (String) -> Int64? = DiskSpace.free(at:)
    var scratchRoot = ClaudeScratch.root
    /// Where its workers' and verifiers' TMPDIRs are made (see `SessionTemp`).
    var sessionTempRoot = SessionTemp.root
    /// The Mac's power source as the app last read it (see `PowerState.load`). Faked in tests.
    var power: () -> PowerState? = { PowerState.load() }
    /// The home whose `.claude/projects` holds its workers' and verifiers' transcripts, read for receipts (see
    /// `LeadReceipts`). A scratch one in tests.
    var claudeHome = VibePaths.home
    /// How often merge reads the load again while it waits for it to drop below load_threshold.
    var loadPoll: TimeInterval = 15
    /// The Mac-wide limits as set in Settings (see `MacLimits`), read at each call. Faked in tests.
    var macLimits: () -> MacLimits = { MacLimits.load() }
    /// Where a call refused for the Mac's room or load is kept, so the app's witness wakes this lead once there's room.
    var roomWaits = LeadWitness.RoomWaits()
    /// How long a worker's or verifier's start waits for its tool server to ask the session host who it is (its
    /// tools connected; see `LeadVault.RosterEntry.toolsAt`) before it's ended and the call fails: one that never
    /// gets its tools can't report. 0 (tests that don't fake a tool server): not waited for. The tool server sets 45 s.
    public var toolsWait: TimeInterval = 0
    /// How often that wait reads the roster.
    var toolsPoll: TimeInterval = 0.25
    /// Moves finished work on by itself (see `LeadAdvance`), once `startAdvancing` is called (the lead's server).
    var advancing: LeadAdvance?
    /// The risk check's model pass (see `LeadRisk`): a prompt in, the answer out, or nil (no Claude, an error, out of
    /// time). The lead's tool server sets headless Claude (`ClaudeHeadless.risk`); nil (tests that don't fake it):
    /// the deterministic triggers only.
    public var riskModel: ((String) -> String?)?
    /// The model pass's answers by task and commit (nil: keep, an error or a timeout), so a merge after auto_advance's
    /// look, or a pass after another, doesn't ask again.
    private var riskAnswers: [String: String?] = [:]
    private let riskLock = NSLock()
    /// Status said once that workflow.md's Mac-wide keys are ignored.
    private var toldIgnoredKeys = false
    private let tellingIgnoredKeys = NSLock()
    /// Status said once that decisions.md is past the size to archive (`LeadRecords.archiveNudge`).
    private var toldArchive = false
    /// When this server last moved finished tasks to the board's archive (`archiveFinished`), and its clock (faked in
    /// tests).
    var archivedAt: Double?
    private let archiving = NSLock()
    var archiveClock: () -> Double = { Date().timeIntervalSince1970 }
    /// The slots merge's and an audit's test runs take one of (see `TestLock`; the workflow's heavy_slots sets how
    /// many): the tool server sets the Mac-wide ones, every project's merges sharing them with `vs-heavy`; nil (tests
    /// that don't give scratch ones): none.
    public var testLock: TestLock?

    /// `testLock` with the workflow's heavy_slots, when set.
    func heavyLock(_ workflow: LeadWorkflow) -> TestLock? {
        testLock.map { lock in workflow.heavySlots.map(lock.with(slots:)) ?? lock }
    }

    /// "3 (not set: the Mac's cores ÷ 4)", as merge and audits take them.
    func heavySlotsText(_ workflow: LeadWorkflow) -> String {
        let count = heavyLock(workflow)?.slots ?? workflow.heavySlots ?? TestLock.slotCount()
        return workflow.heavySlots == nil ? "\(count) (not set: VIBESWITCHER_HEAVY_SLOTS, else the Mac's cores ÷ 4)" : "\(count)"
    }

    /// Status's word on a test and build slot held over `TestLock.longAfter`, or whose holder has been idle over
    /// `TestLock.idleAfter`: "; a test and build slot held long: TGE (pytest -q) for 38 min, idle 35 min". Only said.
    func longHolderText() -> String {
        guard let lock = heavyLock(workflow) else { return "" }
        let now = Date()
        let long = lock.holders().filter { $0.isLong(now: now) || $0.isIdle(now: now) }
        guard !long.isEmpty else { return "" }
        let how = long.allSatisfy { $0.isLong(now: now) } ? "held long" : "held long or idle"
        return "; \(long.count == 1 ? "a test and build slot" : "\(long.count) test and build slots") \(how): " + long.map { $0.short(now: now) }.joined(separator: ", ")
    }

    /// Status's line on the Mac-wide test and build lock while a slot is held or a running task's worker waits for one:
    /// who holds each, and each such worker's wait ("the-y: waiting for the Mac-wide test lock (held by vibeswitcher/x
    /// for 12 min), 2nd in line"), which isn't a stall (see `LeadStall`). Nil otherwise.
    func heavyLockLine(_ board: LeadBoard, now: Date = Date()) -> String? {
        guard let lock = heavyLock(workflow) else { return nil }
        let running = board.tasks.filter { $0.status == .running }.map { ($0.slug, Worktrees.path(root: root, slug: $0.slug)) }
        let waits = lock.waits(for: Dictionary(running, uniquingKeysWith: { first, _ in first }))
        let holders = lock.holders()
        guard !holders.isEmpty || !waits.isEmpty else { return nil }
        var line = "Mac-wide test and build lock: " + (holders.isEmpty ? "a slot just freed" : "held by " + holders.map { $0.whoFor(now: now) }.joined(separator: ", "))
        let waiting = waits.sorted { $0.value.waiter.number < $1.value.waiter.number }.map { "\($0.key): \($0.value.text(now: now))" }
        if !waiting.isEmpty { line += "; " + waiting.joined(separator: "; ") + " (not stalled)" }
        return Self.clip(line + ".", 400)
    }

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
        awaitsRole = unknownRole == nil && problem == nil && member == nil
        grant = refusal == nil ? member?.id : nil
        role = refusal == nil ? member?.role : nil
        taskID = refusal == nil ? member?.task : nil
        if role == .lead, (try? authenticate()) != nil {
            introduceLead()
            // An existing project's board is moved over the first time a server with the archive starts on it.
            archiveFinished(force: true)
        }
    }

    /// Moves the board's finished tasks a day old to its archive (`BoardStore.archive`): on the lead's server's start
    /// (`force`), and after merges at most every `BoardStore.archiveEvery`. Never in the app.
    func archiveFinished(force: Bool) {
        archiving.lock()
        defer { archiving.unlock() }
        let now = archiveClock()
        if !force, let last = archivedAt, now - last < BoardStore.archiveEvery { return }
        archivedAt = now
        _ = try? store.archive(now: now)
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
    public func keepRecords(run: @escaping (@escaping () -> Void) -> Bool = { $0(); return true }) {
        guard role == .lead else { return }
        records.start(run: run) { [weak self] in
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
                MCPToolInfo(name: "report", description: "Tell the lead you're done (everything committed, checks passing), blocked (say what you need), or over_budget (once VibeSwitcher says your task's time budget is reached: commit what works first). A verifier then checks a done branch. Done needs evidence for every acceptance check and your blind check's outcome: a done without them is refused, naming what's missing.",
                            properties: ["status": P(type: "string", description: "done, blocked, or over_budget", options: ["done", "blocked", Self.overBudgetStatus]),
                                         "summary": P(type: "string", description: "What changed and how you checked it, or what blocks you; for over_budget: what works (with evidence), what's missing, and your proposal (finish in N more minutes, cut scope, or another approach)"),
                                         "evidence": P(type: "array", description: Self.evidenceShape, items: "object"),
                                         "blind_check": P(type: "string", description: Self.blindCheckShape)],
                            required: ["status", "summary"]),
                MCPToolInfo(name: "ask_lead", description: "Ask the project lead something without stopping your work; the answer arrives as a message.",
                            properties: ["question": P(type: "string", description: "The question")], required: ["question"]),
                MCPToolInfo(name: "progress", description: "Note a milestone in one line (a part working, checks passing, what's next). It shows on your task's lane in the lead's Team view; it doesn't message the lead. Call it at each milestone.",
                            properties: ["text": P(type: "string", description: "One line: what's done or under way")], required: ["text"]),
                MCPToolInfo(name: "answer_findings", description: "Answer your task's open audit findings by id: fixed (commit the fix first) or disagree, with a reason. The lead sees the answers, and the re-audit judges them: it checks each fix, and closes a finding whose disagreement it accepts.",
                            properties: ["answers": P(type: "array", description: Self.answersShape, items: "object")], required: ["answers"]),
            ]
        case .verifier?:
            return [MCPToolInfo(name: "submit_audit", description: "Your verdict on the worker's branch, with evidence and your findings. Only this moves a task to done; an open Important finding holds its merge back.",
                                properties: ["completion": P(type: "string", description: "Does the branch do what the contract asks?", options: ["complete", "incomplete", "blocked"]),
                                             "integrity": P(type: "string", description: "clean; suspect (not sure); violation (edits outside the boundaries, weakened or deleted tests, faked results)",
                                                            options: ["clean", "suspect", "violation"]),
                                             "summary": P(type: "string", description: "The evidence: what you ran and what you saw"),
                                             "tests": P(type: "string", description: "How the tests went when you ran them: passed, failed, or not_run (you didn't run them)",
                                                        options: LeadVault.TestRun.allCases.map(\.rawValue)),
                                             "findings": P(type: "array", description: Self.findingsShape, items: "object")],
                                required: ["completion", "integrity", "summary"])]
        case .lead?:
            return [
                MCPToolInfo(name: "status", description: "The board at a glance: tasks by state, workers and what they're doing, open questions, and each report that came in since you last asked, in one line (board(task) or read_session has the full text)."),
                MCPToolInfo(name: "board", description: "The board in one line per task, with the open questions and the latest updates; with task, that task in full: its contract, evidence, setback, reports, checkpoints and merge.",
                            properties: ["task": P(type: "string", description: "A task's slug (or id): that task in full")]),
                MCPToolInfo(name: "add_task", description: "Put a task on the board with its contract (title, goal and acceptance), or make one of an audit's finding (from_finding: the contract comes from it, anything you pass replaces that part, and the finding is closed as moved to the new task).",
                            properties: ["title": P(type: "string", description: "Short title"),
                                         "goal": P(type: "string", description: "What must be true when it's done"),
                                         "acceptance": P(type: "array", description: "Checks that can be run or seen. " + LeadPrompts.Policy.leadContracts, items: "string"),
                                         "boundaries": P(type: "array", description: "Files or areas it may touch; what it must not do", items: "string"),
                                         "context": P(type: "string", description: "What a fresh worker needs to know"),
                                         "from_finding": P(type: "string", description: "A finding as status and board name it, <task>:<id> (e.g. add-b:F2)"),
                                         "review": Self.reviewProperty, "after": Self.afterProperty, "auto_advance": Self.autoAdvanceProperty,
                                         "budget_min": Self.budgetProperty]),
                MCPToolInfo(name: "dismiss_finding", description: "Close one of a task's open audit findings with a reason (it isn't a problem, it's out of scope, the user accepted it): it no longer holds the merge back, and no verifier raises it again.",
                            properties: ["task": task, "id": P(type: "string", description: "The finding's id (F2), or <task>:<id>"),
                                         "reason": P(type: "string", description: "Why, in one line (it's kept with the finding)")],
                            required: ["task", "id", "reason"]),
                MCPToolInfo(name: "update_task", description: "Change a task: its contract, or its state. planned, blocked (waits on something), failed (tried and didn't pass); kept: deliberately not merged, which merge then refuses; folded into another task that carries its work (overtaken or batched); abandoned with a reason when nothing will carry it; folded and abandoned tasks are finished, never counted as failed, and cleanup removes their worktree and branch. removed: only for a record made by mistake that never ran (no worker, branch or merge); it leaves the board.",
                            properties: ["task": task, "title": P(type: "string", description: "New title"), "goal": P(type: "string", description: "New goal"),
                                         "acceptance": P(type: "array", description: "New checks (replaces them all)", items: "string"),
                                         "boundaries": P(type: "array", description: "New boundaries (replaces them all)", items: "string"),
                                         "context": P(type: "string", description: "Replaces the whole context; to add to it, use append_context"),
                                         "append_context": P(type: "string", description: "Added at the end of the context, which keeps what it had"),
                                         "status": P(type: "string", description: "New state", options: Self.settableStates.map(\.rawValue) + [Self.removedState]),
                                         "reason": P(type: "string", description: "With status kept: what holds it back (a decision, the user's word); merge names it when it refuses. With abandoned: why nothing will carry it. With removed: why it was a mistake (optional)"),
                                         "into": P(type: "string", description: "With status folded: the task (its slug) that carries this one's work"),
                                         "review": Self.reviewProperty, "after": Self.afterProperty, "auto_advance": Self.autoAdvanceProperty,
                                         "budget_min": Self.budgetProperty,
                                         "reroll": P(type: "boolean", description: "Re-roll it after audit rounds that didn't land: its worker and verifier stop, its branch is kept as archive/<slug>-<n>, its worktree goes, and a fresh worker starts from the base on a new agent/<slug>, its context given a summary of the findings and the worker's answers so far. Contract changes in the same call apply first; not with status")],
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
                MCPToolInfo(name: "audit", description: "Start the read-only verifier on a task's branch. Its report, not the worker's, decides. A worktree left on another branch or a detached HEAD is put back on agent/<slug> first (refused, and its worker told what to run, when it holds uncommitted files or commits the branch lacks). A verifier already auditing the branch's head is left alone (the reply says since when and on which commit); a new commit, or a verifier that has ended, starts a new one in its place.",
                            properties: ["task": task, "restart": P(type: "boolean", description: "End the verifier already auditing the branch's head and start a new one on the same commit (its work is thrown away)")],
                            required: ["task"]),
                MCPToolInfo(name: "merge", description: "Merge a task: rebase onto the lead's branch (squashed when the worker merged it in), run the test command, fast-forward that branch. An audit task (or one whose branch touches sensitive_paths) needs its passing audit; a review none task needs only its worker's done report on the branch's head and the test command passing.",
                            properties: ["task": task], required: ["task"]),
                MCPToolInfo(name: "revert", description: "Undo a merged task in one step: one commit on top of the lead's branch reverts the commits its merge put there, the test command runs on it, and the branch fast-forwards to it; the task reads reverted. It only adds a commit (nothing is reset or rewritten). Refused, with the branch untouched, when the tests fail or when later commits conflict with the revert (it names the files and the tasks that touched them: plan a fix-forward task instead).",
                            properties: ["task": task, "reason": P(type: "string", description: "What the merge broke, in one line: it goes into the revert commit's message and the task's record")],
                            required: ["task", "reason"]),
                MCPToolInfo(name: "cleanup", description: "End a task's sessions and remove its worktree and branch (after merging, or force to abandon it).",
                            properties: ["task": task, "force": P(type: "boolean", description: "Also discard unmerged work")], required: ["task"]),
                MCPToolInfo(name: "accept_git_hooks", description: "Let the tool server's git (merges, cleanups, start_worker, auto_advance) run the repository's git hooks as they are now. It runs only hooks you accepted, from a copy, never the hooks folder a worker can write: status, merge and the rest tell you when that folder isn't as you accepted it. Read each hook first; accept only the user's own.",
                            properties: ["hooks": P(type: "array", description: "The hooks to run, by name (e.g. commit-msg); empty or left out: all that are there now", items: "string")]),
                MCPToolInfo(name: "ask_user", description: "Ask the user something. It doesn't block: keep working; the answer arrives as a message. Your open questions are a queue the user answers in any order: revise one when you learn something (revise_question), withdraw one that no longer applies (withdraw_question). For a reversible choice, prefer proposing your answer with a timer (proposal, decide_in): the user can pick another option or hold it, and if no answer comes in time you get a message to go ahead with your proposal, recorded as your decision. Never a timer on a blocking question, on merging a sensitive path, on deleting or discarding work, or on anything outward-facing (publishing, pushing, sending): those are refused.",
                            properties: ["question": P(type: "string", description: "One clear question"),
                                         "options": P(type: "array", description: "Suggested answers (the user can also write their own)", items: "string"),
                                         "priority": P(type: "string", description: "blocking (work waits on it; it badges the Dock), important (the default), or whenever",
                                                       options: LeadQuestion.Priority.allCases.map(\.rawValue)),
                                         "why_now": P(type: "string", description: "One line: why you need it now (shown with the question)"),
                                         "proposal": P(type: "string", description: "Your proposed answer, one of the options: it starts a timer, and silence means you go ahead with it (reversible choices only)"),
                                         "decide_in": P(type: "integer", description: "Minutes until you go ahead with the proposal (default \(LeadQuestion.defaultDecideIn))"),
                                         "task": P(type: "string", description: "The task it's about (its slug), when it's about one: its wait on the user counts on that task's score")],
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
                                         "images": P(type: "array", description: "Absolute paths of screenshots (image files; a copy is kept, so they stay viewable after cleanup)", items: "string")],
                            required: ["title", "body"]),
                MCPToolInfo(name: "record_decision", description: "Write a decision and its reason to decisions.md.",
                            properties: ["decision": P(type: "string", description: "The decision"), "why": P(type: "string", description: "The reason")],
                            required: ["decision", "why"]),
                MCPToolInfo(name: "archive_decisions", description: "Move decisions that no longer hold from decisions.md to decisions-archive.md, unchanged and with their dates (superseded, obsolete, or now enforced by a check): every lead start reads decisions.md, not the archive. decisions.md keeps the rest in order and one line pointing to the archive; nothing is deleted. An entry that's unknown, or a name that fits several, refuses the call with nothing moved.",
                            properties: ["entries": P(type: "array", description: "The entries to move, each by its heading (without ##) or its start, e.g. its stamp \"2026-10-17 12:15\" (to the minute or the second)", items: "string"),
                                         "reason": P(type: "string", description: "Why they go, in one line (it heads this batch in the archive)")],
                            required: ["entries", "reason"]),
                MCPToolInfo(name: "record_incident", description: "Record an incident (something broke the user's work: a hang, a lost message, a reverted merge) in incidents.md, and plan a task that turns it into a check that runs before merge (a test, or a case in regression_command's corpus), so a merge that brings it back is refused.",
                            properties: ["what": P(type: "string", description: "What happened, in one line"),
                                         "evidence": P(type: "string", description: "How it showed: the transcript, log, commit or steps that reproduce it"),
                                         "task": P(type: "string", description: "The task it happened in or came from (its slug), if any")],
                            required: ["what", "evidence"]),
                MCPToolInfo(name: "sessions", description: "This project's window sessions, live or ended."),
                MCPToolInfo(name: "configure", description: "The project's workflow settings (workflow.md's front matter): without arguments, shows them with suggestions from the repository; with some, sets those (an empty string clears one) and keeps the rest of the file as it is.",
                            properties: ["test_command": P(type: "string", description: "The project's checks; merge runs it on each rebased branch and merges only when it passes"),
                                         "regression_command": P(type: "string", description: "The checks incidents became (e.g. a bench corpus run); merge runs it after test_command and merges only when it passes too"),
                                         "init_command": P(type: "string", description: "What a fresh worktree needs before work starts (install, build)"),
                                         "base_branch": P(type: "string", description: "The branch workers start from and verified work is merged into (an existing local branch)"),
                                         "verifier_model": P(type: "string", description: "The verifier's model (e.g. fable, opus). Empty: audits run on another model than the workers', at least as capable (fable; opus when the workers run fable)"),
                                         "max_workers": P(type: "integer", description: "How many workers may run at once (at least 1)"),
                                         "disk_warning_gb": P(type: "number", description: "Free space (GB) on the worktrees' volume below which you're told, once, what takes the space (default 10)"),
                                         "disk_floor_gb": P(type: "number", description: "Free space (GB) below which start_worker refuses (default 3)"),
                                         "test_timeout_min": P(type: "number", description: "Minutes merge lets init_command and test_command run before it takes them as hung and stops them (default 45)"),
                                         "task_budget_min": P(type: "integer", description: "A task's time budget when it sets none (add_task budget_min), in minutes of its worker's working time: at it the worker is told to stop and report over_budget, and you decide (default 120; 0: no budget)"),
                                         "heavy_slots": P(type: "integer", description: "How many builds and full test runs (vs-heavy's, merges', audits') may run at once across all projects on this Mac (empty: the cores ÷ 4)"),
                                         "audit_finders": P(type: "integer", description: "How many finders an audit runs: 1 (one verifier, the default), 2 or 3 (different focuses on one shared build and test run, and a vote keeps what most of them found; each counts against mac_max_sessions)"),
                                         "audit_nit_cap": P(type: "integer", description: "How many new Nit findings one audit's vote keeps (default 5)"),
                                         "merge_policy": P(type: "string", description: "How merges are handled, as the owner chose once: auto (work merges once its review passes: its audit, or for review none its worker's done report and the merge's test run; the user gets an update afterwards), ask_sensitive (a commit touching sensitive_paths waits for the user's approval of that exact commit), ask_all (every merge waits)",
                                                           options: LeadWorkflow.MergePolicy.allCases.map(\.rawValue)),
                                         "sensitive_paths": P(type: "string", description: "The globs ask_sensitive holds back, comma-separated, as in .gitignore (empty: Claude's settings and instructions, .github, .env files, entitlements, keys)"),
                                         "auto_advance": P(type: "boolean", description: "Whether VibeSwitcher moves finished work on by itself (default true): a task reported done is merged (review none) or audited, a clean audit merged, open Important findings sent back to its worker, a merged task cleaned up, and a planned task started once its after tasks are done; you get one report of what it did. false: you do each"),
                                         "risk_lines": P(type: "integer", description: "The risk check's size trigger: a review none task whose branch changes more lines than this (added and removed) is audited instead of merged when it reports done (default 400; 0: no size trigger)"),
                                         "risk_model": P(type: "boolean", description: "Whether the risk check also asks headless Claude, from the diff's stat, the contract and the base branch's REVIEW.md (no code), to raise a review none task to audit (default true); it only raises, and a timeout or error leaves the deterministic triggers' result"),
                                         "watch_app_logs": P(type: "boolean", description: "Whether you get VibeSwitcher's own health digests (default false; only for the project that builds VibeSwitcher): its freezes, crashes and error lines as it logs them, and a daily trend, each as a witness report to turn into tasks where it's a real bug")]),
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
            case "status": return withGitNotice(MCPToolResult(text: status()))
            case "board": return try MCPToolResult(text: boardText(task: arguments["task"] as? String))
            case "add_task": return try addTask(arguments)
            case "dismiss_finding": return try dismissFinding(arguments)
            case "update_task": return try updateTask(arguments)
            case "start_worker": return withGitNotice(try startWorker(try taskSlug(arguments), recover: arguments["recover"] as? Bool ?? false))
            case "stop_worker": return try stopWorker(try taskSlug(arguments))
            case "message": return try message(try taskSlug(arguments), arguments)
            case "read_session": return try readSession(try taskSlug(arguments), who: arguments["who"] as? String ?? "worker")
            case "audit": return try audit(try taskSlug(arguments), restart: arguments["restart"] as? Bool ?? false)
            case "merge":
                let merged = try merge(try taskSlug(arguments))
                records.flush(base: base)
                return withGitNotice(merged)
            case "revert":
                let reverted = try revert(try taskSlug(arguments), reason: arguments["reason"] as? String ?? "")
                records.flush(base: base)
                return withGitNotice(reverted)
            case "cleanup": return withGitNotice(try cleanup(try taskSlug(arguments), force: arguments["force"] as? Bool ?? false))
            case "accept_git_hooks": return try acceptGitHooks(arguments)
            case "ask_user": return try askUser(arguments)
            case "revise_question": return try reviseQuestion(arguments)
            case "withdraw_question": return try withdrawQuestion(arguments)
            case "questions": return MCPToolResult(text: questionsText())
            case "post_update": return try postUpdate(arguments)
            case "record_decision": return try recordDecision(arguments)
            case "archive_decisions": return try archiveDecisions(arguments)
            case "record_incident": return try recordIncident(arguments)
            case "sessions": return MCPToolResult(text: sessionsText())
            case "configure": return try configure(arguments)
            case "report": return try report(arguments)
            case "ask_lead": return try askLead(arguments)
            case "progress": return try progress(arguments)
            case "answer_findings": return try answerFindings(arguments)
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

    /// `result`, and what the tool server's git doesn't run in this repository (`GitGuard.notice`) when there's any.
    private func withGitNotice(_ result: MCPToolResult) -> MCPToolResult {
        guard let notice = GitGuard.notice(root: root) else { return result }
        return MCPToolResult(text: result.text + "\n\n" + notice, isError: result.isError)
    }

    /// The repository's hooks, as they are now, for the tool server's git to run (`GitGuard.accept`); in the progress log.
    private func acceptGitHooks(_ arguments: [String: Any]) throws -> MCPToolResult {
        let named = (arguments["hooks"] as? [String])?.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        let accepted: String
        do { accepted = try GitGuard.accept(root: root, only: named.isEmpty ? nil : named) } catch let refused as GitGuard.Refused {
            throw Problem(text: refused.description)
        }
        try? store.appendProgress("Git hooks accepted: \(accepted)")
        return MCPToolResult(text: accepted)
    }

    private func fail(_ text: String) -> MCPToolResult { MCPToolResult(text: text, isError: true) }

    private func taskSlug(_ arguments: [String: Any]) throws -> String {
        // A worker or verifier acts on its own task only, whatever it passes: its session's, by slug, not
        // whatever the board (which anyone can edit) says that slug is.
        if role != .lead {
            guard let taskID, try store.read().taskIndex(taskID) != nil else { throw Problem(text: "Your task isn't on the board any more.") }
            return taskID
        }
        guard let wanted = arguments["task"] as? String, let task = try store.read().task(wanted) ?? store.archived().first(where: { $0.id == wanted || $0.slug == wanted }) else {
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
    static let settableStates: [LeadTask.Status] = [.planned, .blocked, .failed, .kept, .folded, .abandoned]
    /// update_task's status that takes a record off the board (`removeTask`), not a state of a task.
    static let removedState = "removed"
    /// add_task's and update_task's review level.
    static var reviewProperty: MCPToolInfo.Property {
        MCPToolInfo.Property(type: "string", description: "Who checks it before merge: none (the default: its worker owns it through completion, and merge takes it on the worker's done report and its own full test run) or audit (a verifier's passing verdict: for security, irreversible operations or complex changes). A branch that touches sensitive_paths is audited whatever this says.",
                             options: LeadTask.Review.allCases.map(\.rawValue))
    }
    /// add_task's and update_task's prerequisites.
    static var afterProperty: MCPToolInfo.Property {
        MCPToolInfo.Property(type: "array", description: "The tasks (their slugs) that must be done first: with auto_advance on, a planned task starts by itself once every one of them is done (none: as soon as a worker slot and the Mac have room). An empty list clears it",
                             items: "string")
    }
    /// add_task's and update_task's per-task opt-out of auto_advance.
    static var budgetProperty: MCPToolInfo.Property {
        MCPToolInfo.Property(type: "integer", description: "Its time budget, in minutes of its worker's working time (waiting on you or the user, and audits, don't count): at it the worker is told to stop and report over_budget. 0: none. Not given: workflow.md's task_budget_min. Changing it clears an over-budget state, and the next stop comes at the new budget")
    }

    /// The `budget_min` passed to add_task or update_task; nil when none was.
    private func budgetArgument(_ arguments: [String: Any]) throws -> Int? {
        guard let given = arguments["budget_min"], !(given is NSNull), !((given as? String)?.isEmpty ?? false) else { return nil }
        let number = (given as? NSNumber)?.doubleValue ?? (given as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard let number, number >= 0, number == number.rounded() else {
            throw Problem(text: "budget_min is a whole number of minutes, 0 (no budget) or more, not \(given). Nothing was changed.")
        }
        return Int(number)
    }

    static var autoAdvanceProperty: MCPToolInfo.Property {
        MCPToolInfo.Property(type: "boolean", description: "false: VibeSwitcher moves nothing on this task by itself (no automatic start, audit, merge, send-back or cleanup), whatever workflow.md's auto_advance says; true (the default) clears that")
    }

    /// The states the lead settles a task in: finished, never counted as failed; nothing starts, audits or merges on it.
    static let settledStates: [LeadTask.Status] = [.folded, .abandoned, .reverted]

    // MARK: Lead

    private func addTask(_ arguments: [String: Any]) throws -> MCPToolResult {
        // A finding made a task: its contract comes from the finding; what the lead passes replaces that part.
        var origin: (slug: String, finding: LeadFinding)?
        if let reference = (arguments["from_finding"] as? String)?.trimmingCharacters(in: .whitespaces), !reference.isEmpty {
            origin = try finding(reference)
            // A Nit never becomes a task (the working policy, 2026-10-21: four picker-card tasks chained from Nits).
            if let origin, origin.finding.severity == .nit {
                throw Problem(text: "Not added: \(origin.slug):\(origin.finding.id) is a Nit, and a Nit never becomes a task: it stays recorded on "
                              + "\(origin.slug), and a worker fixes it only while it's in that code anyway. If it really breaks something, "
                              + "it isn't a Nit: plan that problem as a task of its own with add_task, saying what goes wrong.")
            }
        }
        let given = { (key: String) in (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        guard let title = given("title") ?? origin.map({ Self.findingTitle($0.finding) }), let goal = given("goal") ?? origin.map({ Self.findingGoal($0.finding) }) else {
            throw Problem(text: "A task needs a title and a goal (or from_finding, which gives them).")
        }
        let contract = LeadContract(goal: goal,
                                    acceptance: arguments["acceptance"] != nil ? strings(arguments["acceptance"]) : origin.map { [Self.findingCheck($0.finding)] } ?? [],
                                    boundaries: arguments["boundaries"] != nil ? strings(arguments["boundaries"]) : origin.map { ["\($0.finding.file) and its tests"] } ?? [],
                                    context: given("context") ?? origin.map { Self.findingContext($0.finding, of: $0.slug) } ?? "")
        guard !contract.acceptance.isEmpty else { throw Problem(text: "Give at least one acceptance check: something that can be run or seen.") }
        let review = try reviewArgument(arguments)
        let auto = try autoArgument(arguments)
        let budget = try budgetArgument(arguments)
        let task = try store.update { board -> LeadTask in
            var task = LeadTask(slug: Slug.make(title, taken: store.takenSlugs(board)), title: title, contract: contract)
            task.review = review
            if arguments["after"] != nil { task.after = try Self.afterList(strings(arguments["after"]), on: store.withArchive(board), for: task.slug) }
            task.autoAdvance = auto == false ? false : nil
            task.budgetMin = budget
            board.tasks.append(task)
            return task
        }
        try? store.appendProgress("Planned \(task.slug): \(title)" + (review == .audit ? " (review audit)" : ""))
        let recorded = review.map { recordReview($0, slug: task.slug) } ?? ""
        var closed = ""
        if let origin, origin.finding.isOpen {
            // It's the new task's now: closed on the one it came from, so it neither holds that one's merge back nor
            // comes up in its re-audits.
            do {
                let ledger = try vault.dismissFinding(root: root, task: origin.slug, id: origin.finding.id, reason: "moved to task \(task.slug)", followUp: task.slug)
                mirror(ledger, on: origin.slug)
                closed = " \(origin.slug):\(origin.finding.id) is closed on \(origin.slug) as moved to it."
                if let why = backToReview(origin.slug, ledger) { closed += " No Important finding is open on \(origin.slug) now and \(why): it's back in review; merge(\(origin.slug)) when you're ready." }
            } catch {
                closed = " \(origin.slug):\(origin.finding.id) couldn't be closed on \(origin.slug) (\(error)): dismiss_finding it."
            }
        }
        return MCPToolResult(text: "Added task \(task.slug) (\(title)), review \(task.reviewLevel.rawValue).\(closed)\(recorded) " + startHint(task))
    }

    /// The review level passed as `review`; nil when none was passed. Anything but none or audit is refused.
    private func reviewArgument(_ arguments: [String: Any]) throws -> LeadTask.Review? {
        guard let given = arguments["review"], !((given as? String)?.isEmpty ?? false) else { return nil }
        guard let text = given as? String, let review = LeadTask.Review(text: text) else {
            throw Problem(text: "review is none or audit, not \(given). Nothing was changed.")
        }
        return review
    }

    /// The `auto_advance` passed to add_task or update_task; nil when none was.
    private func autoArgument(_ arguments: [String: Any]) throws -> Bool? {
        guard let given = arguments["auto_advance"], !(given is NSNull), !((given as? String)?.isEmpty ?? false) else { return nil }
        if let flag = given as? Bool { return flag }
        guard let text = given as? String, let flag = LeadWorkflow.flag(text) else {
            throw Problem(text: "auto_advance is true or false, not \(given). Nothing was changed.")
        }
        return flag
    }

    /// `after` as the board has it: each a task on it (by slug or id), never `slug` itself nor one that waits on
    /// `slug` already (a loop would never start); duplicates dropped. Empty clears it (nil).
    static func afterList(_ given: [String], on board: LeadBoard, for slug: String) throws -> [String]? {
        var list: [String] = []
        for name in given.map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            guard let task = board.task(name) else { throw BoardError(text: "after names \(name), which isn't a task on the board. Nothing was changed.") }
            guard task.slug != slug else { throw BoardError(text: "\(slug) can't come after itself. Nothing was changed.") }
            if !list.contains(task.slug) { list.append(task.slug) }
        }
        // A loop: one of them waits, through its own after, on this one.
        var seen: Set<String> = [], queue = list
        while let next = queue.popLast() {
            guard seen.insert(next).inserted else { continue }
            let waits = board.task(next)?.after ?? []
            if waits.contains(slug) { throw BoardError(text: "\(next) already comes after \(slug), so \(slug) can't come after it: neither would start. Nothing was changed.") }
            queue += waits
        }
        return list.isEmpty ? nil : list
    }

    /// What add_task's reply says about starting the task: by itself (auto_advance) or with start_worker.
    private func startHint(_ task: LeadTask) -> String {
        let after = (task.after ?? []).joined(separator: ", ")
        guard workflow.autoAdvance, task.autoAdvance != false else {
            return after.isEmpty ? "Start it with start_worker when it doesn't depend on unfinished work."
                : "Start it with start_worker once \(after) \((task.after ?? []).count == 1 ? "is" : "are") done."
        }
        return (after.isEmpty ? "auto_advance is on: it starts by itself, in board order, as soon as a worker slot and the Mac have room"
            : "auto_advance is on: it starts by itself once \(after) \((task.after ?? []).count == 1 ? "is" : "are") done and a worker slot and the Mac have room")
            + " (to hold it, update_task(\(task.slug), status: blocked), or auto_advance: false for this task)."
    }

    /// Records the task's review level in the vault, which merge goes by (the board's copy can't lower it). Empty
    /// when it was recorded; else what that means, for the lead.
    private func recordReview(_ review: LeadTask.Review, slug: String) -> String {
        do { try vault.setReview(review, root: root, task: slug) } catch {
            return review == .audit
                ? " Its review level couldn't be recorded in the vault (\(error)); the board's audit still holds its merge to a passing audit."
                : " Its review level couldn't be recorded in the vault (\(error)): if the vault had audit for \(slug), merge still asks for an audit."
        }
        return ""
    }

    /// A finding as the lead names it: <task>:<id> (also <task>/<id> or <task>#<id>), as the vault has it.
    private func finding(_ reference: String) throws -> (slug: String, finding: LeadFinding) {
        guard let cut = reference.lastIndex(where: { ":/#".contains($0) }) else {
            throw Problem(text: "Name the finding as <task>:<id> (e.g. add-b:F2), as status and board show it.")
        }
        let wanted = String(reference[..<cut]).trimmingCharacters(in: .whitespaces), id = String(reference[reference.index(after: cut)...])
        guard let slug = store.loadAll().task(wanted)?.slug else { throw Problem(text: "No task \(wanted) on the board.") }
        guard let finding = vault.audits(root: root, task: slug)?.finding(id) else { throw Problem(text: "\(slug) has no finding \(id).") }
        return (slug, finding)
    }

    static func findingTitle(_ finding: LeadFinding) -> String {
        "Fix \((finding.file as NSString).lastPathComponent):\(finding.line): \(clip(finding.evidence, 50))"
    }

    static func findingGoal(_ finding: LeadFinding) -> String {
        "What the \(finding.severity.rawValue) finding at \(finding.place) shows is no longer true: \(finding.evidence)"
    }

    static func findingCheck(_ finding: LeadFinding) -> String {
        "The finding at \(finding.place) no longer holds: what showed it (\(clip(finding.evidence, 160))) now shows it fixed, with a test that would have caught it"
    }

    static func findingContext(_ finding: LeadFinding, of slug: String) -> String {
        "From the audit of \(slug) (round \(finding.raised)): \(finding.label). \(finding.evidence)"
    }

    private func dismissFinding(_ arguments: [String: Any]) throws -> MCPToolResult {
        let slug = try taskSlug(arguments)
        var id = (arguments["id"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if let cut = id.lastIndex(where: { ":/#".contains($0) }) { id = String(id[id.index(after: cut)...]) }
        let reason = try text(arguments, "reason", missing: "Say why it's dismissed.")
        guard !id.isEmpty else { throw Problem(text: "Which finding? Pass its id (F2).") }
        let ledger: LeadAuditLedger?
        do { ledger = try vault.dismissFinding(root: root, task: slug, id: id, reason: reason) } catch { throw Problem(text: "\(error)") }
        mirror(ledger, on: slug)
        try? store.appendProgress("Dismissed \(slug):\(id): \(reason)")
        let left = ledger?.blocking ?? []
        let mergeable = backToReview(slug, ledger).map { " No Important finding is open now and \($0): \(slug) is back in review; merge(\(slug)) when you're ready." } ?? ""
        return MCPToolResult(text: "Dismissed \(slug):\(id).\(left.isEmpty ? "" : " Still open and holding the merge back: \(left.map(\.label).joined(separator: ", ")).")\(mergeable)")
    }

    /// A pass that only its open Important findings left failed goes back to review once the last one is closed,
    /// its setback gone: the verdict stands on the branch's head, so merge can go ahead. So does a complete audit whose
    /// tests passed once the lead has dismissed every Important finding that failed it (see `Verdict.dismissed`).
    /// Says why it went back (nil: it didn't).
    private func backToReview(_ slug: String, _ ledger: LeadAuditLedger?) -> String? {
        guard let ledger, ledger.blocking.isEmpty, let verdict = vault.verdict(root: root, task: slug),
              verdict.commit == ledger.commit, verdict.commit == branchHead(Worktrees.branch(slug)) else { return nil }
        let why: String
        if ledger.passed == true && verdict.passes {
            why = "its audit passed"
        } else if verdict.dismissed(in: ledger) != nil {
            why = "its audit was complete with its tests passing, with every Important finding that failed it dismissed"
        } else {
            return nil
        }
        let moved = (try? store.update { board -> Bool in
            guard let index = board.taskIndex(slug), board.tasks[index].status == .failed else { return false }
            board.tasks[index].status = .review
            board.tasks[index].setback = nil
            return true
        }) ?? false
        guard moved else { return nil }
        try? store.appendProgress("\(slug) back in review: no Important finding open, and \(why)")
        return why
    }

    /// Why dismissing findings doesn't let `verdict` merge, as the end of merge's refusal ("" for a passing one).
    static func notDismissable(_ verdict: LeadVault.Verdict) -> String {
        guard !verdict.passes else { return "" }
        if verdict.completion != .complete { return " (this one is \(verdict.completion.rawValue), which dismissing findings doesn't change)" }
        switch verdict.tests {
        case .failed?: return " (this one's tests failed, which dismissing findings doesn't change)"
        case .notRun?, nil: return " (its verifier didn't say its tests passed, so dismissing findings doesn't make it pass)"
        case .passed?: return " (or a complete one whose tests passed with every Important finding that failed it dismissed: this one has none dismissed since that audit)"
        }
    }

    /// Shows the vault's findings and rounds for `slug` on the board.
    private func mirror(_ ledger: LeadAuditLedger?, on slug: String) {
        try? store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].audits = ledger
        }
    }

    /// submit_audit's findings, as its schema tells the verifier.
    static let evidenceShape = "With done: one object per acceptance check of your contract, {check, how, result, screenshots}. check: "
        + "the check's number (1 for the first) or its text; how: the command you ran and what it printed, the test's name, or "
        + "what you looked at; result: what it showed (passed, the numbers, what you saw); screenshots: the paths of any "
        + "screenshots, optional. A task with no acceptance checks needs one entry, for its goal. Not needed with blocked."
    static let blindCheckShape = "With done: what your blind check (a fresh subagent given only the contract and the diff) found, "
        + "and for each item what you did: fixed (in which commit) or why not. \"Nothing blocking\" when it found nothing."

    static let findingsShape = "Each problem you found, one object each: {id, severity, file, line, evidence, failure_scenario, status, reason}. "
        + "severity: Important only for a concrete problem that blocks the merge (an acceptance check that fails, a bug, a weakened test), "
        + "and it needs failure_scenario: these inputs or this state give this wrong result or crash; an Important finding without one is "
        + "recorded as a Nit. Nit: everything else (worth fixing, never blocks). Pre-existing: already wrong before this branch; never fails "
        + "the task. file and line: where it is (path from the repository's root). "
        + "evidence: what you ran and what it gave, or what the code at file:line does. status: open; in a re-audit, each open finding you were given "
        + "by its id: fixed, open (still), or dismissed with a reason. id: leave it out for a new finding. Empty or left out: you found nothing."

    static let updateKeys: Set<String> = ["task", "title", "goal", "acceptance", "boundaries", "context", "append_context", "status", "reason", "into", "review", "reroll",
                                          "after", "auto_advance", "budget_min"]

    private func updateTask(_ arguments: [String: Any]) throws -> MCPToolResult {
        let slug = try taskSlug(arguments)
        // Nothing passed is dropped unsaid: a name it doesn't take, or a state it doesn't set, is refused whole.
        let unknown = Set(arguments.keys).subtracting(Self.updateKeys)
        guard unknown.isEmpty else {
            throw Problem(text: "update_task doesn't take \(unknown.sorted().joined(separator: ", ")); it takes \(Self.updateKeys.sorted().joined(separator: ", ")). Nothing was changed.")
        }
        var status: LeadTask.Status?
        let reason = (arguments["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reroll = arguments["reroll"] as? Bool ?? false
        if reroll {
            let others = ["status", "reason", "into"].filter { arguments[$0] != nil }
            guard others.isEmpty else {
                throw Problem(text: "reroll doesn't go with \(others.joined(separator: ", ")): it puts the task back to work itself. Nothing was changed.")
            }
            try checkRerollable(slug)
        }
        if let given = arguments["status"] as? String, !given.isEmpty {
            if given.lowercased() == Self.removedState { return try removeTask(slug, arguments, reason: reason) }
            guard let wanted = LeadTask.Status(rawValue: given.lowercased()), Self.settableStates.contains(wanted) else {
                throw Problem(text: "update_task sets the state to \((Self.settableStates.map(\.rawValue) + [Self.removedState]).joined(separator: ", ")), not \(given). Nothing was changed.")
            }
            status = wanted
        }
        if status == .kept, reason.isEmpty {
            throw Problem(text: "Say what keeps it from merging (reason): a decision, the user's word. merge names it when it refuses. Nothing was changed.")
        }
        if status == .abandoned, reason.isEmpty {
            throw Problem(text: "Say why nothing will carry its work (reason): dropped, no longer wanted, the user's word. Nothing was changed.")
        }
        if status == .abandoned { try checkSettleable(slug, "abandon") }
        let into = (arguments["into"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if status == .folded {
            guard !into.isEmpty else {
                throw Problem(text: "Say which task carries its work (into: that task's slug). Nothing was changed.")
            }
            try checkSettleable(slug, "fold")
        } else if !into.isEmpty {
            throw Problem(text: "into goes with status folded (the task that carries this one's work). Nothing was changed.")
        }
        let review = try reviewArgument(arguments)
        let auto = try autoArgument(arguments)
        let budget = try budgetArgument(arguments)
        let defaultBudget = workflow.taskBudgetMinutes
        var budgetCleared = false
        let appended = (arguments["append_context"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note = appended.isEmpty ? nil : leadNote(.context, appended, on: slug)
        // Folded or abandoned, it ends: its receipt's tokens are read before the board's lock is taken.
        let ending: LeadReceipt.Ending? = status == .folded ? .folded : status == .abandoned ? .abandoned : nil
        let usage = ending == nil ? nil : store.load().task(slug).map(receiptUsage)
        var changed: [String] = []
        try boardChange { board in
            // A task in the board's archive comes back to be changed (reopened, renamed).
            guard let index = store.restore(slug, into: &board) else { return }
            if let status, board.tasks[index].status == .reverted {
                throw BoardError(text: "\(slug) was merged and reverted\(board.tasks[index].merged?.revertedBy.map { " (by \($0.prefix(8)))" } ?? ""); it stays reverted, not \(status.rawValue). To do its work again, add_task a new task. Nothing was changed.")
            }
            if let status, board.tasks[index].status == .done {
                throw BoardError(text: "\(slug) is merged already\(board.tasks[index].merged.map { " (at \($0.commit.prefix(8)))" } ?? ""); it stays done, not \(status.rawValue). Nothing was changed.")
            }
            if !reason.isEmpty, ![.kept, .abandoned].contains(status ?? board.tasks[index].status) {
                throw BoardError(text: "reason goes with status kept (what holds the task back) or abandoned (why nothing will carry it); \(slug) is neither. Nothing was changed.")
            }
            var target: LeadTask?
            if status == .folded {
                guard let found = board.task(into) ?? store.withArchive(board).task(into) else {
                    throw BoardError(text: "No task \(into) on the board to fold \(slug) into. Nothing was changed.")
                }
                guard found.id != board.tasks[index].id else {
                    throw BoardError(text: "\(slug) can't be folded into itself: name the task that carries its work. Nothing was changed.")
                }
                // One step: a task folded into a folded one would point at a task that carries nothing.
                if found.status == .folded {
                    throw BoardError(text: "\(found.slug) is itself folded into \(found.foldedInto ?? "another task"); fold \(slug) into that one. Nothing was changed.")
                }
                if found.isAbandoned {
                    throw BoardError(text: "\(found.slug) is abandoned: it carries nothing. Fold \(slug) into the task that carries its work, or abandon it too. Nothing was changed.")
                }
                target = found
            }
            if let title = arguments["title"] as? String { board.tasks[index].title = title; changed.append("title") }
            if let goal = arguments["goal"] as? String { board.tasks[index].contract.goal = goal; changed.append("goal") }
            if arguments["acceptance"] != nil { board.tasks[index].contract.acceptance = strings(arguments["acceptance"]); changed.append("acceptance") }
            if arguments["boundaries"] != nil { board.tasks[index].contract.boundaries = strings(arguments["boundaries"]); changed.append("boundaries") }
            if let context = arguments["context"] as? String { board.tasks[index].contract.context = context; changed.append("context (replaced)") }
            if let review { board.tasks[index].review = review; changed.append("review \(review.rawValue)") }
            if arguments["after"] != nil {
                board.tasks[index].after = try Self.afterList(strings(arguments["after"]), on: store.withArchive(board), for: slug)
                changed.append(board.tasks[index].after.map { "after \($0.joined(separator: ", "))" } ?? "after cleared")
            }
            if let auto {
                board.tasks[index].autoAdvance = auto ? nil : false
                changed.append(auto ? "auto_advance on for it" : "auto_advance off for it (nothing moves on it by itself)")
            }
            if let budget {
                let before = board.tasks[index].budgetMin ?? defaultBudget
                board.tasks[index].budgetMin = budget
                // A new budget is a new stop: the over-budget state goes, and the worker is told again at the new one.
                if budget != before, let over = board.tasks[index].overBudget {
                    board.tasks[index].overBudget = nil
                    budgetCleared = true
                    changed.append("budget_min \(budget) (it was over its \(over.minutes) min budget, \(LeadBudget.text(board.tasks[index].worked ?? 0)) worked: "
                                   + (budget == 0 ? "no budget now" : "the next stop comes at \(budget) min") + ")")
                } else {
                    changed.append(budget == 0 ? "budget_min 0 (no budget)" : "budget_min \(budget)")
                }
            }
            if !appended.isEmpty {
                let context = board.tasks[index].contract.context.trimmingCharacters(in: .whitespacesAndNewlines)
                board.tasks[index].contract.context = context.isEmpty ? appended : context + "\n\n" + appended
                if let note { board.tasks[index].keep(note) }
                changed.append("context (added to)")
            }
            if let status {
                // Re-planned: its next worker's time counts from zero.
                if status == .planned, board.tasks[index].status != .planned {
                    board.tasks[index].worked = nil
                    board.tasks[index].workedAt = nil
                    board.tasks[index].overBudget = nil
                }
                let before = board.tasks[index].status
                board.tasks[index].status = status
                board.tasks[index].keptBecause = status == .kept ? reason : nil
                board.tasks[index].abandonedBecause = status == .abandoned ? reason : nil
                board.tasks[index].foldedInto = target?.slug
                // Ended now (not when it was already folded or abandoned): its receipt, counted again over every round
                // of work if it ended before and was reopened. Open again: none (it's written when it ends).
                if let ending, let usage, board.tasks[index].status != before {
                    board.tasks[index].receipt = LeadReceipt(board.tasks[index], ending: ending, questions: board.questions, usage: usage)
                } else if ending == nil {
                    board.tasks[index].receipt = nil
                }
                changed.append("state \(status.rawValue)" + (target.map { " into \($0.slug)" } ?? ""))
            } else if !reason.isEmpty, board.tasks[index].status == .abandoned {
                board.tasks[index].abandonedBecause = reason
                changed.append("why it's abandoned")
            } else if !reason.isEmpty {
                board.tasks[index].keptBecause = reason
                changed.append("why it's kept")
            }
        }
        if status == .kept { try? store.appendProgress("Kept \(slug) unmerged: \(reason)") }
        if status == .abandoned { try? store.appendProgress("Abandoned \(slug): \(reason)") }
        if status == .folded, let target = store.load().task(slug)?.foldedInto {
            try? store.appendProgress("Folded \(slug) into \(target): that task carries its work")
        }
        // Planned again: re-planned, so its failed audit rounds count from here (its findings stay).
        if status == .planned, let ledger = vault.audits(root: root, task: slug), ledger.failedRounds > 0 {
            if let replanned = try? vault.replan(root: root, task: slug) { mirror(replanned, on: slug) }
        }
        var recorded = ""
        if let review {
            try? store.appendProgress("Review of \(slug): \(review.rawValue)")
            recorded = recordReview(review, slug: slug)
            if review == .none, vault.current(.verifier, root: root, task: slug) != nil {
                recorded += " An audit was started on \(slug) already: its verdict decides its merge."
            }
        }
        if reroll {
            return MCPToolResult(text: (changed.isEmpty ? "" : "Updated \(slug): \(changed.joined(separator: ", ")).\(recorded) ") + (try rerollTask(slug)))
        }
        let goOn = budgetCleared && status == nil ? " If its worker stopped for the budget, message(\(slug), …) to tell it to go on." : ""
        return MCPToolResult(text: changed.isEmpty ? "Nothing to change on \(slug)." : "Updated \(slug): \(changed.joined(separator: ", ")).\(recorded)\(goOn)")
    }

    /// A task may be re-rolled while it's still to land: not merged, kept, folded or abandoned, and no merge of it under way.
    private func checkRerollable(_ slug: String) throws {
        guard let task = store.load().task(slug) else { throw Problem(text: "No task \(slug).") }
        if [.done, .kept, .folded, .abandoned, .reverted].contains(task.status) {
            throw Problem(text: "\(slug) is \(Self.shownState(task)): there's nothing to re-roll\(task.status == .kept ? " (update_task(\(slug), status: planned) first, if it's wanted after all)" : ""). Nothing was changed.")
        }
        guard let lock = FileLock.attempt((store.folder as NSString).appendingPathComponent("run/merge-\(slug).lock")) else {
            throw Problem(text: "A merge of \(slug) is under way: re-roll it once its result is back. Nothing was changed.")
        }
        lock.release()
    }

    /// update_task(reroll: true): the task starts over from the base with what its audit rounds learned, instead of a
    /// third round of patching. Its sessions end; its branch is kept as archive/<slug>-<n> (and uncommitted changes
    /// to tracked files as a commit on archive/<slug>-<n>-uncommitted); its worktree and agent/<slug> go; its context
    /// gets the summary of the findings and the worker's answers (`LeadAuditLedger.rerollSummary`); its rounds count
    /// from zero, its findings stay for the fresh branch's first audit to check again; and a fresh worker starts.
    private func rerollTask(_ slug: String) throws -> String {
        guard let task = store.load().task(slug) else { throw Problem(text: "No task \(slug).") }
        let refused = "\(slug) wasn't re-rolled"
        let folder = (Worktrees.path(root: root, slug: slug) as NSString).standardizingPath
        let ours = Set([task.worker, task.verifier].compactMap { $0 } + (task.panel?.sessions ?? []))
        let sessions = try hostSessions(refused + "; nothing was changed").filter { $0.live && (ours.contains($0.id) || Self.isTeamSession($0, in: folder)) }
        let endings = try endItself(try end(sessions, refused: refused), refused: refused)
        let failed = endings.filter { $0.failure != nil }
        guard failed.isEmpty else {
            throw Problem(text: "\(refused): \(failed.map(\.said).joined(separator: "; ")). Its branch and worktree stay while a session may still write there. If the host refuses, tell the user (they can end it in VibeSwitcher), then re-roll again.")
        }
        let number = (task.rerolls?.count ?? 0) + 1
        let head = branchHead(Worktrees.branch(slug))
        var archive: String?
        var kept: [String] = []
        if let head {
            var suffix = number
            while branchHead("archive/\(slug)-\(suffix)") != nil { suffix += 1 }
            let name = "archive/\(slug)-\(suffix)"
            let made = Git.run(["branch", name, head], in: root)
            guard made.ok else {
                throw Problem(text: "\(refused): its branch couldn't be kept as \(name) (\(made.error)), so nothing of it was removed. \(endings.isEmpty ? "" : "Its sessions were ended: \(endings.map(\.said).joined(separator: ", ")).")")
            }
            archive = name
            kept.append("its branch is kept as \(name) (at \(head.prefix(8)))")
            // `git stash create` makes a commit of the uncommitted changes to tracked files, touching no file and no ref.
            if Worktrees.isWorktree(root: root, slug: slug) {
                let stash = Git.run(["stash", "create", "uncommitted when \(slug) was re-rolled"], in: Worktrees.path(root: root, slug: slug))
                if stash.ok, !stash.output.isEmpty, Git.run(["branch", name + "-uncommitted", stash.output], in: root).ok {
                    kept.append("its uncommitted changes as \(name)-uncommitted")
                }
            }
        }
        let untracked = Worktrees.isWorktree(root: root, slug: slug) ? Worktrees.leftovers(root: root, slug: slug) : []
        _ = removeFolder((Worktrees.path(root: root, slug: slug) as NSString).appendingPathComponent(".build"))
        _ = removeFolder((store.folder as NSString).appendingPathComponent("audit/\(slug)"))
        if FileManager.default.fileExists(atPath: Worktrees.path(root: root, slug: slug)) || head != nil {
            do { try Worktrees.remove(root: root, slug: slug, force: true) } catch {
                throw Problem(text: "\(refused) all the way: \(kept.joined(separator: ", ")), but its worktree or \(Worktrees.branch(slug)) couldn't be removed (\(error)). Tell the user; start_worker would continue on the old branch.")
            }
        }
        let ledger = vault.audits(root: root, task: slug)
        let replanned = ledger == nil ? nil : (try? vault.replan(root: root, task: slug)) ?? nil
        try? vault.clearVerdict(root: root, task: slug)
        let summary = (ledger ?? LeadAuditLedger()).rerollSummary(answers: task.answers ?? [], archive: archive ?? "(none: nothing was committed)",
                                                                  base: workflow.base, number: number)
        let note = leadNote(.context, summary, on: slug)
        let record = LeadReroll(archive: archive ?? "", commit: head, round: ledger?.rounds ?? 0)
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            let context = board.tasks[index].contract.context.trimmingCharacters(in: .whitespacesAndNewlines)
            board.tasks[index].contract.context = context.isEmpty ? summary : context + "\n\n" + summary
            board.tasks[index].keep(note)
            board.tasks[index].rerolls = (board.tasks[index].rerolls ?? []) + [record]
            board.tasks[index].answers = nil
            board.tasks[index].attempts = (board.tasks[index].attempts ?? 1) + 1
            board.tasks[index].status = .planned
            board.tasks[index].stopped = task.worker
            board.tasks[index].verifier = nil
            board.tasks[index].panel = nil
            board.tasks[index].worktree = nil
            board.tasks[index].branch = nil
            board.tasks[index].evidence = nil
            board.tasks[index].outdatedEvidence = nil
            board.tasks[index].report = nil
            board.tasks[index].auditNeeded = nil
            board.tasks[index].blocker = nil
            board.tasks[index].worked = nil
            board.tasks[index].workedAt = nil
            board.tasks[index].overBudget = nil
            if let replanned { board.tasks[index].audits = replanned }
        }
        try? store.appendProgress("Re-rolled \(slug) after \(ledger?.rounds ?? 0) audit round\((ledger?.rounds ?? 0) == 1 ? "" : "s")" + (archive.map { ": its branch is kept as \($0)" } ?? ""))
        let ended = endings.isEmpty ? "" : " Ended " + endings.map(\.said).joined(separator: ", ") + "."
        let dropped = untracked.isEmpty ? "" : " Untracked files left in its worktree went with it: " + untracked.prefix(10).map(\.path).joined(separator: ", ") + (untracked.count > 10 ? ", …" : "") + "."
        let important = ledger?.findings.filter { $0.severity == .important }.count ?? 0
        var text = "Re-rolled \(slug):\(ended) " + (kept.isEmpty ? "it had no branch to keep" : kept.joined(separator: ", ")) + ".\(dropped) "
            + "Its context now ends with a summary of what the rounds learned (\(important) Important finding\(important == 1 ? "" : "s") with the worker's answers); "
            + "its audit rounds count from zero, and the fresh branch's first audit checks each open finding again. "
        do {
            text += try startWorker(slug).text
        } catch let problem as Problem {
            text += "The fresh worker wasn't started: \(problem.text) It's planned; start_worker(\(slug)) then."
        }
        return text
    }

    /// A task may be folded or abandoned (`verb`) once nothing works on it: refused while its worker runs or a merge
    /// of it is under way.
    private func checkSettleable(_ slug: String, _ verb: String) throws {
        guard let task = store.load().task(slug) else { return }
        let sessions = try hostSessions("whether \(slug)'s worker still runs isn't known; nothing was changed")
        if let worker = task.worker, sessions.contains(where: { $0.id == worker && $0.live }) {
            throw Problem(text: "\(slug)'s worker is still running: stop_worker first, then \(verb) it. Nothing was changed.")
        }
        guard let lock = FileLock.attempt((store.folder as NSString).appendingPathComponent("run/merge-\(slug).lock")) else {
            throw Problem(text: "A merge of \(slug) is under way: \(verb) it once its result is back. Nothing was changed.")
        }
        lock.release()
    }

    /// The refusal for a folded or abandoned task: nothing more happens on it (`what`: what was refused).
    private static func settledRefusal(_ task: LeadTask, _ what: String) -> Problem {
        let back = "update_task(\(task.slug), status: planned) first"
        if task.status == .reverted {
            return Problem(text: "\(what): \(task.slug) was merged and then reverted" + (task.merged?.revertReason.map { " (\($0))" } ?? "")
                           + ". Its work stays undone; to do it again, plan a new task (add_task) that does it without what broke.")
        }
        if task.status == .abandoned {
            return Problem(text: "\(what): \(task.slug) is abandoned (\(task.abandonedBecause ?? "no reason recorded")). If it's wanted after all, \(back).")
        }
        let target = task.foldedInto ?? "another task"
        return Problem(text: "\(what): \(task.slug) is folded into \(target), which carries its work. Work on \(target); if \(task.slug) has to go on by itself after all, \(back).")
    }

    /// update_task(status: removed): a record made by mistake that never ran leaves the board for its `removed` list
    /// (kept for the record, shown and counted nowhere). Anything that ran is folded or abandoned instead.
    private func removeTask(_ slug: String, _ arguments: [String: Any], reason: String) throws -> MCPToolResult {
        let others = Set(arguments.keys).subtracting(["task", "status", "reason"])
        guard others.isEmpty else {
            throw Problem(text: "status removed takes task and reason only, not \(others.sorted().joined(separator: ", ")). Nothing was changed.")
        }
        let instead = "remove is only for a record made by mistake that never ran; fold it (status: folded, into: the task that carries it) or abandon it (status: abandoned, reason: why) instead. Nothing was changed."
        // What git has, beside what the board says: a branch or worktree left from a run the board lost.
        let branch = branchHead(Worktrees.branch(slug)) != nil || Worktrees.isWorktree(root: root, slug: slug)
        try boardChange { board in
            guard let index = board.taskIndex(slug) else { throw BoardError(text: "No task \(slug) on the board. Nothing was changed.") }
            let task = board.tasks[index]
            if let ran = task.ranBecause ?? (branch ? "it has a branch (\(Worktrees.branch(task.slug)))" : nil) {
                throw BoardError(text: "\(task.slug) can't be removed: \(ran); " + instead)
            }
            let folded = board.tasks.filter { $0.foldedInto == task.slug }.map(\.slug)
            if !folded.isEmpty {
                throw BoardError(text: "\(task.slug) can't be removed: \(folded.joined(separator: ", ")) \(folded.count == 1 ? "is" : "are") folded into it. Fold \(folded.count == 1 ? "it" : "them") into the task that carries the work first. Nothing was changed.")
            }
            var removed = board.tasks.remove(at: index)
            removed.removedAt = Date().timeIntervalSince1970
            removed.removedBecause = reason.isEmpty ? nil : reason
            board.removed = (board.removed ?? []) + [removed]
        }
        try? store.appendProgress("Removed \(slug) from the board (a record that never ran)" + (reason.isEmpty ? "" : ": \(reason)"))
        return MCPToolResult(text: "Removed \(slug) from the board: it never ran. Its record is kept in board.json's removed list, shown and counted nowhere.")
    }

    /// One start at a time, in this server and any other: each counts the workers running and starts its own before
    /// the next counts, so calls at once can't go past max_workers (or start two workers on one task).
    /// `when` (an automatic start, see `LeadAdvance`): whether the task is still due, asked in that one-at-a-time lock.
    private func startWorker(_ slug: String, recover: Bool = false, when: ((LeadTask) -> Bool)? = nil) throws -> MCPToolResult {
        try exclusively("start-worker") { try startWorkerAlone(slug, recover: recover, when: when) }
    }

    /// Runs `body` holding the lock `run/<name>.lock` in the project's folder, waiting for it while another thread or
    /// process holds it.
    private func exclusively<T>(_ name: String, _ body: () throws -> T) throws -> T {
        let path = (store.folder as NSString).appendingPathComponent("run/\(name).lock")
        try? VibePaths.ensurePrivate(URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true))
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

    private func startWorkerAlone(_ slug: String, recover: Bool, when: ((LeadTask) -> Bool)?) throws -> MCPToolResult {
        let board = try store.read()
        guard let task = board.task(slug) else { throw Problem(text: "No task \(slug).") }
        // Held, or no longer due, since the automatic step looked: not started, and nothing said.
        if let when, !when(task) { throw LeadAdvance.NotDue() }
        if Self.settledStates.contains(task.status) { throw Self.settledRefusal(task, "No worker started") }
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
        try checkBattery(not: "Not started")
        let running = board.tasks.filter { $0.status == .running && $0.id != task.id }.count
        let limit = workflow.maxWorkers
        guard running < limit else {
            throw Problem(text: "\(running) workers already run (max_workers is \(limit) in workflow.md). Wait for one to finish; you'll get a message.")
        }
        // The Mac is every project's: its load and their teams count, not only this one's. A session already in this
        // task's worktree (an ended worker's earlier verifier) is the one this worker replaces.
        let mac = try macLoad(sessions, load: runtime.steadyLoad(), except: Worktrees.path(root: root, slug: slug),
                              refused: "whether the Mac has room for \(slug)'s worker isn't known; no worker was started")
        if let refusal = macRefusal(mac, not: "Not started", what: "start_worker(\(slug))", need: 1) { throw Problem(text: refusal) }
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
        // Named before its grant goes to the new one.
        let noTools = noToolsBefore(task, .worker, sessions: sessions)
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
            // Working again: a receipt from an earlier ending goes; the next ending counts every round.
            board.tasks[index].receipt = nil
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
        return MCPToolResult(text: noTools + offSaid + recovered + locked + "Worker started on \(slug) in \(worktree) (branch agent/\(slug)). You'll get a message when it reports, needs input or stalls.")
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

    /// audit's verifier takes the place of the task's own worker: `MacLoad.count` leaves the task's worktree out. Where
    /// the Mac would be past mac_max_sessions with that worker still there, a worker idle since its done report on
    /// `head` is ended as stop_worker ends one, so the place is real (2026-10-24: finished workers waiting for their
    /// audits held 4 to 5 of the Mac's 10 slots, verifiers were refused for mac_max_sessions, and the lead ended them by
    /// hand). One mid-turn, waiting on a prompt, or whose last report wasn't done on `head` is never ended. What audit's
    /// reply says of it; "" when nothing was ended.
    private func makeRoom(_ task: LeadTask, head: String, need: Int, limits: MacLimits) -> String {
        let refused = "\(task.slug)'s worker wasn't ended to make room"
        guard let worker = task.worker, worker != task.stopped, let sessions = try? hostSessions(refused),
              let info = sessions.first(where: { $0.id == worker && $0.live }) else { return "" }
        guard let others = try? macLoad(sessions, load: nil, except: Worktrees.path(root: root, slug: task.slug)),
              others.sessions + need + 1 > limits.maxSessions, info.waiting == nil, info.status == LeadActivity.idle(background: nil).text,
              (try? vault.unaudited(root: root, task: task.slug))?.reported == head else { return "" }
        guard let ending = try? end([info], refused: refused).first else { return "" }
        if ending.failure != nil {
            return "\(task.slug)'s worker, idle since its done report, wasn't ended to make room for the verifier (\(ending.said)): the verifier starts beside it. "
        }
        try? store.update { board in
            guard let index = board.taskIndex(task.slug) else { return }
            board.tasks[index].stopped = worker
        }
        try? store.appendProgress("Ended \(task.slug)'s worker (idle since its done report on \(head.prefix(8))) to make room on the Mac for its audit")
        return "Ended \(task.slug)'s worker, idle since its done report on \(head.prefix(8)), to make room: beside it the audit would take the Mac's team sessions past "
            + "mac_max_sessions (\(others.sessions + 1 + need) with it, \(limits.maxSessions) at most), and the audit takes its slot (\(ending.said)). "
            + "Its worktree and commits stay; start_worker continues there if there's rework. "
    }

    private func message(_ slug: String, _ arguments: [String: Any]) throws -> MCPToolResult {
        try sent(slug, arguments).result
    }

    /// message(), with what became of the message (auto_advance acts on it, see `LeadAdvance.sendToWorker`).
    private func sent(_ slug: String, _ arguments: [String: Any]) throws -> (delivered: LeadDelivery.Delivered, result: MCPToolResult) {
        let text = try self.text(arguments, "text", missing: "Nothing to send.")
        guard let worker = store.load().task(slug)?.worker else { throw Problem(text: "\(slug) has no worker.") }
        let clear = arguments["clear_draft"] as? Bool ?? false
        let delivered = try runtime.steer(.session(worker), from: .lead("lead of \(project)"), text: text, clearDraft: clear)
        // Kept for the verifier: what the lead accepts here (an edit outside the contract's files) is in scope.
        let note = leadNote(.message, text, on: slug)
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].keep(note)
            guard board.tasks[index].worker == worker else { return }
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
        let result: MCPToolResult
        switch delivered {
        case .steered: result = MCPToolResult(text: "Sent to \(slug)'s worker while it works; it gets it at its next step.")
        case .typed: result = MCPToolResult(text: "Typed into \(slug)'s worker as its next prompt (it was between turns\(clear ? "; a leftover draft was cleared first" : "")).")
        case .awaitingAnswer(let asked):
            result = MCPToolResult(text: "\(slug)'s worker is stopped on a prompt\(asked.map { " (\($0))" } ?? ""). The message is in its inbox and goes in at its next step, once that's answered: answer it yourself if it's yours to, or ask the user.")
        case .behindDraft(let draft):
            result = MCPToolResult(text: "\(slug)'s worker is between turns, but its input box holds a draft: “\(Self.clip(draft))”. The message waits in its inbox (it goes in with the next prompt, or once the box is empty). To clear the draft and send now, message again with clear_draft: true.")
        case .draftStayed(let before, let after):
            // clear_draft was on already: asking for it again would do the same.
            let saw = after.map { $0.isEmpty ? "then read empty, but typing didn't go out" : "still showed “\(Self.clip($0))”" }
                ?? "couldn't be cleared (the ^C didn't go out, or its screen couldn't be read)"
            result = MCPToolResult(text: "\(slug)'s worker is between turns with “\(Self.clip(before))” in its input box. clear_draft sent one ^C, and the box \(saw). The message waits in its inbox and goes in with its next prompt or once the box reads empty. Don't send it again; read_session to see where it is, or tell the user what's in its box.")
        case .notSubmitted(let shown):
            result = MCPToolResult(text: "Typed into \(slug)'s worker (it was between turns\(clear ? "; a leftover draft was cleared first" : "")), but it wasn't submitted: "
                                 + "its input box still shows “\(Self.clip(shown))” and no turn started, one more Enter too. It's in its box, not its inbox. "
                                 + "message again with clear_draft: true to clear it and type it once more; if that isn't submitted either, stop_worker and "
                                 + "start_worker (its worktree and commits stay), or tell the user what's in its box.")
        case .queued:
            result = MCPToolResult(text: "\(slug)'s worker is between turns, but its screen couldn't be read, so the message waits in its inbox; it goes in with its next prompt, or as soon as the box reads empty. read_session to see where it is.")
        }
        return (delivered, result)
    }

    private func readSession(_ slug: String, who: String) throws -> MCPToolResult {
        // Several finders: the first that ended without submitting, else the first still at work.
        let sessions = (try? listed()) ?? []
        let live = Dictionary(sessions.map { ($0.id, $0.live) }, uniquingKeysWith: { a, _ in a })
        guard let task = store.load().task(slug), let session = who == "verifier" ? task.awaitedVerifier(ended: { live[$0] != true }) : task.worker else {
            throw Problem(text: "\(slug) has no \(who).")
        }
        // While it waits on a prompt: that prompt in full, after the conversation.
        let waiting = sessions.first { $0.id == session && $0.live }?.waiting
        let found: String?
        do { found = try runtime.transcript(of: session) } catch {
            throw Problem(text: "The session host can't be read (\(error)), so \(slug)'s \(who) can't be found. Try again in a moment.")
        }
        guard let path = found, let (url, format) = TranscriptReader.checkedURL(path, home: VibePaths.home),
              let data = try? Data(contentsOf: url) else {
            return MCPToolResult(text: "No conversation yet for \(slug)'s \(who)." + (waiting.map { "\n\n" + Self.waitingSection($0) } ?? ""))
        }
        var log = ChatLog()
        let tail = data.count > 2_000_000 ? data.suffix(2_000_000) : data
        log.append(ChatReader.read(Data(tail), format: format).events)
        return MCPToolResult(text: SessionDigest.text(log, limit: 12_000) + (waiting.map { "\n\n" + Self.waitingSection($0) } ?? ""))
    }

    /// The tokens `task`'s own workers and verifiers spent, from their transcripts, for its receipt (see `LeadReceipts`).
    func receiptUsage(_ task: LeadTask) -> LeadReceipts.Usage {
        LeadReceipts.usage(root: root, slug: task.slug, since: task.createdAt, home: claudeHome)
    }

    /// read_session's last section: "Waiting on: since 09:52 (6 min), the prompt it shows:" and that prompt in full.
    static func waitingSection(_ prompt: PendingPrompt, now: Date = Date()) -> String {
        "Waiting on:" + (prompt.waited(now: now).map { " \($0)," } ?? "") + " the prompt it shows:\n" + prompt.quoted
    }

    /// Starts a worker or a verifier with a new grant (it replaces the role's earlier one), bound to its session as soon
    /// as that's started, before its trust question is answered (with `trust`): Claude Code can start the session's tool
    /// server at once (2.1.311 asks no trust question in a worktree), and one that asks before the bind waits for its
    /// role. Then, with `toolsWait`, waits for its tools to connect: a session that never gets them is ended and the call
    /// fails, rather than leave a worker that can't report. Its launch files go in the vault's folder.
    private func launch(_ role: LeadLaunch.Role, task slug: String, name: String, in folder: String, label: String, trust: Bool,
                        prompt: String, start: String, model: String? = nil, branch: String? = nil, auditing: String? = nil,
                        finder: LeadVault.Finder? = nil) throws -> String {
        // Before a grant or a session: one started without its agent's CLI (or git) would only end, or wait out
        // `toolsWait` for tools that never connect, and say nothing of why.
        let command = runtime.claudeCommand(root: root)
        if let missing = runtime.preflight(command: command) {
            throw Problem(text: "Not started: \(missing.description) Tell the user: VibeSwitcher only checks for it and never installs anything.")
        }
        let grant: String
        do { grant = try vault.issue(role: role, root: root, task: slug, auditing: auditing, finder: finder) } catch { throw Problem(text: "\(error)") }
        do {
            let launch = try LeadLaunch.prepare(role: role, root: root, task: slug, base: command, prompt: prompt,
                                                start: start, server: runtime.server, name: name, model: model, branch: branch,
                                                records: workflow.recordsDir, folder: vault.runFolder(root: root, name: name),
                                                cwd: folder, temporary: sessionTempRoot)
            // The project's heavy_slots for its sessions' vs-heavy too.
            var environment = launch.environment
            if let slots = workflow.heavySlots { environment[TestLock.slotsVariable] = String(slots) }
            // And its test_timeout_min, when it sets one of its own, as vs-heavy's: no run holds a slot past it.
            if workflow.testTimeoutMinutes != LeadWorkflow().testTimeoutMinutes {
                environment[TestLock.timeoutVariable] = "\(Int(workflow.testTimeout.rounded(.up)))s"
            }
            let session = try runtime.spawn(cwd: folder, command: launch.command, env: environment, label: label, agent: "claude")
            do { try vault.bind(grant, root: root, session: session) } catch {
                // A session without its role would run with no tools: it goes.
                try? runtime.kill(session)
                runtime.forget(session)
                throw error
            }
            // A worktree is a new folder to Claude: its trust question is answered for that folder (the user started the
            // lead in this repository), unless the lead says not to (a branch that brings its own settings).
            guard trust else { return session }
            runtime.answerTrust(session: session, folder: folder)
            if !toolsConnected(session, role: role) {
                try? runtime.kill(session)
                let who = role == .worker ? "\(slug)'s worker" : "\(slug)'s \(finder == nil ? "verifier" : "finder")"
                throw Problem(text: "\(who) was ended: its vibeswitcher tools didn't connect within \(Int(toolsWait)) s of its start (its tool server "
                              + "never asked the session host which role its session holds), so it couldn't have reported, and its grant was withdrawn. "
                              + "Try again once; if it happens again, tell the user: Claude Code's MCP log for \(folder) says why "
                              + "(~/Library/Caches/claude-cli-nodejs/, mcp-logs-vibeswitcher).")
            }
            return session
        } catch {
            try? vault.revoke(grant, root: root)
            throw error
        }
    }

    /// Whether the session's tool server asked the session host who it is within `toolsWait` (see `launch`). True when
    /// that isn't waited for (0), or can't be told: a host that doesn't keep the time (an older one, no `boundAt`) or
    /// whose roster can't be read, or a role that went to another session meanwhile.
    private func toolsConnected(_ session: String, role: LeadLaunch.Role) -> Bool {
        guard toolsWait > 0 else { return true }
        let deadline = Date().addingTimeInterval(toolsWait)
        while true {
            guard let roster = try? vault.roster(root: root),
                  let entry = roster.first(where: { $0.session == session && $0.role == role && $0.holds }),
                  entry.boundAt != nil else { return true }
            if entry.toolsAt != nil { return true }
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: toolsPoll)
        }
    }

    private func audit(_ slug: String, restart: Bool = false) throws -> MCPToolResult {
        if let task = store.load().task(slug), Self.settledStates.contains(task.status) { throw Self.settledRefusal(task, "Not audited") }
        // A verifier already at work on the branch's head is left to it: another would end it and throw its work away
        // (2026-10-27: audit(land-pr-1-host) ended the one auto_advance had started on that very head).
        if !restart, let running = try runningAudit(slug) { return MCPToolResult(text: running) }
        try checkBattery(not: "Not audited, no verifier started")
        // A worktree that left its branch goes back on it first (see putBackForAudit).
        let putBack = try store.load().task(slug).map { try putBackForAudit(slug, $0) } ?? ""
        // The task's own worktree (not whatever folder the board names) on the commit the branch is at now: that
        // commit is what this verifier's verdict covers.
        guard let task = store.load().task(slug), Worktrees.isWorktree(root: root, slug: slug), let head = branchHead(Worktrees.branch(slug)) else {
            throw Problem(text: "\(slug) has no worktree to check.")
        }
        // A passing verdict on this very commit with nothing Important open: another round would check the same code
        // again, for Nits at most (the working policy: no audit rounds without a concrete open concern; 2026-10-21, text
        // selection took four rounds and the picker card four tasks).
        if let verdict = vault.verdict(root: root, task: slug), verdict.passes, verdict.commit == head,
           vault.audits(root: root, task: slug)?.blocking.isEmpty ?? true {
            throw Problem(text: "Not audited: \(slug)'s audit at \(head.prefix(8)) passed (complete, clean) with no Important finding open, and its branch "
                          + "hasn't moved since, so another audit would check the same commit again. merge(\(slug)) when nothing holds it back; "
                          + "Nits don't need a round. A concrete problem it missed: have the worker fix it and commit, then audit the new commit.")
        }
        let workflow = self.workflow
        let upToDate = try checkUpToDate(slug, head: head, base: workflow.base)
        let behind = upToDate.said
        // Not on a Mac every project's teams already load: the task's own worker (done) and earlier verifier aren't
        // counted, the verifier takes their place.
        let sessions = try hostSessions("whether the Mac has room for a verifier isn't known; no verifier was started")
        let mac = try macLoad(sessions, load: runtime.steadyLoad(), except: Worktrees.path(root: root, slug: slug),
                              refused: "whether the Mac has room for a verifier isn't known; no verifier was started")
        // The finders' number and their Nits' cap as the lead set them, not as a worker rewrote them.
        try checkSettings(workflow, not: "Not audited, no verifier started", keys: ["audit_finders", "audit_nit_cap"])
        // Several finders, or a merged result to test: the audit itself runs init_command and test_command as the lead
        // first (a scratch home is no boundary), so every guard rail must be the lead's, as for merge.
        if workflow.auditFinders > 1 || upToDate.merged != nil {
            try checkSettings(workflow, not: "Not audited, nothing built or tested, no " + (workflow.auditFinders > 1 ? "finder" : "verifier") + " started")
        }
        let finders = workflow.auditFinders
        if let refusal = macRefusal(mac, not: "No verifier started", what: "audit(\(slug))", need: finders) { throw Problem(text: refusal) }
        // Each finder is a session of its own: the Mac must have room for all of them.
        let limits = macLimits()
        if finders > 1, mac.sessions + finders > limits.maxSessions {
            let room = max(0, limits.maxSessions - mac.sessions)
            roomWaits.record(root: root, what: "audit(\(slug))", need: finders, auto: LeadAdvance.isAutomatic)
            throw Problem(text: "Not audited, no finder started: audit_finders is \(finders), and mac_max_sessions leaves room for \(room) more session\(room == 1 ? "" : "s") now "
                          + "(each finder is one, counted with every project's workers and verifiers). Now: \(Self.macText(mac, limits, root: root)). "
                          + "Set audit_finders lower with configure (1 is one verifier), or audit again once sessions have ended. " + LeadPrompts.retryWhenWoken)
        }
        // Settings, hooks or MCP servers the branch brings would run in the verifier: it starts with project settings
        // off (see LeadLaunch), and VibeSwitcher doesn't say yes to Claude's trust question for that folder. What the
        // branch's commits change counts (what would merge), and what Claude reads there uncommitted (see localAgentConfig);
        // any other untracked file (a bench's scratch home, .claude/ and all) is a leftover: it doesn't merge, and cleanup
        // removes the worktree, so the worker names it in its report instead of an rm that could wait on a prompt.
        let committed = Worktrees.committedAgentConfig(root: root, slug: slug, base: workflow.base)
        let local = Worktrees.localAgentConfig(root: root, slug: slug)
        let config = Array(Set(committed + local)).sorted()
        let leftovers = Worktrees.leftovers(root: root, slug: slug)
        // A re-audit checks the open findings and the diff since the commit the last audit covered, not everything again.
        let ledger = vault.audits(root: root, task: slug)
        let recheck = ledger.flatMap { ledger in ledger.isReaudit ? reaudit(ledger, slug: slug, head: head) : nil }
        // Named before its grant goes to the new one.
        let noTools = noToolsBefore(task, .verifier, sessions: sessions)
        let room = makeRoom(task, head: head, need: finders, limits: limits)
        let session: String
        var panel: LeadAuditPanel?
        var merged = upToDate.merged
        let earlier: String
        if finders > 1 {
            let started = try startFinders(finders, task: task, head: head, merged: merged, workflow: workflow, recheck: recheck, trust: config.isEmpty)
            (panel, earlier) = (started.0, started.1)
            session = started.0.sessions[0]
        } else {
            // Behind the base where it matters: its tests run once on the merged result, which the verifier reads.
            if let commit = merged?.commit {
                let run = try auditRun(slug, commit: commit, workflow: workflow, not: "no verifier started")
                merged?.logs = run.logs
                merged?.run = run.outcome.text
                try? store.appendProgress("Audit of \(slug) at \(head.prefix(8)) tested its merged result \(commit.prefix(8)) onto \(workflow.base): \(run.outcome.text)")
            }
            earlier = try endEarlierVerifiers(task, not: "Not audited, no verifier started")
            session = try launch(.verifier, task: slug, name: "verify-\(slug)", in: Worktrees.path(root: root, slug: slug),
                                 label: "Verifier: \(task.title)", trust: config.isEmpty,
                                 prompt: LeadPrompts.verifier(task: task, root: root, workflow: workflow, reaudit: recheck, merged: merged,
                                                              notes: leadNotes(task), report: doneReport(task, head: head),
                                                              guide: LeadRisk.reviewGuide(root: root, base: workflow.base),
                                                              security: Self.securityReason(root: root, head: head, workflow: workflow, raised: task.riskRaised)),
                                 start: "Verify the task now, then call submit_audit.", model: auditModel(workflow), auditing: head)
        }
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].verifier = session
            board.tasks[index].panel = panel
            // A kept task stays kept through a new audit: what holds it back hasn't changed.
            if ![.kept, .folded, .abandoned, .reverted].contains(board.tasks[index].status) { board.tasks[index].status = .review }
            board.tasks[index].evidence = nil
        }
        let flagged: String
        if !committed.isEmpty {
            flagged = " The branch changes Claude's settings or instructions (\(config.prefix(5).joined(separator: ", "))\(config.count > 5 ? ", …" : "")): the verifier runs with project settings off, and VibeSwitcher didn't answer its trust question; tell the user it waits for them to decide, and have the verifier look hard at those files."
        } else if !local.isEmpty {
            flagged = " The worktree holds Claude settings or instructions that aren't committed (\(local.prefix(5).joined(separator: ", "))\(local.count > 5 ? ", …" : "")), which Claude reads when it starts there: the verifier runs with project settings off, and VibeSwitcher didn't answer its trust question; tell the user it waits for them to decide, and have the worker remove them."
        } else {
            flagged = ""
        }
        let round = recheck.map { recheck in
            let covers: String
            switch recheck.scope {
            case .since: covers = "the diff since \(recheck.since.prefix(8)) only"
            case .ownFiles: covers = "the branch's own files since \(recheck.since.prefix(8)) only (it merged \(workflow.base) in since)"
            case .wholeBranch(let same): covers = "the whole branch (\(same ? "the commit audited before, again" : "\(recheck.since.prefix(8)) is no longer in its history"))"
            }
            return " It's a re-audit (round \(recheck.round)): the verifier checks the \(recheck.open.count) open finding\(recheck.open.count == 1 ? "" : "s") and \(covers)."
        } ?? ""
        let cap = ledger?.reconsider == true ? " " + Self.reconsiderText(ledger!, of: slug) : ""
        let tested = merged.map { " One build and test run of its merged result \($0.commit.prefix(8)) came first, and the verifier reads its logs (\($0.run ?? "")): \($0.logs.joined(separator: ", "))." } ?? ""
        if let panel {
            return MCPToolResult(text: noTools + putBack + behind + room + earlier + "\(panel.size) finders started on \(slug) (checking \(head.prefix(8))): " + Self.focusesText(panel.focuses) + ". "
                                 + "One build and test run\(merged.map { " of its merged result \($0.commit.prefix(8))" } ?? "") came first, and every finder reads its logs (\(panel.run)): \(panel.logs.joined(separator: ", ")). "
                                 + "Their findings are voted into one verdict, which arrives as a message once all \(panel.size) have submitted.\(round)\(flagged)\(Self.leftoversText(leftovers))\(cap)")
        }
        return MCPToolResult(text: noTools + putBack + behind + room + earlier + "Verifier started on \(slug) (checking \(head.prefix(8))). Its verdict arrives as a message.\(tested)\(round)\(flagged)\(Self.leftoversText(leftovers))\(cap)")
    }

    /// What audit's reply says of the task's audit still at work on its branch's head: the verifiers it waits on
    /// (see `awaitedVerifiers`), none of which has submitted, ended or had its agent quit, on the commit the branch is
    /// at now; nil when there's none (no audit, one on an older commit, or one whose verifier has died), and audit
    /// starts a new one as before.
    private func runningAudit(_ slug: String) throws -> String? {
        guard let task = store.load().task(slug), task.evidence == nil, let head = branchHead(Worktrees.branch(slug)) else { return nil }
        let waiting = task.awaitedVerifiers
        guard !waiting.isEmpty else { return nil }
        // The commit they check: the panel's, or the verifier's grant's.
        let grant = vault.current(.verifier, root: root, task: slug)
        let commit = task.panel?.commit ?? (grant?.session == task.verifier ? grant?.auditing : nil)
        guard commit == head else { return nil }
        let sessions = try hostSessions("whether \(slug)'s verifier is still auditing isn't known; no verifier was started or ended")
        let roster = (try? vault.roster(root: root)) ?? []
        let submitted = Set(roster.filter { $0.submittedAt != nil }.map(\.session))
        for verifier in waiting {
            guard !submitted.contains(verifier), let info = sessions.first(where: { $0.id == verifier }), info.live,
                  runtime.agentEnding(info) == nil else { return nil }
        }
        let started = roster.first { $0.session == waiting[0] }?.boundAt ?? (grant?.session == waiting[0] ? grant?.issuedAt : nil)
        let since = started.map { " since \(LeadBoard.clock($0)) (\(PendingPrompt.minutes($0, now: Date())) ago)" } ?? ""
        let who = task.panel.map { "\($0.size) finders (\($0.progress); sessions \($0.sessions.joined(separator: ", ")))" } ?? "verifier (session \(waiting[0]))"
        return "Not started again: \(slug)'s \(who) \(task.panel == nil ? "is" : "are") already auditing \(head.prefix(8))\(since), the branch's head, "
            + "so it was left alone; its verdict arrives as a message. A new commit, or its verifier ending without a verdict, lets audit start "
            + "another; audit(\(slug), restart: true) ends it now and starts one on the same commit, throwing its work away."
    }

    /// Why an audit's verifiers get the security checklist (`LeadPrompts.securitySection`); nil when they don't. The
    /// branch touches sensitive_paths, the risk check raised it (a model raises only for security, secrets, stored data
    /// or other sessions; its triggers count for `securityKinds`), or its code changes permissions, spawns processes or
    /// deletes or rewrites files by the risk check's own patterns, on any audit: the lead's review audit too, which the
    /// risk check never reads (a-fix-s-regression was filed so, and its escapes were in a permissions list). Locks
    /// and threads alone are concurrency, not security. `patch`: the branch's `git diff -U0`, read only when needed.
    static func securityReason(sensitive: [String], raised: LeadRiskRaise?, patch: () -> String?) -> String? {
        if !sensitive.isEmpty { return "it touches sensitive_paths: " + LeadRisk.list(sensitive) }
        if let raised, raised.byModel || securityKinds.contains(where: raised.reason.contains) {
            return "the risk check raised it: \(raised.reason)"
        }
        guard let patch = patch(), let flagged = LeadRisk.flagged(patch, kinds: securityKinds) else { return nil }
        return "it has code that \(flagged.what) (\(flagged.path): \(flagged.line))"
    }

    static let securityKinds = Set(LeadRisk.patterns.map(\.what).filter { $0 != "adds locks or threads" })

    /// `securityReason` for the branch at `head` in `root` (`sensitive`: the sensitive paths it touches, when known),
    /// as an audit gives it; scripts/verifier-eval.sh's replay too (vibeswitcher-mcp --verifier-prompt).
    public static func securityReason(root: String, head: String, workflow: LeadWorkflow, raised: LeadRiskRaise?, sensitive: [String]? = nil) -> String? {
        securityReason(sensitive: sensitive ?? sensitiveChanges(root: root, head: head, workflow: workflow), raised: raised, patch: {
            let patch = Git.run(["diff", "-U0", "--no-color", "\(workflow.base)...\(head)"], in: root)
            return patch.ok ? patch.output : nil
        })
    }

    /// The sensitive paths the branch changes from `base` to `head`.
    static func sensitiveChanges(root: String, head: String, workflow: LeadWorkflow) -> [String] {
        let changed = Git.run(["diff", "--name-only", "\(workflow.base)...\(head)"], in: root).output.split(whereSeparator: \.isNewline).map(String.init)
        return changed.filter { path in workflow.sensitiveGlobs.contains { LeadWorkflow.matches(path, glob: $0) } }
    }

    /// The model this project's audits run on: verifier_model, or another than the workers' (see `LeadWorkflow.auditModel`).
    func auditModel(_ workflow: LeadWorkflow) -> String { workflow.auditModel(workerModel: runtime.workerModel(root: root)) }

    /// " The worktree has 3 untracked files (12.0 KB), leftovers …: path (size), …", or "" for none.
    static func leftoversText(_ leftovers: [Worktrees.Leftover]) -> String {
        guard !leftovers.isEmpty else { return "" }
        let shown = 10, total = leftovers.reduce(Int64(0)) { $0 + $1.bytes }
        let list = leftovers.prefix(shown).map(\.text).joined(separator: ", ") + (leftovers.count > shown ? ", and \(leftovers.count - shown) more" : "")
        return " The worktree has \(leftovers.count) untracked file\(leftovers.count == 1 ? "" : "s") (\(Worktrees.Leftover.size(total))), leftovers that don't merge: "
            + "\(list). Leave them: the merge takes only commits and cleanup removes the worktree, so don't have the worker rm "
            + "them (a removal can wait on a permission prompt only the user answers). Scratch goes in its session's TMPDIR, "
            + "never the worktree; they don't change the audit."
    }

    /// "finder 1: contract and acceptance, finder 2: bugs and regressions".
    static func focusesText(_ focuses: [String]) -> String {
        focuses.enumerated().map { "finder \($0.offset + 1): \($0.element)" }.joined(separator: ", ")
    }

    /// An audit by `count` finders: one build and test run of `head` first (its logs kept per commit, so an audit
    /// of the same commit again reuses them), then each finder started with its focus and those logs, as one panel
    /// in the vault. A finder that fails to start ends the ones started before it. The task's earlier verifiers are
    /// ended first (see `endEarlierVerifiers`), and the panel comes with what audit's reply says of them.
    /// A branch behind the base where it matters is tested as it would land: `merged`'s commit, not `head`.
    private func startFinders(_ count: Int, task: LeadTask, head: String, merged: LeadPrompts.Merged?, workflow: LeadWorkflow,
                              recheck: LeadPrompts.Reaudit?, trust: Bool) throws -> (LeadAuditPanel, String) {
        let slug = task.slug
        let tested = merged?.commit ?? head
        let run = try auditRun(slug, commit: tested, workflow: workflow, not: "no finder started")
        let sensitive = Self.sensitiveChanges(root: root, head: head, workflow: workflow)
        let focuses = LeadPrompts.Focus.panel(count, sensitive: !sensitive.isEmpty)
        let notes = leadNotes(task), report = doneReport(task, head: head), guide = LeadRisk.reviewGuide(root: root, base: workflow.base)
        let security = Self.securityReason(root: root, head: head, workflow: workflow, raised: task.riskRaised, sensitive: sensitive)
        let earlier = try endEarlierVerifiers(task, not: "Not audited, no finder started")
        let id = UUID().uuidString
        var sessions: [String] = []
        for (offset, focus) in focuses.enumerated() {
            let index = offset + 1
            let finder = LeadPrompts.Finder(index: index, size: count, focus: focus, commit: tested, logs: run.logs, run: run.outcome.text,
                                            sensitive: sensitive, nitCap: workflow.auditNitCap)
            do {
                sessions.append(try launch(.verifier, task: slug, name: index == 1 ? "verify-\(slug)" : "finder\(index)-\(slug)",
                                           in: Worktrees.path(root: root, slug: slug), label: "Verifier: \(task.title) (finder \(index)/\(count): \(focus.rawValue))",
                                           trust: trust, prompt: LeadPrompts.verifier(task: task, root: root, workflow: workflow, reaudit: recheck, finder: finder,
                                                                                      merged: merged, notes: notes, report: report, guide: guide,
                                                                                      security: security),
                                           start: "Look for findings in your focus now, then call submit_audit.", model: auditModel(workflow), auditing: head,
                                           finder: LeadVault.Finder(panel: id, index: index, size: count, focus: focus.rawValue, nitCap: workflow.auditNitCap)))
            } catch {
                for started in sessions { try? runtime.kill(started) }
                throw Problem(text: "Not audited: finder \(index) of \(count) couldn't start (\(error))" + (sessions.isEmpty ? "." : "; the \(sessions.count) started before it were ended."))
            }
        }
        try? store.appendProgress("Audit of \(slug) at \(head.prefix(8)) by \(count) finders (\(focuses.map(\.rawValue).joined(separator: "; "))); the shared run"
                                  + (merged == nil ? "" : " of its merged result \(tested.prefix(8))") + ": \(run.outcome.text)")
        return (LeadAuditPanel(focuses: focuses.map(\.rawValue), sessions: sessions, commit: head, logs: run.logs, run: run.outcome.text), earlier)
    }

    /// The task's verifiers still running (the board's, and any other in its worktree), ended before an audit starts
    /// its own: a task has one live verifier, or audit_finders finders, at a time. The new grant replaces theirs, so no
    /// verdict can come from them now (2026-10-24: project-c's app-security-rpc-trust had four verifiers alive at once, one
    /// per audit call on the same commit, until all four were ended with its fold). One the host doesn't end refuses the
    /// audit (`not`: what didn't happen): started beside it, the task would have one more. What audit's reply says of
    /// them; "" for none.
    private func endEarlierVerifiers(_ task: LeadTask, not: String) throws -> String {
        let refused = "whether \(task.slug) has a verifier still running isn't known; \(not.prefix(1).lowercased() + not.dropFirst())"
        let folder = (Worktrees.path(root: root, slug: task.slug) as NSString).standardizingPath
        let ours = Set((task.panel?.sessions ?? []) + [task.verifier].compactMap { $0 })
        let earlier = try hostSessions(refused).filter { session in
            session.live && (ours.contains(session.id)
                || (Self.isTeamSession(session, in: folder) && LeadTeams.role(label: session.label) == .verifier))
        }
        guard !earlier.isEmpty else { return "" }
        // Off the board first: a witness pass while they end (or while the new one starts) would take one for a
        // verifier that ended without its verdict, and tell the lead to audit again.
        let named = try store.update { board -> (verifier: String?, panel: LeadAuditPanel?) in
            guard let index = board.taskIndex(task.slug) else { return (nil, nil) }
            defer { (board.tasks[index].verifier, board.tasks[index].panel) = (nil, nil) }
            return (board.tasks[index].verifier, board.tasks[index].panel)
        }
        // One the host didn't end, ended as cleanup ends one (see endItself).
        let endings = try endItself(try end(earlier, refused: refused), refused: refused)
        let failed = endings.filter { $0.failure != nil }
        guard failed.isEmpty else {
            // Still running: the board names it again, as before this audit.
            try? store.update { board in
                guard let index = board.taskIndex(task.slug), board.tasks[index].verifier == nil, board.tasks[index].panel == nil else { return }
                (board.tasks[index].verifier, board.tasks[index].panel) = named
            }
            throw Problem(text: "\(not): \(task.slug)'s earlier verifier is still running (\(failed.map(\.said).joined(separator: "; "))), and one more beside it "
                          + "would make two. If the host refuses, tell the user (they can end it in VibeSwitcher), then audit again.")
        }
        let which = endings.count == 1 ? "earlier verifier" : "\(endings.count) earlier verifiers"
        return "Ended \(task.slug)'s \(which) first (\(endings.map(\.said).joined(separator: ", "))): this audit's grant replaces "
            + "\(endings.count == 1 ? "its" : "theirs"), so no verdict could come from \(endings.count == 1 ? "it" : "them"). "
    }

    /// The audit's one build and test run of `commit` (the branch's head, or its merged result), its logs kept per
    /// commit, so an audit of the same commit again reuses them. `not`: what didn't start when it was cancelled.
    private func auditRun(_ slug: String, commit: String, workflow: LeadWorkflow, not: String) throws -> Worktrees.AuditRun {
        guard let lock = FileLock.attempt((store.folder as NSString).appendingPathComponent("run/audit-\(slug).lock")) else {
            throw Problem(text: "An audit of \(slug) is already making its build and test run; its verdict comes as a report.")
        }
        defer { lock.release() }
        let logs = URL(fileURLWithPath: store.folder).appendingPathComponent("audit/\(slug)/\(commit.prefix(12))")
        let run = Self.sharedRun(at: logs) ?? {
            Worktrees.auditRun(root: root, commit: commit, setup: workflow.initCommand, test: workflow.testCommand,
                               scratch: vault.scratch(root: root, "audit-\(slug)"), home: vault.scratch(root: root, "audit-\(slug)-home"),
                               logs: logs, timeout: workflow.testTimeout, lock: heavyLock(workflow))
        }()
        if case .cancelled = run.outcome {
            throw Problem(text: "The audit of \(slug) was cancelled during its build and test run; \(not).")
        }
        return run
    }

    /// A finished shared run kept at `logs` (its run.txt is written last), for an audit of the same commit again.
    static func sharedRun(at logs: URL) -> Worktrees.AuditRun? {
        guard let said = try? String(contentsOf: logs.appendingPathComponent("run.txt"), encoding: .utf8) else { return nil }
        let files = ["init.log", "test.log"].map { logs.appendingPathComponent($0).path }.filter { FileManager.default.fileExists(atPath: $0) }
        let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a run that ran to its end is kept: one that couldn't run runs again.
        let outcome: Worktrees.AuditRun.Outcome
        switch text {
        case Worktrees.AuditRun.Outcome.passed.text: outcome = .passed
        case Worktrees.AuditRun.Outcome.noTests.text: outcome = .noTests
        case Worktrees.AuditRun.Outcome.failed("init_command").text: outcome = .failed("init_command")
        case Worktrees.AuditRun.Outcome.failed("test command").text: outcome = .failed("test command")
        default: return nil
        }
        return Worktrees.AuditRun(outcome: outcome, logs: files)
    }

    /// What a re-audit's verifier is handed: the open findings, the closed ones (not to raise again) and the diff its
    /// new findings come from (whole while it's short, else its stat and the command; see `reauditScope`).
    private func reaudit(_ ledger: LeadAuditLedger, slug: String, head: String) -> LeadPrompts.Reaudit? {
        guard let since = ledger.commit else { return nil }
        let base = workflow.base
        let scope = reauditScope(since: since, head: head, base: base)
        let range = Self.diffArguments(scope, since: since, head: head, base: base)
        // No file of its own to show: no diff to run (`git diff a...b --` alone would show everything).
        let stat = range.map { Git.run(["diff", "--stat"] + $0, in: root) }
        let diff = range.map { Git.run(["diff"] + $0, in: root) }
        let task = store.load().task(slug)
        return LeadPrompts.Reaudit(round: ledger.rounds + 1, since: since, head: head, open: ledger.toRecheck,
                                   known: ledger.findings.filter { !$0.isOpen || $0.severity == .preExisting },
                                   stat: stat.map { $0.ok ? $0.output : "(git diff --stat failed: \($0.error))" } ?? "",
                                   diff: diff.flatMap { $0.ok && $0.output.count <= LeadPrompts.Reaudit.diffLimit ? $0.output : nil },
                                   base: base, scope: scope, answers: task?.currentAnswers(ledger) ?? [:], reroll: task?.pendingReroll(ledger))
    }

    /// What a re-audit of `head` covers, the last audit having covered `since`: the same commit again (a 'blocked'
    /// verdict, say) or a history without `since` is the whole branch since its merge-base with the base; a branch
    /// that merged the base since is its own commits' files, against that merge-base (the base's commits aren't the
    /// branch's to review); otherwise the diff since `since`.
    private func reauditScope(since: String, head: String, base: String) -> LeadPrompts.Reaudit.Scope {
        if since == head { return .wholeBranch(sameCommit: true) }
        guard Git.run(["merge-base", "--is-ancestor", since, head], in: root).ok else { return .wholeBranch(sameCommit: false) }
        let before = Git.run(["merge-base", base, since], in: root), now = Git.run(["merge-base", base, head], in: root)
        guard before.ok, now.ok, before.output != now.output else { return .since }
        return .ownFiles(ownFiles(since: since, head: head, base: base).sorted())
    }

    /// The files the branch's own commits since `since` touched, not the base's it took in: each commit's against
    /// its parent, a merge's only where it differs from every parent (what resolving it changed).
    private func ownFiles(since: String, head: String, base: String) -> Set<String> {
        let commits = Git.run(["rev-list", "--parents", head, "^" + since, "^" + base], in: root)
        guard commits.ok else { return [] }
        var files: Set<String> = []
        for line in commits.output.split(whereSeparator: \.isNewline) {
            let ids = line.split(separator: " ").map(String.init)
            guard let commit = ids.first else { continue }
            let parents = ids.dropFirst()
            guard let first = parents.first else {
                files.formUnion(changedFiles(from: Self.emptyTree, to: commit) ?? [])
                continue
            }
            var touched = changedFiles(from: first, to: commit) ?? []
            for parent in parents.dropFirst() { touched.formIntersection(changedFiles(from: parent, to: commit) ?? []) }
            files.formUnion(touched)
        }
        return files
    }

    /// git's empty tree, the parent of a root commit.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// `git diff`'s arguments for a re-audit's scope (nil: a branch's own files when there are none).
    static func diffArguments(_ scope: LeadPrompts.Reaudit.Scope, since: String, head: String, base: String) -> [String]? {
        switch scope {
        case .since: return [since, head]
        case .ownFiles(let files): return files.isEmpty ? nil : ["\(base)...\(head)", "--"] + files
        case .wholeBranch: return ["\(base)...\(head)"]
        }
    }

    /// The files a re-audit's new findings may be in (nil: git can't tell).
    private func reauditFiles(since: String, head: String) -> Set<String>? {
        let base = workflow.base
        let scope = reauditScope(since: since, head: head, base: base)
        if case .ownFiles(let files) = scope { return Set(files) }
        guard let range = Self.diffArguments(scope, since: since, head: head, base: base) else { return [] }
        let names = Git.run(["diff", "--name-only"] + range, in: root)
        return names.ok ? Set(names.output.split(whereSeparator: \.isNewline).map(String.init)) : nil
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

    /// The lead's note on `slug`, sealed by the session host as the lead's (unsealed when the host doesn't answer: the
    /// verifier is then told it isn't the lead's word, see `leadNotes`).
    private func leadNote(_ kind: LeadNote.Kind, _ text: String, on slug: String) -> LeadNote {
        var note = LeadNote(kind: kind, text: text, by: "lead of \(project)")
        note.seal = try? vault.seal(note.sealed(task: slug))
        return note
    }

    /// The task's notes for its verifier: those whose seal holds as the lead's for this task, and how many don't (a
    /// line written onto the board by hand, a note copied from another task) or couldn't be checked now.
    func leadNotes(_ task: LeadTask) -> LeadPrompts.Notes {
        let notes = task.notes ?? []
        guard !notes.isEmpty else { return LeadPrompts.Notes() }
        guard let valid = try? vault.verify(notes.map { $0.sealed(task: task.slug) }), valid.count == notes.count else {
            return LeadPrompts.Notes(unverified: notes.count, unchecked: true)
        }
        let held = zip(notes, valid).filter(\.1).map(\.0)
        return LeadPrompts.Notes(lead: held, unverified: notes.count - held.count)
    }

    /// The worker's done report for its verifier: the board's copy, when the vault has the task's own worker
    /// reporting done on `head` (the board is anyone's to write; the vault takes "done" only from that worker).
    /// Its evidence comes from the vault, kept with that done.
    func doneReport(_ task: LeadTask, head: String) -> String? {
        guard let report = task.report, let kept = try? vault.unaudited(root: root, task: task.slug), kept.reported == head else { return nil }
        guard let evidence = kept.evidence else { return report }
        return report + "\n\nIts evidence, check by check (what it says it ran and saw):\n" + evidence.lines.joined(separator: "\n")
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

    /// What `checkUpToDate` found of a branch that may be audited: how far behind the base it is, said in a line, and
    /// the merged result the audit checks when the base changed files it changes too.
    struct UpToDate {
        var said: String
        var merged: LeadPrompts.Merged?
    }

    /// A trial merge onto the base first: a branch that conflicts can't land, and its worker is the one to resolve it
    /// (2026-10-20: a-role-session-s passed its audit, then its verifier found by hand that it conflicted with work
    /// merged meanwhile; one more audit and verifier for the resolution). A branch that hasn't taken in what the base
    /// did since to files it changes too can still break once it's rebased at merge (2026-10-19, twice: base commits
    /// that came after a worker's last `git merge` changed the test file it changed, and the merge's build failed);
    /// it used to be refused, and every merge sent the other branches back for a catch-up their trial merges didn't
    /// need (2026-10-24: about 8 worker turns, all conflict-free). Now its audit checks the merged result instead
    /// (`UpToDate.merged`), and merge's full suite runs on the result as ever. The lead's records (`records_dir`)
    /// count in neither check: merge takes the base's of them (`Worktrees.takeBaseRecords`), and the worker may not
    /// touch them.
    private func checkUpToDate(_ slug: String, head: String, base: String) throws -> UpToDate {
        let records = Set(workflow.recordsDir.map(LeadRecords.paths) ?? [])
        let since: Worktrees.BaseSince
        switch Worktrees.baseSince(root: root, base: base, commit: head) {
        case .success(let found): since = found
        case .failure(let error): throw Problem(text: "No verifier started: whether agent/\(slug) is up to date with \(base) can't be told (\(error)).")
        }
        let conflicts: [String]
        switch Worktrees.trialMerge(root: root, base: base, commit: head) {
        case .success(let found): conflicts = found.filter { !records.contains($0) }
        case .failure(let error): throw Problem(text: "No verifier started: whether agent/\(slug) merges cleanly onto \(base) can't be told (\(error)).")
        }
        if !conflicts.isEmpty {
            let commits = since.commits(touching: conflicts)
            let listed = commits.prefix(8).map { commit in
                "\(commit.line) (\(commit.files.filter(conflicts.contains).joined(separator: ", ")))"
            }
            let files = conflicts.prefix(12).joined(separator: ", ") + (conflicts.count > 12 ? ", …" : "")
            throw Problem(text: "Not audited, no verifier started: a trial merge of agent/\(slug) (\(head.prefix(8))) onto \(base) (git merge-tree) conflicts, so it can't land as it is. "
                          + "Files: \(files). "
                          + "\(base)'s commits that touched them since agent/\(slug) last took it in (at \(since.mergeBase.prefix(8))): "
                          + (listed.isEmpty ? "none found" : listed.joined(separator: "; ") + (commits.count > 8 ? "; …" : "")) + ". "
                          + "Message its worker this: \"Your branch conflicts with \(base) in \(files). In your worktree run `git merge \(base)`, resolve the conflicts in those files, `git add` them, then `git commit`, each command on its own (no pipes, && or 2>&1); "
                          + "then run the test suite once and report.\" (start_worker again if it has stopped). Then audit again: a verifier only checks a branch that merges cleanly.")
        }
        let behind = since.commits.isEmpty ? "" : "agent/\(slug) is \(since.commits.count) commit\(since.commits.count == 1 ? "" : "s") behind \(base); a trial merge onto it is clean. "
        let files = since.overlap.filter { !records.contains($0) }
        guard !files.isEmpty else { return UpToDate(said: behind) }
        let merge: String
        switch Worktrees.mergedCommit(root: root, base: base, commit: head) {
        case .success(let made): merge = made
        case .failure(let error): throw Problem(text: "No verifier started: agent/\(slug) is behind \(base) in files it changes too, and the merged result its audit checks couldn't be made (\(error)).")
        }
        let commits = since.commits(touching: files)
        let listed = commits.prefix(4).map { commit in
            "\(commit.line) (\(commit.files.filter(files.contains).joined(separator: ", ")))"
        }
        let said = "agent/\(slug) is \(since.commits.count) commit\(since.commits.count == 1 ? "" : "s") behind \(base), and \(commits.count) of them change files it changes too "
            + "(\(files.prefix(12).joined(separator: ", "))\(files.count > 12 ? ", …" : "")): \(listed.joined(separator: "; "))\(commits.count > 4 ? "; …" : ""). "
            + "A trial merge onto \(base) is clean, so the audit checks the merged result, \(merge.prefix(8)) (\(base) with the branch merged in; its worker needn't catch up), "
            + "and merge runs the full suite on the result again. "
        return UpToDate(said: said, merged: LeadPrompts.Merged(commit: merge, base: base, head: head, files: files))
    }

    /// What the lead tells a worker whose branch conflicts with the base.
    private static func bringUpToDate(_ base: String) -> String {
        "Message its worker to bring its branch up to date by merging, in its worktree: `git merge \(base)`, resolve the conflicts, `git add` the files, then `git commit`, each command on its own (no pipes, && or 2>&1); then run the tests and report again (start_worker again if it has stopped). Then audit again; merge puts the work on top of \(base) itself."
    }

    private func merge(_ slug: String) throws -> MCPToolResult {
        guard let task = store.load().task(slug) else { throw Problem(text: "No task \(slug).") }
        if task.status == .done {
            throw Problem(text: "\(slug) is already merged" + (task.merged.map { " at \($0.commit.prefix(8)) (\(LeadBoard.clock($0.at)))" } ?? "")
                          + ". Nothing to do but cleanup, if it isn't done yet.")
        }
        if Self.settledStates.contains(task.status) { throw Self.settledRefusal(task, "Not merged") }
        try checkBattery(not: "Not merged")
        // Held back on purpose (a decision, the user's word): only the lead setting it back lets it merge.
        if task.status == .kept {
            throw Problem(text: "Not merged: \(slug) is kept unmerged (\(task.keptBecause ?? "no reason recorded")). If that no longer holds (the user said so, a newer decision), update_task(\(slug), status: planned) first, and say why with record_decision.")
        }
        // The commit that merges, and whether a passing audit let it in.
        let commit: String, audited: Bool
        // The Important findings the lead dismissed on a verdict that failed only on them (see `Verdict.dismissed`).
        var dismissed: [LeadFinding] = []
        // The verdict as the verifier's own tool server recorded it in the vault (the board's copy is for showing):
        // from the verifier VibeSwitcher started last for this task, on the commit it was started on.
        if let verdict = vault.verdict(root: root, task: slug) {
            if !verdict.passes {
                let ledger = vault.audits(root: root, task: slug)
                if let accepted = verdict.dismissed(in: ledger) {
                    dismissed = accepted
                } else if !(verdict.completion == .complete && verdict.tests == .passed && ledger?.commit == verdict.commit && ledger?.blocking.isEmpty == false) {
                    throw Problem(text: vault.missingVerdictReason(root: root, task: slug)
                        ?? "\(slug) has no passing audit. Run audit: merge takes a complete, clean verdict" + Self.notDismissable(verdict) + ".")
                }
                // Else it's open Important findings that hold it back, and the check below says which.
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
            (commit, audited) = (verdict.commit, true)
        } else {
            let head = branchHead(Worktrees.branch(slug))
            if let needed = reviewNeeded(slug, commit: head, model: true) {
                throw Problem(text: (vault.missingVerdictReason(root: root, task: slug)
                    ?? "\(slug) has no passing audit. Run audit: merge takes a complete, clean verdict.") + " " + needed)
            }
            // review none: its worker's "done" on the head, and the merge's own test run below, are the check.
            commit = try unauditedCommit(slug, head: head)
            audited = false
        }
        // Every Important finding is resolved (fixed in a later round, or dismissed with a reason) before it merges.
        if let blocking = vault.audits(root: root, task: slug)?.blocking, !blocking.isEmpty {
            throw Problem(text: "Not merged: \(slug) has \(blocking.count) open Important finding\(blocking.count == 1 ? "" : "s"): "
                + blocking.map { "\(slug):" + Self.clip($0.line1, 200) }.joined(separator: "; ")
                + ". Have the worker fix \(blocking.count == 1 ? "it" : "them") and audit again, or dismiss_finding with a reason, or add_task(from_finding: …) to move one to a task of its own.")
        }
        try checkMergePolicy(task, commit: commit)
        guard let lock = FileLock.attempt((store.folder as NSString).appendingPathComponent("run/merge-\(slug).lock")) else {
            throw Problem(text: "A merge of \(slug) is already running; its result comes back to the call that started it.")
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
        try checkBaseMoves(base: base, current: current)
        // A lock in the main checkout stops the fast-forward at the end: said now, before the tests run.
        if let lock = Worktrees.indexLock(blocking: base, root: root) {
            throw Problem(text: "Not merged (nothing was tested): \(Worktrees.refusal(lock))")
        }
        // Timing-sensitive tests fail on a Mac every project's team is loading: the tests wait (a bounded time) for
        // the load to drop.
        let waited = try waitForLoad(workflow, slug: slug)
        // Exactly the audited commit, rebased and tested where no agent works. A failing test command runs once more
        // (`MergeRerun`): what failed, then the rerun that passed, when that's how it passed.
        let tested: String
        var rerun: MergeRerun.Plan?
        var flaked: (plan: MergeRerun.Plan, failed: String, log: String?)?
        // The passing run's test count, for its receipt.
        var testCount: Int?
        switch Worktrees.rebaseAndTest(root: root, commit: commit, onto: current, setup: workflow.initCommand, test: workflow.mergeChecks,
                                       scratch: vault.scratch(root: root, "merge-\(slug)"), home: vault.scratch(root: root, "merge-\(slug)-home"),
                                       timeout: workflow.testTimeout, lock: heavyLock(workflow), records: workflow.recordsDir,
                                       rerun: { output in
                                           rerun = MergeRerun.plan(after: output, workflow: workflow)
                                           return rerun?.command
                                       }, tested: { testCount = LeadReceipt.testCount($0) }) {
        case .passed(let commit): tested = commit
        case .passedOnRerun(let commit, let failed, let again):
            guard let plan = rerun else { throw Problem(text: "Not merged: \(slug)'s tests passed on a rerun nobody planned.") }
            // A filter that matched nothing ran nothing: that's no pass.
            let unshown = MergeRerun.unshown(plan, rerun: again)
            guard unshown.isEmpty else {
                let names = unshown.prefix(8).joined(separator: ", ")
                try setStatus(slug, .failed, setback: LeadSetback(stage: .merge, reason: "Tests fail rebased onto \(base): \(Self.clip(plan.tests.joined(separator: ", "), 200))"))
                throw Problem(text: testFailure(failed, slug: slug, base: base, commit: commit, onto: current)
                              + "\nIts rerun of the failing tests exited 0 but didn't show \(names) passing (a filter that matched nothing), so it doesn't count.")
            }
            tested = commit
            flaked = (plan, failed, saveMergeLog(failed + "\n" + again, slug: slug))
        case .cancelled:
            // Stopped by the caller: nothing is known about the work, and the task stays as it was.
            throw Problem(text: "The merge of \(slug) was cancelled; nothing was merged, and \(slug) stays as it was.")
        case .hung(let command, let after, let output):
            // Not a failure of the work as far as anyone knows: the task stays as it was, and the lead decides.
            let (what, they) = command == "init_command" ? ("init_command", "it was") : ("tests", "they were")
            let saved = saveMergeLog(output, slug: slug)
            // The tests that never finished and the output's tail, where the worker who fixes the hang can read them
            // (the merge's log is in the vault).
            let hung = Self.clip(Redaction.secrets(in: MergeRerun.hung(in: output).joined(separator: ", ")))
            let readable = saveEvidence(MergeRerun.hungLog(task: slug, commit: commit, command: command, after: after, output: output),
                                        log: MergeRerun.hungPath(task: slug, commit: commit, at: Date()))
                .map { MergeRerun.evidenceFile(root: root, log: $0) }
            let named = hung.isEmpty ? "No test in its output started and never finished. " : "Started and never finished: \(hung). "
            try? store.appendProgress("Hung in \(slug)'s merge: the \(what) stopped after \(Worktrees.duration(after))"
                                      + (hung.isEmpty ? "; no test in its output started and never finished" : "; started and never finished: \(hung)")
                                      + (readable.map { " (\($0))" } ?? ""))
            throw Problem(text: "Not merged: the \(what) hung after \(Worktrees.duration(after)) on \(slug) rebased onto \(base); \(they) stopped, with everything started under them. \(slug) stays as it was. "
                          + named
                          + (readable.map { "Those and the output's last \(MergeRerun.hungTail) lines, readable by the worker who fixes it: \($0). " } ?? "")
                          + (saved.map { "The output so far: \($0). " } ?? "(The output couldn't be saved.) ")
                          + "If they only need longer, raise test_timeout_min (\(Self.gb(workflow.testTimeoutMinutes)) in workflow.md) with configure; else have the worker find what hangs.")
        case .conflict:
            try setStatus(slug, .failed, setback: LeadSetback(stage: .merge, reason: "Conflicts with \(base): the branch needs bringing up to date."))
            throw Problem(text: "\(slug) conflicts with \(base). " + Self.bringUpToDate(base))
        case .failed(let output):
            // The setback names the failing tests; the output's last line only when none is named.
            let tests = TestFailures(output: output).tests.joined(separator: ", ")
            let last = tests.isEmpty ? output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "" : tests
            let what = output.components(separatedBy: "\n").contains(LeadWorkflow.regressionMarker) ? "regression_command fails" : "Tests fail"
            try setStatus(slug, .failed, setback: LeadSetback(stage: .merge, reason: "\(what) rebased onto \(base)" + (last.isEmpty ? "." : ": \(last.prefix(200))")))
            throw Problem(text: testFailure(output, slug: slug, base: base, commit: commit, onto: current))
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
            let flakes = flaked.map { $0.plan.tests.isEmpty ? [MergeRerun.unnamed] : $0.plan.tests } ?? []
            // Each flaky test's failure lines, where every session can read them (the merge's log is in the vault).
            let flakeLines = flaked.map { MergeRerun.evidence(in: $0.failed, tests: $0.plan.tests) } ?? [:]
            // One moment for the file's day and the ledger's entry.
            let flakedAt = Date()
            let flakeLog = flakeLines.isEmpty ? nil : saveFlakeEvidence(flakeLines, tests: flakes, slug: slug, commit: tested, at: flakedAt)
            // Its receipt, written with the merge: its transcripts read before the board's lock is taken.
            let usage = receiptUsage(task)
            let brought = Int(Git.run(["rev-list", "--count", "\(current)..\(tested)"], in: root).output)
            let planned = try store.update { board -> [(test: String, slug: String, noted: Bool)] in
                guard let index = board.taskIndex(slug) else { return [] }
                board.tasks[index].status = .done
                board.tasks[index].merged = LeadMergeRecord(commit: tested, tested: workflow.testCommand != nil, onto: current,
                                                             regression: workflow.regressionCommand.map { _ in true }, audited: audited ? nil : false)
                board.tasks[index].receipt = LeadReceipt(board.tasks[index], ending: .merged, questions: board.questions, usage: usage,
                                                         tests: workflow.testCommand == nil ? nil : testCount, mergeReruns: flaked == nil ? 0 : 1,
                                                         commits: brought)
                guard !flakes.isEmpty else { return [] }
                // The flake ledger, and a task for each test that flaked once too often (once: `recordFlakes`), unless
                // an open task names it already: its count goes in that task's context.
                return board.recordFlakes(flakes, task: slug, commit: tested, now: flakedAt.timeIntervalSince1970, logged: Set(flakeLines.keys),
                                          log: flakeLog).map { test, _, counted in
                    if let open = board.openTask(naming: test), let index = board.taskIndex(open.id) {
                        let context = board.tasks[index].contract.context.trimmingCharacters(in: .whitespacesAndNewlines)
                        let line = MergeRerun.flakeNote(test: test, flakes: counted, root: root)
                        board.tasks[index].contract.context = context.isEmpty ? line : context + "\n\n" + line
                        board.notePlanned(open.slug, for: test)
                        return (test, open.slug, true)
                    }
                    let title = "Fix the flaky test " + Self.clip(test, 60)
                    let fix = LeadTask(slug: Slug.make(title, taken: store.takenSlugs(board)), title: title,
                                       contract: MergeRerun.fixContract(test: test, flakes: counted, workflow: workflow, root: root))
                    board.tasks.append(fix)
                    board.notePlanned(fix.slug, for: test)
                    return (test, fix.slug, false)
                }
            }
            // Nothing ran: say so, it isn't a pass.
            let untested = workflow.testCommand == nil
                ? " (merged without tests: no test_command\(workflow.problem.map { "; \($0)" } ?? ""). Set one with configure.)" : ""
            try? store.appendProgress("Merged \(slug): \(task.title)\(untested.isEmpty ? "" : " (without tests: no test_command)")\(audited ? "" : " (no audit: review none)")"
                + (dismissed.isEmpty ? "" : " (its audit's Important findings dismissed by the lead: \(dismissed.map(\.id).joined(separator: ", ")))"))
            let ran = workflow.regressionCommand == nil ? "" : " (regression_command passed too.)"
            let patience = waited.map { " (The tests waited \(Worktrees.duration($0.after)) for the Mac's load to drop from \(MacLoad.number($0.from)) below load_threshold.)" } ?? ""
            let unaudited = audited ? "" : " (No audit: review none, on its worker's done report and the tests that just passed.)"
            // Only the evidence of a done on the commit merged: an older one's claims aren't this commit's.
            let kept = try? vault.unaudited(root: root, task: slug)
            let evidence = kept?.reported == commit ? kept?.evidence.map { " Its worker's evidence: \($0.brief())" } ?? "" : ""
            let overruled = dismissed.isEmpty ? "" : " (Its audit was complete with its tests passing, and \(dismissed.count == 1 ? "the one Important finding that failed it" : "the \(dismissed.count) Important findings that failed it") you dismissed: "
                + dismissed.map { "\($0.id) \($0.place) (\(Self.clip($0.reason ?? "", 120)))" }.joined(separator: "; ") + ".)"
            var flakeNote = ""
            if let flaked {
                let names = flakes.joined(separator: ", ")
                try? store.appendProgress("Flaky in \(slug)'s merge: \(Self.clip(names, 300)) failed the first test run and passed its rerun (\(flaked.plan.filtered ? "the failing tests only" : "the whole test command")); merged on the rerun")
                for (test, fix, noted) in planned {
                    try? store.appendProgress((noted ? "Noted in \(fix)'s context (an open task naming it; no new task)" : "Planned \(fix)")
                                              + ": \(test) flaked \(LeadBoard.flakeLimit) times within \(Int(LeadBoard.flakeWindow / 86_400)) days")
                }
                let due = planned.map { test, fix, noted -> String in
                    let what = noted ? "the open task \(fix) names it, so that's noted in its context and no new task was planned." : "planned \(fix) to fix it."
                    return "\(test) flaked \(LeadBoard.flakeLimit) times within \(Int(LeadBoard.flakeWindow / 86_400)) days: " + what
                }
                flakeNote = " (Its first test run failed on \(Self.clip(names, 300)) and the rerun of \(flaked.plan.filtered ? "those tests" : "the whole test command") passed, so it merged on the rerun: recorded in the flake ledger, which status lists."
                    + (flaked.log.map { " Both runs' output: \($0)." } ?? "")
                let readable = flakeLog.map { " Each flaky test's failing lines, readable by its fixer: \(MergeRerun.evidenceFile(root: root, log: $0))." } ?? ""
                flakeNote += readable
                    + (due.isEmpty ? "" : " " + due.joined(separator: " "))
                    + ")"
            }
            let caughtUp = tellToCatchUp(merged: slug, from: current, to: tested, base: base)
            archiveFinished(force: false)
            return MCPToolResult(text: "Merged \(slug) into \(base)\(untested). Next: cleanup(\(slug)). \(LeadPrompts.Policy.updates)\(overruled)\(unaudited)\(ran)\(patience)\(evidence)\(flakeNote)\(caughtUp)")
        case .refused(let reason):
            throw Problem(text: "Not merged: \(reason)")
        }
    }

    /// The base moves only through merges and reverts: anything else that moved it from where the vault last saw it
    /// (a worker's git, a hand-made commit) is something nobody audited, and is refused (`BaseMoveRefusal`). Except
    /// the user's own commits, which the vault takes when their sessions' hooks account for every one.
    private func checkBaseMoves(base: String, current: String) throws {
        if let known = vault.head(root: root, branch: base), known != current {
            let move = Result { try vault.acceptMove(root: root, branch: base) }
            guard case .success(let taken) = move, taken.accepted, taken.to == current else {
                // Its merges wait on the user now: the window tells them (`AlertRules.baseMoved`).
                LeadVault.BaseMoveRefusal.mark(base: base, current: current, move: move, root: root)
                throw Problem(text: LeadVault.moveRefusal(base: base, known: known, current: current, move: move, root: root))
            }
            try? store.update { $0.updates.append(LeadUpdate(title: "Took \(taken.count) on \(base)", body: taken.acceptedLine)) }
            try? store.appendProgress(taken.acceptedLine)
        } else if vault.head(root: root, branch: base) == nil {
            try vault.setHead(current, root: root, branch: base)
        }
    }

    /// Undoes a merged task in one step: one commit on top of the base reverts the commits its merge put there (the
    /// board's `merged.onto..merged.commit`), made and tested where no agent works (`Worktrees.revertAndTest`), and the
    /// base fast-forwards to it. It keeps what merge keeps: the battery hold, the Mac-wide test lock, the load wait,
    /// the guarded settings, one move of the base at a time, and the base-move check. It only adds a commit: a failed
    /// test run or a conflict with what came later leaves the base as it was, the task merged.
    private func revert(_ slug: String, reason given: String) throws -> MCPToolResult {
        let reason = given.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            throw Problem(text: "Not reverted: say what the merge broke (reason), in one line; it goes into the revert commit and the task's record.")
        }
        guard let task = store.loadAll().task(slug) else { throw Problem(text: "No task \(slug).") }
        if task.status == .reverted {
            throw Problem(text: "\(slug) is reverted already" + (task.merged?.revertedBy.map { " (by \($0.prefix(8)))" } ?? "") + ". Nothing to do.")
        }
        guard task.status == .done, let merged = task.merged else {
            throw Problem(text: "Not reverted: \(slug) isn't merged (it's \(Self.shownState(task))), so nothing of it is on the base to undo.")
        }
        guard let onto = merged.onto else {
            throw Problem(text: "Not reverted: \(slug) merged (at \(merged.commit.prefix(8))) before the board recorded the commit it went onto, so which commits it brought can't be told for sure. "
                          + "Revert it by hand, or plan a fix-forward task (add_task).")
        }
        if let by = merged.revertedBy {
            throw Problem(text: "Not reverted: \(by.prefix(8)) on the base already reverts \(slug)'s merge (all or part of it). `git show \(by.prefix(8))` shows what it undid; a fix-forward task (add_task) handles anything left.")
        }
        try checkBattery(not: "Not reverted")
        guard let lock = FileLock.attempt((store.folder as NSString).appendingPathComponent("run/merge-\(slug).lock")) else {
            throw Problem(text: "A merge or revert of \(slug) is already running; its result comes back to the call that started it.")
        }
        defer { lock.release() }
        let workflow = self.workflow
        try checkSettings(workflow, not: "Not reverted (nothing was tested)")
        let base = workflow.base
        // One move of the branch at a time, merges and reverts alike: each checks the head the other one moves.
        let baseLock = vault.scratch(root: root, "merge-into-\(LeadVault.hash(base).prefix(16)).lock")
        try vault.ensurePrivate(baseLock.deletingLastPathComponent())
        guard let held = FileLock.attempt(baseLock.path) else {
            throw Problem(text: "A merge or revert into \(base) is running; revert \(slug) when it's done.")
        }
        defer { held.release() }
        guard let current = branchHead(base) else { throw Problem(text: "There's no branch \(base) to revert on.") }
        try checkBaseMoves(base: base, current: current)
        if let lock = Worktrees.indexLock(blocking: base, root: root) {
            throw Problem(text: "Not reverted (nothing was tested): \(Worktrees.refusal(lock))")
        }
        let range = "\(onto)..\(merged.commit)"
        let listed = Git.run(["rev-list", range], in: root)
        let commits = listed.output.split(whereSeparator: \.isNewline).map(String.init)
        guard listed.ok, !commits.isEmpty else {
            throw Problem(text: "Not reverted: the commits \(slug)'s merge brought (\(onto.prefix(8))..\(merged.commit.prefix(8))) can't be listed: \(Worktrees.said(listed))")
        }
        let waited = try waitForLoad(workflow, slug: slug, doing: "revert", done: "reverted")
        // `LeadReverts` reads the hashes from the message, as git's own revert writes them.
        let message = "Revert \(slug): \(Self.clip(task.title, 60))\n\n\(reason)\n\n"
            + commits.map { "This reverts commit \($0)." }.joined(separator: "\n")
        let made: String
        switch Worktrees.revertAndTest(root: root, onto: onto, commit: merged.commit, base: current, message: message,
                                       setup: workflow.initCommand, test: workflow.mergeChecks,
                                       scratch: vault.scratch(root: root, "revert-\(slug)"), home: vault.scratch(root: root, "revert-\(slug)-home"),
                                       timeout: workflow.testTimeout, lock: heavyLock(workflow)) {
        case .passed(let commit): made = commit
        case .conflict(let files):
            let shown = laterTouches(files.prefix(12).map { $0 }, slug: slug, after: merged.commit, current: current)
            throw Problem(text: "Not reverted: reverting \(slug) conflicts with what \(base) did since it merged, in \(files.count) file\(files.count == 1 ? "" : "s"): "
                          + shown.joined(separator: "; ") + (files.count > 12 ? "; …" : "") + ". \(base) is as it was, and \(slug) stays merged. "
                          + "Undoing it would mean undoing those too: plan a fix-forward task instead (add_task), saying what \(slug) broke (\(Self.clip(reason, 120))).")
        case .failed(let output):
            let saved = saveMergeLog(output, slug: slug, name: "revert-test.log")
            let found = TestFailures(output: output).summary()
                ?? "Nothing in the output names a failing test or an error; it ends:\n" + String(output.suffix(1500))
            let which = output.hasPrefix("init_command failed:\n") ? "init_command" : "test command"
            throw Problem(text: "Not reverted: the \(which) fails with \(slug) reverted on \(base). \(base) is as it was, and \(slug) stays merged.\n\(found)\n"
                          + (saved.map { "Full output: \($0)" } ?? "(The full output couldn't be saved.)")
                          + "\nIf the tests fail without the change too, fix forward (add_task); if they only fail reverted, its later work depends on it.")
        case .hung(let command, let after, let output):
            let saved = saveMergeLog(output, slug: slug, name: "revert-test.log")
            throw Problem(text: "Not reverted: the \(command) hung after \(Worktrees.duration(after)) with \(slug) reverted on \(base), and was stopped with everything started under it. \(base) is as it was. "
                          + (saved.map { "The output so far: \($0)." } ?? "(The output couldn't be saved.)"))
        case .cancelled:
            throw Problem(text: "The revert of \(slug) was cancelled; \(base) is as it was, and \(slug) stays merged.")
        case .error(let text):
            throw Problem(text: "Not reverted: \(text) \(base) is as it was.")
        }
        if ShellCancel.current?.isCancelled == true {
            throw Problem(text: "The revert of \(slug) was cancelled after its checks passed; \(base) is as it was, and \(slug) stays merged.")
        }
        switch ShellCancel.with(nil, { Worktrees.fastForward(root: root, base: base, to: made, from: current) }) {
        case .merged:
            try vault.setHead(made, root: root, branch: base)
            let now = Date().timeIntervalSince1970
            try store.update { board in
                guard let index = store.restore(slug, into: &board) else { return }
                board.tasks[index].status = .reverted
                board.tasks[index].merged?.revertedBy = made
                board.tasks[index].merged?.revertedAt = now
                board.tasks[index].merged?.revertReason = reason
            }
            try? store.appendProgress("Reverted \(slug): \(task.title), by \(made.prefix(8)) (\(Self.clip(reason, 200)))")
            let untested = workflow.testCommand == nil
                ? " (reverted without tests: no test_command\(workflow.problem.map { "; \($0)" } ?? ""). Set one with configure.)" : " The test command passed on it."
            let patience = waited.map { " (The tests waited \(Worktrees.duration($0.after)) for the Mac's load to drop from \(MacLoad.number($0.from)) below load_threshold.)" } ?? ""
            let caughtUp = tellToCatchUp(merged: "the revert of \(slug)", from: current, to: made, base: base)
            return MCPToolResult(text: "Reverted \(slug) on \(base): one commit, \(made.prefix(8)) “Revert \(slug)”, undoes the \(commits.count) commit\(commits.count == 1 ? "" : "s") its merge brought (\(onto.prefix(8))..\(merged.commit.prefix(8))).\(untested) \(slug) reads reverted. "
                                 + "Next: post_update what was undone and why (the user installs as usual), and record_incident(what, evidence, task: \(slug)) so what broke becomes a check before merge. "
                                 + "If its work is still wanted, plan a new task (add_task) that does it again without what broke.\(patience)\(caughtUp)")
        case .refused(let why):
            throw Problem(text: "Not reverted: \(why) The revert commit wasn't put on \(base); \(slug) stays merged.")
        }
    }

    /// For each of `files` (a revert's conflicts), who changed it on the base after `slug`'s merge (`after`) up to
    /// `current`: the later tasks whose merged ranges (`merged.onto..merged.commit`) hold such a commit, and the
    /// commits no task's range holds (the user's own), by hash and subject.
    private func laterTouches(_ files: [String], slug: String, after: String, current: String) -> [String] {
        let lines = { (output: String) in output.split(whereSeparator: \.isNewline).map(String.init) }
        var owner: [String: String] = [:]
        for task in store.loadAll().tasks where task.slug != slug {
            guard let merged = task.merged, let onto = merged.onto else { continue }
            let listed = Git.run(["rev-list", "\(onto)..\(merged.commit)"], in: root)
            guard listed.ok else { continue }
            for commit in lines(listed.output) { owner[commit] = task.slug }
        }
        return files.map { file in
            let log = Git.run(["log", "--format=%H%x1f%s", "\(after)..\(current)", "--", file], in: root)
            var tasks: [String] = [], others: [String] = []
            for entry in lines(log.output) {
                let parts = entry.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                if let task = owner[parts[0]] {
                    if !tasks.contains(task) { tasks.append(task) }
                } else {
                    others.append("\(parts[0].prefix(8)) “\(Self.clip(parts.count > 1 ? parts[1] : "", 60))”")
                }
            }
            var who: [String] = []
            if !tasks.isEmpty { who.append((tasks.count == 1 ? "task " : "tasks ") + tasks.joined(separator: ", ")) }
            if !others.isEmpty {
                who.append((others.count == 1 ? "commit " : "commits ") + others.prefix(3).joined(separator: ", ") + (others.count > 3 ? ", …" : ""))
            }
            return file + (who.isEmpty ? " (no later commit changed it)" : " (changed since by " + who.joined(separator: " and ") + ")")
        }
    }

    /// After `merged`'s merge moved `base` from `old` to `new`: each running task whose branch changes a file the merge
    /// changed too gets one message to its worker to merge `base` now, naming the files, while the conflict is still
    /// small (2026-10-25: 21 merge conflicts cost 40.7 task-hours, most found only at merge). Branches that overlap no
    /// file get nothing; the lead's records count in neither. What the lead's result says about it ("" for nothing).
    private func tellToCatchUp(merged: String, from old: String, to new: String, base: String) -> String {
        let records = Set(workflow.recordsDir.map(LeadRecords.paths) ?? [])
        let lines = { (output: String) in output.split(whereSeparator: \.isNewline).map(String.init) }
        let moved = Git.run(["diff", "--name-only", old, new], in: root)
        let changed = Set(moved.ok ? lines(moved.output) : []).subtracting(records)
        guard !changed.isEmpty else { return "" }
        var told: [String] = []
        for task in store.load().tasks where task.status == .running && task.slug != merged {
            // What the branch changes since it last took the base in.
            let diff = Git.run(["diff", "--name-only", "\(new)...\(Worktrees.branch(task.slug))"], in: root)
            guard diff.ok else { continue }
            let files = lines(diff.output).filter(changed.contains).sorted()
            guard !files.isEmpty else { continue }
            let said = tellWorker(task, LeadDelivery.catchUp(base: base, merged: merged, files: files))
            told.append("\(task.slug) (\(files.prefix(4).joined(separator: ", "))\(files.count > 4 ? ", …" : "")): \(said)")
        }
        return told.isEmpty ? "" : " \(merged) changed files that running branches change too, so their workers were told to merge \(base) now: " + told.joined(separator: " ")
    }

    /// Why `slug`'s merge needs a passing audit, in a sentence; nil when it doesn't: review none on the board and in
    /// the vault (only the lead lowers it there), no audit started on it (once one is, its verdict decides), and its
    /// branch at `commit` touches nothing in sensitive_paths (always audited, whatever its review says).
    /// Past those, the risk check (see `LeadRisk`): its deterministic triggers on what the branch changes, then, with
    /// `model` (merge, and auto_advance's step to it, in the lead's server), headless Claude's word. A raise is the
    /// vault's review audit from then on (`raiseReview`), never lowered by it.
    private func reviewNeeded(_ slug: String, commit: String?, model: Bool = false) -> String? {
        let task = store.load().task(slug)
        let level = task?.reviewLevel ?? .none
        let kept: LeadVault.Unaudited
        do { kept = try vault.unaudited(root: root, task: slug) } catch {
            return "Its review level can't be read from the vault (\(error)), so it's audited."
        }
        if level.atLeast(kept.review) == .audit {
            return "Its review is audit." + (task?.riskRaised.map { " (audited: \($0.reason), as the risk check found.)" } ?? "")
        }
        if vault.current(.verifier, root: root, task: slug) != nil { return "An audit was started on it: its verdict decides." }
        guard let commit else { return "Its branch \(Worktrees.branch(slug)) isn't there." }
        let workflow = self.workflow
        let diff = Git.run(["diff", "--name-only", "\(workflow.base)...\(commit)"], in: root)
        guard diff.ok else { return "Which files it changes can't be told (\(diff.error)), so it's audited." }
        let sensitive = diff.output.split(whereSeparator: \.isNewline).map(String.init).filter { path in
            workflow.sensitiveGlobs.contains { LeadWorkflow.matches(path, glob: $0) }
        }
        guard sensitive.isEmpty else {
            return "It touches sensitive_paths (" + sensitive.prefix(8).joined(separator: ", ") + (sensitive.count > 8 ? ", …" : "")
                + "), so it's treated as audit whatever its review says."
        }
        // Only the commit its worker reported done on: one committed since isn't finished work yet (merge refuses it
        // for that), and a raise or a model's answer on it would be on work nobody said is done.
        guard kept.reported == commit else { return nil }
        return riskRaise(task, commit: commit, workflow: workflow, model: model)
    }

    /// What `LeadRisk` says of `task`'s branch at `commit`, as reviewNeeded's sentence; nil: it stays review none. The
    /// model pass runs only when nothing deterministic raised it, once per commit, and its keep, error or timeout leave
    /// the deterministic result. Only the stat, the contract and the base branch's REVIEW.md go to it.
    private func riskRaise(_ task: LeadTask?, commit: String, workflow: LeadWorkflow, model: Bool) -> String? {
        guard let task else { return nil }
        let range = "\(workflow.base)...\(commit)"
        let numstat = Git.run(["diff", "--numstat", "--no-color", range], in: root)
        guard numstat.ok else { return "What its branch changes can't be read for the risk check (\(numstat.error)), so it's audited." }
        var reason = LeadRisk.deterministic(changes: LeadRisk.changes(numstat: numstat.output), patch: {
            let patch = Git.run(["diff", "-U0", "--no-color", range], in: root)
            return patch.ok ? patch.output : nil
        }, workflow: workflow)
        var byModel = false
        if reason == nil, model, workflow.riskModel, let ask = riskModel {
            let key = "\(task.slug)@\(commit)"
            riskLock.lock()
            let asked = riskAnswers[key]
            riskLock.unlock()
            let answer: String?
            if let asked {
                answer = asked
            } else {
                let stat = Git.run(["diff", "--stat", "--no-color", range], in: root)
                let prompt = LeadRisk.prompt(stat: stat.ok ? stat.output : "(the stat can't be read)", contract: WorkerBrief.render(task),
                                             guide: LeadRisk.reviewGuide(root: root, base: workflow.base))
                if case .raise(let why)? = LeadRisk.parse(ask(prompt)) { answer = why } else { answer = nil }
                riskLock.lock()
                riskAnswers[key] = .some(answer)
                riskLock.unlock()
            }
            if let answer {
                reason = "headless Claude said raise: \(answer)"
                byModel = true
            }
        }
        guard let reason else { return nil }
        if role == .lead { raiseReview(task.slug, LeadRiskRaise(reason: reason, commit: commit, byModel: byModel)) }
        return "The risk check raised it to audit: \(reason)."
    }

    /// Records the risk check's raise: the vault's review audit (what merge goes by, which only the lead lowers), the
    /// board's level and why (for showing), and a line in the progress log, once.
    private func raiseReview(_ slug: String, _ raise: LeadRiskRaise) {
        try? vault.setReview(.audit, root: root, task: slug)
        var first = false
        try? store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].review = .audit
            if board.tasks[index].riskRaised == nil {
                board.tasks[index].riskRaised = raise
                first = true
            }
        }
        if first { try? store.appendProgress("Raised \(slug) to audit (the risk check, at \(raise.commit.prefix(8))): \(raise.reason)") }
    }

    /// The commit a review none task merges at: its branch's head, as long as its own worker reported done on it (as
    /// the vault has it) and there's a test command to run on it (without one, nothing would check it).
    private func unauditedCommit(_ slug: String, head: String?) throws -> String {
        let workflow = self.workflow
        guard workflow.testCommand != nil else {
            throw Problem(text: "Not merged: \(slug) has no passing audit, and with no test_command a review none task would merge with nothing checking it. Set test_command with configure, or audit it.")
        }
        let reported: String?
        do { reported = try vault.unaudited(root: root, task: slug).reported } catch {
            throw Problem(text: "Not merged: whether \(slug)'s worker reported done can't be read from the vault (\(error)).")
        }
        guard let head, reported == head else {
            let said = reported.map { "it reported done on \($0.prefix(8))" } ?? "its last report wasn't done, or it sent none"
            throw Problem(text: "Not merged: \(slug) has no passing audit, and a review none task merges without one only on its worker's done report on \(Worktrees.branch(slug))'s head"
                + " (\(head.map { String($0.prefix(8)) } ?? "not there")), and \(said). Have the worker commit and report done, or audit it.")
        }
        return head
    }

    /// The owner's merge policy (workflow.md's merge_policy): a commit it holds back waits for the user's answer
    /// approving that exact commit for this task, as the app recorded it in the vault when they answered (the board's
    /// copy of the answer is for showing: the team can write board.json).
    private func checkMergePolicy(_ task: LeadTask, commit: String) throws {
        let workflow = self.workflow
        // The policy as the lead set it, not as a worker rewrote it.
        try checkSettings(workflow, not: "Not merged")
        guard workflow.mergePolicy != .auto else { return }
        let diff = Git.run(["diff", "--name-only", "\(workflow.base)...\(commit)"], in: root)
        guard diff.ok else { throw Problem(text: "Not merged: can't tell which files \(task.slug) changes (\(diff.error)), so the merge policy can't be checked.") }
        let changed = diff.output.split(whereSeparator: \.isNewline).map(String.init)
        guard let files = workflow.filesNeedingApproval(changed) else { return }
        let approved: Bool
        do { approved = try vault.approved(root: root, task: task.slug, commit: commit) } catch {
            throw Problem(text: "Not merged: the vault can't say whether the user approved \(task.slug) at \(commit.prefix(8)) (\(error)).")
        }
        if approved { return }
        // An approval only the board shows wasn't given in the app: it doesn't count.
        let boardOnly = store.load().questions.contains { LeadWorkflow.approves($0, commit: commit) }
            ? " The board shows an approval of \(commit.prefix(8)), but the user gave none in VibeSwitcher for \(task.slug): only their answer there counts." : ""
        let policy = workflow.mergePolicy?.rawValue ?? "ask_sensitive (no merge_policy is set yet: ask the owner once which one they want, then set it with configure)"
        let touches = files.isEmpty ? "" : " It touches " + files.prefix(8).joined(separator: ", ") + (files.count > 8 ? ", …" : "") + "."
        throw Problem(text: "Not merged yet: the merge policy is \(policy), so the user approves \(task.slug) at \(commit.prefix(8)) first.\(touches) "
            + "Ask once: ask_user(question: \"Merge \(task.slug) (\(task.title)) at \(commit.prefix(8))? …what it changes and the risk…\", "
            + "options: [\"\(LeadWorkflow.approval(of: commit))\", \"Not yet\"], priority: blocking, task: \"\(task.slug)\"), with no timer, and merge again when they approve. "
            + "The approval covers this commit only: a new commit needs a new one.\(boardOnly)")
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
        // The test command passed and the incidents' checks ran after it.
        let regression = !setup && output.components(separatedBy: "\n").contains(LeadWorkflow.regressionMarker)
        let which = setup ? "init_command" : regression ? "regression_command (the checks incidents became; test_command passed)" : "test command"
        // A rerun (`MergeRerun`) failed too: its output is what's told.
        let again = output.hasPrefix(Worktrees.rerunHeader) ? ", and again on its rerun (run once, after the first run failed)" : ""
        return "The \(which) fails on \(slug) rebased onto \(base)\(again).\n\(found)\n\(touched)"
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

    /// Writes a merge's flake evidence to `MergeRerun.evidenceFile` (0600, in a 0700 folder in the repository's
    /// ignored `.vibeswitcher/`); its path relative to the root, as the ledger keeps it, or nil when it couldn't be
    /// written (the merge's log in the vault keeps them).
    private func saveFlakeEvidence(_ evidence: [String: [String]], tests: [String], slug: String, commit: String, at date: Date) -> String? {
        saveEvidence(MergeRerun.evidenceLog(task: slug, commit: commit, evidence: evidence, tests: tests),
                     log: MergeRerun.evidencePath(task: slug, commit: commit, at: date))
    }

    /// Writes `text` to `log` (relative to the root, in `.vibeswitcher/flakes/`), 0600 in a 0700 folder; `log`, or nil
    /// when it couldn't be written.
    private func saveEvidence(_ text: String, log: String) -> String? {
        let file = URL(fileURLWithPath: MergeRerun.evidenceFile(root: root, log: log))
        guard (try? VibePaths.ensurePrivate(file.deletingLastPathComponent(), within: URL(fileURLWithPath: store.folder))) != nil,
              (try? VibePaths.writePrivate(Data(text.utf8), to: file)) != nil else { return nil }
        return log
    }

    /// Saves a merge's test output where the lead can read it; its path, or nil when it couldn't be saved.
    private func saveMergeLog(_ output: String, slug: String, name: String = "merge-test.log") -> String? {
        let log = vault.scratch(root: root, "\(slug)/\(name)")
        return (try? vault.ensurePrivate(log.deletingLastPathComponent())).flatMap {
            (try? Data(output.utf8).write(to: log, options: .atomic)).map { log.path }
        }
    }

    private func cleanup(_ slug: String, force: Bool) throws -> MCPToolResult {
        let board = store.load()
        guard let task = board.task(slug) else { throw Problem(text: "No task \(slug).") }
        // Folded (another task carries its work) or abandoned by the lead: it goes without force.
        guard [.done, .folded, .abandoned, .reverted].contains(task.status) || force else {
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
        // One the host didn't end, cleanup ends itself: its processes, the user's carrying its session's id.
        let endings = try endItself(try end(sessions, refused: refused), refused: refused)
        // Not under a session that's still writing there (its next write would leave a stray folder behind).
        let failed = endings.filter { $0.failure != nil }
        guard failed.isEmpty else {
            throw Problem(text: "Not cleaned up: \(failed.map(\.said).joined(separator: "; ")). Its worktree stays while a session may still write there. If the host refuses, tell the user (they can end it in VibeSwitcher), then cleanup again.")
        }
        // Its sessions' temporary folders and TMPDIRs, found by the worktree's path while it's still there to resolve.
        let worktree = Worktrees.path(root: root, slug: slug)
        let temporary = ClaudeScratch.folders(for: worktree, in: scratchRoot) + SessionTemp.folders(for: worktree, in: sessionTempRoot)
        // Merged work is in main; leftovers in the worktree (build output) can go. Abandoned work goes only on request.
        // The build folder goes first and whatever git makes of the rest: it's most of the space.
        var freed = removeFolder((worktree as NSString).appendingPathComponent(".build"))
        // Its audits' shared build and test logs.
        freed += removeFolder((store.folder as NSString).appendingPathComponent("audit/\(slug)"))
        if FileManager.default.fileExists(atPath: worktree) || branchHead(Worktrees.branch(slug)) != nil {
            try Worktrees.remove(root: root, slug: slug, force: true)
        }
        freed += temporary.reduce(0) { $0 + removeFolder($1.path) }
        freed += sweepFinished(board, except: slug)
        try? vault.retire(root: root, task: slug)
        // Cleaned up unmerged after a worker ran: abandoned, as the board reads it, so it gets its receipt.
        let usage = [.done, .folded, .abandoned, .reverted].contains(task.status) || task.isAbandoned ? nil : receiptUsage(task)
        let after = try store.update { board -> LeadTask? in
            guard let index = board.taskIndex(slug) else { return nil }
            board.tasks[index].worktree = nil
            if ![.done, .folded, .abandoned, .reverted].contains(board.tasks[index].status) { board.tasks[index].status = .failed }
            if let usage, board.tasks[index].isAbandoned {
                board.tasks[index].receipt = LeadReceipt(board.tasks[index], ending: .abandoned, questions: board.questions, usage: usage)
            }
            return board.tasks[index]
        }
        // Its workers and verifiers, this one and any before it, are history now: off the session list.
        for session in (try? listed()) ?? [] where !session.live && Self.isTeamSession(session, in: folder) {
            runtime.forget(session.id)
        }
        let ended = endings.isEmpty ? "" : "; " + endings.map(\.said).joined(separator: ", ")
        return MCPToolResult(text: "Cleaned up \(slug)" + ended + (freed > 0 ? " (freed \(DiskSpace.text(freed)) of build output and temporary folders)." : ".")
                             + (after.map { " " + Self.cleanedState(before: task, after: $0) } ?? ""))
    }

    /// A task's state as status and the board say it: folded, abandoned (`LeadTask.isAbandoned`), or its status.
    static func shownState(_ task: LeadTask) -> String {
        task.status == .folded ? "folded" : task.isAbandoned ? "abandoned" : task.status.rawValue
    }

    /// What cleanup left the task as, the way status and the board show it: "It stays done.", "It was failed: now
    /// abandoned.". A failed task that never had a worker stays failed there, which is said with what to do.
    static func cleanedState(before: LeadTask, after: LeadTask) -> String {
        let was = shownState(before), now = shownState(after)
        let state = was == now ? "It stays \(now)." : "It was \(was): now \(now)."
        guard now == LeadTask.Status.failed.rawValue else { return state }
        return state + " It never had a worker, so status and the board count it as failed, not abandoned: update_task it to abandoned with a reason if nothing will carry it."
    }

    /// Ends itself each session `endings` says the host didn't end: SIGTERM to its processes (`sessionProcesses`: the
    /// user's carrying its `VIBESWITCHER_SESSION` id, its agent among them), SIGKILL to those still running after
    /// `stopWait` (5 s at most), then waits as long again for the host to see it gone. What still runs is named, by pid
    /// and command, with the host's answer.
    private func endItself(_ endings: [Ending], refused: String) throws -> [Ending] {
        guard endings.contains(where: { $0.failure != nil }) else { return endings }
        let grace = min(5, stopWait)
        var found: [String: [SessionStrays.Found]] = [:]
        for ending in endings where ending.failure != nil {
            let processes = sessionProcesses(ending.session.id)
            processes.forEach { Darwin.kill($0.pid, SIGTERM) }
            found[ending.session.id] = processes
        }
        var running = found.values.joined().filter(SessionStrays.isRunning)
        let killAt = Date().addingTimeInterval(grace)
        while !running.isEmpty, Date() < killAt {
            usleep(50_000)
            running = running.filter(SessionStrays.isRunning)
        }
        running.forEach { Darwin.kill($0.pid, SIGKILL) }
        // The host sees the session end once its agent's process is gone.
        let ids = Set(found.filter { !$0.value.isEmpty }.keys)
        var live = ids
        let deadline = Date().addingTimeInterval(stopWait)
        while !live.isEmpty {
            live.formIntersection(try hostSessions(refused).filter(\.live).map(\.id))
            guard !live.isEmpty, Date() < deadline else { break }
            usleep(200_000)
        }
        return endings.map { ending in
            guard let failure = ending.failure else { return ending }
            let processes = found[ending.session.id] ?? []
            if ids.contains(ending.session.id), !live.contains(ending.session.id) {
                return Ending(session: ending.session, failure: nil,
                              itself: "itself, after the host didn't (\(failure)): \(processes.count) process\(processes.count == 1 ? "" : "es") carrying its session's id")
            }
            // What still runs of it: its agent, and those of its processes that outlived the signals.
            let pids = ([ending.session.pid].compactMap { $0 }.filter { Darwin.kill($0, 0) == 0 }
                        + processes.filter(SessionStrays.isRunning).map(\.pid))
            let remaining = pids.reduce(into: [Int32]()) { if !$0.contains($1) { $0.append($1) } }
            let named = remaining.isEmpty ? "" : "; still running: " + remaining.prefix(8).map { "pid \($0) (\(Self.command(of: $0)))" }.joined(separator: ", ")
                + (remaining.count > 8 ? ", and \(remaining.count - 8) more" : "")
            let none = processes.isEmpty ? "; no process carries its session's id, so cleanup ended none itself" : ""
            return Ending(session: ending.session, failure: failure + none + named)
        }
    }

    /// A process's command line, cut short ("node server.js"); its name from the kernel when that can't be read.
    static func command(of pid: Int32) -> String {
        let line = ProcessTable.commandLine(pid: pid).joined(separator: " ")
        let command = line.isEmpty ? ProcessTable.info(pid: pid)?.comm ?? "?" : line
        return command.count > 80 ? String(command.prefix(79)) + "…" : command
    }

    /// The task's worker or verifier that never got its tools (its tool server never asked the host who it is), in a
    /// sentence that comes first in start_worker's or audit's reply, before another is started: "" when none, or the
    /// roster can't be read. One that ended before `LeadWitness.toolsWithin` without them counts too.
    private func noToolsBefore(_ task: LeadTask, _ role: LeadLaunch.Role, sessions: [LeadSessionInfo]) -> String {
        let mine = role == .worker ? [task.worker].compactMap { $0 } : (task.panel?.sessions ?? []) + [task.verifier].compactMap { $0 }
        guard !mine.isEmpty, let roster = try? vault.roster(root: root) else { return "" }
        let now = Date()
        let live = Set(sessions.filter(\.live).map(\.id))
        let dead = roster.filter { entry in
            // Not one the lead stopped (it may have, before its tools had a moment to connect).
            guard entry.holds, entry.role == role, mine.contains(entry.session), entry.session != task.stopped, let bound = entry.boundAt else { return false }
            return LeadWitness.neverGotTools(boundAt: bound, toolsAt: entry.toolsAt, submittedAt: entry.submittedAt, now: now)
                || (!live.contains(entry.session) && entry.toolsAt == nil && entry.submittedAt == nil)
        }
        guard !dead.isEmpty else { return "" }
        let which = dead.map { entry in "session \(entry.session.prefix(8)), started \(LeadBoard.clock(entry.boundAt ?? 0))" }.joined(separator: "; ")
        let who = role == .worker ? "worker" : dead.count == 1 ? "verifier" : "verifiers"
        let lost = role == .worker ? "no report could come from it" : "no verdict could come from \(dead.count == 1 ? "it" : "them")"
        return "The earlier \(who) on \(task.slug) (\(which)) never got \(dead.count == 1 ? "its" : "their") tools: its vibeswitcher tool server never answered, so \(lost). "
            + "If this one doesn't get them either, tell the user (the session host or the tool server is broken) instead of starting more. "
    }

    /// A worker's or verifier's session in the worktree `folder` (standardized).
    private static func isTeamSession(_ session: LeadSessionInfo, in folder: String) -> Bool {
        (session.cwd as NSString).standardizingPath == folder && [.worker, .verifier].contains(LeadTeams.role(label: session.label))
    }

    /// The Mac's load and every project's team sessions, against the Mac-wide limits, in one line, naming only the
    /// project `root` (see `MacLoad.sessionsText(for:)`: refusals and merge replies go into the repo's records).
    private static func macText(_ mac: MacLoad, _ limits: MacLimits, root: String) -> String {
        "load \(mac.loadText) (load_threshold \(limits.loadLimitText)), \(mac.sessionsText(for: root)) (mac_max_sessions \(limits.maxSessions))"
    }

    /// Why no worker or verifier may start now on the Mac as `mac` has it (`not`: what didn't happen); nil when one may.
    /// With `what`, a refusal is kept (see `LeadWitness.RoomWaits`) so this lead is woken once there's room for `need`
    /// more sessions. The limits are the user's, Mac-wide: the text never suggests changing them.
    private func macRefusal(_ mac: MacLoad, not: String, what: String? = nil, need: Int = 1) -> String? {
        let limits = macLimits()
        var over: [String] = []
        if mac.isBusy(threshold: limits.loadLimit) { over.append("its load (the greater of its 1- and 5-minute averages) is above load_threshold") }
        if mac.isFull(max: limits.maxSessions) { over.append("the team sessions of all its projects are at mac_max_sessions") }
        guard !over.isEmpty else { return nil }
        if let what { roomWaits.record(root: root, what: what, need: need, auto: LeadAdvance.isAutomatic) }
        return "\(not): the Mac is shared by every project's team, and \(over.joined(separator: " and ")). Now: \(Self.macText(mac, limits, root: root)). "
            + (what == nil ? "" : "VibeSwitcher sends you one message once there's room again. ") + LeadPrompts.retryWhenWoken + " "
            + "Meanwhile merge and cleanup finished tasks (cleanup ends their sessions), plan, or answer the user."
    }

    /// The battery hold, as start_worker, audit and merge keep it (auto_advance's loop keeps it too, see `LeadAdvance`):
    /// nothing starts, audits or merges while the witness's hold under the user's limit lasts (see `PowerWatch`). The
    /// lead used to keep it by hand from the witness's messages (decisions 2026-10-19 15:50, 2026-10-20 22:12): two
    /// verifiers and a merge's test run died in the Mac's sleeps on 2026-10-19 at 2 %. `not`: what didn't happen.
    private func checkBattery(not: String) throws {
        guard let power = power(), power.onBattery, let limit = power.heldUnder else { return }
        throw Problem(text: "\(not): the Mac is on battery at \(power.percent) %, under the user's \(limit) % limit (Settings › Project lead), "
            + "so nothing starts, audits or merges until AC power returns or the limit is lowered; work in flight finishes. "
            + "The witness tells you when to resume. " + LeadPrompts.retryWhenWoken)
    }

    /// Waits while the Mac's load (`steadyLoad`) is above load_threshold, reading it every `loadPoll`, for at most
    /// test_timeout_min; nil when it didn't wait, else how long and from what load. Throws, with the numbers, when the
    /// load didn't drop in time (nothing was tested).
    /// `doing` and `done`: what waits ("merge", "merged"; a revert's say so).
    private func waitForLoad(_ workflow: LeadWorkflow, slug: String, doing: String = "merge", done: String = "merged") throws -> (after: TimeInterval, from: Double)? {
        let start = Date()
        let deadline = start.addingTimeInterval(workflow.testTimeout)
        let limits = macLimits()
        guard let first = runtime.steadyLoad(), first > limits.loadLimit else { return nil }
        var load: Double? = first
        let progress = ToolProgress.current
        var told: Date?
        while let current = load, current > limits.loadLimit {
            if let progress, told.map({ Date().timeIntervalSince($0) >= progress.every }) ?? true {
                told = Date()
                progress.send("Waiting \(Worktrees.duration(Date().timeIntervalSince(start))) for the Mac's load (\(MacLoad.number(current)), the greater of its 1- and 5-minute averages) to drop below load_threshold (\(MacLoad.number(limits.loadLimit))) before testing \(slug).")
            }
            if ShellCancel.current?.isCancelled == true {
                throw Problem(text: "The \(doing) of \(slug) was cancelled while it waited for the Mac's load to drop; nothing was \(done), and \(slug) stays as it was.")
            }
            guard Date() < deadline else {
                let listing = (try? listed()) ?? []
                let mac = (try? macLoad(listing, load: current)) ?? MacLoad.count(listing.map { ($0.label, $0.cwd, $0.live) }, load: current)
                roomWaits.record(root: root, what: "\(doing)(\(slug))", need: 0, auto: LeadAdvance.isAutomatic)
                throw Problem(text: "Not \(done) (nothing was tested): the Mac's load (the greater of its 1- and 5-minute averages) stayed above load_threshold for the \(Worktrees.duration(workflow.testTimeout)) \(doing) waits (test_timeout_min). Now: \(Self.macText(mac, limits, root: root)). "
                              + "Timing-sensitive tests fail on a Mac this busy, so \(slug) wasn't tested and stays as it was. \(LeadPrompts.retryWhenWoken) Meanwhile start no workers or audits (they'd add to the load), and tell the user if it stays this busy.")
            }
            Thread.sleep(forTimeInterval: min(loadPoll, progress?.every ?? loadPoll, max(0, deadline.timeIntervalSinceNow)))
            load = runtime.steadyLoad()
        }
        return (Date().timeIntervalSince(start), first)
    }

    /// What became of a session asked to end: `failure` nil when its process is gone.
    struct Ending {
        let session: LeadSessionInfo
        let failure: String?
        /// Ended by cleanup itself after the host didn't: how (see `endItself`).
        var itself: String? = nil

        /// "ended pid N (label)", "ended pid N (label) itself, after the host didn't (…): …", or "couldn't end pid N
        /// (label): why".
        var said: String {
            let which = session.pid.map { "pid \($0)" } ?? "session \(session.id.prefix(8))"
            return failure.map { "couldn't end \(which) (\(session.label)): \($0)" }
                ?? "ended \(which) (\(session.label))" + (itself.map { " \($0)" } ?? "")
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

    /// The temporary folders and TMPDIRs other finished tasks left behind (cleaned up before cleanup removed them): only a task
    /// merged or abandoned whose worktree is gone, with no session running there.
    private func sweepFinished(_ board: LeadBoard, except slug: String) -> Int64 {
        // Which folders sessions still run in isn't known: nothing goes.
        guard let sessions = try? listed() else { return 0 }
        let live = Set(sessions.filter(\.live).map { ($0.cwd as NSString).standardizingPath })
        var freed: Int64 = 0
        for task in board.tasks where task.slug != slug && task.worktree == nil && [.done, .failed, .folded, .abandoned, .reverted].contains(task.status) {
            let worktree = Worktrees.path(root: root, slug: task.slug)
            guard !FileManager.default.fileExists(atPath: worktree), !live.contains((worktree as NSString).standardizingPath) else { continue }
            freed += (ClaudeScratch.folders(for: worktree, in: scratchRoot) + SessionTemp.folders(for: worktree, in: sessionTempRoot))
                .reduce(0) { $0 + removeFolder($1.path) }
        }
        return freed
    }

    /// Where the worktrees go (the volume they fill).
    var worktreesFolder: String { (root as NSString).appendingPathComponent(".vibeswitcher/worktrees") }

    /// 10 → "10", 2.5 → "2.5".
    static func gb(_ value: Double) -> String { String(format: "%g", value) }

    /// Low disk space, with what takes it (status says it while it lasts; the witness tells it once).
    /// `sessions`: every project's listed sessions, to name the big TMPDIRs by.
    func diskWarning(_ workflow: LeadWorkflow, board: LeadBoard, sessions: [LeadSessionInfo]? = nil) -> [String] {
        guard let free = freeSpace(worktreesFolder), free < workflow.diskWarning else { return [] }
        return [LeadWitness.diskText(free: free, workflow: workflow, folders: TaskFolder.all(root: root, board: board, scratch: scratchRoot,
                                                                                                 sessions: sessionTempRoot),
                                     tmpdirs: SessionTemp.big(cwds: (sessions ?? []).map(\.cwd), in: sessionTempRoot))]
    }

    private func askUser(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let question = arguments["question"] as? String, !question.isEmpty else { throw Problem(text: "Ask something.") }
        let priority = try self.priority(arguments["priority"])
        let whyNow = (arguments["why_now"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let options = strings(arguments["options"])
        var proposal = (arguments["proposal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if proposal?.isEmpty == true { proposal = nil }
        let decideIn = try minutes(arguments["decide_in"])
        var about: String?
        if let wanted = (arguments["task"] as? String)?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty {
            guard let task = store.loadAll().task(wanted) else { throw Problem(text: "No task \(wanted) on the board: name the task the question is about by its slug, or leave task out.") }
            about = task.slug
        }
        if decideIn != nil, proposal == nil { throw Problem(text: "decide_in needs a proposal: the answer you'd go ahead with.") }
        if let given = proposal {
            if let refusal = LeadQuestion.timerRefusal(text: question, options: options, whyNow: whyNow, priority: priority) { throw Problem(text: refusal) }
            guard let option = options.first(where: { $0.caseInsensitiveCompare(given) == .orderedSame }) else {
                throw Problem(text: "The proposal must be one of the options (\(options.isEmpty ? "there are none" : options.joined(separator: " | "))).")
            }
            proposal = option
        }
        let asked = try store.update { board in
            board.ask(question, options: options, priority: priority, whyNow: whyNow, proposal: proposal, decideIn: decideIn, task: about)
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

    /// The Mac as its limits count it: every project's team from the host's census (`HostCensus`), `sessions` (what
    /// the host lists this lead, its own team) only for the task worktree `except` leaves out; `sessions` alone from a
    /// host that doesn't count. Throws when the census can't be read: counted from its own team, a lead would start
    /// past mac_max_sessions.
    func macLoad(_ sessions: [LeadSessionInfo], load: Double?, except folder: String? = nil) throws -> MacLoad {
        let listed = sessions.map { ($0.label, $0.cwd, $0.live) }
        guard let census = try runtime.census() else { return MacLoad.count(listed, load: load, except: folder) }
        return MacLoad.count(census: census, sessions: listed, load: load, except: folder)
    }

    /// As `macLoad`, a census that can't be read a refusal saying what didn't happen (`refused`).
    private func macLoad(_ sessions: [LeadSessionInfo], load: Double?, except folder: String?, refused: String) throws -> MacLoad {
        do { return try macLoad(sessions, load: load, except: folder) } catch {
            throw Problem(text: "The session host's count of every project's team sessions can't be read (\(error)), so \(refused). Try again in a moment; if it keeps failing, tell the user (VibeSwitcher may be restarting its session host).")
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
        // Copies, kept in .vibeswitcher: what's given is usually in a worktree's .build, gone once the task is cleaned up.
        var update = LeadUpdate(title: title, body: body)
        update.images = try keptImages(strings(arguments["images"]), as: "\(KeptImages.updates)/\(update.id)", relativeTo: root, not: "Not posted")
        try store.update { board in board.updates.append(update) }
        // In the log too, so a later lead sees the updates, check-ins and retrospectives.
        let first = body.split(whereSeparator: \.isNewline).first.map { Self.clip(String($0), 200) }
        try? store.appendProgress("Update: \(Self.clip(title, 200))" + (first.map { " — \($0)" } ?? ""))
        return MCPToolResult(text: "Posted.")
    }

    /// `paths` kept as group `group` (`KeptImages`); a path that isn't there or isn't an image is refused, `not` saying
    /// what didn't happen.
    private func keptImages(_ paths: [String], as group: String, relativeTo base: String, not: String) throws -> [String] {
        do { return try KeptImages(folder: store.folder).keep(paths, as: group, relativeTo: base) } catch let refusal as KeptImages.Refusal {
            throw Problem(text: "\(not): \(refusal.text)")
        }
    }

    private func recordDecision(_ arguments: [String: Any]) throws -> MCPToolResult {
        guard let decision = arguments["decision"] as? String, let why = arguments["why"] as? String else { throw Problem(text: "A decision needs a reason.") }
        try store.appendDecision(decision, why: why)
        return MCPToolResult(text: store.recordsDir.map { "Recorded in \($0)/decisions.md (committed to \(base) with the next batch)." } ?? "Recorded.")
    }

    /// Moves the named decisions to decisions-archive.md (`LeadRecords.archive`); committed with the next batch, as
    /// record_decision's are.
    private func archiveDecisions(_ arguments: [String: Any]) throws -> MCPToolResult {
        let archived: LeadRecords.Archived
        do {
            archived = try LeadRecords.archive(strings(arguments["entries"]), reason: arguments["reason"] as? String ?? "", in: store)
        } catch let refusal as LeadRecords.Refusal { throw Problem(text: refusal.text) }
        let file = store.recordsDir.map { "\($0)/decisions-archive.md (committed to \(base) with the next batch)" } ?? "decisions-archive.md"
        return MCPToolResult(text: "Archived \(archived.moved.count) \(archived.moved.count == 1 ? "entry" : "entries") in \(file): "
                             + archived.moved.map { "“\(Self.clip($0, 80))”" }.joined(separator: ", ")
                             + ". decisions.md keeps \(archived.kept); the archive holds \(archived.archived).")
    }

    /// An incident in incidents.md, and the planned task that turns it into a check run before merge.
    private func recordIncident(_ arguments: [String: Any]) throws -> MCPToolResult {
        let given = { (key: String) in (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let what = given("what"), evidence = given("evidence"), wanted = given("task")
        guard !what.isEmpty else { throw Problem(text: "Say what happened (what), in one line.") }
        guard !evidence.isEmpty else { throw Problem(text: "Give the evidence: the transcript, log, commit or steps that show it (evidence).") }
        var about: String?
        if !wanted.isEmpty {
            guard let task = store.loadAll().task(wanted) else { throw Problem(text: "No task \(wanted) on the board: name the task by its slug, or leave task out.") }
            about = task.slug
        }
        let workflow = self.workflow
        let contract = Self.incidentContract(what: what, evidence: evidence, task: about, workflow: workflow)
        let title = "Turn this incident into a check: " + Self.clip(what.split(whereSeparator: \.isNewline).joined(separator: " "), 60)
        let task = try store.update { board -> LeadTask in
            let task = LeadTask(slug: Slug.make(title, taken: store.takenSlugs(board)), title: title, contract: contract)
            board.tasks.append(task)
            return task
        }
        try store.appendIncident(what, evidence: evidence, task: about, check: task.slug)
        try? store.appendProgress("Incident: \(Self.clip(what, 160))\(about.map { " (in \($0))" } ?? ""); planned \(task.slug) to turn it into a check")
        let file = store.recordsDir.map { "\($0)/incidents.md (committed to \(base) with the next batch)" } ?? "incidents.md"
        let regression = workflow.regressionCommand.map { " regression_command is `\($0)`: its check can be a case there." }
            ?? " There's no regression_command yet: when the check is a run of its own (a bench corpus), set it with configure (regression_command), and merge runs it after test_command."
        return MCPToolResult(text: "Recorded in \(file). Planned task \(task.slug) turns it into a check that runs before merge.\(regression) Start it with start_worker.")
    }

    /// The contract of the task an incident becomes: a check that fails while the incident can happen and runs before
    /// every merge.
    static func incidentContract(what: String, evidence: String, task: String?, workflow: LeadWorkflow) -> LeadContract {
        let tests = workflow.testCommand.map { "`\($0)` passes" } ?? "The project's tests pass"
        return LeadContract(
            goal: "This incident becomes a check that runs before every merge, so a merge that brings it back is refused: \(what)",
            acceptance: ["A new check reproduces the incident: it fails on the code as it was when it happened (or with its fix reverted), shown with its output in the report",
                         "It passes now, and runs in test_command or regression_command" + (workflow.regressionCommand.map { " (`\($0)`)" } ?? " (the lead sets regression_command with configure when it's a run of its own)") + ", so merge runs it",
                         tests],
            boundaries: ["The check and what it needs (tests, a bench corpus case, fixtures); the behaviour it guards changes only if the incident still happens"],
            context: "Incident (in incidents.md): \(what)\nEvidence: \(evidence)" + (task.map { "\nIt happened in task \($0)." } ?? ""))
    }

    private func configure(_ arguments: [String: Any]) throws -> MCPToolResult {
        let mac = LeadWorkflow.macKeys.filter { arguments[$0] != nil }
        guard mac.isEmpty else {
            throw Problem(text: "Nothing was changed: \(mac.joined(separator: " and ")) \(mac.count == 1 ? "is" : "are") set once for the whole Mac, "
                          + "by the user in VibeSwitcher's Settings › Project lead (every project's leads share it), not in workflow.md. "
                          + "Now: \(Self.macLimitsText(macLimits())).")
        }
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
            case "heavy_slots":
                guard !value.isEmpty else { break }
                guard let count = Int(value), count >= 1 else { throw Problem(text: "heavy_slots must be a whole number, at least 1 (empty: the Mac's cores ÷ 4).") }
                value = String(count)
            case "audit_finders":
                guard !value.isEmpty else { break }
                guard let count = Int(value), (1...LeadWorkflow.maxFinders).contains(count) else {
                    throw Problem(text: "audit_finders must be 1 (one verifier), 2 or \(LeadWorkflow.maxFinders) (that many finders and a vote).")
                }
                value = String(count)
            case "audit_nit_cap":
                guard !value.isEmpty else { break }
                guard let count = Int(value), count >= 0 else { throw Problem(text: "audit_nit_cap must be a whole number, 0 or more.") }
                value = String(count)
            case "risk_lines":
                guard !value.isEmpty else { break }
                guard let count = Int(value), count >= 0 else { throw Problem(text: "risk_lines must be a whole number of lines, 0 (no size trigger) or more.") }
                value = String(count)
            case "task_budget_min":
                guard !value.isEmpty else { break }
                guard let count = Int(value), count >= 0 else { throw Problem(text: "task_budget_min must be a whole number of minutes, 0 (no budget) or more.") }
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
            case "auto_advance" where !value.isEmpty, "watch_app_logs" where !value.isEmpty, "risk_model" where !value.isEmpty:
                // A JSON true or false arrives as a number.
                let flag = (given as? Bool) ?? LeadWorkflow.flag(value)
                guard let flag else { throw Problem(text: "\(key) is true or false.") }
                value = String(flag)
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
        // The file and its record in the vault change together, as the automatic passes read them (`LeadAdvance.pass`):
        // one between them would take the lead's own change for a worker's.
        try exclusively("configure") {
            let current = FileManager.default.contents(atPath: path) ?? Data(LeadWorkflow.template.utf8)
            let before = LeadWorkflow.load(from: path)
            try LeadWorkflow.write(LeadWorkflow.updating(current, with: changes), to: path)
            // What the next read sees is what counts.
            let after = LeadWorkflow.load(from: path)
            let read: [String: String] = ["test_command": after.testCommand ?? "", "regression_command": after.regressionCommand ?? "",
                                          "init_command": after.initCommand ?? "",
                                          "base_branch": after.baseBranch ?? "", "verifier_model": after.verifierModel ?? "",
                                          "max_workers": String(after.maxWorkers),
                                          "disk_warning_gb": Self.gb(after.diskWarningGB), "disk_floor_gb": Self.gb(after.diskFloorGB),
                                          "test_timeout_min": Self.gb(after.testTimeoutMinutes), "task_budget_min": String(after.taskBudgetMinutes),
                                          "heavy_slots": after.heavySlots.map(String.init) ?? "",
                                          "audit_finders": String(after.auditFinders), "audit_nit_cap": String(after.auditNitCap),
                                          "merge_policy": after.mergePolicy?.rawValue ?? "", "sensitive_paths": after.sensitivePaths?.joined(separator: ", ") ?? "",
                                          "records_dir": after.recordsDir ?? "", "auto_advance": String(after.autoAdvance),
                                          "risk_lines": String(after.riskLines), "risk_model": String(after.riskModel),
                                          "watch_app_logs": String(after.watchAppLogs)]
            // A limit cleared reads back as its default.
            let defaults = ["disk_warning_gb": Self.gb(LeadWorkflow().diskWarningGB), "disk_floor_gb": Self.gb(LeadWorkflow().diskFloorGB),
                            "test_timeout_min": Self.gb(LeadWorkflow().testTimeoutMinutes), "task_budget_min": String(LeadWorkflow().taskBudgetMinutes),
                            "audit_finders": String(LeadWorkflow().auditFinders), "audit_nit_cap": String(LeadWorkflow().auditNitCap),
                            "auto_advance": String(LeadWorkflow().autoAdvance), "watch_app_logs": String(LeadWorkflow().watchAppLogs),
                            "risk_lines": String(LeadWorkflow().riskLines), "risk_model": String(LeadWorkflow().riskModel)]
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
    private func checkSettings(_ workflow: LeadWorkflow, not: String, keys: Set<String>? = nil) throws {
        var changed: [(key: String, value: String)]
        do { changed = try vault.changedSettings(workflow, root: root) } catch {
            throw Problem(text: "\(not): the session host couldn't say what you last set workflow.md's guard rails to (\(error)).")
        }
        if let keys { changed = changed.filter { keys.contains($0.key) } }
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

    /// The report a worker gives at its task's time budget (see `LeadBudget`): not done, for the lead to decide on.
    static let overBudgetStatus = "over_budget"

    private func report(_ arguments: [String: Any]) throws -> MCPToolResult {
        let slug = try taskSlug(arguments)
        let summary = try text(arguments, "summary", missing: "Say what changed and how you checked it, or what blocks you.")
        let kind = (arguments["status"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
        let overBudget = kind == Self.overBudgetStatus
        if overBudget { return try reportOverBudget(slug, summary) }
        let done = kind != "blocked"
        // Before anything is recorded: a done that doesn't show how each check was checked doesn't count as one.
        var evidence = done ? try Self.doneEvidence(arguments, acceptance: store.load().task(slug)?.contract.acceptance ?? [], base: workflow.base) : nil
        if done { try checkLoadProof(slug, arguments) }
        // Its screenshots as copies kept in .vibeswitcher, so board(task), the verifier and the lead still open them
        // once the worktree (where sandbox shots are) is cleaned up. Relative paths are the worktree's.
        if let given = evidence {
            let shots = given.checks.flatMap { $0.screenshots ?? [] }
            let kept = try keptImages(shots, as: "\(KeptImages.evidence)/\(slug)/\(UUID().uuidString)",
                                      relativeTo: Worktrees.path(root: root, slug: slug), not: "Not reported (evidence screenshots)")
            var next = kept.makeIterator()
            evidence?.checks = given.checks.map { check in
                var check = check
                check.screenshots = check.screenshots?.compactMap { _ in next.next() }
                return check
            }
        }
        // A report on the commit the last verdict covers (an answer, a note, a repeated "done") leaves that verdict
        // standing: only a new commit, or the lead's own audit, needs a new one.
        let head = branchHead(Worktrees.branch(slug))
        let standing = vault.verdict(root: root, task: slug).flatMap { $0.commit == head ? $0 : nil }
        if standing == nil { try vault.clearVerdict(root: root, task: slug) }
        // Where merge reads the worker's "done" for a task with no audit: the board's copy is anyone's to write.
        let recorded = Result { try vault.reportDone(root: root, task: slug, commit: done ? head : nil, evidence: evidence) }
        // A pass that left Important findings open still isn't mergeable.
        let blocking = standing == nil ? [] : vault.audits(root: root, task: slug)?.blocking ?? []
        // Why it's audited; with neither that nor a standing verdict, the merge's own test run is its check.
        let needed = standing == nil && done ? reviewNeeded(slug, commit: head) : nil
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            // Kept, folded, abandoned or reverted by the lead: a late report doesn't change that.
            if ![.kept, .folded, .abandoned, .reverted].contains(board.tasks[index].status) {
                board.tasks[index].status = !done ? .blocked : standing.map { $0.passes && blocking.isEmpty ? .review : .failed } ?? .review
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
            board.tasks[index].auditNeeded = needed
            board.tasks[index].blocker = done ? nil : (summary.isEmpty ? "The worker is blocked." : summary)
        }
        let stands = standing.map { verdict in
            "No new commit since its audit at \(verdict.commit.prefix(8)), which "
                + (verdict.passes ? "passed: that verdict stands" : "didn't pass (\(verdict.completion.rawValue), \(verdict.integrity.rawValue)): that verdict stands")
                + (!done ? "." : !verdict.passes ? "; audit(\(slug)) to have it checked again."
                    : blocking.isEmpty ? ". merge(\(slug)) when you're ready."
                    : ", with Important findings open (\(blocking.map { "\(slug):\($0.id)" }.joined(separator: ", "))) that merge refuses: dismiss_finding them, or have the worker fix them and commit, then audit(\(slug)).")
        }
        // No audit asked for: the merge's own test run is the check.
        let unaudited = standing == nil && needed == nil
        var next: String?
        if let needed {
            next = needed + " Run audit(\(slug)); only the verifier's report counts."
        } else if unaudited, case .failure(let error) = recorded {
            next = "Its done couldn't be recorded in the vault (\(error)), so merge can't take it without an audit: run audit(\(slug))."
        } else if unaudited {
            next = "Its review is none: merge(\(slug)) runs the full test suite on it and merges it when it passes; no audit."
        }
        // VibeSwitcher's own next step, when it takes it (see `LeadAdvance`): the lead needn't.
        var auto = ""
        if done, advances(slug) {
            if let standing {
                if standing.passes && blocking.isEmpty { auto = " " + LeadAdvance.mergesItself }
            } else if needed == nil, case .success = recorded {
                auto = " " + LeadAdvance.mergesItself
            } else {
                auto = " " + LeadAdvance.auditsItself
            }
        }
        let text = done
            ? "The worker on \(slug) says it's done: \(summary)\n" + (stands ?? next ?? "Run audit(\(slug)); only the verifier's report counts.") + auto
            : "The worker on \(slug) is blocked: \(summary)" + (stands.map { "\n\($0)" } ?? "")
        let told = try tellLead(text, about: "worker \(slug)")
        let kept = standing.map { " Your branch is still at \($0.commit.prefix(8)), the commit its audit covers, so that verdict stands." } ?? ""
        let reply = done
            ? (standing == nil ? (unaudited ? "Reported. The lead's merge runs the full test suite on your branch; stay available in case it fails."
                                                          : "Reported. A verifier will check your branch; stay available for fixes.") : "Reported." + kept)
            : "Reported. The lead will get back to you." + kept
        return MCPToolResult(text: reply + (told ? "" : Self.noLead))
    }

    /// report(status: over_budget): like blocked, it's no done (merge and audit don't take it), and it waits on the
    /// lead's decision: extend the budget, re-plan or abandon. Kept on the task as its over-budget state.
    private func reportOverBudget(_ slug: String, _ summary: String) throws -> MCPToolResult {
        // A done recorded earlier for this task goes: what merge reads for a review none task is the latest word.
        let head = branchHead(Worktrees.branch(slug))
        let standing = vault.verdict(root: root, task: slug).flatMap { $0.commit == head ? $0 : nil }
        if standing == nil { try vault.clearVerdict(root: root, task: slug) }
        _ = try? vault.reportDone(root: root, task: slug, commit: nil, evidence: nil)
        let workflow = self.workflow
        let task = try store.update { board -> LeadTask? in
            guard let index = board.taskIndex(slug) else { return nil }
            if ![.kept, .folded, .abandoned, .done, .reverted].contains(board.tasks[index].status) { board.tasks[index].status = .blocked }
            // One that reports it before it's told (it judged the time itself) is over its budget all the same.
            var over = board.tasks[index].overBudget
                ?? LeadOverBudget(minutes: LeadBudget.minutes(board.tasks[index], default: workflow.taskBudgetMinutes) ?? 0)
            over.report = summary
            board.tasks[index].overBudget = over
            if standing == nil, let earlier = board.tasks[index].evidence {
                if earlier.commit != nil, earlier.commit != head { board.tasks[index].outdatedEvidence = earlier }
                board.tasks[index].evidence = nil
            }
            board.tasks[index].auditNeeded = nil
            board.tasks[index].blocker = "Over its time budget: " + summary
            return board.tasks[index]
        }
        let over = task?.overBudget
        let budget = over.map { $0.minutes > 0 ? "its \($0.minutes) min time budget" : "its time budget" } ?? "its time budget"
        let text = "The worker on \(slug) is over \(budget) (\(LeadBudget.text(task?.worked ?? 0)) worked): \(summary)\n"
            + "Decide: extend it (update_task(\(slug), budget_min: more), then message it to go on), re-plan (update_task, then message it), "
            + "or abandon it. It's not a done report: merge and audit don't take it."
        let told = try tellLead(text, about: "worker \(slug)")
        return MCPToolResult(text: "Reported over budget. Wait for the lead's decision: it extends the budget, re-plans or abandons the task." + (told ? "" : Self.noLead))
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

    /// answer_findings' answers, as its schema tells the worker.
    static let answersShape = "One object per finding: {id, answer, reason}. id: the finding's id as the lead sent it (F2). "
        + "answer: fixed (the fix is committed on your branch) or disagree. reason: for disagree, why it isn't a problem that "
        + "blocks the merge (why the failure it describes can't happen, or what allows it), which the re-audit weighs; for "
        + "fixed, what the fix was (optional)."

    /// A worker's answers to its task's open findings: each one fixed (committed since the audit that left it open) or
    /// disagreed with, with a reason. Kept on the task for the lead (board) and the next audit; refused whole when an id
    /// isn't an open finding, a disagreement has no reason, or nothing is committed since the audit for a fix.
    private func answerFindings(_ arguments: [String: Any]) throws -> MCPToolResult {
        let slug = try taskSlug(arguments)
        var value = arguments["answers"]
        if let text = value as? String { value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) }
        guard let list = value as? [Any], !list.isEmpty else { throw Problem(text: "answers is a list of objects: \(Self.answersShape)") }
        let ledger = vault.audits(root: root, task: slug) ?? store.load().task(slug)?.audits
        guard let ledger, !ledger.findings.isEmpty else { throw Problem(text: "Your task has no audit findings to answer. Nothing was recorded.") }
        let head = branchHead(Worktrees.branch(slug))
        var answers: [LeadFindingAnswer] = []
        for (index, item) in list.enumerated() {
            guard let object = item as? [String: Any] else { throw Problem(text: "Answer \(index + 1) isn't an object: \(Self.answersShape)") }
            let word = { (key: String) in (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            guard let finding = ledger.finding(word("id")) else {
                throw Problem(text: "Answer \(index + 1): \(word("id").isEmpty ? "give the finding's id" : "no finding \(word("id"))") (your task's are \(ledger.findings.map(\.id).joined(separator: ", "))). Nothing was recorded.")
            }
            guard finding.isLive else {
                throw Problem(text: "\(finding.label) is \(finding.status.rawValue) already; answer the open ones (\(ledger.findings.filter(\.isLive).map(\.id).joined(separator: ", "))). Nothing was recorded.")
            }
            guard answers.allSatisfy({ !finding.named($0.id) }) else { throw Problem(text: "\(finding.id) is answered twice; answer it once. Nothing was recorded.") }
            guard let kind = LeadFindingAnswer.Kind(rawValue: word("answer").lowercased()) else {
                throw Problem(text: "\(finding.id): answer is fixed or disagree, not \(word("answer").isEmpty ? "missing" : word("answer")). Nothing was recorded.")
            }
            let reason = word("reason")
            if kind == .disagree, reason.isEmpty {
                throw Problem(text: "\(finding.id): say why you disagree (reason), so the re-audit can weigh it. Nothing was recorded.")
            }
            if kind == .fixed, head == nil || head == ledger.commit {
                throw Problem(text: "\(finding.id): nothing is committed on your branch since the audit at \(ledger.commit?.prefix(8) ?? "its commit"); commit the fix first, then answer. Nothing was recorded.")
            }
            answers.append(LeadFindingAnswer(id: finding.id, kind: kind, reason: reason, commit: head, round: ledger.rounds))
        }
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            let answered = Set(answers.map(\.id))
            board.tasks[index].answers = (board.tasks[index].answers ?? []).filter { !answered.contains($0.id) } + answers
        }
        let said = answers.map { "\(slug):\($0.id) \($0.text)" }.joined(separator: "; ")
        try? store.appendProgress("The worker on \(slug) answered findings: \(Self.clip(said, 500))")
        let told = try tellLead("The worker on \(slug) answered findings: \(said)\nThe re-audit judges these answers (audit(\(slug)) once it reports done); dismiss_finding one you accept yourself.",
                                about: "worker \(slug)")
        let current = store.load().task(slug)?.currentAnswers(ledger) ?? [:]
        let open = ledger.blocking.filter { current[$0.id.uppercased()] == nil }
        return MCPToolResult(text: "Answered \(answers.map(\.id).joined(separator: ", ")); the lead sees them in board(\(slug)) and the re-audit judges them."
                             + (open.isEmpty ? "" : " Still unanswered Important findings: \(open.map(\.id).joined(separator: ", ")).")
                             + " When everything is committed, report done." + (told ? "" : Self.noLead))
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
        let tests = try (arguments["tests"] as? String).map { said in
            guard let tests = LeadVault.TestRun(rawValue: said.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "_")) else {
                throw Problem(text: "tests must be passed, failed or not_run.")
            }
            return tests
        }
        let (reports, demoted) = try Self.parsedFindings(arguments["findings"])
        let demotedText = demoted.isEmpty ? "" : " Recorded as Nit\(demoted.count == 1 ? "" : "s"), having no failure_scenario: \(demoted.joined(separator: ", ")) (Important needs one)."
        // Checked here first against what a re-audit covers (the vault has no git; see reauditScope), then by the vault.
        let earlier = vault.audits(root: root, task: slug) ?? LeadAuditLedger()
        if let audited = member.auditing {
            var trial = earlier
            do {
                try trial.record(reports, commit: audited, passes: completion == .complete && integrity == .clean,
                                 changed: earlier.commit.flatMap { reauditFiles(since: $0, head: audited) })
            } catch { throw Problem(text: "Not recorded: \(error) Nothing was recorded; call submit_audit again.") }
        }
        let submission: LeadVault.Submission
        do { submission = try vault.submit(root: root, completion: completion, integrity: integrity, summary: summary, findings: reports, tests: tests) } catch {
            throw Problem(text: "\(error)")
        }
        let finder = member.finder?.index
        guard let verdict = submission.verdict else {
            // One of several finders: its ballot is in, and the vote waits for the others'.
            try store.update { board in
                guard let index = board.taskIndex(slug), let finder, let panel = board.tasks[index].panel, !panel.reported.contains(finder) else { return }
                board.tasks[index].panel?.reported = (panel.reported + [finder]).sorted()
            }
            try? store.appendProgress("Audit of \(slug): finder \(finder ?? 0) of \(submission.of) submitted (\(completion.rawValue), \(integrity.rawValue), \(reports.count) finding\(reports.count == 1 ? "" : "s"))")
            return MCPToolResult(text: "Your findings are in: \(submission.cast) of \(submission.of) finders have submitted, and the vote runs when the last one does.\(demotedText) You're done; the lead takes it from here.")
        }
        // The verdict: one verifier's, or the finders' vote.
        let ledger = vault.audits(root: root, task: slug)
        let audited = verdict.commit
        let evidence = LeadEvidence(completion: verdict.completion, integrity: verdict.integrity, summary: verdict.summary, commit: audited)
        let blocking = ledger?.blocking ?? []
        try store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].evidence = evidence
            board.tasks[index].outdatedEvidence = nil
            board.tasks[index].audits = ledger
            if let size = board.tasks[index].panel?.size { board.tasks[index].panel?.reported = Array(1...size) }
            // A pass that leaves an Important finding open isn't mergeable yet: the lead decides, as on a failure.
            if ![.kept, .folded, .abandoned, .reverted].contains(board.tasks[index].status) { board.tasks[index].status = evidence.passes && blocking.isEmpty ? .review : .failed }
            if !evidence.passes {
                board.tasks[index].setback = LeadSetback(stage: .review, reason: evidence.summary.isEmpty ? "The audit didn't pass (\(evidence.completion.rawValue), \(evidence.integrity.rawValue))." : evidence.summary,
                                                         evidence: evidence)
            } else if !blocking.isEmpty {
                board.tasks[index].setback = LeadSetback(stage: .review, reason: "Important findings open: " + blocking.map(\.line1).joined(separator: "; "), evidence: evidence)
            }
        }
        try? store.appendProgress("Audit of \(slug): \(evidence.completion.rawValue), \(evidence.integrity.rawValue)"
            + (ledger.map { $0.findings.isEmpty ? "" : ", round \($0.rounds): \(Self.findingsTally($0))" } ?? "")
            + (ledger?.vote.map { " (\($0.text))" } ?? ""))
        let head = branchHead(Worktrees.branch(slug))
        let moved = head == audited ? "" : "\nagent/\(slug) moved during the audit (now \(head?.prefix(8) ?? "gone")): this verdict covers \(audited.prefix(8)) only, and merge refuses newer commits until they're audited."
        var text = evidence.passes
            ? "The audit of \(slug) passed (complete, clean): \(evidence.summary)\n" + (blocking.isEmpty ? "merge(\(slug)) when you're ready.\(moved)" : "")
            : "The audit of \(slug) did not pass (\(evidence.completion.rawValue), \(evidence.integrity.rawValue)): \(evidence.summary)\n"
        if let vote = ledger?.vote {
            text += (text.hasSuffix("\n") ? "" : "\n") + vote.text + (vote.unconfirmed > 0 ? " (unconfirmed ones don't hold the merge back; dismiss_finding them, or add_task(from_finding: …) one that's a real Important problem)" : "") + ".\n"
        }
        if let ledger, !ledger.findings.isEmpty {
            text += (text.hasSuffix("\n") ? "" : "\n") + Self.findingsText(ledger, of: slug) + "\n"
        }
        if let ledger, ledger.reconsider {
            text += Self.reconsiderText(ledger, of: slug)
        } else if !blocking.isEmpty {
            text += "merge refuses while an Important finding is open: send the worker the open ones (message, with their ids; it answers each with answer_findings, fixed or disagree with a reason, and the re-audit judges the answers), or dismiss_finding one with a reason, or add_task(from_finding: …) to move it to a task of its own."
        } else if !evidence.passes {
            text += "Send the worker the findings with message, or re-plan the task."
        } else if ledger?.open.isEmpty == false {
            text += "merge(\(slug)) when you're ready: Nits and Pre-existing findings don't hold it back, and a Nit never becomes a task by itself (add_task(from_finding: …) makes a Pre-existing one that matters a task).\(moved)"
        }
        // VibeSwitcher's own next step, when it takes it (see `LeadAdvance`).
        if advances(slug), ledger?.reconsider != true {
            if evidence.passes && blocking.isEmpty && head == audited {
                text += (text.hasSuffix("\n") ? "" : "\n") + LeadAdvance.mergesItself
            } else if !blocking.isEmpty && evidence.integrity == .clean && head == audited {
                text += (text.hasSuffix("\n") ? "" : "\n") + LeadAdvance.sendsBackItself
            }
        }
        let told = try tellLead(text.trimmingCharacters(in: .whitespacesAndNewlines), about: "verifier \(slug)")
        let recorded = submission.of > 1 ? "Your findings are in, the last of \(submission.of): the vote is done and its verdict recorded." : "Verdict recorded."
        return MCPToolResult(text: recorded + demotedText + " You're done; the lead takes it from here." + (told ? "" : Self.noLead))
    }

    /// submit_audit's findings as the verifier passed them (a list of objects, or that list as JSON text).
    static func findingReports(_ value: Any?) throws -> [LeadFinding.Report] { try parsedFindings(value).reports }

    /// The same, and the open Important findings recorded as Nits for having no failure_scenario ("file:line" each):
    /// Important is only for a concrete problem that blocks the merge, shown by what goes wrong.
    static func parsedFindings(_ value: Any?) throws -> (reports: [LeadFinding.Report], demoted: [String]) {
        var demoted: [String] = []
        let reports = try findingList(value).map { report in
            guard report.severity == .important, report.status == .open, (report.failureScenario ?? "").isEmpty else { return report }
            var nit = report
            nit.severity = .nit
            demoted.append("\(report.file):\(report.line)")
            return nit
        }
        return (reports, demoted)
    }

    private static func findingList(_ value: Any?) throws -> [LeadFinding.Report] {
        var value = value
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return [] }
            value = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))
        }
        guard let value else { return [] }
        guard let list = value as? [Any] else { throw Problem(text: "findings is a list of objects: \(findingsShape)") }
        return try list.enumerated().map { index, item in
            let which = "Finding \(index + 1)"
            guard let object = item as? [String: Any] else { throw Problem(text: "\(which) isn't an object: \(findingsShape)") }
            let word = { (key: String) in (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            guard let severity = LeadFinding.Severity.allCases.first(where: { $0.rawValue.lowercased() == word("severity").lowercased() }) else {
                throw Problem(text: "\(which): severity is Important, Nit or Pre-existing, not \(word("severity").isEmpty ? "missing" : word("severity")).")
            }
            let status = word("status").isEmpty ? LeadFinding.Status.open : LeadFinding.Status(rawValue: word("status").lowercased())
            guard let status, status != .unconfirmed else { throw Problem(text: "\(which): status is open, fixed or dismissed, not \(word("status")).") }
            let line = (object["line"] as? Int) ?? (object["line"] as? Double).map { Int($0) } ?? Int(word("line"))
            guard !word("file").isEmpty, let line, line > 0 else {
                throw Problem(text: "\(which): give the file (path from the repository's root) and the line (a number) where it is.")
            }
            guard !word("evidence").isEmpty else { throw Problem(text: "\(which) (\(word("file")):\(line)): give the evidence: what you ran and what it gave, or what the code there does.") }
            let reason = word("reason")
            guard status != .dismissed || !reason.isEmpty else { throw Problem(text: "\(which) (\(word("file")):\(line)): a dismissed finding needs its reason.") }
            let scenario = word("failure_scenario")
            return LeadFinding.Report(id: word("id").isEmpty ? nil : word("id"), severity: severity, file: word("file"), line: line,
                                      evidence: word("evidence"), status: status, reason: reason.isEmpty ? nil : reason,
                                      failureScenario: scenario.isEmpty ? nil : scenario)
        }
    }

    /// The files that differ between two commits (nil: git can't tell).
    private func changedFiles(from: String, to: String) -> Set<String>? {
        let diff = Git.run(["diff", "--name-only", from, to], in: root)
        return diff.ok ? Set(diff.output.split(whereSeparator: \.isNewline).map(String.init)) : nil
    }

    /// A done report's evidence and blind check, refused unless it covers every one of `acceptance` (see
    /// `LeadDoneEvidence.uncovered`) and says what the blind check found.
    static func doneEvidence(_ arguments: [String: Any], acceptance: [String], base: String) throws -> LeadDoneEvidence {
        var value = arguments["evidence"]
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            value = trimmed.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) ?? text
        }
        let missing = "Not reported: a done report needs `evidence`, one entry per acceptance check. " + evidenceShape
        if let one = value as? [String: Any] { value = [one] }
        guard let value else { throw Problem(text: missing) }
        guard let list = value as? [Any] else { throw Problem(text: "Not reported: evidence is a list of objects. " + evidenceShape) }
        let word = { (object: [String: Any], key: String) -> String in
            if let number = object[key] as? NSNumber { return number.stringValue }
            let said = (object[key] as? [String])?.joined(separator: "\n") ?? object[key] as? String ?? ""
            return said.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let checks = try list.enumerated().map { index, item -> LeadDoneEvidence.Check in
            guard let object = item as? [String: Any] else { throw Problem(text: "Not reported: evidence entry \(index + 1) isn't an object. " + evidenceShape) }
            let check = word(object, "check"), how = word(object, "how"), result = word(object, "result")
            guard !check.isEmpty, !how.isEmpty, !result.isEmpty else {
                let lacks = [("check", check), ("how", how), ("result", result)].filter { $0.1.isEmpty }.map(\.0).joined(separator: ", ")
                throw Problem(text: "Not reported: evidence entry \(index + 1)\(check.isEmpty ? "" : " (\(check))") has no \(lacks). " + evidenceShape)
            }
            let shots = (object["screenshots"] as? [String]) ?? (object["screenshots"] as? String).map { [$0] } ?? []
            let paths = shots.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return LeadDoneEvidence.Check(check: check, how: how, result: result, screenshots: paths.isEmpty ? nil : paths)
        }
        guard !checks.isEmpty else { throw Problem(text: missing) }
        let blind = blindCheck(arguments["blind_check"])
        guard !blind.isEmpty else {
            throw Problem(text: "Not reported: say in `blind_check` what your blind check found and what you did about each item. "
                + "Run it first if you haven't: " + LeadPrompts.Policy.blindCheck(base: base))
        }
        let evidence = LeadDoneEvidence(checks: checks, blindCheck: blind)
        let uncovered = evidence.uncovered(acceptance)
        guard uncovered.isEmpty else {
            let named = uncovered.map { "\($0.number) (\(clip($0.text, 120)))" }.joined(separator: "; ")
            throw Problem(text: "Not reported: the evidence has no entry for \(uncovered.count == 1 ? "acceptance check" : "these acceptance checks") \(named). "
                + "Give one entry for each, naming the check by its number or its text, then report again.")
        }
        return evidence
    }

    /// The load harness a done report's new tests are proven under (see `LeadPrompts.newTests`), in the worktree.
    static let loadScript = "scripts/test-under-load.sh"

    /// A done report on a branch that adds or changes tests, in a project with `loadScript`, gives their run under load
    /// (the script named in its summary, evidence or blind check): on 2026-10-23 three new tests passed in their workers
    /// and failed in loaded merge runs, each a ~30 min merge and a rework (decision 2026-10-23 14:16).
    private func checkLoadProof(_ slug: String, _ arguments: [String: Any]) throws {
        let worktree = Worktrees.path(root: root, slug: slug)
        guard FileManager.default.fileExists(atPath: (worktree as NSString).appendingPathComponent(Self.loadScript)),
              let head = branchHead(Worktrees.branch(slug)) else { return }
        // A done again on the same commit (answering findings, a note): its first one gave it.
        if (try? vault.unaudited(root: root, task: slug))?.reported == head { return }
        let changed = Git.run(["diff", "--name-only", "--diff-filter=d", "\(workflow.base)...\(head)"], in: root)
        let tests = Self.testFiles(changed.output.split(whereSeparator: \.isNewline).map(String.init))
        guard changed.ok, !tests.isEmpty else { return }
        let said = [arguments["summary"], arguments["evidence"], arguments["blind_check"]].map { value -> String in
            guard let value else { return "" }
            if let text = value as? String { return text }
            return (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
        }.joined(separator: "\n")
        guard !said.contains("test-under-load") else { return }
        throw Problem(text: "Not reported: your branch adds or changes tests (\(tests.prefix(5).joined(separator: ", "))\(tests.count > 5 ? ", …" : "")), "
            + "and the report doesn't give their run under load. Run them once through `\(LeadPrompts.proofCommand)` and put its "
            + "result line in your report (summary or evidence), then report again.")
    }

    /// The test files among repository paths: under a Tests, tests, test, spec or __tests__ folder, or named as tests
    /// are (FooTests.swift, foo_test.go, foo.test.js, foo.spec.ts, test_foo.py).
    static func testFiles(_ paths: [String]) -> [String] {
        paths.filter { path in
            let parts = path.split(separator: "/").map(String.init)
            guard let name = parts.last else { return false }
            if parts.dropLast().contains(where: { ["Tests", "tests", "test", "spec", "__tests__"].contains($0) }) { return true }
            let stem = (name as NSString).deletingPathExtension
            return stem.hasSuffix("Tests") || stem.hasSuffix("Test") || stem.hasSuffix("_test") || stem.hasPrefix("test_")
                || stem.hasSuffix(".test") || stem.hasSuffix(".spec")
        }
    }

    /// blind_check as text: a string, or a list of strings or of objects (each item's fields on a line).
    static func blindCheck(_ value: Any?) -> String {
        let line = { (item: Any) -> String in
            if let text = item as? String { return text }
            guard let object = item as? [String: Any] else { return "" }
            return object.keys.sorted().compactMap { key in (object[key] as? String).map { "\(key): \($0)" } }.joined(separator: "; ")
        }
        let lines = (value as? [Any])?.map(line) ?? value.map { [line($0)] } ?? []
        return lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// "1 Important open, 2 Nit (1 open), 1 Pre-existing".
    static func findingsTally(_ ledger: LeadAuditLedger) -> String {
        ledger.bySeverity.map { group in
            let open = group.findings.filter(\.isOpen).count
            let unconfirmed = group.findings.filter { $0.status == .unconfirmed }.count
            let all = group.findings.count
            let state = open == all ? " open" : unconfirmed == all ? " unconfirmed" : open + unconfirmed == 0 ? " closed"
                : " (" + [open > 0 ? "\(open) open" : nil, unconfirmed > 0 ? "\(unconfirmed) unconfirmed" : nil].compactMap { $0 }.joined(separator: ", ") + ")"
            return "\(all) \(group.severity.rawValue)" + state
        }.joined(separator: ", ")
    }

    /// The findings grouped by severity, open ones first, each named <task>:<id> for dismiss_finding and add_task.
    /// `answers`: the worker's answers since the last audit (by id, uppercased), each under its finding.
    static func findingsText(_ ledger: LeadAuditLedger, of slug: String, answers: [String: LeadFindingAnswer] = [:]) -> String {
        var lines = ["Findings (round \(ledger.rounds); \(findingsTally(ledger))):"]
        if let vote = ledger.vote { lines.append("Round \(ledger.rounds): \(vote.text) (\(focusesText(vote.focuses))).") }
        for group in ledger.bySeverity {
            lines.append("\(group.severity.rawValue):")
            for finding in group.findings {
                lines.append("- \(slug):" + clip(finding.line1, 300))
                if let answer = answers[finding.id.uppercased()] { lines.append("  The worker's answer: " + clip(answer.text, 300)) }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// What the lead is told once the rounds reached the cap.
    static func reconsiderText(_ ledger: LeadAuditLedger, of slug: String) -> String {
        "Reconsider the approach: \(ledger.reconsiderCause), and a third round of patching rarely lands. "
            + "Don't send the worker back as it is: re-roll \(slug) (update_task(\(slug), reroll: true), with a sharper contract in the same call if you have one): "
            + "its worker stops, its branch is kept under an archive name, and a fresh worker starts from the base with a summary of the findings and answers so far. "
            + "Or re-plan it (update_task, then status planned, which starts its rounds over) or ask the user (ask_user). "
            + "Dismiss a finding that isn't a real problem (dismiss_finding, with a reason), or make one a task of its own (add_task from_finding)."
    }

    // MARK: Text

    /// How many tasks status lists one per line in all (the rest by slug), and how many new reports.
    static let statusTasks = 24
    static let statusReports = 10

    private func status() -> String {
        let board = store.load()
        // The tasks the archive holds (finished a day ago and more): counted, not named.
        let all = store.withArchive(board)
        let live = Set(board.tasks.map(\.id))
        let archived = all.tasks.filter { !live.contains($0.id) }
        // nil: the host can't be read (what workers do isn't known), never "none running".
        let listing = try? listed()
        let sessions = listing.map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        let workflow = self.workflow
        let power = self.power()?.statusText.map { "; \($0)" } ?? ""
        var lines = ["Project \(project) on branch \(workflow.base) — \(all.tasks.count) task(s), max \(workflow.maxWorkers) workers at once\(power)\(longHolderText())."]
        lines += workflowWarnings(workflow)
        if let ignored = ignoredKeysOnce(workflow) { lines.append(ignored) }
        lines += diskWarning(workflow, board: board, sessions: listing)
        if let line = records.statusLine { lines.append(line) }
        if let line = archiveNudgeOnce() { lines.append(line) }
        if let listing {
            do {
                let mac = try macLoad(listing, load: runtime.steadyLoad())
                let full = macRefusal(mac, not: "") != nil
                lines.append("Mac (every project's team): \(Self.macText(mac, macLimits(), root: root)).\(full ? " start_worker and audit refuse until it eases; merge waits for the load." : "")")
            } catch {
                lines.append("Mac (every project's team): not known, the session host's count of their sessions can't be read (\(error)); start_worker and audit refuse until it can.")
            }
        }
        if let line = heavyLockLine(board) { lines.append(line) }
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
        // Over their time budget: each waits on the lead's decision (see `LeadBudget`).
        let over = board.overBudget
        if !over.isEmpty {
            lines.append("\nOver budget (\(over.count)): extend (update_task budget_min, then message it to go on), re-plan or abandon:")
            lines += over.prefix(Self.statusTasks).map { task in Self.clip("- \(task.slug): \(task.overBudget!.text(worked: task.worked))", 300) }
        }
        // A task whose worker or verifier ended without a word, or whose session went with a replaced host, isn't
        // running: it's said apart, with what to do.
        let ended = sessions.map { sessions in board.tasks.compactMap { task in Self.endedMember(task, sessions).map { (task, $0) } } } ?? []
        let endedIDs = Set(ended.map(\.0.id))
        // Short: status stays bounded (the board says it in full).
        if board.tasks.contains(where: { !LeadTeams.isFinished($0) }) { lines.append("\n" + Self.shortReviewLegend) }
        var budget = Self.statusTasks
        for state in LeadTask.Status.attentionOrder {
            var tasks = board.tasks.filter { $0.status == state && !endedIDs.contains($0.id) }
            guard !tasks.isEmpty else { continue }
            switch state {
            case .done, .folded, .abandoned, .reverted:
                // Said below, each in a line: merged and folded together (a folded task's work merges with another
                // task), then reverted, then abandoned.
                continue
            case .failed:
                // Cleaned up after failing (older boards, cleanup with force): abandoned, said below.
                tasks.removeAll(where: \.isAbandoned)
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
        let settled = board.tasks.filter { !endedIDs.contains($0.id) }
        if let merged = Self.mergedLine(settled, earlier: archived) { lines.append("\n" + merged) }
        if let reverted = Self.revertedLine(settled, earlier: archived) { lines.append("\n" + reverted) }
        if let abandoned = Self.abandonedLine(settled, earlier: archived) { lines.append("\n" + abandoned) }
        // The scorecard's cost line: the batch's receipts summed, and its most expensive task.
        if let receipts = LeadReceiptTotals.line(all) { lines.append("\n" + receipts) }
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
            let finished = reports.filter { report in report.task.flatMap(all.task).map(LeadTeams.isFinished) ?? false }
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
        if let flakes = board.flakeLine(now: Date().timeIntervalSince1970) { lines.append("\n" + flakes) }
        let reverted = recordReverts(base: workflow.base)
        if !reverted.isEmpty {
            lines.append("\nReverted on \(workflow.base) since they merged (\(reverted.count)): " + reverted.map { "\($0.slug) (by \($0.commit.prefix(8)))" }.joined(separator: ", ")
                + ". Each is an incident: record_incident(what, evidence, task) so it becomes a check that runs before merge.")
        }
        return lines.joined(separator: "\n")
    }

    /// Finds the merges the base reverted since (`LeadReverts`) and records each on its task's merge; returns the
    /// ones found now.
    @discardableResult
    func recordReverts(base: String) -> [(slug: String, commit: String)] {
        let merges = store.loadAll().tasks.compactMap { task in task.merged.map { (slug: task.slug, merged: $0) } }
        let found = LeadReverts.find(root: root, base: base, merges: merges)
        guard !found.isEmpty else { return [] }
        let now = Date().timeIntervalSince1970
        try? store.update { board in
            for (slug, commit) in found {
                guard let index = store.restore(slug, into: &board), board.tasks[index].merged?.revertedBy == nil else { continue }
                board.tasks[index].merged?.revertedBy = commit
                board.tasks[index].merged?.revertedAt = now
            }
        }
        for (slug, commit) in found.sorted(by: { $0.key < $1.key }) {
            try? store.appendProgress("Reverted on \(base): \(slug)'s merge, by \(commit.prefix(8))")
        }
        return found.sorted { $0.key < $1.key }.map { (slug: $0.key, commit: $0.value) }
    }

    /// What a task's line says, or doesn't, about its review level.
    static let shortReviewLegend = "Review none unless a line says review audit."
    static let reviewLegend = "Review: none (merge takes the worker's done report and runs the test command; no audit) unless a task's line says review audit (merge needs a passing audit). A branch that touches sensitive_paths is audited either way."

    /// "done (5, 2 folded): add-a, add-b, add-c; folded: old-a → add-a, old-b → add-c": the merged tasks and those folded
    /// into another, counted together (bounded); nil when there are none. `earlier`: the archived tasks, counted but
    /// not named (board(task) finds each).
    static func mergedLine(_ tasks: [LeadTask], earlier: [LeadTask] = []) -> String? {
        let done = tasks.filter { $0.status == .done }
        let folded = tasks.filter { $0.status == .folded }
        let older = earlier.filter { [.done, .folded].contains($0.status) }
        guard !done.isEmpty || !folded.isEmpty || !older.isEmpty else { return nil }
        let allFolded = folded.count + older.filter { $0.status == .folded }.count
        let count = "\(done.count + folded.count + older.count)" + (allFolded == 0 ? "" : ", \(allFolded) folded")
        var names = done.map { $0.slug + ($0.merged?.unaudited == true ? " (unaudited)" : "") }.joined(separator: ", ")
        if !folded.isEmpty {
            names += (done.isEmpty ? "" : "; ") + "folded: " + folded.map { "\($0.slug) → \($0.foldedInto ?? "?")" }.joined(separator: ", ")
        }
        return "done (\(count)): " + clip(names, 600) + earlierNote(older.count, named: !done.isEmpty || !folded.isEmpty)
    }

    /// "; and 240 earlier (archived: board(task) finds each)", after the names of the recent ones.
    static func earlierNote(_ count: Int, named: Bool) -> String {
        count == 0 ? "" : (named ? "; and " : "") + "\(count) earlier (archived: board(task) finds each)"
    }

    /// "reverted (1): add-a (by 1a2b3c4d: the chat froze on paste)": the merged tasks the lead's revert undid (bounded);
    /// nil when there are none.
    static func revertedLine(_ tasks: [LeadTask], earlier: [LeadTask] = []) -> String? {
        let reverted = tasks.filter { $0.status == .reverted }
        let older = earlier.filter { $0.status == .reverted }.count
        guard !reverted.isEmpty || older > 0 else { return nil }
        return "reverted (\(reverted.count + older)): " + clip(reverted.map { task in
            task.slug + " (" + (task.merged?.revertedBy.map { "by \($0.prefix(8))" } ?? "by ?")
                + (task.merged?.revertReason.map { ": \(clip($0, 60))" } ?? "") + ")"
        }.joined(separator: ", "), 600) + earlierNote(older, named: !reverted.isEmpty)
    }

    /// "abandoned (2): old-a (no longer wanted), old-b": the tasks the lead gave up, and those cleaned up after
    /// failing (bounded); nil when there are none.
    static func abandonedLine(_ tasks: [LeadTask], earlier: [LeadTask] = []) -> String? {
        let abandoned = tasks.filter(\.isAbandoned)
        let older = earlier.filter(\.isAbandoned).count
        guard !abandoned.isEmpty || older > 0 else { return nil }
        return "abandoned (\(abandoned.count + older)): " + clip(abandoned.map { task in
            task.slug + (task.abandonedBecause.map { " (\(clip($0, 60)))" } ?? "")
        }.joined(separator: ", "), 600) + earlierNote(older, named: !abandoned.isEmpty)
    }

    /// A task in one line (bounded): its title, what its worker does, its audit, rework, why it's kept, its last
    /// progress. `sessions` nil: the host can't be read.
    private func taskLine(_ task: LeadTask, _ sessions: [String: LeadSessionInfo]?) -> String {
        var line = "- \(task.slug): \(Self.clip(task.title, 60))"
        if task.reviewLevel == .audit, ![.done, .reverted].contains(task.status) { line += " — review audit" }
        if let raised = task.riskRaised, ![.done, .reverted].contains(task.status) { line += " — audited: \(Self.clip(raised.reason, 90))" }
        if task.status == .kept { line += " — kept: \(Self.clip(task.keptBecause ?? "no reason recorded", 80))" }
        if task.status == .folded { line += " — folded into \(task.foldedInto ?? "another task")" }
        if task.status == .abandoned { line += " — abandoned: \(Self.clip(task.abandonedBecause ?? "no reason recorded", 80))" }
        if task.status == .reverted {
            line += " — reverted by \(task.merged?.revertedBy.map { String($0.prefix(8)) } ?? "?"): \(Self.clip(task.merged?.revertReason ?? "no reason recorded", 80))"
        }
        if let audits = task.audits, audits.reconsider, ![.done, .reverted].contains(task.status) {
            line += " — reconsider the approach (\(audits.reconsiderCause))"
        }
        if let audits = task.audits, !audits.open.isEmpty, ![.done, .reverted].contains(task.status) {
            let blocking = audits.blocking
            line += " — findings: " + (blocking.isEmpty ? "" : "Important open \(blocking.prefix(3).map { "\($0.id) \($0.place)" }.joined(separator: ", "))\(blocking.count > 3 ? ", …" : ""); ")
                + Self.findingsTally(audits)
        }
        if let worker = task.worker, let info = sessions?[worker] {
            line += " — worker \(info.live ? info.state(prompt: 40) : task.stopped == worker ? "stopped" : "ended")"
        }
        if let evidence = task.evidence ?? task.outdatedEvidence { line += " — " + auditText(evidence, of: task) }
        if let panel = task.panel, task.evidence == nil, task.status == .review, panel.reported.count < panel.size { line += " — audit by \(panel.progress)" }
        else if let vote = task.audits?.vote, task.evidence != nil, task.status != .done { line += " — \(vote.text)" }
        if task.rework > 0 { line += " — rework \(task.rework)" }
        if let over = task.overBudget, !LeadTeams.isFinished(task) {
            line += " — over budget: \(LeadBudget.text(task.worked ?? 0)) of \(over.minutes) min" + (over.report == nil ? ", no report yet" : "")
        }
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
            guard let verifier = task.awaitedVerifier(ended: { sessions[$0]?.live != true }) else { return nil }
            if let retry = task.verifierRetry, let second = retry.second, retry.verifiers.contains(verifier) {
                return "verifier ended twice without a verdict (\(retry.first); then \(second)), so auto_advance doesn't audit it again. read_session, then audit again or tell the user."
            }
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
    /// "load_threshold 24, twice the 12 cores, mac_max_sessions 10", as configure's refusal says them.
    static func macLimitsText(_ limits: MacLimits) -> String {
        "load_threshold \(limits.loadLimitText), mac_max_sessions \(limits.maxSessions)"
    }

    /// workflow.md's Mac-wide keys, ignored: "workflow.md's mac_max_sessions is ignored: …".
    static func ignoredText(_ workflow: LeadWorkflow) -> String {
        let keys = workflow.ignoredKeys.joined(separator: " and ")
        return "workflow.md's \(keys) \(workflow.ignoredKeys.count == 1 ? "is" : "are") ignored: the Mac-wide limits are set once for every "
            + "project in VibeSwitcher's Settings › Project lead."
    }

    /// `ignoredText`, the first time status meets ignored keys in this tool server; nil after, or with none.
    private func ignoredKeysOnce(_ workflow: LeadWorkflow) -> String? {
        guard !workflow.ignoredKeys.isEmpty else { return nil }
        tellingIgnoredKeys.lock()
        defer { tellingIgnoredKeys.unlock() }
        guard !toldIgnoredKeys else { return nil }
        toldIgnoredKeys = true
        return Self.ignoredText(workflow)
    }

    /// `LeadRecords.archiveNudge` for decisions.md as it is, the first time status finds it past the size in this tool
    /// server (once a lead start); nil after, or below it.
    private func archiveNudgeOnce() -> String? {
        tellingIgnoredKeys.lock()
        defer { tellingIgnoredKeys.unlock() }
        guard !toldArchive else { return nil }
        let path = store.recordPath(LeadRecords.Kind.decisions.name)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        let rules = "docs/process/lead-rules.md"
        let nudge = LeadRecords.archiveNudge(entries: store.decisions().count, bytes: bytes,
                                             rules: FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(rules)) ? rules : nil)
        if nudge != nil { toldArchive = true }
        return nudge
    }

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
                     "- regression_command: " + (workflow.regressionCommand.map { "`\($0)` (merge runs it after test_command)" } ?? "not set: the incidents' checks (record_incident) run only as part of test_command"),
                     "- init_command: " + (workflow.initCommand.map { "`\($0)`" } ?? "not set" + (detectedInit.map { " (suggested from the repository: `\($0)`)" } ?? "")),
                     "- base_branch: " + (raw.baseBranch ?? "not set: \(fallback) (the branch the lead first started on)"),
                     "- verifier_model: " + (workflow.verifierModel ?? "not set: audits run on \(auditModel(workflow)), another model than the workers' (\(runtime.workerModel(root: root) ?? "Claude's default"))"),
                     "- max_workers: \(workflow.maxWorkers)",
                     "- disk_warning_gb: \(Self.gb(workflow.diskWarningGB)) (the lead is told below this much free space)",
                     "- disk_floor_gb: \(Self.gb(workflow.diskFloorGB)) (start_worker refuses below it)",
                     "- test_timeout_min: \(Self.gb(workflow.testTimeoutMinutes)) (merge stops init_command and test_command past it, as hung)",
                     "- task_budget_min: " + (workflow.taskBudgetMinutes > 0 ? "\(workflow.taskBudgetMinutes) (a task's time budget, in minutes of its worker's working time, unless it sets its own)" : "0 (no time budget unless a task sets its own)"),
                     "- heavy_slots: \(heavySlotsText(workflow)) (builds and full test runs at once, Mac-wide: vs-heavy's, merges', audits'; one more waits)",
                     "- audit_finders: \(workflow.auditFinders) (" + (workflow.auditFinders == 1 ? "one verifier per audit" : "finders per audit, on one shared build and test run, with a vote; each counts against mac_max_sessions") + ")",
                     "- audit_nit_cap: \(workflow.auditNitCap) (new Nit findings one audit's vote keeps)"]
        let policy = workflow.mergePolicy.map { "\($0.rawValue) (\($0.meaning))" } ?? "not set: ask the owner once; until then merges are handled as ask_sensitive"
        lines.append("- merge_policy: \(policy)")
        lines.append("- sensitive_paths: \(workflow.sensitiveGlobs.joined(separator: ", "))\(workflow.sensitivePaths == nil ? " (the defaults)" : "")")
        lines.append("- auto_advance: " + (workflow.autoAdvance ? "true (finished work moves on by itself: merged, audited, sent back, cleaned up; planned tasks start once their after tasks are done)"
            : "false (you start, audit, merge and clean up each task yourself)"))
        lines.append("- risk_lines: " + (workflow.riskLines > 0 ? "\(workflow.riskLines) (a review none task changing more lines is audited instead of merged)" : "0 (no size trigger)"))
        lines.append("- risk_model: " + (workflow.riskModel ? "true (headless Claude may raise a review none task to audit, from the diff's stat, the contract and REVIEW.md)" : "false (the risk check's deterministic triggers only)"))
        if workflow.watchAppLogs {
            lines.append("- watch_app_logs: true (VibeSwitcher's own freezes, crashes, error lines and daily trend come to you as witness reports)")
        }
        let limits = macLimits()
        lines += ["", "Mac-wide, set by the user in VibeSwitcher's Settings › Project lead (not here; configure doesn't set them):",
                  "- load_threshold: \(limits.loadLimitText) (above this load, the greater of the 1- and 5-minute averages, start_worker and audit refuse and merge waits)",
                  "- mac_max_sessions: \(limits.maxSessions) (workers and verifiers of all projects on this Mac; start_worker and audit refuse at it)"]
        if !workflow.ignoredKeys.isEmpty { lines.append(Self.ignoredText(workflow)) }
        let warnings = workflowWarnings(workflow)
        if !warnings.isEmpty { lines += [""] + warnings }
        return lines.joined(separator: "\n")
    }

    /// How many of the latest updates the board lists.
    static let boardUpdates = 5

    /// The board in one bounded line per task, with the open questions and the latest updates; with `task`, that task
    /// in full, with the reports about it.
    private func boardText(task wanted: String?) throws -> String {
        // With the archive: every task, as before it, finished ones and all.
        let board = store.loadAll()
        let sessions = (try? listed()).map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        if let wanted, !wanted.isEmpty {
            guard let task = board.task(wanted) else { throw Problem(text: "No task \(wanted) on the board. board without task lists them.") }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var lines = [String(decoding: try encoder.encode(task), as: UTF8.self)]
            lines.append("\nReview: \(task.reviewLevel.rawValue)" + (task.merged.map { $0.unaudited ? " (merged with no audit)" : "" } ?? "")
                + (task.riskRaised.map { " (audited: \($0.reason), raised by the risk check at \($0.commit.prefix(8)))" } ?? ""))
            if let receipt = task.receipt { lines.append("\n" + receipt.line) }
            if let sessions, let ended = Self.endedMember(task, sessions) { lines.append("\nNow: \(ended)") }
            // From the vault, where only the task's own worker records it with its done (the board's copy is anyone's).
            if let kept = try? vault.unaudited(root: root, task: task.slug), let commit = kept.reported, let evidence = kept.evidence {
                lines.append("\nIts worker's evidence with its done on \(commit.prefix(8)):")
                lines += evidence.lines
            }
            if let audits = task.audits, !audits.findings.isEmpty || audits.reconsider {
                lines.append("\n" + Self.findingsText(audits, of: task.slug, answers: task.currentAnswers(audits)))
                if audits.reconsider, ![.done, .reverted].contains(task.status) { lines.append(Self.reconsiderText(audits, of: task.slug)) }
            }
            let reports = (board.reports ?? []).filter { $0.task == task.slug }
            lines.append(reports.isEmpty ? "\nNo reports about it on the board." : "\nReports about it (oldest first):")
            lines += reports.map { "- \(LeadBoard.clock($0.at)) \($0.about): \($0.text)" }
            return lines.joined(separator: "\n")
        }
        var counts: [LeadTask.Status: Int] = [:]
        // Folded tasks count with the merged ones: "12 done (3 folded)"; those cleaned up after failing as abandoned.
        for task in board.tasks { counts[task.status == .folded ? .done : task.isAbandoned ? .abandoned : task.status, default: 0] += 1 }
        let folded = board.tasks.filter { $0.status == .folded }.count
        let tally = LeadTask.Status.allCases.compactMap { state in
            counts[state].map { "\($0) \(state.rawValue)" + (state == .done && folded > 0 ? " (\(folded) folded)" : "") }
        }.joined(separator: ", ")
        var lines = ["Board of \(project) (base \(workflow.base)): \(board.tasks.count) task(s)\(tally.isEmpty ? "" : ": \(tally)"). board(task) shows one in full, with its score."]
        let scorecard = LeadScorecard(board)
        if scorecard.merged > 0 { lines.append(scorecard.line) }
        if let receipts = LeadReceiptTotals.line(board) { lines.append(receipts) }
        if board.tasks.contains(where: { !LeadTeams.isFinished($0) }) { lines.append(Self.reviewLegend) }
        lines += board.tasks.map { task in
            let ended = sessions.flatMap { Self.endedMember(task, $0) }
            // A running task whose worker ended reads so, not running.
            let state = ended.map { $0.hasPrefix("worker") ? "worker ended" : "verifier ended" } ?? (task.isAbandoned ? "abandoned" : task.status.rawValue)
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
        let board = store.load()
        let date = Date()
        let now = date.timeIntervalSince1970
        return mine.map { session in
            "- \(session.id): \(session.label) — \(session.state(now: date)) — \(session.cwd)"
                + (Self.strandedSince(session, root: root, board: board, now: now).map { " — stranded (task finished \(LeadTeams.hours(now - $0)) ago)" } ?? "")
        }.joined(separator: "\n")
    }

    /// When the task of a worker's or verifier's session that still runs, not working, finished, if over
    /// `LeadTeams.strandedAfter` ago: it has had no job since (VibeSwitcher ends such sessions; this one it couldn't).
    static func strandedSince(_ session: LeadSessionInfo, root: String, board: LeadBoard, now: Double) -> Double? {
        guard session.live, session.status.map({ !$0.hasPrefix("working") }) ?? true,
              [.worker, .verifier].contains(LeadTeams.role(label: session.label)),
              let owner = LeadTeams.root(ofWorktree: session.cwd), (owner as NSString).standardizingPath == (root as NSString).standardizingPath,
              let slug = LeadTeams.task(ofWorktree: session.cwd), let task = board.task(slug), LeadTeams.isFinished(task) else { return nil }
        let finished = LeadTeams.finishedAt(task)
        return now - finished >= LeadTeams.strandedAfter ? finished : nil
    }
}

/// What `LeadAdvance` takes its steps with: the very tools the lead calls (start_worker, audit, merge, message,
/// cleanup), with every check they make, and the lead's own report channel.
extension LeadToolset {
    /// Whether VibeSwitcher moves `slug` on by itself: a lead's loop runs (see `LeadAdvance.running`), workflow.md's
    /// auto_advance is on, the task doesn't opt out, and the lead doesn't hold it (kept, blocked, folded, abandoned).
    func advances(_ slug: String) -> Bool {
        guard LeadAdvance.running(store), workflow.autoAdvance, let task = store.load().task(slug), task.autoAdvance != false else { return false }
        return ![.kept, .blocked, .folded, .abandoned, .reverted].contains(task.status)
    }

    func advanceStart(_ slug: String, when: @escaping (LeadTask) -> Bool) throws -> MCPToolResult { try startWorker(slug, when: when) }
    func advanceAudit(_ slug: String) throws -> MCPToolResult { try audit(slug) }
    func advanceMerge(_ slug: String) throws -> MCPToolResult {
        let merged = try merge(slug)
        records.flush(base: base)
        return merged
    }
    func advanceCleanup(_ slug: String) throws -> MCPToolResult { try cleanup(slug, force: false) }
    func advanceMessage(_ slug: String, _ text: String, clearDraft: Bool) throws -> (delivered: LeadDelivery.Delivered, result: MCPToolResult) {
        try sent(slug, ["text": text, "clear_draft": clearDraft])
    }
    func advanceTell(_ text: String) throws -> Bool { try tellLead(text, about: LeadAdvance.sender) }
    func advanceReviewNeeded(_ slug: String, commit: String?) -> String? { reviewNeeded(slug, commit: commit, model: true) }
    func advanceHead(_ slug: String) -> String? { branchHead(Worktrees.branch(slug)) }
    func advanceSessions() throws -> [LeadSessionInfo] { try hostSessions("the session host can't be read") }
    func advanceExclusively<T>(_ body: () throws -> T) throws -> T { try exclusively("advance", body) }
    /// `body` while no configure is between writing workflow.md and recording it in the vault.
    func advanceSettled<T>(_ body: () throws -> T) throws -> T { try exclusively("configure", body) }
    /// No merge of `slug`, nor into the base branch, is under way (merge's own locks, looked at and let go).
    func mergeIdle(_ slug: String) -> Bool {
        let base = self.base
        let locks = [(store.folder as NSString).appendingPathComponent("run/merge-\(slug).lock"),
                     vault.scratch(root: root, "merge-into-\(LeadVault.hash(base).prefix(16)).lock").path]
        for path in locks {
            guard let lock = FileLock.attempt(path) else { return false }
            lock.release()
        }
        return true
    }
}

/// An audit by several finders (audit_finders 2 or 3), each with its own focus, voted into one verdict and one set
/// of findings, by a rule that needs no model: findings match on file, kind (severity) and line (within
/// `lineTolerance`), and a finding most finders raised is kept open, the rest kept as unconfirmed. An earlier round's
/// finding is closed when most finders say it's fixed or dismissed; an unconfirmed one is confirmed when most raise
/// it again. New Nits beyond the cap are left out, counted. The verdict is each part's majority (the worse one
/// without a majority); an integrity violation any finder reports makes it at least suspect.
public enum LeadAuditVote {
    /// One finder's verdict and findings, as it submitted them.
    public struct Ballot: Codable, Equatable, Sendable {
        /// 1-based.
        public var finder: Int
        public var focus: String
        public var completion: LeadEvidence.Completion
        public var integrity: LeadEvidence.Integrity
        public var summary: String
        public var findings: [LeadFinding.Report]
        /// How its tests went, as it said (optional: ballots from before it was asked have none).
        public var tests: LeadVault.TestRun?

        public init(finder: Int, focus: String, completion: LeadEvidence.Completion, integrity: LeadEvidence.Integrity,
                    summary: String, findings: [LeadFinding.Report], tests: LeadVault.TestRun? = nil) {
            self.finder = finder
            self.focus = focus
            self.completion = completion
            self.integrity = integrity
            self.summary = summary
            self.findings = findings
            self.tests = tests
        }

        public var passes: Bool { completion == .complete && integrity == .clean }
    }

    /// How a vote went, kept on the ledger (the board and status show it).
    public struct Outcome: Codable, Equatable, Sendable {
        public var finders: Int
        public var focuses: [String]
        /// New findings most finders raised, and the ones fewer did.
        public var confirmed: Int
        public var unconfirmed: Int
        /// New Nits past audit_nit_cap, left out.
        public var nitsLeftOut: Int
        /// The cap they were held to.
        public var nitCap: Int

        public init(finders: Int, focuses: [String], confirmed: Int, unconfirmed: Int, nitsLeftOut: Int, nitCap: Int) {
            self.finders = finders
            self.focuses = focuses
            self.confirmed = confirmed
            self.unconfirmed = unconfirmed
            self.nitsLeftOut = nitsLeftOut
            self.nitCap = nitCap
        }

        /// "3 finders voted: 2 new findings confirmed, 1 unconfirmed, 2 Nits past audit_nit_cap (5) left out".
        public var text: String {
            var text = "\(finders) finders voted: \(confirmed) new finding\(confirmed == 1 ? "" : "s") confirmed, \(unconfirmed) unconfirmed"
            if nitsLeftOut > 0 { text += ", \(nitsLeftOut) Nit\(nitsLeftOut == 1 ? "" : "s") past audit_nit_cap (\(nitCap)) left out" }
            return text
        }
    }

    /// What a vote gives the ledger and the verdict.
    public struct Result: Equatable, Sendable {
        /// Earlier rounds' findings as voted, and the new ones a majority raised.
        public var reports: [LeadFinding.Report]
        /// New findings fewer than most raised.
        public var unconfirmed: [LeadFinding.Report]
        public var completion: LeadEvidence.Completion
        public var integrity: LeadEvidence.Integrity
        public var summary: String
        public var outcome: Outcome
        /// Failed when any finder's did; passed when one's did and none failed; nil when none said either.
        public var tests: LeadVault.TestRun? = nil

        public var passes: Bool { completion == .complete && integrity == .clean }
    }

    /// How far apart two finders' lines may be for the same finding (they point at a statement from different ends).
    public static let lineTolerance = 3

    /// More than half of `size`.
    static func majority(_ count: Int, of size: Int) -> Bool { count * 2 > size }

    /// The finders' ballots (one each, `size` in all) voted against the task's ledger as it was before this audit.
    public static func tally(_ ballots: [Ballot], size: Int, ledger: LeadAuditLedger, nitCap: Int) -> Result {
        // Earlier rounds' findings: each finder's word on each, by id (or, raised again, at an unconfirmed one's place).
        var marks: [String: [(finder: Int, report: LeadFinding.Report)]] = [:]
        var order: [String] = []
        struct Group {
            var file: String
            var severity: LeadFinding.Severity
            var line: Int
            var finders: [Int]
            var evidence: String
            var index: Int
            /// Others raised at its very place with another severity (the ledger keeps one finding per place).
            var also: [String] = []
        }
        var groups: [Group] = []
        for ballot in ballots {
            for report in ballot.findings {
                let named = report.id.flatMap(ledger.finding)
                    ?? (report.status == .open ? ledger.findings.first { $0.status == .unconfirmed && $0.file == report.file && $0.line == report.line
                        && $0.severity == report.severity } : nil)
                if let finding = named {
                    guard !(marks[finding.id] ?? []).contains(where: { $0.finder == ballot.finder }) else { continue }
                    if marks[finding.id] == nil { order.append(finding.id) }
                    marks[finding.id, default: []].append((ballot.finder, report))
                    continue
                }
                if let at = groups.firstIndex(where: { $0.file == report.file && $0.severity == report.severity
                    && abs($0.line - report.line) <= lineTolerance && !$0.finders.contains(ballot.finder) }) {
                    groups[at].finders.append(ballot.finder)
                } else {
                    groups.append(Group(file: report.file, severity: report.severity, line: report.line, finders: [ballot.finder],
                                        evidence: report.evidence, index: groups.count))
                }
            }
        }

        var reports: [LeadFinding.Report] = []
        for id in order {
            guard let finding = ledger.finding(id), finding.isLive, let said = marks[id] else { continue }
            let fixed = said.filter { $0.report.status == .fixed }, dismissed = said.filter { $0.report.status == .dismissed }
            let open = said.filter { $0.report.status == .open }
            var report = LeadFinding.Report(id: finding.id, severity: finding.severity, file: finding.file, line: finding.line,
                                            evidence: open.first?.report.evidence ?? finding.evidence)
            if majority(fixed.count + dismissed.count, of: size) {
                let closing = fixed.count >= dismissed.count ? fixed : dismissed
                report.status = closing[0].report.status
                report.reason = closing.compactMap(\.report.reason).first
            } else if finding.status == .unconfirmed {
                // Confirmed only when most raise it again; else it stays as it is.
                guard majority(open.count, of: size) else { continue }
            }
            reports.append(report)
        }

        // New findings: confirmed ones first, then the more severe, the more seen, the earlier.
        let rank = { (severity: LeadFinding.Severity) in LeadFinding.Severity.allCases.firstIndex(of: severity) ?? 0 }
        let ranked = groups.sorted { a, b in
            let (confirmedA, confirmedB) = (majority(a.finders.count, of: size), majority(b.finders.count, of: size))
            if confirmedA != confirmedB { return confirmedA }
            if a.severity != b.severity { return rank(a.severity) < rank(b.severity) }
            if a.finders.count != b.finders.count { return a.finders.count > b.finders.count }
            return a.index < b.index
        }
        var kept: [Group] = []
        for group in ranked {
            // At a place a more severe or confirmed one holds, folded into it, so it stays in view; one more severe than
            // what holds its place (it's unconfirmed then: confirmed ones come first) stays a finding of its own, so a
            // severity is never lowered by where it is.
            if let at = kept.firstIndex(where: { $0.file == group.file && $0.line == group.line }),
               rank(group.severity) >= rank(kept[at].severity) {
                kept[at].also.append("also raised here as \(group.severity.rawValue) by \(group.finders.sorted().map { "finder \($0)" }.joined(separator: ", ")): \(group.evidence)")
            } else {
                kept.append(group)
            }
        }
        var nits = 0, nitsLeftOut = 0
        var confirmed: [Group] = [], unconfirmed: [Group] = []
        for group in kept {
            if group.severity == .nit {
                guard nits < nitCap else { nitsLeftOut += 1; continue }
                nits += 1
            }
            if majority(group.finders.count, of: size) { confirmed.append(group) } else { unconfirmed.append(group) }
        }
        let byFocus = Dictionary(ballots.map { ($0.finder, $0.focus) }, uniquingKeysWith: { a, _ in a })
        let who = { (finders: [Int]) in finders.sorted().map { "finder \($0)" + (byFocus[$0].map { " (\($0))" } ?? "") }.joined(separator: ", ") }
        // In the order the finders raised them.
        reports += confirmed.sorted { $0.index < $1.index }.map { group in
            LeadFinding.Report(severity: group.severity, file: group.file, line: group.line,
                               evidence: group.evidence + " [\(group.finders.count) of \(size) finders]" + group.also.map { "; \($0)" }.joined())
        }
        let doubted = unconfirmed.sorted { $0.index < $1.index }.map { group in
            LeadFinding.Report(severity: group.severity, file: group.file, line: group.line,
                               evidence: group.evidence + group.also.map { "; \($0)" }.joined(), status: .unconfirmed,
                               reason: "\(group.finders.count) of \(size) finders saw it: \(who(group.finders))")
        }

        let completion = verdict(ballots.map(\.completion), size: size, worse: [.complete, .incomplete, .blocked])
        var integrity = verdict(ballots.map(\.integrity), size: size, worse: [.clean, .suspect, .violation])
        if integrity == .clean, ballots.contains(where: { $0.integrity == .violation }) { integrity = .suspect }
        let outcome = Outcome(finders: size, focuses: ballots.map(\.focus), confirmed: confirmed.count, unconfirmed: unconfirmed.count,
                              nitsLeftOut: nitsLeftOut, nitCap: nitCap)
        let summary = ballots.map { "Finder \($0.finder) (\($0.focus); \($0.completion.rawValue), \($0.integrity.rawValue)): \($0.summary)" }
            .joined(separator: "\n") + "\n" + outcome.text + "."
        let said = ballots.compactMap(\.tests)
        let tests: LeadVault.TestRun? = said.contains(.failed) ? .failed : said.contains(.passed) ? .passed : said.first
        return Result(reports: reports, unconfirmed: doubted, completion: completion, integrity: integrity, summary: summary, outcome: outcome, tests: tests)
    }

    /// What most said; without a majority, the worst any said (`worse`: best first).
    static func verdict<T: Equatable>(_ said: [T], size: Int, worse: [T]) -> T {
        if let most = worse.first(where: { value in majority(said.filter { $0 == value }.count, of: size) }) { return most }
        return said.max { (worse.firstIndex(of: $0) ?? 0) < (worse.firstIndex(of: $1) ?? 0) } ?? worse[worse.count - 1]
    }
}
