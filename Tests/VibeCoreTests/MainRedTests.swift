import Foundation
import Testing
@testable import VibeCore

/// Main red is found before branches are blamed: a batch's failing tests run once on the base before it's split
/// (`MergeRerun.redOnBase`, the whole run's paired base run). Red there too, they send no task back; the lead is told
/// the base is red with the base run's first failing lines, and a fix task goes to the front of the plan. On
/// 2026-11-12 a split marked a docs-only task as failed for tests that failed on main.
extension MergeBatchTests {
    /// y breaks other(); breaks() is red on main. y is first on the stack, so nothing lands before the split: main's
    /// red is still found and told before it, y's setback names other() only, and x lands.
    @Test func aBatchFindsMainRedBeforeItsSplitAndBlamesNoBranchForIt() throws {
        let root = try repo()
        let lines = { (test: String) in
            "echo '✘ Test \(test) recorded an issue at T.swift:3:5: no'; echo '✘ Test \(test) failed after 0.01 seconds with 1 issue.'"
        }
        try commit(["scripts/test.sh": """
            #!/bin/bash
            echo "run $* | $(ls *.txt | tr '\\n' ' ')" >> \(RecentProjects.shellQuote(runs))
            [[ "$*" == *--skip* ]] && { echo "✔ Test run with 0 tests passed after 0.001 seconds."; exit 0; }
            \(lines("breaks()"))
            if [[ -e y.txt ]]; then \(lines("other()")); fi
            echo "✘ Test run with 2 tests failed after 0.020 seconds with 1 issue."
            exit 1
            """], in: root, "the suite")
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["test_command": "bash scripts/test.sh", "merge_policy": "auto", "auto_advance": false, "records_dir": ""]).isError)
        // A task already planned: the fix goes before it.
        #expect(!lead.call("add_task", ["title": "Later work", "goal": "g", "acceptance": ["a"]]).isError)
        try audited(lead, runtime, root: root, "add-y", ["y.txt": "y\n"])
        try audited(lead, runtime, root: root, "add-x", ["x.txt": "x\n"])

        let merged = lead.call("merge", ["tasks": ["add-y", "add-x"]])
        #expect(landed(root) == ["add-x's work"], "\(merged.text)\n\(ran())")
        let after = board(root)
        // y goes back for other() alone; breaks() is said to be main's.
        let y = try #require(after.task("add-y"))
        #expect(y.status == .failed)
        let reason = try #require(y.setback?.reason)
        #expect(reason.contains("other() (breaks() failed on the base too: not this branch's)"), "\(reason)")
        #expect(!reason.contains(": breaks()"), "\(reason)")
        #expect(after.task("add-x")?.status == .done)

        // Told before the split, with the base run's first failing lines, and one fix, first in the plan.
        let red = try #require(after.mainRed)
        #expect(red.tests == ["breaks()"] && !red.all && red.onto == Git.run(["rev-parse", "main~1"], in: root).output, "\(red)")
        #expect(red.lines.contains("✘ Test breaks() recorded an issue at T.swift:3:5: no"), "\(red.lines)")
        let fix = try #require(after.tasks.first { $0.title == "Fix the test breaks(), red on main" })
        #expect(red.fixes == [fix.slug])
        let planned = after.tasks.filter { $0.status == .planned }.map(\.title)
        #expect(planned.first == fix.title && planned.contains("Later work"), "\(planned)")
        #expect(after.tasks.filter { $0.title.hasPrefix("Fix the test") }.count == 1, "\(after.tasks.map(\.title))")
        let report = try #require(after.reports?.first { $0.text.hasPrefix("main is red: breaks()") })
        #expect(report.about == LeadAdvance.sender)
        #expect(report.text.contains("so no branch is sent back for them") && report.text.contains("    ✘ Test breaks() recorded an issue at T.swift:3:5: no"), "\(report.text)")
        #expect(report.text.contains("To fix first: \(fix.slug)"), "\(report.text)")
        #expect(merged.text.contains("main is red: breaks()"), "\(merged.text)")
        // Not the whole failure (other() was y's): merges aren't held for it.
        #expect(lead.mainRedHold("add-z") == nil)
    }

    /// The pieces: what a failed run says of the base, what holds merges, and the urgent order.
    @Test func mainRedsPieces() {
        let pairing = MergeRerun.Pairing()
        let a = "✘ Test a() recorded an issue at A.swift:1:1: no\n✘ Test a() failed after 0.01 seconds with 1 issue."
        let b = "✘ Test b() recorded an issue at B.swift:1:1: no\n✘ Test b() failed after 0.01 seconds with 1 issue."
        #expect(MergeRerun.redOnBase(Worktrees.rerunHeader + a, pairing: pairing) == nil)
        pairing.heard(red: ["a()"], output: a)
        let alone = MergeRerun.redOnBase(Worktrees.rerunHeader + a, pairing: pairing)
        #expect(alone?.red == ["a()"] && alone?.all == true)
        let both = MergeRerun.redOnBase(Worktrees.rerunHeader + a + "\n" + b, pairing: pairing)
        #expect(both?.red == ["a()"] && both?.all == false)
        // The rest of the checks failed after it, or it left processes behind: not the whole failure.
        #expect(MergeRerun.redOnBase(Worktrees.rerunHeader + a + "\n\n" + Worktrees.restHeader + "x", pairing: pairing)?.all == false)
        #expect(MergeRerun.redOnBase(Worktrees.rerunHeader + a + "\nLEFTOVER PROCESSES: 1", pairing: pairing)?.all == false)
        #expect(MergeRerun.redOnBase(Worktrees.rerunHeader + b, pairing: pairing) == nil)

        let red = LeadMainRed(tests: ["a()"], onto: "abc", at: 0, all: true, fixes: ["fix-a"], lines: [])
        #expect(red.holds("add-b", lifted: false))
        #expect(!red.holds("fix-a", lifted: false))
        #expect(!red.holds("add-b", lifted: true))
        var partial = red
        partial.all = false
        #expect(!partial.holds("add-b", lifted: false))

        var board = LeadBoard()
        for (slug, status) in [("done-1", LeadTask.Status.done), ("plan-1", .planned), ("work-1", .running), ("plan-2", .planned), ("fix-a", .planned)] {
            var task = LeadTask(slug: slug, title: slug, contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
            task.status = status
            board.tasks.append(task)
        }
        LeadToolset.putFirst(["fix-a", "work-1"], in: &board)
        #expect(board.tasks.map(\.slug) == ["done-1", "fix-a", "plan-1", "work-1", "plan-2"])
    }

    /// The base red on what's the whole failure: auto_advance holds every
    /// merge but the fix's until the base moves.
    @Test func mainRedThatIsTheWholeFailureHoldsOtherMergesUntilTheBaseMoves() throws {
        let (root, runtime, lead) = try team(["auto_advance": false])
        try audited(lead, runtime, root: root, "add-x", ["x.txt": "x\n"])
        let head = Git.run(["rev-parse", "main"], in: root).output
        try BoardStore(root: root).update { board in
            board.mainRed = LeadMainRed(tests: ["breaks()"], onto: head, at: 0, all: true, fixes: ["fix-breaks"], lines: [])
        }
        let held = try #require(lead.mainRedHold("add-x"))
        #expect(held.contains("main is red (breaks() fail on main itself") && held.contains("it waits for fix-breaks to land"), "\(held)")
        #expect(lead.mainRedHold("fix-breaks") == nil)
        // The lead's records commits (its own "main is red" progress line among them) don't lift it: else every ready
        // task would run its whole merge again on the same red tests each round.
        try commit(["docs/lead/progress.md": "# Progress\n\n- main is red\n"], in: root, LeadRecords.subject)
        #expect(lead.mainRedHold("add-x") != nil)
        // The base moved by anything else: merges go again.
        try commit(["d.txt": "d\n"], in: root, "moved")
        #expect(lead.mainRedHold("add-x") == nil)
    }

    /// A fix landing lifts it, whatever the base did.
    @Test func mainRedIsLiftedWhenItsFixLands() throws {
        let (root, runtime, lead) = try team(["auto_advance": false])
        try audited(lead, runtime, root: root, "add-x", ["x.txt": "x\n"])
        let head = Git.run(["rev-parse", "main"], in: root).output
        try BoardStore(root: root).update { board in
            board.mainRed = LeadMainRed(tests: ["breaks()"], onto: head, at: 0, all: true, fixes: ["add-x"], lines: [])
            var fix = LeadTask(slug: "fix-other", title: "fix", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
            fix.status = .done
            board.tasks.append(fix)
        }
        #expect(lead.mainRedHold("add-y") != nil)
        try BoardStore(root: root).update { board in board.mainRed?.fixes = ["fix-other"] }
        #expect(lead.mainRedHold("add-y") == nil)
    }

    // MARK: The workers are told

    /// `slugs` added and their workers started: each one's session.
    func running(_ lead: LeadToolset, root: String, _ slugs: [String]) throws -> [String] {
        try slugs.map { slug in
            #expect(!lead.call("add_task", ["title": slug, "goal": "g", "acceptance": ["a"]]).isError)
            let started = lead.call("start_worker", ["task": slug])
            #expect(!started.isError, "\(started.text)")
            return try #require(board(root).task(slug)?.worker)
        }
    }

    /// Main red (as a merge's rerun and the base's run found it): each running worker is sent one message naming the
    /// test and saying it isn't theirs; the same red again sends nothing; main green again sends one more. No verifier
    /// and no worker that isn't running (one in review, its audit under way) hears of it. On 2026-11-12, 9 workers
    /// each tracked down main's red PrivateNamesLint on their own.
    @Test func eachRunningWorkerIsToldOnceThatMainIsRedAndOnceThatItsGreenAgain() throws {
        let (root, runtime, lead) = try team(["auto_advance": false])
        try audited(lead, runtime, root: root, "add-x", ["x.txt": "x\n"])
        let verifier = try #require(board(root).task("add-x")?.verifier)
        let reviewed = try #require(board(root).task("add-x")?.worker)
        let workers = try running(lead, root: root, ["work-a", "work-b"])
        let told = { (session: String) in runtime.steered.filter { $0.target == session }.map(\.text) }
        #expect(workers.allSatisfy { told($0).isEmpty })
        let head = Git.run(["rev-parse", "main"], in: root).output
        let red = (red: ["breaks()"], all: true, output: Self.failure)

        lead.mainIsRed(red, rerun: Self.failure, slug: "add-x", onto: head, workflow: lead.workflow)
        for worker in workers {
            let said = told(worker)
            #expect(said.count == 1, "\(said)")
            #expect(said.first?.hasPrefix("main is red: breaks() fail on main itself") == true, "\(said)")
            #expect(said.first?.contains("They aren't yours to fix") == true, "\(said)")
        }
        // Its fix, planned at the front, is named.
        let fix = try #require(board(root).mainRed?.fixes.first)
        #expect(told(workers[0]).first?.contains("(\(fix) fixes them)") == true, "\(told(workers[0]))")

        // The same red again (another merge finds it): nothing more.
        lead.mainIsRed(red, rerun: Self.failure, slug: "add-x", onto: head, workflow: lead.workflow)
        #expect(workers.allSatisfy { told($0).count == 1 })

        // A merge's run passes on main: one "green again" each.
        lead.noteMainGreen(.passed(head), rerun: nil)
        #expect(board(root).mainRed == nil)
        for worker in workers {
            let said = told(worker)
            #expect(said.count == 2 && said.last?.hasPrefix("main is green again") == true, "\(said)")
        }
        // Green again stays quiet.
        lead.noteMainGreen(.passed(head), rerun: nil)
        #expect(workers.allSatisfy { told($0).count == 2 })
        #expect(told(verifier).isEmpty && told(reviewed).isEmpty, "\(told(verifier)) \(told(reviewed))")
    }

    /// A worker in review when main turned red (F1: told nothing then) hears of it with the next message that goes to
    /// it, the audit's findings that send it back to work say (`LeadAdvance.sendBack` sends through `sent`), once;
    /// and, green again while it's still not running, with the next one after that.
    @Test func aWorkerNotRunningWhenMainTurnedRedHearsItWithItsNextMessage() throws {
        let (root, runtime, lead) = try team(["auto_advance": false])
        try audited(lead, runtime, root: root, "add-x", ["x.txt": "x\n"])
        let reviewed = try #require(board(root).task("add-x")?.worker)
        #expect(board(root).task("add-x")?.status != .running)
        let told = { runtime.steered.filter { $0.target == reviewed }.map(\.text) }
        let head = Git.run(["rev-parse", "main"], in: root).output
        lead.mainIsRed((["breaks()"], true, Self.failure), rerun: Self.failure, slug: "add-x", onto: head, workflow: lead.workflow)
        #expect(told().isEmpty, "\(told())")

        #expect(!lead.call("message", ["task": "add-x", "text": "Your branch's audit left 1 Important finding open."]).isError)
        #expect(told().count == 1 && told()[0].hasPrefix("Your branch's audit left") && told()[0].contains("main is red: breaks() fail on main itself"), "\(told())")
        #expect(!lead.call("message", ["task": "add-x", "text": "And another thing."]).isError)
        #expect(told().count == 2 && !told()[1].contains("main is red"), "\(told())")

        // Green while it isn't running: no message of its own, but the next one says it.
        try BoardStore(root: root).update { board in board.tasks[board.taskIndex("add-x")!].status = .review }
        lead.noteMainGreen(.passed(head), rerun: nil)
        #expect(told().count == 2, "\(told())")
        #expect(!lead.call("message", ["task": "add-x", "text": "Go on."]).isError)
        #expect(told().count == 3 && told()[2].contains("main is green again: a merge's run passed on main, breaks() among it"), "\(told())")
        #expect(!lead.call("message", ["task": "add-x", "text": "Thanks."]).isError)
        #expect(told().count == 4 && !told()[3].contains("main is"), "\(told())")
    }

    /// F2: a merge whose tests passed on their rerun (each test it was for shown passing) is green on the base too,
    /// as a first-time pass is; one whose filtered rerun showed none of them passing isn't.
    @Test func aMergePassingOnItsRerunClearsMainRed() throws {
        let (root, runtime, lead) = try team(["auto_advance": false])
        let worker = try running(lead, root: root, ["work-a"])[0]
        let told = { runtime.steered.filter { $0.target == worker }.map(\.text) }
        let head = Git.run(["rev-parse", "main"], in: root).output
        lead.mainIsRed((["breaks()"], true, Self.failure), rerun: Self.failure, slug: "work-a", onto: head, workflow: lead.workflow)
        #expect(told().count == 1)
        let plan = MergeRerun.Plan(tests: ["flaky()"], filtered: true, command: "bash scripts/test.sh --filter flaky")
        lead.noteMainGreen(.passedOnRerun(commit: head, failed: Self.failure, rerun: "✔ Test run with 0 tests passed after 0.001 seconds."), rerun: plan)
        #expect(board(root).mainRed != nil && told().count == 1, "\(told())")
        lead.noteMainGreen(.passedOnRerun(commit: head, failed: Self.failure, rerun: "✔ Test flaky() passed after 0.001 seconds."), rerun: plan)
        #expect(board(root).mainRed == nil)
        #expect(told().count == 2 && told()[1].hasPrefix("main is green again"), "\(told())")
    }

    /// A worker started while main is red has the line in its brief (but the fix's own worker); one started when it's
    /// green doesn't.
    @Test func aWorkerStartedWhileMainIsRedHasItInItsBrief() throws {
        let (root, _, lead) = try team(["auto_advance": false])
        let brief = { (slug: String) in
            try String(contentsOf: vault.runFolder(root: root, name: "worker-\(slug)").appendingPathComponent("prompt.md"), encoding: .utf8)
        }
        _ = try running(lead, root: root, ["while-green"])
        #expect(!(try brief("while-green")).contains("Main red:"))

        let head = Git.run(["rev-parse", "main"], in: root).output
        try BoardStore(root: root).update { board in
            board.mainRed = LeadMainRed(tests: ["PrivateNamesLint"], onto: head, at: 0, all: true, fixes: ["fix-lint"], lines: [])
        }
        _ = try running(lead, root: root, ["while-red", "fix-lint"])
        let red = try brief("while-red")
        #expect(red.contains("Main red: main is red: PrivateNamesLint fail on main itself (\(head.prefix(8)))"), "\(red)")
        #expect(red.contains("They aren't yours to fix (fix-lint fixes them)"), "\(red)")
        #expect(!(try brief("fix-lint")).contains("Main red:"))
    }
}
