import Foundation
import Testing
@testable import VibeCore
@testable import VibeNode

/// The room watch (the engine plan's E7; the app's `watchRoom` and `lookAtRoom`): a lead refused for the machine's room
/// or load is told once there's room again, as the witness. Its waits and the sleep ledger are read on the engine's
/// reads queue, never its own. On an engine whose link reaches no host (none is needed: the waits are files under the
/// root, and a project with no lead running holds what's told), so the Mac's core job runs it too.
@Suite(.timeLimit(.minutes(2)))
struct RoomWatchTests {
    private let scratch = Scratch()

    /// A link to no host: its dialer never connects, so the link's list is empty.
    private struct NoHost: HostDialer {
        func connect(queue: DispatchQueue, patience: TimeInterval) throws -> HostConnection { throw HostLink.Failure("no host in this test") }
    }

    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var onEngine: [Bool] = []
        func read(onEngine: Bool) -> Bool {
            lock.withLock { self.onEngine.append(onEngine) }
            return true
        }
        var all: [Bool] { lock.withLock { onEngine } }
    }

    /// An engine on its own root and queue, its link reaching no host; `onEngine` says whether the caller runs on its
    /// queue.
    private func engine(_ name: String) throws -> (engine: LeadEngine, root: URL, queue: DispatchQueue, onEngine: () -> Bool) {
        let root = scratch.url(name).appendingPathComponent(".vibeswitcher", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = DispatchQueue(label: "room-watch-tests.engine")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        let link = HostLink(dialer: NoHost(), root: root, queue: queue)
        let engine = LeadEngine(root: root, nodeRoot: nil, link: link, clock: nil)
        return (engine, root, queue, { DispatchQueue.getSpecific(key: key) == true })
    }

    /// The app's `RoomWatchTests` case: the sleep ledger is read off the engine's queue, and a pending sleep recovery's
    /// wait outlives the 12-hour expiry while it's held.
    @Test func roomWatchReadsSleepRecoveryOffTheEngineQueueAndKeepsAnExpiredPendingWait() async throws {
        let (engine, root, queue, onEngine) = try engine("room-watch")
        let reads = Reads()
        var waits = LeadWitness.RoomWaits(folder: root.appendingPathComponent("room-waits"))
        waits.pendingSleep = { _ in reads.read(onEngine: onEngine()) }
        waits.record(root: root.deletingLastPathComponent().appendingPathComponent("project").path, what: LeadSleepRecovery.retryWait, need: 0,
                     auto: true, now: Date() - LeadWitness.RoomWaits.expiry - 1)
        queue.sync { engine.room.load = { 10000 } }
        engine.watchRoom(waits)
        for _ in 0..<2 {
            queue.sync {
                #expect(onEngine())
                engine.lookAtRoom(limits: MacLimits(maxSessions: 6))
            }
        }
        // Waits on the injected reader's calls, not a wall-clock delay.
        #expect(await eventually(timeout: 60) { reads.all.count == 2 })
        #expect(reads.all == [false, false])
        #expect(waits.waits().count == 1, "A pending sleep recovery survives the 12-hour expiry while held")
    }

    /// A lead's start_worker refused for room: nothing while the machine is loaded; once the limits are met, one message
    /// from the witness for the project's lead (held here: no lead runs), naming what was refused; none at the next look.
    @Test func aLeadRefusedForRoomIsToldOnceWhenThereIsRoom() async throws {
        let (engine, root, queue, _) = try engine("room-told")
        let project = root.deletingLastPathComponent().appendingPathComponent("project").path
        let waits = LeadWitness.RoomWaits(folder: root.appendingPathComponent("room-waits"))
        waits.record(root: project, what: "start_worker(parser)", need: 1)
        queue.sync {
            engine.room.load = { 10000 }
            engine.room.memory = { nil }
        }
        engine.watchRoom(waits)
        func held() -> [LeadStore.Held] { queue.sync { engine.leads.held[NodeIds.project(root: project)] ?? [] } }
        func drained() async { await offPool { for _ in 0..<3 { engine.reads.queue.sync {}; queue.sync {} } } }

        // Loaded: no room.
        queue.sync { engine.lookAtRoom(limits: MacLimits(maxSessions: 6)) }
        await drained()
        #expect(held().isEmpty)
        #expect(waits.waits().count == 1)

        // Room: one message, as the witness.
        queue.sync { engine.room.load = { 0 } }
        queue.sync { engine.lookAtRoom(limits: MacLimits(maxSessions: 6)) }
        #expect(await eventually(timeout: 60) { !held().isEmpty })
        let told = held()
        #expect(told.count == 1, "\(told)")
        #expect(told.first?.from == .system("witness"))
        #expect(told.first?.text.contains("room again for what was refused: start_worker(parser)") == true, "\(told)")
        #expect(waits.waits().isEmpty)

        // The next look tells nothing more.
        queue.sync { engine.lookAtRoom(limits: MacLimits(maxSessions: 6)) }
        await drained()
        #expect(held().count == 1)
    }
}
