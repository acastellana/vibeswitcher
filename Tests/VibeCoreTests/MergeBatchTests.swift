import Foundation
import Testing
@testable import VibeCore

/// Batched merges (merge_batching, see `LeadToolset.mergeBatch`): several review-passed tasks stacked on the base and
/// tested with one run, split on failure. Fake branches, a fake test command that logs each run; each wait is on the
/// loop's own passes or on the merge's return, never a fixed sleep.
struct MergeBatchTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    /// The fake test command's log: one line per run, its arguments then the files it saw.
    let runs: String
    init() {
        vault = Self.newVault(in: temp)
        runs = temp.url("runs.log").path
    }

    static let failure = """
        ✘ Test breaks() recorded an issue at BreakTests.swift:3:5: Expectation failed: no break.txt
        ✘ Test breaks() failed after 0.010 seconds with 1 issue.
        ✘ Test run with 2 tests failed after 0.020 seconds with 1 issue.
        """

    func repo() throws -> String {
        let url = temp.url("batch")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["config", "commit.gpgsign", "false"]] {
            Git.run(args, in: root)
        }
        try commit(["a.txt": "one\n", "c.txt": "see\n"], in: root, "first")
        return root
    }

    func commit(_ files: [String: String], in dir: String, _ message: String) throws {
        for (file, text) in files {
            let path = (dir as NSString).appendingPathComponent(file)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            Git.run(["add", file], in: dir)
        }
        Git.run(["commit", "-q", "-m", message], in: dir)
    }

    /// The suite: logs its run, fails (naming breaks()) while `fails` holds, else passes.
    func fakeSuite(_ root: String, fails: String = "[[ -e break.txt ]]") throws {
        try commit(["scripts/test.sh": """
            #!/bin/bash
            echo "run $* | $(ls *.txt | tr '\\n' ' ')" >> \(RecentProjects.shellQuote(runs))
            if \(fails); then
              printf '%s\\n' \(Self.failure.split(separator: "\n").map { RecentProjects.shellQuote(String($0)) }.joined(separator: " "))
              exit 1
            fi
            echo "✔ Test breaks() passed after 0.010 seconds."; echo "✔ Test run with 2 tests passed after 0.020 seconds."
            """], in: root, "the suite")
    }

    /// Each run's line; `first`: only the first runs (a rerun's line has --filter).
    func ran(first: Bool = false) -> [String] {
        let lines = ((try? String(contentsOfFile: runs, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        return first ? lines.filter { !$0.contains("--filter") } : lines
    }

    /// A lead on a repository with the fake suite (`suite`: its script in place of `fakeSuite`'s), merge_policy auto,
    /// the records kept local (no commits of theirs on main), and `settings` besides.
    func team(_ settings: [String: Any] = [:], suite: String? = nil) throws -> (root: String, runtime: FakeRuntime, lead: LeadToolset) {
        let root = try repo()
        if let suite { try commit(["scripts/test.sh": suite], in: root, "the suite") } else { try fakeSuite(root) }
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.power = { nil }
        // Room for five tasks' workers and verifiers.
        lead.macLimits = { MacLimits(maxSessions: 12) }
        var all: [String: Any] = ["test_command": "bash scripts/test.sh", "merge_policy": "auto", "records_dir": ""]
        all.merge(settings) { $1 }
        let set = lead.call("configure", all)
        #expect(!set.isError, "\(set.text)")
        return (root, runtime, lead)
    }

    /// `slug`'s worker started with `files` committed on its branch, reported done, and its audit passed.
    func audited(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String, _ slug: String, _ files: [String: String], review: String = "audit") throws {
        let added = lead.call("add_task", ["title": slug, "goal": "g", "acceptance": ["a"], "review": review, "auto_advance": true])
        #expect(!added.isError, "\(added.text)")
        let start = lead.call("start_worker", ["task": slug])
        #expect(!start.isError, "\(start.text)")
        try commit(files, in: Worktrees.path(root: root, slug: slug), "\(slug)'s work")
        #expect(!(try seat("worker-\(slug)", runtime).call("report", doneReport("done"))).isError)
        guard review == "audit" else { return }
        let audit = lead.call("audit", ["task": slug])
        #expect(!audit.isError, "\(audit.text)")
        let verdict = try seat("verify-\(slug)", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "tests": "passed", "summary": "ok"])
        #expect(!verdict.isError, "\(verdict.text)")
    }

    func board(_ root: String) -> LeadBoard { BoardStore(root: root).load() }

    /// The base's commit subjects since the first, oldest first, the suite's own left out.
    func landed(_ root: String) -> [String] {
        Git.run(["log", "--reverse", "--format=%s", "main"], in: root).output.split(separator: "\n").map(String.init)
            .filter { !["first", "the suite"].contains($0) }
    }

    func mergeLines(_ folder: URL) throws -> [MergeSample] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("merges-") }.sorted()
        return try files.flatMap { name in
            try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8).split(separator: "\n")
                .map { try decoder.decode(MergeSample.self, from: Data($0.utf8)) }
        }
    }

    // MARK: The setting

    @Test func mergeBatchingReadsOffBoostOrAlwaysAndAnythingElseIsOff() {
        #expect(LeadWorkflow.parse("---\ntest_command: x\n---").mergeBatching == .off)
        #expect(LeadWorkflow.parse("---\nmerge_batching: always\n---").mergeBatching == .always)
        #expect(LeadWorkflow.parse("---\nmerge_batching: Boost\n---").mergeBatching == .boost)
        #expect(LeadWorkflow.parse("---\nmerge_batching: sometimes\n---").mergeBatching == .off)
        #expect(LeadWorkflow.parse(LeadWorkflow.template).mergeBatching == .off)
        #expect(LeadVault.guardedKeys.contains("merge_batching"))
    }

    @Test func configureSetsMergeBatchingAndBoostBatchesOnlyWhileBoosting() throws {
        let (_, _, lead) = try team()
        #expect(lead.call("configure", ["merge_batching": "often"]).isError)
        let set = lead.call("configure", ["merge_batching": "boost"])
        #expect(!set.isError, "\(set.text)")
        #expect(set.text.contains("- merge_batching: boost (while Boost mode is on"), "\(set.text)")
        #expect(!lead.batching(lead.workflow))
        lead.boosting = { true }
        #expect(lead.batching(lead.workflow))
        #expect(!lead.call("configure", ["merge_batching": "always"]).isError)
        lead.boosting = { false }
        #expect(lead.batching(lead.workflow))
    }

    // MARK: One run for the batch

    /// merge_batching always: three tasks ready together merge on one test run, each its commits on main in order, each
    /// its own merge on the board (`onto` the one before) and its own line in the merge stats.
    @Test func threeReadyTasksMergeOnOneTestRunInOrder() throws {
        let (root, runtime, lead) = try team(["merge_batching": "always"])
        let stats = temp.url("stats")
        lead.mergeStats = { stats }
        lead.batchSize = 3
        let before = Git.run(["rev-parse", "main"], in: root).output
        for (slug, file) in [("add-x", "x.txt"), ("add-y", "y.txt"), ("add-z", "z.txt")] {
            try audited(lead, runtime, root: root, slug, [file: "\(slug)\n"])
        }
        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        #expect(advancing.until { ["add-x", "add-y", "add-z"].allSatisfy { board(root).task($0)?.status == .done } })

        #expect(ran().count == 1, "\(ran())")
        #expect(ran().first?.contains("x.txt y.txt z.txt") == true, "\(ran())")
        #expect(landed(root) == ["add-x's work", "add-y's work", "add-z's work"])
        let tasks = ["add-x", "add-y", "add-z"].compactMap { board(root).task($0) }
        #expect(tasks.map { $0.merged?.onto } == [before, tasks[0].merged?.commit, tasks[1].merged?.commit])
        #expect(tasks[2].merged?.commit == Git.run(["rev-parse", "main"], in: root).output)
        #expect(tasks.allSatisfy { $0.merged?.batch == ["add-x", "add-y", "add-z"] && $0.receipt?.commits == 1 })
        let lines = try mergeLines(stats)
        #expect(lines.map(\.task) == ["add-x", "add-y", "add-z"])
        #expect(Set(lines.compactMap(\.batch)).count == 1 && lines.allSatisfy { $0.batchRuns == 1 && $0.batchTasks == 3 && $0.result == "passed" }, "\(lines)")
        let progress = try String(contentsOfFile: lead.store.recordPath("progress.md"), encoding: .utf8)
        #expect(["add-x", "add-y", "add-z"].allSatisfy { progress.contains("Merged \($0): \($0) (in a batch: add-x, add-y, add-z landed on one test run)") }, "\(progress)")
        #expect(advancing.until { reports(runtime).contains { $0.contains("as one batch, on 1 test run for 3 tasks") } }, "\(reports(runtime))")
        // Revert takes back one task's commits only.
        let reverted = lead.call("revert", ["task": "add-y", "reason": "y broke"])
        #expect(!reverted.isError, "\(reverted.text)")
        #expect(FileManager.default.fileExists(atPath: root + "/x.txt") && !FileManager.default.fileExists(atPath: root + "/y.txt")
                && FileManager.default.fileExists(atPath: root + "/z.txt"))
    }

    /// Fewer than batch_size ready: they wait for the window, then merge together (a look again is armed for its end).
    @Test func readyTasksWaitForTheWindowThenMergeTogether() throws {
        let (root, runtime, lead) = try team(["merge_batching": "always"])
        let clock = Clock()
        lead.batchClock = { clock.now }
        let wakes = Wakes()
        lead.usageWake = { date, body in wakes.add(date, body) }
        for (slug, file) in [("add-x", "x.txt"), ("add-y", "y.txt")] {
            try audited(lead, runtime, root: root, slug, [file: "\(slug)\n"])
        }
        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        #expect(advancing.until { wakes.count > 0 })
        advancing.settle()
        #expect(ran().isEmpty && board(root).task("add-x")?.status == .review)
        let wake = try #require(wakes.first)
        #expect(abs(wake.date.timeIntervalSince(clock.now) - lead.batchWindow - 1) < 0.5)
        clock.now = clock.now.addingTimeInterval(lead.batchWindow)
        wake.body()
        #expect(advancing.until { board(root).task("add-y")?.status == .done })
        #expect(ran().count == 1 && board(root).task("add-x")?.merged?.batch == ["add-x", "add-y"])
    }

    /// merge_batching off (the default): each merges on a run of its own, as before.
    @Test func withBatchingOffEachMergesOnItsOwnRun() throws {
        let (root, runtime, lead) = try team()
        for (slug, file) in [("add-x", "x.txt"), ("add-y", "y.txt")] {
            try audited(lead, runtime, root: root, slug, [file: "\(slug)\n"])
        }
        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        #expect(advancing.until { board(root).task("add-y")?.status == .done && board(root).task("add-x")?.status == .done })
        #expect(ran().count == 2)
        #expect(board(root).task("add-x")?.merged?.batch == nil)
    }

    /// Tasks merge refuses (waiting on the user's approval) don't take a batch's places: the one behind them merges.
    @Test func tasksRefusedAtTheGateDontHoldBackTheOnesBehindThem() throws {
        let (root, runtime, lead) = try team(["merge_batching": "always", "merge_policy": "ask_sensitive"])
        lead.batchSize = 2
        // No wait: what's ready merges at once (all three, before the fix: a batch of the two refused, and nothing ran).
        lead.batchWindow = 0
        try audited(lead, runtime, root: root, "rules", ["AGENTS.md": "rules\n"])
        try audited(lead, runtime, root: root, "more-rules", ["CLAUDE.md": "more\n"])
        try audited(lead, runtime, root: root, "add-z", ["z.txt": "zed\n"])
        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        #expect(advancing.until { board(root).task("add-z")?.status == .done })
        #expect(board(root).task("rules")?.status == .review && board(root).task("more-rules")?.status == .review)
        #expect(advancing.until { reports(runtime).contains { $0.contains("Didn't merge rules: Not merged yet: the merge policy is ask_sensitive") } }, "\(reports(runtime))")
    }

    // MARK: Split on failure

    /// One task of four breaks the suite: the split finds it in log2(4) = 2 more runs, the two before it land, it goes
    /// back to its worker with its failing output, and the one after it lands on a run of its own.
    @Test func aBreakerIsFoundInLog2NRunsAndTheOthersMerge() throws {
        let (root, runtime, lead) = try team(["merge_batching": "always"])
        lead.batchSize = 4
        for (slug, file) in [("add-w", "w.txt"), ("add-x", "x.txt"), ("add-break", "break.txt"), ("add-z", "z.txt")] {
            try audited(lead, runtime, root: root, slug, [file: "\(slug)\n"])
        }
        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        #expect(advancing.until { board(root).task("add-z")?.status == .done && board(root).task("add-break")?.status != .review })

        // The whole stack, then prefixes of 2 (passes) and 3 (fails), then add-z alone on the new main.
        let first = ran(first: true)
        #expect(first.count == 4, "\(ran())")
        #expect(first[0].contains("break.txt") && !first[1].contains("break.txt") && first[2].contains("break.txt") && !first[3].contains("break.txt"), "\(first)")
        #expect(first[3].contains("w.txt x.txt z.txt"), "\(first)")
        #expect(landed(root) == ["add-w's work", "add-x's work", "add-z's work"])
        let breaker = try #require(board(root).task("add-break"))
        // Failed, then back at work once its worker has the output.
        #expect([.failed, .running].contains(breaker.status) && breaker.merged == nil && breaker.setback?.stage == .merge && breaker.setback?.reason.contains("breaks()") == true, "\(String(describing: breaker.setback))")
        #expect(board(root).task("add-w")?.merged?.batch == ["add-w", "add-x"] && board(root).task("add-z")?.merged?.batch == nil)
        #expect(advancing.until { toWorker("add-break", root, runtime).contains { $0.contains("Failing tests (1): breaks()") && $0.contains("the stack without it passes") } },
                "\(toWorker("add-break", root, runtime))")
    }

    /// After a split, the tasks restacked for the next run are checked again as merge checks them: one whose branch
    /// moved during the first run (a commit its verifier never saw) is refused, not landed at the commit it had then.
    /// The breaker, first on the stack, is told it fails on main with it on top (no stack without it passed).
    @Test func tasksRestackedAfterASplitAreCheckedAgainBeforeTheyLand() throws {
        let moved = temp.url("moved").path
        let root = try repo()
        let zTree = Worktrees.path(root: root, slug: "add-z")
        // The first run, besides failing, commits once more on add-z's branch.
        try commit(["scripts/test.sh": """
            #!/bin/bash
            echo "run $* | $(ls *.txt | tr '\\n' ' ')" >> \(RecentProjects.shellQuote(runs))
            if [[ ! -e \(RecentProjects.shellQuote(moved)) ]]; then
              touch \(RecentProjects.shellQuote(moved))
              (cd \(RecentProjects.shellQuote(zTree)) && echo more >> z.txt && git add z.txt && git commit -q -m "more z")
            fi
            if [[ -e break.txt ]]; then
              printf '%s\\n' \(Self.failure.split(separator: "\n").map { RecentProjects.shellQuote(String($0)) }.joined(separator: " "))
              exit 1
            fi
            echo "✔ Test run with 2 tests passed after 0.020 seconds."
            """], in: root, "the suite")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        lead.macLimits = { MacLimits(maxSessions: 12) }
        #expect(!lead.call("configure", ["test_command": "bash scripts/test.sh", "merge_policy": "auto", "auto_advance": false, "records_dir": ""]).isError)
        try audited(lead, runtime, root: root, "add-break", ["break.txt": "b\n"])
        try audited(lead, runtime, root: root, "add-z", ["z.txt": "zed\n"])

        let merged = lead.call("merge", ["tasks": ["add-break", "add-z"]])
        #expect(merged.isError, "nothing merged: \(merged.text)")
        #expect(merged.text.contains("add-z: not merged.") && merged.text.contains("has commits the verifier didn't see"), "\(merged.text)")
        #expect(merged.text.contains("It was tested in a batch, first on the stack: it fails on main with it on top."), "\(merged.text)")
        #expect(!merged.text.contains("the stack without it passes"), "\(merged.text)")
        #expect(landed(root).isEmpty)
        #expect(ran(first: true).count == 2, "the whole stack, then add-break alone: \(ran())")
        #expect(board(root).task("add-z")?.status == .review && board(root).task("add-break")?.status == .failed)
    }

    /// A batch failing on a test that passes its rerun merges on the rerun, flake recorded once, and isn't split.
    @Test func aFlakeInTheBatchMergesOnTheRerunWithoutSplitting() throws {
        let root = try repo()
        // Fails on the first run in a fresh scratch home, passes on the rerun in the same one.
        try fakeSuite(root, fails: "[[ ! -e \"$HOME/ran\" ]] && touch \"$HOME/ran\"")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["test_command": "bash scripts/test.sh", "merge_policy": "auto", "auto_advance": false, "records_dir": ""]).isError)
        for (slug, file) in [("add-x", "x.txt"), ("add-y", "y.txt"), ("add-z", "z.txt")] {
            try audited(lead, runtime, root: root, slug, [file: "\(slug)\n"])
        }
        let merged = lead.call("merge", ["tasks": ["add-x", "add-y", "add-z"]])
        #expect(!merged.isError, "\(merged.text)")
        #expect(ran() == ["run  | a.txt c.txt x.txt y.txt z.txt ", #"run --filter /breaks\(\)(/|$) | a.txt c.txt x.txt y.txt z.txt "#], "\(ran())")
        #expect(merged.text.contains("recorded once in the flake ledger (under add-z)"), "\(merged.text)")
        #expect(landed(root) == ["add-x's work", "add-y's work", "add-z's work"])
        let flakes = board(root).flakes ?? []
        #expect(flakes.count == 1 && flakes.first?.test == "breaks()" && flakes.first?.task == "add-z", "\(flakes)")
        #expect(board(root).task("add-x")?.receipt?.mergeReruns == 1)
    }

    // MARK: Conflicts

    /// A task that doesn't apply on the stack is left out, failed, told to merge main; the rest merge on one run.
    @Test func aTaskThatDoesntApplyOnTheStackIsLeftOutAndToldToMergeMain() throws {
        let (root, runtime, lead) = try team(["auto_advance": false])
        try audited(lead, runtime, root: root, "edit-c", ["c.txt": "sea\n"])
        try audited(lead, runtime, root: root, "edit-c-too", ["c.txt": "sí\n"])
        try audited(lead, runtime, root: root, "add-z", ["z.txt": "zed\n"])
        let merged = lead.call("merge", ["tasks": ["edit-c", "edit-c-too", "add-z"]])
        #expect(!merged.isError, "\(merged.text)")
        #expect(merged.text.contains("edit-c-too: failed. edit-c-too conflicts with main with the batch's tasks before it (edit-c) on it, so it was left out of the batch. Message its worker to bring its branch up to date by merging"), "\(merged.text)")
        #expect(ran().count == 1)
        #expect(landed(root) == ["edit-c's work", "add-z's work"])
        let left = try #require(board(root).task("edit-c-too"))
        #expect(left.status == .failed && left.setback?.reason == "Conflicts with main: the branch needs bringing up to date.")
    }

    // MARK: Every guard, per task

    /// Each task is checked as merge checks it alone: kept, an open Important finding, a missing audit and a missing
    /// approval of a sensitive change each keep their task out, as they stay; the one that passes them merges.
    @Test func everyGuardMergeHasHoldsForEachTaskOfABatch() throws {
        let (root, runtime, lead) = try team(["auto_advance": false, "merge_policy": "ask_sensitive"])
        try audited(lead, runtime, root: root, "add-x", ["x.txt": "x\n"])
        try audited(lead, runtime, root: root, "held", ["h.txt": "h\n"])
        #expect(!lead.call("update_task", ["task": "held", "status": "kept", "reason": "the user wants it later"]).isError)
        // An open Important finding.
        let added = lead.call("add_task", ["title": "found", "goal": "g", "acceptance": ["a"], "review": "audit"])
        #expect(!added.isError)
        #expect(!lead.call("start_worker", ["task": "found"]).isError)
        try commit(["f.txt": "f\n"], in: Worktrees.path(root: root, slug: "found"), "found's work")
        #expect(!(try seat("worker-found", runtime).call("report", doneReport("done"))).isError)
        #expect(!lead.call("audit", ["task": "found"]).isError)
        let finding: [String: Any] = ["id": "F1", "severity": "Important", "file": "f.txt", "line": 1, "evidence": "f.txt says f",
                                      "failure_scenario": "cat f.txt gives f where the contract wants g"]
        let verdict = try seat("verify-found", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "tests": "passed", "summary": "one",
                                                                                "findings": [finding]])
        #expect(!verdict.isError, "\(verdict.text)")
        // Reported done, never audited.
        try audited(lead, runtime, root: root, "unaudited", ["u.txt": "u\n"], review: "none")
        #expect(!lead.call("update_task", ["task": "unaudited", "review": "audit"]).isError)
        // Touches AGENTS.md (sensitive): audited, but the user hasn't approved the commit.
        try audited(lead, runtime, root: root, "sensitive", ["AGENTS.md": "rules\n"])

        let merged = lead.call("merge", ["tasks": ["add-x", "held", "found", "unaudited", "sensitive"]])
        #expect(!merged.isError, "\(merged.text)")
        #expect(landed(root) == ["add-x's work"])
        #expect(ran().count == 1)
        #expect(merged.text.contains("held: not merged. Not merged: held is kept unmerged (the user wants it later)"), "\(merged.text)")
        #expect(merged.text.contains("found: not merged. Not merged: found has 1 open Important finding"), "\(merged.text)")
        #expect(merged.text.contains("unaudited: not merged.") && merged.text.contains("has no passing audit"), "\(merged.text)")
        #expect(merged.text.contains("sensitive: not merged. Not merged yet: the merge policy is ask_sensitive, so the user approves sensitive"), "\(merged.text)")
        let after = board(root)
        #expect(after.task("held")?.status == .kept && after.task("found")?.status != .done && after.task("unaudited")?.status == .review
                && after.task("sensitive")?.status == .review && after.task("add-x")?.status == .done, "\(after.tasks.map { ($0.slug, $0.status) })")
    }

    // MARK: Failing closed

    /// A batch whose tests hang stops: nothing lands, each stays as it was, and auto_advance merges them one at a time.
    @Test func aHungBatchLeavesEachAsItWasAndTheyMergeOneAtATime() throws {
        let hung = temp.url("hung").path
        // The first run hangs (the batch's); every later one passes.
        let (root, runtime, lead) = try team(["merge_batching": "always", "test_timeout_min": "0.05"], suite: """
            #!/bin/bash
            echo "run $* | $(ls *.txt | tr '\\n' ' ')" >> \(RecentProjects.shellQuote(runs))
            if [[ ! -e \(RecentProjects.shellQuote(hung)) ]]; then touch \(RecentProjects.shellQuote(hung)); exec sleep 600; fi
            echo "✔ Test run with 1 test passed after 0.020 seconds."
            """)
        lead.batchSize = 2
        for (slug, file) in [("add-x", "x.txt"), ("add-y", "y.txt")] {
            try audited(lead, runtime, root: root, slug, [file: "\(slug)\n"])
        }
        let advancing = LeadAdvanceTests.Advancing(lead)
        defer { advancing.stop() }
        #expect(advancing.until { board(root).task("add-y")?.status == .done && board(root).task("add-x")?.status == .done })
        #expect(reports(runtime).contains { $0.contains("The batch of add-x, add-y stopped short: the test command hung") && $0.contains("merge one at a time from here") },
                "\(reports(runtime))")
        // The hung batch's run, then one of each.
        #expect(ran().count == 3, "\(ran())")
        #expect(board(root).task("add-x")?.merged?.batch == nil && board(root).task("add-y")?.merged?.batch == nil)
        #expect(landed(root) == ["add-x's work", "add-y's work"])
    }

    func reports(_ runtime: FakeRuntime) -> [String] {
        runtime.calls.lock()
        defer { runtime.calls.unlock() }
        return runtime.steered.filter { $0.text.hasPrefix("VibeSwitcher moved finished work on by itself") }.map(\.text)
    }

    func toWorker(_ slug: String, _ root: String, _ runtime: FakeRuntime) -> [String] {
        guard let worker = board(root).task(slug)?.worker else { return [] }
        runtime.calls.lock()
        defer { runtime.calls.unlock() }
        return runtime.steered.filter { $0.target == worker }.map(\.text)
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date()
        var now: Date {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    final class Wakes: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(date: Date, body: @Sendable () -> Void)] = []
        func add(_ date: Date, _ body: @escaping @Sendable () -> Void) { lock.lock(); list.append((date, body)); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return list.count }
        var first: (date: Date, body: @Sendable () -> Void)? { lock.lock(); defer { lock.unlock() }; return list.first }
    }
}
