import Foundation
import Testing
@testable import VibeCore

/// What a lead reads never pushes it against the user's working policy (2026-10-24, the review of the genswap, TGE and
/// films leads): an update per merge (TGE posted 59), "try again in about 5 minutes" (TGE ran 48 sleep loops), a worker
/// full suite on top of the merge's (20 of genswap's 30 contracts), and briefs asking for git commands workers are refused.
struct LeadPolicyTextsTests {
    static let task = LeadTask(slug: "split-layer", title: "Split the layer",
                               contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
    static let workflows = ["", "---\nmerge_policy: auto\n---", "---\nmerge_policy: ask_sensitive\n---", "---\nmerge_policy: ask_all\nbase_branch: dev\n---"]
        .map(LeadWorkflow.parse)

    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/VibeCore")

    /// Every string literal in the lead's tool server: its results and refusals, piece by piece.
    static func literals(_ file: String) throws -> [String] {
        let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// What tells the lead to sleep or to retry on a timer ("don't sleep" is the opposite).
    static func tellsToSleep(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "don't sleep", with: "")
        return ["about 5 minutes", "retryminutes", "sleep", "in a few minutes"].filter(lowered.contains)
    }

    @Test func noLeadPromptOrRefusalTellsTheLeadToSleepOrRetryOnATimer() throws {
        for workflow in Self.workflows {
            let prompt = LeadPrompts.lead(project: "tge", root: "/r/tge", workflow: workflow)
            #expect(Self.tellsToSleep(prompt).isEmpty, "\(Self.tellsToSleep(prompt))")
            #expect(prompt.contains("Don't sleep, wait or poll") && prompt.contains(LeadPrompts.retryWhenWoken))
            #expect(!prompt.contains("wait or lower audit_finders"))
        }
        let literals = try Self.literals("LeadToolset.swift") + Self.literals("MacLoad.swift")
        #expect(literals.count > 300, "found \(literals.count) literals: the scan no longer finds them")
        for literal in literals { #expect(Self.tellsToSleep(literal).isEmpty, "\(literal)") }
        // What the refusals say instead.
        for needle in ["Don't sleep or poll", "retry when you're next woken", "a report, the user, or a VibeSwitcher message"] {
            #expect(LeadPrompts.retryWhenWoken.contains(needle), "missing \(needle)")
        }
    }

    @Test func aMergeIsPostedOnlyWhenTheUserWouldNoticeItAndTheRestGoIntoADailySummary() {
        let updates = LeadPrompts.Policy.updates
        for needle in ["post_update only for a merge the user would notice", "how it was checked", "revert", "daily summary"] {
            #expect(updates.contains(needle), "missing \(needle)")
        }
        for workflow in Self.workflows {
            let prompt = LeadPrompts.lead(project: "tge", root: "/r/tge", workflow: workflow)
            #expect(prompt.contains("then cleanup(task); " + updates))
            #expect(!prompt.contains("After each merge, post_update") && !prompt.contains("then post_update with what changed"))
            #expect(prompt.contains("daily summary: post_update (title \"Today: …\")"))
            #expect(!prompt.contains("every few merges"))
        }
        let auto = LeadPrompts.mergePolicy(LeadWorkflow.parse("---\nmerge_policy: auto\n---"))
        #expect(auto.contains("A merge the user would notice gets a post_update") && auto.contains("the rest go into your daily summary"))
        let literals = (try? Self.literals("LeadToolset.swift")) ?? []
        #expect(!literals.contains { $0.contains("Post an update") })
    }

    @Test func theMergesRunIsTheOneFullSuiteInTheBriefAndTheContractGuidance() {
        let testing = LeadPrompts.Policy.workerTesting(test: "pnpm test")
        for needle in ["run the tests your change affects", "the lead's merge runs the full suite (`pnpm test`) once",
                       "that run is the one full suite", "only when you changed shared test or build infrastructure"] {
            #expect(testing.contains(needle), "worker: missing \(needle)")
        }
        let brief = LeadPrompts.worker(task: Self.task, root: "/r", workflow: LeadWorkflow.parse("---\ntest_command: pnpm test\n---"))
        #expect(brief.contains(testing))
        let contracts = LeadPrompts.Policy.leadContracts
        for needle in ["never a full suite run by the worker", "merge(task) runs test_command, and that run is the one full suite",
                       "only when its change touches shared test or build infrastructure"] {
            #expect(contracts.contains(needle), "contracts: missing \(needle)")
        }
        #expect(LeadPrompts.lead(project: "genswap", root: "/r", workflow: LeadWorkflow.parse("")).contains(contracts))
        // add_task's acceptance says it too (LeadToolsetTests.addTasksAcceptanceSaysTheMergesRunIsTheOneFullSuite).
    }

    /// 2026-10-24: a worker ran only its filtered tests and the audit's full run found a PrivateWriteLint failure.
    @Test func theBriefTellsTheWorkerToRunTheRepositorysLintTestsBeforeReportingDone() throws {
        let repository = Self.sources.deletingLastPathComponent().deletingLastPathComponent().path
        let lints = LeadPrompts.Policy.lintTests(in: repository)
        for name in ["PrivateWriteLint", "TemporaryFolderLint", "HomePathLint", "AccessibilityLint"] {
            #expect(lints.contains(name), "missing \(name) in \(lints)")
        }
        #expect(lints == lints.sorted() && !lints.contains { $0.hasSuffix("Tests") })
        let workflow = LeadWorkflow.parse("---\ntest_command: bash scripts/test.sh\n---")
        let brief = LeadPrompts.worker(task: Self.task, root: repository, workflow: workflow)
        let filter = "`bash scripts/test.sh --filter '\(lints.joined(separator: "|"))'`"
        #expect(brief.contains("Lints: before you report done, run the repository's lint tests (\(filter)) along with the affected tests."))
        #expect(brief.contains(LeadPrompts.Policy.workerTesting(test: "bash scripts/test.sh") + "\nLints:"))

        // Another project's brief: its own lint tests, or a generic line when it has none.
        let scratch = Scratch()
        let other = scratch.url("lints")
        let folder = other.appendingPathComponent("Tests/AppTests")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["StyleLintTests.swift", "ModelTests.swift", "LintHelpers.swift"] {
            try Data().write(to: folder.appendingPathComponent(file))
        }
        #expect(LeadPrompts.Policy.lintTests(in: other.path) == ["StyleLint"])
        #expect(LeadPrompts.worker(task: Self.task, root: other.path, workflow: LeadWorkflow.parse(""))
            .contains("run the repository's lint tests (`swift test --filter 'StyleLint'`) along with"))
        let none = LeadPrompts.worker(task: Self.task, root: "/r/genswap", workflow: LeadWorkflow.parse(""))
        #expect(none.contains("Lints: before you report done, run your repository-wide lint or check tests, if any, along with the affected tests."))
        #expect(LeadPrompts.worker(task: Self.task, root: "/r", workflow: workflow, lints: ["A", "B"]).contains("--filter 'A|B'"))
    }

    /// 2026-10-25: workers proved UI work through snapshot tests alone, and the user found 35 bugs by hand after
    /// installs. A worker on a UI change shows it in the sandboxed app and attaches the shots to its done report.
    @Test func theBriefTellsAWorkerOnAUIChangeToAttachSandboxScreenshots() throws {
        let repository = Self.sources.deletingLastPathComponent().deletingLastPathComponent().path
        let text = try #require(LeadPrompts.Policy.workerScreenshots(in: repository))
        for needle in ["UI changes:", "`bash scripts/sandbox-app.sh run`", "sandboxed copy", "fake sessions only",
                       "never the user's app, sessions or Keychain", "`shot NAME`", ".build/sandbox-shots/", "`quit`",
                       "`sheet NAME`", "Sources/VibeSwitcher/Sandbox.swift",
                       "Put the shots' paths in your done report's `evidence`, in the `screenshots` of the check each one shows"] {
            #expect(text.contains(needle), "missing \(needle)")
        }
        let workflow = LeadWorkflow.parse("---\ntest_command: bash scripts/test.sh\n---")
        let brief = LeadPrompts.worker(task: Self.task, root: repository, workflow: workflow)
        // Said after the lints, before Done: what a worker does last before reporting.
        #expect(brief.contains("along with the affected tests. They take seconds and catch what a filtered run misses, "
                               + "which otherwise only the merge's full run finds.\n" + text + "\nDone:"))
        // The evidence it points to is the done report's (`workerEvidence`), which has a screenshots list per check.
        #expect(LeadPrompts.Policy.workerEvidence(base: "main").contains("screenshots (the paths of any screenshots you took"))
        // The script the brief names is the repository's.
        #expect(FileManager.default.isExecutableFile(atPath: repository + "/" + LeadPrompts.Policy.sandboxScript))

        // A project without the sandbox script: no such paragraph.
        let none = LeadPrompts.worker(task: Self.task, root: "/r/genswap", workflow: LeadWorkflow.parse(""))
        #expect(LeadPrompts.Policy.workerScreenshots(in: "/r/genswap") == nil)
        #expect(!none.contains("UI changes:") && none.contains("along with the affected tests. They take seconds and catch "
                                                                  + "what a filtered run misses, which otherwise only the merge's full run finds.\nDone:"))
    }

    /// A fix's regression test is shown to fail without the fix, by the worker's evidence, and a re-audit checks that
    /// evidence (2026-10-25: the two tests for finished-work-lands' F1 fix would have passed on the old code too). The
    /// commands the worker is given run under its rules: LeadGuardRailsTests.
    @Test func aFixsTestIsShownToFailWithoutTheFixByTheWorkerAndByTheReaudit() {
        // The worker: in its evidence, next to what the done report carries and the blind check.
        let workflow = LeadWorkflow.parse("---\nbase_branch: project-lead\n---")
        let worker = LeadPrompts.Policy.regressionTest(base: "project-lead")
        #expect(LeadPrompts.worker(task: Self.task, root: "/r", workflow: workflow)
            .contains(LeadPrompts.Policy.workerEvidence(base: "project-lead") + "\n" + worker + "\n" + LeadPrompts.Policy.workerFindings))
        for needle in ["for a bug fix or a fixed audit finding, the evidence includes the new test's failing run on the commit before the fix",
                       "the branch's merge-base with project-lead", "then its passing run after it",
                       "a test that would pass either way doesn't cover the fix", "by reverting the fix locally and restoring it, in this worktree",
                       "`git diff <pre-fix> HEAD -- <the fix's files> | git apply -R`", "the same command without `-R`"] {
            #expect(worker.contains(needle), "missing \(needle)")
        }
        // Not by a command the user's command guard refuses (it stops `git checkout <commit> -- <files>`), nor an export.
        for refused in ["git checkout", "git restore", "git archive", "tar ", "TMPDIR"] { #expect(!worker.contains(refused), "\(refused)") }

        // The re-audit, whatever its scope, and after a re-roll: the worker's evidence, and a Nit when it falls short.
        let reroll = LeadReroll(archive: "archive/split-layer-1", commit: "aaaaaaaa1111", round: 2)
        for (scope, reroll) in [(LeadPrompts.Reaudit.Scope.since, nil), (.ownFiles(["a.swift"]), nil), (.wholeBranch(sameCommit: false), nil),
                                (.wholeBranch(sameCommit: false), reroll)] {
            let text = LeadPrompts.recheck(.init(round: 3, since: "aaaaaaaa1111", head: "bbbbbbbb2222", open: [], known: [], stat: "", diff: nil,
                                                 base: "dev", scope: scope, reroll: reroll))
            #expect(text.contains("A finding fixed with a new or changed test: don't run the old code; check that the worker's "
                                  + "evidence (its done report, or its answer below) shows the test failing on the commit before the "
                                  + "fix and passing after it. When that evidence is missing, or the test plainly can't reach the bug "
                                  + "the finding describes (it would pass on the old code too), the finding can still be fixed, but "
                                  + "raise a Nit at the test's file and line saying which: the test doesn't cover the fix."), "\(scope)")
            // The one new Nit a re-audit raises.
            #expect(reroll != nil || text.contains("never a new Nit but the one for a fix's test below."), "\(scope)")
        }
        let first = LeadPrompts.verifier(task: Self.task, root: "/r", workflow: workflow)
        #expect(!first.contains("A finding fixed with a new or changed test"))
    }

    @Test func privacyIsAReasonForAnAuditAlongsideSecurity() {
        let review = LeadPrompts.Policy.leadReview
        for needle in ["security (", "privacy (the owner's private data in a contract or a file", "a repository's or a share's visibility",
                       "anything that exposes it to others"] {
            #expect(review.contains(needle), "missing \(needle)")
        }
        #expect(LeadPrompts.lead(project: "films", root: "/r", workflow: LeadWorkflow.parse("")).contains(review))
    }

    @Test func theLeadAndTheWorkerListEveryGitCommandAWorkerIsRefused() {
        for (workflow, records) in [(LeadWorkflow.parse(""), "docs/lead"), (LeadWorkflow.parse("---\nbase_branch: project-lead\nrecords_dir: notes\n---"), "notes")] {
            let rules = LeadLaunch.deny(.worker, base: workflow.base, records: workflow.recordsDir)
            #expect(workflow.recordsDir == records)
            let git = rules.filter { $0.hasPrefix("Bash(git ") }
            #expect(git.count > 30 && git.contains("Bash(git -C:*)") && git.contains("Bash(git worktree:*)") && git.contains("Bash(git tag:*)")
                    && git.contains("Bash(git commit --amend:*)"))
            let lead = LeadPrompts.lead(project: "genswap", root: "/r", workflow: workflow)
            let worker = LeadPrompts.worker(task: Self.task, root: "/r", workflow: workflow)
            for rule in git {
                var command = String(rule.dropFirst("Bash(".count).dropLast())
                if command.hasSuffix(":*") { command.removeLast(2) }
                #expect(lead.contains("`\(command)`"), "lead: missing \(rule)")
                #expect(worker.contains("`\(command)`"), "worker: missing \(rule)")
            }
            // git under another name too, and nothing a worker may run (its allow rules).
            #expect(lead.contains("`env git`") && worker.contains("`/usr/bin/git`"))
            let listed = LeadLaunch.deniedGit(.worker, base: workflow.base, records: workflow.recordsDir)
            for allowed in ["git merge \(workflow.base)", "git commit", "git add", "git rebase --continue"] { #expect(!listed.contains(allowed)) }
            #expect(lead.contains("Workers are refused these git commands, so no brief may need one: " + LeadPrompts.deniedGit(workflow) + "."))
            #expect(worker.contains("Git commands refused here, by your permission rules: " + LeadPrompts.deniedGit(workflow) + ".\nOut of date:"))
        }
    }

    /// The brief sends a change to the verifier through its eval set where the project has one, and says nothing of it
    /// elsewhere.
    @Test func theLeadsBriefRunsTheVerifierEvalOnlyWhereTheProjectHasIt() {
        let repository = Self.sources.deletingLastPathComponent().deletingLastPathComponent().path
        let line = "`scripts/verifier-eval.sh --all` before it merges"
        #expect(LeadPrompts.lead(project: "vibeswitcher", root: repository, workflow: LeadWorkflow()).contains(line))
        #expect(LeadPrompts.lead(project: "vibeswitcher", root: repository, workflow: LeadWorkflow()).contains("docs/process/verifier-eval.md"))
        #expect(!LeadPrompts.lead(project: "tge", root: "/r/tge", workflow: LeadWorkflow()).contains("verifier-eval"))
    }
}
