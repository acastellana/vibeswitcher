import Foundation
import Testing
@testable import VibeCore

/// The all-done card's detection (pure, from two board snapshots and the last mark), its persisted mark, and its
/// summary's input, prompt, parsing and fallback. Scratch boards and a fake generator only: never a real Claude.
struct BatchSummaryTests {
    let temp = Scratch()
    let now = 1_800_000_000.0

    /// A token assembled at runtime, so secret scanners don't flag this file.
    let token = "ghp" + "_" + String(String(repeating: "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789", count: 2).prefix(36))

    /// A task made `created` seconds before `now`, in `status` since `since` seconds before `now`.
    func task(_ slug: String, _ status: LeadTask.Status, created: Double = 3_600, since: Double = 600, goal: String = "") -> LeadTask {
        var task = LeadTask(slug: slug, title: "Title of \(slug)", contract: LeadContract(goal: goal, acceptance: [], boundaries: [], context: ""),
                            status: status)
        task.createdAt = now - created
        task.since = now - since
        return task
    }

    func board(_ tasks: [LeadTask]) -> LeadBoard {
        var board = LeadBoard()
        board.tasks = tasks
        return board
    }

    // MARK: Detection

    @Test func itFiresOnceWhenOpenWorkClearsWithAMerge() throws {
        let before = board([task("a", .done, since: 900), task("b", .running)])
        var after = board([task("a", .done, since: 900), task("b", .done, since: 10)])
        let mark = try #require(BatchSummary.detect(previous: before, current: after, now: now, id: "m1"))
        #expect(mark.tasks.map(\.slug) == ["a", "b"])
        #expect(mark.merged == 2)
        #expect(mark.at == now)
        #expect(BatchSummary.mark(&after, previous: before, now: now, id: "m1") == mark)
        #expect(after.allDone?.map(\.id) == ["m1"])
        // The next look sees the board clear already; a stale snapshot (another window's) finds the batch empty.
        #expect(BatchSummary.detect(previous: after, current: after, now: now + 3) == nil)
        #expect(BatchSummary.mark(&after, previous: before, now: now + 3) == nil)
        #expect(after.allDone?.count == 1)
    }

    @Test func aBoardAlreadyClearIsNoClear() {
        let clear = board([task("a", .done), task("b", .folded)])
        // Launch, relaunch, an install's handover: no snapshot before.
        #expect(BatchSummary.detect(previous: nil, current: clear, now: now) == nil)
        #expect(BatchSummary.detect(previous: clear, current: clear, now: now) == nil)
        // An empty board isn't a cleared one either.
        #expect(BatchSummary.detect(previous: LeadBoard(), current: LeadBoard(), now: now) == nil)
    }

    @Test func aBoardThatClearsWithoutAMergeIsNoClear() {
        let before = board([task("a", .running), task("b", .failed)])
        var abandoned = task("b", .failed)
        abandoned.worker = "w"
        // Abandoned, folded and a failed task cleaned up: finished, and nothing merged.
        let after = board([task("a", .abandoned, since: 5), abandoned, task("c", .folded, since: 5)])
        #expect(!BatchSummary.hasOpenWork(after))
        #expect(BatchSummary.detect(previous: before, current: after, now: now) == nil)
    }

    /// Planned, running, review, blocked, kept and failed are open work; done, folded, abandoned and reverted aren't.
    @Test func theOpenStatesAreTheBoardsUnfinishedOnes() {
        for status in LeadTask.Status.allCases {
            let closed = [LeadTask.Status.done, .folded, .abandoned, .reverted].contains(status)
            #expect(BatchSummary.isClosed(task("x", status)) == closed, "\(status)")
        }
        let open = board([task("a", .done), task("k", .kept)])
        #expect(BatchSummary.hasOpenWork(open))
        #expect(BatchSummary.detect(previous: board([task("k", .running)]), current: open, now: now) == nil)
    }

    /// A task removed from the board (made by mistake) leaves it clear; it isn't one of the batch.
    @Test func aRemovedTaskClearsTheBoardButIsntInTheBatch() throws {
        let before = board([task("a", .done, since: 30), task("oops", .planned)])
        var after = board([task("a", .done, since: 30)])
        after.removed = [task("oops", .planned)]
        let mark = try #require(BatchSummary.detect(previous: before, current: after, now: now))
        #expect(mark.tasks.map(\.slug) == ["a"])
    }

    @Test func aBatchIsWhatClosedSinceThePreviousMark() throws {
        var marked = board([task("old", .done, created: 7_200, since: 5_000)])
        marked.allDone = [LeadAllDone(id: "m0", at: now - 4_000, since: now - 7_200, tasks: [.init(slug: "old", title: "Old", outcome: .merged)])]
        let before = { var board = marked; board.tasks += [self.task("new", .running, created: 3_000), self.task("gone", .running, created: 3_000)]; return board }()
        let after = { var board = marked; board.tasks += [self.task("new", .done, created: 3_000, since: 20), self.task("gone", .abandoned, created: 3_000, since: 10)]; return board }()
        let mark = try #require(BatchSummary.detect(previous: before, current: after, now: now))
        #expect(mark.tasks.map(\.slug) == ["new", "gone"])
        #expect(mark.tasks.map(\.outcome) == [.merged, .abandoned])
        #expect(mark.merged == 1)
        #expect(mark.since == now - 4_000)
    }

    /// The first mark on a board doesn't hold the board's whole history: it starts when the board was last clear.
    @Test func withNoMarkTheBatchStartsWhenTheBoardWasLastClear() throws {
        // Yesterday's run (two overlapping tasks), a clear gap, then today's (two overlapping, one created later).
        let history = [task("y1", .done, created: 90_000, since: 85_000), task("y2", .done, created: 88_000, since: 80_000)]
        let before = board(history + [task("t1", .done, created: 3_000, since: 1_000), task("t2", .running, created: 2_000)])
        let after = board(history + [task("t1", .done, created: 3_000, since: 1_000), task("t2", .done, created: 2_000, since: 5)])
        let mark = try #require(BatchSummary.detect(previous: before, current: after, now: now))
        #expect(mark.tasks.map(\.slug) == ["t1", "t2"])
        #expect(mark.since == now - 3_000)
    }

    /// The mark is on the board's file: old boards decode without it, and a relaunch (no snapshot before) neither
    /// repeats it nor loses it.
    @Test func theMarkPersistsInTheBoardAndOldBoardsStillDecode() throws {
        let old = #"{"tasks":[],"questions":[],"updates":[]}"#
        let decoded = try JSONDecoder().decode(LeadBoard.self, from: Data(old.utf8))
        #expect(decoded.allDone == nil)
        #expect(!decoded.hasUnseenAllDone)

        let root = temp.url("board")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        let store = BoardStore(root: root.path)
        try store.update { board in board.tasks = [task("a", .running)] }
        let before = store.load()
        try store.update { board in board.tasks[0].status = .done }
        let mark = try #require(try store.update { board in BatchSummary.mark(&board, previous: before, now: now) })
        // Relaunched: the board as it is on disk, nothing before it.
        let relaunched = store.load()
        #expect(relaunched.allDone == [mark])
        #expect(BatchSummary.detect(previous: nil, current: relaunched, now: now + 60) == nil)
        // Its summary is written once: a second one doesn't replace it.
        let summary = LeadAllDone.Summary(headline: "Done.", bullets: ["One"], byModel: true)
        let first = try store.update { board in board.setAllDoneSummary(summary, for: mark.id) }
        let second = try store.update { board in board.setAllDoneSummary(.init(headline: "Again", bullets: ["Two"], byModel: true), for: mark.id) }
        #expect(first && !second)
        #expect(store.load().allDone?.first?.summary == summary)
    }

    /// The sidebar's check: shown while a mark is unseen, gone once the lead is opened.
    @Test func aMarkIsUnseenUntilTheLeadIsOpened() {
        var board = board([task("a", .done)])
        #expect(!board.hasUnseenAllDone)
        let nothing = board.seeAllDone(at: now)
        #expect(!nothing)
        board.allDone = [LeadAllDone(id: "m1", at: now, since: now - 60, tasks: [])]
        #expect(board.hasUnseenAllDone)
        let seen = board.seeAllDone(at: now + 5)
        #expect(seen)
        #expect(!board.hasUnseenAllDone)
        #expect(board.allDone?.first?.seenAt == now + 5)
        // Seen already: nothing changes.
        let again = board.seeAllDone(at: now + 9)
        #expect(!again)
        #expect(board.allDone?.first?.seenAt == now + 5)
    }

    // MARK: The summary

    func marked() -> (mark: LeadAllDone, board: LeadBoard) {
        var board = board([task("add-login", .done, since: 100, goal: "Users log in with their email; the key is \(token)"),
                           task("fix-crash", .done, since: 50, goal: "The app no longer crashes on start (see abc1234def)")])
        board.updates = [LeadUpdate(title: "Login works", body: "Screenshot attached"), LeadUpdate(title: "Too old", body: "")]
        board.updates[0].at = now - 30
        board.updates[1].at = now - 9_999
        let mark = LeadAllDone(id: "m1", at: now, since: now - 3_600,
                               tasks: [.init(slug: "add-login", title: "Add login", outcome: .merged),
                                       .init(slug: "fix-crash", title: "Fix the crash at start", outcome: .merged)])
        return (mark, board)
    }

    @Test func theInputIsTheBatchsTitlesGoalsAndPostsRedacted() {
        let (mark, board) = marked()
        let input = BatchSummary.input(mark, board: board, project: "acme")
        let prompt = BatchSummaryPrompts.prompt(input)
        #expect(prompt.contains("Add login"))
        #expect(prompt.contains("Users log in with their email"))
        #expect(prompt.contains("Fix the crash at start"))
        #expect(prompt.contains("Login works: Screenshot attached"))
        // Posted before the batch began: not this batch's.
        #expect(!prompt.contains("Too old"))
        // The secret in a goal never reaches the prompt; nor does a commit id.
        #expect(!prompt.contains(token))
        #expect(!prompt.contains("abc1234def"))
        #expect(input.taskCount == 2 && input.merged == 2)
    }

    @Test func theInputIsBounded() {
        let tasks = (0..<80).map { task("t\($0)", .done, goal: String(repeating: "a long goal ", count: 200)) }
        var board = board(tasks)
        board.updates = (0..<40).map { var update = LeadUpdate(title: "Result \($0)", body: String(repeating: "body ", count: 400)); update.at = now - 10; return update }
        let mark = LeadAllDone(at: now, since: now - 3_600, tasks: tasks.map { .init(slug: $0.slug, title: String(repeating: "T", count: 900), outcome: .merged) })
        let input = BatchSummary.input(mark, board: board, project: "acme")
        #expect(input.tasks.count == BatchSummary.tasksShown)
        #expect(input.updates.count == BatchSummary.updatesShown)
        #expect(input.tasks.allSatisfy { $0.title.count <= BatchSummary.titleLimit && $0.goal.count <= BatchSummary.goalLimit })
        #expect(input.text.count <= BatchSummary.inputLimit)
        #expect(input.lines.contains("- (and 50 more tasks)"))
    }

    @Test func theSummaryIsTheModelsHeadlineAndBullets() {
        let (mark, board) = marked()
        var prompts: [String] = []
        let summary = BatchSummary.write(BatchSummary.input(mark, board: board, project: "acme"), tasks: mark.tasks, enabled: true) { prompt in
            prompts.append(prompt)
            return "**You can now sign in.**\n\n- People sign in with their email.\n- The app opens without crashing.\n* It's ready to try today.\n"
        }
        #expect(prompts.count == 1)
        #expect(summary == .init(headline: "You can now sign in.",
                                 bullets: ["People sign in with their email.", "The app opens without crashing.", "It's ready to try today."], byModel: true))
        // Its own system prompt: simple words, no code terms.
        #expect(BatchSummaryPrompts.system.contains("doesn't read code"))
        #expect(BatchSummaryPrompts.system.contains("Never mention file names"))
        #expect(BatchSummaryPrompts.prompt(BatchSummary.input(mark, board: board, project: "acme")).contains("3 to 6"))
    }

    @Test func parsingDropsMarkdownAndKeepsAtMostSixBullets() throws {
        let parsed = try #require(BatchSummary.parse("# Big day\n1. One\n2) Two `thing`\n- 3\n- 4\n- 5\n- 6\n- 7"))
        #expect(parsed.headline == "Big day")
        #expect(parsed.bullets == ["One", "Two thing", "3", "4", "5", "6"])
        // A headline alone, or nothing, isn't a summary.
        #expect(BatchSummary.parse("Just one line.") == nil)
        #expect(BatchSummary.parse("  \n ") == nil)
    }

    /// No Claude, a failure or a timeout (all nil to the writer), or an answer of the wrong shape: the written fallback.
    @Test func withoutClaudeTheFallbackListsTheTitles() {
        let (mark, board) = marked()
        let input = BatchSummary.input(mark, board: board, project: "acme")
        for answer in [nil, "", "One line only"] as [String?] {
            let summary = BatchSummary.write(input, tasks: mark.tasks, enabled: true) { _ in answer }
            #expect(!summary.byModel)
            #expect(summary.headline == "All 2 tasks are finished; every one of them merged.")
            #expect(summary.bullets == ["Done: Add login.", "Done: Fix the crash at start."])
        }
        let many = (0..<9).map { LeadAllDone.Task(slug: "t\($0)", title: "Task \($0)", outcome: $0 == 0 ? .folded : $0 == 1 ? .abandoned : .merged) }
        let fallback = BatchSummary.fallback(many)
        #expect(fallback.headline == "All 9 tasks are finished; 7 of them merged.")
        #expect(fallback.bullets.count == BatchSummary.bulletLimit)
        #expect(fallback.bullets[0] == "Done as part of another task: Task 0.")
        #expect(fallback.bullets[1] == "Set aside: Task 1.")
        #expect(fallback.bullets.last == "And 4 more, listed below.")
        #expect(BatchSummary.fallback([.init(slug: "a", title: "A", outcome: .merged)]).headline == "The last task is finished and merged.")
    }

    @Test func withAISummariesOffNoModelIsCalled() {
        let (mark, board) = marked()
        var calls = 0
        let summary = BatchSummary.write(BatchSummary.input(mark, board: board, project: "acme"), tasks: mark.tasks, enabled: false) { _ in
            calls += 1
            return "Headline\n- bullet"
        }
        #expect(calls == 0)
        #expect(!summary.byModel)
    }

    // MARK: The chat

    func entry(_ id: String, at: Double?) -> ChatEntry { ChatEntry(id: id, at: at.map { Date(timeIntervalSince1970: $0) }, kind: .reply(id)) }

    @Test func aCardGoesWhereTheBoardCleared() {
        let items: [ChatItem] = [.reply(entry("r1", at: now - 300)), .reply(entry("r2", at: nil)), .reply(entry("r3", at: now - 100)),
                                 .reply(entry("r4", at: now + 100))]
        let early = LeadAllDone(id: "early", at: now - 9_000, since: 0, tasks: [])
        let middle = LeadAllDone(id: "middle", at: now - 200, since: 0, tasks: [])
        let late = LeadAllDone(id: "late", at: now + 500, since: 0, tasks: [])
        let placed = BatchSummary.place([late, early, middle], in: items).map(\.id)
        // Before the conversation's first item: another lead's, or a page not loaded: not shown.
        #expect(placed == ["r1", "r2", "all-done:middle", "r3", "r4", "all-done:late"])
        #expect(BatchSummary.place([middle], in: []).isEmpty)
        #expect(BatchSummary.place([], in: items) == items)
    }

    @Test func searchFindsTheCard() {
        var mark = LeadAllDone(id: "m", at: now, since: 0, tasks: [.init(slug: "a", title: "Add login", outcome: .merged)])
        mark.summary = .init(headline: "You can sign in", bullets: ["With email"], byModel: true)
        let items: [ChatItem] = [.allDone(mark)]
        #expect(ChatSearch.matches(items, query: "email") == ["all-done:m"])
        #expect(ChatSearch.matches(items, query: "login") == ["all-done:m"])
        #expect(ChatSearch.matches(items, query: "all tasks finished") == ["all-done:m"])
        #expect(ChatSearch.matches(items, query: "nothing here").isEmpty)
    }
}
