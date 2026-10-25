import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The lead's chat froze for seconds as the host's sessions changed (10-24, 10-25): every change drew the Team tab
/// again, mapping and sorting the board's tasks and reading workflow.md each time. The Team rows are made once per
/// board and members' change (`TeamRowsCache`), the Team pane is equal across another session's change, and the
/// records folder is read with the board.
struct TeamChurnTests {
    static let now = TeamRowsTests.now

    static func board() -> LeadBoard {
        var board = LeadBoard()
        var review = TeamRowsTests.task("rev", .review)
        review.verifier = "v-rev"
        board.tasks = [TeamRowsTests.task("fix", .running), review, TeamRowsTests.task("next", .planned), TeamRowsTests.task("old", .done)]
        return board
    }

    /// A window session (as the inspector's rows have it), ended or not.
    static func hosted(_ id: UUID, title: String = "Working", ended: Bool = false) -> WindowRow {
        WindowRow(content: .hosted(HostSession(id: id, tty: "ttys0", childPID: 1, cwd: "/r", command: "claude", label: "Worker: fix", agent: "claude",
                                               title: title, startedAt: now - 600, cols: 120, rows: 40,
                                               exit: ended ? HostSession.Exit(status: 129, at: now - 5) : nil)), project: "r")
    }

    @Test func rowsAreMadeAgainOnlyWhenTheBoardOrItsMembersChange() {
        let cache = TeamRowsCache()
        let worker = UUID(), verifier = UUID(), lead = UUID(), other = UUID()
        var board = Self.board()
        board.tasks[0].worker = worker.uuidString
        board.tasks[1].verifier = verifier.uuidString
        var all = [Self.hosted(worker), Self.hosted(verifier), Self.hosted(lead), Self.hosted(other)]
        func rows() -> [TeamRow] { cache.rows("/r", board: board, seen: cache.seen("/r", board: board, rows: all, now: Self.now)) }
        let first = rows()
        // What the board's rows read is all they read: the same rows as from every session.
        #expect(first == TeamRows.rows(board, seen: TeamRows.seen(all, now: Self.now)))
        #expect(cache.made == 1)
        for _ in 0..<5 { _ = rows() }
        #expect(cache.made == 1)
        // Another project's session retitled itself, the lead's own ended: nothing to make again.
        all[3] = Self.hosted(other, title: "Another title")
        all[2] = Self.hosted(lead, ended: true)
        #expect(rows() == first)
        #expect(cache.made == 1)
        // The worker's session ended: made again, once.
        all[0] = Self.hosted(worker, ended: true)
        #expect(rows().first { $0.id == "fix" }?.state == "Worker ended")
        _ = rows()
        #expect(cache.made == 2)
        // The board changed: made again, once.
        board.tasks[2].title = "Next, renamed"
        #expect(rows().contains { $0.task.title == "Next, renamed" })
        _ = rows()
        #expect(cache.made == 3)
        // Each key keeps its own (the sidebar's reads the team's rows only).
        _ = cache.rows("sidebar|/r", board: board, seen: cache.seen("sidebar|/r", board: board, rows: all, now: Self.now))
        _ = rows()
        #expect(cache.made == 4)
        cache.keep { $0 == "/r" }
        _ = rows()
        #expect(cache.made == 4)
        // No session with a host id at all: the host's list isn't known yet, and nothing is said of the members.
        #expect(cache.seen("/r", board: board, rows: [], now: Self.now) == TeamSeen(members: [:], listed: false))
    }

    @Test func membersAreTheBoardsWorkersVerifiersAndFinders() {
        var board = Self.board()
        board.tasks[1].panel = LeadAuditPanel(focuses: ["a", "b"], sessions: ["f-1", "f-2"], commit: "abc", logs: [], run: "r")
        #expect(TeamRows.members(board) == ["w-fix", "w-rev", "v-rev", "w-old", "f-1", "f-2"])
    }

    @Test func aMemberMissingFromTheHostStillReadsGone() {
        // The host was replaced: only the lead's new session is listed. Narrowed to the board's members, nothing is
        // left, but the host's list is still known: the worker reads ended, as from every session.
        let board = Self.board()
        let all = ["lead": TeamRowsTests.working]
        let seen = TeamRows.seen(all, members: TeamRows.members(board))
        #expect(seen.members.isEmpty && seen.listed)
        #expect(TeamRows.rows(board, seen: seen) == TeamRows.rows(board, seen: all))
        #expect(TeamRows.rows(board, seen: seen).first { $0.id == "fix" }?.state == "Worker ended")
        // Nothing listed at all yet: nothing is said of them.
        #expect(TeamRows.rows(board, seen: TeamRows.seen([:], members: TeamRows.members(board))).first { $0.id == "fix" }?.state == "Working")
    }

    @Test func theTeamPaneIsEqualAcrossAnotherSessionsChange() {
        let summaries = TeamSummaryModel(generate: { _ in nil })
        let awake = KeepAwake(power: KeepAwakeTests.FakePower())
        let board = Self.board()
        func session(_ title: String, cwd: String = "/other") -> HostSession {
            HostSession(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, tty: "ttys1", childPID: 1, cwd: cwd, command: "claude",
                        label: "Claude", agent: "claude", title: title, startedAt: Self.now, cols: 120, rows: 40, exit: nil)
        }
        func pane(_ hosted: [HostSession], seen: [String: MemberSeen] = ["w-fix": TeamRowsTests.working], open: @escaping (String) -> Void = { _ in }) -> LeadTeamPane {
            LeadTeamPane(root: "/r", board: board, decisions: [], seen: seen, rows: TeamRows.rows(board, seen: seen), open: open, answer: { _, _ in },
                         notices: [:], summaries: summaries, keepAwake: awake, hosted: hosted.map(MacLine.Session.init), recordsDir: "docs/lead")
        }
        // Another session retitled itself (a new closure each draw, as the inspector makes them): equal.
        #expect(pane([session("✳ Fix login")]) == pane([session("⠋ Fix login, step 2")], open: { _ in print("another") }))
        // What it shows changed: not equal.
        #expect(pane([session("a")]) != pane([session("a", cwd: "/r/.vibeswitcher/worktrees/fix")]))
        #expect(pane([]) != pane([], seen: ["w-fix": TeamRowsTests.member(needsYou: true, working: false)]))
    }

    @Test func theRecordsFolderIsReadWithTheBoardOnlyWhenWorkflowChanged() throws {
        let root = scratchRoot.appendingPathComponent("team-churn-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        var files = LeadFiles()
        // No workflow.md: the default.
        #expect(files.recordsDir(root) == LeadWorkflow.defaultRecordsDir)
        let store = BoardStore(root: root)
        try FileManager.default.createDirectory(atPath: store.folder, withIntermediateDirectories: true)
        let workflow = (store.folder as NSString).appendingPathComponent("workflow.md")
        try "---\nbase_branch: main\nrecords_dir: notes\n---\n".write(toFile: workflow, atomically: true, encoding: .utf8)
        let reads = files.fileReads
        #expect(files.recordsDir(root) == "notes")
        #expect(files.fileReads == reads + 1)
        for _ in 0..<5 { #expect(files.recordsDir(root) == "notes") }
        #expect(files.fileReads == reads + 1)
        try "---\nbase_branch: main\nrecords_dir: docs/records\n---\n".write(toFile: workflow, atomically: true, encoding: .utf8)
        #expect(files.recordsDir(root) == "docs/records")
        #expect(files.fileReads == reads + 2)
        #expect(files.recordsDir(root) == store.recordsDir)
    }
}
