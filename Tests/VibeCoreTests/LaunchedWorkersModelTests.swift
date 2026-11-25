import Foundation
import Testing
@testable import VibeCore

/// What a task's audit is kept off under the floor that keeps audits off the workers' model: the workers' model (the
/// floor's worker_model, the user's word, else Claude Code's default) and every model family the session host recorded
/// for the task's worker launches (`WorkerLaunch`), which only ever adds. The record unlocks nothing: a launch on Opus
/// under a Fable default still keeps the audit off Fable; the user's worker_model is what moves the workers' model.
/// Fake sessions only; the vault's book stands in for the host's table (`LeadVault.Book.seenOf`).
extension LeadAdvanceTests {
    static let fableDefault = "claude-fable-5-2[1m]"

    /// A lead under the review floor, security_audit_model fable, the host's view of each session its spawn's command.
    /// `defaultModel`: Claude Code's default, for the project (`settingsModel`) and in the vault's home;
    /// `leadModel`: lead_model; `workerModel`: the floor's worker_model.
    func floorTeam(defaultModel: String, leadModel: String, workerModel: String? = nil) throws -> (root: String, runtime: FakeRuntime, lead: LeadToolset) {
        let (root, runtime, lead) = try team(test: nil, ["auto_advance": false, "max_workers": 5])
        runtime.claude = "claude --dangerously-skip-permissions"
        runtime.settingsModel = defaultModel
        try writeVaultDefault(defaultModel)
        book.seenOf = { [runtime] session in runtime.hostSeen(session) }
        let reads = FloorReads()
        lead.floorClock = { reads.next() }
        try vault.setReviewFloor(LeadReviewFloor().with(workerModel: workerModel), root: root)
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
        let line = "kept off Claude Code's default fable and launched on opus by the host's record"
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

    /// An unknown id adds nothing and takes nothing off; Claude Code's aliases add what they run on (`best` Opus,
    /// `opusplan` Opus and Sonnet); the last --model of a command counts.
    @Test func anAliasAddsNothingAndEveryModelOfACommandCounts() throws {
        let (root, _, lead) = try floorTeam(defaultModel: "opus", leadModel: "opus")
        _ = lead.call("add_task", ["title": "Alias", "goal": "g", "acceptance": ["a"], "review": "audit"])
        bindWorker("alias", root: root, session: "custom", command: "claude --model my-own-model -- 'go'")
        #expect(vault.launchedFamilies(root: root, task: "alias") == nil)
        let alias = try #require(task("alias", root))
        #expect(lead.auditModel(lead.workflow, task: alias, security: true) == "fable")
        // The last --model is what Claude Code runs; one inside a quoted word or after `--` isn't an option.
        bindWorker("alias", root: root, session: "twice", command: "claude --model opus --name 'a --model haiku' --model=claude-fable-5-2[1m] -- 'x --model sonnet'")
        #expect(vault.launchedFamilies(root: root, task: "alias") == ["fable"])
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
        #expect(WorkerLaunch.excluded(floorModel: nil, projectDefault: "opus", launched: nil).text == "kept off Claude Code's default opus, no launch record")
        #expect(WorkerLaunch.excluded(floorModel: "claude-opus-5-5", projectDefault: Self.fableDefault, launched: ["fable"]).text
                == "kept off workers' model opus by your review floor and launched on fable by the host's record")
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

    /// The user's set-up with worker_model opus in the floor: Claude Code's default Fable, every task's worker on Opus.
    /// Every worker starts with --model opus (a task naming none too), and the sensitive audit runs on Fable.
    @Test func workerModelInTheFloorPutsAuditsOnFableForOpusWorkers() throws {
        let (root, runtime, lead) = try floorTeam(defaultModel: Self.fableDefault, leadModel: "fable", workerModel: "opus")
        _ = lead.call("add_task", ["title": "Opus", "goal": "g", "acceptance": ["a"], "review": "audit", "model": "opus"])
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"], "review": "audit"])
        for slug in ["opus", "plain"] { #expect(!lead.call("start_worker", ["task": slug]).isError) }
        #expect(try #require(command("plain", runtime)).contains("--model 'opus'"))
        for slug in ["opus", "plain"] {
            #expect(lead.auditModel(lead.workflow, task: try #require(task(slug, root)), security: true) == "fable", "\(slug)")
        }
        try commit("plain.txt", "x\n", in: Worktrees.path(root: root, slug: "plain"))
        let audited = lead.call("audit", ["task": "plain"])
        #expect(!audited.isError, "\(audited.text)")
        #expect(audited.text.contains("(on fable: kept off workers' model opus by your review floor and launched on opus by the host's record)"), "\(audited.text)")
        #expect(lead.call("status", [:]).text.contains("workers start on opus (worker_model)"))
    }

    /// Under worker_model opus, a task naming Fable runs its worker on Fable: kept off by its record, after the board
    /// forgets the task's model.
    @Test func aTaskNamingFableUnderAnOpusWorkerModelIsExcludedByItsRecord() throws {
        let (root, runtime, lead) = try floorTeam(defaultModel: Self.fableDefault, leadModel: "fable", workerModel: "opus")
        _ = lead.call("add_task", ["title": "Hard", "goal": "g", "acceptance": ["a"], "review": "audit", "model": "fable"])
        #expect(!lead.call("start_worker", ["task": "hard"]).isError)
        #expect(try #require(command("hard", runtime)).contains("--model 'fable'"))
        var hard = try #require(task("hard", root))
        hard.model = nil
        hard.launchedModels = nil
        #expect(lead.auditModel(lead.workflow, task: hard, security: true) == "sonnet")
    }

    /// A worktree's .claude/settings.json naming Fable (branch content) doesn't change the --model a worker starts with.
    @Test func aWorktreesSettingsDontChangeTheLaunchModel() throws {
        let (root, runtime, lead) = try floorTeam(defaultModel: Self.fableDefault, leadModel: "fable", workerModel: "opus")
        try FileManager.default.createDirectory(atPath: root + "/.claude", withIntermediateDirectories: true)
        try commit(".claude/settings.json", "{\"model\": \"claude-fable-5-2\", \"env\": {\"ANTHROPIC_MODEL\": \"fable\"}}\n", in: root)
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"], "review": "audit"])
        #expect(!lead.call("start_worker", ["task": "plain"]).isError)
        let launched = try #require(command("plain", runtime))
        #expect(launched.contains("--model 'opus'") && !launched.contains("fable'"), "\(launched)")
        #expect(vault.launchedFamilies(root: root, task: "plain") == ["opus"])
    }

    /// The task's launches are the lead's and the app's to read, not a worker's or verifier's.
    @Test func onlyTheLeadAndTheAppReadTheLaunches() throws {
        let (root, _, lead) = try floorTeam(defaultModel: "opus", leadModel: "opus")
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"], "review": "audit"])
        #expect(!lead.call("start_worker", ["task": "plain"]).isError)
        let worker = try #require(task("plain", root)?.worker)
        guard case .refused = book.answer(.launchedFamilies(root: root, task: "plain"), from: .session(worker)) else {
            Issue.record("a worker read the launches")
            return
        }
        #expect(book.answer(.launchedFamilies(root: root, task: "plain"), from: .app) == .families(["opus"]))
    }

    /// The floor keeps a known model only; parse takes one and refuses an alias.
    @Test func theFloorsWorkerModelIsAKnownModel() throws {
        #expect(LeadReviewFloor().with(workerModel: "Opus").workerModel == "opus")
        #expect(LeadReviewFloor().with(workerModel: "best").workerModel == nil)
        let coded = try JSONDecoder().decode(LeadReviewFloor.self, from: JSONEncoder().encode(LeadReviewFloor().with(workerModel: "claude-opus-5-5")))
        #expect(coded.workerModel == "claude-opus-5-5" && coded.workerModelGiven)
        let older = try JSONDecoder().decode(LeadReviewFloor.self, from: Data(#"{"sensitivePaths":[],"strictPaths":[],"auditFinders":1,"mergePolicy":"auto","riskLines":0,"riskModel":false,"verifierDifferent":true}"#.utf8))
        #expect(older.workerModel == nil)
    }

    @Test func theWordsAreSplitAsAShellSplitsThem() {
        #expect(WorkerLaunch.words("claude --name 'it'\\''s --model fable' --model \"op\\\"us\" -- go") == ["claude", "--name", "it's --model fable", "--model", "op\"us", "--", "go"])
        #expect(WorkerLaunch.launchModel(command: "claude --name 'it'\\''s --model fable' -- go") == nil)
        #expect(WorkerLaunch.launchModel(command: "claude --model opus --model 'sonnet' -- go") == "sonnet")
    }

    @Test func aliasesAddWhatTheyRunOnAndNoModelCountsAsOpus() {
        let home = temp.url("no-settings").path
        #expect(WorkerLaunch.families(seen: .init(command: "claude --model best -- go"), home: home) == ["opus"])
        #expect(WorkerLaunch.families(seen: .init(command: "claude --model opusplan -- go"), home: home) == ["opus", "sonnet"])
        // No --model (or `default`) and no settings model: Claude's own default, which the floor counts as Opus.
        #expect(WorkerLaunch.families(seen: .init(command: "claude -- go"), home: home) == ["opus"])
        #expect(WorkerLaunch.families(seen: .init(command: "claude --model default -- go"), home: home) == ["opus"])
    }

    /// The worktree's project settings (branch content) add what they name: their model and their env's
    /// ANTHROPIC_MODEL and ANTHROPIC_DEFAULT_*_MODEL (an alias remapped).
    @Test func aWorktreesSettingsAddWhatTheyName() throws {
        let worktree = temp.url("worktree")
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data(#"{"env": {"ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-fable-5-2", "ANTHROPIC_MODEL": "haiku", "OTHER": "sonnet"}}"#.utf8)
            .write(to: worktree.appendingPathComponent(".claude/settings.json"))
        try Data(#"{"model": "mythos"}"#.utf8).write(to: worktree.appendingPathComponent(".claude/settings.local.json"))
        #expect(WorkerLaunch.families(seen: .init(command: "claude --model opus -- go", cwd: worktree.path), home: temp.url("h").path)
                == ["fable", "haiku", "mythos", "opus"])
    }

    /// The floor's every model taken (the workers' default Opus, the task on Sonnet, decoys bound on Fable and
    /// Mythos): the audit is held and the user asked, never run on an excluded model; their answer, recorded by the
    /// app, lets that model audit it. A worker can't record one.
    @Test func noModelLeftHoldsTheAuditAndAsksTheUser() throws {
        let (root, _, lead) = try floorTeam(defaultModel: "opus", leadModel: "opus")
        _ = lead.call("add_task", ["title": "Held", "goal": "g", "acceptance": ["a"], "review": "audit", "model": "sonnet"])
        #expect(!lead.call("start_worker", ["task": "held"]).isError)
        bindWorker("held", root: root, session: "decoy-fable", command: "claude --model fable -- go")
        bindWorker("held", root: root, session: "decoy-mythos", command: "claude --model mythos -- go")
        let task = try #require(task("held", root))
        #expect(lead.auditChoice(lead.workflow, task: task) == nil && lead.auditChoice(lead.workflow, task: task, security: true) == nil)
        #expect(lead.auditModel(lead.workflow, task: task) == LeadWorkflow.noneLeft)
        try commit("held.txt", "x\n", in: Worktrees.path(root: root, slug: "held"))
        let audited = lead.call("audit", ["task": "held"])
        #expect(audited.isError && audited.text.contains("no model is left") && audited.text.contains("The user is asked"), "\(audited.text)")
        let asked = try #require(BoardStore(root: root).load().questions.last)
        #expect(asked.options.contains("Audit held on fable") && asked.isOpen)
        // Asked once while it's open.
        _ = lead.call("audit", ["task": "held"])
        #expect(BoardStore(root: root).load().questions.filter { $0.text == asked.text }.count == 1)
        let worker = try #require(task.worker)
        guard case .refused = book.answer(.allowAuditModel(root: root, task: "held", model: "fable"), from: .session(worker)) else {
            Issue.record("a worker allowed a model")
            return
        }
        var answered = asked
        answered.answer = "Audit held on fable"
        #expect(answered.state == .answered)
        #expect(try vault.recordApproval("Audit held on fable", of: answered, root: root) == nil)
        #expect(lead.auditChoice(lead.workflow, task: task) == "fable")
    }

    /// Under the floor, a task's model must name one: an alias or custom id is refused, and one already on the board
    /// never reaches a launch (the worker starts on worker_model). Without the floor, as before.
    @Test func underTheFloorATasksModelNamesOne() throws {
        let (root, runtime, lead) = try floorTeam(defaultModel: Self.fableDefault, leadModel: "fable", workerModel: "opus")
        for word in ["best", "default", "opusplan", "my-model"] {
            let refused = lead.call("add_task", ["title": "T \(word)", "goal": "g", "acceptance": ["a"], "model": word])
            #expect(refused.isError && refused.text.contains("name a model"), "\(word): \(refused.text)")
        }
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"], "review": "audit"])
        #expect(lead.call("update_task", ["task": "plain", "model": "best"]).isError)
        try BoardStore(root: root).update { board in
            if let index = board.taskIndex("plain") { board.tasks[index].model = "best" }
        }
        #expect(!lead.call("start_worker", ["task": "plain"]).isError)
        let launched = try #require(command("plain", runtime))
        #expect(launched.contains("--model 'opus'") && !launched.contains("best"), "\(launched)")
    }

    /// The Mac's Settings sheet builds its floor without worker_model: recording it keeps the one recorded; an explicit
    /// null (the node's `set … default`) clears it.
    @Test func aFloorThatSaysNothingOfWorkerModelKeepsIt() throws {
        let root = try repo()
        try vault.setReviewFloor(LeadReviewFloor().with(workerModel: "opus"), root: root)
        try vault.setReviewFloor(LeadReviewFloor(auditFinders: 2), root: root)
        #expect(try vault.reviewFloor(root: root)?.workerModel == "opus" && vault.reviewFloor(root: root)?.auditFinders == 2)
        let older = try JSONDecoder().decode(LeadReviewFloor.self, from: Data(#"{"sensitivePaths":[],"strictPaths":[],"auditFinders":3,"mergePolicy":"auto","riskLines":0,"riskModel":false,"verifierDifferent":true,"auditSamplePercent":0}"#.utf8))
        #expect(!older.workerModelGiven)
        try vault.setReviewFloor(older, root: root)
        #expect(try vault.reviewFloor(root: root)?.workerModel == "opus")
        let cleared = try JSONDecoder().decode(LeadReviewFloor.self, from: JSONEncoder().encode(LeadReviewFloor().with(workerModel: nil)))
        #expect(cleared.workerModelGiven)
        try vault.setReviewFloor(cleared, root: root)
        #expect(try vault.reviewFloor(root: root)?.workerModel == nil)
    }
}
