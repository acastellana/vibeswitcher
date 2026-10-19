import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// Brief me: ElevenLabs gets the text only on a press, with the key in its header and nowhere else; a failure or no
/// key falls back to the Mac's voice; pressing again stops. No network (a URLProtocol stub), no Keychain (a memory
/// store), no sound (a fake voice), no real Claude (a fake model), a scratch defaults domain. The key is made up.
@MainActor
struct BriefingButtonTests {
    /// Made up, assembled at runtime; never a real key.
    static let key = "sk" + "_" + String(repeating: "f4ke", count: 8)
    static let token = "ghp" + "_" + String(String(repeating: "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789", count: 2).prefix(36))

    /// ElevenLabs' stand-in: each test's requests by its own voice id (the URL's last part), answered as it says.
    final class Stub: URLProtocol, @unchecked Sendable {
        struct Seen {
            var request: URLRequest
            var body: Data
        }
        nonisolated(unsafe) static var answers: [String: (status: Int, body: Data, fail: Bool)] = [:]
        nonisolated(unsafe) static var seen: [String: [Seen]] = [:]
        static let lock = NSLock()

        static func expect(voice: String, status: Int = 200, body: Data = Data("ID3-fake-mp3".utf8), fail: Bool = false) {
            lock.withLock { answers[voice] = (status, body, fail) }
        }

        static func requests(_ voice: String) -> [Seen] { lock.withLock { seen[voice] ?? [] } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let voice = request.url?.lastPathComponent ?? ""
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    guard read > 0 else { break }
                    body.append(buffer, count: read)
                }
                stream.close()
            }
            let answer = Self.lock.withLock {
                Self.seen[voice, default: []].append(Seen(request: request, body: body))
                return Self.answers[voice]
            }
            guard let answer, !answer.fail else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "audio/mpeg"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: answer.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    final class FakeVoice: BriefingVoice {
        var finished: () -> Void = {}
        var played: [Data] = []
        var said: [(text: String, language: String)] = []
        var stops = 0
        var playable = true

        func play(_ audio: Data) -> Bool {
            played.append(audio)
            return playable
        }

        func say(_ text: String, language: String) { said.append((text, language)) }
        func stop() { stops += 1 }
    }

    final class FakeClaude: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        var answer: String?
        /// Holds the model's answer until let go (to press again while it's written).
        let gate = DispatchSemaphore(value: 0)
        var held = false

        init(_ answer: String?) { self.answer = answer }
        var prompts: [String] { lock.withLock { asked } }

        func generate(_ prompt: String) -> String? {
            lock.withLock { asked.append(prompt) }
            if held { gate.wait() }
            return answer
        }
    }

    let voiceID = "test-voice-\(UUID().uuidString.prefix(8))"
    let defaults: UserDefaults
    let suite = "briefing-tests-\(UUID().uuidString)"

    init() { defaults = UserDefaults(suiteName: suite)! }

    func client() -> ElevenLabs {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return ElevenLabs(voice: voiceID, session: URLSession(configuration: configuration))
    }

    func model(key: String?, claude: FakeClaude, voice: FakeVoice, language: String = "es", store: AppProof.MemorySecret? = nil,
               boards: [String: LeadBoard] = [:], sessions: [Session] = []) -> (BriefingModel, AppProof.MemorySecret) {
        let store = store ?? AppProof.MemorySecret(key)
        let model = BriefingModel(snapshot: { .init(boards: boards, sessions: sessions) },
                                  language: { BriefingLanguage.named(language)! }, keyStore: store,
                                  generate: { claude.generate($0) }, client: client(), voice: voice, defaults: defaults)
        return (model, store)
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }

    /// The request: the URL names the voice, the body the text (redacted), the model and the language; the key is in
    /// the xi-api-key header and nowhere else.
    @Test func theRequestCarriesTheKeyInItsHeaderOnly() throws {
        let request = client().request(text: "Two fixes landed; token \(Self.token) leaked", language: "es", key: Self.key)
        #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == Self.key)
        #expect(!(request.url?.absoluteString.contains(Self.key) ?? true))
        let body = try #require(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        #expect(!text.contains(Self.key))
        #expect(!text.contains(String(Self.token.dropFirst(4))))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model_id"] as? String == "eleven_v4")
        #expect(json["language_code"] as? String == "es")
        #expect((json["text"] as? String)?.hasPrefix("Two fixes landed; token ") == true)
        #expect(Set(json.keys) == ["text", "model_id", "language_code"])
        // Every other header is the plain ones.
        let headers = request.allHTTPHeaderFields ?? [:]
        #expect(headers.filter { $0.value.contains(Self.key) }.keys.sorted() == ["xi-api-key"])
    }

    /// A press writes it (the fake model's words are what's shown), remembers when, and has ElevenLabs read it: the
    /// one request, sent only then, through the stub.
    @Test func aPressWritesItAndElevenLabsReadsIt() async throws {
        defer { cleanUp() }
        Stub.expect(voice: voiceID)
        let claude = FakeClaude("En vibeswitcher aterrizaron nueve arreglos y una instalación espera tu firma.")
        let voice = FakeVoice()
        let (model, store) = model(key: Self.key, claude: claude, voice: voice)
        model.checkKey()
        model.saveKey(Self.key)
        #expect(await until { model.keySaved == true })
        // Nothing has left: not on making the model, not on reading or saving the key.
        #expect(Stub.requests(voiceID).isEmpty)
        #expect(claude.prompts.isEmpty)

        model.press()
        #expect(model.phase == .writing)
        #expect(await until { voice.played.count == 1 })
        #expect(model.phase == .speaking)
        #expect(model.briefing?.text == "En vibeswitcher aterrizaron nueve arreglos y una instalación espera tu firma.")
        #expect(model.briefing?.byModel == true)
        #expect(model.briefing?.notice == nil)
        #expect(model.voiceNotice == nil)
        #expect(claude.prompts.count == 1)
        #expect(claude.prompts[0].contains("Spanish") && claude.prompts[0].contains("70 to 90 words"))
        let seen = Stub.requests(voiceID)
        #expect(seen.count == 1)
        #expect(seen.first?.request.value(forHTTPHeaderField: "xi-api-key") == Self.key)
        let body = try #require(seen.first.map { try JSONSerialization.jsonObject(with: $0.body) as? [String: Any] } ?? nil)
        #expect(body["language_code"] as? String == "es")
        #expect(body["text"] as? String == model.briefing?.text)
        #expect(voice.said.isEmpty)
        // Remembered: the next one covers what's new since.
        #expect(model.lastBriefed == model.briefing?.at)
        #expect(store.reads >= 1)

        // Pressing again stops it.
        model.press()
        #expect(model.phase == .idle)
        #expect(voice.stops == 1)
        // Play reads it again from the audio kept: no second request.
        model.playOrStop()
        #expect(await until { voice.played.count == 2 })
        #expect(Stub.requests(voiceID).count == 1)
        voice.finished()
        #expect(model.phase == .idle)
    }

    /// The key is in the store and nowhere in the defaults.
    @Test func theKeyNeverReachesTheDefaults() async {
        defer { cleanUp() }
        let (model, store) = model(key: nil, claude: FakeClaude(nil), voice: FakeVoice())
        model.saveKey("  \(Self.key)\n")
        #expect(await until { model.keySaved == true })
        #expect(store.read() == Self.key)
        let everything = defaults.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        #expect(!everything.contains(Self.key))
        #expect(!(UserDefaults.standard.dictionaryRepresentation().map { "\($0.value)" }.joined().contains(Self.key)))
        model.saveKey(nil)
        #expect(await until { model.keySaved == false })
        #expect(store.read() == nil)
    }

    /// No key: the Mac's voice, and nothing goes to ElevenLabs.
    @Test func withoutAKeyTheMacsVoiceReadsIt() async {
        defer { cleanUp() }
        Stub.expect(voice: voiceID)
        let voice = FakeVoice()
        let (model, _) = model(key: nil, claude: FakeClaude("Nada nuevo."), voice: voice)
        model.press()
        #expect(await until { voice.said.count == 1 })
        #expect(voice.said.first?.text == "Nada nuevo.")
        #expect(voice.said.first?.language == "es")
        #expect(model.voiceNotice == nil)
        #expect(Stub.requests(voiceID).isEmpty)
    }

    /// ElevenLabs refuses (4xx), fails (5xx) or can't be reached: the Mac's voice reads it, with one line why.
    @Test(arguments: [(401, false, "ElevenLabs refused the key (HTTP 401), so the Mac's voice reads it."),
                      (503, false, "ElevenLabs answered HTTP 503, so the Mac's voice reads it."),
                      (200, true, "ElevenLabs couldn't be reached, so the Mac's voice reads it.")])
    func aFailureFallsBackToTheMacsVoice(status: Int, offline: Bool, notice: String) async {
        defer { cleanUp() }
        Stub.expect(voice: voiceID, status: status, body: Data("{\"detail\":\"no\"}".utf8), fail: offline)
        let voice = FakeVoice()
        let (model, _) = model(key: Self.key, claude: FakeClaude("Two fixes landed."), voice: voice, language: "en")
        model.press()
        #expect(await until { voice.said.count == 1 })
        #expect(voice.played.isEmpty)
        #expect(model.voiceNotice == notice)
        #expect(!(model.voiceNotice ?? "").contains(Self.key))
        #expect(model.phase == .speaking)
        #expect(Stub.requests(voiceID).count == 1)
    }

    /// No Claude: the English template, said so in the panel, and read in English.
    @Test func withoutClaudeTheTemplateIsReadInEnglish() async {
        defer { cleanUp() }
        let voice = FakeVoice()
        let waiting = Session(tty: "ttys001", agent: .claude, pid: 1, startedAt: .distantPast, cwd: nil, project: "genswap", task: nil,
                              status: .needsInput, statusSince: Date(), detail: nil, hasHooks: true, inTerminalApp: false)
        let (model, _) = model(key: nil, claude: FakeClaude(nil), voice: voice, language: "fr", sessions: [waiting])
        model.press()
        #expect(await until { voice.said.count == 1 })
        #expect(model.briefing?.byModel == false)
        #expect(model.briefing?.notice == "Claude isn't available, so this is a template briefing in English.")
        #expect(voice.said.first?.language == "en")
        #expect(voice.said.first?.text == "1 session needs you: genswap.")
    }

    /// Pressed while it's written: cancelled; what the model says later is dropped, nothing is read.
    @Test func pressingWhileItsWrittenCancelsIt() async {
        defer { cleanUp() }
        Stub.expect(voice: voiceID)
        let claude = FakeClaude("Late words.")
        claude.held = true
        let voice = FakeVoice()
        let (model, _) = model(key: Self.key, claude: claude, voice: voice)
        model.press()
        #expect(await until { claude.prompts.count == 1 })
        model.press()
        #expect(model.phase == .idle)
        claude.gate.signal()
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(model.briefing == nil)
        #expect(model.phase == .idle)
        #expect(voice.played.isEmpty && voice.said.isEmpty)
        #expect(Stub.requests(voiceID).isEmpty)
        #expect(model.lastBriefed == nil)
    }

    /// Test voice: one sentence in the chosen language, through the same voice, without writing a briefing.
    @Test func testVoiceSaysOneSentence() async {
        defer { cleanUp() }
        let voice = FakeVoice()
        let claude = FakeClaude("x")
        let (model, _) = model(key: nil, claude: claude, voice: voice, language: "ca")
        model.testVoice()
        #expect(await until { voice.said.count == 1 })
        #expect(voice.said.first?.text == "Així sonarà el teu resum de VibeSwitcher.")
        #expect(voice.said.first?.language == "ca")
        #expect(claude.prompts.isEmpty)
        #expect(model.briefing == nil)
        // A language without a sentence of its own hears the English one, as English.
        let (other, _) = self.model(key: nil, claude: claude, voice: voice, language: "sw")
        other.testVoice()
        #expect(await until { voice.said.count == 2 })
        #expect(voice.said.last?.language == "en")
    }

    /// The button says what it does to VoiceOver in every state.
    @Test func theButtonIsBriefMe() {
        #expect(BriefMeButton.state(.writing) == "Writing the briefing")
        #expect(BriefMeButton.state(.speaking) == "Reading it aloud")
        #expect(BriefMeButton.help(.speaking).contains("Stop"))
    }
}
