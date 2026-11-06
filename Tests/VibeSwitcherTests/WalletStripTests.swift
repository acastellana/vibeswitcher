import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The wallet strip shows only the cards that need the user: a card leaves it once sent and in the Wallet Manager's
/// hands, or finished well, and comes back when a later result needs them (rejected, failed). Dismiss takes a shown
/// final card off for good, across launches, without touching the request's record or what the session is told.
@MainActor
@Suite(.serialized)
struct WalletStripTests {
    static var session: UUID { WalletDeskTests.session }

    /// Every state, with whether the strip shows it. The switch has no default, so a new state can't be added
    /// without a decision here.
    static func expected(_ state: WalletCardModel.State) -> Bool {
        switch state {
        case .waiting, .unreachable, .unsure, .notSent, .rejected, .failed, .expired, .rejectedInWallet, .browserNoAnswer: return true
        case .sent, .received, .proposed, .signedNotSubmitted, .signed, .sentFromBrowser, .inBrowser: return false
        }
    }

    static let hash = WalletCardModelTests.hash
    static let every: [WalletCardModel.State] = [
        .waiting, .sent, .unreachable(message: nil), .unsure(message: "the connection dropped"), .notSent(reason: "refused as a secret"),
        .received, .proposed(safeTxHash: hash), .signedNotSubmitted, .signed(txHash: hash, explorerURL: nil),
        .rejected(reason: "over the limit"), .failed(message: "disconnected"), .expired, .inBrowser,
        .sentFromBrowser(txHash: hash, explorerURL: nil), .rejectedInWallet, .browserNoAnswer,
    ]

    @Test func eachStateHasItsDecision() {
        let shown: [WalletCardModel.State] = [.waiting, .unreachable(message: nil), .unsure(message: "the connection dropped"),
                                              .notSent(reason: "refused as a secret"), .rejected(reason: "over the limit"),
                                              .failed(message: "disconnected"), .expired, .rejectedInWallet, .browserNoAnswer]
        let hidden: [WalletCardModel.State] = [.sent, .received, .proposed(safeTxHash: Self.hash), .signedNotSubmitted,
                                               .signed(txHash: Self.hash, explorerURL: nil), .sentFromBrowser(txHash: Self.hash, explorerURL: nil),
                                               .inBrowser]
        #expect(shown.count + hidden.count == Self.every.count)
        for state in shown { #expect(state.showsOnStrip, "\(state)") }
        for state in hidden { #expect(!state.showsOnStrip, "\(state)") }
        for state in Self.every { #expect(state.showsOnStrip == Self.expected(state), "\(state)") }
        // The shown final ones offer Dismiss; those waiting on the user keep their buttons.
        for state in Self.every {
            let finalShown: Bool = {
                switch state {
                case .rejected, .failed, .expired, .rejectedInWallet, .browserNoAnswer: return true
                default: return false
                }
            }()
            #expect(WalletCardModel.actions(for: state).contains(.dismiss) == finalShown, "\(state)")
        }
        #expect(WalletCardModel.actions(for: .waiting) == [.send, .discard])
        #expect(WalletCardModel.actions(for: .unreachable(message: nil)) == [.retry, .discard])
        #expect(WalletCardModel.Action.dismiss.title == "Dismiss")
    }

    /// Waits until the session's strip lists `count` cards.
    func strip(_ desk: WalletDesk, count: Int) async -> Bool { await until { desk.cards(for: Self.session).count == count } }

    @Test func aSentCardLeavesARejectedOneComesBackAndDismissKeepsItOffAcrossLaunches() async throws {
        let desks = WalletDeskTests()
        let s = try desks.setup()
        let requests = (1...3).map { WalletDeskTests.request($0) }
        for request in requests { try WalletAsk.file(request, in: s.asked) }
        await desks.refreshed(s.desk)
        #expect(await strip(s.desk, count: 3))

        // Sent, and the Wallet Manager has it: off the strip, still on the desk.
        await desks.acted(s.desk, .send, requests[0].id)
        #expect(await strip(s.desk, count: 2))
        #expect(s.desk.cards.first { $0.id == requests[0].id }?.state == .sent)
        #expect(!s.desk.cards(for: Self.session).contains { $0.id == requests[0].id })
        try s.fake.receive(WalletDeskTests.result(requests[0], .received, sequence: 1), second: 1)
        await desks.polled(s.desk)
        #expect(await until { s.desk.cards.first { $0.id == requests[0].id }?.state == .received })
        #expect(s.desk.cards(for: Self.session).map(\.id) == [requests[1].id, requests[2].id])

        // Rejected: back on the strip, showing the rejection, with Dismiss.
        try s.fake.receive(WalletDeskTests.result(requests[0], .rejected, sequence: 2), second: 2)
        await desks.polled(s.desk)
        #expect(await strip(s.desk, count: 3))
        let back = try #require(s.desk.cards(for: Self.session).first { $0.id == requests[0].id })
        #expect(back.state == .rejected(reason: "The Wallet Manager says rejected."))
        #expect(back.actions == [.dismiss])
        #expect(await until { s.told.messages.count == 2 })

        // Dismiss: off again, for good; the record stays and nothing more is told.
        let told = s.told.messages.count
        await desks.acted(s.desk, .dismiss, requests[0].id)
        #expect(await strip(s.desk, count: 2))
        #expect(!s.desk.cards(for: Self.session).contains { $0.id == requests[0].id })
        #expect(FileManager.default.fileExists(atPath: s.store.file(requests[0].id).path))
        #expect(s.desk.cards.contains { $0.id == requests[0].id })
        await desks.refreshed(s.desk)
        #expect(s.told.messages.count == told)
        let file = s.desk.dismissedFile
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        s.desk.close()

        // The next launch: still dismissed.
        let again = WalletDesk(folder: s.asked, store: WalletRequestStore(folder: s.store.folder), inbox: s.fake.inbox,
                               config: { WalletDesk.Config(passage: s.fake.executable, peer: WalletFakePassage.peer) },
                               now: { WalletDeskTests.created.addingTimeInterval(60) }, log: { _ in })
        defer { again.close() }
        again.sessionNames = { WalletDeskTests.names() }
        again.verifyStamps = WalletTestStamps.verify
        again.sealMessage = WalletTestStamps.sealMessage
        again.verifyMessages = WalletTestStamps.verifyMessages
        again.findPassage = { nil }
        again.deliver = { _, _, then in then(.delivered) }
        await desks.refreshed(again)
        #expect(await until { again.cards.count == 3 })
        #expect(again.cards.first { $0.id == requests[0].id }?.state == .rejected(reason: "The Wallet Manager says rejected."))
        #expect(again.cards(for: Self.session).map(\.id) == [requests[1].id, requests[2].id])
    }

    @Test func aFailedResultBringsASentCardBackAndOneFinishedWellStaysOff() async throws {
        let desks = WalletDeskTests()
        let s = try desks.setup()
        defer { s.desk.close() }
        let failing = WalletDeskTests.request(1), signed = WalletDeskTests.request(2)
        for request in [failing, signed] { try WalletAsk.file(request, in: s.asked) }
        await desks.refreshed(s.desk)
        #expect(await strip(s.desk, count: 2))
        await desks.acted(s.desk, .send, failing.id)
        await desks.acted(s.desk, .send, signed.id)
        #expect(await strip(s.desk, count: 0))
        try s.fake.receive(WalletDeskTests.result(signed, .submitted, sequence: 1), second: 1)
        try s.fake.receive(WalletDeskTests.result(failing, .failed, sequence: 1), second: 2)
        await desks.polled(s.desk)
        #expect(await until { s.desk.cards.first { $0.id == signed.id }?.state.isFinished == true })
        #expect(await strip(s.desk, count: 1))
        #expect(s.desk.cards(for: Self.session).first?.state == .failed(message: "The Wallet Manager says failed."))
        #expect(s.desk.cards(for: Self.session).first?.actions == [.dismiss])
    }

    @Test func aSentCardTheWalletManagerDoesntPickUpComesBackToAskWhetherItRuns() async throws {
        let desks = WalletDeskTests()
        let clock = WalletDeskTests.Clock()
        let s = try desks.setup(clock: clock)
        defer { s.desk.close() }
        let request = WalletDeskTests.request()
        try WalletAsk.file(request, in: s.asked)
        await desks.refreshed(s.desk)
        await desks.acted(s.desk, .send, request.id)
        #expect(await strip(s.desk, count: 0))
        clock.now = clock.now.addingTimeInterval(WalletCardModel.notPickedUpAfter)
        await desks.refreshed(s.desk)
        #expect(await strip(s.desk, count: 1))
        let card = try #require(s.desk.cards(for: Self.session).first)
        #expect(card.state == .sent && card.notPickedUp)
    }

    @Test func discardOnAWaitingCardWorksAsBeforeAndADismissalWrittenForItHidesNothing() async throws {
        let desks = WalletDeskTests()
        let s = try desks.setup()
        defer { s.desk.close() }
        let kept = WalletDeskTests.request(1), dropped = WalletDeskTests.request(2)
        for request in [kept, dropped] { try WalletAsk.file(request, in: s.asked) }
        // Someone writes a dismissal for a waiting card: it still shows (only a card offering Dismiss can be dismissed).
        try VibePaths.ensurePrivate(s.store.folder)
        try VibePaths.writePrivate(JSONEncoder().encode([kept.id: WalletDeskTests.created]), to: s.desk.dismissedFile)
        await desks.refreshed(s.desk)
        #expect(await strip(s.desk, count: 2))
        await desks.acted(s.desk, .discard, dropped.id)
        #expect(await strip(s.desk, count: 1))
        #expect(s.desk.cards.map(\.id) == [kept.id])
        #expect(await until { s.told.messages.count == 1 })
        #expect(s.told.messages.first?.text.contains("was discarded by the user. It was not sent to the Wallet Manager.") == true)
        #expect(s.fake.sends.isEmpty)
        // Dismiss isn't offered on a waiting card, so a press does nothing.
        await desks.acted(s.desk, .dismiss, kept.id)
        #expect(s.desk.cards(for: Self.session).map(\.id) == [kept.id])
    }

    @Test func aSessionWithNothingLeftDrawsNothingUnderTheChatOrTheTerminal() async throws {
        let desks = WalletDeskTests()
        let s = try desks.setup()
        defer { s.desk.close() }
        let model = TerminalWalletStripTests.model(hosted: [TerminalWalletStripTests.shell()])
        let terminal = NSHostingView(rootView: TerminalWalletStrip(model: model, desk: s.desk) {}.frame(width: 640))
        terminal.sizingOptions = [.intrinsicContentSize]
        let chat = NSHostingView(rootView: WalletRequestStrip(desk: s.desk, session: Self.session).frame(width: 640))
        chat.sizingOptions = [.intrinsicContentSize]
        func height(_ view: NSView) -> CGFloat {
            view.layoutSubtreeIfNeeded()
            return view.intrinsicContentSize.height
        }

        let request = WalletDeskTests.request()
        try WalletAsk.file(request, in: s.asked)
        await desks.refreshed(s.desk)
        #expect(await strip(s.desk, count: 1))
        #expect(await until { height(terminal) > 40 && height(chat) > 40 })

        await desks.acted(s.desk, .send, request.id)
        #expect(await strip(s.desk, count: 0))
        #expect(s.desk.cards.first?.state == .sent)
        #expect(await until { height(terminal) <= 0.5 && height(chat) <= 0.5 })
    }
}
