import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The app's side of the all-done cards on scratch boards with a fake generator (never the real Claude): a board that
/// clears after a merge is marked once, its summary is written once off the main thread and stored with the mark (a
/// reopen or relaunch asks for none), AI summaries off ask no model, and opening the lead marks it seen.
@MainActor
@Suite(.serialized)
struct AllDoneWatchTests {
    let temp = Scratch()

    /// What the fake generator was asked, and on which thread.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [String] = []
        private var onMain: [Bool] = []
        func note(_ prompt: String) {
            lock.lock()
            prompts.append(prompt)
            onMain.append(Thread.isMainThread)
            lock.unlock()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return prompts.count }
        var anyOnMain: Bool { lock.lock(); defer { lock.unlock() }; return onMain.contains(true) }
        var last: String? { lock.lock(); defer { lock.unlock() }; return prompts.last }
    }

    func store() throws -> BoardStore {
        let root = temp.url("all-done")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        return BoardStore(root: root.path)
    }

    func task(_ slug: String, _ status: LeadTask.Status, goal: String = "") -> LeadTask {
        LeadTask(slug: slug, title: "Title of \(slug)", contract: LeadContract(goal: goal, acceptance: [], boundaries: [], context: ""), status: status)
    }

    /// Everything queued on `reads` so far has run, its results handed to the main thread too.
    func flush(_ reads: LeadReads) async {
        await withCheckedContinuation { done in reads.async({ _ in }) { done.resume() } }
    }

    /// A watch on `reads` whose writes are counted, with `calls` noting what its generator was asked.
    func watch(_ calls: Calls, reads: LeadReads = LeadReads(),
               answer: String? = "You can sign in now.\n- People sign in with email.\n- It's quicker.\n- It works on phones.") -> (AllDoneWatch, () -> Int) {
        let watch = AllDoneWatch(reads: reads)
        watch.generate = { prompt in
            calls.note(prompt)
            return answer
        }
        var writes = 0
        watch.changed = { _ in writes += 1 }
        return (watch, { writes })
    }

    /// The board goes from a running task to every task done: (the board before, the board after).
    func clear(_ store: BoardStore) throws -> (before: LeadBoard, after: LeadBoard) {
        try store.update { board in board.tasks = [task("add-login", .running, goal: "Users sign in"), task("fix-crash", .running)] }
        try store.update { board in board.tasks[0].status = .done }
        let before = store.load()
        try store.update { board in board.tasks[1].status = .done }
        return (before, store.load())
    }

    @Test func aClearIsMarkedOnceAndSummarizedOnceOffTheMainThread() async throws {
        let store = try store()
        let calls = Calls()
        let (watch, writes) = watch(calls)
        let (before, after) = try clear(store)
        watch.look(root: store.root, previous: before, board: after)
        #expect(await until { writes() == 1 })
        let marked = store.load()
        let mark = try #require(marked.allDone?.first)
        #expect(mark.tasks.map(\.slug) == ["add-login", "fix-crash"])
        #expect(mark.summary == nil)
        #expect(marked.hasUnseenAllDone)
        // The next refresh sees the mark: its summary is asked for, once, off the main thread.
        watch.look(root: store.root, previous: after, board: marked)
        watch.look(root: store.root, previous: after, board: marked)
        #expect(await until { writes() == 2 })
        #expect(calls.count == 1)
        #expect(!calls.anyOnMain)
        #expect(calls.last?.contains("Title of add-login") == true)
        let summarized = store.load()
        #expect(summarized.allDone?.count == 1)
        #expect(summarized.allDone?.first?.summary == .init(headline: "You can sign in now.",
                                                            bullets: ["People sign in with email.", "It's quicker.", "It works on phones."], byModel: true))
        // Reopened, and relaunched (a new watch, no snapshot before): no new mark, no model.
        watch.look(root: store.root, previous: summarized, board: summarized)
        let reads = LeadReads()
        let (relaunched, relaunchWrites) = self.watch(calls, reads: reads)
        relaunched.look(root: store.root, previous: nil, board: summarized)
        relaunched.look(root: store.root, previous: summarized, board: summarized)
        await flush(reads)
        #expect(calls.count == 1)
        #expect(writes() == 2 && relaunchWrites() == 0)
        #expect(store.load() == summarized)
    }

    /// Quit after the mark and before its summary: the next launch writes it, once.
    @Test func aMarkWithoutItsSummaryIsSummarizedAfterARelaunch() async throws {
        let store = try store()
        let (before, after) = try clear(store)
        _ = try store.update { board in BatchSummary.mark(&board, previous: before, now: Date().timeIntervalSince1970) }
        let calls = Calls()
        let (watch, writes) = watch(calls)
        watch.look(root: store.root, previous: nil, board: store.load())
        #expect(await until { writes() == 1 })
        #expect(calls.count == 1)
        #expect(store.load().allDone?.first?.summary?.byModel == true)
        #expect(after.allDone == nil)
    }

    @Test func withAISummariesOffNoModelIsAskedAndTheFallbackIsStored() async throws {
        let store = try store()
        let calls = Calls()
        let (watch, writes) = watch(calls)
        watch.enabled = { false }
        let (before, after) = try clear(store)
        watch.look(root: store.root, previous: before, board: after)
        #expect(await until { writes() == 1 })
        watch.look(root: store.root, previous: after, board: store.load())
        #expect(await until { writes() == 2 })
        #expect(calls.count == 0)
        let summary = try #require(store.load().allDone?.first?.summary)
        #expect(!summary.byModel)
        #expect(summary.bullets == ["Done: Title of add-login.", "Done: Title of fix-crash."])
    }

    /// No Claude (the generator gives nothing: missing, failed or timed out): the written fallback.
    @Test func withoutClaudeTheFallbackIsStored() async throws {
        let store = try store()
        let calls = Calls()
        let (watch, writes) = watch(calls, answer: nil)
        let (before, after) = try clear(store)
        watch.look(root: store.root, previous: before, board: after)
        #expect(await until { writes() == 1 })
        watch.look(root: store.root, previous: after, board: store.load())
        #expect(await until { writes() == 2 })
        #expect(calls.count == 1)
        #expect(store.load().allDone?.first?.summary?.byModel == false)
    }

    /// The sidebar's check: shown for a lead with an unseen card, gone once the lead is opened, on screen at once and
    /// in the board's file.
    @Test func openingTheLeadMarksItsCardsSeen() async throws {
        let store = try store()
        let (before, _) = try clear(store)
        _ = try store.update { board in BatchSummary.mark(&board, previous: before, now: Date().timeIntervalSince1970) }
        let board = store.load()
        #expect(board.hasUnseenAllDone)
        let reads = LeadReads()
        let (watch, writes) = watch(Calls(), reads: reads)
        let seen = try #require(watch.see(root: store.root, board: board))
        #expect(!seen.hasUnseenAllDone)
        #expect(await until { writes() == 1 })
        #expect(!store.load().hasUnseenAllDone)
        // Seen already: nothing to show or write.
        #expect(watch.see(root: store.root, board: store.load()) == nil)
        // A refresh read before the write still shows it unseen: shown seen again, and not written twice.
        #expect(watch.see(root: store.root, board: board) != nil)
        let written = store.load()
        await flush(reads)
        #expect(writes() == 1 && store.load() == written)
    }
}
