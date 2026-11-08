import AppKit
import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// A code block's Run typed into a session (`ChatSync.run`), against a fake Claude under a scratch session host (the
/// chat sync harness): never into a draft in Claude's box, never into a question's keys, at a plain shell's prompt
/// only, and each time it can't go, why, in words.
@MainActor
@Suite(.serialized)
struct RunInSessionTests {
    let temp = Scratch()

    /// The `!` commands the fake agent ran, as Claude Code records them (`<bash-input>`).
    static func ran(_ h: Harness) -> [String] {
        let transcript = (try? String(contentsOf: h.transcript, encoding: .utf8)) ?? ""
        return transcript.components(separatedBy: "<bash-input>").dropFirst().compactMap { $0.components(separatedBy: "</bash-input>").first }
    }

    /// `sync.run`'s answer, once it has given one.
    static func run(_ text: String, _ h: Harness) async throws -> String?? {
        var answer: String??
        h.sync.run(text) { answer = .some($0) }
        try await h.waitFor { answer != nil }
        return answer
    }

    @Test func aRunWaitsForADraftInClaudesBoxToGoAndThenRuns() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.keys("half a thought")
        try await h.waitFor { h.agent["input"] as? String == "half a thought" }
        // Typed now, `! echo` would join the draft and go to Claude as a message.
        let refused = try await Self.run("! echo RAN", h)
        #expect(refused == .some(ChatSync.behindDraft(.claude)))
        try await h.quiet()
        #expect(h.agent["input"] as? String == "half a thought")
        #expect(Self.ran(h).isEmpty)
        #expect(!h.agentPrompts.contains { $0.contains("RAN") })
        // The draft cleared: it runs, as the command.
        h.keys("\u{15}")
        try await h.waitFor { (h.agent["input"] as? String)?.isEmpty == true }
        let ran = try await Self.run("! echo RAN", h)
        #expect(ran == .some(nil))
        try await h.waitFor { Self.ran(h) == ["echo RAN"] }
    }

    @Test func aRunWithAQuestionOpenSaysWhyItDidntGo() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "permission", "command": "touch notes.txt"])
        try await h.settle { $0.contains("Do you want to proceed?") }
        // Not the composer's (nothing would send it later): refused, and the line under the composer says so, not
        // that it waits.
        #expect(!h.sync.type("! echo RAN"))
        #expect(h.chat.sendNotice == "Not sent: a question is open in the terminal. Answer it, then try again.")
        let refused = try await Self.run("! echo RAN", h)
        #expect(refused == .some("Not sent: a question is open in the terminal. Answer it, then try again."))
        try await h.quiet()
        #expect(Self.ran(h).isEmpty)
        #expect(h.screen.contains("Do you want to proceed?"))
    }

    @Test func aRunIsNeverAnAnswerToAQuestionThatTakesFreeText() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [ChatSyncTests.fruit]])
        try await h.settle { $0.contains("Which fruit?") }
        // Its "Type something." row would take the command as the answer, and nothing would run.
        let refused = try await Self.run("! git push origin main", h)
        #expect(refused == .some("Not sent: a question is open in the terminal. Answer it, then try again."))
        try await h.quiet()
        #expect(h.screen.contains("Which fruit?"))
        #expect(!h.screen.contains("git push"), "\(h.screen)")
        #expect(Self.ran(h).isEmpty)
    }

    /// A line of the screen that's exactly `text`, or a prompt and then `text` (with echo off, a command's output goes
    /// on the prompt's line).
    static func shows(_ text: String, _ h: Harness) -> Bool {
        h.screen.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { $0 == text || $0.hasSuffix("$ " + text) }
    }

    @Test func aRunAtAShellsPromptDoesntJoinWhatWasHalfTyped() async throws {
        let h = try await Harness.start(temp, keepShell: true)
        defer { h.stop() }
        let pid = try #require(h.agent["pid"] as? Int)
        let shell = h.session.childPID
        h.sync.shellAtPrompt = { _ in ProcessTable.holdsForeground(pid: shell) == true }
        h.tell(["op": "exit"])
        try await h.waitFor { !ChatSync.alive(pid: Int32(pid), on: h.session.tty) }
        try await h.waitFor { ProcessTable.holdsForeground(pid: shell) == true }
        h.targetAgent = nil
        // The shell flushes what's typed ahead as it takes the terminal back: its prompt first.
        try await h.paneShows { $0.split(separator: "\n").last?.hasSuffix("$") == true }
        // Half a command on the line: the Run's command runs on its own, not as `echo PARTIALecho …`.
        h.keys("echo PARTIAL")
        // (The fake left the terminal without echo: it's on the line, not shown.)
        try await h.quiet()
        #expect(try await Self.run("echo RAN_$((6*7))", h) == .some(nil))
        try await h.waitFor { Self.shows("RAN_42", h) }
        #expect(!h.screen.contains("PARTIALecho"), "\(h.screen)")
        // A loop left open: the command isn't its body.
        h.keys("for f in 1 2; do\r")
        try await h.quiet()
        #expect(try await Self.run("echo AGAIN_$((6*7))", h) == .some(nil))
        try await h.waitFor { Self.shows("AGAIN_42", h) }
    }

    @Test func aPlainShellTakesARunOnlyAtItsPrompt() async throws {
        let h = try await Harness.start(temp, keepShell: true)
        defer { h.stop() }
        let pid = try #require(h.agent["pid"] as? Int)
        let shell = h.session.childPID
        h.sync.shellAtPrompt = { _ in ProcessTable.holdsForeground(pid: shell) == true }
        // The agent holds the terminal: the shell isn't at its prompt.
        #expect(ProcessTable.holdsForeground(pid: shell) == false)
        h.tell(["op": "exit"])
        try await h.waitFor { !ChatSync.alive(pid: Int32(pid), on: h.session.tty) }
        try await h.waitFor { ProcessTable.holdsForeground(pid: shell) == true }
        h.targetAgent = nil
        // At its prompt: typed as it is, no `!`.
        let ran = try await Self.run("echo RAN_$((6*7))", h)
        #expect(ran == .some(nil))
        try await h.paneShows { $0.contains("RAN_42") }
        // A program in the foreground: refused, saying why, and nothing typed into it.
        h.keys("sleep 30\r")
        try await h.waitFor { ProcessTable.holdsForeground(pid: shell) == false }
        let before = h.screen
        let refused = try await Self.run("echo LEAKED_$((6*7))", h)
        #expect(refused == .some(ChatSync.shellBusy))
        try await h.quiet()
        #expect(!h.screen.contains("LEAKED_42"))
        #expect(h.screen == before)
    }

    @Test func aRunConfirmedAfterTheWindowShowsAnotherSessionDoesntGo() throws {
        let runnable = try #require(RunnableCommand.runnable(code: "git push origin main", language: "bash"))
        var typed: [String] = []
        var refusals: [String] = []
        var shown = UUID()
        let runner = ChatRunner()
        runner.way = .bang
        runner.session = { shown }
        runner.refused = { refusals.append($0) }
        runner.run = { runnable, way, done in
            typed.append(runnable.typed(way))
            done(.ran)
        }
        var outcome: RunOutcome??
        // While it asks, another session is selected.
        RunButton.run(runnable, way: .bang, with: runner, confirm: { _ in shown = UUID(); return true }) { outcome = .some($0) }
        #expect(outcome == .some(.refused(RunRefusal.otherSession)))
        #expect(typed.isEmpty)
        #expect(refusals == [RunRefusal.otherSession])
        // Or its agent exited, leaving a shell: what it would type differs, so it doesn't go.
        RunButton.run(runnable, way: .bang, with: runner, confirm: { _ in runner.way = .shell; return true }) { outcome = .some($0) }
        #expect(outcome == .some(.refused(RunRefusal.wayChanged)))
        #expect(typed.isEmpty)
        // Asked and still the same: typed as the session takes it.
        RunButton.run(runnable, way: .shell, with: runner, confirm: { _ in true }) { outcome = .some($0) }
        #expect(outcome == .some(.ran))
        #expect(typed == ["git push origin main"])
    }
}
