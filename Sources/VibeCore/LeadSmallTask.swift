import Foundation

/// Small tasks merge on their tests (workflow.md's `small_task_min`, 30 unless set; 0: off). The user's answer to
/// A4977A3E (2026-11-12): "Yes: small, non-sensitive tasks merge on tests plus the 10% sample", from the speed review's
/// dispute #6 (docs/process/reviews/speed-review-2026-11-12.md): tasks under 30 min of work took 42% of the week's
/// verifier spend, and 5 of 49 had an Important finding.
///
/// When a review audit task's worker reports done on its first round with under `small_task_min` minutes of counted
/// work, auto_advance (in the lead's own tool server, which may set the vault's review level)
/// drops its review to none for that round, unless:
/// - its branch touches sensitive_paths or strict_paths, or the risk check's deterministic triggers flag it, or the
///   risk check raised it before;
/// - Codex works or worked on it;
/// - the lead filed it with an audit reason (`LeadTask.AuditReason`: security or irreversible), or set its review
///   before audit_reason existed (its audit may be for security, unsaid);
/// - it's in a later round (it went back to work, or an audit already ran on it), or it was re-rolled;
/// - audit_sample_percent in force (the user's floor joined with workflow.md) is 100: every review none task is audited
///   anyway, so the floor wins.
/// What it's judged by is the vault's (`LeadVault.SmallTaskFacts`), never only the board's, which any session may write:
/// the lead's notes (audit_reason, Codex, new rounds, raises) and the working time the vault counted from what the app's
/// witness saw. Nothing on record there keeps the audit.
/// From there it's a review none task as any: the risk check (its model pass too), the audit sample and the merge's full
/// test run are its checks. The drop is recorded on the task (`LeadTask.smallTask`) and in progress.md; once it doesn't
/// qualify any more (a new round, the risk check or the sample raised it), its review goes back to audit, for good.
public struct LeadSmallTask: Codable, Equatable, Sendable {
    /// Its counted work, in whole minutes, when the drop was made.
    public var minutes: Int
    /// The commit its worker reported done on, and when.
    public var commit: String
    public var at: Double
    /// Why its review went back to audit after the drop; nil while it stands.
    public var restored: String?

    public init(minutes: Int, commit: String, at: Double = Date().timeIntervalSince1970, restored: String? = nil) {
        self.minutes = minutes
        self.commit = commit
        self.at = at
        self.restored = restored
    }

    /// workflow.md's `small_task_min` when it says none.
    public static let defaultMinutes = 30

    /// What progress.md says of a drop.
    public static func progressText(_ slug: String, minutes: Int) -> String {
        "\(slug) small task: merged on tests (\(minutes) min of work)"
    }

    /// Why `task` doesn't qualify for the drop; nil when it does (the branch's paths and risk check are
    /// `LeadToolset`'s). What decides is what the vault keeps (`facts`: the lead's word, and the working time the app's
    /// witness counted); nil facts, or anything not on record there, keeps the audit. The board's own fields (anyone's to
    /// write) can only add a reason to keep it. `auditRounds`: the audits the vault recorded on it. `redrop`: judging a
    /// task dropped already, at a later head of the same round (its drop isn't a reason then).
    public static func ineligible(_ task: LeadTask, facts: LeadVault.SmallTaskFacts?, workflow: LeadWorkflow, auditRounds: Int,
                                  redrop: Bool = false) -> String? {
        let limit = workflow.smallTaskMin
        guard limit > 0 else { return "small_task_min is 0 (off)" }
        if workflow.samplePercentInForce >= 100 { return "audit_sample_percent in force is 100: every task is audited" }
        guard let facts else { return "the vault keeps no record of it for small_task_min" }
        if let kept = facts.kept { return "it's audited for good (\(kept))" }
        if !redrop, facts.dropped != nil { return "it was dropped to review none once already" }
        if facts.codex == true || task.codexAudit != nil { return "Codex works or worked on it" }
        if let reason = facts.auditReason ?? task.auditReason { return "the lead filed it as audit for \(reason.rawValue)" }
        if facts.reviewOffered != true { return "its review was set before audit_reason could say security or irreversible" }
        if auditRounds > 0 { return "it's past its first round (audited)" }
        // The board's: only ever more reasons.
        if let restored = task.smallTask?.restored { return "its review went back to audit (\(restored))" }
        if let raised = task.riskRaised { return "the risk check raised it (\(raised.reason))" }
        if task.auditSample?.sampled == true { return "the audit sample drew it" }
        if !(task.rerolls ?? []).isEmpty { return "it was re-rolled" }
        if (task.attempts ?? 1) > 1 { return "it's past its first round" }
        guard let worked = facts.worked else { return "the witness counted no work on it" }
        guard worked < Double(limit) * 60 else { return "\(Int(worked / 60)) min of work, not under small_task_min (\(limit))" }
        // The count is the witness's, and it sees only what it's shown: the host's own span from its first worker's
        // start to its done report bounds the work, and over small_task_min the count can't be vouched for.
        guard let span = facts.span else { return "when its worker started or said done isn't on record in the vault" }
        guard span < Double(limit) * 60 else {
            return "\(Int(span / 60)) min from its first worker's start to its done report, not under small_task_min (\(limit)): its count can't be vouched for"
        }
        return nil
    }

    /// The tasks that merged this way: their drop stood and they merged with no audit.
    public static func mergedThisWay(_ task: LeadTask) -> Bool {
        guard let small = task.smallTask, small.restored == nil, let merged = task.merged else { return false }
        return merged.audited == false && ![.folded, .abandoned].contains(task.status)
    }

    /// Tasks that name `slug` in their title or goal and were planned after `since`: fix tasks filed against it.
    public static func fixes(of slug: String, since: Double, in tasks: [LeadTask]) -> [String] {
        let pattern = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9-])" + NSRegularExpression.escapedPattern(for: slug) + "(?![A-Za-z0-9-])")
        return tasks.filter { other in
            guard other.slug != slug, other.createdAt > since, other.removedAt == nil, let pattern else { return false }
            let text = other.title + "\n" + other.contract.goal
            return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }.map(\.slug)
    }

    /// Status's line: "Small tasks merged on tests (small_task_min; last 7 days): 4 · reverted since: 1 (a) · a fix
    /// task filed against them: 1 (b ← fix-b)"; nil when none merged this way in the last 7 days.
    public static func statusLine(_ tasks: [LeadTask], now: Double) -> String? {
        let week = 7 * 86_400.0
        let merged = tasks.filter { task in mergedThisWay(task) && (task.merged?.at ?? 0) > now - week }
        guard !merged.isEmpty else { return nil }
        let reverted = merged.filter { $0.merged?.revertedBy != nil || $0.status == .reverted }.map(\.slug)
        let fixed = merged.compactMap { task -> String? in
            let found = fixes(of: task.slug, since: task.merged?.at ?? task.createdAt, in: tasks)
            return found.isEmpty ? nil : "\(task.slug) ← \(found.joined(separator: ", "))"
        }
        let list = { (items: [String]) in items.isEmpty ? "0" : "\(items.count) (\(items.prefix(5).joined(separator: "; "))\(items.count > 5 ? "; …" : ""))" }
        return "Small tasks merged on tests (small_task_min, no audit; last 7 days): \(merged.count) · reverted since: \(list(reverted)) · "
            + "with a fix task filed against them (a later task naming them in its title or goal): \(list(fixed))."
    }
}
