import Foundation
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
}
