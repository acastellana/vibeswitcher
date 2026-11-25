import Foundation
import Testing
@testable import VibeCore

/// What a task's audit is kept off under the floor that keeps audits off the workers' model: Claude Code's default
/// and the lead's model, as before, and every model family the session host recorded for the task's worker launches
/// (`WorkerLaunch`), which only ever adds. Nothing unlocks a model: a launch on Opus under a Fable default still keeps
/// the audit off Fable. Fake sessions only; the vault's book stands in for the host's table (`LeadVault.Book.seenOf`).
extension LeadAdvanceTests {
    static let fableDefault = "claude-fable-5-2[1m]"

    /// A lead under the review floor, security_audit_model fable, the host's view of each session its spawn's command.
    /// `defaultModel`: Claude Code's default, for the project (`settingsModel`) and in the vault's home;
    /// `leadModel`: lead_model.
    func floorTeam(defaultModel: String, leadModel: String) throws -> (root: String, runtime: FakeRuntime, lead: LeadToolset) {
        let (root, runtime, lead) = try team(test: nil, ["auto_advance": false, "max_workers": 5])
        runtime.claude = "claude --dangerously-skip-permissions"
        runtime.settingsModel = defaultModel
        try writeVaultDefault(defaultModel)
        book.seenOf = { [runtime] session in runtime.hostSeen(session) }
        let reads = FloorReads()
        lead.floorClock = { reads.next() }
        try vault.setReviewFloor(LeadReviewFloor(), root: root)
        for (key, value) in ["security_audit_model": "fable", "lead_model": leadModel] {
            let set = lead.call("configure", [key: value])
            #expect(!set.isError, "\(set.text)")
        }
        return (root, runtime, lead)
    }

    /// Claude Code's default as the vault's home holds it (what a bind reads for a launch with no --model).
    func writeVaultDefault(_ model: String) throws {
        let settings = URL(fileURLWithPath: book.configHome).appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"model\": \"\(model)\"}".utf8).write(to: settings)
    }

    /// A worker session for `task` bound straight on the book, with the command the host started it with.
    func bindWorker(_ task: String, root: String, session: String, command: String) {
        guard case .grant(let grant) = book.answer(.issue(role: .worker, root: root, task: task, auditing: nil), from: .session("lead-session")) else {
            Issue.record("no grant")
            return
        }
        #expect(book.answer(.bind(grant: grant, root: root, session: session), from: .session("lead-session"),
                            bound: WorkerLaunch.Seen(command: command)) == .ok)
    }

    /// The user's node: Claude Code's default Fable, the lead on Fable, the task's worker launched on Opus. The record
    /// unlocks nothing: Fable stays excluded (the default and the lead's), and the audit's line says why.
    @Test func anOpusLaunchUnderAFableDefaultUnlocksNothingAndTheLineSaysWhy() throws {
        let (root, runtime, lead) = try floorTeam(defaultModel: Self.fableDefault, leadModel: "fable")
        _ = lead.call("add_task", ["title": "Opus", "goal": "g", "acceptance": ["a"], "review": "audit", "model": "opus"])
        #expect(!lead.call("start_worker", ["task": "opus"]).isError)
        #expect(try #require(command("opus", runtime)).contains("--model 'opus'"))
        #expect(vault.launchedFamilies(root: root, task: "opus") == ["opus"])
        #expect(lead.auditModel(lead.workflow, task: try #require(task("opus", root)), security: true) == "sonnet")
        try commit("opus.txt", "x\n", in: Worktrees.path(root: root, slug: "opus"))
        let audited = lead.call("audit", ["task": "opus"])
        #expect(!audited.isError, "\(audited.text)")
        let line = "kept off the workers' models: Claude Code's default fable; workers launched on opus by the host's record"
        #expect(audited.text.contains("(on sonnet: \(line))"), "\(audited.text)")
        let progress = try String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)
        #expect(progress.contains("Audit of opus on sonnet: \(line)."), "\(progress.suffix(600))")
    }

    /// A launch on Fable keeps the audit off Fable, after the board forgets it (model and launched model cleared), as a
    /// second session of a rework does.
    @Test func aFableLaunchKeepsTheAuditOffFableWhateverTheBoardSays() throws {
        let (root, _, lead) = try floorTeam(defaultModel: "opus", leadModel: "opus")
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"], "review": "audit"])
        #expect(!lead.call("start_worker", ["task": "plain"]).isError)
        var plain = try #require(task("plain", root))
        #expect(lead.auditModel(lead.workflow, task: plain, security: true) == "fable")
        bindWorker("plain", root: root, session: "second", command: "claude --name 'worker-plain' --model 'fable' -- 'go on'")
        #expect(vault.launchedFamilies(root: root, task: "plain") == ["fable", "opus"])
        plain.model = nil
        plain.launchedModels = nil
        #expect(lead.auditModel(lead.workflow, task: plain, security: true) == "sonnet")
    }

    /// A launch with no --model adds Claude Code's default as it was at that moment.
    @Test func aLaunchWithNoModelAddsTheDefaultOfThen() throws {
        let (root, _, lead) = try floorTeam(defaultModel: "opus", leadModel: "opus")
        try writeVaultDefault(Self.fableDefault)
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"], "review": "audit"])
        #expect(!lead.call("start_worker", ["task": "plain"]).isError)
        #expect(vault.launchedFamilies(root: root, task: "plain") == ["fable"])
        #expect(lead.auditModel(lead.workflow, task: try #require(task("plain", root)), security: true) == "sonnet")
    }

    /// An alias or unknown id adds nothing and takes nothing off; every --model of a command counts.
    @Test func anAliasAddsNothingAndEveryModelOfACommandCounts() throws {
        let (root, _, lead) = try floorTeam(defaultModel: "opus", leadModel: "opus")
        _ = lead.call("add_task", ["title": "Alias", "goal": "g", "acceptance": ["a"], "review": "audit"])
        bindWorker("alias", root: root, session: "best", command: "claude --model best -- 'go'")
        #expect(vault.launchedFamilies(root: root, task: "alias") == nil)
        let alias = try #require(task("alias", root))
        #expect(lead.auditModel(lead.workflow, task: alias, security: true) == "fable")
        bindWorker("alias", root: root, session: "twice", command: "claude --model opus --model=claude-fable-5-2[1m] -- 'x --model haiku'")
        #expect(vault.launchedFamilies(root: root, task: "alias") == ["fable", "opus"])
        #expect(lead.auditModel(lead.workflow, task: alias, security: true) == "sonnet")
    }

    /// A team task's member launched on Fable keeps the task's audit off Fable, with the member gone from the board.
    @Test func aTeamMembersFableLaunchCountsWithTheMemberOffTheBoard() throws {
        let (root, _, lead) = try floorTeam(defaultModel: "opus", leadModel: "opus")
        _ = lead.call("add_task", ["title": "Team", "goal": "g", "acceptance": ["a"], "review": "audit"])
        bindWorker(Worktrees.memberSlug("team", member: "ui"), root: root, session: "member", command: "claude --model fable -- 'go'")
        var team = try #require(task("team", root))
        team.team = nil
        #expect(vault.launchedFamilies(root: root, task: "team") == ["fable"])
        #expect(lead.auditModel(lead.workflow, task: team, security: true) == "sonnet")
    }

    /// The record is never trimmed or cleared (not even at retire), and a handover carries it; a host that starts with
    /// no vault has none, and the line says so.
    @Test func theRecordOutlivesRetireAndAHandover() throws {
        let (root, _, lead) = try floorTeam(defaultModel: "opus", leadModel: "opus")
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"], "review": "audit"])
        bindWorker("plain", root: root, session: "w", command: "claude --model fable -- go")
        #expect(book.answer(.retire(root: root, task: "plain"), from: .session("lead-session")) == .ok)
        #expect(vault.launchedFamilies(root: root, task: "plain") == ["fable"])
        let carried = LeadVault.Book(restoring: book.serialized)
        #expect(carried.answer(.launchedFamilies(root: root, task: "plain"), from: .app) == .families(["fable"]))
        #expect(LeadVault.Book().answer(.launchedFamilies(root: root, task: "plain"), from: .app) == .families(nil))
        #expect(WorkerLaunch.excluded(projectDefault: "opus", lead: ["opus"], launched: nil).text
                == "kept off the workers' models: Claude Code's default opus; the lead's opus; no launch record")
        #expect(WorkerLaunch.excluded(projectDefault: "opus", lead: [], launched: ["fable"]).text
                == "kept off the workers' models: Claude Code's default opus; workers launched on fable by the host's record")
    }

    /// A verifier's bind adds nothing; a session the host doesn't know adds nothing.
    @Test func onlyAWorkersLaunchTheHostKnowsIsRecorded() {
        let book = LeadVault.Book()
        book.configHome = temp.url("home").path
        let root = "/repo"
        guard case .grant(let lead) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else { return }
        #expect(book.answer(.bind(grant: lead, root: root, session: "lead"), from: .app) == .ok)
        func bind(_ role: LeadLaunch.Role, _ session: String, _ seen: WorkerLaunch.Seen?) {
            guard case .grant(let grant) = book.answer(.issue(role: role, root: root, task: "t", auditing: role == .verifier ? "c0ffee" : nil),
                                                       from: .session("lead")) else { Issue.record("no grant"); return }
            #expect(book.answer(.bind(grant: grant, root: root, session: session), from: .session("lead"), bound: seen) == .ok)
        }
        bind(.verifier, "v", WorkerLaunch.Seen(command: "claude --model sonnet"))
        bind(.worker, "unknown", nil)
        #expect(book.answer(.launchedFamilies(root: root, task: "t"), from: .app) == .families(nil))
        bind(.worker, "w", WorkerLaunch.Seen(command: "claude --model haiku"))
        #expect(book.answer(.launchedFamilies(root: root, task: "t"), from: .app) == .families(["haiku"]))
    }
}
