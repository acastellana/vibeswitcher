import Foundation
import VibeCore

/// Steering a working agent with the user's words mid-turn (`vibeswitcher send SESSION TEXT --now`, 2026-11-20; the
/// app's `MainWindowController.steerSelected` and `ChatSync.steer`, the port map's "Copied from the app"). A Claude
/// agent that works (its hooks' last event says so, `LeadDelivery.way`) gets the message in its steer inbox, as the
/// user's, sealed by the session host: its own hook hands it over at its next step, without stopping it. One between
/// turns (or whose hooks say nothing, or speak of an earlier agent on its terminal) would wait for a step that never
/// comes: `idle`, and the caller types it in instead, as the app does. A steer whose turn ended before its hook took
/// it is typed in, from the node's record of it, once the agent is between turns with an empty box (`watchSteered`:
/// the app's strip shows it stranded and its user sends it now).
extension LeadEngine {
    public enum SteerOutcome: Equatable, Sendable {
        /// In the agent's steer inbox as the user's, under this id.
        case steered(String)
        /// Not working by its hooks: not posted.
        case idle
        /// Not posted, and why.
        case refused(String)
    }

    /// How often a terminal with the user's steered words waiting is looked at (`watchSteered`).
    static let steerWatchEvery: TimeInterval = 2

    /// `text`, as the user's, into the steer inbox of `hosted`'s Claude agent `pid` while its hooks say it works. The
    /// hook state and the inbox are read and written on `reads`; `then` hears on `queue`. On `queue`.
    func steerAsUser(_ text: String, session hosted: HostSession, agentPid pid: Int32, then: @escaping (SteerOutcome) -> Void) {
        let agent = LeadAgent(pid: pid, tty: hosted.tty, session: hosted.id.uuidString, agent: .claude)
        let (inbox, stateFile, inboxRead) = (root, observer.stateFile, self.inboxRead)
        let id = UUID().uuidString
        reads.async({ _ -> SteerOutcome in
            let state = HookState.load(from: stateFile(agent.tty))
            // The last event of another agent on the terminal says nothing of this one.
            guard LeadDelivery.way(for: state) == .steer, state?.agentPid == nil || state?.agentPid == pid else { return .idle }
            inboxRead(agent.tty)
            do {
                try SteerInbox.post(SteerMessage(id: id, text: text, from: .user, agentPid: pid), tty: agent.tty, root: inbox)
            } catch {
                return .refused("its steer inbox didn't take it (\(error)): nothing was sent")
            }
            return .steered(id)
        }) { [weak self] outcome in
            guard let self else { return }
            if case .steered(let id) = outcome {
                // Renewed while it waits, retired in the vault once its hook took it (`retireTaken`).
                self.postedAsUser(id, tty: agent.tty, text: text, agentPid: pid)
                self.note("steer to session \(hosted.id): in its inbox, \(text.count) characters")
                self.watchSteered(id: id, text: text, agent: agent, hostID: hosted.id)
            } else if case .refused(let why) = outcome {
                self.note("steer to session \(hosted.id): not sent: \(why)")
            }
            then(outcome)
        }
    }

    /// While the message this node posted as `id` (from the user's voice, `steerAsUser`) waits in `agent`'s inbox
    /// unchanged (the same id, agent and text: `PostedUser.isPosted`), every `steerWatchEvery`: once the agent is between
    /// turns with an empty box, that message is taken out of the inbox and its words typed in from the node's own record
    /// (`text`), never re-read from the inbox, which any process of the user's can write; no other line of the inbox is
    /// typed from here, whoever it says it's from. Stops once the line is taken (its hook handed it over), gone or
    /// changed, its session ended, or another agent runs on its terminal. On `queue`.
    func watchSteered(id: String, text: String, agent: LeadAgent, hostID: UUID) {
        guard steerWatched[id] == nil else { return }
        steerWatched[id] = Steered(text: text, agent: agent, hostID: hostID)
        lookAtSteered(id)
    }

    private func lookAtSteered(_ id: String) {
        guard let steered = steerWatched[id] else { return }
        let agent = steered.agent
        guard let hosted = link.sessions.first(where: { $0.id == steered.hostID && $0.isLive }) else {
            steerWatched[id] = nil
            return
        }
        let posted = PostedUser(tty: agent.tty, digest: LeadVaultV2.digest(steered.text), agentPid: agent.pid)
        let (inbox, inboxRead, observer) = (root, self.inboxRead, observer)
        reads.async({ _ -> (waits: Bool, betweenTurns: Bool) in
            inboxRead(agent.tty)
            let line = SteerInbox.pending(tty: agent.tty, root: inbox).first { $0.id == id }
            guard let line, posted.isPosted(line), HostedAgents.agentPid(of: hosted) == agent.pid else { return (false, false) }
            return (true, observer.activity(hosted, agentPid: agent.pid).betweenTurns)
        }) { [weak self] seen in
            guard let self else { return }
            guard seen.waits else {
                self.steerWatched[id] = nil
                return
            }
            if seen.betweenTurns { self.typeSteered(id) }
            self.queue.asyncAfter(deadline: .now() + Self.steerWatchEvery) { [weak self] in self?.lookAtSteered(id) }
        }
    }

    /// The steered message `id`, between turns: taken out of the inbox (only while that line is still the one posted)
    /// and its recorded words typed into an empty box as the user's prompt; not taken by the host, posted again under a
    /// new id and watched. On `queue`.
    private func typeSteered(_ id: String) {
        guard let steered = steerWatched[id], !flushing.contains(steered.agent.tty),
              Platform.Clock.steadyDate().timeIntervalSince(typedAt[steered.agent.tty] ?? .distantPast) > 10 else { return }
        let agent = steered.agent
        flushing.insert(agent.tty)
        link.styledScreen(steered.hostID) { [weak self] screen in
            guard let self else { return }
            let box = screen.map(LeadDelivery.box(in:))
            let posted = PostedUser(tty: agent.tty, digest: LeadVaultV2.digest(steered.text), agentPid: agent.pid)
            let (inbox, inboxRead) = (self.root, self.inboxRead)
            self.reads.async({ _ -> Bool in
                guard box == .empty else { return false }
                inboxRead(agent.tty)
                // Typed only while the line is still the one posted; one changed under its id since the last look is
                // dropped (it's no longer the user's message, and its seal no longer holds), and nothing typed.
                guard let line = SteerInbox.withdraw(id: id, tty: agent.tty, root: inbox) else { return false }
                return posted.isPosted(line)
            }) { [weak self] withdrawn in
                guard let self else { return }
                self.flushing.remove(agent.tty)
                guard withdrawn else { return }
                self.steerWatched[id] = nil
                // Out of the inbox by the node's own hand: its seal retired by name (`retireTaken`).
                self.withdrawnUser.insert(id)
                self.typedAt[agent.tty] = Platform.Clock.steadyDate()
                self.note("steer to session \(steered.hostID): its turn ended before a step took it: typed in")
                self.type(steered.text, into: steered.hostID) { [weak self] taken in
                    guard let self, !taken else { return }
                    self.typedAt[agent.tty] = nil
                    let again = SteerMessage(text: steered.text, from: .user, agentPid: agent.pid)
                    self.reads.async({ _ -> Bool in
                        inboxRead(agent.tty)
                        return (try? SteerInbox.post(again, tty: agent.tty, root: inbox)) != nil
                    }) { [weak self] reposted in
                        guard let self else { return }
                        self.note("steer to session \(steered.hostID): what was typed didn't go in" + (reposted ? ": it waits in its inbox again" : ", and couldn't be put back"))
                        guard reposted else { return }
                        self.postedAsUser(again.id, tty: agent.tty, text: steered.text, agentPid: agent.pid)
                        self.watchSteered(id: again.id, text: steered.text, agent: agent, hostID: steered.hostID)
                    }
                }
            }
        }
    }
}

/// A message `steerAsUser` posted and watches (`watchSteered`): its words as the user gave them, its agent and session.
struct Steered: Equatable, Sendable {
    var text: String
    var agent: LeadAgent
    var hostID: UUID
}
