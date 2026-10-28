import Foundation
import Testing
@testable import VibeCore

/// A lead refused for the Mac's room or load is woken once when there's room again, whichever project's sessions
/// ended: before, nothing woke it, so project-c's lead slept and polled (2026-10-23 10:20 and 10:25, 10-24 13:21). The Mac
/// is faked (the sessions the host lists, the load), and so is the clock.
extension LeadToolsetTests {
    /// project-c's and films' teams with project-c's four ended.
    static var projectCEnded: [LeadSessionInfo] {
        neighbours.map { session in
            var session = session
            if session.cwd.contains("/project-c/.vibeswitcher/") { session.live = false }
            return session
        }
    }

    static func mac(_ sessions: [LeadSessionInfo], load: Double?) -> MacLoad {
        MacLoad.count(sessions.map { ($0.label, $0.cwd, $0.live) }, load: load)
    }

    @Test func aLeadRefusedAtTheCapIsWokenOnceWhenAnotherProjectsSessionsEnd() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let limits = MacLimits(maxSessions: 6)
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        runtime.others = Self.neighbours
        let refused = call(lead, "start_worker", ["task": "one"])
        #expect(refused.isError && refused.text.contains("VibeSwitcher sends you one message once there's room again"), "\(refused.text)")
        // Still full: nothing.
        #expect(roomWaits.look(mac: Self.mac(Self.neighbours, load: 3), limits: limits).isEmpty)
        // project-c's team ends: one message, to this project's lead, naming what was refused.
        let told = roomWaits.look(mac: Self.mac(Self.projectCEnded, load: 3), limits: limits)
        #expect(told.count == 1)
        #expect(told.first?.root == (root as NSString).standardizingPath)
        let text = try #require(told.first?.text)
        #expect(text.hasPrefix("The Mac has room again for what was refused: start_worker(one). "), "\(text)")
        #expect(text.contains("2 team sessions across 1 project (films 2) (mac_max_sessions 6)"), "\(text)")
        // Once only.
        #expect(roomWaits.look(mac: Self.mac(Self.projectCEnded, load: 3), limits: limits).isEmpty)
        #expect(roomWaits.look(mac: Self.mac([], load: 1), limits: limits).isEmpty)
        // And the retry starts.
        runtime.others = Self.projectCEnded
        #expect(!call(lead, "start_worker", ["task": "one"]).isError)
    }

    @Test func aLeadRefusedForLoadIsWokenOnceTheLoadIsUnderTheThreshold() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let limits = MacLimits(maxSessions: 6, loadThreshold: 24)
        lead.macLimits = { limits }
        for title in ["One", "Two"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        runtime.load = 150
        #expect(call(lead, "start_worker", ["task": "one"]).isError)
        #expect(call(lead, "start_worker", ["task": "two"]).isError)
        #expect(call(lead, "start_worker", ["task": "one"]).isError)
        // Room for sessions, but the load is still over: nothing; at the threshold, not over it: one message for all three.
        #expect(roomWaits.look(mac: Self.mac([], load: 40), limits: limits).isEmpty)
        let told = roomWaits.look(mac: Self.mac([], load: 24), limits: limits)
        #expect(told.map(\.text) == [LeadWitness.roomText(["start_worker(one)", "start_worker(two)"], mac: Self.mac([], load: 24), limits: limits)])
        #expect(told.first?.text.contains("load 24.0 (load_threshold 24 in Settings)") == true)
        #expect(roomWaits.look(mac: Self.mac([], load: 1), limits: limits).isEmpty)
    }

    @Test func anAuditWithSeveralFindersWaitsForRoomForAllOfThem() {
        let waits = roomWaits
        let limits = MacLimits(maxSessions: 6)
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        waits.record(root: "/Users/x/dev/vibeswitcher", what: "audit(a)", need: 3, now: now)
        waits.record(root: "/Users/x/dev/project-c", what: "merge(b)", need: 0, now: now)
        // Four of six held: room for one worker, not for three finders; merge waits only on the load.
        let four = Self.mac(Array(Self.neighbours.prefix(4)), load: 2)
        #expect(four.sessions == 4)
        #expect(waits.look(mac: four, limits: limits, now: now).map(\.root) == ["/Users/x/dev/project-c"])
        let three = Self.mac(Array(Self.neighbours.prefix(3)), load: 2)
        #expect(waits.look(mac: three, limits: limits, now: now).map(\.root) == ["/Users/x/dev/vibeswitcher"])
    }

    @Test func aWaitTooOldIsDroppedUntold() {
        let waits = roomWaits
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        waits.record(root: "/r/a", what: "start_worker(a)", need: 1, now: now)
        let full = Self.mac(Self.neighbours, load: 2)
        let limits = MacLimits(maxSessions: 6)
        #expect(waits.look(mac: full, limits: limits, now: now + LeadWitness.RoomWaits.expiry + 1).isEmpty)
        #expect(waits.waits().isEmpty)
        #expect(waits.look(mac: Self.mac([], load: 1), limits: limits, now: now + LeadWitness.RoomWaits.expiry + 2).isEmpty)
    }

    @Test func aMergeRefusedForLoadIsWokenToo() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        try workflow(root, "test_timeout_min: 0.005")
        lead.loadPoll = 0.02
        runtime.load = 150
        #expect(call(lead, "merge", ["task": "add-b"]).isError)
        let full = Self.mac(Self.neighbours, load: 3)
        #expect(roomWaits.look(mac: full, limits: MacLimits(maxSessions: 6)).first?.text.contains("merge(add-b)") == true)
    }
}

/// project-c's leads spent 8–10 % of their tokens on witness wakes for battery, AC power and disk (31 wakes, each a full
/// turn that ended with "nothing to do"). A power change that doesn't cross the user's battery limit, and free space
/// over disk_warning_gb, wake no lead; crossing the limit, or going under the warning, still does.
struct QuietWakesTests {
    let temp = Scratch()

    @Test func powerChangesThatDontCrossTheLimitWakeNoLead() {
        var state: PowerState? = PowerState(onBattery: false, percent: 90, charging: true)
        var power = LeadWitness.Power(read: { state }, limit: { 50 }, file: temp.url("power.json"))
        #expect(power.look() == nil)
        // Unplugged at 90, down to 51, plugged in and out again: none crosses 50.
        for reading in [PowerState(onBattery: true, percent: 90), PowerState(onBattery: true, percent: 51),
                        PowerState(onBattery: false, percent: 52, charging: true), PowerState(onBattery: true, percent: 60)] {
            state = reading
            #expect(power.look() == nil, "\(reading.text)")
        }
        // Under it: one hold, then quiet until AC power.
        state = PowerState(onBattery: true, percent: 49)
        #expect(power.look()?.hasPrefix("On battery: 49 %, under your 50 % limit") == true)
        state = PowerState(onBattery: true, percent: 45)
        #expect(power.look() == nil)
        state = PowerState(onBattery: false, percent: 46, charging: true)
        #expect(power.look()?.hasPrefix("On AC power: resume") == true)
    }

    @Test func freeSpaceOverTheWarningWakesNoLead() {
        var free: Int64 = DiskSpace.bytes(40)
        var disk = LeadWitness.Disk(free: { _ in free })
        let workflow = LeadWorkflow()
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        for gb in [40.0, 12, 10.5, 30] {
            free = DiskSpace.bytes(gb)
            #expect(disk.check(root: "/r/a", workflow: workflow, now: now) == nil, "\(gb) GB")
        }
        free = DiskSpace.bytes(9)
        #expect(disk.check(root: "/r/a", workflow: workflow, now: now) == DiskSpace.bytes(9))
        #expect(disk.check(root: "/r/a", workflow: workflow, now: now + 60) == nil)
    }
}
