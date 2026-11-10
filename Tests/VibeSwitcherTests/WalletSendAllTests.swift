import CryptoKit
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

    // MARK: Calls told apart by their bytes

    /// An undecoded call (a function not known here) with three argument words, the second `argument`.
    static func call(_ number: Int, argument: String, session: UUID = WalletDeskTests.session) -> WalletRequest {
        var request = Self.request(number, session: session)
        request.action = .call
        request.amount = "0"
        request.data = "0xdeadbeef" + String(repeating: "0", count: 63) + "1" + argument + String(repeating: "0", count: 62) + "ff"
        return request
    }

    static func word(_ digit: Character) -> String { String(repeating: "0", count: 63) + String(digit) }

    static func sha256(_ hex: String) -> String {
        let digits = Array(hex.utf8).map { UInt8(Character(UnicodeScalar($0)).hexDigitValue!) }
        let bytes = stride(from: 0, to: digits.count, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func item(_ request: WalletRequest) -> WalletSendAll.Item {
        WalletSendAll.Item(request: request, card: WalletCardModel(request: request, requestedBy: "s", state: .waiting))
    }

    @Test func callsThatDifferOnlyInAnArgumentReadDifferently() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let calls = [Self.call(1, argument: Self.word("a")), Self.call(2, argument: Self.word("b")), Self.call(3, argument: Self.word("c"))]
        for request in calls { try WalletAsk.file(request, in: s.asked) }
        await s.desks.refreshed(s.desk)
        // On their cards they read the same: the same contract, function and size.
        let cards = s.desk.cards(for: Self.session)
        #expect(cards.count == 3 && cards.allSatisfy { $0.call == cards[0].call && $0.calldataBytes == 100 && $0.to == cards[0].to })
        let review = try #require(s.desk.sendAll(for: Self.session))
        // Not alike: the calldata is in each row, never in what is the same in all.
        #expect(!review.common.contains { $0.key == "calldata" })
        #expect(review.rows.map { $0.map(\.key) } == [["calldata"], ["calldata"], ["calldata"]])
        let shown = review.rows.map { $0[0] }
        #expect(Set(shown.map(\.value)).count == 3)
        for (request, field) in zip(calls, shown) {
            let digest = Self.sha256(String(try #require(request.data).dropFirst(2)))
            #expect(field.value.contains("Fingerprint \(digest.prefix(8)) (calldata SHA-256, first 8 hex digits)"))
            #expect(field.value.hasSuffix("100 bytes"))
            // The one word that differs, whole, as hex; the words alike aren't listed.
            #expect(field.differing == 1 && field.words.count == 1)
            #expect(field.alarming)
        }
        #expect(shown.map(\.words) == ["a", "b", "c"].map { ["Word 2: 0x" + Self.word($0)] })
        // The list as text has both for each row.
        let text = review.text
        for field in shown {
            #expect(text.contains(field.words[0]))
            #expect(text.contains(field.value.components(separatedBy: "\n").first { $0.hasPrefix("Fingerprint") }!))
        }
        #expect(text.contains(WalletSendAll.wordsTitle(1)) && WalletSendAll.wordsTitle(2).hasPrefix("2 argument words differ"))
        #expect(s.fake.sends.isEmpty)
    }

    @Test func identicalCalldataHasTheSameFingerprintAndIsStatedOnce() async throws {
        let s = try setup()
        defer { s.desk.close() }
        // Two calls with the same bytes (their value differs), and all three with the same.
        var calls = [Self.call(1, argument: Self.word("a")), Self.call(2, argument: Self.word("a")), Self.call(3, argument: Self.word("a"))]
        for index in calls.indices { calls[index].amount = "\(index + 1)000000000000000000" }
        for request in calls { try WalletAsk.file(request, in: s.asked) }
        await s.desks.refreshed(s.desk)
        let review = try #require(s.desk.sendAll(for: Self.session))
        let calldata = try #require(review.common.first { $0.key == "calldata" })
        let digest = Self.sha256(String(try #require(calls[0].data).dropFirst(2)))
        #expect(calldata.value.contains("Fingerprint \(digest.prefix(8)) "))
        #expect(calldata.words.isEmpty && calldata.differing == 0)
        #expect(review.rows.map { $0.map(\.key) } == [["amount"], ["amount"], ["amount"]])
        // Two alike and one not: each row has its own, the two alike the same fingerprint and the same words.
        let mixed = WalletSendAll.fields(of: [calls[0], calls[1], Self.call(4, argument: Self.word("b"))].map(Self.item))
        let fields = try mixed.map { try #require($0.first { $0.key == "calldata" }) }
        #expect(fields[0] == fields[1] && fields[0].value != fields[2].value)
        #expect(!WalletSendAll.split(mixed).common.contains { $0.key == "calldata" })
        // Hex in another case is the same bytes: the same fingerprint, alike.
        var upper = calls[1]
        upper.data = "0x" + String(try #require(calls[1].data).dropFirst(2)).uppercased()
        let cased = WalletSendAll.fields(of: [calls[0], upper].map(Self.item))
        #expect(cased[0].first { $0.key == "calldata" } == cased[1].first { $0.key == "calldata" })
    }

    /// Calldata an agent chose so that the fingerprints' first 8 digits collide: the fingerprints grow until they
    /// differ, and what is the same in all never has the calldata.
    @Test func differentBytesAreNeverCalledAlikeWhateverTheirFingerprints() throws {
        var seen: [String: String] = [:]
        var pair: (String, String)?
        var counter = 0
        while pair == nil {
            let argument = String(format: "%064x", counter)
            let data = String(Self.call(1, argument: argument).data!.dropFirst(2))
            let short = String(Self.sha256(data).prefix(8))
            if let other = seen[short] { pair = (other, argument) }
            seen[short] = argument
            counter += 1
        }
        let (first, second) = try #require(pair)
        let items = [Self.call(1, argument: first), Self.call(2, argument: second), Self.call(3, argument: first)].map(Self.item)
        let fields = try WalletSendAll.fields(of: items).map { try #require($0.first { $0.key == "calldata" }) }
        func fingerprint(_ field: WalletSendAll.Field) -> String {
            field.value.components(separatedBy: "\n").first { $0.hasPrefix("Fingerprint ") }!.components(separatedBy: " ")[1]
        }
        let prints = fields.map(fingerprint)
        #expect(prints[0].count > 8 && prints[0].prefix(8) == prints[1].prefix(8))
        #expect(prints[0] != prints[1] && prints[0] == prints[2])
        #expect(fields[0].value.contains("first \(prints[0].count) hex digits"))
        #expect(fields[0] != fields[1] && fields[0] == fields[2])
        #expect(fields[0].words == ["Word 2: 0x" + first] && fields[1].words == ["Word 2: 0x" + second])
        #expect(!WalletSendAll.split(WalletSendAll.fields(of: Array(items.prefix(2)))).common.contains { $0.key == "calldata" })
        // Even fields that read the same aren't alike unless their bytes are.
        var same = fields[0], other = fields[0]
        other.bytes = fields[1].bytes
        same.words = []
        other.words = []
        #expect(same.value == other.value)
        #expect(!WalletSendAll.split([[same], [other]]).common.contains { $0.key == "calldata" })
    }

    @Test func theDifferingWordsOfCallsLikeEachOther() {
        func bytes(_ hex: String) -> [UInt8] {
            guard case .bytes(let bytes) = WalletSendAll.calldata(of: Self.call(1, argument: hex)) else { return [] }
            return bytes
        }
        let a = bytes(Self.word("a")), b = bytes(Self.word("b"))
        // Another function, another size, or only itself: nothing to compare with.
        var other = a
        other[0] = 0x11
        let words = WalletSendAll.differingWords([a, b, other, a + [1, 2], a])
        #expect(words.map(\.count) == [1, 1, 0, 0, 1])
        #expect(words[0].lines == words[4].lines && words[0].lines != words[1].lines)
        // A last word shorter than 32 bytes, and more words than a row lists.
        let selector: [UInt8] = [1, 2, 3, 4]
        let long: [UInt8] = selector + [UInt8](repeating: 0, count: 640) + [7]
        let unlike: [UInt8] = selector + [UInt8](repeating: 1, count: 640) + [8]
        let many = WalletSendAll.differingWords([long, unlike])
        #expect(many[0].count == 21 && many[0].lines.count == WalletSendAll.maxWords + 1)
        #expect(many[0].lines.last == "and 9 more words differ")
        let short = WalletSendAll.differingWords([selector + [UInt8](repeating: 0, count: 32) + [7], selector + [UInt8](repeating: 0, count: 32) + [8]])
        #expect(short[0].lines == ["Word 2: 0x07"] && short[1].lines == ["Word 2: 0x08"])
    }

    /// A request whose calldata can't be read is not listed, so not sent from the list, and the list says why.
    @Test(arguments: [("0xzz000000", "not 0x and whole bytes of hex"), ("0x12345", "not 0x and whole bytes of hex"), ("deadbeef00", "not 0x and whole bytes of hex"),
                      ("0x1234", "shorter than a function's 4 bytes"), ("", "not 0x and whole bytes of hex")])
    func calldataThatCantBeReadIsNotListed(_ data: String, _ why: String) async throws {
        var bad = Self.call(2, argument: Self.word("a"))
        bad.data = data
        #expect(WalletSendAll.calldata(of: bad) == .unreadable(why))
        let waiting = [Self.call(1, argument: Self.word("a")), bad, Self.request(3)].map(Self.item)
        let listed = WalletSendAll.listed(waiting)
        #expect(listed.items.map(\.id) == [waiting[0].id, waiting[2].id])
        #expect(listed.unreadable == [WalletSendAll.Unreadable(id: bad.id, why: why)])
        // A call with no calldata, and calldata on a transfer, neither.
        var none = Self.call(4, argument: Self.word("a"))
        none.data = nil
        var transfer = Self.request(5)
        transfer.data = "0xdeadbeef"
        #expect(WalletSendAll.listed([none, transfer].map(Self.item)).items.isEmpty)
        #expect(WalletSendAll.calldata(of: Self.request(1)) == .none)
    }

    // MARK: More waiting than the list holds

    @Test func withMoreWaitingThanTheListHoldsItHoldsTheOldestAndTheRestAreOfferedAfter() async throws {
        let s = try setup()
        defer { s.desk.close() }
        #expect(WalletSendAll.maxListed == WalletDesk.maxCards && WalletDesk.maxCards == 30)
        // 36 calls of one function that differ in one argument, and another session's 2, the oldest of all.
        let theirs = [Self.request(1, session: Self.other), Self.request(2, session: Self.other)]
        let requests = (3...38).map { Self.call($0, argument: String(format: "%064x", $0)) }
        for request in theirs + requests { try WalletAsk.file(request, in: s.asked) }
        await s.desks.refreshed(s.desk)
        // The cards in chat are capped as ever (the newest), and the offer names all 36.
        #expect(s.desk.cards.count == 30)
        #expect(s.desk.cards(for: Self.session).map(\.id) == requests.suffix(30).map(\.id))
        #expect(s.desk.sendAllCount(for: Self.session) == 36)
        #expect(WalletSendAll.offerTitle(36) == "Send all 36 to Wallet Manager…")
        let review = try #require(s.desk.sendAll(for: Self.session))
        // The oldest 30, in filing order.
        #expect(review.items.map(\.request) == Array(requests.prefix(30)))
        #expect(review.waiting == 36 && review.unreadable.isEmpty && review.unreadableNote == nil)
        let note = "30 of 36 waiting requests; the other 6 stay waiting: open Send all again after these"
        #expect(review.cappedNote == note)
        #expect(review.title == "Send 30 requests to the Wallet Manager" && review.confirmTitle == "Send 30 to Wallet Manager")
        // Above the rows.
        let lines = review.text.components(separatedBy: "\n")
        let at = try #require(lines.firstIndex(of: note))
        #expect(at < (try #require(lines.firstIndex(of: "Request 1"))))
        #expect(Set(review.rows.map { $0.first { $0.key == "calldata" }?.value }).count == 30)
        await confirmed(review)
        #expect(Self.sentIDs(s.fake) == requests.prefix(30).map(\.id))
        let summary = try summary(review)
        #expect(summary.sent == 30 && summary.notSent == 0)
        #expect(summary.text == "All 30 sent to the Wallet Manager. Each card shows its own answer. 6 more requests still wait: open Send all again for them.")
        for request in requests.prefix(30) { #expect(review.status(of: Self.item(request)) == "Sent" || state(s, request) == nil) }
        #expect(review.outcomes.count == 30 && review.outcomes.values.allSatisfy { $0 == .some(.sent) })
        // The 6 left: all on their cards, all offered, none dropped or hidden; the other session's untouched.
        let rest = Array(requests.suffix(6))
        #expect(s.desk.cards(for: Self.session).map(\.id) == rest.map(\.id))
        #expect(s.desk.sendAllCount(for: Self.session) == 6)
        #expect(s.desk.sendAllCount(for: Self.other) == 2)
        let second = try #require(s.desk.sendAll(for: Self.session))
        #expect(second.items.map(\.request) == rest && second.cappedNote == nil)
        await confirmed(second)
        #expect(Self.sentIDs(s.fake) == requests.map(\.id))
        #expect(try self.summary(second).text == "All 6 sent to the Wallet Manager. Each card shows its own answer.")
        #expect(s.desk.sendAllCount(for: Self.session) == nil)
        for request in theirs { #expect(s.desk.uncut.cards.first { $0.id == request.id }?.state == .waiting) }
    }

    /// A capped list that stops midway: what it didn't send, and what it didn't hold, all still wait and are offered.
    @Test func aCappedListThatStopsLeavesEveryOtherRequestWaiting() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let requests = try await filed(s, 33)
        try s.fake.setSendExit(4, for: requests[1].id)
        let review = try #require(s.desk.sendAll(for: Self.session))
        #expect(review.cappedNote == "30 of 33 waiting requests; the other 3 stay waiting: open Send all again after these")
        await confirmed(review)
        #expect(Self.sentIDs(s.fake) == [requests[0].id, requests[1].id])
        #expect(s.desk.sendAllCount(for: Self.session) == 31)
        let again = try #require(s.desk.sendAll(for: Self.session))
        #expect(again.items.map(\.id) == requests[2..<32].map(\.id))
        #expect(again.cappedNote == "30 of 31 waiting requests; the other 1 stays waiting: open Send all again after these")
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
