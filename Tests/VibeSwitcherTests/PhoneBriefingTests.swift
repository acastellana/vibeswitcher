import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Brief me on the phone: `POST /api/briefing` starts one and `GET /api/briefing` returns its text and audio, through
/// the same gate as the other phone routes (this Mac's tailnet name, its account, a paired device's token). Reading a
/// briefing types nothing, so the screen lock doesn't apply; starting one is throttled per source; the ElevenLabs key
/// is never in what the phone gets. Phone Access is served in memory only (`serveForTests`: nothing listens, no
/// Tailscale), ElevenLabs is `BriefingButtonTests.Stub` (no network), Claude a fake, the key made up.
@MainActor
struct PhoneBriefingTests {
    nonisolated static let host = "mac.tail1234.ts.net"
    nonisolated static let login = "me@example.com"
    typealias Stub = BriefingButtonTests.Stub

    let access: PhoneAccess
    let suite = "phone-briefing-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let voiceID = "phone-voice-\(UUID().uuidString.prefix(8))"

    init() {
        access = PhoneAccess(store: SessionStore())
        access.serveForTests(.init(dnsName: Self.host, login: Self.login, httpsAvailable: true))
        defaults = UserDefaults(suiteName: suite)!
    }

    struct Answer {
        var status: Int
        var body: Data
        var json: [String: Any] { ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:] }
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    /// A request as `tailscale serve` relays it (its Host, its account, the device's address), parsed as the server would.
    func send(_ method: String, _ path: String, token: String? = nil, body: String = "", from address: String = "100.64.0.7",
              host: String = "\(host):\(PhoneAccess.httpsPort)", login: String = login) -> Answer {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nTailscale-User-Login: \(login)\r\nX-Forwarded-For: \(address)\r\n"
        if let token { head += "Authorization: Bearer \(token)\r\n" }
        head += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let request) = HTTPParser.parse(Data(head.utf8)) else {
            Issue.record("unparsable request")
            return Answer(status: 0, body: Data())
        }
        var answer: Answer?
        access.handleForTests(request) { answer = Answer(status: $0.status, body: $0.body) }
        return answer ?? Answer(status: -1, body: Data())
    }

    /// Pairs a phone the way the phone does (a code shown on the Mac, then `/api/pair`); its token.
    func pair() throws -> String {
        access.startPairing()
        let code = try #require(access.pairing?.code)
        let answer = send("POST", "/api/pair", body: #"{"code":"\#(code)","name":"Test phone"}"#)
        #expect(answer.status == 200)
        return try #require(answer.json["token"] as? String)
    }

    /// A stand-in for `PhoneBriefer`: counts presses and finishes each when told.
    final class FakeBriefer {
        var pending: [(PhoneBriefing) -> Void] = []
        var presses = 0
        func brief(_ done: @escaping (PhoneBriefing) -> Void) {
            presses += 1
            pending.append(done)
        }
        func finish(_ briefing: PhoneBriefing = .init(text: "Two tasks landed.", language: "en", at: 1000, voice: "mac",
                                                       audio: Data("m4a".utf8), audioType: "audio/mp4")) {
            guard !pending.isEmpty else { return }
            pending.removeFirst()(briefing)
        }
    }

    func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(condition())
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }

    // MARK: - The gate

    @Test func anUnpairedDeviceGetsNoBriefing() throws {
        let fake = FakeBriefer()
        access.brief = fake.brief
        let token = try pair()
        #expect(send("POST", "/api/briefing").status == 401)
        #expect(send("POST", "/api/briefing", token: "not-a-paired-token").status == 401)
        #expect(send("GET", "/api/briefing", token: "not-a-paired-token").status == 401)
        // The other routes' Host and account rules: another name (DNS rebinding) or another account gets nothing.
        #expect(send("POST", "/api/briefing", token: token, host: "evil.example:\(PhoneAccess.httpsPort)").status == 421)
        #expect(send("POST", "/api/briefing", token: token, host: "127.0.0.1:\(PhoneAccess.port)").status == 421)
        #expect(send("POST", "/api/briefing", token: token, login: "someone@else.com").status == 403)
        #expect(fake.presses == 0)
        // An unpaired phone (removed on the Mac) is refused too, its token no longer good.
        #expect(send("POST", "/api/unpair", token: token).status == 200)
        #expect(send("POST", "/api/briefing", token: token).status == 401)
        #expect(fake.presses == 0)
    }

    @Test func aPairedPhoneStartsOneAndGetsItsTextAndAudio() throws {
        let fake = FakeBriefer()
        access.brief = fake.brief
        let token = try pair()
        #expect(send("GET", "/api/briefing", token: token).status == 404)
        let start = send("POST", "/api/briefing", token: token)
        #expect(start.status == 200)
        #expect(start.json["writing"] as? Bool == true)
        #expect(fake.presses == 1)
        // While it's written: asking says so, and pressing again doesn't start a second.
        #expect(send("GET", "/api/briefing", token: token).json["writing"] as? Bool == true)
        #expect(send("POST", "/api/briefing", token: token).json["writing"] as? Bool == true)
        #expect(fake.presses == 1)
        fake.finish()
        let done = send("GET", "/api/briefing", token: token)
        #expect(done.status == 200)
        #expect(done.json["text"] as? String == "Two tasks landed.")
        #expect(done.json["voice"] as? String == "mac")
        #expect(done.json["audioType"] as? String == "audio/mp4")
        #expect(done.json["audio"] as? String == Data("m4a".utf8).base64EncodedString())
        #expect(done.json["writing"] == nil)
        // A later press writes a fresh one.
        #expect(send("POST", "/api/briefing", token: token).json["writing"] as? Bool == true)
        #expect(fake.presses == 2)
    }

    @Test func withoutABrieferTheRouteSaysSo() throws {
        let token = try pair()
        #expect(send("POST", "/api/briefing", token: token).status == 503)
    }

    /// Decided: the lock doesn't apply. A briefing is read, like the list and the screens, and types nothing; the phone
    /// is where it's wanted while away from the Mac, which is when it's locked. The replies switch doesn't apply either.
    @Test func aLockedMacStillBriefsAndTheLockIsntAsked() throws {
        let fake = FakeBriefer()
        access.brief = fake.brief
        var asked = 0
        access.screenLocked = { asked += 1; return true }
        access.inputAllowed = false
        let token = try pair()
        #expect(send("POST", "/api/briefing", token: token).status == 200)
        fake.finish()
        #expect(send("GET", "/api/briefing", token: token).status == 200)
        #expect(fake.presses == 1)
        #expect(asked == 0)
        // Where the lock does apply, typing, the same check refuses.
        #expect(access.windowInputVerdict(device: "phone", tty: "ttys999", sid: "s", agent: (pid: 1, startedAt: .distantPast)) == .locked)
    }

    @Test func startingBriefingsIsThrottledPerSource() throws {
        let fake = FakeBriefer()
        access.brief = fake.brief
        let token = try pair()
        for _ in 0..<6 {
            #expect(send("POST", "/api/briefing", token: token, from: "100.64.0.7").status == 200)
            fake.finish()
        }
        let throttled = send("POST", "/api/briefing", token: token, from: "100.64.0.7")
        #expect(throttled.status == 429)
        #expect(fake.presses == 6)
        // What's written stays readable, and another source isn't held back by this one.
        #expect(send("GET", "/api/briefing", token: token, from: "100.64.0.7").status == 200)
        #expect(send("POST", "/api/briefing", token: token, from: "100.64.0.9").status == 200)
        #expect(fake.presses == 7)
    }

    // MARK: - The key never reaches the phone

    func briefer(key: String?, claude: BriefingButtonTests.FakeClaude, rendered: Data? = Data("mac-m4a".utf8)) -> PhoneBriefer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let client = ElevenLabs(voice: voiceID, session: URLSession(configuration: configuration))
        return PhoneBriefer(snapshot: { .init(boards: [:], sessions: []) }, language: { BriefingLanguage.named("es")! },
                            keyStore: AppProof.MemorySecret(key), generate: { claude.generate($0) }, client: client,
                            render: { _, _ in rendered }, defaults: defaults, now: { 5000 })
    }

    func briefed(_ briefer: PhoneBriefer) async throws -> Answer {
        access.brief = briefer.brief
        let token = try pair()
        #expect(send("POST", "/api/briefing", token: token).status == 200)
        try await waitFor { send("GET", "/api/briefing", token: token).json["writing"] == nil }
        return send("GET", "/api/briefing", token: token)
    }

    @Test func withAKeyElevenLabsAudioIsSentButNeverTheKey() async throws {
        defer { cleanUp() }
        let key = BriefingButtonTests.key
        Stub.expect(voice: voiceID, body: Data("ID3-phone-mp3".utf8))
        let claude = BriefingButtonTests.FakeClaude("Dos tareas han terminado y una pregunta te espera.")
        let answer = try await briefed(briefer(key: key, claude: claude))
        #expect(answer.status == 200)
        #expect(answer.json["text"] as? String == "Dos tareas han terminado y una pregunta te espera.")
        #expect(answer.json["language"] as? String == "es")
        #expect(answer.json["voice"] as? String == "elevenlabs")
        #expect(answer.json["audioType"] as? String == "audio/mpeg")
        #expect(answer.json["audio"] as? String == Data("ID3-phone-mp3".utf8).base64EncodedString())
        #expect(!answer.text.contains(key))
        #expect(!answer.text.contains(Data(key.utf8).base64EncodedString()))
        #expect(Set(answer.json.keys) == ["text", "language", "at", "voice", "audio", "audioType"])
        // ElevenLabs had it, in its header only (the stub, not the network).
        let seen = Stub.requests(voiceID)
        #expect(seen.count == 1)
        #expect(seen.first?.request.value(forHTTPHeaderField: "xi-api-key") == key)
        // It counts as the last briefing for the Mac's button too.
        #expect(defaults.object(forKey: BriefingModel.lastKey) as? Double == 5000)
    }

    @Test func aRefusedKeyFallsBackToTheMacsVoiceStillWithoutTheKey() async throws {
        defer { cleanUp() }
        let key = BriefingButtonTests.key
        Stub.expect(voice: voiceID, status: 401, body: Data(#"{"detail":"invalid key \#(key)"}"#.utf8))
        let claude = BriefingButtonTests.FakeClaude("Todo tranquilo.")
        let answer = try await briefed(briefer(key: key, claude: claude))
        #expect(answer.json["voice"] as? String == "mac")
        #expect(answer.json["audioType"] as? String == "audio/mp4")
        #expect(answer.json["audio"] as? String == Data("mac-m4a".utf8).base64EncodedString())
        #expect(answer.json["notice"] as? String == ElevenLabs.Failure.status(401).notice)
        #expect(!answer.text.contains(key))
    }

    @Test func withoutAKeyTheMacsVoiceIsSentAndElevenLabsIsntAsked() async throws {
        defer { cleanUp() }
        let claude = BriefingButtonTests.FakeClaude(nil)   // Claude isn't there: the English template
        let answer = try await briefed(briefer(key: nil, claude: claude))
        #expect(answer.json["voice"] as? String == "mac")
        #expect(answer.json["language"] as? String == "en")
        #expect((answer.json["notice"] as? String)?.contains("template") == true)
        #expect(Stub.requests(voiceID).isEmpty)
        // No audio at all: the text alone, and a line saying so.
        let silent = await PhoneBriefer.voiced(BriefingText(text: "Quiet.", language: .english, byModel: true, at: 1, notice: nil),
                                               key: nil, client: ElevenLabs(voice: voiceID), render: { _, _ in nil })
        #expect(silent.audio == nil && silent.voice == nil)
        #expect(silent.json["audio"] == nil)
        #expect(silent.notice == "No audio could be made on the Mac, so here's the text.")
    }

    // MARK: - The Mac's voice to a file, and the page's policy

    /// The real renderer: the Mac's speech synthesizer (on the Mac, no network) to AAC in an MP4 container.
    @Test func theMacsVoiceRendersToAnM4AFile() async throws {
        let data = try #require(await Task.detached { MacVoiceFile.render("Two tasks landed.", language: "en") }.value)
        #expect(data.count > 1000)
        #expect(String(decoding: data.dropFirst(4).prefix(4), as: UTF8.self) == "ftyp")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("vs-briefing-") }
        #expect(leftovers.isEmpty)
    }

    /// The page plays the briefing from a blob (fetched with the token in its header): media from the page's own
    /// origin and blobs only; the rest of the policy as it was.
    @Test func thePagesPolicyLetsItPlayABlobAndNothingMore() {
        let head = String(decoding: HTTPResponse.json([:]).serialized(), as: UTF8.self)
        let policy = head.components(separatedBy: "\r\n").filter { $0.hasPrefix("Content-Security-Policy: ") }
        #expect(policy == ["Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
                           + "media-src 'self' blob:; connect-src 'self'; worker-src 'self'; manifest-src 'self'; base-uri 'none'; "
                           + "form-action 'none'; frame-ancestors 'none'"])
    }
}
