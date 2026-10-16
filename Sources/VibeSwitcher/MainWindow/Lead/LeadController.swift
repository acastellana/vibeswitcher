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

    private func deliver(_ text: String, from sender: SteerMessage.Sender, to board: LeadBoard) {
        guard let pid = board.leadPid, let tty = board.leadTTY else { return }
        let session = board.leadSession.flatMap(UUID.init(uuidString:))
        try? LeadDelivery.deliver(text, from: sender, to: LeadAgent(pid: pid, tty: tty, session: board.leadSession),
                                  typeInto: session.map { id in { [weak self] typed in
                                      self?.type(typed, into: id)
                                      return true
                                  } })
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

    /// Tells the lead what its workers can't: that one is waiting for input, stopped without reporting, or died.
    private func witness(root: String, board: LeadBoard) {
        let hosted = Dictionary(uniqueKeysWithValues: host.sessions.map { ($0.id.uuidString, $0) })
        for task in board.tasks where task.status == .running {
            guard let worker = task.worker else { continue }
            let session = store.sessions.first { $0.hostID?.uuidString == worker }
            var event: (key: String, text: String)?
            if let info = hosted[worker], !info.isLive {
                event = ("ended", "The worker on \(task.slug) ended (exit \(info.exit?.status ?? 0)) without reporting. Its commits are on agent/\(task.slug); read_session to see why, then start_worker again or re-plan.")
            } else if let session, session.status == .needsInput {
                event = ("input-\(Int(session.statusSince.timeIntervalSince1970))",
                         "The worker on \(task.slug) is waiting for input: \(session.detail ?? "a question or a permission"). Answer it with message, or tell the user if it's theirs to decide.")
            } else if let session, [.done, .idle].contains(session.status), Date().timeIntervalSince(session.statusSince) > 90 {
                event = ("stopped-\(Int(session.statusSince.timeIntervalSince1970))",
                         "The worker on \(task.slug) stopped without calling report. read_session to see where it is, then message it.")
            }
            guard let event, told.insert("\(root)|\(task.id)|\(event.key)").inserted else { continue }
            deliver(event.text, from: .system("witness for \(task.slug)"), to: board)
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
