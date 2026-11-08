import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The heartbeat and boost watch enter on main. Neither may take the sleep ledger's lock or read its file.
@MainActor
@Suite(.serialized)
struct RoomWatchTests {
    let temp = Scratch()

    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var threads: [Bool] = []
        func read(_ root: String) -> Bool {
            lock.withLock { threads.append(Thread.isMainThread) }
            return true
        }
        var all: [Bool] { lock.withLock { threads } }
    }

    @Test func roomWatchReadsSleepRecoveryOffMainAndKeepsAnExpiredPendingWait() async throws {
        AppStatus.enabled = false
        let folder = temp.url("room-watch")
        let stateDir = folder.appendingPathComponent("state")
        let inbox = folder.appendingPathComponent("inbox")
        for dir in [stateDir, inbox] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let host = HostClient(socketPath: folder.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { stateDir }, cwd: { _ in nil }, arguments: { _ in [] }))
        let vault = LeadVault(folder: folder.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") })
        let controller = LeadController(host: host, store: store, vault: vault, inbox: inbox, home: folder.path) { _ in "true" }
        controller.macLoad = { 10000 }
        let reads = Reads()
        var waits = LeadWitness.RoomWaits(folder: folder.appendingPathComponent("waits"))
        waits.pendingSleep = { reads.read($0) }
        waits.record(root: folder.appendingPathComponent("project").path, what: LeadSleepRecovery.retryWait, need: 0,
                     auto: true, now: Date() - LeadWitness.RoomWaits.expiry - 1)
        controller.watchRoom(waits)
        for _ in 0..<2 {
            #expect(Thread.isMainThread)
            controller.lookAtRoom(limits: MacLimits(maxSessions: 6))
        }
        // Wait on the injected reader's calls, rather than a wall-clock delay.
        #expect(await until { reads.all.count == 2 })
        #expect(reads.all == [false, false])
        #expect(waits.waits().count == 1, "A pending sleep recovery survives the 12-hour expiry while held")
    }
}
