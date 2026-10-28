import Foundation
import Testing
@testable import VibeCore

/// The lead's tools with a board whose finished tasks went to its archive (`BoardStore.archive`): the lead's server
/// moves them on its start and at most hourly after a merge, and every tool that needs a finished task still finds it.
struct LeadArchiveToolTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("archive-lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// A lead whose merges run `true` as their tests and need no audit, and that moves nothing on by itself.
    func team() throws -> (root: String, runtime: FakeRuntime, lead: LeadToolset) {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.power = { nil }
        let configured = lead.call("configure", ["merge_policy": "auto", "test_command": "true", "auto_advance": false])
        #expect(!configured.isError, "\(configured.text)")
        return (root, runtime, lead)
    }

    /// `slug` added, worked on (`file`), reported done, merged and cleaned up.
    func merged(_ slug: String, file: String, _ lead: LeadToolset, _ runtime: FakeRuntime, root: String) throws {
        #expect(!lead.call("add_task", ["title": slug.capitalized, "goal": "g", "acceptance": ["a"]]).isError)
        #expect(!lead.call("start_worker", ["task": slug]).isError)
        let worktree = Worktrees.path(root: root, slug: slug)
        try "\(slug)\n".write(toFile: worktree + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: worktree)
        Git.run(["commit", "-q", "-m", "add \(file)"], in: worktree)
        #expect(!(try seat("worker-\(slug)", runtime)).call("report", doneReport("added \(file)")).isError)
        let merged = lead.call("merge", ["task": slug])
        #expect(!merged.isError, "\(merged.text)")
        #expect(!lead.call("cleanup", ["task": slug]).isError)
    }

    /// Ages `slugs` on the board by two days, as if they finished then.
    func age(_ slugs: [String], root: String) throws {
        let store = BoardStore(root: root)
        var board = try store.read()
        for index in board.tasks.indices where slugs.contains(board.tasks[index].slug) {
            board.tasks[index].since = (board.tasks[index].since ?? 0) - 2 * 86_400
            board.tasks[index].merged?.at -= 2 * 86_400
        }
        try store.locked { try store.write(board) }
    }

    func line(_ text: String, _ prefix: String) -> String? {
        text.split(separator: "\n").map(String.init).first { $0.hasPrefix(prefix) }
    }

    @Test func boardStatusRevertReceiptsScorecardAndSlugsFindAnArchivedTask() throws {
        let (root, runtime, lead) = try team()
        try merged("change", file: "b.txt", lead, runtime, root: root)
        try age(["change"], root: root)
        let store = BoardStore(root: root)
        let full = lead.call("board", ["task": "change"]).text
        let listing = lead.call("board", [:]).text
        let status = lead.call("status", [:]).text
        #expect(line(status, "done (1)") == "done (1): change (unaudited)", "\(status)")

        lead.archiveFinished(force: true)
        #expect(store.load().task("change") == nil)
        #expect(store.archived().map(\.slug) == ["change"])
        // board(task) and board are as before the archive: the task in full, its receipt, the scorecard line.
        // (Its score as of its last change on the board: an archived task's isn't counted again.)
        let unstamped = { (text: String) in text.replacing(#/"asOf" : [0-9.]+/#, with: "") }
        #expect(unstamped(lead.call("board", ["task": "change"]).text) == unstamped(full))
        #expect(full.contains("\"slug\" : \"change\"") && full.contains("\"receipt\""), "\(full)")
        #expect(lead.call("board", [:]).text == listing)
        #expect(listing.contains("- change [done]") && listing.contains("Scorecard (1 merged"), "\(listing)")
        // status counts it and doesn't name it; its receipts line is the same.
        let after = lead.call("status", [:]).text
        #expect(after.contains("— 1 task(s)"), "\(after)")
        #expect(line(after, "done (1)") == "done (1): 1 earlier (archived: board(task) finds each)", "\(after)")
        #expect(line(after, "Receipts") == line(status, "Receipts") && line(status, "Receipts") != nil, "\(status)")
        // A new task never takes its slug.
        let added = lead.call("add_task", ["title": "Change", "goal": "again", "acceptance": ["a"]])
        #expect(added.text.contains("change-2"), "\(added.text)")
        // A record_incident about it names it.
        #expect(!lead.call("record_incident", ["what": "b broke", "evidence": "log", "task": "change"]).isError)

        // revert brings it back on the board to read reverted; the archive keeps its line (append-only).
        let reverted = lead.call("revert", ["task": "change", "reason": "b.txt broke the build"])
        #expect(!reverted.isError, "\(reverted.text)")
        #expect(store.load().task("change")?.status == .reverted)
        #expect(store.load().task("change")?.merged?.revertedBy != nil)
        #expect(store.archived().first?.status == .done)
        let card = LeadScorecard(store.load())
        #expect(card.merged == 1 && card.reverts == 1)
        #expect(LeadScorecard(store.loadAll()) == card)
        #expect(line(lead.call("status", [:]).text, "reverted (1)")?.hasPrefix("reverted (1): change (by ") == true)
    }

    @Test func aMergeArchivesAtMostHourly() throws {
        let (root, runtime, lead) = try team()
        var clock = Date().timeIntervalSince1970
        lead.archiveClock = { clock }
        lead.archiveFinished(force: true)
        try merged("first", file: "b.txt", lead, runtime, root: root)
        try age(["first"], root: root)
        // Half an hour on: the merge leaves the board as it is.
        clock += 1_800
        try merged("second", file: "c.txt", lead, runtime, root: root)
        let store = BoardStore(root: root)
        #expect(store.load().task("first") != nil)
        #expect(!FileManager.default.fileExists(atPath: store.archiveFile))
        // Over an hour since: the next merge moves it.
        clock += 1_801
        try merged("third", file: "d.txt", lead, runtime, root: root)
        #expect(store.load().task("first") == nil)
        #expect(store.load().tasks.map(\.slug) == ["second", "third"])
        #expect(store.archived().map(\.slug) == ["first"])
    }

    @Test func aBoardOf300TasksMovesOverWhenTheLeadsServerFirstStarts() throws {
        let root = try repo()
        let store = BoardStore(root: root)
        let old = Date().timeIntervalSince1970 - 3 * 86_400
        let report = String(repeating: "The worker ran the suite twice; every check passed. ", count: 200)
        var board = LeadBoard()
        for index in 0..<300 {
            let status: LeadTask.Status
            switch index {
            case 0..<280: status = .done
            case 280..<285: status = .folded
            case 285..<290: status = .abandoned
            default: status = [.planned, .running, .review, .kept, .blocked][index % 5]
            }
            var task = LeadBoardArchiveTests.task("task-\(index)", status, finished: old + Double(index), report: report)
            if status == .done, index >= 270 { task.since = Date().timeIntervalSince1970 - 600 }
            board.tasks.append(task)
        }
        // Its last all-done card, as real boards have: the open batch since is the last 40 tasks.
        board.allDone = [LeadAllDone(at: old + 250, since: old, tasks: [])]
        try store.locked { try store.write(board) }
        let size = try FileManager.default.attributesOfItem(atPath: store.file)[.size] as? Int ?? 0
        let card = LeadScorecard(board)

        // The first run of a server with the archive: the lead starts.
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let moved = store.load()
        #expect(moved.tasks.count == 20)
        #expect(moved.tasks.map(\.slug) == (270..<280).map { "task-\($0)" } + (290..<300).map { "task-\($0)" })
        #expect(store.archived().count == 280)
        #expect(Set(store.archived().map(\.slug)).isDisjoint(with: moved.tasks.map(\.slug)))
        let smaller = try FileManager.default.attributesOfItem(atPath: store.file)[.size] as? Int ?? 0
        #expect(smaller * 10 < size, "\(smaller) of \(size) bytes")
        #expect(LeadScorecard(moved) == card)
        let status = lead.call("status", [:]).text
        #expect(status.contains("— 300 task(s)"), "\(status)")
        #expect(line(status, "done (")?.hasPrefix("done (285, 5 folded): task-270") == true, "\(status)")
        #expect(line(status, "abandoned (5)") == "abandoned (5): 5 earlier (archived: board(task) finds each)", "\(status)")
        #expect(lead.call("board", ["task": "task-3"]).text.contains("\"slug\" : \"task-3\""))
        // A second start moves nothing more.
        _ = try self.lead(root, runtime)
        #expect(store.archived().count == 280 && store.load().tasks.count == 20)
    }

    @Test func aPlannedTaskAfterAnArchivedOneStillWaitsOnIt() throws {
        let (root, runtime, lead) = try team()
        try merged("base", file: "b.txt", lead, runtime, root: root)
        try age(["base"], root: root)
        lead.archiveFinished(force: true)
        #expect(BoardStore(root: root).load().task("base") == nil)
        // after names it from the archive, and the task starts as its after task is done.
        let added = lead.call("add_task", ["title": "Next", "goal": "g", "acceptance": ["a"], "after": ["base"], "auto_advance": true])
        #expect(!added.isError, "\(added.text)")
        #expect(BoardStore(root: root).load().task("next")?.after == ["base"])
        #expect(!lead.call("configure", ["auto_advance": true]).isError)
        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        #expect(advancing.until { BoardStore(root: root).load().task("next")?.status == .running })
    }

    @Test func updateTaskReopensAnArchivedTaskAndFoldsIntoOne() throws {
        let (root, runtime, lead) = try team()
        try merged("base", file: "b.txt", lead, runtime, root: root)
        #expect(!lead.call("add_task", ["title": "Dropped", "goal": "g", "acceptance": ["a"]]).isError)
        #expect(!lead.call("update_task", ["task": "dropped", "status": "abandoned", "reason": "not wanted then"]).isError)
        try age(["base", "dropped"], root: root)
        lead.archiveFinished(force: true)
        let store = BoardStore(root: root)
        #expect(store.load().tasks.isEmpty && Set(store.archived().map(\.slug)) == ["base", "dropped"])
        // Reopened: back on the board, planned.
        let reopened = lead.call("update_task", ["task": "dropped", "status": "planned", "append_context": "wanted again"])
        #expect(!reopened.isError && !reopened.text.contains("Nothing to change"), "\(reopened.text)")
        #expect(store.load().task("dropped")?.status == .planned)
        #expect(store.load().task("dropped")?.contract.context.contains("wanted again") == true)
        // A planned task folded into the archived one that carries its work.
        #expect(!lead.call("add_task", ["title": "Covered", "goal": "g", "acceptance": ["a"]]).isError)
        let folded = lead.call("update_task", ["task": "covered", "status": "folded", "into": "base"])
        #expect(!folded.isError, "\(folded.text)")
        #expect(store.load().task("covered")?.foldedInto == "base")
    }
}
