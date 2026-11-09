import Foundation

/// VibeSwitcher moves finished work on by itself, without waiting for the lead's next turn (workflow.md's
/// `auto_advance`, on unless set false; a task opts out with its own `auto_advance: false`). Over 2026-10-22..25, 59 %
/// of task time was finished work waiting for the lead, often overnight, and about 1.15 of 5 worker slots were used.
/// Each pass looks at the board and the vault as they are and takes the steps that are due:
/// - a review none task whose worker reported done on its branch's head merges (merge's full test run is its check),
///   unless the risk check (`LeadRisk`) raises it to audit from what its branch changes, or the audit sample
///   (`LeadAuditSample`, audit_sample_percent of them at random) draws it: then it's audited instead;
/// - an audit task reported done gets its audit, and a passing verdict on its head merges, unless it judged an older
///   version of the task's contract than it has now (`LeadToolset.StaleVerdict`): then it's audited again, on what
///   changed since that version;
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
/// A merge's test run takes 12 to 45 minutes, and every other step goes on meanwhile (2026-11-08: audits, findings and
/// starts sat idle through merges, with the Mac idle too). So a pass doesn't run a merge: it hands it to work of its own
/// (`inBackground`) and goes on, and the merge's end looks again. Merges stay one at a time (this loop has one out at
/// most, and merge's own locks hold across processes), and no step touches a task whose merge is out (`beingMerged`).
///
/// It lives in the lead's tool server, not the app or the session host: that process holds the lead's grant, which
/// the vault asks of every merge and start (the app's and host's processes aren't the lead's session), it is the one
/// that ran merges and their test runs before (with the Mac-wide test lock), and it runs as long as the lead's
/// session does, idle or not. An install replaces it in place: each pass runs as a call does
/// (`MCPServer.background`), a merge in the background too, so the switch waits for those under way and none starts
/// during one; and since a pass
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
    static let reauditsItself = "auto_advance is on: its passing verdict judged an older version of its contract, so VibeSwitcher doesn't merge it; it starts a re-audit of what changed since by itself, and you get one report. merge(…, accept_stale_verdict: …) only if that verdict covers the current contract."
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
    /// `held`'s lock: a merge in the background reads `lead` while a run of passes takes it up or lets it go.
    private let holding = NSLock()
    private var lead: LeadToolset { holding.withLock { held ?? owner! } }
    /// How a run of passes is run: as the MCP server's background work (see the type's comment); in tests, a thread.
    private let run: (@escaping () -> Void) -> Bool
    private let lock = NSCondition()
    private var busy = false
    /// Stopped: no run starts any more.
    private var stopped = false
    private var again = false
    /// The tasks of the merge (or batch) this loop has in the background; empty when it has none. One at a time.
    private var merging: Set<String> = []
    /// While it's out: something new was said, or a task ready to merge waited behind it. Either way its end looks again;
    /// a merge refused again as before, with nothing waiting, doesn't (each look would only refuse it again).
    private var mergeSaid = false
    private var mergeWaited = false
    /// Tasks whose merge ended with another waiting behind it: the next pass lets that one go first, so one that doesn't
    /// land can't keep the turn. `resting` is the pass's own copy, read by passes only.
    private var rest: Set<String> = []
    private var resting: Set<String> = []
    /// The folder watch's way to end (its thread waits on the folder and on this pipe), and the lock it holds while it
    /// runs (see `running`).
    private var stopWrite: Int32 = -1
    private var runningLock: FileLock?
    /// What the next report to the lead says, a line per step.
    private var lines: [String] = []
    /// Refusals and holds told already (a step's, on a commit), each told once.
    private var told: Set<String> = []
    /// The usage holds whose reset has a look again armed (`usageHeld`), each armed once.
    private var wakes: Set<String> = []
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

    // Batched merges (merge_batching, see `LeadToolset.mergeBatch`). Read and written by passes only, one at a time.
    /// The tasks a pass found ready to merge while batching, in board order: merged together at the pass's end.
    private var ready: [Ready] = []
    /// When each task was first seen ready, on its head ("slug|head").
    private var readySince: [String: Date] = [:]
    /// Tasks (on their head) a batch stopped short of, or couldn't start with: merged one at a time from then on.
    /// Unlike the rest it's written by a batch in the background: under `lock`.
    private var unbatched: Set<String> = []
    /// The look again armed for the window's end, at this time.
    private var batchWake: Date?

    struct Ready {
        let slug: String
        let head: String
        let audited: Bool
        var key: String { "\(slug)|\(head)" }
    }

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
        while wait && (busy || !merging.isEmpty) { lock.wait() }
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
        holding.withLock { held = owner }
        lock.unlock()
        guard run({ [self] in passes() }) else {
            lock.lock()
            busy = false
            holding.withLock { held = nil }
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
                holding.withLock { held = nil }
                lock.broadcast()
            }
            lock.unlock()
            ended?()
            if !more { return }
        }
    }

    /// Only successful housekeeping is FYI. Unknown outcomes and refusals still need judgement.
    static func wakes(_ text: String) -> Bool {
        if text.localizedCaseInsensitiveContains("decide") { return true }
        let outcomes = text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
        guard !outcomes.isEmpty else { return true }
        return outcomes.contains { line in
            return !["Started a worker on ", "Started the audit of ", "Released ", "Cleaned up ", "Resumed after sleep: "].contains { line.hasPrefix($0) }
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
        mergeSaid = true
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
        lock.lock()
        resting = rest
        rest = []
        lock.unlock()
        guard let rotationGate = FileLock.attempt(LeadRotation.gate(lead.root), shared: true) else { return }
        defer { rotationGate.release() }
        guard (try? lead.authenticate()) != nil else { return }
        // The file and the vault's record of it as one (a configure under way finishes first).
        guard let (workflow, changed) = try? lead.advanceSettled({ () -> (LeadWorkflow, [(key: String, value: String)]?) in
            let workflow = lead.workflow
            return (workflow, try? lead.vault.changedSettings(workflow, root: lead.root))
        }) else { return }
        resumeAfterSleep()
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
        // (a done report freed its worker's slot already); then the audits and merges. Each in board order.
        let tasks = board.tasks.filter { $0.autoAdvance != false }
        for task in tasks {
            switch task.status {
            // A running one too: the lead's message to its worker (the verdict's report says VibeSwitcher sends the
            // findings) puts it back to work before this pass may come to it, a merge's test run ahead of it.
            case .failed, .running: sendBack(task.slug, onHold: onHold)
            case .done, .reverted: cleanup(task.slug)
            // Its audit under way: its worker, idle since its done report, frees its Mac slot (before the starts).
            case .review: release(task.slug)
            default: break
            }
        }
        guard !onHold else { return }
        starts(workflow)
        let batching = lead.batching(workflow)
        ready = []
        for task in tasks where task.status == .review { review(task.slug, busy: busy, batching: batching) }
        if batching { mergeReady(busy: busy) } else { readySince = [:] }
    }

    /// A gate or session-host refusal leaves all pending interruptions visible and keeps one room-again retry.
    private func deferSleepRecovery(_ recovery: LeadSleepRecovery.Store) {
        for remaining in (try? recovery.pending()) ?? [] { try? recovery.release(remaining) }
        // Retry even with auto_advance off, without needing another interruption or power change.
        let what = LeadSleepRecovery.retryWait
        if !lead.roomWaits.waits().contains(where: { $0.wait.root == lead.root && $0.wait.auto == true && $0.wait.what == what }) {
            lead.roomWaits.record(root: lead.root, what: what, need: 0, auto: true)
        }
    }

    /// Recovery is independent of auto_advance's task planning switch. Gate refusals leave the interruption visible
    /// to the lead and register a room-again nudge; no stale or missing power/load reading grants permission to resume.
    private func resumeAfterSleep() {
        let recovery = LeadSleepRecovery.Store(root: lead.root)
        guard let pending = try? recovery.pending(), !pending.isEmpty else { return }
        for event in pending {
            guard let power = lead.power(), !(power.onBattery && power.heldUnder != nil),
                  let load = lead.runtime.steadyLoad(), load <= lead.macLimits().loadLimit else {
                deferSleepRecovery(recovery)
                return
            }
            // The timestamp must still describe the last turn. A lead/user may have resumed it while held.
            guard let sessions = try? lead.advanceSessions() else {
                deferSleepRecovery(recovery)
                return
            }
            let task = lead.store.load().task(event.slug)
            let current = event.verifier
                ? task?.status == .review && task?.evidence == nil && task?.awaitedVerifiers.contains(event.session) == true
                : [.running, .failed].contains(task?.status ?? .done) && task?.worker == event.session && task?.stopped != event.session
            let info = sessions.first { $0.id == event.session }
            let path = try? lead.runtime.transcript(of: event.session)
            let tail = path.flatMap { TranscriptTail.read(url: URL(fileURLWithPath: $0)) }
            let sleepError: Bool
            if case .turnOver(let error)? = tail?.state { sleepError = LeadSleepRecovery.isSleepError(error) } else { sleepError = false }
            let stillInterrupted = sleepError && tail?.at == event.at && tail?.usageLimit == nil
            let actionable = current && info.map { $0.live && $0.usageLimit == nil && lead.runtime.agentEnding($0) == nil } == true && stillInterrupted
            guard let allowed = try? recovery.claim(event, now: Date().timeIntervalSince1970, attempting: actionable) else { continue }
            guard actionable else {
                try? recovery.release(event)
                once("sleep|\(event.key)", "Not resumed after sleep: the \(event.verifier ? "verifier" : "worker") on \(event.slug) could not be confirmed as still interrupted on its last turn. Check its session and resume it yourself if needed.")
                continue
            }
            guard allowed else {
                try? recovery.release(event)
                once("sleep|\(event.key)", "The \(event.verifier ? "verifier" : "worker") on \(event.slug) stopped on the sleep API error a third time in an hour; it needs you to resume it (two automatic resumes already).")
                continue
            }
            step("sleep|\(event.key)") {
                do {
                    if event.verifier {
                        guard let entry = try lead.vault.roster(root: lead.root).first(where: { $0.session == event.session }),
                              entry.holds, entry.submittedAt == nil, let head = lead.vault.current(.verifier, root: lead.root, task: event.slug)?.auditing else {
                            throw LeadToolset.Problem(text: "Not resumed after sleep: the interrupted audit of \(event.slug) no longer holds its verifier grant. Check its audit before restarting it.")
                        }
                        guard lead.advanceHead(event.slug) == head else {
                            throw LeadToolset.Problem(text: "The branch moved since the interrupted audit; audit \(event.slug) yourself on its new commit.")
                        }
                        _ = try lead.advanceAudit(event.slug, restarting: head)
                        return "Resumed after sleep: restarted the audit of \(event.slug) on the same commit, \(head.prefix(8))."
                    }
                    let sent = try lead.advanceMessage(event.slug, LeadSleepRecovery.message, clearDraft: false)
                    if case .notSubmitted = sent.delivered { throw LeadToolset.Problem(text: "Sleep resume was not submitted: " + sent.result.text) }
                    return "Resumed after sleep: sent \(event.slug)'s worker one go-on message."
                } catch {
                    try? recovery.release(event)
                    throw error
                }
            }
        }
    }

    /// A task in review: its merge, or its audit, when due.
    private func review(_ slug: String, busy: Bool, batching: Bool) {
        // Its merge is out: not audited, sampled or merged again on the way. Its end looks again.
        guard !beingMerged(slug), due(slug, [.review]) != nil, let head = lead.advanceHead(slug) else { return }
        let vault = lead.vault, root = lead.root
        if let verdict = vault.verdict(root: root, task: slug) {
            guard verdict.commit == head else { return }
            let ledger = vault.audits(root: root, task: slug)
            // Nothing Important open, nor an unconfirmed one held by strict_paths (`LeadToolset.hold`).
            guard lead.hold(slug, ledger, head: head).isEmpty, verdict.passes || verdict.dismissed(in: ledger) != nil else { return }
            // Judged an older version of the contract than it has now: not merged, audited again on what changed.
            if let task = lead.store.load().task(slug), let stale = LeadToolset.staleVerdict(task) {
                return audit(slug, head: head, busy: busy, why: "not merged: its passing audit \(stale.text), so this re-audit judges "
                             + (stale.changes == nil ? "the whole of v\(stale.current) (v\(stale.judged)'s text isn't on record)" : "only what changed since v\(stale.judged)"),
                             key: "audit|\(slug)|\(head)|v\(stale.current)")
            }
            toMerge(Ready(slug: slug, head: head, audited: true), busy: busy, batching: batching)
            return
        }
        // An audit under way on this commit: its verdict comes, unless its verifier ended without one.
        if vault.current(.verifier, root: root, task: slug)?.auditing == head { return auditAgain(slug, head: head, busy: busy) }
        // The risk check runs here too (`LeadRisk`): a review none task whose change it flags is audited, not merged.
        if let needed = lead.advanceReviewNeeded(slug, commit: head) {
            // One the sample drew is audit from then on: its audit says why, however long it waits for room.
            let sampled = lead.store.load().task(slug)?.auditSample.flatMap { $0.sampled ? $0 : nil }
            return audit(slug, head: head, busy: busy, why: sampled.map { "Sampled for audit: \($0.text)." } ?? needed)
        }
        // review none: on its worker's done report on this head (one on an older commit waits for its next report).
        guard (try? vault.unaudited(root: root, task: slug))?.reported == head else { return }
        // A random share of them is audited anyway (audit_sample_percent, see `LeadAuditSample`): drawn once per task.
        if let sample = sample(slug, head: head), sample.sampled {
            return audit(slug, head: head, busy: busy, why: "Sampled for audit: \(sample.text).")
        }
        toMerge(Ready(slug: slug, head: head, audited: false), busy: busy, batching: batching)
    }

    /// Starts `slug`'s audit at `head` (`why`: what sends it there) once the Mac has room for its finders.
    private func audit(_ slug: String, head: String, busy: Bool, why needed: String, key: String? = nil) {
        let finders = lead.workflow.findersInForce
        guard !busy, hasRoom(slug, need: finders) else {
            // Raised: the lead hears why now, though its audit waits for the Mac's room.
            if let raised = lead.store.load().task(slug)?.riskRaised {
                once("risk|\(slug)|\(raised.commit)", "\(slug) is audited, not merged: \(raised.reason) (the risk check raised it from review none). Its audit starts once the Mac has room.")
            }
            return roomWait("audit(\(slug))", need: finders)
        }
        if usageHeld(model: lead.auditModel(lead.workflow, task: lead.store.load().task(slug))) { return }
        step(key ?? "audit|\(slug)|\(head)") {
            guard let before = due(slug, [.review]) else { throw NotDue() }
            _ = try lead.advanceAudit(slug)
            return "Started the audit of \(slug) at \(head.prefix(8)) (\(needed.trimmingCharacters(in: CharacterSet(charactersIn: "."))))." + releasedText(slug, worker: before.worker)
        }
    }

    /// `slug`'s audit sample: the one drawn at its first done report on review none's path, or, when none was and
    /// audit_sample_percent isn't 0, one drawn now from `lead.auditSampleSeed` and recorded on the task with its seed.
    /// A sampled task's review becomes audit (the vault's too, so no merge takes it unaudited) and the lead's progress
    /// log says so. nil: sampling is off and nothing was drawn, or the task isn't due.
    private func sample(_ slug: String, head: String) -> LeadAuditSample? {
        guard let task = due(slug, [.review]) else { return nil }
        if let drawn = task.auditSample { return drawn }
        let percent = lead.workflow.samplePercentInForce
        guard percent > 0 else { return nil }
        let drawn = LeadAuditSample(seed: lead.auditSampleSeed(), percent: percent, commit: head)
        var kept: LeadAuditSample?
        try? lead.store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            if let earlier = board.tasks[index].auditSample { kept = earlier; return }
            board.tasks[index].auditSample = drawn
            if drawn.sampled { board.tasks[index].review = .audit }
            kept = drawn
        }
        guard let kept else { return nil }
        if kept == drawn, drawn.sampled {
            try? lead.vault.setReview(.audit, root: lead.root, task: slug)
            try? lead.store.appendProgress("Sampled \(slug) for audit from review none (at \(head.prefix(8))): \(drawn.text)")
        }
        return kept
    }

    /// A task ready to merge: merged now, or, while batching, kept for the pass's batch (`mergeReady`); one a batch fell
    /// back from merges on its own.
    private func toMerge(_ task: Ready, busy: Bool, batching: Bool) {
        if batching, !isUnbatched(task.key) { ready.append(task) } else { merge(task.slug, head: task.head, busy: busy, audited: task.audited) }
    }

    /// The tasks this pass found ready to merge while batching: once `LeadToolset.batchSize` are ready, or the first of
    /// them has waited `LeadToolset.batchWindow`, they merge as one batch (`LeadToolset.mergeBatch`; a lone one, as merge merges it). Until
    /// then a look again is armed for the window's end: nothing else may change in the folder meanwhile.
    private func mergeReady(busy: Bool) {
        // One of this loop's merges is out: what's ready keeps its place, and its end looks again.
        guard !mergeOut(waiting: !ready.isEmpty) else { return }
        let everyReady = ready
        ready = []
        let keys = Set(everyReady.map(\.key))
        readySince = readySince.filter { keys.contains($0.key) }
        // Only the ones merge would take now count and go in a batch: one its own checks refuse (waiting on the user's
        // approval, say) is said once and left out, so it never holds back a batch of the ones behind it.
        let found = everyReady.filter { task in
            guard !resting.contains(task.slug) else { return false }
            guard let refusal = lead.advanceGate(task.slug) else { return true }
            once("merge|\(task.slug)|\(task.head)|\(refusal.prefix(60))", "Didn't merge \(task.slug): \(LeadToolset.clip(refusal, 600))")
            return false
        }
        guard !found.isEmpty else { return }
        let (window, size) = (lead.batchWindow, lead.batchSize)
        let now = lead.batchClock()
        for task in found where readySince[task.key] == nil { readySince[task.key] = now }
        let oldest = found.compactMap { readySince[$0.key] }.min() ?? now
        guard found.count >= size || now.timeIntervalSince(oldest) >= window else {
            let end = oldest.addingTimeInterval(window)
            if batchWake != end {
                batchWake = end
                let root = lead.root
                lead.usageWake(end.addingTimeInterval(1)) { LeadAdvance.nudge(root: root) }
            }
            return
        }
        let batch = Array(found.prefix(max(1, min(size, LeadToolset.batchLimit))))
        guard batch.count > 1 else { return merge(batch[0].slug, head: batch[0].head, busy: busy, audited: batch[0].audited) }
        // A loaded Mac: the batch would wait in its tests' place; the app nudges once the load drops.
        guard !busy else { return roomWait("merge(\(batch.map(\.slug).joined(separator: ", ")))", need: 0) }
        mergeBatch(batch)
    }

    /// `batch` merged as one (`LeadToolset.mergeBatch`): the merged ones said in one line, each failure's output sent to its
    /// worker as a merge's failure is, refusals said once, and what the batch stopped short of merged one at a time.
    private func mergeBatch(_ given: [Ready]) {
        // Each still due and with no merge of it under way (another task's merge takes minutes).
        let batch = given.filter { due($0.slug, [.review]) != nil && lead.mergeIdle($0.slug) }
        guard batch.count > 1 else {
            for task in batch { merge(task.slug, head: task.head, busy: false, audited: task.audited) }
            return
        }
        let before = Dictionary(uniqueKeysWithValues: batch.map { ($0.slug, lead.store.load().task($0.slug)?.setback) })
        inBackground(batch.map(\.slug)) { [self] locked in
            let names = batch.map(\.slug).joined(separator: ", ")
            let result: LeadToolset.BatchResult
            do {
                result = try lead.advanceMergeBatch(batch.map(\.slug), locked: locked)
            } catch {
                // It couldn't start: one at a time from here, each with merge's own checks and refusals.
                for task in batch { markUnbatched(task.key) }
                let text = (error as? LeadToolset.Problem)?.text ?? "\(error)"
                did("Didn't merge \(names) as a batch: \(LeadToolset.clip(text, 400)) They merge one at a time from here.")
                return
            }
            var merged: [String] = []
            for task in batch {
                switch result.end(task.slug) {
                case .merged(let commit)?:
                    merged.append("\(task.slug) at \(commit.prefix(8)) (" + (task.audited ? "its passing audit" : "review none: its worker's done report on \(task.head.prefix(8))") + ")")
                    forget(where: { $0.hasPrefix("merge|\(task.slug)|") })
                case .failed(let text)?, .conflict(let text)?:
                    failed(task.slug, head: task.head, before: before[task.slug] ?? nil, problem: text)
                case .refused(let text)?:
                    once("merge|\(task.slug)|\(task.head)|\(text.prefix(60))", "Didn't merge \(task.slug): \(LeadToolset.clip(text, 600))")
                case .untouched?, nil:
                    markUnbatched(task.key)
                }
            }
            if !merged.isEmpty {
                did("Merged \(merged.joined(separator: ", ")) into \(lead.base) as one batch, on \(result.runs) test run\(result.runs == 1 ? "" : "s") for \(batch.count) tasks.")
            }
            if let stopped = result.stopped {
                let left = batch.filter { isUnbatched($0.key) }.map(\.slug)
                did("The batch of \(names) stopped short: \(LeadToolset.clip(stopped, 400))." + (left.isEmpty ? "" : " \(left.joined(separator: ", ")) stay as they were and merge one at a time from here."))
            }
        }
    }

    /// " Its worker … was released …" when the audit just started released `worker` (see `LeadToolset.releaseWorker`).
    private func releasedText(_ slug: String, worker: String?) -> String {
        guard let worker, lead.store.load().task(slug)?.released == worker else { return "" }
        return " Released its worker, idle since its done report, while the audit runs: its Mac slot and memory are free, its worktree and branch stay."
    }

    /// A task in review whose audit is under way: its worker, idle since its done report, is released
    /// (`LeadToolset.releaseWorker`): by the audit's start when it was idle then, else here once its turn ends (the
    /// app nudges the loop, `LeadWitness.releasableForAdvance`). A host that won't end it is told once.
    private func release(_ slug: String) {
        guard !beingMerged(slug), let task = due(slug, [.review]), let release = lead.releaseWorker(slug) else { return }
        if release.released { did(release.text) } else { once("release|\(slug)|\(task.worker ?? "")", release.text) }
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
                // Its audit ended here, without a verdict (`LeadWaits`).
                board.tasks[index].noteWaits { $0.auditEnded(at: Date().timeIntervalSince1970) }
            }
            if ended.live { try? lead.runtime.kill(ended.session) }
            did("The verifier on \(slug) ended without a verdict twice at \(head.prefix(8)), so its audit doesn't start again by itself: "
                + "the first: \(retry.first); the second: \(ended.ending)\(ended.live ? " (its shell is closed now)" : ""). "
                + "read_session(\(slug), who: verifier) to see why, then audit(\(slug)) again or tell the user.")
            return
        }
        let finders = lead.workflow.findersInForce
        guard !busy, hasRoom(slug, need: finders) else { return roomWait("audit(\(slug))", need: finders) }
        if usageHeld(model: lead.auditModel(lead.workflow, task: lead.store.load().task(slug))) { return }
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
        // A merge under way (this loop's, the lead's own, or into the same branch): its end, or the board's change once
        // it's done, looks again. Before the load: a merge's own tests are what loads the Mac.
        guard !resting.contains(slug), !mergeOut(waiting: true), lead.mergeIdle(slug) else { return }
        // A loaded Mac: merge would wait in its tests' place; the app nudges once the load drops.
        guard !busy else { return roomWait("merge(\(slug))", need: 0) }
        // Held or switched off while an earlier step ran.
        guard let before = due(slug, [.review]).map({ $0.setback }) else { return }
        inBackground([slug]) { [self] locked in
            do {
                let result = try lead.advanceMerge(slug, locked: locked)
                let task = lead.store.load().task(slug)
                // Merged on a rerun of its failing tests (`MergeRerun`): merge's own note says which, and what it planned.
                let rerun = result.text.range(of: "(Its first test run failed").map { " " + LeadToolset.clip(String(result.text[$0.lowerBound...]).components(separatedBy: ".)").first ?? "", 400) + ".)" } ?? ""
                did("Merged \(slug) (\(task?.title ?? slug)) into \(lead.base) at \(task?.merged?.commit.prefix(8) ?? head.prefix(8)), "
                    + (audited ? "on its passing audit and the full test run." : "review none: on its worker's done report on \(head.prefix(8)) and the full test run.") + rerun)
            } catch let problem as LeadToolset.Problem {
                let task = lead.store.load().task(slug)
                // Its tests failed, or it conflicts: the output goes back to its worker, as the lead would send it.
                if let setback = task?.setback, setback != before, setback.stage == .merge, task?.status == .failed {
                    failed(slug, head: head, before: before, problem: problem.text)
                } else {
                    once("merge|\(slug)|\(head)|\(problem.text.prefix(60))", "Didn't merge \(slug): \(LeadToolset.clip(problem.text, 600))")
                }
            } catch {
                once("merge|\(slug)|\(head)", "Didn't merge \(slug): \(error)")
            }
        }
    }

    /// One of this loop's merges is out; `waiting`: a task ready to merge is behind it.
    private func mergeOut(waiting: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if waiting, !merging.isEmpty { mergeWaited = true }
        return !merging.isEmpty
    }

    /// A merge of `slug` is under way: this loop's, from its handing over to its report, or anyone's by merge's own lock.
    private func beingMerged(_ slug: String) -> Bool {
        lock.lock()
        let here = merging.contains(slug)
        lock.unlock()
        return here || lead.mergeUnderWay(slug)
    }

    private func isUnbatched(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return unbatched.contains(key)
    }

    private func markUnbatched(_ key: String) {
        lock.lock()
        unbatched.insert(key)
        lock.unlock()
    }

    /// Runs `body`, a merge of `slugs` and what's said of it, as work of its own, so the pass goes on: through `run` as a
    /// pass is (an install's switch waits for it, the server's stop cancels its test run), holding the rotation gate as
    /// the lead's merge call does, and as automatic as the pass's steps. Returns once the merge is past its refusals and
    /// about to wait for its tests, holding its locks (the `locked` it's given), or has ended: a refused one is over
    /// before the pass goes on to the next task, as when it ran in the pass. The pass still holds `run/advance.lock`
    /// until then, so a pass after it, in any process, finds the merge by those locks. Not started when a merge of this loop's is out, or the server is ending; the
    /// next pass takes what's still due.
    private func inBackground(_ slugs: [String], _ body: @escaping (_ locked: @escaping () -> Void) -> Void) {
        guard let gate = FileLock.attempt(LeadRotation.gate(lead.root), shared: true) else { return }
        lock.lock()
        guard merging.isEmpty, !stopped else {
            lock.unlock()
            gate.release()
            return
        }
        merging = Set(slugs)
        mergeSaid = false
        mergeWaited = false
        lock.unlock()
        // Held until the merge's end, though the run of passes that started it lets the toolset go.
        let keep = lead
        let holds = DispatchSemaphore(value: 0)
        let started = run { [self] in
            withExtendedLifetime(keep) {
                Self.automatically { body { holds.signal() } }
                gate.release()
                mergeEnded()
                holds.signal()
            }
        }
        if started { holds.wait() } else {
            gate.release()
            lock.lock()
            merging = []
            lock.broadcast()
            lock.unlock()
        }
    }

    /// The merge in the background ended, its result said: when that's something new, or a task waited behind it, the
    /// next pass reports it and takes what's due after it. No more passes come once the loop is stopped, so then what it
    /// said goes out from here.
    private func mergeEnded() {
        while true {
            lock.lock()
            guard stopped, !lines.isEmpty else { break }
            let report = lines
            lines = []
            lock.unlock()
            tell(report)
        }
        let again = mergeSaid || mergeWaited
        if mergeWaited { rest = merging }
        merging = []
        lock.broadcast()
        lock.unlock()
        if again { trigger() }
    }

    /// A merge (or a batch) that set `slug` failed with a new merge setback (its tests failed, or it conflicts): the output
    /// goes back to its worker, as the lead would send it.
    private func failed(_ slug: String, head: String, before: LeadSetback?, problem: String) {
        let task = lead.store.load().task(slug)
        guard let setback = task?.setback, setback != before, setback.stage == .merge, task?.status == .failed else {
            once("merge|\(slug)|\(head)|\(problem.prefix(60))", "Didn't merge \(slug): \(LeadToolset.clip(problem, 600))")
            return
        }
        let message = "The merge of your branch (\(head.prefix(8))) failed: \(setback.reason)\n\n\(problem)\n\n"
            + "Fix it on your branch, commit, run the affected tests, then report done again."
        let unsent: String?
        do { unsent = try sendToWorker(slug, message, states: [.failed]) } catch let stuck as NotSubmitted { unsent = stuck.text }
        catch { unsent = "\(slug) is held or no longer moves by itself now" }
        did("Merge of \(slug) failed: \(setback.reason) " + (unsent.map { "Its worker couldn't be told (\($0)): message it, or start_worker(\(slug)), with the output: \(LeadToolset.clip(problem, 600))" }
            ?? "Sent its worker the output; it's back at work."))
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
              let ledger = vault.audits(root: root, task: slug), !ledger.reconsider else { return }
        let hold = lead.hold(slug, ledger, head: head)
        guard !hold.isEmpty, !beingMerged(slug) else { return }
        let open = hold.findings
        let ids = open.map { "\(slug):\($0.id)" }.joined(separator: ", ")
        let why: String = hold.why.isEmpty ? "" : "\n(\(hold.why).)"
        let listed: String = open.map { "- \($0.id): " + LeadToolset.clip($0.line1, 400) }.joined(separator: "\n") + why
        let text = "Your branch's audit (at \(head.prefix(8))) left \(open.count) Important finding\(open.count == 1 ? "" : "s") open, which hold its merge back:\n"
            + listed
            + "\nFix \(open.count == 1 ? "it" : "each") on your branch and commit, or disagree with a reason; answer each by id with answer_findings "
            + "(fixed or disagree), run the affected tests, then report done again: it's audited again then (a re-audit checks these findings' concerns and judges your answers)."
        let live = workerRuns(task)
        // Its worker ended (released during the audit, say): a new one in its worktree gets them, not on a battery
        // hold, and not for a running one (the witness tells the lead its worker ended).
        if !live, onHold || task.status == .running { return }
        let released = task.worker != nil && task.released == task.worker
        // A new worker knows only its contract: where its branch stands, and what the one before it reported.
        let fresh = live ? "" : "You're a new worker on this task, started in its worktree to answer its audit: the worker before you "
            + (released ? "was released while the audit ran (to free its Mac slot)" : "had ended")
            + ". Its commits are on your branch, agent/\(slug), at \(head.prefix(8)): `git log \(lead.base)..HEAD` and `git diff \(lead.base)...HEAD` show its work; build on them."
            + (task.report.map { " Its done report: " + LeadToolset.clip($0, 1500) } ?? "") + "\n\n"
        let unsent: String?
        do { unsent = try sendToWorker(slug, fresh + text, states: [task.status]) } catch let stuck as NotSubmitted {
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
        did("Sent \(slug)'s worker the open Important findings \(ids) from its audit at \(head.prefix(8))" + (live ? "." : released ? " (in a new worker: its last one was released during the audit)." : " (in a new worker: its last one had ended)."))
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
    /// audit count it), and isn't short of memory.
    private func hasRoom(_ slug: String, need: Int) -> Bool {
        guard let sessions = try? lead.advanceSessions(),
              let mac = try? lead.macLoad(sessions, load: lead.runtime.steadyLoad(), except: Worktrees.path(root: lead.root, slug: slug)) else { return false }
        let limits = lead.macLimits()
        return !mac.isBusy(threshold: limits.loadLimit) && mac.memoryShortage(limits) == nil && mac.sessions + need <= limits.maxSessions
            && lead.roomWaits.heldFor(root: lead.root, need: need, mac: mac, limits: limits) == nil
    }

    /// A merged task (a reverted one too: its work is out of the base, and it stays reverted) whose worktree or
    /// branch is still there.
    private func cleanup(_ slug: String) {
        guard let task = due(slug, [.done, .reverted]), task.merged != nil,
              task.worktree != nil || lead.advanceHead(slug) != nil, !beingMerged(slug) else { return }
        step("cleanup|\(slug)") {
            guard due(slug, [.done, .reverted]) != nil else { throw NotDue() }
            let result = try lead.advanceCleanup(slug)
            return LeadToolset.clip(result.text, 300)
        }
    }

    /// `task` may start by itself now: planned, not opted out, and not on an incident's generic brief still (2026-11-08:
    /// turn-this-incident-into-16 started on v1 in the turn the lead wrote v2; see `LeadTask.waitsForContract`).
    private func startsByItself(_ task: LeadTask) -> Bool { isDue(task, [.planned]) && !task.waitsForContract }

    /// The planned tasks whose `after` tasks are done, in board order, while there's room.
    private func starts(_ workflow: LeadWorkflow) {
        for task in lead.store.load().tasks where task.status == .planned && task.autoAdvance != false {
            let board = lead.store.load()
            guard let task = board.task(task.slug), startsByItself(task), let waits = waiting(task, board) else { continue }
            // Not startable yet (see `LeadLaunch.codexWorkersUsable`): said once, never tried.
            if task.workerAgent == .codex, !lead.codexWorkers {
                once("codex|\(task.slug)", "\(task.slug) won't start by itself: \(LeadLaunch.codexUnusable) update_task(\(task.slug), agent: claude) to run it on Claude.")
                continue
            }
            guard waits.isEmpty, !beingMerged(task.slug) else { continue }
            let running = board.tasks.filter { $0.status == .running }.count
            guard running < lead.maxWorkers(workflow) else { return }
            // The Mac's room as start_worker counts it; a refusal for it waits for the app's nudge.
            guard hasRoom(task.slug, need: 1) else { return roomWait("start_worker(\(task.slug))", need: 1) }
            // An auto task goes where both accounts' usage says (start_worker routes it again in its lock): on Codex,
            // Claude's back-off doesn't hold it.
            let route = task.workerAgent == .auto ? lead.workerRoute(for: task, sessions: try? lead.advanceSessions()) : nil
            // Near a usage limit on its model: another task on another model may still start.
            // A Codex task runs on the Codex account: Claude's limits don't hold it.
            if (route?.agent ?? task.workerAgent) != .codex, usageHeld(model: lead.workerModel(for: task)) { continue }
            let after = (task.after ?? []).joined(separator: ", ")
            var overlap: String?
            step("start|\(task.slug)") {
                // Asked again in start_worker's lock: a hold set while the room was counted stands.
                _ = try lead.advanceStart(task.slug, when: { [self] in startsByItself($0) }, warned: { overlap = $0 })
                let routed = lead.store.load().task(task.slug)?.routed
                return "Started a worker on \(task.slug) (\(task.title))" + (after.isEmpty ? "" : ", its after tasks done (\(after))")
                    + (routed.map { "; its agent is auto, so it went to \($0)." } ?? ".")
            }
            // A line of its own, so the report wakes the lead (`wakes`): "Started a worker" alone is FYI.
            if let overlap { did(overlap) }
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

    /// The account's usage is at `AccountUsage.threshold` or more of a limit on `model` (see `AccountUsage`): nothing
    /// starts on it by itself, and the lead is told once per limit and reset, with the reset time. Within its window a
    /// limit's use only grows, and nothing in the project's folder changes at its reset, so a look again is armed for
    /// just after it (a reading with no reset time: once it's no longer believed): what was held starts then.
    private func usageHeld(model: String?) -> Bool {
        guard let limit = lead.usageHold(model: model, sessions: try? lead.advanceSessions()) else { return false }
        let key = "usage|\(limit.key)|\(Int(limit.resetsAt ?? limit.at))"
        lock.lock()
        let arm = wakes.insert(key).inserted
        lock.unlock()
        if arm {
            let root = lead.root
            lead.usageWake(Date(timeIntervalSince1970: (limit.resetsAt ?? limit.at + AccountUsage.untimed) + 1)) { LeadAdvance.nudge(root: root) }
        }
        once(key,
             "The account's usage is near a limit: \(limit.text). " + LeadToolset.usageBackoff(limit, model: model)
                + " Tell the user. Nothing on it starts by itself until the reset, then it does; start_worker or audit with override_usage: true starts one anyway"
                + (limit.model == nil ? "." : ", and a task can run on another model (update_task model, configure verifier_model).")
                + (lead.codexWorkers ? " A bounded, mechanical task with a tight contract can run on Codex instead (update_task(<task>, agent: codex): the Codex account's usage, always audited by a Claude verifier); you decide." : ""))
        return true
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

/// auto_advance's audit sample: a random share (audit_sample_percent, 10 by default) of the review none tasks whose
/// worker reported done is audited before merge anyway, so how often the unaudited path lets a problem through is
/// known, not assumed zero (216 merges went unaudited by 2026-11-07). One draw per task, at its first done report on
/// that path, kept on it (`LeadTask.auditSample`) with its seed: the draw is the seed's first SplitMix64 output, so
/// anyone can check it. At about 15 sampled audits a month it's a tripwire, not a statistic.
public struct LeadAuditSample: Codable, Equatable, Sendable {
    /// How a sampled task's audits went (`LeadTaskScore.sampleVerdict`): an Important finding raised (the unaudited
    /// path would have let it through), passed with none, or a verdict that didn't pass with none raised.
    public enum Verdict: String, Codable, Sendable { case important, clean, failed }

    public static let defaultPercent = 10

    /// The random source's seed (under 2^53, so every JSON reader keeps it exact) and the draw it gives, in 0..<100.
    public var seed: Int
    public var draw: Double
    /// audit_sample_percent when it was drawn; sampled: the draw was under it.
    public var percent: Int
    public var sampled: Bool
    /// The commit its worker reported done on, and when it was drawn.
    public var commit: String
    public var at: Double

    public init(seed: Int, percent: Int, commit: String, at: Double = Date().timeIntervalSince1970) {
        self.seed = seed
        draw = Self.draw(seed: seed)
        self.percent = percent
        sampled = draw < Double(percent)
        self.commit = commit
        self.at = at
    }

    /// A seed from the system's random source.
    public static func randomSeed() -> Int { Int.random(in: 0..<(1 << 53)) }

    /// `seed`'s draw, in 0..<100: SplitMix64's first output for it, its top 53 bits as a fraction.
    public static func draw(seed: Int) -> Double {
        var z = UInt64(truncatingIfNeeded: seed) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53) * 100
    }

    /// "draw 4.21 under audit_sample_percent 10 (seed 123456)", or "… not under …".
    public var text: String {
        "draw \(String(format: "%.2f", draw)) \(sampled ? "under" : "not under") audit_sample_percent \(percent) (seed \(seed))"
    }

    /// How `audits` went for a sampled task; nil while none is recorded.
    public static func verdict(_ audits: LeadAuditLedger?) -> Verdict? {
        guard let audits, audits.rounds > 0 else { return nil }
        if audits.findings.contains(where: { $0.severity == .important && $0.status != .unconfirmed }) { return .important }
        return audits.passed == true ? .clean : .failed
    }
}
