import Foundation
import Testing
@testable import VibeCore

struct MergeRerunSelectionTests {
    static let inventory = ["Example.FinishedTests/steady()", "Example.UnfinishedTests/queuedOne()",
                            "Example.UnfinishedTests/queuedTwo()", "Example.NeverStartedTests/later()"]
    static let passing = """
        ✔ Test headlessAnswersQueriesOnlyWhenNoClient() passed after 0.1 seconds.
        ✔ Suite UnfinishedTests passed after 0.1 seconds.
        ✔ Suite NeverStartedTests passed after 0.1 seconds.
        ✔ Test run with 4 tests in 2 suites passed after 0.1 seconds.
        """
    static let stopped = """
        ◇ Test run started.
        ◇ Suite FinishedTests started.
        ◇ Suite UnfinishedTests started.
        ✔ Test steady() passed after 0.001 seconds.
        ✔ Suite FinishedTests passed after 0.002 seconds.
        ◇ Test queuedOne() started.
        ◇ Test queuedTwo() started.
        error: Exited with unexpected signal code 13
        """

    /// A whole run of this repository that failed on one test, as a merge saw it on 2026-11-18 (lines from its log,
    /// trimmed): every whole run has 4 tests that pass with known issues, marked ━, which its closing line counts.
    /// Parameterized cases print their start and no end when they pass.
    static let oneTestBesideKnownIssues = """
        ◇ Test run started.
        ◇ Suite BenchDefaultsTests started.
        ◇ Test aToolThatGivesNoAnswerIsEnded() started.
        ◇ Test everyBenchFlagInMainRunsOnScratchDefaults() started.
        ━ Test aToolThatGivesNoAnswerIsEnded() recorded a known issue at ParserCostTests.swift:52:36: Issue recorded
        ↳ /bin/sleep (pid 4187) gave no answer in 1 s and was ended.
        ━ Test aToolThatGivesNoAnswerIsEnded() passed after 31.085 seconds with 1 known issue.
        ━ Suite ParserCostTests passed after 31.098 seconds with 1 known issue.
        ━ Test aFailingTestsHostIsEnded() recorded a known issue at TestHostsTests.swift:39:29: Caught error: Failure()
        ↳ the body fails on purpose, its host still running
        ━ Test aFailingTestsHostIsEnded() passed after 45.278 seconds with 1 known issue.
        ◇ Test aCancelledTestsHostIsAskedToEndFirst() started.
        ━ Test noTestReadsTheMacsOwnFreeSpace() recorded a known issue at TestSupport.swift:26:21: Issue recorded
        ↳ the guard: a read of the volume itself is a failure
        ━ Test noTestReadsTheMacsOwnFreeSpace() passed after 122.854 seconds with 1 known issue.
        ━ Test aFailingSceneIsEnded() recorded a known issue at TestHostsTests.swift:80:29: Caught error: Failure()
        ━ Test aFailingSceneIsEnded() passed after 18.881 seconds with 1 known issue.
        ✘ Test everyBenchFlagInMainRunsOnScratchDefaults() recorded an issue at BenchDefaultsTests.swift:92:36: Expectation failed: BenchDefaults.flags.contains(flag)
        ↳ BenchDefaults.flags.contains(flag) → false
        ◇ Test case passing 3 arguments arguments → [], fault → "no-folder", why → "wallet-manager-testnet) is missing" to refusesBeforeAnyNetwork(_:_:_:) started.
        ✘ Test everyBenchFlagInMainRunsOnScratchDefaults() failed after 186.453 seconds with 1 issue.
        ✘ Suite BenchDefaultsTests failed after 186.480 seconds with 1 issue.
        ✔ Test aCancelledTestsHostIsAskedToEndFirst() passed after 186.521 seconds.
        ✘ Test run with 4493 tests in 619 suites failed after 614.743 seconds with 5 issues (including 4 known issues).
        Note: Some test targets reported failures:
          - VibeSwitcherPackageTests (Swift Testing)
        web tests: 7 of 7 passed
        """
    static let benchFlag = "everyBenchFlagInMainRunsOnScratchDefaults()"

    /// A run of this repository's suites stopped partway (shaped on a real one, killed 30 s in): `TestHomeGuardTests`
    /// and `LeadRotationToolGateTests` each exist in two modules and both started; a nested suite prints only its own
    /// label. Discovery lists a test whose name repeats with its source location.
    static let stoppedAcrossModules = """
        ◇ Test run started.
        ◇ Suite TestHomeGuardTests started.
        ◇ Suite LeadRotationToolGateTests started.
        ◇ Suite TestHomeGuardTests started.
        ◇ Suite TailscaleFakeTests started.
        ◇ Suite PhoneTailscaleFlowTests started.
        ◇ Suite LeadRotationToolGateTests started.
        ✔ Test theGuardRanAndTheRootIsntTheAccountsOwn() passed after 0.004 seconds.
        ✔ Test theRunReadsARoomyDiskNotTheMacs() passed after 0.004 seconds.
        ✔ Test theGuardRanAndTheRootIsntTheAccountsOwn() passed after 0.004 seconds.
        ✔ Test theRunReadsARoomyDiskNotTheMacs() passed after 3.002 seconds.
        ✔ Suite TestHomeGuardTests passed after 0.005 seconds.
        ✔ Test anActiveToolDoesNotRefuseAnotherToolAsARotation() passed after 0.079 seconds.
        ✔ Suite LeadRotationToolGateTests passed after 0.080 seconds.
        ✔ Suite TestHomeGuardTests passed after 3.003 seconds.
        ✔ Test aChangedNameOrLoginRestartsOnTheNewOne() passed after 0.5 seconds.
        ✔ Suite PhoneTailscaleFlowTests passed after 0.6 seconds.
        ◇ Test aRoutineContextReadDoesNotBlockLeadTools() started.
        ◇ Test fromOffToOnMapsThePort() started.
        """
    static let modules = [
        "VibeHostTests.TestHomeGuardTests/theGuardRanAndTheRootIsntTheAccountsOwn()/TestHomeGuardTests.swift:8:6",
        "VibeHostTests.TestHomeGuardTests/theRunReadsARoomyDiskNotTheMacs()/TestHomeGuardTests.swift:15:6",
        "VibeSwitcherTests.TestHomeGuardTests/theGuardRanAndTheRootIsntTheAccountsOwn()/TestHomeGuardTests.swift:8:6",
        "VibeSwitcherTests.TestHomeGuardTests/theRunReadsARoomyDiskNotTheMacs()/TestHomeGuardTests.swift:15:6",
        "VibeCoreTests.LeadRotationToolGateTests/anActiveToolDoesNotRefuseAnotherToolAsARotation()",
        "VibeSwitcherTests.LeadRotationToolGateTests/aRoutineContextReadDoesNotBlockLeadTools()",
        "VibeSwitcherTests.TailscaleFakeTests/PhoneTailscaleFlowTests/aChangedNameOrLoginRestartsOnTheNewOne()",
        "VibeSwitcherTests.TailscaleFakeTests/TailscaleCLITests/fromOffToOnMapsThePort()",
        "VibeSwitcherTests.NeverStartedTests/later()",
    ]
    static let modulesSkip = #"run --skip ^VibeHostTests\.TestHomeGuardTests(/|$)|^VibeSwitcherTests\.TailscaleFakeTests\/PhoneTailscaleFlowTests(/|$)|^VibeSwitcherTests\.TestHomeGuardTests(/|$)"#
    /// The continuation's run: each suite it ran passing, both `LeadRotationToolGateTests` among them.
    static let modulesResumed = """
        ✔ Test anActiveToolDoesNotRefuseAnotherToolAsARotation() passed after 0.1 seconds.
        ✔ Suite LeadRotationToolGateTests passed after 0.1 seconds.
        ✔ Test aRoutineContextReadDoesNotBlockLeadTools() passed after 0.1 seconds.
        ✔ Suite LeadRotationToolGateTests passed after 0.1 seconds.
        ✔ Suite TailscaleCLITests passed after 0.1 seconds.
        ✔ Suite TailscaleFakeTests passed after 0.1 seconds.
        ✔ Suite NeverStartedTests passed after 0.1 seconds.
        ✔ Test run with 4 tests in 5 suites passed after 0.2 seconds.
        """

    func resume(_ output: String, inventory: [String] = Self.inventory, again: String = Self.passing,
                expectMerge: Bool = true, rerunOK: Bool = true) throws -> (gate: MergeGateTests, root: String, lead: LeadToolset) {
        let gate = MergeGateTests()
        let root = try gate.repo()
        try gate.commit(["scripts/test.sh": """
            #!/bin/bash
            echo "run $*" >> \(RecentProjects.shellQuote(gate.runs))
            if [[ "$*" == *--list-tests* ]]; then
                printf '%s\\n' \(inventory.map(RecentProjects.shellQuote).joined(separator: " "))
                exit 0
            fi
            if [[ -e "$HOME/ran" ]]; then
                printf '%s\\n' \(again.components(separatedBy: "\n").map(RecentProjects.shellQuote).joined(separator: " "))
                exit \(rerunOK ? 0 : 1)
            fi
            touch "$HOME/ran"
            printf '%s\\n' \(output.components(separatedBy: "\n").map(RecentProjects.shellQuote).joined(separator: " "))
            exit 1
            """], in: root, "a suite stopped partway")
        let runtime = FakeRuntime()
        let lead = try gate.lead(root, runtime)
        gate.configure(lead, ["test_command": "bash scripts/test.sh"])
        try gate.audited(lead, runtime, root: root)
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(merged.isError != expectMerge, "\(merged.text)")
        return (gate, root, lead)
    }

    @Test func aStoppedRunSkipsOnlySuitesThatPassedInFull() throws {
        let (gate, root, lead) = try resume(Self.stopped)
        #expect(gate.ran().last == #"run --skip ^Example\.FinishedTests(/|$)"#)
        #expect(gate.ledger(root).reruns.first?.filtered == true)
        #expect(gate.ledger(root).reruns.first?.tests == [])
        #expect(gate.ledger(root).flakes.map(\.test) == [MergeRerun.unnamed])
        #expect(BoardStore(root: root).load().task("add-b")?.receipt?.mergeReruns == 1)
        #expect(lead.call("status", [:]).text.contains("Unfinished-suite reruns: 1 of 1 passed"))
    }

    @Test func aNamedFailureWithAnUnfinishedSuiteAlsoResumesTheRemainingSuites() throws {
        let output = Self.stopped + "\n" + MergeGateTests.failure
            .replacingOccurrences(of: "flaky()", with: "headlessAnswersQueriesOnlyWhenNoClient()")
            .components(separatedBy: "\n").dropLast().joined(separator: "\n")
        let (gate, root, _) = try resume(output)
        #expect(!MergeRerun.finished(output))
        #expect(gate.ran().last == #"run --skip ^Example\.FinishedTests(/|$)"#)
        #expect(gate.ledger(root).reruns.first?.filtered == true)
        #expect(gate.ledger(root).reruns.first?.tests == ["headlessAnswersQueriesOnlyWhenNoClient()"])
        #expect(gate.ledger(root).flakes.map(\.test) == ["headlessAnswersQueriesOnlyWhenNoClient()", MergeRerun.unnamed])
    }

    @Test func aFailingContinuationDoesNotMergeEvenWhenItsNamedFailureIsRedOnBase() throws {
        let output = Self.stopped + "\n" + MergeGateTests.failure.components(separatedBy: "\n").dropLast().joined(separator: "\n")
        let (gate, root, _) = try resume(output, again: MergeGateTests.failure, expectMerge: false, rerunOK: false)
        let record = try #require(gate.ledger(root).reruns.first)
        #expect(record.filtered && !record.passed && record.base == .red)
        #expect(gate.ledger(root).flakes.isEmpty)
        #expect(BoardStore(root: root).load().task("add-b")?.merged == nil)
        #expect(gate.ran().last == #"run --filter /flaky\(\)(/|$)"#)
    }

    @Test func aClosedNamedFailureRerunsOnlyThatTestAndRecordsIt() throws {
        let gate = MergeGateTests()
        let root = try gate.repo()
        let name = "headlessAnswersQueriesOnlyWhenNoClient()"
        try gate.fakeSuite(root, passes: "[[ \"$*\" == *--filter* ]]", test: name)
        let runtime = FakeRuntime()
        let lead = try gate.lead(root, runtime)
        gate.configure(lead, ["test_command": "bash scripts/test.sh"])
        try gate.audited(lead, runtime, root: root)
        #expect(!lead.call("merge", ["task": "add-b"]).isError)
        #expect(gate.ran() == ["run ", #"run --filter /headlessAnswersQueriesOnlyWhenNoClient\(\)(/|$)"#])
        let record = try #require(gate.ledger(root).reruns.first)
        #expect(record.filtered && record.passed && record.tests == [name])
        #expect(gate.ledger(root).flakes.map(\.test) == [name])
        #expect(BoardStore(root: root).load().task("add-b")?.receipt?.mergeReruns == 1)
    }

    // Two suites of the label in discovery, one started: which one passed can't be told, so neither is skipped, and
    // with nothing else provably complete the rerun is whole, saying why.
    @Test func aCompletedLabelThatDiscoveryCantPinFallsBackWithEvidenceAndAReason() throws {
        let (gate, root, lead) = try resume(Self.stopped, inventory: Self.inventory + ["Another.FinishedTests/other()"])
        let record = try #require(gate.ledger(root).reruns.first)
        #expect(!record.filtered)
        #expect(gate.ran().last == "run ")
        #expect(record.baseNote?.contains("Whole rerun:") == true)
        #expect(record.baseNote?.contains("no completed suite's ID could be told from discovery") == true)
        #expect(lead.call("status", [:]).text.contains("Whole rerun reasons:"))
        let logs = try FileManager.default.contentsOfDirectory(atPath: root + "/.vibeswitcher/flakes")
        let name = try #require(logs.first { $0.hasSuffix("-first-run.log") })
        let text = try String(contentsOfFile: root + "/.vibeswitcher/flakes/" + name, encoding: .utf8)
        #expect(text.contains("Whole rerun:") && text.contains("Suite FinishedTests passed") && text.contains("signal code 13"))
    }

    @Test func aContinuationThatRunsNoTestsDoesNotMerge() throws {
        let (gate, root, _) = try resume(Self.stopped, again: "✔ Test run with 0 tests passed after 0.001 seconds.", expectMerge: false)
        #expect(gate.ledger(root).reruns.map(\.passed) == [false])
        #expect(gate.ledger(root).flakes.isEmpty)
        #expect(BoardStore(root: root).load().task("add-b")?.merged == nil)
    }

    @Test func aLaterBundlesSummaryDoesNotFinishAnEarlierInterruptedBundle() throws {
        var workflow = LeadWorkflow()
        workflow.testCommand = "bash scripts/test.sh"
        let output = Self.stopped + "\n◇ Test run started.\n" + MergeGateTests.failure
        #expect(!MergeRerun.finished(output))
        #expect(MergeRerun.plan(after: output, workflow: workflow)?.filtered == false)
    }

    @Test func missingDiscoveryFallsBackToTheWholeCommand() throws {
        let (gate, root, _) = try resume(Self.stopped, inventory: [])
        let record = try #require(gate.ledger(root).reruns.first)
        #expect(!record.filtered && record.baseNote?.contains("discovery") == true)
    }

    @Test func firstFailureEvidenceKeepsABoundedMaskedTail() throws {
        let prefix = "X-Auth: Bearer abc123def456\n" + (0..<500).map { "old-line-\($0) " + String(repeating: "x", count: 1200) }.joined(separator: "\n")
        let (gate, root, _) = try resume(prefix + "\n" + Self.stopped + "\nX-Auth: Bearer abc123def456", inventory: [])
        let folder = root + "/.vibeswitcher/flakes"
        let name = try #require(FileManager.default.contentsOfDirectory(atPath: folder).first { $0.hasSuffix("-first-run.log") })
        let text = try String(contentsOfFile: folder + "/" + name, encoding: .utf8)
        #expect(text.count < 210_000)
        #expect(!text.contains("old-line-0 ") && !text.contains("abc123def456"))
        #expect(text.contains("X-Auth: Bearer •••"))
        #expect(text.contains("error: Exited with unexpected signal code 13"))
        #expect(gate.ledger(root).reruns.count == 1)
    }

    @Test func aFailingFilteredRerunStillRefusesTheMergeAndPairsOnBase() throws {
        let gate = MergeGateTests()
        try gate.aRunThatFailsTwiceIsRefusedWithTheRerunsOutputAndRerunsOnce()
    }

    // Why no merge rerun ran filtered over 2026-11-08..18 (29 of 29 whole): the closing line's issue count includes
    // known issues, whose lines no ✘ marks, so a run that ended on one named failure read as stopped partway.
    @Test func aWholeRunFailingOnOneTestBesideKnownIssuesRanToItsEnd() {
        var workflow = LeadWorkflow()
        workflow.testCommand = "bash scripts/test.sh"
        #expect(MergeRerun.finished(Self.oneTestBesideKnownIssues))
        let plan = MergeRerun.plan(after: Self.oneTestBesideKnownIssues, workflow: workflow)
        #expect(plan?.filtered == true)
        #expect(plan?.tests == [Self.benchFlag])
        #expect(plan?.note == nil)
        #expect(MergeRerun.flakes(in: Self.oneTestBesideKnownIssues) == [Self.benchFlag])
    }

    @Test func aMergeFailingOnOneTestBesideKnownIssuesRerunsOnlyThatTest() throws {
        let again = "✔ Test \(Self.benchFlag) passed after 1.2 seconds.\n✔ Test run with 1 test in 1 suite passed after 1.2 seconds."
        let (gate, root, lead) = try resume(Self.oneTestBesideKnownIssues, again: again)
        #expect(gate.ran() == ["run ", #"run --filter /everyBenchFlagInMainRunsOnScratchDefaults\(\)(/|$)"#])
        let record = try #require(gate.ledger(root).reruns.first)
        #expect(record.filtered && record.passed && record.tests == [Self.benchFlag])
        #expect(gate.ledger(root).flakes.map(\.test) == [Self.benchFlag])
        #expect(lead.call("status", [:]).text.contains("Filtered reruns (the failing tests only): 1 of 1 passed"))
    }

    @Test func aFilteredRerunThatFailsAgainStillRefusesTheMerge() throws {
        let again = MergeGateTests.failure.replacingOccurrences(of: "flaky()", with: Self.benchFlag)
        let (gate, root, _) = try resume(Self.oneTestBesideKnownIssues, again: again, expectMerge: false, rerunOK: false)
        #expect(gate.ran().contains(#"run --filter /everyBenchFlagInMainRunsOnScratchDefaults\(\)(/|$)"#))
        let record = try #require(gate.ledger(root).reruns.first)
        #expect(record.filtered && !record.passed)
        #expect(gate.ledger(root).flakes.isEmpty)
        #expect(BoardStore(root: root).load().task("add-b")?.merged == nil)
    }

    // A parameterized test's end names its cases: that name took a rerun whole on 2026-11-16 (no filter for it).
    @Test func aParameterizedFailureRerunsItsFunction() {
        let output = """
            ◇ Test run started.
            ✘ Test aFailedReadFallsBackOnTheParsersLines(hook:) recorded an issue with 1 argument hook → true at A.swift:3:5: Expectation failed
            ✘ Test aFailedReadFallsBackOnTheParsersLines(hook:) with 2 test cases failed after 0.4 seconds with 1 issue.
            ✘ Test run with 9 tests in 2 suites failed after 0.5 seconds with 1 issue.
            """
        var workflow = LeadWorkflow()
        workflow.testCommand = "bash scripts/test.sh"
        let plan = MergeRerun.plan(after: output, workflow: workflow)
        #expect(plan?.filtered == true)
        #expect(plan?.command.hasPrefix(#"bash scripts/test.sh --filter '/aFailedReadFallsBackOnTheParsersLines\(hook:\)(/|$)|"#) == true)
        let rerun = "✔ Test aFailedReadFallsBackOnTheParsersLines(hook:) with 2 test cases passed after 0.3 seconds."
        #expect(plan.map { MergeRerun.unshown($0, rerun: rerun) } == [])
        #expect(plan.map { MergeRerun.unshown($0, rerun: "✔ Test run with 0 tests passed after 0.1 seconds.").count } == 2)
    }

    // F1: suites of one name in two modules, and nested suites, are skipped by their module-qualified IDs when each
    // passed in full; a label that started twice and passed once runs again, and must pass as often as it started.
    @Test func aStoppedRunSkipsCompletedSuitesByModuleQualifiedID() throws {
        let (gate, root, lead) = try resume(Self.stoppedAcrossModules, inventory: Self.modules, again: Self.modulesResumed)
        #expect(gate.ran().last == Self.modulesSkip)
        let record = try #require(gate.ledger(root).reruns.first)
        #expect(record.filtered && record.passed)
        #expect(record.baseNote?.hasPrefix("Unfinished-suite rerun: skipped 3 completed passing suites") == true)
        #expect(gate.ledger(root).flakes.map(\.test) == [MergeRerun.unnamed])
        #expect(lead.call("status", [:]).text.contains("Unfinished-suite reruns: 1 of 1 passed"))
    }

    @Test func aContinuationMissingARepeatedSuitesSecondPassDoesNotMerge() throws {
        let once = Self.modulesResumed.components(separatedBy: "\n").filter { $0 != "✔ Suite LeadRotationToolGateTests passed after 0.1 seconds." }
            .joined(separator: "\n") + "\n✔ Suite LeadRotationToolGateTests passed after 0.1 seconds."
        let (gate, root, _) = try resume(Self.stoppedAcrossModules, inventory: Self.modules, again: once, expectMerge: false)
        #expect(gate.ran().last == Self.modulesSkip)
        #expect(gate.ledger(root).reruns.map(\.passed) == [false])
        #expect(gate.ledger(root).flakes.isEmpty)
        #expect(BoardStore(root: root).load().task("add-b")?.merged == nil)
    }

    // A suite whose label passed but whose tests' own passes don't all show (a display name standing for another
    // suite, say) isn't skipped.
    @Test func aCompletedSuiteIsSkippedOnlyWhenEachOfItsTestsShowsItsPass() {
        var workflow = LeadWorkflow()
        workflow.testCommand = "bash scripts/test.sh"
        let missing = Self.stoppedAcrossModules.replacingOccurrences(of: "✔ Test aChangedNameOrLoginRestartsOnTheNewOne() passed after 0.5 seconds.\n", with: "")
        let plan = MergeRerun.plan(after: missing, workflow: workflow, suites: { Self.modules })
        #expect(plan?.filtered == true)
        #expect(plan?.command.contains("PhoneTailscaleFlowTests(/|$)") == false)
        #expect(plan?.command.contains(#"^VibeHostTests\.TestHomeGuardTests(/|$)"#) == true)
        #expect(plan?.requiredSuites == ["LeadRotationToolGateTests", "LeadRotationToolGateTests", "TailscaleFakeTests", "PhoneTailscaleFlowTests"])
    }

    // F3: scripts/test.sh's leftover and preference lines name no suite, so a stopped run that printed one reruns whole.
    @Test func aStoppedRunThatLeftProcessesOrPreferencesRerunsWhole() throws {
        for marker in MergeRerun.suiteMarkers {
            var workflow = LeadWorkflow()
            workflow.testCommand = "bash scripts/test.sh"
            let output = Self.stoppedAcrossModules + "\n" + marker + " the run left these running:\n  4242 sleep 3600"
            let plan = MergeRerun.plan(after: output, workflow: workflow, suites: { Self.modules })
            #expect(plan?.filtered == false)
            #expect(plan?.note?.contains("left processes or preferences behind") == true)
        }
        let (gate, root, _) = try resume(Self.stopped + "\nPREFERENCES CHANGED: the run changed VibeSwitcher.plist")
        #expect(gate.ran().last == "run ")
        let record = try #require(gate.ledger(root).reruns.first)
        #expect(!record.filtered && record.baseNote?.contains("left processes or preferences behind") == true)
    }
}
