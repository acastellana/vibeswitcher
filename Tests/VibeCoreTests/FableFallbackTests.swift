import Foundation
import Testing
@testable import VibeCore

/// While Claude refuses Fable at its usage limit, workers and audits fall back to Opus, and back to Fable at the reset
/// (`AccountUsage.fableHeldBack`, `LeadUsageFallback`; the user's answer of 2026-11-12). On fake sessions only: the
/// usage is read by an injected clock, never the wall clock's.
extension LeadAdvanceTests {
    static let fableNow = Date(timeIntervalSince1970: 1_793_509_200)
    static var fableReset: Double { fableNow.timeIntervalSince1970 + 86_400 }

    /// Claude's refusal at the Fable limit, as a worker on Fable's transcript ends on it (boost-release-7-7, 2026-11-11).
    static var outOfCredits: UsageLimit {
        UsageLimit(said: "You're out of usage credits. Run /usage-credits to keep using Fable 5.2 or /model to switch models.",
                   resetsAt: fableReset, at: fableNow.timeIntervalSince1970 - 60, kind: "seven_day_overage_included",
                   apiError: "model_requires_usage_credits")
    }

    /// The refusal kept as the lead's tools keep one: Fable's alone, reached, until its reset.
    func recordFableRefusal() {
        let limit = AccountUsage.fromRefusal(Self.outOfCredits, model: "fable", now: Self.fableNow)!
        usageStore.record([limit], now: Self.fableNow)
    }

    /// A lead whose Claude command runs Fable by default, auto_advance off, reading the usage at `fableNow`.
    func fableTeam(_ settings: [String: Any] = [:]) throws -> (root: String, runtime: FakeRuntime, lead: LeadToolset) {
        let (root, runtime, lead) = try team(test: nil, ["auto_advance": false, "max_workers": 5].merging(settings) { $1 })
        runtime.claude = "claude --dangerously-skip-permissions --model fable"
        lead.usageClock = { Self.fableNow }
        lead.power = { PowerState(onBattery: false, percent: 90) }
        // The floor read afresh at each look (it's kept `floorFresh` otherwise).
        let reads = FloorReads()
        lead.floorClock = { reads.next() }
        return (root, runtime, lead)
    }

    func command(_ slug: String, _ runtime: FakeRuntime) -> String? {
        runtime.spawned.last { $0.command.contains("--name 'worker-\(slug)'") }?.command
    }

    @Test func whileFableIsHeldBackWorkersMeantForFableStartOnOpusOthersKeepTheirModel() throws {
        let (root, runtime, lead) = try fableTeam()
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("add_task", ["title": "Mechanical", "goal": "g", "acceptance": ["a"], "model": "sonnet"])
        _ = lead.call("add_task", ["title": "Pinned", "goal": "g", "acceptance": ["a"], "model": "claude-fable-5-2"])
        _ = lead.call("add_task", ["title": "Later", "goal": "g", "acceptance": ["a"]])
        recordFableRefusal()
        let started = lead.call("start_worker", ["task": "plain"])
        #expect(!started.isError && started.text.contains("on opus in Fable's place: Fable held back until"), "\(started.text)")
        let plain = try #require(command("plain", runtime))
        #expect(plain.contains("--model 'opus'") && !plain.contains("fable"), "\(plain)")
        // Noted as started on Opus; the task's own model stays unset, so after the reset it's on Fable again.
        let worker = try #require(task("plain", root)?.worker)
        #expect(task("plain", root)?.launchedModels?[worker] == "opus" && task("plain", root)?.model == nil)
        // A task that names another model keeps it; one that names Fable falls back too.
        #expect(!lead.call("start_worker", ["task": "mechanical"]).isError)
        #expect(try #require(command("mechanical", runtime)).contains("--model 'sonnet'"))
        #expect(!lead.call("start_worker", ["task": "pinned"]).isError)
        let pinned = try #require(command("pinned", runtime))
        #expect(pinned.contains("--model 'opus'") && !pinned.contains("fable"), "\(pinned)")
        #expect(task("pinned", root)?.model == "claude-fable-5-2")
        // status says so.
        let status = lead.call("status", [:]).text
        #expect(status.contains("Fable held back until \(UsageLimit.resetText(Self.fableReset)): workers and audits on Opus"), "\(status)")
        // At the reset, by the lead's clock: the same start is on Fable again, and status says nothing of it.
        lead.usageClock = { Date(timeIntervalSince1970: Self.fableReset) }
        let again = lead.call("start_worker", ["task": "later"])
        #expect(!again.isError, "\(again.text)")
        let later = try #require(command("later", runtime))
        #expect(later.contains("--model fable") && !later.contains("--model 'opus'"), "\(later)")
        #expect(!lead.call("status", [:]).text.contains("Fable held back"))
    }

    @Test func auditsFollowTheReviewFloorWhileFableIsHeldBack() throws {
        // A floor that keeps audits off the workers' model: workers on Opus, so the audit goes one down, to Sonnet.
        let (root, runtime, lead) = try fableTeam()
        try vault.setReviewFloor(LeadReviewFloor(), root: root)
        _ = lead.call("add_task", ["title": "One", "goal": "g", "acceptance": ["a"], "review": "audit"])
        #expect(lead.auditModel(lead.workflow) == "opus")
        recordFableRefusal()
        #expect(lead.auditModel(lead.workflow) == "sonnet")
        #expect(!lead.call("start_worker", ["task": "one"]).isError)
        let audited = lead.call("audit", ["task": "one"])
        #expect(!audited.isError, "\(audited.text)")
        let verifier = try #require(runtime.spawned.last { $0.command.contains("--name 'verify-one'") }?.command)
        #expect(verifier.contains("--model 'sonnet'"), "\(verifier)")
        // A floor that allows any model: the most capable that isn't held back, Opus.
        try vault.setReviewFloor(LeadReviewFloor(verifierDifferent: false), root: root)
        #expect(lead.auditModel(lead.workflow) == "opus")
        // verifier_model set to Fable by hand goes the same way while it's held back.
        var workflow = LeadWorkflow()
        workflow.verifierModel = "fable"
        #expect(workflow.auditModel(workerModel: "opus", heldBack: "fable") == "opus")
        workflow.floor = LeadReviewFloor()
        #expect(workflow.auditModel(workerModel: "opus", heldBack: "fable") == "sonnet")
        // Past the reset: Fable again.
        lead.usageClock = { Date(timeIntervalSince1970: Self.fableReset) }
        try vault.setReviewFloor(LeadReviewFloor(), root: root)
        #expect(lead.auditModel(lead.workflow) == "opus")
    }

    @Test func aWorkerHaltedAtTheFableLimitStartsAgainOnOpusInItsWorktreeOncePerHalt() throws {
        let (root, runtime, lead) = try fableTeam()
        _ = lead.call("add_task", ["title": "Halted", "goal": "g", "acceptance": ["a"]])
        #expect(!lead.call("start_worker", ["task": "halted"]).isError)
        let halted = try #require(task("halted", root)?.worker)
        let worktree = try #require(task("halted", root)?.worktree)
        #expect(try #require(command("halted", runtime)).contains("--model fable"))
        let loop = LeadAdvance(lead: lead, run: { $0(); return true })
        defer { withExtendedLifetime(lead) {} }
        // Nothing held back yet: a pass says nothing of Fable.
        loop.trigger()
        #expect(!reports(runtime).contains { $0.contains("Fable") })
        // Its turn ends on Claude's refusal at the Fable limit, as the witness reads it.
        runtime.usageLimits[halted] = Self.outOfCredits
        let seen = [halted: LeadWitness.Seen(live: true, status: .working, activity: .usageLimit(Self.outOfCredits))]
        let halts = LeadUsageFallback.halts(board: BoardStore(root: root).load(), seen: seen)
        #expect(halts.map(\.session) == [halted])
        // The witness's own notice of that stop waits while the restart is due.
        let witnessKeys = LeadWitness.events(board: BoardStore(root: root).load(), seen: seen).map(\.key)
        let held = LeadUsageFallback.enqueue(halts, root: root)
        #expect(!held.isEmpty && held.isSubset(of: Set(witnessKeys)), "\(held) \(witnessKeys)")
        loop.trigger()
        // Ended, and a worker on Opus in the same worktree and branch, told why.
        #expect(runtime.killed.contains(halted))
        let worker = try #require(task("halted", root)?.worker)
        #expect(worker != halted && task("halted", root)?.status == .running)
        #expect(task("halted", root)?.worktree == worktree && task("halted", root)?.branch == "agent/halted")
        let spawn = try #require(runtime.spawned.last { $0.id == worker })
        #expect(spawn.cwd == worktree && spawn.command.contains("--model 'opus'"), "\(spawn.command)")
        #expect(spawn.command.contains("You were moved to Opus") && spawn.command.contains("carry on where it was"), "\(spawn.command)")
        let workers = runtime.spawned.filter { $0.command.contains("--name 'worker-halted'") }.count
        // The lead told once of the switch and of the move.
        #expect(reports(runtime).filter { $0.contains("- Fable held back until") }.count == 1, "\(reports(runtime))")
        #expect(reports(runtime).contains { $0.contains("Moved halted's worker to Opus") })
        // The same halt seen again, and more passes: no second restart, no second switch notice.
        _ = LeadUsageFallback.enqueue(halts, root: root)
        loop.trigger()
        LeadAdvance(lead: lead, run: { $0(); return true }).trigger()
        #expect(runtime.spawned.filter { $0.command.contains("--name 'worker-halted'") }.count == workers)
        #expect(reports(runtime).filter { $0.contains("- Fable held back until") }.count == 1, "\(reports(runtime))")
        // The new worker isn't a Fable halt: the witness hands nothing over for it.
        let onOpus = [worker: LeadWitness.Seen(live: true, status: .working, activity: .usageLimit(Self.outOfCredits))]
        #expect(LeadUsageFallback.halts(board: BoardStore(root: root).load(), seen: onOpus).isEmpty)
        // At the reset: one message that Fable is back.
        lead.usageClock = { Date(timeIntervalSince1970: Self.fableReset + 1) }
        runtime.usageLimits = [:]
        loop.trigger()
        loop.trigger()
        #expect(reports(runtime).filter { $0.contains("Fable is back") }.count == 1, "\(reports(runtime))")
    }
}

/// A floor clock that moves past `LeadToolset.floorFresh` at each read.
final class FloorReads: @unchecked Sendable {
    private let lock = NSLock()
    private var now: TimeInterval = 0
    func next() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        now += LeadToolset.floorFresh
        return now
    }
}
