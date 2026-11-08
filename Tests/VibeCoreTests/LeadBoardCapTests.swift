import Foundation
import Testing
@testable import VibeCore

/// board.json and the records stop growing without bound: updates and closed questions past the cap go to the board's
/// archive and stay readable; the budget's clock writes the board at most every 5 minutes; progress.md rolls over
/// monthly; scratch folders cut short leave at the tool server's start, and a task's merge log with the archive.
struct LeadBoardCapTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    static let now = 2_000_000_000.0

    func store() throws -> BoardStore {
        let url = temp.url("project")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        return BoardStore(root: url.path)
    }

    /// `count` updates, the n-th `at` n seconds after the first, its title naming it.
    static func updates(_ count: Int) -> [LeadUpdate] {
        (0..<count).map { n in
            var update = LeadUpdate(id: "U\(n)", title: "Update \(n)", body: "body of \(n)")
            update.at = now - Double(count - n)
            return update
        }
    }

    /// A question asked at `n` and answered a minute later.
    static func closed(_ n: Int, task: String? = nil) -> LeadQuestion {
        var question = LeadQuestion(text: "Question \(n)", options: ["a"], priority: nil, whyNow: nil, proposal: nil, decideIn: nil, at: now - Double(10_000 - n) * 120)
        question.id = "Q\(n)"
        question.task = task
        question.answer = "a"
        question.answeredAt = question.askedAt + 60
        question.answeredVersion = 1
        return question
    }

    // MARK: The cap

    @Test func updatesPastTheCapMoveToTheArchiveAndStayReadable() throws {
        let store = try store()
        try store.update { $0.updates = Self.updates(300) }
        #expect(try store.archive(now: Self.now) == 250)
        let board = store.load()
        #expect(board.updates.count == LeadBoard.keptUpdates)
        #expect(board.updates.map(\.id) == (250..<300).map { "U\($0)" }) // The latest stay, in order.
        #expect(store.archivedUpdates().map(\.id) == (0..<250).map { "U\($0)" })
        // Read together, nothing lost and nothing doubled, in the order they were made.
        #expect(store.loadAll().updates.map(\.id) == (0..<300).map { "U\($0)" })
    }

    @Test func closedQuestionsPastTheCapMoveToTheArchiveAndTheirMinutesStayCounted() throws {
        let store = try store()
        try store.update { board in
            board.tasks = [LeadBudgetTests.task(budget: 0)]
            board.tasks[0].slug = "live-task"
            // 300 closed questions, one about a task still on the board (the oldest closed), and an open one.
            board.questions = (0..<300).map { Self.closed($0, task: $0 == 0 ? "live-task" : nil) }
            board.ask("Still open?", options: ["yes"], priority: nil, whyNow: nil, at: Self.now)
        }
        let before = LeadScorecard(store.load(), now: Self.now).userMinutes
        #expect(try store.archive(now: Self.now) == 249)
        let board = store.load()
        // The latest closed stay, and the open one, and the one the live task's score counts.
        #expect(board.questions.filter(\.isOpen).count == 1)
        #expect(board.questions.filter { !$0.isOpen }.count == LeadBoard.keptClosedQuestions + 1)
        #expect(board.questions.contains { $0.id == "Q0" })
        #expect(!board.questions.contains { $0.id == "Q10" })
        #expect(store.archivedQuestions().contains { $0.id == "Q10" })
        #expect(store.loadAll().questions.count == 301)
        // The scorecard, from board.json alone and from the board with its archive, is unchanged.
        #expect(abs(LeadScorecard(board, now: Self.now).userMinutes - before) < 0.001)
        #expect(abs(LeadScorecard(store.loadAll(), now: Self.now).userMinutes - before) < 0.001)
    }

    @Test func aCrashPartWayNeitherLosesNorDoublesUpdatesOrQuestions() throws {
        let store = try store()
        try store.update {
            $0.updates = Self.updates(60)
            $0.questions = (0..<60).map { Self.closed($0) }
        }
        let written = try Data(contentsOf: URL(fileURLWithPath: store.file))
        try store.archive(now: Self.now)
        let archive = try String(contentsOfFile: store.archiveFile, encoding: .utf8)
        // Crashed after the archive took them and before the board was written.
        try written.write(to: URL(fileURLWithPath: store.file))
        try store.archive(now: Self.now)
        #expect(try String(contentsOfFile: store.archiveFile, encoding: .utf8) == archive)
        #expect(store.load().updates.count == LeadBoard.keptUpdates)
        #expect(store.loadAll().updates.count == 60 && store.loadAll().questions.count == 60)
    }

    @Test func archivingTwiceMovesNothingMoreAndTheArchiveStaysTasksFirstReadable() throws {
        let store = try store()
        try store.update {
            $0.updates = Self.updates(300)
            $0.tasks = [LeadBoardArchiveTests.task("old", .done, finished: Self.now - 2 * 86_400)]
        }
        try store.archive(now: Self.now)
        #expect(try store.archive(now: Self.now) == 0)
        #expect(store.archived().map(\.slug) == ["old"])
        #expect(store.archivedUpdates().count == 250)
    }

    /// A task brought back for an update has its archived questions back with it, counted by its score again.
    @Test func aRestoredTaskTakesItsQuestionsBackOutOfTheTally() throws {
        let store = try store()
        try store.update { board in
            board.tasks = [LeadBoardArchiveTests.task("old", .done, finished: Self.now - 2 * 86_400)]
            board.questions = (0..<60).map { Self.closed($0, task: $0 == 0 ? "old" : nil) }
        }
        let minutes = LeadScorecard(store.load(), now: Self.now).userMinutes
        try store.archive(now: Self.now)
        #expect(store.archivedQuestions().contains { $0.id == "Q0" })
        try store.update { board in _ = store.restore("old", into: &board) }
        let board = store.load()
        #expect(board.questions.contains { $0.id == "Q0" })
        #expect(abs(LeadScorecard(board, now: Self.now).userMinutes - minutes) < 0.001)
    }

    @Test func aBoardOfThreeHundredUpdatesShrinksWhenTheLeadsServerLoadsItAndNoneIsLost() throws {
        let root = try makeRepo()
        let store = BoardStore(root: root)
        try store.prepare()
        try store.update { board in
            board.updates = Self.updates(300)
            board.questions = (0..<120).map { Self.closed($0) }
        }
        let lead = try lead(root, FakeRuntime())
        #expect(lead.store.load().updates.count == LeadBoard.keptUpdates)
        #expect(lead.store.load().questions.count == LeadBoard.keptClosedQuestions)
        // Findable through board(task) (an update names no task: by its title) and questions.
        let found = lead.call("board", ["task": "Update 7"])
        #expect(!found.isError && found.text.contains("body of 7"), "\(found.text)")
        #expect(lead.call("questions", [:]).text.contains("Question 3"))
        #expect(lead.store.loadAll().updates.count == 300)
    }

    /// The Setup stats read closed questions from the board's archive too: its numbers don't shrink with the cap.
    @Test func setupStatsCountTheQuestionsTheArchiveTook() throws {
        let store = try store()
        try store.update { $0.questions = (0..<120).map { Self.closed($0) } }
        try store.archive(now: Self.now)
        #expect(store.load().questions.count == LeadBoard.keptClosedQuestions)
        let view = try #require(BoardView(path: store.file))
        #expect(view.questions.count == 120)
        #expect(Set(view.questions.map(\.id)).count == 120)
    }

    @Test func boardOfATaskListsItsArchivedQuestionsAndTheUpdatesNamingIt() throws {
        let root = try makeRepo()
        let store = BoardStore(root: root)
        try store.prepare()
        let lead = try lead(root, FakeRuntime())
        try store.update { board in
            board.tasks = [LeadBoardArchiveTests.task("some-task", .done, finished: Self.now - 2 * 86_400)]
            board.updates = Self.updates(60)
            board.updates[0].title = "Merged some-task at last"
            board.questions = (0..<60).map { Self.closed($0, task: $0 == 0 ? "some-task" : nil) }
        }
        try store.archive(now: Self.now)
        let text = lead.call("board", ["task": "some-task"]).text
        #expect(text.contains("Question 0") && text.contains("Merged some-task at last"), "\(text)")
    }

    // MARK: The budget's clock

    func boardBytes(_ store: BoardStore) -> Data { (try? Data(contentsOf: URL(fileURLWithPath: store.file))) ?? Data() }

    /// The witness's looks every 3 s, as `LeadController` does: read the board, ask, then write off the main thread.
    func look(_ store: BoardStore, from: Double, for seconds: Double, defaultMinutes: Int = 120, seen: LeadWitness.Seen = LeadBudgetTests.working,
              each: (Double, [LeadTask]) -> Void) throws {
        var now = from
        while now <= from + seconds {
            let board = store.load()
            let working = LeadBudget.working(board: board, seen: ["w1": seen])
            var reached: [LeadTask] = []
            if board.notesWork(working, defaultMinutes: defaultMinutes, now: now, clock: store.budgetClock()) {
                reached = try store.noteWork(working, defaultMinutes: defaultMinutes, now: now)
            }
            each(now, reached)
            now += 3
        }
    }

    @Test func aWorkingMinuteRewritesTheBoardAtMostEveryFiveMinutes() throws {
        let store = try store()
        let t0 = LeadBudgetTests.t0
        try store.update { $0.tasks = [LeadBudgetTests.task(budget: 0)] }
        var bytes = boardBytes(store)
        var writes = 0
        try look(store, from: t0, for: 30 * 60) { _, _ in
            let now = boardBytes(store)
            if now != bytes {
                writes += 1
                bytes = now
            }
        }
        // 30 minutes of looks: at most one write every 5 minutes for the count alone.
        #expect((1...6).contains(writes), "\(writes)")
        var board = store.load()
        store.budgetClock().apply(to: &board)
        #expect(board.tasks[0].worked == Double(30 * 60))
        // The board took most of it, the clock the last few minutes.
        #expect((store.load().tasks[0].worked ?? 0) >= 25 * 60)
    }

    @Test func aWorkerIsStoppedAtItsBudgetOnTimeAndTheBoardSaysSoAtOnce() throws {
        let store = try store()
        let t0 = LeadBudgetTests.t0
        try store.update { $0.tasks = [LeadBudgetTests.task(budget: 1)] }
        var told: [Double] = []
        try look(store, from: t0, for: 10 * 60) { now, reached in
            told += reached.map { _ in now - t0 }
        }
        #expect(told == [60], "\(told)")
        let task = store.load().tasks[0]
        #expect(task.overBudget?.minutes == 1)
        #expect(task.overBudget?.at == t0 + 60)
        // A stop isn't forgotten: the next looks don't tell it again, and its running time stays counted.
        #expect((task.worked ?? 0) >= 5 * 60)
    }

    @Test func aTaskThatStopsRunningGetsItsCountOnTheBoardAtOnce() throws {
        let store = try store()
        let t0 = LeadBudgetTests.t0
        try store.update { $0.tasks = [LeadBudgetTests.task(budget: 0)] }
        try look(store, from: t0, for: 90) { _, _ in }
        #expect((store.load().tasks[0].worked ?? 0) == 0) // Only the clock has the minute yet.
        try store.update { $0.tasks[0].status = .review }
        try look(store, from: t0 + 93, for: 6) { _, _ in }
        let task = store.load().tasks[0]
        #expect((task.worked ?? 0) >= 60 && task.workedAt == nil)
        #expect(store.budgetClock().entries.isEmpty)
    }

    @Test func replanningATaskDropsItsCountOnTheClock() throws {
        let store = try store()
        let t0 = LeadBudgetTests.t0
        try store.update { $0.tasks = [LeadBudgetTests.task(budget: 0)] }
        try look(store, from: t0, for: 90) { _, _ in }
        try store.update { board in
            board.tasks[0].worked = nil
            board.tasks[0].workedAt = nil
            store.dropBudgetClock(board.tasks[0].id)
        }
        var board = store.load()
        store.budgetClock().apply(to: &board)
        #expect(board.tasks[0].worked == nil)
    }

    // MARK: progress.md

    func progressStore() throws -> BoardStore {
        let root = try makeRepo()
        let store = BoardStore(root: root)
        try store.prepare()
        return store
    }

    @Test func progressMovesLastMonthsEntriesToItsArchiveUnchanged() throws {
        let store = try progressStore()
        let path = store.recordPath("progress.md")
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let old = "- 2026-10-31 23:59 Last of October\n  with a second line\n- 2026-10-02 10:00 Also October\n"
        let kept = "- 2026-11-01 00:01 First of November\n"
        try ("# Progress\n\n" + old + kept).write(toFile: path, atomically: true, encoding: .utf8)
        let now = Date(timeIntervalSince1970: 1_794_100_000) // 2026-11-0x, local
        #expect(try LeadRecords.rollProgress(store, now: now) == 2)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "# Progress\n\n" + kept)
        let archive = try String(contentsOfFile: store.recordPath("progress-archive.md"), encoding: .utf8)
        #expect(archive.hasPrefix("# Archived progress") && archive.hasSuffix(old))
        // A second flush moves nothing, and appends nothing.
        #expect(try LeadRecords.rollProgress(store, now: now) == 0)
        #expect(try String(contentsOfFile: store.recordPath("progress-archive.md"), encoding: .utf8) == archive)
        #expect(LeadRecords.paths("docs/lead").contains("docs/lead/progress-archive.md"))
    }

    @Test func aRollCutShortLosesNothingAndDoublesNothing() throws {
        let store = try progressStore()
        let path = store.recordPath("progress.md"), archivePath = store.recordPath("progress-archive.md")
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let text = "# Progress\n\n- 2026-10-02 10:00 Also October\n"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let now = Date(timeIntervalSince1970: 1_794_100_000)
        try LeadRecords.rollProgress(store, now: now)
        let archive = try String(contentsOfFile: archivePath, encoding: .utf8)
        // The crash left the archive written and progress.md as it was.
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try LeadRecords.rollProgress(store, now: now)
        #expect(try String(contentsOfFile: archivePath, encoding: .utf8) == archive)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "# Progress\n\n")
    }

    @Test func statusSaysOnceThatProgressIsPastItsSize() throws {
        let store = try progressStore()
        let path = store.recordPath("progress.md")
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try ("# Progress\n\n" + String(repeating: "x", count: LeadRecords.progressNudgeBytes + 1)).write(toFile: path, atomically: true, encoding: .utf8)
        let lead = try lead(store.root, FakeRuntime())
        #expect(lead.call("status", [:]).text.contains("read its tail"))
        #expect(!lead.call("status", [:]).text.contains("read its tail"))
    }

    // MARK: The scratch sweep

    func makeRepo() throws -> String {
        let root = temp.url("repo").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["commit", "-q", "--allow-empty", "-m", "first"]] {
            _ = Git.run(args, in: root)
        }
        return root
    }

    func leftover(_ lead: LeadToolset, _ name: String) throws -> String {
        let path = vault.scratch(root: lead.root, name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test func theSweepRemovesAnUnlockedLeftoverAndNeverALiveLockOrARunningTasksFolder() throws {
        let root = try makeRepo()
        let lead = try lead(root, FakeRuntime())
        try lead.store.update { board in
            board.tasks = [LeadBudgetTests.task(budget: 0), LeadBudgetTests.task(budget: 0, .review)]
            board.tasks[0].slug = "still-running"
            board.tasks[1].slug = "in-review"
            board.tasks[1].id = "id-review"
        }
        let gone = ["merge-finished", "merge-finished-home", "audit-finished", "audit-finished-home", "revert-finished", "merge-gone-task"]
        let paths = try gone.map { try leftover(lead, $0) }
        // A running task's and a task in review's, whichever the kind: never.
        for keep in ["merge-still-running", "audit-still-running-home", "audit-in-review", "merge-in-review-home", "remote-git", "still-running"] {
            _ = try leftover(lead, keep)
        }
        // A merge holding the base's lock keeps merge folders; an audit's lock keeps its audit folders.
        let baseLock = vault.scratch(root: root, "merge-into-abcd.lock")
        try vault.ensurePrivate(baseLock.deletingLastPathComponent())
        let mergeRunning = try #require(FileLock.attempt(baseLock.path))
        let auditLock = (lead.store.folder as NSString).appendingPathComponent("run/audit-locked.lock")
        let auditRunning = try #require(FileLock.attempt(auditLock))
        let lockedAudit = try leftover(lead, "audit-locked")
        var removed = Set(lead.sweepScratch())
        #expect(removed == ["audit-finished", "audit-finished-home"], "\(removed)")
        #expect(FileManager.default.fileExists(atPath: lockedAudit))
        mergeRunning.release()
        removed = Set(lead.sweepScratch())
        #expect(removed.isSuperset(of: ["merge-finished", "merge-finished-home", "revert-finished", "merge-gone-task"]), "\(removed)")
        for path in paths { #expect(!FileManager.default.fileExists(atPath: path), "\(path)") }
        // Still held: the audit's folder stays; the next sweep, with the lock gone, takes it.
        #expect(FileManager.default.fileExists(atPath: lockedAudit))
        auditRunning.release()
        #expect(lead.sweepScratch().contains("audit-locked"))
        // The kept ones are all there still.
        for keep in ["merge-still-running", "audit-still-running-home", "audit-in-review", "merge-in-review-home", "remote-git", "still-running"] {
            #expect(FileManager.default.fileExists(atPath: vault.scratch(root: root, keep).path), "\(keep)")
        }
        // The merge-into lock file itself is not a leftover.
        #expect(FileManager.default.fileExists(atPath: baseLock.path))
    }

    @Test func aTasksMergeLogGoesWhenItsArchived() throws {
        let root = try makeRepo()
        try BoardStore(root: root).prepare()
        let lead = try lead(root, FakeRuntime())
        let log = try #require(lead.saveMergeLog("the merge's output", slug: "old-merge"))
        let live = try #require(lead.saveMergeLog("a live task's output", slug: "not-yet-archived"))
        // Older than the archive's age, and a day since it left the board.
        try lead.store.update { board in
            board.tasks = [LeadBoardArchiveTests.task("old-merge", .done, finished: Date().timeIntervalSince1970 - 3 * 86_400)]
        }
        lead.archiveFinished(force: true)
        #expect(!FileManager.default.fileExists(atPath: log))
        #expect(FileManager.default.fileExists(atPath: live))
        #expect(lead.store.archived().map(\.slug) == ["old-merge"])
    }
}
