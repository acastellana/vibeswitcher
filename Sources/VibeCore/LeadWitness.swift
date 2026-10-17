import Foundation

/// What VibeSwitcher sees that the lead can't: a worker or verifier that waits for input, stops without
/// reporting, or ends. Each event is keyed by its session, so it's told once, and a new session on the same
/// task is watched afresh.
public enum LeadWitness {
    /// A session as VibeSwitcher sees it.
    public struct Seen: Equatable, Sendable {
        public var live: Bool
        public var exit: Int32?
        public var status: SessionStatus?
        public var since: Date?
        public var detail: String?

        public init(live: Bool, exit: Int32? = nil, status: SessionStatus? = nil, since: Date? = nil, detail: String? = nil) {
            self.live = live
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
            if let worker = task.worker, let info = seen[worker] {
                if !info.live, [.running, .failed].contains(task.status) {
                    events.append(("\(worker)|ended", "The worker on \(task.slug) ended (exit \(info.exit ?? 0)) without reporting. Its commits are on agent/\(task.slug); read_session to see why, then start_worker again or re-plan."))
                } else if info.live, let event = waiting(info, session: worker, now: now,
                                                         input: "The worker on \(task.slug) is waiting for input: \(info.detail ?? "a question or a permission"). Answer it with message, or ask the user if it's theirs to decide.",
                                                         stopped: task.status == .running ? "The worker on \(task.slug) stopped without calling report. read_session to see where it is, then message it." : nil) {
                    events.append(event)
                }
            }
            if task.status == .review, task.evidence == nil, let verifier = task.verifier, let info = seen[verifier] {
                if !info.live {
                    events.append(("\(verifier)|ended", "The verifier on \(task.slug) ended without a verdict. read_session(\(task.slug), who: verifier) to see why, then audit again."))
                } else if let event = waiting(info, session: verifier, now: now,
                                              input: "The verifier on \(task.slug) is waiting for input: \(info.detail ?? "a question or a permission"). Tell the user if it's theirs, or audit again.",
                                              stopped: "The verifier on \(task.slug) stopped without calling submit_audit. read_session(\(task.slug), who: verifier) to see why, then audit again.") {
                    events.append(event)
                }
            }
        }
        return events
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
