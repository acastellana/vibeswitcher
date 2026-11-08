import Foundation
import Testing
@testable import VibeCore

/// Starts and audits wait while the Mac is short of memory, not only while its load is high. Replays 2026-11-08
/// 03:40–06:00: load 100–225 on 12 cores with the CPU 27–40 % idle, 504 MB free, swap at 7.8 of 9.2 GB; the holds
/// looked at the load alone and Boost kept starting sessions into a Mac that was paging. The memory is injected
/// (`FakeRuntime.memory`), so is the Mac's load.
extension LeadToolsetTests {
    static let gib: UInt64 = 1_073_741_824
    static let calm = MacMemory(pressure: .normal, swapUsed: 7 * gib, swapTotal: 9 * gib, swapOutRate: 0)

    @Test func startWorkerAndAuditRefuseAtMemoryPressureWarningAndAreWokenOnceItEases() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let limits = MacLimits(maxSessions: 6)
        for title in ["One", "Two"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        _ = call(lead, "start_worker", ["task": "one"])
        _ = call(try seat("worker-one", runtime), "report", doneReport("done"))
        // The load is low (0.5): only the memory holds.
        runtime.memory = MacMemory(pressure: .warning, swapUsed: 8 * Self.gib, swapTotal: 9 * Self.gib, swapOutRate: 3)
        let refused = call(lead, "start_worker", ["task": "two"])
        #expect(refused.isError && refused.text.contains("Not started"), "\(refused.text)")
        #expect(refused.text.contains("it's short of memory: its memory pressure is warning (memory_pressure warning)"), "\(refused.text)")
        #expect(!refused.text.contains("above load_threshold"), "\(refused.text)")
        #expect(refused.text.contains("memory pressure warning, swap 8 of 9 GB used, swapping out 3 pages/s (holds at memory_pressure warning or swap_out_rate 50 pages/s)"), "\(refused.text)")
        #expect(refused.text.contains("VibeSwitcher sends you one message once there's room again"), "\(refused.text)")
        let audit = call(lead, "audit", ["task": "one"])
        #expect(audit.isError && audit.text.contains("No verifier started") && audit.text.contains("short of memory"), "\(audit.text)")
        #expect(runtime.spawned.count == 1)
        // Critical holds too.
        runtime.memory?.pressure = .critical
        #expect(call(lead, "start_worker", ["task": "two"]).text.contains("its memory pressure is critical"))
        // Still short: no message. Eased: one, for both, then none.
        var short = Self.mac([], load: 1)
        short.memory = runtime.memory
        #expect(roomWaits.look(mac: short, limits: limits).isEmpty)
        var eased = Self.mac([], load: 1)
        eased.memory = Self.calm
        let told = roomWaits.look(mac: eased, limits: limits)
        #expect(told.count == 1)
        let text = try #require(told.first?.text)
        #expect(text.hasPrefix("The Mac has room again for what was refused: start_worker(two), audit(one)."), "\(text)")
        #expect(text.contains("memory pressure normal"), "\(text)")
        #expect(roomWaits.look(mac: eased, limits: limits).isEmpty)
        // And the retries start.
        runtime.memory = Self.calm
        #expect(!call(lead, "audit", ["task": "one"]).isError)
        #expect(!call(lead, "start_worker", ["task": "two"]).isError)
    }

    @Test func swappingOutAboveTheRateHoldsStartsAndAuditsButTheSwapUsedAloneDoesnt() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        for title in ["One", "Two"] { _ = call(lead, "add_task", ["title": title, "goal": "g", "acceptance": ["a"]]) }
        _ = call(lead, "start_worker", ["task": "one"])
        _ = call(try seat("worker-one", runtime), "report", doneReport("done"))
        runtime.memory = MacMemory(pressure: .normal, swapUsed: 9 * Self.gib - 1, swapTotal: 9 * Self.gib, swapOutRate: 120.4)
        let refused = call(lead, "start_worker", ["task": "two"])
        #expect(refused.isError, "\(refused.text)")
        #expect(refused.text.contains("it's short of memory: it swaps out 120 pages/s over the last minute (swap_out_rate 50)"), "\(refused.text)")
        #expect(call(lead, "audit", ["task": "one"]).text.contains("swaps out 120 pages/s"))
        #expect(runtime.spawned.count == 1)
        // A rate the user set higher in mac-limits.json lets them start; at 0 (off) too.
        lead.macLimits = { MacLimits(maxSessions: 6, swapOutRate: 200) }
        #expect(!call(lead, "audit", ["task": "one"]).isError)
        lead.macLimits = { MacLimits(maxSessions: 6, swapOutRate: 0) }
        // Swap nearly full but not swapping out (an idle Mac keeps it used): no hold.
        runtime.memory = MacMemory(pressure: .normal, swapUsed: 9 * Self.gib - 1, swapTotal: 9 * Self.gib, swapOutRate: 0)
        lead.macLimits = { MacLimits(maxSessions: 6) }
        #expect(!call(lead, "start_worker", ["task": "two"]).isError)
    }

    @Test func statusShowsTheMemoryOnTheMacLine() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        runtime.memory = MacMemory(pressure: .normal, swapUsed: 7_761 * 1_048_576, swapTotal: 9_216 * 1_048_576, swapOutRate: nil)
        let calm = call(lead, "status").text
        let line = try #require(calm.components(separatedBy: "\n").first { $0.hasPrefix("Mac (every project's team):") })
        #expect(line.contains("load 0.5"), "\(line)")
        #expect(line.contains("memory pressure normal, swap 7.6 of 9 GB used, swapping out not known yet (holds at memory_pressure warning or swap_out_rate 50 pages/s)."), "\(line)")
        #expect(!line.contains("refuse until it eases"), "\(line)")
        runtime.memory?.pressure = .warning
        #expect(call(lead, "status").text.contains("memory pressure warning, swap 7.6 of 9 GB used") )
        #expect(call(lead, "status").text.contains("start_worker and audit refuse until it eases"))
        // Not read (an older tool server, or none): no memory said, nothing held.
        runtime.memory = nil
        #expect(!call(lead, "status").text.contains("memory pressure"))
    }
}

extension LeadAdvanceTests {
    /// auto_advance's start waits while the Mac is short of memory, and starts once the app's nudge comes with it eased.
    @Test func autoAdvanceStartsNothingWhileTheMacIsShortOfMemory() async throws {
        let (root, runtime, lead) = try team()
        let set = { (memory: MacMemory) in
            runtime.calls.lock()
            runtime.memory = memory
            runtime.calls.unlock()
        }
        set(MacMemory(pressure: .warning, swapOutRate: 0))
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Paging", "goal": "g", "acceptance": ["a"]])
        await advancing.settle()
        #expect(task("paging", root)?.status == .planned)
        #expect(roomWaits.waits().contains { $0.wait.auto == true && $0.wait.what == "start_worker(paging)" }, "\(roomWaits.waits())")
        #expect(runtime.spawned.isEmpty)
        // Swapping out fast at pressure normal holds it too.
        set(MacMemory(pressure: .normal, swapOutRate: 500))
        LeadAdvance.nudge(root: root)
        await advancing.settle()
        #expect(task("paging", root)?.status == .planned && runtime.spawned.isEmpty)
        set(MacMemory(pressure: .normal, swapOutRate: 0))
        LeadAdvance.nudge(root: root)
        #expect(await advancing.until { task("paging", root)?.status == .running })
    }
}

struct MacMemoryTests {
    @Test func theMemoryHoldsAreMacWideDefaultsInMacLimitsJson() throws {
        let defaults = MacLimits()
        #expect(defaults.pressureLimit == .warning && defaults.swapOutRateLimit == 50)
        let decoded = { (json: String) in try JSONDecoder().decode(MacLimits.self, from: Data(json.utf8)) }
        #expect(try decoded(#"{"maxSessions":15}"#).pressureLimit == .warning)
        #expect(try decoded(#"{"memoryPressure":"critical","swapOutRate":200}"#).pressureLimit == .critical)
        #expect(try decoded(#"{"memoryPressure":"critical","swapOutRate":200}"#).swapOutRateLimit == 200)
        #expect(try decoded(#"{"memoryPressure":"off","swapOutRate":0}"#).pressureLimit == nil)
        #expect(try decoded(#"{"memoryPressure":"off","swapOutRate":0}"#).swapOutRateLimit == nil)
        // Nonsense keeps the default hold, never none.
        #expect(try decoded(#"{"memoryPressure":"normal","swapOutRate":-3}"#).pressureLimit == .warning)
        #expect(try decoded(#"{"memoryPressure":"banana","swapOutRate":"x"}"#).swapOutRateLimit == 50)
        // Kept through a save (unset ones stay unset) and through Boost, which raises only the load and sessions.
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mac-limits-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try MacLimits(maxSessions: 4, memoryPressure: "critical", swapOutRate: 80).save(to: file)
        let saved = MacLimits.load(from: file)
        #expect(saved.memoryPressure == "critical" && saved.swapOutRate == 80)
        try MacLimits(maxSessions: 4).save(to: file)
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("memory"))
        let boost = BoostState(on: true, why: "on demand")
        let boosted = saved.boosted(by: boost)
        #expect(boosted.pressureLimit == .critical && boosted.swapOutRateLimit == 80)
    }

    @Test func theSwapOutRateIsAveragedOverAboutTheLastMinute() throws {
        typealias Sample = MacMemory.SwapSamples.Sample
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let at = { (ago: TimeInterval, outs: UInt64) in Sample(at: now.timeIntervalSince1970 - ago, outs: outs) }
        // Against the newest reading at least a minute old.
        #expect(MacMemory.SwapSamples.rate([at(200, 0), at(90, 1_000), at(70, 2_000), at(30, 9_000)], outs: 9_000, now: now) == 100)
        // None that old: the oldest at least 15 s old.
        #expect(MacMemory.SwapSamples.rate([at(40, 1_000), at(20, 1_500), at(5, 1_900)], outs: 2_000, now: now) == 25)
        // Nothing to compare with yet, only too recent or too old ones, or a counter gone back (a restart): not known.
        #expect(MacMemory.SwapSamples.rate([], outs: 5, now: now) == nil)
        #expect(MacMemory.SwapSamples.rate([at(5, 1), at(400, 0)], outs: 5, now: now) == nil)
        #expect(MacMemory.SwapSamples.rate([at(60, 9_000)], outs: 5, now: now) == nil)
        // The file: each reading kept for the next reader, old ones dropped.
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("swap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let samples = MacMemory.SwapSamples(file: file)
        #expect(samples.rate(adding: 100, now: now.addingTimeInterval(-1_000)) == nil)
        #expect(samples.rate(adding: 1_000, now: now.addingTimeInterval(-60)) == nil)
        #expect(samples.rate(adding: 4_000, now: now) == 50)
        let kept = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: file))
        #expect(kept.map(\.outs) == [1_000, 4_000])
    }

    @Test func theMacsOwnMemoryReadsWithoutATool() {
        #expect(MacMemory.pressureLevel() != nil)
        #expect(MacMemory.swapUsage() != nil)
        #expect(MacMemory.swapOuts() != nil)
    }
}
