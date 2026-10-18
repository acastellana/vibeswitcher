import AppKit
import Combine
import Foundation
import VibeCore

/// How many reports have waited for each lead too long to be woken for (see `LeadWake.waiting`), by the lead's
/// terminal: its strip shows them.
final class ReportsWaiting: ObservableObject {
    static let shared = ReportsWaiting()
    @Published private(set) var count: [String: Int] = [:]

    func set(_ count: Int, tty: String) {
        if (self.count[tty] ?? 0) != count { self.count[tty] = count > 0 ? count : nil }
    }

    /// Only these terminals still have a lead.
    func keep(_ ttys: Set<String>) {
        if !Set(count.keys).isSubset(of: ttys) { count = count.filter { ttys.contains($0.key) } }
    }
}

/// The app's side of project leads: starting them, keeping their boards loaded, answering their questions, and
/// being their witness (telling a lead when one of its workers needs input, stops without reporting, or dies).
final class LeadController: ObservableObject {
    /// Each running lead's board, by repository root.
    @Published private(set) var boards: [String: LeadBoard] = [:]
    /// Each running lead's decisions (`BoardStore.decisions`), by repository root.
    @Published private(set) var decisions: [String: [LeadDecision]] = [:]
    /// The Team view's plain-language lines.
    let summaries = TeamSummaryModel()

    private let host: HostClient
    private let store: SessionStore
    /// The project's Claude command (its launch preset), flags included.
    private let claudeCommand: (String) -> String
    var notify: (String, String) -> Void = { _, _ in }
    var select: (UUID) -> Void = { _ in }
    private var timer: Heartbeat.Subscription?
    /// Questions told about (by id and version: a revision is news too).
    private var seenQuestions: Set<String> = []
    /// What became of an answer that didn't land as one (the question was withdrawn, or answered already), by
    /// question id: its card says so.
    @Published private(set) var answerNotices: [String: String] = [:]
    /// Witness events already told, so each is told once.
    private var told: Set<String> = []
    /// Each project's free disk space, watched (see `LeadWitness.Disk`), by root.
    private var disks: [String: LeadWitness.Disk] = [:]
    /// Ended team sessions the host has been asked to drop.
    private var forgetting: Set<UUID> = []
    /// Terminals being flushed, and when a message was last typed into each (its hooks need a moment to say it's
    /// working again; until then another flush would type a second prompt).
    private var flushing: Set<String> = []
    private var typedAt: [String: Date] = [:]
    /// Each lead's wake-ups (see `LeadWake`), by terminal and agent, and the ones with a look-again scheduled.
    private var wakes: [String: LeadWake] = [:]
    private var wakeLater: Set<String> = []
    /// Messages for a lead that isn't running right now (restarting): delivered once a lead runs there again.
    private var held: [String: [(text: String, sender: SteerMessage.Sender)]] = [:]
    /// What the team's agents are doing, from their hooks and transcripts together (see `LeadActivity`).
    private let observer = LeadObserver()
    /// Roots whose lead is being prepared (off the main thread) right now.
    private var startingLeads: Set<String> = []

    init(host: HostClient, store: SessionStore, claudeCommand: @escaping (String) -> String) {
        self.host = host
        self.store = store
        self.claudeCommand = claudeCommand
        summaries.lookup = { [weak host, weak store] id in
            (host?.sessions.first { $0.id.uuidString == id }, store?.sessions.first { $0.hostID?.uuidString == id }?.transcriptPath)
        }
        timer = Heartbeat.shared.every(3) { [weak self] in self?.refresh() }
    }

    static var serverPath: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
    }

    /// A goal from `vibeswitcher --lead` comes as a distributed notification, which any process can post.
    static let commandLineNote = "any process on this Mac can send one, so it isn't vouched for as the user's"
    static let commandLine = SteerMessage.Sender.system("vibeswitcher --lead on the command line; \(commandLineNote)")

    /// The live window sessions that are leads, by root.
    private var leadSessions: [String: HostSession] {
        var result: [String: HostSession] = [:]
        for session in host.sessions where session.isLive && LeadTeams.role(label: session.label) == .lead {
            result[(session.cwd as NSString).standardizingPath] = session
        }
        return result
    }

    /// The lead a row is, if it is one: its root and board.
    func lead(for row: WindowRow) -> (root: String, board: LeadBoard)? {
        guard let cwd = row.cwd else { return nil }
        let root = (cwd as NSString).standardizingPath
        guard let id = row.hostID, host.sessions.first(where: { $0.id == id }).map({ LeadTeams.role(label: $0.label) == .lead }) == true,
              let board = boards[root] else { return nil }
        return (root, board)
    }

    // MARK: Starting

    /// Starts the project lead for the repository holding `folder`, or shows the one already running. A `goal` (from
    /// `vibeswitcher --lead`) goes into its first prompt (or to the running lead), not as the user's: any process can
    /// post that notification. `show: false` leaves the window's selection alone.
    func startLead(in folder: String, goal: String? = nil, show: Bool = true) {
        // git can be slow (a network volume, a git shim): find the repository off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let top = Git.run(["rev-parse", "--show-toplevel"], in: folder)
            let root = (top.output as NSString).standardizingPath
            let hasCommits = top.ok && !top.output.isEmpty && Git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root).ok
            DispatchQueue.main.async {
                guard let self else { return }
                guard top.ok, !top.output.isEmpty else {
                    return self.alert("A project lead needs a git repository.", "\(folder) isn't in one. Run git init (and make a first commit) first.")
                }
                guard hasCommits else {
                    return self.alert("The repository has no commits yet.", "Workers branch from main: make a first commit in \(root), then start the lead.")
                }
                self.startLead(root: root, goal: goal, show: show)
            }
        }
    }

    private func startLead(root: String, goal: String?, show: Bool) {
        if let running = leadSessions[root] {
            if let goal { deliver("New goal: \(goal)", from: Self.commandLine, to: BoardStore(root: root).load(), root: root) }
            if show { select(running.id) }
            return
        }
        // The lead's vault lives in the session host: an older one still serving its sessions can't hold it (and
        // one too old to hand over stays until restarted).
        if case .outdated = host.state, !host.hostCapabilities.contains(HostProtocol.Capability.leadVault) {
            return offerHostRestart()
        }
        // Preparing runs git (the board's folder, the base branch): off the main thread, one start per root at a time.
        guard startingLeads.insert(root).inserted else { return }
        let project = (root as NSString).lastPathComponent
        let base = claudeCommand(root)
        let boardStore = BoardStore(root: root)
        let vault = LeadVault.standard
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var issued: String?
            let prepared = Result<(grant: String, launch: LeadLaunch.Prepared), Error> {
                let workflowPath = try boardStore.prepare()
                var workflow = LeadWorkflow.load(from: workflowPath)
                workflow.baseBranch = workflow.baseBranch ?? boardStore.load().baseBranch
                // Only the app makes a lead (the session host tells the app from the team): its grant (the lead's
                // tools, once bound to its session) and the branch as you start it, which merges then check nothing
                // else has moved.
                let grant = try vault.startLead(root: root, branch: workflow.baseBranch ?? Worktrees.mainBranch(root: root))
                issued = grant
                let name = "lead-\(Slug.make(project, taken: []))"
                let launch = try LeadLaunch.prepare(
                    role: .lead, root: root, task: nil, base: base,
                    prompt: LeadPrompts.lead(project: project, root: root, workflow: workflow),
                    start: goal.map { "You're starting as the project lead. A goal given with vibeswitcher --lead (\(Self.commandLineNote)): \($0)\nRead status and the workflow notes, plan the goal into tasks with contracts, start the workers, and tell the user your plan in a few lines." }
                        ?? "You're starting as the project lead. Read status and the workflow notes, then greet the user in one short line: what's on the board, and what they'd like to build next.",
                    server: Self.serverPath, name: name, folder: vault.runFolder(root: root, name: name))
                return (grant, launch)
            }
            if case .failure = prepared, let issued { try? vault.revoke(issued, root: root) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.startingLeads.remove(root)
                switch prepared {
                case .failure(let error): self.alert("The lead didn't start.", "\(error)")
                case .success(let (grant, launch)): self.spawnLead(root: root, project: project, grant: grant, launch: launch, show: show)
                }
            }
        }
    }

    private func spawnLead(root: String, project: String, grant: String, launch: LeadLaunch.Prepared, show: Bool) {
        let boardStore = BoardStore(root: root)
        let vault = LeadVault.standard
        host.spawn(SpawnRequest(cwd: root, command: launch.command, env: [:], cols: 120, rows: 40, keepShell: false,
                                label: "Lead · \(project)", agent: "claude")) { [weak self] result in
            switch result {
            case .success(let session):
                // The lead's tool server asks for its role as it starts (and waits a moment for this).
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try vault.bind(grant, root: root, session: session.id.uuidString) } catch {
                        Breadcrumbs.shared.note("lead: its role wasn't bound to its session: \(error)")
                    }
                }
                try? boardStore.update { board in board.leadSession = session.id.uuidString }
                // You chose to start the lead here: answer Claude's trust question for this folder.
                self?.answerTrust(session.id, folder: root)
                if show { self?.select(session.id) }
                self?.refresh()
            case .failure(let error):
                DispatchQueue.global(qos: .userInitiated).async { try? vault.revoke(grant, root: root) }
                self?.alert("The lead didn't start.", error.message)
            }
        }
    }

    // MARK: Questions

    /// Your answer: recorded on the board and delivered to the lead (steered in while it works, typed while idle).
    /// `question` is the card as you saw it: the answer is tied to that version, so if the lead revised it meanwhile
    /// it's told which wording you answered; if the lead had withdrawn it, the card says so and the lead gets your
    /// answer as a note.
    func answer(_ question: LeadQuestion, root: String, with text: String) {
        let store = BoardStore(root: root)
        let outcome = (try? store.update { board in board.answer(question.id, with: text, saw: question.version) }) ?? .missing
        switch outcome {
        case .answered: answerNotices[question.id] = nil
        case .withdrawn(let withdrawn):
            answerNotices[question.id] = "Withdrawn before your answer: \(withdrawn.withdrawReason ?? "no reason given"). The lead got your answer as a note."
        case .alreadyAnswered(let answered):
            answerNotices[question.id] = "Already answered: \(answered.answer ?? ""). Your new answer wasn't sent."
        case .missing:
            answerNotices[question.id] = "That question is no longer on the board. Your answer wasn't sent."
        }
        if let message = outcome.message(given: text) { deliver(message, from: .user, to: store.load(), root: root) }
        refresh()
    }

    /// Steered in while the lead works; while it's idle the message waits in its inbox and `flush` types it as soon
    /// as its input box is empty (never into your draft; a draft you send takes it along).
    private func deliver(_ text: String, from sender: SteerMessage.Sender, to board: LeadBoard, root: String? = nil) {
        // The board names the lead that last started; if that one is gone (a restart under way), the message
        // would be dropped by the next lead's hook: keep it until a lead runs again.
        guard let pid = board.leadPid, let tty = board.leadTTY,
              ProcessTable.info(pid: pid).map({ $0.tty == tty && $0.agent != nil }) == true else {
            if let root {
                held[root, default: []].append((text, sender))
                Breadcrumbs.shared.note("lead: holding a message for \((root as NSString).lastPathComponent) (no lead running)")
            }
            return
        }
        let agent = LeadAgent(pid: pid, tty: tty, session: board.leadSession)
        try? LeadDelivery.deliver(text, from: sender, to: agent, inputIsEmpty: nil, typeInto: nil)
        wake(agent)
    }

    /// Wakes an idle lead that reports wait for (see `LeadWake`): one short prompt for all of them, typed into its
    /// empty box between turns, and none again until it has taken a turn. Your own words waiting for it (an
    /// answer) are typed as they are instead, and the reports go along with them.
    private func wake(_ lead: LeadAgent) {
        let pending = SteerInbox.pending(tty: lead.tty).filter { $0.agentPid == lead.pid }
        let reports = LeadWake.reports(pending, agentPid: lead.pid)
        let now = Date().timeIntervalSince1970
        ReportsWaiting.shared.set(LeadWake.waiting(reports, now: now), tty: lead.tty)
        if pending.first?.from == .user { return flush(lead) }
        let key = "\(lead.tty)#\(lead.pid)"
        guard let id = lead.session.flatMap(UUID.init(uuidString:)), let hosted = host.sessions.first(where: { $0.id == id }) else { return }
        var state = wakes[key] ?? LeadWake()
        let step = state.step(reports: reports, activity: observer.activity(hosted, agentPid: lead.pid), now: now)
        wakes[key] = state
        switch step {
        case .none:
            return
        case .later(let due):
            guard wakeLater.insert(key).inserted else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due - now) + 0.2) { [weak self] in
                self?.wakeLater.remove(key)
                self?.wake(lead)
            }
        case .ready:
            // A prompt typed a moment ago (its hooks haven't said it's working yet) is one in flight too.
            guard !flushing.contains(lead.tty), Date().timeIntervalSince(typedAt[lead.tty] ?? .distantPast) > 10 else { return }
            flushing.insert(lead.tty)
            host.styledScreen(id) { [weak self] screen in
                guard let self else { return }
                self.flushing.remove(lead.tty)
                // What waits now (its hook may have taken some meanwhile), typed only into an empty box: Claude's
                // dim suggestion counts as empty, a draft or a dialog waits for the next try.
                let reports = LeadWake.reports(SteerInbox.pending(tty: lead.tty), agentPid: lead.pid)
                var state = self.wakes[key] ?? LeadWake()
                state.type(reports: reports, box: screen.map(LeadDelivery.box(in:))) { text in
                    self.typedAt[lead.tty] = Date()
                    self.type(text, into: id)
                    Breadcrumbs.shared.note("lead: woke the lead on \(lead.tty) for \(reports.count) report(s)")
                    return true
                }
                self.wakes[key] = state
            }
        }
    }

    /// Types what waits for an idle agent in a window session, once its input box is empty. Only between turns: a
    /// missing or stale state file isn't an idle agent (its transcript says whether it's mid-turn).
    private func flush(_ agent: LeadAgent) {
        guard let id = agent.session.flatMap(UUID.init(uuidString:)),
              SteerInbox.pending(tty: agent.tty).contains(where: { $0.agentPid == agent.pid }),
              let hosted = host.sessions.first(where: { $0.id == id }),
              observer.activity(hosted, agentPid: agent.pid).betweenTurns, !flushing.contains(agent.tty),
              Date().timeIntervalSince(typedAt[agent.tty] ?? .distantPast) > 10 else { return }
        flushing.insert(agent.tty)
        host.styledScreen(id) { [weak self] screen in
            guard let self else { return }
            self.flushing.remove(agent.tty)
            // Claude's dim suggested prompt isn't a draft: typing replaces it.
            guard let screen, LeadDelivery.box(in: screen) == .empty else { return }
            LeadDelivery.flush(agent, betweenTurns: true, inputIsEmpty: { true }, typeInto: { text in
                self.typedAt[agent.tty] = Date()
                self.type(text, into: id)
                return true
            })
        }
    }

    /// Answers Claude's trust question about `folder` in the new session, carefully (see `TrustPrompt.answer`).
    private func answerTrust(_ id: UUID, folder: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            TrustPrompt.answer(folder: folder, readScreen: {
                if case .screenText(_, let text)? = try? HostCall.request(.screen(id: id)) { return text }
                return nil
            }, send: { writes in
                for write in writes { try? HostCall.send(.input(id: id, bytes: Data(write.bytes), reply: false)) }
            })
        }
    }

    private func type(_ text: String, into id: UUID) {
        var at: TimeInterval = 0
        for write in ComposerText.writes(text, bracketed: true) {
            at += write.delay
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                self?.host.send(id, bytes: Data(write.bytes), reply: false)
            }
        }
    }

    // MARK: Refresh and witness

    private func refresh() {
        let roots = Set(leadSessions.keys)
        var loaded: [String: LeadBoard] = [:]
        for root in roots { loaded[root] = BoardStore(root: root).load() }
        if loaded != boards { boards = loaded }
        let read = Dictionary(uniqueKeysWithValues: roots.map { ($0, BoardStore(root: $0).decisions()) })
        if read != decisions { decisions = read }
        for (root, board) in loaded {
            for question in board.openQuestions where seenQuestions.insert("\(question.id)#\(question.version)").inserted {
                let project = (root as NSString).lastPathComponent
                notify(question.version > 1 ? "The lead of \(project) updated a question" : "The lead of \(project) asks", question.text)
            }
            witness(root: root, board: board)
        }
        forgetFinished(loaded)
        // A lead that ended, or another agent on its terminal now: its wake-ups and its waiting count go.
        let leads = Set(loaded.values.compactMap { board in board.leadTTY.flatMap { tty in board.leadPid.map { "\(tty)#\($0)" } } })
        wakes = wakes.filter { leads.contains($0.key) }
        ReportsWaiting.shared.keep(Set(loaded.values.compactMap(\.leadTTY)))
    }

    /// A task merged or abandoned: its ended workers and verifiers leave the session list (everywhere it's shown:
    /// the host drops them). The lead's cleanup does this too; this catches tasks finished some other way.
    private func forgetFinished(_ boards: [String: LeadBoard]) {
        forgetting.formIntersection(host.sessions.map(\.id))
        for (root, board) in boards {
            for id in LeadTeams.finished(host.sessions, root: root, board: board) where forgetting.insert(id).inserted {
                host.remove(id)
            }
        }
    }

    /// Tells the lead what its team can't (see `LeadWitness`), and types waiting messages into idle team members.
    private func witness(root: String, board: LeadBoard) {
        let hosted = Dictionary(uniqueKeysWithValues: host.sessions.map { ($0.id.uuidString, $0) })
        var seen: [String: LeadWitness.Seen] = [:]
        let now = Date()
        let workers = Set(board.tasks.compactMap(\.worker))
        // The process table, read once and only when a quiet worker's shells are in question.
        var processes: [Int32: ProcInfo]??
        for id in board.tasks.flatMap({ [$0.worker, $0.verifier] }).compactMap({ $0 }) {
            guard let info = hosted[id] else { continue }
            let session = store.sessions.first { $0.hostID?.uuidString == id }
            // A turn that ended on an API error reads as finished or waiting; its transcript says which it was. A
            // worker's transcript is read whatever it shows: a stall is one that reads as working too (see `LeadStall`).
            var apiError: (text: String, at: Double?)?
            var watched: (activity: LeadActivity, tail: TranscriptTail?, progress: TranscriptProgress?)?
            var shellRunning = false
            var held: SteerMessage?
            if info.isLive, let session, session.status != .working || workers.contains(id) {
                let reading = observer.watching(info, agentPid: session.pid)
                watched = reading
                if session.status != .working, case .apiError(let error) = reading.activity { apiError = (error, reading.tail?.at) }
                if workers.contains(id) {
                    if let last = reading.progress?.lastWritten, now.timeIntervalSince1970 - last >= LeadStall.silentAfter {
                        if processes == nil { processes = .some(ProcessTable.trySnapshot()) }
                        if let table = processes ?? nil {
                            shellRunning = !BackgroundJobs.jobs(forAgent: session.pid, in: table, arguments: {
                                ProcessTable.arguments(pid: $0.pid, start: Int($0.startTime.timeIntervalSince1970), comm: $0.comm)
                            }).isEmpty
                        } else {
                            shellRunning = true  // Unknown: not taken for silence.
                        }
                    }
                    held = SteerInbox.pending(tty: session.tty).filter { $0.agentPid == session.pid }.min { $0.at < $1.at }
                }
            }
            // No agent in the scan a minute on: "agent ended · shell", as good as ended.
            seen[id] = LeadWitness.Seen(live: info.isLive, exit: info.exit?.status, cause: info.exit?.cause, status: session?.status,
                                        since: session?.statusSince, detail: session?.detail,
                                        agentQuit: session == nil && info.agentQuit(now: now), apiError: apiError?.text,
                                        apiErrorAt: apiError?.at, activity: watched?.activity,
                                        lastActivity: watched?.progress?.lastWritten, compactedAt: watched?.progress?.compactedAt,
                                        shellRunning: shellRunning, heldSince: held?.at, heldFrom: held.map { Self.sender($0.from) })
            if info.isLive, let session { flush(LeadAgent(pid: session.pid, tty: session.tty, session: id)) }
        }
        // Sessions that ended together (a stray kill, the app relaunched over them) are told in one message.
        for message in LeadWitness.messages(board: board, seen: seen, now: now, told: { told.contains("\(root)|\($0)") }) {
            message.keys.forEach { told.insert("\(root)|\($0)") }
            deliver(message.text, from: .system("witness"), to: board, root: root)
        }
        // Low disk space, once per episode; what takes it is sized off the main thread.
        var disk = disks[root] ?? LeadWitness.Disk()
        let workflow = LeadWorkflow.load(from: (BoardStore(root: root).folder as NSString).appendingPathComponent("workflow.md"))
        if let free = disk.check(root: root, workflow: workflow) {
            let sizing = disk
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let text = sizing.text(free: free, root: root, board: board, workflow: workflow)
                DispatchQueue.main.async { self?.deliver(text, from: .system("witness"), to: board, root: root) }
            }
        }
        disks[root] = disk
        // On the board too, for status and the Team view, until the worker moves again.
        let stalls = LeadWitness.stalls(board: board, seen: seen, now: now)
        var noted = board
        if noted.noteStalls(stalls) { try? BoardStore(root: root).update { $0.noteStalls(stalls) } }
        // A lead runs again: what was held for it goes now.
        if let waiting = held.removeValue(forKey: root) {
            for message in waiting { deliver(message.text, from: message.sender, to: board, root: root) }
        }
        if let pid = board.leadPid, let tty = board.leadTTY { wake(LeadAgent(pid: pid, tty: tty, session: board.leadSession)) }
    }

    /// Who a waiting message is from, in words.
    private static func sender(_ sender: SteerMessage.Sender) -> String {
        switch sender {
        case .user: return "the user"
        case .lead(let name): return name
        case .system(let about): return "VibeSwitcher (\(about))"
        }
    }

    private func offerHostRestart() {
        let live = host.sessions.filter(\.isLive).count
        let alert = NSAlert()
        alert.messageText = "The session host is older than the lead."
        alert.informativeText = host.canHandOver
            ? "The lead's vault lives in the session host. Restart it to this app's version; its sessions keep running."
            : "The lead's vault lives in the session host, and the one running predates it (and can't update in place). "
                + "Restarting it ends its \(live == 1 ? "live session" : "\(live) live sessions"); hosts from now on update without ending any."
        alert.addButton(withTitle: host.canHandOver ? "Restart Session Host" : "Restart Session Host (ends \(live))")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { host.restartHost() }
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }
}
