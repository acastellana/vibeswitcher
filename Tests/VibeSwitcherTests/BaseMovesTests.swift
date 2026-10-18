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

    func commit(_ file: String) throws {
        try "\(file)\n".write(toFile: root + "/" + file, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: root)
        #expect(Git.run(["commit", "-q", "-m", "add \(file)"], in: root).ok)
    }

    func moves() -> BaseMoves {
        let moves = BaseMoves(vault: app, background: { $0() }, main: { $0() })
        moves.onAsk = { [unowned self] _, move in asked.append(move.to) }
        moves.onTaken = { [unowned self] _, move, byYou in taken.append((move.to, byYou)) }
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

    @Test func aCommitOfYoursIsTakenWithoutAsking() throws {
        try yours("git commit -m b") { try commit("b.txt") }
        let moves = moves()
        moves.look([root])
        #expect(moves.asking.isEmpty)
        #expect(asked.isEmpty)
        #expect(taken.map(\.to) == [head()])
        #expect(taken.first?.byYou == false)
        #expect(app.headMoved(root: root, branch: "main") == nil)
        let update = try #require(BoardStore(root: root).load().updates.last)
        #expect(update.body.hasPrefix("accepted 1 commit on main from your session"), "\(update.body)")
        #expect(logged.contains { $0.contains("accepted 1 commit on main") && $0.contains(String(head().prefix(7))) })
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
        #expect(BoardStore(root: root).load().updates.last?.body.hasPrefix("You accepted 1 commit on main") == true)
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
}
