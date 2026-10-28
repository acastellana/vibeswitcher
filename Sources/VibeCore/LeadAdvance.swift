import Foundation

/// VibeSwitcher moves finished work on by itself, without waiting for the lead's next turn (workflow.md's
/// `auto_advance`, on unless set false; a task opts out with its own `auto_advance: false`). Over 2026-10-22..25, 59 %
/// of task time was finished work waiting for the lead, often overnight, and about 1.15 of 5 worker slots were used.
/// Each pass looks at the board and the vault as they are and takes the steps that are due:
/// - a review none task whose worker reported done on its branch's head merges (merge's full test run is its check),
///   unless the risk check (`LeadRisk`) raises it to audit from what its branch changes: then it's audited instead;
/// - an audit task reported done gets its audit, and a passing verdict on its head merges;
/// - a verdict that left Important findings open sends its worker the open ids to answer with answer_findings (once
///   per verdict), or starts a worker to get them when its own has ended; a verdict the round cap says to reconsider
///   (the lead's call: re-plan, or update_task reroll), or one that isn't clean, is left to the lead;
/// - an audit whose verifier ended without a verdict starts again once on the same commit, its leftover session closed;
///   a second that ends so is left to the lead, with how each ended;
/// - a merge whose tests fail (or that conflicts) sends its worker the output, and the task goes back to work;
/// - a merged task is cleaned up;
/// - a planned task whose `after` tasks are all done starts, in board order, within max_workers, the Mac-wide
///   session limit and load threshold, and never on a battery hold.
/// Every step goes through the lead's own tools (`LeadToolset.advanceMerge` and the rest), so the merge gate and every
/// other check is the same as when the lead calls them. Nothing moves a task the lead holds: kept, blocked, failed
/// (but for the findings above), folded, abandoned. What it did reaches the lead as one report per run of passes,
/// and each step goes into the progress log; the judgement calls (holds, re-plans, questions to the user) stay the
/// lead's.
///
/// It lives in the lead's tool server, not the app or the session host: that process holds the lead's grant, which
/// the vault asks of every merge and start (the app's and host's processes aren't the lead's session), it is the one
/// that ran merges and their test runs before (with the Mac-wide test lock), and it runs as long as the lead's
/// session does, idle or not. An install replaces it in place: each pass runs as a call does
/// (`MCPServer.background`), so the switch waits for a pass under way and none starts during one; and since a pass
/// takes no step from memory, only from the board and the vault (a merged task is done, an audit started is the
/// vault's current verifier on that head, findings sent are `LeadTask.autoSentBack`), the new build's first pass
/// takes whatever is still due, once. Passes are one at a time across processes too (`run/advance.lock`).
///
/// No polling: a pass runs at the start and whenever the project's `.vibeswitcher` folder changes (each write of the
/// board is a rename into it; a worker's report, a verdict, a merge, a session ending all write it), and when the app
/// nudges it (`nudge`: the Mac has room again for a step it refused, or AC power came back).
public final class LeadAdvance: @unchecked Sendable {
    /// Who the lead's reports from here are from (`LeadReport.about`): sealed as VibeSwitcher's by the lead's own
    /// session for its own agent only (see `LeadVault.Book.maySeal`), so they arrive as VibeSwitcher's word.
    public static let sender = "auto_advance"

    /// What the lead is told with a report when VibeSwitcher takes the next step itself.
    static let mergesItself = "auto_advance is on: VibeSwitcher merges it by itself (the same merge, with its test run and every check), and you get one report of what happened; don't merge it yourself."
    static let auditsItself = "auto_advance is on: VibeSwitcher starts its audit by itself, and you get one report of what happened; don't audit it yourself."
    static let sendsBackItself = "auto_advance is on: VibeSwitcher sends its worker the open Important findings by itself and audits again once it reports; you get one report. Dismiss a finding, add_task(from_finding: …) or re-plan only if that's your call."

    private static let key = "VibeSwitcher.LeadAdvance"

    /// A step found its task no longer due when it came to take it (held, opted out, switched off, moved on): nothing
    /// is done, and nothing said.
    struct NotDue: Error {}

    /// The step running on this thread is one of these (its Mac refusals are kept as automatic, see `RoomWaits.Wait.auto`).
    static var isAutomatic: Bool { Thread.current.threadDictionary[key] as? Bool == true }

    static func automatically<T>(_ body: () throws -> T) rethrows -> T {
        let outer = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = true
        defer { Thread.current.threadDictionary[key] = outer }
        return try body()
    }

    /// The file whose change makes the lead's tool server look again.
    public static func nudgeFile(root: String) -> String {
        ((root as NSString).appendingPathComponent(".vibeswitcher") as NSString).appendingPathComponent("advance.nudge")
    }

    /// Makes the lead's tool server of `root` look again (the app: the Mac has room again, AC power is back).
    public static func nudge(root: String) {
        let folder = ((root as NSString).appendingPathComponent(".vibeswitcher"))
        guard FileManager.default.fileExists(atPath: folder) else { return }
        try? VibePaths.writePrivate(Data("\(Date().timeIntervalSince1970)\n".utf8), to: URL(fileURLWithPath: nudgeFile(root: root)))
    }

    /// The lead's toolset; held only while a run of passes uses it (`lead`), so a toolset let go ends its loop.
    private weak var owner: LeadToolset?
    private var held: LeadToolset?
    private var lead: LeadToolset { held ?? owner! }
    /// How a run of passes is run: as the MCP server's background work (see the type's comment); in tests, a thread.
    private let run: (@escaping () -> Void) -> Bool
    private let lock = NSCondition()
    private var busy = false
    /// Stopped: no run starts any more.
    private var stopped = false
    private var again = false
    /// The folder watch's way to end (its thread waits on the folder and on this pipe), and the lock it holds while it
    /// runs (see `running`).
    private var stopWrite: Int32 = -1
    private var runningLock: FileLock?
    /// What the next report to the lead says, a line per step.
    private var lines: [String] = []
    /// Refusals and holds told already (a step's, on a commit), each told once.
    private var told: Set<String> = []
    /// Called after each run of passes (tests wait on it).
    var passed: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return ended
        }
        set {
            lock.lock()
            ended = newValue
            lock.unlock()
        }
    }
    private var ended: (() -> Void)?
    /// A step's room wait recorded already (the Mac was full or loaded): not again until it's nudged.
    private var waitingRoom = false
    private var nudgedAt: Date?
    /// What the tool server's git doesn't run here, as last told (`GitGuard.notice`): told again only when it changes.
    private var gitNotice: String?

    init(lead: LeadToolset, run: @escaping (@escaping () -> Void) -> Bool) {
        owner = lead
        self.run = run
    }

    deinit { stop() }

    /// Where a running loop holds its lock: the workers' and verifiers' tool servers tell the lead that VibeSwitcher
    /// takes the next step only while one does.
    static func runningLock(_ store: BoardStore) -> String { (store.folder as NSString).appendingPathComponent("run/advancing.lock") }

    /// A lead's loop runs for this project now (in any process).
    public static func running(_ store: BoardStore) -> Bool {
        guard let lock = FileLock.attempt(runningLock(store)) else { return true }
        lock.release()
        return false
    }

    /// Watches the project's folder from now on, and looks once now. The watch is a thread of its own waiting in
    /// kevent, not a dispatch source: it hears the folder change even while every pooled thread is busy (a merge's
    /// tests, a test run's blocked waits).
    func start() {
        guard let lead = owner else { return }
        try? lead.store.prepare()
        runningLock = FileLock.attempt(Self.runningLock(lead.store))
        let fd = open(lead.store.folder, O_EVTONLY)
        let queue = kqueue()
        var pipes: [Int32] = [-1, -1]
        if fd >= 0, queue >= 0, pipe(&pipes) == 0 {
            for end in pipes { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(queue, F_SETFD, FD_CLOEXEC)
            var changes = [kevent(ident: UInt(fd), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR),
                                  fflags: UInt32(NOTE_WRITE | NOTE_RENAME | NOTE_DELETE), data: 0, udata: nil),
                           kevent(ident: UInt(pipes[0]), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)]
            _ = kevent(queue, &changes, Int32(changes.count), nil, 0, nil)
            stopWrite = pipes[1]
            let stopRead = pipes[0]
            Thread.detachNewThread { [weak self] in
                var event = kevent()
                while true {
                    let count = kevent(queue, nil, 0, &event, 1, nil)
                    if count < 0 && errno == EINTR { continue }
                    if count < 0 || event.filter == Int16(EVFILT_READ) { break }
                    self?.trigger()
                }
                close(queue)
                close(fd)
                close(stopRead)
            }
        } else {
            for descriptor in [fd, queue] + pipes where descriptor >= 0 { close(descriptor) }
        }
        trigger()
    }

    /// Stops watching, and waits for a run under way to end (`wait`): none starts after.
    func stop(wait: Bool = false) {
        lock.lock()
        stopped = true
        while wait && busy { lock.wait() }
        let write = stopWrite
        stopWrite = -1
        let held = runningLock
        runningLock = nil
        lock.unlock()
        held?.release()
        guard write >= 0 else { return }
        _ = Darwin.write(write, [UInt8(1)], 1)
        close(write)
    }

    /// A pass is due: one runs now, or once the one under way is done.
    func trigger() {
        lock.lock()
        if busy {
            again = true
            lock.unlock()
            return
        }
        guard !stopped, let owner else {
            lock.unlock()
            return
        }
        busy = true
        again = false
        held = owner
        lock.unlock()
        guard run({ [self] in passes() }) else {
            lock.lock()
            busy = false
            held = nil
            lock.broadcast()
            lock.unlock()
            return
        }
    }

    /// Passes until one ends with nothing new come in meanwhile, then the report.
    private func passes() {
        while true {
            // A probe of `running` that held the lock for a moment when the loop started (or since) left it untaken.
            lock.lock()
            if runningLock == nil, !stopped { runningLock = FileLock.attempt(Self.runningLock(lead.store)) }
            lock.unlock()
            Self.automatically { (try? lead.advanceExclusively { pass() }) ?? () }
            lock.lock()
            if again && !stopped {
                again = false
                lock.unlock()
                continue
            }
            let report = lines
            lines = []
            lock.unlock()
            if !report.isEmpty { tell(report) }
            lock.lock()
            // Something came in while the report went out: another run.
            let more = again && !stopped
            again = false
            let ended = self.ended
            if !more {
                busy = false
                held = nil
                lock.broadcast()
            }
            lock.unlock()
            ended?()
            if !more { return }
        }
    }

    private func tell(_ report: [String]) {
        let text = "VibeSwitcher moved finished work on by itself (auto_advance):\n" + report.map { "- " + $0 }.joined(separator: "\n")
            + "\nThe judgement calls stay yours: holds (update_task kept or blocked), re-plans, questions to the user, and post_update for a merge the user would notice."
        _ = try? lead.advanceTell(text)
    }

    /// A step done: in the next report, and in the progress log.
    private func did(_ line: String) {
        try? lead.store.appendProgress("Automatically (auto_advance): \(line)")
        lock.lock()
        lines.append(line)
        // What it did may make the next step due (a merge, its cleanup): one more pass before the report.
        again = true
        lock.unlock()
    }

    /// A refusal or hold, told once per `key`.
    private func once(_ key: String, _ line: String) {
        lock.lock()
        let new = told.insert(key).inserted
        lock.unlock()
        if new { did(line) }
    }

    private func forget(_ key: String) {
        lock.lock()
        told.remove(key)
        lock.unlock()
    }

    private func forget(where matches: (String) -> Bool) {
        lock.lock()
        told = told.filter { !matches($0) }
        lock.unlock()
    }

    // MARK: A pass

    /// The workflow's switch as the lead set it: on, and workflow.md says what the vault recorded (a configure under
    /// way finishes first). Read again before each step: one that lands during another's merge counts.
    private func switchedOn() -> Bool {
        guard let (workflow, changed) = try? lead.advanceSettled({ () -> (LeadWorkflow, [(key: String, value: String)]?) in
            let workflow = lead.workflow
            return (workflow, try? lead.vault.changedSettings(workflow, root: lead.root))
        }) else { return false }
        return workflow.autoAdvance && !(changed?.contains { $0.key == "auto_advance" } ?? false)
    }

    /// `task` may still be moved by itself, in one of `states`: the switch is on and the task doesn't opt out.
    private func isDue(_ task: LeadTask, _ states: [LeadTask.Status]) -> Bool {
        states.contains(task.status) && task.autoAdvance != false && switchedOn()
    }

    /// `slug` as the board has it now, when it's still due in one of `states` (see `isDue`); nil when it isn't.
    private func due(_ slug: String, _ states: [LeadTask.Status]) -> LeadTask? {
        lead.store.load().task(slug).flatMap { isDue($0, states) ? $0 : nil }
    }

    /// One look at the board, taking the steps that are due.
    func pass() {
        guard (try? lead.authenticate()) != nil else { return }
        // The file and the vault's record of it as one (a configure under way finishes first).
        guard let (workflow, changed) = try? lead.advanceSettled({ () -> (LeadWorkflow, [(key: String, value: String)]?) in
            let workflow = lead.workflow
            return (workflow, try? lead.vault.changedSettings(workflow, root: lead.root))
        }) else { return }
        guard workflow.autoAdvance else { return }
        // Off as the lead set it, whatever a worker wrote into workflow.md since.
        if let changed, changed.contains(where: { $0.key == "auto_advance" }) {
            once("settings|auto_advance", "Nothing moved by itself: workflow.md's auto_advance isn't what you last set with configure (a worker may have changed it). Set it with configure as it should read.")
            return
        }
        forget("settings|auto_advance")
        // The steps below run git unattended: only the hooks the lead accepted, so a change there is the lead's to know.
        let notice = GitGuard.notice(root: lead.root)
        if notice != gitNotice {
            gitNotice = notice
            if let notice { did(notice) }
        }
        guard let board = try? lead.store.read() else { return }
        let nudged = (try? FileManager.default.attributesOfItem(atPath: Self.nudgeFile(root: lead.root))[.modificationDate]) as? Date
        if nudged != nudgedAt {
            nudgedAt = nudged
            waitingRoom = false
        }
        let power = lead.power()
        let onHold = power.map { $0.onBattery && $0.heldUnder != nil } ?? false
        // Told once a hold (and again under a new limit), forgotten only once a reading says it's over: no reading (the
        // app's is stale after the Mac slept, or the app hung) says nothing about it. 2026-10-27/28: on battery all
        // night, each wake from sleep found the reading stale, forgot the hold, and told it again with nothing new.
        if let power {
            if onHold, let limit = power.heldUnder {
                forget(where: { $0.hasPrefix("battery|") && $0 != "battery|\(limit)" })
                once("battery|\(limit)", "Held: on battery under your \(limit) % limit, so nothing starts, audits or merges by itself until AC power returns.")
            } else {
                forget(where: { $0.hasPrefix("battery|") })
            }
        }
        let limits = lead.macLimits()
        let busy = lead.runtime.steadyLoad().map { $0 > limits.loadLimit } ?? false
        // The quick steps first: findings back to work, merged tasks' sessions ended (room on the Mac); then the starts
        // (a done report freed its worker's slot already); then the audits and merges, which can take as long as the
        // suite. Each in board order.
        let tasks = board.tasks.filter { $0.autoAdvance != false }
        for task in tasks {
            switch task.status {
            // A running one too: the lead's message to its worker (the verdict's report says VibeSwitcher sends the
            // findings) puts it back to work before this pass may come to it, a merge's test run ahead of it.
            case .failed, .running: sendBack(task.slug, onHold: onHold)
            case .done, .reverted: cleanup(task.slug)
            default: break
            }
        }
        guard !onHold else { return }
        starts(workflow)
        for task in tasks where task.status == .review { review(task.slug, busy: busy) }
    }

    /// A task in review: its merge, or its audit, when due.
    private func review(_ slug: String, busy: Bool) {
        guard due(slug, [.review]) != nil, let head = lead.advanceHead(slug) else { return }
        let vault = lead.vault, root = lead.root
        if let verdict = vault.verdict(root: root, task: slug) {
            guard verdict.commit == head else { return }
            let ledger = vault.audits(root: root, task: slug)
            guard ledger?.blocking.isEmpty ?? true, verdict.passes || verdict.dismissed(in: ledger) != nil else { return }
            merge(slug, head: head, busy: busy, audited: true)
            return
        }
        // An audit under way on this commit: its verdict comes, unless its verifier ended without one.
        if vault.current(.verifier, root: root, task: slug)?.auditing == head { return auditAgain(slug, head: head, busy: busy) }
        // The risk check runs here too (`LeadRisk`): a review none task whose change it flags is audited, not merged.
        if let needed = lead.advanceReviewNeeded(slug, commit: head) {
            let finders = lead.workflow.auditFinders
            guard !busy, hasRoom(slug, need: finders) else {
                // Raised: the lead hears why now, though its audit waits for the Mac's room.
                if let raised = lead.store.load().task(slug)?.riskRaised {
                    once("risk|\(slug)|\(raised.commit)", "\(slug) is audited, not merged: \(raised.reason) (the risk check raised it from review none). Its audit starts once the Mac has room.")
                }
                return roomWait("audit(\(slug))", need: finders)
            }
            step("audit|\(slug)|\(head)") {
                guard due(slug, [.review]) != nil else { throw NotDue() }
                _ = try lead.advanceAudit(slug)
                return "Started the audit of \(slug) at \(head.prefix(8)) (\(needed.trimmingCharacters(in: CharacterSet(charactersIn: "."))))."
            }
            return
        }
        // review none: on its worker's done report on this head (one on an older commit waits for its next report).
        guard (try? vault.unaudited(root: root, task: slug))?.reported == head else { return }
        merge(slug, head: head, busy: busy, audited: false)
    }

    /// The audit under way on `head` lost its verifier without a verdict (its session ended, or its agent quit and left
    /// the shell open): it starts again once on the same commit, as any audit start waits for the Mac's room, and
    /// audit closes the old verifier's session first. When the retry's verifier ends so too, nothing starts a third
    /// (a verifier the lead started since is a first ending of its own):
    /// its leftover session is closed and the lead gets one report, with how each ended. A verifier that submitted
    /// nothing records no audit round (the vault counts one per verdict), so this never moves a task toward
    /// reconsider by itself.
    private func auditAgain(_ slug: String, head: String, busy: Bool) {
        guard let task = due(slug, [.review]), task.evidence == nil, let ended = endedVerifier(task) else { return }
        // The retry's own verifier ended too; any other (the lead audited again since, or an older commit's retry) is a
        // first ending.
        if let retry = task.verifierRetry, retry.commit == head, retry.verifiers.contains(ended.session) {
            guard retry.second == nil else { return }
            try? lead.store.update { board in
                guard let index = board.taskIndex(slug) else { return }
                board.tasks[index].verifierRetry?.second = ended.ending
            }
            if ended.live { try? lead.runtime.kill(ended.session) }
            did("The verifier on \(slug) ended without a verdict twice at \(head.prefix(8)), so its audit doesn't start again by itself: "
                + "the first: \(retry.first); the second: \(ended.ending)\(ended.live ? " (its shell is closed now)" : ""). "
                + "read_session(\(slug), who: verifier) to see why, then audit(\(slug)) again or tell the user.")
            return
        }
        let finders = lead.workflow.auditFinders
        guard !busy, hasRoom(slug, need: finders) else { return roomWait("audit(\(slug))", need: finders) }
        step("audit|\(slug)|\(head)|again") {
            guard let task = due(slug, [.review]), task.evidence == nil, endedVerifier(task)?.session == ended.session else { throw NotDue() }
            _ = try lead.advanceAudit(slug)
            try? lead.store.update { board in
                guard let index = board.taskIndex(slug) else { return }
                let started = board.tasks[index]
                board.tasks[index].verifierRetry = LeadVerifierRetry(commit: head, first: ended.ending,
                                                                     verifiers: started.panel?.sessions ?? [started.verifier].compactMap { $0 })
            }
            return "The verifier on \(slug) ended without a verdict (\(ended.ending)): closed its session and started the audit again on the same commit, "
                + "\(head.prefix(8)). If this one ends without a verdict too, it's left to you."
        }
    }

    /// One of the verifiers `task` waits on that ended without its verdict, how (`LeadRuntime.agentEnding`), and whether
    /// its session lives on as a shell; nil while each works (or the host can't be read).
    private func endedVerifier(_ task: LeadTask) -> Ended? {
        guard let sessions = try? lead.advanceSessions() else { return nil }
        // Submitted: the host ends it shortly after, its job done.
        let submitted = Set(((try? lead.vault.roster(root: lead.root)) ?? []).filter { $0.submittedAt != nil }.map(\.session))
        for verifier in task.awaitedVerifiers where !submitted.contains(verifier) {
            guard let info = sessions.first(where: { $0.id == verifier }) else {
                return Ended(session: verifier, ending: "its session is gone (the session host was replaced, or it was removed)", live: false)
            }
            if let ending = lead.runtime.agentEnding(info) { return Ended(session: verifier, ending: ending, live: info.live) }
        }
        return nil
    }

    struct Ended {
        var session: String
        var ending: String
        var live: Bool
    }

    private func merge(_ slug: String, head: String, busy: Bool, audited: Bool) {
        // A loaded Mac: merge would wait in its tests' place; the app nudges once the load drops.
        guard !busy else { return roomWait("merge(\(slug))", need: 0) }
        // A merge under way (the lead's own, or into the same branch): the board's change once it's done looks again.
        guard lead.mergeIdle(slug) else { return }
        // Held or switched off while an earlier step ran (another task's merge takes minutes).
        guard let before = due(slug, [.review]).map({ $0.setback }) else { return }
        do {
            let result = try lead.advanceMerge(slug)
            let task = lead.store.load().task(slug)
            // Merged on a rerun of its failing tests (`MergeRerun`): merge's own note says which, and what it planned.
            let rerun = result.text.range(of: "(Its first test run failed").map { " " + LeadToolset.clip(String(result.text[$0.lowerBound...]).components(separatedBy: ".)").first ?? "", 400) + ".)" } ?? ""
            did("Merged \(slug) (\(task?.title ?? slug)) into \(lead.base) at \(task?.merged?.commit.prefix(8) ?? head.prefix(8)), "
                + (audited ? "on its passing audit and the full test run." : "review none: on its worker's done report on \(head.prefix(8)) and the full test run.") + rerun)
        } catch let problem as LeadToolset.Problem {
            let task = lead.store.load().task(slug)
            // Its tests failed, or it conflicts: the output goes back to its worker, as the lead would send it.
            if let setback = task?.setback, setback != before, setback.stage == .merge, task?.status == .failed {
                let message = "The merge of your branch (\(head.prefix(8))) failed: \(setback.reason)\n\n\(problem.text)\n\n"
                    + "Fix it on your branch, commit, run the affected tests, then report done again."
                let unsent: String?
                do { unsent = try sendToWorker(slug, message, states: [.failed]) } catch let stuck as NotSubmitted { unsent = stuck.text }
                catch { unsent = "\(slug) is held or no longer moves by itself now" }
                did("Merge of \(slug) failed: \(setback.reason) " + (unsent.map { "Its worker couldn't be told (\($0)): message it, or start_worker(\(slug)), with the output: \(LeadToolset.clip(problem.text, 600))" }
                    ?? "Sent its worker the output; it's back at work."))
            } else {
                once("merge|\(slug)|\(head)|\(problem.text.prefix(60))", "Didn't merge \(slug): \(LeadToolset.clip(problem.text, 600))")
            }
        } catch {
            once("merge|\(slug)|\(head)", "Didn't merge \(slug): \(error)")
        }
    }

    /// A verdict that left Important findings open on the branch's head goes back to its worker, once: failed, or
    /// running again on that head with its live worker (2026-10-27, land-pr-1-host: the lead's message to the worker
    /// moved it to running 9 s after the verdict, while a merge's test run held the loop, and the findings never went;
    /// the worker had to ask for them).
    private func sendBack(_ slug: String, onHold: Bool) {
        let vault = lead.vault, root = lead.root
        guard let task = due(slug, [.failed, .running]), task.setback?.stage == .review,
              let head = lead.advanceHead(slug), task.autoSentBack != head,
              let verdict = vault.verdict(root: root, task: slug), verdict.commit == head, verdict.integrity == .clean,
              let ledger = vault.audits(root: root, task: slug), !ledger.reconsider, !ledger.blocking.isEmpty else { return }
        let open = ledger.blocking
        let ids = open.map { "\(slug):\($0.id)" }.joined(separator: ", ")
        let text = "Your branch's audit (at \(head.prefix(8))) left \(open.count) Important finding\(open.count == 1 ? "" : "s") open, which hold its merge back:\n"
            + open.map { "- \($0.id): " + LeadToolset.clip($0.line1, 400) }.joined(separator: "\n")
            + "\nFix \(open.count == 1 ? "it" : "each") on your branch and commit, or disagree with a reason; answer each by id with answer_findings "
            + "(fixed or disagree), run the affected tests, then report done again: it's audited again then (a re-audit checks these findings' concerns and judges your answers)."
        let live = workerRuns(task)
        // Its worker ended (made room for the audit, say): a new one in its worktree gets them, not on a battery hold,
        // and not for a running one (the witness tells the lead its worker ended).
        if !live, onHold || task.status == .running { return }
        let unsent: String?
        do { unsent = try sendToWorker(slug, text, states: [task.status]) } catch let stuck as NotSubmitted {
            // Typed, but its box kept it, cleared and typed again too: not typed a third time at each pass. Said once.
            markSentBack(slug, head)
            once("sendback|\(slug)|\(head)", "Couldn't send \(slug)'s worker its open Important findings (\(ids)): \(stuck.text)")
            return
        } catch { return }
        if let unsent {
            once("sendback|\(slug)|\(head)", "Couldn't send \(slug)'s worker its open Important findings (\(ids)): \(unsent)")
            return
        }
        markSentBack(slug, head)
        did("Sent \(slug)'s worker the open Important findings \(ids) from its audit at \(head.prefix(8))" + (live ? "." : " (in a new worker: its last one had ended)."))
    }

    private func markSentBack(_ slug: String, _ head: String) {
        try? lead.store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].autoSentBack = head
        }
    }

    /// The message was typed into its worker's box, but not submitted (see `LeadDelivery.submitted`): what message says.
    private struct NotSubmitted: Error { let text: String }

    private func workerRuns(_ task: LeadTask?) -> Bool {
        guard let worker = task?.worker else { return false }
        return (try? lead.advanceSessions())?.contains { $0.id == worker && $0.live } ?? false
    }

    /// Sends `text` to the task's worker, starting one in its worktree first when its own has ended (it counts as a
    /// start: max_workers and the Mac's room hold); nil when it went (into its context, or its inbox, where it waits
    /// for its next step or prompt), else why not. Throws `NotDue` when the task was held, opted out or switched off
    /// meanwhile, or left `states` (nothing sent); `NotSubmitted` when it was typed but its box kept it, once more
    /// after clearing it too (before, a box that kept it was said as sent).
    private func sendToWorker(_ slug: String, _ text: String, states: [LeadTask.Status]) throws -> String? {
        do {
            if !workerRuns(lead.store.load().task(slug)) {
                _ = try lead.advanceStart(slug, when: { [self] in isDue($0, states) })
            } else if due(slug, states) == nil {
                throw NotDue()
            }
            var sent = try lead.advanceMessage(slug, text, clearDraft: false)
            if case .notSubmitted = sent.delivered { sent = try lead.advanceMessage(slug, text, clearDraft: true) }
            if case .notSubmitted = sent.delivered { throw NotSubmitted(text: LeadToolset.clip(sent.result.text, 600)) }
            return nil
        } catch let notDue as NotDue {
            throw notDue
        } catch let stuck as NotSubmitted {
            throw stuck
        } catch let problem as LeadToolset.Problem {
            return LeadToolset.clip(problem.text, 400)
        } catch {
            return "\(error)"
        }
    }

    /// The Mac has room for `need` more team sessions on `slug` (its own worktree's not counted, as start_worker and
    /// audit count it).
    private func hasRoom(_ slug: String, need: Int) -> Bool {
        guard let sessions = try? lead.advanceSessions(),
              let mac = try? lead.macLoad(sessions, load: lead.runtime.steadyLoad(), except: Worktrees.path(root: lead.root, slug: slug)) else { return false }
        let limits = lead.macLimits()
        return !mac.isBusy(threshold: limits.loadLimit) && mac.sessions + need <= limits.maxSessions
    }

    /// A merged task (a reverted one too: its work is out of the base, and it stays reverted) whose worktree or
    /// branch is still there.
    private func cleanup(_ slug: String) {
        guard let task = due(slug, [.done, .reverted]), task.merged != nil,
              task.worktree != nil || lead.advanceHead(slug) != nil else { return }
        step("cleanup|\(slug)") {
            guard due(slug, [.done, .reverted]) != nil else { throw NotDue() }
            let result = try lead.advanceCleanup(slug)
            return LeadToolset.clip(result.text, 300)
        }
    }

    /// The planned tasks whose `after` tasks are done, in board order, while there's room.
    private func starts(_ workflow: LeadWorkflow) {
        for task in lead.store.load().tasks where task.status == .planned && task.autoAdvance != false {
            let board = lead.store.load()
            guard let task = board.task(task.slug), isDue(task, [.planned]), let waits = waiting(task, board) else { continue }
            guard waits.isEmpty else { continue }
            let running = board.tasks.filter { $0.status == .running }.count
            guard running < workflow.maxWorkers else { return }
            // The Mac's room as start_worker counts it; a refusal for it waits for the app's nudge.
            guard hasRoom(task.slug, need: 1) else { return roomWait("start_worker(\(task.slug))", need: 1) }
            let after = (task.after ?? []).joined(separator: ", ")
            step("start|\(task.slug)") {
                // Asked again in start_worker's lock: a hold set while the room was counted stands.
                _ = try lead.advanceStart(task.slug, when: { [self] in isDue($0, [.planned]) })
                return "Started a worker on \(task.slug) (\(task.title))" + (after.isEmpty ? "." : ", its after tasks done (\(after)).")
            }
        }
    }

    /// What `task` still waits on: its `after` tasks not done yet (a folded one counts as its carrier); nil when it
    /// never starts by itself (one is abandoned, reverted or gone), told once.
    private func waiting(_ task: LeadTask, _ board: LeadBoard) -> [String]? {
        var left: [String] = []
        // A task finished a day ago is in the board's archive: read only when one is missing from the board.
        lazy var all = lead.store.withArchive(board)
        func find(_ slug: String) -> LeadTask? { board.task(slug) ?? all.task(slug) }
        for slug in task.after ?? [] {
            var other = find(slug)
            if other?.status == .folded, let carrier = other?.foldedInto { other = find(carrier) }
            guard let other, !other.isAbandoned, ![.abandoned, .reverted].contains(other.status) else {
                let why = other?.status == .reverted ? "which was merged and then reverted (its work is out of the base)" : "which is abandoned or gone"
                once("after|\(task.slug)|\(slug)", "\(task.slug) won't start by itself: it comes after \(slug), \(why). update_task(\(task.slug), after: …) or start_worker it.")
                return nil
            }
            if other.status != .done { left.append(slug) }
        }
        return left
    }

    /// The Mac has no room (or too much load) for `what`: the app nudges once it has.
    private func roomWait(_ what: String, need: Int) {
        guard !waitingRoom else { return }
        waitingRoom = true
        lead.roomWaits.record(root: lead.root, what: what, need: need, auto: true)
    }

    /// A step through a lead tool: done, said in the report; refused, said once (on this key).
    private func step(_ key: String, _ body: () throws -> String) {
        do {
            did(try body())
            forget(key)
        } catch is NotDue {
            return
        } catch let problem as LeadToolset.Problem {
            once(key, "Didn't \(key.split(separator: "|").first.map(String.init) ?? "act") \(key.split(separator: "|").dropFirst().first.map(String.init) ?? ""): \(LeadToolset.clip(problem.text, 500))")
        } catch {
            once(key, "Didn't \(key): \(error)")
        }
    }
}

extension LeadToolset {
    /// Starts moving finished work on by itself (the lead's server only; see `LeadAdvance`): each run of passes goes
    /// through `run` (the MCP server's background work, which an install's switch waits for).
    public func startAdvancing(run: @escaping (@escaping () -> Void) -> Bool) {
        guard role == .lead else { return }
        let advance = LeadAdvance(lead: self, run: run)
        advancing = advance
        advance.start()
    }
}
