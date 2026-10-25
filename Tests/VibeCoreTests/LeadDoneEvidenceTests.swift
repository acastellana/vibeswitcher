import Foundation
import Testing
@testable import VibeCore

/// A worker's done report as the report tool takes it: `summary` (under `key`), with an entry for each of the task's
/// first `checks` acceptance checks, by number, and a blind check that found nothing.
func doneReport(_ summary: String, checks: Int = 1, key: String = "summary") -> [String: Any] {
    ["status": "done", key: summary, "blind_check": "Nothing blocking.",
     "evidence": (1...max(checks, 1)).map { ["check": "\($0)", "how": "ran it", "result": "passed"] }]
}

/// Done reports carry evidence (Lead Process v3 phase 2, 2026-10-25): an entry for each acceptance check, saying how it
/// was checked, and what a blind check found. A done without them is refused with what's missing; the vault keeps them
/// with the done, and board(task), the verifier and merge show them.
struct LeadDoneEvidenceTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    static let checks = ["test -f b.txt", "b.txt says bee, one line, nothing else in it", "LeadDoneEvidenceTests pass"]

    func repo() throws -> String {
        let url = temp.url("evidence")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// Task "add-b" with `acceptance`, merge_policy auto and `test -f b.txt` its test command, its worker started and
    /// b.txt committed: the lead's tools and the worker's.
    func working(_ root: String, _ runtime: FakeRuntime, acceptance: [String] = checks) throws -> (lead: LeadToolset, worker: LeadToolset) {
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "auto", "test_command": "test -f b.txt"]).isError)
        #expect(!lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": acceptance]).isError)
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b"], in: worktree)
        return (lead, try seat("worker-add-b", runtime))
    }

    /// Evidence for all three checks: by number, by text, and by the start of its text, with a screenshot.
    static let full: [[String: Any]] = [
        ["check": 1, "how": "`test -f b.txt` in the worktree", "result": "exit 0"],
        ["check": "B.txt says bee, one line, nothing else in it.", "how": "cat b.txt", "result": "bee"],
        ["check": "LeadDoneEvidenceTests", "how": "swift test --filter LeadDoneEvidenceTests", "result": "9 tests passed",
         "screenshots": ["shots/board.png"]],
    ]

    func done(_ evidence: Any?, blind: Any? = "Found: b.txt lacked a newline. Fixed in the last commit.") -> [String: Any] {
        var arguments: [String: Any] = ["status": "done", "summary": "added b.txt"]
        if let evidence { arguments["evidence"] = evidence }
        if let blind { arguments["blind_check"] = blind }
        return arguments
    }

    @Test func aDoneWithoutEvidenceForEveryCheckIsRefusedNamingWhatsMissing() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let (_, worker) = try working(root, runtime)

        let none = worker.call("report", done(nil))
        #expect(none.isError && none.text.contains("needs `evidence`, one entry per acceptance check"), "\(none.text)")
        let partial = worker.call("report", done([Self.full[0]]))
        #expect(partial.isError, "\(partial.text)")
        #expect(partial.text.contains("no entry for these acceptance checks 2 (b.txt says bee, one line, nothing else in it); 3 (LeadDoneEvidenceTests pass)"), "\(partial.text)")
        #expect(!partial.text.contains("1 (test -f b.txt)"))
        // A check named by too few words of its text, or by a number it doesn't have, covers nothing.
        let vague = worker.call("report", done([Self.full[0], Self.full[1], ["check": "tests", "how": "ran", "result": "ok"], ["check": "4", "how": "x", "result": "y"]]))
        #expect(vague.isError && vague.text.contains("acceptance check 3 (LeadDoneEvidenceTests pass)"), "\(vague.text)")
        let unsaid = worker.call("report", done([["check": "1", "how": "ran it"]]))
        #expect(unsaid.isError && unsaid.text.contains("evidence entry 1 (1) has no result"), "\(unsaid.text)")
        let blind = worker.call("report", done(Self.full, blind: nil))
        #expect(blind.isError && blind.text.contains("`blind_check`") && blind.text.contains("git diff main...HEAD"), "\(blind.text)")

        // Nothing refused was recorded: no done in the vault, none on the board, nothing sent to the lead.
        #expect(try vault.unaudited(root: root, task: "add-b").reported == nil)
        #expect(BoardStore(root: root).load().task("add-b")?.report == nil)
        #expect(!runtime.steered.contains { $0.text.contains("says it's done") })

        // A blocked report needs none.
        #expect(!worker.call("report", ["status": "blocked", "summary": "need a key"]).isError)
        let reported = worker.call("report", done(Self.full))
        #expect(!reported.isError, "\(reported.text)")
        let kept = try vault.unaudited(root: root, task: "add-b")
        #expect(kept.reported == Git.run(["rev-parse", "agent/add-b"], in: root).output)
        #expect(kept.evidence?.checks.map(\.check) == ["1", "B.txt says bee, one line, nothing else in it.", "LeadDoneEvidenceTests"])
        #expect(kept.evidence?.checks.last?.screenshots == ["shots/board.png"])
        #expect(kept.evidence?.blindCheck == "Found: b.txt lacked a newline. Fixed in the last commit.")
    }

    /// Evidence passed as a JSON string, and a blind check as a list of items, as callers sometimes send them.
    @Test func evidenceTakesTheShapesCallersSend() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let (_, worker) = try working(root, runtime, acceptance: ["test -f b.txt"])
        let text = String(decoding: try JSONSerialization.data(withJSONObject: [["check": "#1", "how": "test -f b.txt", "result": "exit 0"]]), as: UTF8.self)
        let reported = worker.call("report", done(text, blind: [["found": "no newline at the end", "done": "fixed in 1a2b3c4"], "nothing else"]))
        #expect(!reported.isError, "\(reported.text)")
        #expect(try vault.unaudited(root: root, task: "add-b").evidence?.blindCheck == "done: fixed in 1a2b3c4; found: no newline at the end\nnothing else")
    }

    /// A task with no acceptance checks (add_task asks for one, but an older board can have none) needs a single entry.
    @Test func aTaskWithNoAcceptanceChecksNeedsOneEntry() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let (_, worker) = try working(root, runtime, acceptance: ["a"])
        try BoardStore(root: root).update { board in
            let index = try #require(board.taskIndex("add-b"))
            board.tasks[index].contract.acceptance = []
        }
        let refused = worker.call("report", done([]))
        #expect(refused.isError && refused.text.contains("needs `evidence`"), "\(refused.text)")
        #expect(!worker.call("report", done([["check": "the goal", "how": "ls", "result": "b.txt is there"]])).isError)
    }

    /// The evidence is the vault's, so a worker can't rewrite it through the board; board(task), the verifier's prompt
    /// and merge's result show it.
    @Test func theEvidenceShowsInTheBoardTheVerifierAndTheMerge() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let (lead, worker) = try working(root, runtime)
        #expect(!worker.call("report", done(Self.full)).isError)
        // board.json is anyone's to write: what a worker puts there isn't its evidence.
        try BoardStore(root: root).update { board in
            let index = try #require(board.taskIndex("add-b"))
            board.tasks[index].report = "added b.txt"
        }

        let shown = lead.call("board", ["task": "add-b"]).text
        let head = Git.run(["rev-parse", "agent/add-b"], in: root).output
        #expect(shown.contains("Its worker's evidence with its done on \(head.prefix(8)):\n- 1: `test -f b.txt` in the worktree → exit 0\n"), "\(shown)")
        #expect(shown.contains("- LeadDoneEvidenceTests: swift test --filter LeadDoneEvidenceTests → 9 tests passed (screenshots: shots/board.png)"))
        #expect(shown.contains("Blind check: Found: b.txt lacked a newline. Fixed in the last commit."))

        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        let prompt = try String(contentsOf: vault.runFolder(root: root, name: "verify-add-b").appendingPathComponent("prompt.md"), encoding: .utf8)
        let section = try #require(prompt.range(of: LeadPrompts.reportHeading)).upperBound
        let report = prompt[section...]
        #expect(report.contains("its evidence is what it says it ran and saw: run the checks yourself, and a claimed result your run doesn't reproduce is a finding"))
        #expect(report.contains("added b.txt\n\nIts evidence, check by check (what it says it ran and saw):\n- 1: `test -f b.txt` in the worktree → exit 0"), "\(report)")
        #expect(report.contains("Blind check: Found: b.txt lacked a newline."))
    }

    @Test func mergesResultQuotesTheEvidence() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let (lead, worker) = try working(root, runtime, acceptance: ["test -f b.txt"])
        #expect(!worker.call("report", done([Self.full[0]], blind: "Nothing blocking.")).isError)
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(merged.text.contains("Its worker's evidence: 1: exit 0. Blind check: Nothing blocking."), "\(merged.text)")
    }

    /// An audited task merged at a commit its worker didn't report done on: the result doesn't quote the older done's
    /// evidence as this commit's.
    @Test func mergeQuotesNoEvidenceOfAnOlderCommit() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let (lead, worker) = try working(root, runtime, acceptance: ["test -f b.txt"])
        #expect(!lead.call("update_task", ["task": "add-b", "review": "audit"]).isError)
        #expect(!worker.call("report", done([Self.full[0]], blind: "Nothing blocking.")).isError)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "more\n".write(toFile: worktree + "/c.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "c.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add c, unreported"], in: worktree)
        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        let verifier = try seat("verify-add-b", runtime)
        #expect(!verifier.call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "test -f b.txt: exit 0", "tests": "passed"]).isError)
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        #expect(!merged.text.contains("Its worker's evidence"), "\(merged.text)")
    }

    /// A done recorded before evidence was asked for (an older tool server, an older vault) still reads, and merges.
    @Test func anOlderDoneWithoutEvidenceStillReads() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let (lead, worker) = try working(root, runtime, acceptance: ["test -f b.txt"])
        let head = Git.run(["rev-parse", "agent/add-b"], in: root).output
        _ = worker
        let seat = FakeSeat(runtime, agent: LeadAgent(pid: 7002, tty: "ttys072", session: try launched("worker-add-b", runtime).session))
        try vault(for: seat).reportDone(root: root, task: "add-b", commit: head)
        try BoardStore(root: root).update { board in
            let index = try #require(board.taskIndex("add-b"))
            board.tasks[index].report = "added b.txt"
            board.tasks[index].status = .review
        }
        let shown = lead.call("board", ["task": "add-b"])
        #expect(!shown.isError && !shown.text.contains("Its worker's evidence"), "\(shown.text)")
        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError && !merged.text.contains("Its worker's evidence"), "\(merged.text)")
        // A vault reply from a host that predates evidence decodes, with none.
        let older = #"{"unaudited":{"review":"audit","reported":"abc"}}"#
        #expect(try JSONDecoder().decode(LeadVault.Reply.self, from: Data(older.utf8)) == .unaudited(review: .audit, reported: "abc", evidence: nil))
    }

    /// The worker's brief describes the evidence and the blind check: the Agent tool, a prompt holding only the contract
    /// and the branch's diff, blocking problems each with a failure scenario.
    @Test func theWorkerBriefDescribesTheEvidenceAndTheBlindCheck() throws {
        let root = try repo()
        let (_, worker) = try working(root, FakeRuntime())
        let task = LeadTask(slug: "t", title: "T", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        var workflow = LeadWorkflow()
        workflow.baseBranch = "project-lead"
        let brief = LeadPrompts.worker(task: task, root: "/repo", workflow: workflow, policy: "", lints: [])
        #expect(brief.contains("Evidence: report done with `evidence`, one entry per acceptance check: check (its number, 1 for the first, or its text), how (the command you ran and what it printed, the test's name, or what you looked at), result (what it showed), and screenshots (the paths of any screenshots you took, optional)."))
        #expect(brief.contains("A done report without an entry for every check is refused, naming the ones missing; blocked needs none."))
        #expect(brief.contains("Blind check: before you report done, start a fresh subagent with the Agent tool whose prompt holds only your task's contract (the Task section below, as written) and the output of `git diff project-lead...HEAD`: not your reasoning, notes or summary."))
        #expect(brief.contains("Ask it for any problem that would block the merge, each with a concrete failure scenario (the input or state, and what goes wrong then), and nothing cosmetic. Fix what it finds, or say why not."))
        #expect(brief.contains("Then put in `blind_check` what it found"))
        // The report tool says so too.
        let tool = try #require(worker.tools.first { $0.name == "report" })
        #expect(tool.properties["evidence"]?.type == "array" && tool.properties["blind_check"] != nil)
        #expect(tool.description.contains("Done needs evidence for every acceptance check"))
    }

    @Test func anEntryNamesACheckByNumberOrText() {
        let check = "b.txt says bee, one line, nothing else in it"
        for said in ["2", "#2", "Check 2", "check #2", "AC2", "2.", "2) b.txt", "2: the bee one", " 2 "] {
            #expect(LeadDoneEvidence.covers(said, number: 2, text: check), "\(said)")
        }
        for said in ["3", "12", "2 workers", "b.txt", "bee", ""] {
            #expect(!LeadDoneEvidence.covers(said, number: 2, text: check), "\(said)")
        }
        #expect(LeadDoneEvidence.covers("B.TXT says bee — one line; nothing else in it!", number: 2, text: check))
        #expect(LeadDoneEvidence.covers("b.txt says bee, one line", number: 2, text: check))
        #expect(LeadDoneEvidence.covers("Check: `test -f b.txt` (exit 0)", number: 1, text: "test -f b.txt"))
        // Whole words only: a short check isn't in a longer word.
        #expect(!LeadDoneEvidence.covers("passed", number: 1, text: "a"))
        #expect(!LeadDoneEvidence.covers("b.txt is there", number: 1, text: "test -f b.txt"))
    }
}
