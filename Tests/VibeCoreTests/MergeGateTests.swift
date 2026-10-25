import Foundation
import Testing
@testable import VibeCore

/// The merge gate's one rerun of failing tests, its flake ledger, and the catch-up message a merge sends to running
/// branches it overlaps (see `MergeRerun`, `LeadBoard.recordFlakes`, `LeadToolset.tellToCatchUp`).
struct MergeGateTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    /// The fake test command's log of its runs (one line each: its arguments), outside every worktree.
    let runs: String
    init() {
        vault = Self.newVault(in: temp)
        runs = temp.url("runs.log").path
    }

    static let failure = """
        ✘ Test flaky() recorded an issue at FlakyTests.swift:3:5: Expectation failed: ready
        ✘ Test flaky() failed after 0.010 seconds with 1 issue.
        ✘ Test run with 2 tests failed after 0.020 seconds with 1 issue.
        """

    // MARK: What reruns

    @Test func onlyACommandThatEndsInSwiftTestsOptionsIsFiltered() {
        for command in ["bash scripts/test.sh", "scripts/test.sh", "./scripts/test.sh --skip Bench", "swift test", "swift build && swift test --parallel"] {
            #expect(MergeRerun.filterable(command), "\(command)")
        }
        for command in ["make test", "bash scripts/test.sh; echo done", "swift test | tee log", "npm test", "bash scripts/test.sh\nrm x", "swift test > out", "pytest"] {
            #expect(!MergeRerun.filterable(command), "\(command)")
        }
    }

    @Test func aFilteredRerunNamesTheFailingTestsThenRunsRegressionCommand() throws {
        var workflow = LeadWorkflow()
        workflow.testCommand = "bash scripts/test.sh"
        workflow.regressionCommand = "make corpus"
        let output = Self.failure + "\n✘ Test param(n:) recorded an issue with 1 argument n → 2 at P.swift:1:1: x\n"
        let plan = try #require(MergeRerun.plan(after: output, workflow: workflow))
        #expect(plan.filtered)
        #expect(plan.tests == ["flaky()", "param(n:)"])
        #expect(plan.command.contains(#"bash scripts/test.sh --filter '/flaky\(\)(/|$)|/param\(n:\)(/|$)'"#), "\(plan.command)")
        #expect(plan.command.contains("make corpus") && plan.command.contains(LeadWorkflow.regressionMarker), "\(plan.command)")
    }

    /// A run that crashed (a test started and never ended) stopped partway: the tests after the crash never ran, so a
    /// rerun of the failing ones alone would merge what only part of the suite checked. It all runs again.
    @Test func aRunThatCrashedPartwayRerunsWhole() throws {
        var workflow = LeadWorkflow()
        workflow.testCommand = "bash scripts/test.sh"
        workflow.regressionCommand = "make corpus"
        let output = Self.failure + "\n◇ Test crashed() started.\nFatal error: Unexpectedly found nil\n"
        let plan = try #require(MergeRerun.plan(after: output, workflow: workflow))
        #expect(!plan.filtered)
        #expect(plan.tests == ["flaky()", "crashed()"])
        #expect(!plan.command.contains("--filter") && plan.command.contains("bash scripts/test.sh"), "\(plan.command)")
        #expect(plan.command.contains("make corpus"), "\(plan.command)")
        // Its rerun is a whole one: it counts on passing, without naming each test.
        #expect(MergeRerun.unshown(plan, rerun: "✔ Test run with 1956 tests passed after 190 seconds.").isEmpty)
        // Crashed with nothing else failing by name: still whole.
        let alone = try #require(MergeRerun.plan(after: "◇ Test crashed() started.\nFatal error: boom", workflow: workflow))
        #expect(!alone.filtered && alone.tests == ["crashed()"] && alone.command == "{\nbash scripts/test.sh\n} && {\necho '\(LeadWorkflow.regressionMarker)'\nmake corpus\n}")
    }

    @Test func anotherCommandRerunsWholeAndSomeFailuresDontRerun() throws {
        var workflow = LeadWorkflow()
        workflow.testCommand = "make test"
        let whole = try #require(MergeRerun.plan(after: Self.failure, workflow: workflow))
        #expect(!whole.filtered && whole.command == "make test" && whole.tests == ["flaky()"])
        // Naming no test (leftover processes, a web test): the whole command again.
        workflow.testCommand = "bash scripts/test.sh"
        let unnamed = try #require(MergeRerun.plan(after: "LEFTOVER PROCESSES: the run left these running", workflow: workflow))
        #expect(!unnamed.filtered && unnamed.tests.isEmpty && unnamed.command == "bash scripts/test.sh")
        // A build error fails again; a failing regression_command isn't retried.
        #expect(MergeRerun.plan(after: "/r/Sources/A.swift:3:1: error: cannot find 'x' in scope", workflow: workflow) == nil)
        #expect(MergeRerun.plan(after: "ok\n\(LeadWorkflow.regressionMarker)\ncase 3 failed", workflow: workflow) == nil)
        // More failing tests than a filter names: the whole command.
        let many = (1...25).map { "✘ Test t\($0)() failed after 0.1 seconds with 1 issue." }.joined(separator: "\n")
        #expect(MergeRerun.plan(after: many, workflow: workflow)?.filtered == false)
    }

    @Test func aFilteredRerunCountsOnlyWhenItShowsEachTestPassing() throws {
        var workflow = LeadWorkflow()
        workflow.testCommand = "swift test"
        let plan = try #require(MergeRerun.plan(after: Self.failure, workflow: workflow))
        #expect(MergeRerun.unshown(plan, rerun: "✔ Test run with 0 tests passed after 0.001 seconds.") == ["flaky()"])
        #expect(MergeRerun.unshown(plan, rerun: "✔ Test flaky() passed after 0.2 seconds.\n✔ Test run with 1 test passed").isEmpty)
        // A pass with a known issue is a pass, ✘ as piped output marks it.
        #expect(MergeRerun.unshown(plan, rerun: "✘ Test flaky() passed after 0.2 seconds with 1 known issue.").isEmpty)
    }

    /// Tests that pass with a known issue (`withKnownIssue`), ✘ in piped output, are neither failing nor unfinished:
    /// the rerun is of the one that failed, filtered (lead-team-panel-clear's reran the whole suite for four of them).
    @Test func aPassWithAKnownIssueIsntRerun() throws {
        var workflow = LeadWorkflow()
        workflow.testCommand = "bash scripts/test.sh"
        let output = """
            ◇ Test aFailingSceneIsEnded() started.
            ✘ Test aFailingSceneIsEnded() recorded a known issue at TestHostsTests.swift:63:23: Caught error: Failure()
            ✘ Test aFailingSceneIsEnded() passed after 1.365 seconds with 1 known issue.
            """ + "\n" + Self.failure
        let plan = try #require(MergeRerun.plan(after: output, workflow: workflow))
        #expect(plan.tests == ["flaky()"])
        #expect(plan.filtered)
    }

    // MARK: The ledger

    @Test func aTestThatFlakesThreeTimesInAWeekIsDueOnce() {
        var board = LeadBoard()
        let day = 86_400.0, start = 1_000_000.0
        // One flake eight days ago is out of the window.
        #expect(board.recordFlakes(["flaky()"], task: "old", commit: "c0", now: start).isEmpty)
        #expect(board.recordFlakes(["flaky()", "other()"], task: "one", commit: "c1", now: start + 8 * day).isEmpty)
        #expect(board.recordFlakes(["flaky()"], task: "two", commit: "c2", now: start + 9 * day).isEmpty)
        let due = board.recordFlakes(["flaky()"], task: "three", commit: "c3", now: start + 10 * day)
        #expect(due.map(\.test) == ["flaky()"] && due.first?.merges == ["one", "two", "three"])
        board.notePlanned("fix-the-flaky-test-flaky", for: "flaky()")
        // The next flake doesn't plan another; three more after the planned one do.
        #expect(board.recordFlakes(["flaky()"], task: "four", commit: "c4", now: start + 10 * day + 1).isEmpty)
        #expect(board.recordFlakes(["flaky()"], task: "five", commit: "c5", now: start + 10 * day + 2).isEmpty)
        #expect(board.recordFlakes(["flaky()"], task: "six", commit: "c6", now: start + 10 * day + 3).map(\.test) == ["flaky()"])
        // Unnamed failures are recorded and plan nothing.
        for n in 0..<3 { #expect(board.recordFlakes([MergeRerun.unnamed], task: "u\(n)", commit: "u", now: start + 10 * day + 4).isEmpty) }
        let line = try? #require(board.flakeLine(now: start + 10 * day + 5))
        #expect(line?.contains("flaky() ×6 (one, two, three, four, five, six) → task fix-the-flaky-test-flaky") == true, "\(line ?? "")")
        #expect(line?.contains("other() ×1 (one)") == true)
        #expect(LeadBoard().flakeLine(now: start) == nil)
    }

    // MARK: Merges

    func repo() throws -> String {
        let url = temp.url("gate")
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
        #expect(Git.run(["commit", "-q", "-m", message], in: dir).ok)
    }

    func ran() -> [String] {
        ((try? String(contentsOfFile: runs, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// A fake scripts/test.sh, committed: it logs its arguments, and fails naming flaky() unless `passes` (a shell
    /// condition) holds.
    func fakeSuite(_ root: String, passes: String) throws {
        try commit(["scripts/test.sh": """
            #!/bin/bash
            echo "run $*" >> \(RecentProjects.shellQuote(runs))
            if \(passes); then echo "✔ Test flaky() passed after 0.010 seconds."; echo "✔ Test run with 1 test passed"; exit 0; fi
            printf '%s\\n' \(Self.failure.split(separator: "\n").map { RecentProjects.shellQuote(String($0)) }.joined(separator: " "))
            exit 1
            """], in: root, "the suite")
    }

    func configure(_ lead: LeadToolset, _ settings: [String: Any]) {
        let set = lead.call("configure", settings)
        #expect(!set.isError, "\(set.text)")
    }

    /// `slug`'s task (adding `files` on its branch) taken to a passing audit.
    func audited(_ lead: LeadToolset, _ runtime: FakeRuntime, root: String, slug: String = "add-b", files: [String: String] = ["b.txt": "bee\n"]) throws {
        try started(lead, root: root, slug: slug, files: files)
        #expect(!(try seat("worker-\(slug)", runtime).call("report", doneReport("done"))).isError)
        let audit = lead.call("audit", ["task": slug])
        #expect(!audit.isError, "\(audit.text)")
        let verdict = try seat("verify-\(slug)", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "tests": "passed", "summary": "ok"])
        #expect(!verdict.isError, "\(verdict.text)")
    }

    /// `slug`'s worker started, with `files` committed on its branch.
    func started(_ lead: LeadToolset, root: String, slug: String, files: [String: String]) throws {
        let added = lead.call("add_task", ["title": slug, "goal": "g", "acceptance": ["a"]])
        #expect(!added.isError, "\(added.text)")
        let start = lead.call("start_worker", ["task": slug])
        #expect(!start.isError, "\(start.text)")
        try commit(files, in: Worktrees.path(root: root, slug: slug), "\(slug)'s work")
    }

    @Test func aRunThatFailsOnceThenPassesItsRerunMergesAndIsRecorded() throws {
        let root = try repo()
        // Fails on the first run in a scratch home, passes on the second in the same one.
        try fakeSuite(root, passes: "[[ -e \"$HOME/ran\" ]] || { touch \"$HOME/ran\"; false; }")
        // Not filterable (scripts/run.sh), so it runs whole.
        try commit(["scripts/run.sh": "#!/bin/bash\nexec bash scripts/test.sh \"$@\"\n"], in: root, "a runner")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let regression = temp.url("regression.log").path
        configure(lead, ["test_command": "bash scripts/run.sh", "regression_command": "echo ran >> \(RecentProjects.shellQuote(regression))"])
        try audited(lead, runtime, root: root)

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(merged.text.contains("Its first test run failed on flaky() and the rerun of the whole test command passed"), "\(merged.text)")
        #expect(ran() == ["run ", "run "])
        // regression_command ran once, after the rerun: never skipped.
        #expect(try String(contentsOfFile: regression, encoding: .utf8) == "ran\n")
        let board = BoardStore(root: root).load()
        #expect(board.task("add-b")?.status == .done)
        let flake = try #require(board.flakes?.first)
        #expect(board.flakes?.count == 1 && flake.test == "flaky()" && flake.task == "add-b" && flake.commit == board.task("add-b")?.merged?.commit)
        let status = lead.call("status", [:]).text
        #expect(status.contains("Flaky tests in the last 7 days (1 flake: each failed a merge's test run, passed its rerun"), "\(status)")
        #expect(status.contains("flaky() ×1 (add-b)"), "\(status)")
        let log = vault.scratch(root: root, "add-b/merge-test.log")
        let saved = try String(contentsOf: log, encoding: .utf8)
        #expect(saved.contains("✘ Test flaky() recorded an issue") && saved.contains(Worktrees.rerunHeader), "\(saved)")
    }

    @Test func aFilteredRerunRunsOnlyTheFailingTests() throws {
        let root = try repo()
        try fakeSuite(root, passes: "[[ \"$*\" == *--filter* ]]")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        configure(lead, ["test_command": "bash scripts/test.sh"])
        try audited(lead, runtime, root: root)

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(merged.text.contains("the rerun of those tests passed"), "\(merged.text)")
        #expect(ran() == ["run ", #"run --filter /flaky\(\)(/|$)"#])
    }

    @Test func aFilteredRerunThatRanNoTestDoesntMerge() throws {
        let root = try repo()
        // With a filter it passes having run nothing.
        try commit(["scripts/test.sh": """
            #!/bin/bash
            echo "run $*" >> \(RecentProjects.shellQuote(runs))
            [[ "$*" == *--filter* ]] && { echo "✔ Test run with 0 tests passed after 0.001 seconds."; exit 0; }
            printf '%s\\n' \(Self.failure.split(separator: "\n").map { RecentProjects.shellQuote(String($0)) }.joined(separator: " "))
            exit 1
            """], in: root, "the suite")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        configure(lead, ["test_command": "bash scripts/test.sh"])
        try audited(lead, runtime, root: root)

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError)
        #expect(merged.text.contains("didn't show flaky() passing"), "\(merged.text)")
        #expect(ran().count == 2)
        #expect(!FileManager.default.fileExists(atPath: root + "/b.txt"))
        #expect(BoardStore(root: root).load().task("add-b")?.status == .failed)
        #expect(BoardStore(root: root).load().flakes == nil)
    }

    @Test func aRunThatFailsTwiceIsRefusedWithTheRerunsOutputAndRerunsOnce() throws {
        let root = try repo()
        try fakeSuite(root, passes: "false")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        configure(lead, ["test_command": "bash scripts/test.sh"])
        try audited(lead, runtime, root: root)

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError)
        let lines = merged.text.components(separatedBy: "\n")
        #expect(lines.first == "The test command fails on add-b rebased onto main, and again on its rerun (run once, after the first run failed).", "\(merged.text)")
        #expect(lines.dropFirst().first == "Failing tests (1): flaky()")
        #expect(ran() == ["run ", #"run --filter /flaky\(\)(/|$)"#])
        let saved = try String(contentsOf: vault.scratch(root: root, "add-b/merge-test.log"), encoding: .utf8)
        #expect(saved.hasPrefix(Worktrees.rerunHeader), "\(saved.prefix(300))")
        let board = BoardStore(root: root).load()
        #expect(board.task("add-b")?.status == .failed && board.flakes == nil)
        #expect(!FileManager.default.fileExists(atPath: root + "/b.txt"))
    }

    @Test func aBuildErrorIsntRerun() throws {
        let root = try repo()
        try commit(["scripts/test.sh": "#!/bin/bash\necho \"run $*\" >> \(RecentProjects.shellQuote(runs))\necho '/r/Sources/A.swift:3:1: error: cannot find x in scope'\nexit 1\n"],
                   in: root, "the suite")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        configure(lead, ["test_command": "bash scripts/test.sh"])
        try audited(lead, runtime, root: root)
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError && merged.text.hasPrefix("The test command fails on add-b rebased onto main.\n"), "\(merged.text)")
        #expect(ran() == ["run "])
    }

    @Test func aTestsThirdFlakeInAWeekPlansOneTaskToFixIt() throws {
        let root = try repo()
        try fakeSuite(root, passes: "[[ \"$*\" == *--filter* ]]")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        configure(lead, ["test_command": "bash scripts/test.sh"])
        let now = Date().timeIntervalSince1970
        try BoardStore(root: root).update { board in
            board.flakes = [LeadFlake(test: "flaky()", task: "earlier", commit: "c1", at: now - 3 * 86_400),
                            LeadFlake(test: "flaky()", task: "later", commit: "c2", at: now - 86_400)]
        }
        try audited(lead, runtime, root: root)

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        let board = BoardStore(root: root).load()
        let fixes = board.tasks.filter { $0.title.hasPrefix("Fix the flaky test") }
        let fix = try #require(fixes.first)
        #expect(fixes.count == 1)
        #expect(merged.text.contains("flaky() flaked 3 times within 7 days: planned \(fix.slug) to fix it."), "\(merged.text)")
        #expect(fix.status == .planned && fix.title == "Fix the flaky test flaky()")
        #expect(fix.contract.context.contains("earlier, later, add-b"), "\(fix.contract.context)")
        #expect(board.flakes?.last?.planned == fix.slug)
        let progress = try String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)
        #expect(progress.contains("Planned \(fix.slug): flaky() flaked 3 times within 7 days"), "\(progress)")
    }

    // MARK: Catching up

    @Test func aMergeTellsOnlyTheRunningBranchesItOverlapsToMergeTheBaseNow() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        configure(lead, ["test_command": "true", "max_workers": 3])
        // Running meanwhile: one branch changes a.txt too, the other only c.txt.
        try started(lead, root: root, slug: "edit-a", files: ["a.txt": "one, edited\n"])
        try started(lead, root: root, slug: "edit-c", files: ["c.txt": "see, edited\n"])
        try audited(lead, runtime, root: root, files: ["a.txt": "one, the merge's\n", "b.txt": "bee\n"])
        let board = BoardStore(root: root).load()
        let (overlapping, apart) = (try #require(board.task("edit-a")?.worker), try #require(board.task("edit-c")?.worker))
        let before = runtime.steered.count

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        let sent = runtime.steered.dropFirst(before).filter { $0.text.contains("just moved") }
        #expect(sent.count == 1, "\(sent.map(\.text))")
        #expect(sent.first?.target == overlapping)
        #expect(sent.first?.text.contains("main just moved: add-b merged, and it changed files your branch changes too: a.txt.") == true, "\(sent.first?.text ?? "")")
        #expect(sent.first?.text.contains("`git merge main`") == true)
        #expect(!runtime.steered.contains { $0.target == apart && $0.text.contains("just moved") })
        #expect(merged.text.contains("their workers were told to merge main now: edit-a (a.txt): Its worker was sent this."), "\(merged.text)")
        #expect(!merged.text.contains("edit-c"))
    }
}
