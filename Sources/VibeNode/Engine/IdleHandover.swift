import Foundation
import VibeCore

/// Lead rotation (the app's `LeadController.rotateIfDue` and `launchRotation`, `LeadController.swift` at main's
/// `26923f7c` 2214-2410, and Settings' `leadRotation`): at each refresh, for the live lead the board names and the vault
/// binds, once its hooks and transcript say it is between turns with nothing waiting in its inbox and no question to
/// the user open (`LeadRotation.quiet`, `LeadRotation.conversationOpen`), the lead goes to a fresh session
/// - on schedule, by workflow.md's `lead_rotation:` (the node's stand-in for the Mac's Settings: `daily`, the session over
///   24 hours old; `context`, the default as on the Mac, Claude's status line saying its context is over 60% full,
///   `LeadContextStore`; `never`, no rotation at all, the idle handover included, as on the Mac);
/// - or idle past `handover_idle_min` with at least `handover_tokens` of context (main's `26923f7c`, `LeadRotation.idle`).
/// The old lead is asked for its own handover note first (`LeadRotation.request`, with a marker its reply starts with,
/// delivered from VibeSwitcher), and its reply within one minute is the note; no reply by then cancels, and the next
/// look is 5 minutes on. An idle lead past its prompt cache's lifetime isn't asked (`LeadRotation.cold`: asking would
/// re-send its whole context): the engine writes the note itself (`LeadRotation.coldNote`). Then a fresh lead is spawned
/// with the old one's last turns and the note, and only after the spawn the board and the vault's role move to it
/// (`LeadVault.rotateLead`, which checks the old lead still holds the role), both put back when either step fails. What
/// waited in the old lead's inbox is held for the new one, the old session is marked a replaced lead
/// (`LeadStore.replacing`) and ended with its tool server at a refresh once the fresh lead holds the role
/// (`ReplacedLeads.swift`; on the Mac it ran on), and progress.md says why.
///
/// **Not here, as on the Mac:** the user's typing into the lead (the app's `noteLeadInput`, its input held during the
/// commit, and its count of deliveries that cancels an ask): the node has no record of it, so the two-minute quiet
/// counts from the engine's start, an idle stretch's tries (`LeadRotation.maxIdleAttempts`) count until the lead
/// answers anything but the engine's own ask (where the Mac counts until the user types), and the commit's last check
/// (between turns, nothing in its inbox) is what keeps a turn that began meanwhile.
extension LeadEngine {
    /// What a look found that rotates the lead: its transcript and log, its tail, why, whether the idle rule found it
    /// (and the cache cold), the old lead's agent and the rotation gate held.
    struct IdleReading {
        var path: String
        var log: ChatLog
        var tail: LeadRotation.Tail?
        var reason: String
        var idle: Bool
        var cold: Bool
        var agent: LeadAgent
        var gate: FileLock
    }

    /// The idle stretch a lead's handover tries count in: the lead's last response when the first try came, how many
    /// tries, and until when a response is the reply to the engine's own ask (which doesn't start a new stretch).
    struct IdleTries {
        var since: Date
        var count: Int
        var ownUntil: Date?

        /// Whether a lead whose last response is `last` is still in this stretch.
        func holds(_ last: Date?) -> Bool {
            guard let last else { return true }
            return last == since || (ownUntil.map { last <= $0 } ?? false)
        }
    }

    /// workflow.md's `lead_rotation:` (`daily`, `context`, `never`): the Mac's Settings mode, `context` when empty or
    /// not one of the three (the Mac's default).
    static func rotationMode(_ workflow: LeadWorkflow) -> LeadRotationMode {
        LeadRotationMode(rawValue: (workflow.settings["lead_rotation"] ?? "").lowercased()) ?? .context
    }

    /// Rotates `root`'s live lead when it's due. On `queue`, from the refresh.
    func rotateIfDue(root: String) {
        let project = NodeIds.project(root: root)
        guard let id = leads.leads[project]?.session, let session = link.sessions.first(where: { $0.id == id && $0.isLive }) else {
            if !handingOver.contains(root) { rotationAsked[root] = nil }
            return
        }
        let now = handoverNow()
        if !handingOver.contains(root), let asked = rotationAsked[root] {
            if asked.session != session.id { rotationAsked[root] = nil }
            // The note's minute is up: the running lead stays, and the next look is 5 minutes on.
            else if now.timeIntervalSince(asked.at) > 60 { return cancelAsk(root, now: now) }
        }
        guard !stopping, starting[root] == nil, !handingOver.contains(root), now >= (handoverRetry[root] ?? .distantPast),
              leads.held[project]?.isEmpty != false, !sendingHeld.contains(root), !posting.contains(root) else { return }
        // The node keeps no record of the user's typing into the lead: its quiet counts from the engine's start.
        let lastInput = handoverStarted
        guard now.timeIntervalSince(lastInput) >= 120 else { return }
        handingOver.insert(root)
        let (observer, inbox, vault, tries, asked) = (observer, self.root, link.vault, handoverAttempts[session.id], rotationAsked[root])
        let context = LeadContextStore(root: self.root, home: home)
        reads.async({ _ -> IdleReading? in
            let store = BoardStore(root: root), board = store.load()
            let workflow = LeadWorkflow.load(from: store.folder + "/workflow.md")
            let mode = Self.rotationMode(workflow)
            guard mode != .never,
                  board.leadSession == session.id.uuidString,
                  vault.current(.lead, root: root, task: nil)?.session == session.id.uuidString,
                  let agent = LeadHandover.named(board), agent.tty == session.tty,
                  let path = observer.transcript(session, hook: observer.hook(session, agentPid: agent.pid)),
                  let log = try? LeadRotation.reading(path: path),
                  LeadRotation.quiet(activity: observer.reading(session, agentPid: agent.pid).activity,
                                     queued: !SteerInbox.pending(tty: agent.tty, root: inbox).filter { $0.agentPid == agent.pid }.isEmpty,
                                     lastInput: lastInput, now: now),
                  // The user's conversation is never cut mid-exchange: a question just asked waits for its answer.
                  !LeadRotation.conversationOpen(openQuestionsAskedAt: board.openQuestions.map(\.askedAt),
                                                 asking: log.pendingQuestions != nil, now: now)
            else { return nil }
            let tail = LeadRotation.tail(path: path)
            // Once the note is asked for, the reason stands: the note's own reply ends the idle the rule measured.
            let scheduled = (asked?.session == session.id ? asked?.reason : nil)
                ?? LeadRotation.reason(mode: mode, started: session.startedAt,
                                       percent: context.percent(transcript: path, started: session.startedAt), now: now)
            // At most `maxIdleAttempts` tries in one idle stretch: a response other than the reply to an ask starts another.
            let spent = tries.map { $0.count >= LeadRotation.maxIdleAttempts && $0.holds(tail?.lastResponse) } ?? false
            let idle = scheduled == nil && !spent
                ? LeadRotation.idle(tail: tail, idleMinutes: workflow.handoverIdleMinutes, tokens: workflow.handoverTokens, now: now) : nil
            guard let reason = scheduled ?? idle, let gate = FileLock.attempt(LeadRotation.gate(root)) else { return nil }
            // An idle handover past the cache's lifetime writes its own note: asking would re-send the whole old context.
            // The scheduled rotations ask, as on the Mac.
            return IdleReading(path: path, log: log, tail: tail, reason: reason, idle: idle != nil,
                               cold: idle != nil && LeadRotation.cold(tail: tail, now: now), agent: agent, gate: gate)
        }) { [weak self] reading in
            guard let self else { reading?.gate.release(); return }
            guard let reading else {
                self.handingOver.remove(root)
                if let asked, now.timeIntervalSince(asked.at) >= 60 { return self.cancelAsk(root, now: now) }
                return self.handoverEvent("checked")
            }
            guard !self.stopping, self.starting[root] == nil, self.leads.held[project]?.isEmpty != false,
                  asked == nil || self.rotationAsked[root]?.marker == asked?.marker else {
                reading.gate.release(); self.handingOver.remove(root); self.handoverEvent("checked"); return
            }
            if asked == nil, reading.idle {
                let last = reading.tail?.lastResponse ?? now
                if var kept = self.handoverAttempts[session.id], kept.holds(last) { kept.count += 1; self.handoverAttempts[session.id] = kept }
                else { self.handoverAttempts[session.id] = IdleTries(since: last, count: 1) }
            }
            if asked == nil, reading.cold {
                return self.handOver(root: root, old: session, reading: reading, note: LeadRotation.coldNote(reading.tail, now: now),
                                     reason: reading.reason + "; its prompt cache had expired, so VibeSwitcher wrote the note")
            }
            guard let asked, asked.session == session.id else {
                reading.gate.release()
                self.handingOver.remove(root)
                self.ask(root: root, session: session.id, reason: reading.reason, idle: reading.idle, now: now)
                return
            }
            // A fresh completed reply is the note. An old reply, a timeout, an API error or a tool still running leaves
            // the running lead alone. The one minute is a deadline, never a fixed sleep in tests.
            let note = reading.log.entries.reversed().compactMap { entry -> String? in
                guard let at = entry.at, at >= asked.at, at <= asked.at.addingTimeInterval(60),
                      case .reply(let text) = entry.kind, text.contains(asked.marker) else { return nil }
                return text.replacingOccurrences(of: asked.marker, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }.first
            guard let note, !note.isEmpty else {
                reading.gate.release()
                self.handingOver.remove(root)
                if now.timeIntervalSince(asked.at) >= 60 { return self.cancelAsk(root, now: now) }
                return self.handoverEvent("checked")
            }
            self.rotationAsked[root] = nil
            self.handOver(root: root, old: session, reading: reading, note: note, reason: asked.reason)
        }
    }

    /// Asks `root`'s lead for its handover note (`LeadRotation.request`, with a marker its reply starts with), from
    /// VibeSwitcher; a message that doesn't reach its inbox cancels the ask. On `queue`.
    private func ask(root: String, session: UUID, reason: String, idle: Bool, now: Date) {
        let marker = "VIBESWITCHER_HANDOVER_" + UUID().uuidString
        rotationAsked[root] = (session, now, reason, marker)
        // The reply to this ask doesn't start a new idle stretch.
        if idle { handoverAttempts[session]?.ownUntil = now.addingTimeInterval(120) }
        let message = LeadRotation.request + " Start your reply with this line:\n" + marker + "\nThen write the handover note."
        let done: (Bool) -> Void = { [weak self] sent in
            guard let self, !sent, self.rotationAsked[root]?.marker == marker else { return }
            self.cancelAsk(root, now: self.handoverNow())
        }
        note("lead: \(LeadMail.project(of: root)): asked the lead for its handover note (\(reason))")
        if let rotationRequest { rotationRequest(message, root, done) }
        else { deliver(built: { message }, from: .system("scheduled rotation"), root: root, action: nil, then: done) }
        handoverEvent("asked")
    }

    /// The ask for `root`'s note is over without a note: the lead stays, and the next look is 5 minutes on. On `queue`.
    private func cancelAsk(_ root: String, now: Date) {
        rotationAsked[root] = nil
        handoverRetry[root] = now.addingTimeInterval(300)
        handoverEvent("cancelled")
    }

    /// Spawns the fresh lead, then moves the board and the role to it. On `queue`; `handingOver` holds `root` until done.
    private func handOver(root: String, old: HostSession, reading: IdleReading, note handoverNote: String, reason: String) {
        let project = (root as NSString).lastPathComponent
        let vault = link.vault
        let (preflight, nodeRoot, temporary, home, inbox) = (self.preflight, self.root, temporaryRoot, self.home, self.root)
        let gate = reading.gate
        let giveUp: (String) -> Void = { [weak self] why in
            guard let self else { gate.release(); return }
            self.note("lead: the rotation of \(LeadMail.project(of: root))'s lead didn't go on: \(why)")
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
                let base = RecentProjects.shellQuote(program)
                let run = Self.leadRun(workflow, base: base, nodeRoot: nodeRoot, home: home)
                let launch = try LeadLaunch.prepare(
                    role: .lead, root: root, task: nil, base: base,
                    prompt: LeadPrompts.lead(project: project, root: root, workflow: workflow, policy: policy, limits: limits),
                    start: LeadPrompts.leadStart(root: root, goal: nil, note: Self.goalNote, replaced: (old.tty, file), scheduledNote: noteFile),
                    server: server, name: name, model: run.model, advisor: run.advisor,
                    folder: vault.runFolder(root: root, name: "scheduled-\(UUID().uuidString)"), cwd: root, temporary: temporary)
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
                    let text = "The lead rotation could not confirm the old lead \(old.id.uuidString) holds its role again. "
                        + "The fresh session \(fresh.id.uuidString) was kept running because it may hold the role. "
                        + "The board and the vault need reconciling before another handover. Error: \(error)"
                    try? store.update { board in board.reports = (board.reports ?? []) + [LeadReport(about: "lead rotation", text: text)] }
                }
                return (false, [], restored)
            }
        }) { [weak self] committed, waiting, endFresh in
            guard let self else { gate.release(); return }
            self.cancelHandover(root)
            defer { gate.release() }
            guard committed else {
                if endFresh { self.link.kill(fresh.id) }
                self.note("lead: the rotation of \(LeadMail.project(of: root))'s lead was cancelled: the lead changed meanwhile"
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
