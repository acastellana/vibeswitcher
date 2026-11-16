import Foundation

/// What small_task_min (`LeadSmallTask`) judges a task by, kept in the session host's vault: the board is anyone's to
/// write, and a board entry a worker edited must never lower an audit. The lead's tool server notes the lead's word
/// (audit_reason, that its review was set where audit_reason could be given, Codex, and what keeps it audited for good);
/// the app's witness says which sessions it sees at work, and the vault counts each worker's task's time from that
/// (`count`), never from the board's count.
extension LeadVault {
    public struct SmallTaskFacts: Codable, Equatable, Sendable {
        /// The lead filed it as audit for this (security, irreversible).
        public var auditReason: LeadTask.AuditReason?
        /// Its review was set by a build that offered audit_reason: one set before may be audited for security, unsaid.
        public var reviewOffered: Bool?
        /// A Codex worker was started on it.
        public var codex: Bool?
        /// Why it's audited for good, whatever its size (a new round, a re-roll, the risk check's or the sample's raise,
        /// back to audit after a drop): the first reason noted.
        public var kept: String?
        /// The commit small_task_min dropped its review to none at, once it did.
        public var dropped: String?
        /// Seconds its workers were seen at work, by the app's witness, and since when the current stretch runs.
        public var worked: Double?
        public var workingSince: Double?
        /// When its first worker's grant was issued, and when its worker last reported done, both on the host's clock:
        /// no worker can have worked longer than that span, whatever the witness saw or missed (a session the board
        /// hid from it, the app down while the host ran it on). The count is trusted only under it.
        public var startedAt: Double?
        public var reportedAt: Double?

        /// The span from its first worker's start to its last done report, in seconds; nil when either isn't on record.
        public var span: Double? {
            guard let startedAt, let reportedAt, reportedAt >= startedAt else { return nil }
            return reportedAt - startedAt
        }

        public init(auditReason: LeadTask.AuditReason? = nil, reviewOffered: Bool? = nil, codex: Bool? = nil, kept: String? = nil,
                    dropped: String? = nil, worked: Double? = nil, workingSince: Double? = nil, startedAt: Double? = nil, reportedAt: Double? = nil) {
            self.auditReason = auditReason
            self.reviewOffered = reviewOffered
            self.codex = codex
            self.kept = kept
            self.dropped = dropped
            self.worked = worked
            self.workingSince = workingSince
            self.startedAt = startedAt
            self.reportedAt = reportedAt
        }

        /// These with `note` taken: audit_reason as given (empty clears it); the rest only ever set, never cleared.
        func noting(_ note: SmallTaskNote) -> SmallTaskFacts {
            var facts = self
            if let reason = note.auditReason { facts.auditReason = LeadTask.AuditReason(text: reason) }
            if note.reviewOffered == true { facts.reviewOffered = true }
            if note.codex == true { facts.codex = true }
            if facts.kept == nil, let kept = note.kept, !kept.isEmpty { facts.kept = kept }
            if facts.dropped == nil, let dropped = note.dropped, !dropped.isEmpty { facts.dropped = dropped }
            return facts
        }

        /// The witness's look at `at`: a task seen at work counts the time since it was last seen so, at most
        /// `LeadBudget.longestStep` (a look missed, or the Mac asleep, counts that much: more, never less); one not at
        /// work stops its stretch.
        mutating func count(working: Bool, at: Double) {
            guard working else { workingSince = nil; return }
            if let since = workingSince, at > since { worked = (worked ?? 0) + min(at - since, LeadBudget.longestStep) }
            if workingSince.map({ at > $0 }) ?? true { workingSince = at }
        }
    }

    /// What the lead's tool server notes on a task (`SmallTaskFacts.noting`): nil leaves each as it is.
    public struct SmallTaskNote: Codable, Equatable, Sendable {
        /// security or irreversible; empty clears it.
        public var auditReason: String?
        public var reviewOffered: Bool?
        public var codex: Bool?
        public var kept: String?
        public var dropped: String?

        public init(auditReason: String? = nil, reviewOffered: Bool? = nil, codex: Bool? = nil, kept: String? = nil, dropped: String? = nil) {
            self.auditReason = auditReason
            self.reviewOffered = reviewOffered
            self.codex = codex
            self.kept = kept
            self.dropped = dropped
        }
    }

    /// What the vault keeps of `task` for small_task_min; nil while nothing is.
    public func smallTaskFacts(root: String, task: String) throws -> SmallTaskFacts? {
        guard case .smallTask(let facts) = try call(.smallTaskFacts(root: root, task: task)) else { throw Self.unexpected }
        return facts
    }

    /// The lead's tool server notes `note` on `task`.
    public func noteSmallTask(_ note: SmallTaskNote, root: String, task: String) throws {
        _ = try call(.noteSmallTask(root: root, task: task, note: note))
    }

    /// The app's witness: `sessions` are at work at `at`.
    public func noteWorking(root: String, sessions: [String], at: Double = Date().timeIntervalSince1970) throws {
        _ = try call(.noteWorking(root: root, sessions: sessions, at: at))
    }
}
