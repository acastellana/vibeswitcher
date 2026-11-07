import CryptoKit
import Foundation
import Testing
import UserNotifications
import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// The incident of 2026-11-05 and the decision of 2026-11-07: a user clicked a permission prompt's notification
/// thinking it allowed the prompt, and nothing was sent (`Notifier.didReceive` only opened the session). The banner now
/// has Allow and Deny (`PromptActions`), answered the chat card's way (`PromptAnswer`): here against a fake Claude Code
/// (`FakeClaude`, on a scratch pty through a scratch session host: never a real session) drawing Claude Code 2.1.318's
/// Read file prompt, through the same handler the notification's actions call.
@MainActor
@Suite(.serialized)
struct PromptActionsTests {
    let temp = Scratch()

    nonisolated static let file = "/Users/x/dev/repo/.vibeswitcher/evidence/wallet-requests-marked/7C0E0F5B-1D2A/4-marked-no-peer-main-dark.png"

    /// The harness's fake asking to Read `file`, and the actions with that prompt prepared as a banner's is.
    private func readPrompt(_ h: Harness, file: String = Self.file) async throws -> (PromptActions, Notices) {
        h.tell(["op": "permission", "file": file])
        try await h.paneShows { $0.contains("Read file") && $0.contains("Do you want to proceed?") && $0.contains((file as NSString).lastPathComponent) }
        try await h.waitFor { h.agent["mode"] as? String == "permission" }
        let actions = PromptActions(answerer: PromptAnswer(host: h.host))
        let notices = Notices()
        actions.notice = { tty, title, body in notices.said.append((tty, title, body)) }
        var ready: Bool?
        actions.prepare(tty: h.session.tty, id: h.session.id) { ready = $0 }
        try await h.waitFor { ready != nil }
        #expect(ready == true, "the banner got no actions")
        return (actions, notices)
    }

    /// What `action` came to, the notification's handler run as `Notifier.didReceive` runs it.
    private func act(_ actions: PromptActions, _ action: String, _ h: Harness) async throws -> PromptAnswer.Failure? {
        var outcome: PromptAnswer.Failure??
        actions.handle(action, tty: h.session.tty) { outcome = .some($0) }
        try await h.waitFor { outcome != nil }
        return outcome ?? nil
    }

    private func transcript(_ h: Harness) throws -> String { try String(contentsOf: h.transcript, encoding: .utf8) }

    @Test func allowFromTheNotificationAnswersTheReadPromptYes() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let (actions, notices) = try await readPrompt(h)
        let failure = try await act(actions, PromptActions.allowAction, h)
        #expect(failure == nil, "\(String(describing: failure))")
        // Answered: the turn goes on with the Read's result (one read of its state holds both).
        try await h.waitFor {
            let agent = h.agent
            return agent["mode"] as? String == "working" && agent["reply"] as? String == "Allowed."
        }
        let lines = try transcript(h)
        #expect(lines.contains("ran Read \(Self.file)"), "no Read result: \(lines.suffix(400))")
        #expect(!lines.contains("The user doesn't want to proceed"))
        #expect(notices.said.isEmpty, "\(notices.said)")
        // The banner's Allow answers once: a second one is refused, said, and types nothing.
        let again = try await act(actions, PromptActions.allowAction, h)
        #expect(again == .unknown && notices.said.count == 1)
    }

    @Test func denyFromTheNotificationAnswersNo() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let (actions, notices) = try await readPrompt(h)
        let failure = try await act(actions, PromptActions.denyAction, h)
        #expect(failure == nil, "\(String(describing: failure))")
        try await h.waitFor {
            let agent = h.agent
            return agent["mode"] as? String == "idle" && agent["reply"] as? String == "Denied."
        }
        let lines = try transcript(h)
        #expect(lines.contains("The user doesn't want to proceed with this tool use. The tool use was rejected."), "\(lines.suffix(400))")
        #expect(!lines.contains("ran Read"), "a Yes went in: \(lines.suffix(400))")
        #expect(notices.said.isEmpty, "\(notices.said)")
    }

    /// Another prompt on screen by the time Allow is clicked: refused before any key, and said.
    @Test func aPromptThatChangedBeforeTheActionGetsNothingTypedAndANotice() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let (actions, notices) = try await readPrompt(h)
        // Answered in the terminal (Yes), and the next Read asked: another file.
        h.keys("1")
        try await h.waitFor { h.agent["reply"] as? String == "Allowed." }
        let other = "/Users/x/dev/repo/secrets/other.png"
        h.tell(["op": "permission", "file": other])
        try await h.paneShows { $0.contains("other.png") && $0.contains("Do you want to proceed?") }
        try await h.waitFor { h.agent["mode"] as? String == "permission" }
        var typed: [Data] = []
        h.host.inputGate = { _, bytes in typed.append(bytes); return false }
        let failure = try await act(actions, PromptActions.allowAction, h)
        #expect(failure == .changed)
        #expect(typed.isEmpty, "keys went in: \(typed)")
        #expect(notices.said.count == 1 && notices.said.first?.tty == h.session.tty && notices.said.first?.body == PromptAnswer.Failure.changed.text,
                "\(notices.said)")
        #expect(notices.said.first?.title == "Not allowed")
        let lines = try transcript(h)
        #expect(h.agent["mode"] as? String == "permission" && !lines.contains("ran Read \(other)"))
    }

    /// The prompt gone (answered in the terminal) before Deny: nothing typed (an Enter would land in the prompt box),
    /// and said.
    @Test func aPromptGoneBeforeTheActionGetsNothingTypedAndANotice() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let (actions, notices) = try await readPrompt(h)
        h.keys("3")
        try await h.waitFor { h.agent["mode"] as? String == "idle" && h.agent["reply"] as? String == "Denied." }
        try await h.paneShows { !$0.contains("Do you want to proceed?") }
        var typed: [Data] = []
        h.host.inputGate = { _, bytes in typed.append(bytes); return false }
        let failure = try await act(actions, PromptActions.denyAction, h)
        #expect(failure == .gone)
        #expect(typed.isEmpty, "keys went in: \(typed)")
        #expect(notices.said.map(\.body) == [PromptAnswer.Failure.gone.text], "\(notices.said)")
        #expect(notices.said.first?.title == "Not denied")
        #expect(h.agent["input"] as? String == "" && h.agent["enters"] as? Int == 0, "\(h.agent)")
    }

    /// The session host didn't take the keys: said, not only logged, and the prompt still waits.
    @Test func aHostWriteThatFailsIsSaid() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let (actions, notices) = try await readPrompt(h)
        var sent = 0
        actions.answerer.send = { _, _, _, confirmed in sent += 1; confirmed(false) }
        let failure = try await act(actions, PromptActions.allowAction, h)
        #expect(failure == .hostFailed && sent == 1)
        #expect(notices.said.map(\.body) == [PromptAnswer.Failure.hostFailed.text], "\(notices.said)")
        #expect(h.agent["mode"] as? String == "permission")
    }

    /// The card's own keys (`ChatSync.write`) the host didn't confirm: the card says so (it only logged a breadcrumb).
    @Test func theCardSaysWhenTheHostDidntTakeItsKeys() async throws {
        let socket = try temp.shortFolder("vsh-dead") + "/none.sock"
        let dead = HostClient(socketPath: socket, appKey: { SymmetricKey(size: .bits256) })
        let chat = ChatModel(outbox: ComposerOutbox(url: temp.url("outbox.json")), home: temp.url("home").path, steerRoot: temp.url("steer"))
        let sync = ChatSync(chat: chat, host: dead)
        sync.write([HostInput.Write(bytes: [13], delay: 0)], to: UUID())
        #expect(await until(timeout: 30) { chat.answerNotice != nil })
        #expect(chat.answerNotice == ChatSync.keysLost)
    }

    // MARK: No actions for anything else

    /// A question (AskUserQuestion) on screen isn't a permission prompt: its banner gets no Allow and Deny.
    @Test func aQuestionsBannerGetsNoActions() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "ask", "questions": [ChatSyncTests.fruit]])
        try await h.paneShows { $0.contains("Which fruit?") }
        let actions = PromptActions(answerer: PromptAnswer(host: h.host))
        actions.answerer.lookEvery = 0.05
        var ready: Bool?
        actions.prepare(tty: h.session.tty, id: h.session.id) { ready = $0 }
        try await h.waitFor { ready != nil }
        #expect(ready == false)
        #expect(actions.prompts.isEmpty)
        // Its Allow, were it clicked, answers nothing.
        var outcome: PromptAnswer.Failure??
        actions.handle(PromptActions.allowAction, tty: h.session.tty) { outcome = .some($0) }
        #expect(outcome == .some(.unknown))
    }

    @Test func onlyAPermissionPromptsAlertAsksForActions() throws {
        func session(_ status: SessionStatus, event: String?, detail: String?) -> Session {
            var session = Session(tty: "ttys901", agent: .claude, pid: 1, startedAt: Date(), cwd: "/r", project: "r", task: nil, status: status,
                                  statusSince: Date(), detail: detail, hasHooks: true, inTerminalApp: false)
            session.hookEvent = event
            return session
        }
        #expect(PromptActions.asksPermission(session(.needsInput, event: "PermissionRequest", detail: "Allow: Read x.png")))
        #expect(PromptActions.asksPermission(session(.needsInput, event: "Notification", detail: "Claude needs your permission to use Read")))
        #expect(PromptActions.asksPermission(session(.needsInput, event: "Notification", detail: "Run: swift build")))
        #expect(!PromptActions.asksPermission(session(.needsInput, event: "PreToolUse", detail: "Which fruit?")))
        #expect(!PromptActions.asksPermission(session(.needsInput, event: "PreToolUse", detail: "Plan ready: Ship it")))
        #expect(!PromptActions.asksPermission(session(.done, event: "Stop", detail: "Run: swift build")))
        #expect(!PromptActions.asksPermission(session(.working, event: "PermissionRequest", detail: nil)))

        // The banner's content: the permission prompt's with the category, a turn's end without it.
        let settings = AlertRules.Settings()
        let alert = try #require(AlertRules.attention(session(.needsInput, event: "PermissionRequest", detail: "Allow: Read x.png"),
                                                      question: nil, settings: settings))
        #expect(Notifier.content(for: alert, actions: true).categoryIdentifier == PromptActions.category)
        #expect(Notifier.content(for: alert, actions: false).categoryIdentifier.isEmpty)
        let done = try #require(AlertRules.attention(session(.done, event: "Stop", detail: nil), question: nil, settings: settings))
        #expect(done.kind == .done && Notifier.content(for: done, actions: false).categoryIdentifier.isEmpty)
        #expect(Notifier.content(for: alert, actions: true).userInfo["tty"] as? String == "ttys901")
        // The category: Allow and Deny, neither bringing the app forward.
        let category = PromptActions.notificationCategory
        #expect(category.identifier == PromptActions.category)
        #expect(category.actions.map(\.title) == ["Allow", "Deny"])
        #expect(category.actions.allSatisfy { !$0.options.contains(.foreground) && $0.options.contains(.authenticationRequired) })
        #expect(PromptActions.choice(for: PromptActions.allowAction) == .allow && PromptActions.choice(for: PromptActions.denyAction) == .deny)
        #expect(PromptActions.choice(for: UNNotificationDefaultActionIdentifier) == nil)
    }

    @Test func thePermissionPromptIsReadOffTheScreenAndNothingElseIs() {
        let read = ["⏺ Read(/a/b.png)", "╭" + String(repeating: "─", count: 58) + "╮", "│ Read file", "│", "│   Read(/a/b.png)", "│",
                    "│ Do you want to proceed?", "│ ❯ 1. Yes", "│   2. Yes, allow reading from a/ during this session", "│   3. No",
                    "╰" + String(repeating: "─", count: 58) + "╯", "Esc to cancel · Tab to amend"].joined(separator: "\n")
        let menu = PromptAnswer.permissionMenu(read)
        #expect(menu?.options.count == 3, "\(String(describing: menu))")
        #expect(menu.flatMap { PromptAnswer.row(.allow, in: $0) } == 0 && menu.flatMap { PromptAnswer.row(.deny, in: $0) } == 2)
        let older = read.replacingOccurrences(of: "3. No", with: "3. No, and tell Claude what to do differently (esc)")
        #expect(PromptAnswer.permissionMenu(older).flatMap { PromptAnswer.row(.deny, in: $0) } == 2)
        let model = ["Select model", "Switch between Claude models.", "", "❯ 1. Default (recommended)", "  2. Opus", "", "Enter to confirm · Esc to cancel"]
        #expect(PromptAnswer.permissionMenu(model.joined(separator: "\n")) == nil)
        #expect(PromptAnswer.permissionMenu("> hello\n? for shortcuts") == nil)
        #expect(PromptAnswer.permissionMenu(nil) == nil)
    }
}

/// The notices `PromptActions` said.
@MainActor
final class Notices {
    var said: [(tty: String, title: String, body: String)] = []
}
