import Foundation
import Testing
@testable import VibeCore

/// The lead's rules that were prose in decisions.md and its brief, made checks the tools keep (docs/process/lead-rules.md
/// lists every rule and what enforces it): a breach is refused, whatever the lead or the worker remembers. On fake
/// sessions only.
struct LeadRuleChecksTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo(loadScript: Bool = false) throws -> String {
        let url = temp.url("rules")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try commit("a.txt", "one\n", in: root)
        if loadScript { try commit(LeadToolset.loadScript, "#!/bin/bash\n", in: root) }
        return root
    }

    func commit(_ file: String, _ text: String, in dir: String) throws {
        let path = dir + "/" + file
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        Git.run(["add", file], in: dir)
        Git.run(["commit", "-q", "-m", "change \(file)"], in: dir)
    }

    func head(_ ref: String, _ root: String) -> String { Git.run(["rev-parse", ref], in: root).output }

    /// A lead with merge_policy auto and `test -f b.txt` its test command, and task add-b (review audit) planned.
    func planned(_ root: String, _ runtime: FakeRuntime) throws -> LeadToolset {
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "test -f b.txt"]).isError)
        #expect(!lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "review": "audit"]).isError)
        return lead
    }

    /// add-b's worker started, b.txt committed and reported done; its worktree.
    func reported(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String) throws -> String {
        let started = lead.call("start_worker", ["task": "add-b"])
        #expect(!started.isError, "\(started.text)")
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try commit("b.txt", "bee\n", in: worktree)
        let report = try seat("worker-add-b", runtime).call("report", doneReport("added b.txt"))
        #expect(!report.isError, "\(report.text)")
        return worktree
    }

    func verifiers(_ runtime: FakeRuntime) -> Int { runtime.spawned.filter { $0.label.hasPrefix("Verifier:") }.count }

    // MARK: the battery hold (decisions 2026-10-19 15:50, 2026-10-20 22:12)

    /// Under the user's battery limit nothing starts, audits or merges, through the lead's own calls too: the lead
    /// kept the hold by hand from the witness's messages, and on 2026-10-19 two verifiers and a merge's test run died
    /// in the Mac's sleeps at 2 %.
    @Test func underTheBatteryLimitStartWorkerAuditAndMergeRefuse() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try planned(root, runtime)
        var held = PowerState(onBattery: true, percent: 40)
        held.heldUnder = 50
        lead.power = { held }

        let start = lead.call("start_worker", ["task": "add-b"])
        #expect(start.isError && start.text.hasPrefix("Not started: the Mac is on battery at 40 %, under the user's 50 % limit"), "\(start.text)")
        #expect(runtime.spawned.isEmpty)
        // On battery above the limit, as on power.
        lead.power = { PowerState(onBattery: true, percent: 80) }
        _ = try reported(lead, runtime, root: root)

        lead.power = { held }
        let audit = lead.call("audit", ["task": "add-b"])
        #expect(audit.isError && audit.text.hasPrefix("Not audited, no verifier started: the Mac is on battery"), "\(audit.text)")
        #expect(verifiers(runtime) == 0)
        lead.power = { nil }
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        let verdict = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "ok", "tests": "passed"])
        #expect(!verdict.isError, "\(verdict.text)")

        lead.power = { held }
        let merge = lead.call("merge", ["task": "add-b"])
        #expect(merge.isError && merge.text.hasPrefix("Not merged: the Mac is on battery"), "\(merge.text)")
        #expect(!Git.run(["show", "main:b.txt"], in: root).ok)
        // AC power back: it merges.
        lead.power = { PowerState(onBattery: false, percent: 41) }
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(Git.run(["show", "main:b.txt"], in: root).output == "bee")
    }

    // MARK: no audit round on a passing, unchanged commit (working policy 2026-10-21)

    /// A second audit of the commit a passing verdict covers, with nothing Important open, checks the same code again:
    /// refused, no verifier started. A new commit is audited as ever.
    @Test func aPassingCommitIsntAuditedAgainUntilTheBranchMoves() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try planned(root, runtime)
        let worktree = try reported(lead, runtime, root: root)
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        let nit: [String: Any] = ["severity": "Nit", "file": "b.txt", "line": 1, "evidence": "no trailing blank line", "status": "open"]
        let verdict = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "ok",
                                                                                "tests": "passed", "findings": [nit]])
        #expect(!verdict.isError, "\(verdict.text)")
        let spawned = verifiers(runtime)
        let audited = head("agent/add-b", root)

        let again = lead.call("audit", ["task": "add-b"])
        #expect(again.isError, "\(again.text)")
        #expect(again.text.hasPrefix("Not audited: add-b's audit at \(audited.prefix(8)) passed (complete, clean) with no Important finding open"), "\(again.text)")
        #expect(verifiers(runtime) == spawned)
        // The verdict still stands: merge can go ahead.
        #expect(vault.verdict(root: root, task: "add-b")?.commit == audited)

        // The worker commits a change: that commit is audited.
        try commit("b.txt", "bee!\n", in: worktree)
        let moved = lead.call("audit", ["task": "add-b"])
        #expect(!moved.isError, "\(moved.text)")
        #expect(verifiers(runtime) == spawned + 1)
    }

    /// A verdict that didn't pass, or a passing one with an Important finding open (its answers to judge), is audited
    /// again on the same commit: only a clean pass is refused.
    @Test func aFailedOrBlockedVerdictIsAuditedAgainOnTheSameCommit() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try planned(root, runtime)
        _ = try reported(lead, runtime, root: root)
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        let important: [String: Any] = ["severity": "Important", "file": "b.txt", "line": 1, "evidence": "says bee",
                                        "failure_scenario": "cat b.txt gives bee where the contract wants b", "status": "open"]
        _ = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "one problem",
                                                                    "tests": "passed", "findings": [important]])
        let again = lead.call("audit", ["task": "add-b"])
        #expect(!again.isError, "\(again.text)")
        _ = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "blocked", "integrity": "clean", "summary": "couldn't build"])
        let third = lead.call("audit", ["task": "add-b"])
        #expect(!third.isError, "\(third.text)")
    }

    // MARK: a Nit never becomes a task (working policy 2026-10-21)

    /// add_task(from_finding:) refuses a Nit and plans nothing; an Important one still becomes a task.
    @Test func aNitIsntMadeATask() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try planned(root, runtime)
        _ = try reported(lead, runtime, root: root)
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        let nit: [String: Any] = ["severity": "Nit", "file": "b.txt", "line": 1, "evidence": "no trailing blank line", "status": "open"]
        let important: [String: Any] = ["severity": "Important", "file": "a.txt", "line": 1, "evidence": "a.txt was emptied",
                                        "failure_scenario": "cat a.txt gives nothing where one was", "status": "open"]
        _ = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "two",
                                                                    "tests": "passed", "findings": [nit, important]])
        let findings = try #require(vault.audits(root: root, task: "add-b")?.findings)
        let nitID = try #require(findings.first { $0.severity == .nit }?.id)
        let importantID = try #require(findings.first { $0.severity == .important }?.id)
        let tasks = BoardStore(root: root).load().tasks.count

        let refused = lead.call("add_task", ["from_finding": "add-b:\(nitID)"])
        #expect(refused.isError && refused.text.hasPrefix("Not added: add-b:\(nitID) is a Nit, and a Nit never becomes a task"), "\(refused.text)")
        #expect(BoardStore(root: root).load().tasks.count == tasks)
        // Still open on add-b, not closed as moved.
        #expect(vault.audits(root: root, task: "add-b")?.findings.first { $0.id == nitID }?.isOpen == true)

        let added = lead.call("add_task", ["from_finding": "add-b:\(importantID)"])
        #expect(!added.isError, "\(added.text)")
        #expect(BoardStore(root: root).load().tasks.count == tasks + 1)
    }

    // MARK: new tests proven under load (decision 2026-10-23 14:16)

    /// A done report on a branch that adds or changes tests, in a project with the load harness, gives their run under
    /// load: one that doesn't is refused, and nothing is recorded.
    @Test func aDoneThatAddsTestsWithoutTheirRunUnderLoadIsRefused() throws {
        let root = try repo(loadScript: true)
        let runtime = FakeRuntime()
        let lead = try planned(root, runtime)
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try commit("b.txt", "bee\n", in: worktree)
        try commit("Tests/CoreTests/BeeTests.swift", "// b\n", in: worktree)
        let worker = try seat("worker-add-b", runtime)

        let refused = worker.call("report", doneReport("added b.txt and BeeTests"))
        #expect(refused.isError, "\(refused.text)")
        #expect(refused.text.hasPrefix("Not reported: your branch adds or changes tests (Tests/CoreTests/BeeTests.swift)"), "\(refused.text)")
        #expect(refused.text.contains(LeadPrompts.proofCommand))
        #expect((try? vault.unaudited(root: root, task: "add-b"))?.reported == nil)
        #expect(BoardStore(root: root).load().task("add-b")?.status == .running)

        let proved = worker.call("report", doneReport("added b.txt and BeeTests; scripts/test-under-load.sh --load 24 -r 3 -f BeeTests: all 3 runs passed and left nothing behind"))
        #expect(!proved.isError, "\(proved.text)")
        #expect((try? vault.unaudited(root: root, task: "add-b"))?.reported == head("agent/add-b", root))
        // Again on the same commit (an answer, a note): its first done gave it.
        #expect(!worker.call("report", doneReport("answered")).isError)
    }

    /// No tests changed, or a project without the harness: nothing more is asked.
    @Test func aDoneWithoutNewTestsOrWithoutTheHarnessNeedsNoLoadRun() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try planned(root, runtime)
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try commit("Tests/CoreTests/BeeTests.swift", "// b\n", in: worktree)
        let report = try seat("worker-add-b", runtime).call("report", doneReport("added BeeTests"))
        #expect(!report.isError, "\(report.text)")
    }

    @Test func testFilesAreTheOnesUnderATestFolderOrNamedAsTests() {
        let paths = ["Tests/VibeCoreTests/LeadToolsetTests.swift", "Sources/VibeCore/LeadToolset.swift", "web/app.test.js", "web/app.spec.ts",
                     "pkg/merge_test.go", "tools/test_merge.py", "src/__tests__/x.js", "docs/testing.md", "Sources/VibeCore/Contest.swift",
                     "Tests/Web/app.js", "Sources/VibeCore/TestLock.swift"]
        #expect(LeadToolset.testFiles(paths) == ["Tests/VibeCoreTests/LeadToolsetTests.swift", "web/app.test.js", "web/app.spec.ts",
                                                 "pkg/merge_test.go", "tools/test_merge.py", "src/__tests__/x.js", "Tests/Web/app.js"])
    }
}
