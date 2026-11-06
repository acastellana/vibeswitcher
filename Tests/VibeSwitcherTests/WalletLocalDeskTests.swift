import Foundation
import Testing
import VibeCore
@testable import VibeSwitcher

/// The wallet desk with the Wallet Manager on this Mac chosen in Settings › Wallet: Send writes the request into the
/// folder pair (`WalletLocalLink`) and the Wallet Manager's result files move the card and reach the asking session,
/// with no Passage; and with a Passage peer chosen, the folders are never touched. The Wallet Manager's side is a
/// stand-in in a scratch home (never the real ~/Library/Application Support), Passage a fake script that logs each run.
@MainActor
@Suite(.serialized)
struct WalletLocalDeskTests {
    let temp = Scratch()
    static let onThisMac = WalletAsk.WalletManager.onThisMac

    /// The Wallet Manager's side of the pair: its folders (0700) once started, `.listening` while it takes requests
    /// from this Mac, and results written under a dot-name and renamed.
    struct Manager {
        let home: URL
        var transport: URL { VibePaths.walletLocalTransport(home: home.path) }
        var to: URL { transport.appendingPathComponent("to-wm", isDirectory: true) }
        var from: URL { transport.appendingPathComponent("from-wm", isDirectory: true) }

        init(_ scratch: Scratch, started: Bool = true) throws {
            home = scratch.url("home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            if started { try start() }
        }

        /// Started with its local transport, and taking requests from this Mac.
        func start() throws {
            for folder in [to, from] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                chmod(folder.path, 0o700)
            }
            let listening = to.appendingPathComponent(".listening")
            try Data("\(getpid())\n".utf8).write(to: listening)
            chmod(listening.path, 0o600)
        }

        func stopAccepting() throws { try FileManager.default.removeItem(at: to.appendingPathComponent(".listening")) }

        func answer(_ result: WalletResult) throws {
            let name = "wallet-result-\(result.id)-\(result.sequence).json"
            let temporary = from.appendingPathComponent(".\(name).tmp")
            try result.encoded().write(to: temporary)
            chmod(temporary.path, 0o600)
            try FileManager.default.moveItem(at: temporary, to: from.appendingPathComponent(name))
        }

        func request(_ id: String) -> URL { to.appendingPathComponent("wallet-request-\(id).json") }

        /// Every path under the home, with each one's kind, mode and size.
        var everything: [String] {
            ((try? FileManager.default.subpathsOfDirectory(atPath: home.path)) ?? []).sorted().map { path in
                var info = stat()
                lstat(home.appendingPathComponent(path).path, &info)
                return "\(path) \(info.st_mode) \(info.st_size)"
            }
        }
    }

    struct Setup {
        let fake: WalletFakePassage
        let manager: Manager
        let desk: WalletDesk
        let asked: URL
        let store: WalletRequestStore
        let told: WalletDeskTests.Told
        let choice: Choice
        let looked: Choice
        /// The passage path Settings › Wallet has (the fake's, unless a test clears it).
        let path: Choice
    }

    /// What Settings › Wallet has chosen, changed as a test goes; and, for `looked`, whether Passage was looked for.
    final class Choice: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String
        init(_ value: String) { self.value = value }
        var peer: String {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// A desk whose Settings have `peer` chosen (the Wallet Manager on this Mac unless given), a fake Passage it could
    /// run, and the Wallet Manager's stand-in.
    func setup(peer: String = WalletLocalDeskTests.onThisMac, started: Bool = true) throws -> Setup {
        let fake = try WalletFakePassage(temp)
        let manager = try Manager(temp, started: started)
        let asked = temp.url("asked")
        let store = WalletRequestStore(folder: temp.url("requests"))
        let choice = Choice(peer), looked = Choice(""), path = Choice(fake.executable)
        let clock = WalletDeskTests.Clock()
        let desk = WalletDesk(folder: asked, store: store, inbox: fake.inbox, local: WalletLocalLink(home: manager.home.path),
                              config: { WalletDesk.Config(passage: path.peer, peer: choice.peer) }, now: { clock.now }, log: { _ in })
        desk.sessionNames = { WalletDeskTests.names() }
        desk.verifyStamps = WalletTestStamps.verify
        desk.sealMessage = WalletTestStamps.sealMessage
        desk.verifyMessages = WalletTestStamps.verifyMessages
        desk.findPassage = {
            looked.peer = "looked"
            return nil
        }
        let told = WalletDeskTests.Told()
        desk.deliver = { session, text, then in told.messages.append((session, text)); then(.delivered) }
        return Setup(fake: fake, manager: manager, desk: desk, asked: asked, store: store, told: told, choice: choice, looked: looked, path: path)
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

    func records(_ store: WalletRequestStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.folder.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
    }

    /// Send on a waiting card writes the request's file into to-wm and the card reads sent; each result file that
    /// appears in from-wm moves the card (no one asks: the watch on the folder hears it) and goes to the asking
    /// session, worded as a result from Passage is.
    @Test func sendWritesTheFileAndResultFilesMoveTheCardAndReachTheSession() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let request = WalletDeskTests.request()
        try WalletAsk.file(request, in: s.asked)
        await refreshed(s.desk)
        let card = try #require(s.desk.cards(for: WalletDeskTests.session).first)
        #expect(card.state == .waiting && card.actions == [.send, .discard] && card.setupNeeded == nil)
        // Nothing goes before the click.
        #expect(!FileManager.default.fileExists(atPath: s.manager.request(request.id).path))

        await acted(s.desk, .send, request.id)
        #expect(try Data(contentsOf: s.manager.request(request.id)) == request.encoded())
        var info = stat()
        #expect(lstat(s.manager.request(request.id).path, &info) == 0 && info.st_mode & 0o7777 == 0o600)
        let sent = try #require(s.desk.cards.first)
        #expect(sent.state == .sent && sent.actions == [])
        #expect(sent.detail == "Sent to the Wallet Manager on this Mac. Waiting for it to answer.")
        #expect(records(s.store) == ["\(request.id).json"])
        // A second Send isn't offered once it went.
        await acted(s.desk, .send, request.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.manager.to.path).sorted() == [".listening", "wallet-request-\(request.id).json"])

        // The Wallet Manager's first answer: the card reads received as its file appears.
        let received = WalletDeskTests.result(request, .received, sequence: 1)
        try s.manager.answer(received)
        #expect(await until { s.desk.cards.first?.state == .received })
        #expect(await until { s.told.messages.count == 1 })
        #expect(s.desk.cards.first?.checks == [.init(name: "balance", ok: true, detail: "covers it")])
        #expect(s.told.messages[0].text == WalletCardModel.message(for: received, request: request))
        #expect(s.told.messages[0].text.hasSuffix("More answers may follow."))

        // Its last: a final status.
        let submitted = WalletDeskTests.result(request, .submitted, sequence: 2)
        try s.manager.answer(submitted)
        let hash = "0x" + String(repeating: "ab", count: 32)
        #expect(await until { s.desk.cards.first?.state == .signed(txHash: hash, explorerURL: URL(string: "https://explorer.example/tx/" + hash)) })
        #expect(await until { s.told.messages.count == 2 })
        #expect(s.told.messages.map(\.session) == [WalletDeskTests.session.uuidString.lowercased(), WalletDeskTests.session.uuidString.lowercased()])
        #expect(s.told.messages[1].text == WalletCardModel.message(for: submitted, request: request))
        #expect(s.told.messages[1].text.hasSuffix("This request is finished."))
        // One after the final status changes nothing, and is told to no one.
        try s.manager.answer(WalletDeskTests.result(request, .failed, sequence: 3))
        var polled = false
        s.desk.poll { polled = true }
        _ = await until { polled }
        #expect(s.desk.cards.first?.state == .signed(txHash: hash, explorerURL: URL(string: "https://explorer.example/tx/" + hash)))
        #expect(s.told.messages.count == 2)
        // Passage had no part in any of it.
        #expect(s.fake.calls.isEmpty && s.looked.peer.isEmpty)
    }

    /// With no to-wm (the Wallet Manager never started with its local transport) the card reads unreachable, with
    /// Retry, and says so; nothing is written anywhere. Started but not taking requests: the same, saying that. Once
    /// it does, Retry sends it.
    @Test func withToWMMissingTheCardReadsUnreachableWithRetryAndNothingIsWritten() async throws {
        let s = try setup(started: false)
        defer { s.desk.close() }
        let request = WalletDeskTests.request()
        try WalletAsk.file(request, in: s.asked)
        await refreshed(s.desk)
        #expect(s.desk.cards.first?.actions == [.send, .discard])
        await acted(s.desk, .send, request.id)
        var card = try #require(s.desk.cards.first)
        let notRunning = "The Wallet Manager isn't running with its local transport on this Mac (to-wm is missing)"
        #expect(card.state == .unreachable(message: notRunning))
        #expect(card.actions == [.retry, .discard])
        #expect(card.detail == notRunning + ". Nothing was sent.")
        #expect(WalletCardModel.title(card.state) == "Wallet Manager not reachable")
        // Nothing anywhere: no folder made under the home, no record of a send.
        #expect(s.manager.everything.isEmpty)
        #expect(records(s.store).isEmpty)
        // Retry while it's still missing: the same.
        await acted(s.desk, .retry, request.id)
        #expect(s.desk.cards.first?.state == .unreachable(message: notRunning))
        #expect(s.manager.everything.isEmpty && records(s.store).isEmpty)

        // Started, its user not yet accepting this Mac's requests (no .listening).
        try s.manager.start()
        try s.manager.stopAccepting()
        let before = s.manager.everything
        await acted(s.desk, .retry, request.id)
        card = try #require(s.desk.cards.first)
        #expect(card.actions == [.retry, .discard])
        #expect(card.detail == "The Wallet Manager on this Mac isn't accepting requests (no readable .listening in to-wm): start it with its local "
                + "transport and accept this Mac's requests there. Nothing was sent.")
        #expect(s.manager.everything == before && records(s.store).isEmpty)

        // Accepting: Retry sends it.
        try s.manager.start()
        await acted(s.desk, .retry, request.id)
        #expect(s.desk.cards.first?.state == .sent)
        #expect(try Data(contentsOf: s.manager.request(request.id)) == request.encoded())
        #expect(s.told.messages.isEmpty && s.fake.calls.isEmpty)
    }

    /// A request marked LOCAL FORK ONLY in its reason goes as any other: the file in to-wm is the filed request, byte
    /// for byte.
    @Test func aRequestMarkedLocalForkOnlyIsSentByteForByte() async throws {
        let s = try setup()
        defer { s.desk.close() }
        var request = WalletDeskTests.request()
        request.from = "0x00000000000000000000000000000000000000aa"
        request.reason = "LOCAL FORK ONLY: fund the example account on the local fork (chain 31337 stand-in). Never a real network."
        try WalletAsk.file(request, in: s.asked)
        let filed = try Data(contentsOf: s.asked.appendingPathComponent("\(request.id).json"))
        await refreshed(s.desk)
        #expect(s.desk.cards.first?.reason == request.reason)
        await acted(s.desk, .send, request.id)
        #expect(s.desk.cards.first?.state == .sent)
        let sent = try Data(contentsOf: s.manager.request(request.id))
        #expect(sent == filed)
        #expect(sent == (try request.encoded()))
        #expect(String(decoding: sent, as: UTF8.self).contains("LOCAL FORK ONLY: fund the example account"))
    }

    /// Never both, one way: with the Wallet Manager on this Mac chosen, nothing runs `passage` (not send, inbox or
    /// listen, nor a look for it), through a request's whole life and the discarding of another.
    @Test func withTheLocalTransportChosenNothingRunsPassage() async throws {
        let s = try setup()
        defer { s.desk.close() }
        let request = WalletDeskTests.request(), other = WalletDeskTests.request(2)
        try WalletAsk.file(request, in: s.asked)
        try WalletAsk.file(other, in: s.asked)
        await refreshed(s.desk)
        await acted(s.desk, .send, request.id)
        await refreshed(s.desk)
        var polled = false
        s.desk.poll { polled = true }
        _ = await until { polled }
        try s.manager.answer(WalletDeskTests.result(request, .rejected, sequence: 1))
        #expect(await until { s.told.messages.count == 1 })
        await acted(s.desk, .discard, other.id)
        await refreshed(s.desk)
        #expect(s.desk.cards.map(\.id) == [request.id])
        #expect(s.fake.calls.isEmpty, "\(s.fake.calls)")
        #expect(s.looked.peer.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: s.fake.file("sent-wallet-request-\(request.id).json").path))
        #expect(!FileManager.default.fileExists(atPath: WalletCourier.ListenRecord.file(in: s.store.folder).path))
    }

    /// Never both, the other way: with a Passage peer chosen, nothing is written to the local folders and nothing is
    /// read from them, though the Wallet Manager on this Mac is there, taking requests, with a result for the very
    /// request waiting in from-wm.
    @Test func withAPassagePeerChosenTheLocalFoldersAreNeverTouched() async throws {
        let s = try setup(peer: WalletFakePassage.peer)
        defer { s.desk.close() }
        let request = WalletDeskTests.request()
        try s.manager.answer(WalletDeskTests.result(request, .rejected, sequence: 1))
        let before = s.manager.everything
        try WalletAsk.file(request, in: s.asked)
        await refreshed(s.desk)
        await acted(s.desk, .send, request.id)
        #expect(s.fake.sends.count == 1)
        #expect(s.desk.cards.first?.state == .sent)
        #expect(s.desk.cards.first?.detail == "Sent through Passage. Waiting for the Wallet Manager to answer.")
        // Looked for results, the way Passage's are: the one in from-wm isn't taken.
        var polled = false
        s.desk.poll { polled = true }
        _ = await until { polled }
        await refreshed(s.desk)
        #expect(s.fake.calls.contains("inbox \(WalletFakePassage.peer) --json"))
        #expect(s.desk.cards.first?.state == .sent)
        #expect(s.told.messages.isEmpty)
        #expect(s.store.load().first?.results.isEmpty == true)
        #expect(s.manager.everything == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.manager.to.path) == [".listening"])

        // Passage's own result for it is the one that counts.
        try s.fake.receive(WalletDeskTests.result(request, .received, sequence: 1), second: 1)
        polled = false
        s.desk.poll { polled = true }
        _ = await until { polled }
        #expect(await until { s.told.messages.count == 1 })
        #expect(s.desk.cards.first?.state == .received)
        #expect(s.manager.everything == before)
    }

    /// Settings › Wallet changed from a Passage peer to the Wallet Manager on this Mac: the next request goes through
    /// the folder, and from then on Passage isn't run.
    @Test func choosingThisMacInSettingsMovesTheNextSendToTheFolder() async throws {
        let s = try setup(peer: WalletFakePassage.peer)
        defer { s.desk.close() }
        let first = WalletDeskTests.request(), second = WalletDeskTests.request(2)
        try WalletAsk.file(first, in: s.asked)
        await refreshed(s.desk)
        await acted(s.desk, .send, first.id)
        #expect(s.fake.sends.count == 1)
        try s.fake.receive(WalletDeskTests.result(first, .rejected, sequence: 1), second: 1)
        var polled = false
        s.desk.poll { polled = true }
        _ = await until { polled }
        #expect(await until { s.told.messages.count == 1 })

        s.choice.peer = Self.onThisMac
        try WalletAsk.file(second, in: s.asked)
        await refreshed(s.desk)
        let calls = s.fake.calls
        #expect(s.desk.cards.last?.actions == [.send, .discard])
        await acted(s.desk, .send, second.id)
        #expect(try Data(contentsOf: s.manager.request(second.id)) == second.encoded())
        #expect(s.desk.cards.last?.state == .sent)
        try s.manager.answer(WalletDeskTests.result(second, .received, sequence: 1))
        #expect(await until { s.desk.cards.last?.state == .received })
        #expect(s.fake.calls == calls)
    }

    /// Settings › Wallet changed away from the Wallet Manager on this Mac while a request is outstanding, to no
    /// Wallet Manager at all or to a peer with no Passage to run: the folder is no longer watched, and a result that
    /// appears in from-wm is not read (nothing recorded, the card unmoved, the session not told) until this Mac is
    /// chosen again, when it is taken as ever.
    @Test(arguments: ["", WalletFakePassage.peer])
    func switchingAwayFromThisMacStopsTheWatchAndNothingReadsFromWM(away: String) async throws {
        let s = try setup()
        defer { s.desk.close() }
        let request = WalletDeskTests.request()
        try WalletAsk.file(request, in: s.asked)
        await refreshed(s.desk)
        await acted(s.desk, .send, request.id)
        #expect(s.desk.cards.first?.state == .sent)
        // Outstanding: from-wm is watched.
        #expect(s.desk.isListening)

        // None chosen; or a peer, with no passage path set and none found.
        s.choice.peer = away
        s.path.peer = ""
        await refreshed(s.desk)
        #expect(!s.desk.isListening)
        let card = try #require(s.desk.cards.first)
        #expect(card.state == .sent && card.actions == [])
        #expect(card.setupNeeded == (away.isEmpty ? WalletCardModel.noPeerNote : WalletCardModel.noPassageNote))

        // The Wallet Manager answers meanwhile: no one reads it, however often the desk looks.
        try s.manager.answer(WalletDeskTests.result(request, .rejected, sequence: 1))
        for _ in 0..<2 {
            var polled = false
            s.desk.poll { polled = true }
            _ = await until { polled }
            await refreshed(s.desk)
        }
        #expect(!s.desk.isListening)
        #expect(s.store.load().first?.results.isEmpty == true)
        #expect(s.desk.cards.first?.state == .sent)
        #expect(s.told.messages.isEmpty)
        #expect(s.fake.calls.isEmpty, "\(s.fake.calls)")

        // Chosen again: the result waiting there is taken, once.
        s.choice.peer = Self.onThisMac
        var polled = false
        s.desk.poll { polled = true }
        _ = await until { polled }
        #expect(await until { s.told.messages.count == 1 })
        #expect(await until { if case .rejected = s.desk.cards.first?.state { true } else { false } })
        #expect(s.desk.cards.first?.detail.hasPrefix("The Wallet Manager on this Mac refused it: ") == true)
        #expect(s.store.load().first?.results.map(\.sequence) == [1])
    }

    // MARK: Settings › Wallet and the card's words

    @Test func settingsOfferThisMacKeepItAndSayWhatItNeeds() throws {
        let defaults = temp.defaults("wallet-settings")
        let presets = temp.url("wallet-settings-presets")
        let preferences = Preferences(defaults: defaults, presetsFile: presets)
        let peers = [WalletPeerChoice(peerID: "0a1b2c3d", name: "Example Wallet Manager Mac")]
        #expect(WalletSettingsTab.onThisMac == "this-mac" && WalletSettingsTab.onThisMacTitle == "Wallet Manager on this Mac")
        preferences.walletPeerID = WalletSettingsTab.onThisMac
        // Kept across launches, as the CLI reads it too.
        let again = Preferences(defaults: defaults, presetsFile: presets)
        #expect(again.walletPeerID == WalletSettingsTab.onThisMac)
        #expect(defaults.string(forKey: "walletPeerID") == "this-mac")
        #expect(WalletAsk.WalletManager.from(peer: again.walletPeerID, passagePath: again.walletPassagePath, path: nil, apps: []) == .ready)
        // Its own row beside the peers, never "Not found now": the picker's rows are the peers as they are.
        #expect(WalletSettingsTab.choices(peers, saved: again.walletPeerID) == peers)
        #expect(WalletSettingsTab.choices([], saved: again.walletPeerID).isEmpty)
        // One line saying what it needs.
        let line = WalletSettingsTab.status(peers, saved: again.walletPeerID)
        #expect(line == WalletSettingsTab.onThisMacNote)
        #expect(line.contains("it needs the Wallet Manager started with its local transport") && !line.contains("\n"))
        // A peer chosen again reads as before.
        #expect(WalletSettingsTab.status(peers, saved: "0a1b2c3d").contains("Requests go to Example Wallet Manager Mac"))
    }

    /// The lines that name the way to the Wallet Manager say this Mac's folder with it chosen, and Passage otherwise;
    /// every other line is the same.
    @Test func theCardNamesTheWayOnlyWhereItSaysOne() {
        var card = WalletCardModel(request: WalletDeskTests.request(), requestedBy: "Example session", state: .sent)
        #expect(card.detail == "Sent through Passage. Waiting for the Wallet Manager to answer.")
        card.onThisMac = true
        #expect(card.detail == "Sent to the Wallet Manager on this Mac. Waiting for it to answer.")
        card.notPickedUp = true
        #expect(card.detail.hasSuffix("Delivered to the Wallet Manager's folder on this Mac, but it hasn't picked it up yet. Is the Wallet Manager running?"))
        card.notPickedUp = false
        card.state = .unreachable(message: nil)
        #expect(card.detail == "The Wallet Manager isn't running with its local transport on this Mac. Nothing was sent.")
        #expect(card.actions == [.retry, .discard])
        card.state = .unsure(message: nil)
        #expect(card.detail.hasPrefix("It may have reached the Wallet Manager on this Mac: its answer shows here if it did.") && !card.detail.contains("Passage"))
        for state in [WalletCardModel.State.waiting, .expired, .notSent(reason: "no"), .inBrowser, .rejectedInWallet, .browserNoAnswer,
                      .sentFromBrowser(txHash: "0xab", explorerURL: nil)] {
            card.state = state
            #expect(card.detail == WalletCardModel.detail(state, wallet: nil), "\(state)")
        }
    }

    /// A card answered by the Wallet Manager on this Mac says this Mac: never "the Wallet Manager's Mac", "there" or
    /// "the person at" it, in any state the Wallet Manager's answers lead to, for any kind of wallet. With a Passage
    /// peer chosen each line is as it was.
    @Test func aCardAnsweredOnThisMacNeverNamesAnotherMac() throws {
        let hash = "0x" + String(repeating: "ab", count: 32)
        let answered: [WalletCardModel.State] = [.received, .proposed(safeTxHash: nil), .proposed(safeTxHash: hash), .signedNotSubmitted,
                                                 .signed(txHash: hash, explorerURL: nil), .rejected(reason: "over the limit"),
                                                 .failed(message: "the node didn't answer")]
        var card = WalletCardModel(request: WalletDeskTests.request(), requestedBy: "Example session", state: .received)
        for wallet in [nil] + WalletCardModel.Wallet.allCases.map(Optional.some) {
            card.wallet = wallet
            for state in answered {
                card.state = state
                card.onThisMac = false
                #expect(card.detail == WalletCardModel.detail(state, wallet: wallet), "\(state) \(String(describing: wallet))")
                card.onThisMac = true
                for other in ["Wallet Manager's Mac", "there", "the person at", "Passage"] {
                    #expect(!card.detail.contains(other), "\(state) \(String(describing: wallet)): \(card.detail)")
                }
                // Copy carries the same line.
                #expect(card.text.contains(card.detail))
            }
        }
        card.onThisMac = true
        card.wallet = nil
        card.state = .received
        #expect(card.detail == "The Wallet Manager on this Mac has it and is checking it. It's signed in the Wallet Manager, not in VibeSwitcher.")
        card.wallet = .hardware
        #expect(card.detail == "The Wallet Manager on this Mac has it and is checking it. Sign it in the Wallet Manager, on the hardware wallet.")
        card.wallet = .hot
        #expect(card.detail == "The Wallet Manager on this Mac has it and is checking it.")
        card.wallet = .safe
        #expect(card.detail == "The Wallet Manager on this Mac has it and is checking it. Sign it in the Wallet Manager to propose it to the Safe.")
        // A Safe's proposal and signing name no Mac: the same either way.
        card.state = .proposed(safeTxHash: hash)
        #expect(card.detail == "Proposed to the Safe: waiting for the other owners' signatures.")
        card.state = .signed(txHash: hash, explorerURL: nil)
        #expect(card.detail == "Signed by the Safe's owners and submitted.")
        card.wallet = .hardware
        #expect(card.detail == "Signed in the Wallet Manager on this Mac and submitted.")
        card.state = .proposed(safeTxHash: nil)
        #expect(card.detail == "Proposed: waiting for you to sign it in the Wallet Manager on this Mac.")
        card.state = .signedNotSubmitted
        #expect(card.detail == "Signed in the Wallet Manager on this Mac; waiting for it to be submitted to the chain.")
        card.state = .rejected(reason: "over the limit")
        #expect(card.detail == "The Wallet Manager on this Mac refused it: over the limit")
        card.state = .failed(message: "the node didn't answer")
        #expect(card.detail == "The Wallet Manager on this Mac couldn't finish it: the node didn't answer")
    }
}
