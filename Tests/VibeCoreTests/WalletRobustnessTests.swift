import Foundation
import Testing
@testable import VibeCore

/// The wallet request plumbing under bursts, crashes and odd input: one `passage inbox` at a time, records read safely
/// and bounded, and a `passage listen` a crash orphaned ended at the next launch. Fake passages in a scratch folder,
/// never the real one.
struct WalletRobustnessTests {
    let scratch = Scratch()
    typealias Fake = PassageLinkTests.FakePassage

    func courier(_ fake: Fake, store: WalletRequestStore? = nil, log: PassageLinkTests.Log = .init(),
                 now: Date = PassageLinkTests.created.addingTimeInterval(30)) -> WalletCourier {
        WalletCourier(link: fake.link, store: store ?? WalletRequestStore(folder: scratch.url("requests")), log: { [log] in log.note($0) },
                      now: { now })
    }

    func inboxRuns(_ fake: Fake) -> Int { fake.calls.filter { $0.hasPrefix("inbox ") }.count }

    // MARK: One poll at a time

    /// Listen lines (and another poll asked) while `passage inbox` runs start no second process: they ask the running
    /// poll to run once more when it's done, once however many asked.
    @Test func listenLinesDuringAPollAskForOneMoreRunNotAnotherProcess() throws {
        let fake = try Fake(scratch)
        let courier = courier(fake)
        defer { courier.close() }
        FileManager.default.createFile(atPath: fake.file("inbox-hold").path, contents: nil)
        let first = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = courier.poll(); first.signal() }
        #expect(eventually { FileManager.default.fileExists(atPath: fake.file("inbox-started").path) })
        for _ in 0..<5 { courier.heardListenLine() }
        let second = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = courier.poll(); second.signal() }
        #expect(eventually { courier.pollsPending == 7 })
        #expect(inboxRuns(fake) == 1)
        try FileManager.default.removeItem(at: fake.file("inbox-hold"))
        FileManager.default.createFile(atPath: fake.file("inbox-go").path, contents: nil)
        #expect(first.wait(timeout: .now() + hangGuard) == .success)
        #expect(second.wait(timeout: .now() + hangGuard) == .success)
        #expect(inboxRuns(fake) == 2)
        #expect(courier.pollsPending == 0)
        // Nothing running: a listen line starts one poll of its own.
        courier.heardListenLine()
        #expect(eventually { courier.pollsPending == 0 && inboxRuns(fake) == 3 })
    }
}
