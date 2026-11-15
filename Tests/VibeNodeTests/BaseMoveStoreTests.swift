import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// A lead's base moving outside its merges (`BaseMoveStore`; the app's `BaseMovesTests`, the cases that need no window,
/// ported: the engine plan's E6): a move of the user's is taken without asking; any other is a card, asked once, and
/// `base accept` takes it in the vault with the lead running on; `base show` makes a card with no lead running. The five
/// cases about `!` lines sent from the window aren't ported: no composer sends them before stage 5.
final class BaseMoveStoreTests {
    let temp = Scratch()
    let book = LeadVault.Book()
    let app: LeadVault
    let root: String
    /// The engine's reads queue (the boards' and the notes' writes): read through it, a read sees what was written before.
    let reads = BoardReads(handTo: DispatchQueue(label: "base-move-tests.handed"))
    var asked: [String] = []
    var taken: [(to: String, byYou: Bool)] = []
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
        moves.onTaken = { [unowned self] _, move, taker in taken.append((move.to, taker == .you)) }
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
        reads.async({ _ in gate.wait() })
        moves.look([root])
        #expect(taken.map(\.to) == [head()])
        // The queue is held: nothing written yet.
        #expect(!BoardStore(root: root).load().updates.contains { $0.title.hasPrefix("Took") })
        gate.signal()
        let update = try #require(board().updates.last)
        #expect(update.title == "Took 1 commit on main")
        #expect(update.body.hasPrefix("accepted 1 commit on main from your session"), "\(update.body)")
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
        #expect(refusal.contains("VibeSwitcher is asking the user"), "\(refusal)")
        try LeadVault.BaseMoveRefusal(branch: "fair-launch", to: now, at: 1).save(root: root)

        moves.accept(root)
        #expect(app.headMoved(root: root, branch: "fair-launch") == nil)
        _ = board()
        #expect(LeadVault.BaseMoveNote.load(root: root) == nil)
        // Taken: no merge waits on the user any more.
        #expect(LeadVault.BaseMoveRefusal.load(root: root) == nil)
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
}
