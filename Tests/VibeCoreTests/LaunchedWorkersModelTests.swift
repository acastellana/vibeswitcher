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
        #expect(try #require(command("opus", runtime)).contains("--model 'claude-opus-5-5'"))
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
        #expect(try #require(command("plain", runtime)).contains("--model 'claude-opus-5-5'"))
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
        #expect(try #require(command("hard", runtime)).contains("--model 'claude-fable-5-2'"))
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
        #expect(launched.contains("--model 'claude-opus-5-5'") && launchedOn(launched) == ["claude-opus-5-5"], "\(launched)")
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
        #expect(WorkerLaunch.families(seen: .init(command: "claude --model best -- go"), home: home).families == ["opus"])
        #expect(WorkerLaunch.families(seen: .init(command: "claude --model opusplan -- go"), home: home).families == ["opus", "sonnet"])
        // No --model (or `default`) and no settings model: Claude's own default, which the floor counts as Opus.
        #expect(WorkerLaunch.families(seen: .init(command: "claude -- go"), home: home).families == ["opus"])
        #expect(WorkerLaunch.families(seen: .init(command: "claude --model default -- go"), home: home).families == ["opus"])
    }

    /// The worktree's project settings (branch content) add what they name: their model and their env's
    /// ANTHROPIC_MODEL and ANTHROPIC_DEFAULT_*_MODEL (an alias remapped).
    @Test func aWorktreesSettingsAddWhatTheyName() throws {
        let worktree = temp.url("worktree")
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data(#"{"env": {"ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-fable-5-2", "ANTHROPIC_MODEL": "haiku", "OTHER": "sonnet"}}"#.utf8)
            .write(to: worktree.appendingPathComponent(".claude/settings.json"))
        try Data(#"{"model": "mythos"}"#.utf8).write(to: worktree.appendingPathComponent(".claude/settings.local.json"))
        #expect(WorkerLaunch.families(seen: .init(command: "claude --model opus -- go", cwd: worktree.path), home: temp.url("h").path).families
                == ["fable", "haiku", "mythos", "opus"])
    }

    /// A task the floor leaves no model for: the workers' default Opus, the task on Sonnet, decoys bound on Fable and
    /// Mythos.
    func exhausted() throws -> (root: String, lead: LeadToolset, task: LeadTask, head: String) {
        let (root, _, lead) = try floorTeam(defaultModel: "opus", leadModel: "opus")
        _ = lead.call("add_task", ["title": "Held", "goal": "g", "acceptance": ["a"], "review": "audit", "model": "sonnet"])
        #expect(!lead.call("start_worker", ["task": "held"]).isError)
        bindWorker("held", root: root, session: "decoy-fable", command: "claude --model fable -- go")
        bindWorker("held", root: root, session: "decoy-mythos", command: "claude --model mythos -- go")
        try commit("held.txt", "x\n", in: Worktrees.path(root: root, slug: "held"))
        let head = Git.run(["rev-parse", "agent/held"], in: root).output
        return (root, lead, try #require(task("held", root)), head)
    }

    /// The user's answer, as the app records it once the board took it.
    func answer(_ question: LeadQuestion, _ text: String, root: String) -> String? {
        var answered = question
        answered.answer = text
        return vault.recordAuditGrant(text, of: answered, root: root)
    }

    /// No model left: the audit is held and the user asked, never run on an excluded model; their answer to that
    /// question, recorded by the app, lets that model audit the task at that commit, once. A worker can't record one.
    @Test func noModelLeftHoldsTheAuditAndAsksTheUser() throws {
        let (root, lead, task, head) = try exhausted()
        #expect(lead.auditChoice(lead.workflow, task: task) == nil && lead.auditChoice(lead.workflow, task: task, security: true) == nil)
        #expect(lead.auditModel(lead.workflow, task: task) == LeadWorkflow.noneLeft)
        let audited = lead.call("audit", ["task": "held"])
        #expect(audited.isError && audited.text.contains("no model is left") && audited.text.contains("The user is asked"), "\(audited.text)")
        let asked = try #require(BoardStore(root: root).load().questions.last)
        let option = "Audit held at \(head.prefix(12)) on fable"
        #expect(asked.options.contains(option) && asked.isOpen && asked.task == "held")
        #expect(vault.auditOffer(root: root, question: asked.id)?.commit == head)
        // Asked once while it's open.
        _ = lead.call("audit", ["task": "held"])
        #expect(BoardStore(root: root).load().questions.filter { $0.text == asked.text }.count == 1)
        let worker = try #require(task.worker)
        guard case .refused = book.answer(.allowAuditModel(root: root, task: "held", commit: head, model: "fable", question: asked.id), from: .session(worker)) else {
            Issue.record("a worker allowed a model")
            return
        }
        #expect(answer(asked, option, root: root) == "Recorded: held may be audited on fable at \(head.prefix(12)), by its next audit only.")
        #expect(lead.auditChoice(lead.workflow, task: task) == "fable")
        let started = lead.call("audit", ["task": "held"])
        #expect(!started.isError, "\(started.text)")
        // Used once: the next audit is held again.
        #expect(vault.auditAllowance(root: root, task: "held") == nil && lead.auditChoice(lead.workflow, task: task) == nil)
    }

    /// A lead's own question that looks like the audit's (its options in the same words, about the task): no offer in
    /// the vault, so the answer allows nothing.
    @Test func aLeadsLookAlikeQuestionAllowsNothing() throws {
        let (root, lead, task, head) = try exhausted()
        let option = "Audit held at \(head.prefix(12)) on fable"
        let asked = lead.call("ask_user", ["question": "Pick a reviewer for held", "options": [option, "Audit held at \(head.prefix(12)) on opus"], "task": "held"])
        #expect(!asked.isError, "\(asked.text)")
        let question = try #require(BoardStore(root: root).load().questions.last)
        let said = try #require(answer(question, option, root: root))
        #expect(said.hasPrefix("No model was allowed") && said.contains("isn't the one the audit"), "\(said)")
        #expect(lead.auditChoice(lead.workflow, task: task) == nil)
    }

    /// An answer naming another task than the question's, or not one of its options, allows nothing.
    @Test func anAnswerForAnotherTaskOrOffTheOptionsAllowsNothing() throws {
        let (root, lead, task, head) = try exhausted()
        _ = lead.call("audit", ["task": "held"])
        let asked = try #require(BoardStore(root: root).load().questions.last)
        // Another task's name, as an option the lead's revision added.
        var revised = asked
        revised.options.append("Audit other at \(head.prefix(12)) on fable")
        #expect(try #require(answer(revised, "Audit other at \(head.prefix(12)) on fable", root: root)).contains("isn't about other"))
        #expect(try #require(answer(asked, "Audit held at \(head.prefix(12)) on haiku", root: root)).contains("isn't one of the question's options"))
        #expect(lead.auditChoice(lead.workflow, task: task) == nil)
    }

    /// An allowance is for the commit it was given at: new commits on the branch and it isn't used.
    @Test func anAllowanceIsntUsedAfterNewCommits() throws {
        let (root, lead, task, head) = try exhausted()
        _ = lead.call("audit", ["task": "held"])
        let asked = try #require(BoardStore(root: root).load().questions.last)
        #expect(try #require(answer(asked, "Audit held at \(head.prefix(12)) on fable", root: root)).hasPrefix("Recorded"))
        try commit("more.txt", "y\n", in: Worktrees.path(root: root, slug: "held"))
        #expect(lead.auditChoice(lead.workflow, task: task) == nil)
        let audited = lead.call("audit", ["task": "held"])
        #expect(audited.isError && audited.text.contains("no model is left"), "\(audited.text)")
    }

    /// The worktree's settings and the home's are read the careful way at the bind: a link, a FIFO, a file over the
    /// bound, JSON nested too deep: the bind returns at once, records only the launch's own model, and says why.
    @Test(arguments: ["link", "fifo", "big", "deep"])
    func aBindReadsSettingsCarefully(_ kind: String) throws {
        let worktree = temp.url("worktree-\(kind)")
        let folder = worktree.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("settings.local.json")
        switch kind {
        case "link":
            let target = temp.url("elsewhere.json")
            try Data(#"{"model": "fable"}"#.utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        case "fifo":
            #expect(mkfifo(file.path, 0o600) == 0)
        case "big":
            #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
            #expect(truncate(file.path, off_t(300 << 20)) == 0)
        default:
            try Data((String(repeating: "[", count: 5_000) + "\"fable\"" + String(repeating: "]", count: 5_000)).utf8).write(to: file)
        }
        // The home's settings a FIFO too: the default isn't read either.
        let home = temp.url("home-\(kind)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        #expect(mkfifo(home.appendingPathComponent(".claude/settings.json").path, 0o600) == 0)
        let found = WorkerLaunch.families(seen: .init(command: "claude --model opus -- go", cwd: worktree.path), home: home.path, limit: hangGuard)
        #expect(found.families == ["opus"] && found.notes.count == 1 && found.notes[0].contains("settings.local.json"), "\(found)")
        let unnamed = WorkerLaunch.families(seen: .init(command: "claude -- go", cwd: nil), home: home.path, limit: hangGuard)
        #expect(unnamed.families == ["opus"] && unnamed.notes.first?.contains("settings.json") == true, "\(unnamed)")
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
        #expect(launched.contains("--model 'claude-opus-5-5'") && !launchedOn(launched).contains("best"), "\(launched)")
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

    /// The --model and --advisor values a launch command passes (before its `--`).
    func launchedOn(_ command: String) -> [String] {
        let words = WorkerLaunch.words(command).prefix { $0 != "--" }
        return words.indices.compactMap { index in
            ["--model", "--advisor"].contains(words[index]) && index + 1 < words.endIndex ? words[index + 1] : nil
        }
    }

    /// Under the floor a worker launches by its model's full id, and every team session's --settings pins each
    /// family's alias to its id and ANTHROPIC_MODEL to the session's own model.
    @Test func aWorkerLaunchesByFullIDWithTheAliasesPinned() throws {
        let (_, runtime, lead) = try floorTeam(defaultModel: Self.fableDefault, leadModel: "fable", workerModel: "opus")
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"], "review": "audit"])
        #expect(!lead.call("start_worker", ["task": "plain"]).isError)
        let launched = try #require(command("plain", runtime))
        #expect(launchedOn(launched).first == "claude-opus-5-5", "\(launched)")
        let settings = try #require(try LaunchArguments.json("--settings", in: launched) as [String: Any]?)
        let env = try #require(settings["env"] as? [String: String])
        #expect(env["ANTHROPIC_MODEL"] == "claude-opus-5-5")
        for (family, id) in WorkerLaunch.currentIDs { #expect(env["ANTHROPIC_DEFAULT_\(family.uppercased())_MODEL"] == id, "\(family)") }
        // Every id this build pins is one it prices (kept in step with `LeadPrices.table`).
        for id in WorkerLaunch.currentIDs.values { #expect(LeadPrices.table[id] != nil, "\(id)") }
        #expect(WorkerLaunch.fullID("Opus") == "claude-opus-5-5" && WorkerLaunch.fullID("fable[1m]") == "claude-fable-5-2[1m]")
        #expect(WorkerLaunch.fullID("claude-sonnet-4-6") == "claude-sonnet-4-6" && WorkerLaunch.fullID("my-model") == "my-model")
    }
}
