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
}
