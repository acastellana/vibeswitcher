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
        return .object(fields)
    }
}

extension Session {
    /// `liveValue` with what the node keeps beside the session (2026-11-20): `prompt`, the question open on its screen
    /// (`SessionPrompt`), and `draft`, the message a page left for it (`SessionDraft`), each null when there's none.
    public func liveValue(prompt: SessionPrompt?, draft: SessionDraft?) -> NodeWire.Value {
        guard case .object(var fields) = liveValue else { return liveValue }
        fields["prompt"] = prompt?.value ?? .null
        fields["draft"] = draft?.value ?? .null
        return .object(fields)
    }
}

/// The `sessions` collection's values: each session with its prompt and draft (`Session.liveValue(prompt:draft:)`),
/// sent again when any of the three changes, by the node's id for the session. A draft whose session went is dropped.
/// On `queue` (the engine's, the stores').
final class SessionLiveValues: @unchecked Sendable {
    let changes = Changes<NodeWire.Value>()
    private let queue: DispatchQueue
    private let sessions: NodeSessions
    private let drafts: Changes<SessionDraft>
    private var follows: [Subscription] = []

    init(queue: DispatchQueue, sessions: NodeSessions, drafts: Changes<SessionDraft>) {
        self.queue = queue
        self.sessions = sessions
        self.drafts = drafts
    }

    /// Follows the three, and sends what each holds now. On `queue`, once.
    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        follows.append(sessions.changes.subscribe(on: queue) { [weak self] batch in
            guard let self else { return }
            for gone in batch where gone.value == nil && self.drafts.values[gone.id] != nil { self.drafts.send(gone.id, nil) }
            self.update(batch.map(\.id))
        })
        follows.append(sessions.prompts.subscribe(on: queue) { [weak self] batch in self?.update(batch.map(\.id)) })
        follows.append(drafts.subscribe(on: queue) { [weak self] batch in self?.update(batch.map(\.id)) })
        update(Array(sessions.changes.values.keys))
    }

    private func update(_ ids: [String]) {
        let (all, prompts, drafts) = (sessions.changes.values, sessions.prompts.values, self.drafts.values)
        for id in Set(ids).sorted() {
            let value = all[id].map { $0.liveValue(prompt: prompts[id], draft: drafts[id]) }
            if changes.values[id] != value { changes.send(id, value) }
        }
    }
}
