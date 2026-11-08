import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// A request's record and its browser mark are files any process of the user's can write, so they say nothing the
/// host-stamped filed request doesn't, unless they carry a seal the session host confirms: what the app itself wrote,
/// so rewriting a filed request can't hide what was really sent.
@MainActor
@Suite(.serialized)
struct WalletDeskCopiesTests {
    let browser = WalletBrowserDeskTests()
    static let other = UUID(uuidString: "99999999-2222-4333-8444-555555555555")!

    func setup(_ logged: WalletBrowserDeskTests.Logged = .init()) throws -> WalletBrowserDeskTests.Setup {
        let s = try browser.setup(logged: logged)
        s.desk.sessionNames = { WalletDeskTests.names(Self.other) }
        return s
    }

    /// A desk made anew over `s`'s folders, as the app makes one at a relaunch.
    func relaunch(_ s: WalletBrowserDeskTests.Setup, _ logged: WalletBrowserDeskTests.Logged) -> WalletBrowserDeskTests.Setup {
        let fake = s.base.fake
        let clock = WalletDeskTests.Clock()
        let desk = WalletDesk(folder: s.base.asked, store: s.base.store, inbox: fake.inbox,
                              config: { WalletDesk.Config(passage: fake.executable, peer: WalletFakePassage.peer) }, now: { clock.now }, log: { logged.add($0) })
        desk.sessionNames = { WalletDeskTests.names(Self.other) }
        desk.verifyStamps = WalletTestStamps.verify
        desk.sealMessage = WalletTestStamps.sealMessage
        desk.verifyMessages = WalletTestStamps.verifyMessages
        desk.findPassage = { nil }
        let told = WalletDeskTests.Told()
        desk.deliver = { session, text, then in told.messages.append((session, text)); then(.delivered) }
        return .init(base: .init(fake: fake, desk: desk, asked: s.base.asked, store: s.base.store, told: told), opened: s.opened)
    }

    /// The forgeries a copy on disk may be: another session's, or the same session's with something else in it.
    static func forgeries(of request: WalletRequest) -> [WalletRequest] {
        var otherSession = request
        otherSession.requestedBy.session = other.uuidString.lowercased()
        otherSession.amount = "9000000000000000000"
        otherSession.requestedBy.label = "PLANTED-LABEL"
        var otherAmount = request
        otherAmount.amount = "9000000000000000000"
        otherAmount.to = "0x00000000000000000000000000000000000000ff"
        return [otherSession, otherAmount]
    }

    func noCardNoRetry(_ s: WalletBrowserDeskTests.Setup, _ request: WalletRequest, _ logged: WalletBrowserDeskTests.Logged, copy: String) async {
        #expect(s.desk.cards.isEmpty)
        #expect(s.desk.cards(for: Self.other).isEmpty)
        #expect(s.desk.cards(for: WalletDeskTests.session).isEmpty)
        // Nothing can be done without a card.
        await browser.acted(s.desk, .retry, request.id)
        #expect(s.base.fake.sends.isEmpty)
        #expect(s.base.told.messages.isEmpty)
        // Once, however often the desk looks, and with nothing of what the copy says.
        await browser.refreshed(s.desk)
        let lines = logged.lines.filter { $0.contains("no card and no Retry") }
        #expect(lines == ["\(request.id): no card and no Retry: its \(copy) isn't the request the session host stamped and has no seal the host confirmed"])
        #expect(!logged.lines.contains { $0.contains("PLANTED-LABEL") || $0.contains(Self.other.uuidString.lowercased()) || $0.contains("9000000000000000000") })
    }

    /// A planted record, naming another session or saying something else, unsealed or under a seal the host never made.
    @Test(arguments: [nil, "bm90IHRoZSBob3N0J3M="] as [String?])
    func aPlantedRecordGetsNoCardNoRetryAndALineWithNoContent(seal: String?) async throws {
        for (index, forgery) in Self.forgeries(of: WalletBrowserDeskTests.request()).enumerated() {
            let logged = WalletBrowserDeskTests.Logged()
            let s = try setup(logged)
            defer { s.desk.close() }
            var filed = WalletBrowserDeskTests.request(10 + index)
            filed.requestedBy.session = WalletDeskTests.session.uuidString.lowercased()
            var planted = forgery
            planted.id = filed.id
            try WalletAsk.file(filed, in: s.base.asked)
            try s.base.store.save(WalletRequestStore.Record(request: planted, state: .unsure, seal: seal))
            await browser.refreshed(s.desk)
            await noCardNoRetry(s, filed, logged, copy: "record")
            // A result for it reaches no session either.
            try s.base.fake.receive(WalletDeskTests.result(filed, .received, sequence: 1), second: 1)
            var polled = false
            s.desk.poll { polled = true }
            _ = await until { polled }
            await browser.refreshed(s.desk)
            #expect(s.base.told.messages.isEmpty)
        }
    }

    /// The same for a planted browser mark: no card, no Retry, and no "no answer" told to the session it names.
    @Test(arguments: [nil, "bm90IHRoZSBob3N0J3M="] as [String?])
    func aPlantedBrowserMarkGetsNoCardNoRetryAndALineWithNoContent(seal: String?) async throws {
        for (index, forgery) in Self.forgeries(of: WalletBrowserDeskTests.request()).enumerated() {
            let logged = WalletBrowserDeskTests.Logged()
            let s = try setup(logged)
            defer { s.desk.close() }
            let filed = WalletBrowserDeskTests.request(20 + index)
            var planted = forgery
            planted.id = filed.id
            try WalletAsk.file(filed, in: s.base.asked)
            try WalletBrowser.setMark(.init(state: .opened, at: WalletDeskTests.created, request: planted, seal: seal), for: filed.id, in: s.base.asked)
            await browser.refreshed(s.desk)
            await noCardNoRetry(s, filed, logged, copy: "browser mark")
        }
    }

    /// A seal that's the host's, but on another request (moved to this one's file) speaks for nothing here.
    @Test func aSealedCopyOfAnotherRequestIsRefused() async throws {
        let logged = WalletBrowserDeskTests.Logged()
        let s = try setup(logged)
        defer { s.desk.close() }
        let filed = WalletBrowserDeskTests.request(30), elsewhere = WalletBrowserDeskTests.request(31)
        try WalletAsk.file(filed, in: s.base.asked)
        let seal = try WalletTestStamps.sealMessage(elsewhere.sealedCopy(.browserMark))
        try WalletBrowser.setMark(.init(state: .noAnswer, at: WalletDeskTests.created, request: elsewhere, seal: seal), for: filed.id, in: s.base.asked)
        await browser.refreshed(s.desk)
        await noCardNoRetry(s, filed, logged, copy: "browser mark")
    }

    /// The normal path, for a record from before seals were kept: equal to the filed request, it offers Retry as ever,
    /// and takes a seal when it's sent again.
    @Test func anUnsealedRecordEqualToTheFiledRequestStillOffersRetry() async throws {
        let logged = WalletBrowserDeskTests.Logged()
        let s = try setup(logged)
        defer { s.desk.close() }
        let request = WalletBrowserDeskTests.request()
        try WalletAsk.file(request, in: s.base.asked)
        try s.base.store.save(WalletRequestStore.Record(request: request, state: .unsure))
        await browser.refreshed(s.desk)
        let card = try #require(s.desk.cards.first)
        #expect(card.state == .unsure(message: nil) && card.actions == [.retry, .discard])
        #expect(s.desk.sessions[request.id] == WalletDeskTests.session.uuidString.lowercased())
        await browser.acted(s.desk, .retry, request.id)
        #expect(s.base.fake.sends.count == 1)
        #expect(!logged.lines.contains { $0.contains("no card and no Retry") })
        let saved = try #require(s.base.store.load().first)
        #expect(saved.seal == (try WalletTestStamps.sealMessage(request.sealedCopy(.record))))
    }

    /// A browser mark from before seals were kept, equal to the filed request, shows as ever.
    @Test func anUnsealedMarkEqualToTheFiledRequestStillShows() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let request = WalletBrowserDeskTests.request()
        try WalletAsk.file(request, in: s.base.asked)
        try WalletBrowser.setMark(.init(state: .rejected, at: WalletDeskTests.created, request: request), for: request.id, in: s.base.asked)
        await browser.refreshed(s.desk)
        #expect(s.desk.cards.first?.state == WalletCardModel.state(.init(state: .rejected, at: WalletDeskTests.created), chainId: request.chainId))
    }

    /// What the app really sent survives a relaunch after the filed request was rewritten: its record is sealed, so the
    /// rewrite can't hide it. The rewrite itself is neither shown nor sent.
    @Test func aSealedRecordSurvivesARelaunchAfterTheFiledRequestWasRewritten() async throws {
        let first = try setup()
        let request = WalletBrowserDeskTests.request()
        try WalletAsk.file(request, in: first.base.asked)
        await browser.refreshed(first.desk)
        await browser.acted(first.desk, .send, request.id)
        #expect(first.base.fake.sends.count == 1)
        #expect(try #require(first.base.store.load().first).seal != nil)
        first.desk.close()
        var rewritten = request
        rewritten.amount = "9000000000000000000"
        try WalletAsk.file(rewritten, in: first.base.asked)

        let logged = WalletBrowserDeskTests.Logged()
        let relaunched = relaunch(first, logged)
        defer { relaunched.desk.close() }
        await browser.refreshed(relaunched.desk)
        let card = try #require(relaunched.desk.cards.first)
        #expect(card.amount == "1.25" && card.state == .sent)
        #expect(!logged.lines.contains { $0.contains("no card and no Retry") })
        // Its results still reach the session that asked.
        try relaunched.base.fake.receive(WalletDeskTests.result(request, .received, sequence: 1), second: 1)
        var polled = false
        relaunched.desk.poll { polled = true }
        _ = await until { polled }
        #expect(await until { relaunched.base.told.messages.count == 1 })
        #expect(relaunched.base.told.messages.first?.session == WalletDeskTests.session.uuidString.lowercased())
    }

    /// The same for what was opened in the browser wallet: a sealed mark keeps its seal through "no answer", and the card
    /// keeps showing what the page was made from, across a relaunch.
    @Test func aSealedMarkSurvivesARelaunchAfterTheFiledRequestWasRewritten() async throws {
        let first = try setup()
        let request = WalletBrowserDeskTests.request()
        _ = try await browser.open(first, request)
        first.desk.close()
        var rewritten = request
        rewritten.amount = "9000000000000000000"
        try WalletAsk.file(rewritten, in: first.base.asked)

        let logged = WalletBrowserDeskTests.Logged()
        let relaunched = relaunch(first, logged)
        defer { relaunched.desk.close() }
        await browser.refreshed(relaunched.desk)
        let card = try #require(relaunched.desk.cards.first)
        #expect(card.amount == "1.25" && card.fileChanged)
        #expect(!logged.lines.contains { $0.contains("no card and no Retry") })
        // "No answer" reached the session, from the sealed copy, and the mark written then keeps the seal.
        #expect(await until { relaunched.base.told.messages.count == 1 })
        #expect(relaunched.base.told.messages.first?.session == WalletDeskTests.session.uuidString.lowercased())
        #expect(await until { WalletBrowser.mark(request.id, in: relaunched.base.asked)?.state == .noAnswer })
        #expect(WalletBrowser.mark(request.id, in: relaunched.base.asked)?.seal != nil)
    }

    /// While the host can't be asked, a copy that differs from the filed request isn't believed; once it answers, it is.
    @Test func aSealedCopyWaitsForTheHost() async throws {
        let logged = WalletBrowserDeskTests.Logged()
        let s = try setup(logged)
        defer { s.desk.close() }
        let request = WalletBrowserDeskTests.request()
        var rewritten = request
        rewritten.amount = "9000000000000000000"
        try WalletAsk.file(rewritten, in: s.base.asked)
        let seal = try WalletTestStamps.sealMessage(request.sealedCopy(.record))
        try s.base.store.save(WalletRequestStore.Record(request: request, state: .sent, seal: seal))
        s.desk.verifyMessages = { _ in throw WalletAsk.Refusal("no session host") }
        await browser.refreshed(s.desk)
        #expect(s.desk.cards.isEmpty)
        s.desk.verifyMessages = WalletTestStamps.verifyMessages
        await browser.refreshed(s.desk)
        #expect(s.desk.cards.first?.amount == "1.25")
    }
}
