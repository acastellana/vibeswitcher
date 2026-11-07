import AppKit
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// A code block's Run (`RunButton`): what its confirmation shows, and what it writes and types once you confirm. The
/// session is a `ChatRunner` whose `run` keeps what it was given: nothing is typed anywhere.
@MainActor
struct RunButtonTests {
    let scratch = Scratch()

    static let block = """
        W=/work/project; M=3f2a91c
        if [ -z "$(git -C "$W" diff $M HEAD)" ]; then
          git -C "$W" push -u origin release &&
          echo pushed
        else echo "STOPPED: differs from $M"; fi
        """

    /// The text the confirmation shows in its box.
    static func shown(_ alert: NSAlert) -> String? {
        ((alert.accessoryView as? NSScrollView)?.documentView as? NSTextView)?.string
    }

    @Test func aScriptsConfirmationShowsTheBlockItself() throws {
        let runnable = try #require(RunnableCommand.runnable(code: Self.block, language: "bash", scripts: scratch.url("scripts")))
        let alert = RunButton.confirmation(runnable)
        #expect(Self.shown(alert) == Self.block)
        #expect(alert.informativeText.contains("one bash script, exactly as shown"))
        #expect(alert.informativeText.hasSuffix(runnable.prompt))
        #expect(alert.buttons.map(\.title) == ["Run", "Cancel"])
        // A command's is what's typed, as before.
        let command = try #require(RunnableCommand.runnable(code: "git push origin main", language: "bash"))
        #expect(Self.shown(RunButton.confirmation(command)) == "! git push origin main")
    }

    /// A runner whose session is `id`, taking commands `way`, keeping what it's asked to type and answering `answer`.
    static func runner(way: RunnableCommand.Way? = .bang, id: UUID? = UUID(), answer: RunOutcome = .ran,
                       typed: @escaping (String) -> Void = { _ in }) -> ChatRunner {
        let runner = ChatRunner()
        runner.way = way
        runner.session = { id }
        runner.run = { runnable, way, done in
            typed(runnable.typed(way))
            done(answer)
        }
        return runner
    }

    @Test func runWritesTheScriptThenTypesItsPrompt() throws {
        let runnable = try #require(RunnableCommand.runnable(code: Self.block, language: "bash", scripts: scratch.url("scripts")))
        let script = try #require(runnable.script)
        var typed: [String] = []
        var fileWhenTyped: Data?
        var answer = RunOutcome.ran
        let runner = ChatRunner()
        runner.way = .bang
        let id = UUID()
        runner.session = { id }
        runner.run = { runnable, way, done in
            typed.append(runnable.typed(way))
            fileWhenTyped = FileManager.default.contents(atPath: script.file.path)
            done(answer)
        }
        var outcomes: [RunOutcome?] = []
        // Cancelled: nothing written, nothing typed.
        var asked: [RunnableCommand.Runnable] = []
        RunButton.run(runnable, way: .bang, with: runner, confirm: { asked.append($0); return false }) { outcomes.append($0) }
        #expect(outcomes == [nil])
        #expect(asked == [runnable])
        #expect(typed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: script.file.path))
        // Confirmed: the file holds the block exactly, private, before the prompt that runs it is typed.
        RunButton.run(runnable, way: .bang, with: runner, confirm: { _ in true }) { outcomes.append($0) }
        #expect(outcomes.last == .ran)
        #expect(typed == [runnable.prompt])
        #expect(fileWhenTyped == Data(Self.block.utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: script.file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        // The session couldn't take it: the file goes too, unless an earlier Run's (maybe still queued) was there.
        try FileManager.default.removeItem(at: script.file)
        answer = .refused("Not run: because.")
        RunButton.run(runnable, way: .bang, with: runner, confirm: { _ in true }) { outcomes.append($0) }
        #expect(outcomes.last == .refused("Not run: because."))
        #expect(!FileManager.default.fileExists(atPath: script.file.path))
    }

    @Test func aPlainLineIsTypedWithoutAsking() throws {
        let runnable = try #require(RunnableCommand.runnable(code: "swift test", language: "bash"))
        var typed: [String] = []
        let runner = Self.runner { typed.append($0) }
        RunButton.run(runnable, way: .bang, with: runner, confirm: { _ in Issue.record("asked"); return false })
        #expect(typed == ["! swift test"])
    }
}
