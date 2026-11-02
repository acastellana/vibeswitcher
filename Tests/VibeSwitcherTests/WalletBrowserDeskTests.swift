import AppKit
import CryptoKit
import Foundation
import JavaScriptCore
import Testing
import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// Sign in browser wallet on the card: when it shows (never once the request may have reached the Wallet Manager, never
/// for a Safe), and the reverse (once used, Send to Wallet Manager is gone); and the "not picked up" hint.
struct WalletBrowserCardTests {
    static let hash = "0x" + String(repeating: "ab", count: 32)
    static let states: [WalletCardModel.State] = WalletCardModelTests.states + [
        .inBrowser, .sentFromBrowser(txHash: hash, explorerURL: nil), .rejectedInWallet, .browserNoAnswer,
    ]

    static func card(_ state: WalletCardModel.State, signable: Bool = true, wallet: WalletCardModel.Wallet? = nil) -> WalletCardModel {
        WalletCardModel(id: "r", workspace: "example", from: "0x00000000000000000000000000000000000000aa", wallet: wallet,
                        to: "0x0000000000000000000000000000000000000001", chainID: 42_424_242, asset: "GEN", amount: "1.25",
                        reason: "a test", requestedBy: "example-agent", state: state, browserSignable: signable)
    }

    /// Only while the request never reached the Wallet Manager: waiting for you, unreachable, not sent.
    @Test func browserShowsOnlyWhileTheRequestNeverReachedTheWalletManager() {
        for state in Self.states {
            let never: Bool
            switch state {
            case .waiting, .unreachable, .notSent: never = true
            default: never = false
            }
            #expect(Self.card(state).actions.contains(.browser) == never, "\(state)")
        }
        #expect(Self.card(.waiting).actions == [.send, .browser, .discard])
        #expect(Self.card(.unreachable(message: nil)).actions == [.retry, .browser, .discard])
        #expect(Self.card(.notSent(reason: "refused")).actions == [.browser, .discard])
        #expect(WalletCardModel.Action.browser.title == "Sign in browser wallet")
        #expect(WalletCardModel.browserNote == "Skips the Wallet Manager's checks: read the wallet's own popup")
    }

    @Test func neverForASafe() {
        for state in Self.states { #expect(!Self.card(state, wallet: .safe).actions.contains(.browser), "\(state)") }
        #expect(Self.card(.waiting, wallet: .hardware).actions.contains(.browser))
    }

    /// A wallet id in `from` names a wallet only the Wallet Manager knows: the browser can't sign for it.
    @Test func neverForAWalletIdFrom() {
        for state in Self.states { #expect(!Self.card(state, signable: false).actions.contains(.browser), "\(state)") }
    }

    /// Once used, Send to Wallet Manager (and Retry) is gone for that request.
    @Test func onceUsedSendIsGone() {
        for state in [WalletCardModel.State.inBrowser, .sentFromBrowser(txHash: Self.hash, explorerURL: nil), .rejectedInWallet, .browserNoAnswer] {
            let actions = Self.card(state).actions
            #expect(!actions.contains(.send) && !actions.contains(.retry) && !actions.contains(.browser), "\(state)")
        }
        #expect(WalletCardModel.title(.sentFromBrowser(txHash: Self.hash, explorerURL: nil)) == "Sent from browser wallet")
        #expect(WalletCardModel.title(.rejectedInWallet) == "Rejected in the wallet")
    }

    /// No Wallet Manager set up (`setupNeeded`): Send and Retry give way to Open Settings; the browser wallet stays where
    /// today's rules offer it; a wallet id says it needs the Wallet Manager. Once set up, the card is as before.
    @Test func withNoWalletManagerSendGivesWayToSettings() {
        var card = Self.card(.waiting)
        card.setupNeeded = WalletCardModel.noPeerNote
        #expect(card.actions == [.browser, .discard, .settings])
        #expect(card.detail == "Nothing has left this Mac. Sign it in your browser wallet, or discard it.")
        #expect(card.text.contains("No Wallet Manager chosen: choose its Mac in Settings › Wallet"))
        #expect(WalletCardModel.Action.settings.title == "Open Settings")
        var id = Self.card(.waiting, signable: false)
        id.setupNeeded = WalletCardModel.noPeerNote
        #expect(id.actions == [.discard, .settings])
        #expect(id.detail.contains("It needs the Wallet Manager: a browser wallet can't use a wallet id."))
        var unreachable = Self.card(.unreachable(message: nil))
        unreachable.setupNeeded = WalletCardModel.noPeerNote
        #expect(unreachable.actions == [.browser, .discard, .settings])
        // Never Send, nor Open Settings, once a request went one way or the other.
        for state in Self.states {
            var gone = Self.card(state)
            gone.setupNeeded = WalletCardModel.noPeerNote
            #expect(!gone.actions.contains(.send) && !gone.actions.contains(.retry), "\(state)")
            switch state {
            case .waiting, .unreachable, .unsure: #expect(gone.actions.contains(.settings), "\(state)")
            default: #expect(!gone.actions.contains(.settings), "\(state)")
            }
        }
        // Set up: as before.
        card.setupNeeded = nil
        #expect(card.actions == [.send, .browser, .discard])
        #expect(card.detail == WalletCardModel.detail(.waiting, wallet: nil))
    }

    @Test func aSentCardNotPickedUpAsksWhetherTheWalletManagerRuns() {
        var card = Self.card(.sent)
        #expect(!card.detail.contains("Is the Wallet Manager running?"))
        card.notPickedUp = true
        #expect(card.detail.hasSuffix("Delivered to the Wallet Manager's Mac, but it hasn't picked it up yet. Is the Wallet Manager running?"))
        card.state = .received
        #expect(!card.detail.contains("Is the Wallet Manager running?"))
    }
}

/// The local page (`WalletSignServer`) and the desk around it, with a fake page client (URLSession to 127.0.0.1, never a
/// browser or wallet): the hash or rejection comes back to the card and the asking session; anything else is refused.
@MainActor
@Suite(.serialized)
struct WalletBrowserDeskTests {
    let temp = Scratch()
    static let hash = "0xABCDEF" + String(repeating: "01", count: 29)

    final class Opened: @unchecked Sendable {
        var urls: [URL] = []
    }

    struct Setup {
        let base: WalletDeskTests.Setup
        let opened: Opened
        var desk: WalletDesk { base.desk }
    }

    /// The Wallet Manager peer Settings › Wallet names, changed as a test goes (empty: none chosen).
    final class Peer: @unchecked Sendable {
        var id: String
        init(_ id: String = WalletFakePassage.peer) { self.id = id }
    }

    func setup(clock: WalletDeskTests.Clock = WalletDeskTests.Clock(), peer: Peer = Peer()) throws -> Setup {
        let fake = try WalletFakePassage(temp)
        let asked = temp.url("asked")
        let store = WalletRequestStore(folder: temp.url("requests"))
        let desk = WalletDesk(folder: asked, store: store, inbox: fake.inbox,
                              config: { WalletDesk.Config(passage: fake.executable, peer: peer.id) }, now: { clock.now }, log: { _ in })
        desk.sessionNames = { WalletDeskTests.names() }
        desk.verifyStamps = WalletTestStamps.verify
        desk.sealMessage = WalletTestStamps.sealMessage
        desk.verifyMessages = WalletTestStamps.verifyMessages
        desk.findPassage = { nil }
        let told = WalletDeskTests.Told()
        desk.deliver = { session, text, then in told.messages.append((session, text)); then(.delivered) }
        let opened = Opened()
        desk.openBrowser = { opened.urls.append($0) }
        return Setup(base: .init(fake: fake, desk: desk, asked: asked, store: store, told: told), opened: opened)
    }

    /// A request from an 0x address (the browser can sign for it).
    static func request(_ number: Int = 1, session: UUID = WalletDeskTests.session) -> WalletRequest {
        var request = WalletDeskTests.request(number, session: session)
        request.from = "0x00000000000000000000000000000000000000aa"
        return request
    }

    func refreshed(_ desk: WalletDesk) async {
        var done = false
        desk.refresh { done = true }
        _ = await until { done }
    }

    func acted(_ desk: WalletDesk, _ action: WalletCardModel.Action, _ id: String) async {
        var done = false
        desk.act(action, on: id) { done = true }
        _ = await until { done }
    }

    /// The fake page client: one request to the local page, as the browser would send it. Nil when nothing listens.
    nonisolated static func fetch(_ url: URL, method: String = "GET", body: String? = nil, origin: String? = nil,
                                  contentType: String = "application/json") async -> (status: Int, body: String, headers: [String: String])? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        return (http.statusCode, String(decoding: data, as: UTF8.self), headers)
    }

    static func origin(_ url: URL) -> String { "http://127.0.0.1:\(url.port ?? 0)" }
    static func result(_ url: URL) -> URL { url.appendingPathComponent("result") }

    /// Opens the newest request's page: its card is then waiting for the browser wallet, and Send is gone.
    func open(_ s: Setup, _ request: WalletRequest) async throws -> URL {
        try WalletAsk.file(request, in: s.base.asked)
        await refreshed(s.desk)
        #expect(s.desk.cards.first?.actions == [.send, .browser, .discard])
        await acted(s.desk, .browser, request.id)
        #expect(await until { s.opened.urls.count == 1 })
        return try #require(s.opened.urls.first)
    }

    @Test func theBrowserWalletsHashComesBackToTheCardAndTheSession() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let request = Self.request()
        let url = try await open(s, request)
        // 127.0.0.1, a port of its own, a 256-bit token in the path.
        #expect(url.scheme == "http" && url.host == "127.0.0.1" && (url.port ?? 0) > 0)
        let token = url.pathComponents.dropFirst().first ?? ""
        #expect(token.count == 43 && url.absoluteString == "http://127.0.0.1:\(url.port!)/\(token)/")
        #expect(s.desk.cards.first?.state == .inBrowser)
        #expect(s.desk.cards.first?.actions == [.discard])
        // Send doesn't go now.
        await acted(s.desk, .send, request.id)
        #expect(s.base.fake.sends.isEmpty)

        // The page: the request, the app's own script, a strict CSP.
        let page = try #require(await Self.fetch(url))
        #expect(page.status == 200)
        #expect(page.headers["content-type"] == "text/html; charset=utf-8")
        let csp = try #require(page.headers["content-security-policy"])
        #expect(csp.hasPrefix("default-src 'none'; script-src 'sha256-") && csp.contains("connect-src 'self'"))
        #expect(!csp.contains("unsafe") && !csp.contains("http"))
        #expect(page.body.contains(request.id) && page.body.contains("0x00000000000000000000000000000000000000aa"))
        #expect(page.body.contains("window.ethereum") && page.body.contains("eth_sendTransaction"))
        #expect(!page.body.contains("src=") && !page.body.contains("href="))

        // The page posts the hash: taken once.
        let posted = try #require(await Self.fetch(Self.result(url), method: "POST", body: #"{"txHash":"\#(Self.hash)"}"#, origin: Self.origin(url)))
        #expect(posted.status == 204)
        #expect(await until { s.base.told.messages.count == 1 })
        let hash = Self.hash.lowercased()
        _ = await until { s.desk.cards.first?.state != .inBrowser }
        #expect(s.desk.cards.first?.state == .sentFromBrowser(txHash: hash, explorerURL: URL(string: "https://scan.chain.genlayer.com/tx/" + hash)))
        #expect(s.desk.cards.first?.actions == [])
        let told = try #require(s.base.told.messages.first)
        #expect(told.session == WalletDeskTests.session.uuidString.lowercased())
        #expect(told.text.contains(request.id) && told.text.contains(hash) && told.text.contains("browser wallet"))
        // The page is no longer served, and the answer stands.
        let after = await Self.fetch(url)
        #expect(after == nil || after?.status == 410)
        await refreshed(s.desk)
        #expect(s.desk.cards.first?.state == .sentFromBrowser(txHash: hash, explorerURL: URL(string: "https://scan.chain.genlayer.com/tx/" + hash)))
        await acted(s.desk, .send, request.id)
        #expect(s.base.fake.sends.isEmpty)
    }

    @Test func aRejectionInTheWalletComesBack() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let request = Self.request()
        let url = try await open(s, request)
        let posted = try #require(await Self.fetch(Self.result(url), method: "POST", body: #"{"rejected":true}"#, origin: Self.origin(url)))
        #expect(posted.status == 204)
        #expect(await until { s.base.told.messages.count == 1 })
        _ = await until { s.desk.cards.first?.state != .inBrowser }
        #expect(s.desk.cards.first?.state == .rejectedInWallet)
        #expect(s.desk.cards.first?.actions == [.discard])
        #expect(s.base.told.messages[0].text.contains("rejected it in their browser wallet"))
        await acted(s.desk, .send, request.id)
        #expect(s.base.fake.sends.isEmpty)
    }

    /// Another origin, another token, a body that isn't exactly a hash or a rejection: refused, and the page still waits.
    @Test func anythingElsePostedIsRefused() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let request = Self.request()
        let url = try await open(s, request)
        let origin = Self.origin(url)
        let wrongToken = URL(string: "http://127.0.0.1:\(url.port!)/\(String(repeating: "A", count: 43))/result")!
        let tries: [(URL, String, String?, String, Int)] = [
            (Self.result(url), #"{"txHash":"\#(Self.hash)"}"#, "http://localhost:\(url.port!)", "application/json", 403),
            (Self.result(url), #"{"txHash":"\#(Self.hash)"}"#, nil, "application/json", 403),
            (Self.result(url), #"{"txHash":"\#(Self.hash)"}"#, origin, "text/plain", 415),
            (wrongToken, #"{"txHash":"\#(Self.hash)"}"#, origin, "application/json", 404),
            (Self.result(url), #"{"txHash":"0x1234"}"#, origin, "application/json", 400),
            (Self.result(url), #"{"txHash":"\#(Self.hash)","rejected":true}"#, origin, "application/json", 400),
            (Self.result(url), #"{"rejected":false}"#, origin, "application/json", 400),
            (Self.result(url), String(repeating: " ", count: 2000), origin, "application/json", 413),
        ]
        for (target, body, from, type, status) in tries {
            let reply = await Self.fetch(target, method: "POST", body: body, origin: from, contentType: type)
            #expect(reply?.status == status, "\(body.prefix(60)) from \(from ?? "no origin") as \(type)")
        }
        #expect((await Self.fetch(wrongToken.deletingLastPathComponent()))?.status == 404)
        await refreshed(s.desk)
        #expect(s.desk.cards.first?.state == .inBrowser)
        #expect(s.base.told.messages.isEmpty)
        // The real answer is still taken.
        #expect((await Self.fetch(Self.result(url), method: "POST", body: #"{"rejected":true}"#, origin: origin))?.status == 204)
        #expect(await until { s.base.told.messages.count == 1 })
    }

    /// A page under another name that resolves to 127.0.0.1 (DNS rebinding) sends its own Host: refused.
    @Test func anotherHostIsRefused() {
        let page = Data("page".utf8)
        func reply(_ method: String, _ path: String, host: String, origin: String? = nil, body: String = "", answered: Bool = false) -> Int {
            let raw = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nContent-Type: application/json\r\n"
                + (origin.map { "Origin: \($0)\r\n" } ?? "") + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
            guard case .complete(let request) = HTTPParser.parse(Data(raw.utf8)) else { return 0 }
            return WalletSignServer.reply(to: request, token: "tok", port: 4000, page: page, answered: answered).status
        }
        #expect(reply("GET", "/tok/", host: "127.0.0.1:4000") == 200)
        #expect(reply("GET", "/tok/", host: "evil.example:4000") == 421)
        #expect(reply("GET", "/tok/", host: "localhost:4000") == 421)
        #expect(reply("GET", "/tok/", host: "127.0.0.1:4001") == 421)
        #expect(reply("GET", "/tok", host: "127.0.0.1:4000") == 404)
        #expect(reply("GET", "/tok/x", host: "127.0.0.1:4000") == 404)
        #expect(reply("GET", "/tok/", host: "127.0.0.1:4000", answered: true) == 410)
        #expect(reply("GET", "/tok/result", host: "127.0.0.1:4000") == 404)
        #expect(reply("POST", "/tok/result", host: "127.0.0.1:4000", origin: "http://127.0.0.1:4000", body: #"{"rejected":true}"#) == 204)
        #expect(reply("POST", "/tok/result", host: "127.0.0.1:4000", origin: "http://127.0.0.1:4000", body: #"{"rejected":true}"#, answered: true) == 410)
    }

    /// No answer in 15 minutes (the desk's clock): the page stops, the card says so, the session hears it, and it can't
    /// be sent to the Wallet Manager after all.
    @Test func noAnswerInFifteenMinutesStopsThePage() async throws {
        let clock = WalletDeskTests.Clock()
        let s = try setup(clock: clock)
        defer { s.desk.close() }
        let request = Self.request()
        let url = try await open(s, request)
        clock.now = clock.now.addingTimeInterval(WalletBrowser.pageLifetime - 1)
        await refreshed(s.desk)
        #expect(s.desk.cards.first?.state == .inBrowser)
        #expect((await Self.fetch(url))?.status == 200)
        clock.now = clock.now.addingTimeInterval(1)
        await refreshed(s.desk)
        #expect(s.desk.cards.first?.state == .browserNoAnswer)
        #expect(s.desk.cards.first?.actions == [.discard])
        #expect(await until { s.base.told.messages.count == 1 })
        #expect(s.base.told.messages[0].text.contains("no answer came back"))
        // Stopped: nothing served, nothing taken.
        let late = await Self.fetch(Self.result(url), method: "POST", body: #"{"txHash":"\#(Self.hash)"}"#, origin: Self.origin(url))
        #expect(late == nil || late?.status == 410)
        await refreshed(s.desk)
        #expect(s.desk.cards.first?.state == .browserNoAnswer)
        #expect(s.base.told.messages.count == 1)
        await acted(s.desk, .send, request.id)
        #expect(s.base.fake.sends.isEmpty)
    }

    /// wallet-request-fallback:F3: an answer the page posts in the same instant as the cutoff (taken by the page, which
    /// told it so, while the desk was stopping it) isn't dropped: its hash is recorded and the session hears it.
    @Test func anAnswerAtTheCutoffIsntDropped() async throws {
        let clock = WalletDeskTests.Clock()
        let s = try setup(clock: clock)
        defer { s.desk.close() }
        let request = Self.request()
        let url = try await open(s, request)
        clock.now = clock.now.addingTimeInterval(WalletBrowser.pageLifetime)
        // The desk's look at the cutoff starts, and waits there while the page's answer is taken.
        clock.hold()
        var looked = false
        s.desk.refresh { looked = true }
        #expect(await until { clock.held })
        let posted = await Self.fetch(Self.result(url), method: "POST", body: #"{"txHash":"\#(Self.hash)"}"#, origin: Self.origin(url))
        #expect(posted?.status == 204)
        clock.release()
        #expect(await until { looked })
        // The answer was queued behind that look: the next look comes after it.
        await refreshed(s.desk)
        let hash = Self.hash.lowercased()
        #expect(s.base.told.messages.contains { $0.text.contains(hash) })
        #expect(s.desk.cards.first?.state == .sentFromBrowser(txHash: hash, explorerURL: URL(string: "https://scan.chain.genlayer.com/tx/" + hash)))
        #expect(WalletBrowser.mark(request.id, in: s.base.asked)?.txHash == hash)
    }

    /// Blind check: a filed request deleted while its page is open, whose answer comes in the same instant as the cutoff:
    /// the hash is still told, and the mark goes.
    @Test func anAnswerAtTheCutoffForADeletedRequestIsntDropped() async throws {
        let clock = WalletDeskTests.Clock()
        let s = try setup(clock: clock)
        defer { s.desk.close() }
        let request = Self.request()
        let url = try await open(s, request)
        try FileManager.default.removeItem(at: s.base.asked.appendingPathComponent("\(request.id).json"))
        clock.now = clock.now.addingTimeInterval(WalletBrowser.pageLifetime)
        clock.hold()
        var looked = false
        s.desk.refresh { looked = true }
        #expect(await until { clock.held })
        let posted = await Self.fetch(Self.result(url), method: "POST", body: #"{"txHash":"\#(Self.hash)"}"#, origin: Self.origin(url))
        #expect(posted?.status == 204)
        clock.release()
        #expect(await until { looked })
        await refreshed(s.desk)
        let hash = Self.hash.lowercased()
        #expect(s.base.told.messages.contains { $0.text.contains(hash) && $0.text.contains(request.id) })
        #expect(WalletBrowser.mark(request.id, in: s.base.asked) == nil)
    }

    /// Review finding 3: the page and the card come from the request as it was at the click. A filed request rewritten
    /// since shows the copy, with a warning, and the session hears what was signed, not the rewrite.
    @Test func aRequestRewrittenAfterTheClickShowsWhatWasSignedAndSaysSo() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let request = Self.request()
        let url = try await open(s, request)
        #expect(WalletBrowser.mark(request.id, in: s.base.asked)?.request == request)
        #expect(s.desk.cards.first?.fileChanged == false)
        var rewritten = request
        rewritten.amount = "9000000000000000000"
        rewritten.to = "0x00000000000000000000000000000000000000ff"
        try WalletAsk.file(rewritten, in: s.base.asked)
        await refreshed(s.desk)
        let card = try #require(s.desk.cards.first)
        #expect(card.state == .inBrowser)
        #expect(card.amount == "1.25" && card.to == request.to)
        #expect(card.fileChanged)
        #expect(card.text.contains(WalletCardModel.fileChangedNote))
        let posted = await Self.fetch(Self.result(url), method: "POST", body: #"{"txHash":"\#(Self.hash)"}"#, origin: Self.origin(url))
        #expect(posted?.status == 204)
        // The page hands its answer to the desk before it replies: a look after the reply comes after the answer.
        await refreshed(s.desk)
        let told = try #require(s.base.told.messages.first).text
        #expect(told.contains("1.25 GEN to \(request.to)") && !told.contains(rewritten.to))
        #expect(told.contains("changed after the user opened it"))
        #expect(s.desk.cards.first?.state != .inBrowser)
        #expect(s.desk.cards.first?.amount == "1.25" && s.desk.cards.first?.fileChanged == true)
        // Discard on a rewritten card still waiting for the browser wallet goes: the button acts on the copy it shows.
        let other = Self.request(2)
        try WalletAsk.file(other, in: s.base.asked)
        await refreshed(s.desk)
        await acted(s.desk, .browser, other.id)
        #expect(await until { s.opened.urls.count == 2 })
        var otherRewritten = other
        otherRewritten.amount = "7"
        try WalletAsk.file(otherRewritten, in: s.base.asked)
        await refreshed(s.desk)
        #expect(s.desk.cards.last?.fileChanged == true && s.desk.cards.last?.actions == [.discard])
        await acted(s.desk, .discard, other.id)
        #expect(s.desk.cards.map(\.id) == [request.id])
    }

    /// Review finding 3: a filed request deleted after the click: the page's answer still reaches the session with its
    /// hash, the page stops and the mark goes. With no answer, its page still stops at its time and the mark goes.
    @Test func aRequestDeletedAfterTheClickKeepsTheHashStopsThePageAndClearsTheMark() async throws {
        let clock = WalletDeskTests.Clock()
        let s = try setup(clock: clock)
        defer { s.desk.close() }
        let request = Self.request()
        let url = try await open(s, request)
        try FileManager.default.removeItem(at: s.base.asked.appendingPathComponent("\(request.id).json"))
        await refreshed(s.desk)
        #expect(s.desk.cards.isEmpty)
        let posted = await Self.fetch(Self.result(url), method: "POST", body: #"{"txHash":"\#(Self.hash)"}"#, origin: Self.origin(url))
        #expect(posted?.status == 204)
        let hash = Self.hash.lowercased()
        await refreshed(s.desk)
        let told = try #require(s.base.told.messages.first).text
        #expect(told.contains(hash) && told.contains(request.id))
        #expect(WalletBrowser.mark(request.id, in: s.base.asked) == nil)
        let after = await Self.fetch(url)
        #expect(after == nil || after?.status == 410)

        // No answer: the page stops at its time, the session hears it, and the mark goes.
        let other = Self.request(2)
        try WalletAsk.file(other, in: s.base.asked)
        await refreshed(s.desk)
        await acted(s.desk, .browser, other.id)
        #expect(await until { s.opened.urls.count == 2 })
        let page = s.opened.urls[1]
        try FileManager.default.removeItem(at: s.base.asked.appendingPathComponent("\(other.id).json"))
        clock.now = clock.now.addingTimeInterval(WalletBrowser.pageLifetime)
        await refreshed(s.desk)
        #expect(s.base.told.messages.count == 2)
        let noAnswer = s.base.told.messages.last?.text ?? ""
        #expect(noAnswer.contains(other.id) && noAnswer.contains("no answer came back"))
        #expect(WalletBrowser.mark(other.id, in: s.base.asked) == nil)
        let late = await Self.fetch(page)
        #expect(late == nil || late?.status == 410)
    }

    /// No Wallet Manager peer chosen: the card shows, offers the browser wallet and Open Settings, never Send; once a
    /// peer is chosen, a card still waiting offers Send again.
    @Test func withNoPeerTheCardOffersTheBrowserAndSendComesBackOnceOneIsChosen() async throws {
        let peer = Peer("")
        let s = try setup(peer: peer)
        defer { s.desk.close() }
        var opened = 0
        s.desk.openSettings = { opened += 1 }
        let request = Self.request()
        try WalletAsk.file(request, in: s.base.asked)
        await refreshed(s.desk)
        let card = try #require(s.desk.cards.first)
        #expect(card.state == .waiting)
        #expect(card.actions == [.browser, .discard, .settings])
        #expect(card.setupNeeded == "No Wallet Manager chosen: choose its Mac in Settings › Wallet")
        await acted(s.desk, .send, request.id)
        #expect(s.base.fake.calls.isEmpty)
        await acted(s.desk, .settings, request.id)
        #expect(opened == 1)
        peer.id = WalletFakePassage.peer
        await refreshed(s.desk)
        #expect(s.desk.cards.first?.setupNeeded == nil)
        #expect(s.desk.cards.first?.actions == [.send, .browser, .discard])
        await acted(s.desk, .send, request.id)
        #expect(s.base.fake.sends.count == 1)
        #expect(s.desk.cards.first?.state == .sent)
    }

    /// One request, one path: signed in the browser with no peer chosen, it never offers Send, nor sends, once one is.
    @Test func onceInTheBrowserAPeerChosenLaterDoesntBringSendBack() async throws {
        let peer = Peer("")
        let s = try setup(peer: peer)
        defer { s.desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: s.base.asked)
        await refreshed(s.desk)
        await acted(s.desk, .browser, request.id)
        #expect(await until { s.opened.urls.count == 1 })
        #expect(s.desk.cards.first?.state == .inBrowser && s.desk.cards.first?.actions == [.discard])
        peer.id = WalletFakePassage.peer
        await refreshed(s.desk)
        #expect(s.desk.cards.first?.state == .inBrowser && s.desk.cards.first?.actions == [.discard])
        await acted(s.desk, .send, request.id)
        // Rejected in the wallet: still no Send.
        let url = try #require(s.opened.urls.first)
        let posted = await Self.fetch(Self.result(url), method: "POST", body: #"{"rejected":true}"#, origin: Self.origin(url))
        #expect(posted?.status == 204)
        #expect(await until { s.desk.cards.first?.state == .rejectedInWallet })
        await refreshed(s.desk)
        #expect(s.desk.cards.first?.actions == [.discard])
        await acted(s.desk, .send, request.id)
        #expect(s.base.fake.sends.isEmpty)
    }

    /// The other way: once Send to Wallet Manager went, Sign in browser wallet isn't offered nor done.
    @Test func onceSentToTheWalletManagerTheBrowserIsGone() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let request = Self.request()
        try WalletAsk.file(request, in: s.base.asked)
        await refreshed(s.desk)
        await acted(s.desk, .send, request.id)
        #expect(s.desk.cards.first?.state == .sent)
        #expect(s.desk.cards.first?.actions == [])
        await acted(s.desk, .browser, request.id)
        // Unsure (it may have arrived): no browser either.
        let unsure = Self.request(2)
        try WalletAsk.file(unsure, in: s.base.asked)
        await refreshed(s.desk)
        try s.base.fake.setSendExit(1)
        await acted(s.desk, .send, unsure.id)
        #expect(s.desk.cards.last?.state == .unsure(message: "passage: fake exit 1"))
        #expect(s.desk.cards.last?.actions == [.retry, .discard])
        await acted(s.desk, .browser, unsure.id)
        await refreshed(s.desk)
        #expect(s.opened.urls.isEmpty)
        #expect(WalletBrowser.mark(request.id, in: s.base.asked) == nil && WalletBrowser.mark(unsure.id, in: s.base.asked) == nil)
        // Passage couldn't reach the Wallet Manager: it never got there, so the browser is offered, and once used, Retry is gone.
        let unreached = Self.request(3)
        try WalletAsk.file(unreached, in: s.base.asked)
        await refreshed(s.desk)
        try s.base.fake.setSendExit(4)
        await acted(s.desk, .send, unreached.id)
        #expect(s.desk.cards.last?.actions == [.retry, .browser, .discard])
        await acted(s.desk, .browser, unreached.id)
        #expect(await until { s.opened.urls.count == 1 })
        #expect(s.desk.cards.last?.state == .inBrowser && s.desk.cards.last?.actions == [.discard])
        let sends = s.base.fake.sends.count
        await acted(s.desk, .retry, unreached.id)
        #expect(s.base.fake.sends.count == sends)
    }

    /// A page an earlier run opened stopped with it: the next run says no answer came, once, and won't send it on.
    @Test func aPageLeftOpenByAnEarlierRunEndsWithNoAnswer() async throws {
        let s = try setup()
        let request = Self.request()
        try WalletAsk.file(request, in: s.base.asked)
        try WalletBrowser.setMark(.init(state: .opened, at: WalletDeskTests.created), for: request.id, in: s.base.asked)
        await refreshed(s.desk)
        #expect(s.desk.cards.first?.state == .browserNoAnswer)
        #expect(await until { s.base.told.messages.count == 1 })
        await refreshed(s.desk)
        #expect(s.base.told.messages.count == 1)
        await acted(s.desk, .send, request.id)
        #expect(s.base.fake.sends.isEmpty)
        // Its expiry isn't told as "never sent".
        s.desk.close()
        let clock = WalletDeskTests.Clock()
        clock.now = request.expiresAt.addingTimeInterval(1)
        let later = WalletDesk(folder: s.base.asked, store: s.base.store, inbox: s.base.fake.inbox,
                               config: { WalletDesk.Config(passage: s.base.fake.executable, peer: WalletFakePassage.peer) },
                               now: { clock.now }, log: { _ in })
        later.sessionNames = { WalletDeskTests.names() }
        later.verifyStamps = WalletTestStamps.verify
        later.sealMessage = WalletTestStamps.sealMessage
        later.verifyMessages = WalletTestStamps.verifyMessages
        defer { later.close() }
        let told = WalletDeskTests.Told()
        later.deliver = { told.messages.append(($0, $1)); $2(.delivered) }
        await refreshed(later)
        #expect(later.cards.first?.state == .browserNoAnswer)
        #expect(!told.messages.contains { $0.text.contains("without being sent") })
    }

    /// Delivered, and no word from the Wallet Manager for 5 minutes (the desk's clock): the card asks if it's running.
    @Test func aSentRequestNotPickedUpForFiveMinutesSaysSo() async throws {
        let clock = WalletDeskTests.Clock()
        let s = try setup(clock: clock)
        defer { s.desk.close() }
        let request = WalletDeskTests.request()
        try WalletAsk.file(request, in: s.base.asked)
        await refreshed(s.desk)
        await acted(s.desk, .send, request.id)
        #expect(s.desk.cards.first?.state == .sent)
        #expect(s.desk.cards.first?.notPickedUp == false)
        clock.now = clock.now.addingTimeInterval(WalletCardModel.notPickedUpAfter - 1)
        await refreshed(s.desk)
        #expect(s.desk.cards.first?.notPickedUp == false)
        clock.now = clock.now.addingTimeInterval(1)
        await refreshed(s.desk)
        #expect(s.desk.cards.first?.notPickedUp == true)
        #expect(s.desk.cards.first?.detail.contains("Delivered to the Wallet Manager's Mac, but it hasn't picked it up yet. Is the Wallet Manager running?") == true)
        // Once it's received, the hint goes.
        try s.base.fake.receive(WalletDeskTests.result(request, .received, sequence: 1), second: 1)
        var done = false
        s.desk.poll { done = true }
        _ = await until { done }
        _ = await until { s.desk.cards.first?.state == .received }
        #expect(s.desk.cards.first?.state == .received)
        #expect(s.desk.cards.first?.detail.contains("Is the Wallet Manager running?") == false)
    }

    @Test func thePageIsTheAppsOwnWithNothingExternal() throws {
        let request = Self.request()
        let html = try #require(WalletSignPage.html(for: request))
        // No link at all: the chain's URLs ride in the data for wallet_addEthereumChain, escaped; no script, style, font or
        // image is fetched.
        #expect(!html.contains("http://") && !html.contains("https://"))
        for marker in ["<link", "<img", "<iframe", "src=", "@import", "url(", "@font-face"] { #expect(!html.contains(marker), "\(marker)") }
        #expect(html.contains(#""chainHex":"0x28757b2""#))
        #expect(html.contains(#""rpcUrls":["https:\/\/rpc.chain.genlayer.com"]"#))
        #expect(html.contains(#""decimals":18"#) && html.contains(#""symbol":"GEN""#))
        // Text from the request can't end the data block.
        var hostile = request
        hostile.reason = "</script><script>alert(1)</script>"
        let page = try #require(WalletSignPage.html(for: hostile))
        #expect(!page.contains("</script><script>alert"))
        #expect(page.contains(#"</script>"#))
        // Testnet: its own RPC and explorer; another chain: only switched to.
        var test = request
        test.chainId = 4221
        #expect(try #require(WalletSignPage.html(for: test)).contains(#"https:\/\/rpc.testnet-chain.genlayer.com"#))
        var other = request
        other.chainId = 5
        #expect(try #require(WalletSignPage.data(for: other))["addChain"] == nil)
        // Never asks for a key, seed or passphrase.
        for word in ["seed", "private key", "passphrase", "mnemonic", "<textarea", "contenteditable"] { #expect(!html.lowercased().contains(word), "\(word)") }
        // Its one input is the confirmation checkbox (hidden but for a grant or a call not decoded here).
        #expect(html.components(separatedBy: "<input").count == 2 && html.contains(#"<input type="checkbox" id="confirm">"#))
        #expect(WalletSignPage.html(for: WalletDeskTests.request()) == nil)
    }

    static let spender = "0x00000000000000000000000000000000000000bb"
    /// approve(spender, 2^256−1): the classic drain.
    static let approveAll = "0x095ea7b3" + String(repeating: "0", count: 24) + "00000000000000000000000000000000000000bb" + String(repeating: "f", count: 64)

    /// A contract call from an 0x address, sending nothing with it.
    static func call(_ data: String) -> WalletRequest {
        var request = request()
        request.action = .call
        request.amount = "0"
        request.data = data
        return request
    }

    static func rows(_ data: [String: Any]) -> [[String: String]] { data["rows"] as? [[String: String]] ?? [] }

    /// On the browser path nothing else decodes the call: the page does, an approve reads as one (unlimited in red, and
    /// a box to tick naming the spender and the amount), anything else plainly as an unknown call. Who asked is the
    /// session's name as VibeSwitcher knows it, the reason set apart in quotes.
    @Test func aCallsPageSaysWhatItDoesAndAGrantAsksToBeConfirmed() throws {
        let request = Self.call(Self.approveAll)
        let data = try #require(WalletSignPage.data(for: request, requestedBy: "Session A"))
        let rows = Self.rows(data)
        #expect(rows.first == ["label": "Call", "value": "Approve a spender", "kind": "big bad"])
        #expect(rows.contains(["label": "Spender", "value": Self.spender, "kind": "mono"]))
        #expect(rows.first { $0["label"] == "Amount" }?["value"]?.hasPrefix("Unlimited (") == true)
        #expect(rows.first { $0["label"] == "Amount" }?["kind"] == "bad")
        #expect(rows.contains(["label": "Value sent", "value": "0 GEN", "kind": ""]))
        #expect(rows.last == ["label": "Requested by", "value": "Session A (the agent's label: Example agent)", "kind": ""])
        #expect(data["confirm"] as? String == "I understand this lets \(Self.spender) spend an unlimited amount of the token \(request.to) from this wallet.")
        #expect(data["reason"] as? String == "“Pay the example invoice.”" && data["reasonTitle"] as? String == "Reason, in the agent's words")
        let html = try #require(WalletSignPage.html(for: request, requestedBy: "Session A"))
        #expect(!html.contains("decoded") && !html.contains("Wallet Manager's Mac"))

        let unknown = try #require(WalletSignPage.data(for: Self.call("0x12345678" + String(repeating: "0", count: 64))))
        #expect(Self.rows(unknown).first == ["label": "Call", "value": "Unknown contract call: it may move tokens", "kind": "big bad"])
        // Not decoded here: the same deliberate tick before the wallet is asked.
        #expect((unknown["confirm"] as? String)?.contains("wasn't decoded here, and it may move tokens from this wallet") == true)
        // A transfer: the amount first, nothing to confirm.
        let transfer = try #require(WalletSignPage.data(for: Self.request()))
        #expect(Self.rows(transfer).first == ["label": "Amount", "value": "1.25 GEN", "kind": "big"])
        #expect(transfer["confirm"] == nil)
    }
}

/// The browser wallet's hash reaches the asking session's agent the way the Wallet Manager's answers do: through its
/// steer inbox, into a FakeClaude's transcript (a fake tty, never a real session).
@MainActor
@Suite(.serialized)
struct WalletBrowserDeliveryTests {
    let temp = Scratch()

    @Test func theBrowserWalletsHashReachesTheAskingSessionsAgent() async throws {
        let h = try await Harness.start(temp)
        defer { h.stop() }
        let stateDir = temp.url("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { stateDir }, cwd: { _ in nil }, arguments: { _ in [] }))
        let controller = LeadController(host: h.host, store: store, vault: LeadVault.Book().vault(folder: temp.url("vault"), as: { .app }),
                                        inbox: h.steerRoot, home: h.chat.home) { _ in "exec /bin/sleep 600 #" }
        controller.answersTrust = false
        h.tell(["op": "work"])
        try await h.settle { $0.contains("Working") }

        let fake = try WalletFakePassage(temp)
        let asked = temp.url("asked")
        let desk = WalletDesk(folder: asked, store: WalletRequestStore(folder: temp.url("requests")), inbox: fake.inbox,
                              config: { WalletDesk.Config(passage: fake.executable, peer: WalletFakePassage.peer) },
                              now: { WalletDeskTests.created.addingTimeInterval(30) }, log: { _ in })
        desk.sessionNames = { WalletDeskTests.names(h.session.id) }
        desk.verifyStamps = WalletTestStamps.verify
        desk.sealMessage = WalletTestStamps.sealMessage
        desk.verifyMessages = WalletTestStamps.verifyMessages
        defer { desk.close() }
        desk.deliver = { session, text, then in
            controller.tell(text, from: .system("from the Wallet Manager"), session: UUID(uuidString: session)!, then: then)
        }
        var opened: URL?
        desk.openBrowser = { opened = $0 }
        let request = WalletBrowserDeskTests.request(session: h.session.id)
        try WalletAsk.file(request, in: asked)
        var done = false
        desk.refresh { done = true }
        #expect(await until { done })
        done = false
        desk.act(.browser, on: request.id) { done = true }
        #expect(await until { done && opened != nil })
        let url = try #require(opened)
        let posted = await WalletBrowserDeskTests.fetch(WalletBrowserDeskTests.result(url), method: "POST",
                                                        body: #"{"txHash":"\#(WalletBrowserDeskTests.hash)"}"#,
                                                        origin: WalletBrowserDeskTests.origin(url))
        #expect(posted?.status == 204)

        let hash = WalletBrowserDeskTests.hash.lowercased()
        let pending = { SteerInbox.pending(tty: h.session.tty, root: h.steerRoot).filter { $0.text.contains(request.id) } }
        try await h.waitFor { pending().count == 1 }
        #expect(pending().first?.text.contains(hash) == true)
        h.hookTakes()
        #expect(pending().isEmpty)
        let transcript = try String(contentsOf: h.transcript, encoding: .utf8)
        #expect(transcript.contains(request.id) && transcript.contains(hash) && transcript.contains("browser wallet"))
    }
}

/// The sandbox's `wallet-page` window is closed and dropped once drawn: AppKit mustn't release it a second time.
@MainActor
struct WalletPageWindowTests {
    @Test func closingThePageWindowDoesntReleaseItTwice() {
        weak var gone: NSWindow?
        autoreleasepool {
            let window = Sandbox.pageWindow(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))
            #expect(!window.isReleasedWhenClosed)
            // Closing one AppKit releases too would release it twice and crash the run: fail instead.
            guard !window.isReleasedWhenClosed else { return }
            window.close()
            gone = window
        }
        #expect(gone == nil)
    }
}

/// The page's own script (`WalletSignPage.script`), run in JavaScriptCore against a fake `window.ethereum` and a fake
/// document: never a browser or a wallet. What it asks the wallet, what it says, and what it posts back.
@MainActor
struct WalletSignPageScriptTests {
    /// A context with the page's elements and data, `ethereum` (JS source for `window.ethereum`, or "undefined"), and
    /// the script run.
    static func page(_ request: WalletRequest? = nil, ethereum: String) throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, error in Issue.record("JS: \(error?.toString() ?? "?")") }
        let data = try #require(WalletSignPage.data(for: request ?? WalletBrowserDeskTests.request()))
        let json = String(decoding: try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), as: UTF8.self)
        context.evaluateScript("""
            var window = globalThis, elements = {}, posts = [], calls = [], listeners = {};
            function make(tag) {
              return { tag: tag, textContent: "", className: "", disabled: false, hidden: false, checked: false, listeners: {}, children: [],
                addEventListener: function (type, f) { this.listeners[type] = f; },
                appendChild: function (child) { this.children.push(child); } };
            }
            function element(id) {
              if (!elements[id]) elements[id] = make("#" + id);
              return elements[id];
            }
            var document = { getElementById: element, createElement: make };
            function addEventListener(type, f) { listeners[type] = f; }
            function fetch(url, options) { posts.push({ url: url, body: JSON.parse(options.body) }); return Promise.resolve({ ok: true, status: 204 }); }
            element("request").textContent = JSON.stringify(\(json));
            window.ethereum = \(ethereum);
            """)
        context.evaluateScript(WalletSignPage.script)
        return context
    }

    /// Presses the page's button; the promise jobs run before the call returns.
    static func click(_ context: JSContext) { context.evaluateScript("element('sign').listeners.click()") }
    static func status(_ context: JSContext) -> String { context.evaluateScript("element('status').textContent").toString() }
    static func value(_ context: JSContext, _ script: String) -> String { context.evaluateScript(script).toString() }

    /// A fake wallet: `accounts`, on `chain`, answering eth_sendTransaction with `send` (JS: a value or a thrown error).
    static func wallet(accounts: String = #"["0x00000000000000000000000000000000000000AA"]"#, chain: String = "0x28757b2",
                       switchError: String = "null", code: String = "0x", send: String) -> String {
        """
        { chain: "\(chain)", request: async function (a) {
            calls.push(a.method);
            switch (a.method) {
            case "eth_requestAccounts": case "eth_accounts": return \(accounts);
            case "eth_chainId": return this.chain;
            case "wallet_switchEthereumChain":
              if (\(switchError) && !this.added) throw \(switchError);
              this.chain = a.params[0].chainId; return null;
            case "wallet_addEthereumChain": this.added = a.params[0]; return null;
            case "eth_getCode": return "\(code)";
            case "eth_sendTransaction": this.tx = a.params[0]; \(send)
            }
            throw { code: 4200, message: "unsupported " + a.method };
        } }
        """
    }

    /// An approve: its rows say so, and the wallet isn't asked until the box naming the spender and amount is ticked.
    @Test func aGrantNeedsItsBoxTickedBeforeTheWalletIsAsked() throws {
        let hash = "0x" + String(repeating: "ab", count: 32)
        let request = WalletBrowserDeskTests.call(WalletBrowserDeskTests.approveAll)
        let context = try Self.page(request, ethereum: Self.wallet(send: #"return "\#(hash)";"#))
        #expect(Self.value(context, "element('rows').children[1].textContent") == "Approve a spender")
        #expect(Self.value(context, "element('rows').children[1].className") == "big bad")
        #expect(Self.value(context, "element('confirmRow').hidden") == "false")
        #expect(Self.value(context, "element('confirmText').textContent").contains("spend an unlimited amount of the token"))
        #expect(Self.value(context, "element('sign').disabled") == "true")
        #expect(Self.status(context).hasPrefix("Tick the box above first"))
        // Pressed anyway (a disabled button's click, sent by a script): the wallet isn't asked.
        Self.click(context)
        #expect(Self.value(context, "calls.length") == "0")
        context.evaluateScript("element('confirm').checked = true; element('confirm').listeners.change()")
        #expect(Self.value(context, "element('sign').disabled") == "false")
        Self.click(context)
        #expect(Self.value(context, "JSON.stringify(posts)") == #"[{"url":"result","body":{"txHash":"\#(hash)"}}]"#)
        #expect(Self.value(context, "window.ethereum.tx.data") == WalletBrowserDeskTests.approveAll)
    }

    /// A call not decoded here: the same box, saying it may move tokens, before the wallet is asked.
    @Test func anUnknownCallNeedsItsBoxTickedBeforeTheWalletIsAsked() throws {
        let hash = "0x" + String(repeating: "cd", count: 32)
        let data = "0x12345678" + String(repeating: "0", count: 64)
        let context = try Self.page(WalletBrowserDeskTests.call(data), ethereum: Self.wallet(send: #"return "\#(hash)";"#))
        #expect(Self.value(context, "element('rows').children[1].textContent") == "Unknown contract call: it may move tokens")
        #expect(Self.value(context, "element('confirmRow').hidden") == "false")
        #expect(Self.value(context, "element('confirmText').textContent").contains("it may move tokens from this wallet"))
        #expect(Self.value(context, "element('sign').disabled") == "true")
        Self.click(context)
        #expect(Self.value(context, "calls.length") == "0")
        context.evaluateScript("element('confirm').checked = true; element('confirm').listeners.change()")
        Self.click(context)
        #expect(Self.value(context, "window.ethereum.tx.data") == data)
    }

    /// A transfer has no box: the page is ready as before.
    @Test func aTransferHasNoBoxToTick() throws {
        let context = try Self.page(ethereum: Self.wallet(send: "return null;"))
        // The script leaves the row as the page has it (hidden), its sentence empty.
        #expect(Self.value(context, "element('confirmText').textContent") == "")
        #expect(Self.value(context, "element('sign').disabled") == "false")
        #expect(Self.value(context, "element('rows').children[1].textContent") == "1.25 GEN")
    }

    @Test func noWalletSaysSo() throws {
        let context = try Self.page(ethereum: "undefined")
        #expect(Self.status(context).contains("No wallet extension was found"))
        #expect(Self.value(context, "element('sign').disabled") == "true")
    }

    @Test func theHashIsPostedBack() throws {
        let hash = "0x" + String(repeating: "ab", count: 32)
        let context = try Self.page(ethereum: Self.wallet(send: #"return "\#(hash)";"#))
        Self.click(context)
        #expect(Self.value(context, "JSON.stringify(posts)") == #"[{"url":"result","body":{"txHash":"\#(hash)"}}]"#)
        #expect(Self.value(context, "JSON.stringify(window.ethereum.tx)")
                == #"{"from":"0x00000000000000000000000000000000000000aa","to":"0x0000000000000000000000000000000000000001","value":"0x1158e460913d0000"}"#)
        #expect(Self.status(context).hasPrefix("Sent."))
    }

    @Test func aRejectionIsPostedBack() throws {
        let context = try Self.page(ethereum: Self.wallet(send: #"throw { code: 4001, message: "User rejected" };"#))
        Self.click(context)
        #expect(Self.value(context, "JSON.stringify(posts)") == #"[{"url":"result","body":{"rejected":true}}]"#)
        #expect(Self.status(context).hasPrefix("Rejected in the wallet"))
    }

    /// An error once the wallet was asked to send may come after the transaction went out: nothing is posted, the page
    /// says it may have been sent, and it never asks to send again.
    @Test func anErrorAfterAskingToSendNeverOffersASecondTry() throws {
        let context = try Self.page(ethereum: Self.wallet(send: #"throw { code: -32603, message: "Internal JSON-RPC error" };"#))
        Self.click(context)
        #expect(Self.status(context).contains("may or may not have been sent"))
        #expect(Self.value(context, "element('sign').disabled") == "true")
        Self.click(context)
        #expect(Self.value(context, "calls.filter(function (m) { return m === 'eth_sendTransaction'; }).length") == "1")
        #expect(Self.value(context, "posts.length") == "0")
    }

    @Test func accountsWithoutFromAreRefused() throws {
        let context = try Self.page(ethereum: Self.wallet(accounts: #"["0x00000000000000000000000000000000000000bb"]"#, send: "return null;"))
        Self.click(context)
        #expect(Self.status(context).contains("connected accounts don't include 0x00000000000000000000000000000000000000aa"))
        #expect(!Self.value(context, "calls.join()").contains("eth_sendTransaction"))
        #expect(Self.value(context, "element('sign').disabled") == "false")
    }

    /// GenLayer unknown to the wallet: added with its RPC, explorer and GEN, then switched to.
    @Test func genLayerIsAddedWhenTheWalletDoesntKnowIt() throws {
        let hash = "0x" + String(repeating: "cd", count: 32)
        let context = try Self.page(ethereum: Self.wallet(chain: "0x1", switchError: #"{ code: 4902, message: "Unrecognized chain" }"#,
                                                          send: #"return "\#(hash)";"#))
        Self.click(context)
        #expect(Self.value(context, "JSON.stringify(window.ethereum.added)")
                == #"{"blockExplorerUrls":["https://scan.chain.genlayer.com"],"chainId":"0x28757b2","chainName":"GenLayer","nativeCurrency":{"decimals":18,"name":"GEN","symbol":"GEN"},"rpcUrls":["https://rpc.chain.genlayer.com"]}"#)
        #expect(Self.value(context, "posts.length") == "1")
    }

    /// Base and Base Sepolia unknown to the wallet: added with their official public RPC, explorer and ETH, then switched to.
    @Test func baseIsAddedWhenTheWalletDoesntKnowIt() throws {
        let hash = "0x" + String(repeating: "cd", count: 32)
        for (id, hex, name, rpc, explorer) in [(Int64(8453), "0x2105", "Base", "https://mainnet.base.org", "https://basescan.org"),
                                               (84532, "0x14a34", "Base Sepolia", "https://sepolia.base.org", "https://sepolia.basescan.org")] {
            var request = WalletBrowserDeskTests.request()
            request.chainId = id
            let context = try Self.page(request, ethereum: Self.wallet(chain: "0x1", switchError: #"{ code: 4902, message: "Unrecognized chain" }"#,
                                                                       send: #"return "\#(hash)";"#))
            Self.click(context)
            #expect(Self.value(context, "JSON.stringify(window.ethereum.added)")
                    == #"{"blockExplorerUrls":["\#(explorer)"],"chainId":"\#(hex)","chainName":"\#(name)","nativeCurrency":{"decimals":18,"name":"ETH","symbol":"ETH"},"rpcUrls":["\#(rpc)"]}"#)
            #expect(Self.value(context, "window.ethereum.chain") == hex)
            #expect(Self.value(context, "posts.length") == "1")
            #expect(Self.value(context, "element('rows').children[3].textContent") == "\(name) (\(id))")
        }
    }

    /// Ethereum and Sepolia ship in every wallet: switched to, never added; the wallet's error is shown when it can't.
    @Test func ethereumAndSepoliaAreOnlySwitchedTo() throws {
        let hash = "0x" + String(repeating: "cd", count: 32)
        for (id, hex, name) in [(Int64(1), "0x1", "Ethereum"), (11_155_111, "0xaa36a7", "Sepolia")] {
            var request = WalletBrowserDeskTests.request()
            request.chainId = id
            #expect(try #require(WalletSignPage.data(for: request))["addChain"] == nil)
            let switched = try Self.page(request, ethereum: Self.wallet(chain: "0x2105", send: #"return "\#(hash)";"#))
            Self.click(switched)
            #expect(Self.value(switched, "window.ethereum.chain") == hex)
            #expect(!Self.value(switched, "calls.join()").contains("wallet_addEthereumChain"))
            #expect(Self.value(switched, "posts.length") == "1")
            #expect(Self.value(switched, "element('rows').children[3].textContent") == "\(name) (\(id))")
            let refused = try Self.page(request, ethereum: Self.wallet(chain: "0x2105", switchError: #"{ code: 4902, message: "Unrecognized chain" }"#,
                                                                       send: "return null;"))
            Self.click(refused)
            #expect(Self.status(refused).contains("Unrecognized chain"))
            #expect(!Self.value(refused, "calls.join()").contains("wallet_addEthereumChain"))
            #expect(!Self.value(refused, "calls.join()").contains("eth_sendTransaction"))
        }
    }

    /// The CSP names the hashes of the script and style the page actually carries, whatever chain it's for.
    @Test func theCSPHashesMatchThePageOnEveryKnownChain() throws {
        func hash(_ text: String) -> String { "'sha256-" + Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString() + "'" }
        func between(_ html: String, _ open: String, _ close: String) -> String? {
            guard let start = html.range(of: open), let end = html.range(of: close, range: start.upperBound..<html.endIndex) else { return nil }
            return String(html[start.upperBound..<end.lowerBound])
        }
        for id in WalletChain.known.keys.sorted() + [5] {
            var request = WalletBrowserDeskTests.request()
            request.chainId = id
            let html = try #require(WalletSignPage.html(for: request))
            let script = try #require(between(html, "<script>", "</script>"))
            let style = try #require(between(html, "<style>", "</style>"))
            #expect(WalletSignPage.csp.contains("script-src \(hash(script));"), "chain \(id)")
            #expect(WalletSignPage.csp.contains("style-src \(hash(style));"), "chain \(id)")
        }
    }

    /// Another chain is only switched to; the wallet's error is shown when it can't.
    @Test func anotherChainShowsTheWalletsError() throws {
        var request = WalletBrowserDeskTests.request()
        request.chainId = 5
        let context = try Self.page(request, ethereum: Self.wallet(chain: "0x1", switchError: #"{ code: 4902, message: "Unrecognized chain 0x5" }"#,
                                                                   send: "return null;"))
        Self.click(context)
        #expect(Self.status(context).contains("Unrecognized chain 0x5"))
        #expect(!Self.value(context, "calls.join()").contains("wallet_addEthereumChain"))
        #expect(!Self.value(context, "calls.join()").contains("eth_sendTransaction"))
    }

    @Test func aContractFromIsRefused() throws {
        let context = try Self.page(ethereum: Self.wallet(code: "0x6080604052", send: "return null;"))
        Self.click(context)
        #expect(Self.status(context).contains("is a contract"))
        #expect(!Self.value(context, "calls.join()").contains("eth_sendTransaction"))
    }
}
