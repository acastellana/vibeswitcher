import AppKit
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

    func setup(clock: WalletDeskTests.Clock = WalletDeskTests.Clock()) throws -> Setup {
        let fake = try WalletFakePassage(temp)
        let asked = temp.url("asked")
        let store = WalletRequestStore(folder: temp.url("requests"))
        let desk = WalletDesk(folder: asked, store: store, inbox: fake.inbox,
                              config: { WalletDesk.Config(passage: fake.executable, peer: WalletFakePassage.peer) }, now: { clock.now }, log: { _ in })
        desk.findPassage = { nil }
        let told = WalletDeskTests.Told()
        desk.deliver = { session, text in told.messages.append((session, text)) }
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
        defer { later.close() }
        let told = WalletDeskTests.Told()
        later.deliver = { told.messages.append(($0, $1)) }
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
        for word in ["seed", "private key", "passphrase", "mnemonic", "<input"] { #expect(!html.lowercased().contains(word), "\(word)") }
        #expect(WalletSignPage.html(for: WalletDeskTests.request()) == nil)
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
        defer { desk.close() }
        desk.deliver = { session, text in
            controller.tell(text, from: .system("from the Wallet Manager"), session: UUID(uuidString: session)!)
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
            function element(id) {
              if (!elements[id]) elements[id] = { textContent: "", className: "", disabled: false, listeners: {},
                addEventListener: function (type, f) { this.listeners[type] = f; } };
              return elements[id];
            }
            var document = { getElementById: element };
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
