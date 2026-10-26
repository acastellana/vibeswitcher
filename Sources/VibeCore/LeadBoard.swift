import Darwin
import Foundation

/// What a worker is asked to do: the bounded contract it runs and the verifier checks.
public struct LeadContract: Codable, Equatable, Sendable {
    public var goal: String
    /// Checks the result must pass (commands to run, behaviors to see).
    public var acceptance: [String]
    /// What it must not touch or do.
    public var boundaries: [String]
    /// What it should know: files, decisions, earlier evidence.
    public var context: String

    public init(goal: String, acceptance: [String], boundaries: [String], context: String) {
        self.goal = goal
        self.acceptance = acceptance
        self.boundaries = boundaries
        self.context = context
    }
}

/// The verifier's report: what it found in the worker's branch, not what the worker said.
public struct LeadEvidence: Codable, Equatable, Sendable {
    public enum Completion: String, Codable, Sendable { case complete, incomplete, blocked }
    public enum Integrity: String, Codable, Sendable { case clean, suspect, violation }
    public var completion: Completion
    public var integrity: Integrity
    public var summary: String
    public var at: Double
    /// The branch's commit the verifier looked at: only that commit may be merged on this verdict.
    public var commit: String?

    public init(completion: Completion, integrity: Integrity, summary: String, commit: String? = nil, at: Double = Date().timeIntervalSince1970) {
        self.completion = completion
        self.integrity = integrity
        self.summary = summary
        self.commit = commit
        self.at = at
    }

    public var passes: Bool { completion == .complete && integrity == .clean }
}

/// A milestone a worker noted with its `progress` tool.
public struct LeadCheckpoint: Codable, Equatable, Sendable {
    public var text: String
    public var at: Double

    public init(text: String, at: Double = Date().timeIntervalSince1970) {
        self.text = text
        self.at = at
    }
}

/// The lead's word on a task after its contract: what it appended to the task's context (update_task's
/// append_context) or a message it sent the worker. The verifier reads them: an edit outside the contract's files that
/// the lead accepted here is in scope (twice on 2026-10-19 a branch was marked suspect for wiring the lead had approved
/// by message, and audited again in full on the same commit). Sealed by the session host as the lead's when written
/// (see `SteerInbox.seal`; the board is a file anyone's Bash can write): only a note whose seal holds is the lead's.
public struct LeadNote: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Appended to the task's context.
        case context
        /// A message to the task's worker.
        case message
    }

    public var id: String
    public var kind: Kind
    public var text: String
    /// Who sealed it: the lead's name as its messages carry it ("lead of <project>").
    public var by: String
    public var at: Double
    public var seal: String?

    public init(id: String = UUID().uuidString, kind: Kind, text: String, by: String, at: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.kind = kind
        self.text = text
        self.by = by
        self.at = at
    }

    /// The message its seal is made for: the task and the kind are in its id, so a note sealed for one task (or as a
    /// message) doesn't hold copied onto another (or as appended context).
    public func sealed(task: String) -> SteerMessage {
        var message = SteerMessage(id: "note \(task) \(kind.rawValue) \(id)", text: text, from: .lead(by), agentPid: 0, at: at)
        message.seal = seal
        return message
    }
}

/// Why a task last failed: an audit that didn't pass, or a merge that conflicted or failed its tests. Kept when the
/// task goes back to work, so what's being reworked stays in view.
public struct LeadSetback: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case review, merge }
    public var stage: Stage
    public var reason: String
    /// The verdict, when an audit failed it.
    public var evidence: LeadEvidence?
    public var at: Double

    public init(stage: Stage, reason: String, evidence: LeadEvidence? = nil, at: Double = Date().timeIntervalSince1970) {
        self.stage = stage
        self.reason = reason
        self.evidence = evidence
        self.at = at
    }
}

/// What a merge put on the lead's branch.
public struct LeadMergeRecord: Codable, Equatable, Sendable {
    public var commit: String
    /// The test command ran on it and passed (false: there was none, so nothing ran).
    public var tested: Bool
    public var at: Double
    // The fields below are optional: older records have none of them.
    /// The branch's head it went onto: `onto..commit` are the commits it put there.
    public var onto: String?
    /// regression_command ran on it too, and passed.
    public var regression: Bool?
    /// The base's commit that reverted it (all or part of it), and when that was found (see `LeadReverts`).
    public var revertedBy: String?
    public var revertedAt: Double?
    /// Why the lead reverted it (the revert tool); nil when the base's own commit did (found by `LeadReverts`).
    public var revertReason: String?
    /// false: it merged with no verdict, a `review: none` task on its worker's report and the merge's own test run;
    /// nil (older records, and every audited merge): a passing audit let it in.
    public var audited: Bool?

    public init(commit: String, tested: Bool, onto: String? = nil, regression: Bool? = nil, audited: Bool? = nil,
                at: Double = Date().timeIntervalSince1970) {
        self.commit = commit
        self.tested = tested
        self.onto = onto
        self.regression = regression
        self.audited = audited
        self.at = at
    }

    /// It merged without an audit (`audited` false).
    public var unaudited: Bool { audited == false }
}

/// Something a verifier found in a task's branch, kept until it's resolved: fixed (a later audit saw it fixed) or
/// dismissed with a reason (by a verifier, or by the lead, who may turn it into a task of its own).
public struct LeadFinding: Codable, Equatable, Sendable, Identifiable {
    public enum Severity: String, Codable, Sendable, CaseIterable {
        /// Must be fixed (or dismissed with a reason) before the task merges.
        case important = "Important"
        /// Worth fixing; never holds a merge back.
        case nit = "Nit"
        /// Already wrong before this branch: never fails the task; the lead may make it a task of its own.
        case preExisting = "Pre-existing"
    }
    /// `unconfirmed`: an audit's vote kept it visible, but fewer than most of its finders saw it; it doesn't hold the
    /// merge back, and a later round may confirm it (open), or close it.
    public enum Status: String, Codable, Sendable, CaseIterable { case open, fixed, dismissed, unconfirmed }

    /// What a verifier's submit_audit says about one finding: a new one (no id, or one not seen before), or one
    /// raised in an earlier round (its id) marked fixed, dismissed or still open.
    public struct Report: Codable, Equatable, Sendable {
        public var id: String?
        public var severity: Severity
        public var file: String
        public var line: Int
        public var evidence: String
        public var status: Status
        public var reason: String?
        /// An Important finding's failure: these inputs or this state give this wrong result or crash.
        public var failureScenario: String?

        public init(id: String? = nil, severity: Severity, file: String, line: Int, evidence: String, status: Status = .open, reason: String? = nil,
                    failureScenario: String? = nil) {
            self.id = id
            self.severity = severity
            self.file = file
            self.line = line
            self.evidence = evidence
            self.status = status
            self.reason = reason
            self.failureScenario = failureScenario
        }
    }

    public var id: String
    public var severity: Severity
    public var file: String
    public var line: Int
    /// What shows it: the code at file:line, and what was run and what it gave.
    public var evidence: String
    public var status: Status
    /// Why it was dismissed (or how it was fixed, when the verifier said).
    public var reason: String?
    /// The audit round that raised it, and the one that closed it (fixed or dismissed).
    public var raised: Int
    public var closed: Int?
    /// Who closed it: the verifier, or the lead.
    public var closedBy: String?
    /// The task the lead made of it (add_task from_finding).
    public var followUp: String?
    /// What goes wrong because of it (an Important finding's: one without it is recorded as a Nit; optional: findings
    /// from before it was asked have none).
    public var failureScenario: String?

    public var isOpen: Bool { status == .open }
    /// Open, or unconfirmed: a later round may still say something about it.
    public var isLive: Bool { status == .open || status == .unconfirmed }
    /// An open Important finding: merge refuses while there's one.
    public var blocks: Bool { isOpen && severity == .important }
    public var place: String { "\(file):\(line)" }
    /// "F2 (Important, Sources/A.swift:12)".
    public var label: String { "\(id) (\(severity.rawValue), \(place))" }
    /// "F2 Sources/A.swift:12 — evidence (fails: scenario) [fixed: reason]", for the lead's text.
    public var line1: String {
        var text = "\(id) \(place) — \(evidence)"
        if let failureScenario { text += " (fails: \(failureScenario))" }
        if status != .open { text += " [\(status.rawValue)\(closedBy == "lead" ? " by the lead" : "")\(reason.map { ": \($0)" } ?? "")]" }
        if let followUp { text += " → task \(followUp)" }
        return text
    }

    /// The same finding, however its id is written ("f2", " F2 ").
    func named(_ name: String) -> Bool { id.lowercased() == name.trimmingCharacters(in: .whitespaces).lowercased() }
}

/// A worker's answer to one of its task's open findings (answer_findings): fixed (in a commit) or a disagreement with
/// its reason. The re-audit is told the answers given since the last audit and judges them: it checks a fix, and
/// closes a finding whose disagreement it accepts (dismissed).
public struct LeadFindingAnswer: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case fixed, disagree }

    public var id: String
    public var kind: Kind
    /// How it was fixed, or why the worker disagrees.
    public var reason: String
    /// The branch's head when it answered.
    public var commit: String?
    /// The audit rounds recorded when it answered: an answer counts for the next audit only.
    public var round: Int
    public var at: Double

    public init(id: String, kind: Kind, reason: String, commit: String?, round: Int, at: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.kind = kind
        self.reason = reason
        self.commit = commit
        self.round = round
        self.at = at
    }

    /// "fixed at 1234abcd: how", "disagrees: why".
    public var text: String {
        switch kind {
        case .fixed: return "fixed" + (commit.map { " at \($0.prefix(8))" } ?? "") + (reason.isEmpty ? "" : ": \(reason)")
        case .disagree: return "disagrees: \(reason)"
        }
    }
}

/// A task re-rolled after its audit rounds (update_task reroll): its worker stopped, its branch kept under `archive`,
/// and a fresh worker started from the base with what the rounds learned.
public struct LeadReroll: Codable, Equatable, Sendable {
    /// The branch the earlier attempt is kept under, and its head.
    public var archive: String
    public var commit: String?
    /// The audit rounds recorded when it was re-rolled: the next audit is the fresh branch's first.
    public var round: Int
    public var at: Double

    public init(archive: String, commit: String?, round: Int, at: Double = Date().timeIntervalSince1970) {
        self.archive = archive
        self.commit = commit
        self.round = round
        self.at = at
    }
}

/// A task's audits: the findings raised across its rounds, each with its state, and how the rounds went. The vault
/// keeps it with the task's verdict (the board shows a copy). A verifier changes it only through `record`, the lead
/// only through `dismiss` and `replan`; a finding once closed stays closed.
public struct LeadAuditLedger: Codable, Equatable, Sendable {
    public var findings: [LeadFinding] = []
    /// Audits recorded.
    public var rounds = 0
    /// Audits in a row that left an Important finding open or didn't pass; a clean round, or the lead re-planning
    /// the task, starts it over.
    public var failedRounds = 0
    /// Of those, the ones whose verdict didn't pass (optional: ledgers from before it was counted have none).
    public var failedVerdicts: Int?
    /// The commit the last audit covered: a re-audit checks the diff since it.
    public var commit: String?
    /// The last audit's verdict passed.
    public var passed: Bool?
    /// How the last audit's finders voted, when it ran more than one (optional: one verifier gives none).
    public var vote: LeadAuditVote.Outcome?

    /// Failed rounds after which the task is re-rolled (or re-planned), not sent back for a third: fixes past the
    /// second attempt rarely land, and a fresh start from what the rounds learned does better.
    public static let roundCap = 2

    public init() {}

    public var open: [LeadFinding] { findings.filter(\.isOpen) }
    /// Open Important findings: merge refuses while there are any.
    public var blocking: [LeadFinding] { findings.filter(\.blocks) }
    /// The open findings a re-audit must say fixed or still open about (an open Pre-existing one isn't the branch's).
    public var toRecheck: [LeadFinding] { open.filter { $0.severity != .preExisting } }
    /// A re-audit: an earlier one is recorded, so new findings come from the diff since its commit only.
    public var isReaudit: Bool { rounds > 0 && commit != nil }
    /// `roundCap` audits in a row left Important findings open (or failed) and the last one still does.
    public var reconsider: Bool { failedRounds >= Self.roundCap && (!blocking.isEmpty || passed == false) }

    /// What the failed rounds were: "2 Important findings left open across 2 rounds", "2 failed verdicts in a row",
    /// or both kinds counted.
    public var reconsiderCause: String {
        let rounds = failedRounds, open = blocking.count
        let findings = "\(open) Important finding\(open == 1 ? "" : "s") left open"
        guard let counted = failedVerdicts else { return "\(rounds) audits in a row left Important findings open or failed" }
        let failed = min(counted, rounds)
        let verdicts = "\(failed) failed verdict\(failed == 1 ? "" : "s")"
        if failed == 0 { return "\(findings) across \(rounds) rounds" }
        if failed == rounds { return "\(verdicts) in a row" + (open == 0 ? "" : ", with \(findings)") }
        let others = rounds - failed
        return "\(rounds) audits in a row: \(verdicts), and \(others) that left Important findings open" + (open == 0 ? "" : " (\(open) open now)")
    }

    public func finding(_ id: String) -> LeadFinding? { findings.first { $0.named(id) } }

    public struct Refusal: Error, CustomStringConvertible, Equatable {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// One audit's findings, on `commit`, with its verdict: each one an earlier round raised is marked as reported
    /// (open, fixed or dismissed with a reason); each new one is added open. `changed`: the files the re-audit covers,
    /// when known (the branch's own changes since the last audited commit, or its whole change when it's that commit
    /// again); a re-audit's new findings must be in them. Refused whole, leaving the ledger
    /// as it was, when it raises again a finding already closed (by id, or at the same file:line), adds one at the
    /// place of one still open, skips an open one a re-audit must recheck, or brings a new one from outside the diff.
    /// An unconfirmed finding raised again (by id, or at its place with its severity) is confirmed: open; one of
    /// another severity there doesn't hold the place. `unconfirmed`: new findings an audit's vote keeps without a
    /// majority (see `LeadAuditVote`), added as unconfirmed (one where a finding of its severity already is, is left
    /// out: the vote checked each finder's findings against the ledger); `vote`: how the vote went.
    public mutating func record(_ reports: [LeadFinding.Report], unconfirmed: [LeadFinding.Report] = [], vote: LeadAuditVote.Outcome? = nil,
                                commit: String, passes: Bool, changed: Set<String>? = nil) throws {
        var next = self
        let round = rounds + 1
        var seen: Set<String> = []
        for report in reports {
            guard report.status != .unconfirmed else {
                throw Refusal("\(report.id ?? "\(report.file):\(report.line)"): a finding's status is open, fixed or dismissed; only a vote of several finders leaves one unconfirmed.")
            }
            // Raised again at an unconfirmed one's place: that one, confirmed.
            var named = report.id?.trimmingCharacters(in: .whitespaces) ?? ""
            if next.finding(named) == nil, report.status == .open,
               let there = next.findings.first(where: { $0.status == .unconfirmed && $0.file == report.file && $0.line == report.line
                   && $0.severity == report.severity }) {
                named = there.id
            }
            if !named.isEmpty, let index = next.findings.firstIndex(where: { $0.named(named) }) {
                let finding = next.findings[index]
                guard seen.insert(finding.id).inserted else { throw Refusal("\(finding.id) is in findings twice; say it once.") }
                if finding.status == .unconfirmed {
                    next.findings[index].status = report.status
                    next.findings[index].reason = report.status == .open ? nil : report.reason
                    if report.status != .open {
                        next.findings[index].closed = round
                        next.findings[index].closedBy = "verifier"
                    }
                    continue
                }
                guard finding.isOpen else {
                    // Saying again how it was closed is no news; reopening it is refused.
                    if report.status == finding.status { continue }
                    throw Refusal("\(finding.label) was closed in round \(finding.closed ?? 0) (\(finding.status.rawValue)\(finding.reason.map { ": \($0)" } ?? "")); a closed finding isn't raised again.")
                }
                switch report.status {
                case .open, .unconfirmed: break
                case .fixed, .dismissed:
                    next.findings[index].status = report.status
                    next.findings[index].reason = report.reason
                    next.findings[index].closed = round
                    next.findings[index].closedBy = "verifier"
                }
            } else {
                guard report.status == .open else {
                    throw Refusal("\(report.id ?? "A finding at \(report.file):\(report.line)") isn't one raised before (\(next.findings.isEmpty ? "none was" : next.findings.map(\.id).joined(separator: ", "))), so it can't be \(report.status.rawValue); a new finding is open.")
                }
                // An unconfirmed one of another severity there doesn't hold its place.
                if let there = next.findings.first(where: { $0.file == report.file && $0.line == report.line && $0.status != .unconfirmed }) {
                    throw there.isOpen
                        ? Refusal("\(there.label) is already open at \(there.place); mark that one (its id) instead of raising a new one.")
                        : Refusal("\(there.label) at \(there.place) was closed in round \(there.closed ?? 0) (\(there.status.rawValue)); a closed finding isn't raised again.")
                }
                if next.isReaudit, let changed, !changed.contains(report.file) {
                    let audited = next.commit.map { String($0.prefix(8)) } ?? ""
                    let covers = changed.isEmpty ? "no file" : changed.sorted().prefix(12).joined(separator: ", ") + (changed.count > 12 ? ", …" : "")
                    throw Refusal(commit == next.commit
                        ? "\(report.file) isn't changed by the branch: a re-audit of the audited commit \(audited) again raises new findings from the branch's whole change only (it covers \(covers))."
                        : "\(report.file) isn't in what the branch changed since the audited commit \(audited): a re-audit raises new findings from the new diff only (it covers \(covers)).")
                }
                var id = report.id?.trimmingCharacters(in: .whitespaces) ?? ""
                if id.isEmpty || next.finding(id) != nil {
                    var number = next.findings.count + 1
                    while next.finding("F\(number)") != nil { number += 1 }
                    id = "F\(number)"
                }
                seen.insert(id)
                next.findings.append(LeadFinding(id: id, severity: report.severity, file: report.file, line: report.line, evidence: report.evidence,
                                                 status: .open, reason: nil, raised: round, failureScenario: report.failureScenario))
            }
        }
        for report in unconfirmed where !next.findings.contains(where: { $0.file == report.file && $0.line == report.line && $0.severity == report.severity }) {
            var number = next.findings.count + 1
            while next.finding("F\(number)") != nil { number += 1 }
            next.findings.append(LeadFinding(id: "F\(number)", severity: report.severity, file: report.file, line: report.line, evidence: report.evidence,
                                             status: .unconfirmed, reason: report.reason, raised: round, failureScenario: report.failureScenario))
        }
        if isReaudit {
            let skipped = toRecheck.filter { !seen.contains($0.id) }
            guard skipped.isEmpty else {
                throw Refusal("Say for each open finding whether it's fixed or still open: \(skipped.map(\.label).joined(separator: ", ")) \(skipped.count == 1 ? "isn't" : "aren't") in findings.")
            }
        }
        next.rounds = round
        next.commit = commit
        next.passed = passes
        next.vote = vote
        let clean = passes && next.blocking.isEmpty
        next.failedRounds = clean ? 0 : failedRounds + 1
        next.failedVerdicts = clean ? 0 : (failedVerdicts ?? 0) + (passes ? 0 : 1)
        self = next
    }

    /// The lead closes an open finding with a reason (a dismissal, or the task it became).
    public mutating func dismiss(_ id: String, reason: String, followUp: String? = nil) throws {
        guard let index = findings.firstIndex(where: { $0.named(id) }) else {
            throw Refusal("No finding \(id)\(findings.isEmpty ? "" : " (there are \(findings.map(\.id).joined(separator: ", ")))").")
        }
        guard findings[index].isLive else {
            throw Refusal("\(findings[index].label) is \(findings[index].status.rawValue) already.")
        }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refusal("Say why it's dismissed (reason).") }
        findings[index].status = .dismissed
        findings[index].reason = reason
        findings[index].closed = rounds
        findings[index].closedBy = "lead"
        findings[index].followUp = followUp
        // The last Important one closed on a pass: that round is clean after all, and the rounds count from here.
        if passed == true, blocking.isEmpty { replan() }
    }

    /// The lead re-planned the task: its rounds count from here.
    public mutating func replan() {
        failedRounds = 0
        failedVerdicts = 0
    }

    /// What the rounds learned, for a re-rolled task's fresh worker (and its verifier): where the earlier attempt is
    /// kept, why it was re-rolled, and each Important finding (and open Nit) with its evidence, its failure, how it
    /// ended and the worker's last answer. `answers`: the worker's, the latest per finding; `number`: which re-roll.
    public func rerollSummary(answers: [LeadFindingAnswer], archive: String, base: String, number: Int) -> String {
        func clip(_ text: String, _ limit: Int = 400) -> String {
            let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            return line.count > limit ? String(line.prefix(limit)) + "…" : line
        }
        let latest = Dictionary(answers.map { ($0.id.uppercased(), $0) }) { $1 }
        var lines = ["## Re-roll \(number): what the earlier attempt's audits learned",
                     "The task was re-rolled after \(rounds) audit round\(rounds == 1 ? "" : "s")\(failedRounds >= Self.roundCap ? " (\(reconsiderCause))" : ""): a fresh worker starts from \(base). "
                        + "The earlier attempt is kept on the branch \(archive) (`git log \(base)..\(archive)`, `git diff \(base)...\(archive)`): read it for what "
                        + "worked, but don't merge it in or copy it whole; avoid what its findings below say went wrong. The new branch's first audit checks each open finding again."]
        let shown = findings.filter { $0.severity == .important || ($0.severity == .nit && $0.isLive) }
        if shown.isEmpty { lines.append("No Important finding was raised; the rounds failed on their verdicts.") }
        for finding in shown {
            let state: String
            switch finding.status {
            case .open: state = "open"
            case .unconfirmed: state = "unconfirmed"
            case .fixed: state = "fixed in round \(finding.closed ?? rounds)"
            case .dismissed: state = "dismissed by the \(finding.closedBy ?? "verifier")" + (finding.reason.map { ": \(clip($0, 200))" } ?? "")
            }
            var line = "- \(finding.id) [\(finding.severity.rawValue), \(state)] \(finding.place): \(clip(finding.evidence))"
            if let scenario = finding.failureScenario { line += " Fails when: \(clip(scenario, 300))" }
            if let answer = latest[finding.id.uppercased()] { line += " The worker's answer: \(clip(answer.text, 300))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// The findings by severity (Important, Nit, Pre-existing), each group's open ones first, then unconfirmed ones;
    /// empty groups left out.
    public var bySeverity: [(severity: LeadFinding.Severity, findings: [LeadFinding])] {
        LeadFinding.Severity.allCases.compactMap { severity in
            let group = findings.filter { $0.severity == severity }
            return group.isEmpty ? nil : (severity, group.filter(\.isOpen) + group.filter { $0.status == .unconfirmed } + group.filter { !$0.isLive })
        }
    }
}

/// An audit run by several finders, as the board shows it: who they are, and who has reported.
public struct LeadAuditPanel: Codable, Equatable, Sendable {
    /// Each finder's focus, finder 1 first.
    public var focuses: [String]
    /// Each finder's session, finder 1 first.
    public var sessions: [String]
    /// The finders (1-based) whose findings are in.
    public var reported: [Int]
    /// The commit they check, and the shared build and test run's logs and how it went.
    public var commit: String
    public var logs: [String]
    public var run: String

    public init(focuses: [String], sessions: [String], reported: [Int] = [], commit: String, logs: [String], run: String) {
        self.focuses = focuses
        self.sessions = sessions
        self.reported = reported
        self.commit = commit
        self.logs = logs
        self.run = run
    }

    public var size: Int { focuses.count }
    /// "3 finders, 1 reported".
    public var progress: String { "\(size) finders, \(reported.count) reported" }
}

/// An audit VibeSwitcher started again by itself because its verifier ended without a verdict (see `LeadAdvance`):
/// once per commit. One that ends so too is left to the lead ("Verifier ended twice").
public struct LeadVerifierRetry: Codable, Equatable, Sendable {
    /// The branch's commit both audits check.
    public var commit: String
    /// How the first verifier ended, in the witness's words (see `LeadWitness.verifierEnding`).
    public var first: String
    /// The verifiers the retry started (its finders, with several).
    public var verifiers: [String]
    /// How the retry's verifier ended too, once it did: no third audit starts by itself.
    public var second: String?

    public init(commit: String, first: String, verifiers: [String], second: String? = nil) {
        self.commit = commit
        self.first = first
        self.verifiers = verifiers
        self.second = second
    }
}

public struct LeadTask: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        /// On the board, no worker yet.
        case planned
        /// A worker has it.
        case running
        /// The worker says it's done; the verifier checks.
        case review
        /// Verified and merged.
        case done
        /// Verified as not done (or the worker gave up); the lead decides what next.
        case failed
        /// Waiting on something (an answer, another task).
        case blocked
        /// Deliberately not merged (a decision, a note or the user holds it back, e.g. a prototype the user hasn't
        /// looked at): its work stays, merge refuses it, and nothing counts it as failed.
        case kept
        /// Folded into another task (`foldedInto`), which carries its work: finished like a merged task, counted with
        /// the merged ones, never as failed or blocked; nothing more starts, audits or merges on it.
        case folded
        /// Given up by the lead (`abandonedBecause`): nothing will carry its work. Finished, counted apart from the
        /// merged ones and never as failed or blocked; nothing more starts, audits or merges on it.
        case abandoned
        /// Merged, then undone by the lead's revert (`merged.revertedBy`, `merged.revertReason`): one commit on the base
        /// took its changes out again. Finished; nothing more starts, audits or merges on it (new work is a new task).
        case reverted

        /// The order the board lists the states in: what needs the lead first. Holds every case (a test checks).
        public static let attentionOrder: [Status] = [.running, .review, .blocked, .failed, .kept, .planned, .done, .reverted, .folded, .abandoned]
        /// Where the state sits in `attentionOrder`.
        public var attentionRank: Int { Self.attentionOrder.firstIndex(of: self) ?? Self.attentionOrder.count }
    }

    /// Who checks its work before merge, as the lead set it (add_task, update_task). none: its worker owns it through
    /// completion, and merge takes it on the worker's "done" report and the merge's own test run, with no verdict.
    /// audit: a verifier's passing verdict, as every task before review levels: for security, irreversible operations
    /// and complex changes. A branch that touches sensitive_paths is audited whatever it says (merge checks).
    public enum Review: String, Codable, Sendable, CaseIterable {
        case none, audit

        /// "audit", "Audit", " none ": the level; nil for anything else.
        public init?(text: String) { self.init(rawValue: text.trimmingCharacters(in: .whitespaces).lowercased()) }

        /// The stricter of two levels.
        public func atLeast(_ other: Review?) -> Review { self == .audit || other == .audit ? .audit : .none }
    }

    public var id: String
    public var slug: String
    public var title: String
    public var contract: LeadContract
    public var status: Status
    /// The session host's id of the worker running it.
    public var worker: String?
    public var verifier: String?
    /// The worker session the lead itself stopped (stop_worker): its end is no news to the lead.
    public var stopped: String?
    public var branch: String?
    public var worktree: String?
    /// The verdict on the commit its branch is at, as long as it's there: a report on that commit keeps it; a new
    /// commit's report moves it to `outdatedEvidence`.
    public var evidence: LeadEvidence?
    public var createdAt: Double
    // The fields below are optional: older boards have none of them.
    /// When it took its current status (`BoardStore.update` stamps every change).
    public var since: Double?
    /// When its first worker started.
    public var startedAt: Double?
    /// Rounds of work: 1 for the first worker, one more each time it goes back to work after failing (the lead
    /// messages its worker or starts a new one).
    public var attempts: Int?
    /// Why it last failed; kept through the rework.
    public var setback: LeadSetback?
    /// Why it's blocked (the worker's words, or the lead stopped it); cleared when it works again.
    public var blocker: String?
    /// The worker's milestones, oldest first.
    public var checkpoints: [LeadCheckpoint]?
    /// The worker's last "done" report.
    public var report: String?
    /// The last verdict once the worker reported on a newer commit: shown as for an older commit, never merged on;
    /// gone with the next verdict.
    public var outdatedEvidence: LeadEvidence?
    public var merged: LeadMergeRecord?
    /// When its worker asked the lead something (ask_lead) that the lead hasn't answered with a message yet.
    public var leadQuestionAt: Double?
    /// The witness's latest word that its worker stopped making progress (see `LeadStall`); cleared once it moves.
    public var stall: LeadStall?
    /// Why the lead keeps it unmerged (status kept).
    public var keptBecause: String?
    /// The slug of the task it's folded into (status folded).
    public var foldedInto: String?
    /// Why the lead gave it up (status abandoned).
    public var abandonedBecause: String?
    /// When the lead removed it from the board (a record made by mistake that never ran: `LeadBoard.removed`), and why.
    public var removedAt: Double?
    public var removedBecause: String?
    /// Its audits' findings and rounds, as the vault last had them (for showing; merge goes by the vault's).
    public var audits: LeadAuditLedger?
    /// The finders its audit runs, while it runs more than one (for showing; the vault holds their reports).
    public var panel: LeadAuditPanel?
    /// Its worker's answers to its open findings (answer_findings), the latest for each finding.
    public var answers: [LeadFindingAnswer]?
    /// Its re-rolls, oldest first (update_task reroll): the branches its earlier attempts are kept under.
    public var rerolls: [LeadReroll]?
    /// The lead's notes on it since its contract (appended context, messages to its worker), oldest first.
    public var notes: [LeadNote]?
    /// How it went, in the scorecard's numbers, as of the board's last change (see `LeadTaskScore`).
    public var score: LeadTaskScore?
    /// Its review level as the lead set it (for showing, and never lowering: merge goes by the stricter of this and
    /// the vault's copy, which only the lead writes). nil: none, the default.
    public var review: Review?
    /// Why its worker's last done report needs an audit before merge though its review is none (its branch touches
    /// sensitive_paths, say), as report found it; nil when it needs none (for showing: merge checks again).
    public var auditNeeded: String?
    /// The risk check raised it from review none to audit (see `LeadRisk`): why, on which commit, and by what. For
    /// showing (status's "audited: <reason>", its score); the vault's review audit is what merge goes by.
    public var riskRaised: LeadRiskRaise?
    /// The tasks (their slugs) that must be done before it starts by itself (add_task's and update_task's `after`; see
    /// `LeadAdvance`); nil or empty: none.
    public var after: [String]?
    /// False: VibeSwitcher moves nothing on it by itself (the contract opts it out of auto_advance); nil: it does.
    public var autoAdvance: Bool?
    /// The commit whose verdict's open Important findings VibeSwitcher last sent its worker by itself (`LeadAdvance`):
    /// each verdict's are sent once.
    public var autoSentBack: String?
    /// The audit VibeSwitcher last started again by itself after its verifier ended without a verdict (`LeadAdvance`).
    public var verifierRetry: LeadVerifierRetry?
    /// Its time budget in minutes as the lead set it (add_task's and update_task's budget_min; 0: none); nil: the
    /// workflow's task_budget_min (see `LeadBudget`).
    public var budgetMin: Int?
    /// How long its workers have worked on it, in seconds, as the witness counted (see `LeadBudget.counts`): waiting
    /// on a prompt, the lead or the user, and its audits, don't count.
    public var worked: Double?
    /// When the witness last counted its worker at work; nil while it isn't.
    public var workedAt: Double?
    /// Its working time reached its budget (see `LeadBudget`): until the lead changes budget_min.
    public var overBudget: LeadOverBudget?
    /// What it cost, once it ended (merged, folded or abandoned): see `LeadReceipt`. nil for tasks that ended before
    /// receipts, and for any still open.
    public var receipt: LeadReceipt?

    /// Its review level: none unless the lead set audit.
    public var reviewLevel: Review { review ?? .none }

    /// Its worker's answers given since the last audit `ledger` records, by finding id: the ones the next audit judges.
    public func currentAnswers(_ ledger: LeadAuditLedger?) -> [String: LeadFindingAnswer] {
        let rounds = ledger?.rounds ?? 0
        return Dictionary((answers ?? []).filter { $0.round == rounds }.map { ($0.id.uppercased(), $0) }) { $1 }
    }

    /// The re-roll the next audit is the first after (no audit recorded since), if any.
    public func pendingReroll(_ ledger: LeadAuditLedger?) -> LeadReroll? {
        rerolls?.last.flatMap { $0.round == (ledger?.rounds ?? 0) ? $0 : nil }
    }

    public static let keptCheckpoints = 40
    /// Notes kept per task, the newest: an approval is rarely more than a few dozen messages back.
    public static let keptNotes = 100

    /// The verifiers whose word the task waits on: with several finders, those that haven't submitted yet (one that
    /// has may end while the others work); else its verifier.
    public var awaitedVerifiers: [String] {
        guard let panel else { return verifier.map { [$0] } ?? [] }
        let waiting = panel.sessions.enumerated().filter { !panel.reported.contains($0.offset + 1) }.map(\.element)
        return waiting.isEmpty ? verifier.map { [$0] } ?? [] : waiting
    }

    /// The one of them to watch: the first that `ended` says has ended, else the first.
    public func awaitedVerifier(ended: (String) -> Bool = { _ in false }) -> String? {
        let waiting = awaitedVerifiers
        return waiting.first(where: ended) ?? waiting.first
    }

    /// Adds the lead's note, keeping the newest `keptNotes`.
    public mutating func keep(_ note: LeadNote) {
        notes = Array(((notes ?? []) + [note]).suffix(Self.keptNotes))
    }

    /// Abandoned: set so by the lead, or (older boards, and cleanup with force) cleaned up after failing without
    /// merging.
    public var isAbandoned: Bool { status == .abandoned || (status == .failed && worktree == nil && worker != nil) }

    /// It ran, or something of it is left: a worker was started on it, it has a branch or worktree on the board, or
    /// a merge. Why not, in words; nil when it never ran.
    public var ranBecause: String? {
        if merged != nil { return "it merged" }
        if worker != nil || startedAt != nil || (attempts ?? 0) > 0 { return "a worker was started on it" }
        if verifier != nil { return "a verifier was started on it" }
        if branch != nil || worktree != nil { return "it has a branch" }
        return nil
    }

    /// Rework rounds so far (0 on the first attempt).
    public var rework: Int { max(0, (attempts ?? 1) - 1) }

    public init(id: String = UUID().uuidString, slug: String, title: String, contract: LeadContract, status: Status = .planned) {
        self.id = id
        self.slug = slug
        self.title = title
        self.contract = contract
        self.status = status
        self.createdAt = Date().timeIntervalSince1970
    }
}

/// Something the lead asked you; the answer is steered back into it. The lead's questions are a queue it keeps up:
/// it can revise one (the question keeps its id, and its earlier wordings), withdraw one that no longer applies, and
/// say how much each matters.
public struct LeadQuestion: Codable, Equatable, Sendable, Identifiable {
    /// How much it matters: blocking holds up work (the Dock badge counts these), important is the default,
    /// whenever can wait.
    public enum Priority: String, Codable, Sendable, CaseIterable, Comparable {
        case blocking, important, whenever

        var rank: Int { Self.allCases.firstIndex(of: self)! }
        public static func < (a: Priority, b: Priority) -> Bool { a.rank < b.rank }
    }

    /// `autoDecided`: its timer ran out unanswered and the lead went ahead with its proposal.
    public enum State: String, Sendable { case open, answered, withdrawn, autoDecided }

    /// How long a proposal's timer runs when the lead doesn't say (minutes).
    public static let defaultDecideIn = 10

    /// A wording the question had before a revision, and why it changed.
    public struct Revision: Codable, Equatable, Sendable {
        /// The wording it replaced.
        public var text: String
        public var options: [String]
        /// Why the lead changed it.
        public var note: String
        /// When it changed.
        public var at: Double

        public init(text: String, options: [String], note: String, at: Double = Date().timeIntervalSince1970) {
            self.text = text
            self.options = options
            self.note = note
            self.at = at
        }
    }

    public var id: String
    /// The current wording.
    public var text: String
    public var options: [String]
    public var answer: String?
    public var askedAt: Double
    public var answeredAt: Double?
    // The fields below are optional: older boards have none of them.
    public var priority: Priority?
    /// Why the lead asks it now.
    public var whyNow: String?
    /// Its earlier wordings, oldest first: version n's wording is `revisions[n - 1]`, the current one is the last version.
    public var revisions: [Revision]?
    /// The version the user saw when answering.
    public var answeredVersion: Int?
    public var withdrawnAt: Double?
    public var withdrawReason: String?
    /// The answer the lead proposes (one of the options), with a timer: unless you answer or hold it by `decideBy`,
    /// the lead goes ahead with it.
    public var proposal: String?
    /// The timer's length in minutes, and when it runs out: an absolute time, so it survives a relaunch.
    public var decideIn: Int?
    public var decideBy: Double?
    /// You held it: the timer stopped, and it's an ordinary open question.
    public var heldAt: Double?
    /// When the timer ran out and the lead went ahead with its proposal.
    public var autoDecidedAt: Double?
    /// The task it's about (its slug), when the lead said: its wait on the user counts on that task's score.
    public var task: String?

    public init(id: String = UUID().uuidString, text: String, options: [String], priority: Priority? = nil, whyNow: String? = nil,
                proposal: String? = nil, decideIn: Int? = nil, at: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.text = text
        self.options = options
        self.priority = priority
        self.whyNow = whyNow
        self.askedAt = at
        if let proposal {
            self.proposal = proposal
            self.decideIn = decideIn ?? Self.defaultDecideIn
            decideBy = at + Double(self.decideIn!) * 60
        }
    }

    /// Old questions (no priority) count as important.
    public var rank: Priority { priority ?? .important }
    /// 1 for the first wording, one more for each revision.
    public var version: Int { (revisions?.count ?? 0) + 1 }
    /// The latest revision: when the current wording came, and why.
    public var lastRevision: Revision? { revisions?.last }
    /// A withdrawn question stays withdrawn, and an auto-decided one auto-decided, even if an answer came in late.
    public var state: State {
        withdrawnAt != nil ? .withdrawn : autoDecidedAt != nil ? .autoDecided : answer != nil ? .answered : .open
    }
    /// Its timer runs: it's open, with a proposal and a deadline, and you haven't held it.
    public var isCounting: Bool { isOpen && proposal != nil && decideBy != nil && heldAt == nil }
    /// "10 min": how long its timer ran (or runs).
    public var decideInText: String { "\(decideIn ?? Self.defaultDecideIn) min" }
    public var isOpen: Bool { state == .open }
    public var short: String { String(id.prefix(8)) }

    /// The wording of a version (1-based): an earlier one from the revisions, the latest the current text.
    public func wording(_ version: Int) -> (text: String, options: [String]) {
        if let revisions, version >= 1, version <= revisions.count { return (revisions[version - 1].text, revisions[version - 1].options) }
        return (text, options)
    }

    /// When it was last asked or reworded.
    public var updatedAt: Double { lastRevision?.at ?? askedAt }

    /// What the lead is told when the timer runs out: once, when the question turns auto-decided.
    public var autoDecisionMessage: String {
        "No answer in \(decideInText): going with your proposal ‘\(proposal ?? "")’\n"
            + "That's your question \(short) “\(text)”, now recorded as your decision. Go ahead with it; if the user answers "
            + "later you'll hear."
    }

    /// The decision recorded for it when its timer runs out.
    public var autoDecision: (decision: String, why: String) {
        ("\(text) → \(proposal ?? "")",
         "The lead proposed it with a \(decideInText) timer and the user didn't answer in time, so it went ahead (question \(short))."
            + (whyNow.map { " Why it was asked: \($0)" } ?? ""))
    }

    /// Why a question can't carry a timer, if it can't: a timer is for reversible choices only, never for one that
    /// holds up work (blocking), merges a sensitive path, deletes or discards work, or reaches outside the project
    /// (publishing, pushing, sending). The words of the question, its options and why-now are checked.
    public static func timerRefusal(text: String, options: [String], whyNow: String?, priority: Priority?) -> String? {
        if priority == .blocking {
            return "No timer on a blocking question: work waits on the user's say, so silence can't mean go. Ask it without proposal and decide_in."
        }
        let words = ([text, whyNow ?? ""] + options).joined(separator: "\n")
        func found(_ patterns: [String]) -> String? {
            for pattern in patterns {
                if let range = words.range(of: pattern, options: [.regularExpression, .caseInsensitive]) { return String(words[range]) }
            }
            return nil
        }
        let advice = "Ask it without proposal and decide_in: only reversible choices go ahead on silence."
        if let word = found([#"\bdelet\w*"#, #"\bdiscard\w*"#, #"\babandon\w*"#, #"\bwip(e|es|ed|ing)\b"#, #"\beras\w*"#,
                             #"\bpurg\w*"#, #"\bdestroy\w*"#, #"\bthrow\w* (it |them |\w+ )?away\b"#, #"\boverwrit\w*"#,
                             #"\bforce[- ]?push\w*"#, #"\bpush\w* --force\b"#, #"\breset --hard\b"#, #"\brm -\w*r"#,
                             #"\bdrop\w* (the |this |that |its |their )?(branch|work|commits?|changes|worktree|stash|table|database)"#]) {
            return "No timer on this one: it's about deleting or discarding work (“\(word)”). \(advice)"
        }
        let sensitive = #"(\.claude\b|CLAUDE(\.local)?\.md|AGENTS\.md|\.mcp\.json|\.github|\.env\b|secret|credential|password|token|private key|"#
            + #"\bauth\w*|permission|entitlement|signing|keychain|hooks?\b|settings\.json|sensitive)"#
        if words.range(of: #"\bmerg\w*"#, options: [.regularExpression, .caseInsensitive]) != nil, let word = found([sensitive]) {
            return "No timer on this one: it's about merging a sensitive path (“\(word)”). \(advice)"
        }
        if let word = found([#"\bpublish\w*"#, #"\brelease[sd]?\b"#, #"\breleasing\b"#, #"\bdeploy\w*"#, #"\bproduction\b"#, #"\bprod\b"#,
                             #"\bgit push\b"#, #"\bpush\w* (it |them |this |the \w+ )?(to )?(origin|remote|upstream|github|main)\b"#,
                             #"\bpull request"#, #"\bopen\w* a PR\b"#, #"\bupload\w*"#, #"\bsubmit\w* (it |this )?to\b"#,
                             #"\be-?mail\w*"#, #"\bslack\b"#, #"\btweet\w*"#, #"\bannounc\w*"#, #"\bpost\w* (it |this )?(to|on)\b"#,
                             #"\bsend\w* (it |this |an? \w+ )?to (the )?(users?|customers?|clients?|team|list|everyone)\b"#,
                             #"\bcustomers?\b"#, #"\bapp store\b"#, #"\bnotar\w*"#, #"\binvit\w*"#]) {
            return "No timer on this one: it reaches outside the project (“\(word)”). \(advice)"
        }
        return nil
    }
}

/// What happened to an answer (see `LeadBoard.answer`).
public enum LeadAnswerOutcome: Equatable, Sendable {
    /// Recorded; `saw` is the version the user answered, which is older than the current one when the lead revised
    /// the question meanwhile.
    case answered(LeadQuestion, saw: Int)
    /// The lead had withdrawn it; the answer is kept on it, the question stays withdrawn.
    case withdrawn(LeadQuestion)
    /// Its timer had run out and the lead went ahead with its proposal; the answer is kept on it, as a note.
    case afterAutoDecision(LeadQuestion)
    /// It was answered already (another window, the phone).
    case alreadyAnswered(LeadQuestion)
    case missing

    /// The message for the lead, if any: the answer tied to the wording the user saw.
    public func message(given text: String) -> String? {
        func clock(_ at: Double) -> String { LeadBoard.clock(at) }
        switch self {
        case .answered(let question, let saw) where saw < question.version:
            let seen = question.wording(saw)
            return "Answer to your question \(question.short), version \(saw) of \(question.version) (the user saw “\(seen.text)”, "
                + "before your revision at \(clock(question.lastRevision?.at ?? question.askedAt)) to “\(question.text)”): \(text)\n"
                + "Check it still answers the current wording; ask again (ask_user) if it doesn't."
        case .answered(let question, _):
            return "Answer to your question \(question.short) “\(question.text)”: \(text)"
        case .withdrawn(let question):
            return "The user answered your withdrawn question \(question.short) “\(question.text)” (withdrawn: \(question.withdrawReason ?? "no reason")) anyway: \(text)\n"
                + "Take it as a note; nothing waits on it."
        case .afterAutoDecision(let question):
            let proposal = question.proposal ?? ""
            let went = "The user answered your question \(question.short) “\(question.text)” after its timer ran out (no answer in "
                + "\(question.decideInText)) and you went ahead with your proposal ‘\(proposal)’"
            if text.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(proposal) == .orderedSame {
                return went + ": they agree (\(text)). Nothing to change."
            }
            return went + ". They would have chosen otherwise: \(text)\n"
                + "Take it as a note: weigh changing course (it was a reversible choice), and record_decision if you do."
        case .alreadyAnswered, .missing:
            return nil
        }
    }
}

/// A result the lead wants you to see.
public struct LeadUpdate: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    /// Image files (screenshots): post_update keeps copies in `.vibeswitcher/updates/<id>/` (`KeptImages`), so they're
    /// there after the worktree they were taken in is cleaned up, until the folder's cap drops the oldest.
    public var images: [String]
    public var at: Double

    public init(id: String = UUID().uuidString, title: String, body: String, images: [String] = []) {
        self.id = id
        self.title = title
        self.body = body
        self.images = images
        self.at = Date().timeIntervalSince1970
    }
}

/// Something a worker or verifier told the lead (done, blocked, a question, a verdict), kept so the lead's status lists
/// what came in even if the message itself never reached it.
public struct LeadReport: Codable, Equatable, Sendable {
    /// Who it's from ("worker add-b", "verifier add-b").
    public var about: String
    public var text: String
    public var at: Double

    public init(about: String, text: String, at: Double = Date().timeIntervalSince1970) {
        self.about = about
        self.text = text
        self.at = at
    }

    /// The task it's about: the slug after "worker " or "verifier ".
    public var task: String? {
        let parts = about.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, ["worker", "verifier"].contains(parts[0]) else { return nil }
        return String(parts[1])
    }
}

/// A test that failed a merge's test run and passed its rerun (`MergeRerun`): one entry in the board's flake ledger.
public struct LeadFlake: Codable, Equatable, Sendable {
    /// As `TestFailures` names it (`MergeRerun.unnamed` when the run named none).
    public var test: String
    /// The task whose merge it held up, and the commit that merge tested.
    public var task: String
    public var commit: String
    public var at: Double
    /// The task planned to fix it, on the flake that made it due (`LeadBoard.recordFlakes`).
    public var planned: String?

    public init(test: String, task: String, commit: String, at: Double, planned: String? = nil) {
        self.test = test
        self.task = task
        self.commit = commit
        self.at = at
        self.planned = planned
    }
}

public struct LeadBoard: Codable, Equatable, Sendable {
    /// The lead's session (host id) and agent pid, so answers and events can be steered into it.
    public var leadSession: String?
    public var leadPid: Int32?
    public var leadTTY: String?
    /// The branch the lead builds on and merges into: the one checked out when it first started here.
    public var baseBranch: String?
    public var tasks: [LeadTask] = []
    public var questions: [LeadQuestion] = []
    public var updates: [LeadUpdate] = []
    /// The latest reports for the lead, oldest first, and when its status last listed them. Optional: older boards
    /// have neither.
    public var reports: [LeadReport]?
    public var reportsSeenAt: Double?
    /// Records the lead removed (made by mistake, never ran), oldest first: kept for the record, shown and counted
    /// nowhere. Optional: older boards have none.
    public var removed: [LeadTask]?
    /// Each moment the board cleared after merges (see `BatchSummary`), oldest first, with its summary once written.
    /// Optional: older boards have none.
    public var allDone: [LeadAllDone]?
    /// The flake ledger: each test that failed a merge's test run and passed its rerun (`MergeRerun`), oldest first,
    /// at most `keptFlakes`. Optional: older boards have none.
    public var flakes: [LeadFlake]?

    public static let keptReports = 50
    public static let keptFlakes = 200
    /// A test that flakes `flakeLimit` times within `flakeWindow` becomes a task to fix it, once.
    public static let flakeLimit = 3
    public static let flakeWindow: Double = 7 * 86_400

    public init() {}

    public func task(_ id: String) -> LeadTask? { tasks.first { $0.id == id || $0.slug == id } }

    /// Keeps the witness's stalls (by task id) on the tasks, and clears the rest: a stall already noted for the same
    /// episode keeps when it was first noticed. Returns whether anything changed.
    @discardableResult
    public mutating func noteStalls(_ found: [String: LeadStall]) -> Bool {
        var changed = false
        for index in tasks.indices {
            let old = tasks[index].stall
            var new = found[tasks[index].id]
            if let old, let fresh = new, old.reason == fresh.reason, old.lastActivity == fresh.lastActivity,
               old.waitingSince == fresh.waitingSince {
                new = old
            }
            if new != old {
                tasks[index].stall = new
                changed = true
            }
        }
        return changed
    }

    /// The tasks whose workers are stalled now, the longest quiet first.
    public var stalled: [LeadTask] {
        tasks.filter { $0.stall != nil && $0.status == .running }.sorted { $0.stall!.lastActivity < $1.stall!.lastActivity }
    }
    public func taskIndex(_ id: String) -> Int? { tasks.firstIndex { $0.id == id || $0.slug == id } }

    // MARK: Flakes

    /// Records each of `tests` as having flaked in `task`'s merge (tested at `commit`). Returns those that flaked
    /// `flakeLimit` times within `flakeWindow` since a task was last planned for them, each with the merges it held up
    /// (oldest first): the caller plans one task each and marks it (`planned`), so a test makes one task, not one per
    /// flake. A flake recorded under `MergeRerun.unnamed` names no test, and plans nothing.
    public mutating func recordFlakes(_ tests: [String], task: String, commit: String, now: Double) -> [(test: String, merges: [String])] {
        var ledger = flakes ?? []
        var due: [(test: String, merges: [String])] = []
        for test in tests {
            ledger.append(LeadFlake(test: test, task: task, commit: commit, at: now))
            guard test != MergeRerun.unnamed else { continue }
            let since = ledger.last { $0.test == test && $0.planned != nil }?.at ?? -.infinity
            let counted = ledger.filter { $0.test == test && $0.at > since && now - $0.at <= Self.flakeWindow }
            if counted.count >= Self.flakeLimit { due.append((test, counted.map(\.task))) }
        }
        flakes = Array(ledger.suffix(Self.keptFlakes))
        return due
    }

    /// Marks `test`'s latest flake as the one `slug` was planned for.
    public mutating func notePlanned(_ slug: String, for test: String) {
        guard let index = flakes?.lastIndex(where: { $0.test == test }) else { return }
        flakes?[index].planned = slug
    }

    /// For status: the tests that flaked within `flakeWindow` of `now`, the most flakes first, each with the merges
    /// it held up and the task planned for it; nil when none did.
    public func flakeLine(now: Double) -> String? {
        let recent = (flakes ?? []).filter { now - $0.at <= Self.flakeWindow }
        guard !recent.isEmpty else { return nil }
        var order: [String] = []
        for flake in recent.reversed() where !order.contains(flake.test) { order.append(flake.test) }
        let counts = Dictionary(grouping: recent, by: \.test)
        order.sort { counts[$0]!.count > counts[$1]!.count }
        let shown = order.prefix(8).map { test -> String in
            let flakes = counts[test]!
            let planned = (self.flakes ?? []).last { $0.test == test && $0.planned != nil }?.planned
            return "\(test) ×\(flakes.count) (\(flakes.map(\.task).joined(separator: ", ")))" + (planned.map { " → task \($0)" } ?? "")
        }
        return "Flaky tests in the last \(Int(Self.flakeWindow / 86_400)) days (\(recent.count) flake\(recent.count == 1 ? "" : "s"): each failed a merge's test run, passed its rerun, and the merge went ahead; "
            + "\(Self.flakeLimit) of one test become a task to fix it): " + shown.joined(separator: "; ") + (order.count > 8 ? "; …" : "") + "."
    }

    // MARK: Questions

    /// An open question older than this (since asked or last revised) is flagged for the lead to re-check.
    public static let staleQuestion: Double = 3_600

    /// The open questions, most important first, then oldest first.
    public var openQuestions: [LeadQuestion] {
        questions.filter(\.isOpen).sorted { ($0.rank, $0.askedAt) < ($1.rank, $1.askedAt) }
    }

    /// How long a withdrawn or auto-decided question stays in the stack, collapsed, so you see it went and why.
    public static let withdrawnShown: Double = 30 * 60

    /// The "Questions for you" stack: the open questions in order, then the ones withdrawn or auto-decided lately
    /// (newest first) as collapsed lines.
    public func questionStack(now: Double = Date().timeIntervalSince1970) -> [LeadQuestion] {
        func closed(_ question: LeadQuestion) -> Double? {
            switch question.state {
            case .withdrawn: return question.withdrawnAt
            case .autoDecided: return question.autoDecidedAt
            case .open, .answered: return nil
            }
        }
        let lately = questions.filter { closed($0).map { now - $0 < Self.withdrawnShown } ?? false }
        return openQuestions + lately.sorted { (closed($0) ?? 0) > (closed($1) ?? 0) }
    }

    /// Open questions that hold up work: what the Dock badge counts.
    public var blockingQuestions: Int { questions.filter { $0.isOpen && $0.rank == .blocking }.count }

    /// The question with this id, or the one id it begins with (the lead is shown the first 8 characters).
    public func questionIndex(_ id: String) throws -> Int {
        let wanted = id.trimmingCharacters(in: .whitespaces).uppercased()
        if let exact = questions.firstIndex(where: { $0.id.uppercased() == wanted }) { return exact }
        let matches = questions.indices.filter { !wanted.isEmpty && questions[$0].id.uppercased().hasPrefix(wanted) }
        guard matches.count == 1, let index = matches.first else {
            throw BoardError(text: matches.isEmpty ? "No question \(id) on the board. The questions tool lists them."
                                                  : "\(id) begins \(matches.count) questions' ids; give more of it.")
        }
        return index
    }

    /// A `proposal` starts its timer: `decideIn` minutes (10 when nil) from `at`.
    @discardableResult
    public mutating func ask(_ text: String, options: [String], priority: LeadQuestion.Priority?, whyNow: String?,
                             proposal: String? = nil, decideIn: Int? = nil, task: String? = nil, at: Double = Date().timeIntervalSince1970) -> LeadQuestion {
        var question = LeadQuestion(text: text, options: options, priority: priority, whyNow: whyNow, proposal: proposal, decideIn: decideIn, at: at)
        question.task = task
        questions.append(question)
        return question
    }

    /// Rewords an open question (text, options, or both), keeping its id and the wording it replaces.
    @discardableResult
    public mutating func revise(_ id: String, text: String?, options: [String]?, note: String,
                                at: Double = Date().timeIntervalSince1970) throws -> LeadQuestion {
        let index = try questionIndex(id)
        var question = questions[index]
        guard question.isOpen else { throw BoardError(text: Self.closed(question)) }
        let newText = text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? question.text
        let newOptions = options ?? question.options
        guard newText != question.text || newOptions != question.options else {
            throw BoardError(text: "That's the wording it has already; nothing changed.")
        }
        question.revisions = (question.revisions ?? []) + [LeadQuestion.Revision(text: question.text, options: question.options, note: note, at: at)]
        question.text = newText
        question.options = newOptions
        // A running timer starts again, so the new wording gets its full time; when the proposal is no longer an
        // option, or the new wording is one no timer may carry (`timerRefusal`), it becomes an ordinary question.
        if question.isCounting {
            if let proposal = question.proposal, newOptions.contains(proposal),
               LeadQuestion.timerRefusal(text: newText, options: newOptions, whyNow: question.whyNow, priority: question.priority) == nil {
                question.decideBy = at + Double(question.decideIn ?? LeadQuestion.defaultDecideIn) * 60
            } else {
                question.proposal = nil
                question.decideBy = nil
            }
        }
        questions[index] = question
        return question
    }

    /// You hold a question with a timer: the timer stops and it waits for your answer like any other.
    @discardableResult
    public mutating func hold(_ id: String, at: Double = Date().timeIntervalSince1970) throws -> LeadQuestion {
        let index = try questionIndex(id)
        guard questions[index].isOpen else { throw BoardError(text: Self.closed(questions[index])) }
        guard questions[index].isCounting else { throw BoardError(text: "Question \(questions[index].short) has no timer running.") }
        questions[index].heldAt = at
        return questions[index]
    }

    /// The questions whose timer runs out by `now`, now auto-decided: the lead goes ahead with each proposal.
    /// Each turns auto-decided once; a later call finds nothing more to do for it.
    public mutating func expire(now: Double = Date().timeIntervalSince1970) -> [LeadQuestion] {
        var expired: [LeadQuestion] = []
        for index in questions.indices where questions[index].isCounting && (questions[index].decideBy ?? .infinity) <= now {
            questions[index].autoDecidedAt = now
            expired.append(questions[index])
        }
        return expired
    }

    /// Some timer has run out by `now` (`expire` would change the board).
    public func hasExpired(now: Double = Date().timeIntervalSince1970) -> Bool {
        questions.contains { $0.isCounting && ($0.decideBy ?? .infinity) <= now }
    }

    @discardableResult
    public mutating func withdraw(_ id: String, reason: String, at: Double = Date().timeIntervalSince1970) throws -> LeadQuestion {
        let index = try questionIndex(id)
        guard questions[index].isOpen else { throw BoardError(text: Self.closed(questions[index])) }
        questions[index].withdrawnAt = at
        questions[index].withdrawReason = reason
        return questions[index]
    }

    /// The user's answer to the version of the question they saw. It's tied to that version, so when the lead
    /// revised it meanwhile the lead learns which wording was answered; a withdrawn question keeps the answer but
    /// stays withdrawn.
    public mutating func answer(_ id: String, with text: String, saw version: Int, at: Double = Date().timeIntervalSince1970) -> LeadAnswerOutcome {
        guard let index = questions.firstIndex(where: { $0.id == id }) else { return .missing }
        switch questions[index].state {
        case .answered: return .alreadyAnswered(questions[index])
        case .autoDecided where questions[index].answer != nil: return .alreadyAnswered(questions[index])
        case .open, .withdrawn, .autoDecided: break
        }
        let saw = min(max(version, 1), questions[index].version)
        questions[index].answer = text
        questions[index].answeredAt = at
        questions[index].answeredVersion = saw
        switch questions[index].state {
        case .withdrawn: return .withdrawn(questions[index])
        case .autoDecided: return .afterAutoDecision(questions[index])
        case .open, .answered: return .answered(questions[index], saw: saw)
        }
    }

    private static func closed(_ question: LeadQuestion) -> String {
        switch question.state {
        case .withdrawn: return "Question \(question.short) is withdrawn already (\(question.withdrawReason ?? "no reason"))."
        case .answered: return "The user answered question \(question.short) already: \(question.answer ?? ""). Ask a new one if you need more."
        case .autoDecided: return "Question \(question.short) is decided already: its timer ran out and you went ahead with ‘\(question.proposal ?? "")’."
        case .open: return ""
        }
    }

    /// "17:42": the local time of day.
    public static func clock(_ at: Double) -> String {
        clockFormatter.string(from: Date(timeIntervalSince1970: at))
    }

    /// Made once: the Team view draws a time on every row it shows, and making a formatter costs more than using one.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

public struct BoardError: Error, CustomStringConvertible {
    public var text: String
    public var description: String { text }
}

/// An exclusive lock on a file, across processes, taken only if free.
public final class FileLock {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    public static func attempt(_ path: String) -> FileLock? {
        try? VibePaths.ensurePrivate(URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true))
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return FileLock(fd: fd)
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

/// The board on disk: `<repo>/.vibeswitcher/board.json`; the progress log and decisions are in the workflow's
/// `records_dir` (committed by `LeadRecords`), or next to the board when it sets none.
public final class BoardStore: @unchecked Sendable {
    public let root: String
    public var folder: String { (root as NSString).appendingPathComponent(".vibeswitcher") }
    var file: String { (folder as NSString).appendingPathComponent("board.json") }
    private let local = NSLock()

    public init(root: String) { self.root = root }

    /// The board, or an empty one when there's none or it can't be read (for showing it).
    public func load() -> LeadBoard { (try? read()) ?? LeadBoard() }

    /// Only the lead the board names (`leadPid`, `leadTTY`, `leadSession`), the rest left out: what the app checks on
    /// the main thread (whom to deliver to) decodes three fields, not most of a MB of tasks and reports. A board that
    /// can't be read names none, as `load()` gives.
    public func loadLead() -> LeadBoard {
        var board = LeadBoard()
        guard let data = FileManager.default.contents(atPath: file),
              let named = try? JSONDecoder().decode(NamedLead.self, from: data) else { return board }
        board.leadPid = named.leadPid
        board.leadTTY = named.leadTTY
        board.leadSession = named.leadSession
        return board
    }

    private struct NamedLead: Decodable {
        var leadPid: Int32?
        var leadTTY: String?
        var leadSession: String?
    }

    /// The board; throws when the file is there but doesn't read (a hand edit, a newer version), so nothing
    /// writes an empty board over it.
    public func read() throws -> LeadBoard {
        if Thread.isMainThread { Self.noteReadOnMainThread() }
        guard let data = FileManager.default.contents(atPath: file) else { return LeadBoard() }
        do {
            return try JSONDecoder().decode(LeadBoard.self, from: data)
        } catch {
            throw BoardError(text: "\(file) doesn't read as a board (\(error)); fix or move it, nothing was changed.")
        }
    }

    /// How many times a board was read on the main thread, in this process. The app reads none there: a day's board
    /// is most of a MB of JSON, and decoding it there froze the window (`--board-bench` checks).
    public static var readsOnMainThread: Int {
        counter.lock()
        defer { counter.unlock() }
        return mainThreadReads
    }

    private static let counter = NSLock()
    nonisolated(unsafe) private static var mainThreadReads = 0

    private static func noteReadOnMainThread() {
        counter.lock()
        mainThreadReads += 1
        counter.unlock()
    }

    /// Reads, changes and writes the board under a lock (other processes too), atomically.
    @discardableResult
    public func update<T>(_ change: (inout LeadBoard) throws -> T) throws -> T {
        try ensureFolder()
        local.lock()
        defer { local.unlock() }
        let fd = open(file + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        flock(fd, LOCK_EX)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        var board = try read()
        let before = Dictionary(board.tasks.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        let result = try change(&board)
        // Each status change is stamped, whoever made it: how long a task has been where it is.
        let now = Date().timeIntervalSince1970
        for index in board.tasks.indices where before[board.tasks[index].id] != board.tasks[index].status {
            board.tasks[index].since = before[board.tasks[index].id] == nil ? board.tasks[index].createdAt : now
        }
        board.refreshScores(now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try VibePaths.writePrivate(try encoder.encode(board), to: URL(fileURLWithPath: file))
        return result
    }

    public func appendProgress(_ line: String) throws {
        try append("- \(Self.stamp()) \(line)\n", to: "progress.md", header: "# Progress\n\n")
    }

    /// Runs out the timers due by `now`. Each such question turns auto-decided, is recorded as the lead's decision
    /// (`appendDecision`, as record_decision writes it) and goes into the lead's reports (its status lists it even if
    /// the message never reaches it), all under the board's lock: it happens once, however many windows watch the
    /// board and across relaunches. Returns each one with the message for the lead.
    public func runTimers(now: Double = Date().timeIntervalSince1970) throws -> [(question: LeadQuestion, message: String)] {
        // Checked first without writing: this runs every few seconds.
        guard load().hasExpired(now: now) else { return [] }
        return try update { board in
            let expired = board.expire(now: now)
            for question in expired {
                try appendDecision(question.autoDecision.decision, why: question.autoDecision.why)
                board.reports = ((board.reports ?? []) + [LeadReport(about: "timer", text: question.autoDecisionMessage, at: now)])
                    .suffix(LeadBoard.keptReports)
            }
            return expired.map { ($0, $0.autoDecisionMessage) }
        }
    }

    /// A decision under a `## <date and time> <decision>` heading (one line), its reason below.
    public func appendDecision(_ decision: String, why: String) throws {
        let heading = decision.split(whereSeparator: \.isNewline).joined(separator: " ")
        try append("## \(LeadDecision.stamp(Date())) \(heading)\n\n\(why)\n\n", to: "decisions.md", header: "# Decisions\n\n")
    }

    /// An incident under a `## <date and time> <what>` heading (one line), its evidence, the task it happened in and
    /// the task that turns it into a check below (`record_incident`).
    public func appendIncident(_ what: String, evidence: String, task: String?, check: String) throws {
        let heading = what.split(whereSeparator: \.isNewline).joined(separator: " ")
        let about = task.map { "Task: \($0)\n" } ?? ""
        try append("## \(LeadDecision.stamp(Date())) \(heading)\n\nEvidence: \(evidence)\n\n\(about)Check: task \(check) turns it into a check that runs before merge.\n\n",
                   to: "incidents.md", header: "# Incidents\n\n")
    }

    /// The lead's decisions, oldest first. Everything that shows them reads them here, so where they're kept can
    /// change in this one place.
    public func decisions() -> [LeadDecision] {
        // Not moved yet (nothing was written since records_dir was set): the old file's, merged in as a move would.
        let local = (folder as NSString).appendingPathComponent("decisions.md")
        let path = recordPath("decisions.md")
        let text = try? String(contentsOfFile: path, encoding: .utf8)
        guard path != local, let old = try? String(contentsOfFile: local, encoding: .utf8) else { return text.map(LeadDecision.parse) ?? [] }
        return LeadDecision.parse(LeadRecords.merged(old: old, into: text, kind: .decisions))
    }

    /// Sets a repository up for a lead: the `.vibeswitcher` folder, kept out of git, with the workflow notes (a
    /// template the first time; yours are never overwritten). Returns the workflow file's path.
    @discardableResult
    public func prepare() throws -> String {
        try ensureFolder()
        try ensureExcluded()
        // The lead's branch: what you're on now, kept for the next leads here (switching branches later doesn't
        // move it; `base_branch:` in the workflow does).
        if try read().baseBranch == nil {
            let branch = Worktrees.currentBranch(root: root) ?? Worktrees.mainBranch(root: root)
            try update { if $0.baseBranch == nil { $0.baseBranch = branch } }
        }
        let workflow = (folder as NSString).appendingPathComponent("workflow.md")
        if !FileManager.default.fileExists(atPath: workflow) {
            try LeadWorkflow.write(Data(LeadWorkflow.template.utf8), to: workflow)
        }
        return workflow
    }

    /// `.vibeswitcher/` in `.git/info/exclude`: ignored without changing the repo's own files.
    public func ensureExcluded() throws {
        // Where git keeps it: `.git/info/exclude`, or the main repository's when `.git` is a file (a worktree).
        let asked = Git.run(["rev-parse", "--git-path", "info/exclude"], in: root)
        let exclude = asked.ok && !asked.output.isEmpty
            ? (asked.output.hasPrefix("/") ? asked.output : (root as NSString).appendingPathComponent(asked.output))
            : (root as NSString).appendingPathComponent(".git/info/exclude")
        let current = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
        guard !current.components(separatedBy: "\n").contains("/.vibeswitcher/") else { return }
        try FileManager.default.createDirectory(atPath: (exclude as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let line = (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + "/.vibeswitcher/\n"
        try (current + line).write(toFile: exclude, atomically: true, encoding: .utf8)
    }

    /// The `.vibeswitcher` folder, private to you (0700); the first time this version writes in it, what older ones left
    /// there is made private too (`PrivateRepair.project`).
    private func ensureFolder() throws {
        try VibePaths.ensurePrivate(URL(fileURLWithPath: folder, isDirectory: true))
        PrivateRepair.project(folder)
    }

    /// Appends to a record (redacted), in `records_dir` when the workflow sets one, moving the old local file's entries
    /// there first (`LeadRecords.migrate`); under the records' lock, which the commit takes too.
    private func append(_ text: String, to name: String, header: String) throws {
        try ensureFolder()
        try withRecordsLock {
            try LeadRecords.migrate(self)
            let path = recordPath(name)
            if !FileManager.default.fileExists(atPath: path) { try LeadRecords.write(header, to: path, in: self) }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(Redaction.secrets(in: text).utf8))
        }
    }

    /// The folder the workflow keeps the decision and progress logs in, relative to the repository (`records_dir:`);
    /// nil when they're kept in `.vibeswitcher`.
    public var recordsDir: String? {
        LeadWorkflow.load(from: (folder as NSString).appendingPathComponent("workflow.md")).recordsDir
    }

    /// Where `decisions.md` or `progress.md` is kept: in `records_dir`, else in `.vibeswitcher`. Everything that reads
    /// or writes them finds them here.
    public func recordPath(_ name: String) -> String {
        guard let dir = recordsDir else { return (folder as NSString).appendingPathComponent(name) }
        return ((root as NSString).appendingPathComponent(dir) as NSString).appendingPathComponent(name)
    }

    /// Replaces a record's whole text (the benches' made-up decisions), where `recordPath` keeps it.
    public func replaceRecord(_ name: String, with text: String) throws {
        try LeadRecords.write(text, to: recordPath(name), in: self)
    }

    /// Runs `body` holding the records' lock (across processes: the app's timers write decisions too).
    func withRecordsLock<T>(_ body: () throws -> T) throws -> T {
        try ensureFolder()
        let fd = open((folder as NSString).appendingPathComponent("records.lock"), O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        flock(fd, LOCK_EX)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return try body()
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}

/// A decision the lead recorded (`record_decision`), as `decisions.md` has it.
public struct LeadDecision: Equatable, Sendable, Identifiable {
    public var at: Double
    public var text: String
    public var why: String
    public var id: String { "\(at)|\(text)" }

    public init(at: Double, text: String, why: String) {
        self.at = at
        self.text = text
        self.why = why
    }

    /// "2026-10-17 21:27:05", local time (older entries have no seconds).
    static func stamp(_ date: Date) -> String { formatter("yyyy-MM-dd HH:mm:ss").string(from: date) }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// The decisions in a `decisions.md`: each `## <stamp> <decision>` heading and the text under it.
    public static func parse(_ markdown: String) -> [LeadDecision] {
        let seconds = formatter("yyyy-MM-dd HH:mm:ss"), minutes = formatter("yyyy-MM-dd HH:mm")
        var decisions: [LeadDecision] = []
        var why: [Substring] = []
        func close() {
            guard !decisions.isEmpty else { return }
            decisions[decisions.count - 1].why = why.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            why = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("## ") else {
                why.append(line)
                continue
            }
            let words = line.dropFirst(3).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard words.count >= 2 else { continue }
            let time = String(words[1])
            guard let date = seconds.date(from: "\(words[0]) \(time)") ?? minutes.date(from: "\(words[0]) \(time)") else { continue }
            close()
            why = []
            let text = words.count > 2 ? String(words[2]).trimmingCharacters(in: .whitespaces) : ""
            decisions.append(LeadDecision(at: date.timeIntervalSince1970, text: text, why: ""))
        }
        close()
        return decisions
    }
}

/// Branch- and folder-safe names for tasks.
public enum Slug {
    public static func make(_ title: String, taken: Set<String>) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var words: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        var base = ""
        // The first few words, short enough for a branch name.
        for (index, word) in words.enumerated() {
            let next = base.isEmpty ? String(word.prefix(24)) : base + "-" + word
            guard index < 4, next.count <= 24 else { break }
            base = next
        }
        if base.isEmpty { base = "task" }
        var slug = base
        var number = 2
        while taken.contains(slug) {
            slug = "\(base)-\(number)"
            number += 1
        }
        return slug
    }
}
