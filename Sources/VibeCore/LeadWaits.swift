import Foundation

/// Where a task's time between its start and its end went, besides its worker's working time (`LeadTask.worked`) and
/// the user's answers (`LeadQuestion.waitingOnUser`), kept on the task as its board changes and copied into its receipt
/// when it ends (`LeadReceipt.waits`): waiting for an audit to start (from the worker's done report to the verifier's
/// start: the Mac's room, its slots, the lead), auditing (from the verifier's start to the verdict), and the merge's
/// test runs waiting for the load to drop and for a heavy slot, and running. Seconds, summed over its rounds; nil: none
/// of that kind happened (or it ran before these were recorded). Timestamps only, ridden on writes the board makes
/// anyway: recording it adds no file write of its own.
public struct LeadWaits: Codable, Equatable, Sendable {
    /// The worker's last done report that no audit has started after yet: an audit started next waited from then.
    public var doneAt: Double?
    /// Seconds from done reports to the audits started next.
    public var auditWait: Double?
    /// The audit under way: when its verifier (or finders) started, and how many sessions it runs.
    public var auditAt: Double?
    public var auditSessions: Int?
    /// Seconds of audits, each from its start to its verdict (or to the next audit's start, its verifier's end without
    /// a verdict, or the task's end); and those seconds times the sessions each ran (verifier time).
    public var auditing: Double?
    public var verifierTime: Double?
    /// Seconds the merges' test runs waited for the Mac's load to drop (load_threshold) and for a heavy slot (the
    /// Mac-wide test and build lock), and the seconds their commands ran.
    public var mergeLoadWait: Double?
    public var mergeSlotWait: Double?
    public var mergeTesting: Double?

    public init(doneAt: Double? = nil, auditWait: Double? = nil, auditAt: Double? = nil, auditSessions: Int? = nil, auditing: Double? = nil,
                verifierTime: Double? = nil, mergeLoadWait: Double? = nil, mergeSlotWait: Double? = nil, mergeTesting: Double? = nil) {
        self.doneAt = doneAt
        self.auditWait = auditWait
        self.auditAt = auditAt
        self.auditSessions = auditSessions
        self.auditing = auditing
        self.verifierTime = verifierTime
        self.mergeLoadWait = mergeLoadWait
        self.mergeSlotWait = mergeSlotWait
        self.mergeTesting = mergeTesting
    }

    private static func add(_ sum: Double?, _ seconds: Double) -> Double { (sum ?? 0) + max(0, seconds) }

    /// The worker reported done at `at`: the next audit's wait counts from then (a later done report, after more
    /// work, from that one).
    public mutating func reportedDone(at: Double) { doneAt = at }

    /// An audit of `sessions` verifiers (finders) started at `at`: one still open ends here, and the wait since the
    /// last done report is counted.
    public mutating func auditStarted(at: Double, sessions: Int) {
        auditEnded(at: at)
        if let doneAt { auditWait = Self.add(auditWait, at - doneAt) }
        doneAt = nil
        auditAt = at
        auditSessions = max(1, sessions)
    }

    /// The audit under way (if any) ended at `at`: its verdict, or its verifier's end without one.
    public mutating func auditEnded(at: Double) {
        guard let auditAt else { return }
        let seconds = max(0, at - auditAt)
        auditing = Self.add(auditing, seconds)
        verifierTime = Self.add(verifierTime, seconds * Double(auditSessions ?? 1))
        self.auditAt = nil
        auditSessions = nil
    }

    /// A merge's test run: how long it waited for the load and for a slot (nil: its commands never started), and how
    /// long its commands ran.
    public mutating func mergeRan(loadWait: Double, slotWait: Double?, testing: Double?) {
        mergeLoadWait = Self.add(mergeLoadWait, loadWait)
        if let slotWait { mergeSlotWait = Self.add(mergeSlotWait, slotWait) }
        if let testing { mergeTesting = Self.add(mergeTesting, testing) }
    }

    /// As kept in a receipt when the task ends at `at`: an audit still open ends then, and a done report no audit
    /// followed waited for nothing it's counted under.
    public func closed(at: Double) -> LeadWaits {
        var closed = self
        closed.auditEnded(at: at)
        closed.doneAt = nil
        return closed
    }
}

extension LeadTask {
    /// Its `waits`, changed by `change` (made when it has none).
    mutating func noteWaits(_ change: (inout LeadWaits) -> Void) {
        var waits = self.waits ?? LeadWaits()
        change(&waits)
        self.waits = waits == LeadWaits() ? nil : waits
    }

    /// A merge's test run that was `called` at, waited `loadWait` seconds for the load before that, took its slot
    /// at `begun` (nil: its commands never started) and was decided at `ended`.
    mutating func noteMergeRun(loadWait: Double, called: Date, begun: Date?, ended: Date) {
        noteWaits { $0.mergeRan(loadWait: loadWait, slotWait: begun.map { $0.timeIntervalSince(called) },
                                testing: begun.map { ended.timeIntervalSince($0) }) }
    }
}
