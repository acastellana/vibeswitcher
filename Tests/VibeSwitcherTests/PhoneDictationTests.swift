import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// Dictation from the phone: `POST /api/dictation` takes the recording from a paired phone, through the same gate as
/// every phone route (this Mac's tailnet name, its account, a paired device's token), only with replies on, as audio,
/// within 2 minutes and `phoneMaxBytes`, a few a minute per source; the Mac transcribes it (here a fake: no network,
/// no key) and answers the text alone. The parser and the server let only that route, from a phone that sends a
/// token, past the usual 64 KB. Phone Access is served in memory only (`serveForTests`).
@MainActor
struct PhoneDictationTests {
    nonisolated static let host = "mac.tail1234.ts.net"
    nonisolated static let login = "me@example.com"

    let access: PhoneAccess

    init() {
        access = PhoneAccess(store: SessionStore())
        access.serveForTests(.init(dnsName: Self.host, login: Self.login, httpsAvailable: true))
    }

    struct Answer {
        var status: Int
        var body: Data
        var json: [String: Any] { ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:] }
        var error: String { json["error"] as? String ?? "" }
    }

    /// The transcriber's stand-in: what it was given, answered with `result` at once.
    final class FakeTranscriber {
        var given: [(audio: DictationAudio, sid: String?)] = []
        var result: Result<String, OpenAITranscription.Failure> = .success("run the tests on main")
        func transcribe(_ audio: DictationAudio, sid: String?, _ done: @escaping (Result<String, OpenAITranscription.Failure>) -> Void) {
            given.append((audio, sid))
            done(result)
        }
    }

    /// A request as `tailscale serve` relays it, parsed as the server parses it (with its body limit).
    func send(_ path: String, token: String?, body: Data = Data("recording".utf8), type: String = "audio/webm;codecs=opus",
              from address: String = "100.64.0.9") -> Answer {
        var head = "POST \(path) HTTP/1.1\r\nHost: \(Self.host):\(PhoneAccess.httpsPort)\r\nTailscale-User-Login: \(Self.login)\r\n"
        head += "X-Forwarded-For: \(address)\r\n"
        if let token { head += "Authorization: Bearer \(token)\r\n" }
        head += "Content-Type: \(type)\r\nContent-Length: \(body.count)\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        let devices = access.devices
        switch HTTPParser.parse(data, bodyLimit: { RemoteServer.bodyLimit(method: $0, path: $1, headers: $2, devices: devices) }) {
        case .complete(let request):
            var answer: Answer?
            access.handleForTests(request) { answer = Answer(status: $0.status, body: $0.body) }
            return answer ?? Answer(status: -1, body: Data())
        case .tooLarge: return Answer(status: 413, body: Data())
        default:
            Issue.record("unparsable request")
            return Answer(status: 0, body: Data())
        }
    }

    /// Pairs a phone, replies on: its token, and what undoes both (the devices file is shared by the suites of a run).
    func pair() throws -> (token: String, done: () -> Void) {
        access.startPairing()
        let code = try #require(access.pairing?.code)
        var head = "POST /api/pair HTTP/1.1\r\nHost: \(Self.host):\(PhoneAccess.httpsPort)\r\nTailscale-User-Login: \(Self.login)\r\n"
        let body = #"{"code":"\#(code)","name":"Dictation phone"}"#
        head += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let request) = HTTPParser.parse(Data(head.utf8)) else { throw CancellationError() }
        var token: String?
        access.handleForTests(request) { token = (try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any])?["token"] as? String }
        let paired = try #require(token)
        let wasAllowed = access.inputAllowed
        access.inputAllowed = true
        return (paired, { [access] in
            access.inputAllowed = wasAllowed
            if let device = access.devices.first(where: { $0.tokenHash == RemoteAuth.hash(paired) }) { access.remove(device) }
        })
    }

    @Test func aPairedPhoneGetsTheTextOfItsRecording() throws {
        let fake = FakeTranscriber()
        access.transcribe = fake.transcribe
        let (token, done) = try pair()
        defer { done() }
        let answer = send("/api/dictation?duration=4.2&sid=gone-session", token: token)
        #expect(answer.status == 200)
        #expect(answer.json as NSDictionary == ["text": "run the tests on main"] as NSDictionary)
        let given = try #require(fake.given.first)
        #expect(given.audio == DictationAudio(data: Data("recording".utf8), mimeType: "audio/webm", duration: 4.2))
        // A session that isn't on the Mac gives no words.
        #expect(given.sid == nil)
        // The audit names the phone and the length, never the text.
        #expect(access.recentActivity.contains { $0.contains("dictation for Dictation phone (4 s)") })
        #expect(!access.recentActivity.contains { $0.contains("run the tests") })
    }

    @Test func anUnpairedPhoneGetsNothingTranscribed() throws {
        let fake = FakeTranscriber()
        access.transcribe = fake.transcribe
        let (_, done) = try pair()
        defer { done() }
        #expect(send("/api/dictation?duration=2", token: nil).status == 401)
        #expect(send("/api/dictation?duration=2", token: "not-a-paired-token").status == 401)
        #expect(fake.given.isEmpty)
    }

    @Test func theLimitsAreEnforced() throws {
        let fake = FakeTranscriber()
        access.transcribe = fake.transcribe
        let (token, done) = try pair()
        defer { done() }
        #expect(send("/api/dictation?duration=2", token: token, type: "application/json").status == 415)
        #expect(send("/api/dictation?duration=2", token: token, type: "text/plain").status == 415)
        #expect(send("/api/dictation", token: token).status == 400)
        #expect(send("/api/dictation?duration=nan", token: token).status == 400)
        #expect(send("/api/dictation?duration=0", token: token).status == 400)
        #expect(send("/api/dictation?duration=2", token: token, body: Data()).status == 400)
        #expect(send("/api/dictation?duration=150", token: token).status == 413)
        // Bigger than a phone's 2 minutes: refused as it's read, before anything else.
        #expect(send("/api/dictation?duration=60", token: token, body: Data(count: DictationLimits.phoneMaxBytes + 1)).status == 413)
        #expect(fake.given.isEmpty)
        // At the limit it goes.
        #expect(send("/api/dictation?duration=120", token: token, body: Data(count: DictationLimits.phoneMaxBytes)).status == 200)
        #expect(fake.given.count == 1)
    }

    @Test func repliesOffMeansNoDictation() throws {
        let fake = FakeTranscriber()
        access.transcribe = fake.transcribe
        let (token, done) = try pair()
        defer { done() }
        access.inputAllowed = false
        #expect(send("/api/dictation?duration=2", token: token).status == 403)
        #expect(fake.given.isEmpty)
    }

    @Test func withoutAKeyOnTheMacThePhoneIsTold() throws {
        let fake = FakeTranscriber()
        access.transcribe = fake.transcribe
        let (token, done) = try pair()
        defer { done() }
        access.dictationReady = { false }
        let refused = send("/api/dictation?duration=2", token: token)
        #expect(refused.status == 503)
        #expect(refused.error.contains("OpenAI API key on the Mac"))
        #expect(fake.given.isEmpty)
        // Not known yet: tried, and the Mac says so if there's none.
        access.dictationReady = { nil }
        fake.result = .failure(.noKey)
        #expect(send("/api/dictation?duration=2", token: token).error.contains("OpenAI API key on the Mac"))
        fake.result = .failure(.status(401))
        let failed = send("/api/dictation?duration=2", token: token)
        #expect(failed.status == 502)
        #expect(failed.error == OpenAITranscription.Failure.status(401).notice)
    }

    @Test func withoutATranscriberTheRouteSaysSo() throws {
        let (token, done) = try pair()
        defer { done() }
        #expect(send("/api/dictation?duration=2", token: token).status == 503)
    }

    @Test func oneSourceGetsAFewAMinute() throws {
        let fake = FakeTranscriber()
        access.transcribe = fake.transcribe
        let (token, done) = try pair()
        defer { done() }
        for _ in 0..<20 { #expect(send("/api/dictation?duration=1", token: token, from: "100.64.0.20").status == 200) }
        #expect(send("/api/dictation?duration=1", token: token, from: "100.64.0.20").status == 429)
        // Another device isn't held up by it.
        #expect(send("/api/dictation?duration=1", token: token, from: "100.64.0.21").status == 200)
        #expect(fake.given.count == 21)
    }

    /// The phone's state says whether its mic button can be used.
    @Test func theStateSaysWhetherDictationIsReady() throws {
        let (token, done) = try pair()
        defer { done() }
        func state() -> String? {
            let head = "GET /api/state HTTP/1.1\r\nHost: \(Self.host):\(PhoneAccess.httpsPort)\r\nTailscale-User-Login: \(Self.login)\r\nAuthorization: Bearer \(token)\r\n\r\n"
            guard case .complete(let request) = HTTPParser.parse(Data(head.utf8)) else { return nil }
            var value: String?
            access.handleForTests(request) { value = (try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any])?["dictation"] as? String }
            return value
        }
        #expect(state() == "off")
        access.transcribe = FakeTranscriber().transcribe
        access.dictationReady = { true }
        #expect(state() == "on")
        access.dictationReady = { false }
        #expect(state() == "needsKey")
        access.dictationReady = { nil }
        #expect(state() == "unknown")
    }

    /// A phone paired with `token` from `login`.
    nonisolated static func device(token: String, login: String = login) -> PairedDevice {
        PairedDevice(id: "d", name: "Phone", tokenHash: RemoteAuth.hash(token), tailscaleLogin: login, pairedAt: Date())
    }

    /// Only a dictation from a paired phone (its token checked as the headers come in) may be bigger than 64 KB;
    /// everything else, a made-up token's dictation too, keeps the usual limit.
    @Test func onlyAPairedPhonesDictationGetsABigBody() {
        let devices = [Self.device(token: "good-token")]
        let paired = ["authorization": "Bearer good-token", "tailscale-user-login": Self.login]
        let limit = { (method: String, path: String, headers: [String: String]) in
            RemoteServer.bodyLimit(method: method, path: path, headers: headers, devices: devices)
        }
        #expect(limit("POST", "/api/dictation", paired) == DictationLimits.phoneMaxBytes)
        #expect(limit("POST", "/api/dictation", ["authorization": "Bearer junk", "tailscale-user-login": Self.login]) == 64 * 1024)
        #expect(limit("POST", "/api/dictation", ["authorization": "Bearer good-token", "tailscale-user-login": "other@example.com"]) == 64 * 1024)
        #expect(limit("POST", "/api/dictation", ["tailscale-user-login": Self.login]) == 64 * 1024)
        #expect(limit("POST", "/api/dictation", ["authorization": "Bearer good-token"]) == 64 * 1024)
        #expect(limit("POST", "/api/input", paired) == 64 * 1024)
        #expect(limit("GET", "/api/dictation", paired) == 64 * 1024)
        #expect(RemoteServer.bodyLimit(method: "POST", path: "/api/dictation", headers: paired, devices: []) == 64 * 1024)
        let head = { (path: String, token: String) in
            "POST \(path) HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nTailscale-User-Login: \(Self.login)\r\nContent-Length: \(100 * 1024)\r\n\r\n"
        }
        #expect(HTTPParser.parse(Data(head("/api/input", "good-token").utf8), bodyLimit: limit) == .tooLarge)
        #expect(HTTPParser.parse(Data(head("/api/dictation", "junk").utf8), bodyLimit: limit) == .tooLarge)
        #expect(HTTPParser.parse(Data(head("/api/dictation", "good-token").utf8), bodyLimit: limit) == .incomplete)
    }

    /// Through the real server on a loopback port: a 300 KB recording arrives whole at the handler, while a JSON route's
    /// 300 KB body is refused (413) before any handler runs.
    @Test func theServerTakesARecordingButNoOtherBigBody() async throws {
        let handled = Box<[HTTPRequest]>([])
        let server = RemoteServer { request, respond in
            handled.value.append(request)
            respond(.json(["ok": true]))
        }
        let port = try Self.freePort()
        try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, Error>) in
            server.start(port: port, onReady: { started.resume() }, onFailure: { started.resume(throwing: URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: $0])) })
        }
        defer { server.stop() }
        server.paired = { [Self.device(token: "t")] }
        let body = Data((0..<(300 * 1024)).map { UInt8($0 % 251) })
        func post(_ path: String, headers: [String: String]) async throws -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = "POST"
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (_, response) = try await session.upload(for: request, from: body)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        let phone = ["Authorization": "Bearer t", "Tailscale-User-Login": Self.login, "Content-Type": "audio/webm"]
        #expect(try await post("/api/dictation?duration=30", headers: phone) == 200)
        #expect(handled.value.count == 1)
        #expect(handled.value.first?.body == body)
        // A made-up token's recording is refused before its body, like any big body.
        var junk = phone
        junk["Authorization"] = "Bearer junk"
        let refusedJunk = try? await post("/api/dictation?duration=30", headers: junk)
        #expect(refusedJunk == 413 || refusedJunk == nil)
        #expect(handled.value.count == 1)
        // Refused as soon as its length is read: the phone hears 413, or the connection closes mid-upload.
        let refused = try? await post("/api/input", headers: phone)
        #expect(refused == 413 || refused == nil)
        #expect(handled.value.count == 1)
    }

    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// A loopback port nothing listens on now (the system picks it).
    static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        return UInt16(bigEndian: address.sin_port)
    }
}
