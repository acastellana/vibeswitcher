import Foundation
import VibeCore

extension Session {
    /// A session as the live protocol's `sessions` collection carries it (the live wire contract's §5): the eight fields
    /// `status` writes (`Requests.value(_:)`), by the same names and unchanged, and twelve more, every one present (null
    /// when it holds nothing). Fields marked † in the contract (`project`, `task`, `detail`, `activity`, `startFolder`,
    /// `cwd`) are an agent's or a path's words: a client shows them as text only.
    public var liveValue: NodeWire.Value {
        guard case .object(var fields) = Requests.value(self) else { return Requests.value(self) }
        fields["shownStatus"] = .string(Requests.statusWord(shownStatus))
        fields["project"] = .string(project)
        fields["task"] = task.map(NodeWire.Value.string) ?? .null
        fields["detail"] = detail.map(NodeWire.Value.string) ?? .null
        fields["activity"] = activity.map(NodeWire.Value.string) ?? .null
        fields["activitySince"] = activitySince.map(NodeWire.Value.date) ?? .null
        fields["startedAt"] = .date(startedAt)
        fields["hasHooks"] = .bool(hasHooks)
        fields["leadAsks"] = .bool(leadAsks)
        fields["startFolder"] = startFolder.map(NodeWire.Value.string) ?? .null
        fields["backgroundJobs"] = .int(backgroundJobs.count)
        fields["hasTranscript"] = .bool(transcriptPath != nil)
        // Your name for it and its pause (`SessionMarks`, 2026-11-20), and the agent's own session id (what `--resume` takes).
        fields["name"] = customName.map(NodeWire.Value.string) ?? .null
        fields["pausedUntil"] = pausedUntil.map(NodeWire.Value.date) ?? .null
        fields["agentSession"] = agentSessionID.map(NodeWire.Value.string) ?? .null
        // The inspector's (the parity table's Inspector row, 2026-11-21): the agent's process, and the board a team's
        // session is on: its project's id (`lead`) and, for a worker or a verifier, its task's slug (`boardTask`), both
        // from the folder the host started it in, as the app tells a team (`LeadTeams`).
        fields["pid"] = .int(Int(pid))
        let team = teamProject
        fields["lead"] = team.map { .string(NodeIds.project(root: $0.root)) } ?? .null
        fields["boardTask"] = team?.task.map(NodeWire.Value.string) ?? .null
        return .object(fields)
    }

    /// The project root a lead's, worker's or verifier's board is under, and the task's slug for a worker or a verifier:
    /// a lead's own folder, a worker's worktree's repository. Nil for a session with no role, or no folder to tell by.
    var teamProject: (root: String, task: String?)? {
        guard let role = teamRole, let folder = startFolder else { return nil }
        if role == .lead { return ((folder as NSString).standardizingPath, nil) }
        guard let root = LeadTeams.root(ofWorktree: folder) else { return nil }
        return ((root as NSString).standardizingPath, LeadTeams.task(ofWorktree: folder))
    }
}

extension Session {
    /// `liveValue` with what the node keeps beside the session (2026-11-20): `prompt`, the question open on its screen
    /// (`SessionPrompt`), and `draft`, the message a page left for it (`SessionDraft`), each null when there's none;
    /// and `queued`, the messages `send` holds for it until its question closes (`HeldSend`, the composer's lane).
    ///
    /// And the inspector's facts from beside it (2026-11-21): `branch`, its folder's git branch (`GitBranch`, read by the
    /// caller); `command` and `size`, from the host's record of the session (`host`): the preset's command with any
    /// credential in it masked (`Redaction`, `PushText.scrub`; null for a shell), and the terminal's columns and rows.
    /// Null where the host doesn't run it.
    public func liveValue(prompt: SessionPrompt?, draft: SessionDraft?, queued: [HeldSend] = [], host: HostSession? = nil,
                          branch: String? = nil) -> NodeWire.Value {
        guard case .object(var fields) = liveValue else { return liveValue }
        fields["prompt"] = prompt?.value ?? .null
        fields["draft"] = draft?.value ?? .null
        fields["queued"] = .array(queued.map(\.value))
        fields["branch"] = branch.map(NodeWire.Value.string) ?? .null
        fields["command"] = host?.command.map { .string(Redaction.secrets(in: PushText.scrub($0))) } ?? .null
        fields["size"] = host.map { .object(["cols": .int($0.cols), "rows": .int($0.rows)]) } ?? .null
        return .object(fields)
    }
}

/// The `sessions` collection's values: each session with its prompt, draft and held messages
/// (`Session.liveValue(prompt:draft:queued:host:branch:)`), sent again when any of them changes, by the node's id for the
/// session. A draft whose session went is dropped (its held messages go at their next look, `Requests.pumpHeld`).
///
/// The host's record of a hosted session (`hosts`, the link's changes by the same ids) gives its command and size: a
/// resize is sent, a title changing (many times a second while an agent works) reads the same value and isn't. Its git
/// branch is read again (`branch`, `GitBranch.current` by default) each time the session itself changes, so a branch
/// switched shows at the session's next change (its status moves as its agent works), with no read per title.
/// On `queue` (the engine's, the stores').
final class SessionLiveValues: @unchecked Sendable {
    let changes = Changes<NodeWire.Value>()
    private let queue: DispatchQueue
    private let sessions: NodeSessions
    private let drafts: Changes<SessionDraft>
    private let held: Changes<[HeldSend]>
    private let hosts: Changes<HostSession>
    private let branch: (String) -> String?
    /// Each session's folder and its branch as last read.
    private var branches: [String: (cwd: String?, branch: String?)] = [:]
    private var follows: [Subscription] = []

    init(queue: DispatchQueue, sessions: NodeSessions, drafts: Changes<SessionDraft>, held: Changes<[HeldSend]> = Changes(),
         hosts: Changes<HostSession> = Changes(), branch: @escaping (String) -> String? = { GitBranch.current(in: $0) }) {
        self.queue = queue
        self.sessions = sessions
        self.drafts = drafts
        self.held = held
        self.hosts = hosts
        self.branch = branch
    }

    /// Follows them all, and sends what each holds now. On `queue`, once.
    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        follows.append(sessions.changes.subscribe(on: queue) { [weak self] batch in
            guard let self else { return }
            for gone in batch where gone.value == nil && self.drafts.values[gone.id] != nil { self.drafts.send(gone.id, nil) }
            self.readBranches(batch.map(\.id))
            self.update(batch.map(\.id))
        })
        follows.append(sessions.prompts.subscribe(on: queue) { [weak self] batch in self?.update(batch.map(\.id)) })
        follows.append(drafts.subscribe(on: queue) { [weak self] batch in self?.update(batch.map(\.id)) })
        follows.append(held.subscribe(on: queue) { [weak self] batch in self?.update(batch.map(\.id)) })
        follows.append(hosts.subscribe(on: queue) { [weak self] batch in self?.update(batch.map(\.id)) })
        readBranches(Array(sessions.changes.values.keys))
        update(Array(sessions.changes.values.keys))
    }

    /// The branch of each of `ids`' folders, read again; a session gone forgets its own.
    private func readBranches(_ ids: [String]) {
        for id in ids {
            guard let session = sessions.changes.values[id] else {
                branches[id] = nil
                continue
            }
            branches[id] = (session.cwd, session.cwd.flatMap(branch))
        }
    }

    private func update(_ ids: [String]) {
        let (all, prompts, drafts, held, hosts) = (sessions.changes.values, sessions.prompts.values, self.drafts.values, self.held.values,
                                                   self.hosts.values)
        for id in Set(ids).sorted() {
            let value = all[id].map { session in
                session.liveValue(prompt: prompts[id], draft: drafts[id], queued: held[id] ?? [], host: hosts[id],
                                  branch: branches[id].flatMap { $0.cwd == session.cwd ? $0.branch : nil })
            }
            if changes.values[id] != value { changes.send(id, value) }
        }
    }
}
