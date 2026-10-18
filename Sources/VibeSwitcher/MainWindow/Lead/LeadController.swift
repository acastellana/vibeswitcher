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

/// Each lead's board and decisions as last read, kept while their files are unchanged. The lead controller looks
/// every 3 s on the main thread, and a day's board is most of a MB of JSON (its decisions, dates to parse).
struct LeadFiles {
    /// A file's identity, size and modification time: while they're the same, so is what it says. A board is
    /// written whole and renamed into place, so a new one is a new file.
    struct Stamp: Equatable {
        let inode: UInt64
        let size: Int64
        let modified: timespec

        init?(_ path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            inode = info.st_ino
            size = info.st_size
            modified = info.st_mtimespec
        }

        static func == (a: Stamp, b: Stamp) -> Bool {
            a.inode == b.inode && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    private var boards: [String: (stamp: Stamp, board: LeadBoard)] = [:]
    private var decisionLists: [String: (stamp: Stamp, decisions: [LeadDecision])] = [:]
    /// How many times a file was read (for tests).
    private(set) var fileReads = 0

    mutating func board(_ root: String) -> LeadBoard {
        let store = BoardStore(root: root)
        let stamp = Stamp((store.folder as NSString).appendingPathComponent("board.json"))
        if let stamp, let kept = boards[root], kept.stamp == stamp { return kept.board }
        fileReads += 1
        let board = store.load()
        boards[root] = stamp.map { ($0, board) }
        return board
    }

    mutating func decisions(_ root: String) -> [LeadDecision] {
        let store = BoardStore(root: root)
        let stamp = Stamp((store.folder as NSString).appendingPathComponent("decisions.md"))
        if let stamp, let kept = decisionLists[root], kept.stamp == stamp { return kept.decisions }
        fileReads += 1
        let decisions = store.decisions()
        decisionLists[root] = stamp.map { ($0, decisions) }
        return decisions
    }

    /// Only these roots still have a lead.
    mutating func keep(_ roots: Set<String>) {
        boards = boards.filter { roots.contains($0.key) }
        decisionLists = decisionLists.filter { roots.contains($0.key) }
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
    /// The leads' bases, when they moved other than through merges (see `BaseMoves`).
    let baseMoves: BaseMoves

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
    /// Starts asked for before the host said which sessions run (right after a relaunch), by root: decided then.
    private var pendingStarts: [String: (goal: String?, show: Bool, askAboutMovedHead: Bool)] = [:]
    /// The leads found running (after a relaunch, an install) whose role the vault binds to their session: bound
    /// again, by root. Each live lead session is looked at once.
    @Published private(set) var keptLeads: [String: UUID] = [:]
    private var adopting: Set<UUID> = []
    private var hostWelcome: AnyCancellable?
    /// The boards and decisions as last read: the refresh reads them again only when their files changed.
    private var reads = LeadFiles()
    private let vault: LeadVault
    /// Asks the user (an alert): the index of the button chosen. Faked in tests.
    var confirm: (_ title: String, _ text: String, _ buttons: [String]) -> Int = LeadController.runAlert
    /// Answers Claude's trust question in a lead the app started (off in tests: no real host to ask).
    var answersTrust = true

    init(host: HostClient, store: SessionStore, vault: LeadVault = .standard, claudeCommand: @escaping (String) -> String) {
        self.host = host
        self.store = store
        self.vault = vault
        baseMoves = BaseMoves(vault: vault)
        self.claudeCommand = claudeCommand
        summaries.lookup = { [weak host, weak store] id in
            (host?.sessions.first { $0.id.uuidString == id }, store?.sessions.first { $0.hostID?.uuidString == id }?.transcriptPath)
        }
        timer = Heartbeat.shared.every(3) { [weak self] in self?.refresh() }
        // The host's welcome says which sessions run: the starts that waited for it, and the running leads, go on.
        hostWelcome = host.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.startPending()
            self?.keepRunningLeads()
        }
        baseMoves.onAsk = { [weak self] root, move in
            self?.notify("\(move.branch) moved outside the lead's merges", "\(move.count) in \((root as NSString).lastPathComponent): accept them in the lead's chat, or keep its merges refused.")
        }
        baseMoves.onTaken = { [weak self] root, move, byYou in
            guard byYou, let self else { return }
            self.deliver("The user accepted the \(move.count) on \(move.branch) (\(move.from.prefix(8)) → \(move.to.prefix(8))) in VibeSwitcher: merges start from there now.",
                         from: .system("the user, in the window"), root: root)
        }
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
    /// `askAboutMovedHead`: you asked in the app (not the notification), so a moved branch is yours to take.
    func startLead(in folder: String, goal: String? = nil, show: Bool = true, askAboutMovedHead: Bool = true) {
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
                self.startLead(root: root, goal: goal, show: show, askAboutMovedHead: askAboutMovedHead)
            }
        }
    }

    /// What a start does with the lead that may be running already.
    enum StartPlan: Equatable {
        /// The host hasn't said yet which sessions run (the app just relaunched): decided once it has.
        case wait
        /// No lead runs for the project.
        case start
        /// The lead runs (and holds its role, or nothing here may replace it): shown, never replaced.
        case show(UUID)
        /// The lead runs without its role (the vault binds it to no session, or another): you're asked first.
        case askToReplace(UUID)
    }

    /// `running`: the project's live lead session, if any; `holdsRole`: whether the vault binds the lead's role to it
    /// (nil: the vault couldn't be asked); `fromUser`: you asked in the app (not `vibeswitcher --lead`, which anything
    /// can post).
    static func plan(hostState: HostClient.State, running: UUID?, holdsRole: Bool?, fromUser: Bool) -> StartPlan {
        if hostState == .connecting { return .wait }
        guard let running else { return .start }
        return holdsRole == false && fromUser ? .askToReplace(running) : .show(running)
    }

    private func startLead(root: String, goal: String?, show: Bool, askAboutMovedHead: Bool) {
        guard let running = leadSessions[root] else {
            if Self.plan(hostState: host.state, running: nil, holdsRole: nil, fromUser: askAboutMovedHead) == .wait {
                // A relaunched app's session list is empty until the host's welcome: that's no sign no lead runs.
                pendingStarts[root] = (goal, show, askAboutMovedHead)
                return
            }
            return prepareLead(root: root, goal: goal, show: show, askAboutMovedHead: askAboutMovedHead)
        }
        // Whether it holds its role, the vault says (off the main thread: it's a call to the host); held, it's bound
        // to its session again, as at a relaunch.
        let vault = self.vault
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let holds: Bool?
            do { holds = try vault.rebindLead(root: root, session: running.id.uuidString) != nil } catch { holds = nil }
            DispatchQueue.main.async {
                guard let self else { return }
                switch Self.plan(hostState: self.host.state, running: running.id, holdsRole: holds, fromUser: askAboutMovedHead) {
                case .wait:
                    self.pendingStarts[root] = (goal, show, askAboutMovedHead)
                case .start:
                    self.prepareLead(root: root, goal: goal, show: show, askAboutMovedHead: askAboutMovedHead)
                case .show(let id):
                    if let goal { self.deliver("New goal: \(goal)", from: Self.commandLine, root: root) }
                    if show { self.select(id) }
                case .askToReplace(let id):
                    if self.askToReplace(root: root, running: running) {
                        self.prepareLead(root: root, goal: goal, show: show, askAboutMovedHead: askAboutMovedHead)
                    } else if show {
                        self.select(id)
                    }
                }
            }
        }
    }

    /// The starts that waited for the host's sessions, decided now that they're known.
    private func startPending() {
        guard host.state != .connecting, !pendingStarts.isEmpty else { return }
        let pending = pendingStarts
        pendingStarts = [:]
        for (root, start) in pending { startLead(root: root, goal: start.goal, show: start.show, askAboutMovedHead: start.askAboutMovedHead) }
    }

    /// The leads still running when the app starts again (a relaunch, an install handed their sessions over): each
    /// keeps its role, bound again to its session when the vault binds it there; none is replaced. One the vault
    /// gives no role stays as it is (its tools say so); Project Lead then asks before starting another.
    private func keepRunningLeads() {
        guard host.state != .connecting else { return }
        for (root, session) in leadSessions where adopting.insert(session.id).inserted {
            let vault = self.vault
            let project = (root as NSString).lastPathComponent
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let kept: LeadVault.Member?
                do { kept = try vault.rebindLead(root: root, session: session.id.uuidString) } catch {
                    Breadcrumbs.shared.note("lead: couldn't bind the running lead of \(project) again: \(error)")
                    DispatchQueue.main.async { self?.adopting.remove(session.id) }  // Tried again on the next refresh.
                    return
                }
                Breadcrumbs.shared.note(kept != nil
                    ? "lead: kept the running lead of \(project) (session \(session.id.uuidString.prefix(8)))"
                    : "lead: the running lead of \(project) (session \(session.id.uuidString.prefix(8))) holds no role in the vault; left as it is")
                guard kept != nil else { return }
                DispatchQueue.main.async { self?.keptLeads[root] = session.id }
            }
        }
    }

    private func prepareLead(root: String, goal: String?, show: Bool, askAboutMovedHead: Bool) {
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
        let vault = self.vault
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var issued: String?
            var waiting: [SteerMessage] = []
            let prepared = Result<(grant: String, launch: LeadLaunch.Prepared), Error> {
                let workflowPath = try boardStore.prepare()
                var workflow = LeadWorkflow.load(from: workflowPath)
                workflow.baseBranch = workflow.baseBranch ?? boardStore.load().baseBranch
                // Only the app makes a lead (the session host tells the app from the team): its grant (the lead's
                // tools, once bound to its session). Merges check nothing else moved the branch since the lead last
                // left it; a start takes the branch as it is only when you say so here, shown the move (a start asked
                // for from outside the app never does: anything can ask).
                let branch = workflow.baseBranch ?? Worktrees.mainBranch(root: root)
                var takeHead = false
                if askAboutMovedHead, let moved = vault.headMoved(root: root, branch: branch) {
                    takeHead = DispatchQueue.main.sync { self?.askToTakeHead(branch: branch, moved) ?? false }
                }
                let grant = try vault.startLead(root: root, branch: branch, takeHead: takeHead)
                issued = grant
                // The role is the new session's from now on: the lead it replaces gets nothing more, and what waited
                // for it goes to the new one (see `LeadHandover`).
                let handover = try LeadHandover.begin(boardStore)
                waiting = handover.waiting
                if let replaced = handover.replaced {
                    Breadcrumbs.shared.note("lead: replacing the lead on \(replaced.tty); \(waiting.count) message(s) for it go to the new one")
                }
                let name = "lead-\(Slug.make(project, taken: []))"
                let launch = try LeadLaunch.prepare(
                    role: .lead, root: root, task: nil, base: base,
                    prompt: LeadPrompts.lead(project: project, root: root, workflow: workflow),
                    start: LeadPrompts.leadStart(root: root, goal: goal, note: Self.commandLineNote),
                    server: Self.serverPath, name: name, folder: vault.runFolder(root: root, name: name))
                return (grant, launch)
            }
            if case .failure = prepared, let issued { try? vault.revoke(issued, root: root) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.startingLeads.remove(root)
                if !waiting.isEmpty { self.held[root, default: []] += waiting.map { (text: $0.text, sender: $0.from) } }
                switch prepared {
                case .failure(let error): self.alert("The lead didn't start.", "\(error)")
                case .success(let (grant, launch)): self.spawnLead(root: root, project: project, grant: grant, launch: launch, show: show)
                }
            }
        }
    }

    private func spawnLead(root: String, project: String, grant: String, launch: LeadLaunch.Prepared, show: Bool) {
        let boardStore = BoardStore(root: root)
        let vault = self.vault
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
                try? boardStore.update { board in LeadHandover.started(session.id.uuidString, on: &board) }
                // You chose to start the lead here: answer Claude's trust question for this folder.
                if self?.answersTrust == true { self?.answerTrust(session.id, folder: root) }
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
        case .afterAutoDecision(let decided):
            answerNotices[question.id] = "The timer had run out: the lead went ahead with ‘\(decided.proposal ?? "")’. Your answer reached it as a note."
        case .alreadyAnswered(let answered):
            answerNotices[question.id] = "Already answered: \(answered.answer ?? answered.proposal ?? ""). Your new answer wasn't sent."
        case .missing:
            answerNotices[question.id] = "That question is no longer on the board. Your answer wasn't sent."
        }
        if let message = outcome.message(given: text) { deliver(message, from: .user, root: root) }
        refresh()
    }

    /// You hold a question with a timer: the timer stops, it waits for your answer like any other, and the lead is
    /// told not to go ahead.
    func hold(_ question: LeadQuestion) {
        guard let root = boards.first(where: { $0.value.questions.contains { $0.id == question.id } })?.key else { return }
        let store = BoardStore(root: root)
        do {
            let held = try store.update { board in try board.hold(question.id) }
            answerNotices[question.id] = nil
            deliver("The user is holding your question \(held.short) “\(held.text)”: its timer is off, so don't go ahead with ‘\(held.proposal ?? "")’; "
                    + "wait for their answer.", from: .user, root: root)
        } catch {
            answerNotices[question.id] = "\(error)"
        }
        refresh()
    }

    /// Runs out the timers of the leads' questions (see `BoardStore.runTimers`): the lead is told to go ahead with
    /// each proposal no one answered, once.
    private func runTimers(_ roots: Set<String>) {
        for root in roots {
            let store = BoardStore(root: root)
            guard let fired = try? store.runTimers(), !fired.isEmpty else { continue }
            let project = (root as NSString).lastPathComponent
            for (question, message) in fired {
                deliver(message, from: .system("timer"), root: root)
                notify("The lead of \(project) went ahead with ‘\(question.proposal ?? "")’", question.text)
            }
        }
    }

    /// Steered in while the lead works; while it's idle the message waits in its inbox and `flush` types it as soon
    /// as its input box is empty (never into your draft; a draft you send takes it along).
    private func deliver(_ text: String, from sender: SteerMessage.Sender, root: String) {
        // The board as it is now names the lead that holds the role (none while a new one starts, see
        // `LeadHandover`); if that one is gone (a restart under way), the message would be dropped by the next lead's
        // hook: keep it until a lead runs again.
        guard let agent = LeadHandover.named(reads.board(root)),
              ProcessTable.info(pid: agent.pid).map({ $0.tty == agent.tty && $0.agent != nil }) == true else {
            held[root, default: []].append((text, sender))
            Breadcrumbs.shared.note("lead: holding a message for \((root as NSString).lastPathComponent) (no lead running)")
            return
        }
        try? LeadDelivery.deliver(text, from: sender, to: agent, inputIsEmpty: nil, typeInto: nil)
        wake(root: root)
    }

    /// Wakes an idle lead that reports wait for (see `LeadWake`): one short prompt for all of them, typed into its
    /// empty box between turns, and none again until it has taken a turn. Your own words waiting for it (an
    /// answer) are typed as they are instead, and the reports go along with them. Always the lead the board names
    /// at that moment, looked up again before anything is typed: a lead replaced meanwhile gets nothing.
    private func wake(root: String) {
        guard let lead = LeadHandover.named(reads.board(root)) else { return }
        let pending = SteerInbox.pending(tty: lead.tty).filter { $0.agentPid == lead.pid }
        let reports = LeadWake.reports(pending, agentPid: lead.pid)
        let now = Date().timeIntervalSince1970
        ReportsWaiting.shared.set(LeadWake.waiting(reports, now: now), tty: lead.tty)
        if pending.first?.from == .user { return flush(lead, lead: root) }
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
                self?.wake(root: root)
            }
        case .ready:
            // A prompt typed a moment ago (its hooks haven't said it's working yet) is one in flight too.
            guard !flushing.contains(lead.tty), Date().timeIntervalSince(typedAt[lead.tty] ?? .distantPast) > 10 else { return }
            flushing.insert(lead.tty)
            host.styledScreen(id) { [weak self] screen in
                guard let self else { return }
                self.flushing.remove(lead.tty)
                guard LeadHandover.named(self.reads.board(root)) == lead else { return }
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
    /// missing or stale state file isn't an idle agent (its transcript says whether it's mid-turn). A lead's (`lead`:
    /// its root) only while the board still names it.
    private func flush(_ agent: LeadAgent, lead root: String? = nil) {
        guard let id = agent.session.flatMap(UUID.init(uuidString:)),
              SteerInbox.pending(tty: agent.tty).contains(where: { $0.agentPid == agent.pid }),
              let hosted = host.sessions.first(where: { $0.id == id }),
              observer.activity(hosted, agentPid: agent.pid).betweenTurns, !flushing.contains(agent.tty),
              Date().timeIntervalSince(typedAt[agent.tty] ?? .distantPast) > 10 else { return }
        flushing.insert(agent.tty)
        host.styledScreen(id) { [weak self] screen in
            guard let self else { return }
            self.flushing.remove(agent.tty)
            if let root, LeadHandover.named(self.reads.board(root)) != agent { return }
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
        startPending()
        keepRunningLeads()
        let roots = Set(leadSessions.keys)
        runTimers(roots)
        var loaded: [String: LeadBoard] = [:]
        for root in roots { loaded[root] = reads.board(root) }
        if loaded != boards { boards = loaded }
        let read = Dictionary(uniqueKeysWithValues: roots.map { ($0, reads.decisions($0)) })
        if read != decisions { decisions = read }
        reads.keep(roots)
        baseMoves.look(roots)
        for (root, board) in loaded {
            for question in board.openQuestions where seenQuestions.insert("\(question.id)#\(question.version)").inserted {
                let project = (root as NSString).lastPathComponent
                let timer = question.isCounting ? "Going with ‘\(question.proposal ?? "")’ in \(question.decideInText) unless you answer: " : ""
                notify(question.version > 1 ? "The lead of \(project) updated a question" : "The lead of \(project) asks", timer + question.text)
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
                        // From the store's last scan, which reads the process table off the main thread. Reading it
                        // here froze the window for minutes at a time on a loaded Mac (sysctl walks every process).
                        shellRunning = !session.backgroundJobs.isEmpty
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
                                        shellRunning: shellRunning, heldSince: held?.at, heldFrom: held.map { Self.sender($0.from) },
                                        started: info.startedAt.timeIntervalSince1970)
            if info.isLive, let session { flush(LeadAgent(pid: session.pid, tty: session.tty, session: id)) }
        }
        // Sessions that ended together (a stray kill, the app relaunched over them) are told in one message.
        for message in LeadWitness.messages(board: board, seen: seen, now: now, told: { told.contains("\(root)|\($0)") }) {
            message.keys.forEach { told.insert("\(root)|\($0)") }
            deliver(message.text, from: .system("witness"), root: root)
        }
        // Low disk space, once per episode; what takes it is sized off the main thread.
        var disk = disks[root] ?? LeadWitness.Disk()
        let workflow = LeadWorkflow.load(from: (BoardStore(root: root).folder as NSString).appendingPathComponent("workflow.md"))
        if let free = disk.check(root: root, workflow: workflow) {
            let sizing = disk
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let text = sizing.text(free: free, root: root, board: board, workflow: workflow)
                DispatchQueue.main.async { self?.deliver(text, from: .system("witness"), root: root) }
            }
        }
        disks[root] = disk
        // On the board too, for status and the Team view, until the worker moves again.
        let stalls = LeadWitness.stalls(board: board, seen: seen, now: now)
        var noted = board
        if noted.noteStalls(stalls) { try? BoardStore(root: root).update { $0.noteStalls(stalls) } }
        // A lead runs again: what was held for it goes now.
        if let waiting = held.removeValue(forKey: root) {
            for message in waiting { deliver(message.text, from: message.sender, root: root) }
        }
        wake(root: root)
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

    /// The lead's branch moved since the lead last left it, not through its merges: whether to take it as it is now.
    private func askToTakeHead(branch: String, _ moved: (recorded: String, now: String)) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(branch) moved since the lead last left it, and not through its merges."
        alert.informativeText = "It was at \(moved.recorded.prefix(8)) and is at \(moved.now.prefix(8)) (`git log \(moved.recorded.prefix(8))..\(branch)` "
            + "shows what came in). If you moved it, take it as it is: merges start from there. Otherwise keep it checked, and the lead's merges "
            + "stay refused until it's back where the lead left it."
        alert.addButton(withTitle: "Keep Checking")
        alert.addButton(withTitle: "I Moved It: Take \(branch) As It Is")
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The project's lead runs without its role: whether to start a new one (the running one is told where to go on
    /// when it next uses its tools; its conversation stays where it is).
    private func askToReplace(root: String, running: HostSession) -> Bool {
        let project = (root as NSString).lastPathComponent
        let chosen = confirm("The lead of \(project) is running, but without its role.",
                             "Its session (‘\(running.label)’, \(running.id.uuidString.prefix(8))) still runs, with its conversation, but the "
                                + "session host no longer gives it the lead's role, so its tools are off. A new lead takes the role: the "
                                + "running one is then told, when it next uses its tools, to send you to the new one. Anything you told it "
                                + "that isn't on the board yet, tell the new lead.",
                             ["Show the Running Lead", "Start a New Lead"])
        return chosen == 1
    }

    private func alert(_ title: String, _ text: String) {
        _ = confirm(title, text, ["OK"])
    }

    static func runAlert(_ title: String, _ text: String, _ buttons: [String]) -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate()
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}
