import Foundation

/// Review levels (`LeadTask.Review`) and the worker's "done": what lets a `review: none` task merge with no verdict.
/// Kept in the vault, like verdicts: board.json is in the project's `.vibeswitcher` folder, which every session of the
/// team can write, so a worker that set its own task to none there, or wrote itself a "done" report, would get its work
/// merged unchecked. merge goes by the stricter of the board's level and this one, which only the lead sets, and by the
/// commit the task's own worker last reported done on.
extension LeadVault {
    /// What the vault knows of a task for a merge without an audit.
    public struct Unaudited: Equatable, Sendable {
        /// The lead's level; none when it set none (or nothing).
        public var review: LeadTask.Review
        /// The commit its worker last reported done on; nil when its last report wasn't done, or there was none.
        public var reported: String?
        /// The evidence it gave with that done; nil for a done from before evidence was asked for.
        public var evidence: LeadDoneEvidence? = nil
    }

    /// The lead sets the task's review level.
    public func setReview(_ review: LeadTask.Review, root: String, task: String) throws {
        _ = try call(.setReview(root: root, task: task, review: review))
    }

    /// The task's own worker reported done on `commit` (nil: its report wasn't done), with its evidence.
    public func reportDone(root: String, task: String, commit: String?, evidence: LeadDoneEvidence? = nil) throws {
        _ = try call(.reportDone(root: root, task: task, commit: commit, evidence: evidence))
    }

    /// The task's review level and its worker's last "done", as the vault has them.
    public func unaudited(root: String, task: String) throws -> Unaudited {
        guard case .unaudited(let review, let reported, let evidence) = try call(.unaudited(root: root, task: task)) else { throw Self.unexpected }
        return Unaudited(review: review ?? .none, reported: reported, evidence: evidence)
    }
}

/// A worker's proof of its done (Lead Process v3 phase 2, 2026-10-25): for each acceptance check, how it was checked
/// and what that gave, and what a blind check (a fresh subagent given only the contract and the diff) found and what
/// the worker did about each item. Workers grade their own work leniently; this makes the report show its work.
/// Kept in the vault with the done it came with, so the worker can't change it afterwards through board.json.
public struct LeadDoneEvidence: Codable, Equatable, Sendable {
    public struct Check: Codable, Equatable, Sendable {
        /// The acceptance check it covers: its number (1-based) or its text.
        public var check: String
        /// The command and what it printed, the test's name, or what was looked at.
        public var how: String
        public var result: String
        public var screenshots: [String]?

        public init(check: String, how: String, result: String, screenshots: [String]? = nil) {
            self.check = check
            self.how = how
            self.result = result
            self.screenshots = screenshots
        }
    }

    public var checks: [Check]
    /// What the blind check found, and what was done about each item.
    public var blindCheck: String

    public init(checks: [Check], blindCheck: String) {
        self.checks = checks
        self.blindCheck = blindCheck
    }

    /// The acceptance checks (1-based number, text) no entry covers. A contract with none needs one entry at least
    /// (its only check is its goal), else nothing is missing.
    public func uncovered(_ acceptance: [String]) -> [(number: Int, text: String)] {
        guard !acceptance.isEmpty else { return checks.isEmpty ? [(1, "the task's goal (it has no acceptance checks)")] : [] }
        return acceptance.enumerated().compactMap { index, text in
            checks.contains { Self.covers($0.check, number: index + 1, text: text) } ? nil : (index + 1, text)
        }
    }

    /// Whether an entry's `check` names acceptance check `number`: by its number ("2", "#2", "check 2", "2. its text")
    /// or by its text (the same words, the start of them, or quoted in full), case and punctuation aside. Words match
    /// whole: a check "a" isn't in "passed".
    static func covers(_ entry: String, number: Int, text: String) -> Bool {
        let said = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if Self.number(said) == number { return true }
        let words = { (text: String) in text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        let entry = words(said), check = words(text)
        guard !entry.isEmpty, !check.isEmpty else { return false }
        // The check's words in a row in the entry's (quoted in full), or the entry's the check's first ones.
        let quoted = entry.count >= check.count && (0...(entry.count - check.count)).contains { Array(entry[$0..<($0 + check.count)]) == check }
        return quoted || (entry.joined(separator: " ").count >= 20 && check.starts(with: entry))
    }

    /// The number an entry names a check by: "2", "#2", "check 2", "AC 2", "2. its text", "2) …", "2: …".
    static func number(_ said: Substring) -> Int? {
        var rest = said
        for prefix in ["check", "ac"] where rest.hasPrefix(prefix) { rest = rest.dropFirst(prefix.count).drop(while: \.isWhitespace) }
        if rest.hasPrefix("#") { rest = rest.dropFirst() }
        let digits = rest.prefix(while: \.isASCII).prefix(while: \.isNumber)
        let after = rest.dropFirst(digits.count)
        guard !digits.isEmpty, after.isEmpty || after.first.map({ ".):".contains($0) }) == true else { return nil }
        return Int(digits)
    }

    static func number(_ said: String) -> Int? { number(Substring(said)) }

    /// One line per check and the blind check's, as board(task) and the verifier show them.
    public var lines: [String] {
        checks.map { entry in
            let shots = entry.screenshots.map { $0.isEmpty ? "" : " (screenshots: \($0.joined(separator: ", ")))" } ?? ""
            return "- \(entry.check): \(entry.how) → \(entry.result)\(shots)"
        } + ["Blind check: \(blindCheck)"]
    }

    /// In a sentence for merge's result: each check's result, then the blind check's, cut at `limit`.
    public func brief(limit: Int = 400) -> String {
        let text = checks.map { "\($0.check): \($0.result)" }.joined(separator: "; ") + ". Blind check: \(blindCheck)"
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }
}

/// How the verifier's own run of the tests went, as it said in submit_audit. Kept on the verdict: a verdict that
/// failed only on findings the lead dismissed merges only when its tests passed.
extension LeadVault {
    public enum TestRun: String, Codable, CaseIterable, Sendable {
        case passed, failed
        case notRun = "not_run"
    }
}

extension LeadVault.Verdict {
    /// The lead's dismissals that are all that kept this verdict from passing: it's complete, its verifier's tests
    /// passed, and every Important finding its audit left open the lead has dismissed since, on this audit's ledger
    /// (2026-10-24: a verifier found the work correct with every test passing, marked it violation only for edits outside
    /// the boundaries the worker had listed as routine calls, and the lead's dismissing all three still left merge
    /// demanding a whole new verifier run). Nil when it doesn't stand that way: it passes by itself, it's incomplete or
    /// blocked, its tests failed or weren't said to pass, the ledger is another audit's, an Important finding is still
    /// open, or the lead dismissed none (nothing the lead looked at explains the failure).
    public func dismissed(in ledger: LeadAuditLedger?) -> [LeadFinding]? {
        guard !passes, completion == .complete, tests == .passed, let ledger, ledger.commit == commit, ledger.blocking.isEmpty else { return nil }
        let dismissed = ledger.findings.filter {
            $0.severity == .important && $0.status == .dismissed && $0.closedBy == "lead" && $0.closed == ledger.rounds
        }
        return dismissed.isEmpty ? nil : dismissed
    }
}
