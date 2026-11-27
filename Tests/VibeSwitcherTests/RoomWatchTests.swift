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
        controller.macAverages = { MacLoad.Averages(one: 10000, five: 10000) }
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

    // MARK: The load gate's one rule (rule (cI), docs/process/reviews/load-gate-2026-11.md)

    /// The 2026-11-27 restart, boosted (load_threshold 36), no team session throughout, a heavy slot held 11:14–11:17.
    static let restart: [(at: String, one: Double, five: Double, slot: Bool, room: Bool)] = [
        ("11:09", 28.8, 175.98, false, true), ("11:10", 12.8, 144.62, false, true), ("11:11", 7.89, 119.17, false, true),
        ("11:12", 7.17, 98.75, false, true), ("11:13", 6.27, 81.85, false, true),
        ("11:14", 5.28, 67.83, true, false), ("11:15", 4.53, 56.22, true, false), ("11:16", 3.85, 46.61, true, false),
        ("11:17", 4.84, 39.07, true, false),
        ("11:18", 27.36, 40.63, false, true), ("11:19", 11.82, 33.76, false, true),
    ]

    final class Looks: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func look() { lock.withLock { count += 1 } }
        var all: Int { lock.withLock { count } }
    }

    func controller(_ name: String) throws -> LeadController {
        AppStatus.enabled = false
        let folder = temp.url(name)
        let stateDir = folder.appendingPathComponent("state")
        let inbox = folder.appendingPathComponent("inbox")
        for dir in [stateDir, inbox] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let host = HostClient(socketPath: folder.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { stateDir }, cwd: { _ in nil }, arguments: { _ in [] }))
        let vault = LeadVault(folder: folder.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") })
        return LeadController(host: host, store: store, vault: vault, inbox: inbox, home: folder.path) { _ in "true" }
    }

    /// A slot of `lock` held until released.
    func hold(_ lock: TestLock) throws -> TestLock.Held {
        guard case .held(let held, _, _) = lock.acquire(as: "a build", timeout: hangGuard) else { throw LeadVault.Refused("no slot taken") }
        return held
    }

    /// The room watch reads the heavy slots' holders and judges the load as start_worker does: after the restart the
    /// "room again" message goes out at the 11:09 look (the 1-minute 28.8 under 36, nothing of ours running), the same
    /// minute start_worker allows the start, and not at the 11:14 look, a slot held and the 5-minute 67.8 over 36.
    @Test func theRoomAgainMessageGoesOutAtTheRestartsFirstMinuteOfRoomNotWhileASlotIsHeld() async throws {
        let controller = try controller("room-again")
        let looks = Looks()
        var waits = LeadWitness.RoomWaits(folder: temp.url("room-again-waits"))
        // Read at each look with a wait for disk on it, before the wait is judged: the look's own event.
        waits.freeSpace = { _ in
            looks.look()
            return Int64.max
        }
        waits.record(root: temp.url("room-again-project").path, what: "start_worker(one)", need: 1, disk: 1)
        controller.watchRoom(waits)
        let limits = MacLimits(maxSessions: 6, loadThreshold: 36)
        // 11:09 before the host has listed its sessions (just launched): its empty list isn't "no team session".
        let unlisted = TestLock(directory: temp.url("room-again-unlisted").path)
        controller.hostListed = { false }
        controller.macAverages = { MacLoad.Averages(one: 28.8, five: 175.98) }
        controller.heavyLock = { unlisted }
        controller.lookAtRoom(limits: limits)
        controller.hostListed = { true }
        // 11:14: a slot held (its own lock, so the next look's free one can't race it).
        let busy = TestLock(directory: temp.url("room-again-held").path)
        let held = try hold(busy)
        defer { held.release() }
        controller.macAverages = { MacLoad.Averages(one: 5.28, five: 67.83) }
        controller.heavyLock = { busy }
        controller.lookAtRoom(limits: limits)
        // 11:09: no slot held, no team session.
        let free = TestLock(directory: temp.url("room-again-free").path)
        controller.macAverages = { MacLoad.Averages(one: 28.8, five: 175.98) }
        controller.heavyLock = { free }
        controller.lookAtRoom(limits: limits)
        // The third look found the wait still there (the first two kept it), and told it.
        #expect(await until { looks.all == 3 && waits.waits().isEmpty }, "looks \(looks.all), waits \(waits.waits().map(\.wait))")
    }

    /// The runtime of a lead's tool server with nothing of ours running: no session, the host's census empty, and the
    /// load averages as set.
    final class Seat: LeadRuntime, @unchecked Sendable {
        var averages: MacLoad.Averages?
        let server = "/App/vibeswitcher-mcp"
        func claudeCommand(root: String) -> String { "claude" }
        func spawn(cwd: String, command: String, env: [String: String], label: String, agent: String) throws -> String { throw CancellationError() }
        func answerTrust(session: String, folder: String) {}
        func kill(_ session: String) {}
        func forget(_ session: String) {}
        func steer(_ target: LeadTarget, from sender: SteerMessage.Sender, text: String, clearDraft: Bool) throws -> LeadDelivery.Delivered {
            throw CancellationError()
        }
        func sessions() throws -> [LeadSessionInfo] { [] }
        func census() throws -> [HostCensus]? { [] }
        func transcript(of session: String) throws -> String? { nil }
        func currentAgent() -> LeadAgent? { nil }
        func isRunning(_ agent: LeadAgent) -> Bool { false }
        func loadAverages() -> MacLoad.Averages? { averages }
    }

    /// The Team view's Mac line and start_worker's refusal, minute by minute through the restart, on the same averages
    /// and slots: over the limit exactly when start_worker refuses, with the same load and reading.
    @Test func theTeamLineAgreesWithStartWorkerThroughTheRestart() async throws {
        let seat = Seat()
        let lead = LeadToolset(root: temp.url("agree-project").path, runtime: seat,
                               vault: LeadVault(folder: temp.url("agree-vault"), ask: { _ in throw LeadVault.Refused("none") }))
        let limits = MacLimits(maxSessions: 6, loadThreshold: 36)
        lead.macLimits = { limits }
        lead.roomWaits = LeadWitness.RoomWaits(folder: temp.url("agree-waits"))
        let lock = TestLock(directory: temp.url("agree-locks").path)
        lead.testLock = lock
        for minute in Self.restart {
            let averages = MacLoad.Averages(one: minute.one, five: minute.five)
            seat.averages = averages
            let held = minute.slot ? try hold(lock) : nil
            defer { held?.release() }
            let mac = try lead.macLoad([])
            let refusal = lead.macRefusal(mac, not: "Not started")
            let reads = LeadTeamPane.MacReads(run: { $0() }, averages: { averages }, slotsHeld: { lock.readHolders()?.count }, limits: { limits })
            var line: MacLine?
            reads.make([], reread: true) { line = $0 }
            #expect(await until { line != nil })
            let made = try #require(line)
            #expect((refusal != nil) == !minute.room, "\(minute.at): \(refusal ?? "room")")
            #expect(made.isOver == !minute.room, "\(minute.at): \(made.text)")
            #expect(made.text.hasPrefix("Mac: load \(mac.loadText)"), "\(minute.at): \(made.text) / \(mac.loadText)")
            // Before the host has listed its sessions, the line doesn't take its empty list for none.
            let unlisted = MacLine.make(listed: [], hostListed: false, averages: averages, slotsHeld: 0, limits: limits)
            #expect(unlisted.isOver == (averages.steady > 36) && !unlisted.text.contains("(last minute)"), "\(unlisted.text)")
            if minute.slot {
                #expect(made.text.contains("(5-minute)") && made.spoken.contains("the greater of the last minute's and the last 5 minutes'"), "\(made.spoken)")
                #expect(refusal?.contains("load \(mac.loadText) (its 5-minute average") == true, "\(refusal ?? "")")
            } else {
                #expect(made.text.contains("(last minute)") && made.spoken.contains("the last minute's, since nothing of ours runs"), "\(made.spoken)")
                #expect(mac.room?.reading == .lastMinute)
            }
        }
    }
}
