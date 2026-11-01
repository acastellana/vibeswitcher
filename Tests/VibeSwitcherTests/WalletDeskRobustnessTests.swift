import AppKit
import Foundation
import SwiftUI
import Testing
import VibeCore
@testable import VibeSwitcher

/// The wallet desk under odd input and bursts: a passage path being typed in Settings › Wallet is never run, the cards
/// are capped, and many cards cost memory only for the few drawn. Fake passages in a scratch folder, never the real one.
@MainActor
@Suite(.serialized)
struct WalletDeskRobustnessTests {
    let temp = Scratch()

    /// Pauses a test's `WalletPeerList` waits for, run when the test says (no clock waits).
    final class Pauses {
        var pending: [() -> Void] = []
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            #expect(delay == WalletPeerList.settlePause)
            pending.append(work)
        }
        /// Runs every pause armed so far, oldest first: only the last keystroke's applies.
        func elapse() {
            let due = pending
            pending = []
            for work in due { work() }
        }
    }

    final class Loads: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func note(_ path: String) { lock.withLock { paths.append(path) } }
        var all: [String] { lock.withLock { paths } }
    }

    func refreshed(_ desk: WalletDesk) async {
        var done = false
        desk.refresh(polling: false) { done = true }
        _ = await until { done }
    }

    /// A desk whose passage path is the list's settled one, as the app wires it, with a request outstanding in the
    /// store (so a courier made would start `passage listen` at once) and its filed copy showing a card.
    func typingSetup() throws -> (fake: WalletFakePassage, desk: WalletDesk, list: WalletPeerList, pauses: Pauses, loads: Loads) {
        let fake = try WalletFakePassage(temp, app: true)
        let pauses = Pauses()
        let loads = Loads()
        let list = WalletPeerList(settledPath: "", load: { path in
            loads.note(path)
            return WalletPeerList.Read(passage: nil, peers: nil)
        }, schedule: { pauses.schedule($0, $1) })
        let asked = temp.url("asked")
        let store = WalletRequestStore(folder: temp.url("requests"))
        let request = WalletDeskTests.request()
        try WalletAsk.file(request, in: asked)
        try store.save(WalletRequestStore.Record(request: request, state: .sent))
        let desk = WalletDesk(folder: asked, store: store, inbox: fake.inbox,
                              config: { [list] in WalletDesk.Config(passage: list.settledPath, peer: WalletFakePassage.peer) },
                              now: { WalletDeskTests.created.addingTimeInterval(30) }, log: { _ in })
        desk.sessionNames = { WalletDeskTests.names() }
        desk.verifyStamps = WalletTestStamps.verify
        desk.sealMessage = WalletTestStamps.sealMessage
        desk.verifyMessages = WalletTestStamps.verifyMessages
        desk.findPassage = { nil }
        return (fake, desk, list, pauses, loads)
    }

    /// Typing Passage.app's path one key at a time, with the desk looking after every key (as its 15 s look or a
    /// filed request would): nothing runs, not even a prefix that is itself a program (`…/Pass`, a stand-in that
    /// notes it ran). Only once typing paused is the path used: the courier is made then, and `cli listen` runs.
    @Test func aPassagePathBeingTypedIsNeverRun() async throws {
        let (fake, desk, list, pauses, loads) = try typingSetup()
        defer { desk.close() }
        let target = fake.app.path
        let prefix = fake.folder.appendingPathComponent("Pass").path
        try "#!/bin/sh\ntouch \"\(fake.file("prefix-ran").path)\"\n".write(toFile: prefix, atomically: true, encoding: .utf8)
        chmod(prefix, 0o755)
        #expect(target.hasPrefix(prefix) && PassageCommand.runnable(prefix) != nil)
        var typed = ""
        for character in target {
            typed.append(character)
            list.typed(typed)
            await refreshed(desk)
        }
        #expect(fake.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fake.file("prefix-ran").path))
        #expect(loads.all.isEmpty && list.settledPath == "")
        // Typing paused: only the last keystroke's path is taken, and the peers are read through it, once.
        pauses.elapse()
        #expect(list.settledPath == target)
        #expect(await until { loads.all == [target] })
        await refreshed(desk)
        #expect(await until { fake.calls.contains("cli listen") })
        #expect(fake.calls.allSatisfy { $0.hasPrefix("cli ") })
        #expect(!FileManager.default.fileExists(atPath: fake.file("prefix-ran").path))
    }

    /// Typing paused on a path that names nothing that can run (a missing file, a folder): still nothing runs, and the
    /// card and Settings say why.
    @Test(arguments: ["Passage.ap", "Passage.app/Contents", ""])
    func aSettledPathThatCantRunRunsNothing(_ tail: String) async throws {
        let (fake, desk, list, pauses, _) = try typingSetup()
        defer { desk.close() }
        let path = tail.isEmpty ? fake.folder.path : fake.folder.appendingPathComponent(tail).path
        list.typed(path)
        pauses.elapse()
        #expect(list.settledPath == path)
        await refreshed(desk)
        #expect(fake.calls.isEmpty)
        #expect(desk.cards.first?.setupNeeded == WalletCardModel.passageNotRunnableNote)
        #expect(WalletSettingsTab.using(nil, read: true, path: path) == WalletSettingsTab.notRunnableNote)
        #expect(WalletSettingsTab.using(nil, read: true, path: "relative/passage") == "This path isn't absolute.")
    }

    // MARK: Times and the cap

    func plainDesk(now: Date = WalletDeskTests.created.addingTimeInterval(30)) throws -> (fake: WalletFakePassage, desk: WalletDesk, asked: URL, store: WalletRequestStore) {
        let fake = try WalletFakePassage(temp)
        let asked = temp.url("asked")
        let store = WalletRequestStore(folder: temp.url("requests"))
        let desk = WalletDesk(folder: asked, store: store, inbox: fake.inbox,
                              config: { WalletDesk.Config(passage: fake.executable, peer: WalletFakePassage.peer) }, now: { now }, log: { _ in })
        desk.sessionNames = { WalletDeskTests.names() }
        desk.verifyStamps = WalletTestStamps.verify
        desk.sealMessage = WalletTestStamps.sealMessage
        desk.verifyMessages = WalletTestStamps.verifyMessages
        desk.findPassage = { nil }
        return (fake, desk, asked, store)
    }

    /// A filed request whose createdAt is more than 5 minutes ahead of this Mac's clock is refused and removed; one a
    /// few minutes ahead (a clock a little off) shows.
    @Test func aFiledRequestFromTheFutureIsRefused() async throws {
        let (fake, desk, asked, _) = try plainDesk()
        defer { desk.close() }
        var ahead = WalletDeskTests.request(1)
        ahead.createdAt = WalletDeskTests.created.addingTimeInterval(30 + 301)
        ahead.expiresAt = ahead.createdAt.addingTimeInterval(3600)
        var slightly = WalletDeskTests.request(2)
        slightly.createdAt = WalletDeskTests.created.addingTimeInterval(30 + 240)
        slightly.expiresAt = slightly.createdAt.addingTimeInterval(3600)
        try WalletAsk.file(ahead, in: asked)
        try WalletAsk.file(slightly, in: asked)
        await refreshed(desk)
        #expect(desk.cards.map(\.id) == [slightly.id])
        #expect(!FileManager.default.fileExists(atPath: asked.appendingPathComponent("\(ahead.id).json").path))
        #expect(!FileManager.default.fileExists(atPath: WalletAsk.stampFile(ahead.id, in: asked).path))
        #expect(fake.calls.isEmpty)
    }

    /// Past `maxCards` the oldest finished cards give way first, then the oldest of any; the order stays.
    @Test func theCardsAreCappedOldestFinishedFirst() {
        func card(_ number: Int, _ state: WalletCardModel.State) -> WalletCardModel {
            WalletCardModel(request: WalletDeskTests.request(number), requestedBy: "Example session", label: "Example agent", state: state)
        }
        let cards = [card(1, .waiting), card(2, .expired), card(3, .sent), card(4, .rejected(reason: "no")), card(5, .waiting)]
        #expect(WalletDesk.capped(cards, limit: 5).map(\.id) == cards.map(\.id))
        #expect(WalletDesk.capped(cards, limit: 4).map(\.id) == [1, 3, 4, 5].map { WalletDeskTests.request($0).id })
        #expect(WalletDesk.capped(cards, limit: 3).map(\.id) == [1, 3, 5].map { WalletDeskTests.request($0).id })
        #expect(WalletDesk.capped(cards, limit: 2).map(\.id) == [3, 5].map { WalletDeskTests.request($0).id })
    }

    /// Many requests filed: at most `maxCards` cards, the newest ones; the rest keep their files.
    @Test func manyFiledRequestsShowAtMostTheCap() async throws {
        let (_, desk, asked, _) = try plainDesk()
        defer { desk.close() }
        let count = WalletDesk.maxCards + 5
        for number in 1...count {
            var request = WalletDeskTests.request(number)
            request.createdAt = WalletDeskTests.created.addingTimeInterval(TimeInterval(number - count))
            try WalletAsk.file(request, in: asked)
        }
        await refreshed(desk)
        #expect(desk.cards.count == WalletDesk.maxCards)
        #expect(desk.cards.first?.id == WalletDeskTests.request(6).id && desk.cards.last?.id == WalletDeskTests.request(count).id)
        #expect(desk.sessions.count == WalletDesk.maxCards)
        #expect(FileManager.default.fileExists(atPath: asked.appendingPathComponent("\(WalletDeskTests.request(1).id).json").path))
    }

    /// At launch (`start`) records past their results window by 30 days go, and a stale listener record is cleared.
    @Test func startPrunesOldRecordsAndClearsAStaleListenerRecord() async throws {
        let request = WalletDeskTests.request(1)
        let now = request.expiresAt.addingTimeInterval(WalletCourier.resultGrace + WalletRequestStore.keptAfterWindow)
        let (_, desk, _, store) = try plainDesk(now: now)
        defer { desk.close() }
        try store.save(.init(request: request, state: .sent))
        // A pid record whose process is long gone (pid 1's start time isn't this).
        try VibePaths.writePrivate(Data("1 1 1\n/opt/example/bin/passage\n".utf8), to: WalletCourier.ListenRecord.file(in: store.folder))
        desk.start(interval: 3600)
        #expect(await until { !FileManager.default.fileExists(atPath: store.file(request.id).path) })
        #expect(!FileManager.default.fileExists(atPath: WalletCourier.ListenRecord.file(in: store.folder).path))
    }

    // MARK: The strip

    /// The views under `view`, itself included.
    static func viewCount(_ view: NSView) -> Int { 1 + view.subviews.reduce(0) { $0 + viewCount($1) } }

    /// The strip draws only the cards in its 380 points: its views (and the memory they hold) stay about those of the
    /// first few cards whether 3 or the cap are live. Drawn eagerly, 30 cards made about ten times 3's.
    @Test func theStripDrawsOnlyTheCardsInView() async throws {
        func hostedViews(_ count: Int) async throws -> Int {
            let scratch = Scratch()
            let fake = try WalletFakePassage(scratch)
            let asked = scratch.url("asked")
            let desk = WalletDesk(folder: asked, store: WalletRequestStore(folder: scratch.url("requests")), inbox: fake.inbox,
                                  config: { WalletDesk.Config(passage: fake.executable, peer: WalletFakePassage.peer) },
                                  now: { WalletDeskTests.created.addingTimeInterval(30) }, log: { _ in })
            desk.sessionNames = { WalletDeskTests.names() }
            desk.verifyStamps = WalletTestStamps.verify
            desk.sealMessage = WalletTestStamps.sealMessage
            desk.verifyMessages = WalletTestStamps.verifyMessages
            defer { desk.close() }
            for number in 1...count { try WalletAsk.file(WalletDeskTests.request(number), in: asked) }
            await refreshed(desk)
            #expect(desk.cards(for: WalletDeskTests.session).count == count)
            let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 640, height: 600), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: WalletRequestStrip(desk: desk, session: WalletDeskTests.session).frame(width: 640, height: 600))
            window.contentView = host
            window.orderFrontRegardless()
            var views = 0
            // Settled: the same count twice running once laid out.
            _ = await until {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let now = Self.viewCount(host)
                defer { views = now }
                return now == views && now > 1
            }
            return views
        }
        let few = try await hostedViews(3)
        let many = try await hostedViews(WalletDesk.maxCards)
        #expect(many <= few + few / 2, "\(WalletDesk.maxCards) cards made \(many) views, 3 made \(few)")
    }
}
