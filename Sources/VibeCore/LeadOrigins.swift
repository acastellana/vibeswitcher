import Foundation

/// Where the board's tasks came from, week by week (`LeadTask.origin`): how many bugs the user reported against those
/// the system found (incidents, the log watcher, flakes, audits), counted by when each task was created. Status says
/// the last 7 days' and the 7 before's; Statistics counts the same way (`SetupScorecard`).
public struct LeadOrigins: Equatable, Sendable {
    /// Tasks created in the span, by origin; `unsaid`: created with none said.
    public var counts: [LeadTask.Origin: Int] = [:]
    public var unsaid = 0

    public init(counts: [LeadTask.Origin: Int] = [:], unsaid: Int = 0) {
        self.counts = counts
        self.unsaid = unsaid
    }

    /// The tasks among `tasks` created in [start, end): each counted once, by its `originKind` (a value this build
    /// doesn't know counts as other).
    public init(_ tasks: [(createdAt: Double, origin: String?)], from start: Double, to end: Double) {
        for task in tasks where start <= task.createdAt && task.createdAt < end {
            guard let said = task.origin, !said.trimmingCharacters(in: .whitespaces).isEmpty else { unsaid += 1; continue }
            counts[LeadTask.Origin(text: said) ?? .other, default: 0] += 1
        }
    }

    /// All tasks counted (n).
    public var total: Int { counts.values.reduce(0, +) + unsaid }
    public var userReported: Int { counts[.userReport] ?? 0 }
    public var systemFound: Int { counts.filter { $0.key.systemFound }.values.reduce(0, +) }

    /// "2 user_report, 1 incident, 1 audit, 3 not said (n = 7)"; "none (n = 0)".
    public var text: String {
        var parts = LeadTask.Origin.allCases.compactMap { origin in counts[origin].flatMap { $0 > 0 ? "\($0) \(origin.rawValue)" : nil } }
        if unsaid > 0 { parts.append("\(unsaid) not said") }
        return (parts.isEmpty ? "none" : parts.joined(separator: ", ")) + " (n = \(total))"
    }

    /// Status's line: "Task origins (by creation; last 7 days): 2 user_report, 1 incident (n = 3) · the 7 days before:
    /// … · bugs you reported 2 vs found by the system 1"; nil when no task created in either week has an origin said
    /// (a board from before origins: nothing to count, and status stays short).
    public static func statusLine(_ tasks: [LeadTask], now: Double) -> String? {
        let week = 7 * 86_400.0
        let pairs = tasks.filter { $0.removedAt == nil }.map { (createdAt: $0.createdAt, origin: $0.origin) }
        let this = LeadOrigins(pairs, from: now - week, to: now + 1), last = LeadOrigins(pairs, from: now - 2 * week, to: now - week)
        guard this.total - this.unsaid + last.total - last.unsaid > 0 else { return nil }
        return "Task origins (by creation; last 7 days): \(this.text) · the 7 days before: \(last.text) · bugs you reported "
            + "\(this.userReported) vs found by the system \(this.systemFound) this week (\(last.userReported) vs \(last.systemFound) the week before)."
    }
}

/// Bugs that got past review, week by week: each bug task (origin user_report, log_watcher or incident) whose done
/// report named the commit that introduced the bug (`LeadTask.introducedBy`), counted by the review of the merge that
/// brought that commit to the base, as its `VS-Review` trailer says (`LeadProvenance`): audit, none, or none but drawn
/// by the audit sample (`LeadAuditSample`: its trailer says audit, the board says it was sampled from none). A commit no
/// merge of the team's brought (no `VS-Task` trailer: the user's own) is outside the team; "unknown", or a commit the
/// base doesn't have, is unknown. Beside them, the merges reverted in the same weeks (`LeadMergeRecord.revertedAt`).
/// Counted by when each bug task was created, as `LeadOrigins` counts; status says the last 7 days' and the 7 before's.
/// From "How the Claude Code team thinks about verification" (2026-11-23): reviewers judged by what got past them.
public struct LeadEscapedBugs: Equatable, Sendable {
    /// How the merge that brought a bug was reviewed.
    public enum Review: String, CaseIterable, Sendable {
        case audit, none, noneSampled = "none but sampled", outside = "outside the team", unknown
    }

    /// The trailers of the merge that brought a commit: its task (nil: no `VS-Task`, not the team's) and its review.
    public struct Merge: Equatable, Sendable {
        public var task: String?
        public var review: String?

        public init(task: String?, review: String?) {
            self.task = task
            self.review = review
        }
    }

    public var counts: [Review: Int] = [:]
    /// Bug tasks with a done report that didn't say what introduced the bug (workers from before it was asked).
    public var notSaid = 0
    /// Merges reverted in the span, by their own review (audit, none, none but sampled).
    public var reverted: [Review: Int] = [:]

    public init(counts: [Review: Int] = [:], notSaid: Int = 0, reverted: [Review: Int] = [:]) {
        self.counts = counts
        self.notSaid = notSaid
        self.reverted = reverted
    }

    /// The origins whose tasks fix a bug that got to the base.
    public static let bugOrigins: Set<LeadTask.Origin> = [.userReport, .logWatcher, .incident]

    /// The bug tasks among `tasks` created in [start, end), each by the merge `resolve` finds for its introducing
    /// commit (nil: the base hasn't it), and the merges reverted in the span. Folded, abandoned and removed tasks
    /// count nowhere.
    public init(_ tasks: [LeadTask], from start: Double, to end: Double, resolve: (String) -> Merge?) {
        let counted = tasks.filter { $0.removedAt == nil && ![.folded, .abandoned].contains($0.status) }
        for task in counted where start <= task.createdAt && task.createdAt < end {
            guard let origin = task.originKind, Self.bugOrigins.contains(origin) else { continue }
            guard let said = task.introducedBy else {
                if task.report != nil { notSaid += 1 }
                continue
            }
            counts[Self.review(of: said, resolve: resolve, tasks: tasks), default: 0] += 1
        }
        for task in counted {
            guard let merged = task.merged, merged.revertedBy != nil || task.status == .reverted,
                  let at = merged.revertedAt, start <= at, at < end else { continue }
            reverted[Self.review(of: task), default: 0] += 1
        }
    }

    /// How the merge that brought `said` (a commit, or "unknown") was reviewed.
    public static func review(of said: String, resolve: (String) -> Merge?, tasks: [LeadTask]) -> Review {
        let commit = said.trimmingCharacters(in: .whitespaces)
        guard !commit.isEmpty, commit.lowercased() != "unknown", let merge = resolve(commit) else { return .unknown }
        guard let slug = merge.task?.trimmingCharacters(in: .whitespaces), !slug.isEmpty else { return .outside }
        // The task that merge landed (the newest of that name that merged, as a slug can be used again).
        let task = tasks.filter { $0.slug == slug && $0.merged != nil }.max { ($0.merged?.at ?? 0) < ($1.merged?.at ?? 0) }
        if task?.auditSample?.sampled == true { return .noneSampled }
        let review = (merge.review ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if review.hasPrefix("audit") { return .audit }
        if review.hasPrefix("none") { return .none }
        return .unknown
    }

    /// A merged task's own review, from the board: none but sampled, none (merged unaudited), else audit.
    static func review(of task: LeadTask) -> Review {
        if task.auditSample?.sampled == true { return .noneSampled }
        return task.merged?.unaudited == true ? .none : .audit
    }

    public var total: Int { counts.values.reduce(0, +) }
    public var revertedTotal: Int { reverted.values.reduce(0, +) }

    /// "3 (1 audit, 1 none, 0 none but sampled, 1 outside the team) · 1 reverted merge (1 none)"; the three review
    /// levels always, outside the team, unknown and not said only when there are some.
    public var text: String {
        var parts = [Review.audit, .none, .noneSampled].map { "\(counts[$0] ?? 0) \($0.rawValue)" }
        parts += [Review.outside, .unknown].compactMap { review in counts[review].flatMap { $0 > 0 ? "\($0) \(review.rawValue)" : nil } }
        let unsaid = notSaid > 0 ? ", \(notSaid) more not said" : ""
        let split = Review.allCases.compactMap { review in reverted[review].flatMap { $0 > 0 ? "\($0) \(review.rawValue)" : nil } }
        let reverts = "\(revertedTotal) reverted merge\(revertedTotal == 1 ? "" : "s")" + (split.isEmpty ? "" : " (\(split.joined(separator: ", ")))")
        return "\(total) (\(parts.joined(separator: ", "))\(unsaid)) · \(reverts)"
    }

    /// Status's line: "Bugs that got past review (bug tasks by creation, by the review of the merge that introduced
    /// each; last 7 days): 3 (1 audit, …) · 1 reverted merge (1 none) | the 7 days before: …"; nil when neither week
    /// has a bug task with a done report or a reverted merge (status stays short).
    public static func statusLine(_ tasks: [LeadTask], now: Double, resolve: (String) -> Merge?) -> String? {
        let week = 7 * 86_400.0
        let this = LeadEscapedBugs(tasks, from: now - week, to: now + 1, resolve: resolve)
        let last = LeadEscapedBugs(tasks, from: now - 2 * week, to: now - week, resolve: resolve)
        guard [this, last].contains(where: { $0.total + $0.notSaid + $0.revertedTotal > 0 }) else { return nil }
        return "Bugs that got past review (bug tasks by creation, by the review of the merge that introduced each, from its "
            + "VS-Review trailer; last 7 days): \(this.text) | the 7 days before: \(last.text)."
    }
}

extension LeadEscapedBugs {
    /// The merge on `base` in `root` that brought `commit`, by its trailers: the commit itself when it carries a
    /// `VS-Task` (a squashed or rebased merge's top commit, or a true merge); else the first commit after it on the
    /// base's first-parent line that carries one, when that merge's commits include it (a rebased merge's lower
    /// commits: it isn't under the head the merge went onto, `LeadMergeRecord.onto`, or the merge is a true merge
    /// that brought it through its second parent). Anything else on the base came another way: a merge with no task
    /// (outside the team). Nil when the base hasn't `commit` (or it isn't a commit).
    public static func merge(of commit: String, root: String, base: String, tasks: [LeadTask]) -> Merge? {
        let resolved = Git.run(["rev-parse", "--verify", "--quiet", "\(commit)^{commit}"], in: root)
        guard resolved.ok, !resolved.output.isEmpty else { return nil }
        let hash = resolved.output
        guard Git.run(["merge-base", "--is-ancestor", hash, "refs/heads/\(base)"], in: root).ok else { return nil }
        let format = "--format=%H%x1f%P%x1f%(trailers:key=VS-Task,valueonly,separator=%x20)%x1f%(trailers:key=VS-Review,valueonly,separator=%x20)%x1e"
        let own = Git.run(["log", "-1", format, hash], in: root)
        if let mine = parse(own.output).first, mine.task != nil { return Merge(task: mine.task, review: mine.review) }
        // The base's first-parent line after it, kept to the commits that have it. (`--ancestry-path --first-parent`
        // together walks nothing when a true merge brought it through a later parent, so they run apart.)
        let line = Git.run(["log", "--first-parent", "--reverse", format, "\(hash)..refs/heads/\(base)"], in: root)
        let under = Git.run(["rev-list", "--ancestry-path", "\(hash)..refs/heads/\(base)"], in: root)
        guard line.ok, under.ok else { return Merge(task: nil, review: nil) }
        let having = Set(under.output.split(separator: "\n").map(String.init))
        guard let next = parse(line.output).first(where: { $0.task != nil && having.contains($0.commit) }) else {
            return Merge(task: nil, review: nil)
        }
        let merge = Merge(task: next.task, review: next.review)
        // A true merge that brought it through a parent past its first.
        if next.parents.count > 1, !Git.run(["merge-base", "--is-ancestor", hash, next.parents[0]], in: root).ok { return merge }
        // A rebased merge's lower commit: under its top, not under where it went onto.
        let record = tasks.compactMap(\.merged).first { $0.commit.hasPrefix(next.commit) || next.commit.hasPrefix($0.commit) }
        if let onto = record?.onto, !Git.run(["merge-base", "--is-ancestor", hash, onto], in: root).ok { return merge }
        return Merge(task: nil, review: nil)
    }

    /// Each record of `git log` output in `merge`'s format: commit, parents, VS-Task, VS-Review (nil when blank).
    static func parse(_ output: String) -> [(commit: String, parents: [String], task: String?, review: String?)] {
        output.components(separatedBy: "\u{1e}").compactMap { record in
            let parts = record.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
            guard parts.count == 4, !parts[0].isEmpty else { return nil }
            let said = { (text: String) -> String? in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return (parts[0], parts[1].split(separator: " ").map(String.init), said(parts[2]), said(parts[3]))
        }
    }
}
