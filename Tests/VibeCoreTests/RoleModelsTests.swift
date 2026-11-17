import Foundation
import Testing
@testable import VibeCore

/// Each role gets the model that suits it (the user, 2026-11-12): the lead on Fable (lead_model), Opus with a Fable
/// advisor while it runs on Opus; workers on Opus, a hard task (advisor fable) consulting Fable at effort high; a
/// re-rolled task's next worker on Fable; sensitive and security audits on Fable where the floor allows; and while Fable
/// is held back, no `--advisor fable` and Opus in Fable's place. Fake sessions only, usage read by an injected clock.
extension LeadAdvanceTests {
    /// A role's command line as `LeadLaunch.prepare` makes it, in a scratch folder.
    func prepared(_ role: LeadLaunch.Role, base: String = "claude", task: String? = "t", run: LeadLaunch.Run) throws -> (command: String, files: LeadLaunch.Prepared) {
        let root = temp.url("prepare-\(role.rawValue)-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let launch = try LeadLaunch.prepare(role: role, root: root, task: task, base: base, prompt: "p", start: "go", server: "/App/vibeswitcher-mcp",
                                            name: "n", model: run.model, advisor: run.advisor, effort: run.effort,
                                            folder: temp.url("run-\(UUID().uuidString.prefix(6))"), cwd: root, temporary: temp.url("tmp"))
        return (launch.command, launch)
    }

    /// The command line `prepare` writes, with its files' paths: what each role's launch is pinned to.
    func expected(_ launch: LeadLaunch.Prepared, base: String = "claude", tail: String) -> String {
        let quote = RecentProjects.shellQuote
        return "\(base) --append-system-prompt-file \(quote(launch.promptFile)) --mcp-config \(quote(launch.mcpFile)) --settings \(quote(launch.settingsFile)) "
            + "--name 'n' \(tail)-- 'go'"
    }

    @Test func theLeadsAPlainTasksAndAHardTasksCommandLinesArePinned() throws {
        // The lead, by default: Fable, no advisor (lead_advisor counts only on Opus).
        let workflow = LeadWorkflow.parse("---\nmax_workers: 3\n---\n")
        #expect(workflow.leadModel == "fable" && workflow.leadAdvisor == "fable" && workflow.workerAdvisor == nil)
        let leadRun = LeadLaunch.leadRun(workflow, defaultModel: "opus", fableHeldBack: false)
        #expect(leadRun == LeadLaunch.Run(model: "fable"))
        let lead = try prepared(.lead, task: nil, run: leadRun)
        #expect(lead.command == expected(lead.files, tail: "--model 'fable' "), "\(lead.command)")
        // A lead set to Opus: Fable as its advisor.
        let onOpus = LeadWorkflow.parse("---\nlead_model: opus\n---\n")
        let opusRun = LeadLaunch.leadRun(onOpus, defaultModel: "opus", fableHeldBack: false)
        let opusLead = try prepared(.lead, task: nil, run: opusRun)
        #expect(opusLead.command == expected(opusLead.files, tail: "--model 'opus' --advisor 'fable' "), "\(opusLead.command)")
        // lead_advisor none: Opus alone.
        #expect(LeadLaunch.leadRun(LeadWorkflow.parse("---\nlead_model: opus\nlead_advisor: none\n---\n"), defaultModel: nil, fableHeldBack: false)
                == LeadLaunch.Run(model: "opus"))

        // A plain task: no model, advisor or effort on its line (the project's command's, as before).
        var plain = LeadTask(slug: "plain", title: "Plain", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        let plainRun = LeadLaunch.workerRun(plain, workflow: workflow, codex: false, defaultModel: "opus", fableHeldBack: false)
        #expect(plainRun == LeadLaunch.Run())
        let worker = try prepared(.worker, run: plainRun)
        #expect(worker.command == expected(worker.files, tail: ""), "\(worker.command)")
        // A task marked hard (advisor fable): Fable advises its Opus worker, at effort high.
        plain.advisor = "fable"
        let hardRun = LeadLaunch.workerRun(plain, workflow: workflow, codex: false, defaultModel: "opus", fableHeldBack: false)
        #expect(hardRun == LeadLaunch.Run(advisor: "fable", effort: "high"))
        let hard = try prepared(.worker, run: hardRun)
        #expect(hard.command == expected(hard.files, tail: "--advisor 'fable' --effort 'high' "), "\(hard.command)")
        // Its own effort wins over high.
        plain.effort = "xhigh"
        #expect(LeadLaunch.workerRun(plain, workflow: workflow, codex: false, defaultModel: "opus", fableHeldBack: false).effort == "xhigh")
        // The project's command's own --model, --advisor and --effort give way to the ones passed.
        let given = try prepared(.worker, base: "claude --advisor opus --effort=low --model sonnet", run: LeadLaunch.Run(model: "opus", advisor: "fable", effort: "high"))
        #expect(given.command == expected(given.files, tail: "--model 'opus' --advisor 'fable' --effort 'high' "), "\(given.command)")
        // With no advisor passed, the command's own --advisor goes too: the workflow keys and the task decide advisors,
        // so a command's `--advisor fable` can't reach a session Fable is held back from or one whose task says none.
        let none = try prepared(.worker, base: "claude --advisor fable", run: LeadLaunch.Run())
        #expect(none.command == expected(none.files, tail: ""), "\(none.command)")
        let lead2 = try prepared(.lead, base: "claude --advisor=fable --model fable", task: nil, run: LeadLaunch.Run(model: "opus"))
        #expect(lead2.command == expected(lead2.files, tail: "--model 'opus' "), "\(lead2.command)")
    }

    @Test func anAdvisorBelowItsMainModelIsDroppedAndWorkerAdvisorAppliesToTasksThatSetNone() {
        // Claude Code refuses an advisor ranked below the main model (an interactive session exits at launch).
        #expect(LeadLaunch.advisor("opus", main: "fable") == nil)
        #expect(LeadLaunch.advisor("fable", main: "fable") == nil)
        #expect(LeadLaunch.advisor("fable", main: "opus") == "fable")
        #expect(LeadLaunch.advisor("opus", main: "claude-opus-5-5") == "opus")
        #expect(LeadLaunch.advisor("opus", main: "sonnet") == "opus")
        #expect(LeadLaunch.advisor("none", main: "opus") == nil)
        // The main not known: only Fable, which ranks above any.
        #expect(LeadLaunch.advisor("fable", main: nil) == "fable" && LeadLaunch.advisor("opus", main: nil) == nil)
        // worker_advisor for a task that names none; none on the task turns it off.
        let workflow = LeadWorkflow.parse("---\nworker_advisor: opus\n---\n")
        var task = LeadTask(slug: "t", title: "T", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        #expect(LeadLaunch.workerRun(task, workflow: workflow, codex: false, defaultModel: "opus", fableHeldBack: false).advisor == "opus")
        task.advisor = "none"
        #expect(LeadLaunch.workerRun(task, workflow: workflow, codex: false, defaultModel: "opus", fableHeldBack: false).advisor == nil)
        #expect(!task.hard)
        // A Codex worker never gets one; its effort goes to Codex.
        task.advisor = "fable"
        #expect(LeadLaunch.workerRun(task, workflow: workflow, codex: true, defaultModel: "opus", fableHeldBack: false) == LeadLaunch.Run(effort: "high"))
    }

    @Test func codexLaunchLinesWithAndWithoutEffortArePinned() throws {
        let root = temp.url("codex-root").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        func line(_ effort: String?, model: String? = nil) throws -> String {
            try LeadLaunch.prepareCodex(root: root, task: "t", base: "codex", prompt: "p", start: "go", server: "/App/vibeswitcher-mcp", name: "n",
                                        model: model, effort: effort, folder: temp.url("codex-run-\(UUID().uuidString.prefix(6))"), cwd: root,
                                        temporary: temp.url("tmp")).command
        }
        let without = try line(nil)
        #expect(!without.contains("model_reasoning_effort") && without.hasSuffix("default_tools_approval_mode=\"approve\"' -c 'mcp_servers.vibeswitcher.env_vars=[\"VIBESWITCHER_HOME\", \"CFFIXED_USER_HOME\", \"HOME\", \"PATH\", \"TMPDIR\"]' -- 'go'"),
                "\(without)")
        let with = try line("high")
        #expect(with.hasSuffix("env_vars=[\"VIBESWITCHER_HOME\", \"CFFIXED_USER_HOME\", \"HOME\", \"PATH\", \"TMPDIR\"]' -c 'model_reasoning_effort=\"high\"' -- 'go'"), "\(with)")
        #expect(with.components(separatedBy: "model_reasoning_effort").count == 2)
        // A model the task names goes after it; none is invented.
        let named = try line("xhigh", model: "gpt-6.1-sol")
        #expect(named.hasSuffix(" -c 'model_reasoning_effort=\"xhigh\"' --model 'gpt-6.1-sol' -- 'go'"), "\(named)")
        // Each level as each CLI takes it: all four are both's; one a CLI lacks goes to its nearest.
        for level in LeadLaunch.effortLevels { #expect(LeadLaunch.claudeEffort(level) == level && LeadLaunch.codexEffort(level) == level) }
        #expect(LeadLaunch.claudeEffort("minimal") == "low" && LeadLaunch.claudeEffort("none") == "low")
        // Codex's defaults, for showing: config.toml's top-level keys only.
        let home = temp.url("codex-defaults").path
        try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        try "model = \"gpt-6.1-sol\"\nmodel_reasoning_effort = \"medium\" # default\n\n[profiles.x]\nmodel = \"other\"\n"
            .write(toFile: home + "/.codex/config.toml", atomically: true, encoding: .utf8)
        let defaults = LeadLaunch.codexDefaults(home: home, codexHome: nil)
        #expect(defaults.model == "gpt-6.1-sol" && defaults.effort == "medium")
    }

    @Test func hardTasksStartWithAFableAdvisorAtEffortHighAndStatusShowsEachSessionsRun() throws {
        let (root, runtime, lead) = try team(test: nil, ["auto_advance": false, "max_workers": 5])
        runtime.claude = "claude --model opus"
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"]])
        let added = lead.call("add_task", ["title": "Hard", "goal": "g", "acceptance": ["a"], "advisor": "fable"])
        #expect(!added.isError && added.text.contains("marked hard (advisor fable)"), "\(added.text)")
        #expect(lead.call("add_task", ["title": "Bad", "goal": "g", "acceptance": ["a"], "advisor": "sonnet"]).isError)
        #expect(lead.call("add_task", ["title": "Bad", "goal": "g", "acceptance": ["a"], "effort": "max"]).isError)
        #expect(!lead.call("start_worker", ["task": "plain"]).isError)
        let plain = try #require(command("plain", runtime))
        #expect(!plain.contains("--advisor") && !plain.contains("--effort") && !plain.contains("--model 'opus'"), "\(plain)")
        let started = lead.call("start_worker", ["task": "hard"])
        #expect(!started.isError && started.text.contains("Claude on opus (its command's default), effort high, advisor fable"), "\(started.text)")
        let hard = try #require(command("hard", runtime))
        #expect(hard.contains("--advisor 'fable' --effort 'high'"), "\(hard)")
        let worker = try #require(task("hard", root)?.worker)
        #expect(task("hard", root)?.launchedAdvisors?[worker] == "fable" && task("hard", root)?.launchedEfforts?[worker] == "high")
        // update_task changes them from the next worker; an empty value clears.
        let updated = lead.call("update_task", ["task": "plain", "effort": "low", "advisor": "opus"])
        #expect(!updated.isError && updated.text.contains("effort low") && updated.text.contains("advisor opus"), "\(updated.text)")
        #expect(task("plain", root)?.effort == "low" && task("plain", root)?.advisor == "opus")
        #expect(!lead.call("update_task", ["task": "plain", "advisor": ""]).isError && task("plain", root)?.advisor == nil)
        // status: each running session's agent, model, effort and advisor, and the lead's.
        let status = lead.call("status", [:]).text
        #expect(status.contains("- hard worker: Claude on opus, effort high, advisor fable"), "\(status)")
        #expect(status.contains("- plain worker: Claude on opus\n"), "\(status)")
        #expect(status.contains("- lead (by lead_model now): Claude on fable"), "\(status)")
    }

    @Test func aRerolledTaskWithNoModelOfItsOwnStartsItsNextWorkerOnFableAnExplicitModelWins() throws {
        let (root, runtime, lead) = try team(test: nil, ["auto_advance": false, "max_workers": 5])
        runtime.claude = "claude --model opus"
        _ = lead.call("add_task", ["title": "Again", "goal": "g", "acceptance": ["a"]])
        _ = lead.call("add_task", ["title": "Pinned", "goal": "g", "acceptance": ["a"], "model": "sonnet"])
        for slug in ["again", "pinned"] {
            #expect(!lead.call("start_worker", ["task": slug]).isError)
            #expect(try #require(command(slug, runtime)).contains("--model 'fable'") == false)
            try commit("\(slug).txt", "x\n", in: Worktrees.path(root: root, slug: slug))
            let rerolled = lead.call("update_task", ["task": slug, "reroll": true])
            #expect(!rerolled.isError && rerolled.text.contains("Worker started on \(slug)"), "\(rerolled.text)")
        }
        let again = try #require(command("again", runtime))
        #expect(again.contains("--model 'fable'"), "\(again)")
        #expect(task("again", root)?.model == nil && task("again", root)?.intendedModel == "fable")
        let pinned = try #require(command("pinned", runtime))
        #expect(pinned.contains("--model 'sonnet'") && !pinned.contains("fable"), "\(pinned)")
    }

    @Test func aSensitiveOrSecurityAuditRunsOnFableOthersOnVerifierModelAndTheFloorWins() throws {
        let (root, runtime, lead) = try team(test: nil, ["auto_advance": false, "max_workers": 5, "verifier_model": "opus"])
        runtime.claude = "claude --model opus"
        _ = lead.call("add_task", ["title": "Plain", "goal": "g", "acceptance": ["a"], "review": "audit"])
        _ = lead.call("add_task", ["title": "Touchy", "goal": "g", "acceptance": ["a"], "review": "audit"])
        for slug in ["plain", "touchy"] { #expect(!lead.call("start_worker", ["task": slug]).isError) }
        try commit("plain.txt", "x\n", in: Worktrees.path(root: root, slug: "plain"))
        let touchy = Worktrees.path(root: root, slug: "touchy")
        try FileManager.default.createDirectory(atPath: touchy + "/.github", withIntermediateDirectories: true)
        try commit(".github/ci.yml", "on: push\n", in: touchy)
        for slug in ["plain", "touchy"] {
            let audited = lead.call("audit", ["task": slug])
            #expect(!audited.isError, "\(audited.text)")
        }
        let plainVerifier = try #require(runtime.spawned.last { $0.command.contains("--name 'verify-plain'") }?.command)
        #expect(plainVerifier.contains("--model 'opus'"), "\(plainVerifier)")
        let touchyVerifier = try #require(runtime.spawned.last { $0.command.contains("--name 'verify-touchy'") }?.command)
        #expect(touchyVerifier.contains("--model 'fable'") && !touchyVerifier.contains("--advisor"), "\(touchyVerifier)")
        // The floor's checks as before: one that keeps audits off the workers' model, and workers on Fable.
        var workflow = LeadWorkflow()
        #expect(workflow.auditModel(workerModel: "opus", security: true) == "fable")
        workflow.verifierModel = "sonnet"
        #expect(workflow.auditModel(workerModel: "opus", security: true) == "fable" && workflow.auditModel(workerModel: "opus") == "sonnet")
        workflow.verifierModel = nil
        workflow.floor = LeadReviewFloor()
        #expect(workflow.auditModel(workerModel: "fable", security: true) == "opus")
        #expect(workflow.auditModel(workerModel: "opus", taskModel: "fable", security: true) == "sonnet")
        #expect(workflow.auditModel(workerModel: "opus", launchedModel: "fable", security: true) == "sonnet")
        #expect(workflow.auditModel(workerModel: "opus", security: true) == "fable")
        // Held back: not Fable after all.
        #expect(workflow.auditModel(workerModel: "opus", heldBack: "fable", security: true) == "sonnet")
        workflow.floor = nil
        #expect(workflow.auditModel(workerModel: "opus", heldBack: "fable", security: true) == "opus")
    }

    /// auto_advance checks usage on the model the audit will run on: a sensitive branch's is Fable whatever
    /// verifier_model says, so near Fable's limit its audit waits for the reset (a look again armed) instead of being
    /// tried on Opus's reading and refused on Fable's.
    @Test func autoAdvanceHoldsASensitiveAuditNearFablesLimitThoughVerifierModelIsOpus() async throws {
        let (root, runtime, lead) = try team(test: nil, ["verifier_model": "opus"])
        runtime.claude = "claude --model opus"
        let now = AccountUsageTests.now, resets = AccountUsageTests.tomorrow
        lead.usageClock = { now }
        let armed = Armed()
        lead.usageWake = { date, body in armed.add(date, body) }
        // Fable at 91 % of its own limit, not refused: Fable isn't held back, so the audit stays on Fable.
        usageStore.record([AccountUsage.Limit(name: "seven_day_fable", model: "fable", usedPercent: 91, resetsAt: resets,
                                              at: now.timeIntervalSince1970)], now: now)
        #expect(lead.usageHold(model: "fable", sessions: nil) != nil && lead.usageHold(model: "opus", sessions: nil) == nil)
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Touchy", "goal": "g", "acceptance": ["a"], "review": "audit"])
        #expect(await advancing.until { task("touchy", root)?.status == .running })
        let worktree = Worktrees.path(root: root, slug: "touchy")
        try FileManager.default.createDirectory(atPath: worktree + "/.github", withIntermediateDirectories: true)
        try commit(".github/ci.yml", "on: push\n", in: worktree)
        let report = try seat("worker-touchy", runtime).call("report", doneReport("added ci"))
        #expect(!report.isError, "\(report.text)")
        #expect(await advancing.until { armed.taken.contains { $0.0.timeIntervalSince1970 == resets + 1 } }, "\(reports(runtime))")
        await advancing.settle()
        #expect(!runtime.spawned.contains { $0.command.contains("--name 'verify-touchy'") })
        // Held before it was tried, not refused by audit itself (which arms no look again for the reset).
        #expect(!reports(runtime).contains { $0.contains("Didn't audit") || $0.contains("Not audited") }, "\(reports(runtime))")
        #expect(lead.auditModel(lead.workflow, task: lead.store.load().task("touchy"), head: head("agent/touchy", root)) == "fable")
    }

    @Test func whileFableIsHeldBackNoSessionStartsWithAFableAdvisorAndFableSessionsStartOnOpus() throws {
        let (root, runtime, lead) = try fableTeam()
        // The project's command names its own Fable advisor: it doesn't get through either.
        runtime.claude = "claude --model opus --advisor fable"
        _ = lead.call("add_task", ["title": "Hard", "goal": "g", "acceptance": ["a"], "advisor": "fable"])
        _ = lead.call("add_task", ["title": "Again", "goal": "g", "acceptance": ["a"]])
        #expect(!lead.call("start_worker", ["task": "again"]).isError)
        try commit("again.txt", "x\n", in: Worktrees.path(root: root, slug: "again"))
        recordFableRefusal()
        let started = lead.call("start_worker", ["task": "hard"])
        #expect(!started.isError && started.text.contains("in Fable's place: Fable held back until"), "\(started.text)")
        let hard = try #require(command("hard", runtime))
        #expect(!hard.contains("--advisor") && hard.contains("--effort 'high'"), "\(hard)")
        // A re-roll meant for Fable starts on Opus.
        let rerolled = lead.call("update_task", ["task": "again", "reroll": true])
        #expect(!rerolled.isError, "\(rerolled.text)")
        let again = try #require(command("again", runtime))
        #expect(again.contains("--model 'opus'") && !again.contains("fable"), "\(again)")
        // No session the team started since carries --advisor fable.
        #expect(!runtime.spawned.contains { $0.command.contains("--advisor") }, "\(runtime.spawned.map(\.command))")
        // The lead: Opus, and no Fable advisor whatever lead_advisor says.
        let workflow = LeadWorkflow.parse("---\nlead_model: fable\nlead_advisor: fable\n---\n")
        #expect(LeadLaunch.leadRun(workflow, defaultModel: "opus", fableHeldBack: true) == LeadLaunch.Run(model: "opus"))
        let opus = LeadWorkflow.parse("---\nlead_model: opus\n---\n")
        #expect(LeadLaunch.leadRun(opus, defaultModel: "opus", fableHeldBack: true) == LeadLaunch.Run(model: "opus"))
        // A lead whose command runs Fable by default and lead_model cleared to it: Opus, passed explicitly.
        #expect(LeadLaunch.run(model: nil, advisor: "fable", effort: nil, defaultModel: "fable", fableHeldBack: true) == LeadLaunch.Run(model: "opus"))
        // status shows the lead on Opus while it's held back.
        #expect(lead.call("status", [:]).text.contains("lead (by lead_model now): Claude on opus"))
    }

    @Test func aLeadStoppedAtFablesLimitHoldsFableBackSoTheNextLeadStartsOnOpus() throws {
        // The lead's launch carries its model; its tool server notes it on the board as it introduces the lead.
        let launch = try prepared(.lead, task: nil, run: LeadLaunch.Run(model: "fable"))
        #expect(launch.files.environment[LeadLaunch.leadModelVariable] == "fable")
        #expect(try prepared(.worker, run: LeadLaunch.Run(model: "fable")).files.environment[LeadLaunch.leadModelVariable] == nil)
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.power = { nil }
        lead.usageClock = { Self.fableNow }
        lead.leadLaunchedModel = { "fable" }
        // As its tool server does when it introduces the lead (at its start, before a test could inject the model).
        lead.noteLeadModel()
        let board = BoardStore(root: root).load()
        #expect(board.leadSession == runtime.me.session && board.leadModel == "fable")
        #expect(lead.fableFallback(sessions: try runtime.sessions()) == nil)
        // The lead's own turn ends on Fable's refusal: kept as Fable held back, though no task names its session.
        runtime.spawned.append((try #require(runtime.me.session), root, "claude", "Lead", true))
        runtime.usageLimits[try #require(runtime.me.session)] = Self.outOfCredits
        let held = try #require(lead.fableFallback(sessions: try runtime.sessions()))
        #expect(LeadLaunch.leadRun(lead.workflow, defaultModel: "opus", fableHeldBack: held.fableHeldBack(now: Self.fableNow) != nil) == LeadLaunch.Run(model: "opus"))
        #expect(lead.call("status", [:]).text.contains("lead (by lead_model now): Claude on opus"))
    }

    @Test func workflowKeysForModelsAndAdvisorsAreReadAndConfigured() throws {
        let (_, _, lead) = try team(test: nil, ["auto_advance": false])
        #expect(lead.workflow.leadModel == "fable" && lead.workflow.leadAdvisor == "fable" && lead.workflow.workerAdvisor == nil)
        let set = lead.call("configure", ["lead_model": "opus", "lead_advisor": "none", "worker_advisor": "fable"])
        #expect(!set.isError, "\(set.text)")
        #expect(lead.workflow.leadModel == "opus" && lead.workflow.leadAdvisor == nil && lead.workflow.workerAdvisor == "fable")
        #expect(lead.call("configure", ["worker_advisor": "haiku"]).isError)
        #expect(lead.call("configure", ["lead_model": "two words"]).isError)
        let cleared = lead.call("configure", ["lead_model": "", "lead_advisor": "", "worker_advisor": ""])
        #expect(!cleared.isError, "\(cleared.text)")
        #expect(lead.workflow.leadModel == "fable" && lead.workflow.leadAdvisor == "fable" && lead.workflow.workerAdvisor == nil)
        // The template says the defaults.
        let template = LeadWorkflow.parse(LeadWorkflow.template)
        #expect(template.leadModel == "fable" && template.leadAdvisor == "fable" && template.workerAdvisor == nil)
        // The lead's prompt says when to mark a task hard.
        let prompt = LeadPrompts.lead(project: "p", root: "/r", workflow: LeadWorkflow(), policy: "")
        #expect(prompt.contains("advisor: fable when judgment decides it (concurrency, root-cause debugging, many parts at once, architecture choices)"))
    }
}

extension UsageRoutingTests {
    @Test func aHardAutoTaskPrefersClaudeUnlessClaudesUsageHoldsItBack() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try routingLead(root, runtime)
        // Claude ahead of pace, Codex with room: a routine auto task goes to Codex, a hard one stays on Claude.
        claudeWeekly(64, gone: 0.52)
        try codexWeekly(40)
        _ = lead.call("add_task", ["title": "Routine", "goal": "g", "acceptance": ["a"], "agent": "auto"])
        _ = lead.call("add_task", ["title": "Hard", "goal": "g", "acceptance": ["a"], "agent": "auto", "advisor": "fable"])
        #expect(lead.workerRoute(for: try #require(task("routine", root)), sessions: nil).agent == .codex)
        let hard = lead.call("start_worker", ["task": "hard"])
        #expect(!hard.isError && hard.text.contains("so it went to Claude: a hard task (advisor fable)"), "\(hard.text)")
        let spawn = try #require(runtime.spawned.last)
        #expect(runtime.agents[spawn.id] == "claude" && spawn.command.contains("--advisor 'fable' --effort 'high'"), "\(spawn.command.prefix(400))")
        // Claude's usage at the hold: routed as any other, to Codex, with its effort as Codex's.
        claudeWeekly(92, gone: 0.6)
        _ = lead.call("add_task", ["title": "Held", "goal": "g", "acceptance": ["a"], "agent": "auto", "advisor": "fable"])
        let held = lead.call("start_worker", ["task": "held"])
        #expect(!held.isError && held.text.contains("so it went to Codex"), "\(held.text)")
        let codex = try #require(runtime.spawned.last)
        #expect(runtime.agents[codex.id] == "codex" && codex.command.contains("model_reasoning_effort=\"high\"") && !codex.command.contains("--advisor"))
    }
}
