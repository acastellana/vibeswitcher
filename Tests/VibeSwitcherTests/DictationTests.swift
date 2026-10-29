import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Push to talk on the Mac: the request to OpenAI (multipart, three parts only, the key from the key store in the
/// Authorization header alone), its answer read, failures said plainly without the server's words, the vocabulary
/// prompt, the key found elsewhere imported only once confirmed, and the controller's press, release, one-time note
/// and 2-minute limit. Nothing reaches the network or the microphone: `FakeHTTP` and `FakeRecorder` stand in, the key
/// is made up and lives in memory (`AppProof.MemorySecret`).
@MainActor
struct DictationTests {
    let temp = Scratch()
    nonisolated static let key = "sk-test-\(String(repeating: "a", count: 24))"

    /// Answers every request with `status` and `body`, and keeps the requests.
    final class FakeHTTP: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [URLRequest] = []
        let status: Int
        let body: Data
        let fails: Bool

        init(status: Int = 200, body: String = #"{"text":"Open ComposerView.swift on main"}"#, fails: Bool = false) {
            self.status = status
            self.body = Data(body.utf8)
            self.fails = fails
        }

        var requests: [URLRequest] { lock.withLock { seen } }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            lock.withLock { seen.append(request) }
            if fails { throw URLError(.notConnectedToInternet) }
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    /// A microphone that records `audio` when started, if allowed.
    final class FakeRecorder: DictationRecorder {
        var allowed = true
        var audio: DictationAudio? = DictationAudio(data: Data("m4a-bytes".utf8), mimeType: "audio/mp4", duration: 3)
        private(set) var starts = 0
        private(set) var stops = 0
        private(set) var recording = false

        func permission(_ done: @escaping (Bool) -> Void) { done(allowed) }
        func start() throws {
            starts += 1
            recording = true
        }
        func stop() -> DictationAudio? {
            stops += 1
            recording = false
            return audio
        }
        func cancel() { recording = false }
    }

    /// The 2-minute limit's timer, fired when the test says.
    final class FakeClock {
        var pending: [(delay: TimeInterval, work: () -> Void)] = []
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
            pending.append((delay, work))
            let index = pending.count - 1
            return { [weak self] in self?.pending[index].work = {} }
        }
    }

    func transcription(_ http: FakeHTTP) -> OpenAITranscription {
        var transcription = OpenAITranscription(client: http)
        transcription.boundary = { "BOUNDARY" }
        return transcription
    }

    func controller(_ http: FakeHTTP, recorder: FakeRecorder, key: String? = key, clock: FakeClock = FakeClock(),
                    noted: Bool = true, found: FoundOpenAIKey? = nil) -> (DictationController, AppProof.MemorySecret) {
        let store = AppProof.MemorySecret(key)
        let defaults = temp.defaults("dictation")
        if noted { defaults.set(true, forKey: DictationController.privacyNotedKey) }
        let controller = DictationController(keyStore: store, recorder: recorder, transcription: transcription(http), defaults: defaults,
                                             findKey: { found }, background: { $0() }, schedule: clock.schedule)
        return (controller, store)
    }

    /// Releases and waits for the controller to be idle again (the transcription answered).
    func releaseAndWait(_ controller: DictationController) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            controller.onIdle = {
                controller.onIdle = nil
                done.resume()
            }
            controller.release()
        }
    }

    /// The names of the body's parts, in order.
    static func partNames(_ body: Data) -> [String] {
        let text = String(decoding: body, as: UTF8.self)
        return text.components(separatedBy: "Content-Disposition: form-data; name=\"").dropFirst()
            .compactMap { $0.split(separator: "\"").first.map(String.init) }
    }

    // MARK: - The request

    @Test func theRequestCarriesTheAudioTheModelAndThePromptOnly() throws {
        let audio = DictationAudio(data: Data([0, 1, 2, 255]), mimeType: "audio/webm;codecs=opus", duration: 2)
        let request = transcription(FakeHTTP()).request(audio: audio, model: "gpt-transcribe", prompt: "Words: VibeSwitcher.", key: Self.key)
        #expect(request.url == URL(string: "https://api.openai.com/v1/audio/transcriptions"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUNDARY")
        let body = try #require(request.httpBody)
        var expected = Data("--BOUNDARY\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.webm\"\r\nContent-Type: audio/webm\r\n\r\n".utf8)
        expected.append(Data([0, 1, 2, 255]))
        expected.append(Data("\r\n--BOUNDARY\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n".utf8))
        expected.append(Data("--BOUNDARY\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nWords: VibeSwitcher.\r\n--BOUNDARY--\r\n".utf8))
        #expect(body == expected)
        #expect(Self.partNames(body) == ["file", "model", "prompt"])
        // The key is in the header, never in the URL or the body.
        #expect(!request.url!.absoluteString.contains(Self.key))
        #expect(body.range(of: Data(Self.key.utf8)) == nil)
    }

    @Test func noPromptPartWhenThereAreNoWords() throws {
        let audio = DictationAudio(data: Data("x".utf8), mimeType: "audio/mp4", duration: 1)
        let body = try #require(transcription(FakeHTTP()).request(audio: audio, model: "gpt-transcribe", prompt: "", key: Self.key).httpBody)
        #expect(Self.partNames(body) == ["file", "model"])
        #expect(String(decoding: body, as: UTF8.self).contains("filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n"))
    }

    /// A Content-Type the phone sent can't add a header line or parameters to the part.
    @Test func aPartTypeIsTheBareTypeOrNone() {
        #expect(OpenAITranscription.partType("audio/webm;codecs=opus") == "audio/webm")
        #expect(OpenAITranscription.partType("Audio/MP4") == "audio/mp4")
        #expect(OpenAITranscription.partType("audio/mp4\r\nX-Evil: 1") == "application/octet-stream")
        #expect(OpenAITranscription.partType("") == "application/octet-stream")
    }

    // MARK: - The answer

    @Test func theAnswersTextIsReadTrimmed() throws {
        #expect(try OpenAITranscription.text(from: Data(#"{"text":"  hello there \n","languages":[{"code":"en"}]}"#.utf8)) == "hello there")
        #expect(throws: OpenAITranscription.Failure.empty) { try OpenAITranscription.text(from: Data(#"{"text":"  "}"#.utf8)) }
        #expect(throws: OpenAITranscription.Failure.unreadable) { try OpenAITranscription.text(from: Data("<html>".utf8)) }
    }

    @Test func failuresArePlainAndNeverTheServersWords() async {
        let audio = DictationAudio(data: Data("x".utf8), mimeType: "audio/mp4", duration: 1)
        let refused = FakeHTTP(status: 401, body: #"{"error":{"message":"Incorrect API key provided: sk-test-aa***aaaa"}}"#)
        await #expect(throws: OpenAITranscription.Failure.status(401)) {
            try await transcription(refused).transcribe(audio, model: "gpt-transcribe", prompt: "", key: Self.key)
        }
        #expect(OpenAITranscription.Failure.status(401).notice.contains("refused the API key"))
        #expect(!OpenAITranscription.Failure.status(401).notice.contains("sk-"))
        await #expect(throws: OpenAITranscription.Failure.network) {
            try await transcription(FakeHTTP(fails: true)).transcribe(audio, model: "gpt-transcribe", prompt: "", key: Self.key)
        }
        #expect(OpenAITranscription.Failure.network.notice.contains("Couldn't reach OpenAI"))
        // Too long or keyless: nothing is sent.
        let none = FakeHTTP()
        await #expect(throws: OpenAITranscription.Failure.tooLong) {
            try await transcription(none).transcribe(DictationAudio(data: Data("x".utf8), mimeType: "audio/mp4", duration: 150),
                                                     model: "gpt-transcribe", prompt: "", key: Self.key)
        }
        await #expect(throws: OpenAITranscription.Failure.noKey) {
            try await transcription(none).transcribe(audio, model: "gpt-transcribe", prompt: "", key: nil)
        }
        #expect(none.requests.isEmpty)
    }

    // MARK: - The vocabulary

    @Test func thePromptNamesTheProjectBranchesAndFilesOnce() {
        let prompt = DictationVocabulary.prompt(project: "VibeSwitcher", branches: ["agent/push-to-talk", "main", "VibeSwitcher"],
                                                files: ["ComposerView.swift", "app.js", "ComposerView.swift"])
        #expect(prompt == "Words that may come up: VibeSwitcher, agent/push-to-talk, main, ComposerView.swift, app.js.")
        #expect(DictationVocabulary.prompt(project: nil, branches: [], files: []) == "")
    }

    @Test func thePromptStaysShortAndMasksCredentials() {
        let files = (0..<200).map { "VeryLongFileName\($0)WithManyWords.swift" }
        let prompt = DictationVocabulary.prompt(project: "p", branches: [], files: files)
        #expect(prompt.count <= DictationVocabulary.maxCharacters)
        #expect(prompt.hasSuffix(".swift."))
        let secret = DictationVocabulary.prompt(project: "p", branches: ["sk-proj-\(String(repeating: "Z", count: 40))"], files: [])
        #expect(!secret.contains("ZZZZ"))
    }

    @Test func recentFilesComeFromTheConversationLatestFirst() {
        func tool(_ id: String, _ detail: ToolDetail) -> ChatEntry {
            ChatEntry(id: id, kind: .tool(ChatTool(id: id, name: "t", title: "t", detail: detail)))
        }
        let entries = [tool("1", .read(path: "/r/Sources/Old.swift")), tool("2", .command("ls")),
                       tool("3", .edit(path: "/r/Web/app.js", changes: [])), tool("4", .write(path: "/r/Sources/Old.swift", content: ""))]
        #expect(DictationVocabulary.files(in: entries) == ["Old.swift", "app.js"])
    }

    // MARK: - The key

    @Test func codexsAuthFileGivesItsAPIKeyNeverChatGPTTokens() {
        #expect(DictationKey.apiKey(inCodexAuth: #"{"OPENAI_API_KEY":"\#(Self.key)","tokens":null}"#) == Self.key)
        #expect(DictationKey.apiKey(inCodexAuth: #"{"OPENAI_API_KEY":null,"tokens":{"id_token":"eyJhbGciOi.x.y","access_token":"eyJz.a.b","refresh_token":"rt"}}"#) == nil)
        #expect(DictationKey.apiKey(inCodexAuth: #"{"OPENAI_API_KEY":"eyJhbGciOiJSUzI1NiJ9.payload.signature"}"#) == nil)
        #expect(DictationKey.apiKey(inCodexAuth: "not json") == nil)
        #expect(DictationKey.find(shell: { Self.key }, codexAuth: { nil }) == FoundOpenAIKey(source: .shell, key: Self.key))
        let codex = "sk-codex-\(String(repeating: "b", count: 24))"
        #expect(DictationKey.find(shell: { nil }, codexAuth: { #"{"OPENAI_API_KEY":"\#(codex)"}"# }) == FoundOpenAIKey(source: .codex, key: codex))
        #expect(DictationKey.find(shell: { "not-a-key" }, codexAuth: { nil }) == nil)
    }

    /// A key found in the shell is offered, and saved to the key store only when the import is confirmed.
    @Test func aFoundKeyIsSavedOnlyOnceImported() async {
        let (controller, store) = controller(FakeHTTP(), recorder: FakeRecorder(), key: nil, found: FoundOpenAIKey(source: .shell, key: Self.key))
        controller.lookForKeys()
        await waitForMain { controller.found != nil }
        #expect(controller.keyState == .missing)
        #expect(store.read() == nil)
        controller.importFound()
        await waitForMain { controller.keyState == .saved }
        #expect(store.read() == Self.key)
        #expect(controller.found == nil)
    }

    @Test func aTypedKeyThatIsntOpenAIsIsntSaved() async {
        let (controller, store) = controller(FakeHTTP(), recorder: FakeRecorder(), key: nil)
        controller.saveKey("hello")
        #expect(controller.keyNotice?.contains("sk-") == true)
        #expect(store.read() == nil)
        controller.saveKey("  \(Self.key)\n")
        await waitForMain { controller.keyState == .saved }
        #expect(store.read() == Self.key)
        controller.saveKey(nil)
        await waitForMain { controller.keyState == .missing }
        #expect(store.read() == nil)
    }

    /// Waits for main-thread work the controller queued (`DispatchQueue.main.async`) to have run and made `condition` true.
    func waitForMain(_ condition: @escaping () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
        }
    }

    // MARK: - Push to talk

    @Test func aReleaseSendsTheRecordingWithTheSavedKeyAndTheTextWaitsInTheBox() async throws {
        let http = FakeHTTP()
        let recorder = FakeRecorder()
        let (controller, _) = controller(http, recorder: recorder)
        controller.press("row-1") { "Words that may come up: VibeSwitcher." }
        #expect(controller.isRecording("row-1"))
        #expect(recorder.recording)
        await releaseAndWait(controller)
        #expect(recorder.stops == 1)
        let request = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)")
        let body = try #require(request.httpBody)
        #expect(Self.partNames(body) == ["file", "model", "prompt"])
        #expect(String(decoding: body, as: UTF8.self).contains("\r\n\r\ngpt-transcribe\r\n"))
        #expect(String(decoding: body, as: UTF8.self).contains("Words that may come up: VibeSwitcher."))
        // In the box's inbox, not sent: nothing but the transcript.
        #expect(controller.deliveries["row-1"]?.text == "Open ComposerView.swift on main")
        #expect(controller.phase == .idle)
        #expect(controller.notice == nil)
        let serial = try #require(controller.deliveries["row-1"]?.serial)
        controller.delivered("row-1", serial: serial)
        #expect(controller.deliveries["row-1"] == nil)
    }

    @Test func theFirstPressShowsTheNoteAboutOpenAIOnce() async {
        let recorder = FakeRecorder()
        let (controller, _) = controller(FakeHTTP(), recorder: recorder, noted: false)
        controller.press("row-1") { "" }
        #expect(controller.privacyNoteFor == "row-1")
        #expect(recorder.starts == 0)
        controller.release()
        controller.acknowledgePrivacy()
        #expect(controller.privacyNoted)
        #expect(controller.privacyNoteFor == nil)
        controller.press("row-1") { "" }
        #expect(recorder.starts == 1)
        await releaseAndWait(controller)
        #expect(controller.privacyNoteFor == nil)
    }

    @Test func withoutAKeyThePressSaysWhatsNeededAndSendsNothing() async {
        let http = FakeHTTP()
        let recorder = FakeRecorder()
        let (controller, _) = controller(http, recorder: recorder, key: nil)
        controller.checkKey()
        await waitForMain { controller.keyState == .missing }
        controller.press("row-1") { "" }
        #expect(recorder.starts == 0)
        #expect(controller.notice?.settings == true)
        #expect(controller.notice?.text.contains("OpenAI API key") == true)
        #expect(http.requests.isEmpty)
    }

    @Test func aKeyRemovedSinceTheLastLookIsSaidAfterTheRecording() async {
        let http = FakeHTTP()
        let (controller, _) = controller(http, recorder: FakeRecorder(), key: nil)
        controller.press("row-1") { "" }
        await releaseAndWait(controller)
        #expect(http.requests.isEmpty)
        #expect(controller.keyState == .missing)
        #expect(controller.notice?.settings == true)
        #expect(controller.deliveries.isEmpty)
    }

    @Test func aRefusedMicrophoneIsSaid() {
        let recorder = FakeRecorder()
        recorder.allowed = false
        let (controller, _) = controller(FakeHTTP(), recorder: recorder)
        controller.press("row-1") { "" }
        #expect(recorder.starts == 0)
        #expect(controller.notice?.text.contains("Microphone") == true)
    }

    @Test func aRecordingStopsAtTwoMinutes() async throws {
        let http = FakeHTTP()
        let recorder = FakeRecorder()
        let clock = FakeClock()
        let (controller, _) = controller(http, recorder: recorder, clock: clock)
        controller.press("row-1") { "" }
        let limit = try #require(clock.pending.first)
        #expect(limit.delay == 120)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            controller.onIdle = { done.resume() }
            limit.work()
        }
        #expect(!recorder.recording)
        #expect(http.requests.count == 1)
        #expect(controller.notice?.text.contains("2 minutes") == true)
        // Letting go afterwards sends nothing more.
        controller.onIdle = nil
        controller.release()
        #expect(http.requests.count == 1)
    }

    @Test func aTapTooShortSendsNothing() {
        let http = FakeHTTP()
        let recorder = FakeRecorder()
        recorder.audio = DictationAudio(data: Data("x".utf8), mimeType: "audio/mp4", duration: 0.1)
        let (controller, _) = controller(http, recorder: recorder)
        controller.press("row-1") { "" }
        controller.release()
        #expect(http.requests.isEmpty)
        #expect(controller.notice?.text.contains("Nothing was recorded") == true)
        #expect(controller.phase == .idle)
    }

    @Test func anOpenAIFailureIsSaidUnderTheBox() async {
        let (controller, _) = controller(FakeHTTP(status: 429, body: #"{"error":{"message":"quota"}}"#), recorder: FakeRecorder())
        controller.press("row-2") { "" }
        await releaseAndWait(controller)
        #expect(controller.notice == .init(rowID: "row-2", text: OpenAITranscription.Failure.status(429).notice))
        #expect(controller.deliveries.isEmpty)
    }

    // MARK: - The box

    @Test func theTextGoesInAtTheCursorWithSpacesWhereWordsTouch() {
        #expect(DictationInsert.text("hello", before: nil, after: nil) == "hello")
        #expect(DictationInsert.text("hello", before: "a", after: "b") == " hello ")
        #expect(DictationInsert.text("hello", before: " ", after: ".") == "hello")
        let textView = NSTextView()
        textView.string = "fix  please"
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        DictationInsert.insert("the header", into: textView)
        #expect(textView.string == "fix the header please")
        textView.setSelectedRange(NSRange(location: 4, length: 3))
        DictationInsert.insert("a", into: textView)
        #expect(textView.string == "fix a header please")
    }

    /// A transcript that arrives for a box goes in once, at its cursor; it's never sent.
    @Test func theInboxPutsATranscriptInOnce() async {
        let (controller, _) = controller(FakeHTTP(), recorder: FakeRecorder())
        let textView = NSTextView()
        textView.string = "Run "
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        let inbox = DictationInbox()
        inbox.watch(controller, rowID: { "row-1" }, textView: textView)
        controller.press("row-1") { "" }
        await releaseAndWait(controller)
        await waitForMain { controller.deliveries.isEmpty }
        #expect(textView.string == "Run Open ComposerView.swift on main")
        // Another box for another row takes nothing.
        let other = NSTextView()
        DictationInbox().watch(controller, rowID: { "row-2" }, textView: other)
        await waitForMain { true }
        #expect(other.string.isEmpty)
    }

    @Test func optionSpaceAloneIsTheTalkKey() throws {
        func key(_ flags: NSEvent.ModifierFlags, code: Int = kVK_Space) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                          characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: UInt16(code)))
        }
        #expect(ComposerNSTextView.isTalkKey(try key(.option)))
        #expect(!ComposerNSTextView.isTalkKey(try key([])))
        #expect(!ComposerNSTextView.isTalkKey(try key([.option, .command])))
        #expect(!ComposerNSTextView.isTalkKey(try key(.option, code: kVK_ANSI_A)))
    }

    /// ⌥Space held in the box records, its key-up sends it; the window losing key (another app) ends it as the key-up would.
    @Test func holdingOptionSpaceTalksUntilLetGoOrTheWindowLeaves() throws {
        func event(_ type: NSEvent.EventType, repeat: Bool = false, window: NSWindow) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: `repeat`,
                                          keyCode: UInt16(kVK_Space)))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let textView = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = textView
        var held: [Bool] = []
        textView.holdToTalk = { held.append($0) }
        textView.keyDown(with: try event(.keyDown, window: window))
        textView.keyDown(with: try event(.keyDown, repeat: true, window: window))
        #expect(held == [true])
        #expect(textView.string.isEmpty, "⌥Space typed nothing")
        textView.keyUp(with: try event(.keyUp, window: window))
        #expect(held == [true, false])
        textView.keyDown(with: try event(.keyDown, window: window))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(held == [true, false, true, false])
        textView.keyUp(with: try event(.keyUp, window: window))
        #expect(held == [true, false, true, false], "the late key-up sends nothing more")
    }
}
