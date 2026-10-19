import Foundation

/// What VibeSwitcher sees that the lead can't: a worker or verifier that waits for input, stops without
/// reporting, ends (its session, or only its agent, leaving the shell open), or stalls whatever its screen says (see
/// `LeadStall`). Each event is keyed by its session, so it's told once, and a new session on the same task is
/// watched afresh.
public enum LeadWitness {
    /// A session as VibeSwitcher sees it.
    public struct Seen: Equatable, Sendable {
        public var live: Bool
        public var exit: Int32?
        /// How it ended, in words (see `HostSession.Exit.cause`): "killed by SIGTERM", "exited 143".
        public var cause: String?
        public var status: SessionStatus?
        public var since: Date?
        public var detail: String?
        /// The session lives on as a shell, its agent gone (see `HostSession.agentQuit`).
        public var agentQuit: Bool
        /// Its last turn ended on this API error (see `TranscriptTail`), and it's between turns; `apiErrorAt` is when
        /// that turn ended (each error is told once).
        public var apiError: String?
        public var apiErrorAt: Double?
        /// What its hooks and transcript together say it's doing (see `LeadActivity`), when read.
        public var activity: LeadActivity?
        /// When its transcript was last written to (see `TranscriptProgress`), and when it ends at a compaction.
        public var lastActivity: Double?
        public var compactedAt: Double?
        /// A shell of its own runs (a command in the foreground or the background).
        public var shellRunning: Bool
        /// The shells of its own the store's last scan found running (see `Session.backgroundJobs`): between turns,
        /// background work it waits on, whether or not its transcript's read window names the task.
        public var shells: [BackgroundJob]
        /// The oldest message waiting in its inbox, and who sent it.
        public var heldSince: Double?
        public var heldFrom: String?
        /// When this session was started (the host spawned it): a status or quiet from before then is another
        /// session's (the terminal it reuses, or none read yet).
        public var started: Double?

        /// How it ended, in words; its exit code when that wasn't said.
        var ending: String { cause ?? "exit \(exit ?? 0)" }

        /// Between turns, the work of its own it waits on, in words: the background task its transcript names, or
        /// else its shells, as the lead's status says them ("1 shell: bash calm-check.sh", "2 shells"). Its turn goes
        /// on when that's done.
        public var waitingOn: String? {
            if case .idle(let running?)? = activity { return running }
            guard activity?.betweenTurns ?? [.done, .idle, .background].contains(status ?? .unknown), let first = shells.first else { return nil }
            return shells.count == 1 ? "1 shell: \(first.command.prefix(80))" : "\(shells.count) shells"
        }

        public init(live: Bool, exit: Int32? = nil, cause: String? = nil, status: SessionStatus? = nil, since: Date? = nil, detail: String? = nil,
                    agentQuit: Bool = false, apiError: String? = nil, apiErrorAt: Double? = nil, activity: LeadActivity? = nil,
                    lastActivity: Double? = nil, compactedAt: Double? = nil, shellRunning: Bool = false, shells: [BackgroundJob] = [],
                    heldSince: Double? = nil, heldFrom: String? = nil, started: Double? = nil) {
            self.live = live
            self.started = started
            self.activity = activity
            self.lastActivity = lastActivity
            self.compactedAt = compactedAt
            self.shellRunning = shellRunning
            self.shells = shells
            self.heldSince = heldSince
            self.heldFrom = heldFrom
            self.agentQuit = agentQuit
            self.apiError = apiError
            self.apiErrorAt = apiErrorAt
            self.exit = exit
            self.cause = cause
            self.status = status
            self.since = since
            self.detail = detail
        }
    }

    /// How long a session may sit finished before it counts as stopped.
    public static let quiet: TimeInterval = 90

    public static func events(board: LeadBoard, seen: [String: Seen], now: Date = Date()) -> [(key: String, text: String)] {
        var events: [(key: String, text: String)] = []
        for task in board.tasks where task.status != .done {
            // A worker the lead stopped itself ended because it was told to.
            if let worker = task.worker, worker != task.stopped, let info = seen[worker] {
                if !info.live, [.running, .failed].contains(task.status) {
                    events.append(("\(worker)|ended", "The worker on \(task.slug) ended (\(info.ending)) without reporting. Its commits are on agent/\(task.slug); read_session to see why, then start_worker(\(task.slug)) starts it again where it was (the task needn't be set to blocked first), or re-plan."))
                } else if info.live, info.agentQuit, [.running, .failed].contains(task.status) {
                    events.append(("\(worker)|ended", "The worker on \(task.slug) ended without reporting: its agent quit and left the session's shell open. Its commits are on agent/\(task.slug); read_session to see why, then stop_worker (it closes the shell) and start_worker again, or re-plan."))
                } else if info.live, !info.agentQuit, let error = info.apiError, [.running, .failed].contains(task.status) {
                    events.append(("\(worker)|api-error-\(Int(info.apiErrorAt ?? 0))", "The worker on \(task.slug) stopped mid-task: its turn ended on an API error (\(error)). Tell it to go on with message(\(task.slug), …); it picks up where it was."))
                } else if info.live, !info.agentQuit, let event = waiting(info, session: worker, now: now,
                                                         input: "The worker on \(task.slug) is waiting for input: \(info.detail ?? "a question or a permission"). Answer it with message, or ask the user if it's theirs to decide.",
                                                         stopped: task.status == .running ? "The worker on \(task.slug) stopped without calling report. read_session to see where it is, then message it." : nil) {
                    events.append(event)
                }
                if info.live {
                    for stall in LeadStall.detect(info, task: task, now: now) {
                        events.append((stall.key(session: worker), "The worker on \(task.slug) is \(stall.text(now: now)). \(stall.advice(slug: task.slug))"))
                    }
                }
            }
            // With several finders, each that hasn't submitted yet.
            for verifier in task.status == .review && task.evidence == nil ? task.awaitedVerifiers : [] {
                guard let info = seen[verifier] else { continue }
                if info.live, !info.agentQuit, let error = info.apiError {
                    events.append(("\(verifier)|api-error-\(Int(info.apiErrorAt ?? 0))", "The verifier on \(task.slug) stopped mid-audit: its turn ended on an API error (\(error)). Tell the user, or audit again."))
                } else if !info.live || info.agentQuit {
                    events.append(("\(verifier)|ended", "The verifier on \(task.slug) ended without a verdict (\(info.live ? "its agent quit; the session's shell is still open" : info.ending)). read_session(\(task.slug), who: verifier) to see why, then audit again."))
                } else if let event = waiting(info, session: verifier, now: now,
                                              input: "The verifier on \(task.slug) is waiting for input: \(info.detail ?? "a question or a permission"). Tell the user if it's theirs, or audit again.",
                                              stopped: "The verifier on \(task.slug) stopped without calling submit_audit. read_session(\(task.slug), who: verifier) to see why, then audit again.") {
                    events.append(event)
                }
            }
        }
        return events
    }

    /// What to tell the lead: the `events` not `told` yet, as they are, except that sessions that ended without
    /// reporting are told together, in one message naming each task and how it ended (a stray kill ends many at
    /// once). Each message carries the keys of the events it tells.
    public static func messages(board: LeadBoard, seen: [String: Seen], now: Date = Date(), told: (String) -> Bool) -> [(keys: [String], text: String)] {
        let fresh = events(board: board, seen: seen, now: now).filter { !told($0.key) }
        let ended = Set(fresh.map(\.key).filter { $0.hasSuffix("|ended") })
        guard ended.count > 1 else { return fresh.map { ([$0.key], $0.text) } }
        let lines = endings(board: board, seen: seen).filter { ended.contains($0.key) }
        var advice: [String] = []
        if lines.contains(where: { $0.restart == .worker }) {
            advice.append("start_worker(<task>) starts a worker again where it was, its worktree and commits kept; the task needn't be set to blocked first")
        }
        if lines.contains(where: { $0.restart == .stopFirst }) { advice.append("a worker whose agent quit needs stop_worker (it closes the shell) first") }
        if lines.contains(where: { $0.restart == .verifier }) { advice.append("audit(<task>) checks a task again") }
        let text = "\(lines.count) sessions ended without reporting:\n" + lines.map { "- The \($0.line)" }.joined(separator: "\n")
            + "\nread_session to see why. " + advice.joined(separator: "; ") + "."
        return [(lines.map(\.key), text)] + fresh.filter { !ended.contains($0.key) }.map { ([$0.key], $0.text) }
    }

    private enum Restart { case worker, stopFirst, verifier }

    /// Each session `events` tells as ended, in a line: "worker on a: killed by SIGTERM".
    private static func endings(board: LeadBoard, seen: [String: Seen]) -> [(key: String, line: String, restart: Restart)] {
        var lines: [(key: String, line: String, restart: Restart)] = []
        for task in board.tasks where task.status != .done {
            if let worker = task.worker, worker != task.stopped, let info = seen[worker], [.running, .failed].contains(task.status) {
                if !info.live {
                    lines.append(("\(worker)|ended", "worker on \(task.slug): \(info.ending)", .worker))
                } else if info.agentQuit {
                    lines.append(("\(worker)|ended", "worker on \(task.slug): its agent quit, leaving the session's shell open", .stopFirst))
                }
            }
            for verifier in task.status == .review && task.evidence == nil ? task.awaitedVerifiers : [] {
                guard let info = seen[verifier], !info.live || info.agentQuit else { continue }
                lines.append(("\(verifier)|ended", "verifier on \(task.slug): \(info.live ? "its agent quit, leaving the session's shell open" : info.ending)", .verifier))
            }
        }
        return lines
    }

    /// The stall to keep on each running task whose worker is stalled now (the most telling one), by task id.
    public static func stalls(board: LeadBoard, seen: [String: Seen], now: Date = Date()) -> [String: LeadStall] {
        var found: [String: LeadStall] = [:]
        for task in board.tasks {
            guard let worker = task.worker, worker != task.stopped, let info = seen[worker],
                  let stall = LeadStall.detect(info, task: task, now: now).first else { continue }
            found[task.id] = stall
        }
        return found
    }

    /// Watches the free space on the volume holding a project's worktrees: when it drops below the workflow's
    /// warning, the lead is told once (until it's back up, see `DiskWatch`), with the task folders that take most.
    public struct Disk {
        let free: (String) -> Int64?
        let scratch: URL
        public private(set) var watch = DiskWatch()

        public init(free: @escaping (String) -> Int64? = DiskSpace.free(at:), scratch: URL = ClaudeScratch.root) {
            self.free = free
            self.scratch = scratch
        }

        /// The free space to tell the lead about now (once per episode); nil otherwise. Cheap: sizing the folders
        /// is `text`'s.
        public mutating func check(root: String, workflow: LeadWorkflow) -> Int64? {
            let free = self.free((root as NSString).appendingPathComponent(".vibeswitcher/worktrees"))
            return watch.check(free: free, warning: workflow.diskWarning) ? free : nil
        }

        /// What to tell the lead: the space left, and the biggest task folders (sized now: it takes a while).
        public func text(free: Int64, root: String, board: LeadBoard, workflow: LeadWorkflow,
                         size: (String) -> Int64 = DiskSpace.size(of:)) -> String {
            LeadWitness.diskText(free: free, workflow: workflow, folders: TaskFolder.all(root: root, board: board, scratch: scratch, size: size))
        }

        /// Both at once.
        public mutating func event(root: String, board: LeadBoard, workflow: LeadWorkflow,
                                   size: (String) -> Int64 = DiskSpace.size(of:)) -> String? {
            check(root: root, workflow: workflow).map { text(free: $0, root: root, board: board, workflow: workflow, size: size) }
        }
    }

    /// "Disk space is low: 7.4 GB free … Biggest task folders: …".
    public static func diskText(free: Int64, workflow: LeadWorkflow, folders: [TaskFolder]) -> String {
        let biggest = folders.prefix(5).map(\.text)
        let finished = folders.contains(where: \.finished)
        return "Disk space is low: \(DiskSpace.text(free)) free on the volume holding the worktrees (the warning is at \(LeadToolset.gb(workflow.diskWarningGB)) GB; "
            + "start_worker refuses below \(LeadToolset.gb(workflow.diskFloorGB)) GB, and at 0 every session stops). "
            + (biggest.isEmpty ? "No task folder takes much of it; tell the user what else fills the disk."
               : "Biggest task folders: \(biggest.joined(separator: "; ")). "
               + (finished ? "cleanup the finished tasks to free theirs; " : "")
               + "tell the user if it stays low.")
    }

    private static func waiting(_ info: Seen, session: String, now: Date, input: String, stopped: String?) -> (key: String, text: String)? {
        let since = Int(info.since?.timeIntervalSince1970 ?? 0)
        if info.status == .needsInput { return ("\(session)|input-\(since)", input) }
        // Waiting on its own background task (a long test run) or shell, its turn goes on when that's done.
        if info.waitingOn != nil { return nil }
        guard let stopped, let status = info.status, [.done, .idle].contains(status), let at = info.since else { return nil }
        // Its hooks or transcript, read after the status, say it's mid-turn: the status is stale.
        if case .working? = info.activity { return nil }
        // Quiet since the last of: its turn ending, this session starting (a session first seen before its hooks
        // fire reads as finished since ever, one on a reused terminal as the earlier session finished), and its
        // transcript's last write.
        let quietSince = max(at.timeIntervalSince1970, info.started ?? -.infinity, info.lastActivity ?? -.infinity)
        return now.timeIntervalSince1970 - quietSince > quiet ? ("\(session)|stopped-\(since)", stopped) : nil
    }
}
