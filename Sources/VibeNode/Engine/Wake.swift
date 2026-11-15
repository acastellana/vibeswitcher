import Foundation
import VibeCore

/// A step of typing into a session (`LeadEngine.wakeStep`, for tests): its box was read (before the last look that
/// decides), what was typed, or why nothing was.
public enum WakeStep: Equatable, Sendable {
    case screenRead(session: UUID)
    case typed(session: UUID, text: String)
    case notTyped(session: UUID, why: String)
}

/// Waking the lead and typing what waits for an agent (the engine plan's E5; the app's `wake`, `flush`,
/// `type(waiting:id:lead:)` and `type(_:into:)`, `LeadController.swift` 1331-1448 and 1462-1467, and `ReportsWaiting`,
/// 6-20). Reports wait in the lead's inbox and its hooks hand them over at its next step or prompt; an idle lead takes
/// no step, so one short prompt is typed for every report that waits (`LeadWake`), once, into an empty box, and none
/// again until the lead has taken a turn. The user's words that wait are typed as they are (`flush`), and the reports
/// go along with them. Typed only into the lead the vault binds and the board names at the moment of typing, while its
/// agent runs on its terminal: never into a shell the agent left. The boards, the inboxes and the transcripts are read on
/// `reads`, never the engine's queue. No dictation check: `ClaudeVoiceRun` is the Mac's.
extension LeadEngine {
    /// What the app's refresh does for delivery, every 3 s on the engine's clock until E7's refresh takes it: for each
    /// project's lead, what's held for it goes once it can take it, and it's woken for what waits. On `queue`.
    public func look() {
        for root in Set(leads.leads.values.map(\.root)).sorted() {
            deliverHeld(root: root)
            wake(root: root)
        }
    }

    /// Wakes `root`'s lead for the reports that wait for it, or types the user's words that wait (`flush`). On `queue`.
    func wake(root: String) {
        let (sessions, observer, inbox, inboxRead) = (link.sessions, observer, self.root, self.inboxRead)
        // The lead the board names, what waits for it, and what it's doing (its hooks and transcript), read on `reads`.
        reads.async({ files -> (lead: LeadAgent, pending: [SteerMessage], activity: LeadActivity?)? in
            guard let lead = LeadHandover.named(files.names.board(root)) else { return nil }
            let hosted = lead.session.flatMap(UUID.init(uuidString:)).flatMap { id in sessions.first { $0.id == id } }
            inboxRead(lead.tty)
            let pending = SteerInbox.pending(tty: lead.tty, root: inbox).filter { $0.agentPid == lead.pid }
            return (lead, pending, pending.first?.from == .user ? nil : hosted.map { observer.activity($0, agentPid: lead.pid) })
        }) { [weak self] read in
            guard let self else { return }
            guard let read else { return self.reportsWaiting(0, root: root) }
            self.wake(root: root, lead: read.lead, pending: read.pending, activity: read.activity)
        }
    }

    private func wake(root: String, lead: LeadAgent, pending: [SteerMessage], activity: LeadActivity?) {
        let reports = LeadWake.reports(pending, agentPid: lead.pid)
        let now = Date().timeIntervalSince1970
        reportsWaiting(LeadWake.waiting(reports, now: now), root: root)
        if pending.contains(where: { $0.from == .user }) { return flush(lead, lead: root) }
        // A lead that ended, or another agent on its terminal now: the old one's wake-ups go.
        let key = "\(lead.tty)#\(lead.pid)"
        if let old = wakeKeys[root], old != key { wakes[old] = nil }
        wakeKeys[root] = key
        guard let id = lead.session.flatMap(UUID.init(uuidString:)), let activity else { return }
        var state = wakes[key] ?? LeadWake()
        let step = state.step(reports: reports, activity: activity, now: now)
        wakes[key] = state
        switch step {
        case .none:
            // A wake-up typed for what waits now, and the lead hasn't taken a turn since (none of them was taken).
            if reports.contains(where: { state.typedFor.contains($0.id) }) {
                wakeStep(.notTyped(session: id, why: "a wake-up was typed for what waits: none again until the lead has taken a turn"))
            }
        case .later(let due):
            // More may come: one look again then (a wait, not a poll).
            guard wakeLater.insert(key).inserted else { return }
            queue.asyncAfter(deadline: .now() + max(0, due - now) + 0.2) { [weak self] in
                self?.wakeLater.remove(key)
                self?.wake(root: root)
            }
        case .ready:
            // A prompt typed a moment ago (its hooks haven't said it's working yet) is one in flight too.
            guard !flushing.contains(lead.tty), Date().timeIntervalSince(typedAt[lead.tty] ?? .distantPast) > 10 else { return }
            flushing.insert(lead.tty)
            link.styledScreen(id) { [weak self] screen in
                guard let self else { return }
                self.wakeStep(.screenRead(session: id))
                // Still the lead the vault binds and the board names, its agent on its terminal, and what waits now (its
                // hook may have taken some meanwhile), read on `reads`. Typed only into an empty box: Claude's dim
                // suggestion counts as empty, a draft or a dialog waits for the next try. The reports it's for are marked
                // in the inbox, under its lock, before it's typed: a Stop hook or a step before the prompt goes in leaves
                // them to the prompt's hook, so they don't come twice.
                let box = screen.map(LeadDelivery.box(in:))
                let (vault, runs, inbox, inboxRead) = (self.link.vault, self.leadRuns, self.root, self.inboxRead)
                self.reads.async({ files -> Result<[SteerMessage], Refusal> in
                    if let why = Self.notTheLead(lead, root: root, board: files.names.board(root), vault: vault, runs: runs) { return .failure(why) }
                    guard box == .empty else { return .failure(Refusal("its box isn't empty (\(Self.word(box)))")) }
                    inboxRead(lead.tty)
                    guard let reports = SteerInbox.wake(tty: lead.tty, agentPid: lead.pid, root: inbox, type: { _ in true }) else {
                        return .failure(Refusal("no report waits for it now"))
                    }
                    return .success(reports)
                }) { [weak self] result in
                    guard let self else { return }
                    self.flushing.remove(lead.tty)
                    switch result {
                    case .failure(let why):
                        self.wakeStep(.notTyped(session: id, why: why.description))
                    case .success(let reports):
                        var state = self.wakes[key] ?? LeadWake()
                        state.type(reports: reports, box: box) { text in
                            self.typedAt[lead.tty] = Date()
                            self.type(text, into: id)
                            self.note("lead: woke the lead of \(LeadMail.project(of: root)) on \(lead.tty) for \(reports.count) report(s)")
                            return true
                        }
                        self.wakes[key] = state
                    }
                }
            }
        }
    }

    /// Types what waits for an idle agent once its input box is empty. Only between turns: a missing or stale state file
    /// isn't an idle agent (its transcript says whether it's mid-turn). A lead's (`lead`: its root) only while the vault
    /// binds it and the board names it. On `queue`.
    func flush(_ agent: LeadAgent, lead root: String? = nil) {
        guard let id = agent.session.flatMap(UUID.init(uuidString:)), let hosted = link.sessions.first(where: { $0.id == id }),
              !flushing.contains(agent.tty), Date().timeIntervalSince(typedAt[agent.tty] ?? .distantPast) > 10 else { return }
        let (observer, inbox, inboxRead) = (observer, self.root, self.inboxRead)
        // Whether something waits for it and it's between turns: its inbox and its transcript, read on `reads`.
        reads.async({ _ -> Bool in
            inboxRead(agent.tty)
            return SteerInbox.pending(tty: agent.tty, root: inbox).contains { $0.agentPid == agent.pid }
                && observer.activity(hosted, agentPid: agent.pid).betweenTurns
        }) { [weak self] ready in
            guard ready, let self else { return }
            self.type(waiting: agent, id: id, lead: root)
        }
    }

    /// What waits for an agent between turns, typed once its box is empty (`flush`). On `queue`.
    private func type(waiting agent: LeadAgent, id: UUID, lead root: String?) {
        guard !flushing.contains(agent.tty), Date().timeIntervalSince(typedAt[agent.tty] ?? .distantPast) > 10 else { return }
        flushing.insert(agent.tty)
        link.styledScreen(id) { [weak self] screen in
            guard let self else { return }
            self.wakeStep(.screenRead(session: id))
            // Claude's dim suggested prompt isn't a draft: typing replaces it.
            let box = screen.map(LeadDelivery.box(in:))
            let (vault, runs, inbox, inboxRead) = (self.link.vault, self.leadRuns, self.root, self.inboxRead)
            // A lead's only while the vault binds it and its board still names it, any agent's only while it runs on its
            // terminal: read on `reads`, and what's taken from the inbox typed on the engine's queue.
            self.reads.async({ files -> Result<String, Refusal> in
                if let root {
                    if let why = Self.notTheLead(agent, root: root, board: files.names.board(root), vault: vault, runs: runs) { return .failure(why) }
                } else if !runs(agent) {
                    return .failure(Refusal("its agent doesn't run on its terminal (it left to a shell, or ended)"))
                }
                guard box == .empty else { return .failure(Refusal("its box isn't empty (\(Self.word(box)))")) }
                inboxRead(agent.tty)
                var typed: String?
                LeadDelivery.flush(agent, betweenTurns: true, inputIsEmpty: { true }, typeInto: { text in
                    typed = text
                    return true
                }, root: inbox)
                return typed.map { .success($0) } ?? .failure(Refusal("nothing waits for it now"))
            }) { [weak self] result in
                guard let self else { return }
                self.flushing.remove(agent.tty)
                switch result {
                case .failure(let why):
                    self.wakeStep(.notTyped(session: id, why: why.description))
                case .success(let text):
                    self.typedAt[agent.tty] = Date()
                    self.type(text, into: id)
                }
            }
        }
    }

    /// As one unit through the link, in order with what else is typed into that session: a bracketed paste and its
    /// Enter, so a text that starts with a digit is text, never an option's key. On `queue`.
    func type(_ text: String, into id: UUID) {
        let writes = ComposerText.writes(text, bracketed: true)
        typing(id, writes)
        wakeStep(.typed(session: id, text: text))
        link.type(writes, into: id)
    }

    /// Why `lead` isn't the one to type into now, on `reads`: the board names another, the vault binds the lead's role
    /// to another session (or none), or its agent left its terminal; nil when it is.
    static func notTheLead(_ lead: LeadAgent, root: String, board: LeadBoard, vault: LeadVault, runs: (LeadAgent) -> Bool) -> Refusal? {
        guard let named = LeadHandover.named(board), named.pid == lead.pid, named.tty == lead.tty, named.session == lead.session else {
            return Refusal("the board names another lead now")
        }
        switch target(root: root, board: board, vault: vault, runs: runs) {
        case .lead: return nil
        case .notBound: return Refusal("the vault binds the lead's role to another session")
        case .notRunning: return Refusal("the lead's agent doesn't run on its terminal (it left to a shell, or ended)")
        case .noLead: return Refusal("the board names no lead now")
        }
    }

    /// A box that isn't empty, in a word.
    static func word(_ box: LeadDelivery.Box?) -> String {
        switch box {
        case .empty?: return "empty"
        case .draft?: return "a draft"
        case .dialog?: return "a dialog is open"
        case nil: return "its screen didn't read"
        }
    }

    /// How many reports have waited for `root`'s lead too long (`LeadWake.waiting`), in `status`. On `queue`.
    func reportsWaiting(_ count: Int, root: String) {
        let project = NodeIds.project(root: root)
        guard let lead = leads.leads[project], lead.reportsWaiting != count else { return }
        leads.lead(root: root) { $0.reportsWaiting = count }
    }

    /// Why something wasn't typed.
    struct Refusal: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
