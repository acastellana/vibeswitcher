import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Dictation in a Claude Code session through Claude's own /voice (no OpenAI key): the route by the session's agent,
/// Space as key repeats while held (hold mode, after its warmup), the transcript Claude writes into its prompt box moved
/// into the composer and the box cleared with ⌃U, never an Enter; off, tap mode, no claude.ai sign-in and a box with
/// someone else's text each said plainly and left alone; Esc cancels. The flows run against `FakeClaude`'s /voice
/// model on a scratch pty through a scratch host (`Harness`), never a real Claude, the microphone or the network.
@MainActor
@Suite(.serialized)
struct ClaudeDictationTests {
    let temp = Scratch()

    nonisolated static let rule = String(repeating: "─", count: 60)

    /// A Claude Code screen: its prompt box holding `input`, `footer` under it.
    nonisolated static func screen(input: String = "", footer: String = "? for shortcuts", above: String = "⏺ Ready.") -> LeadDelivery.Screen {
        LeadDelivery.Screen(text: [above, "", rule, "❯ " + input, rule, "  " + footer].joined(separator: "\n"), runs: [])
    }

    /// A session whose screen the test sets, and whose keys and commands it keeps.
    @MainActor final class ScriptedSession {
        var keys: [[UInt8]] = []
        var commands: [String] = []
        /// The screen after each key (by how many went in), else `screen`.
        var screen = ClaudeDictationTests.screen()
        var after: (Int) -> LeadDelivery.Screen? = { _ in nil }

        var session: ClaudeVoiceSession {
            ClaudeVoiceSession(keys: { [self] in keys.append($0); return true },
                               screen: { [self] done in
                                   let shown = after(keys.count) ?? screen
                                   DispatchQueue.main.async { done(shown) }
                               },
                               command: { [self] in commands.append($0); return true })
        }
    }

    func controller(key: String? = nil, session: @escaping (String) -> ClaudeVoiceSession?,
                    settings: ClaudeVoiceSettings = ClaudeVoiceSettings()) -> (DictationController, DictationTests.FakeHTTP) {
        let http = DictationTests.FakeHTTP()
        var transcription = OpenAITranscription(client: http)
        transcription.boundary = { "BOUNDARY" }
        let defaults = temp.defaults("claude-dictation")
        defaults.set(true, forKey: DictationController.privacyNotedKey)
        let controller = DictationController(keyStore: AppProof.MemorySecret(key), recorder: DictationTests.FakeRecorder(),
                                             transcription: transcription, defaults: defaults, findKey: { nil }, background: { $0() })
        controller.claudeSession = session
        controller.claudeSettings = { settings }
        return (controller, http)
    }

    // MARK: - Routing

    @Test func aClaudeSessionDictatesThroughClaudeAndOthersThroughOpenAI() async {
        let scripted = ScriptedSession()
        let (controller, http) = controller(session: { $0 == "claude-row" ? scripted.session : nil })
        controller.checkKey()
        #expect(await until { controller.keyState == .missing })

        // Claude Code, with no OpenAI key: no key is asked for, and the keys go to the session.
        #expect(controller.usesClaude("claude-row", agent: .claude))
        controller.press("claude-row", agent: .claude) { "" }
        #expect(controller.claudeRow == "claude-row" && controller.isRecording("claude-row"))
        #expect(controller.notice == nil)
        #expect(await until { scripted.keys.first == [ClaudeVoiceRun.space] })
        controller.cancel()
        #expect(await until { controller.phase == .idle })
        #expect(http.requests.isEmpty)
        #expect(controller.notice == nil, "\(String(describing: controller.notice))")

        // Codex, or a Claude session the window can't type into (a Terminal tab): OpenAI's, which needs the key.
        #expect(!controller.usesClaude("codex-row", agent: .codex))
        controller.press("codex-row", agent: .codex) { "" }
        #expect(controller.notice?.settings == true && controller.notice?.rowID == "codex-row")
        #expect(!controller.usesClaude("terminal-row", agent: .claude))
        controller.press("terminal-row", agent: .claude) { "" }
        #expect(controller.notice?.settings == true && controller.notice?.rowID == "terminal-row")
        // Even a Claude row whose session can be typed into, when its agent isn't Claude Code.
        #expect(!controller.usesClaude("claude-row", agent: .codex))
        #expect(scripted.keys.filter { $0 == [ClaudeVoiceRun.space] }.count == 1)
    }

    @Test func claudesSettingsForTapModeOrAutoSubmitAreReadNeverWrittenAndStopIt() async {
        #expect(ClaudeVoiceSettings.parse(Data(#"{"voice":{"enabled":true,"mode":"tap"}}"#.utf8)) == ClaudeVoiceSettings(mode: "tap"))
        #expect(ClaudeVoiceSettings.parse(Data(#"{"voice":{"autoSubmit":true}}"#.utf8)).autoSubmit)
        #expect(ClaudeVoiceSettings.parse(Data("not json".utf8)) == ClaudeVoiceSettings())
        #expect(ClaudeVoiceSettings.parse(nil).refusal == nil)
        #expect(ClaudeVoiceSettings(mode: "hold").refusal == nil)
        #expect(ClaudeVoiceSettings(mode: "tap").refusal?.offer == true)
        #expect(ClaudeVoiceSettings(mode: "hold", autoSubmit: true).refusal?.offer == false)

        for settings in [ClaudeVoiceSettings(mode: "tap"), ClaudeVoiceSettings(autoSubmit: true)] {
            let scripted = ScriptedSession()
            let (controller, _) = controller(session: { _ in scripted.session }, settings: settings)
            controller.press("row", agent: .claude) { "" }
            #expect(await until { controller.phase == .idle })
            #expect(scripted.keys.isEmpty, "keys went in with \(settings)")
            #expect(controller.notice?.text == settings.refusal?.text)
            #expect(controller.notice?.turnOn == settings.refusal?.offer)
        }
    }

    // MARK: - The screen

    @Test func claudesFooterAndMessagesAreReadOffItsScreen() {
        #expect(ClaudeVoiceScreen.footer(Self.screen().text) == .none)
        #expect(ClaudeVoiceScreen.footer(Self.screen(footer: "keep holding…").text) == .warming)
        #expect(ClaudeVoiceScreen.footer(Self.screen(footer: "listening…").text) == .listening)
        #expect(ClaudeVoiceScreen.footer(Self.screen(footer: "● REC · tap to send").text) == .tap)
        // Above the box it's the conversation, not the footer.
        #expect(ClaudeVoiceScreen.footer(Self.screen(above: "⏺ I'm listening… to the logs").text) == .none)

        let before = ClaudeVoiceScreen.signals(Self.screen(above: "⏺ Unknown command: /voice").text)
        #expect(before == [.unknownCommand: 1])
        let after = ClaudeVoiceScreen.signals(Self.screen(above: "⏺ Unknown command: /voice\n⏺ Unknown command: /voice").text)
        #expect(ClaudeVoiceScreen.new(after, since: before) == [.unknownCommand])
        #expect(ClaudeVoiceScreen.new(before, since: before).isEmpty)
        #expect(ClaudeVoiceScreen.signals(Self.screen(footer: "Voice mode requires a Claude.ai account. Run /login.").text) == [.needsAccount: 1])
        #expect(ClaudeVoiceScreen.line("open the composer\nview on main") == "open the composer view on main")
    }

    // MARK: - Safety, on a scripted screen

    @Test func aBoxWithTextOrAQuestionGetsNoKeys() async {
        for (screen, word) in [(Self.screen(input: "half a thought"), "already has text"),
                               (LeadDelivery.Screen(text: "Do you want to proceed?\n❯ 1. Yes\n  2. No", runs: []), "asking")] {
            let scripted = ScriptedSession()
            scripted.screen = screen
            let (controller, _) = controller(session: { _ in scripted.session })
            controller.press("row", agent: .claude) { "" }
            #expect(await until { controller.phase == .idle })
            #expect(scripted.keys.isEmpty)
            #expect(controller.notice?.text.contains(word) == true, "\(String(describing: controller.notice))")
        }
    }

    /// Tap mode records on the first Space and sends on the next: on screen after the first, it's cancelled (Esc)
    /// before a second goes.
    @Test func tapModeOnScreenIsCancelledBeforeASecondSpace() async {
        let scripted = ScriptedSession()
        scripted.after = { count in count >= 1 ? ClaudeDictationTests.screen(footer: "● REC · tap to send") : nil }
        let (controller, _) = controller(session: { _ in scripted.session })
        controller.press("row", agent: .claude) { "" }
        #expect(await until { controller.phase == .idle })
        #expect(scripted.keys.filter { $0 == [ClaudeVoiceRun.space] }.count == 1, "\(scripted.keys)")
        #expect(scripted.keys.contains([ClaudeVoiceRun.escape]))
        #expect(!scripted.keys.contains([0x0d]) && !scripted.keys.contains([0x0a]))
        #expect(controller.notice?.text == ClaudeVoiceRun.tapMode && controller.notice?.turnOn == true)
    }

    // MARK: - Against FakeClaude's /voice

    /// The harness's session, as the window gives it to dictation.
    func dictation(_ h: Harness) -> DictationController {
        controller(session: { [weak h] key in h?.sync.claudeVoice(key: key) }).0
    }

    var input: (Harness) -> String { { $0.agent["input"] as? String ?? "?" } }

    @Test func heldTheTranscriptLandsInTheComposerAndClaudesBoxIsCleared() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "hold", "gap": 1.5])
        try await h.waitFor { h.agent["voice"] as? String == "hold" }
        let prompts = h.agentPrompts
        let controller = dictation(h)

        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        #expect(h.agent["recording"] as? String == "listening")
        // The warmup's spaces are gone: what it hears is dim, not typed.
        #expect(input(h) == "")
        controller.release()
        try await h.waitFor { controller.phase == .idle }

        #expect(controller.deliveries[h.key]?.text == "open the composer view on main", "\(String(describing: controller.notice))")
        #expect(controller.notice == nil)
        #expect(input(h) == "")
        #expect(h.agent["voiceInserts"] as? Int == 1)
        #expect((h.agent["killed"] as? Int ?? 0) >= 1)
        #expect(h.agent["enters"] as? Int == 0)
        #expect(h.agentPrompts == prompts)

        // Again: another recording, added after the first in the composer.
        h.tell(["op": "voice", "transcript": "and run the tests"])
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        controller.release()
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.deliveries[h.key]?.text == "open the composer view on main and run the tests")
        #expect(h.agent["enters"] as? Int == 0)
    }

    @Test func escCancelsTheRecordingAndNothingLands() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "hold", "gap": 1.5])
        try await h.waitFor { h.agent["voice"] as? String == "hold" }
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        controller.cancel()
        try await h.waitFor { controller.phase == .idle }
        try await h.waitFor { h.agent["voiceCancels"] as? Int == 1 }
        #expect(controller.deliveries[h.key] == nil)
        #expect(controller.notice == nil)
        #expect(h.agent["voiceInserts"] as? Int == 0)
        #expect(input(h) == "")
        #expect(h.agent["enters"] as? Int == 0)
    }

    @Test func offItsSaidAndTurningItOnTypesVoiceHoldAfterTheClick() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        // Its spaces typed in, as a terminal with /voice off takes them.
        try await h.waitFor { self.input(h).count >= 3 }
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.notice?.text == ClaudeVoiceRun.didntStart && controller.notice?.turnOn == true)
        // The spaces are gone, and nothing was sent or typed but them.
        try await h.waitFor { self.input(h) == "" }
        #expect(h.agent["enters"] as? Int == 0)
        #expect(h.agent["voice"] as? String == "off")

        controller.turnOnClaude(h.key)
        try await h.waitFor { controller.turningOn == nil }
        #expect(h.agent["voice"] as? String == "hold")
        #expect(controller.notice?.info == true && controller.notice?.text.contains("is on") == true, "\(String(describing: controller.notice))")

        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        controller.release()
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.deliveries[h.key]?.text == "open the composer view on main")
    }

    @Test func withoutAClaudeAiSignInItSaysSo() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        // Signed in, but the sign-in can't be used for dictation: Claude says so as it would start recording.
        h.tell(["op": "voice", "mode": "hold", "account": "expired"])
        try await h.waitFor { h.agent["voiceAccount"] as? String == "expired" }
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.notice?.text == ClaudeVoiceScreen.Signal.needsAccount.notice, "\(String(describing: controller.notice))")
        #expect(controller.notice?.turnOn == false)
        try await h.waitFor { self.input(h) == "" }

        // No claude.ai sign-in at all: Claude has no /voice, and turning it on says so.
        h.tell(["op": "voice", "mode": "off", "account": "none"])
        try await h.waitFor { h.agent["voiceAccount"] as? String == "none" }
        controller.turnOnClaude(h.key)
        try await h.waitFor { controller.turningOn == nil }
        #expect(controller.notice?.text == ClaudeVoiceScreen.Signal.unknownCommand.notice, "\(String(describing: controller.notice))")
        #expect(h.agent["voice"] as? String == "off")
    }

    @Test func somethingTypedInTheTerminalMeanwhileIsLeftAlone() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        // It never starts listening: the spaces go in, and then a word someone types.
        h.tell(["op": "voice", "mode": "hold", "warmup": 100000])
        try await h.waitFor { h.agent["warmup"] as? Int == 100000 }
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { self.input(h).count >= 3 }
        h.keys("x")
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.notice?.text.contains("typed in the terminal") == true, "\(String(describing: controller.notice))")
        #expect(input(h).contains("x"))
        #expect(h.agent["killed"] as? Int == 0)
        #expect(controller.deliveries[h.key] == nil)

        // A box that already holds text: no key goes in at all.
        let before = input(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.notice?.text.contains("already has text") == true)
        #expect(input(h) == before)
    }

    @Test func tapModeInTheSessionIsCancelledAndNothingIsSent() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "tap"])
        try await h.waitFor { h.agent["voice"] as? String == "tap" }
        let prompts = h.agentPrompts
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.notice?.text == ClaudeVoiceRun.tapMode && controller.notice?.turnOn == true)
        try await h.waitFor { h.agent["voiceCancels"] as? Int == 1 }
        #expect(h.agentPrompts == prompts)
        #expect(h.agent["voiceInserts"] as? Int == 0)
        #expect(input(h) == "")
        #expect(h.agent["enters"] as? Int == 0)
    }
}
