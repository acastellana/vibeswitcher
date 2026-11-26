import Foundation
import VibeCore

/// A start asked for before the host said which sessions run (`LeadEngine.pendingStarts`).
struct PendingStart {
    var goal: String?
    var takeHead: Bool
    var replace: Bool
    /// Reopen the lead a host restart ended, in its same conversation (`RestartResume.swift`).
    var resume = false
}

/// A request waiting on a start under way (`LeadEngine.starting`): what it asked, the program found for it, and who
/// hears what became of it.
struct JoinedStart {
    var start: PendingStart
    var program: String
    var completion: (LeadEngine.StartOutcome) -> Void
}

/// Starting a project's lead (the engine plan's E4; the app's `LeadController.startLead` and its neighbours,
/// `LeadController.swift` 801-1116, without their dialogs): what the app asks in a modal dialog is a flag here.
/// `takeHead` (`askToTakeHead`): without it a moved base stays checked, and merges stay refused until `base accept`.
/// `replace` (`askToReplace`): without it a running lead without its role is shown, not replaced, and the reply says how
/// to replace it. A folder with no commit (the app's first-commit offer) and an older host (the app's restart offer)
/// are refusals. The lead's program is `claude` as `NodePreflight` finds it (EN-D13), its tool server
/// `<node-root>/bin/vibeswitcher-mcp` (S9); no review floor is seeded (EN-D7: `config accept` records it).
extension LeadEngine {
    /// What a start does with the lead that may be running already (the app's `StartPlan`, copied).
    public enum StartPlan: Equatable, Sendable {
        /// The host hasn't said yet which sessions run (the link isn't welcomed): decided once it has.
        case wait
        /// No lead runs for the project.
        case start
        /// The lead runs (and holds its role, or nothing here may replace it): shown, never replaced.
        case show(UUID)
        /// The lead runs without its role (the vault binds it to no session, or another): replaced only when asked.
        case askToReplace(UUID)
    }

    /// `running`: the project's live lead session, if any; `holdsRole`: whether the vault binds the lead's role to it
    /// (nil: the vault couldn't be asked); `fromUser`: the user asked (the app's `plan(hostState:…)`, copied, on the
    /// link's state).
    public static func plan(hostState: HostLink.State, running: UUID?, holdsRole: Bool?, fromUser: Bool) -> StartPlan {
        if hostState == .connecting { return .wait }
        guard let running else { return .start }
        return holdsRole == false && fromUser ? .askToReplace(running) : .show(running)
    }

    /// What the lead's start prompt says of the goal it was given (the app's `commandLineNote`, for this node).
    public static let goalNote = "typed by the user at this node's command line (vibeswitcher lead, confirmed with a typed code): "
        + "the user's voice, a guard rail before signed approvals"
    /// Who a goal for a running lead is held as from.
    static let goalSender = SteerMessage.Sender.system("vibeswitcher lead on this node's command line; \(goalNote)")

    /// Starts the project lead for the repository holding `folder`, or shows the one already running; `completion`
    /// (on `queue`) hears what it did. A `goal` goes into a new lead's first prompt, or is held for the running one (E5
    /// delivers it). `resume`: reopen the lead a host restart ended, in its same conversation (`RestartResume.swift`).
    /// `initialized`: `lead --init` made the repository at `folder` just now (`LeadInit`): before any git of the guard's
    /// runs there, its hooks baseline is recorded empty (`GitGuard.accept(only: [])`), so a hook a session put in its
    /// `.git` between the install and this start is listed, never run, until the lead accepts it.
    /// `stillMade`: why `folder` is no longer what its caller made (nil: it is), asked before the baseline is recorded (with
    /// no root) and again once the repository is found (with its top), off the engine's queue: `project.new`'s pin
    /// (`ProjectMaker.stillMade`), so a folder swapped after the make sends the start nowhere else. From any thread.
    public func startLead(folder: String, goal: String?, takeHead: Bool, replace: Bool, resume: Bool = false, initialized: Bool = false,
                          stillMade: ((_ root: String?) -> String?)? = nil, completion: @escaping (StartOutcome) -> Void) {
        let (preflight, looked) = (self.preflight, preflightLooked)
        // git can be slow: the repository is found off the engine's queue, and first what's missing (without git, git
        // below would only say the folder isn't a repository).
        work.async { [weak self] in
            if let why = stillMade?(nil) {
                self?.queue.async { completion(.refused(why)) }
                return
            }
            if initialized {
                do { _ = try GitGuard.accept(root: folder, only: [], baseline: true) } catch {
                    self?.queue.async { completion(.refused("the new repository's hooks baseline couldn't be recorded (\(error)): the lead wasn't started")) }
                    return
                }
            }
            var found = Self.repository(folder, preflight: preflight, looked: looked)
            if let root = found.root, let why = stillMade?(root) { found = (nil, nil, why) }
            guard let self else { return }
            self.queue.async {
                guard let root = found.root, let program = found.program else {
                    let why = found.why ?? "the lead wasn't started"
                    self.note("lead: not started in \(ConfigSeal.inert(folder, limit: 200)): \(why)")
                    return completion(.refused(why))
                }
                self.begin(root: root, program: program, start: PendingStart(goal: goal, takeHead: takeHead, replace: replace, resume: resume),
                           completion: completion)
            }
        }
    }

    /// The program the lead runs and the top of the repository holding `folder`, or why there's none: what's missing
    /// first, then a folder in no repository, then one with no commit (workers branch from one).
    static func repository(_ folder: String, preflight: NodePreflight, looked: () -> Void = {}) -> (root: String?, program: String?, why: String?) {
        let program: String
        looked()
        switch preflight.check() {
        case .failure(let refusal): return (nil, nil, refusal.description)
        case .success(let path): program = path
        }
        let top = Git.run(["rev-parse", "--show-toplevel"], in: folder)
        guard top.ok, !top.output.isEmpty else {
            return (nil, nil, "\(folder) isn't in a git repository: a lead needs one (git init, and a first commit; `vibeswitcher lead FOLDER --init` makes them)")
        }
        let root = (top.output as NSString).standardizingPath
        guard Git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root).ok else {
            return (nil, nil, "\(root) has no commits yet: workers branch from a commit; make one (git add, git commit), then start the lead")
        }
        return (root, program, nil)
    }

    /// The start for `root`, on `queue`: joined to one under way (and taken up, as asked, once that one is over);
    /// held until the host's welcome; else the running lead read (off the queue) and the plan made.
    func begin(root: String, program: String, start: PendingStart, completion: @escaping (StartOutcome) -> Void) {
        guard !stopping else { return completion(.refused(Self.stoppingRefusal)) }
        if case .gone(let why) = link.state { return completion(.refused("the session host is gone (\(why))")) }
        if start.resume, start.goal != nil { return completion(.refused("--resume takes no goal: give it once the lead is reopened")) }
        // One start per root at a time: a second ask waits for the first, then goes on with what it asked (`finish`).
        if starting[root] != nil {
            starting[root]?.append(JoinedStart(start: start, program: program, completion: completion))
            note("lead: a start of \(LeadMail.project(of: root)) waits for the one under way")
            return
        }
        // Before the welcome the host's sessions aren't known: no sign no lead runs. Held until then (the app's
        // pendingStarts), each as asked; the request hears it waits.
        if link.state == .connecting {
            pendingStarts[root, default: (program, [])].starts.append(start)
            leads.lead(root: root) { $0.lastStart = "waiting for the host's welcome"; $0.lastStartAt = Date() }
            note("lead: the start of \(LeadMail.project(of: root)) waits for the host's welcome")
            return completion(.waiting)
        }
        // Only now: the welcome is what says the host restarted (`restartLook`), so a reopen asked before it is decided
        // on the restart it brought.
        if start.resume, let refusal = reopenRefusal(root: root) { return completion(.refused(refusal)) }
        starting[root] = [JoinedStart(start: start, program: program, completion: completion)]
        leads.lead(root: root) { $0.starting = true }
        // Which lead runs for the root, the board read on the reads queue (even its stat waited seconds on a busy disk).
        let sessions = link.sessions
        reads.async({ files -> (running: HostSession?, named: String?) in
            let named = files.names.board(root).leadSession
            return (LeadStore.leadSessions(sessions) { $0 == root ? named : files.names.board($0).leadSession }[root], named)
        }) { [weak self] found in
            guard let self else { return }
            self.holders[root] = found.named.flatMap(UUID.init(uuidString:))
            self.leads.lead(root: root) { $0.named = found.named }
            self.decide(root: root, program: program, start: start, running: found.running)
        }
    }

    /// The starts that waited for the host's sessions, decided now that they're known. On `queue`.
    func startPending() {
        guard link.state == .connected, !pendingStarts.isEmpty else { return }
        let pending = pendingStarts
        pendingStarts = [:]
        for (root, waited) in pending {
            // One start with every flag asked and the first goal (a new lead's first prompt says it); each other goal
            // a start of its own, which joins that one and then is held for the lead it leaves (`finish`). In the
            // order asked, here on the queue.
            let goals = waited.starts.compactMap(\.goal)
            let first = PendingStart(goal: goals.first, takeHead: waited.starts.contains { $0.takeHead },
                                     replace: waited.starts.contains { $0.replace }, resume: waited.starts.contains { $0.resume })
            for start in [first] + goals.dropFirst().map({ PendingStart(goal: $0, takeHead: false, replace: false) }) {
                let begun: @Sendable () -> Void = { [weak self] in
                    self?.begin(root: root, program: waited.program, start: start) { [weak self] outcome in
                        self?.note("lead: the start of \(LeadMail.project(of: root)) that waited for the welcome: \(Self.word(outcome))")
                    }
                }
                // A reopen is decided on the restart this welcome brings (`welcomed` looks for it after this): next on
                // the queue, after the welcome.
                if start.resume { queue.async { begun() } } else { begun() }
            }
        }
    }

    /// The link dropped while the start of `root` went on: it waits for the next welcome again, ahead of what joined
    /// it, and the request hears it waits. On `queue`.
    private func waitAgain(root: String, program: String, start: PendingStart) {
        pendingStarts[root, default: (program, [])].starts.insert(start, at: 0)
        finish(root: root, .waiting)
    }

    /// `running`: the project's live lead session. Whether it holds its role, the vault says (off the queue: a call to
    /// the host); held, it's bound to its session again, as at a server start.
    private func decide(root: String, program: String, start: PendingStart, running: HostSession?) {
        guard let running else {
            return prepare(root: root, program: program, start: start, running: nil)
        }
        let vault = link.vault
        work.async { [weak self] in
            let holds: Bool?
            do { holds = try vault.rebindLead(root: root, session: running.id.uuidString) != nil } catch { holds = nil }
            guard let self else { return }
            self.queue.async {
                self.leads.lead(root: root) { $0.bound = holds == true ? running.id.uuidString : $0.bound }
                switch Self.plan(hostState: self.link.state, running: running.id, holdsRole: holds, fromUser: true) {
                case .wait:
                    self.waitAgain(root: root, program: program, start: start)
                case .start:
                    self.prepare(root: root, program: program, start: start, running: running)
                case .show(let id):
                    var notes: [String] = []
                    if let goal = start.goal {
                        self.leads.hold(.init(text: "New goal: \(goal)", from: Self.goalSender), root: root)
                        notes.append("the goal is held for the running lead until it can be delivered")
                    }
                    if start.resume { notes.append("a lead runs there already: nothing was reopened") }
                    if start.takeHead {
                        notes.append("--take-head takes the base branch as it is only when a lead starts: the running lead's stays as recorded "
                            + "(`vibeswitcher base accept` takes it)")
                    }
                    self.finish(root: root, .shown(session: id, notes: notes))
                case .askToReplace(let id):
                    guard start.replace else {
                        var notes = [
                            "the lead of \(LeadMail.project(of: root)) runs (session \(id.uuidString.prefix(8))) without its role, so its tools are off: "
                                + "nothing was started; `vibeswitcher lead \(root) --replace` starts a new lead, which takes the role, reads its last "
                                + "turns and gets what waited for it",
                        ]
                        if start.goal != nil { notes.append("the goal wasn't held: a lead without its role gets nothing; give it again with --replace") }
                        return self.finish(root: root, .shown(session: id, notes: notes))
                    }
                    self.prepare(root: root, program: program, start: start, running: running)
                }
            }
        }
    }

    /// Prepares the lead (off the queue: git, the board's folder, the vault) and spawns it. `running`: the lead this
    /// start may replace.
    private func prepare(root: String, program: String, start: PendingStart, running: HostSession?) {
        // The welcome's capabilities are known only while the link is welcomed: one that dropped since the request
        // was taken waits for the next welcome (its capabilities are empty meanwhile), one that's gone is refused.
        switch link.state {
        case .gone(let why): return finish(root: root, .refused("the session host is gone (\(why))"))
        case .connecting: return waitAgain(root: root, program: program, start: start)
        case .connected: break
        }
        // The lead's vault lives in the session host: one too old to hold it is a build switch away (host and server
        // are one build on Linux).
        guard link.capabilities.contains(HostProtocol.Capability.leadVault) else {
            return finish(root: root, .refused("the session host is an older build than its server (it doesn't keep the lead's vault): switch builds"))
        }
        guard let server = toolServer else {
            return finish(root: root, .refused("the server has no --node-root, so the lead's tool server isn't known"))
        }
        let project = (root as NSString).lastPathComponent
        let vault = link.vault
        let (firstLook, nodeRoot, temporary, home) = (options.firstLook, self.root, temporaryRoot, self.home)
        // Where the conversation of the lead this start may replace is: the new lead reads its last turns. Only a
        // session the host started in this root (its own cwd, not the agent's): another project's conversation never
        // goes into this lead's first prompt.
        let transcripts = Dictionary((sessions?.sessions ?? []).compactMap { session in
            session.startFolder.map { ($0 as NSString).standardizingPath } == root
                ? session.hostID.flatMap { id in session.transcriptPath.map { (id.uuidString, $0) } } : nil
        }, uniquingKeysWith: { $1 })
        let hosted = link.sessions
        let record = start.resume ? reopen[root] : nil
        let records = reopen
        // A record kept for this project: a fresh start that leaves the old lead's messages says how to take them.
        let reopenable = !start.resume && reopen[root] != nil
        work.async { [weak self] in
            var issued: String?
            var waiting: [SteerMessage] = []
            var replaced: UUID?
            var notes: [String] = []
            var resumed: (conversation: String, transcript: String)?
            let prepared = Result<(grant: String, launch: LeadLaunch.Prepared, run: LeadLaunch.Run), Error> {
                let boardStore = BoardStore(root: root)
                let workflowPath = try boardStore.prepare()
                var workflow = LeadWorkflow.load(from: workflowPath)
                workflow.baseBranch = workflow.baseBranch ?? boardStore.load().baseBranch
                let branch = workflow.baseBranch ?? Worktrees.mainBranch(root: root)
                // S7: a fresh vault takes nothing from disk as its baseline: the lead starts once the user accepted the
                // config held and recorded the base's head.
                if firstLook, let refusal = try Self.firstLookRefusal(vault: vault, root: root, branch: branch) { throw Refused(refusal) }
                // A reopen after a host restart: the conversation its record names, only once it checks out.
                if start.resume {
                    resumed = try Self.resumable(record, root: root, home: home).get()
                    notes.append("reopened in its same conversation (\(resumed?.conversation ?? "")), told which workers ended with the restart")
                }
                // Merges check nothing else moved the branch since the lead last left it; the start takes the branch
                // as it is only with --take-head.
                if !start.takeHead, let moved = vault.headMoved(root: root, branch: branch) {
                    notes.append("\(branch) moved since the lead last left it (\(moved.recorded.prefix(8)) to \(moved.now.prefix(8))), not through "
                        + "its merges: kept checked, so merges stay refused until `vibeswitcher base accept`; `--take-head` takes it as it is")
                }
                // The session the vault binds this root's lead role to until the new lead's is bound: a lead that ended
                // is the one replaced only when it's that one (`replacedLead`).
                let bound = vault.current(.lead, root: root, task: nil)?.session
                // EN-D7: no floor: on Linux `config accept` records the one workflow.md proposes.
                let grant = try vault.startLead(root: root, branch: branch, takeHead: start.takeHead)
                issued = grant
                // The role is the new session's from now on: the lead it replaces gets nothing more, and what waited
                // for it goes to the new one (`LeadHandover`). The board is the repository's, which any process of the
                // user's can write: the lead it named is the one replaced only when the host runs (or ran) it as this
                // root's lead on that terminal (`replacedLead`), else its inbox and its turns stay where they are, said.
                let named = try boardStore.update { LeadHandover.release(&$0) }
                let verified = Self.replacedLead(named, root: root, hosted: hosted, bound: bound)
                // The user's own `lead --resume` after a restart they made (stop, start: the fresh vault binds no one,
                // the host lists no old session): the lead it reopens in its same conversation takes what waited for
                // the session the board names, when that is the session the node's reopen record names, whose
                // conversation this start just checked (`resumable`).
                let reopenedFrom = verified == nil
                    ? Self.reopenedLead(named, record: record, resumed: resumed != nil, hosted: hosted, records: records, root: root) : nil
                if let verified {
                    waiting = LeadHandover.takeWaiting(for: verified, root: nodeRoot)
                } else if let reopenedFrom {
                    let (taken, left) = Self.takeWaiting(for: reopenedFrom, root: nodeRoot)
                    waiting = taken
                    if !taken.isEmpty || left > 0 {
                        notes.append("took the \(taken.count) message(s) waiting for the lead it reopens (session "
                            + "\(ConfigSeal.inert(reopenedFrom.session ?? "", limit: 40)), its same conversation)"
                            + (left == 0 ? "" : "; \(left) more stay in its inbox, past the \(Self.reopenTakesMost) messages or \(Self.reopenTakesBytes >> 10) KiB "
                                + "a reopen takes: \(nodeRoot.appendingPathComponent("steer/\(reopenedFrom.tty).jsonl").path) holds them, one JSON line each, "
                                + "to read, never to run"))
                    }
                }
                if verified == nil, reopenedFrom == nil, let named, let left = Self.leftWaiting(named, root: nodeRoot) {
                    notes.append("the board named session \(ConfigSeal.inert(named.session ?? "none", limit: 40)) on "
                        + "\(ConfigSeal.inert(named.tty, limit: 40)) as the lead, which isn't known to be this project's lead (not live here, nor the "
                        + "ended session the vault binds the role to): the \(left) message(s) waiting in its inbox stay there"
                        + (reopenable ? " (`vibeswitcher lead \(root) --resume` reopens that lead in its same conversation and takes them)" : ""))
                }
                let name = "lead-\(Slug.make(project, taken: []))"
                var handed: (tty: String, turnsFile: String)?
                let old = verified.flatMap { $0.session.flatMap(UUID.init(uuidString:)) } ?? running?.id
                if let old, let tty = verified?.tty ?? running?.tty {
                    replaced = old
                    // A reopened lead carries on its own conversation: no turns handed over.
                    if resumed == nil {
                        let transcript = transcripts[old.uuidString]
                            ?? running.flatMap { TranscriptLocator.claude(cwd: root, name: name, startedAt: $0.startedAt, home: home) }
                        let turns = transcript.flatMap { LastTurns.read(transcript: $0, tty: tty, home: home) }
                        if let file = try LeadLaunch.writeTurns(turns, root: root) { handed = (tty, file) }
                    }
                }
                let policy = WorkingPolicy.load(from: nodeRoot.appendingPathComponent("policy.md"))
                let limits = MacLimits.load(from: nodeRoot.appendingPathComponent(MacLimits.fileName))
                // lead_model (Fable unless set), Opus while Fable is held back; lead_advisor only on Opus.
                let base = RecentProjects.shellQuote(program)
                let run = Self.leadRun(workflow, base: base, nodeRoot: nodeRoot, home: home)
                let launch = try LeadLaunch.prepare(
                    role: .lead, root: root, task: nil, base: base,
                    prompt: LeadPrompts.lead(project: project, root: root, workflow: workflow, policy: policy, limits: limits),
                    start: resumed == nil ? LeadPrompts.leadStart(root: root, goal: start.goal, note: Self.goalNote, replaced: handed)
                        : Self.notice(board: boardStore.load(), root: root),
                    server: server, name: name, model: run.model, advisor: run.advisor,
                    folder: vault.runFolder(root: root, name: name), cwd: root, temporary: temporary, resume: resumed?.conversation)
                return (grant, launch, run)
            }
            if case .failure = prepared, let issued { try? vault.revoke(issued, root: root) }
            guard let self else { return }
            let (taken, replacedLead, said, reopened) = (waiting, replaced, notes, resumed)
            self.queue.async {
                for message in taken { self.leads.hold(.init(text: message.text, from: message.from), root: root) }
                self.withdrewFromInbox(taken.map(\.id))
                switch prepared {
                case .failure(let error):
                    self.finish(root: root, .refused("\(error)"))
                case .success(let (grant, launch, run)):
                    // The board names no lead now (`LeadHandover.release`); one replaced is so from now, no board read waited for.
                    self.holders[root] = nil
                    self.leads.lead(root: root) { $0.named = nil }
                    if let replacedLead { self.leads.replacing(replacedLead, root: root) }
                    self.spawn(root: root, project: project, program: program, grant: grant, launch: launch, notes: said, run: run, resumed: reopened)
                }
            }
        }
    }

    /// The lead the board named (`named`, as `LeadHandover.release` took it off) as the lead a start of `root` replaces:
    /// only a session the host lists (`hosted`), labelled as a lead, started in `root`, on the terminal the board names,
    /// and either live or, ended (a crash, the close-out review), the session the vault binds this root's lead role to
    /// (`bound`), its terminal taken by no live session since (whose messages its inbox would hold). A board naming
    /// another project's session, or this one's on another terminal, replaces nothing: its inbox isn't emptied into this
    /// lead and its conversation isn't read into this lead's first prompt.
    static func replacedLead(_ named: LeadAgent?, root: String, hosted: [HostSession], bound: String?) -> LeadAgent? {
        guard let named, let id = named.session.flatMap(UUID.init(uuidString:)),
              let session = hosted.first(where: { $0.id == id }), LeadTeams.role(label: session.label) == .lead,
              (session.cwd as NSString).standardizingPath == root, session.tty == named.tty else { return nil }
        if !session.isLive {
            guard bound?.lowercased() == id.uuidString.lowercased(), !hosted.contains(where: { $0.isLive && $0.tty == session.tty }) else { return nil }
        }
        return LeadAgent(pid: named.pid, tty: session.tty, session: session.id.uuidString)
    }

    /// The lead a `lead --resume` reopens (`resumed`: its conversation checked out), from the node's own reopen record
    /// (`record`, which `noteReopen` writes from its scan: the session, its terminal and its agent's pid), never from the
    /// board, which any session can write: what waited in that terminal's inbox for that agent is the reopened lead's.
    /// Nil, so nothing is taken, unless the board names the same session, terminal and pid; no live hosted session holds
    /// that terminal; the pid is no live process (it would be another session's now); and no other root's record names
    /// that terminal. The vault can't vouch for the old session after the restart (it binds no one): the user's voice
    /// named the project and the resume, and what is taken is checked by its seal or marked not vouched for.
    static func reopenedLead(_ named: LeadAgent?, record: EngineState.Reopen?, resumed: Bool, hosted: [HostSession],
                             records: [String: EngineState.Reopen], root: String, alive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) -> LeadAgent? {
        guard resumed, let named, let record, let tty = record.tty, let pid = record.pid,
              named.session?.lowercased() == record.session.lowercased(), named.tty == tty, named.pid == pid,
              !hosted.contains(where: { $0.isLive && $0.tty == tty }), !alive(pid),
              !records.contains(where: { $0.key != root && $0.value.tty == tty }) else { return nil }
        return LeadAgent(pid: pid, tty: tty, session: record.session)
    }

    /// The most messages, and bytes of their text, a reopen takes from the old lead's inbox: the rest stay, said.
    static let reopenTakesMost = 50
    static let reopenTakesBytes = 256 << 10

    /// What waited for `lead` in its inbox, taken in order up to `most` messages or `bytes` of text, each verified by its
    /// seal or marked not vouched for (as `LeadHandover.takeWaiting`); and how many were left.
    static func takeWaiting(for lead: LeadAgent, root: URL, most: Int = reopenTakesMost, bytes: Int = reopenTakesBytes) -> (taken: [SteerMessage], left: Int) {
        let pending = SteerInbox.pending(tty: lead.tty, root: root).filter { $0.agentPid == lead.pid }
        var chosen: [SteerMessage] = []
        var size = 0
        for message in pending {
            let length = message.text.utf8.count
            guard chosen.count < most, size + length <= bytes else { break }
            chosen.append(message)
            size += length
        }
        let taken = chosen.compactMap { SteerInbox.withdraw(id: $0.id, tty: lead.tty, root: root) }
        guard !taken.isEmpty else { return ([], pending.count) }
        let valid = SteerSeal.for(root).verify(taken).flatMap { $0.count == taken.count ? $0 : nil } ?? taken.map { _ in false }
        let checked = zip(taken, valid).map { message, valid in
            valid ? message : SteerInbox.unverified(message, user: "a message for the lead this one reopened, marked as the user's but not vouched for")
        }
        return (checked, pending.count - taken.count)
    }

    /// How many messages wait for the lead the board named in its inbox (`named`'s terminal, for its agent), when the
    /// start leaves them there: said, never read out.
    static func leftWaiting(_ named: LeadAgent, root: URL) -> Int? {
        let waiting = SteerInbox.pending(tty: named.tty, root: root).filter { $0.agentPid == named.pid }
        return waiting.isEmpty ? nil : waiting.count
    }

    /// Why a vault that holds its first look doesn't start `root`'s lead yet (S7): config held from it, or no head
    /// recorded for `branch`; nil once both are done. The look is made here first, as `config held` makes it (a card
    /// that showed nothing, `shown: [:]`), so nothing is sealed and the first look stays held whatever the look finds
    /// (the security follow-ups' item 20: the vault ends it only for a `shown` with something in it, an accept's hashes
    /// with `ConfigHoldStore.acceptMark`, never for a look, even with nothing held, a home already accepted for another
    /// root and a project with nothing watched). The vault holds what it has nothing recorded for only once something
    /// looked, so a config never looked at isn't taken as accepted; and an app's look with no card
    /// (`checkConfig(root:)`) would seal everything held that didn't move since (the E6 review), a change a look held
    /// after the first accept among it. Throws when the vault can't be asked.
    static func firstLookRefusal(vault: LeadVault, root: String, branch: String) throws -> String? {
        let check = try vault.checkConfig(root: root, shown: [:])
        var held = ConfigSeal.held(in: try vault.guardedRecord(root: root))
        for name in check.held where !held.contains(name) { held.append(name) }
        let head = try vault.head(root: root, branch: branch)
        guard !held.isEmpty || head == nil else { return nil }
        var missing: [String] = []
        if !held.isEmpty { missing.append("\(held.count) held from its first look (`vibeswitcher config held`, then `config accept CARD`)") }
        if head == nil { missing.append("no head recorded for \(branch) (`vibeswitcher base show \(root)`, then `base accept CARD`)") }
        return "the session host's vault holds its first look of \(LeadMail.project(of: root)), so nothing on disk is taken as the user's "
            + "until accepted: " + missing.joined(separator: "; ") + ". Accept both, then start the lead"
    }

    /// The lead's environment: the launch's, the program it was started by (`VIBESWITCHER_CLAUDE`, for its tool
    /// server's workers and verifiers: EN-D13), no Codex workers (the security document's decision 15), and on a
    /// scratch node its root (`VIBESWITCHER_HOME`, so its tool server and hook use it) and its own test and build
    /// slots (`TestLock.directoryVariable`: `temporaryRoot`, where the user's node's are too). A scratch node's merges
    /// and audits never wait on the account's slots nor show in them: a suite that runs under `vs-heavy` holds one of
    /// those itself, and on a machine with a single slot (under 12 cores) its scratch lead's merge waited for it until
    /// the suite ended (the `v2 linux` run of 2026-11-17, a 4-core runner).
    /// What a lead starts on, by the app's rule (`LeadController.leadRun`, `LeadLaunch.leadRun`): `base`'s model (else
    /// Claude's settings in `home`) is what no `--model` would run, and the account's usage kept under the node's root
    /// (where its leads' tool servers keep it, `AccountUsageStore` at `VibePaths.root`) says whether Fable is held back.
    static func leadRun(_ workflow: LeadWorkflow, base: String, nodeRoot: URL, home: String) -> LeadLaunch.Run {
        let usage = AccountUsageStore(file: nodeRoot.appendingPathComponent("account-usage.json"), home: home)
        return LeadLaunch.leadRun(workflow, defaultModel: LeadWorkflow.claudeModel(command: base, home: home),
                                  fableHeldBack: usage.load().fableHeldBack() != nil)
    }

    func environment(_ launch: LeadLaunch.Prepared, program: String) -> [String: String] {
        var environment = launch.environment
        environment[RoleProgram.variable] = program
        environment["VIBESWITCHER_CODEX_WORKERS"] = "0"
        if isScratch {
            environment["VIBESWITCHER_HOME"] = root.path
            environment[TestLock.directoryVariable] = temporaryRoot.path
        }
        return environment
    }

    private func spawn(root: String, project: String, program: String, grant: String, launch: LeadLaunch.Prepared, notes: [String],
                       run: LeadLaunch.Run, resumed: (conversation: String, transcript: String)?) {
        let vault = link.vault
        guard !stopping else {
            work.async { try? vault.revoke(grant, root: root) }
            leads.notReplacing(root: root)
            return finish(root: root, .refused(Self.stoppingRefusal))
        }
        let request = SpawnRequest(cwd: root, command: launch.command, env: environment(launch, program: program), cols: 120, rows: 40,
                                   keepShell: false, label: "Lead · \(project)", agent: "claude")
        spawning(request)
        link.spawn(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let session):
                // Bound before the reply: the lead's tool server asks for its role as it starts (and waits a moment).
                self.work.async {
                    var said = notes
                    do { try vault.bind(grant, root: root, session: session.id.uuidString) } catch {
                        said.append("its role wasn't bound to its session: \(error)")
                    }
                    let notes = said
                    // The board names it (`LeadHandover.started`, until its tool server names it itself) before the reply
                    // says it started: written on the reads queue, in order with the boards' reads.
                    self.reads.async({ _ in try? BoardStore(root: root).update { LeadHandover.started(session.id.uuidString, on: &$0) } }) { _ in
                        if self.options.answersTrust { self.answerTrust(session.id, folder: root) }
                        self.holders[root] = session.id
                        self.leads.lead(root: root) {
                            $0.bound = session.id.uuidString
                            $0.named = session.id.uuidString
                        }
                        self.leads.update(sessions: self.link.sessions, holders: self.holders)
                        self.noteStarted(root: root, session: session.id, run: run, resumed: resumed)
                        if resumed == nil { self.policyPrompted(session.id) }
                        self.finish(root: root, .started(session: session.id, program: program, notes: notes))
                    }
                }
            case .failure(let error):
                self.work.async { try? vault.revoke(grant, root: root) }
                self.leads.notReplacing(root: root)
                self.finish(root: root, .refused("the session host didn't start the lead: \(error.message)"))
            }
        }
    }

    /// Answers Claude's trust question about `folder` in the new session, carefully (`TrustPrompt.answer`): the screen
    /// read and the keys typed as units through the link, off the engine's queue.
    func answerTrust(_ id: UUID, folder: String) {
        let link = self.link
        work.async {
            TrustPrompt.answer(folder: folder, readScreen: {
                let read = DispatchSemaphore(value: 0)
                let screen = Locked<String?>(nil)
                link.screen(id) { text in
                    screen.set(text)
                    read.signal()
                }
                _ = read.wait(timeout: .now() + 5)
                return screen.get()
            }, send: { writes in
                link.type(writes, into: id)
            })
        }
    }

    /// The start of `root` is over: the request that made it hears what it did, and the store says so. Each request
    /// that joined it is taken up now with what it asked (so its goal is held for the lead this start left, its
    /// `--replace` applies to a lead still without its role): the first of them starts again and the rest join it. A
    /// refusal is theirs too. On `queue`.
    func finish(root: String, _ outcome: StartOutcome) {
        var waiting = starting.removeValue(forKey: root) ?? []
        note("lead: \(LeadMail.project(of: root)): \(Self.word(outcome))")
        leads.lead(root: root) {
            $0.starting = false
            $0.lastStart = Self.word(outcome)
            $0.lastStartAt = Date()
        }
        // A lead runs there again: a host restart's notice for the project is over (E8).
        if case .started = outcome { teamStarted(root: root) }
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().completion(outcome)
        for joined in waiting {
            if case .refused = outcome {
                joined.completion(outcome)
            } else {
                begin(root: root, program: joined.program, start: joined.start, completion: joined.completion)
            }
        }
    }

    /// What a start did, in a word or a line (the log and `status`).
    static func word(_ outcome: StartOutcome) -> String {
        switch outcome {
        case .started(let session, _, _): return "started (session \(session.uuidString.prefix(8)))"
        case .shown(let session, _): return "shown (session \(session.uuidString.prefix(8)))"
        case .waiting: return "waiting for the host's welcome"
        case .refused(let why): return "refused: " + why
        }
    }

    /// A refusal the start makes itself.
    struct Refused: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// A value read and written from several threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}
