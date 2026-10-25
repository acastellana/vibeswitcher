import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The calm Team view: one line per task (where it is now, for how long, what its agent is doing), the lead's
/// decisions fading out, and the plain-language lines, with a fake summarizer (no Claude runs here).
struct TeamRowsTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func task(_ slug: String, _ status: LeadTask.Status, title: String? = nil, since: TimeInterval? = 12 * 60, created: Double = 0) -> LeadTask {
        var task = LeadTask(id: slug, slug: slug, title: title ?? slug, contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""),
                            status: status)
        // Made hours ago: a clock from here would read "4h".
        task.createdAt = now.timeIntervalSince1970 - 4 * 3_600 + created
        task.since = since.map { now.timeIntervalSince1970 - $0 }
        task.worktree = "/r/.vibeswitcher/worktrees/\(slug)"
        if status != .planned {
            task.worker = "w-\(slug)"
            task.attempts = 1
            task.startedAt = task.createdAt + 1
        }
        return task
    }

    static func member(live: Bool = true, needsYou: Bool = false, working: Bool = true, activity: String? = "Running swift test",
                       detail: String? = nil, started: TimeInterval = 20 * 60) -> MemberSeen {
        MemberSeen(live: live, needsYou: needsYou, working: working, activity: activity, detail: detail, since: now - 30, startedAt: now - started)
    }

    static let working = member()
    static let idle = member(working: false, activity: nil)
    static let ended = member(live: false, working: false, activity: nil)

    func row(_ task: LeadTask, _ seen: [String: MemberSeen] = [:]) -> TeamRow { TeamRows.row(task, seen: seen) }

    // MARK: State and time

    @Test func aRunningTaskIsWorkingSinceItsStageBegan() {
        var task = Self.task("fix", .running)
        task.checkpoints = [LeadCheckpoint(text: "Parser done", at: Self.now.timeIntervalSince1970 - 300)]
        let row = row(task, ["w-fix": Self.working])
        #expect(row.group == .working && row.mark == .working)
        #expect(row.stateText(now: Self.now) == "Working 12m")
        #expect(row.isLive && row.agent == "w-fix")
        #expect(row.summaryKey == "task|fix|w-fix")
    }

    @Test func withoutAStageStampTheClockIsTheSessionsStartOrNone() {
        // An old board: no `since`. The worker's session started 20 minutes ago.
        let task = Self.task("fix", .running, since: nil)
        #expect(row(task, ["w-fix": Self.working]).stateText(now: Self.now) == "Working 20m")
        // Nothing says when: no time, never the task's age.
        #expect(row(task).stateText(now: Self.now) == "Working")
        // In review: the verifier's session start.
        var review = Self.task("rev", .review, since: nil)
        review.verifier = "v-rev"
        #expect(row(review, ["v-rev": Self.member(started: 3 * 60)]).stateText(now: Self.now) == "In review 3m")
        #expect(row(review).stateText(now: Self.now) == "In review")
    }

    @Test func aFailedTaskWhoseWorkerWorksAgainIsReworkNotFailed() {
        var task = Self.task("fix", .failed, since: 22 * 60)
        task.setback = LeadSetback(stage: .review, reason: "The test still fails")
        let reworked = row(task, ["w-fix": Self.working])
        #expect(reworked.group == .working && reworked.mark == .rework)
        #expect(reworked.stateText(now: Self.now) == "Rework 1 · 22m")
        #expect(reworked.problem == "The test still fails")
        // A rework round the board knows of.
        var round = Self.task("fix", .running, since: 22 * 60)
        round.attempts = 3
        #expect(row(round, ["w-fix": Self.working]).stateText(now: Self.now) == "Rework 2 · 22m")
        // Its worker idle or gone: failed, red, saying why.
        for seen in [Self.idle, Self.ended] {
            let failed = row(task, ["w-fix": seen])
            #expect(failed.mark == .failed && failed.group == .needsYou)
            #expect(failed.state == "Failed")
            #expect(failed.line(summary: "ignored") == "The test still fails")
        }
    }

    @Test func aTaskWhoseRoundsKeepLeavingImportantFindingsSaysReconsider() throws {
        var task = Self.task("fix", .failed, since: 22 * 60)
        task.setback = LeadSetback(stage: .review, reason: "Important findings open: F1 a.swift:1")
        var audits = LeadAuditLedger()
        let still = LeadFinding.Report(id: "F1", severity: .important, file: "a.swift", line: 1, evidence: "still fails")
        try audits.record([still], commit: "c1", passes: true)
        task.audits = audits
        #expect(row(task, ["w-fix": Self.idle]).state == "Failed")
        try audits.record([still], commit: "c2", passes: true, changed: ["a.swift"])
        task.audits = audits
        let reconsider = row(task, ["w-fix": Self.idle])
        #expect(reconsider.state == "Reconsider" && reconsider.mark == .failed && reconsider.group == .needsYou)
        #expect(reconsider.line(summary: "ignored") == "Reconsider the approach: 1 Important finding left open across 2 rounds; the lead re-rolls it, re-plans it or asks you.")

        // Rounds whose verdict failed are counted as such.
        var failed = LeadAuditLedger()
        for commit in ["c1", "c2", "c3"] { try failed.record([], commit: commit, passes: false, changed: []) }
        task.audits = failed
        #expect(row(task, ["w-fix": Self.idle]).line(summary: "ignored") == "Reconsider the approach: 3 failed verdicts in a row; the lead re-rolls it, re-plans it or asks you.")
    }

    @Test func theTaskViewShowsFindingsBySeverity() throws {
        var audits = LeadAuditLedger()
        try audits.record([.init(severity: .nit, file: "b.swift", line: 2, evidence: "typo"),
                           .init(severity: .important, file: "a.swift", line: 1, evidence: "test fails"),
                           .init(severity: .important, file: "a.swift", line: 9, evidence: "leak")], commit: "c1", passes: true)
        try audits.dismiss("F3", reason: "not ours", followUp: "fix-leak")
        let groups = audits.bySeverity
        #expect(groups.map(\.severity) == [.important, .nit])
        #expect(groups[0].findings.map(\.id) == ["F2", "F3"])
        #expect(TeamRowDetails.groupTitle(.important, groups[0].findings) == "Important · 1 open of 2")
        #expect(TeamRowDetails.groupTitle(.nit, groups[1].findings) == "Nit · 1 open")
        #expect(TeamRowDetails.findingText(groups[0].findings[0]) == "F2 a.swift:1 — test fails")
        #expect(TeamRowDetails.findingText(groups[0].findings[1]) == "F3 a.swift:9 — leak (dismissed by the lead: not ours → task fix-leak)")
    }

    /// An audit by several finders: the row says how many have submitted, and waits on the first that hasn't (one
    /// that has may end); an unconfirmed finding is shown as such.
    @Test func anAuditByFindersShowsWhoHasSubmitted() throws {
        var task = Self.task("fix", .review)
        task.verifier = "v1"
        task.panel = LeadAuditPanel(focuses: ["contract and acceptance", "bugs and regressions", "tests and edge cases"], sessions: ["v1", "v2", "v3"],
                                    reported: [1], commit: "c1", logs: ["/r/.vibeswitcher/audit/fix/c1/test.log"], run: "the test command passed")
        #expect(task.awaitedVerifiers == ["v2", "v3"])
        #expect(task.awaitedVerifier() == "v2")
        let row = row(task, ["v1": Self.ended, "v2": Self.working, "v3": Self.working])
        #expect(row.mark == .review, "finder 1 ended after submitting: not a verifier that ended without a verdict")
        #expect(row.activity == "3 finders, 1 reported · Running swift test")
        #expect(self.row(task, ["v1": Self.ended, "v2": Self.ended, "v3": Self.working]).mark == .ended)
        // A later finder that ends while an earlier one works is seen at once.
        #expect(self.row(task, ["v1": Self.ended, "v2": Self.working, "v3": Self.ended]).mark == .ended)

        var audits = LeadAuditLedger()
        try audits.record([.init(severity: .nit, file: "b.swift", line: 2, evidence: "typo")],
                          unconfirmed: [.init(severity: .nit, file: "b.swift", line: 9, evidence: "naming", status: .unconfirmed, reason: "1 of 3 finders saw it: finder 2")],
                          commit: "c1", passes: true)
        let nits = try #require(audits.bySeverity.first?.findings)
        #expect(TeamRowDetails.groupTitle(.nit, nits) == "Nit · 1 open of 2, 1 unconfirmed")
        #expect(TeamRowDetails.findingText(nits[1]) == "F2 b.swift:9 — naming (unconfirmed: 1 of 3 finders saw it: finder 2)")
    }

    @Test func aSessionWaitingOnYouNeedsYouWithoutAClock() {
        let asking = Self.member(needsYou: true, working: false, activity: nil, detail: "Which database?")
        let row = row(Self.task("fix", .running), ["w-fix": asking])
        #expect(row.mark == .needsYou && row.group == .needsYou)
        #expect(row.stateText(now: Self.now) == "Needs you")
        #expect(row.line(summary: "Making a database") == "Which database?")
    }

    @Test func aStalledWorkerIsRedWhateverItsScreenSays() {
        // It reads as working (a compaction summary looks like a prompt), but the witness saw it stop two hours ago.
        var task = Self.task("fix", .running)
        task.stall = LeadStall(reason: .compacted, lastActivity: Self.now.timeIntervalSince1970 - 2 * 3600,
                               at: Self.now.timeIntervalSince1970 - 3600)
        let row = row(task, ["w-fix": Self.working])
        #expect(row.mark == .stalled && row.group == .needsYou)
        #expect(row.stateText(now: Self.now) == "Stalled 2h")
        #expect(row.line(summary: "Fixing the layout") == "Its transcript ends at a context-compaction summary and nothing followed.")
        // Once it's in review or the worker ended, the stall is no longer what the row says.
        task.status = .review
        #expect(self.row(task, ["w-fix": Self.working]).state != "Stalled")
        task.status = .running
        #expect(self.row(task, ["w-fix": Self.ended]).problem == "The worker ended without reporting.")
    }

    @Test func otherStates() {
        #expect(row(Self.task("q", .planned)).stateText(now: Self.now) == "Queued")
        var blocked = Self.task("b", .blocked)
        blocked.blocker = "Need the API key"
        #expect(row(blocked, ["w-b": Self.idle]).mark == .blocked)
        #expect(row(blocked, ["w-b": Self.idle]).line(summary: nil) == "Need the API key")
        #expect(row(Self.task("s", .running), ["w-s": Self.ended]).mark == .ended)
        var passed = Self.task("p", .review, since: 60)
        passed.evidence = LeadEvidence(completion: .complete, integrity: .clean, summary: "ok")
        #expect(row(passed).state == "Ready to merge")
        #expect(!row(passed).isLive)
        var merged = Self.task("m", .done)
        merged.worktree = nil
        #expect(row(merged).stateText(now: Self.now) == "Merged")
        var abandoned = Self.task("a", .failed)
        abandoned.worktree = nil
        #expect(row(abandoned).mark == .abandoned)
        #expect(TeamRows.finishedTitle([row(merged), row(abandoned)]) == "Merged (1) · Abandoned (1)")
    }

    @Test func aReviewNoneTaskItsWorkerReportedIsReadyToMerge() {
        // No audit to wait for: merge takes the worker's done report and runs the tests.
        let none = Self.task("n", .review, since: 60)
        #expect(row(none).state == "Ready to merge" && row(none).mark == .merge)
        // An audit task waits for its audit; so does a none task once an audit was started on it.
        var audit = Self.task("a", .review, since: 60)
        audit.review = .audit
        #expect(row(audit).state == "In review" && row(audit).activity == "Waiting for the audit")
        var audited = Self.task("v", .review, since: 60)
        audited.verifier = "v-v"
        #expect(row(audited, ["v-v": Self.working]).state == "In review")
        // Review none, but its branch touches sensitive_paths: merge refuses it until an audit passes, and the row says so.
        var sensitive = Self.task("s", .review, since: 60)
        sensitive.auditNeeded = "It touches sensitive_paths (.github/ci.yml), so it's treated as audit whatever its review says."
        #expect(row(sensitive).state == "Needs audit" && row(sensitive).mark == .review)
        #expect(row(sensitive).activity?.contains(".github/ci.yml") == true)
    }

    @Test func theScorecardSaysHowManyMergedWithNoAudit() {
        var board = LeadBoard()
        var plain = Self.task("p", .done)
        plain.merged = LeadMergeRecord(commit: "abc", tested: true, audited: false)
        var checked = Self.task("c", .done)
        checked.merged = LeadMergeRecord(commit: "def", tested: true)
        var ledger = LeadAuditLedger()
        (ledger.rounds, ledger.passed) = (1, true)
        checked.audits = ledger
        board.tasks = [plain, checked]
        let scorecard = LeadScorecard(board)
        #expect(ScorecardView.footnote(scorecard) == "Over 2 merged tasks; 1 with no audit (review none).")
    }

    @Test func eachMarkHasItsOwnShape() {
        let shapes = TeamRow.Mark.allCases.map(\.symbol)
        #expect(Set(shapes).count == shapes.count)
    }

    // MARK: The line under a task

    @Test func theLineIsTheSummaryElseTheCheckpointElseTheActivity() {
        var task = Self.task("fix", .running)
        let live = row(task, ["w-fix": Self.working])
        #expect(live.line(summary: "Making the masker fast") == "Making the masker fast")
        #expect(live.line(summary: nil) == "Running swift test")
        task.checkpoints = [LeadCheckpoint(text: "Parser done", at: 0)]
        #expect(row(task, ["w-fix": Self.working]).line(summary: nil) == "Parser done")
        // Queued and finished: none.
        #expect(row(Self.task("q", .planned)).line(summary: "x") == nil)
    }

    // MARK: Kept, and ended with a replaced host

    @Test func aKeptTaskIsKeptNotFailed() {
        var kept = Self.task("proto", .kept)
        kept.keptBecause = "Prototype: never merge until the user has looked"
        let row = row(kept)
        #expect(row.group == .finished && row.mark == .kept && row.state == "Kept")
        #expect(!row.mark.isRed)
        #expect(row.line(summary: nil) == "Prototype: never merge until the user has looked")
        var merged = Self.task("m", .done)
        merged.merged = LeadMergeRecord(commit: "abc", tested: true)
        #expect(TeamRows.finishedTitle([self.row(merged), row]) == "Merged (1) · Kept (1)")
    }

    @Test func aWorkerWhoseSessionIsGoneReadsEnded() {
        // The host was replaced: the lead's new session is listed, the worker's and verifier's aren't.
        var board = LeadBoard()
        board.tasks = [Self.task("fix", .running), Self.task("rev", .review)]
        board.tasks[1].verifier = "v-rev"
        let rows = TeamRows.rows(board, seen: ["lead": Self.working])
        let fix = rows.first { $0.id == "fix" }!
        #expect(fix.state == "Worker ended" && fix.mark == .ended && fix.group == .needsYou)
        #expect(fix.stateText(now: Self.now) == "Worker ended")
        let rev = rows.first { $0.id == "rev" }!
        #expect(rev.state == "Verifier ended")
        // Nothing listed yet (the host hasn't answered): nothing is said of them.
        #expect(TeamRows.rows(board, seen: [:]).first { $0.id == "fix" }?.state == "Working")
        // A worker that ended on the host reads the same.
        #expect(row(Self.task("s", .running), ["w-s": Self.ended]).state == "Worker ended")
    }

    // MARK: Order

    @Test func rowsAreOrderedNeedsYouWorkingReviewQueuedFinished() {
        var board = LeadBoard()
        var merged = Self.task("merged", .done)
        merged.worktree = nil
        var failed = Self.task("failed", .failed)
        failed.setback = LeadSetback(stage: .review, reason: "no")
        var rework = Self.task("rework", .failed, created: 5)
        rework.setback = LeadSetback(stage: .review, reason: "no")
        // The board's order is the planned order: queued-b was put before queued-a.
        board.tasks = [merged, Self.task("queued-b", .planned, created: 20), Self.task("review", .review), Self.task("queued-a", .planned, created: 10),
                       failed, Self.task("running", .running), rework, Self.task("asking", .running)]
        let seen = ["w-running": Self.working, "w-rework": Self.working,
                    "w-asking": Self.member(needsYou: true, working: false, activity: nil, detail: "Which?")]
        let rows = TeamRows.rows(board, seen: seen)
        #expect(rows.map(\.task.slug) == ["asking", "failed", "running", "rework", "review", "queued-b", "queued-a", "merged"])
        #expect(TeamRows.summary(rows) == "team: 2 need you · 2 working · 1 in review · 2 queued")
        #expect(TeamRows.summary([]) == "team: none running")
    }

    @Test func voiceOverReadsTheRow() {
        let task = Self.task("fix", .running, title: "Calm Team view")
        #expect(row(task, ["w-fix": Self.working]).spoken(now: Self.now, summary: "Drawing the task rows")
                    == "Calm Team view: Working, 12 minutes, Drawing the task rows")
    }

    @Test func windowRowsSayWhenTheirSessionStarted() {
        let id = UUID()
        let hosted = HostSession(id: id, tty: "ttys0", childPID: 1, cwd: "/r/.vibeswitcher/worktrees/fix", command: "claude", label: "Worker: Fix",
                                 agent: "claude", title: "Worker: Fix", startedAt: Self.now - 10, cols: 120, rows: 40, exit: nil)
        let seen = TeamRows.seen([WindowRow(content: .hosted(hosted), project: "fix")], now: Self.now)
        // Started, its agent not shown up yet: being briefed, not idle.
        #expect(seen[id.uuidString]?.live == true)
        #expect(seen[id.uuidString]?.working == true)
        #expect(seen[id.uuidString]?.activity == "Starting…")
        #expect(seen[id.uuidString]?.startedAt == Self.now - 10)
    }

    @Test func endedSessionsOfFinishedTasksAreHistory() {
        func row(_ slug: String, exit: Bool) -> WindowRow {
            let info = HostSession(id: UUID(), tty: "ttys0", childPID: 1, cwd: "/r/.vibeswitcher/worktrees/\(slug)", command: "claude", label: "Worker: \(slug)",
                                   agent: "claude", title: slug, startedAt: Self.now - 10, cols: 120, rows: 40,
                                   exit: exit ? HostSession.Exit(status: 129, at: Self.now - 5) : nil)
            return WindowRow(content: .hosted(info), project: slug)
        }
        var board = LeadBoard()
        var merged = Self.task("merged", .done)
        merged.worktree = nil
        board.tasks = [merged, Self.task("running", .running)]
        let boards = ["/r": board]
        #expect(TeamRows.isHistory(row("merged", exit: true), boards: boards, now: Self.now))
        #expect(!TeamRows.isHistory(row("running", exit: true), boards: boards, now: Self.now))
        #expect(!TeamRows.isHistory(row("merged", exit: false), boards: boards, now: Self.now))
    }

    // MARK: Decisions

    static func decision(_ text: String, ago: Double) -> LeadDecision {
        LeadDecision(at: now.timeIntervalSince1970 - ago, text: text, why: "Because.")
    }

    @Test func aDecisionStaysTwoMinutesThenFadesForAMinuteThenFolds() {
        let at = Self.now.timeIntervalSince1970
        let decision = Self.decision("Run overlapping tasks in parallel", ago: 0)
        #expect(DecisionFeed.phase(decision, now: at + 119, reduceMotion: false) == .fresh)
        #expect(DecisionFeed.phase(decision, now: at + 120, reduceMotion: false) == .fading(0))
        #expect(DecisionFeed.phase(decision, now: at + 150, reduceMotion: false) == .fading(0.5))
        #expect(DecisionFeed.phase(decision, now: at + 180, reduceMotion: false) == .folded)
        // A clock behind the file's: still new.
        #expect(DecisionFeed.phase(decision, now: at - 30, reduceMotion: false) == .fresh)
        // Reduce Motion: no fade, it folds when its time in view is up.
        #expect(DecisionFeed.phase(decision, now: at + 119, reduceMotion: true) == .fresh)
        #expect(DecisionFeed.phase(decision, now: at + 120, reduceMotion: true) == .folded)
        // The fade dims and blurs as it goes.
        let half = DecisionFeed.look(.fading(0.5)), end = DecisionFeed.look(.fading(1))
        #expect(DecisionFeed.look(.fresh) == (1, 0))
        #expect(half.opacity < 1 && half.blur > 0 && end.opacity < half.opacity && end.blur > half.blur)
    }

    @Test func recentDecisionsAreShownNewestFirstAndTheRestFolded() {
        let decisions = [Self.decision("Old", ago: 3_600), Self.decision("Fading", ago: 150), Self.decision("New", ago: 10), Self.decision("Older", ago: 7_200)]
        let split = DecisionFeed.split(decisions, now: Self.now.timeIntervalSince1970, reduceMotion: false)
        #expect(split.recent.map(\.decision.text) == ["New", "Fading"])
        #expect(split.recent.map(\.phase) == [.fresh, .fading(0.5)])
        #expect(split.earlier.map(\.text) == ["Old", "Older"])
        #expect(DecisionFeed.tick(decisions, now: Self.now.timeIntervalSince1970, reduceMotion: false) == 1)
        #expect(DecisionFeed.tick([decisions[0]], now: Self.now.timeIntervalSince1970, reduceMotion: false) == 30)
    }

    @Test func aDecisionReadsAsOneShortLine() {
        let short = Self.decision("Run overlapping tasks in parallel", ago: 0)
        #expect(DecisionFeed.line(short, summary: "ignored") == "Decided: run overlapping tasks in parallel")
        #expect(DecisionFeed.line(Self.decision("VibeSwitcher keeps its name", ago: 0), summary: nil) == "Decided: VibeSwitcher keeps its name")
        let long = Self.decision(String(repeating: "Use all five worker slots and run overlapping tasks ", count: 3), ago: 0)
        #expect(DecisionFeed.needsSummary(long) && !DecisionFeed.needsSummary(short))
        #expect(DecisionFeed.line(long, summary: "Use every worker slot") == "Decided: use every worker slot")
        // No summary (yet): the decision itself, the view cuts it to a line.
        #expect(DecisionFeed.line(long, summary: nil).hasPrefix("Decided: use all five"))
    }

    // MARK: Summaries

    final class Fake: @unchecked Sendable {
        var prompts: [String] = []
        var answer: String? = "Making the masker fast on huge inputs"
        var now: Double = 0
        var changes = 0
    }

    static func transcript(_ folder: URL, steps: Int) throws -> String {
        let path = folder.appendingPathComponent("worker.jsonl").path
        let lines = (0..<steps).map { #"{"type":"assistant","uuid":"u\#($0)","timestamp":"2026-10-17T18:00:0\#($0)Z","message":{"role":"assistant","content":[{"type":"text","text":"Step \#($0)"}]}}"# }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func model(_ fake: Fake, transcript: String?) -> TeamSummaryModel {
        let model = TeamSummaryModel(generate: { fake.prompts.append($0); return fake.answer }, now: { fake.now },
                                     run: { $0() }, deliver: { $0() }, perform: { $0() })
        model.lookup = { _ in (nil, transcript) }
        return model
    }

    @Test func aTaskAtWorkGetsItsSummaryCachedAndRedoneOnlyWhenItsTranscriptChangedThreeMinutesOn() throws {
        let folder = scratchRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try Self.transcript(folder, steps: 2)
        let fake = Fake()
        let model = model(fake, transcript: path)
        var task = Self.task("fix", .running, title: "Fast credential masker")
        task.checkpoints = [LeadCheckpoint(text: "Rules rewritten", at: 0)]
        let rows = [row(task, ["w-fix": Self.working]), row(Self.task("q", .planned))]

        model.request(rows: rows, decisions: [])
        #expect(fake.prompts.count == 1)
        #expect(fake.prompts[0].contains("Fast credential masker") && fake.prompts[0].contains("Rules rewritten") && fake.prompts[0].contains("Step 1"))
        #expect(model.line(rows[0]) == "Making the masker fast on huge inputs")
        #expect(rows[0].line(summary: model.line(rows[0])) == "Making the masker fast on huge inputs")

        // Changed, but within three minutes of the last request: not yet.
        _ = try Self.transcript(folder, steps: 3)
        fake.now = 100
        model.request(rows: rows, decisions: [])
        #expect(fake.prompts.count == 1)
        fake.now = 180
        fake.answer = "Checking the 1 MB case"
        model.request(rows: rows, decisions: [])
        #expect(fake.prompts.count == 2)
        #expect(model.line(rows[0]) == "Checking the 1 MB case")
        // Unchanged since: cached, however long.
        fake.now = 10_000
        model.request(rows: rows, decisions: [])
        #expect(fake.prompts.count == 2)
    }

    @Test func whenGenerationFailsOrIsOffTheRowShowsItsCheckpointOrActivity() throws {
        let fake = Fake()
        fake.answer = nil
        var task = Self.task("fix", .running)
        task.checkpoints = [LeadCheckpoint(text: "Rules rewritten", at: 0)]
        let live = row(task, ["w-fix": Self.working])
        let model = model(fake, transcript: nil)
        model.request(rows: [live], decisions: [])
        // Written from the checkpoints (no transcript found), and it failed: the checkpoint shows.
        #expect(fake.prompts.count == 1)
        #expect(model.line(live) == nil)
        #expect(live.line(summary: model.line(live)) == "Rules rewritten")

        // Nothing to write from (no transcript, no checkpoint): no call, the activity shows.
        let bare = row(Self.task("bare", .running), ["w-bare": Self.working])
        model.request(rows: [bare], decisions: [])
        #expect(fake.prompts.count == 1)
        #expect(bare.line(summary: model.line(bare)) == "Running swift test")

        // Switched off: no calls, no summaries, even cached ones.
        let off = Fake()
        let disabled = self.model(off, transcript: nil)
        disabled.request(rows: [live], decisions: [])
        #expect(disabled.line(live) == "Making the masker fast on huge inputs")
        disabled.enabled = false
        #expect(disabled.line(live) == nil)
        disabled.request(rows: [row(Self.task("other", .running, title: "Other"), ["w-other": Self.working])].map {
            var row = $0
            row.task.checkpoints = [LeadCheckpoint(text: "x", at: 0)]
            return row
        }, decisions: [])
        #expect(off.prompts.count == 1)
    }

    @Test func aSlowSummaryLeavesTheFallbackUntilItArrives() {
        let fake = Fake()
        var pending: [@Sendable () -> Void] = []
        let model = TeamSummaryModel(generate: { fake.prompts.append($0); return fake.answer }, now: { fake.now },
                                     run: { pending.append($0) }, deliver: { $0() }, perform: { $0() })
        var task = Self.task("fix", .running)
        task.checkpoints = [LeadCheckpoint(text: "Rules rewritten", at: 0)]
        let live = row(task, ["w-fix": Self.working])
        model.request(rows: [live], decisions: [])
        model.request(rows: [live], decisions: [])
        // One request in flight, none duplicated; meanwhile the checkpoint.
        #expect(pending.count == 1)
        #expect(live.line(summary: model.line(live)) == "Rules rewritten")
        pending.removeFirst()()
        #expect(live.line(summary: model.line(live)) == "Making the masker fast on huge inputs")
    }

    @Test func onlyLongDecisionsAreSummarizedOnce() {
        let fake = Fake()
        fake.answer = "Use every worker slot"
        let model = model(fake, transcript: nil)
        let long = Self.decision(String(repeating: "Use all five worker slots and run overlapping tasks ", count: 3), ago: 0)
        let short = Self.decision("Keep the name", ago: 0)
        model.request(rows: [], decisions: [long, short])
        fake.now = 100_000
        model.request(rows: [], decisions: [long, short])
        #expect(fake.prompts.count == 1)
        #expect(fake.prompts[0].contains("Because."))
        #expect(model.line(long) == "Use every worker slot")
        #expect(model.line(short) == nil)
    }
}
