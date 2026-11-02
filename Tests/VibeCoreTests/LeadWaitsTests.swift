import Foundation
import Testing
@testable import VibeCore

/// A task's time between its start and its end, split by cause from the timestamps its board keeps (`LeadWaits`):
/// waiting for an audit to start, auditing, the merge's test runs waiting and running. Copied into its receipt.
struct LeadWaitsTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    func repo() throws -> String {
        let url = temp.url("lead")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    static func task(_ waits: LeadWaits? = nil) -> LeadTask {
        var task = LeadTask(slug: "change", title: "Change", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        task.createdAt = 0
        task.startedAt = 10
        task.worked = 50
        task.waits = waits
        return task
    }

    @Test func aHandBuiltHistoryIsSplitByCause() throws {
        var task = Self.task()
        // Done at 100; a 2-finder audit starts at 160 (60 s waited) and gives its verdict at 460 (300 s, 600 verifier s).
        task.noteWaits { $0.reportedDone(at: 100) }
        task.noteWaits { $0.auditStarted(at: 160, sessions: 2) }
        task.noteWaits { $0.auditEnded(at: 460) }
        // Reworked, done again at 1000; an audit at 1030 (30 s waited) whose verifier ends without a verdict: the next
        // audit, at 1300, ends it (270 s) and runs till the task's end.
        task.noteWaits { $0.reportedDone(at: 1000) }
        task.noteWaits { $0.auditStarted(at: 1030, sessions: 1) }
        task.noteWaits { $0.auditStarted(at: 1300, sessions: 1) }
        #expect(task.waits?.auditAt == 1300 && task.waits?.doneAt == nil)
        // Two merge runs: the first waited 20 s for the load and 10 s for a slot and ran 90 s; the second never started.
        let called = Date(timeIntervalSince1970: 2000)
        task.noteMergeRun(loadWait: 20, called: called, begun: called.addingTimeInterval(10), ended: called.addingTimeInterval(100))
        task.noteMergeRun(loadWait: 5, called: called, begun: nil, ended: called.addingTimeInterval(7))
        // A done report after the last audit that no audit followed waits for nothing counted.
        task.noteWaits { $0.reportedDone(at: 1400) }

        let receipt = LeadReceipt(task, ending: .merged, questions: [], usage: LeadReceipts.Usage(), now: 1500)
        let waits = try #require(receipt.waits)
        #expect(waits.auditWait == 90)
        let auditing: Double = 300 + 270 + 200, verifierTime: Double = 600 + 270 + 200
        #expect(waits.auditing == auditing, "\(String(describing: waits.auditing))")
        #expect(waits.verifierTime == verifierTime, "\(String(describing: waits.verifierTime))")
        #expect(waits.mergeLoadWait == 25 && waits.mergeSlotWait == 10 && waits.mergeTesting == 90)
        #expect(waits.doneAt == nil && waits.auditAt == nil && waits.auditSessions == nil)
        // The task itself keeps its open marks (it may reopen): only the receipt's copy is closed.
        #expect(task.waits?.auditAt == 1300 && task.waits?.doneAt == 1400)
        // Its other causes stay where they were: the worker's time and the user's.
        #expect(receipt.worked == 50 && receipt.waitingOnUser == 0)
    }

    @Test func boardsAndReceiptsFromBeforeWaitsDecodeUnchangedAndNewOnesRoundTrip() throws {
        // A task and its receipt as boards before this change wrote them: no waits, no codex.
        var old = Self.task()
        old.receipt = LeadReceipt(ending: .merged, startedAt: 10, endedAt: 100, worked: 50,
                                  worker: LeadTokens(input: 1, output: 2, models: ["claude-opus-5-5"]), verifier: nil)
        let encoder = JSONEncoder()
        var json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(old)) as? [String: Any])
        #expect(json["waits"] == nil)
        var receipt = try #require(json["receipt"] as? [String: Any])
        #expect(receipt["waits"] == nil && (receipt["worker"] as? [String: Any])?["codex"] == nil)
        // The fields an older build had, only.
        receipt.removeValue(forKey: "waits")
        json["receipt"] = receipt
        let decoded = try JSONDecoder().decode(LeadTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == old && decoded.waits == nil && decoded.receipt?.waits == nil && decoded.receipt?.worker?.codex == nil)

        var new = old
        new.waits = LeadWaits(doneAt: 5, auditWait: 1, auditAt: 7, auditSessions: 2, auditing: 3, verifierTime: 6, mergeLoadWait: 4,
                              mergeSlotWait: 8, mergeTesting: 9)
        new.receipt?.waits = new.waits?.closed(at: 10)
        new.receipt?.worker?.codex = 3
        #expect(try JSONDecoder().decode(LeadTask.self, from: encoder.encode(new)) == new)
    }

    @Test func theToolsRecordEachWaitOnTheBoardAndTheReceipt() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        _ = lead.call("add_task", ["title": "Add b", "goal": "b.txt exists", "acceptance": ["test -f b.txt"], "review": "audit"])
        #expect(!lead.call("start_worker", ["task": "add-b"]).isError)
        let worktree = Worktrees.path(root: root, slug: "add-b")
        try "bee\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "b.txt"], in: worktree)
        Git.run(["commit", "-q", "-m", "add b"], in: worktree)
        let before = Date().timeIntervalSince1970
        #expect(!(try seat("worker-add-b", runtime)).call("report", doneReport("added b.txt")).isError)
        let reported = try #require(BoardStore(root: root).load().task("add-b")?.waits?.doneAt)
        #expect(reported >= before)

        #expect(!lead.call("audit", ["task": "add-b"]).isError)
        let auditing = try #require(BoardStore(root: root).load().task("add-b")?.waits)
        #expect(auditing.doneAt == nil && auditing.auditSessions == 1 && (auditing.auditAt ?? 0) >= reported)
        #expect(auditing.auditWait == (auditing.auditAt ?? 0) - reported)

        let verdict = try seat("verify-add-b", runtime).call("submit_audit", ["completion": "complete", "integrity": "clean", "summary": "ok"])
        #expect(!verdict.isError, "\(verdict.text)")
        let audited = try #require(BoardStore(root: root).load().task("add-b")?.waits)
        #expect(audited.auditAt == nil && audited.auditing != nil && audited.verifierTime == audited.auditing)

        let merged = lead.call("merge", ["task": "add-b"])
        #expect(!merged.isError, "\(merged.text)")
        let task = try #require(BoardStore(root: root).load().task("add-b"))
        let waits = try #require(task.receipt?.waits)
        #expect(waits.auditWait == audited.auditWait && waits.auditing == audited.auditing)
        // No load_threshold: no load wait; the scratch lock was free: a slot wait of about nothing, and a test run.
        #expect(waits.mergeLoadWait == 0 && waits.mergeSlotWait != nil && waits.mergeTesting != nil)
        #expect(task.waits?.mergeTesting == waits.mergeTesting)
    }
}
