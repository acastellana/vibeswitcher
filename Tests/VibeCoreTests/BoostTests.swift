import Foundation
import Testing
@testable import VibeCore

/// Boost mode (boost release 6/7, 2026-11-01): what the app decides from the power source, the user's presence and the
/// usage watch, kept in boost.json, and the limits every lead's tool server reads from it.
struct BoostTests {
    let temp = Scratch()

    static let now = Date(timeIntervalSince1970: 1_793_000_000)

    static func weekly(_ percent: Double) -> AccountUsage.Limit {
        AccountUsage.Limit(name: "seven_day", usedPercent: percent, resetsAt: now.timeIntervalSince1970 + 86_400, at: now.timeIntervalSince1970)
    }

    @Test func automaticBoostsOnlyAwayAndOnAC() {
        #expect(Boost.decide(mode: .automatic, onAC: true, away: true, veto: nil) == (true, "automatic: away, on AC"))
        #expect(Boost.decide(mode: .automatic, onAC: false, away: true, veto: nil) == (false, "automatic: on battery"))
        #expect(Boost.decide(mode: .automatic, onAC: true, away: false, veto: nil) == (false, "automatic: you're at the Mac"))
        #expect(Boost.decide(mode: .automatic, onAC: false, away: false, veto: nil) == (false, "automatic: on battery, you're at the Mac"))
        // The power source not read yet is taken as battery.
        #expect(Boost.decide(mode: .automatic, onAC: nil, away: true, veto: nil).on == false)
    }

    @Test func neverOnBatteryWhateverTheMode() {
        for mode in BoostMode.allCases {
            for away in [true, false] {
                #expect(!Boost.decide(mode: mode, onAC: false, away: away, veto: nil).on, "\(mode) away \(away)")
                #expect(!Boost.decide(mode: mode, onAC: nil, away: away, veto: nil).on, "\(mode) away \(away)")
            }
        }
        #expect(Boost.decide(mode: .on, onAC: false, away: false, veto: nil).why == "on in Settings, but on battery: boost never runs on battery")
        #expect(Boost.decide(mode: .on, onAC: true, away: false, veto: nil) == (true, "on in Settings, on AC"))
        #expect(Boost.decide(mode: .off, onAC: true, away: true, veto: nil) == (false, "off in Settings"))
    }

    /// The usage watch's veto keeps boost off near an every-model limit, and says why; a model's own limit doesn't
    /// (other models still work), and neither does one under the veto's share.
    @Test func aUsageLimitVetoKeepsBoostOffAndSaysWhy() {
        var usage = AccountUsage(limits: [Self.weekly(74)])
        let veto = Boost.veto(usage, now: Self.now)
        #expect(veto?.name == "seven_day")
        let decided = Boost.decide(mode: .automatic, onAC: true, away: true, veto: veto, now: Self.now)
        #expect(!decided.on)
        #expect(decided.why.hasPrefix("held off by the usage watch: the weekly limit"), "\(decided.why)")
        #expect(decided.why.contains("74%"), "\(decided.why)")
        #expect(!Boost.decide(mode: .on, onAC: true, away: false, veto: veto, now: Self.now).on)
        // Said only where boost would otherwise be on.
        #expect(Boost.decide(mode: .automatic, onAC: true, away: false, veto: veto, now: Self.now).why == "automatic: you're at the Mac")
        usage = AccountUsage(limits: [Self.weekly(60)])
        #expect(Boost.veto(usage, now: Self.now) == nil)
        usage = AccountUsage(limits: [AccountUsage.Limit(name: "seven_day_opus", model: "opus", usedPercent: 100, resetsAt: Self.now.timeIntervalSince1970 + 3600,
                                                         at: Self.now.timeIntervalSince1970, reached: true)])
        #expect(Boost.veto(usage, now: Self.now) == nil)
        // A limit whose window has reset holds nothing.
        usage = AccountUsage(limits: [AccountUsage.Limit(name: "five_hour", usedPercent: 95, resetsAt: Self.now.timeIntervalSince1970 - 1, at: Self.now.timeIntervalSince1970 - 3600)])
        #expect(Boost.veto(usage, now: Self.now) == nil)
    }

    @Test func boostRaisesTheLimitsAndNeverLowersThem() {
        let normal = MacLimits(maxSessions: 15)
        let state = BoostState(on: true, why: "automatic: away, on AC")
        let boosted = normal.boosted(by: state)
        #expect(boosted.maxSessions == 18 && boosted.loadLimit == 36)
        #expect(boosted.maxWorkers(5) == 7 && boosted.heavySlotsInForce(3) == 3)
        #expect(boosted.maxSessionsText == "18 while boosted (15 normally)")
        #expect(boosted.loadLimitText == "36 while boosted (normally \(MacLoad.number(Double(2 * MacLoad.processors))), twice the \(MacLoad.processors) cores)")
        // Off, or none: the normal limits, said as before.
        for none in [nil, BoostState(on: false, why: "automatic: you're at the Mac")] {
            let same = normal.boosted(by: none)
            #expect(same == normal && same.maxWorkers(5) == 5 && same.maxSessionsText == "15" && same.boost == nil)
        }
        // A normal limit set higher than boost's stays; a project's own max_workers over boost's stays.
        let high = MacLimits(maxSessions: 30, loadThreshold: 50).boosted(by: state)
        #expect(high.maxSessions == 30 && high.loadLimit == 50 && high.maxWorkers(9) == 9)
        // The normal values are untouched: 15 sessions as set, load_threshold twice the cores, max_workers as set.
        #expect(MacLimits(maxSessions: 15).loadLimit == Double(2 * MacLoad.processors))
        #expect(BoostLimits() == BoostLimits(loadThreshold: 36, maxSessions: 18, maxWorkers: 7, heavySlots: 3))
        #expect(BoostLimits(loadThreshold: -1, maxSessions: 0, maxWorkers: 0, heavySlots: 0) == BoostLimits(loadThreshold: 36, maxSessions: 1, maxWorkers: 1, heavySlots: 1))
    }

    /// Every lead reads the app's decision with the limits at each call; a file the app stopped refreshing (it quit,
    /// or hangs) is boost off.
    @Test func theLeadsReadTheDecisionAndAStaleOneIsOff() throws {
        let limitsFile = temp.url("mac-limits.json"), boostFile = temp.url("boost.json")
        try MacLimits(maxSessions: 15, loadThreshold: 24).save(to: limitsFile)
        #expect(MacLimits.current(file: limitsFile, boostFile: boostFile, now: Self.now) == MacLimits(maxSessions: 15, loadThreshold: 24))
        let on = BoostState(on: true, why: "automatic: away, on AC", limits: BoostLimits(loadThreshold: 40, maxSessions: 20, maxWorkers: 8, heavySlots: 4),
                            favored: "/Users/x/dev/alpha/", at: Self.now.timeIntervalSince1970)
        try on.save(to: boostFile)
        #expect(BoostState.load(from: boostFile, now: Self.now) == on)
        #expect(on.favored == "/Users/x/dev/alpha")
        let current = MacLimits.current(file: limitsFile, boostFile: boostFile, now: Self.now + 30)
        #expect(current.maxSessions == 20 && current.loadLimit == 40 && current.maxWorkers(5) == 8 && current.heavySlotsInForce(3) == 4)
        #expect(current.boost?.text == "boost: on (automatic: away, on AC)")
        // Stale: the normal limits.
        let stale = Self.now + BoostState.staleAfter + 1
        #expect(BoostState.load(from: boostFile, now: stale) == nil)
        #expect(MacLimits.current(file: limitsFile, boostFile: boostFile, now: stale) == MacLimits(maxSessions: 15, loadThreshold: 24))
        // Off: the normal limits; load still says why.
        try BoostState(on: false, why: "automatic: on battery", at: Self.now.timeIntervalSince1970).save(to: boostFile)
        #expect(MacLimits.current(file: limitsFile, boostFile: boostFile, now: Self.now).boost == nil)
        #expect(BoostState.load(from: boostFile, now: Self.now)?.text == "boost: off (automatic: on battery)")
        #expect(BoostState.file == VibePaths.root.appendingPathComponent("boost.json"))
        // Unreadable: off.
        try Data("{".utf8).write(to: boostFile)
        #expect(BoostState.load(from: boostFile, now: Self.now) == nil)
    }

    /// boost.json raises the caps every lead reads, so what's read from it is clamped (F1): a file a session wrote
    /// with a load of 1000 and 500 sessions boosts no further than 4× the cores and a slot per core.
    @Test func anOutOfRangeBoostFileIsClamped() throws {
        let file = temp.url("boost.json")
        let cores = MacLoad.processors
        let forged = #"{"on": true, "why": "forged", "at": \#(Self.now.timeIntervalSince1970), "limits": {"loadThreshold": 1000, "maxSessions": 500, "maxWorkers": 400, "heavySlots": 64}}"#
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(forged.utf8).write(to: file)
        let limits = try #require(BoostState.load(from: file, now: Self.now)).limits
        #expect(limits == BoostLimits(loadThreshold: Double(4 * cores), maxSessions: 4 * cores, maxWorkers: 4 * cores, heavySlots: cores))
        let current = MacLimits.current(file: temp.url("mac-limits.json"), boostFile: file, now: Self.now)
        #expect(current.loadLimit == Double(4 * cores) && current.maxSessions == 4 * cores && current.maxWorkers(5) == 4 * cores && current.heavySlotsInForce(2) == cores)
        // Negative and zero values are their least, as Settings keeps them.
        #expect(BoostLimits(loadThreshold: 0, maxSessions: -3, maxWorkers: 0, heavySlots: -1) == BoostLimits(loadThreshold: 36, maxSessions: 1, maxWorkers: 1, heavySlots: 1))
    }

    /// While boosted, freed room goes to the project the user last worked in first: the witness wakes its waits
    /// first, and the others only with room left beside them; without boost, every wait with room is woken as before.
    @Test func theWitnessWakesTheFavoredProjectFirst() {
        let waits = LeadWitness.RoomWaits(folder: temp.url("room-waits"))
        waits.record(root: "/Users/x/dev/beta", what: "start_worker(b)", need: 1, now: Self.now)
        waits.record(root: "/Users/x/dev/alpha", what: "start_worker(a)", need: 1, now: Self.now + 5)
        let mac = MacLoad(load: 2, holders: [MacLoad.Holder(project: "gamma", sessions: 17)])
        let boosted = MacLimits(maxSessions: 15).boosted(by: BoostState(on: true, why: "automatic: away, on AC", favored: "/Users/x/dev/alpha"))
        // Room for one: alpha's, though beta waited longer.
        #expect(waits.look(mac: mac, limits: boosted, now: Self.now + 10).map(\.root) == ["/Users/x/dev/alpha"])
        // beta's next, once there's room again.
        #expect(waits.look(mac: mac, limits: boosted, now: Self.now + 20).map(\.root) == ["/Users/x/dev/beta"])
        // The favored project's audit that doesn't fit yet keeps its room: beta's start waits with it.
        waits.record(root: "/Users/x/dev/alpha", what: "audit(a)", need: 2, now: Self.now + 30)
        waits.record(root: "/Users/x/dev/beta", what: "start_worker(c)", need: 1, now: Self.now + 31)
        #expect(waits.look(mac: mac, limits: boosted, now: Self.now + 40).isEmpty)
        let freer = MacLoad(load: 2, holders: [MacLoad.Holder(project: "gamma", sessions: 15)])
        #expect(waits.look(mac: freer, limits: boosted, now: Self.now + 50).map(\.root) == ["/Users/x/dev/alpha", "/Users/x/dev/beta"])
        // Not boosted: both woken at once, as ever.
        waits.record(root: "/Users/x/dev/beta", what: "start_worker(d)", need: 1, now: Self.now + 60)
        waits.record(root: "/Users/x/dev/alpha", what: "start_worker(e)", need: 1, now: Self.now + 61)
        let normalRoom = MacLoad(load: 2, holders: [MacLoad.Holder(project: "gamma", sessions: 14)])
        #expect(waits.look(mac: normalRoom, limits: MacLimits(maxSessions: 15), now: Self.now + 70).map(\.root) == ["/Users/x/dev/alpha", "/Users/x/dev/beta"])
    }
}

/// start_worker, audit, status and merge batching under Boost mode, with the Mac and the boost faked.
extension LeadToolsetTests {
    static func boost(_ why: String = "automatic: away, on AC", limits: BoostLimits = BoostLimits(), favored: String? = nil) -> BoostState {
        BoostState(on: true, why: why, limits: limits, favored: favored)
    }

    @Test func startWorkerAndAuditUseTheBoostedMacLimits() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        var boosting = false
        lead.macLimits = { MacLimits(maxSessions: 6, loadThreshold: 24).boosted(by: boosting ? Self.boost() : nil) }
        for title in ["One", "Two", "Three"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        // mac_max_sessions: the neighbours' six fill the normal cap; boost's 18 has room.
        runtime.others = Self.neighbours
        let refused = call(lead, "start_worker", ["task": "one"])
        #expect(refused.isError && refused.text.contains("(mac_max_sessions 6)"), "\(refused.text)")
        boosting = true
        let started = call(lead, "start_worker", ["task": "one"])
        #expect(!started.isError, "\(started.text)")
        // load_threshold: 30 is over the normal 24, under boost's 36.
        runtime.load = 30
        let audit = call(try seat("worker-one", runtime), "report", doneReport("done"))
        #expect(!audit.isError, "\(audit.text)")
        boosting = false
        let busy = call(lead, "audit", ["task": "one"])
        #expect(busy.isError && busy.text.contains("load 30.0 (load_threshold 24 in Settings)"), "\(busy.text)")
        let busyStart = call(lead, "start_worker", ["task": "two"])
        #expect(busyStart.isError && busyStart.text.contains("above load_threshold"), "\(busyStart.text)")
        boosting = true
        let audited = call(lead, "audit", ["task": "one"])
        #expect(!audited.isError, "\(audited.text)")
        #expect(!call(lead, "start_worker", ["task": "two"]).isError)
        // Over boost's too: refused, said with both.
        runtime.load = 40
        let over = call(lead, "start_worker", ["task": "three"])
        #expect(over.isError && over.text.contains("load_threshold 36 while boosted (normally 24 in Settings)"), "\(over.text)")
        #expect(over.text.contains("mac_max_sessions 18 while boosted (6 normally)"), "\(over.text)")
        // Boost off again (the user came back): new starts stop above the normal limits; what runs goes on.
        boosting = false
        runtime.load = 30
        #expect(call(lead, "start_worker", ["task": "three"]).isError)
        #expect(BoardStore(root: root).load().tasks.filter { $0.status == .running }.count == 1)
    }

    @Test func startWorkerUsesBoostsMaxWorkers() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try workflow(root, "max_workers: 1")
        var boosting = false
        lead.macLimits = { MacLimits(maxSessions: 15).boosted(by: boosting ? Self.boost(limits: BoostLimits(maxWorkers: 2)) : nil) }
        for title in ["One", "Two", "Three"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        #expect(!call(lead, "start_worker", ["task": "one"]).isError)
        let refused = call(lead, "start_worker", ["task": "two"])
        #expect(refused.isError && refused.text.contains("1 workers already run (max_workers is 1 in workflow.md)"), "\(refused.text)")
        boosting = true
        #expect(!call(lead, "start_worker", ["task": "two"]).isError)
        let third = call(lead, "start_worker", ["task": "three"])
        #expect(third.isError && third.text.contains("max_workers is 2 while boosted (1 in workflow.md)"), "\(third.text)")
        #expect(call(lead, "status").text.contains("max 2 workers at once"))
    }

    @Test func statusSaysWhetherBoostIsOnAndWhy() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        try workflow(root, "max_workers: 5\nmerge_batching: boost")
        // Never said by the app: nothing about boost.
        lead.boostState = { _ in nil }
        #expect(!call(lead, "status").text.contains("boost:"))
        lead.boostState = { _ in BoostState(on: false, why: "automatic: you're at the Mac") }
        #expect(call(lead, "status").text.contains("boost: off (automatic: you're at the Mac): the normal limits hold."))
        lead.macLimits = { MacLimits(maxSessions: 15).boosted(by: Self.boost()) }
        let status = call(lead, "status").text
        #expect(status.contains("boost: on (automatic: away, on AC): load_threshold 36, mac_max_sessions 18, max_workers 7 (5 in workflow.md), heavy_slots 3; merge_batching boost batches now."), "\(status)")
        #expect(status.contains("(mac_max_sessions 18 while boosted (15 normally))"), "\(status)")
        #expect(status.contains("max 7 workers at once"), "\(status)")
        #expect(call(lead, "configure").text.contains("- mac_max_sessions: 18 while boosted (15 normally)"))
    }

    @Test func mergeBatchingBoostFollowsBoostMode() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        var boosting = false
        lead.macLimits = { MacLimits(maxSessions: 15).boosted(by: boosting ? Self.boost() : nil) }
        var workflow = LeadWorkflow()
        for (batching, off, on) in [(LeadWorkflow.MergeBatching.boost, false, true), (.always, true, true), (.off, false, false)] {
            workflow.mergeBatching = batching
            boosting = false
            #expect(lead.batching(workflow) == off, "\(batching) off")
            boosting = true
            #expect(lead.batching(workflow) == on, "\(batching) on")
        }
    }

    /// Fairness: with the Mac's room contended while boosted, the project the user last worked in starts its next task
    /// first. This lead's project isn't it: another project's refused start waits; this lead's start is held for it
    /// while there's room for only one, and goes once that one has started and there's room again.
    @Test func whileBoostedTheProjectLastWorkedInStartsFirst() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let favored = "/Users/x/dev/project-c"
        lead.macLimits = { MacLimits(maxSessions: 6).boosted(by: Self.boost(limits: BoostLimits(maxSessions: 7), favored: favored)) }
        _ = call(lead, "add_task", ["title": "One", "goal": "g", "acceptance": ["a"]])
        // Full at 7: project-c's own start was refused and waits.
        runtime.others = Self.neighbours + [Self.member("films", "z")]
        roomWaits.record(root: favored, what: "start_worker(d)", need: 1)
        #expect(call(lead, "start_worker", ["task": "one"]).isError)
        // A films session ends: room for one, and it's project-c's.
        runtime.others = Self.neighbours
        let held = call(lead, "start_worker", ["task": "one"])
        #expect(held.isError, "\(held.text)")
        #expect(held.text.contains("kept for the project the user last worked in"), "\(held.text)")
        #expect(!held.text.contains("project-c"), "\(held.text)")
        #expect(runtime.spawned.isEmpty)
        let told = roomWaits.look(mac: Self.mac(Self.neighbours, load: 2), limits: lead.macLimits())
        #expect(told.map(\.root) == [favored])
        // project-c's worker started; one more frees: this one's turn.
        runtime.others = Self.neighbours + [Self.member("project-c", "d")]
        #expect(call(lead, "start_worker", ["task": "one"]).isError)
        runtime.others = Array(Self.neighbours.dropFirst()) + [Self.member("project-c", "d")]
        let started = call(lead, "start_worker", ["task": "one"])
        #expect(!started.isError, "\(started.text)")
    }

    /// merge's wait for the load reads the limits at each poll (F3): boost ending while it waits puts load_threshold
    /// back to the normal 24 at once, so a load of 30 that boost's 36 would let through still waits.
    @Test func mergesWaitForTheLoadGoesBackToTheNormalThresholdWhenBoostEnds() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = try audited(lead, runtime, root: root)
        lead.loadPoll = 0.01
        let reads = runtime.loadReads
        // Boosted for the wait's first read only.
        lead.macLimits = { MacLimits(maxSessions: 6, loadThreshold: 24).boosted(by: runtime.loadReads - reads <= 1 ? Self.boost() : nil) }
        runtime.loadReadings = [40, 30, 30, 20]
        let merged = call(lead, "merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(runtime.loadReads - reads == 4, "\(merged.text)")
        #expect(merged.text.contains("from 40 below load_threshold"), "\(merged.text)")
    }

    /// F6: the lead's merge and audit lock takes the same count as vs-heavy: Settings' Mac-wide one (2 here), raised
    /// to boost's 3 while boosted; a project's own heavy_slots is its base instead.
    @Test func theLeadsLockTakesSettingsSlotsRaisedByBoost() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        lead.slotsFromSettings = true
        var boosting = false
        lead.macLimits = { MacLimits(maxSessions: 6, heavySlots: 2).boosted(by: boosting ? Self.boost() : nil) }
        #expect(lead.heavyLock(lead.workflow)?.slots == 2)
        boosting = true
        #expect(lead.heavyLock(lead.workflow)?.slots == 3)
        #expect(call(lead, "configure").text.contains("- heavy_slots: 3 (not set: VIBESWITCHER_HEAVY_SLOTS, else Settings' Mac-wide count, raised while boosted)"))
        try workflow(root, "heavy_slots: 1")
        #expect(lead.heavyLock(lead.workflow)?.slots == 3)
        try workflow(root, "heavy_slots: 4")
        #expect(lead.heavyLock(lead.workflow)?.slots == 4)
        boosting = false
        try workflow(root, "heavy_slots: 1")
        #expect(lead.heavyLock(lead.workflow)?.slots == 1)
    }

    /// The favored project's own start isn't held for anyone, and without boost no project is favored.
    @Test func theFavoredProjectAndUnboostedStartsArentHeld() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for title in ["One", "Two"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        runtime.others = Self.neighbours
        roomWaits.record(root: "/Users/x/dev/project-c", what: "start_worker(d)", need: 1)
        lead.macLimits = { MacLimits(maxSessions: 7).boosted(by: Self.boost(limits: BoostLimits(maxSessions: 7), favored: root)) }
        #expect(!call(lead, "start_worker", ["task": "one"]).isError)
        lead.macLimits = { MacLimits(maxSessions: 8) }
        #expect(!call(lead, "start_worker", ["task": "two"]).isError)
    }
}
