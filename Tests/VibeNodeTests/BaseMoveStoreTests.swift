import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// A lead's base moving outside its merges (`BaseMoveStore`; the app's `BaseMovesTests`, the cases that need no window,
/// ported: the engine plan's E6): a move of the user's is taken without asking; any other is a card, asked once, and
/// `base accept` takes it in the vault with the lead running on; `base show` makes a card with no lead running. The five
/// cases about `!` lines sent from the window are ported for `vibeswitcher send`'s (`typed`, 2026-11-22).
final class BaseMoveStoreTests {
    let temp = Scratch()
    let book = LeadVault.Book()
    let app: LeadVault
    let root: String
    /// The engine's reads queue (the boards' and the notes' writes): read through it, a read sees what was written before.
    let reads = BoardReads(handTo: DispatchQueue(label: "base-move-tests.handed"))
    var asked: [String] = []
    var taken: [(to: String, byYou: Bool)] = []
    var takers: [BaseMoveStore.Taker] = []
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

    /// What was asked of the reads queue lands before the scratch folder goes.
    deinit { reads.queue.sync {} }

    func commit(_ file: String, in dir: String? = nil) throws {
        let dir = dir ?? root
        try "\(file)\n".write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: dir)
        #expect(Git.run(["commit", "-q", "-m", "add \(file)"], in: dir).ok)
    }

    /// A store looking inline (its background and main the caller's thread).
    func moves() -> BaseMoveStore {
        let moves = BaseMoveStore(vault: app, reads: reads, background: { $0() }, main: { $0() })
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

    func head(_ branch: String = "main") -> String { Git.run(["rev-parse", branch], in: root).output }

    /// The board as read on the reads queue, after every write asked of it before.
    func board() -> LeadBoard {
        let root = root
        return reads.queue.sync { BoardStore(root: root).load() }
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

    /// What was taken is written on the engine's reads queue, never where the move was looked at: it waits its turn
    /// behind what was asked of the queue before it, and a read after it sees it.
    @Test func whatWasTakenIsWrittenOnTheEnginesReadsQueueInOrder() throws {
        try yours("git commit -m b") { try commit("b.txt") }
        let moves = moves()
        let gate = DispatchSemaphore(value: 0)
        let wroteOnLooker = Locked<Bool?>(nil)
        let looker = pthread_self()
        reads.async({ _ in gate.wait() })
        moves.look([root])
        #expect(taken.map(\.to) == [head()])
        // The queue is held: nothing written yet.
        #expect(!BoardStore(root: root).load().updates.contains { $0.title.hasPrefix("Took") })
        reads.async({ _ in wroteOnLooker.value = pthread_equal(pthread_self(), looker) != 0 })
        gate.signal()
        let update = try #require(board().updates.last)
        #expect(update.title == "Took 1 commit on main")
        #expect(update.body.hasPrefix("accepted 1 commit on main from your session"), "\(update.body)")
        // Written on the reads queue, not on the thread that looked (the app's `wroteOnMain == false`).
        #expect(wroteOnLooker.value == false)
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
        #expect(try app.head(root: root, branch: "main") == move.to)
        #expect(app.headMoved(root: root, branch: "main") == nil)
        #expect(taken.count == 1 && taken.first?.byYou == true)
        #expect(board().updates.last?.body.hasPrefix("You accepted 1 commit on main") == true)
        moves.look([root], now: Date().addingTimeInterval(120))
        #expect(moves.asking.isEmpty)
    }

    @Test func keptRefusedIsNotAskedAgainUntilItMovesAgain() throws {
        let left = try #require(try app.head(root: root, branch: "main"))
        try commit("b.txt")
        let moves = moves()
        moves.look([root])
        #expect(moves.asking[root] != nil)
        moves.keepRefused(root)
        #expect(moves.asking.isEmpty)
        #expect(try app.head(root: root, branch: "main") == left)
        moves.look([root], now: Date().addingTimeInterval(60))
        #expect(moves.asking.isEmpty)
        #expect(asked.count == 1)
        _ = board()
        #expect(LeadVault.BaseMoveNote.load(root: root)?.state == .kept)
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

    /// project-c, 2026-10-22: the store looked while the base was another branch; the lead then set base_branch to
    /// fair-launch, and the user committed on it from its worktree. The next look has to see that, at once.
    @Test func aCommitOnABaseSwitchedSinceTheLastLookIsAskedAboutAndTheMergeSaysSo() throws {
        Git.run(["branch", "fair-launch"], in: root)
        let worktree = root + "/.claude/worktrees/fair-launch"
        #expect(Git.run(["worktree", "add", "-q", worktree, "fair-launch"], in: root).ok)
        let moves = moves()
        moves.look([root])
        #expect(moves.asking.isEmpty)
        _ = try app.startLead(root: root, branch: "fair-launch")
        try FileManager.default.createDirectory(atPath: root + "/.vibeswitcher", withIntermediateDirectories: true)
        try "---\nbase_branch: fair-launch\n---\n".write(toFile: ConfigHoldStore.workflowPath(root: root), atomically: true, encoding: .utf8)
        let left = try #require(try app.head(root: root, branch: "fair-launch"))
        try commit("README.md", in: worktree)
        let now = head("fair-launch")
        // At once, not 30 s on: the base it watches is the one workflow.md names now.
        moves.look([root])
        let move = try #require(moves.asking[root])
        #expect(move.branch == "fair-launch" && move.to == now)
        #expect(asked == [now])
        _ = board()
        let note = try #require(LeadVault.BaseMoveNote.load(root: root))
        #expect(note.state == .asking && note.from == left && note.to == now && note.commits == 1)
        let refusal = LeadVault.moveRefusal(base: "fair-launch", known: left, current: now,
                                            move: .success(try app.acceptMove(root: root, branch: "fair-launch")), root: root)
        #expect(refusal.contains("VibeSwitcher is asking the user: a card in your chat"), "\(refusal)")
        #expect(refusal.contains("Don't ask them to restart you"), "\(refusal)")
        #expect(!refusal.contains("starting the lead again"))
        try LeadVault.BaseMoveRefusal(branch: "fair-launch", to: now, at: 1).save(root: root)

        moves.accept(root)
        #expect(app.headMoved(root: root, branch: "fair-launch") == nil)
        _ = board()
        #expect(LeadVault.BaseMoveNote.load(root: root) == nil)
        // Taken: no merge waits on the user any more.
        #expect(LeadVault.BaseMoveRefusal.load(root: root) == nil)
    }

    /// The lead's base switched to `fair-launch`, checked out in a worktree of its own, looked at once.
    func switchedBase() throws -> (moves: BaseMoveStore, worktree: String) {
        Git.run(["branch", "fair-launch"], in: root)
        let worktree = root + "/.claude/worktrees/fair-launch"
        #expect(Git.run(["worktree", "add", "-q", worktree, "fair-launch"], in: root).ok)
        let moves = moves()
        moves.look([root])
        #expect(moves.asking.isEmpty)
        _ = try app.startLead(root: root, branch: "fair-launch")
        try FileManager.default.createDirectory(atPath: root + "/.vibeswitcher", withIntermediateDirectories: true)
        try "---\nbase_branch: fair-launch\n---\n".write(toFile: ConfigHoldStore.workflowPath(root: root), atomically: true, encoding: .utf8)
        return (moves, worktree)
    }

    @Test func aBangGitCommandYouSentIsTakenWithoutAsking() throws {
        let (moves, worktree) = try switchedBase()
        // `vibeswitcher send` into the lead: `!` makes it a shell command in its session, which no hook sees.
        moves.typed("! cd \(worktree) && git add README.md && git commit -m 'Fair launch: README'", session: "lead-session", cwd: root)
        try "README.md\n".write(toFile: worktree + "/README.md", atomically: true, encoding: .utf8)
        Git.run(["add", "README.md"], in: worktree)
        #expect(Git.run(["commit", "-q", "-m", "Fair launch: README"], in: worktree).ok)
        let now = head("fair-launch")
        moves.look([root])
        #expect(moves.asking.isEmpty)
        #expect(asked.isEmpty)
        #expect(takers == [.typed])
        #expect(try app.head(root: root, branch: "fair-launch") == now)
        let update = try #require(board().updates.last)
        #expect(update.body.hasPrefix("accepted 1 commit on fair-launch that you ran with vibeswitcher send"), "\(update.body)")
        // Used up: a later commit nobody accounts for is asked about.
        try commit("b.txt", in: worktree)
        moves.look([root])
        #expect(moves.asking[root]?.commits.count == 1)
    }

    @Test func whatYouSentDoesntTakeAMoveATeamSessionCouldHaveMade() throws {
        let (moves, worktree) = try switchedBase()
        moves.typed("! cd \(worktree) && git commit -am 'mine'", session: "lead-session", cwd: root)
        // A session the user didn't open (a team member's) commits there too, its hooks say.
        let team = book.vault(folder: app.folder, as: { .session("worker-session") }, userOpened: false)
        let event: (String) -> [String: Any] = { ["hook_event_name": $0, "tool_name": "Bash", "tool_input": ["command": "git commit -am x"], "cwd": worktree, "tool_use_id": "w1"] }
        for (root, step) in GitMoves.steps(for: event("PreToolUse")) { try team.record(step, root: root) }
        try commit("README.md", in: worktree)
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
        let team = book.vault(folder: app.folder, as: { .session("worker-session") }, userOpened: false)
        let event: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "git commit -am x"], "cwd": worktree, "tool_use_id": "w1"]
        for (root, step) in GitMoves.steps(for: event) { try team.record(step, root: root) }
        try commit("README.md", in: worktree)
        moves.look([root])
        let move = try #require(moves.asking[root])
        #expect(move.team == true)
        #expect(takers.isEmpty)
        #expect(app.headMoved(root: root, branch: "fair-launch") != nil)
    }

    /// A line counts only for what appeared after it was sent, within `Typed.lasts`, and once.
    @Test func aLineYouSentCountsOnlyForWhatAppearedSoonAfterItAndOnce() throws {
        let (moves, worktree) = try switchedBase()
        let line = "! cd \(worktree) && git commit -am 'mine'"
        // Sent after the commit (its reflog entry is older): not what it made.
        try commit("README.md", in: worktree)
        moves.typed(line, session: "lead-session", cwd: root, at: Date().addingTimeInterval(3))
        moves.look([root], now: Date().addingTimeInterval(4))
        #expect(moves.asking[root] != nil)
        #expect(takers.isEmpty)
        // Looked at for that move: used up, though it was asked about.
        #expect(moves.sent.isEmpty)
        moves.accept(root)

        // Sent long before the commit (a commit that failed, say): not what it made either.
        moves.typed(line, session: "lead-session", cwd: root, at: Date().addingTimeInterval(-(LeadVault.Typed.lasts + 10)))
        try commit("b.txt", in: worktree)
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
        try commit("README.md", in: worktree)
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

    /// hang-20261027-175604: a stat waited 3 s on a busy disk. The engine looks at each base from its queue; the reflog
    /// and workflow.md are stamped off it, after a look and at the next to see whether either changed.
    @Test func theBaseIsStampedOffTheEngineQueue() async throws {
        try commit("b.txt")
        let engine = DispatchQueue(label: "base-move-tests.engine")
        let key = DispatchSpecificKey<Bool>()
        engine.setSpecific(key: key, value: true)
        let moves = BaseMoveStore(vault: app, reads: reads, main: { engine.async(execute: $0) })
        let seen = Locked<(asked: Int, off: Int, on: Int)>((0, 0, 0))
        moves.onAsk = { _, _ in seen.mutate { $0.asked += 1 } }
        moves.stamped = { _ in seen.mutate { DispatchQueue.getSpecific(key: key) == true ? ($0.on += 1) : ($0.off += 1) } }
        engine.sync { moves.look([root]) }
        #expect(await eventually { seen.value.asked == 1 })
        #expect(await eventually { seen.value.off == 1 })
        // Nothing changed and not due: only the stamps are taken, to see that.
        engine.sync { moves.look([root]) }
        #expect(await eventually { seen.value.off == 2 })
        #expect(await eventually {
            engine.sync { moves.look([self.root]) }
            return seen.value.off >= 3
        })
        #expect(seen.value.on == 0)
        #expect(seen.value.asked == 1)
    }
}

extension BaseMoveStoreTests {
    /// `base show FOLDER [--from COMMIT]` with no lead running (a fresh vault's, S7), on a scratch host through the
    /// server's requests: refused until the user's `config accept` recorded workflow.md's base; then a card listing what
    /// came in since the commit given, which `base accept` records as the head.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(5))) func baseShowMakesACardWithNoLeadRunning() async throws {
        let world = try await CardWorld.make(temp)
        defer { world.stop() }
        let first = Git.run(["rev-parse", "main"], in: world.repo).output
        let commit = try await taskBranch(world.repo, task: "x")
        #expect(Git.run(["merge", "-q", "--ff-only", "agent/x"], in: world.repo).ok)

        let early = try #require(await world.ask("base.show", ["folder": .string(world.repo), "from": .string(first)]))
        #expect(early.error?.code == NodeWire.Code.refused.rawValue && early.error?.message.contains("config accept") == true, "\(early)")

        let held = try #require(await world.ask("config.held", ["folder": .string(world.repo)]))
        let configCard = try #require(held.result?["card"]?["id"]?.string, "\(held)")
        #expect(try #require(await world.ask("config.accept", ["card": .string(configCard), "code": .string(NodeIds.code(card: configCard))])).ok)

        let shown = try #require(await world.ask("base.show", ["folder": .string(world.repo), "from": .string(first)]))
        let card = try #require(shown.result?["card"], "\(shown)")
        #expect(card["base"]?["branch"]?.string == "main")
        #expect(card["base"]?["from"]?.string == first && card["base"]?["fromIs"]?.string == "given")
        #expect(card["base"]?["to"]?.string == commit)
        #expect(card["base"]?["commits"]?.array?.compactMap { $0["subject"]?.string } == ["change"])
        #expect(world.queue.sync { world.engine.leads.leads.values.contains { $0.session != nil } } == false)

        let id = try #require(card["id"]?.string)
        let accepted = try #require(await world.ask("base.accept", ["card": .string(id), "code": .string(NodeIds.code(card: id))]))
        #expect(accepted.ok, "\(accepted)")
        let vault = world.host.vault
        #expect(try await offPool { try vault.head(root: world.repo, branch: "main") } == commit)
        #expect(world.card(id)?.closed == "accepted")

        // With no head recorded and none given: the last commits, said.
        let other = world.host.folder.appendingPathComponent("other", isDirectory: true)
        try await scratchRepository(other)
        let otherRoot = other.resolvingSymlinksInPath().path
        let otherHeld = try #require(await world.ask("config.held", ["folder": .string(otherRoot)]))
        let otherCard = try #require(otherHeld.result?["card"]?["id"]?.string)
        #expect(try #require(await world.ask("config.accept", ["card": .string(otherCard), "code": .string(NodeIds.code(card: otherCard))])).ok)
        let none = try #require(await world.ask("base.show", ["folder": .string(otherRoot)]))
        #expect(none.result?["card"]?["base"]?["fromIs"]?.string == "none", "\(none)")
        #expect(none.result?["card"]?["base"]?["reason"]?.string?.contains("last 20 commits") == true, "\(none)")
    }

    /// The user's `base show` card for a move, then the engine's own look finding that same move (A16's flake under
    /// load: its card closed the one the user was accepting, "superseded by a newer move"): the user's card stays open
    /// and is accepted; a move somewhere else still supersedes it.
    @Test(NodeTraits.linuxOnly, .timeLimit(.minutes(5))) func theLooksAskForTheMoveShownKeepsTheShownCard() async throws {
        let world = try await CardWorld.make(temp)
        defer { world.stop() }
        let first = Git.run(["rev-parse", "main"], in: world.repo).output
        let commit = try await taskBranch(world.repo, task: "x")
        #expect(Git.run(["merge", "-q", "--ff-only", "agent/x"], in: world.repo).ok)
        let held = try #require(await world.ask("config.held", ["folder": .string(world.repo)]))
        let configCard = try #require(held.result?["card"]?["id"]?.string, "\(held)")
        #expect(try #require(await world.ask("config.accept", ["card": .string(configCard), "code": .string(NodeIds.code(card: configCard))])).ok)
        let shown = try #require(await world.ask("base.show", ["folder": .string(world.repo), "from": .string(first)]))
        let id = try #require(shown.result?["card"]?["id"]?.string, "\(shown)")

        // The look finds that same move and asks (as `lookAtBases` does at a refresh): the shown card stays the move's.
        let move = try JSONDecoder().decode(LeadVault.BaseMove.self, from: Data("""
            {"branch":"main","from":"\(first)","to":"\(commit)","accepted":false,"commits":[],"sessions":[],"reason":"no session of yours made it"}
            """.utf8))
        world.queue.sync { world.engine.baseMoves.onAsk(world.repo, move) }
        #expect(world.card(id)?.closed == nil, "\(String(describing: world.card(id)?.closed))")
        #expect(world.queue.sync { world.engine.cards.list(project: world.project).filter { $0.kind == .baseMove }.count } == 1)
        let accepted = try #require(await world.ask("base.accept", ["card": .string(id), "code": .string(NodeIds.code(card: id))]))
        #expect(accepted.ok, "\(accepted)")
        let vault = world.host.vault
        #expect(try await offPool { try vault.head(root: world.repo, branch: "main") } == commit)

        // A move to somewhere else still supersedes an open card.
        let again = try #require(await world.ask("base.show", ["folder": .string(world.repo), "from": .string(first)]))
        let second = try #require(again.result?["card"]?["id"]?.string, "\(again)")
        var elsewhere = move
        elsewhere.to = String(repeating: "e", count: 40)
        world.queue.sync { world.engine.baseMoves.onAsk(world.repo, elsewhere) }
        #expect(world.card(second)?.closed == "superseded by a newer move")
    }
}
