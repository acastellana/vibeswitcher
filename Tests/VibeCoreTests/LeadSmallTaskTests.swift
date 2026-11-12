import Foundation
import Testing
@testable import VibeCore

/// small_task_min (see `LeadSmallTask`): which tasks qualify, from what the vault keeps, the board and the workflow.
struct LeadSmallTaskTests {
    func task(_ change: (inout LeadTask) -> Void = { _ in }) -> LeadTask {
        var task = LeadTask(slug: "add-b", title: "Add b", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.review = .audit
        task.attempts = 1
        change(&task)
        return task
    }

    /// What the vault keeps: filed where audit_reason could be given, and `minutes` of work its witness counted.
    func facts(worked minutes: Double? = 10, _ change: (inout LeadVault.SmallTaskFacts) -> Void = { _ in }) -> LeadVault.SmallTaskFacts {
        var facts = LeadVault.SmallTaskFacts(reviewOffered: true, worked: minutes.map { $0 * 60 }, startedAt: 1_000, reportedAt: 1_000 + 20 * 60)
        change(&facts)
        return facts
    }

    func why(_ task: LeadTask, _ facts: LeadVault.SmallTaskFacts?, _ workflow: LeadWorkflow = LeadWorkflow(), rounds: Int = 0) -> String? {
        LeadSmallTask.ineligible(task, facts: facts, workflow: workflow, auditRounds: rounds)
    }

    @Test func underTheThresholdQualifiesAtOrOverItDoesnt() {
        #expect(LeadWorkflow().smallTaskMin == 30)
        #expect(why(task(), facts(worked: 29.9)) == nil)
        #expect(why(task(), facts(worked: 30))?.contains("not under small_task_min (30)") == true)
        #expect(why(task(), facts(worked: 45)) != nil)
        // Work the vault didn't count isn't small, whatever the board says; nothing kept at all keeps the audit.
        #expect(why(task { $0.worked = 60 }, facts(worked: nil)) != nil)
        #expect(why(task { $0.worked = 60 }, nil)?.contains("vault keeps no record") == true)
        // 0 turns it off; another threshold is taken.
        #expect(why(task(), facts(worked: 1), LeadWorkflow.parse("---\nsmall_task_min: 0\n---\n"))?.contains("off") == true)
        #expect(why(task(), facts(worked: 50), LeadWorkflow.parse("---\nsmall_task_min: 60\n---\n")) == nil)
    }

    @Test func codexRiskRaisedAuditReasonAndSampledTasksDontQualify() {
        // Codex: the vault's note, or the board's own word.
        #expect(why(task(), facts { $0.codex = true })?.contains("Codex") == true)
        #expect(why(task { $0.agent = .codex }, facts())?.contains("Codex") == true)
        #expect(why(task { $0.codexWorked = true }, facts())?.contains("Codex") == true)
        for reason in LeadTask.AuditReason.allCases {
            #expect(why(task(), facts { $0.auditReason = reason })?.contains(reason.rawValue) == true)
            #expect(why(task { $0.auditReason = reason }, facts())?.contains(reason.rawValue) == true)
        }
        // Filed before audit_reason could be given: its audit may be for security, unsaid.
        #expect(why(task(), facts { $0.reviewOffered = nil })?.contains("before audit_reason") == true)
        #expect(why(task(), facts { $0.kept = "the risk check raised it" })?.contains("risk check") == true)
        #expect(why(task { $0.riskRaised = LeadRiskRaise(reason: "it spawns processes", commit: "abc", byModel: false) }, facts())?.contains("risk check") == true)
        #expect(why(task { $0.auditSample = LeadAuditSample(seed: 1, percent: 100, commit: "abc") }, facts()) != nil)
    }

    @Test func aSecondRoundOrAReRolledTaskDoesntQualify() {
        #expect(why(task { $0.attempts = 2 }, facts())?.contains("first round") == true)
        #expect(why(task(), facts(), rounds: 1)?.contains("first round") == true)
        #expect(why(task { $0.rerolls = [LeadReroll(archive: "archive/add-b-1", commit: "abc", round: 2)] }, facts())?.contains("re-rolled") == true)
        // The vault's word for a new round or a re-roll, whatever the board says.
        #expect(why(task(), facts { $0.kept = "re-rolled" })?.contains("re-rolled") == true)
        #expect(why(task(), facts { $0.kept = "sent back to work" }) != nil)
        // Dropped once: not again, but judged again at a later head of the same round.
        #expect(why(task(), facts { $0.dropped = "abc" })?.contains("once already") == true)
        #expect(LeadSmallTask.ineligible(task(), facts: facts { $0.dropped = "abc" }, workflow: LeadWorkflow(), auditRounds: 0, redrop: true) == nil)
    }

    /// The host's span from the first worker's start to the done report bounds the count: over small_task_min, or not
    /// on record, the count isn't vouched for (the witness missed time, or was kept from seeing the worker).
    @Test func aCountOverTheHostsSpanIsntTrusted() {
        #expect(why(task(), facts { $0.reportedAt = 1_000 + 3 * 3_600 })?.contains("can't be vouched for") == true)
        #expect(why(task(), facts { $0.startedAt = nil })?.contains("isn't on record") == true)
        #expect(why(task(), facts { $0.reportedAt = nil })?.contains("isn't on record") == true)
        #expect(why(task(), facts { $0.reportedAt = 1_000 + 29 * 60 }) == nil)
    }

    /// A floor (or workflow.md) that audits every review none task wins: nothing is dropped.
    @Test func aFloorThatAuditsEveryTaskWins() {
        var workflow = LeadWorkflow()
        workflow.floor = LeadReviewFloor(auditSamplePercent: 100)
        #expect(why(task(), facts(), workflow)?.contains("100") == true)
        #expect(why(task(), facts(), LeadWorkflow.parse("---\naudit_sample_percent: 100\n---\n")) != nil)
        workflow.floor = LeadReviewFloor(auditSamplePercent: 50)
        #expect(why(task(), facts(), workflow) == nil)
    }

    /// The vault counts working time from the app's looks: each stretch at most `LeadBudget.longestStep`, a look not at
    /// work ends the stretch, a look out of order counts nothing.
    @Test func theVaultCountsWorkFromTheWitnessLooks() {
        var facts = LeadVault.SmallTaskFacts()
        facts.count(working: true, at: 1_000)
        #expect(facts.worked == nil && facts.workingSince == 1_000)
        facts.count(working: true, at: 1_030)
        facts.count(working: true, at: 1_020)
        facts.count(working: true, at: 5_000)
        #expect(facts.worked == 30 + LeadBudget.longestStep)
        facts.count(working: false, at: 5_010)
        facts.count(working: true, at: 9_000)
        #expect(facts.worked == 30 + LeadBudget.longestStep && facts.workingSince == 9_000)
        // The lead's notes: audit_reason as given (empty clears it), the rest only ever set.
        var noted = facts.noting(LeadVault.SmallTaskNote(auditReason: "security", reviewOffered: true, codex: true, kept: "re-rolled", dropped: "abc"))
        noted = noted.noting(LeadVault.SmallTaskNote(auditReason: "", reviewOffered: false, codex: false, kept: "later", dropped: "def"))
        #expect(noted.auditReason == nil && noted.reviewOffered == true && noted.codex == true && noted.kept == "re-rolled" && noted.dropped == "abc")
    }

    /// Status's line: this week's merged this way, and of them the reverted and those a later task names as fixed.
    @Test func theStatusLineCountsThisWeeksMergesRevertsAndFixTasks() {
        let now = 1_800_000_000.0
        func merged(_ slug: String, at: Double, revertedBy: String? = nil, restored: String? = nil) -> LeadTask {
            var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
            task.status = .done
            task.smallTask = LeadSmallTask(minutes: 5, commit: "abc", at: at - 60, restored: restored)
            var record = LeadMergeRecord(commit: "def", tested: true, audited: false)
            record.at = at
            record.revertedBy = revertedBy
            task.merged = record
            return task
        }
        #expect(LeadSmallTask.statusLine([], now: now) == nil)
        var fix = LeadTask(slug: "fix-a", title: "Fix the crash small-a left", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        fix.createdAt = now - 3_600
        var older = LeadTask(slug: "plan-c", title: "Before small-a merged", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        older.createdAt = now - 3 * 86_400
        let tasks = [merged("small-a", at: now - 86_400), merged("small-b", at: now - 2 * 86_400, revertedBy: "1234567890"),
                     merged("small-old", at: now - 8 * 86_400), merged("small-raised", at: now - 3_600, restored: "the audit sample drew it"),
                     fix, older]
        let line = LeadSmallTask.statusLine(tasks, now: now)
        #expect(line == "Small tasks merged on tests (small_task_min, no audit; last 7 days): 2 · reverted since: 1 (small-b) · "
            + "with a fix task filed against them (a later task naming them in its title or goal): 1 (small-a ← fix-a).", "\(line ?? "")")
    }
}

/// small_task_min through auto_advance: the drop at the done report, and what keeps a task audited.
extension LeadAdvanceTests {
    /// The worker's counted work so far, as the vault counts it from the app's witness (looks `LeadBudget.longestStep`
    /// apart, on the witness's clock), and its rounds as the board says.
    func setWorked(_ slug: String, minutes: Double, attempts: Int? = nil, root: String) throws {
        let worker = try #require(task(slug, root)?.worker)
        var at = Date().timeIntervalSince1970 - minutes * 60
        try vault.noteWorking(root: root, sessions: [worker], at: at)
        var left = minutes * 60
        while left > 0 {
            let step = min(left, LeadBudget.longestStep)
            at += step
            left -= step
            try vault.noteWorking(root: root, sessions: [worker], at: at)
        }
        try vault.noteWorking(root: root, sessions: [], at: at)
        if let attempts {
            try BoardStore(root: root).update { board in
                guard let index = board.taskIndex(slug) else { return }
                board.tasks[index].attempts = attempts
            }
        }
    }

    func toLead(_ runtime: FakeRuntime) -> [String] {
        runtime.calls.lock()
        defer { runtime.calls.unlock() }
        return runtime.steered.map(\.text)
    }

    @Test func smallTaskUnderTheThresholdMergesOnItsTestsWithNoAudit() async throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        let added = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "review": "audit"])
        #expect(added.text.contains("review audit"), "\(added.text)")
        #expect(await advancing.until { task("add-b", root)?.status == .running })
        try setWorked("add-b", minutes: 12, root: root)
        try work("add-b", file: "b.txt", root: root, runtime)
        let reported = head("agent/add-b", root)
        #expect(await advancing.until { task("add-b", root)?.status == .done && reports(runtime).contains { $0.contains("Merged add-b") } })
        let done = try #require(task("add-b", root))
        #expect(done.merged?.unaudited == true && vault.current(.verifier, root: root, task: "add-b") == nil)
        #expect(done.smallTask?.minutes == 12 && done.smallTask?.commit == reported && done.smallTask?.restored == nil)
        #expect(done.review == LeadTask.Review.none)
        let vaultReview = try vault.unaudited(root: root, task: "add-b").review
        #expect(vaultReview == LeadTask.Review.none)
        #expect(progress(root).contains("add-b small task: merged on tests (12 min of work)"))
        // The sample still drew, as for any review none task (the fixture's seed doesn't sample).
        #expect(done.auditSample?.sampled == false)
        // The lead was told at the report that it goes as review none.
        #expect(toLead(runtime).contains { $0.contains("it's a small task (12 min of work") }, "\(toLead(runtime))")
        #expect(lead.call("status", [:]).text.contains("Small tasks merged on tests (small_task_min, no audit; last 7 days): 1 · reverted since: 0"))
        #expect(lead.call("board", ["task": "add-b"]).text.contains("small task: merged on tests (12 min of work)"))
    }

    enum Kept: String, CaseIterable { case overThreshold, sensitivePath, strictPath, riskFlagged, auditReason, floorAuditsAll, secondRound }

    /// Every other task keeps its audit: it's audited, not merged, and nothing is dropped.
    @Test(arguments: Kept.allCases)
    func smallTaskRuleLeavesTheseAudited(_ kept: Kept) async throws {
        let settings: [String: Any] = kept == .sensitivePath ? ["sensitive_paths": "secret/"] : kept == .strictPath ? ["strict_paths": "secret/"] : [:]
        let (root, runtime, lead) = try team(settings)
        if kept == .floorAuditsAll {
            try vault.setReviewFloor(LeadReviewFloor(auditSamplePercent: 100), root: root)
            // Past the floor read configure cached (`LeadToolset.floorFresh`): the lead reads the one just set.
            lead.floorClock = { ProcessInfo.processInfo.systemUptime + 3_600 }
            #expect(lead.workflow.samplePercentInForce == 100)
        }
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        var add: [String: Any] = ["title": "Add b", "goal": "b exists", "acceptance": ["test -e b"], "review": "audit"]
        if kept == .auditReason { add["audit_reason"] = "irreversible" }
        let added = lead.call("add_task", add)
        #expect(!added.isError, "\(added.text)")
        #expect(await advancing.until { task("add-b", root)?.status == .running })
        try setWorked("add-b", minutes: kept == .overThreshold ? 30 : 5, attempts: kept == .secondRound ? 2 : nil, root: root)
        let file = kept == .sensitivePath || kept == .strictPath ? "secret/b.txt" : kept == .riskFlagged ? "b.swift" : "b.txt"
        try FileManager.default.createDirectory(atPath: Worktrees.path(root: root, slug: "add-b") + "/secret", withIntermediateDirectories: true)
        try work("add-b", file: file, root: root, runtime)
        let reported = head("agent/add-b", root)
        #expect(await advancing.until { vault.current(.verifier, root: root, task: "add-b")?.auditing == reported
            && reports(runtime).contains { $0.contains("Started the audit of add-b") } })
        let after = try #require(task("add-b", root))
        #expect(after.smallTask == nil && after.merged == nil && after.review == .audit, "\(kept)")
        #expect(try vault.unaudited(root: root, task: "add-b").review == .audit)
        #expect(!progress(root).contains("small task"))
        #expect(!toLead(runtime).contains { $0.contains("it's a small task") })
        if kept == .auditReason { #expect(after.auditReason == .irreversible) }
        #expect((try? String(contentsOfFile: log, encoding: .utf8)) == nil)
    }

    /// The drop is for its first round: a merge whose tests fail sends it back, and from then on it's audited.
    @Test func smallTaskSentBackAfterItsDropIsAuditedFromThen() async throws {
        let (root, runtime, lead) = try team(test: "if test -f bad.txt; then echo BROKEN-ON-PURPOSE; exit 1; fi; echo ran >> '\(log)'")
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "review": "audit"])
        #expect(await advancing.until { task("add-b", root)?.status == .running })
        try setWorked("add-b", minutes: 8, root: root)
        try work("add-b", file: "bad.txt", root: root, runtime)
        #expect(await advancing.until { reports(runtime).contains { $0.contains("Merge of add-b failed") } && task("add-b", root)?.status == .running })
        let sent = try #require(task("add-b", root))
        // Its merge's failure ended the round, before its worker was sent the output.
        #expect(sent.smallTask?.restored == "its merge failed" && sent.review == .audit, "\(String(describing: sent.smallTask))")
        #expect(try vault.smallTaskFacts(root: root, task: "add-b")?.kept == "its merge failed")
        #expect(try vault.unaudited(root: root, task: "add-b").review == .audit)
        #expect(progress(root).contains("add-b small task: merged on tests (8 min of work)") && progress(root).contains("add-b small task: back to audit (its merge failed)"))
        // Its fix, reported done: audited, not merged.
        let worktree = Worktrees.path(root: root, slug: "add-b")
        Git.run(["rm", "-q", "bad.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "drop bad.txt"], in: worktree)
        try commit("b.txt", "bee\n", in: worktree)
        let report = try seat("worker-add-b", runtime).call("report", doneReport("fixed"))
        #expect(!report.isError, "\(report.text)")
        let fixed = head("agent/add-b", root)
        #expect(await advancing.until { vault.current(.verifier, root: root, task: "add-b")?.auditing == fixed })
        #expect(task("add-b", root)?.merged == nil)
        #expect(!lead.call("status", [:]).text.contains("Small tasks merged on tests"))
    }

    enum Edited: String, CaseIterable { case overOnTheVaultsCount, noCountInTheVault, auditReasonInTheVault, codexInTheVault, workflowRaisesSmallTaskMin }

    /// The board is anyone's to write: an entry edited to claim 1 minute of work, no audit_reason and no Codex doesn't
    /// drop the audit when the vault says otherwise (more work, none counted, an audit_reason, a Codex worker). Nor is
    /// workflow.md, which any session may write: small_task_min raised there for the done report doesn't drop it (the
    /// vault keeps what the lead set with configure; a worker could set the file back before merge looks).
    @Test(arguments: Edited.allCases)
    func smallTaskEditedBoardEntryDoesntDropTheAudit(_ edited: Edited) async throws {
        let (root, runtime, lead) = try team()
        let advancing = Advancing(lead)
        defer { advancing.stop() }
        var add: [String: Any] = ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "review": "audit"]
        if edited == .auditReasonInTheVault { add["audit_reason"] = "security" }
        #expect(!lead.call("add_task", add).isError)
        #expect(await advancing.until { task("add-b", root)?.status == .running })
        switch edited {
        case .overOnTheVaultsCount, .workflowRaisesSmallTaskMin: try setWorked("add-b", minutes: 40, root: root)
        case .noCountInTheVault: break
        case .auditReasonInTheVault: try setWorked("add-b", minutes: 5, root: root)
        case .codexInTheVault:
            // As start_worker notes a Codex worker it starts.
            lead.noteSmallTask("add-b", LeadVault.SmallTaskNote(codex: true))
            try setWorked("add-b", minutes: 5, root: root)
        }
        // The worker's edit: 1 minute, no audit_reason, Claude's, first round.
        try BoardStore(root: root).update { board in
            guard let index = board.taskIndex("add-b") else { return }
            board.tasks[index].worked = 60
            board.tasks[index].auditReason = nil
            board.tasks[index].agent = nil
            board.tasks[index].codexWorked = nil
            board.tasks[index].attempts = 1
        }
        let configured = try String(contentsOfFile: lead.workflowPath, encoding: .utf8)
        if edited == .workflowRaisesSmallTaskMin {
            let raised = configured.replacingOccurrences(of: "small_task_min: 30", with: "small_task_min: 100000")
            #expect(raised != configured)
            try raised.write(toFile: lead.workflowPath, atomically: true, encoding: .utf8)
        }
        try work("add-b", file: "b.txt", root: root, runtime)
        let reported = head("agent/add-b", root)
        // Judged at its done report: its audit starts, or it's dropped (red), whichever comes first.
        #expect(await advancing.until { vault.current(.verifier, root: root, task: "add-b")?.auditing == reported || task("add-b", root)?.smallTask != nil })
        #expect(vault.current(.verifier, root: root, task: "add-b")?.auditing == reported)
        #expect(task("add-b", root)?.smallTask == nil && task("add-b", root)?.merged == nil, "\(edited)")
        #expect(try vault.unaudited(root: root, task: "add-b").review == .audit)
        #expect(!progress(root).contains("small task"))
    }

    /// A later round is the vault's to say, not the board's: a worker started again on a task the vault granted a
    /// worker before is a later round, even when its board entry was edited to read as never started.
    @Test func smallTaskSecondWorkerIsALaterRoundWhateverTheBoardSays() async throws {
        let (root, runtime, lead) = try team()
        #expect(!lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "review": "audit", "auto_advance": false]).isError)
        let first = lead.call("start_worker", ["task": "add-b"])
        #expect(!first.isError, "\(first.text)")
        #expect(try vault.smallTaskFacts(root: root, task: "add-b")?.startedAt != nil)
        #expect(try vault.smallTaskFacts(root: root, task: "add-b")?.kept == nil)
        // The first worker's gone, and the board edited to read as a task never started (not failed, first attempt).
        let worker = try #require(task("add-b", root)?.worker)
        try runtime.kill(worker)
        try BoardStore(root: root).update { board in
            guard let index = board.taskIndex("add-b") else { return }
            board.tasks[index].status = .planned
            board.tasks[index].worker = nil
            board.tasks[index].attempts = nil
        }
        let second = lead.call("start_worker", ["task": "add-b"])
        #expect(!second.isError, "\(second.text)")
        #expect(try vault.smallTaskFacts(root: root, task: "add-b")?.kept == "a new round of work")
    }

    /// small_task_min is a workflow setting configure sets (0 turns it off), a guard rail as the risk check's are.
    @Test func smallTaskMinIsASettingConfigureSets() throws {
        let (_, _, lead) = try team()
        #expect(LeadWorkflow.load(from: lead.workflowPath).smallTaskMin == 30)
        #expect(LeadWorkflow.configurable.contains("small_task_min") && LeadVault.guardedKeys.contains("small_task_min"))
        #expect(lead.call("configure", ["small_task_min": -1]).isError)
        let set = lead.call("configure", ["small_task_min": 15])
        #expect(!set.isError, "\(set.text)")
        #expect(LeadWorkflow.load(from: lead.workflowPath).smallTaskMin == 15)
        #expect(!lead.call("configure", ["small_task_min": 0]).isError)
        #expect(lead.call("configure", [:]).text.contains("small_task_min: 0 (off"))
        // audit_reason: one of security or irreversible, and never with review none.
        #expect(lead.call("add_task", ["title": "X", "goal": "g", "acceptance": ["a"], "audit_reason": "cosmetic"]).isError)
        #expect(lead.call("add_task", ["title": "Y", "goal": "g", "acceptance": ["a"], "audit_reason": "security", "review": "none"]).isError)
        let pinned = lead.call("add_task", ["title": "Z", "goal": "g", "acceptance": ["a"], "audit_reason": "security"])
        #expect(pinned.text.contains("review audit"), "\(pinned.text)")
        #expect(!lead.call("update_task", ["task": "z", "audit_reason": ""]).isError)
        #expect(BoardStore(root: lead.root).load().task("z")?.auditReason == nil && BoardStore(root: lead.root).load().task("z")?.review == .audit)
        // The vault keeps the lead's word, where a worker can't write it.
        #expect(try vault.smallTaskFacts(root: lead.root, task: "z") == LeadVault.SmallTaskFacts(reviewOffered: true))
        #expect(!lead.call("update_task", ["task": "z", "audit_reason": "irreversible"]).isError)
        #expect(try vault.smallTaskFacts(root: lead.root, task: "z")?.auditReason == .irreversible)
    }
}
