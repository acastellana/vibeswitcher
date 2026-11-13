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
}
