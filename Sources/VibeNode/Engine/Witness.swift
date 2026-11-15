import Foundation
import VibeCore

/// The witness (the engine plan's E7; the app's `LeadController.witness`, `witnessed`, `stopForBudget`,
/// `forgetFinished`, `tellStranded` and `sender(_:)`, `LeadController.swift` 1804-1982 and 2015-2022): it tells the
/// lead what its team can't. At each refresh, for each lead: the sessions whose tools never connected end (asked again
/// a minute on); auto_advance's loop is nudged once per ended verifier and releasable worker; the witness's messages
/// are told once each; a verifier's prompt no one answers is declined (`PromptDecline`, on `HostLink`) and the lead told
/// once; low disk is told once per episode; the working time is counted and a task's time budget stops its worker and
/// tells the lead; the stalls go on the board; what was held for the lead goes; the lead is woken. What the team's
/// transcripts and inboxes say was read on `reads` (`TeamReading`), what to tell worked out there (`WitnessWork`), and
/// only applied on the engine's queue; the files it writes (the nudge, the disk watch's) are written on `reads` too.
extension LeadEngine {
    /// Tells the lead what its team can't, and types waiting messages into idle team members. `team`: what the team's
    /// transcripts and inboxes say, read on `reads` with the sessions as they were then. On `queue`.
    func witness(root: String, board: LeadBoard, team: TeamReading) {
        let hosted = team.hosted
        var seen: [String: LeadWitness.Seen] = [:]
        let now = Date()
        // Before anything is judged: a look just after a sleep sees that sleep.
        macSleep.note(.real)
        let awake = MacTime.real.awake()
        let workers = Set(board.tasks.compactMap(\.worker))
        for id in board.tasks.flatMap(\.members) {
            guard let info = hosted[id] else { continue }
            let session = team.sessions[id]
            // A turn that ended on an API error reads as finished or waiting; its transcript says which it was. One that
            // ended on the usage limit reads as working too: the witness takes it from the activity (`Seen.usageLimit`).
            var apiError: (text: String, at: Double?)?
            var watched: TeamReading.Watched?
            var shells: [BackgroundJob] = []
            var held: SteerMessage?
            if let session, let reading = team.watched[id] {
                watched = reading
                if session.status != .working, case .apiError(let error) = reading.activity { apiError = (error, reading.tail?.at) }
                if workers.contains(id) {
                    // Its shells: mid-turn the command its turn runs, between turns what it waits on, from the store's
                    // last scan (which reads the process table off the engine's queue).
                    shells = session.backgroundJobs
                    held = team.held[id]
                }
            }
            // No agent in the scan a minute on, by a table that could tell, and its agent's own process has exited
            // (`TeamReading.agentGone`): one waiting on a background command runs on.
            let quit = team.agentQuit(id, session: session, scanSaysQuit: sessions?.agentQuit(info) ?? false)
            var look = LeadWitness.Seen(live: info.isLive, exit: info.exit?.status, cause: info.exit?.cause, status: session?.status,
                                        since: session?.statusSince, detail: session?.detail, pending: watched?.tail?.pending,
                                        agentQuit: quit, apiError: apiError?.text,
                                        apiErrorAt: apiError?.at, activity: watched?.activity,
                                        lastActivity: watched?.progress?.lastWritten, compactedAt: watched?.progress?.compactedAt,
                                        shells: shells, heldSince: held?.at, heldFrom: held.map { Self.sender($0.from) },
                                        started: info.startedAt.timeIntervalSince1970, submittedAt: submitted[id],
                                        boundAt: toolTimes[id]?.bound, toolsAt: toolTimes[id]?.tools, lockWait: team.lockWaits[id],
                                        backgroundTasks: watched?.tail?.background ?? [],
                                        shellsRead: workers.contains(id) && session != nil && watched != nil, sleep: macSleep)
            // Called gone only once its job has stayed missing (`MissingJobs`): until then, not known either way.
            look.confirmMissingJob(id, in: &missingJobs, awake: awake)
            seen[id] = look
            if info.isLive, let session { flush(LeadAgent(pid: session.pid, tty: session.tty, session: id)) }
        }
        // What to tell and do is worked out on `reads` (see `WitnessWork`), with what's told and seen so far; the reads
        // queue runs one thing at a time, so each look is applied before the next refresh's.
        let (toldNow, advanceSeenNow, step) = (told, advanceSeen, witnessStep)
        let (advancing, budget, sleep) = (team.advancing, team.workflow.taskBudgetMinutes, macSleep)
        reads.async({ _ in
            WitnessWork(board: board, seen: seen, now: now, advancing: advancing, budgetMinutes: budget,
                        firstSeen: { advanceSeenNow["\(root)|\($0)"] }, told: { toldNow.contains("\(root)|\($0)") }, step: step,
                        recoveryRoot: root, sleep: sleep)
        }) { [weak self] work in
            self?.witnessed(work, root: root, board: board, team: team, now: now)
        }
    }

    /// What the witness worked out of a look (`WitnessWork`), applied on the engine's queue: sessions without tools end,
    /// the auto_advance loop is nudged, the lead is told what it wasn't yet, the board keeps the working time and the
    /// stalls, held messages go, and the lead is woken.
    func witnessed(_ work: WitnessWork, root: String, board: LeadBoard, team: TeamReading, now: Date) {
        let project = LeadMail.project(of: root)
        // What's told and nudged is kept at rest too (E8): a restarted server doesn't tell or nudge it again.
        let (toldBefore, seenBefore) = (told.count, advanceSeen.count)
        defer { if told.count != toldBefore || advanceSeen.count != seenBefore { saveState() } }
        // A worker or verifier whose tools never connected only holds a slot: it ends (`events` tells the lead).
        for id in work.withoutTools {
            guard let uuid = UUID(uuidString: id), endingNoTools[id].map({ now.timeIntervalSince($0) >= 60 }) ?? true else { continue }
            endingNoTools[id] = now
            note("witness: ending session \(id.prefix(8)) in \(project): its tools never connected")
            link.kill(uuid)
        }
        // A verifier that ended without a verdict, which auto_advance audits again: its loop looks now (an agent that
        // quit leaving its shell open writes nothing in the project's folder), and the lead hears of it in its report;
        // past `LeadWitness.advanceGrace` with no retry, from here as ever. The nudge is a file written on `reads`.
        var nudges = 0
        for verifier in work.endedForAdvance {
            let key = "\(root)|\(verifier)"
            if advanceSeen[key] == nil {
                advanceSeen[key] = now
                nudges += 1
            }
        }
        // A worker whose turn ended after its audit started (it had only just reported): its loop looks now and releases
        // it, freeing its slot (its turn's end writes nothing in the project's folder). Once per worker.
        for worker in work.releasableForAdvance {
            let key = "\(root)|release|\(worker)"
            if advanceSeen[key] == nil {
                advanceSeen[key] = now
                nudges += 1
            }
        }
        if nudges > 0 {
            let nudge = nudgeAdvance
            reads.async { _ in for _ in 0..<nudges { nudge(root) } }
        }
        // Only the keys here: each text is built where it's posted, on `reads`. One a look before this told already (two
        // looks under way at once) isn't told again.
        for message in work.messages where !message.keys.allSatisfy({ told.contains("\(root)|\($0)") }) {
            message.keys.forEach { told.insert("\(root)|\($0)") }
            deliver(built: message.text, from: .system("witness"), root: root, action: nil)
        }
        // A verifier waiting on a prompt no one answers: declined with a reason it can act on, and the lead told once
        // what was asked (or that it couldn't be declined), instead of the audit hanging until it's started again.
        for stuck in work.stuckPrompts where told.insert("\(root)|\(stuck.key)").inserted {
            note("witness: declining the prompt verifier \(stuck.session.prefix(8)) on \(ConfigSeal.inert(stuck.slug, limit: 80)) waits on")
            PromptDecline.handle(stuck, link: link) { [weak self] text in self?.deliver(built: text, from: .system("witness"), root: root, action: nil) }
        }
        // Low disk space, once per episode: the watch looks on `reads` (a statfs, its `disk-watch.json`), and what takes
        // the space is sized on `work`; only the message comes back to the engine's queue.
        let workflow = team.workflow
        let (watches, free, sessionsRoot, cwds) = (disks, freeSpace, temporaryRoot, link.sessions.map(\.cwd))
        let file = self.root.appendingPathComponent("disk-watch.json")
        reads.async { [weak self, work = self.work] _ in
            watches.free = free
            var disk = watches.watches[root] ?? LeadWitness.Disk(free: { [watches] in watches.free($0) }, scratch: ClaudeScratch.root,
                                                                 sessions: sessionsRoot, file: file)
            let low = disk.check(root: root, workflow: workflow)
            watches.watches[root] = disk
            guard let low else { return }
            work.async {
                let text = disk.text(free: low, root: root, board: board, workflow: workflow, cwds: cwds)
                guard let engine = self else { return }
                engine.queue.async { engine.deliver(built: { text }, from: .system("witness"), root: root, action: nil) }
            }
        }
        // Working time, and the stop at a task's time budget (see `LeadBudget`): counted on the board as it is when
        // written, so each budget is told once, to its worker and to the lead. The count is written on `reads`, under
        // the board's lock.
        let working = work.working
        let budget = workflow.taskBudgetMinutes, at = now.timeIntervalSince1970, sleep = work.sleep
        if work.notesWork {
            let sessions = team.sessions
            reads.async({ _ in
                (try? BoardStore(root: root).noteWork(working, defaultMinutes: budget, now: at, sleep: sleep)) ?? []
            }) { [weak self] reached in
                for task in reached {
                    let agent = task.worker.flatMap { worker in sessions[worker].map { LeadAgent(pid: $0.pid, tty: $0.tty, session: worker) } }
                    self?.stopForBudget(task, root: root, worker: agent, defaultMinutes: budget)
                }
            }
        }
        // On the board too, for status, until the worker moves again.
        let stalls = work.stalls
        if work.notesStalls { reads.async { _ in try? BoardStore(root: root).update { $0.noteStalls(stalls) } } }
        // A lead runs again: what was held for it goes now; and it's woken for what waits.
        deliverHeld(root: root)
        wake(root: root)
        witnessStep?("applied")
    }

    /// A task's worker reached its time budget: it's told to stop and report over_budget (in its inbox, typed in if
    /// it's between turns), and the lead is told. Nothing is ended. On `queue`.
    func stopForBudget(_ task: LeadTask, root: String, worker: LeadAgent?, defaultMinutes: Int) {
        let minutes = task.overBudget?.minutes ?? LeadBudget.minutes(task, default: defaultMinutes) ?? 0
        note("witness: \(ConfigSeal.inert(task.slug, limit: 80)) in \(LeadMail.project(of: root)) reached its \(minutes) min budget")
        if let worker {
            // Posted on `reads`: a post asks the session host for its seal.
            let (text, inbox, stateFile) = (LeadBudget.stopText(task, minutes: minutes), self.root, observer.stateFile)
            reads.async({ _ in
                _ = try? LeadDelivery.deliver(text, from: .system("time budget"), to: worker, state: HookState.load(from: stateFile(worker.tty)),
                                              inputIsEmpty: nil, typeInto: nil, root: inbox)
            }) { [weak self] in self?.flush(worker) }
        }
        deliver(built: { LeadBudget.leadText(task, minutes: minutes) }, from: .system("witness"), root: root, action: nil)
    }

    /// A task merged or abandoned: its ended workers and verifiers leave the host's list (`LeadTeams.finished`, matched
    /// on `reads`), each asked once. The lead's cleanup does this too; this catches tasks finished some other way. On
    /// `queue`.
    func forgetFinished(_ finished: Set<UUID>) {
        let listed = Set(link.sessions.map(\.id))
        forgetting.formIntersection(listed)
        for id in finished.intersection(listed) where forgetting.insert(id).inserted {
            link.remove(id)
        }
    }

    /// The stranded role sessions, in every project: to each running lead, as the witness. On `queue`.
    func tellStranded(_ text: String) {
        for root in leadRoots.sorted() { deliver(built: { text }, from: .system("witness"), root: root, action: nil) }
    }

    /// Who a waiting message is from, in words (the app's `sender(_:)`, `LeadController.swift` 2015-2022, copied).
    static func sender(_ sender: SteerMessage.Sender) -> String {
        switch sender {
        case .user: return "the user"
        case .lead(let name): return name
        case .system(let about): return "VibeSwitcher (\(about))"
        }
    }
}

/// Each project's disk watch (`LeadWitness.Disk`), by root, with the free-space read it uses: only ever touched on the
/// engine's `reads` queue, where the watch's statfs and its `disk-watch.json` are read and written.
final class DiskWatches: @unchecked Sendable {
    var watches: [String: LeadWitness.Disk] = [:]
    /// The engine's `freeSpace`, as the last look handed it.
    var free: (String) -> Int64? = { _ in nil }
}
