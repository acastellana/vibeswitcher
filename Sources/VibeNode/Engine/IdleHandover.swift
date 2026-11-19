import Foundation
import VibeCore

/// A lead idle for long with a large context, handed over to a fresh lead session (main's `26923f7c`; the app's
/// `LeadController.rotateIfDue` and `launchRotation`, `LeadController.swift` at main's `26923f7c` 2214-2410, the idle
/// half only). At each refresh, for the live lead the board names and the vault binds: once its hooks and transcript say
/// it is between turns with nothing waiting in its inbox, no question to the user open (`LeadRotation.conversationOpen`),
/// and its transcript's tail says it has been idle past `handover_idle_min` with at least `handover_tokens` of context and
/// past its prompt cache's lifetime (`LeadRotation.idle`, `LeadRotation.cold`), the engine writes the handover note
/// itself (`LeadRotation.coldNote`), spawns a fresh lead given the old one's last turns and the note, and only after the
/// spawn moves the board and the vault's role to it (`LeadVault.rotateLead`, which checks the old lead still holds the
/// role), restoring both when either step fails. What waited in the old lead's inbox is held for the new one, the old
/// session stays running as a replaced lead (`LeadStore.replacing`), and progress.md says why.
///
/// **Not here, owed with rotation** (the port map's "what waits" row): asking the old lead for its own note while its
/// cache is still warm (minutes 50 to 55 by default: the app's marker, its one-minute deadline and the reply read back),
/// so on a node the idle handover waits until the cache is cold and always writes the note itself; the scheduled
/// rotations (daily, at 60% context) and Settings' `leadRotation` mode, which the node has no setting for: the idle rule
/// is on wherever the workflow's two keys are (0 turns it off, as on the Mac); the user's typing into the lead (the
/// app's `noteLeadInput` and its input held during the commit): the node has no record of it, so the two-minute quiet
/// counts from the engine's start, and the tries per idle stretch (`LeadRotation.maxIdleAttempts`) count per last
/// response instead of until the user types.
extension LeadEngine {
    /// What a look found that hands the lead over now: its transcript, its tail, why, the old lead's agent and the
    /// rotation gate held.
    struct IdleReading {
        var path: String
        var tail: LeadRotation.Tail
        var reason: String
        var agent: LeadAgent
        var gate: FileLock
    }

    /// Hands `root`'s live lead over when it has idled long with a large context. On `queue`, from the refresh.
    func handOverIfIdle(root: String) {
        let project = NodeIds.project(root: root)
        guard let id = leads.leads[project]?.session, let session = link.sessions.first(where: { $0.id == id && $0.isLive }) else { return }
        let now = handoverNow()
        guard !stopping, starting[root] == nil, !handingOver.contains(root), now >= (handoverRetry[root] ?? .distantPast),
              leads.held[project]?.isEmpty != false, !sendingHeld.contains(root), !posting.contains(root) else { return }
        // The node keeps no record of the user's typing into the lead: its quiet counts from the engine's start.
        let lastInput = handoverStarted
        guard now.timeIntervalSince(lastInput) >= 120 else { return }
        handingOver.insert(root)
        let (observer, inbox, vault, attempts) = (observer, self.root, link.vault, handoverAttempts[session.id])
        reads.async({ _ -> IdleReading? in
            let store = BoardStore(root: root), board = store.load()
            guard board.leadSession == session.id.uuidString,
                  vault.current(.lead, root: root, task: nil)?.session == session.id.uuidString,
                  let agent = LeadHandover.named(board), agent.tty == session.tty,
                  let path = observer.transcript(session, hook: observer.hook(session, agentPid: agent.pid)),
                  let log = try? LeadRotation.reading(path: path),
                  LeadRotation.quiet(activity: observer.reading(session, agentPid: agent.pid).activity,
                                     queued: !SteerInbox.pending(tty: agent.tty, root: inbox).filter { $0.agentPid == agent.pid }.isEmpty,
                                     lastInput: lastInput, now: now),
                  // The user's conversation is never cut mid-exchange: a question just asked waits for its answer.
                  !LeadRotation.conversationOpen(openQuestionsAskedAt: board.openQuestions.map(\.askedAt),
                                                 asking: log.pendingQuestions != nil, now: now),
                  let tail = LeadRotation.tail(path: path)
            else { return nil }
            // At most `maxIdleAttempts` tries in one idle stretch: a new response starts another.
            if let attempts, attempts.since == tail.lastResponse, attempts.count >= LeadRotation.maxIdleAttempts { return nil }
            let workflow = LeadWorkflow.load(from: store.folder + "/workflow.md")
            // Only once the cache is cold: asking the lead for its own note while it is warm is owed with rotation.
            guard let reason = LeadRotation.idle(tail: tail, idleMinutes: workflow.handoverIdleMinutes, tokens: workflow.handoverTokens, now: now),
                  LeadRotation.cold(tail: tail, now: now),
                  let gate = FileLock.attempt(LeadRotation.gate(root)) else { return nil }
            return IdleReading(path: path, tail: tail, reason: reason, agent: agent, gate: gate)
        }) { [weak self] reading in
            guard let self else { reading?.gate.release(); return }
            guard let reading else { self.handingOver.remove(root); self.handoverEvent("checked"); return }
            guard !self.stopping, self.starting[root] == nil, self.leads.held[project]?.isEmpty != false else {
                reading.gate.release(); self.handingOver.remove(root); self.handoverEvent("checked"); return
            }
            let tries = self.handoverAttempts[session.id].flatMap { $0.since == reading.tail.lastResponse ? $0.count : nil } ?? 0
            self.handoverAttempts[session.id] = (reading.tail.lastResponse, tries + 1)
            self.handOver(root: root, old: session, reading: reading,
                          note: LeadRotation.coldNote(reading.tail, now: now),
                          reason: reading.reason + "; its prompt cache had expired, so VibeSwitcher wrote the note")
        }
    }

    /// Spawns the fresh lead, then moves the board and the role to it. On `queue`; `handingOver` holds `root` until done.
    private func handOver(root: String, old: HostSession, reading: IdleReading, note handoverNote: String, reason: String) {
        let project = (root as NSString).lastPathComponent
        let vault = link.vault
        let (preflight, nodeRoot, temporary, home, inbox) = (self.preflight, self.root, temporaryRoot, self.home, self.root)
        let gate = reading.gate
        let giveUp: (String) -> Void = { [weak self] why in
            guard let self else { gate.release(); return }
            self.note("lead: the idle handover of \(LeadMail.project(of: root)) didn't go on: \(why)")
            self.cancelHandover(root)
            gate.release()
            self.handoverEvent("cancelled")
        }
        guard let server = toolServer else { return giveUp("the server has no --node-root, so the lead's tool server isn't known") }
        work.async { [weak self] in
            let prepared = Result<(program: String, launch: LeadLaunch.Prepared), Error> {
                let program: String
                switch preflight.check() {
                case .failure(let refusal): throw Refused(refusal.description)
                case .success(let path): program = path
                }
                let store = BoardStore(root: root)
                let turns = LastTurns.read(transcript: reading.path, tty: old.tty, home: home, hadRole: true)
                    ?? "No user turns were recorded. Continue from the board and the scheduled handover note."
                guard let file = try LeadLaunch.writeTurns(turns, root: root) else { throw Refused("the last turns weren't written") }
                let noteFile = store.folder + "/scheduled-lead-handover.md"
                try VibePaths.writePrivate(Data(handoverNote.utf8), to: URL(fileURLWithPath: noteFile))
                var workflow = LeadWorkflow.load(from: store.folder + "/workflow.md")
                workflow.baseBranch = workflow.baseBranch ?? store.load().baseBranch
                let policy = WorkingPolicy.load(from: nodeRoot.appendingPathComponent("policy.md"))
                let limits = MacLimits.load(from: nodeRoot.appendingPathComponent("mac-limits.json"))
                let name = "lead-\(Slug.make(project, taken: []))"
                let launch = try LeadLaunch.prepare(
                    role: .lead, root: root, task: nil, base: RecentProjects.shellQuote(program),
                    prompt: LeadPrompts.lead(project: project, root: root, workflow: workflow, policy: policy, limits: limits),
                    start: LeadPrompts.leadStart(root: root, goal: nil, note: Self.goalNote, replaced: (old.tty, file), scheduledNote: noteFile),
                    server: server, name: name, folder: vault.runFolder(root: root, name: "scheduled-\(UUID().uuidString)"), cwd: root,
                    temporary: temporary)
                return (program, launch)
            }
            guard let self else { gate.release(); return }
            self.queue.async {
                let program: String, launch: LeadLaunch.Prepared
                switch prepared {
                case .failure(let error): return giveUp("\(error)")
                case .success(let ready): (program, launch) = ready
                }
                guard !self.stopping, self.starting[root] == nil else { return giveUp("a start of the lead came first") }
                let request = SpawnRequest(cwd: root, command: launch.command, env: self.environment(launch, program: program), cols: 120, rows: 40,
                                           keepShell: false, label: "Lead · \(project)", agent: "claude")
                self.spawning(request)
                self.link.spawn(request) { result in
                    guard case .success(let fresh) = result else { return giveUp("the session host didn't start the fresh lead") }
                    self.commitHandover(root: root, old: old, fresh: fresh, agent: reading.agent, reason: reason, gate: gate, inbox: inbox)
                }
            }
        }
    }

    /// The fresh lead runs: the board and the vault's role move to it, only while the old lead still holds both, is
    /// idle, and nothing waits in its inbox; a step that fails puts back what moved. On `queue`.
    private func commitHandover(root: String, old: HostSession, fresh: HostSession, agent: LeadAgent, reason: String, gate: FileLock, inbox: URL) {
        let (vault, observer) = (link.vault, observer)
        reads.async({ _ -> (committed: Bool, waiting: [SteerMessage], endFresh: Bool) in
            let store = BoardStore(root: root)
            let before = store.load()
            let original = vault.current(.lead, root: root, task: nil)
            do {
                guard let original, original.session == old.id.uuidString, LeadHandover.named(before) == agent,
                      observer.reading(old, agentPid: agent.pid).activity == .idle(background: nil),
                      SteerInbox.pending(tty: agent.tty, root: inbox).filter({ $0.agentPid == agent.pid }).isEmpty
                else { throw HandoverChanged() }
                try store.update { board in
                    guard board.leadSession == old.id.uuidString else { throw HandoverChanged() }
                    board.leadSession = fresh.id.uuidString
                    board.leadPid = nil; board.leadTTY = nil
                }
                do { try vault.rotateLead(root: root, expected: old.id.uuidString, session: fresh.id.uuidString) } catch {
                    // A lost reply may follow a transfer that went through: the old session's role goes back too.
                    if vault.current(.lead, root: root, task: nil)?.session == fresh.id.uuidString {
                        try? vault.rotateLead(root: root, expected: fresh.id.uuidString, session: old.id.uuidString, restoring: original)
                    }
                    try store.update { board in
                        board.leadSession = before.leadSession; board.leadPid = before.leadPid; board.leadTTY = before.leadTTY
                    }
                    throw error
                }
                let waiting = LeadHandover.takeWaiting(for: agent, root: inbox)
                try? store.appendProgress("Handed the lead over to a fresh session: \(reason)")
                return (true, waiting, false)
            } catch {
                let restored = vault.current(.lead, root: root, task: nil)?.session == old.id.uuidString
                if !restored {
                    let text = "The idle lead handover could not confirm the old lead \(old.id.uuidString) holds its role again. "
                        + "The fresh session \(fresh.id.uuidString) was kept running because it may hold the role. "
                        + "The board and the vault need reconciling before another handover. Error: \(error)"
                    try? store.update { board in board.reports = (board.reports ?? []) + [LeadReport(about: "idle lead handover", text: text)] }
                }
                return (false, [], restored)
            }
        }) { [weak self] committed, waiting, endFresh in
            guard let self else { gate.release(); return }
            self.cancelHandover(root)
            defer { gate.release() }
            guard committed else {
                if endFresh { self.link.kill(fresh.id) }
                self.note("lead: the idle handover of \(LeadMail.project(of: root)) was cancelled: the lead changed meanwhile"
                    + (endFresh ? "" : "; the fresh session was kept, see the board's reports"))
                self.handoverEvent(endFresh ? "cancelled" : "retained")
                return
            }
            for message in waiting { self.leads.hold(.init(text: message.text, from: message.from), root: root) }
            self.withdrewFromInbox(waiting.map(\.id))
            self.leads.replacing(old.id, root: root)
            self.holders[root] = fresh.id
            let notice = LeadRotation.notice(reason: reason, at: self.handoverNow())
            self.leads.lead(root: root) {
                $0.bound = fresh.id.uuidString
                $0.named = fresh.id.uuidString
                $0.lastStart = notice
                $0.lastStartAt = Date()
            }
            self.leads.update(sessions: self.link.sessions, holders: self.holders)
            self.note("lead: \(LeadMail.project(of: root)): \(notice)")
            if self.options.answersTrust { self.answerTrust(fresh.id, folder: root) }
            self.handoverEvent("handed over")
        }
    }

    /// The handover of `root` is over, done or not: the next look waits 5 minutes. On `queue`.
    private func cancelHandover(_ root: String) {
        handingOver.remove(root)
        handoverRetry[root] = handoverNow().addingTimeInterval(300)
    }

    private struct HandoverChanged: Error, CustomStringConvertible {
        var description: String { "the running lead changed" }
    }
}
