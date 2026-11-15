import Foundation
import VibeCore

/// What became of a message for a session's agent (`LeadEngine.tell`; the app's `SessionDelivery`,
/// `LeadController.swift` 2287-2295, copied: the port map's "Copied from the app").
public enum SessionDelivery: Equatable, Sendable {
    /// In its steer inbox: its hook hands it over at the agent's next step.
    case delivered
    /// Not now, but it may go later: the session host hasn't welcomed the engine yet (or is gone), or the post failed.
    case notYet
    /// The session host, welcomed, says its session ended or doesn't run it: no agent there will read it.
    case ended
}

/// Delivering to a project's lead (the engine plan's E5; the app's `LeadController.deliver`, `next` and `hold`,
/// `LeadController.swift` 1203-1251, and `tell`, 1984-2013). A message goes to the session the vault binds the project's
/// lead role to (EN-D14), on the terminal the session host runs that session on, when the board names that session on
/// that terminal and its agent runs there: posted into its steer inbox under the engine's root (as `LeadDelivery.deliver`
/// posts, with the message's own id), steered in at its next step, or typed in between turns by the wake (`Wake.swift`).
/// Otherwise it's held, in the order sent, and kept at rest in `engine.json` (EN-D9) with its id and the action id of
/// the user's request that made it; a board naming a session the vault doesn't bind, or the bound one on another
/// terminal, gets nothing, and `status` carries a notice. The board, the vault and the inbox are read on `reads`, never
/// the engine's queue.
extension LeadEngine {
    /// Sends `text` from `sender` to `project`'s lead (`NodeIds.project`), or holds it until that lead can take it.
    /// `action`: the action id of the user's request that made it (a `.user` message's, EN-D9). `then` hears on `queue`
    /// whether it reached the lead's inbox (false: held, or `project` is no project the engine knows). From any thread.
    public func deliver(_ text: String, from sender: SteerMessage.Sender, project: String, action: String? = nil,
                        then: @escaping (Bool) -> Void = { _ in }) {
        deliver(built: { text }, from: sender, project: project, action: action, then: then)
    }

    /// As above, the text built on `reads` (the witness's, which quote what a session waits for: E7).
    public func deliver(built: @escaping @Sendable () -> String, from sender: SteerMessage.Sender, project: String, action: String? = nil,
                        then: @escaping (Bool) -> Void = { _ in }) {
        queue.async { [self] in
            guard let root = leads.leads[project]?.root else {
                note("lead: a message for \(project), a project this node has no lead for, wasn't sent")
                return then(false)
            }
            deliver(built: built, from: sender, root: root, action: action, then: then)
        }
    }

    /// On `queue`. Behind what's held already for `root`'s lead, what of it is being sent, and a message whose post is
    /// still under way (a lead that became able to take the next one before that post came back would get them out of
    /// order), or sent.
    func deliver(built: @escaping @Sendable () -> String, from sender: SteerMessage.Sender, root: String, action: String?,
                 then: @escaping (Bool) -> Void = { _ in }) {
        let project = NodeIds.project(root: root)
        let (order, id) = (leads.next(), UUID().uuidString)
        if leads.held[project]?.isEmpty == false || sendingHeld.contains(root) || posting.contains(root) {
            reads.async({ _ in built() }) { [weak self] text in
                guard let self else { return }
                self.leads.hold(.init(id: id, text: text, from: sender, order: order, action: action), root: root)
                self.deliverHeld(root: root)
                then(false)
            }
            return
        }
        posting.insert(root)
        post(id: id, built: built, from: sender, root: root) { [weak self] went, text in
            guard let self else { return }
            self.posting.remove(root)
            if !went {
                self.leads.hold(.init(id: id, text: text, from: sender, order: order, action: action), root: root)
                self.note("lead: holding a message for \(LeadMail.project(of: root)) (no lead the vault binds runs there)")
            }
            then(went)
            // What was sent meanwhile waited behind it.
            self.deliverHeld(root: root)
        }
    }

    /// The messages held for `root`'s lead, sent one after another in the order sent while it takes them; each stays
    /// held (and at rest) until it went. On `queue`.
    func deliverHeld(root: String) {
        let project = NodeIds.project(root: root)
        guard !sendingHeld.contains(root), !posting.contains(root), let first = leads.held[project]?.first else { return }
        sendingHeld.insert(root)
        post(id: first.id, built: { first.text }, from: first.from, root: root) { [weak self] went, _ in
            guard let self else { return }
            self.sendingHeld.remove(root)
            guard went else { return }
            self.leads.delivered(project: project, order: first.order)
            self.deliverHeld(root: root)
        }
    }

    /// Where a message for `root`'s lead goes, read on `reads` (EN-D14): the session the vault binds the lead's role to,
    /// on the terminal the session host runs it on (`hosted`, the link's list), with the agent the board names there
    /// while it runs on that terminal (`ProcessTable`: only a process of that session has it as its terminal). The board
    /// is a cross-check: it must name that session on that terminal. Else why not.
    enum Target {
        case lead(LeadAgent)
        /// The board names no lead (one starts, or none ran yet).
        case noLead
        /// The board names `named`, but the vault binds the role to `bound` (none: to no session, or it couldn't be asked).
        case notBound(named: String?, bound: String?)
        /// The board names the session the vault binds on terminal `named`, but the session host runs it on `runs`.
        case otherTerminal(named: String, runs: String)
        /// The lead the vault binds and the board names isn't live in the host's list, or its agent doesn't run on its
        /// terminal.
        case notRunning
    }

    /// The target, on `reads`.
    static func target(root: String, board: LeadBoard, vault: LeadVault, hosted: [HostSession], runs: (LeadAgent) -> Bool) -> Target {
        guard let named = LeadHandover.named(board) else { return .noLead }
        let bound = vault.current(.lead, root: root, task: nil)?.session
        guard let session = named.session, session == bound else { return .notBound(named: named.session, bound: bound) }
        guard let id = UUID(uuidString: session), let host = hosted.first(where: { $0.id == id && $0.isLive }) else { return .notRunning }
        guard host.tty == named.tty else { return .otherTerminal(named: named.tty, runs: host.tty) }
        let lead = LeadAgent(pid: named.pid, tty: host.tty, session: session)
        return runs(lead) ? .lead(lead) : .notRunning
    }

    /// Posts the message, as `id`, into the inbox of `root`'s lead if it has one now (`went`), and wakes it; else sets or
    /// clears the project's notice. One already in that inbox, or taken from it, under `id` went already: a held message
    /// the server posted before it stopped, `engine.json` still holding it, isn't posted again. On `queue`; `then` too,
    /// with the text as built.
    private func post(id: String, built: @escaping @Sendable () -> String, from sender: SteerMessage.Sender, root: String,
                      then: @escaping (_ went: Bool, _ text: String) -> Void) {
        let (vault, runs, inbox, inboxRead, hosted) = (link.vault, leadRuns, self.root, self.inboxRead, link.sessions)
        reads.async({ files -> (target: Target, posted: Bool, text: String) in
            let text = built()
            let target = Self.target(root: root, board: files.names.board(root), vault: vault, hosted: hosted, runs: runs)
            guard case .lead(let lead) = target else { return (target, false, text) }
            inboxRead(lead.tty)
            if SteerInbox.pending(tty: lead.tty, root: inbox).contains(where: { $0.id == id && $0.agentPid == lead.pid })
                || SteerInbox.delivered(tty: lead.tty, root: inbox).contains(id) {
                return (target, true, text)
            }
            // `LeadDelivery.deliver` without a way to type posts just this, under a new id.
            let posted = (try? SteerInbox.post(SteerMessage(id: id, text: text, from: sender, agentPid: lead.pid), tty: lead.tty, root: inbox)) != nil
            return (target, posted, text)
        }) { [weak self] target, posted, text in
            guard let self else { return }
            self.noted(target, root: root)
            if posted, sender == .user, case .lead(let lead) = target { self.postedAsUser(id, tty: lead.tty) }
            if posted { self.wake(root: root) }
            then(posted, text)
        }
    }

    /// The project's notice and the session the vault binds, from what a delivery found. On `queue`.
    private func noted(_ target: Target, root: String) {
        let project = NodeIds.project(root: root)
        var notice: String?
        var bound = leads.leads[project]?.bound
        switch target {
        case .lead(let lead): bound = lead.session
        case .notBound(let named, let binds):
            bound = binds
            notice = "the board of \(LeadMail.project(of: root)) names session \(ConfigSeal.inert(named ?? "none", limit: 40)) as its lead, but the "
                + "vault binds the lead's role to " + (binds.map { "session \($0)" } ?? "no session") + ": what's sent to the lead is held"
        case .otherTerminal(let named, let runs):
            notice = "the board of \(LeadMail.project(of: root)) names the session the vault binds as its lead on terminal "
                + "\(ConfigSeal.inert(named, limit: 40)), but the session host runs that session on \(runs): what's sent to the lead is held"
        case .noLead, .notRunning: break
        }
        guard leads.leads[project]?.notice != notice || leads.leads[project]?.bound != bound else { return }
        if let notice, leads.leads[project]?.notice != notice { note("lead: \(notice)") }
        leads.lead(root: root) {
            $0.notice = notice
            $0.bound = bound
        }
    }

    /// A message from VibeSwitcher itself for the agent of session `id` (`LeadController.tell`): posted into its steer
    /// inbox, which its hook hands over at its next step, and typed in once it's between turns with an empty box
    /// (`flush`). `then` hears on `queue` whether it reached the inbox, and if not, whether trying again later can
    /// (`SessionDelivery`): nothing is kept here, the caller keeps what didn't go. From any thread.
    public func tell(_ text: String, from sender: SteerMessage.Sender, session id: UUID, then: @escaping (SessionDelivery) -> Void = { _ in }) {
        queue.async { [self] in
            // Before the host's welcome, or while it's gone, its list says nothing about who runs.
            let welcomed = link.state == .connected
            guard welcomed, let hosted = link.sessions.first(where: { $0.id == id && $0.isLive }) else {
                let listed = link.sessions.contains { $0.id == id }
                note("lead: a message for session \(id) not delivered: "
                     + (!welcomed ? "the session host hasn't welcomed the engine yet" : listed ? "its session ended" : "the session host doesn't run it"))
                return then(welcomed ? .ended : .notYet)
            }
            let pid = sessions?.sessions.first { $0.hostID == id && $0.tty == hosted.tty }?.pid ?? hosted.childPID
            let agent = LeadAgent(pid: pid, tty: hosted.tty, session: id.uuidString)
            let (inbox, stateFile, inboxRead) = (root, observer.stateFile, self.inboxRead)
            reads.async({ _ -> Bool in
                inboxRead(agent.tty)
                return (try? LeadDelivery.deliver(text, from: sender, to: agent, state: HookState.load(from: stateFile(agent.tty)),
                                                  inputIsEmpty: nil, typeInto: nil, root: inbox)) != nil
            }) { [weak self] went in
                if went { self?.flush(agent) }
                then(went ? .delivered : .notYet)
            }
        }
    }

    // MARK: At rest

    /// What `engine.json` held when the engine started, taken back (EN-D9): a `.user` message stays the user's only when
    /// the vault's record of the user's actions vouches for it; any other goes as VibeSwitcher's, said in the log.
    func restoreHeld() {
        let loaded = EngineState.load(root: root)
        if let problem = loaded.problem { note("engine state: \(problem)") }
        let restored = EngineState.restored(loaded.state.held, actions: options.userActions)
        if restored.notVouched > 0 {
            note("engine state: \(restored.notVouched) held message(s) marked as the user's weren't vouched for by the vault's record of "
                 + "the user's actions: they go as from an unverified sender, not the user's")
        }
        if restored.unvouchedSenders > 0 {
            note("engine state: \(restored.unvouchedSenders) held message(s) marked as the lead's or VibeSwitcher's go as from an unverified "
                 + "sender: nothing vouches for a sender at rest")
        }
        for message in restored.held {
            leads.hold(.init(id: message.id ?? UUID().uuidString, text: message.text, from: message.from, order: message.order, action: message.action),
                       root: message.root)
        }
    }

    /// What's held now, written to `engine.json` on `reads` (in order with every other write there). On `queue`.
    func saveHeld() {
        let held = leads.held.flatMap { project, messages in
            messages.compactMap { message -> EngineState.Held? in
                guard let root = leads.leads[project]?.root else { return nil }
                return EngineState.Held(id: message.id, root: root, order: message.order ?? 0, text: message.text, from: message.from,
                                        action: message.action)
            }
        }.sorted { $0.order < $1.order }
        let (state, root) = (EngineState(held: held), self.root)
        reads.async({ _ in Result { try state.save(root: root) } }) { [weak self] saved in
            if case .failure(let error) = saved { self?.note("engine state: \(EngineState.url(root: root).path) not written: \(error)") }
        }
    }
}
