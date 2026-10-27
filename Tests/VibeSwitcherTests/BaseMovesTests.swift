import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The window's side of a lead's base moving outside its merges: a move of yours is taken without asking; any other
/// is asked about once, and Accept takes it in the vault with the lead running on.
final class BaseMovesTests {
    let temp = Scratch()
    let book = LeadVault.Book()
    let app: LeadVault
    let root: String
    /// Where the board is written (the lead controller's queue): read through it, a read sees what was written before.
    let reads = LeadReads()
    var asked: [String] = []
    var taken: [(to: String, byYou: Bool)] = []
    var takers: [BaseMoves.Taker] = []
    var logged: [String] = []

    init() throws {
        app = book.vault(folder: temp.url("vault"), as: { .app })
        let url = temp.url("base-moves")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["config", "commit.gpgsign", "false"]] {
            Git.run(args, in: root)
        }
        try commit("a.txt")
        _ = try app.startLead(root: root, branch: "main")
    }

    /// What was asked of the queue lands before the scratch folder goes: a board or note written after would make
    /// the repository again.
    deinit {
        let done = DispatchSemaphore(value: 0)
        reads.async { _ in done.signal() }
        done.wait()
    }

    func commit(_ file: String) throws {
        try "\(file)\n".write(toFile: root + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: root)
        #expect(Git.run(["commit", "-q", "-m", "add \(file)"], in: root).ok)
    }

    func moves() -> BaseMoves {
        let moves = BaseMoves(vault: app, reads: reads, background: { $0() }, main: { $0() })
        moves.onAsk = { [unowned self] _, move in asked.append(move.to) }
        moves.onTaken = { [unowned self] _, move, taker in
            taken.append((move.to, taker == .you))
            takers.append(taker)
        }
        moves.log = { [unowned self] in logged.append($0) }
        return moves
    }

    /// A session the app opened, its hooks telling the host about `command` around `body`.
    func yours(_ command: String, after: Bool = true, _ body: () throws -> Void) throws {
        let session = book.vault(folder: app.folder, as: { .session("user-session") }, userOpened: true)
        let event: (String) -> [String: Any] = { ["hook_event_name": $0, "tool_name": "Bash", "tool_input": ["command": command], "cwd": self.root, "tool_use_id": "t1"] }
        for (root, step) in GitMoves.steps(for: event("PreToolUse")) { try session.record(step, root: root) }
        try body()
        guard after else { return }
        for (root, step) in GitMoves.steps(for: event("PostToolUse")) { try session.record(step, root: root) }
    }

    func head() -> String { Git.run(["rev-parse", "main"], in: root).output }

    /// The board as read on `reads`' queue, after every write asked of it before.
    func board() -> LeadBoard {
        let done = DispatchSemaphore(value: 0)
        var board = LeadBoard()
        reads.async { [root] _ in
            board = BoardStore(root: root).load()
            done.signal()
        }
        done.wait()
        return board
    }

    @Test func aCommitOfYoursIsTakenWithoutAsking() throws {
        try yours("git commit -m b") { try commit("b.txt") }
        let moves = moves()
        moves.look([root])
        #expect(moves.asking.isEmpty)
        #expect(asked.isEmpty)
        #expect(taken.map(\.to) == [head()])
        #expect(taken.first?.byYou == false)
        #expect(app.headMoved(root: root, branch: "main") == nil)
        let update = try #require(board().updates.last)
        #expect(update.body.hasPrefix("accepted 1 commit on main from your session"), "\(update.body)")
        #expect(logged.contains { $0.contains("accepted 1 commit on main") && $0.contains(String(head().prefix(7))) })
    }

    /// What was taken is written on the lead controller's queue, never where the move was looked at (the main thread in
    /// the app): it waits its turn behind what was asked of the queue before it, and a read after it sees it.
    @Test func whatWasTakenIsWrittenOnTheLeadsQueueInOrder() throws {
        try yours("git commit -m b") { try commit("b.txt") }
        let moves = moves()
        let gate = DispatchSemaphore(value: 0)
        var wroteOnMain: Bool?
        reads.async { _ in gate.wait() }
        moves.look([root])
        #expect(taken.map(\.to) == [head()])
        // The queue is held: nothing written yet.
        #expect(!BoardStore(root: root).load().updates.contains { $0.title.hasPrefix("Took") })
        reads.async { _ in wroteOnMain = Thread.isMainThread }
        gate.signal()
        let update = try #require(board().updates.last)
        #expect(update.title == "Took 1 commit on main")
        #expect(update.body.hasPrefix("accepted 1 commit on main from your session"), "\(update.body)")
        #expect(wroteOnMain == false)
    }

    @Test func aMoveNobodyAccountsForIsAskedOnceAndAcceptingTakesIt() throws {
        try commit("b.txt")
        let moves = moves()
        moves.look([root])
        let move = try #require(moves.asking[root])
        #expect(move.commits.map(\.subject) == ["add b.txt"])
        #expect(asked == [head()])
        // Looked at again (nothing changed, or every 30 s while it asks): not asked again.
        moves.look([root])
        moves.look([root], now: Date().addingTimeInterval(60))
        #expect(asked.count == 1)
        #expect(moves.asking[root] == move)

        moves.accept(root)
        #expect(moves.asking.isEmpty)
        #expect(app.head(root: root, branch: "main") == move.to)
        #expect(app.headMoved(root: root, branch: "main") == nil)
        #expect(taken.count == 1 && taken.first?.byYou == true)
        #expect(board().updates.last?.body.hasPrefix("You accepted 1 commit on main") == true)
        moves.look([root], now: Date().addingTimeInterval(120))
        #expect(moves.asking.isEmpty)
    }

    @Test func keptRefusedIsNotAskedAgainUntilItMovesAgain() throws {
        let left = try #require(app.head(root: root, branch: "main"))
        try commit("b.txt")
        let moves = moves()
        moves.look([root])
        #expect(moves.asking[root] != nil)
        moves.keepRefused(root)
        #expect(moves.asking.isEmpty)
        #expect(app.head(root: root, branch: "main") == left)
        moves.look([root], now: Date().addingTimeInterval(60))
        #expect(moves.asking.isEmpty)
        #expect(asked.count == 1)
        // It moved again: a new move, asked about.
        try commit("c.txt")
        moves.look([root], now: Date().addingTimeInterval(120))
        #expect(moves.asking[root]?.commits.count == 2)
        #expect(asked.count == 2)
    }

    @Test func aCommandOfYoursStillRunningIsWaitedForNotAskedAbout() throws {
        try yours("git commit -m b", after: false) { try commit("b.txt") }
        let moves = moves()
        moves.look([root])
        #expect(moves.asking.isEmpty)
        #expect(asked.isEmpty)
        #expect(taken.isEmpty)
        // Its hooks say it's done: the next look takes it.
        let session = book.vault(folder: app.folder, as: { .session("user-session") }, userOpened: true)
        try session.record(LeadVault.GitStep(phase: .after, call: "t1", verb: "commit", branch: "main", head: head()), root: root)
        moves.look([root])
        #expect(taken.map(\.to) == [head()])
        #expect(asked.isEmpty)
    }

    /// genswap, 2026-10-22: the window looked while the base was another branch; the lead then set base_branch to
    /// fair-launch, and the user committed on it from its worktree in .claude/worktrees. The window has to see that.
    func switchedBase() throws -> (moves: BaseMoves, worktree: String) {
        Git.run(["branch", "fair-launch"], in: root)
        let worktree = root + "/.claude/worktrees/fair-launch"
        #expect(Git.run(["worktree", "add", "-q", worktree, "fair-launch"], in: root).ok)
        let moves = moves()
        moves.look([root])
        #expect(moves.asking.isEmpty)
        _ = try app.startLead(root: root, branch: "fair-launch")
        try FileManager.default.createDirectory(atPath: root + "/.vibeswitcher", withIntermediateDirectories: true)
        try "---\nbase_branch: fair-launch\n---\n".write(toFile: BaseMoves.workflow(root: root), atomically: true, encoding: .utf8)
        return (moves, worktree)
    }

    func commit(_ file: String, in dir: String) {
        try? "\(file)\n".write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: dir)
        #expect(Git.run(["commit", "-q", "-m", "add \(file)"], in: dir).ok)
    }

    @Test func aCommitOnABaseSwitchedSinceTheLastLookIsAskedAboutAndTheMergeSaysSo() throws {
        let (moves, worktree) = try switchedBase()
        let left = try #require(app.head(root: root, branch: "fair-launch"))
        // A terminal, or a `!` line typed straight into the session's terminal: nothing accounts for it.
        commit("README.md", in: worktree)
        let now = Git.run(["rev-parse", "fair-launch"], in: root).output
        // At once, not 30 s on: the base it watches is the one workflow.md names now.
        moves.look([root])
        let move = try #require(moves.asking[root])
        #expect(move.branch == "fair-launch" && move.to == now)
        #expect(asked == [now])
        // The lead's merge says the window is asking, and that no restart is needed.
        _ = board()
        let note = try #require(LeadVault.BaseMoveNote.load(root: root))
        #expect(note.state == .asking && note.from == left && note.to == now && note.commits == 1)
        let refusal = LeadVault.moveRefusal(base: "fair-launch", known: left, current: now,
                                            move: .success(try app.acceptMove(root: root, branch: "fair-launch")), root: root)
        #expect(refusal.contains("VibeSwitcher is asking the user: a card in your chat"), "\(refusal)")
        #expect(refusal.contains("Don't ask them to restart you"), "\(refusal)")
        #expect(!refusal.contains("starting the lead again"))
        // Asked about in the lead's chat, but no merge of the lead's refused yet: no alert (the user commits on the base).
        #expect(AlertRules.baseMoved(move, refused: LeadVault.BaseMoveRefusal.load(root: root), root: root, leadTTY: nil) == nil)
        // The lead's merge refused for it: its merges wait on the user, who's told.
        try LeadVault.BaseMoveRefusal(branch: "fair-launch", to: now, at: 1).save(root: root)
        #expect(AlertRules.baseMoved(moves.asking[root], refused: LeadVault.BaseMoveRefusal.load(root: root), root: root, leadTTY: nil) != nil)

        moves.accept(root)
        #expect(app.headMoved(root: root, branch: "fair-launch") == nil)
        _ = board()
        #expect(LeadVault.BaseMoveNote.load(root: root) == nil)
        // Taken: no merge waits on the user any more.
        #expect(LeadVault.BaseMoveRefusal.load(root: root) == nil)
    }

    @Test func aBangGitCommandYouSentFromTheWindowIsTakenWithoutAsking() throws {
        let (moves, worktree) = try switchedBase()
        // Run on the lead's code block: `!` makes it a shell command in the lead's session, which no hook sees.
        moves.typed("! cd \(worktree) && git add README.md && git commit -m 'Fair launch: README'", session: "lead-session", cwd: root)
        commit("README.md", in: worktree)
        let now = Git.run(["rev-parse", "fair-launch"], in: root).output
        moves.look([root])
        #expect(moves.asking.isEmpty)
        #expect(asked.isEmpty)
        #expect(takers == [.typed])
        #expect(app.head(root: root, branch: "fair-launch") == now)
        let update = try #require(board().updates.last)
        #expect(update.body.hasPrefix("accepted 1 commit on fair-launch that you ran from VibeSwitcher's window"), "\(update.body)")
        // Used up: a later commit nobody accounts for is asked about.
        commit("b.txt", in: worktree)
        moves.look([root])
        #expect(moves.asking[root]?.commits.count == 1)
    }

    @Test func whatYouSentDoesntTakeAMoveATeamSessionCouldHaveMade() throws {
        let (moves, worktree) = try switchedBase()
        moves.typed("! cd \(worktree) && git commit -am 'mine'", session: "lead-session", cwd: root)
        // A session the app didn't open (a team member's, or one a session started) commits there too, its hooks say.
        let team = book.vault(folder: app.folder, as: { .session("worker-session") }, userOpened: false)
        let event: (String) -> [String: Any] = { ["hook_event_name": $0, "tool_name": "Bash", "tool_input": ["command": "git commit -am x"], "cwd": worktree, "tool_use_id": "w1"] }
        for (root, step) in GitMoves.steps(for: event("PreToolUse")) { try team.record(step, root: root) }
        commit("README.md", in: worktree)
        for (root, step) in GitMoves.steps(for: event("PostToolUse")) { try team.record(step, root: root) }
        moves.look([root])
        let move = try #require(moves.asking[root])
        #expect(move.team == true)
        #expect(move.reason?.contains("isn't one of yours") == true, "\(move.reason ?? "")")
        #expect(takers.isEmpty)
    }

    @Test func whatYouSentDoesntTakeAMoveATeamCommandStillRunningCouldHaveMade() throws {
        let (moves, worktree) = try switchedBase()
        moves.typed("! cd \(worktree) && git commit -am 'mine'", session: "lead-session", cwd: root)
        // A team session's commit there has started, and its hooks haven't said it ended when the entry appears.
        let team = book.vault(folder: app.folder, as: { .session("worker-session") }, userOpened: false)
        let event: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "git commit -am x"], "cwd": worktree, "tool_use_id": "w1"]
        for (root, step) in GitMoves.steps(for: event) { try team.record(step, root: root) }
        commit("README.md", in: worktree)
        moves.look([root])
        let move = try #require(moves.asking[root])
        #expect(move.team == true)
        #expect(takers.isEmpty)
        #expect(app.headMoved(root: root, branch: "fair-launch") != nil)
    }

    /// A line counts only for what appeared after it was sent, within `Typed.lasts`, and once: a `! git commit` that
    /// committed nothing doesn't vouch for a commit that comes later.
    @Test func aLineYouSentCountsOnlyForWhatAppearedSoonAfterItAndOnce() throws {
        let (moves, worktree) = try switchedBase()
        let line = "! cd \(worktree) && git commit -am 'mine'"
        // Sent after the commit (its reflog entry is older): not what it made.
        commit("README.md", in: worktree)
        moves.typed(line, session: "lead-session", cwd: root, at: Date().addingTimeInterval(3))
        moves.look([root], now: Date().addingTimeInterval(4))
        #expect(moves.asking[root] != nil)
        #expect(takers.isEmpty)
        // Looked at for that move: used up, though it was asked about.
        #expect(moves.sent.isEmpty)
        moves.accept(root)

        // Sent long before the commit (a commit that failed, say): not what it made either.
        moves.typed(line, session: "lead-session", cwd: root, at: Date().addingTimeInterval(-(LeadVault.Typed.lasts + 10)))
        commit("b.txt", in: worktree)
        moves.look([root])
        #expect(moves.asking[root] != nil)
        #expect(takers == [.you])
        #expect(moves.sent.isEmpty)
    }

    @Test func aMessageToTheAgentIsNotWhatYouRan() throws {
        let (moves, worktree) = try switchedBase()
        // Without `!` it's a prompt: the agent runs the git, and its own hooks say whose that is.
        moves.typed("cd \(worktree) && git commit -am 'mine'", session: "lead-session", cwd: root)
        #expect(moves.sent.isEmpty)
        moves.typed("! git status", session: "lead-session", cwd: root)
        #expect(moves.sent.isEmpty)
        commit("README.md", in: worktree)
        moves.look([root])
        #expect(moves.asking[root] != nil)
        #expect(takers.isEmpty)
    }

    @Test func aRewriteIsAskedAboutWithNothingListed() throws {
        try commit("b.txt")
        _ = try app.startLead(root: root, branch: "main", takeHead: true)
        #expect(Git.run(["reset", "-q", "--hard", "HEAD~1"], in: root).ok)
        let moves = moves()
        moves.look([root])
        let move = try #require(moves.asking[root])
        #expect(move.commits.isEmpty)
        #expect(move.reason?.contains("rewritten") == true)
    }

    /// Where each root's reflog and workflow.md were stamped, and on which thread.
    final class Stamped: @unchecked Sendable {
        private let lock = NSLock()
        private var stamps: [(root: String, main: Bool)] = []

        func add(_ root: String) {
            lock.lock()
            stamps.append((root, Thread.isMainThread))
            lock.unlock()
        }

        func count(main: Bool) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return stamps.filter { $0.main == main }.count
        }
    }

    /// hang-20261027-175604: a stat waited 3 s on a busy disk. The lead controller's refresh looks at each base on the
    /// main thread, and its reflog and workflow.md are stamped off it: after a look, and at the next to see whether
    /// either changed.
    @MainActor @Test func theBaseIsStampedOffTheMainThread() async throws {
        try commit("b.txt")
        let moves = BaseMoves(vault: app, reads: reads)
        moves.onAsk = { [unowned self] _, move in asked.append(move.to) }
        let stamped = Stamped()
        moves.stamped = { stamped.add($0) }
        moves.look([root])
        #expect(await until { asked.count == 1 })
        #expect(stamped.count(main: false) == 1)
        // Nothing changed and not due: only the stamps are taken, to see that.
        moves.look([root])
        #expect(await until { stamped.count(main: false) == 2 })
        // Then the next look begins (none while one is under way): it stamps again.
        #expect(await until {
            moves.look([root])
            return stamped.count(main: false) >= 3
        })
        #expect(stamped.count(main: true) == 0)
        #expect(asked.count == 1)
    }
}
