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
        awake.update(working: ["/Users/you/dev/vibeswitcher", "/Users/you/dev/genswap"])
        #expect(power.names == ["VibeSwitcher: team working on vibeswitcher", "VibeSwitcher: team working on genswap"])
        awake.update(working: ["/Users/you/dev/genswap"])
        #expect(power.names == ["VibeSwitcher: team working on genswap"])
        #expect(awake.held == ["/Users/you/dev/genswap"])
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
