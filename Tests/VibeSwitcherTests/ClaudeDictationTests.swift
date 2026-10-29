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
                    settings: ClaudeVoiceSettings = ClaudeVoiceSettings(),
                    microphone: DictationTests.FakeMicrophone = DictationTests.FakeMicrophone()) -> (DictationController, DictationTests.FakeHTTP) {
        let http = DictationTests.FakeHTTP()
        var transcription = OpenAITranscription(client: http)
        transcription.boundary = { "BOUNDARY" }
        let defaults = temp.defaults("claude-dictation")
        defaults.set(true, forKey: DictationController.privacyNotedKey)
        let controller = DictationController(keyStore: AppProof.MemorySecret(key), recorder: DictationTests.FakeRecorder(), microphone: microphone,
                                             transcription: transcription, defaults: defaults, findKey: { nil }, background: { $0() })
        controller.claudeSession = session
        controller.claudeSettings = { _ in settings }
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
        let keys = scripted.keys.count

        // Codex, or a Claude session the window can't type into (a Terminal tab): OpenAI's, which needs the key.
        #expect(!controller.usesClaude("codex-row", agent: .codex))
        controller.press("codex-row", agent: .codex) { "" }
        #expect(controller.notice?.settings == true && controller.notice?.rowID == "codex-row")
        #expect(!controller.usesClaude("terminal-row", agent: .claude))
        controller.press("terminal-row", agent: .claude) { "" }
        #expect(controller.notice?.settings == true && controller.notice?.rowID == "terminal-row")
        // Even a Claude row whose session can be typed into, when its agent isn't Claude Code.
        #expect(!controller.usesClaude("claude-row", agent: .codex))
        // None of those reached the Claude session.
        #expect(scripted.keys.count == keys)
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

    /// Claude reads its settings from its config folder, the project's two and the Mac's managed ones, each over the one
    /// before: an autoSubmit anywhere that isn't turned off again above it stops dictation.
    @Test func claudesSettingsAreReadFromEveryPlaceItReadsThem() {
        #expect(ClaudeVoiceSettings.files(folder: "/p", environment: ["CLAUDE_CONFIG_DIR": "/c"])
                == ["/c/settings.json", "/p/.claude/settings.json", "/p/.claude/settings.local.json",
                    "/Library/Application Support/ClaudeCode/managed-settings.json"])
        #expect(ClaudeVoiceSettings.files(folder: nil, environment: [:]).first == NSHomeDirectory() + "/.claude/settings.json")
        let on = Data(#"{"voice":{"autoSubmit":true}}"#.utf8), off = Data(#"{"voice":{"autoSubmit":false}}"#.utf8)
        let tap = Data(#"{"voice":{"mode":"tap"}}"#.utf8)
        #expect(ClaudeVoiceSettings.merged([nil, nil, on, nil]).autoSubmit)
        #expect(!ClaudeVoiceSettings.merged([on, off, nil, nil]).autoSubmit)
        #expect(ClaudeVoiceSettings.merged([Data(#"{"voice":{"mode":"hold"}}"#.utf8), nil, nil, tap]).mode == "tap")
    }

    /// Claude's dictation key, from its keybindings (read, never written): Space unless rebound; rebound or unbound,
    /// VibeSwitcher says so and sends nothing.
    @Test func aDictationKeyReboundAwayFromSpaceIsSaidAndNothingIsSent() async {
        #expect(ClaudeVoiceSettings.keybindings(environment: ["CLAUDE_CONFIG_DIR": "/c"]) == "/c/keybindings.json")
        #expect(ClaudeVoiceSettings.pushToTalk(nil) == "space")
        #expect(ClaudeVoiceSettings.pushToTalk(Data(#"{"bindings":[{"context":"Chat","bindings":{"ctrl+s":"chat:stash"}}]}"#.utf8)) == "space")
        let rebound = Data(#"{"bindings":[{"context":"Chat","bindings":{"meta+k":"voice:pushToTalk","space":null}}]}"#.utf8)
        #expect(ClaudeVoiceSettings.pushToTalk(rebound) == "meta+k")
        #expect(ClaudeVoiceSettings.pushToTalk(Data(#"{"bindings":[{"context":"Chat","bindings":{"space":null}}]}"#.utf8)) == nil)
        // Another context's binding isn't the composer's.
        #expect(ClaudeVoiceSettings.pushToTalk(Data(#"{"bindings":[{"context":"Global","bindings":{"meta+k":"voice:pushToTalk"}}]}"#.utf8)) == "space")

        for key in ["meta+k", nil] as [String?] {
            let scripted = ScriptedSession()
            let (controller, _) = controller(session: { _ in scripted.session }, settings: ClaudeVoiceSettings(pushToTalk: key))
            controller.press("row", agent: .claude) { "" }
            #expect(await until { controller.phase == .idle })
            #expect(scripted.keys.isEmpty)
            #expect(controller.notice?.text.contains(key ?? "unbound") == true, "\(String(describing: controller.notice))")
        }
    }

    @Test func onlyTextThatGrewOutOfWhatClaudeHeardIsTaken() {
        #expect(ClaudeVoiceScreen.grew("Open the composer view", from: "open the"))
        #expect(ClaudeVoiceScreen.grew("So, open the composer", from: "open"))
        #expect(!ClaudeVoiceScreen.grew("x", from: "open the"))
        #expect(!ClaudeVoiceScreen.grew("something else entirely", from: "open the"))
        // Only the first word revised once final.
        #expect(ClaudeVoiceScreen.grew("Often the composer", from: "open the"))
        // Claude's recording-level cursor isn't typed, and isn't part of the text.
        #expect(ClaudeVoiceScreen.meterOnly("▃") && ClaudeVoiceScreen.meterOnly(" ▇ ") && !ClaudeVoiceScreen.meterOnly("x▃"))
        #expect(ClaudeVoiceScreen.line("open the composer ▃") == "open the composer")
        #expect(ClaudeVoiceScreen.grew("anything", from: ""))
        let screen = LeadDelivery.Screen(text: [Self.rule, "❯ typed heard", Self.rule].joined(separator: "\n"),
                                         runs: [ScreenRun(row: 1, column: 8, length: 5, faint: true)])
        #expect(LeadDelivery.dimText(in: screen) == "heard")
        #expect(LeadDelivery.box(in: screen) == .draft("typed"))
    }

    // MARK: - The microphone

    /// Denied (or restricted), either kind of dictation says so with a way to System Settings, and records nothing:
    /// macOS asks about VibeSwitcher for a session's Claude too.
    @Test func aDeniedMicrophoneIsSaidForBothKindsAndNothingRecords() async {
        let scripted = ScriptedSession()
        let recorder = DictationTests.FakeRecorder()
        let microphone = DictationTests.FakeMicrophone(.denied)
        let (controller, _) = controller(key: DictationTests.key, session: { $0 == "claude" ? scripted.session : nil }, microphone: microphone)
        for (row, agent) in [("claude", Agent.claude), ("codex", Agent.codex)] {
            controller.press(row, agent: agent) { "" }
            #expect(controller.phase == .idle)
            #expect(controller.notice == DictationController.Notice(rowID: row, text: DictationController.microphoneNotice, privacy: true))
        }
        #expect(await until { controller.phase == .idle })
        #expect(scripted.keys.isEmpty && recorder.starts == 0)
        #expect(microphone.requests == 0)
    }

    /// Never asked: the first press asks macOS, once; allowed while still held, the dictation goes on. Refused, it's
    /// said, and later presses don't ask again.
    @Test func theFirstPressAsksForTheMicrophoneOnce() async {
        let scripted = ScriptedSession()
        let microphone = DictationTests.FakeMicrophone(.undetermined)
        let (first, _) = controller(session: { _ in scripted.session }, microphone: microphone)
        first.press("row", agent: .claude) { "" }
        #expect(microphone.requests == 1 && scripted.keys.isEmpty)
        #expect(await until { scripted.keys.first == [ClaudeVoiceRun.space] })
        first.cancel()
        #expect(await until { first.phase == .idle })
        first.press("row", agent: .claude) { "" }
        #expect(microphone.requests == 1)
        first.cancel()
        #expect(await until { first.phase == .idle })

        let refused = DictationTests.FakeMicrophone(.undetermined)
        refused.grants = false
        let other = ScriptedSession()
        let (second, _) = controller(session: { _ in other.session }, microphone: refused)
        second.press("row", agent: .claude) { "" }
        #expect(await until { second.notice?.privacy == true })
        second.press("row", agent: .claude) { "" }
        #expect(refused.requests == 1 && other.keys.isEmpty)
        #expect(second.notice?.text == DictationController.microphoneNotice)
    }

    /// Claude's own words about the microphone get the same notice.
    @Test func claudesMicrophoneMessagesGetTheSameNotice() async {
        for message in ["Microphone access is denied. Grant it in System Settings.", "No audio detected from microphone"] {
            let scripted = ScriptedSession()
            scripted.after = { count in count >= 1 ? ClaudeDictationTests.screen(footer: message) : nil }
            let (controller, _) = controller(session: { _ in scripted.session })
            controller.press("row", agent: .claude) { "" }
            #expect(await until { controller.phase == .idle })
            #expect(controller.notice?.text == DictationController.microphoneNotice && controller.notice?.privacy == true,
                    "\(String(describing: controller.notice))")
        }
    }

    // MARK: - The screen

    @Test func claudesFooterAndMessagesAreReadOffItsScreen() {
        #expect(ClaudeVoiceScreen.footer(Self.screen().text) == .none)
        #expect(ClaudeVoiceScreen.footer(Self.screen(footer: "keep holding…").text) == .warming)
        #expect(ClaudeVoiceScreen.footer(Self.screen(footer: "listening…").text) == .listening)
        #expect(ClaudeVoiceScreen.footer(Self.screen(footer: "● REC · tap to send").text) == .tap)
        #expect(ClaudeVoiceScreen.footer(Self.screen(footer: "Voice: processing…").text) == .processing)
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

    /// What Claude draws in the prompt box itself (2.1.312), for when its footer isn't on screen (a custom status line
    /// in its place): its level cursor where the caret was, coloured or grey; the words heard, dim; the warmup's two
    /// typed spaces with its later repeats swallowed, against /voice off's spaces that all stay.
    @Test func claudesPromptBoxSaysWhatItsDictationDoesWithoutItsFooter() {
        let status = "[Opus 5.5] vibeswitcher | 9 hooks | ctx ███░░ 41%"
        // The box is row 3; its text starts at column 2, after "❯ ".
        let shot = { (input: String, runs: [ScreenRun]) in
            LeadDelivery.Screen(text: Self.screen(input: input, footer: status).text, runs: runs)
        }
        let bar = ScreenRun(row: 5, column: 43, length: 5, color: .rgb(0, 200, 0))

        // Recording: the level cursor, coloured or grey (below a low level), after the words heard so far.
        let coloured = shot("▃", [ScreenRun(row: 3, column: 2, length: 1, color: .rgb(215, 119, 87)), bar])
        #expect(ClaudeVoiceScreen.prompt(coloured) == .init(spaces: 0, meter: true, dim: ""))
        #expect(ClaudeVoiceScreen.seen(coloured, sent: 7) == .recording)
        let grey = shot("open the▁", [ScreenRun(row: 3, column: 2, length: 8, faint: true),
                                      ScreenRun(row: 3, column: 10, length: 1, color: .rgb(128, 128, 128)), bar])
        #expect(ClaudeVoiceScreen.prompt(grey) == .init(spaces: 0, meter: true, dim: "open the"))
        #expect(ClaudeVoiceScreen.seen(grey, sent: 7) == .recording)
        // A bar glyph typed, or in the status line under the box, isn't its level cursor.
        #expect(!ClaudeVoiceScreen.prompt(shot("▃", [bar])).meter)
        #expect(ClaudeVoiceScreen.seen(shot("", [bar]), sent: 1) == .nothing)

        // Words heard, dim, with no level cursor (a terminal out of focus draws none): heard, not more. The box's own
        // placeholder, dim before the first Space too, isn't.
        let heard = shot("open the", [ScreenRun(row: 3, column: 2, length: 8, faint: true)])
        #expect(ClaudeVoiceScreen.seen(heard, sent: 7) == .heard)
        #expect(ClaudeVoiceScreen.seen(heard, sent: 7, dimBefore: "open the") == .nothing)

        // Spaces before the caret: the warmup's two, with more Spaces sent than kept, against /voice off's.
        let caret = { (spaces: Int) in shot(String(repeating: " ", count: spaces + 1), [ScreenRun(row: 3, column: 2 + spaces, length: 1, inverse: true)]) }
        #expect(ClaudeVoiceScreen.prompt(caret(2)).spaces == 2)
        #expect(ClaudeVoiceScreen.seen(caret(2), sent: 5) == .warming)
        #expect(ClaudeVoiceScreen.seen(caret(2), sent: 2) == .typed)
        #expect(ClaudeVoiceScreen.seen(caret(6), sent: 7) == .typed)
        // No caret (an older host, or a terminal out of focus): the spaces the row kept.
        #expect(ClaudeVoiceScreen.prompt(shot("   ", [])).spaces == 3)
        // Anything else in the box: not spaces.
        #expect(ClaudeVoiceScreen.prompt(shot("  x", [])).spaces == nil)
        #expect(ClaudeVoiceScreen.seen(shot("", []), sent: 0) == .nothing)
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
        h.tell(["op": "voice", "mode": "hold"])
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
        #expect(h.agent["doubleSubmits"] as? Int == 0)
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
        h.tell(["op": "voice", "mode": "hold"])
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
        try await h.waitFor { self.input(h).count >= ClaudeVoiceScreen.warmupTyped }
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

    /// Typed in the terminal while Claude records, or after the release before its text lands: the box holds theirs and
    /// Claude's, and none of it is moved or cleared.
    @Test func typedInTheTerminalWhileClaudeRecordsNothingIsMovedOrCleared() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        // Slow to finish (as Claude writing a long transcript): "y" lands before it does.
        h.tell(["op": "voice", "mode": "hold", "gap": 1.5])
        try await h.waitFor { h.agent["voice"] as? String == "hold" }
        let controller = dictation(h)
        for (word, afterRelease) in [("x", false), ("y", true)] {
            let (before, killed) = (input(h), h.agent["killed"] as? Int)
            controller.press(h.key, agent: .claude) { "" }
            try await h.waitFor { controller.listening }
            if afterRelease { controller.release() }
            h.keys(word)
            try await h.waitFor { self.input(h).hasSuffix(word) }
            if !afterRelease { controller.release() }
            try await h.waitFor { controller.phase == .idle }
            #expect(controller.notice?.text == ClaudeVoiceRun.typedMeanwhile, "\(String(describing: controller.notice))")
            #expect(input(h) == before + word + "open the composer view on main")
            #expect(h.agent["killed"] as? Int == killed)
            #expect(controller.deliveries[h.key] == nil)
            #expect(h.agent["enters"] as? Int == 0)
            // The next one needs an empty box.
            h.keys("\u{15}")
            try await h.waitFor { self.input(h) == "" }
        }
    }

    /// The composer's message, typed in while a dictation goes in, would take it out with its Enter: it waits in the box.
    @Test func nothingElseIsTypedIntoTheSessionWhileADictationGoesIn() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "hold"])
        try await h.waitFor { h.agent["voice"] as? String == "hold" }
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        #expect(ClaudeVoiceRun.busy.contains(h.session.id))
        #expect(!h.sync.type("also check the tests"))
        #expect(h.chat.sendNotice == ChatSync.dictating)
        controller.release()
        try await h.waitFor { controller.phase == .idle }
        #expect(!ClaudeVoiceRun.busy.contains(h.session.id))
        #expect(controller.deliveries[h.key]?.text == "open the composer view on main")
        #expect(h.agent["enters"] as? Int == 0)
        #expect(input(h) == "")
        // Once it's in the composer, a message goes as usual.
        #expect(h.sync.type("also check the tests"))
        try await h.waitFor { h.agentPrompts.last == "also check the tests" }
    }

    /// Claude stops listening by itself (silence, its limit, or repeats that stalled past its 120 ms) while the mic is
    /// still held: no Space goes after, so no second push sends the transcript; it lands in the composer.
    @Test func claudeStoppingByItselfWhileHeldSendsNothing() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "hold"])
        try await h.waitFor { h.agent["voice"] as? String == "hold" }
        let prompts = h.agentPrompts
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        h.tell(["op": "voiceStop"])
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.deliveries[h.key]?.text == "open the composer view on main", "\(String(describing: controller.notice))")
        #expect(h.agent["doubleSubmits"] as? Int == 0)
        #expect(h.agent["voiceStarts"] as? Int == 1)
        #expect(h.agentPrompts == prompts)
        #expect(input(h) == "")
        controller.release()
        #expect(controller.phase == .idle)
    }

    /// What Claude showed while listening was revised once final (its first word): still the dictation, taken.
    @Test func aTranscriptWhoseFirstWordWasRevisedIsTaken() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "hold", "interim": "often the composer"])
        try await h.waitFor { h.agent["interim"] as? String == "often the composer" }
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        controller.release()
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.deliveries[h.key]?.text == "open the composer view on main", "\(String(describing: controller.notice))")
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

    // MARK: - A custom status line (no voice footer)

    /// Claude Code with a custom status line, as the user's (claude-hud): its footer never says `keep holding…` or
    /// `listening…`. The level cursor in the box says it records: the whole hold, release and take, and again with it
    /// grey (nothing heard yet) and Claude stopping by itself while held, which sends nothing.
    @Test func withACustomStatusLineTheDictationIsReadOffThePromptBox() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "hold", "statusLine": true])
        try await h.waitFor { h.agent["statusLine"] as? Bool == true }
        let prompts = h.agentPrompts
        let controller = dictation(h)

        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        #expect(h.agent["recording"] as? String == "listening")
        #expect(input(h) == "")
        controller.release()
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.deliveries[h.key]?.text == "open the composer view on main", "\(String(describing: controller.notice))")
        #expect(controller.notice == nil)
        #expect(input(h) == "")
        #expect(h.agent["voiceInserts"] as? Int == 1)

        h.tell(["op": "voice", "interim": "", "transcript": "and run the tests"])
        try await h.waitFor { h.agent["interim"] as? String == "" }
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        h.tell(["op": "voiceStop"])
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.deliveries[h.key]?.text == "open the composer view on main and run the tests", "\(String(describing: controller.notice))")
        controller.release()
        #expect(input(h) == "")
        #expect(h.agent["voiceStarts"] as? Int == 2)
        #expect(h.agent["enters"] as? Int == 0)
        #expect(h.agent["doubleSubmits"] as? Int == 0)
        #expect(h.agentPrompts == prompts)
    }

    /// /voice off with no footer: every Space stays typed, so it's said to be off (with the offer to turn it on), and
    /// the spaces go.
    @Test func withACustomStatusLineOffIsTheSpacesItKeeps() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "off", "statusLine": true])
        try await h.waitFor { h.agent["statusLine"] as? Bool == true }
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { self.input(h).count > ClaudeVoiceScreen.warmupTyped }
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.notice?.text == ClaudeVoiceRun.didntStart && controller.notice?.turnOn == true, "\(String(describing: controller.notice))")
        try await h.waitFor { self.input(h) == "" }
        #expect(h.agent["enters"] as? Int == 0)
    }

    /// Warming up but never recording, with no footer: neither off nor on, so no offer to turn it on; the notice says
    /// what was seen last, by name, so do the breadcrumbs (never the screen's text), and the warmup's spaces go.
    @Test func withACustomStatusLineAWarmupThatNeverRecordsIsSaidByWhatWasSeen() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "hold", "statusLine": true, "warmup": 100000])
        try await h.waitFor { h.agent["warmup"] as? Int == 100000 }
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { self.input(h).count == ClaudeVoiceScreen.warmupTyped }
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.notice?.text == ClaudeVoiceRun.unclear(.warming) && controller.notice?.turnOn == false,
                "\(String(describing: controller.notice))")
        try await h.waitFor { self.input(h) == "" }
        #expect(h.agent["voiceStarts"] as? Int == 0)
        #expect(h.agent["enters"] as? Int == 0)
        let crumb = try #require(Breadcrumbs.shared.lines.last { $0.contains("dictation: Claude's didn't start") })
        #expect(crumb.contains("unclear") && crumb.hasSuffix("Spaces") && crumb.contains("warming up"), "\(crumb)")
        #expect(!crumb.contains("Opus") && !crumb.contains("hooks"))
        controller.release()
    }

    // MARK: - Focus

    /// A session with a custom status line whose terminal is out of focus (the composer has the keyboard: the pane told
    /// it so with CSI O), its program asking for focus events: Claude draws no caret and no level cursor then.
    func outOfFocus(_ h: Harness, _ more: [String: Any] = [:]) async throws {
        h.tell(["op": "voice", "mode": "hold", "statusLine": true, "focusEvents": true].merging(more) { $1 })
        // Drawn after it asked: the pane read the request (and answered it, focused, as SwiftTerm does) before this.
        try await h.paneShows { $0.contains("9 hooks") }
        h.keys("\u{1b}[O")
        try await h.waitFor { h.agent["focused"] as? Bool == false }
    }

    var focusOuts: (Harness) -> Int { { $0.agent["focusOuts"] as? Int ?? -1 } }

    /// Told it has focus while it dictates, it draws its level cursor and the dictation lands; told the real focus after
    /// (out, the pane not having it). With the pane having the keyboard, nothing is said after.
    @Test func outOfFocusItsToldItHasFocusWhileItDictatesAndTheTruthAfterATake() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        try await outOfFocus(h)
        let (ins, outs) = (h.agent["focusIns"] as? Int ?? -1, focusOuts(h))
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        #expect(h.agent["focused"] as? Bool == true)
        controller.release()
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.deliveries[h.key]?.text == "open the composer view on main", "\(String(describing: controller.notice))")
        try await h.waitFor { self.focusOuts(h) == outs + 1 }
        #expect(h.agent["focused"] as? Bool == false)
        #expect(h.agent["focusIns"] as? Int == ins + 1)
        #expect(input(h) == "" && h.agent["enters"] as? Int == 0)

        // The pane has the keyboard: it's focused, and stays so.
        h.sync.paneFocused = { _ in true }
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        controller.release()
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.deliveries[h.key]?.text == "open the composer view on main open the composer view on main")
        #expect(h.agent["focused"] as? Bool == true)
        #expect(focusOuts(h) == outs + 1)
    }

    @Test func outOfFocusItsToldTheTruthAfterACancel() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        try await outOfFocus(h)
        let outs = focusOuts(h)
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        controller.cancel()
        try await h.waitFor { controller.phase == .idle }
        try await h.waitFor { self.focusOuts(h) == outs + 1 }
        #expect(h.agent["focused"] as? Bool == false)
        #expect(h.agent["voiceCancels"] as? Int == 1 && controller.deliveries[h.key] == nil)
    }

    @Test func outOfFocusItsToldTheTruthAfterAWarmupThatNeverRecords() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        try await outOfFocus(h, ["warmup": 100000])
        let outs = focusOuts(h)
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.notice?.text == ClaudeVoiceRun.unclear(.warming), "\(String(describing: controller.notice))")
        try await h.waitFor { self.focusOuts(h) == outs + 1 }
        #expect(h.agent["focused"] as? Bool == false)
        try await h.waitFor { self.input(h) == "" }
        controller.release()
    }

    @Test func outOfFocusItsToldTheTruthAfterClaudeRefuses() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        try await outOfFocus(h, ["account": "expired"])
        let outs = focusOuts(h)
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.notice?.text == ClaudeVoiceScreen.Signal.needsAccount.notice, "\(String(describing: controller.notice))")
        try await h.waitFor { self.focusOuts(h) == outs + 1 }
        #expect(h.agent["focused"] as? Bool == false)
    }

    /// A program that didn't ask for focus events gets no focus report (it would take it as Esc and typed text), so out
    /// of focus it draws no level cursor: the words heard, dim, are all that says it records, and they stay dim while it
    /// processes. The run stops holding at them: what was heard lands, and nothing is sent.
    @Test func withoutFocusEventsNoReportGoesAndADimOnlyRecordingStopsWithoutSending() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "hold", "statusLine": true, "focused": false])
        try await h.waitFor { h.agent["focused"] as? Bool == false }
        let prompts = h.agentPrompts
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.deliveries[h.key]?.text == "open the composer view on main", "\(String(describing: controller.notice))")
        #expect(h.agent["voiceInserts"] as? Int == 1)
        #expect(h.agent["focusIns"] as? Int == 0)
        #expect(input(h) == "")
        #expect(h.agent["enters"] as? Int == 0 && h.agent["doubleSubmits"] as? Int == 0)
        #expect(h.agentPrompts == prompts)
        controller.release()
    }
}
