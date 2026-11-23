import Foundation
import Testing
@testable import VibeCore

/// The weekly scorecard's bugs that got past review (`LeadEscapedBugs`): a bug task's done report names the commit
/// that introduced the bug (`introduced_by`), and status counts those bugs by the review of the merge that brought the
/// commit (its VS-Review trailer), beside the merges reverted in the same weeks.
struct LeadEscapedBugsTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    static let day = 86_400.0

    func repo() throws -> String {
        let url = temp.url("escaped")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try commit(root, "a.txt", "first")
        return root
    }

    /// Commits `file` on main with `message` (trailers and all); returns the commit.
    @discardableResult
    func commit(_ root: String, _ file: String, _ message: String) throws -> String {
        try UUID().uuidString.write(toFile: root + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: root)
        Git.run(["commit", "-q", "-m", message], in: root)
        return Git.run(["rev-parse", "HEAD"], in: root).output
    }

    /// A merged task `slug` (its merge record `commit`, from `onto`), audit-sampled from review none when `sampled`.
    func merged(_ slug: String, commit: String, onto: String? = nil, audited: Bool? = nil, sampled: Bool = false) -> LeadTask {
        var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""), status: .done)
        task.merged = LeadMergeRecord(commit: commit, tested: true, onto: onto, audited: audited)
        if sampled { task.auditSample = LeadAuditSample(seed: 1, percent: 100, commit: commit) }
        return task
    }

    /// A bug task (origin `origin`) created at `at`, whose done report said `introduced` (nil: said nothing).
    func bug(_ slug: String, origin: String = "user_report", introduced: String?, at: Double) -> LeadTask {
        var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""), status: .review)
        task.createdAt = at
        task.origin = origin
        task.report = "fixed it"
        task.introducedBy = introduced
        return task
    }

    @Test func aBugCountsByTheReviewOfTheMergeThatIntroducedIt() throws {
        let root = try repo()
        let audited = try commit(root, "b.txt", "Add b\n\nVS-Task: add-b\nVS-Review: audit (pass at 1234567890ab)\nVS-Worker-Model: opus")
        let unaudited = try commit(root, "c.txt", "Add c\n\nVS-Task: add-c\nVS-Review: none\nVS-Worker-Model: opus")
        let sampled = try commit(root, "d.txt", "Add d\n\nVS-Task: add-d\nVS-Review: audit (pass at abcdef123456)")
        let own = try commit(root, "e.txt", "The user's own change")
        // A rebased merge of two commits: the lower one has no trailers, the top one the merge's.
        let onto = own
        let lower = try commit(root, "f.txt", "Add f, part one")
        let top = try commit(root, "g.txt", "Add f, part two\n\nVS-Task: add-f\nVS-Review: none")
        // After it, the user's own commit again, then a team merge: it isn't that merge's.
        let later = try commit(root, "h.txt", "The user's later change")
        try commit(root, "i.txt", "Add i\n\nVS-Task: add-i\nVS-Review: audit (pass at 0000000aaaaa)")
        let now = Date().timeIntervalSince1970
        let tasks = [merged("add-b", commit: audited), merged("add-c", commit: unaudited, audited: false),
                     merged("add-d", commit: sampled, sampled: true), merged("add-f", commit: top, onto: onto, audited: false),
                     bug("fix-1", introduced: audited, at: now - Self.day),
                     bug("fix-2", origin: "log_watcher", introduced: String(unaudited.prefix(8)), at: now - Self.day),
                     bug("fix-3", origin: "incident", introduced: sampled, at: now - Self.day),
                     bug("fix-4", introduced: own, at: now - Self.day),
                     bug("fix-5", introduced: "unknown", at: now - Self.day),
                     bug("fix-6", introduced: lower, at: now - Self.day),
                     bug("fix-7", introduced: later, at: now - Self.day),
                     // Not on the base: unknown.
                     bug("fix-8", introduced: "0123456789abcdef0123456789abcdef01234567", at: now - Self.day),
                     // Not a bug task: not counted.
                     bug("lead-plan", origin: "lead", introduced: audited, at: now - Self.day)]
        let resolve = { (commit: String) in LeadEscapedBugs.merge(of: commit, root: root, base: "main", tasks: tasks) }
        let week = LeadEscapedBugs(tasks, from: now - 7 * Self.day, to: now + 1, resolve: resolve)
        #expect(week.counts == [.audit: 1, .none: 2, .noneSampled: 1, .outside: 2, .unknown: 2], "\(week.counts)")
        #expect(LeadEscapedBugs.review(of: audited, resolve: resolve, tasks: tasks) == .audit)
        #expect(LeadEscapedBugs.review(of: unaudited, resolve: resolve, tasks: tasks) == .none)
        #expect(LeadEscapedBugs.review(of: "unknown", resolve: resolve, tasks: tasks) == .unknown)
        #expect(LeadEscapedBugs.review(of: own, resolve: resolve, tasks: tasks) == .outside)
        #expect(LeadEscapedBugs.review(of: lower, resolve: resolve, tasks: tasks) == .none)
        #expect(LeadEscapedBugs.review(of: later, resolve: resolve, tasks: tasks) == .outside)
    }

    /// A team true merge (merge commit with trailers) brings a side branch's commits through its second parent: a bug
    /// one of them introduced counts under that merge's review, and a commit on the base before it stays outside.
    @Test func aCommitATrueMergeBroughtThroughItsSecondParentCountsUnderThatMerge() throws {
        let root = try repo()
        let fork = Git.run(["rev-parse", "HEAD"], in: root).output
        Git.run(["checkout", "-q", "-b", "side"], in: root)
        let side = try commit(root, "s.txt", "Upstream change, no trailers")
        try commit(root, "t.txt", "Another upstream change")
        Git.run(["checkout", "-q", "main"], in: root)
        // The base moves on before the merge: the user's own commit, then a team merge with no part in the side branch.
        let own = try commit(root, "u.txt", "The user's own change")
        let squashed = try commit(root, "v.txt", "Add v\n\nVS-Task: add-v\nVS-Review: none")
        let merging = Git.run(["merge", "-q", "--no-ff", "side", "-m", "Merge side\n\nVS-Task: merge-side\nVS-Review: audit (pass at 1234567890ab)"], in: root)
        #expect(merging.ok, "\(merging.output)")
        let merge = Git.run(["rev-parse", "HEAD"], in: root).output
        // On the base's first-parent line, the side commit is under the merge but not under its first parent.
        #expect(!Git.run(["merge-base", "--is-ancestor", side, merge + "^1"], in: root).ok)
        let tasks = [merged("add-v", commit: squashed, onto: own, audited: false), merged("merge-side", commit: merge)]
        let resolve = { (commit: String) in LeadEscapedBugs.merge(of: commit, root: root, base: "main", tasks: tasks) }
        #expect(LeadEscapedBugs.review(of: side, resolve: resolve, tasks: tasks) == .audit)
        #expect(LeadEscapedBugs.review(of: own, resolve: resolve, tasks: tasks) == .outside)
        #expect(LeadEscapedBugs.review(of: fork, resolve: resolve, tasks: tasks) == .outside)
    }

    @Test func theScorecardLineSaysThisWeeksAndTheWeekBeforesCountsAndReverts() {
        let now = Date().timeIntervalSince1970
        let merges: [String: LeadEscapedBugs.Merge] = ["aaaaaaa1": .init(task: "a", review: "audit (pass at 1)"),
                                                       "bbbbbbb2": .init(task: "b", review: "none"),
                                                       "ccccccc3": .init(task: nil, review: nil)]
        var revertedNow = merged("r1", commit: "9999999", audited: false)
        revertedNow.merged?.revertedBy = "7777777"
        revertedNow.merged?.revertedAt = now - Self.day
        var revertedBefore = merged("r2", commit: "8888888")
        revertedBefore.merged?.revertedBy = "6666666"
        revertedBefore.merged?.revertedAt = now - 10 * Self.day
        var notSaid = bug("fix-old-worker", introduced: nil, at: now - Self.day)
        notSaid.introducedBy = nil
        let tasks = [bug("fix-1", introduced: "aaaaaaa1", at: now - Self.day), bug("fix-2", introduced: "bbbbbbb2", at: now - 2 * Self.day),
                     bug("fix-3", introduced: "unknown", at: now - 3 * Self.day), notSaid,
                     bug("fix-4", introduced: "bbbbbbb2", at: now - 9 * Self.day), bug("fix-5", introduced: "ccccccc3", at: now - 9 * Self.day),
                     // Older than two weeks: in neither.
                     bug("fix-6", introduced: "aaaaaaa1", at: now - 20 * Self.day),
                     revertedNow, revertedBefore]
        let line = LeadEscapedBugs.statusLine(tasks, now: now, resolve: { merges[$0] })
        #expect(line == "Bugs that got past review (bug tasks by creation, by the review of the merge that introduced each, from its "
            + "VS-Review trailer; last 7 days): 3 (1 audit, 1 none, 0 none but sampled, 1 unknown, 1 more not said) · 1 reverted merge (1 none) "
            + "| the 7 days before: 2 (0 audit, 1 none, 0 none but sampled, 1 outside the team) · 1 reverted merge (1 audit).", "\(line ?? "nil")")
        // Nothing to count in either week: status stays short.
        #expect(LeadEscapedBugs.statusLine([bug("fix-6", introduced: "aaaaaaa1", at: now - 20 * Self.day)], now: now, resolve: { merges[$0] }) == nil)
    }

    @Test func introducedByIsKeptAsAHashOrUnknown() {
        #expect(LeadDoneEvidence.introducedBy(nil) == nil)
        #expect(LeadDoneEvidence.introducedBy("  ") == nil)
        #expect(LeadDoneEvidence.introducedBy("CCA6BD7E") == "cca6bd7e")
        #expect(LeadDoneEvidence.introducedBy("cca6bd7e (the lead's chat merge)") == "cca6bd7e")
        #expect(LeadDoneEvidence.introducedBy("unknown") == "unknown")
        // A word of hex letters isn't a hash.
        #expect(LeadDoneEvidence.introducedBy("acceded somewhere") == "unknown")
    }

    /// The report tool keeps a bug fix's `introduced_by` on the board's task and with the done's evidence in the vault,
    /// and status counts it; a done without it goes through as before.
    @Test func aDoneReportCarriesIntroducedByAndOneWithoutItStillGoesThrough() throws {
        let root = try repo()
        let audited = try commit(root, "b.txt", "Add b\n\nVS-Task: add-b\nVS-Review: audit (pass at 1234567890ab)")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for (slug, title) in [("fix-crash", "Fix crash"), ("fix-hang", "Fix hang")] {
            #expect(!lead.call("add_task", ["title": title, "goal": "it doesn't", "acceptance": ["it's fixed"], "origin": "user_report"]).isError)
            #expect(!lead.call("start_worker", ["task": slug]).isError)
            let worktree = Worktrees.path(root: root, slug: slug)
            try commit(worktree, "\(slug).txt", "fix")
        }
        var said = doneReport("fixed the crash")
        said["introduced_by"] = audited
        let reported = try seat("worker-fix-crash", runtime).call("report", said)
        #expect(!reported.isError, "\(reported.text)")
        let quiet = try seat("worker-fix-hang", runtime).call("report", doneReport("fixed the hang"))
        #expect(!quiet.isError, "\(quiet.text)")

        let board = BoardStore(root: root).load()
        #expect(board.task("fix-crash")?.introducedBy == audited)
        #expect(board.task("fix-hang")?.introducedBy == nil)
        #expect(try vault.unaudited(root: root, task: "fix-crash").evidence?.introducedBy == audited)
        #expect(try vault.unaudited(root: root, task: "fix-hang").evidence?.introducedBy == nil)
        let status = lead.call("status", [:]).text
        #expect(status.contains("last 7 days): 1 (1 audit, 0 none, 0 none but sampled, 1 more not said) · 0 reverted merges"), "\(status)")
    }
}
