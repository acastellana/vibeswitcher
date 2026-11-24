import AppKit
import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// A code block's Run in New Shell (`RunInShellButton`): it starts a New Shell session in the folder of the session
/// shown by the path a vs-shell card's Run takes (`ShellDesk.runBlock` → `ShellDesk.launch` → `ShellAsk.spawnRequest`), the
/// block's command given to the new shell at launch, never typed into any terminal (2026-11-06 decision). The desk's
/// `launch` records, never spawns; the runner's `run` (what types into a session) records any call, which must not come.
@MainActor
@Suite(.serialized)
struct RunInShellTests {
    let scratch = Scratch()
    static let folder = "/work/site"
    static let session = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    static let shell = UUID(uuidString: "99999999-2222-4333-8444-555555555555")!
    /// The block from 2026-11-18: a lead's local server in a bare fence (its header "code").
    static let server = "cd /work/site/prototype && python3 -m http.server 8123"

    final class Seen {
        var launched: [ShellRequest] = []
        var typed: [String] = []
        var asked: [RunnableCommand.Runnable] = []
        var refused: [String] = []
        var logged: [String] = []
    }

    /// A desk whose `launch` records what it was given (and answers `failure` when given one), and a runner wired to it
    /// as the window wires its chat's (`MainWindowController.openShell`).
    func setUp(_ seen: Seen, failure: String? = nil) -> (ShellDesk, ChatRunner) {
        let desk = ShellDesk(folder: scratch.url("shells"), log: { seen.logged.append($0) })
        desk.launch = { request, then in
            seen.launched.append(request)
            if let failure { return then(.failure(ShellAsk.Refusal(failure))) }
            then(.success((Self.shell, ShellAsk.sessionLabel(request))))
        }
        let runner = ChatRunner()
        runner.way = .bang
        runner.folder = Self.folder
        runner.session = { Self.session }
        runner.sessionKind = { "claude" }
        runner.refused = { seen.refused.append($0) }
        runner.log = { seen.logged.append($0) }
        runner.run = { runnable, way, done in
            seen.typed.append(runnable.typed(way))
            done(.ran)
        }
        runner.openShell = { runnable, folder, session, done in
            desk.runBlock(command: runnable.command, cwd: folder, from: session, done: done)
        }
        return (desk, runner)
    }

    func run(_ runnable: RunnableCommand.Runnable, _ runner: ChatRunner, _ seen: Seen, confirm: Bool = true,
             meanwhile: @escaping () -> Void = {}) -> RunOutcome?? {
        var outcome: RunOutcome??
        RunInShellButton.run(runnable, in: Self.folder, with: runner, confirm: {
            seen.asked.append($0)
            meanwhile()
            return confirm
        }) { outcome = .some($0) }
        return outcome
    }

    /// The reported block: a bare fence holding a server's command. Confirmed, it starts one New Shell session whose
    /// launch carries exactly the block's command, in the session's folder, given to the shell in a variable at launch.
    @Test func theServerBlockStartsANewShellRunningExactlyItsCommand() throws {
        let seen = Seen()
        let (_, runner) = setUp(seen)
        let runnable = try #require(RunnableCommand.runnable(code: Self.server + "\n", language: nil))
        #expect(run(runnable, runner, seen) == .some(.ran))
        // Untagged: always asked first, showing the command.
        #expect(seen.asked == [runnable])
        let request = try #require(seen.launched.first)
        #expect(seen.launched.count == 1)
        #expect(request.command == Self.server)
        #expect(request.cwd == Self.folder)
        #expect(request.session == Self.session.uuidString.lowercased())
        // Never typed into the session shown, nor anywhere: the shell gets it at launch.
        #expect(seen.typed.isEmpty)
        let spawn = ShellAsk.spawnRequest(request)
        #expect(spawn.cwd == Self.folder)
        #expect(spawn.env[ShellAsk.commandVariable] == Self.server)
        #expect(spawn.keepShell)
        #expect(spawn.agent == nil)
        // The launch line runs the variable; the command itself isn't in it.
        #expect(spawn.command == "\(ShellTidy.launchLine) \(ShellTidy.report)")
        #expect(spawn.command?.contains("http.server") == false)
        // What app.log keeps: its length and the new session, never its words.
        #expect(seen.logged.contains { $0.contains("started as \(Self.shell)") })
        #expect(!seen.logged.joined().contains("http.server"))
    }

    /// A plain line Run types without asking starts its new shell without asking too: your click is what starts it.
    @Test func aPlainLineStartsWithoutAskingAndAScriptsFileIsWrittenFirst() throws {
        let seen = Seen()
        let (_, runner) = setUp(seen)
        let plain = try #require(RunnableCommand.runnable(code: "npm run dev", language: "bash"))
        #expect(run(plain, runner, seen) == .some(.ran))
        #expect(seen.asked.isEmpty)
        #expect(seen.launched.map(\.command) == ["npm run dev"])

        let block = "if true; then\n  npm run dev\nfi"
        let script = try #require(RunnableCommand.runnable(code: block, language: "bash", scripts: scratch.url("scripts")))
        let file = try #require(script.script?.file)
        var written: Data?
        let launch = runner.openShell
        runner.openShell = { runnable, folder, session, done in
            written = FileManager.default.contents(atPath: file.path)
            launch(runnable, folder, session, done)
        }
        #expect(run(script, runner, seen) == .some(.ran))
        #expect(seen.asked == [script])
        #expect(written == Data(block.utf8))
        #expect(seen.launched.last?.command == script.command)
        #expect(seen.typed.isEmpty)
    }

    @Test func cancelledOrMovedMeanwhileNothingStarts() throws {
        let seen = Seen()
        let (_, runner) = setUp(seen)
        let runnable = try #require(RunnableCommand.runnable(code: Self.server, language: nil))
        #expect(run(runnable, runner, seen, confirm: false) == .some(nil))
        #expect(seen.launched.isEmpty && seen.refused.isEmpty)
        // While it asked, the window came to show another folder: refused, said, logged by kind.
        let outcome = run(runnable, runner, seen) { runner.folder = "/work/other" }
        #expect(outcome == .some(.refused(RunRefusal.folderChanged)))
        #expect(seen.launched.isEmpty)
        #expect(seen.refused == [RunRefusal.folderChanged])
        #expect(seen.logged.last == "chat: Run refused (claude session), kind: folderChanged")
        // Or another session in the same folder.
        runner.folder = Self.folder
        let other = UUID()
        #expect(run(runnable, runner, seen) { runner.session = { other } } == .some(.refused(RunRefusal.folderChanged)))
        #expect(seen.launched.isEmpty && seen.typed.isEmpty)
    }

    /// A launch that fails, or a folder a card couldn't name either: "Not run: …" in the chat's words, by kind in app.log.
    @Test func aShellThatDoesntStartSaysWhy() throws {
        let seen = Seen()
        let (desk, runner) = setUp(seen, failure: "No such folder: /work/site")
        let runnable = try #require(RunnableCommand.runnable(code: "npm run dev", language: "bash"))
        let why = RunRefusal.shellNotStarted("No such folder: /work/site")
        #expect(run(runnable, runner, seen) == .some(.refused(why)))
        #expect(seen.refused == [why])
        #expect(seen.logged.last == "chat: Run refused (claude session), kind: shellNotStarted")
        // Held to a card's rules: a folder that isn't plainly absolute never reaches launch.
        var outcome: RunOutcome?
        desk.runBlock(command: "npm run dev", cwd: "work/../site", from: Self.session) { outcome = $0 }
        #expect(outcome.map { if case .refused(let reason) = $0 { reason.hasPrefix("Not run: the shell session didn't start (cwd:") } else { false } } == true)
        #expect(seen.launched.count == 1)
    }

    /// The confirmation names the folder and shows the command in full, wrapped: a line wider than the block is all there.
    @Test func theConfirmationShowsTheFolderAndTheWholeCommand() throws {
        let wide = Self.server + " --bind 127.0.0.1 " + Array(repeating: "--directory /work/site/prototype/public", count: 6).joined(separator: " ")
        let runnable = try #require(RunnableCommand.runnable(code: wide, language: nil))
        let alert = RunInShellButton.confirmation(runnable, folder: Self.folder)
        #expect(alert.messageText == "Run this in a new shell session?")
        #expect(alert.informativeText.contains(Self.folder))
        #expect(alert.buttons.map(\.title) == ["Run in New Shell", "Cancel"])
        let text = try #require((alert.accessoryView as? NSScrollView)?.documentView as? NSTextView)
        #expect(text.string == wide)
        // Wrapped to the box: nothing off to the side.
        #expect(text.textContainer?.widthTracksTextView == true)
        #expect(text.isHorizontallyResizable == false)
    }

    /// Shown beside Run while the session shown has a folder; the header's two buttons.
    @Test func itsLabelsFollowWhatCameOfIt() {
        #expect(RunInShellButton.label(.ready) == "Run in New Shell")
        #expect(RunInShellButton.label(.sent) == "Started")
        #expect(RunInShellButton.label(.refused("Not run: x")) == "Not run")
        #expect(RunRefusal.kind(of: RunRefusal.noFolder) == "noFolder")
    }
}
