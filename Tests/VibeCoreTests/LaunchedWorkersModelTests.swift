import Foundation
import Testing
@testable import VibeCore

/// The floor that keeps audits off the workers' model judges a task's audit by every launch of its worker sessions as
/// the session host recorded it in the vault (`WorkerLaunch`: the `--model` on the command the host started it with,
/// and Claude Code's default at that moment), not by Claude Code's default now, and never by the board. A real node,
/// 2026-11-25: Claude Code's default Fable, every task on model: opus, security_audit_model: fable, and every sensitive
/// audit kept off Fable. With no record, the project's default counts, as before, and the audit says which it was.
/// Fake sessions only; the vault's book stands in for the host's table (`LeadVault.Book.seenOf`).
extension LeadAdvanceTests {
    static let fableDefault = "claude-fable-5-2[1m]"

    /// A lead under the review floor whose Claude Code default is Fable as `~/.claude/settings.json` gives it (the
    /// project's command names no model; the vault's home holds the same file), security_audit_model fable, the host's
    /// view of each session its spawn's command.
    func fableDefaultTeam() throws -> (root: String, runtime: FakeRuntime, lead: LeadToolset) {
        let (root, runtime, lead) = try team(test: nil, ["auto_advance": false, "max_workers": 5])
        runtime.claude = "claude --dangerously-skip-permissions"
        runtime.settingsModel = Self.fableDefault
        let settings = URL(fileURLWithPath: book.configHome).appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"model\": \"\(Self.fableDefault)\"}".utf8).write(to: settings)
        book.seenOf = { [runtime] session in runtime.hostSeen(session) }
        let reads = FloorReads()
        lead.floorClock = { reads.next() }
        try vault.setReviewFloor(LeadReviewFloor(), root: root)
        let set = lead.call("configure", ["security_audit_model": "fable"])
        #expect(!set.isError, "\(set.text)")
        return (root, runtime, lead)
    }

    @Test func workersLaunchedOnOpusUnderAFableDefaultAreAuditedOnFableAndSaySo() throws {
        let (root, runtime, lead) = try fableDefaultTeam()
        _ = lead.call("add_task", ["title": "Opus", "goal": "g", "acceptance": ["a"], "review": "audit", "model": "opus", "advisor": "fable"])
        #expect(!lead.call("start_worker", ["task": "opus"]).isError)
        let launched = try #require(command("opus", runtime))
        #expect(launched.contains("--model 'opus'") && launched.contains("--advisor 'fable'"), "\(launched)")
        let task = try #require(task("opus", root))
        #expect(vault.launches(root: root, task: "opus")?.map(\.model) == ["opus"])
        #expect(lead.auditModel(lead.workflow, task: task, security: true) == "fable")
        #expect(lead.auditModel(lead.workflow, task: task) == "fable")
        try commit("opus.txt", "x\n", in: Worktrees.path(root: root, slug: "opus"))
        let audited = lead.call("audit", ["task": "opus"])
        #expect(!audited.isError, "\(audited.text)")
        #expect(audited.text.contains("(on fable: workers ran on opus by the host's record)"), "\(audited.text)")
        let progress = try String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)
        #expect(progress.contains("Audit of opus on fable: workers ran on opus by the host's record."), "\(progress.suffix(600))")
    }

    /// The task's sessions are the vault's, bound at each start, never the board's: a task whose board entry names
    /// another task's Opus-launched session as its worker is still judged by its own launch (on the Fable default).
    @Test func aBoardThatNamesAnotherTasksSessionUnlocksNothing() throws {
        let (root, _, lead) = try fableDefaultTeam()
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"], "review": "audit"])
        _ = lead.call("add_task", ["title": "Opus", "goal": "g", "acceptance": ["a"], "review": "audit", "model": "opus"])
        for slug in ["plain", "opus"] { #expect(!lead.call("start_worker", ["task": slug]).isError) }
        var plain = try #require(task("plain", root))
        plain.worker = try #require(task("opus", root)?.worker)
        plain.team = nil
        #expect(!LeadReviewFloor.sameModel(lead.auditModel(lead.workflow, task: plain, security: true), "fable"))
        #expect(lead.workersBasis(plain, projectDefault: Self.fableDefault).text == "workers ran on fable by the host's record")
    }

    /// A handover carries the vault whole (`Book.serialized`): the launches with it. A host that starts again with no
    /// vault to restore (the node's, kept in memory only) has none: the fallback, said.
    @Test func theRecordSurvivesAHandoverAndAHostRestartFallsBack() throws {
        let (root, _, lead) = try fableDefaultTeam()
        _ = lead.call("add_task", ["title": "Opus", "goal": "g", "acceptance": ["a"], "review": "audit", "model": "opus"])
        #expect(!lead.call("start_worker", ["task": "opus"]).isError)
        let carried = LeadVault.Book(restoring: book.serialized)
        guard case .launches(let launches) = carried.answer(.launches(root: root, task: "opus"), from: .app) else {
            Issue.record("no launches")
            return
        }
        #expect(launches?.map(\.model) == ["opus"])
        #expect(WorkerLaunch.basis(launches, projectDefault: Self.fableDefault).text == "workers ran on opus by the host's record")
        let restarted = LeadVault.Book()
        #expect(restarted.answer(.launches(root: root, task: "opus"), from: .app) == .launches(nil))
        let fallback = WorkerLaunch.basis(nil, projectDefault: Self.fableDefault)
        #expect(fallback.workers == [Self.fableDefault] && fallback.text == "no launch record: Claude Code's default counts as the workers' model")
    }

    @Test func workersOnTheFableDefaultStillKeepTheirAuditOffFable() throws {
        let (root, runtime, lead) = try fableDefaultTeam()
        // No model of its own: started with no --model, while Claude Code's default was Fable.
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"], "review": "audit"])
        #expect(!lead.call("start_worker", ["task": "plain"]).isError)
        #expect(!(try #require(command("plain", runtime))).contains("--model"))
        #expect(vault.launches(root: root, task: "plain")?.map(\.defaultModel) == [Self.fableDefault])
        let plain = try #require(task("plain", root))
        #expect(lead.auditModel(lead.workflow, task: plain, security: true) == "opus")
        // Launched on Fable by name: refused as today.
        _ = lead.call("add_task", ["title": "Named", "goal": "g", "acceptance": ["a"], "review": "audit", "model": "fable"])
        #expect(!lead.call("start_worker", ["task": "named"]).isError)
        let named = try #require(task("named", root))
        #expect(lead.auditModel(lead.workflow, task: named, security: true) == "opus")
    }

    /// A task with two worker sessions (a rework), one on Opus and one on Fable: Fable stays excluded, and so does Opus.
    @Test func twoLaunchesOneOnFableKeepTheAuditOffBoth() throws {
        let (root, _, lead) = try fableDefaultTeam()
        _ = lead.call("add_task", ["title": "Opus", "goal": "g", "acceptance": ["a"], "review": "audit", "model": "opus"])
        #expect(!lead.call("start_worker", ["task": "opus"]).isError)
        // A second worker session for the task, which the host started on Fable.
        let leadSession = "lead-session"
        guard case .grant(let grant) = book.answer(.issue(role: .worker, root: root, task: "opus", auditing: nil), from: .session(leadSession)) else {
            Issue.record("no grant")
            return
        }
        #expect(book.answer(.bind(grant: grant, root: root, session: "second"), from: .session(leadSession),
                            bound: WorkerLaunch.Seen(command: "claude --name 'worker-opus' --model 'fable' -- 'go on'")) == .ok)
        #expect(vault.launches(root: root, task: "opus")?.map(\.model) == ["opus", "fable"])
        let task = try #require(task("opus", root))
        #expect(lead.auditModel(lead.workflow, task: task, security: true) == "sonnet")
    }

    /// The worker ended (its session gone from the host) before the audit: the record still says what it ran on.
    @Test func aWorkerThatEndedIsStillJudgedByItsLaunch() throws {
        let (root, runtime, lead) = try fableDefaultTeam()
        _ = lead.call("add_task", ["title": "Opus", "goal": "g", "acceptance": ["a"], "review": "audit", "model": "opus"])
        #expect(!lead.call("start_worker", ["task": "opus"]).isError)
        runtime.calls.lock()
        runtime.spawned.removeAll()
        runtime.calls.unlock()
        #expect(lead.auditModel(lead.workflow, task: try #require(task("opus", root)), security: true) == "fable")
    }

    /// The board's word unlocks nothing: a worker started on the Fable default whose task now says opus.
    @Test func aBoardModelEditAloneUnlocksNothing() throws {
        let (root, _, lead) = try fableDefaultTeam()
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"], "review": "audit"])
        #expect(!lead.call("start_worker", ["task": "plain"]).isError)
        var edited = try #require(task("plain", root))
        edited.model = "opus"
        edited.launchedModels = edited.launchedModels?.mapValues { _ in "opus" }
        #expect(!LeadReviewFloor.sameModel(lead.auditModel(lead.workflow, task: edited, security: true), "fable"))
    }

    /// No record for the task (its worker started before this build, or the vault started over), or a launch the host
    /// couldn't tell: the project's default counts, as before, and the audit's line says so.
    @Test func noLaunchRecordFallsBackToTheDefaultAndSaysSo() throws {
        let (root, _, lead) = try fableDefaultTeam()
        var old = LeadTask(slug: "old", title: "Old", contract: LeadContract(goal: "g", acceptance: [], boundaries: [], context: ""), status: .review)
        old.model = "opus"
        old.worker = "before-this-build"
        #expect(vault.launches(root: root, task: "old") == nil)
        #expect(!LeadReviewFloor.sameModel(lead.auditModel(lead.workflow, task: old, security: true), "fable"))
        #expect(lead.workersBasis(old, projectDefault: Self.fableDefault).text == "no launch record: Claude Code's default counts as the workers' model")
        // The host didn't know the session it bound: no record to judge by either.
        book.seenOf = nil
        _ = lead.call("add_task", ["title": "Unseen", "goal": "g", "acceptance": ["a"], "review": "audit", "model": "opus"])
        #expect(!lead.call("start_worker", ["task": "unseen"]).isError)
        #expect(vault.launches(root: root, task: "unseen")?.map(\.known) == [false])
        let unseen = try #require(task("unseen", root))
        #expect(!LeadReviewFloor.sameModel(lead.auditModel(lead.workflow, task: unseen, security: true), "fable"))
        #expect(lead.workersBasis(unseen, projectDefault: Self.fableDefault).text.hasPrefix("no launch record"))
    }

    /// The vault keeps a launch per worker session bound (a verifier's isn't one), and forgets them with the task.
    @Test func theVaultKeepsWorkerLaunchesUntilTheTaskIsRetired() {
        let book = LeadVault.Book()
        book.configHome = temp.url("home").path
        let root = "/repo"
        guard case .grant(let lead) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else { return }
        #expect(book.answer(.bind(grant: lead, root: root, session: "lead"), from: .app) == .ok)
        func bind(_ role: LeadLaunch.Role, _ session: String, _ command: String?) {
            guard case .grant(let grant) = book.answer(.issue(role: role, root: root, task: "t", auditing: role == .verifier ? "c0ffee" : nil),
                                                       from: .session("lead")) else { Issue.record("no grant"); return }
            #expect(book.answer(.bind(grant: grant, root: root, session: session), from: .session("lead"), bound: WorkerLaunch.Seen(command: command)) == .ok)
        }
        bind(.worker, "w1", "claude --model opus -- 'x --model fable'")
        bind(.verifier, "v1", "claude --model sonnet")
        bind(.worker, "w2", "claude -- go")
        guard case .launches(let launches) = book.answer(.launches(root: root, task: "t"), from: .session("w2")) else { Issue.record("no launches"); return }
        #expect(launches?.map(\.session) == ["w1", "w2"] && launches?.map(\.model) == ["opus", nil])
        // No settings file in its home: Claude's own default, which counts as opus.
        #expect(launches?.last?.ran == "opus")
        #expect(book.answer(.retire(root: root, task: "t"), from: .session("lead")) == .ok)
        #expect(book.answer(.launches(root: root, task: "t"), from: .app) == .launches(nil))
    }

    @Test func theLaunchModelIsReadBeforeTheStartMessageAndTheBasisNamesFamilies() {
        #expect(WorkerLaunch.launchModel(command: "claude --name w --model 'claude-fable-5-2[1m]' -- 'go'") == "claude-fable-5-2[1m]")
        #expect(LeadReviewFloor.sameModel(WorkerLaunch.launchModel(command: "claude --model=claude-fable-5-2[1m] -- go"), "fable"))
        #expect(WorkerLaunch.launchModel(command: "claude --name w -- 'use --model opus'") == nil)
        let opus = WorkerLaunch(session: "a", model: "opus", defaultModel: nil, known: true, at: 0)
        let onDefault = WorkerLaunch(session: "b", model: nil, defaultModel: Self.fableDefault, known: true, at: 0)
        let basis = WorkerLaunch.basis([opus, onDefault], projectDefault: "sonnet")
        #expect(basis.workers == ["opus", Self.fableDefault] && basis.text == "workers ran on opus and fable by the host's record")
        #expect(WorkerLaunch.basis(nil, projectDefault: "sonnet").workers == ["sonnet"])
    }
}
