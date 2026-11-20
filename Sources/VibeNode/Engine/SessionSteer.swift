import Foundation
import VibeCore

/// Steering a working agent with the user's words mid-turn (`vibeswitcher send SESSION TEXT --now`, 2026-11-20; the
/// app's `MainWindowController.steerSelected` and `ChatSync.steer`, the port map's "Copied from the app"). A Claude
/// agent that works (its hooks' last event says so, `LeadDelivery.way`) gets the message in its steer inbox, as the
/// user's, sealed by the session host: its own hook hands it over at its next step, without stopping it. One between
/// turns (or whose hooks say nothing, or speak of an earlier agent on its terminal) would wait for a step that never
/// comes: `idle`, and the caller types it in instead, as the app does. A steer whose turn ended before its hook took
/// it is typed in once the agent is between turns with an empty box (`watchSteered`, the engine's `flush`: the app's
/// strip shows it stranded and its user sends it now).
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
                self.watchSteered(agent, hostID: hosted.id)
            } else if case .refused(let why) = outcome {
                self.note("steer to session \(hosted.id): not sent: \(why)")
            }
            then(outcome)
        }
    }

    /// While the user's steered words wait in `agent`'s inbox, every `steerWatchEvery`: typed in (`flush`) once its turn
    /// is over and its box empty, since no step of that turn will take them. Stops once none waits, its session ended,
    /// or another agent runs on its terminal (the inbox keeps nothing of an earlier agent's). One watch a terminal. On
    /// `queue`.
    func watchSteered(_ agent: LeadAgent, hostID: UUID) {
        guard steerWatched.insert(agent.tty).inserted else { return }
        lookAtSteered(agent, hostID: hostID)
    }

    private func lookAtSteered(_ agent: LeadAgent, hostID: UUID) {
        guard let hosted = link.sessions.first(where: { $0.id == hostID && $0.isLive }) else {
            steerWatched.remove(agent.tty)
            return
        }
        let (inbox, inboxRead) = (root, self.inboxRead)
        reads.async({ _ -> (waits: Bool, runs: Bool) in
            inboxRead(agent.tty)
            let waits = SteerInbox.pending(tty: agent.tty, root: inbox).contains { $0.agentPid == agent.pid && $0.from == .user }
            return (waits, waits && HostedAgents.agentPid(of: hosted) == agent.pid)
        }) { [weak self] seen in
            guard let self else { return }
            guard seen.waits, seen.runs else {
                self.steerWatched.remove(agent.tty)
                return
            }
            self.flush(agent)
            self.queue.asyncAfter(deadline: .now() + Self.steerWatchEvery) { [weak self] in self?.lookAtSteered(agent, hostID: hostID) }
        }
    }
}
