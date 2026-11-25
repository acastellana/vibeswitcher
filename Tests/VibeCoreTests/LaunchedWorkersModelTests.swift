import Foundation
import Testing
@testable import VibeCore

/// The floor that keeps audits off the workers' model judges the model a task's workers were launched on, by the
/// session host's record of their launch commands (`LeadToolset.launchedWorkersModel`), and Claude Code's default
/// only for workers started without a `--model` (a real node, 2026-11-25: Claude Code's default Fable, every task on
/// model: opus, security_audit_model: fable, and every sensitive audit kept off Fable). The board's model never
/// takes a model off the list: any session of the team may write it. Fake sessions only.
extension LeadAdvanceTests {
    /// A lead under the review floor whose Claude Code default is Fable as `~/.claude/settings.json` gives it
    /// (`claude-fable-5-2[1m]`; the project's command names no model), security_audit_model fable.
    func fableDefaultTeam() throws -> (root: String, runtime: FakeRuntime, lead: LeadToolset) {
        let (root, runtime, lead) = try team(test: nil, ["auto_advance": false, "max_workers": 5])
        runtime.claude = "claude --dangerously-skip-permissions"
        runtime.settingsModel = "claude-fable-5-2[1m]"
        let reads = FloorReads()
        lead.floorClock = { reads.next() }
        try vault.setReviewFloor(LeadReviewFloor(), root: root)
        let set = lead.call("configure", ["security_audit_model": "fable"])
        #expect(!set.isError, "\(set.text)")
        return (root, runtime, lead)
    }

    @Test func workersLaunchedOnOpusUnderAFableDefaultAreAuditedOnFable() throws {
        let (root, runtime, lead) = try fableDefaultTeam()
        _ = lead.call("add_task", ["title": "Opus", "goal": "g", "acceptance": ["a"], "review": "audit", "model": "opus", "advisor": "fable"])
        #expect(!lead.call("start_worker", ["task": "opus"]).isError)
        let launched = try #require(command("opus", runtime))
        #expect(launched.contains("--model 'opus'") && launched.contains("--advisor 'fable'"), "\(launched)")
        let task = try #require(task("opus", root))
        #expect(lead.auditModel(lead.workflow, task: task, security: true) == "fable")
        #expect(lead.auditModel(lead.workflow, task: task) == "fable")
    }

    @Test func workersOnTheFableDefaultStillKeepTheirAuditOffFable() throws {
        let (root, runtime, lead) = try fableDefaultTeam()
        // No model of its own: started with no --model, so on Claude Code's default, Fable.
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"], "review": "audit"])
        #expect(!lead.call("start_worker", ["task": "plain"]).isError)
        #expect(!(try #require(command("plain", runtime))).contains("--model"))
        let plain = try #require(task("plain", root))
        #expect(lead.auditModel(lead.workflow, task: plain, security: true) == "opus")
        // Launched on Fable by name: refused as today.
        _ = lead.call("add_task", ["title": "Named", "goal": "g", "acceptance": ["a"], "review": "audit", "model": "fable"])
        #expect(!lead.call("start_worker", ["task": "named"]).isError)
        let named = try #require(task("named", root))
        #expect(lead.auditModel(lead.workflow, task: named, security: true) == "opus")
        // With no task, the project's default as before.
        #expect(!LeadReviewFloor.sameModel(lead.auditModel(lead.workflow), "fable"))
    }

    /// The board's word alone never unlocks Fable: a worker started on the default whose task now says opus, a worker
    /// the host doesn't know, and a start message that only mentions `--model opus` all leave the default in place.
    @Test func onlyTheHostsRecordOfTheLaunchTakesTheDefaultOff() throws {
        let (root, runtime, lead) = try fableDefaultTeam()
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"], "review": "audit"])
        #expect(!lead.call("start_worker", ["task": "plain"]).isError)
        var edited = try #require(task("plain", root))
        edited.model = "opus"
        #expect(!LeadReviewFloor.sameModel(lead.auditModel(lead.workflow, task: edited, security: true), "fable"))

        _ = lead.call("add_task", ["title": "Opus", "goal": "g", "acceptance": ["a"], "review": "audit", "model": "opus"])
        #expect(!lead.call("start_worker", ["task": "opus"]).isError)
        let opus = try #require(task("opus", root))
        let worker = try #require(opus.worker)
        runtime.hostCommands[worker] = .some(nil)
        #expect(!LeadReviewFloor.sameModel(lead.auditModel(lead.workflow, task: opus, security: true), "fable"))
        runtime.hostCommands[worker] = "claude --name 'worker-opus' -- 'start with --model opus as the brief says'"
        #expect(!LeadReviewFloor.sameModel(lead.auditModel(lead.workflow, task: opus, security: true), "fable"))
        runtime.hostCommands[worker] = "claude --name 'worker-opus' --model 'claude-opus-5-5[1m]' -- 'start'"
        #expect(lead.auditModel(lead.workflow, task: opus, security: true) == "fable")
    }

    @Test func theLaunchModelIsReadBeforeTheStartMessageAndNormalisedByFamily() {
        #expect(LeadToolset.launchModel(command: "claude --name w --model 'claude-fable-5-2[1m]' -- 'go'") == "claude-fable-5-2[1m]")
        #expect(LeadReviewFloor.sameModel(LeadToolset.launchModel(command: "claude --model=claude-fable-5-2[1m] -- go"), "fable"))
        #expect(LeadToolset.launchModel(command: "claude --name w -- 'use --model opus'") == nil)
        #expect(LeadToolset.launchModel(command: "claude --name w") == nil)
    }
}
