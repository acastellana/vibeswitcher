import AppKit
import Combine
import Foundation
import VibeCore

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
    private var timer: Timer?
    /// Questions told about (by id and version: a revision is news too).
    private var seenQuestions: Set<String> = []
    /// What became of an answer that didn't land as one (the question was withdrawn, or answered already), by
    /// question id: its card says so.
    @Published private(set) var answerNotices: [String: String] = [:]
    /// Witness events already told, so each is told once.
    private var told: Set<String> = []
    /// Ended team sessions the host has been asked to drop.
    private var forgetting: Set<UUID> = []
    /// Terminals being flushed, and when a message was last typed into each (its hooks need a moment to say it's
    /// working again; until then another flush would type a second prompt).
    private var flushing: Set<String> = []
    private var typedAt: [String: Date] = [:]
    /// Messages for a lead that isn't running right now (restarting): delivered once a lead runs there again.
    private var held: [String: [(text: String, sender: SteerMessage.Sender)]] = [:]
    /// What the team's agents are doing, from their hooks and transcripts together (see `LeadActivity`).
    private let observer = LeadObserver()

    init(host: HostClient, store: SessionStore, claudeCommand: @escaping (String) -> String) {
        self.host = host
        self.store = store
        self.claudeCommand = claudeCommand
        summaries.lookup = { [weak host, weak store] id in
            (host?.sessions.first { $0.id.uuidString == id }, store?.sessions.first { $0.hostID?.uuidString == id }?.transcriptPath)
        }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    static var serverPath: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
    }

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

    /// Starts the project lead for the repository holding `folder`, or shows the one already running. A `goal`
    /// goes into its first prompt (or to the running lead); `show: false` leaves the window's selection alone.
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
            if let goal { deliver("New goal from the user: \(goal)", from: .user, to: BoardStore(root: root).load(), root: root) }
            if show { select(running.id) }
            return
        }
        let project = (root as NSString).lastPathComponent
        let boardStore = BoardStore(root: root)
        let vault = LeadVault.standard
        var capability: String?
        do {
            let workflowPath = try boardStore.prepare()
            var workflow = LeadWorkflow.load(from: workflowPath)
            workflow.baseBranch = workflow.baseBranch ?? boardStore.load().baseBranch
            // Only the app makes a lead: its capability (the lead's tools) and the branch as you start it, which
            // merges then check nothing else has moved.
            let token = try vault.startLead(root: root, branch: workflow.baseBranch ?? Worktrees.mainBranch(root: root))
            capability = token
            let name = "lead-\(Slug.make(project, taken: []))"
            let launch = try LeadLaunch.prepare(
                role: .lead, root: root, task: nil, base: claudeCommand(root),
                prompt: LeadPrompts.lead(project: project, root: root, workflow: workflow),
                start: goal.map { "You're starting as the project lead. The user's goal: \($0)\nRead status and the workflow notes, plan the goal into tasks with contracts, start the workers, and tell the user your plan in a few lines." }
                    ?? "You're starting as the project lead. Read status and the workflow notes, then greet the user in one short line: what's on the board, and what they'd like to build next.",
                server: Self.serverPath, name: name, capability: token, folder: vault.runFolder(root: root, name: name))
            host.spawn(SpawnRequest(cwd: root, command: launch.command, env: [:], cols: 120, rows: 40, keepShell: false,
                                    label: "Lead · \(project)", agent: "claude")) { [weak self] result in
                switch result {
                case .success(let session):
                    try? vault.bind(token, root: root, session: session.id.uuidString)
                    try? boardStore.update { board in board.leadSession = session.id.uuidString }
                    // You chose to start the lead here: answer Claude's trust question for this folder.
                    self?.answerTrust(session.id, folder: root)
                    if show { self?.select(session.id) }
                    self?.refresh()
                case .failure(let error):
                    try? vault.revoke(token, root: root)
                    self?.alert("The lead didn't start.", error.message)
                }
            }
        } catch {
            if let capability { try? vault.revoke(capability, root: root) }
            alert("The lead didn't start.", "\(error)")
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
        flush(agent)
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
            seen[id] = LeadWitness.Seen(live: info.isLive, exit: info.exit?.status, status: session?.status,
                                        since: session?.statusSince, detail: session?.detail,
                                        agentQuit: session == nil && info.agentQuit(now: now), apiError: apiError?.text,
                                        apiErrorAt: apiError?.at, activity: watched?.activity,
                                        lastActivity: watched?.progress?.lastWritten, compactedAt: watched?.progress?.compactedAt,
                                        shellRunning: shellRunning, heldSince: held?.at, heldFrom: held.map { Self.sender($0.from) })
            if info.isLive, let session { flush(LeadAgent(pid: session.pid, tty: session.tty, session: id)) }
        }
        for event in LeadWitness.events(board: board, seen: seen, now: now) where told.insert("\(root)|\(event.key)").inserted {
            deliver(event.text, from: .system("witness"), to: board, root: root)
        }
        // On the board too, for status and the Team view, until the worker moves again.
        let stalls = LeadWitness.stalls(board: board, seen: seen, now: now)
        var noted = board
        if noted.noteStalls(stalls) { try? BoardStore(root: root).update { $0.noteStalls(stalls) } }
        // A lead runs again: what was held for it goes now.
        if let waiting = held.removeValue(forKey: root) {
            for message in waiting { deliver(message.text, from: message.sender, to: board, root: root) }
        }
        if let pid = board.leadPid, let tty = board.leadTTY { flush(LeadAgent(pid: pid, tty: tty, session: board.leadSession)) }
    }

    /// Who a waiting message is from, in words.
    private static func sender(_ sender: SteerMessage.Sender) -> String {
        switch sender {
        case .user: return "the user"
        case .lead(let name): return name
        case .system(let about): return "VibeSwitcher (\(about))"
        }
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }
}
