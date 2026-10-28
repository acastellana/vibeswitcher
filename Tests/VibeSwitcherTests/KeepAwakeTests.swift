import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// 2026-10-19 01:38: the Mac went to Maintenance Sleep (pmset -g log) under a merge's test run, a verifier and a
/// worker's test run. The merge's tests died with no named failure, the verifier's turn ended on 'Your computer went
/// to sleep mid-response', and the worker's build ran 25 minutes across dark wakes. Here the app holds the Mac awake
/// while any of them runs, with a fake power runtime (no assertion is held), and one real assertion is held for the
/// length of one test to see `pmset -g assertions` list it.
struct KeepAwakeTests {
    /// Assertions as the system would hold them, and the power source.
    final class FakePower: PowerRuntime {
        var held: [UInt32: String] = [:]
        var onACPower = true
        var refuse = false
        private var next: UInt32 = 1

        func hold(_ name: String) -> UInt32? {
            guard !refuse else { return nil }
            defer { next += 1 }
            held[next] = name
            return next
        }

        func release(_ id: UInt32) { held[id] = nil }

        var names: Set<String> { Set(held.values) }
    }

    static let root = "/Users/you/dev/vibeswitcher"
    static let name = "VibeSwitcher: team working on vibeswitcher"

    /// A lead's team as the lead controller reads it: the lead, a worker and a verifier, each a live window session.
    struct Team {
        var board = LeadBoard()
        var hosted: [String: HostSession] = [:]
        var sessions: [String: Session] = [:]
        let lead = UUID().uuidString
        let worker = UUID().uuidString
        let verifier = UUID().uuidString
        let other = UUID().uuidString

        init() {
            board.leadSession = lead
            var task = LeadTask(slug: "fix", title: "Fix", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""),
                                status: .review)
            task.worker = worker
            task.verifier = verifier
            board.tasks = [task]
            for (index, id) in [lead, worker, verifier, other].enumerated() {
                let uuid = UUID(uuidString: id)!
                hosted[id] = HostSession(id: uuid, tty: "ttys9\(index)", childPID: 1, cwd: KeepAwakeTests.root, command: "claude", label: "member \(index)",
                                         agent: "claude", title: "", startedAt: Date(), cols: 80, rows: 24, exit: nil)
                var session = Session(tty: "ttys9\(index)", agent: .claude, pid: Int32(9000 + index), startedAt: Date(), cwd: KeepAwakeTests.root,
                                      project: "vibeswitcher", task: nil, status: .idle, statusSince: Date(), detail: nil, hasHooks: true, inTerminalApp: false)
                session.hostID = uuid
                sessions[id] = session
            }
        }

        mutating func set(_ id: String, _ status: SessionStatus, activity: String? = nil) {
            sessions[id]?.status = status
            sessions[id]?.activity = activity
        }

        var reading: TeamReading { TeamReading(hosted: hosted, sessions: sessions) }
        var working: Bool { KeepAwake.working(board: board, hosted: hosted, sessions: sessions) }
    }

    // MARK: What counts as the team working

    @Test func aWorkerOrVerifierRunningATurnOrShellsAfterOneIsWork() {
        var team = Team()
        #expect(!team.working)
        team.set(team.worker, .working, activity: "Run swift test")
        #expect(team.working)
        // Its turn ended, its test run still going in the background.
        team.set(team.worker, .background)
        #expect(team.working)
        team.set(team.worker, .done)
        team.set(team.verifier, .working)
        #expect(team.working)
    }

    @Test func waitingOnYouFinishedOrEndedIsntWork() {
        var team = Team()
        for status in [SessionStatus.needsInput, .done, .idle, .unknown] {
            team.set(team.worker, status)
            team.set(team.verifier, status)
            #expect(!team.working)
        }
        // Its session ended: whatever the last scan said.
        team.set(team.worker, .working)
        team.hosted[team.worker]?.exit = HostSession.Exit(status: 0, at: Date())
        #expect(!team.working)
        // A session that isn't the team's.
        team.set(team.other, .working)
        #expect(!team.working)
    }

    @Test func theLeadMergingIsWorkItsOtherTurnsArent() {
        var team = Team()
        // The merge tool call, as the lead's hooks name it.
        let merging = ToolActivity.describe(toolName: "mcp__vibeswitcher__merge", input: ["task": "fix"])
        #expect(merging == "merge (vibeswitcher)")
        team.set(team.lead, .working, activity: merging)
        #expect(team.working)
        team.set(team.lead, .working, activity: ToolActivity.describe(toolName: "mcp__vibeswitcher__status", input: [:]))
        #expect(!team.working)
        team.set(team.lead, .working, activity: nil)
        #expect(!team.working)
        // The merge ended (its result came back), the lead's turn too.
        team.set(team.lead, .done, activity: merging)
        #expect(!team.working)
    }

    /// A revert runs the tests on the reverted base as a merge does: the Mac stays awake under it too.
    @Test func theLeadRevertingIsWorkToo() {
        var team = Team()
        let reverting = ToolActivity.describe(toolName: "mcp__vibeswitcher__revert", input: ["task": "fix", "reason": "it broke"])
        #expect(reverting == "revert (vibeswitcher)")
        team.set(team.lead, .working, activity: reverting)
        #expect(team.working)
        team.set(team.lead, .done, activity: reverting)
        #expect(!team.working)
    }

    @Test func theProjectsWorkingAreReadPerBoard() {
        var busy = Team()
        busy.set(busy.worker, .working)
        let quiet = Team()
        let boards = ["/r/busy": busy.board, "/r/quiet": quiet.board, "/r/unread": busy.board]
        // A board without a reading (nothing read of its team) counts as idle.
        #expect(KeepAwake.working(boards, teams: ["/r/busy": busy.reading, "/r/quiet": quiet.reading]) == ["/r/busy"])
    }

    // MARK: Holding and releasing

    /// The night of 2026-10-19 replayed: a merge, a verifier and a worker's test run, ending one by one. The assertion
    /// is held from the first look that sees work until the first look after the last one ended (looks are 3 s apart).
    @Test func heldWhileAnyRunsReleasedWhenTheLastEnds() {
        let power = FakePower()
        let awake = KeepAwake(power: power)
        awake.mode = { .onPower }
        var team = Team()
        func look() { awake.update(working: KeepAwake.working([Self.root: team.board], teams: [Self.root: team.reading])) }

        look()
        #expect(power.held.isEmpty && awake.held.isEmpty)
        team.set(team.lead, .working, activity: KeepAwake.mergeActivity)
        team.set(team.verifier, .working)
        team.set(team.worker, .background)
        look()
        #expect(power.names == [Self.name])
        #expect(awake.held == [Self.root])
        // Looked at again and again: still one assertion, the same one.
        let id = power.held.keys.first
        look()
        #expect(power.held.keys.first == id && power.held.count == 1)
        team.set(team.lead, .done)
        look()
        team.set(team.verifier, .done)
        look()
        #expect(power.names == [Self.name])
        team.set(team.worker, .done)
        look()
        #expect(power.held.isEmpty && awake.held.isEmpty)
        // No lead running at all: nothing held.
        team.set(team.worker, .working)
        look()
        awake.update(working: KeepAwake.working([:], teams: [:]))
        #expect(power.held.isEmpty && awake.held.isEmpty)
    }

    @Test func oneAssertionPerProjectNamedForIt() {
        let power = FakePower()
        let awake = KeepAwake(power: power)
        awake.mode = { .always }
        awake.update(working: ["/Users/you/dev/vibeswitcher", "/Users/you/dev/project-c"])
        #expect(power.names == ["VibeSwitcher: team working on vibeswitcher", "VibeSwitcher: team working on project-c"])
        awake.update(working: ["/Users/you/dev/project-c"])
        #expect(power.names == ["VibeSwitcher: team working on project-c"])
        #expect(awake.held == ["/Users/you/dev/project-c"])
    }

    @Test func onBatteryNothingIsHeldUnlessTheSettingSaysAlways() {
        let power = FakePower()
        power.onACPower = false
        let awake = KeepAwake(power: power)
        var mode = KeepAwakeMode.onPower
        awake.mode = { mode }
        awake.update(working: [Self.root])
        #expect(power.held.isEmpty && awake.held.isEmpty)
        mode = .always
        awake.update(working: [Self.root])
        #expect(power.names == [Self.name])
        // Back on the default: released at the next look.
        mode = .onPower
        awake.update(working: [Self.root])
        #expect(power.held.isEmpty)
        // Plugged in again.
        power.onACPower = true
        awake.update(working: [Self.root])
        #expect(power.names == [Self.name])
        // Pulled out while held: released.
        power.onACPower = false
        awake.update(working: [Self.root])
        #expect(power.held.isEmpty && awake.held.isEmpty)
    }

    @Test func neverHoldsNothingAndTurningItOffReleases() {
        let power = FakePower()
        let awake = KeepAwake(power: power)
        var mode = KeepAwakeMode.always
        awake.mode = { mode }
        awake.update(working: [Self.root])
        #expect(power.held.count == 1)
        mode = .never
        awake.update(working: [Self.root])
        #expect(power.held.isEmpty && awake.held.isEmpty)
    }

    @Test func untilTheAppGivesItTheSettingNothingIsHeld() {
        // Benches and tests make lead controllers too: they never hold the Mac awake.
        let power = FakePower()
        KeepAwake(power: power).update(working: [Self.root])
        #expect(power.held.isEmpty)
    }

    @Test func aRefusedAssertionIsAskedForAgainNextLook() {
        let power = FakePower()
        power.refuse = true
        let awake = KeepAwake(power: power)
        awake.mode = { .always }
        awake.update(working: [Self.root])
        #expect(awake.held.isEmpty)
        power.refuse = false
        awake.update(working: [Self.root])
        #expect(power.names == [Self.name] && awake.held == [Self.root])
    }

    @Test func releasedWhenItGoes() {
        let power = FakePower()
        var awake: KeepAwake? = KeepAwake(power: power)
        awake?.mode = { .always }
        awake?.update(working: [Self.root])
        #expect(power.held.count == 1)
        awake = nil
        #expect(power.held.isEmpty)
    }

    @Test func theSettingDefaultsToOnPowerOnly() throws {
        let temp = Scratch()
        let defaults = temp.defaults("keep-awake")
        let presets = temp.url("keep-awake-presets")
        let preferences = Preferences(defaults: defaults, presetsFile: presets)
        #expect(preferences.keepAwake == .onPower)
        preferences.keepAwake = .always
        #expect(Preferences(defaults: defaults, presetsFile: presets).keepAwake == .always)
        #expect(KeepAwakeMode.allCases.map(\.label) == ["Always", "On power only", "Never"])
    }

    // MARK: The power source, read off the main thread

    /// A power daemon as slow as on 2026-10-28 at 17:02 (the window froze 6.4 s in `SystemPower.onACPower`): each read
    /// waits until the test opens the gate, 5 s at most, and finds the Mac on battery.
    final class SlowPower: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        private let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var count = 0

        var reads: Int { lock.withLock { count } }

        func read() -> PowerSourceCache.Reading {
            lock.withLock { count += 1 }
            started.signal()
            _ = gate.wait(timeout: .now() + 5)
            return PowerSourceCache.Reading(onACPower: false, state: PowerState(onBattery: true, percent: 40, at: 0))
        }

        /// Lets every read through from now on.
        func open() { for _ in 0..<16 { gate.signal() } }
    }

    /// Waits until every read `source` was asked for so far has ended.
    static func settle(_ source: PowerSourceCache) throws {
        let done = DispatchSemaphore(value: 0)
        source.settled { done.signal() }
        try #require(done.wait(timeout: .now() + 10) == .success)
    }

    /// The freeze of 17:02 replayed: the power daemon stuck under a read, a lead's team working, the setting on power
    /// only. A refresh on the main thread doesn't wait for it; once the read ends, the next look has what it found.
    @MainActor @Test func aSlowPowerDaemonDoesntHoldUpALeadRefresh() throws {
        let slow = SlowPower()
        let source = PowerSourceCache(read: slow.read)
        defer { slow.open() }
        try #require(slow.started.wait(timeout: .now() + 5) == .success)
        let awake = KeepAwake(power: SystemPower(source: source))
        awake.mode = { .onPower }
        let temp = Scratch()
        let scratch = temp.url("keep-awake-slow-power")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let host = HostClient(socketPath: scratch.appendingPathComponent("no-host.sock").path)
        let store = SessionStore(scanner: SessionScanner(processes: { [:] }, stateDir: { scratch }, cwd: { _ in nil }, arguments: { _ in [] }))
        let leads = LeadController(host: host, store: store, vault: LeadVault(folder: scratch.appendingPathComponent("vault"), ask: { _ in throw LeadVault.Refused("none") }),
                                   inbox: scratch, home: scratch.path, keepAwake: awake) { _ in "true" }
        var team = Team()
        team.set(team.worker, .working)
        func refresh() -> TimeInterval {
            let began = Date()
            leads.refreshed(roots: [Self.root], fired: [:], loaded: [Self.root: team.board], decisions: [:], teams: [Self.root: team.reading], refusals: [:])
            return Date().timeIntervalSince(began)
        }
        let took = refresh()
        #expect(took < 0.05, "refreshed took \(took) s")
        // Nothing read yet: taken as AC power, as before when the system didn't say.
        #expect(awake.held == [Self.root])
        #expect(slow.reads == 1)

        slow.open()
        try Self.settle(source)
        #expect(!source.onACPower && source.state?.percent == 40)
        #expect(refresh() < 0.05)
        // On battery: released at the first look after the read.
        #expect(awake.held.isEmpty)
    }

    /// However often the looks ask while the daemon is slow, one read at a time and one more queued, not a pile.
    @Test func looksWhileAReadIsStuckQueueOneMore() throws {
        let slow = SlowPower()
        let source = PowerSourceCache(read: slow.read)
        defer { slow.open() }
        try #require(slow.started.wait(timeout: .now() + 5) == .success)
        for _ in 0..<100 {
            #expect(source.onACPower)
            #expect(source.state == nil)
        }
        slow.open()
        try Self.settle(source)
        #expect(slow.reads == 2)
        #expect(!source.onACPower)
    }

    /// A reading is read again at a look once it's older than `maxAge` (the battery's charge for the witness's minute
    /// look), not at every look before.
    @Test func anOldReadingIsReadAgainAtTheNextLook() throws {
        let slow = SlowPower()
        slow.open()
        let source = PowerSourceCache(read: slow.read, maxAge: 30)
        try Self.settle(source)
        #expect(slow.reads == 1)
        _ = source.current(now: Date().addingTimeInterval(10))
        try Self.settle(source)
        #expect(slow.reads == 1)
        #expect(source.current(now: Date().addingTimeInterval(31))?.onACPower == false)
        try Self.settle(source)
        #expect(slow.reads == 2)
    }

    /// The app's reads the system, and registers for its changes, on the cache's queue.
    @Test func theSystemsPowerSourceIsReadOnTheQueue() throws {
        let source = PowerSourceCache(notifications: true)
        try Self.settle(source)
        let reading = try #require(source.current())
        // A Mac without a battery has no state; one with says its charge.
        if let state = reading.state { #expect((0...100).contains(state.percent) && state.onBattery == !reading.onACPower) }
    }

    // MARK: The real assertion

    /// `pmset -g assertions`, all of it.
    static func assertions() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Held for the length of this test only: a project of its own name, so it's this test's in the list.
    @Test func pmsetListsTheAssertionWhileHeldAndNotAfter() throws {
        let root = "/tmp/keep-awake-test-\(UUID().uuidString.prefix(8))"
        let name = KeepAwake.name(root: root)
        let awake = KeepAwake(power: SystemPower())
        awake.mode = { .always }
        defer { awake.update(working: []) }
        awake.update(working: [root])
        #expect(awake.held == [root])
        let held = try Self.assertions()
        #expect(held.contains(name))
        #expect(held.components(separatedBy: "\n").contains { $0.contains(name) && $0.contains("PreventUserIdleSystemSleep") })
        awake.update(working: [])
        #expect(awake.held.isEmpty)
        #expect(try !Self.assertions().contains(name))
    }
}
