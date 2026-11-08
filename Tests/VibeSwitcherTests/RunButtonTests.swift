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

    // MARK: Refusals in app.log

    /// Each way a Run is refused writes one app.log line naming its kind and the session's, never what it was asked to
    /// run nor the reason's words (a script's path, an error's text). The log watcher counts each kind as one cause.
    @Test func eachRefusalWritesOneLogLineWithItsKindAndNothingItRan() throws {
        let blocked = scratch.url("blocked")
        try Data("a file, not a folder".utf8).write(to: blocked)
        let script = try #require(RunnableCommand.runnable(code: Self.block, language: "bash", scripts: scratch.url("scripts")))
        let unwritable = try #require(RunnableCommand.runnable(code: Self.block, language: "bash",
                                                               scripts: blocked.appendingPathComponent("scripts")))
        let line = try #require(RunnableCommand.runnable(code: "git push origin secret-branch-name", language: "bash"))
        var logged: [String] = []
        var outcome: RunOutcome??
        func refused(_ runner: ChatRunner, _ runnable: RunnableCommand.Runnable, way: RunnableCommand.Way = .bang,
                     confirm: @escaping (RunnableCommand.Runnable) -> Bool = { _ in true }) -> String? {
            logged = []
            outcome = nil
            runner.sessionKind = { "claude" }
            runner.log = { logged.append($0) }
            RunButton.run(runnable, way: way, with: runner, confirm: confirm) { outcome = .some($0) }
            guard case .refused(let reason)?? = outcome else { Issue.record("not refused: \(String(describing: outcome))"); return nil }
            #expect(logged.count == 1, "\(logged)")
            for text in logged {
                #expect(text.hasPrefix("chat: Run refused (claude session), kind: "))
                for secret in ["secret-branch-name", "git push", "STOPPED", scratch.url("").path, "/", reason] {
                    #expect(!text.contains(secret), "\(text) holds \(secret)")
                }
            }
            return logged.first.map { String($0.dropFirst("chat: Run refused (claude session), kind: ".count)) }
        }
        // The button's own: no session there, another session shown meanwhile, the way it takes commands changed, the
        // script's file couldn't be written.
        let alone = ChatRunner()
        alone.way = .bang
        let id = UUID()
        alone.session = { id }
        #expect(refused(alone, line) == "noSession")
        let switched = Self.runner()
        #expect(refused(switched, script, confirm: { _ in switched.session = { UUID() }; return true }) == "otherSession")
        let changed = Self.runner()
        #expect(refused(changed, script, confirm: { _ in changed.way = .shell; return true }) == "wayChanged")
        #expect(refused(Self.runner(), unwritable) == "notWritten")
        // The session's own, from the window and `ChatSync.run`; and one nobody named yet.
        let answers: [(String, String)] = [
            (RunRefusal.noSession, "noSession"), (RunRefusal.otherSession, "otherSession"), (RunRefusal.wayChanged, "wayChanged"),
            (RunRefusal.replacedLead, "replacedLead"), (ChatSync.notConnected, "notConnected"), (ChatSync.shellBusy, "shellBusy"),
            (ChatSync.behindDraft(.claude), "behindDraft"), (ChatSync.behindDraft(.codex), "behindDraft"),
            (ChatSync.notTaken(.codex), "notTaken"), (ChatSync.noAgent, "noAgent"), (ChatSync.dictating, "dictating"),
            (ChatSync.pickerOpen, "pickerOpen"), (ChatSync.questionOpen, "questionOpen"),
            (RunRefusal.notWritten(CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/Users/someone/x.sh"])), "notWritten"),
            ("Not run: some reason nobody named at /Users/someone/x.", "other"),
        ]
        for (reason, kind) in answers {
            #expect(refused(Self.runner(answer: .refused(reason)), line) == kind, "\(reason)")
            #expect(refused(Self.runner(answer: .refused(reason)), script) == kind, "\(reason)")
        }
        // Run: nothing logged.
        logged = []
        let ran = Self.runner()
        ran.log = { logged.append($0) }
        RunButton.run(line, way: .bang, with: ran, confirm: { _ in true })
        #expect(logged.isEmpty)
    }

    /// The line goes to the app's own log (`Breadcrumbs`, app.log once the app turns its file on), and the log watcher
    /// takes it as one cause per kind, whatever the session.
    @Test func aRefusalsLineIsTheAppLogsAndTheWatcherGroupsItByKind() throws {
        let line = try #require(RunnableCommand.runnable(code: "make deploy", language: "bash"))
        let runner = Self.runner(answer: .refused(ChatSync.shellBusy))
        let kind = "probe\(UUID().uuidString.prefix(8).filter(\.isLetter))"
        runner.sessionKind = { kind }
        RunButton.run(line, way: .bang, with: runner, confirm: { _ in true })
        #expect(Breadcrumbs.shared.lines.contains { $0.hasSuffix("chat: Run refused (\(kind) session), kind: shellBusy") })
        let at = "2026-11-08 10:00:00"
        for session in ["claude", "codex", "shell", "none"] {
            #expect(AppHealth.cause(ofLine: "10:00:00.000 " + RunRefusal.logLine(RunRefusal.wayChanged, session: session), at: at)?.key
                        == "notice Code block's Run refused: wayChanged")
        }
        #expect(AppHealth.cause(ofLine: RunRefusal.logLine(ChatSync.shellBusy, session: "shell"), at: at)?.key
                    == "notice Code block's Run refused: shellBusy")
    }
}
