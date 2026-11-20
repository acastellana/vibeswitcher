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
    /// (`SessionPrompt`), and `draft`, the message a page left for it (`SessionDraft`), each null when there's none;
    /// and `queued`, the messages `send` holds for it until its question closes (`HeldSend`, the composer's lane).
    public func liveValue(prompt: SessionPrompt?, draft: SessionDraft?, queued: [HeldSend] = []) -> NodeWire.Value {
        guard case .object(var fields) = liveValue else { return liveValue }
        fields["prompt"] = prompt?.value ?? .null
        fields["draft"] = draft?.value ?? .null
        fields["queued"] = .array(queued.map(\.value))
        return .object(fields)
    }
}

/// The `sessions` collection's values: each session with its prompt, draft and held messages
/// (`Session.liveValue(prompt:draft:queued:)`), sent again when any of them changes, by the node's id for the session. A
/// draft whose session went is dropped (its held messages go at their next look, `Requests.pumpHeld`).
/// On `queue` (the engine's, the stores').
final class SessionLiveValues: @unchecked Sendable {
    let changes = Changes<NodeWire.Value>()
    private let queue: DispatchQueue
    private let sessions: NodeSessions
    private let drafts: Changes<SessionDraft>
    private let held: Changes<[HeldSend]>
    private var follows: [Subscription] = []

    init(queue: DispatchQueue, sessions: NodeSessions, drafts: Changes<SessionDraft>, held: Changes<[HeldSend]> = Changes()) {
        self.queue = queue
        self.sessions = sessions
        self.drafts = drafts
        self.held = held
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
        follows.append(held.subscribe(on: queue) { [weak self] batch in self?.update(batch.map(\.id)) })
        update(Array(sessions.changes.values.keys))
    }

    private func update(_ ids: [String]) {
        let (all, prompts, drafts, held) = (sessions.changes.values, sessions.prompts.values, self.drafts.values, self.held.values)
        for id in Set(ids).sorted() {
            let value = all[id].map { $0.liveValue(prompt: prompts[id], draft: drafts[id], queued: held[id] ?? []) }
            if changes.values[id] != value { changes.send(id, value) }
        }
    }
}
