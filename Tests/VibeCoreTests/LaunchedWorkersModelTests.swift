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
        bindWorker("alias", root: root, session: "twice", command: "claude --model opus --name 'a --model haiku' '--model=claude-fable-5-2[1m]' -- 'x --model sonnet'")
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
        return vault.recordAuditGrant(text, of: answered, root: root, home: book.configHome)
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
        guard case .refused = book.answer(.allowAuditModel(root: root, task: "held", commit: head, model: "fable", question: asked.id,
                                                           digest: AuditOffer.questionDigest(text: asked.text, options: asked.options)), from: .session(worker)) else {
            Issue.record("a worker allowed a model")
            return
        }
        #expect(answer(asked, option, root: root) == "Recorded: held may be audited on fable at \(head.prefix(12)), by its next audit only.")
        #expect(lead.auditChoice(lead.workflow, task: task) == "fable")
        let started = lead.call("audit", ["task": "held"])
        #expect(!started.isError, "\(started.text)")
        // Taken by that audit's verifier at its bind: the next audit is held again.
        #expect(vault.auditAllowance(root: root, task: "held")?.usedBy != nil && lead.auditChoice(lead.workflow, task: task) == nil)
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
    @Test(arguments: ["link", "fifo", "big", "deep", "utf16"])
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
        case "utf16":
            // What the parser would read as JSON, its bytes no depth scan of UTF-8 sees as nested.
            try #require((String(repeating: "[", count: 5_000) + "\"fable\"" + String(repeating: "]", count: 5_000)).data(using: .utf16)).write(to: file)
        default:
            try Data((String(repeating: "[", count: 5_000) + "\"fable\"" + String(repeating: "]", count: 5_000)).utf8).write(to: file)
        }
        // The home's settings a FIFO too: the default isn't read either.
        let home = temp.url("home-\(kind)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        #expect(mkfifo(home.appendingPathComponent(".claude/settings.json").path, 0o600) == 0)
        let found = WorkerLaunch.families(seen: .init(command: "claude --model opus -- go", cwd: worktree.path), home: home.path, limit: hangGuard)
        // A link at the end is followed to a regular file (read: its model added); anything else adds nothing.
        #expect(found.families == (kind == "link" ? ["fable", "opus"] : ["opus"]), "\(found)")
        let worktreeNotes = found.notes.filter { $0.contains("settings.local.json") }
        #expect(worktreeNotes.count == (kind == "link" ? 0 : 1) && found.notes.contains { $0.contains("home-") && $0.contains("settings.json") }, "\(found)")
        // No --model, and the default not read (the home's settings a FIFO): every family, never a guess.
        let unnamed = WorkerLaunch.families(seen: .init(command: "claude -- go", cwd: nil), home: home.path, limit: hangGuard)
        #expect(unnamed.families == WorkerLaunch.allFamilies && unnamed.notes.first?.contains("settings.json") == true, "\(unnamed)")
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

    /// Without the floor that keeps audits off the workers' model, nothing is pinned: a session's settings `env` is as
    /// it ever was, and a worker starts by its alias.
    @Test func withoutTheFloorNothingIsPinned() throws {
        let (root, runtime, lead) = try floorTeam(defaultModel: Self.fableDefault, leadModel: "fable")
        try vault.setReviewFloor(LeadReviewFloor(verifierDifferent: false), root: root)
        _ = lead.call("add_task", ["title": "Opus", "goal": "g", "acceptance": ["a"], "review": "audit", "model": "opus"])
        #expect(!lead.call("start_worker", ["task": "opus"]).isError)
        let launched = try #require(command("opus", runtime))
        #expect(launchedOn(launched).first == "opus", "\(launched)")
        let settings = try #require(try LaunchArguments.json("--settings", in: launched) as [String: Any]?)
        let env = settings["env"] as? [String: String] ?? [:]
        #expect(env == LeadLaunch.environment(.worker), "\(env)")
    }

    /// An offer a process in the lead's session filed with no audit out of models (a question of its own, in the
    /// audit's very words): the app side finds a model free by the vault's record, and records nothing.
    @Test func anOfferWithNoModelLeftOutRecordsNothing() throws {
        let (root, _, lead) = try floorTeam(defaultModel: "opus", leadModel: "opus")
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"], "review": "audit"])
        #expect(!lead.call("start_worker", ["task": "plain"]).isError)
        try commit("plain.txt", "x\n", in: Worktrees.path(root: root, slug: "plain"))
        let head = Git.run(["rev-parse", "agent/plain"], in: root).output
        let option = "Audit plain at \(head.prefix(12)) on fable"
        #expect(!lead.call("ask_user", ["question": "Which may audit plain?", "options": [option], "task": "plain"]).isError)
        let question = try #require(BoardStore(root: root).load().questions.last)
        #expect(book.answer(.offerAuditModels(root: root, task: "plain", commit: head, question: question.id,
                                              digest: AuditOffer.questionDigest(text: question.text, options: question.options)), from: .session("lead-session")) == .ok)
        let said = try #require(answer(question, option, root: root))
        #expect(said.contains("is free for its audit"), "\(said)")
        #expect(vault.auditAllowance(root: root, task: "plain") == nil)
    }

    /// A question the lead wrote first in the audit's very words isn't the audit's: the audit asks its own.
    @Test func aPreCreatedLookAlikeIsntAdopted() throws {
        let (root, lead, task, head) = try exhausted()
        let why = lead.workersBasis(task, projectDefault: "opus", workflow: lead.workflow).text
        let short = String(head.prefix(12))
        let text = "Audit held at \(short): every model is one this task's workers ran on (\(why)), and the review floor keeps audits off those. Which may audit it at this commit?"
        let options = ["fable", "opus", "sonnet", "mythos"].map { "Audit held at \(short) on \($0)" }
        #expect(!lead.call("ask_user", ["question": text, "options": options, "task": "held", "priority": "important"]).isError)
        let planted = try #require(BoardStore(root: root).load().questions.last)
        _ = lead.call("audit", ["task": "held"])
        let questions = BoardStore(root: root).load().questions.filter { $0.text == text }
        #expect(questions.count == 2, "\(questions.map(\.id))")
        let asked = try #require(questions.last)
        #expect(asked.id != planted.id && vault.auditOffer(root: root, question: planted.id) == nil && vault.auditOffer(root: root, question: asked.id) != nil)
        // The planted one's answer allows nothing; the audit's does.
        #expect(try #require(answer(planted, options[0], root: root)).contains("isn't the one the audit"))
        #expect(try #require(answer(asked, options[0], root: root)).hasPrefix("Recorded"))
    }

    /// A question reworded (or re-optioned) after the audit asked it isn't the one the audit asked: refused.
    @Test func aQuestionEditedAfterTheOfferIsRefused() throws {
        let (root, lead, task, head) = try exhausted()
        _ = lead.call("audit", ["task": "held"])
        var asked = try #require(BoardStore(root: root).load().questions.last)
        asked.text += " (Fable wrote none of it.)"
        let said = try #require(answer(asked, "Audit held at \(head.prefix(12)) on fable", root: root))
        #expect(said.contains("isn't the one the audit"), "\(said)")
        #expect(lead.auditChoice(lead.workflow, task: task) == nil)
    }

    /// A vault with a lead, the floor (worker_model sonnet), and a worker of `t` the host saw launched on Fable: a
    /// verifier's bind is judged there, whatever the lead's tool server chose.
    func floorBook(floor: LeadReviewFloor = LeadReviewFloor().with(workerModel: "sonnet")) -> (book: LeadVault.Book, root: String, commit: String) {
        let book = LeadVault.Book()
        book.configHome = temp.url("vault-home").path
        let root = "/repo"
        guard case .grant(let lead) = book.answer(.issue(role: .lead, root: root, task: nil, auditing: nil), from: .app) else { return (book, root, "") }
        _ = book.answer(.bind(grant: lead, root: root, session: "lead"), from: .app)
        _ = book.answer(.setReviewFloor(root: root, floor: floor, onlyIfUnset: false), from: .app)
        guard case .grant(let worker) = book.answer(.issue(role: .worker, root: root, task: "t", auditing: nil), from: .session("lead")) else { return (book, root, "") }
        _ = book.answer(.bind(grant: worker, root: root, session: "w"), from: .session("lead"), bound: .init(command: "claude --model fable -- go"))
        return (book, root, String(repeating: "c", count: 40))
    }

    /// A verifier (or finder) bound to a session launched with `command`; the bind's reply.
    func bindVerifier(_ book: LeadVault.Book, root: String, commit: String, session: String, command: String?,
                      finder: LeadVault.Finder? = nil, agent: Agent? = nil) -> LeadVault.Reply {
        guard case .grant(let grant) = book.answer(.issue(role: .verifier, root: root, task: "t", auditing: commit, finder: finder, agent: agent),
                                                   from: .session("lead")) else { return .refused("no grant") }
        // A Claude verifier's own flags, as its launch carries them (`RoleLaunchCheck.verifierFlags`).
        let carried = command.map { agent != .codex && $0.hasPrefix("claude ") ? "claude --setting-sources user --strict-mcp-config" + $0.dropFirst("claude".count) : $0 }
        return book.answer(.bind(grant: grant, root: root, session: session), from: .session("lead"), bound: carried.map { .init(command: $0) })
    }

    /// The user's allowance of `model` for `t` at `commit`, as the app records an answer to the audit's question.
    func allow(_ book: LeadVault.Book, root: String, commit: String, model: String) {
        #expect(book.answer(.offerAuditModels(root: root, task: "t", commit: commit, question: "q", digest: "d"), from: .session("lead")) == .ok)
        #expect(book.answer(.allowAuditModel(root: root, task: "t", commit: commit, model: model, question: "q", digest: "d"), from: .app) == .ok)
    }

    /// F1: a verifier on a family the vault's record excludes (a worker's Fable, the floor's Sonnet) holds no role, and its
    /// verdict counts for nothing; one on a free model is bound; none or an alias is refused.
    @Test func aVerifierOnAnExcludedModelIsntBound() {
        let (book, root, commit) = floorBook()
        guard case .refused = bindVerifier(book, root: root, commit: commit, session: "v-fable", command: "claude --model 'claude-fable-5-2' -- go") else {
            Issue.record("a verifier on Fable was bound")
            return
        }
        guard case .refused = book.answer(.submitVerdict(root: root, completion: .complete, integrity: .clean, summary: "ok"), from: .session("v-fable")) else {
            Issue.record("its verdict counted")
            return
        }
        guard case .refused = bindVerifier(book, root: root, commit: commit, session: "v-sonnet", command: "claude --model sonnet -- go") else {
            Issue.record("a verifier on the floor's worker_model was bound")
            return
        }
        for command in ["claude -- go", "claude --model best -- go", "claude --model opusplan -- go"] {
            guard case .refused = bindVerifier(book, root: root, commit: commit, session: "v-\(command.count)", command: command) else {
                Issue.record("\(command) was bound")
                return
            }
        }
        #expect(bindVerifier(book, root: root, commit: commit, session: "v-opus", command: "claude --model 'claude-opus-5-5' -- go") == .ok)
    }

    /// With the user's allowance for that commit, one verifier on that model is bound, the vault taking the allowance;
    /// a second is refused; another commit's audit isn't covered.
    @Test func anAllowanceLetsOneVerifierBind() {
        let (book, root, commit) = floorBook()
        allow(book, root: root, commit: commit, model: "fable")
        guard case .refused = bindVerifier(book, root: root, commit: String(repeating: "d", count: 40), session: "v-other", command: "claude --model fable -- go") else {
            Issue.record("another commit's verifier used it")
            return
        }
        #expect(bindVerifier(book, root: root, commit: commit, session: "v1", command: "claude --model fable -- go") == .ok)
        guard case .allowance(let taken?) = book.answer(.auditAllowance(root: root, task: "t"), from: .app), taken.usedBy != nil else {
            Issue.record("the allowance wasn't taken")
            return
        }
        guard case .refused = bindVerifier(book, root: root, commit: commit, session: "v2", command: "claude --model fable -- go") else {
            Issue.record("a second verifier used it")
            return
        }
    }

    /// A finders' panel shares the allowance: each of its finders binds; another panel's doesn't.
    @Test func anAllowanceLetsOnePanelsFindersBind() {
        let (book, root, commit) = floorBook()
        allow(book, root: root, commit: commit, model: "fable")
        func finder(_ panel: String, _ index: Int) -> LeadVault.Finder { .init(panel: panel, index: index, size: 2, focus: "f", nitCap: 3) }
        #expect(bindVerifier(book, root: root, commit: commit, session: "f1", command: "claude --model fable -- go", finder: finder("p", 1)) == .ok)
        #expect(bindVerifier(book, root: root, commit: commit, session: "f2", command: "claude --model fable -- go", finder: finder("p", 2)) == .ok)
        guard case .refused = bindVerifier(book, root: root, commit: commit, session: "g1", command: "claude --model fable -- go", finder: finder("q", 1)) else {
            Issue.record("another panel used it")
            return
        }
    }

    /// No floor keeping audits off the workers' model: binds as before, whatever the model.
    @Test func withoutTheFloorAVerifierBindsAsBefore() {
        let (book, root, commit) = floorBook(floor: LeadReviewFloor(verifierDifferent: false))
        #expect(bindVerifier(book, root: root, commit: commit, session: "v", command: "claude --model fable -- go") == .ok)
        #expect(bindVerifier(book, root: root, commit: commit, session: "v0", command: nil) == .ok)
    }

    /// A Codex verifier: bound unless a Codex worker worked on the task.
    @Test func aCodexVerifierIsKeptOffACodexWorkersTask() {
        let (book, root, commit) = floorBook()
        #expect(bindVerifier(book, root: root, commit: commit, session: "c1", command: "codex --model gpt-6", agent: .codex) == .ok)
        guard case .grant(let worker) = book.answer(.issue(role: .worker, root: root, task: "t", auditing: nil, agent: .codex), from: .session("lead")) else { return }
        #expect(book.answer(.bind(grant: worker, root: root, session: "cw"), from: .session("lead"), bound: .init(command: "codex --model gpt-6")) == .ok)
        guard case .refused = bindVerifier(book, root: root, commit: commit, session: "c2", command: "codex --model gpt-6", agent: .codex) else {
            Issue.record("a Codex verifier on a Codex worker's task was bound")
            return
        }
    }

    /// The agent is the host's, not the lead's word: a worker declared Codex whose command is `claude --model fable`, and
    /// a verifier declared Codex with a Claude command, hold no role; the task's record stays the true one.
    @Test func aDeclaredAgentTheCommandBeliesIsntBound() {
        let (book, root, commit) = floorBook()
        guard case .grant(let worker) = book.answer(.issue(role: .worker, root: root, task: "t", auditing: nil, agent: .codex), from: .session("lead")) else { return }
        guard case .refused = book.answer(.bind(grant: worker, root: root, session: "fake-codex"), from: .session("lead"),
                                          bound: .init(command: "claude --model fable -- go")) else {
            Issue.record("a Claude worker declared Codex was bound")
            return
        }
        #expect(book.answer(.launchedFamilies(root: root, task: "t"), from: .app) == .families(["fable"]))
        guard case .refused = bindVerifier(book, root: root, commit: commit, session: "fake-codex-v", command: "claude --model fable -- go", agent: .codex) else {
            Issue.record("a Claude verifier declared Codex was bound")
            return
        }
        // A Claude grant whose session runs Codex isn't bound either.
        guard case .refused = bindVerifier(book, root: root, commit: commit, session: "codex-as-claude", command: "codex -m gpt-6") else {
            Issue.record("a Codex session bound on a Claude grant")
            return
        }
    }

    /// The agent is judged by the program that runs: one simple command, `env` the only wrapper passed over, a path
    /// resolved to Claude Code's or Codex's own; a shell, `sh -c`, a look-alike path, an argument that is only the word,
    /// or a second command after the first isn't told apart, and holds no role under the floor.
    @Test func theAgentIsTheProgramThatRuns() throws {
        let versions = temp.url("share").appendingPathComponent("claude/versions")
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        let real = versions.appendingPathComponent("2.1.282")
        try installScript("#!/bin/sh\n", at: real)
        let link = temp.url("bin-claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        // The node's own links name Claude Code's and Codex's programs here (its engine starts roles by those paths).
        let codex = temp.url("codex-bin").appendingPathComponent("codex.js")
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try installScript("#!/usr/bin/env node\n", at: codex)
        let nodeLinks: [Agent: [String]] = [.claude: [link.path], .codex: [codex.path]]
        let lookAlike = temp.url("wrappers").appendingPathComponent("claude")
        let codexLookAlike = temp.url("wrappers").appendingPathComponent("codex")
        let package = temp.url("prefix").appendingPathComponent("lib/node_modules/@openai/codex/bin/codex.js")
        for file in [lookAlike, codexLookAlike, package] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try installScript("#!/bin/sh\nexec codex-evil\n", at: file)
        }
        #expect(WorkerLaunch.commandAgent("env -i '\(real.path)' --model opus -- go", links: nodeLinks) == .claude)
        #expect(WorkerLaunch.commandAgent("'\(link.path)' --model opus", links: nodeLinks) == .claude)
        #expect(WorkerLaunch.commandAgent("'\(codex.path)' -m gpt-6", links: nodeLinks) == .codex)
        // A quoted start message is literal, whatever it holds.
        #expect(WorkerLaunch.commandAgent("claude --model opus -- 'a; b | c $HOME/*.txt ~ {a,b} [x]?'") == .claude)
        #expect(WorkerLaunch.commandAgent("env -i claude") == .claude)
        for command in ["sh -c 'exec codex-evil' claude", "env X=claude real-program", "'\(lookAlike.path)' --model opus", "bash codex", "bash -l",
                        "claude --model opus; claude --model fable", "exec -a claude fable", "env -S 'claude' x", "claude --model opus > out.txt",
                        // Any assignment: none is put in a role's command, and each may change the model, the config or what runs.
                        "FOO=1 claude", "PATH=/x claude", "env PATH=/x codex", "NODE_OPTIONS=--require=/x/evil.js codex", "LD_PRELOAD=/x.so claude",
                        "ANTHROPIC_MODEL=claude-fable-5-2 claude", "CLAUDE_CONFIG_DIR=/x claude", "env -i CODEX_HOME=/x codex",
                        // Not assignments to the shell: a program by that name.
                        "'FOO=1' claude", "\"PATH\"=/x claude", "é=1 claude",
                        // A name alone, or a package path anyone of the uid could make.
                        "'\(codexLookAlike.path)' -m gpt-6", "'\(package.path)'",
                        // What the shell would expand: never taken literally.
                        "/a/b/cl*", "$HOME/x", "~/.local/bin/claude", "{claude,x}", "\"$HOME\"/claude", "claude[0]"] {
            #expect(WorkerLaunch.commandAgent(command, links: nodeLinks) == nil, "\(command)")
        }
        // What a scratch node's stand-in link names counts as that agent (a test's program).
        #expect(WorkerLaunch.commandAgent("'\(lookAlike.path)' --model opus", links: [.claude: [lookAlike.path]]) == .claude)
        // A link is judged by what it resolves to, never by being the account's link: one to bash is bash.
        let toBash = temp.url("account-bin").appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: toBash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: toBash.path, withDestinationPath: "/bin/bash")
        #expect(WorkerLaunch.commandAgent("'\(toBash.path)' -c 'exec fable' x --model claude-sonnet-5-5", links: [:]) == nil)
        // A package path in a Claude Code-looking place under the home, but not its versions folder: nil.
        let cli = temp.url("w").appendingPathComponent("lib/node_modules/@anthropic-ai/claude-code/cli")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try installScript("#!/bin/sh\n", at: cli)
        #expect(WorkerLaunch.commandAgent("'\(cli.path)' --model opus", links: [:]) == nil)
        // The stand-ins' links count only on a scratch node (these tests' root isn't the account's own).
        #expect(WorkerLaunch.nodeLinks.isEmpty == VibePaths.isAccountRoot(VibePaths.root, accountHome: VibePaths.accountHome))
        #expect(!WorkerLaunch.nodeLinks.isEmpty)
        // Under the floor, such a session holds no role.
        let (book, root, commit) = floorBook()
        guard case .refused(let why) = bindVerifier(book, root: root, commit: commit, session: "sh", command: "sh -c 'exec claude --model fable' claude") else {
            Issue.record("a shell bound as a verifier")
            return
        }
        #expect(why.contains("can tell apart"), "\(why)")
    }

    /// A finder issued later under a panel's name that took the allowance isn't bound on it: one panel's worth, each
    /// index once.
    @Test func aFinderIssuedLaterUnderTheSamePanelIsntBound() {
        let (book, root, commit) = floorBook()
        allow(book, root: root, commit: commit, model: "fable")
        func finder(_ index: Int) -> LeadVault.Finder { .init(panel: "p", index: index, size: 2, focus: "f", nitCap: 3) }
        #expect(bindVerifier(book, root: root, commit: commit, session: "f1", command: "claude --model fable -- go", finder: finder(1)) == .ok)
        #expect(bindVerifier(book, root: root, commit: commit, session: "f2", command: "claude --model fable -- go", finder: finder(2)) == .ok)
        guard case .refused = bindVerifier(book, root: root, commit: commit, session: "f1-again", command: "claude --model fable -- go", finder: finder(1)) else {
            Issue.record("a later finder under the panel's name used it")
            return
        }
    }

    /// V1: a Codex worker's record is Codex and its command's model family too.
    @Test func aCodexWorkersRecordHasItsCommandsModelToo() {
        let (book, root, _) = floorBook()
        guard case .grant(let worker) = book.answer(.issue(role: .worker, root: root, task: "x", auditing: nil, agent: .codex), from: .session("lead")) else { return }
        #expect(book.answer(.bind(grant: worker, root: root, session: "cx"), from: .session("lead"), bound: .init(command: "codex --model claude-opus-5-5")) == .ok)
        #expect(book.answer(.launchedFamilies(root: root, task: "x"), from: .app) == .families(["codex", "opus"]))
    }

    /// V2: with no worker_model and Claude Code's default unreadable, a verifier's bind is refused (the workers' model
    /// isn't known), and a worker's launch with no --model is recorded as every family.
    @Test func anUnreadableDefaultFailsClosed() throws {
        let (book, root, commit) = floorBook(floor: LeadReviewFloor())
        let settings = URL(fileURLWithPath: book.configHome).appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(mkfifo(settings.path, 0o600) == 0)
        guard case .refused(let why) = bindVerifier(book, root: root, commit: commit, session: "v", command: "claude --model sonnet -- go") else {
            Issue.record("a verifier bound with the default unknown")
            return
        }
        #expect(why.contains("couldn't be read"), "\(why)")
        guard case .grant(let worker) = book.answer(.issue(role: .worker, root: root, task: "y", auditing: nil), from: .session("lead")) else { return }
        #expect(book.answer(.bind(grant: worker, root: root, session: "wy"), from: .session("lead"), bound: .init(command: "claude -- go")) == .ok)
        #expect(book.answer(.launchedFamilies(root: root, task: "y"), from: .app) == .families(WorkerLaunch.allFamilies))
        // The lead's tools read the same set: every family, so no audit model is left and the user is asked.
        #expect(book.answer(.auditExclusions(root: root, task: "y"), from: .app) == .families(WorkerLaunch.allFamilies))
    }

    /// V4: the lead's choice is made from the vault's set too: with the project's command on Sonnet and Claude Code's
    /// default (where the vault reads it) on Fable, the audit isn't put on Fable, which the bind would refuse.
    @Test func theLeadsChoiceNeverTakesAModelTheVaultExcludes() throws {
        let (root, runtime, lead) = try floorTeam(defaultModel: "sonnet", leadModel: "opus")
        runtime.claude = "claude --model sonnet"
        try writeVaultDefault(Self.fableDefault)
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"], "review": "audit"])
        #expect(!lead.call("start_worker", ["task": "plain"]).isError)
        let task = try #require(task("plain", root))
        #expect(vault.auditExclusions(root: root, task: "plain") == ["fable", "sonnet"])
        let choice = try #require(lead.auditChoice(lead.workflow, task: task))
        #expect(!["fable", "sonnet"].contains { LeadReviewFloor.sameModel(choice, $0) }, "\(choice)")
        try commit("plain.txt", "x\n", in: Worktrees.path(root: root, slug: "plain"))
        let audited = lead.call("audit", ["task": "plain"])
        #expect(!audited.isError, "\(audited.text)")
    }

    // MARK: X1: a role's launch carries what VibeSwitcher's own does

    /// The `--settings` a prepared launch carries, as the bind reads it: inline JSON, or the file's text.
    func settingsRead(_ prepared: LeadLaunch.Prepared) -> RoleLaunchCheck.SettingsRead? {
        guard let path = RoleLaunchCheck.settingsPath(in: prepared.command) else { return nil }
        return (try? String(contentsOfFile: path, encoding: .utf8)).map { .text($0) } ?? .unread(path)
    }

    /// The builders' own launches pass their check, each role and agent, with the toolset's heavy-slot variables, on the
    /// Mac's presets' defaults and the node's program by its path: the allowlists are the builders' output.
    @Test func whatTheBuildersLaunchPassesTheCheck() throws {
        let root = temp.url("builders-repo").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let toolset = [TestLock.slotsVariable, TestLock.timeoutVariable, TestLock.stallVariable]
        let presets = LaunchPresets.builtIns().presets(for: nil).filter { $0.kind != .shell }.map(\.command)
        #expect(presets == ["claude", "codex"])
        // Each launch made in a leads' folder reached by a link (the Mac's /var and /tmp are links) and judged as the
        // bind judges it, from the bind's own facts and the run folder it resolves, its settings inline (Linux) and as a
        // file (the Mac's, S10) on every platform.
        let leads = temp.url("builders-leads")
        let leadsLink = temp.url("builders-leads-link")
        try FileManager.default.createDirectory(at: leads, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: leadsLink, withDestinationURL: leads)
        let launches = LeadVault(folder: leadsLink) { _ in .ok }
        for base in ["claude", "'/home/u/.local/share/claude/versions/2.1.332'"] {
            for role in [LeadLaunch.Role.worker, .verifier] {
                for pins in [false, true] {
                    for inline in [true, false] {
                        let name = "\(role.rawValue)-t-\(pins)-\(inline)-\(base.count)"
                        let prepared = try LeadLaunch.prepare(role: role, root: root, task: "t", base: base, prompt: "p {x} $HOME ~ [y]",
                                                              start: "Go on: a; b | c {d} $e", server: "/s", name: name, model: "claude-opus-5-5",
                                                              advisor: "fable", effort: "high", folder: launches.runFolder(root: root, name: name),
                                                              pinModels: pins, inline: inline)
                        #expect((RoleLaunchCheck.settingsPath(in: prepared.command) == nil) == inline, "\(name): \(prepared.command.prefix(300))")
                        let facts = WorkerLaunch.bindFacts(seen: .init(command: prepared.command, environmentNames: Array(prepared.environment.keys) + toolset),
                                                           home: temp.url("builders-home").path, limit: 60)
                        let why = RoleLaunchCheck.refusal(facts, agent: .claude, role: role, digest: prepared.settingsDigest, root: root, lead: leads,
                                                          inline: inline)
                        #expect(why == nil, "\(name): \(why ?? "")")
                    }
                }
            }
        }
        for role in [LeadLaunch.Role.worker, .verifier] {
            let prepared = try LeadLaunch.prepareCodex(root: root, task: "t", base: "codex", prompt: "p", start: "Go", server: "/s", name: "codex-\(role.rawValue)",
                                                       model: "gpt-6", effort: "high", folder: temp.url("codex-run-\(role.rawValue)"), cwd: root, role: role)
            let why = RoleLaunchCheck.refusal(command: prepared.command, agent: .codex, role: role, environment: Array(prepared.environment.keys) + toolset, settings: nil)
            #expect(why == nil, "codex \(role): \(why ?? "")")
        }
        // The real node's worker command, as its process list shows it.
        let real = "'/home/u/.local/share/claude/versions/2.1.332' --permission-mode auto --name 'worker-sb6-2-2-a' --model 'opus' --advisor 'fable' --effort 'high' "
            + "--mcp-config '{\"mcpServers\":{\"vibeswitcher\":{\"args\":[\"--keeper\",\"--role\",\"worker\"],\"command\":\"/x/bin/vibeswitcher-mcp\"}}}' "
            + "--settings '{\"enabledPlugins\":{\"a@b\":false},\"env\":{\"GIT_EDITOR\":\"true\",\"GIT_OPTIONAL_LOCKS\":\"0\"},\"hooks\":{},\"permissions\":{\"allow\":[\"Bash(git status:*)\"],\"deny\":[]},\"statusLine\":{\"type\":\"command\"}}' "
            + "--append-system-prompt 'You are a worker {x} [y] $z' -- 'Start the task.'"
        #expect(RoleLaunchCheck.refusal(command: real, agent: .claude, role: .worker, environment: [SessionNote.roleVariable, LeadLaunch.autoUpdaterVariable, "TMPDIR"],
                                        settings: nil) == nil)
    }

    /// What can change the model without `--model` is refused under the floor, in one plain sentence with the way out.
    @Test func whatCanChangeTheModelIsRefused() {
        let base = "claude --name w --model opus"
        let env = [SessionNote.roleVariable, "TMPDIR"]
        func refused(_ command: String, agent: Agent = .claude, environment: [String]? = nil, settings: RoleLaunchCheck.SettingsRead? = nil) -> String? {
            RoleLaunchCheck.refusal(command: command, agent: agent, role: .worker, environment: environment ?? env, settings: settings)
        }
        #expect(refused(base + " --fallback-model fable -- go") == "This session's command has `--fallback-model`, which the node can't vouch for under your review rules: remove it from the launch preset, or lower `floor_verifier_different`.")
        for command in [base + " --agents '{\"x\":{\"model\":\"fable\"}}' -- go",
                        base + " --settings '{\"env\":{\"GIT_EDITOR\":\"true\"}}' --settings '{\"env\":{}}' -- go",
                        base + " --settings '{\"env\":{\"ANTHROPIC_BASE_URL\":\"https://x\"}}' -- go",
                        base + " --settings '{\"model\":\"fable\"}' -- go",
                        base + " --settings '{\"fallbackModel\":\"fable\"}' -- go",
                        base + " --settings 'not json' -- go"] {
            #expect(refused(command)?.hasSuffix("which the node can't vouch for under your review rules: remove it from the launch preset, or lower `floor_verifier_different`.") == true, "\(command)")
        }
        #expect(refused("codex --no-daemon -c 'model=o3' --model gpt-6 -- go", agent: .codex)?.contains("`-c model`") == true)
        #expect(refused("codex --no-daemon -c 'mcp_servers.vibeswitcher.command=\"/s\"' --model gpt-6 -- go", agent: .codex) == nil)
        #expect(refused(base + " -- go", environment: env + ["PATH"])?.contains("spawn environment has `PATH`") == true)
        #expect(refused(base + " -- go", environment: env + ["ANTHROPIC_MODEL"])?.contains("`ANTHROPIC_MODEL`") == true)
        // A `--settings` file where settings are inline: never the launch's (the Mac's: `aSettingsFileIsOnlyTheOneTheLaunchWrote`).
        #expect(RoleLaunchCheck.refusal(command: base + " --settings /run/s.json -- go", agent: .claude, role: .worker, environment: env,
                                        settings: .text("{\"env\":{\"GIT_EDITOR\":\"true\"}}"), inline: true)?.contains("gives its settings inline") == true)
        // A flag twice (the program takes the last), a value that starts with `-`, a switch given a value.
        #expect(refused("claude --model opus --name a --name b -- go")?.contains("`--name` more than once") == true)
        #expect(refused("claude --model opus --model fable -- go") == nil)
        #expect(refused("claude --model opus --append-system-prompt '--fallback-model is not a flag here' -- go")?.contains("given `--fallback-model") == true)
        #expect(refused(base + " --strict-mcp-config=x -- go") != nil)
        // The host's recorded command (long values as '…', `LinuxLaunch.recorded`) can't be judged: the bind takes the full one.
        #expect(refused(base + " --settings '…' -- go") != nil)
        // Words after `--` are the start message, never flags.
        #expect(refused(base + " -- 'use --fallback-model fable'") == nil)
    }

    /// At the bind: under the floor such a worker holds no role; without it, as before.
    @Test func aBindUnderTheFloorJudgesTheLaunchAndWithoutItNothingChanges() {
        let fallback = "claude --model sonnet --fallback-model fable -- go"
        let (book, root, _) = floorBook()
        guard case .grant(let worker) = book.answer(.issue(role: .worker, root: root, task: "x", auditing: nil), from: .session("lead")) else { return }
        guard case .refused(let why) = book.answer(.bind(grant: worker, root: root, session: "fb"), from: .session("lead"),
                                                   bound: .init(command: fallback, environmentNames: [SessionNote.roleVariable])) else {
            Issue.record("a worker with --fallback-model was bound under the floor")
            return
        }
        #expect(why.contains("`--fallback-model`"), "\(why)")
        guard case .grant(let pathed) = book.answer(.issue(role: .worker, root: root, task: "y", auditing: nil), from: .session("lead")) else { return }
        guard case .refused = book.answer(.bind(grant: pathed, root: root, session: "path"), from: .session("lead"),
                                          bound: .init(command: "claude --model sonnet -- go", environmentNames: [SessionNote.roleVariable, "PATH"])) else {
            Issue.record("a worker whose spawn set PATH was bound under the floor")
            return
        }
        let (free, freeRoot, _) = floorBook(floor: LeadReviewFloor(verifierDifferent: false))
        guard case .grant(let other) = free.answer(.issue(role: .worker, root: freeRoot, task: "x", auditing: nil), from: .session("lead")) else { return }
        #expect(free.answer(.bind(grant: other, root: freeRoot, session: "fb"), from: .session("lead"),
                            bound: .init(command: fallback, environmentNames: [SessionNote.roleVariable, "PATH"])) == .ok)
    }

    // MARK: Codex's install roots

    /// bun's root in the account's home counts by its path; npm's global roots only when root's all the way down; a Codex
    /// path outside them is refused under the floor, named with the roots.
    @Test func codexCountsUnderItsInstallRootsAndNpmsOnlyWhenRoots() throws {
        let roots = WorkerLaunch.codexRoots.map(\.folder)
        #expect(roots == [(VibePaths.accountHome as NSString).appendingPathComponent(".bun/install/global/node_modules/@openai/codex") + "/",
                          "/usr/lib/node_modules/@openai/codex/", "/usr/local/lib/node_modules/@openai/codex/", "/opt/homebrew/lib/node_modules/@openai/codex/"])
        #expect(WorkerLaunch.codexRoots.map(\.rootOwned) == [false, true, true, true])
        // A home root (bun's): its path is enough.
        let bun = temp.url("bun/install/global/node_modules/@openai/codex")
        try FileManager.default.createDirectory(at: bun.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let program = bun.appendingPathComponent("bin/codex.js")
        try Data("codex stand-in".utf8).write(to: program)
        let link = temp.url("bun-codex-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: program)
        let home = WorkerLaunch.CodexRoot(folder: bun.path, rootOwned: false)
        #expect(WorkerLaunch.agent(atPath: link.path, links: [:], codexRoots: [home]) == .codex)
        // The same folder as an npm root: not root's, so not Codex.
        #expect(WorkerLaunch.agent(atPath: program.path, links: [:], codexRoots: [WorkerLaunch.CodexRoot(folder: bun.path, rootOwned: true)]) == nil)
        // A root that is root's all the way down (the system's /usr/bin, standing in for npm's): counted.
        let env = try #require(WorkerLaunch.realPathOf("/usr/bin/env"))
        #expect(WorkerLaunch.rootsAlone(env))
        #expect(WorkerLaunch.agent(atPath: "/usr/bin/env", links: [:], codexRoots: [WorkerLaunch.CodexRoot(folder: (env as NSString).deletingLastPathComponent, rootOwned: true)]) == .codex)
        #expect(!WorkerLaunch.rootsAlone(program.path))
        // Outside every root: nil, and the refusal names the path and the roots.
        #expect(WorkerLaunch.agent(atPath: program.path, links: [:], codexRoots: []) == nil)
        let said = WorkerLaunch.codexRootsSaid("/x/codex")
        #expect(said.contains("/x/codex") && said.contains("/usr/lib/node_modules/@openai/codex/ (root's)") && said.contains(".bun/install/global"), "\(said)")
    }

    /// At the bind under the floor: a Codex grant whose program isn't under a root is refused, naming the path.
    @Test func aCodexOutsideItsRootsIsRefusedNamingThePath() throws {
        let (book, root, _) = floorBook()
        guard case .grant(let worker) = book.answer(.issue(role: .worker, root: root, task: "x", auditing: nil, agent: .codex), from: .session("lead")) else {
            Issue.record("no grant")
            return
        }
        let stray = temp.url("npm-user/lib/node_modules/@openai/codex/bin/codex.js")
        try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("codex stand-in".utf8).write(to: stray)
        guard case .refused(let why) = book.answer(.bind(grant: worker, root: root, session: "cx"), from: .session("lead"),
                                                   bound: .init(command: "'\(stray.path)' --model gpt-6 -- go", links: [:])) else {
            Issue.record("a Codex outside its roots was bound under the floor")
            return
        }
        #expect(why.contains(stray.path) && why.contains("install roots"), "\(why)")
    }

    // MARK: The options as the agent reads them

    /// One reading of the options, as Claude Code's parser reads them: a value-taking flag takes the next word whatever
    /// it is, `--` included; only a `--` where a flag could start ends them; `--resume`'s value only when it doesn't
    /// start with `-`.
    @Test func theOptionsAreReadAsTheAgentReadsThem() {
        let hidden = "claude --model sonnet --name -- --model claude-fable-5-2 -- 'start'"
        #expect(WorkerLaunch.launchModel(command: hidden) == "claude-fable-5-2")
        #expect(WorkerLaunch.options(of: hidden).map(\.flag) == ["--model", "--name", "--model"])
        #expect(RoleLaunchCheck.refusal(command: hidden, agent: .claude, role: .worker, environment: nil, settings: nil)?.contains("`--name` given `--`") == true)
        #expect(WorkerLaunch.launchModel(command: "claude --model x -- --model y") == "x")
        #expect(RoleLaunchCheck.settingsPath(in: "claude --name -- --settings /x/s.json -- go") == "/x/s.json")
        #expect(RoleLaunchCheck.settingsPath(in: "claude -- --settings /x/s.json") == nil)
        // `--resume [value]`: the next flag is a flag.
        #expect(WorkerLaunch.options(of: "claude --resume --fallback-model fable").map(\.flag) == ["--resume", "--fallback-model"])
        #expect(WorkerLaunch.options(of: "claude --resume abc --model x").map(\.value) == ["abc", "x"])
        #expect(WorkerLaunch.launchModel(command: "claude --resume --model claude-fable-5-2 -- go") == "claude-fable-5-2")
        for command in ["claude --model sonnet --resume --fallback-model claude-fable-5-2 -- go",
                        "claude --model sonnet --resume --settings '{\"env\":{\"ANTHROPIC_BASE_URL\":\"https://x\"}}' -- go",
                        "claude --model sonnet --resume abc -- go"] {
            #expect(RoleLaunchCheck.refusal(command: command, agent: .claude, role: .worker, environment: nil, settings: nil) != nil, "\(command)")
        }
        // Codex's: one value each, `--no-daemon` none.
        #expect(WorkerLaunch.options(of: "codex --no-daemon --cd /w -c 'a=1' --model gpt-6 -- go").map(\.value) == [nil, "/w", "a=1", "gpt-6"])
        #expect(RoleLaunchCheck.refusal(command: "codex --no-daemon --cd -- --model o3 -- go", agent: .codex, role: .worker, environment: nil, settings: nil) != nil)
    }

    /// A verifier carries `--setting-sources user` and `--strict-mcp-config`, exactly; a worker neither.
    @Test func eachRoleCarriesItsOwnFlagsExactly() {
        func refused(_ command: String, _ role: LeadLaunch.Role) -> String? {
            RoleLaunchCheck.refusal(command: command, agent: .claude, role: role, environment: nil, settings: nil)
        }
        let verifier = "claude --name v --model opus --setting-sources user --strict-mcp-config -- go"
        #expect(refused(verifier, .verifier) == nil)
        #expect(refused("claude --name v --model opus --strict-mcp-config -- go", .verifier)?.contains("lacks `--setting-sources user`") == true)
        #expect(refused("claude --name v --model opus --setting-sources user -- go", .verifier)?.contains("lacks `--strict-mcp-config`") == true)
        #expect(refused("claude --name v --model opus --setting-sources user,project,local --strict-mcp-config -- go", .verifier)?
            .contains("a verifier's launch carries `--setting-sources user`") == true)
        #expect(refused(verifier, .worker)?.contains("`--setting-sources`") == true)
        #expect(refused("claude --name w --model opus --strict-mcp-config -- go", .worker)?.contains("`--strict-mcp-config`") == true)
        #expect(refused("claude --name w --model opus -- go", .worker) == nil)
    }

    /// A `--settings` file: never where settings are inline (Linux); where they aren't (the Mac's), only the one the
    /// launch wrote, by its digest, in the launch's own folder.
    @Test func aSettingsFileIsOnlyTheOneTheLaunchWrote() {
        let text = "{\"env\":{\"GIT_EDITOR\":\"true\"}}"
        let folder = "/v/lead/run/abc/"
        let command = "claude --name w --model opus --settings \(folder)w-x/settings.json -- go"
        // The folder the bind found the file in, as it resolves it (here, paths with no links).
        func refused(_ command: String, read: RoleLaunchCheck.SettingsRead?, digest: String?, inline: Bool) -> String? {
            RoleLaunchCheck.refusal(command: command, agent: .claude, role: .worker, environment: nil, settings: read,
                                    file: .init(digest: digest, folder: folder),
                                    settingsAt: RoleLaunchCheck.settingsPath(in: command).map { (($0 as NSString).deletingLastPathComponent as NSString).standardizingPath },
                                    inline: inline)
        }
        let digest = WalletStamp.digest(Data(text.utf8))
        #expect(refused(command, read: .text(text), digest: digest, inline: true)?.contains("gives its settings inline") == true)
        #expect(refused(command, read: .text(text), digest: digest, inline: false) == nil)
        #expect(refused(command, read: .text(text + " "), digest: digest, inline: false)?.contains("isn't the one VibeSwitcher wrote") == true)
        #expect(refused(command, read: .text(text), digest: nil, inline: false) != nil)
        #expect(refused(command, read: .unread("x"), digest: digest, inline: false)?.contains("couldn't read") == true)
        #expect(refused("claude --name w --model opus --settings /elsewhere/settings.json -- go", read: .text(text), digest: digest, inline: false)?
            .contains("outside its launch's own folder") == true)
        #expect(refused("claude --name w --model opus --settings \(folder)../x/settings.json -- go", read: .text(text), digest: digest, inline: false) != nil)
        // The builder's digest is its file's, and an inline launch carries none.
        let prepared = LeadLaunch.Prepared(command: "c", promptFile: "/p", mcpFile: "/m", settingsFile: "/s")
        #expect(prepared.settingsDigest == nil)
    }

    /// The launch builder's digest is what it wrote; inlined, it carries none.
    @Test func theBuildersDigestIsWhatItWrote() throws {
        let root = temp.url("digest-repo").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let prepared = try LeadLaunch.prepare(role: .worker, root: root, task: "t", base: "claude", prompt: "p", start: "go", server: "/s",
                                              name: "w-t", model: "opus", folder: temp.url("digest-run"))
        if Platform.Tools.roleSettingsInline {
            #expect(prepared.settingsDigest == nil)
        } else {
            let data = try Data(contentsOf: URL(fileURLWithPath: prepared.settingsFile))
            #expect(prepared.settingsDigest == WalletStamp.digest(data))
        }
    }

    /// At the bind under the floor: a worker whose branch's settings route it elsewhere, and a session whose full
    /// command the host no longer has, hold no role; without the floor, as before.
    @Test func aRoutedBranchAndAnUnknownFullCommandAreRefused() throws {
        let worktree = temp.url("routed-worktree")
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data("{\"env\":{\"ANTHROPIC_BASE_URL\":\"https://gateway.example\"}}".utf8).write(to: worktree.appendingPathComponent(".claude/settings.local.json"))
        let (book, root, _) = floorBook()
        guard case .grant(let worker) = book.answer(.issue(role: .worker, root: root, task: "x", auditing: nil), from: .session("lead")) else { return }
        guard case .refused(let why) = book.answer(.bind(grant: worker, root: root, session: "routed"), from: .session("lead"),
                                                   bound: .init(command: "claude --model sonnet -- go", cwd: worktree.path)) else {
            Issue.record("a routed worker was bound under the floor")
            return
        }
        #expect(why.contains("ANTHROPIC_BASE_URL in .claude/settings.local.json"), "\(why)")
        // A role's own is pinned to Anthropic's API (a subscription session was seen to start with it, 2026-11-26).
        #expect(WorkerLaunch.pins(model: "opus")["ANTHROPIC_BASE_URL"] == "https://api.anthropic.com")
        guard case .grant(let other) = book.answer(.issue(role: .worker, root: root, task: "y", auditing: nil), from: .session("lead")) else { return }
        guard case .refused(let restart) = book.answer(.bind(grant: other, root: root, session: "clipped"), from: .session("lead"),
                                                       bound: .init(command: "claude --model sonnet --settings '…' -- go", full: false)) else {
            Issue.record("a session without its full command was bound under the floor")
            return
        }
        #expect(restart.contains("start it again"), "\(restart)")
        let (free, freeRoot, _) = floorBook(floor: LeadReviewFloor(verifierDifferent: false))
        guard case .grant(let loose) = free.answer(.issue(role: .worker, root: freeRoot, task: "x", auditing: nil), from: .session("lead")) else { return }
        #expect(free.answer(.bind(grant: loose, root: freeRoot, session: "routed"), from: .session("lead"),
                            bound: .init(command: "claude --model sonnet -- go", cwd: worktree.path)) == .ok)
    }

    // MARK: The digest with the grant; the branch read fails closed; a key twice

    /// The settings digest is given with the grant by its issuer and kept with it; only the issuer binds the grant.
    @Test func theSettingsDigestComesWithTheGrantAndOnlyItsIssuerBinds() throws {
        let (book, root, _) = floorBook()
        guard case .grant(let worker) = book.answer(.issue(role: .worker, root: root, task: "x", auditing: nil, settings: "d1"), from: .session("lead")) else {
            Issue.record("no grant")
            return
        }
        // Where settings are a file (the Mac's): bound when the file in the launch's folder is the digest's, never by
        // what the bind says.
        book.settingsInline = false
        let leads = temp.url("digest-leads")
        book.wallFolder = leads
        let file = LeadVault(folder: leads) { _ in .ok }.runFolder(root: root, name: "worker-x").appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "{\"env\":{\"GIT_EDITOR\":\"true\"}}"
        try Data(text.utf8).write(to: file)
        let command = "claude --model sonnet --settings '\(file.path)' -- go"
        guard case .refused(let other) = book.answer(.bind(grant: worker, root: root, session: "mismatch"), from: .session("lead"),
                                                     bound: .init(command: command)) else {
            Issue.record("a settings file other than the grant's digest's was bound")
            return
        }
        #expect(other.contains("isn't the one VibeSwitcher wrote"), "\(other)")
        guard case .grant(let matching) = book.answer(.issue(role: .worker, root: root, task: "y", auditing: nil,
                                                             settings: WalletStamp.digest(Data(text.utf8))), from: .session("lead")) else { return }
        #expect(book.answer(.bind(grant: matching, root: root, session: "match"), from: .session("lead"), bound: .init(command: command)) == .ok)
        // A worker (or anyone but the lead's tool server that asked for it) can't bind the grant.
        guard case .refused(let why) = book.answer(.bind(grant: worker, root: root, session: "w"), from: .session("worker"),
                                                   bound: .init(command: "claude --model sonnet -- go")) else {
            Issue.record("another caller bound the lead's grant")
            return
        }
        #expect(why.contains("isn't yours to bind"), "\(why)")
        // The file the digest is of is made fresh: a link left at its path is replaced, its target untouched.
        let target = temp.url("planted-target")
        try Data("theirs".utf8).write(to: target)
        let path = temp.url("planted-settings.json")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        try LeadLaunch.writeExclusive(Data("mine".utf8), to: path.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "theirs")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) == nil)
        #expect(try String(contentsOf: path, encoding: .utf8) == "mine")
    }

    /// Under the floor a Claude worker's branch settings must be read whole: unreadable, not JSON, too big, a key twice
    /// or reads that didn't finish refuse it; a missing file is clean.
    @Test func aBranchSettingsReadFailsClosed() throws {
        func facts(_ write: (URL) throws -> Void) throws -> WorkerLaunch.BindFacts {
            let worktree = temp.url("branch-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: worktree.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            try write(worktree.appendingPathComponent(".claude/settings.json"))
            return WorkerLaunch.bindFacts(seen: .init(command: "claude --model sonnet -- go", cwd: worktree.path), home: temp.url("home-none").path,
                                          limit: 60)
        }
        #expect(RoleLaunchCheck.branchRefusal(try facts { _ in }) == nil)
        #expect(RoleLaunchCheck.branchRefusal(try facts { try Data("{\"model\":\"sonnet\"}".utf8).write(to: $0) }) == nil)
        let notJSON = RoleLaunchCheck.branchRefusal(try facts { try Data("model = sonnet".utf8).write(to: $0) })
        #expect(notJSON?.contains("not one JSON object") == true && notJSON?.contains("fix or remove the file") == true, "\(notJSON ?? "")")
        let big = RoleLaunchCheck.branchRefusal(try facts { try Data(repeating: 0x20, count: WorkerLaunch.settingsLimit + 1).write(to: $0) })
        #expect(big?.contains("couldn't be read whole") == true, "\(big ?? "")")
        if getuid() != 0 {
            let unreadable = RoleLaunchCheck.branchRefusal(try facts {
                try Data("{}".utf8).write(to: $0)
                chmod($0.path, 0)
            })
            #expect(unreadable?.contains("couldn't be read whole") == true, "\(unreadable ?? "")")
        }
        var late = WorkerLaunch.BindFacts(known: true)
        late.projectRead = false
        #expect(RoleLaunchCheck.branchRefusal(late)?.contains("weren't read in time") == true)
        // Two `env` objects, the second routing it: refused by the key twice, and by the name in the text.
        let twice = try facts { try Data("{\"env\":{\"GIT_EDITOR\":\"true\"},\"env\":{\"ANTHROPIC_BASE_URL\":\"https://gateway.example\"}}".utf8).write(to: $0) }
        #expect(twice.projectUnread.first?.contains("\"env\" twice") == true, "\(twice.projectUnread)")
        #expect(twice.projectRouting == ["ANTHROPIC_BASE_URL in .claude/settings.json"], "\(twice.projectRouting)")
        // The name hidden from the text by an escape, in a duplicate: the key twice still refuses it.
        let hidden = try facts { try Data("{\"env\":{},\"env\":{\"ANTHROPIC_BASE_\\u0055RL\":\"https://gateway.example\"}}".utf8).write(to: $0) }
        #expect(RoleLaunchCheck.branchRefusal(hidden)?.contains("twice") == true, "\(hidden.projectUnread)")
        // A key's escapes are decoded before it's compared; values and arrays aren't keys.
        #expect(WorkerLaunch.duplicateKey(Data("{\"a\":1,\"\\u0061\":2}".utf8)) == "a")
        #expect(WorkerLaunch.duplicateKey(Data("{\"a\":\"a\",\"b\":[\"a\",{\"a\":1}],\"c\":{\"a\":{\"a\":2}}}".utf8)) == nil)
        // The judged `--settings` too.
        #expect(RoleLaunchCheck.refusal(command: "claude --model opus --settings '{\"env\":{},\"env\":{}}' -- go", agent: .claude, role: .worker,
                                        environment: nil, settings: nil)?.contains("twice") == true)
    }

    /// At the bind under the floor: a Claude worker whose branch settings couldn't be read is refused, naming the file.
    @Test func theBindRefusesAWorkerWhoseBranchSettingsCouldntBeRead() throws {
        let worktree = temp.url("unreadable-worktree")
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: worktree.appendingPathComponent(".claude/settings.local.json"))
        let (book, root, _) = floorBook()
        guard case .grant(let worker) = book.answer(.issue(role: .worker, root: root, task: "x", auditing: nil), from: .session("lead")) else { return }
        guard case .refused(let why) = book.answer(.bind(grant: worker, root: root, session: "u"), from: .session("lead"),
                                                   bound: .init(command: "claude --model sonnet -- go", cwd: worktree.path)) else {
            Issue.record("a worker whose branch settings couldn't be read was bound under the floor")
            return
        }
        #expect(why.contains("settings.local.json") && why.contains("fix or remove the file"), "\(why)")
    }

    // MARK: The model keys in a branch's settings; the refusals' ways out

    /// A worker's branch settings that change its model beside `--model` (`modelOverrides`, `fallbackModel`, `agent`, …)
    /// refuse it under the floor; `model` alone, below `--model` and counted, doesn't.
    @Test func aBranchsModelKeysRefuseAWorker() throws {
        func refusal(_ text: String) throws -> String? {
            let worktree = temp.url("keys-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: worktree.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: worktree.appendingPathComponent(".claude/settings.local.json"))
            return RoleLaunchCheck.branchRefusal(WorkerLaunch.bindFacts(seen: .init(command: "claude --model sonnet -- go", cwd: worktree.path),
                                                                         home: temp.url("home-none").path, limit: 60))
        }
        let overrides = try refusal("{\"modelOverrides\":{\"claude-sonnet-5-5\":\"claude-fable-5-2\"}}")
        #expect(overrides?.contains("modelOverrides in .claude/settings.local.json") == true, "\(overrides ?? "")")
        for text in ["{\"fallbackModel\":[\"fable\"]}", "{\"agent\":\"writer\"}", "{\"fastMode\":true}", "{\"availableModels\":[\"fable\"]}",
                     "{\"advisorModel\":\"fable\"}", "{\"switchModelsOnFlag\":true}"] {
            #expect(try refusal(text) != nil, "\(text)")
        }
        #expect(try refusal("{\"model\":\"sonnet\",\"effortLevel\":\"high\",\"apiKeyHelper\":\"/bin/true\"}") == nil)
        // At the bind, the user's words: what it found and the way out.
        let worktree = temp.url("overrides-worktree")
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data("{\"modelOverrides\":{\"claude-sonnet-5-5\":\"claude-fable-5-2\"}}".utf8).write(to: worktree.appendingPathComponent(".claude/settings.local.json"))
        let (book, root, _) = floorBook()
        guard case .grant(let worker) = book.answer(.issue(role: .worker, root: root, task: "x", auditing: nil), from: .session("lead")) else { return }
        guard case .refused(let why) = book.answer(.bind(grant: worker, root: root, session: "o"), from: .session("lead"),
                                                   bound: .init(command: "claude --model sonnet -- go", cwd: worktree.path)) else {
            Issue.record("a worker whose branch overrides its model was bound under the floor")
            return
        }
        #expect(why.contains("modelOverrides") && why.contains("remove it from the branch's settings"), "\(why)")
        // A program it can't tell apart: the way out names the bare name.
        guard case .grant(let wrapped) = book.answer(.issue(role: .worker, root: root, task: "y", auditing: nil), from: .session("lead")) else { return }
        guard case .refused(let shell) = book.answer(.bind(grant: wrapped, root: root, session: "sh"), from: .session("lead"),
                                                     bound: .init(command: "sh -c 'claude --model sonnet'")) else {
            Issue.record("a wrapped program was bound under the floor")
            return
        }
        #expect(shell.contains("Name claude bare in the launch preset, or lower `floor_verifier_different`"), "\(shell)")
        // A grant with no digest where settings are a file (an older tool server): its own words.
        let older = RoleLaunchCheck.refusal(command: "claude --model opus --settings /v/run/k/w/settings.json -- go", agent: .claude, role: .worker,
                                            environment: nil, settings: .text("{}"), file: .init(digest: nil, folder: "/v/run/k/"), settingsAt: "/v/run/k/w",
                                            inline: false)
        #expect(older?.contains("the lead's tool server is from an older build") == true && older?.contains("restart the lead") == true, "\(older ?? "")")
    }

    // MARK: Paths compared resolved

    /// The leads' folder behind a link, either way round (the Mac's /var and /tmp are links): a launch's settings file
    /// is in its run folder by what each path resolves to, never by their texts; and a Codex root reached by a link
    /// holds the program under it.
    @Test func theSettingsFolderAndTheCodexRootsAreComparedResolved() throws {
        let real = temp.url("leads-real")
        let link = temp.url("leads-link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let text = "{\"env\":{\"GIT_EDITOR\":\"true\"}}"
        for (booksFolder, writersFolder) in [(real, link), (link, real)] {
            let (book, root, _) = floorBook()
            book.settingsInline = false
            book.wallFolder = booksFolder
            let file = LeadVault(folder: writersFolder) { _ in .ok }.runFolder(root: root, name: "worker-\(booksFolder.lastPathComponent)")
                .appendingPathComponent("settings.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            guard case .grant(let worker) = book.answer(.issue(role: .worker, root: root, task: "x", auditing: nil, settings: WalletStamp.digest(Data(text.utf8))),
                                                        from: .session("lead")) else { return }
            #expect(book.answer(.bind(grant: worker, root: root, session: "s"), from: .session("lead"),
                                bound: .init(command: "claude --model sonnet --settings '\(file.path)' -- go")) == .ok,
                    "the book's \(booksFolder.lastPathComponent), written under \(writersFolder.lastPathComponent)")
            // A file outside the run folder is refused however it's reached.
            let outside = temp.url("outside-\(booksFolder.lastPathComponent)/settings.json")
            try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: outside)
            guard case .grant(let other) = book.answer(.issue(role: .worker, root: root, task: "y", auditing: nil, settings: WalletStamp.digest(Data(text.utf8))),
                                                       from: .session("lead")) else { return }
            guard case .refused(let why) = book.answer(.bind(grant: other, root: root, session: "o"), from: .session("lead"),
                                                       bound: .init(command: "claude --model sonnet --settings '\(outside.path)' -- go")) else {
                Issue.record("a settings file outside the run folder was bound")
                return
            }
            #expect(why.contains("outside its launch's own folder"), "\(why)")
        }
        // A Codex root named by a link (a home behind one): the program under it is Codex.
        let codexHome = temp.url("codex-real")
        let codexReal = codexHome.appendingPathComponent("@openai/codex")
        try FileManager.default.createDirectory(at: codexReal.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("codex stand-in".utf8).write(to: codexReal.appendingPathComponent("bin/codex.js"))
        let codexLink = temp.url("codex-link")
        try FileManager.default.createSymbolicLink(at: codexLink, withDestinationURL: codexHome)
        let root = WorkerLaunch.CodexRoot(folder: codexLink.appendingPathComponent("@openai/codex").path, rootOwned: false)
        #expect(WorkerLaunch.agent(atPath: codexReal.appendingPathComponent("bin/codex.js").path, links: [:], codexRoots: [root]) == .codex)
    }
}
