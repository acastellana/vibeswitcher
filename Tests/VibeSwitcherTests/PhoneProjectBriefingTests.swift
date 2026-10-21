import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The phone's Brief me card on one project: `POST /api/briefing` with `{"project": name}` asks for that led project's
/// briefing through the same endpoint and gate; a name the Mac doesn't lead now is refused (400) and nothing is
/// written; the state lists the led projects for the card's picker; the project's briefing keeps its own 'since' and
/// carries no key. In memory only, as `PhoneBriefingTests`.
extension PhoneBriefingTests {
    /// A stand-in for `PhoneBriefer`'s two kinds of press: every press, by project (nil: all), finished when told.
    final class FakeScopedBriefer {
        var pending: [(project: String?, done: (PhoneBriefing) -> Void)] = []
        var presses: [String?] = []
        func brief(_ done: @escaping (PhoneBriefing) -> Void) {
            presses.append(nil)
            pending.append((nil, done))
        }
        func brief(project: String, _ done: @escaping (PhoneBriefing) -> Void) {
            presses.append(project)
            pending.append((project, done))
        }
        func finish(_ text: String) {
            guard !pending.isEmpty else { return }
            let next = pending.removeFirst()
            next.done(PhoneBriefing(text: text, language: "en", at: 1000, project: next.project))
        }
    }

    func scoped() -> FakeScopedBriefer {
        let fake = FakeScopedBriefer()
        access.brief = fake.brief
        access.briefProject = fake.brief(project:_:)
        access.briefingProjects = { ["genswap", "vibeswitcher"] }
        return fake
    }

    @Test func aPhoneAsksForALedProjectByName() throws {
        let fake = scoped()
        let token = try pair()
        let state = send("GET", "/api/state", token: token)
        #expect(state.json["briefingProjects"] as? [String] == ["genswap", "vibeswitcher"])

        let start = send("POST", "/api/briefing", token: token, body: #"{"project":"genswap"}"#)
        #expect(start.status == 200)
        #expect(start.json["writing"] as? Bool == true)
        #expect(fake.presses == ["genswap"])
        // Asking again for the same one while it's written doesn't start a second.
        #expect(send("POST", "/api/briefing", token: token, body: #"{"project":"genswap"}"#).json["writing"] as? Bool == true)
        #expect(fake.presses == ["genswap"])
        fake.finish("Genswap: one question for you.")
        let done = send("GET", "/api/briefing", token: token)
        #expect(done.json["text"] as? String == "Genswap: one question for you.")
        #expect(done.json["project"] as? String == "genswap")

        // No project (or null): the global one, through the same endpoint.
        #expect(send("POST", "/api/briefing", token: token, body: "{}").status == 200)
        fake.finish("All quiet.")
        #expect(send("POST", "/api/briefing", token: token, body: #"{"project":null}"#).status == 200)
        #expect(fake.presses == ["genswap", nil, nil])
        fake.finish("All quiet.")
        #expect(send("GET", "/api/briefing", token: token).json["project"] == nil)
    }

    /// Switching while one is written starts the asked one; the earlier one, when it comes back, is dropped.
    @Test func switchingWhileItsWrittenStartsTheAskedOne() throws {
        let fake = scoped()
        let token = try pair()
        #expect(send("POST", "/api/briefing", token: token, body: "{}").status == 200)
        #expect(send("POST", "/api/briefing", token: token, body: #"{"project":"vibeswitcher"}"#).status == 200)
        #expect(fake.presses == [nil, "vibeswitcher"])
        fake.finish("The global one, late.")
        #expect(send("GET", "/api/briefing", token: token).json["writing"] as? Bool == true)
        fake.finish("Vibeswitcher: two landed.")
        let done = send("GET", "/api/briefing", token: token)
        #expect(done.json["text"] as? String == "Vibeswitcher: two landed.")
        #expect(done.json["project"] as? String == "vibeswitcher")
    }

    /// Only a name the Mac leads now: another name, a path, a non-string, an empty one are refused, nothing written.
    @Test func aNameTheMacDoesntLeadIsRefused() throws {
        let fake = scoped()
        let token = try pair()
        for body in [#"{"project":"films"}"#, #"{"project":"../../etc"}"#, #"{"project":"/Users/me/dev/genswap"}"#,
                     #"{"project":""}"#, #"{"project":7}"#, #"{"project":["genswap"]}"#] {
            let answer = send("POST", "/api/briefing", token: token, body: body)
            #expect(answer.status == 400, "\(body)")
            #expect(answer.json["error"] as? String == "No project lead runs in that project.")
        }
        #expect(fake.presses.isEmpty)
        #expect(send("GET", "/api/briefing", token: token).status == 404)
        // Without a project briefer, a led name gets the route's 503, as the global one without a briefer does.
        access.briefProject = nil
        #expect(send("POST", "/api/briefing", token: token, body: #"{"project":"genswap"}"#).status == 503)
        #expect(fake.presses.isEmpty)
    }

    /// The real briefer: the project's briefing is written from that project, moves only its own 'since', and the
    /// ElevenLabs key goes to ElevenLabs only.
    @Test func aPhonesProjectBriefingKeepsItsOwnSinceAndNoKey() async throws {
        defer { cleanUp() }
        let key = BriefingButtonTests.key
        Stub.expect(voice: voiceID, body: Data("ID3-project-mp3".utf8))
        let root = scratchRoot.appendingPathComponent("phone-project-\(UUID().uuidString)/genswap").path
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        var board = LeadBoard()
        board.questions = [LeadQuestion(text: "Which logo?", options: [])]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let claude = BriefingButtonTests.FakeClaude("Genswap está tranquilo; una pregunta te espera.")
        let briefer = PhoneBriefer(snapshot: { .init(boards: [root: board, "/elsewhere/vibeswitcher": LeadBoard()], sessions: []) },
                                   language: { BriefingLanguage.named("es")! }, keyStore: AppProof.MemorySecret(key),
                                   generate: { claude.generate($0) },
                                   client: ElevenLabs(voice: voiceID, session: URLSession(configuration: configuration)),
                                   render: { _, _ in nil }, defaults: defaults, now: { 5000 })
        #expect(briefer.projects() == ["genswap", "vibeswitcher"])
        access.brief = briefer.brief
        access.briefProject = briefer.brief(project:_:)
        access.briefingProjects = briefer.projects
        defaults.set(1234.0, forKey: BriefingModel.lastKey)
        let token = try pair()

        #expect(send("POST", "/api/briefing", token: token, body: #"{"project":"genswap"}"#).status == 200)
        try await waitFor { send("GET", "/api/briefing", token: token).json["writing"] == nil }
        let answer = send("GET", "/api/briefing", token: token)
        #expect(answer.json["text"] as? String == "Genswap está tranquilo; una pregunta te espera.")
        #expect(answer.json["project"] as? String == "genswap")
        #expect(answer.json["voice"] as? String == "elevenlabs")
        #expect(!answer.text.contains(key))
        #expect(!answer.text.contains(Data(key.utf8).base64EncodedString()))
        #expect(Set(answer.json.keys) == ["text", "language", "at", "voice", "audio", "audioType", "project"])
        #expect(claude.prompts.count == 1)
        #expect(claude.prompts[0].contains("in the project genswap"))
        #expect(claude.prompts[0].contains("Question for the user: Which logo?"))
        // Its own stamp moved; the global one's didn't.
        #expect(defaults.object(forKey: BriefingModel.lastKey(.project(root: root))) as? Double == 5000)
        #expect(defaults.object(forKey: BriefingModel.lastKey) as? Double == 1234)
        #expect(Stub.requests(voiceID).first?.request.value(forHTTPHeaderField: "xi-api-key") == key)
    }
}
