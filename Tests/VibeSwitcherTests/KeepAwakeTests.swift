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
    /// Assertions as the system would hold them, and the power source. Held and released on the keep-awake queue,
    /// read by the test: under a lock. With `gate`, each hold and release waits until the test opens it, 5 s at most:
    /// powerd stuck around a sleep or a charging change.
    final class FakePower: PowerRuntime, @unchecked Sendable {
        private let lock = NSLock()
        private var assertions: [UInt32: String] = [:]
        private var log: [String] = []
        private var ac = true
        private var refusing = false
        private var next: UInt32 = 1
        let started = DispatchSemaphore(value: 0)
        let gate: DispatchSemaphore?

        init(blocking: Bool = false) {
            gate = blocking ? DispatchSemaphore(value: 0) : nil
        }

        var held: [UInt32: String] { lock.withLock { assertions } }
        /// Each call as it reached the system, in order: "hold <name>", "release <id>".
        var calls: [String] { lock.withLock { log } }
        var onACPower: Bool {
            get { lock.withLock { ac } }
            set { lock.withLock { ac = newValue } }
        }
        var refuse: Bool {
            get { lock.withLock { refusing } }
            set { lock.withLock { refusing = newValue } }
        }

        func hold(_ name: String) -> UInt32? {
            wait()
            return lock.withLock {
                log.append("hold \(name)")
                guard !refusing else { return nil }
                defer { next += 1 }
                assertions[next] = name
                return next
            }
        }

        func release(_ id: UInt32) {
            wait()
            lock.withLock {
                log.append("release \(id)")
                assertions[id] = nil
            }
        }

        private func wait() {
            started.signal()
            if let gate { _ = gate.wait(timeout: .now() + 5) }
        }

        /// Lets every call through from now on.
        func open() { for _ in 0..<16 { gate?.signal() } }

        var names: Set<String> { Set(held.values) }
    }

    /// Waits until every hold and release `awake` asked for so far has ended and its `held` says so.
    @MainActor static func settle(_ awake: KeepAwake) async {
        await withCheckedContinuation { done in awake.settled { done.resume() } }
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
    @MainActor @Test func heldWhileAnyRunsReleasedWhenTheLastEnds() async {
        let power = FakePower()
        let awake = KeepAwake(power: power)
        awake.mode = { .onPower }
        var team = Team()
        func look() async {
            awake.update(working: KeepAwake.working([Self.root: team.board], teams: [Self.root: team.reading]))
            await Self.settle(awake)
        }

        await look()
        #expect(power.held.isEmpty && awake.held.isEmpty)
        team.set(team.lead, .working, activity: KeepAwake.mergeActivity)
        team.set(team.verifier, .working)
        team.set(team.worker, .background)
        await look()
        #expect(power.names == [Self.name])
        #expect(awake.held == [Self.root])
        // Looked at again and again: still one assertion, the same one.
        let id = power.held.keys.first
        await look()
        #expect(power.held.keys.first == id && power.held.count == 1)
        team.set(team.lead, .done)
        await look()
        team.set(team.verifier, .done)
        await look()
        #expect(power.names == [Self.name])
        team.set(team.worker, .done)
        await look()
        #expect(power.held.isEmpty && awake.held.isEmpty)
        // No lead running at all: nothing held.
        team.set(team.worker, .working)
        await look()
        awake.update(working: KeepAwake.working([:], teams: [:]))
        await Self.settle(awake)
        #expect(power.held.isEmpty && awake.held.isEmpty)
    }

    @MainActor @Test func oneAssertionPerProjectNamedForIt() async {
        let power = FakePower()
        let awake = KeepAwake(power: power)
        awake.mode = { .always }
        awake.update(working: ["/Users/you/dev/vibeswitcher", "/Users/you/dev/project-c"])
        await Self.settle(awake)
        #expect(power.names == ["VibeSwitcher: team working on vibeswitcher", "VibeSwitcher: team working on project-c"])
        awake.update(working: ["/Users/you/dev/project-c"])
        await Self.settle(awake)
        #expect(power.names == ["VibeSwitcher: team working on project-c"])
        #expect(awake.held == ["/Users/you/dev/project-c"])
    }

    @MainActor @Test func onBatteryNothingIsHeldUnlessTheSettingSaysAlways() async {
        let power = FakePower()
        power.onACPower = false
        let awake = KeepAwake(power: power)
        var mode = KeepAwakeMode.onPower
        awake.mode = { mode }
        awake.update(working: [Self.root])
        await Self.settle(awake)
        #expect(power.held.isEmpty && awake.held.isEmpty)
        mode = .always
        awake.update(working: [Self.root])
        await Self.settle(awake)
        #expect(power.names == [Self.name])
        // Back on the default: released at the next look.
        mode = .onPower
        awake.update(working: [Self.root])
        await Self.settle(awake)
        #expect(power.held.isEmpty)
        // Plugged in again.
        power.onACPower = true
        awake.update(working: [Self.root])
        await Self.settle(awake)
        #expect(power.names == [Self.name])
        // Pulled out while held: released.
        power.onACPower = false
        awake.update(working: [Self.root])
        await Self.settle(awake)
        #expect(power.held.isEmpty && awake.held.isEmpty)
    }

    @MainActor @Test func neverHoldsNothingAndTurningItOffReleases() async {
        let power = FakePower()
        let awake = KeepAwake(power: power)
        var mode = KeepAwakeMode.always
        awake.mode = { mode }
        awake.update(working: [Self.root])
        await Self.settle(awake)
        #expect(power.held.count == 1)
        mode = .never
        awake.update(working: [Self.root])
        await Self.settle(awake)
        #expect(power.held.isEmpty && awake.held.isEmpty)
    }

    @MainActor @Test func untilTheAppGivesItTheSettingNothingIsHeld() async {
        // Benches and tests make lead controllers too: they never hold the Mac awake.
        let power = FakePower()
        let awake = KeepAwake(power: power)
        awake.update(working: [Self.root])
        await Self.settle(awake)
        #expect(power.calls.isEmpty && awake.held.isEmpty)
    }

    @MainActor @Test func aRefusedAssertionIsAskedForAgainNextLook() async {
        let power = FakePower()
        power.refuse = true
        let awake = KeepAwake(power: power)
        awake.mode = { .always }
        awake.update(working: [Self.root])
        await Self.settle(awake)
        #expect(awake.held.isEmpty)
        power.refuse = false
        awake.update(working: [Self.root])
        await Self.settle(awake)
        #expect(power.names == [Self.name] && awake.held == [Self.root])
    }

    @MainActor @Test func releasedWhenItGoes() async {
        let power = FakePower()
        var awake: KeepAwake? = KeepAwake(power: power)
        awake?.mode = { .always }
        awake?.update(working: [Self.root])
        await Self.settle(awake!)
        #expect(power.held.count == 1)
        let assertions = awake!.assertions
        awake = nil
        await withCheckedContinuation { done in assertions.settled { done.resume() } }
        #expect(power.held.isEmpty)
    }

    /// powerd stuck around a sleep or a charging change, as it kept the power source's read 6.4 s on 2026-10-28: each
    /// hold and release waits on it. A look on the main thread doesn't: the assertions are held and released on their
    /// own queue, a project's hold and release in the order the looks asked, and never held twice.
    @MainActor @Test func aStuckPowerDaemonDoesntHoldUpALookAndGetsTheCallsInOrder() async throws {
        let power = FakePower(blocking: true)
        defer { power.open() }
        let awake = KeepAwake(power: power)
        awake.mode = { .always }
        func look(_ roots: Set<String>) -> TimeInterval {
            let began = Date()
            awake.update(working: roots)
            return Date().timeIntervalSince(began)
        }
        var took = look([Self.root])
        #expect(took < 0.05, "update took \(took) s")
        // The hold reached powerd and waits there; the team's work ends meanwhile.
        try #require(power.started.wait(timeout: .now() + 5) == .success)
        took = look([])
        #expect(took < 0.05, "update took \(took) s")
        // Nothing held yet as far as the Team view knows.
        #expect(awake.held.isEmpty)
        power.open()
        await Self.settle(awake)
        #expect(power.calls == ["hold \(Self.name)", "release 1"])
        #expect(power.held.isEmpty && awake.held.isEmpty)

        // Looks asking again and again while the hold is under way: one assertion.
        for _ in 0..<5 { awake.update(working: [Self.root]) }
        await Self.settle(awake)
        awake.update(working: [Self.root])
        await Self.settle(awake)
        #expect(power.calls == ["hold \(Self.name)", "release 1", "hold \(Self.name)"])
        #expect(power.names == [Self.name] && awake.held == [Self.root])
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
    /// waits until the test opens the gate and finds the Mac on battery. The gate's 2 minutes are only a net for a test
    /// that fails before opening it: with 5 s, a loaded Mac's full run let the first read end while the test was still
    /// setting up, so its first look already read battery.
    final class SlowPower: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        private let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var count = 0

        var reads: Int { lock.withLock { count } }

        func read() -> PowerSourceCache.Reading {
            lock.withLock { count += 1 }
            started.signal()
            _ = gate.wait(timeout: .now() + 120)
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
    /// only. A lead refresh's look on the main thread doesn't wait for it; once the read ends, the next look has what it
    /// found. The look is the one `LeadController.refreshed` makes, without a lead controller: its heartbeat looks on
    /// its own every 3 s, and with no lead session on a host it finds no team working and releases the hold.
    @MainActor @Test func aSlowPowerDaemonDoesntHoldUpALeadRefresh() async throws {
        let slow = SlowPower()
        let source = PowerSourceCache(read: slow.read)
        defer { slow.open() }
        try #require(slow.started.wait(timeout: .now() + 5) == .success)
        let awake = KeepAwake(power: SystemPower(source: source))
        awake.mode = { .onPower }
        var team = Team()
        team.set(team.worker, .working)
        func look() -> TimeInterval {
            let began = Date()
            awake.update(working: KeepAwake.working([Self.root: team.board], teams: [Self.root: team.reading]))
            return Date().timeIntervalSince(began)
        }
        let took = look()
        #expect(took < 0.05, "the look took \(took) s")
        // Nothing read yet: taken as AC power, as before when the system didn't say.
        await Self.settle(awake)
        #expect(awake.held == [Self.root])
        #expect(slow.reads == 1)

        slow.open()
        try Self.settle(source)
        #expect(!source.onACPower && source.state?.percent == 40)
        #expect(look() < 0.05)
        // On battery: released at the first look after the read.
        await Self.settle(awake)
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
    @MainActor @Test func pmsetListsTheAssertionWhileHeldAndNotAfter() async throws {
        let root = "/tmp/keep-awake-test-\(UUID().uuidString.prefix(8))"
        let name = KeepAwake.name(root: root)
        let awake = KeepAwake(power: SystemPower())
        awake.mode = { .always }
        defer { awake.update(working: []) }
        awake.update(working: [root])
        await Self.settle(awake)
        #expect(awake.held == [root])
        let held = try Self.assertions()
        #expect(held.contains(name))
        #expect(held.components(separatedBy: "\n").contains { $0.contains(name) && $0.contains("PreventUserIdleSystemSleep") })
        awake.update(working: [])
        await Self.settle(awake)
        #expect(awake.held.isEmpty)
        #expect(try !Self.assertions().contains(name))
    }
}
