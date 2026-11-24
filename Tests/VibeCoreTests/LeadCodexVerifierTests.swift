import Foundation
import Testing
@testable import VibeCore

struct LeadCodexVerifierTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }
    static let now = AccountUsageTests.now

    func team(sensitive: Bool = false, worker: String = "claude", security: Bool = false) throws -> (String, FakeRuntime, LeadToolset) {
        let root = temp.url("repo").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { #expect(Git.run(args, in: root).ok) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        #expect(Git.run(["add", "a.txt"], in: root).ok)
        #expect(Git.run(["commit", "-qm", "first"], in: root).ok)
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.codexWorkers = true
        lead.power = { nil }
        try codexRoom(lead, used: 20)
        lead.usageClock = { Self.now }
        #expect(!lead.call("configure", ["merge_policy": "auto", "small_task_min": 0, "test_command": "echo AUDIT_HOST_LOG", "verifier_model": "fable"]).isError)
        #expect(!lead.call("add_task", ["title": "Fix", "goal": "add b", "acceptance": ["b exists"], "review": "audit", "agent": worker]).isError)
        #expect(!lead.call("start_worker", ["task": "fix"]).isError)
        let path = Worktrees.path(root: root, slug: "fix")
        let file = sensitive ? ".github/workflows/ci.yml" : security ? "runner.swift" : "b.txt"
        try FileManager.default.createDirectory(atPath: (path + "/" + file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try (security ? "let process = Process()\n" : "bee\n").write(toFile: path + "/" + file, atomically: true, encoding: .utf8)
        #expect(Git.run(["add", file], in: path).ok)
        #expect(Git.run(["commit", "-qm", "add b"], in: path).ok)
        #expect(!(try seat("worker-fix", runtime)).call("report", doneReport("added b")).isError)
        return (root, runtime, lead)
    }

    func codexRoom(_ lead: LeadToolset, used: Double) throws {
        let home = temp.url("codex-home")
        let folder = home.appendingPathComponent("sessions/2026/11/19")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let window = UsageRoutingTests.window(used, resets: Self.now.timeIntervalSince1970 + 3600)
        try UsageRoutingTests.event(primary: window).write(to: folder.appendingPathComponent("rollout-test.jsonl"), atomically: true, encoding: .utf8)
        lead.codexUsage = CodexUsageReader(home: home, ttl: 0)
    }

    func hold(_ lead: LeadToolset, model: String? = nil) {
        usageStore.record([AccountUsage.Limit(name: "seven_day", model: model, usedPercent: 100,
                                              resetsAt: Self.now.timeIntervalSince1970 + 3600, at: Self.now.timeIntervalSince1970)], now: Self.now)
    }

    @Test(arguments: [false, true], [false, true]) func aHeldClaudeVerifierStartsOnCodex(sensitive: Bool, modelOnly: Bool) throws {
        let (root, runtime, lead) = try team(sensitive: sensitive)
        if modelOnly {
            for model in ["fable", "opus", "sonnet"] { hold(lead, model: model) }
        } else { hold(lead) }
        let audit = lead.call("audit", ["task": "fix"])
        #expect(!audit.isError, "\(audit.text)")
        #expect(!audit.text.contains("waiting on the account's usage limit"))
        let verifier = try #require(BoardStore(root: root).load().task("fix")?.verifier)
        #expect(runtime.agents[verifier] == "codex")
        #expect(runtime.spawned.last?.command.hasPrefix("codex ") == true)
        #expect(vault.current(.verifier, root: root, task: "fix")?.session == verifier)
        #expect(runtime.environments[verifier]?[SessionNote.roleVariable] == "verifier")
    }

    /// Inspect the persisted optional fields so these regression tests also compile with the fix reverted.
    func fields<T: Encodable>(_ value: T?) -> [String: Any] {
        guard let value, let data = try? JSONEncoder().encode(value),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return fields
    }

    func followup(_ root: String) -> [String: Any] {
        fields(BoardStore(root: root).load().task("fix"))["claudeReaudit"] as? [String: Any] ?? [:]
    }

    func verifier(_ root: String, _ runtime: FakeRuntime, session given: String? = nil) throws -> LeadToolset {
        let session = try #require(given ?? vault.current(.verifier, root: root, task: "fix")?.session)
        let runtime = FakeSeat(runtime, agent: LeadAgent(pid: 6010, tty: "ttys081", session: session))
        return LeadToolset(root: root, runtime: runtime, vault: vault(for: runtime), expected: .verifier, expectedTask: "fix")
    }

    @Test func offWaitsForClaudeAndRejectsAnUnknownSetting() throws {
        let (root, runtime, lead) = try team()
        #expect(!lead.call("configure", ["codex_verifier": "off"]).isError)
        #expect(lead.workflow.settings["codex_verifier"] == "off")
        #expect(lead.call("configure", ["codex_verifier": "always"]).isError)
        hold(lead)
        let audit = lead.call("audit", ["task": "fix"])
        #expect(audit.isError && audit.text.contains("usage is near a limit"), "\(audit.text)")
        #expect(BoardStore(root: root).load().task("fix")?.verifier == nil)
        #expect(runtime.spawned.count == 1)
        #expect(LeadWorkflow.template.contains("codex_verifier: fallback"))
        #expect(!lead.call("configure", ["codex_verifier": ""]).isError)
        #expect(!lead.call("configure", [:]).text.contains("- codex_verifier: off"))
    }

    @Test func availableClaudeStaysOnItsVerifierModel() throws {
        let (root, runtime, lead) = try team(sensitive: true)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let session = try #require(vault.current(.verifier, root: root, task: "fix")?.session)
        #expect(runtime.agents[session] == "claude")
        #expect(LeadWorkflow.claudeModel(command: runtime.spawned.last?.command ?? "") == "fable")
        #expect(fields(vault.current(.verifier, root: root, task: "fix"))["agent"] == nil)
    }

    @Test(arguments: [false, true], [false, true]) func anAlreadyLimitedClaudeVerifierIsReplacedAtTheNextAudit(automatic: Bool, allClaude: Bool) async throws {
        let (root, runtime, lead) = try team(sensitive: true)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let first = try #require(vault.current(.verifier, root: root, task: "fix")?.session)
        let oldSeat = try verifier(root, runtime)
        if allClaude { hold(lead) }
        runtime.usageLimits[first] = UsageLimit(said: "You've hit your Fable limit", resetsAt: Self.now.timeIntervalSince1970 + 3600,
                                               at: Self.now.timeIntervalSince1970, kind: "seven_day_overage_included", apiError: "model_requires_usage_credits")
        if automatic {
            // Even a Claude retry already spent at quota must get the Codex fallback, not the retry cap.
            try BoardStore(root: root).update { board in
                let index = try #require(board.taskIndex("fix"))
                board.tasks[index].verifierRetry = LeadVerifierRetry(commit: try #require(vault.current(.verifier, root: root, task: "fix")?.auditing),
                                                                     first: "earlier verifier ended", verifiers: [first])
            }
            let advancing = LeadAdvanceTests.Advancing(lead)
            defer { advancing.stop() }
            #expect(await advancing.until { BoardStore(root: root).load().task("fix")?.verifier != first })
            advancing.stop()
        } else {
            let restarted = lead.call("audit", ["task": "fix"])
            #expect(!restarted.isError, "\(restarted.text)")
        }
        let session = try #require(vault.current(.verifier, root: root, task: "fix")?.session)
        #expect(session != first && runtime.agents[session] == (allClaude ? "codex" : "claude") && runtime.killed.contains(first))
        if !allClaude { #expect(LeadWorkflow.claudeModel(command: runtime.spawned.last?.command ?? "") == "opus") }
        #expect(oldSeat.call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "stale"]).isError)
    }

    @Test(arguments: [false, true], ["claude", "codex"])
    func codexReadsHostLogsAndItsVerdictMerges(sensitive: Bool, worker: String) throws {
        let (root, runtime, lead) = try team(sensitive: sensitive, worker: worker)
        hold(lead)
        let audit = lead.call("audit", ["task": "fix"])
        #expect(!audit.isError, "\(audit.text)")
        let folder = vault.runFolder(root: root, name: "verify-fix")
        let prompt = try String(contentsOf: folder.appendingPathComponent("prompt.md"), encoding: .utf8)
        #expect(prompt.contains("Do not run host tests") && prompt.contains("read every log before judging"))
        #expect(!prompt.contains("Check: run every acceptance check") && !prompt.contains("Reproduce at the contract's load"))
        let config = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("codex-config.json"))) as? [String: Any])
        let server = try #require(config["mcpServer"] as? [String: Any])
        let args = try #require(server["args"] as? [String])
        #expect(args.contains("verifier") && !args.contains("worker"))
        let head = try #require(vault.current(.verifier, root: root, task: "fix")?.auditing)
        let logs = URL(fileURLWithPath: root + "/.vibeswitcher/audit/fix/" + head.prefix(12) + "/test.log")
        #expect(prompt.contains(logs.path))
        #expect(try String(contentsOf: logs, encoding: .utf8).contains("AUDIT_HOST_LOG"))
        let submitted = try verifier(root, runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "logs and code checked", "tests": "passed"])
        #expect(!submitted.isError, "\(submitted.text)")
        #expect(fields(vault.verdict(root: root, task: "fix"))["agent"] as? String == "codex")
        #expect(fields(vault.audits(root: root, task: "fix"))["agent"] as? String == "codex")
        #expect(fields(BoardStore(root: root).load().task("fix")?.evidence)["agent"] as? String == "codex")
        for tool in ["status", "board"] {
            #expect(lead.call(tool, ["task": "fix"]).text.contains("audited by Codex"))
        }
        let merged = lead.call("merge", ["task": "fix"])
        #expect(!merged.isError, "\(merged.text)")
        let task = try #require(BoardStore(root: root).load().task("fix"))
        #expect(task.status == .done && fields(task.merged)["agent"] as? String == "codex")
        // A sensitive merge, or Codex's own work, gets the post-merge Claude re-audit; a Claude-worked one doesn't.
        #expect((!followup(root).isEmpty) == (sensitive || worker == "codex"))
        #expect(lead.call("status", [:]).text.contains("audited by Codex"))
    }

    /// From audits-run-on-codex's blind check: a Codex-worked task touching no sensitive_paths merged on a Codex verdict
    /// with no later Claude re-audit, so Codex had the only say on its own work. It gets the same obligation, started
    /// once the injected limit clears; a security-flagged one keeps its security checklist.
    @Test(arguments: [false, true]) func codexWorkedCodexMergesGetClaudeAfterReset(security: Bool) async throws {
        let (root, runtime, lead) = try team(worker: "codex", security: security)
        #expect(BoardStore(root: root).load().task("fix")?.workerAgent == .codex)
        #expect(!lead.call("configure", ["auto_advance": false]).isError)
        hold(lead)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let audited = try #require(vault.current(.verifier, root: root, task: "fix")?.session)
        #expect(runtime.agents[audited] == "codex")
        #expect(!(try verifier(root, runtime)).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "Codex checked"]).isError)
        #expect(!lead.call("merge", ["task": "fix"]).isError)
        let merged = try #require(BoardStore(root: root).load().task("fix")?.merged)
        #expect(fields(merged)["agent"] as? String == "codex")
        #expect(!followup(root).isEmpty, "A Codex-worked merge on a Codex verdict records the Claude re-audit")
        #expect(followup(root)["session"] == nil)
        #expect(lead.call("cleanup", ["task": "fix"]).isError)
        let status = lead.call("status", [:]).text
        #expect(status.contains("Claude re-audit pending") && status.contains("Codex worked it"), "\(status)")
        let armed = LeadAdvanceTests.Armed()
        lead.usageWake = { date, work in armed.add(date, work) }
        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        #expect(await advancing.until { !armed.taken.isEmpty })
        #expect(followup(root)["session"] == nil, "Nothing starts while Claude is held")
        clearClaude(Self.now.timeIntervalSince1970 + 1)
        armed.taken.first?.1()
        #expect(await advancing.until { followup(root)["session"] != nil })
        advancing.stop()
        let session = try #require(followup(root)["session"] as? String)
        #expect(runtime.agents[session] == "claude")
        // A Claude launch's prompt as its command gives it: its file on the Mac, its text on Linux (inlined, the file
        // removed: the security architecture document's inline launch settings).
        let prompt = try LaunchArguments.prompt(of: "verify-fix", runtime)
        #expect(prompt.contains("Review the whole change against the pinned baseline") && prompt.contains("Codex worked"))
        #expect(prompt.contains("## Security checklist") == security)
        #expect(!(try verifier(root, runtime)).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "Claude checked"]).isError)
        #expect(followup(root)["passed"] as? Bool == true)
        #expect(!lead.call("cleanup", ["task": "fix"]).isError)
    }

    @Test(arguments: [false, true]) func autoAdvanceStartsCodexAuditsAtTheLimit(sensitive: Bool) async throws {
        let (root, runtime, lead) = try team(sensitive: sensitive)
        hold(lead)
        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        #expect(await advancing.until { BoardStore(root: root).load().task("fix")?.verifier != nil })
        advancing.stop()
        let session = try #require(vault.current(.verifier, root: root, task: "fix")?.session)
        #expect(runtime.agents[session] == "codex")
    }

    @Test func codexImportantFindingsKeepTheSameMergeGate() throws {
        let (root, runtime, lead) = try team()
        hold(lead)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let submitted = try verifier(root, runtime).call("submit_audit", ["completion": "incomplete", "integrity": "clean", "summary": "bug",
            "findings": [["severity": "Important", "file": "b.txt", "line": 1, "evidence": "wrong text", "failure_scenario": "reader expects b; receives bee"]]])
        #expect(!submitted.isError, "\(submitted.text)")
        #expect(vault.audits(root: root, task: "fix")?.blocking.count == 1)
        #expect(lead.call("merge", ["task": "fix"]).isError)
    }

    @Test(arguments: [false, true]) func sensitiveCodexMergesGetClaudeAfterReset(important: Bool) async throws {
        let (root, runtime, lead) = try team(sensitive: true)
        #expect(!lead.call("configure", ["auto_advance": false]).isError)
        hold(lead)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        #expect(!(try verifier(root, runtime)).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "Codex checked"]).isError)
        #expect(!lead.call("merge", ["task": "fix"]).isError)
        let merged = try #require(BoardStore(root: root).load().task("fix")?.merged)
        #expect(lead.call("cleanup", ["task": "fix"]).isError)
        #expect(lead.call("status", [:]).text.contains("Claude re-audit pending"))
        let armed = LeadAdvanceTests.Armed()
        lead.usageWake = { date, work in armed.add(date, work) }
        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        #expect(await advancing.until { !armed.taken.isEmpty })
        #expect(followup(root)["session"] == nil)
        // Inject a fresh, clear usage reading and fire the reset event the loop itself armed.
        usageStore.record([AccountUsage.Limit(name: "seven_day", usedPercent: 20, resetsAt: Self.now.timeIntervalSince1970 + 3600,
                                              at: Self.now.timeIntervalSince1970 + 1)], now: Self.now)
        armed.taken.first?.1()
        #expect(await advancing.until { followup(root)["session"] != nil })
        advancing.stop()
        let session = try #require(followup(root)["session"] as? String)
        #expect(runtime.agents[session] == "claude" && runtime.spawned.last?.trust == true)
        let prompt = try LaunchArguments.prompt(of: "verify-fix", runtime)
        #expect(prompt.contains("Review the whole change against the pinned baseline"))
        let base = try #require(followup(root)["base"] as? String)
        #expect(prompt.contains("git diff " + base + "...HEAD"))
        #expect(!Git.run(["diff", base + "...agent/fix"], in: root).output.isEmpty)
        var verdict: [String: Any] = ["completion": important ? "incomplete" : "complete", "integrity": "clean", "summary": "Claude checked"]
        if important { verdict["findings"] = [["severity": "Important", "file": ".github/workflows/ci.yml", "line": 1,
                                               "evidence": "wrong setting", "failure_scenario": "CI receives invalid config and cannot start"]] }
        #expect(!(try verifier(root, runtime)).call("submit_audit", verdict).isError)
        let after = try #require(BoardStore(root: root).load().task("fix"))
        #expect(after.status == .done && after.merged == merged)
        #expect((followup(root)["passed"] as? Bool != true) == important)
        #expect(fields(after.evidence)["agent"] as? String == "codex")
        let status = lead.call("status", [:]).text
        #expect(status.contains("Post-merge Claude re-audits") == important)
        if important {
            #expect(vault.audits(root: root, task: "fix")?.blocking.count == 1)
            #expect(status.contains("needs the lead's attention"))
            #expect(runtime.steered.last?.text.contains("Important") == true)
        } else {
            #expect(!lead.call("cleanup", ["task": "fix"]).isError)
        }
    }

    @Test func aSecurityAuditAlsoFallsBackWithItsChecklist() throws {
        let (root, runtime, lead) = try team(security: true)
        hold(lead)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let session = try #require(vault.current(.verifier, root: root, task: "fix")?.session)
        #expect(runtime.agents[session] == "codex")
        let prompt = try String(contentsOf: vault.runFolder(root: root, name: "verify-fix").appendingPathComponent("prompt.md"), encoding: .utf8)
        #expect(prompt.contains("## Security checklist") && prompt.contains("spawns processes"))
    }

    @Test func codexFinderPanelsKeepTheirVoteAndProvenance() throws {
        let (root, runtime, lead) = try team(sensitive: true)
        #expect(!lead.call("configure", ["audit_finders": 2]).isError)
        hold(lead)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let sessions = try #require(BoardStore(root: root).load().task("fix")?.panel?.sessions)
        #expect(sessions.count == 2)
        for session in sessions {
            #expect(runtime.agents[session] == "codex")
            let result = try verifier(root, runtime, session: session).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "checked", "tests": "passed"])
            #expect(!result.isError, "\(result.text)")
        }
        #expect(fields(vault.verdict(root: root, task: "fix"))["agent"] as? String == "codex")
        #expect(vault.audits(root: root, task: "fix")?.vote != nil)
        #expect(!lead.call("merge", ["task": "fix"]).isError)
        #expect(!followup(root).isEmpty)
    }

    @Test func codexMergeProvenanceSurvivesVerdictReplacementDuringTheTestRun() throws {
        let (root, runtime, lead) = try team(sensitive: true)
        hold(lead)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        #expect(!(try verifier(root, runtime)).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "checked"]).isError)
        _ = try lead.advanceMerge("fix", locked: { try? lead.vault.clearVerdict(root: root, task: "fix") })
        #expect(fields(BoardStore(root: root).load().task("fix")?.merged)["agent"] as? String == "codex")
        #expect(!followup(root).isEmpty)
    }

    @Test(arguments: [false, true], [false, true]) func eligibleClaudeModelsAreTriedBeforeCodex(sensitive: Bool, refused: Bool) throws {
        let (root, runtime, lead) = try team(sensitive: sensitive)
        if refused {
            usageStore.record([AccountUsage.Limit(name: "seven_day_overage_included", model: "fable", usedPercent: 100,
                resetsAt: Self.now.timeIntervalSince1970 + 3600, at: Self.now.timeIntervalSince1970, reached: true)], now: Self.now)
        } else { hold(lead, model: "fable") }
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let session = try #require(vault.current(.verifier, root: root, task: "fix")?.session)
        #expect(runtime.agents[session] == "claude")
        #expect(LeadWorkflow.claudeModel(command: runtime.spawned.last?.command ?? "") == "opus")
    }

    @Test func claudeFallbackRespectsTheWorkerModelFloor() throws {
        let (root, runtime, lead) = try team(sensitive: true)
        try vault.setReviewFloor(LeadReviewFloor(), root: root)
        let nextFloorRead = lead.floorClock() + LeadToolset.floorFresh
        lead.floorClock = { nextFloorRead }
        hold(lead, model: "fable")
        hold(lead, model: "sonnet")
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let session = try #require(vault.current(.verifier, root: root, task: "fix")?.session)
        #expect(runtime.agents[session] == "codex", "The default worker model is Opus, so no Claude model the floor permits has room")
    }

    @Test(arguments: [false, true], [false, true]) func codexWithoutRoomWaits(automatic: Bool, unknown: Bool) throws {
        let (root, runtime, lead) = try team(sensitive: true)
        hold(lead)
        if unknown { lead.codexUsage = CodexUsageReader(home: temp.url("unknown-codex-home")) }
        else { try codexRoom(lead, used: 100) }
        let reason = unknown ? "Codex usage not known" : "Codex 100%, no room"
        if automatic {
            let advance = LeadAdvance(lead: lead, run: { $0(); return true })
            advance.pass()
            let progress = try String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)
            #expect(progress.contains(reason), "\(progress)")
        } else {
            let result = lead.call("audit", ["task": "fix"])
            #expect(result.isError && result.text.contains(reason), "\(result.text)")
        }
        #expect(BoardStore(root: root).load().task("fix")?.verifier == nil)
        #expect(runtime.spawned.count == 1)
    }

    @Test func codexVerifierIsReadOnly() throws {
        let (_, runtime, lead) = try team()
        hold(lead)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let command = try #require(runtime.spawned.last?.command)
        #expect(command.contains("--sandbox read-only"))
        #expect(!command.contains("--sandbox workspace-write"))
    }

    @Test(arguments: ["gone", "ended", "limited"]) func postMergeClaudeAuditRetriesLostVerifiers(ending: String) throws {
        let (root, runtime, lead) = try team(sensitive: true)
        #expect(!lead.call("configure", ["auto_advance": false]).isError)
        hold(lead)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        #expect(!(try verifier(root, runtime)).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "checked"]).isError)
        #expect(!lead.call("merge", ["task": "fix"]).isError)
        clearClaude(Self.now.timeIntervalSince1970 + 1)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let first = try #require(followup(root)["session"] as? String)
        let stale = try verifier(root, runtime)
        if ending == "gone" { runtime.forgotten.append(first) }
        if ending == "ended" { runtime.endings[first] = "exited 1" }
        if ending == "limited" {
            runtime.usageLimits[first] = UsageLimit(said: "You've hit your Fable limit", resetsAt: Self.now.timeIntervalSince1970 + 3600,
                at: Self.now.timeIntervalSince1970 + 2, kind: "seven_day")
        }
        let armed = LeadAdvanceTests.Armed()
        lead.usageWake = { date, work in armed.add(date, work) }
        let advance = LeadAdvance(lead: lead, run: { $0(); return true })
        advance.pass()
        if ending == "limited" {
            #expect(!armed.taken.isEmpty)
            #expect(followup(root)["session"] as? String == first)
            runtime.usageLimits[first] = nil
            runtime.endings[first] = "exited after limit"
            clearClaude(Self.now.timeIntervalSince1970 + 3)
            advance.pass()
            #expect(followup(root)["session"] as? String == first, "A stop at the limit waits for that limit's reset")
            lead.usageClock = { Self.now.addingTimeInterval(3601) }
            advance.pass()
        }
        let second = try #require(followup(root)["session"] as? String)
        #expect(second != first)
        #expect(runtime.agents[second] == "claude")
        advance.pass()
        #expect(followup(root)["session"] as? String == second, "A live verifier is left alone")
        #expect(stale.call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "stale"]).isError)
        #expect(!(try verifier(root, runtime)).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "retried"]).isError)
        #expect(followup(root)["passed"] as? Bool == true)
        #expect(BoardStore(root: root).load().task("fix")?.status == .done)
    }

    @Test func codexMergedResultRunsHostChecksOnce() throws {
        let (root, runtime, lead) = try team()
        let worktree = Worktrees.path(root: root, slug: "fix")
        try "one\nworker\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        #expect(Git.run(["add", "a.txt"], in: worktree).ok)
        #expect(Git.run(["commit", "-qm", "worker append"], in: worktree).ok)
        #expect(!(try seat("worker-fix", runtime)).call("report", doneReport("appended")).isError)
        try "base\none\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        #expect(Git.run(["add", "a.txt"], in: root).ok)
        #expect(Git.run(["commit", "-qm", "base prepend"], in: root).ok)
        let count = temp.url("host-runs").path
        #expect(!lead.call("configure", ["test_command": "echo AUDIT_HOST_LOG; echo run >> " + RecentProjects.shellQuote(count)]).isError)
        hold(lead)
        let result = lead.call("audit", ["task": "fix"])
        #expect(!result.isError && result.text.contains("checks the merged result"), "\(result.text)")
        #expect(try String(contentsOfFile: count, encoding: .utf8).split(separator: "\n").count == 1)
        let prompt = try String(contentsOf: vault.runFolder(root: root, name: "verify-fix").appendingPathComponent("prompt.md"), encoding: .utf8)
        #expect(prompt.contains("Do not run host tests") && prompt.contains("read every log before judging"))
    }

    @Test func aPostMergeVerifierDeathIsRetriedFromItsScheduledCheck() async throws {
        let (root, runtime, lead) = try team(sensitive: true)
        #expect(!lead.call("configure", ["auto_advance": false]).isError)
        hold(lead)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        #expect(!(try verifier(root, runtime)).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "checked"]).isError)
        #expect(!lead.call("merge", ["task": "fix"]).isError)
        usageStore.record([AccountUsage.Limit(name: "seven_day", usedPercent: 20,
            resetsAt: Self.now.timeIntervalSince1970 + 3600, at: Self.now.timeIntervalSince1970 + 1)], now: Self.now)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let first = try #require(followup(root)["session"] as? String)
        let armed = LeadAdvanceTests.Armed()
        lead.usageWake = { date, work in armed.add(date, work) }
        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        await advancing.settle()
        let wake = try #require(armed.taken.first, "A merged task gets no ordinary review-task death notification; its own check must be scheduled")
        runtime.calls.withLock { runtime.endings[first] = "exited 1" }
        wake.1()
        #expect(await advancing.until { followup(root)["session"] as? String != first })
        let second = try #require(followup(root)["session"] as? String)
        #expect(runtime.agents[second] == "claude")
        await advancing.settle()
        let secondWake = try #require(armed.taken.dropFirst().first, "The scheduled check must rearm after firing")
        runtime.calls.withLock { runtime.endings[second] = "exited 1 again" }
        secondWake.1()
        // A second ending stops it, as an ordinary audit's retry stops: the lead is told, and nothing starts a third.
        #expect(await advancing.until { (followup(root)["endings"] as? [Any])?.count == 2 })
        await advancing.settle()
        #expect(followup(root)["session"] as? String == second)
        #expect(await advancing.until { runtime.calls.withLock { runtime.steered.contains { $0.text.contains("ended without a verdict 2 times") } } })
    }

    /// A sensitive task merged on a Codex verdict, Claude's limit cleared by a newer reading, and its post-merge Claude
    /// re-audit started: the verifier's session.
    func reauditing() throws -> (String, FakeRuntime, LeadToolset, String) {
        let (root, runtime, lead) = try team(sensitive: true)
        #expect(!lead.call("configure", ["auto_advance": false]).isError)
        hold(lead)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        #expect(!(try verifier(root, runtime)).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "checked"]).isError)
        #expect(!lead.call("merge", ["task": "fix"]).isError)
        clearClaude(Self.now.timeIntervalSince1970 + 1)
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        return (root, runtime, lead, try #require(followup(root)["session"] as? String))
    }

    /// A fresh reading of Claude's account under every limit, read at `at`.
    func clearClaude(_ at: Double) {
        usageStore.record([AccountUsage.Limit(name: "seven_day", usedPercent: 20, resetsAt: Self.now.timeIntervalSince1970 + 3600, at: at)], now: Self.now)
    }

    func progress(_ root: String) -> String {
        (try? String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)) ?? ""
    }

    /// F9: a re-audit verifier stopped at Claude's limit was started again at every pass (60 s apart) once any newer
    /// reading of the account looked clear, each one stopping at the limit again. It waits for its own limit's reset.
    @Test func aLimitStoppedPostMergeVerifierWaitsForItsReset() throws {
        let (root, runtime, lead, first) = try reauditing()
        let reset = Self.now.timeIntervalSince1970 + 3600
        runtime.usageLimits[first] = UsageLimit(said: "You've hit your limit", resetsAt: reset, at: Self.now.timeIntervalSince1970 + 2, kind: "seven_day")
        let armed = LeadAdvanceTests.Armed()
        lead.usageWake = { date, work in armed.add(date, work) }
        let advance = LeadAdvance(lead: lead, run: { $0(); return true })
        let spawned = runtime.spawned.count
        for at in [3.0, 4.0, 5.0] {
            // Other sessions' status lines read the account as clear: only the verifier's own refusal says it's held.
            clearClaude(Self.now.timeIntervalSince1970 + at)
            advance.pass()
            #expect(followup(root)["session"] as? String == first)
        }
        #expect(runtime.spawned.count == spawned)
        let wake = try #require(armed.taken.first { $0.0.timeIntervalSince1970 > reset }, "A look again just after the limit's reset")
        lead.usageClock = { Date(timeIntervalSince1970: reset + 1) }
        wake.1()
        advance.pass()
        let second = try #require(followup(root)["session"] as? String)
        #expect(second != first && runtime.agents[second] == "claude")
        #expect(followup(root)["endings"] == nil, "A stop at the limit isn't an ending")
    }

    /// F9: a re-audit whose verifiers end without a verdict is retried once, as an ordinary audit is; at the second
    /// ending nothing starts a third, the lead is told once (a restarted lead server too), and it stays listed.
    @Test func postMergeRetriesStopAfterTwoEndingsAndReportOnce() throws {
        let (root, runtime, lead, first) = try reauditing()
        lead.usageWake = { _, _ in }
        let advance = LeadAdvance(lead: lead, run: { $0(); return true })
        runtime.endings[first] = "exited 1"
        advance.pass()
        let second = try #require(followup(root)["session"] as? String)
        #expect(second != first)
        runtime.forgotten.append(second)
        let spawned = runtime.spawned.count
        for advance in [advance, advance, LeadAdvance(lead: lead, run: { $0(); return true })] { advance.pass() }
        #expect(runtime.spawned.count == spawned)
        #expect(followup(root)["session"] as? String == second)
        let told = progress(root).components(separatedBy: "\n").filter { $0.contains("ended without a verdict 2 times") }
        #expect(told.count == 1, "\(told)")
        #expect(told.first?.contains("exited 1") == true && told.first?.contains("its session is gone") == true)
        #expect(lead.call("status", [:]).text.contains("Claude re-audit stopped"))
        #expect(lead.call("cleanup", ["task": "fix"]).isError)
        // The lead starts it again: its count starts over.
        #expect(!lead.call("audit", ["task": "fix"]).isError)
        let third = try #require(followup(root)["session"] as? String)
        #expect(third != second && runtime.agents[third] == "claude" && followup(root)["endings"] == nil)
    }

    /// F4: a re-audit that can't be audited (no verdict to rule on) is closed only by the lead's explicit decision:
    /// cleanup with force and a reason that cites something checkable.
    @Test func theLeadClosesAReauditThatCantBeAuditedOnlyExplicitly() throws {
        let (root, _, lead, _) = try reauditing()
        #expect(lead.call("cleanup", ["task": "fix"]).isError)
        #expect(lead.call("cleanup", ["task": "fix", "force": true]).isError)
        #expect(lead.call("cleanup", ["task": "fix", "force": true, "reason": "I remember it was fine"]).isError)
        #expect(followup(root)["passed"] as? Bool != true)
        let closed = lead.call("cleanup", ["task": "fix", "force": true, "reason": "branch lost; the user accepted it, decided 2026-11-19 10:00:00"])
        #expect(!closed.isError, "\(closed.text)")
        #expect(followup(root)["passed"] as? Bool == true && (followup(root)["closed"] as? String)?.contains("2026-11-19 10:00:00") == true)
        #expect(!lead.call("status", [:]).text.contains("Post-merge Claude re-audits"))
        #expect(progress(root).contains("closed by the lead without its verdict"))
        // Its reason goes into progress.md, so the record lints screen it as dismiss_finding's.
        #expect(RecordLint.recordingTools.contains("cleanup"))
    }

    /// F4: a re-audit's Important finding the lead dismisses (or moves to a task) closes the obligation, so its branch
    /// can be cleaned up; never before a Claude verdict is in.
    @Test(arguments: [false, true]) func theLeadClosesAReauditByRulingOnItsFindings(moved: Bool) throws {
        let (root, runtime, lead, _) = try reauditing()
        #expect(lead.call("cleanup", ["task": "fix"]).isError)
        let verdict: [String: Any] = ["completion": "incomplete", "integrity": "clean", "summary": "Claude checked",
                                      "findings": [["severity": "Important", "file": ".github/workflows/ci.yml", "line": 1,
                                                    "evidence": "wrong setting", "failure_scenario": "CI receives invalid config and cannot start"]]]
        #expect(!(try verifier(root, runtime)).call("submit_audit", verdict).isError)
        let id = try #require(vault.audits(root: root, task: "fix")?.blocking.first?.id)
        #expect(lead.call("cleanup", ["task": "fix"]).isError)
        let ruled = moved ? lead.call("add_task", ["from_finding": "fix:\(id)", "title": "Fix CI config"])
            : lead.call("dismiss_finding", ["task": "fix", "id": id, "reason": "the user's setting, decided 2026-11-19 10:00:00"])
        #expect(!ruled.isError, "\(ruled.text)")
        #expect(ruled.text.contains("post-merge Claude re-audit is closed"), "\(ruled.text)")
        #expect(followup(root)["passed"] as? Bool == true && followup(root)["closed"] != nil)
        #expect(!lead.call("status", [:]).text.contains("Post-merge Claude re-audits"))
        #expect(!lead.call("cleanup", ["task": "fix"]).isError)
    }

}
