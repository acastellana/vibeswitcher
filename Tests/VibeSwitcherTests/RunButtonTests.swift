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

    @Test func runWritesTheScriptThenTypesItsPrompt() throws {
        let runnable = try #require(RunnableCommand.runnable(code: Self.block, language: "bash", scripts: scratch.url("scripts")))
        let script = try #require(runnable.script)
        let runner = ChatRunner()
        var typed: [String] = []
        var fileWhenTyped: Data?
        runner.run = { prompt in
            typed.append(prompt)
            fileWhenTyped = FileManager.default.contents(atPath: script.file.path)
            return true
        }
        // Cancelled: nothing written, nothing typed.
        var asked: [RunnableCommand.Runnable] = []
        #expect(!RunButton.run(runnable, with: runner, confirm: { asked.append($0); return false }))
        #expect(asked == [runnable])
        #expect(typed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: script.file.path))
        // Confirmed: the file holds the block exactly, private, before the prompt that runs it is typed.
        #expect(RunButton.run(runnable, with: runner, confirm: { _ in true }))
        #expect(typed == [runnable.prompt])
        #expect(fileWhenTyped == Data(Self.block.utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: script.file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        // The session couldn't take it: the file goes too.
        runner.run = { _ in false }
        #expect(!RunButton.run(runnable, with: runner, confirm: { _ in true }))
        #expect(!FileManager.default.fileExists(atPath: script.file.path))
    }

    @Test func aPlainLineIsTypedWithoutAsking() throws {
        let runnable = try #require(RunnableCommand.runnable(code: "swift test", language: "bash"))
        let runner = ChatRunner()
        var typed: [String] = []
        runner.run = { typed.append($0); return true }
        #expect(RunButton.run(runnable, with: runner, confirm: { _ in Issue.record("asked"); return false }))
        #expect(typed == ["! swift test"])
    }
}
