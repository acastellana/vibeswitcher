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
        /// The oldest message waiting in its inbox, and who sent it.
        public var heldSince: Double?
        public var heldFrom: String?

        public init(live: Bool, exit: Int32? = nil, status: SessionStatus? = nil, since: Date? = nil, detail: String? = nil,
                    agentQuit: Bool = false, apiError: String? = nil, apiErrorAt: Double? = nil, activity: LeadActivity? = nil,
                    lastActivity: Double? = nil, compactedAt: Double? = nil, shellRunning: Bool = false,
                    heldSince: Double? = nil, heldFrom: String? = nil) {
            self.live = live
            self.activity = activity
            self.lastActivity = lastActivity
            self.compactedAt = compactedAt
            self.shellRunning = shellRunning
            self.heldSince = heldSince
            self.heldFrom = heldFrom
            self.agentQuit = agentQuit
            self.apiError = apiError
            self.apiErrorAt = apiErrorAt
            self.exit = exit
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
                    events.append(("\(worker)|ended", "The worker on \(task.slug) ended (exit \(info.exit ?? 0)) without reporting. Its commits are on agent/\(task.slug); read_session to see why, then start_worker again or re-plan."))
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
            if task.status == .review, task.evidence == nil, let verifier = task.verifier, let info = seen[verifier] {
                if info.live, !info.agentQuit, let error = info.apiError {
                    events.append(("\(verifier)|api-error-\(Int(info.apiErrorAt ?? 0))", "The verifier on \(task.slug) stopped mid-audit: its turn ended on an API error (\(error)). Tell the user, or audit again."))
                } else if !info.live || info.agentQuit {
                    events.append(("\(verifier)|ended", "The verifier on \(task.slug) ended without a verdict\(info.live ? " (its agent quit; the session's shell is still open)" : ""). read_session(\(task.slug), who: verifier) to see why, then audit again."))
                } else if let event = waiting(info, session: verifier, now: now,
                                              input: "The verifier on \(task.slug) is waiting for input: \(info.detail ?? "a question or a permission"). Tell the user if it's theirs, or audit again.",
                                              stopped: "The verifier on \(task.slug) stopped without calling submit_audit. read_session(\(task.slug), who: verifier) to see why, then audit again.") {
                    events.append(event)
                }
            }
        }
        return events
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

    private static func waiting(_ info: Seen, session: String, now: Date, input: String, stopped: String?) -> (key: String, text: String)? {
        let since = Int(info.since?.timeIntervalSince1970 ?? 0)
        if info.status == .needsInput { return ("\(session)|input-\(since)", input) }
        if let stopped, let status = info.status, [.done, .idle].contains(status), let at = info.since, now.timeIntervalSince(at) > quiet {
            return ("\(session)|stopped-\(since)", stopped)
        }
        return nil
    }
}
