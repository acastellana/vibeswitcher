import AppKit
import Combine
import Foundation
import VibeCore

/// The app's side of project leads: starting them, keeping their boards loaded, answering their questions, and
/// being their witness (telling a lead when one of its workers needs input, stops without reporting, or dies).
final class LeadController: ObservableObject {
    /// Each running lead's board, by repository root.
    @Published private(set) var boards: [String: LeadBoard] = [:]

    private let host: HostClient
    private let store: SessionStore
    /// The project's Claude command (its launch preset), flags included.
    private let claudeCommand: (String) -> String
    var notify: (String, String) -> Void = { _, _ in }
    var select: (UUID) -> Void = { _ in }
    private var timer: Timer?
    private var seenQuestions: Set<String> = []
    /// Witness events already told, so each is told once.
    private var told: Set<String> = []
    /// Terminals being flushed, and when a message was last typed into each (its hooks need a moment to say it's
    /// working again; until then another flush would type a second prompt).
    private var flushing: Set<String> = []
    private var typedAt: [String: Date] = [:]

    init(host: HostClient, store: SessionStore, claudeCommand: @escaping (String) -> String) {
        self.host = host
        self.store = store
        self.claudeCommand = claudeCommand
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
        let top = Git.run(["rev-parse", "--show-toplevel"], in: folder)
        guard top.ok, !top.output.isEmpty else {
            return alert("A project lead needs a git repository.", "\(folder) isn't in one. Run git init (and make a first commit) first.")
        }
        let root = (top.output as NSString).standardizingPath
        guard Git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root).ok else {
            return alert("The repository has no commits yet.", "Workers branch from main: make a first commit in \(root), then start the lead.")
        }
        if let running = leadSessions[root] {
            if let goal { deliver("New goal from the user: \(goal)", from: .user, to: BoardStore(root: root).load()) }
            if show { select(running.id) }
            return
        }
        let project = (root as NSString).lastPathComponent
        let boardStore = BoardStore(root: root)
        do {
            try boardStore.ensureExcluded()
            let workflowPath = (boardStore.folder as NSString).appendingPathComponent("workflow.md")
            if !FileManager.default.fileExists(atPath: workflowPath) {
                try LeadWorkflow.template.write(toFile: workflowPath, atomically: true, encoding: .utf8)
            }
            let workflow = LeadWorkflow.parse((try? String(contentsOfFile: workflowPath, encoding: .utf8)) ?? "")
            let launch = try LeadLaunch.prepare(
                role: .lead, root: root, task: nil, base: claudeCommand(root),
                prompt: LeadPrompts.lead(project: project, root: root, workflow: workflow),
                start: goal.map { "You're starting as the project lead. The user's goal: \($0)\nRead status and the workflow notes, plan the goal into tasks with contracts, start the workers, and tell the user your plan in a few lines." }
                    ?? "You're starting as the project lead. Read status and the workflow notes, then greet the user in one short line: what's on the board, and what they'd like to build next.",
                server: Self.serverPath, name: "lead-\(Slug.make(project, taken: []))")
            host.spawn(SpawnRequest(cwd: root, command: launch.command, env: [:], cols: 120, rows: 40, keepShell: false,
                                    label: "Lead · \(project)", agent: "claude")) { [weak self] result in
                switch result {
                case .success(let session):
                    try? boardStore.update { board in board.leadSession = session.id.uuidString }
                    // You chose to start the lead here: answer Claude's trust question for this folder.
                    self?.answerTrust(session.id, folder: root)
                    if show { self?.select(session.id) }
                    self?.refresh()
                case .failure(let error):
                    self?.alert("The lead didn't start.", error.message)
                }
            }
        } catch {
            alert("The lead didn't start.", "\(error)")
        }
    }

    // MARK: Questions

    /// Your answer: recorded on the board and delivered to the lead (steered in while it works, typed while idle).
    func answer(_ question: LeadQuestion, root: String, with text: String) {
        let store = BoardStore(root: root)
        try? store.update { board in
            guard let index = board.questions.firstIndex(where: { $0.id == question.id }) else { return }
            board.questions[index].answer = text
            board.questions[index].answeredAt = Date().timeIntervalSince1970
        }
        let board = store.load()
        deliver("Answer to your question “\(question.text)”: \(text)", from: .user, to: board)
        refresh()
    }

    /// Steered in while the lead works; while it's idle the message waits in its inbox and `flush` types it as soon
    /// as its input box is empty (never into your draft; a draft you send takes it along).
    private func deliver(_ text: String, from sender: SteerMessage.Sender, to board: LeadBoard) {
        guard let pid = board.leadPid, let tty = board.leadTTY else { return }
        let agent = LeadAgent(pid: pid, tty: tty, session: board.leadSession)
        try? LeadDelivery.deliver(text, from: sender, to: agent, inputIsEmpty: nil, typeInto: nil)
        flush(agent)
    }

    /// Types what waits for an idle agent in a window session, once its input box is empty.
    private func flush(_ agent: LeadAgent) {
        guard let id = agent.session.flatMap(UUID.init(uuidString:)),
              SteerInbox.pending(tty: agent.tty).contains(where: { $0.agentPid == agent.pid }) else { return }
        let state = HookState.load(from: VibePaths.stateFile(tty: agent.tty))
        guard LeadDelivery.way(for: state) == .type, !flushing.contains(agent.tty),
              Date().timeIntervalSince(typedAt[agent.tty] ?? .distantPast) > 10 else { return }
        flushing.insert(agent.tty)
        host.screen(id) { [weak self] screen in
            guard let self else { return }
            self.flushing.remove(agent.tty)
            guard let screen, TerminalInput.isEmpty(screen) else { return }
            LeadDelivery.flush(agent, state: state, inputIsEmpty: { true }, typeInto: { text in
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
        for (root, board) in loaded {
            for question in board.questions where question.answer == nil && !seenQuestions.contains(question.id) {
                seenQuestions.insert(question.id)
                notify("The lead of \((root as NSString).lastPathComponent) asks", question.text)
            }
            witness(root: root, board: board)
        }
    }

    /// Tells the lead what its team can't (see `LeadWitness`), and types waiting messages into idle team members.
    private func witness(root: String, board: LeadBoard) {
        let hosted = Dictionary(uniqueKeysWithValues: host.sessions.map { ($0.id.uuidString, $0) })
        var seen: [String: LeadWitness.Seen] = [:]
        for id in board.tasks.flatMap({ [$0.worker, $0.verifier] }).compactMap({ $0 }) {
            guard let info = hosted[id] else { continue }
            let session = store.sessions.first { $0.hostID?.uuidString == id }
            seen[id] = LeadWitness.Seen(live: info.isLive, exit: info.exit?.status, status: session?.status,
                                        since: session?.statusSince, detail: session?.detail)
            if info.isLive, let session { flush(LeadAgent(pid: session.pid, tty: session.tty, session: id)) }
        }
        for event in LeadWitness.events(board: board, seen: seen) where told.insert("\(root)|\(event.key)").inserted {
            deliver(event.text, from: .system("witness"), to: board)
        }
        if let pid = board.leadPid, let tty = board.leadTTY { flush(LeadAgent(pid: pid, tty: tty, session: board.leadSession)) }
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }
}
