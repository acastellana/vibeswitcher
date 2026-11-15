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
        // A board naming a session on another terminal than the host runs it on (EN-D14) gets nothing of that terminal's
        // inbox woken for: the check again at the moment of typing (`notTheLead`) would refuse it.
        reads.async({ files -> WakeRead in
            guard let lead = LeadHandover.named(files.names.board(root)) else { return .none }
            let hosted = lead.session.flatMap(UUID.init(uuidString:)).flatMap { id in sessions.first { $0.id == id } }
            if let hosted, hosted.tty != lead.tty { return .otherTerminal(hosted.id) }
            inboxRead(lead.tty)
            let pending = SteerInbox.pending(tty: lead.tty, root: inbox).filter { $0.agentPid == lead.pid }
            return .lead(lead, pending, pending.first?.from == .user ? nil : hosted.map { observer.activity($0, agentPid: lead.pid) })
        }) { [weak self] read in
            guard let self else { return }
            switch read {
            case .none:
                self.reportsWaiting(0, root: root)
            case .otherTerminal(let id):
                self.reportsWaiting(0, root: root)
                self.wakeStep(.notTyped(session: id, why: Self.otherTerminal))
            case .lead(let lead, let pending, let activity):
                self.wake(root: root, lead: lead, pending: pending, activity: activity)
            }
        }
    }

    /// What the wake's first read found.
    private enum WakeRead {
        case none
        /// The board names session `id` on another terminal than the session host runs it on.
        case otherTerminal(UUID)
        case lead(LeadAgent, [SteerMessage], LeadActivity?)
    }

    static let otherTerminal = "the board names the lead's session on another terminal than the session host runs it on"

    /// Why nothing was typed when the session host didn't take the unit.
    static let notTaken = "the session host didn't take what was typed (the session went, or the connection closed): it's tried again"


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
                let (vault, runs, inbox, inboxRead, hosted) = (self.link.vault, self.leadRuns, self.root, self.inboxRead, self.link.sessions)
                self.reads.async({ files -> Result<[SteerMessage], Refusal> in
                    if let why = Self.notTheLead(lead, root: root, board: files.names.board(root), vault: vault, hosted: hosted, runs: runs) {
                        return .failure(why)
                    }
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
                            self.type(text, into: id) { taken in
                                guard !taken else { return }
                                // Not in: the next look wakes it again (the reports keep their mark until that wake-up
                                // marks them anew).
                                self.typedAt[lead.tty] = nil
                                if self.wakes[key]?.typedFor == Set(reports.map(\.id)) { self.wakes[key] = LeadWake() }
                                self.wakeStep(.notTyped(session: id, why: Self.notTaken))
                                self.note("lead: the wake-up for the lead of \(LeadMail.project(of: root)) didn't go in: it's typed again at the next look")
                            }
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
            let (vault, runs, inbox, inboxRead, hosted) = (self.link.vault, self.leadRuns, self.root, self.inboxRead, self.link.sessions)
            // A lead's only while the vault binds it and its board still names it, any agent's only while it runs on its
            // terminal: read on `reads`, and what's taken from the inbox typed on the engine's queue.
            self.reads.async({ files -> Result<(prompt: String, taken: [SteerMessage]), Refusal> in
                if let root {
                    if let why = Self.notTheLead(agent, root: root, board: files.names.board(root), vault: vault, hosted: hosted, runs: runs) {
                        return .failure(why)
                    }
                } else if !runs(agent) {
                    return .failure(Refusal("its agent doesn't run on its terminal (it left to a shell, or ended)"))
                }
                guard box == .empty else { return .failure(Refusal("its box isn't empty (\(Self.word(box)))")) }
                inboxRead(agent.tty)
                return Self.takeWaiting(agent, root: inbox).map { .success($0) } ?? .failure(Refusal("nothing waits for it now"))
            }) { [weak self] result in
                guard let self else { return }
                self.flushing.remove(agent.tty)
                switch result {
                case .failure(let why):
                    self.wakeStep(.notTyped(session: id, why: why.description))
                case .success(let waiting):
                    self.typedAt[agent.tty] = Date()
                    self.type(waiting.prompt, into: id) { taken in
                        guard !taken else { return }
                        // Not in: what was taken waits in the inbox again (behind what came meanwhile), typed at the next look.
                        self.typedAt[agent.tty] = nil
                        let (inbox, inboxRead) = (self.root, self.inboxRead)
                        self.reads.async({ _ -> Int in
                            inboxRead(agent.tty)
                            return waiting.taken.filter { message in
                                (try? SteerInbox.post(SteerMessage(text: Self.whole(message), from: message.from, agentPid: message.agentPid),
                                                      tty: agent.tty, root: inbox)) != nil
                            }.count
                        }) { [weak self] back in
                            guard let self else { return }
                            self.wakeStep(.notTyped(session: id, why: Self.notTaken))
                            self.note("lead: what was typed into session \(id) didn't go in: \(back) of \(waiting.taken.count) message(s) wait in its inbox again")
                        }
                    }
                }
            }
        }
    }

    /// As one unit through the link, in order with what else is typed into that session: a bracketed paste and its
    /// Enter, so a text that starts with a digit is text, never an option's key. `then` hears on `queue`, after this
    /// returns, whether the host took all of it. On `queue`.
    func type(_ text: String, into id: UUID, then: @escaping (Bool) -> Void = { _ in }) {
        let writes = ComposerText.writes(text, bracketed: true)
        typing(id, writes)
        wakeStep(.typed(session: id, text: text))
        let confirmed: (Bool) -> Void = { [queue] taken in queue.async { then(taken) } }
        if let typeUnit { typeUnit(writes, id, confirmed) } else { link.type(writes, into: id, confirmed: confirmed) }
    }

    /// What waits for `agent`, taken from its inbox to be typed as its next prompt, with the messages taken; nil when
    /// nothing does. `LeadDelivery.flush`'s way (the first message, marked as its sender's, the rest left to the prompt's
    /// hook; a Codex agent's whole queue in one prompt), keeping what it took so it can go back. On `reads`.
    static func takeWaiting(_ agent: LeadAgent, root: URL) -> (prompt: String, taken: [SteerMessage])? {
        guard SteerInbox.pending(tty: agent.tty, root: root).contains(where: { $0.agentPid == agent.pid && $0.wakesLead }) else { return nil }
        var waiting: (prompt: String, taken: [SteerMessage])?
        SteerInbox.deliver(tty: agent.tty, agentPid: agent.pid, root: root, wholeBatch: agent.agent == .codex) { messages in
            guard let first = messages.first else { return 0 }
            let taken = agent.agent == .codex ? messages : [first]
            waiting = (taken.map { LeadDelivery.typed(whole($0), from: $0.from) }.joined(separator: "\n\n"), taken)
            return taken.count
        }
        return waiting
    }

    /// A message as it's typed: a long one whose first parts its agent got at its steps, the rest, saying so.
    static func whole(_ message: SteerMessage) -> String {
        (message.handedOver ?? 0) > 0 ? "(The rest of the long message whose first part reached you earlier.) " + message.remainingText : message.text
    }

    /// Why `lead` isn't the one to type into now, on `reads` (`target`'s check): the board names another, the vault binds
    /// the lead's role to another session (or none), the board names it on another terminal than the session host runs
    /// it on, or its agent left its terminal; nil when it is.
    static func notTheLead(_ lead: LeadAgent, root: String, board: LeadBoard, vault: LeadVault, hosted: [HostSession],
                           runs: (LeadAgent) -> Bool) -> Refusal? {
        guard let named = LeadHandover.named(board), named.pid == lead.pid, named.tty == lead.tty, named.session == lead.session else {
            return Refusal("the board names another lead now")
        }
        switch target(root: root, board: board, vault: vault, hosted: hosted, runs: runs) {
        case .lead: return nil
        case .notBound: return Refusal("the vault binds the lead's role to another session")
        case .otherTerminal: return Refusal(otherTerminal)
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
