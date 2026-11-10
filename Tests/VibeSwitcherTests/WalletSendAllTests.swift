import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// Send all (`WalletSendAll`): a session's waiting wallet requests listed, then sent by one confirmation, each through
/// its card's Send. The list is a snapshot and fails closed; the run stops at the first request that didn't plainly go.
@MainActor
@Suite(.serialized)
struct WalletSendAllTests {
    static var session: UUID { WalletDeskTests.session }
    static let other = UUID(uuidString: "99999999-2222-4333-8444-555555555555")!

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [String] = []
        func add(_ line: String) { lock.withLock { kept.append(line) } }
        var all: [String] { lock.withLock { kept } }
    }

    struct Setup {
        let desks: WalletDeskTests
        let fake: WalletFakePassage
        let desk: WalletDesk
        let asked: URL
        let clock: WalletDeskTests.Clock
        let log: Lines
        let opened: Lines
    }

    /// A desk as `WalletDeskTests.setup` makes it, keeping its log and the pages it would open in a browser.
    func setup(peer: String = WalletFakePassage.peer) throws -> Setup {
        let desks = WalletDeskTests()
        let fake = try WalletFakePassage(desks.temp)
        let asked = desks.temp.url("asked")
        let clock = WalletDeskTests.Clock()
        let log = Lines(), opened = Lines()
        let desk = WalletDesk(folder: asked, store: WalletRequestStore(folder: desks.temp.url("requests")), inbox: fake.inbox,
                             config: { WalletDesk.Config(passage: fake.executable, peer: peer) }, now: { clock.now }, log: { log.add($0) })
        desk.sessionNames = { WalletDeskTests.names(Self.other) }
        desk.verifyStamps = WalletTestStamps.verify
        desk.sealMessage = WalletTestStamps.sealMessage
        desk.verifyMessages = WalletTestStamps.verifyMessages
        desk.findPassage = { nil }
        desk.openBrowser = { opened.add($0.absoluteString) }
        desk.deliver = { _, _, then in then(.delivered) }
        return Setup(desks: desks, fake: fake, desk: desk, asked: asked, clock: clock, log: log, opened: opened)
    }

    /// Request `number`, its amount `number` GEN, from `session`.
    static func request(_ number: Int, session: UUID = WalletDeskTests.session) -> WalletRequest {
        var request = WalletDeskTests.request(number, session: session)
        request.amount = "\(number)000000000000000000"
        return request
    }

    /// Files requests 1…count for the test's session and waits for their cards.
    func filed(_ s: Setup, _ count: Int) async throws -> [WalletRequest] {
        let requests = (1...count).map { Self.request($0) }
        for request in requests { try WalletAsk.file(request, in: s.asked) }
        await s.desks.refreshed(s.desk)
        return requests
    }

    func confirmed(_ review: WalletSendAll) async {
        var done = false
        review.confirm { done = true }
        _ = await until { done }
    }

    /// The ids `passage send` was run for, in order.
    static func sentIDs(_ fake: WalletFakePassage) -> [String] {
        fake.sends.compactMap { line in
            line.range(of: "--name wallet-request-").map { String(line[$0.upperBound...].dropLast(".json".count)) }
        }
    }

    func summary(_ review: WalletSendAll) throws -> WalletSendAll.Summary {
        guard case .done(let summary) = review.phase else { throw WalletTestStamps.Refused() }
        return summary
    }

    func state(_ s: Setup, _ request: WalletRequest) -> WalletCardModel.State? { s.desk.cards.first { $0.id == request.id }?.state }

    // MARK: The offer

    @Test func offeredOnlyWithTwoOrMoreWaitingAndAWalletManagerChosen() async throws {
        let s = try setup()
        defer { s.desk.close() }
        await s.desks.refreshed(s.desk)
        #expect(s.desk.sendAllCount(for: Self.session) == nil && s.desk.sendAll(for: Self.session) == nil)
        try WalletAsk.file(Self.request(1), in: s.asked)
        await s.desks.refreshed(s.desk)
        #expect(s.desk.sendAllCount(for: Self.session) == nil && s.desk.sendAll(for: Self.session) == nil)
        try WalletAsk.file(Self.request(2), in: s.asked)
        try WalletAsk.file(Self.request(3), in: s.asked)
        await s.desks.refreshed(s.desk)
        #expect(s.desk.sendAllCount(for: Self.session) == 3)
        #expect(WalletSendAll.offerTitle(3) == "Send all 3 to Wallet Manager…")
        // One sent: 2 wait, still offered; another: 1 waits, not offered.
        await s.desks.acted(s.desk, .send, Self.request(1).id)
        #expect(s.desk.sendAllCount(for: Self.session) == 2)
        await s.desks.acted(s.desk, .send, Self.request(2).id)
        #expect(s.desk.sendAllCount(for: Self.session) == nil && s.desk.sendAll(for: Self.session) == nil)
    }

    @Test func notOfferedWithNoWalletManagerChosen() async throws {
        let s = try setup(peer: "")
        defer { s.desk.close() }
        _ = try await filed(s, 3)
        #expect(s.desk.cards(for: Self.session).count == 3)
        #expect(s.desk.cards.allSatisfy { $0.state == .waiting && $0.setupNeeded == WalletCardModel.noPeerNote })
        #expect(s.desk.sendAllCount(for: Self.session) == nil && s.desk.sendAll(for: Self.session) == nil)
        #expect(s.fake.sends.isEmpty)
    }

    @Test func anotherSessionsCardsAreNeverListedOrSent() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let mine = [Self.request(1), Self.request(3)]
        let theirs = [Self.request(2, session: Self.other), Self.request(4, session: Self.other), Self.request(5, session: Self.other)]
        for request in mine + theirs { try WalletAsk.file(request, in: s.asked) }
        await s.desks.refreshed(s.desk)
        #expect(s.desk.sendAllCount(for: Self.session) == 2 && s.desk.sendAllCount(for: Self.other) == 3)
        let review = try #require(s.desk.sendAll(for: Self.session))
        #expect(review.items.map(\.id) == mine.map(\.id))
        await confirmed(review)
        #expect(Self.sentIDs(s.fake) == mine.map(\.id))
        for request in theirs { #expect(state(s, request) == .waiting) }
        // A session with one waiting of its own isn't offered, however many others wait.
        #expect(s.desk.sendAllCount(for: UUID()) == nil)
    }

    // MARK: The list

    @Test func theListStatesWhatIsAlikeOnceAndEachRowsDifference() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let requests = try await filed(s, 3)
        let review = try #require(s.desk.sendAll(for: Self.session))
        #expect(review.items.map(\.request) == requests)
        #expect(review.title == "Send 3 requests to the Wallet Manager" && review.confirmTitle == "Send 3 to Wallet Manager")
        #expect(review.requestedBy == WalletDeskTests.sessionName)
        // Only the amount differs: every other fact once, above.
        #expect(review.common.map(\.key) == ["chain", "from", "to", "calldata", "workspace", "label", "reason"])
        #expect(review.rows.map { $0.map(\.key) } == [["amount"], ["amount"], ["amount"]])
        #expect(review.rows.map { $0[0].value } == ["1 GEN", "2 GEN", "3 GEN"])
        let common = Dictionary(uniqueKeysWithValues: review.common.map { ($0.key, $0) })
        #expect(common["chain"]?.value == "GenLayer (42424242)")
        #expect(common["from"]?.value == "example-hardware")
        #expect(common["to"]?.value == "0x0000000000000000000000000000000000000001")
        #expect(common["calldata"]?.value == "None: a transfer")
        // The agent's words, quoted and named as the agent's.
        #expect(common["label"]?.name == "The agent's label" && common["label"]?.value == "“Example agent”" && common["label"]?.agents == true)
        #expect(common["reason"]?.name == WalletCardModel.reasonTitle && common["reason"]?.value == "“Pay the example invoice.”" && common["reason"]?.agents == true)
        #expect(review.text.contains("Buttons: Cancel, Send 3 to Wallet Manager"))
        #expect(s.fake.sends.isEmpty)
    }

    @Test func aContractCallsCalldataReadsAsOnItsCard() async throws {
        let s = try setup()
        defer { s.desk.close() }
        var call = Self.request(1)
        call.action = .call
        call.amount = "0"
        // approve(spender, unlimited)
        call.data = "0x095ea7b3" + String(repeating: "0", count: 63) + "2" + String(repeating: "f", count: 64)
        let transfer = Self.request(2)
        for request in [call, transfer] { try WalletAsk.file(request, in: s.asked) }
        await s.desks.refreshed(s.desk)
        let review = try #require(s.desk.sendAll(for: Self.session))
        let card = try #require(s.desk.cards.first { $0.id == call.id })
        let decoded = try #require(card.call)
        let shown = try #require(review.rows[0].first { $0.key == "calldata" })
        #expect(shown.value.hasPrefix(decoded.headline))
        for field in decoded.fields { #expect(shown.value.contains("\(field.name): \(field.value)")) }
        #expect(shown.value.hasSuffix("68 bytes"))
        #expect(shown.alarming == (decoded.alarming || decoded.fields.contains { $0.alarming }))
        #expect(review.rows[0].first { $0.key == "to" }?.name == "Contract")
        #expect(review.rows[1].first { $0.key == "calldata" }?.value == "None: a transfer")
    }

    @Test func identicalRequestsSayTheyAreTheSame() async throws {
        let a = WalletCardModel(id: "a", workspace: "w", from: "f", to: "t", chainID: 1, asset: "ETH", amount: "1", reason: "r", requestedBy: "s", state: .waiting)
        var b = a
        b.id = "b"
        let split = WalletSendAll.split([a, b])
        #expect(split.common.count == 8 && split.rows == [[], []])
    }

    // MARK: The snapshot, failing closed

    @Test func aRequestFiledAfterTheListOpenedIsNotSent() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let requests = try await filed(s, 2)
        let review = try #require(s.desk.sendAll(for: Self.session))
        let late = Self.request(3)
        try WalletAsk.file(late, in: s.asked)
        await s.desks.refreshed(s.desk)
        #expect(state(s, late) == .waiting)
        await confirmed(review)
        #expect(Self.sentIDs(s.fake) == requests.map(\.id))
        #expect(state(s, late) == .waiting)
        #expect(try summary(review).sent == 2)
        #expect(try summary(review).notSent == 0)
    }

    /// Each way a listed request stops being as listed: nothing at all is sent, and the list says to open it again.
    @Test(arguments: ["discarded", "sent", "expired", "rewritten", "no wallet manager"])
    func aListedRequestNoLongerAsListedSendsNothing(_ change: String) async throws {
        var peer = WalletFakePassage.peer
        let s = try setup()
        s.desk.config = { [fake = s.fake] in WalletDesk.Config(passage: fake.executable, peer: peer) }
        defer { s.desk.close() }
        let requests = try await filed(s, 3)
        let review = try #require(s.desk.sendAll(for: Self.session))
        var before = 0
        switch change {
        case "discarded": await s.desks.acted(s.desk, .discard, requests[1].id)
        case "sent":
            await s.desks.acted(s.desk, .send, requests[1].id)
            before = 1
        case "expired":
            // Every request expires a day after it was made; nothing redraws the cards before the confirmation does.
            s.clock.now = WalletDeskTests.created.addingTimeInterval(86_401)
        case "rewritten":
            // Filed again under its id with another amount, stamped as the agent's own filing would be, not yet redrawn.
            var changed = requests[1]
            changed.amount = "999000000000000000000"
            try WalletAsk.file(changed, in: s.asked)
        default: peer = ""
        }
        #expect(s.fake.sends.count == before)
        await confirmed(review)
        #expect(s.fake.sends.count == before, "\(s.fake.sends)")
        let summary = try summary(review)
        #expect(summary.sent == 0 && summary.notSent == 3 && summary.reopen)
        #expect(summary.text.hasPrefix("Nothing was sent.") && summary.text.contains("open it again"))
        // The others still wait (or expired on their own cards): untouched by the list.
        if change == "discarded" || change == "sent" || change == "rewritten" {
            #expect(state(s, requests[0]) == .waiting && state(s, requests[2]) == .waiting)
        }
        // A list that ended can't be confirmed again.
        await confirmed(review)
        #expect(s.fake.sends.count == before)
    }

    /// A listed request rewritten while the first is being sent, and redrawn before its turn: it isn't sent (the
    /// user never saw the new version in this list), nor is anything after it.
    @Test func aRequestThatChangesDuringTheRunIsNotSent() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let requests = try await filed(s, 3)
        let review = try #require(s.desk.sendAll(for: Self.session))
        var changed = requests[2]
        changed.amount = "999000000000000000000"
        let desk = s.desk, asked = s.asked
        let once = Lines()
        // The desk seals its record of request 1 while sending it (on its queue): then.
        s.desk.sealMessage = { message in
            if once.all.isEmpty {
                once.add("rewritten")
                try WalletAsk.file(changed, in: asked)
                DispatchQueue.main.async { desk.refresh(polling: false) }
            }
            return try WalletTestStamps.sealMessage(message)
        }
        await confirmed(review)
        #expect(once.all == ["rewritten"])
        #expect(Self.sentIDs(s.fake) == [requests[0].id, requests[1].id])
        let summary = try summary(review)
        #expect(summary.sent == 2 && summary.notSent == 1 && !summary.reopen)
        #expect(summary.text.contains("Request 3 is no longer waiting as this list shows it"))
        // The changed request has its card, as changed, waiting for its own Send.
        let card = try #require(s.desk.cards.first { $0.id == changed.id })
        #expect(card.state == .waiting && card.amount == "999")
    }

    @Test func cancelSendsNothingAndTheListCanSendNothingAfter() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let requests = try await filed(s, 3)
        let review = try #require(s.desk.sendAll(for: Self.session))
        review.cancel()
        #expect(review.phase == .cancelled)
        await confirmed(review)
        #expect(review.phase == .cancelled)
        await s.desks.refreshed(s.desk)
        #expect(s.fake.sends.isEmpty)
        for request in requests { #expect(state(s, request) == .waiting) }
        // A sheet with no window to show on cancels too.
        let unseen = try #require(s.desk.sendAll(for: Self.session))
        var closed = false
        WalletSendAllSheet.present(unseen, over: nil) { closed = true }
        #expect(closed && unseen.phase == .cancelled)
        #expect(s.fake.sends.isEmpty)
    }

    /// Stop pressed while the run is under way (here, before its first request): no further request is started.
    @Test func stopDuringTheRunStartsNoFurtherRequest() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let requests = try await filed(s, 3)
        let review = try #require(s.desk.sendAll(for: Self.session))
        s.clock.hold()
        var done = false
        review.confirm { done = true }
        #expect(await until { s.clock.held })
        #expect(review.phase == .sending)
        review.cancel()
        s.clock.release()
        #expect(await until { done })
        #expect(s.fake.sends.isEmpty)
        let summary = try summary(review)
        #expect(summary.sent == 0 && summary.notSent == 3 && summary.text.contains("You stopped it"))
        for request in requests { #expect(state(s, request) == .waiting) }
    }

    // MARK: The run

    @Test func eachRequestGoesOnceInFilingOrderAndItsCardShowsItsOwnOutcome() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let requests = try await filed(s, 4)
        let review = try #require(s.desk.sendAll(for: Self.session))
        await confirmed(review)
        #expect(Self.sentIDs(s.fake) == requests.map(\.id))
        for request in requests {
            #expect(state(s, request) == .sent)
            #expect(try Data(contentsOf: s.fake.file("sent-wallet-request-\(request.id).json")) == request.encoded())
            #expect(review.outcomes[request.id] == .some(.sent))
        }
        #expect(!s.fake.sends.contains { $0.contains("--yes") })
        let summary = try summary(review)
        #expect(summary.sent == 4 && summary.notSent == 0 && summary.text.hasPrefix("All 4 sent"))
        // The Wallet Manager's answer to one shows on that card alone, as after a single Send.
        try s.fake.receive(WalletDeskTests.result(requests[2], .rejected, sequence: 1), second: 1)
        await s.desks.polled(s.desk)
        #expect(await until { state(s, requests[2]) != .sent })
        #expect(state(s, requests[0]) == .sent && state(s, requests[1]) == .sent && state(s, requests[3]) == .sent)
        #expect(s.desk.sendAllCount(for: Self.session) == nil)
    }

    /// passage's exit code for request 2 and the card state it leaves: the run stops there, request 1 sent, request 3
    /// never tried. 4, 3, 2 and 5 end before anything went; 1 and any other end may have delivered.
    @Test(arguments: [(4, "unreachable"), (3, "unreachable"), (2, "notSent"), (5, "notSent"), (1, "unsure"), (9, "unsure")])
    func theRunStopsAtTheFirstRequestThatDidntPlainlyGo(_ exit: Int, _ expected: String) async throws {
        let s = try setup()
        defer { s.desk.close() }
        let requests = try await filed(s, 3)
        try s.fake.setSendExit(Int32(exit), for: requests[1].id)
        let review = try #require(s.desk.sendAll(for: Self.session))
        await confirmed(review)
        #expect(Self.sentIDs(s.fake) == [requests[0].id, requests[1].id])
        #expect(state(s, requests[0]) == .sent)
        let stopped = try #require(s.desk.cards.first { $0.id == requests[1].id })
        switch (expected, stopped.state) {
        case ("unreachable", .unreachable), ("unsure", .unsure):
            #expect(stopped.actions == [.retry, .discard])
        case ("notSent", .notSent):
            #expect(stopped.actions == [.discard])
        default: Issue.record("request 2's card is \(stopped.state) after exit \(exit)")
        }
        // Untouched: waiting, with its Send, nothing run for it.
        let third = try #require(s.desk.cards.first { $0.id == requests[2].id })
        #expect(third.state == .waiting && third.actions == [.send, .discard])
        #expect(third == review.items[2].card)
        #expect(!FileManager.default.fileExists(atPath: s.fake.file("sent-wallet-request-\(requests[2].id).json").path))
        let summary = try summary(review)
        #expect(summary.sent == 1 && summary.notSent == 2)
        #expect(summary.text.hasPrefix("1 of 3 sent. Stopped at request 2 (\(WalletCardModel.title(stopped.state)))"))
        #expect(summary.text.contains("The 1 after it weren't tried and still wait"))
        #expect(review.status(of: review.items[2]) == "Waiting for you")
    }

    /// Only a card that says the request went lets the run go on: every state has its decision.
    @Test func onlyAStateThatSaysItWentLetsTheRunGoOn() {
        let went: [WalletCardModel.State] = [.sent, .received, .proposed(safeTxHash: nil), .signedNotSubmitted,
                                             .signed(txHash: WalletStripTests.hash, explorerURL: nil), .rejected(reason: "r"), .failed(message: "m")]
        for state in WalletStripTests.every {
            #expect(WalletSendAll.went(state) == went.contains { WalletCardModel.title($0) == WalletCardModel.title(state) }, "\(state)")
        }
        #expect(!WalletSendAll.went(.notSent(reason: "the folder holds other bytes under its name")))
    }

    // MARK: The other ways stay as they were

    @Test func afterAStoppedRunSendRetryAndDiscardWorkAsEver() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let requests = try await filed(s, 4)
        try s.fake.setSendExit(4, for: requests[1].id)
        let review = try #require(s.desk.sendAll(for: Self.session))
        await confirmed(review)
        #expect(state(s, requests[1]) == .unreachable(message: "passage: fake exit 4"))
        // Retry on the one that stopped it.
        try s.fake.setSendExit(0, for: requests[1].id)
        await s.desks.acted(s.desk, .retry, requests[1].id)
        #expect(state(s, requests[1]) == .sent)
        // A single Send, and a Discard, on the ones left waiting.
        await s.desks.acted(s.desk, .send, requests[2].id)
        #expect(state(s, requests[2]) == .sent)
        await s.desks.acted(s.desk, .discard, requests[3].id)
        #expect(state(s, requests[3]) == nil)
        #expect(Self.sentIDs(s.fake) == [requests[0].id, requests[1].id, requests[1].id, requests[2].id])
        // The finished list does nothing more.
        await confirmed(review)
        #expect(s.fake.sends.count == 4)
    }

    /// Requests the browser wallet could sign: the list sends them to the Wallet Manager only. No page is served or
    /// opened, and no browser mark is written.
    @Test func neverTheBrowserWallet() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let requests = (1...3).map { number -> WalletRequest in
            var request = Self.request(number)
            request.from = "0x00000000000000000000000000000000000000aa"
            return request
        }
        for request in requests { try WalletAsk.file(request, in: s.asked) }
        await s.desks.refreshed(s.desk)
        #expect(s.desk.cards.allSatisfy { $0.actions == [.send, .browser, .discard] })
        try s.fake.setSendExit(4, for: requests[1].id)
        let review = try #require(s.desk.sendAll(for: Self.session))
        await confirmed(review)
        await s.desks.refreshed(s.desk)
        #expect(s.opened.all.isEmpty)
        for request in requests { #expect(WalletBrowser.mark(request.id, in: s.asked) == nil) }
        #expect(!s.log.all.contains { $0.contains("browser") })
        #expect(Self.sentIDs(s.fake) == [requests[0].id, requests[1].id])
    }

    // MARK: No way to the Wallet Manager of its own

    /// Every file the transport was handed during a run is one the desk's single send handed it (its own log line, one
    /// per send): a delivery with no such line would be the list reaching the transport some other way.
    @Test func everyDeliveryIsTheDesksSingleSend() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let requests = try await filed(s, 4)
        try s.fake.setSendExit(1, for: requests[2].id)
        let review = try #require(s.desk.sendAll(for: Self.session))
        await confirmed(review)
        let delivered = Self.sentIDs(s.fake)
        let singleSends = s.log.all.compactMap { line -> String? in
            guard line.hasPrefix("sent "), let end = line.range(of: " from its card: ") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 5)..<end.lowerBound])
        }
        #expect(delivered == requests.prefix(3).map(\.id))
        #expect(delivered == singleSends)
        // And nothing but `send` to the chosen peer was run for them.
        #expect(s.fake.calls.filter { !$0.hasPrefix("listen") && !$0.hasPrefix("inbox") }.allSatisfy { $0.hasPrefix("send \(WalletFakePassage.peer) ") })
    }

    /// The list's source names nothing it could send with: no courier, transport or link, no process, and of a
    /// card's actions only send, handed to the desk's `act`. The desk's own send stays private.
    @Test func theListsSourceHasNoSendPathOfItsOwn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let wallet = root.appendingPathComponent("Sources/VibeSwitcher/Wallet")
        let source = try String(contentsOf: wallet.appendingPathComponent("WalletSendAll.swift"), encoding: .utf8)
        let code = source.components(separatedBy: "\n").map { $0.components(separatedBy: "//").first ?? $0 }.joined(separator: "\n")
        for banned in ["WalletTransport", "WalletCourier", "courier", "PassageLink", "PassageCommand", "WalletLocalLink", "localLink", "WalletSignServer",
                       "WalletBrowser", "openBrowser", ".deliver", "Process(", "Shell.", "FileManager", "write("] {
            #expect(!code.contains(banned), "WalletSendAll.swift names \(banned)")
        }
        // No other button of a card (a state's name may start like one: `.browserNoAnswer`).
        for action in WalletCardModel.Action.allCases where action != .send {
            #expect(code.range(of: "\\.\(action.rawValue)\\b", options: .regularExpression) == nil, "WalletSendAll.swift names .\(action.rawValue)")
        }
        // One call into the desk that can send, with send.
        #expect(code.components(separatedBy: "desk.act(").count == 2)
        #expect(code.contains("desk.act(.send, on: item.id)"))
        let desk = try String(contentsOf: wallet.appendingPathComponent("WalletDesk.swift"), encoding: .utf8)
        #expect(desk.contains("private func send(_ request: WalletRequest, config: Config)"))
        // The courier's send is called from that one place in the app.
        var callers: [String] = []
        let files = try #require(FileManager.default.enumerator(at: root.appendingPathComponent("Sources/VibeSwitcher"), includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("courier.send(") || text.contains("courier?.send(") { callers.append(url.lastPathComponent) }
        }
        #expect(callers == ["WalletDesk.swift"])
        #expect(desk.components(separatedBy: "courier.send(").count == 2)
    }
}
