import Foundation

/// How a task went, in the numbers that say whether the lead saves the user time without breaking things: the audits
/// it took to pass and the Important findings they raised, the user's questions about it and how long they waited on
/// the user, whether it merged without tests, and whether the base later reverted its merge. The board keeps each
/// task's (`LeadTask.score`, refreshed with every board change: `LeadBoard.refreshScores`); the Team tab's scorecard
/// sums them up (`LeadScorecard`).
public struct LeadTaskScore: Codable, Equatable, Sendable {
    /// Audits recorded up to the one that passed it (that one included); nil while none has.
    public var roundsToPass: Int?
    /// Audits recorded so far.
    public var rounds: Int
    /// Important findings its audits raised and most finders confirmed (open, fixed or dismissed since).
    public var importantFindings: Int
    /// The lead's questions to the user about it (ask_user with task), and how many the user answered (a timer
    /// running out isn't an answer).
    public var questions: Int
    public var answers: Int
    /// Seconds those questions waited on the user: each from when it was asked until it was answered, withdrawn or
    /// decided by its timer; an open one, until `asOf`.
    public var waitingOnUser: Double
    /// It merged with no test_command run; nil while it isn't merged.
    public var mergedWithoutTests: Bool?
    /// It merged with no audit (review none: its worker's report and the merge's own test run); nil while it isn't
    /// merged, and in scores counted before review levels.
    public var mergedUnaudited: Bool?
    /// Its review level (none, or audit); nil in scores counted before review levels.
    public var review: LeadTask.Review?
    /// The base's commit that reverted its merge (all or part of it), once one did.
    public var revertedBy: String?
    /// When these were counted.
    public var asOf: Double

    public init(roundsToPass: Int? = nil, rounds: Int = 0, importantFindings: Int = 0, questions: Int = 0, answers: Int = 0,
                waitingOnUser: Double = 0, mergedWithoutTests: Bool? = nil, mergedUnaudited: Bool? = nil, review: LeadTask.Review? = nil,
                revertedBy: String? = nil, asOf: Double = Date().timeIntervalSince1970) {
        self.roundsToPass = roundsToPass
        self.rounds = rounds
        self.importantFindings = importantFindings
        self.questions = questions
        self.answers = answers
        self.waitingOnUser = waitingOnUser
        self.mergedWithoutTests = mergedWithoutTests
        self.mergedUnaudited = mergedUnaudited
        self.review = review
        self.revertedBy = revertedBy
        self.asOf = asOf
    }

    /// "Passed on audit 2 · 1 Important finding · 1 question to you (answered), 4 min waiting on you · reverted by
    /// abc12345": what the Team tab shows under an opened task.
    public var line: String {
        var parts: [String] = []
        if mergedUnaudited == true {
            parts.append("Merged with no audit (review none)")
        } else if review == LeadTask.Review.none, rounds == 0 {
            // Its worker owns it through merge: no audit to count.
            parts.append("Review none: no audit")
        } else {
            if review == .audit { parts.append("Review audit") }
            parts.append(roundsToPass.map { "Passed on audit \($0)" } ?? (rounds == 0 ? "Not audited yet" : "\(rounds) audit\(rounds == 1 ? "" : "s"), not passed yet"))
            parts.append("\(importantFindings) Important finding\(importantFindings == 1 ? "" : "s")")
        }
        if questions > 0 {
            let answered = answers == questions ? (questions == 1 ? "answered" : "all answered") : "\(answers) answered"
            parts.append("\(questions) question\(questions == 1 ? "" : "s") to you (\(answered)), \(LeadScorecard.minutes(waitingOnUser / 60)) min waiting on you")
        }
        if mergedWithoutTests == true { parts.append("merged without tests") }
        if let revertedBy { parts.append("reverted by \(revertedBy.prefix(8))") }
        return parts.joined(separator: " · ")
    }

    /// `task`'s score from the board's `questions` (those asked about it), as of `now`.
    public init(_ task: LeadTask, questions: [LeadQuestion], now: Double = Date().timeIntervalSince1970) {
        let audits = task.audits
        let rounds = audits?.rounds ?? 0
        // Merged: its last audit passed it (merge takes nothing less). Else passed once its last audit passed and no
        // Important finding is open.
        let passed = task.merged != nil || (audits?.passed == true && audits?.blocking.isEmpty == true)
        // Folded into another task (its work merges there) or abandoned: nothing here passes or merges (with tests or
        // without).
        let folded = [.folded, .abandoned].contains(task.status)
        let asked = questions.filter { $0.task == task.slug }
        self.init(roundsToPass: passed && rounds > 0 && !folded ? rounds : nil, rounds: rounds,
                  importantFindings: audits?.findings.filter { $0.severity == .important && $0.status != .unconfirmed }.count ?? 0,
                  questions: asked.count, answers: asked.filter { $0.answer != nil }.count,
                  waitingOnUser: asked.reduce(0) { $0 + $1.waitingOnUser(now: now) },
                  mergedWithoutTests: folded ? nil : task.merged.map { !$0.tested }, mergedUnaudited: folded ? nil : task.merged.map(\.unaudited),
                  review: task.reviewLevel, revertedBy: folded ? nil : task.merged?.revertedBy, asOf: now)
    }
}

extension LeadQuestion {
    /// Seconds it waited on the user: from when it was asked until the first of its answer, its withdrawal and its
    /// timer's decision; an open one (held or not), until `now`.
    public func waitingOnUser(now: Double = Date().timeIntervalSince1970) -> Double {
        let ends = [answeredAt, withdrawnAt, autoDecidedAt].compactMap { $0 }
        return max(0, (ends.min() ?? (isOpen ? now : askedAt)) - askedAt)
    }
}

extension LeadBoard {
    /// Each task's score counted again as of `now` (`BoardStore.update` does it with every change).
    public mutating func refreshScores(now: Double = Date().timeIntervalSince1970) {
        for index in tasks.indices {
            tasks[index].score = LeadTaskScore(tasks[index], questions: questions, now: now)
        }
    }
}

/// The lead's scorecard over the board: mean audit rounds to pass and the share passing on the first audit (of the
/// merged tasks whose audits were counted), the user's minutes per merged task (every question's wait on the user,
/// about a task or not, over the merged tasks), merges the base later reverted, and merges without tests; tasks folded
/// into another or abandoned count nowhere in it. The Team
/// tab shows it; the lead's board tool says it in a line.
public struct LeadScorecard: Equatable, Sendable {
    public var merged: Int
    /// Merged tasks whose audit rounds are known (older boards kept none).
    public var counted: Int
    public var meanRoundsToPass: Double?
    /// 0…1.
    public var firstAuditPassRate: Double?
    public var userMinutesPerMergedTask: Double?
    /// Every question's wait on the user, in minutes.
    public var userMinutes: Double
    public var reverts: Int
    public var mergedWithoutTests: Int
    /// Merged with no audit (review none): not in the audit numbers, which are the audited merges'.
    public var mergedUnaudited: Int

    public init(_ board: LeadBoard, now: Double = Date().timeIntervalSince1970) {
        // A folded task isn't counted (its work merged with the task that carried it; that one's rounds count), nor
        // an abandoned one.
        let merged = board.tasks.filter { $0.merged != nil && ![.folded, .abandoned].contains($0.status) }
        let scores = merged.map { LeadTaskScore($0, questions: board.questions, now: now) }
        let rounds = scores.compactMap(\.roundsToPass)
        self.merged = merged.count
        counted = rounds.count
        meanRoundsToPass = rounds.isEmpty ? nil : Double(rounds.reduce(0, +)) / Double(rounds.count)
        firstAuditPassRate = rounds.isEmpty ? nil : Double(rounds.filter { $0 == 1 }.count) / Double(rounds.count)
        userMinutes = board.questions.reduce(0) { $0 + $1.waitingOnUser(now: now) } / 60
        userMinutesPerMergedTask = merged.isEmpty ? nil : userMinutes / Double(merged.count)
        reverts = scores.filter { $0.revertedBy != nil }.count
        mergedWithoutTests = scores.filter { $0.mergedWithoutTests == true }.count
        mergedUnaudited = scores.filter { $0.mergedUnaudited == true }.count
    }

    /// The four numbers as the Team tab shows them, each a value and what it is ("–" while nothing is merged).
    public var items: [(value: String, label: String)] {
        [(meanRoundsToPass.map { String(format: "%.1f", $0) } ?? "–", "audit rounds to pass"),
         (firstAuditPassRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", "pass the first audit"),
         (userMinutesPerMergedTask.map(Self.minutes) ?? "–", "user min per merged task"),
         ("\(reverts)", reverts == 1 ? "revert" : "reverts")]
    }

    /// Fewer audited merged tasks than this, and the audit numbers aren't shown as rates: one audit is no average.
    public static let fewestAudited = 3

    /// One of the Team tab's four numbers: its value, what it is, a note under it, and what it means (its help tag).
    public struct Tile: Equatable, Sendable {
        public var value: String
        public var label: String
        public var note: String?
        public var help: String
    }

    /// The four numbers as the Team tab shows them: the audit ones only over enough audited tasks
    /// (`fewestAudited`), "—" and why below that.
    public var tiles: [Tile] {
        let few = counted < Self.fewestAudited
        let over = "over the \(counted) audited merged task\(counted == 1 ? "" : "s")"
        let tooFew = few ? "too few audited tasks (\(counted))" : nil
        let tooFewHelp = few ? " Shown from \(Self.fewestAudited) audited merged tasks on." : ""
        return [Tile(value: few ? "—" : meanRoundsToPass.map { String(format: "%.1f", $0) } ?? "–", label: "audit rounds to pass", note: tooFew,
                     help: "The audits a merged task took to pass, on average, \(over).\(tooFewHelp)"),
                Tile(value: few ? "—" : firstAuditPassRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", label: "pass the first audit", note: tooFew,
                     help: "The share of the audited merged tasks that passed their first audit, \(over).\(tooFewHelp)"),
                Tile(value: userMinutesPerMergedTask.map(Self.minutes) ?? "–", label: "min waiting on you per task", note: nil,
                     help: "Your minutes per merged task: the time the lead's questions waited on your answer (\(Self.minutes(userMinutes)) min in all, "
                         + "every question, about a task or not) divided by the \(merged) merged task\(merged == 1 ? "" : "s")."),
                Tile(value: "\(reverts)", label: reverts == 1 ? "revert" : "reverts", note: nil,
                     help: "Merges the base later reverted (a commit saying “This reverts commit …” for one of a merge's commits).")]
    }

    /// "Scorecard (5 merged): 1.4 audit rounds to pass, 60% pass the first audit, 12 user min per merged task, 0 reverts; 1 merged without tests."
    public var line: String {
        guard merged > 0 else { return "Scorecard: nothing merged yet." }
        let untested = mergedWithoutTests == 0 ? "" : "; \(mergedWithoutTests) merged without tests"
        let unaudited = mergedUnaudited == 0 ? "" : "; \(mergedUnaudited) merged with no audit (review none)"
        let uncounted = counted < merged - mergedUnaudited ? " (rounds of \(counted) of them)" : ""
        return "Scorecard (\(merged) merged\(uncounted)): " + items.map { "\($0.value) \($0.label)" }.joined(separator: ", ") + untested + unaudited + "."
    }

    /// What VoiceOver reads.
    public var spoken: String {
        guard merged > 0 else { return "Scorecard: nothing merged yet." }
        var parts = ["\(merged) task\(merged == 1 ? "" : "s") merged"]
        if counted < Self.fewestAudited {
            parts.append("too few audited tasks (\(counted)) for the audit numbers")
        } else {
            if let mean = meanRoundsToPass { parts.append(String(format: "%.1f", mean) + " audit rounds to pass on average") }
            if let rate = firstAuditPassRate { parts.append("\(Int((rate * 100).rounded())) percent passed the first audit") }
        }
        if let minutes = userMinutesPerMergedTask { parts.append("\(Self.minutes(minutes)) minutes waiting on you per merged task") }
        parts.append("\(reverts) reverted later")
        if mergedWithoutTests > 0 { parts.append("\(mergedWithoutTests) merged without tests") }
        if mergedUnaudited > 0 { parts.append("\(mergedUnaudited) merged with no audit") }
        return "Scorecard: " + parts.joined(separator: ", ") + "."
    }

    /// 0.4 → "0.4", 12.3 → "12".
    static func minutes(_ value: Double) -> String { value < 10 ? String(format: "%.1f", value) : String(Int(value.rounded())) }
}

/// Merges the base reverted later: a commit on the base whose message says `This reverts commit <hash>` (as
/// `git revert` writes it) for one of the commits a merge put there.
public enum LeadReverts {
    /// For each merge in `merges` (a task's slug and its record), the commit on `base` that reverts one of its
    /// commits, when one does; merges already known as reverted are left out. One `git log` of the base since the
    /// oldest of them finds every revert; only when there's one are the merges' commits listed.
    public static func find(root: String, base: String, merges: [(slug: String, merged: LeadMergeRecord)]) -> [String: String] {
        let pending = merges.filter { $0.merged.revertedBy == nil }
        guard let oldest = pending.min(by: { $0.merged.at < $1.merged.at }) else { return [:] }
        let log = Git.run(["log", "--format=%H%x1f%B%x1e", "--grep=This reverts commit", "\(oldest.merged.commit)..refs/heads/\(base)"], in: root)
        guard log.ok else { return [:] }
        let reverts = parse(log.output)
        guard !reverts.isEmpty else { return [:] }
        var found: [String: String] = [:]
        for (slug, merged) in pending {
            let commits = self.commits(of: merged, root: root)
            // The oldest first: the revert that undid it.
            if let revert = reverts.last(where: { revert in revert.reverted.contains { hash in commits.contains { $0.hasPrefix(hash) } } }) {
                found[slug] = revert.commit
            }
        }
        return found
    }

    /// Each revert commit in `git log --format=%H%x1f%B%x1e` output, newest first, with the hashes it says it reverts.
    static func parse(_ output: String) -> [(commit: String, reverted: [String])] {
        output.components(separatedBy: "\u{1e}").compactMap { record in
            let parts = record.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            let body = parts[1]
            let pattern = try! NSRegularExpression(pattern: "This reverts commit ([0-9a-f]{7,64})")
            let hashes = pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap {
                Range($0.range(at: 1), in: body).map { String(body[$0]) }
            }
            return hashes.isEmpty ? nil : (parts[0], hashes)
        }
    }

    /// The commits a merge put on the base: from the head it went onto to the one it left; just that one when
    /// where it went onto isn't recorded (merges from before it was).
    static func commits(of merged: LeadMergeRecord, root: String) -> [String] {
        guard let onto = merged.onto else { return [merged.commit] }
        let list = Git.run(["rev-list", "\(onto)..\(merged.commit)"], in: root)
        let commits = list.ok ? list.output.split(whereSeparator: \.isNewline).map(String.init) : []
        return commits.isEmpty ? [merged.commit] : commits
    }
}
