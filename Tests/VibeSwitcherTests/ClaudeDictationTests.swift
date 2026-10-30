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
                    microphone: DictationTests.FakeMicrophone = DictationTests.FakeMicrophone(),
                    now: @escaping () -> Date = Date.init) -> (DictationController, DictationTests.FakeHTTP) {
        let http = DictationTests.FakeHTTP()
        var transcription = OpenAITranscription(client: http)
        transcription.boundary = { "BOUNDARY" }
        let defaults = temp.defaults("claude-dictation")
        defaults.set(true, forKey: DictationController.privacyNotedKey)
        let controller = DictationController(keyStore: AppProof.MemorySecret(key), recorder: DictationTests.FakeRecorder(), microphone: microphone,
                                             transcription: transcription, defaults: defaults, findKey: { nil }, background: { $0() },
                                             now: now)
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
        // Grey is a low level: quiet (a whole recording of it, and no text, is a microphone that gave silence).
        #expect(ClaudeVoiceScreen.prompt(grey) == .init(spaces: 0, meter: true, quiet: true, dim: "open the"))
        #expect(ClaudeVoiceScreen.seen(grey, sent: 7) == .recording)
        // A bar glyph typed, or in the status line under the box, isn't its level cursor.
        #expect(!ClaudeVoiceScreen.prompt(shot("▃", [bar])).meter)
        #expect(ClaudeVoiceScreen.seen(shot("", [bar]), sent: 1) == .nothing)

        // Words heard, dim, with no level cursor (a terminal out of focus draws none): heard, not more. The box's own
        // placeholder, dim before the first Space too, isn't.
        let heard = shot("open the", [ScreenRun(row: 3, column: 2, length: 8, faint: true)])
        #expect(ClaudeVoiceScreen.seen(heard, sent: 7) == .heard)
        #expect(ClaudeVoiceScreen.seen(heard, sent: 7, dimBefore: "open the") == .nothing)
        // Before the warmup's presses went in, a dim change is the box's own (its placeholder redrawn on focus).
        #expect(ClaudeVoiceScreen.seen(heard, sent: ClaudeVoiceScreen.warmupPresses - 1) == .nothing)

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

    /// Stopping on reads that come back late (a busy Mac): a read asked before Claude redrew after the Esc still shows
    /// it processing, and must not send a second Esc, which would reach Claude idle and interrupt its turn. One Esc.
    @Test func aStaleReadAfterTheEscSendsNoSecondOne() async {
        var keys: [[UInt8]] = []
        var escapedAt: Date?
        let session = ClaudeVoiceSession(id: UUID(), keys: { keys.append($0); if $0 == [ClaudeVoiceRun.escape], escapedAt == nil { escapedAt = Date() }; return true },
                                         screen: { done in
            // As asked: processing until 0.3 s after the Esc (Claude's redraw), then idle; answered 0.6 s later.
            let shown = escapedAt.map { Date().timeIntervalSince($0) >= 0.3 } == true
                ? ClaudeDictationTests.screen() : ClaudeDictationTests.screen(footer: "Voice: processing…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done(shown) }
        }, command: { _ in true })
        var outcome: ClaudeVoiceRun.Outcome?
        var listening = false
        let run = ClaudeVoiceRun(session: session, schedule: DictationController.after, onListening: { listening = true }) { outcome = $0 }
        run.start()
        #expect(await until { listening })
        run.release()
        run.cancel(.button)
        #expect(await until { outcome != nil })
        #expect(outcome == .cancelled)
        #expect(keys.filter { $0 == [ClaudeVoiceRun.escape] }.count == 1, "\(keys)")
    }

    /// A message sent over a dictation that doesn't show it stopped (Claude still processing after its Esc): the run says
    /// so, and tells the override its box isn't clean, so the message doesn't go onto whatever lands there.
    @Test func aMessageSentOverARunThatDidntStopDoesntGo() async {
        let id = UUID()
        let scripted = ScriptedSession()
        scripted.after = { count in count >= 1 ? ClaudeDictationTests.screen(footer: "Voice: processing…") : nil }
        var session = scripted.session
        session.id = id
        let (controller, _) = controller(session: { _ in session })
        controller.press("row", agent: .claude) { "" }
        #expect(await until { controller.listening })
        controller.release()
        var clean: Bool?
        #expect(controller.override(session: id) { clean = $0 })
        #expect(await until { controller.phase == .idle })
        #expect(clean == false)
        #expect(controller.notice?.text == ClaudeVoiceRun.notStopped, "\(String(describing: controller.notice))")
        #expect(scripted.keys.filter { $0 == [ClaudeVoiceRun.escape] }.count == ClaudeVoiceRun.stopKeys)
        #expect(ended?.contains("cancelled by a message sent over it") == true, "\(String(describing: ended))")
    }

    // MARK: - Against FakeClaude's /voice

    /// The harness's session, as the window gives it to dictation, a message sent over a dictation cancelling it as the
    /// window wires it; `now`: the runs' clock.
    func dictation(_ h: Harness, now: @escaping () -> Date = Date.init) -> DictationController {
        let controller = controller(session: { [weak h] key in h?.sync.claudeVoice(key: key) }, now: now).0
        h.sync.overrideDictation = { [weak controller] id, then in controller?.override(session: id, then: then) ?? false }
        return controller
    }

    /// The real time, moved on by the test.
    final class Clock: @unchecked Sendable {
        var ahead: TimeInterval = 0
        func now() -> Date { Date().addingTimeInterval(ahead) }
    }

    /// How the last run ended, as app.log says.
    var ended: String? { Breadcrumbs.shared.lines.last { $0.contains("dictation: Claude's ended") } }

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

    /// Esc and the ✕ stop a dictation at once in each phase: held, waiting after the release (Claude still recording
    /// after the Spaces stopped), and processing. Each time Claude's recording is cancelled (its own cancel), its box is
    /// as before, nothing lands, and its turn goes on (mid-turn, as the user's was: an Esc that reached Claude idle
    /// would have interrupted it). app.log says what cancelled it.
    @Test func escAndTheCrossCancelWhileHeldWaitingAndProcessing() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "work"])
        h.tell(["op": "voice", "mode": "hold"])
        try await h.waitFor { h.agent["voice"] as? String == "hold" && h.agent["mode"] as? String == "working" }
        let controller = dictation(h)
        var cancels = 0
        for phase in ["held", "waiting", "processing"] {
            for reason in [ClaudeVoiceRun.CancelReason.escape, .button] {
                h.tell(["op": "voice", "stuck": phase == "waiting", "processing": phase == "processing" ? 30.0 : 0.0])
                try await h.waitFor { h.agent["stuck"] as? Bool == (phase == "waiting") }
                controller.press(h.key, agent: .claude) { "" }
                try await h.waitFor { controller.listening }
                if phase != "held" {
                    controller.release()
                    #expect(controller.isTranscribing(h.key))
                    try await h.waitFor { h.agent["recording"] as? String == (phase == "waiting" ? "listening" : "processing") }
                }
                controller.cancel(reason)
                try await h.waitFor { controller.phase == .idle }
                cancels += 1
                #expect(h.agent["voiceCancels"] as? Int == cancels, "\(phase) \(reason)")
                #expect(h.agent["recording"] as? String == "", "\(phase) \(reason)")
                #expect(input(h) == "" && h.agent["voiceInserts"] as? Int == 0, "\(phase) \(reason)")
                #expect(controller.deliveries[h.key] == nil && controller.notice == nil, "\(phase) \(reason)")
                #expect(!ClaudeVoiceRun.busy.contains(h.session.id))
                #expect(ended?.contains("cancelled by \(reason.rawValue)") == true, "\(String(describing: ended))")
            }
        }
        try await h.quiet()
        #expect(h.agent["voiceCancels"] as? Int == cancels && h.agent["voiceInserts"] as? Int == 0 && input(h) == "")
        #expect(h.agent["mode"] as? String == "working" && h.agent["enters"] as? Int == 0)
    }

    /// The user's case (2026-10-30): a recording whose level cursor stayed flat, no processing seen and no text after the
    /// release, ends 3 s after it (the runs' clock), not 20. Claude went idle at once with nothing (too fast to see it
    /// process): nothing more to do. Claude still recording after the Spaces stopped: its own cancel first, so it isn't
    /// left recording. Mid-turn both times, and its turn goes on.
    @Test func aRecordingThatStaysFlatAfterTheReleaseEndsWithinAboutThreeSeconds() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "work"])
        h.tell(["op": "voice", "mode": "hold", "transcript": "", "interim": ""])
        try await h.waitFor { h.agent["voice"] as? String == "hold" && h.agent["interim"] as? String == "" }
        let clock = Clock()
        let controller = dictation(h, now: clock.now)
        for stuck in [false, true] {
            h.tell(["op": "voice", "stuck": stuck])
            try await h.waitFor { h.agent["stuck"] as? Bool == stuck }
            let inserts = h.agent["voiceInserts"] as? Int ?? 0
            controller.press(h.key, agent: .claude) { "" }
            try await h.waitFor { controller.listening }
            controller.release()
            if stuck {
                try await h.waitFor { h.agent["recording"] as? String == "listening" }
            } else {
                // Idle again with nothing written, at once.
                try await h.waitFor { h.agent["voiceInserts"] as? Int == inserts + 1 && h.agent["recording"] as? String == "" }
            }
            #expect(controller.isTranscribing(h.key), "ended before its 3 s: \(String(describing: ended))")
            clock.ahead += ClaudeVoiceRun.quietAfterRelease + 0.1
            try await h.waitFor { controller.phase == .idle }
            #expect(controller.notice?.text == ClaudeVoiceRun.heardNothing, "\(String(describing: controller.notice))")
            #expect(ended?.contains("nothing 3 s after the release, no processing") == true && ended?.contains("level cursor flat") == true,
                    "\(String(describing: ended))")
            #expect(h.agent["recording"] as? String == "")
            #expect(h.agent["voiceCancels"] as? Int == (stuck ? 1 : 0))
            #expect(input(h) == "" && controller.deliveries[h.key] == nil)
        }
        try await h.quiet()
        #expect(h.agent["mode"] as? String == "working" && h.agent["enters"] as? Int == 0)
    }

    /// A level heard while held (its cursor coloured) but no words shown yet, and Claude processing out of sight (a
    /// custom status line: no `processing…` footer): not the flat case, so 3 s after the release it's still waited for,
    /// and the transcript lands in the composer, not left in Claude's box after the run let go of it.
    @Test func aLevelHeardWithNoWordsYetIsWaitedForPastThreeSeconds() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "hold", "statusLine": true, "interim": "", "loud": true, "processing": 3.0,
                "transcript": "fix the build"])
        try await h.waitFor { h.agent["loud"] as? Bool == true && h.agent["processing"] as? Double == 3 }
        let clock = Clock()
        let controller = dictation(h, now: clock.now)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening && controller.claudeHeard }
        // Quiet from here on: only what was heard while held says it isn't the flat case.
        h.tell(["op": "voice", "loud": false])
        try await h.waitFor { h.agent["loud"] as? Bool == false }
        controller.release()
        try await h.waitFor { h.agent["recording"] as? String == "processing" }
        clock.ahead += ClaudeVoiceRun.quietAfterRelease + 0.1
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.deliveries[h.key]?.text == "fix the build", "\(String(describing: controller.notice)) \(String(describing: ended))")
        #expect(input(h) == "" && h.agent["voiceCancels"] as? Int == 0)
    }

    /// No text and a flat level cursor after an earlier run in this launch heard fine: the microphone works, so the
    /// notice says Claude didn't catch anything that time, with no privacy settings to open. Until a run has heard, the
    /// microphone's notice stays (`anEmptyTranscriptAfterAFlatLevelCursorSaysClaudeHeardNothing`).
    @Test func afterARunHeardAFlatOneSaysClaudeDidntCatchAnything() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "hold"])
        try await h.waitFor { h.agent["voice"] as? String == "hold" }
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        controller.release()
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.deliveries[h.key]?.text == "open the composer view on main")

        h.tell(["op": "voice", "transcript": "", "interim": "", "processing": 0.5])
        try await h.waitFor { h.agent["interim"] as? String == "" && h.agent["processing"] as? Double == 0.5 }
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        controller.release()
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.notice?.text == ClaudeVoiceRun.didntCatch && controller.notice?.privacy == false,
                "\(String(describing: controller.notice))")
        #expect(ended?.contains("level cursor flat") == true, "\(String(describing: ended))")
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
        // In app.log: the turning on, and what came of it.
        let lines = Breadcrumbs.shared.lines
        let typed = try #require(lines.lastIndex { $0.hasSuffix("dictation: turning on Claude's (/voice hold typed)") })
        #expect(lines[typed...].contains { $0.contains("dictation: turning on Claude's ended: Claude's dictation is on") }, "\(lines.suffix(5))")

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

    /// The composer's message sent while a dictation waits for Claude's text: sending wins. Claude's recording is
    /// cancelled first (its box as it was, nothing it heard written), then the message goes in, once, alone; the
    /// dictation lands nowhere. Typed in before, its Enter would have sent the dictation with it.
    @Test func sendingWhileADictationWaitsCancelsItAndTheMessageGoesOnceUnmixed() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        // Slow to process (as the user's 20 s wait): the transcript would land after the message, if at all.
        h.tell(["op": "voice", "mode": "hold", "processing": 30.0])
        try await h.waitFor { h.agent["voice"] as? String == "hold" && h.agent["processing"] as? Double == 30 }
        let prompts = h.agentPrompts
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        controller.release()
        try await h.waitFor { h.agent["recording"] as? String == "processing" }
        #expect(ClaudeVoiceRun.busy.contains(h.session.id))

        #expect(h.sync.type("also check the tests"))
        try await h.waitFor { h.agentPrompts.count > prompts.count }
        #expect(h.agentPrompts == prompts + ["also check the tests"], "\(h.agentPrompts)")
        #expect(h.agent["voiceCancels"] as? Int == 1 && h.agent["voiceInserts"] as? Int == 0)
        #expect(h.agent["recording"] as? String == "")
        #expect(controller.phase == .idle && controller.deliveries[h.key] == nil && controller.notice == nil)
        #expect(!ClaudeVoiceRun.busy.contains(h.session.id))
        #expect(h.chat.sendNotice != ChatSync.dictating)
        // In app.log: the override, and the run cancelled by it.
        #expect(Breadcrumbs.shared.lines.contains { $0.hasSuffix("composer: a dictation cancelled to send a message") })
        #expect(ended?.contains("cancelled by a message sent over it") == true, "\(String(describing: ended))")
        // Nothing comes after: the message went once, and Claude wrote nothing of the dictation.
        try await h.quiet()
        #expect(h.agentPrompts == prompts + ["also check the tests"])
        #expect(h.agent["voiceInserts"] as? Int == 0 && h.agent["enters"] as? Int == 1 && input(h) == "")
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

    /// Claude wrote nothing after its level cursor stayed grey the whole recording (silence from the microphone): the
    /// notice says it heard nothing and offers the microphone's privacy settings, without waiting out the 20 s.
    @Test func anEmptyTranscriptAfterAFlatLevelCursorSaysClaudeHeardNothing() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "hold", "transcript": "", "interim": "", "processing": 0.5])
        try await h.waitFor { h.agent["voice"] as? String == "hold" && h.agent["processing"] as? Double == 0.5 }
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        controller.release()
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.notice?.text == ClaudeVoiceRun.heardNothing && controller.notice?.privacy == true,
                "\(String(describing: controller.notice))")
        #expect(controller.deliveries[h.key] == nil)
        #expect(h.agent["voiceInserts"] as? Int == 1)
        #expect(h.agent["enters"] as? Int == 0)
        let ended = try #require(Breadcrumbs.shared.lines.last { $0.contains("dictation: Claude's ended") })
        #expect(ended.contains("no text after processing") && ended.contains("level cursor flat"), "\(ended)")
    }

    /// The same with a level heard (its cursor coloured): Claude gave no text, which isn't the microphone's doing.
    @Test func anEmptyTranscriptAfterALevelHeardSaysItGaveNoText() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "hold", "transcript": "", "interim": "um", "processing": 0.5])
        try await h.waitFor { h.agent["voice"] as? String == "hold" && h.agent["processing"] as? Double == 0.5 }
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        controller.release()
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.notice?.text == ClaudeVoiceRun.gaveNoText && controller.notice?.privacy == false,
                "\(String(describing: controller.notice))")
        let ended = try #require(Breadcrumbs.shared.lines.last { $0.contains("dictation: Claude's ended") })
        #expect(ended.contains("level cursor moved"), "\(ended)")
    }

    /// Each run leaves a trail in app.log: that it began, the states it saw by name (recording, processing), and how it
    /// ended and why; never what was heard or written.
    @Test func eachRunLeavesATrailInAppLogWithoutWhatWasSaid() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "hold", "transcript": "rename the quokka fixture", "interim": "rename the quokka", "processing": 0.5])
        try await h.waitFor { h.agent["voice"] as? String == "hold" && h.agent["processing"] as? Double == 0.5 }
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        controller.release()
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.deliveries[h.key]?.text == "rename the quokka fixture", "\(String(describing: controller.notice))")
        let lines = Breadcrumbs.shared.lines
        let began = try #require(lines.lastIndex { $0.contains("dictation: Claude's began") })
        let run = lines[began...].filter { $0.contains("dictation: Claude's") }
        let saw = run.filter { $0.contains("dictation: Claude's saw") }
        #expect(saw.contains { $0.hasSuffix("saw recording") } && saw.contains { $0.hasSuffix("saw processing") }, "\(run)")
        let ended = try #require(run.last { $0.contains("dictation: Claude's ended") })
        #expect(ended.contains("text taken (25 characters)") && ended.contains("Spaces") && ended.contains("level cursor moved")
                && ended.contains("recording → processing"), "\(ended)")
        #expect(!run.contains { $0.contains("quokka") || $0.contains("rename") }, "\(run)")
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

    // MARK: - Pacing

    /// The harness's session with every read of its screen taking `latency` (a busy Mac's host round trip).
    func dictation(_ h: Harness, readLatency latency: TimeInterval) -> DictationController {
        controller(session: { [weak h] key in
            guard var session = h?.sync.claudeVoice(key: key) else { return nil }
            let read = session.screen
            session.screen = { done in DispatchQueue.main.asyncAfter(deadline: .now() + latency) { read(done) } }
            return session
        }).0
    }

    /// Reads slower than Claude's 120 ms chain: the Spaces keep their own time, so it records, and the transcript lands
    /// with nothing sent.
    @Test func underSlowReadsAHoldRecordsAndLandsWithNothingSent() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "hold"])
        try await h.waitFor { h.agent["voice"] as? String == "hold" }
        let prompts = h.agentPrompts
        let controller = dictation(h, readLatency: 0.25)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        controller.release()
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.deliveries[h.key]?.text == "open the composer view on main", "\(String(describing: controller.notice))")
        #expect(h.agent["voiceStarts"] as? Int == 1)
        #expect(h.agent["doubleSubmits"] as? Int == 0 && h.agent["enters"] as? Int == 0)
        #expect(h.agentPrompts == prompts)
        #expect(input(h) == "")
    }

    /// Claude stopping by itself while held, under slow reads: Spaces go on until the reads see it, some of them pushes
    /// after its transcript went in, and none of it is sent.
    @Test func underSlowReadsClaudeStoppingByItselfSendsNothing() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "hold"])
        try await h.waitFor { h.agent["voice"] as? String == "hold" }
        let prompts = h.agentPrompts
        let controller = dictation(h, readLatency: 0.25)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        h.tell(["op": "voiceStop"])
        try await h.waitFor { h.agent["voiceInserts"] as? Int == 1 }
        controller.release()
        try await h.waitFor { controller.phase == .idle }
        let text = controller.deliveries[h.key]?.text ?? ""
        #expect(text.hasPrefix("open the composer view on main"), "\(text) \(String(describing: controller.notice))")
        #expect(h.agent["doubleSubmits"] as? Int == 0 && h.agent["enters"] as? Int == 0)
        #expect(h.agentPrompts == prompts)
    }

    /// The app stalls (its main thread busy) past the end of Claude's hold: Claude ends the recording and processes it,
    /// and a Space then would be typed and make it drop what it heard. The Spaces wait for a read asked since: it shows
    /// it processing, the hold stops, and what was heard lands.
    @Test func aStallPastTheEndOfTheHoldSendsNoSpaceWhileClaudeProcesses() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        h.tell(["op": "voice", "mode": "hold", "processing": 0.6])
        try await h.waitFor { h.agent["processing"] as? Double == 0.6 }
        let controller = dictation(h)
        controller.press(h.key, agent: .claude) { "" }
        try await h.waitFor { controller.listening }
        // The stall itself (what's tested), longer than Claude's 120 ms here.
        Thread.sleep(forTimeInterval: 0.35)
        try await h.waitFor { controller.phase == .idle }
        #expect(controller.deliveries[h.key]?.text == "open the composer view on main", "\(String(describing: controller.notice))")
        #expect(h.agent["dropped"] as? Int == 0)
        #expect(h.agent["doubleSubmits"] as? Int == 0 && h.agent["enters"] as? Int == 0)
        #expect(input(h) == "")
        controller.release()
    }

    /// A screen of Claude's for `keys`: recording after the first Space; the transcript in the box once `landed` says so;
    /// empty once ⌃U went.
    nonisolated static func scripted(_ keys: [[UInt8]], landed: Bool) -> LeadDelivery.Screen {
        if keys.contains([ClaudeVoiceRun.killLine]) { return screen() }
        if landed { return screen(input: "open the composer") }
        return keys.isEmpty ? screen() : screen(footer: "listening…")
    }

    /// The hold's last Space is followed at once by End (any key but Space calls off Claude's double push), and no
    /// Space after it: on the release, and when Claude stops by itself.
    @Test func aHoldsLastSpaceIsFollowedByEndAndNoSpaceAfter() async {
        for byItself in [false, true] {
            let scripted = ScriptedSession()
            var landed = false
            scripted.after = { [scripted] _ in
                // By itself: the transcript goes in after a few repeats.
                if byItself, scripted.keys.filter({ $0 == [ClaudeVoiceRun.space] }).count >= 8 { landed = true }
                return ClaudeDictationTests.scripted(scripted.keys, landed: landed)
            }
            let (controller, _) = controller(session: { _ in scripted.session })
            controller.press("row", agent: .claude) { "" }
            #expect(await until { controller.listening })
            if !byItself {
                controller.release()
                landed = true
            }
            #expect(await until { controller.phase == .idle })
            #expect(controller.deliveries["row"]?.text == "open the composer", "\(String(describing: controller.notice))")
            let end = scripted.keys.firstIndex(of: ClaudeVoiceRun.disarm)
            #expect(end != nil, "no End after the hold: \(scripted.keys)")
            if let end {
                #expect(scripted.keys[..<end].allSatisfy { $0 == [ClaudeVoiceRun.space] }, "\(scripted.keys)")
                #expect(!scripted.keys[(end + 1)...].contains([ClaudeVoiceRun.space]), "\(scripted.keys)")
            }
            controller.release()
        }
    }

    // MARK: - Turning it on

    /// Claude's answer to /voice hold is the one after the command's newest echo: an earlier "Voice mode enabled"
    /// scrolling off as the new one comes in (the same count before and after) doesn't hide it.
    @Test func turningOnFindsTheAnswerAfterTheCommandThoughAnEarlierOneScrolledOff() async {
        let earlier = ["❯ /voice hold", "  ⎿ Voice mode enabled (hold). Hold Space to record.", "⏺ Done earlier."]
        let now = ["⏺ Done earlier.", "❯ /voice hold", "  ⎿ Voice mode enabled (hold). Hold Space to record."]
        #expect(ClaudeVoiceScreen.signals(Self.screen(above: earlier.joined(separator: "\n")).text)
                == ClaudeVoiceScreen.signals(Self.screen(above: now.joined(separator: "\n")).text))
        let scripted = ScriptedSession()
        scripted.screen = Self.screen(above: earlier.joined(separator: "\n"))
        scripted.after = { [scripted] _ in
            scripted.commands.isEmpty ? nil : ClaudeDictationTests.screen(above: now.joined(separator: "\n"))
        }
        let (controller, _) = controller(session: { _ in scripted.session })
        controller.turnOnClaude("row")
        #expect(await until { controller.turningOn == nil })
        #expect(scripted.commands == [DictationController.turnOnCommand])
        #expect(controller.notice?.info == true && controller.notice?.text.contains("is on") == true, "\(String(describing: controller.notice))")

        // Typed into the box but not sent yet, or an answer to something else: not its answer.
        let typed = ClaudeDictationTests.screen(input: "/voice hold", above: earlier.joined(separator: "\n"))
        #expect(ClaudeVoiceScreen.answer(to: "/voice hold", in: typed.text, before: ClaudeVoiceScreen.conversation(Self.screen(above: earlier.joined(separator: "\n")).text)) == nil)
        let unchanged = Self.screen(above: earlier.joined(separator: "\n")).text
        #expect(ClaudeVoiceScreen.answer(to: "/voice hold", in: unchanged, before: ClaudeVoiceScreen.conversation(unchanged)) == nil)
    }
}
