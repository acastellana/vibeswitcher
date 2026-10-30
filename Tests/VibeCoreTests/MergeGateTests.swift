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

    @Test func eachFailingTestsLinesAreKeptMaskedAndCapped() {
        let output = """
            ◇ Test flaky() started.
            ✘ Test flaky() recorded an issue at FlakyTests.swift:3:5: Expectation failed: (header → "X-Auth: Bearer abc123def456") == nil
            ↳ waited for the reply
            ✔ Test steady() passed after 0.001 seconds.
            ✘ Test param(n:) recorded an issue with 1 argument n → 2 at ParamTests.swift:9:7: Expectation failed: eventually {
                n == 3
            }
            \u{1B}[1;31m✘\u{1B}[0m Test flaky() failed after 0.010 seconds with 1 issue.
            /r/Tests/OldTests.swift:12: error: -[VibeCoreTests.OldTests testIt] : XCTAssertEqual failed: ("1") is not equal to ("2")
            Test Case '-[VibeCoreTests.OldTests testIt]' failed (0.002 seconds).
            ✘ Test run with 4 tests failed after 0.020 seconds with 3 issues.
            """
        let evidence = MergeRerun.evidence(in: output, tests: ["flaky()", "param(n:)", "OldTests.testIt", "crashed()"])
        #expect(evidence["flaky()"] == [#"✘ Test flaky() recorded an issue at FlakyTests.swift:3:5: Expectation failed: (header → "X-Auth: Bearer •••") == nil"#,
                                        "↳ waited for the reply", "✘ Test flaky() failed after 0.010 seconds with 1 issue."], "\(evidence)")
        #expect(evidence["param(n:)"] == ["✘ Test param(n:) recorded an issue with 1 argument n → 2 at ParamTests.swift:9:7: Expectation failed: eventually {",
                                          "    n == 3", "}"], "\(evidence)")
        #expect(evidence["OldTests.testIt"]?.count == 2, "\(evidence)")
        // A test with no line of its own (one that crashed) is left out, and so is one that isn't asked for.
        #expect(evidence["crashed()"] == nil && evidence["steady()"] == nil)

        // At most `evidenceLimit` lines a test, the last saying how many more; each line cut short.
        let many = (1...30).map { "✘ Test many() recorded an issue at ManyTests.swift:\($0):1: " + String(repeating: "x", count: 500) }
        let kept = MergeRerun.evidence(in: many.joined(separator: "\n"), tests: ["many()"])["many()"] ?? []
        #expect(kept.count == MergeRerun.evidenceLimit && kept.last == "… and 11 more lines.", "\(kept.last ?? "")")
        #expect(kept.first?.count == MergeRerun.evidenceWidth && kept.first?.hasSuffix("…") == true)
    }

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
    func fakeSuite(_ root: String, passes: String, test: String = "flaky()") throws {
        try commit(["scripts/test.sh": """
            #!/bin/bash
            echo "run $*" >> \(RecentProjects.shellQuote(runs))
            if \(passes); then echo "✔ Test \(test) passed after 0.010 seconds."; echo "✔ Test run with 1 test passed"; exit 0; fi
            printf '%s\\n' \(Self.failure.replacingOccurrences(of: "flaky()", with: test).split(separator: "\n").map { RecentProjects.shellQuote(String($0)) }.joined(separator: " "))
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

    /// A first run that crashed: what it named failing is a flake, and so is the crash (`unnamed`), but the tests that
    /// were only running when it crashed aren't: on 2026-10-30 one crash logged 200 and more of them, and planned fix
    /// tasks for six tests that had never failed (aFailingTestsHostIsEnded among them).
    @Test func aCrashedRunsUnfinishedTestsArentFlakes() throws {
        let root = try repo()
        let crashed = Self.failure.components(separatedBy: "\n").dropLast().joined(separator: "\n") + """

            ◇ Test bystander() started.
            ◇ Test aFailingTestsHostIsEnded() started.
            Fatal error: Unexpectedly found nil while unwrapping an Optional value
            error: Exited with unexpected signal code 5
            """
        // Crashes on the first run in a scratch home, passes on the second (a whole one) in the same one.
        try commit(["scripts/test.sh": """
            #!/bin/bash
            echo "run $*" >> \(RecentProjects.shellQuote(runs))
            if [[ -e "$HOME/ran" ]]; then echo "✔ Test run with 4 tests passed"; exit 0; fi
            touch "$HOME/ran"
            printf '%s\\n' \(crashed.split(separator: "\n").map { RecentProjects.shellQuote(String($0)) }.joined(separator: " "))
            exit 1
            """], in: root, "the suite")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        configure(lead, ["test_command": "bash scripts/test.sh"])
        try audited(lead, runtime, root: root)

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(ran() == ["run ", "run "])
        let board = BoardStore(root: root).load()
        #expect(board.flakes?.map(\.test) == ["flaky()", MergeRerun.unnamed])
        #expect(!merged.text.contains("bystander()") && !merged.text.contains("aFailingTestsHostIsEnded()"), "\(merged.text)")
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
            // A finished task naming it doesn't count: only an open one stands in for the fix.
            var old = LeadTask(slug: "steady-flaky", title: "Steady flaky()", contract: LeadContract(goal: "flaky() passes", acceptance: [], boundaries: [], context: ""))
            old.status = .done
            board.tasks.append(old)
        }
        try audited(lead, runtime, root: root)

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        let board = BoardStore(root: root).load()
        let fixes = board.tasks.filter { $0.title.hasPrefix("Fix the flaky test") }
        let fix = try #require(fixes.first)
        #expect(fixes.count == 1)
        #expect(board.task("steady-flaky")?.contract.context == "")
        #expect(merged.text.contains("flaky() flaked 3 times within 7 days: planned \(fix.slug) to fix it."), "\(merged.text)")
        #expect(fix.status == .planned && fix.title == "Fix the flaky test flaky()")
        #expect(fix.contract.context.contains("earlier, later, add-b"), "\(fix.contract.context)")
        #expect(board.flakes?.last?.planned == fix.slug)
        let progress = try String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)
        #expect(progress.contains("Planned \(fix.slug): flaky() flaked 3 times within 7 days"), "\(progress)")
    }

    @Test func aFlakysFailingLinesAreReadableInTheRepositoryTheLedgerAndTheFixTasksContext() throws {
        let root = try repo()
        let failure = """
            ✘ Test flaky() recorded an issue at FlakyTests.swift:3:5: Expectation failed: (header → "X-Auth: Bearer abc123def456") == nil
            ↳ waited for the reply
            ✘ Test flaky() failed after 0.010 seconds with 1 issue.
            ✘ Test run with 2 tests failed after 0.020 seconds with 1 issue.
            """
        try commit(["scripts/test.sh": """
            #!/bin/bash
            echo "run $*" >> \(RecentProjects.shellQuote(runs))
            [[ "$*" == *--filter* ]] && { echo "✔ Test flaky() passed after 0.010 seconds."; exit 0; }
            printf '%s\\n' \(failure.split(separator: "\n").map { RecentProjects.shellQuote(String($0)) }.joined(separator: " "))
            exit 1
            """], in: root, "the suite")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        configure(lead, ["test_command": "bash scripts/test.sh"])
        let now = Date().timeIntervalSince1970
        // Yesterday's merge's evidence file, named as before the merge's commit was in the name.
        let earlier = root + "/.vibeswitcher/flakes/2026-10-27-later.log"
        try FileManager.default.createDirectory(atPath: (earlier as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try MergeRerun.evidenceLog(task: "later", commit: "c2", evidence: ["flaky()": ["✘ Test flaky() failed after 9.000 seconds with 1 issue."]], tests: ["flaky()"])
            .write(toFile: earlier, atomically: true, encoding: .utf8)
        try BoardStore(root: root).update { board in
            // An older entry, from before the ledger kept evidence, and one whose file keeps it.
            board.flakes = [LeadFlake(test: "flaky()", task: "earlier", commit: "c1", at: now - 3 * 86_400),
                            LeadFlake(test: "flaky()", task: "later", commit: "c2", at: now - 86_400, log: earlier)]
        }
        try audited(lead, runtime, root: root)

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        let lines = [#"✘ Test flaky() recorded an issue at FlakyTests.swift:3:5: Expectation failed: (header → "X-Auth: Bearer •••") == nil"#,
                     "↳ waited for the reply", "✘ Test flaky() failed after 0.010 seconds with 1 issue."]
        let board = BoardStore(root: root).load()
        let flake = try #require(board.flakes?.last)
        #expect(flake.task == "add-b", "\(flake)")
        // In the repository's ignored folder, private, named by the day, the task and the merge's commit.
        // The ledger keeps it relative to the root.
        let kept = try #require(flake.log)
        #expect(kept == MergeRerun.evidencePath(task: "add-b", commit: flake.commit, at: Date(timeIntervalSince1970: flake.at)))
        #expect(kept.range(of: #"^\.vibeswitcher/flakes/\d{4}-\d{2}-\d{2}-add-b-[0-9a-f]{8}\.log$"#, options: .regularExpression) != nil, "\(kept)")
        #expect(kept.hasSuffix("-add-b-\(flake.commit.prefix(8)).log"), "\(kept)")
        let log = root + "/" + kept
        #expect(log == MergeRerun.evidenceFile(root: root, task: "add-b", commit: flake.commit, at: Date(timeIntervalSince1970: flake.at)).path)
        #expect(MergeRerun.evidence(for: "flaky()", inLog: log) == lines)
        let text = try String(contentsOfFile: log, encoding: .utf8)
        #expect(text.contains("\nflaky()\n" + lines.map { "    " + $0 }.joined(separator: "\n")), "\(text)")
        #expect(!text.contains("abc123def456"))
        let mode = { (path: String) in (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1 }
        #expect(mode(log) == 0o600 && mode((log as NSString).deletingLastPathComponent) == 0o700)
        #expect(Git.run(["check-ignore", "-q", log], in: root).ok)
        #expect(merged.text.contains("Each flaky test's failing lines, readable by its fixer: \(log)."), "\(merged.text)")
        // The fix task quotes each merge's lines it has, under where they're kept.
        let fix = try #require(board.tasks.first { $0.title.hasPrefix("Fix the flaky test") })
        let context = fix.contract.context
        #expect(context.contains("- later's merge (\(earlier)):\n    ✘ Test flaky() failed after 9.000 seconds"), "\(context)")
        #expect(context.contains("- add-b's merge (\(log)):\n" + lines.map { "    " + $0 }.joined(separator: "\n")), "\(context)")
        #expect(!context.contains("earlier's merge") && !context.contains("abc123def456"), "\(context)")
    }

    @Test func twoMergesOfOneTaskOnOneDayLeaveTwoEvidenceFiles() throws {
        let root = try repo()
        try fakeSuite(root, passes: "[[ \"$*\" == *--filter* ]]")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        configure(lead, ["test_command": "bash scripts/test.sh"])
        try audited(lead, runtime, root: root)
        let first = lead.call("merge", ["task": "add-b"])
        #expect(!first.isError, "\(first.text)")
        // Its work goes on after the merge (as after a set-back), and merges again the same day.
        try BoardStore(root: root).update { board in
            let index = try #require(board.taskIndex("add-b"))
            board.tasks[index].status = .running
            board.tasks[index].merged = nil
        }
        try commit(["d.txt": "dee\n"], in: Worktrees.path(root: root, slug: "add-b"), "more of add-b's work")
        #expect(!(try seat("worker-add-b", runtime).call("report", doneReport("done"))).isError)
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        let verdict = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "tests": "passed", "summary": "ok"])
        #expect(!verdict.isError, "\(verdict.text)")
        let second = lead.call("merge", ["task": "add-b"])
        #expect(!second.isError, "\(second.text)")

        let flakes = (BoardStore(root: root).load().flakes ?? []).filter { $0.task == "add-b" }
        #expect(flakes.count == 2, "\(flakes)")
        let logs = flakes.compactMap(\.log).map { MergeRerun.evidenceFile(root: root, log: $0) }
        #expect(logs.count == 2 && Set(logs).count == 2, "\(logs)")
        let folder = root + "/.vibeswitcher/flakes"
        let files = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".log") }
        #expect(files.count == 2, "\(files)")
        for (flake, log) in zip(flakes, logs) {
            #expect(log.hasSuffix("-add-b-\(flake.commit.prefix(8)).log"), "\(log)")
            #expect(MergeRerun.evidence(for: "flaky()", inLog: log)?.first?.hasPrefix("✘ Test flaky() recorded an issue") == true)
        }
    }

    @Test func twoHundredFlakesWithEvidenceKeepTheBoardSmallAndTheFixQuotesTheirFiles() throws {
        let root = try repo()
        let store = BoardStore(root: root)
        var board = LeadBoard()
        let now = Date().timeIntervalSince1970
        // The most a test's evidence keeps: `evidenceLimit` lines of `evidenceWidth` characters.
        let lines = MergeRerun.capped((1...30).map { "✘ Test SomeLongerSuiteName.aTestWithARatherLongDescriptiveName() recorded an issue at File.swift:\($0):1: " + String(repeating: "x", count: 500) })
        var due: [(test: String, merges: [String], flakes: [LeadFlake])] = []
        for n in 0..<LeadBoard.keptFlakes {
            let test = "SomeLongerSuiteName.aTestWithARatherLongDescriptiveName\(n % 60)()"
            let task = "a-task-with-a-long-enough-slug-\(n)"
            let commit = String(repeating: String(format: "%08x", n), count: 5)
            let file = MergeRerun.evidenceFile(root: root, task: task, commit: commit, at: Date(timeIntervalSince1970: now))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try MergeRerun.evidenceLog(task: task, commit: commit, evidence: [test: lines], tests: [test]).write(to: file, atomically: true, encoding: .utf8)
            due += board.recordFlakes([test], task: task, commit: commit, now: now + Double(n), logged: [test],
                                      log: MergeRerun.evidencePath(task: task, commit: commit, at: Date(timeIntervalSince1970: now)))
        }
        try store.update { $0.flakes = board.flakes }
        let flakes = try #require(store.load().flakes)
        #expect(flakes.count == LeadBoard.keptFlakes && flakes.allSatisfy { $0.log != nil })
        let size = try #require(try FileManager.default.attributesOfItem(atPath: store.file)[.size] as? Int)
        #expect(size < 100_000, "board.json is \(size) bytes")

        // A fix task's context still quotes each merge's lines, read from its file.
        let last = try #require(due.last)
        let context = MergeRerun.fixContract(test: last.test, flakes: last.flakes, workflow: LeadWorkflow(), root: root).context
        for flake in last.flakes {
            #expect(context.contains("- \(flake.task)'s merge (\(root)/\(try #require(flake.log))):\n" + lines.map { "    " + $0 }.joined(separator: "\n")), "\(context)")
        }
        let note = MergeRerun.flakeNote(test: last.test, flakes: last.flakes, root: root)
        #expect(note.contains(lines[0]) && note.contains(lines[lines.count - 1]), "\(note)")
        // A file that's gone is said so, and quotes nothing.
        let first = MergeRerun.evidenceFile(root: root, log: try #require(last.flakes[0].log))
        try FileManager.default.removeItem(atPath: first)
        let gone = MergeRerun.fixContract(test: last.test, flakes: last.flakes, workflow: LeadWorkflow(), root: root).context
        #expect(gone.contains("- \(last.flakes[0].task)'s merge (\(first)): (its file can't be read now)"), "\(gone)")
    }

    @Test func anEvidenceFileThatIsntAPlainFileQuotesNothingAndDoesntBlock() throws {
        let root = try repo()
        let folder = root + "/.vibeswitcher/flakes"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // A FIFO in the file's place: opening it to read waits for a writer unless it's opened without blocking.
        let fifo = folder + "/2026-10-28-add-b-0123abcd.log"
        #expect(mkfifo(fifo, 0o600) == 0)
        let read = DispatchSemaphore(value: 0)
        let found = Locked<[String]?>(["unread"])
        Thread.detachNewThread {
            found.set(MergeRerun.evidence(for: "flaky()", inLog: fifo))
            read.signal()
        }
        // Waits on the read itself; the bound is only for failing: a writer then frees the blocked read.
        let returned = read.wait(timeout: .now() + 60) == .success
        if !returned {
            let writer = open(fifo, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
            read.wait()
        }
        #expect(returned, "reading a FIFO blocked")
        #expect(found.get() == nil)
        // A symbolic link is refused too.
        let target = folder + "/real.log"
        try MergeRerun.evidenceLog(task: "t", commit: "c", evidence: ["flaky()": ["✘ secret line"]], tests: ["flaky()"]).write(toFile: target, atomically: true, encoding: .utf8)
        let link = folder + "/2026-10-28-add-b-4567cdef.log"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(MergeRerun.evidence(for: "flaky()", inLog: target) == ["✘ secret line"])
        #expect(MergeRerun.evidence(for: "flaky()", inLog: link) == nil)
    }

    @Test func aBoardWhoseFlakesKeptTheirLinesDecodesAndDropsThemOnTheNextWrite() throws {
        let root = try repo()
        let store = BoardStore(root: root)
        try store.update { $0.flakes = [] }
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: store.file))) as? [String: Any])
        json["flakes"] = [["test": "flaky()", "task": "old", "commit": "c1", "at": 1_000_000.0, "planned": "fix-it",
                           "lines": ["✘ Test flaky() failed after 9.000 seconds with 1 issue."], "log": root + "/.vibeswitcher/flakes/2026-10-27-old.log"]]
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: store.file))

        #expect(store.load().flakes == [LeadFlake(test: "flaky()", task: "old", commit: "c1", at: 1_000_000, planned: "fix-it",
                                                  log: root + "/.vibeswitcher/flakes/2026-10-27-old.log")])
        try store.update { _ in }
        let written = try String(contentsOfFile: store.file, encoding: .utf8)
        #expect(!written.contains("\"lines\"") && !written.contains("9.000 seconds"), "\(written)")
        #expect(written.contains("2026-10-27-old.log") && store.load().flakes?.first?.planned == "fix-it")
    }

    @Test func aThirdFlakeOfATestAnOpenTaskNamesGoesInThatTasksContextNotANewTask() throws {
        let test = "onlyTheFocusedVisiblePaneSetsTheClipboardLive()"
        let root = try repo()
        try fakeSuite(root, passes: "[[ \"$*\" == *--filter* ]]", test: test)
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        configure(lead, ["test_command": "bash scripts/test.sh"])
        let now = Date().timeIntervalSince1970
        try BoardStore(root: root).update { board in
            board.flakes = [LeadFlake(test: test, task: "earlier", commit: "c1", at: now - 3 * 86_400),
                            LeadFlake(test: test, task: "later", commit: "c2", at: now - 86_400)]
            // In review already, naming the test by its bare name, as a lead writes it.
            var open = LeadTask(slug: "terminal-clipboard-security", title: "Terminal clipboard security",
                                contract: LeadContract(goal: "Only the focused pane sets the clipboard; onlyTheFocusedVisiblePaneSetsTheClipboardLive stops flaking",
                                                       acceptance: [], boundaries: [], context: "What it knew."))
            open.status = .review
            board.tasks.append(open)
        }
        try audited(lead, runtime, root: root)

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        let board = BoardStore(root: root).load()
        #expect(!board.tasks.contains { $0.title.hasPrefix("Fix the flaky test") }, "\(board.tasks.map(\.slug))")
        let open = try #require(board.task("terminal-clipboard-security"))
        #expect(open.status == .review)
        #expect(open.contract.context.hasPrefix("What it knew.\n\nFlake ledger: \(test) flaked 3 times within 7 days"), "\(open.contract.context)")
        #expect(open.contract.context.contains("earlier, later, add-b"), "\(open.contract.context)")
        #expect(open.contract.context.contains("- add-b's merge (") && open.contract.context.contains("\n    ✘ Test \(test) recorded an issue at FlakyTests.swift:3:5"),
                "\(open.contract.context)")
        #expect(board.flakes?.last?.planned == open.slug)
        #expect(merged.text.contains("\(test) flaked 3 times within 7 days: the open task terminal-clipboard-security names it"), "\(merged.text)")
        let progress = try String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)
        #expect(progress.contains("Noted in terminal-clipboard-security's context"), "\(progress)")
        #expect(!progress.contains("Planned fix-the-flaky-test"), "\(progress)")
    }

    @Test func anOpenTaskNamesATestInItsTitleOrGoalAsAWholeName() {
        func task(_ slug: String, title: String = "Something", goal: String, _ status: LeadTask.Status) -> LeadTask {
            var task = LeadTask(slug: slug, title: title, contract: LeadContract(goal: goal, acceptance: [], boundaries: [], context: ""))
            task.status = status
            return task
        }
        var board = LeadBoard()
        board.tasks = [task("merged", goal: "loginShellIsRead() passes", .done),
                       task("longer", goal: "loginShellIsReadTwice stops flaking", .planned),
                       task("short", goal: "a test that waits", .planned)]
        // Finished, or only a longer name: nothing names it.
        #expect(board.openTask(naming: "loginShellIsRead()") == nil)
        // A short bare name counts only in full; the unnamed flake names nothing.
        #expect(board.openTask(naming: "test()") == nil)
        #expect(board.openTask(naming: MergeRerun.unnamed) == nil)
        for status in [LeadTask.Status.planned, .running, .review, .blocked] {
            board.tasks.append(task("open-\(status.rawValue)", title: "Fix loginShellIsRead", goal: "", status))
            #expect(board.openTask(naming: "loginShellIsRead()")?.slug == "open-\(status.rawValue)")
            board.tasks.removeLast()
        }
        board.tasks.append(task("legacy", goal: "LegacyTests.testFailsOnLinux, in full", .running))
        #expect(board.openTask(naming: "LegacyTests.testFailsOnLinux")?.slug == "legacy")
        #expect(board.openTask(naming: "Other.testFailsOnLinux")?.slug == "legacy")
        #expect(board.openTask(naming: "test()") == nil)
    }

    // MARK: A hung run

    @Test func aHungRunsUnfinishedTestsAreTheOnesThatStartedAndNeverEnded() {
        let output = """
            ◇ Test run started.
            ◇ Test passes() started.
            ◇ Test fails() started.
            ◇ Test skips() started.
            ◇ Test hangs() started.
            ◇ Test "Some words" started.
            \u{1B}[1;32m✔\u{1B}[0m Test passes() passed after 0.001 seconds.
            ✘ Test fails() recorded an issue at F.swift:1:1: Expectation failed: x
            ✘ Test fails() failed after 0.002 seconds with 1 issue.
            ➜ Test skips() skipped: "not here"
            ✘ Test known() passed after 0.003 seconds with 1 known issue.
            Test Case '-[VibeCoreTests.OldTests testDone]' started.
            Test Case '-[VibeCoreTests.OldTests testDone]' passed (0.001 seconds).
            Test Case '-[VibeCoreTests.OldTests testHangs]' started.
            ✔ Test run with 5 tests passed after 0.004 seconds.
            """
        #expect(MergeRerun.hung(in: output) == ["hangs()", "\"Some words\"", "OldTests.testHangs"], "\(MergeRerun.hung(in: output))")
        #expect(MergeRerun.hung(in: Self.failure).isEmpty)
        #expect(MergeRerun.hung(in: "").isEmpty)
    }

    @Test func aHungRunsFileListsItsUnfinishedTestsAndItsTailMaskedAndCut() {
        let filler: String = (1...80).map { "filler \($0)" }.joined(separator: "\n")
        let wide: String = String(repeating: "y", count: 900)
        let output: String = filler + "\n" + """
            -----BEGIN RSA PRIVATE KEY-----
            MIIEowIBAAKCAQEAsecretkeybodyline1
            MIIEowIBAAKCAQEAsecretkeybodyline2
            -----END RSA PRIVATE KEY-----
            ◇ Test hangs() started.
            waiting with X-Auth: Bearer abc123def456
            """ + "\n" + wide + "\n\n\n"
        let text = MergeRerun.hungLog(task: "add-b", commit: "0123456789abcdef", command: "test command", after: 180, output: output)
        #expect(text.hasPrefix("Hung in add-b's merge (tested 0123456789ab): its test command ran past test_timeout_min (3 min) and was stopped"), "\(text)")
        #expect(text.contains("\nStarted and never finished (secrets masked):\n    hangs()\n"), "\(text)")
        // The last 60 lines, trailing blank ones left out (the key masked to one): filler 25 on.
        #expect(text.contains("Its output's last 60 lines"), "\(text)")
        #expect(text.contains("\n    filler 25\n") && !text.contains("\n    filler 24\n"), "\(text)")
        #expect(text.contains("X-Auth: Bearer •••") && !text.contains("abc123def456"), "\(text)")
        // A key masked whole, though only part of it might have been in the tail.
        #expect(!text.contains("secretkeybody"), "\(text)")
        #expect(text.contains("    " + String(repeating: "y", count: MergeRerun.evidenceWidth - 1) + "…\n"), "\(text)")
        #expect(text.hasSuffix(String(repeating: "y", count: MergeRerun.evidenceWidth - 1) + "…\n"))
        let none = MergeRerun.hungLog(task: "add-b", commit: "0123", command: "init_command", after: 3, output: "building\n")
        #expect(none.contains("its init_command ran past") && none.contains("No test in its output started and never finished."), "\(none)")
        #expect(MergeRerun.hungPath(task: "add-b", commit: "0123456789", at: Date(timeIntervalSince1970: 0))
                    .range(of: #"^\.vibeswitcher/flakes/19(69|70)-\d{2}-\d{2}-add-b-01234567-hung\.log$"#, options: .regularExpression) != nil)
    }

    /// The tests a hung merge left started and never finished, and its output's tail, in a file every session can read
    /// (the merge's log is in the vault); the reply and the progress log name them.
    @Test func aHungMergeNamesTheTestsThatNeverFinishedInAReadableFile() throws {
        let root = try repo()
        let marks = temp.url("marks").path
        try FileManager.default.createDirectory(atPath: marks, withIntermediateDirectories: true)
        // Three tests start, two finish (one passing, one failing), and the third hangs till the merge stops it.
        try commit(["scripts/test.sh": """
            #!/bin/bash
            for i in $(seq 1 80); do echo "filler $i"; done
            echo "◇ Test run started."
            echo "◇ Test passes() started."
            echo "◇ Test fails() started."
            echo "◇ Test hangs() started."
            echo "✔ Test passes() passed after 0.001 seconds."
            echo "✘ Test fails() failed after 0.002 seconds with 1 issue."
            echo "hangs() waits with X-Auth: Bearer abc123def456"
            sleep \(ShellTests.childRuns) & echo $! > \(RecentProjects.shellQuote(marks))/child; wait
            """], in: root, "a suite that hangs")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        // 0.1 min: 6 s.
        configure(lead, ["test_command": "bash scripts/test.sh", "test_timeout_min": "0.1"])
        try audited(lead, runtime, root: root)
        let commit = Git.run(["rev-parse", "agent/add-b"], in: root).output

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError)
        #expect(merged.text.contains("the tests hung after 6 s") && merged.text.contains("Started and never finished: hangs()."), "\(merged.text)")
        let flakes = root + "/.vibeswitcher/flakes"
        let files = try FileManager.default.contentsOfDirectory(atPath: flakes)
        #expect(files.count == 1 && files.first?.hasSuffix("-add-b-\(commit.prefix(8))-hung.log") == true, "\(files)")
        let file = flakes + "/" + (files.first ?? "")
        #expect(merged.text.contains("Those and the output's last 60 lines, readable by the worker who fixes it: \(file)."), "\(merged.text)")
        let text = try String(contentsOfFile: file, encoding: .utf8)
        #expect(text.contains("\nStarted and never finished (secrets masked):\n    hangs()\n"), "\(text)")
        #expect(!text.contains("    passes()\n") && !text.contains("    fails()\n"), "\(text)")
        #expect(text.contains("\n    hangs() waits with X-Auth: Bearer •••\n") && !text.contains("abc123def456"), "\(text)")
        #expect(text.contains("\n    filler 80\n") && !text.contains("\n    filler 1\n"), "\(text)")
        let mode = { (path: String) in (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1 }
        #expect(mode(file) == 0o600 && mode(flakes) == 0o700)
        #expect(Git.run(["check-ignore", "-q", file], in: root).ok)
        let progress = try String(contentsOfFile: BoardStore(root: root).recordPath("progress.md"), encoding: .utf8)
        #expect(progress.contains("Hung in add-b's merge: the tests stopped after 6 s; started and never finished: hangs() (\(file))"), "\(progress)")
        // Not a failure of the work: the task stays as it was.
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        #expect(task.status == .review && task.setback == nil)
        let child = try #require(Int32((try String(contentsOfFile: marks + "/child", encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(eventually { kill(child, 0) != 0 })
    }

    @Test func aFailingOrPassingMergeWritesNoHungFile() throws {
        let root = try repo()
        let pass = temp.url("pass").path
        try fakeSuite(root, passes: "[[ -e \(RecentProjects.shellQuote(pass)) ]]")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        configure(lead, ["test_command": "bash scripts/test.sh", "max_workers": 2])
        try audited(lead, runtime, root: root)
        let hungFiles = { ((try? FileManager.default.contentsOfDirectory(atPath: root + "/.vibeswitcher/flakes")) ?? []).filter { $0.hasSuffix("-hung.log") } }

        // Fails, and its rerun fails too.
        let failed = lead.call("merge", ["task": "add-b"])
        #expect(failed.isError && !failed.text.contains("hung"), "\(failed.text)")
        #expect(hungFiles().isEmpty)
        // Passes.
        FileManager.default.createFile(atPath: pass, contents: nil)
        try audited(lead, runtime, root: root, slug: "add-c", files: ["c2.txt": "sea\n"])
        let merged = lead.call("merge", ["task": "add-c"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(hungFiles().isEmpty)
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
