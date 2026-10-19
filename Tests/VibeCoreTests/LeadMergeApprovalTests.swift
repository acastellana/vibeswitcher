import Foundation
import Testing
@testable import VibeCore

/// The user's approval of a held merge lives in the vault, written by the app when they answer, bound to the project,
/// the task and the whole commit: an approval only board.json shows (a lead's or worker's Bash can write it) doesn't
/// merge anything, and no session of the team can write one into the vault.
extension LeadMergePolicyTests {
    /// They cross the host's socket as JSON.
    @Test func theApprovalMessagesReadBackAsSent() throws {
        let commit = String(repeating: "ab", count: 20)
        let requests: [LeadVault.Request] = [.approve(root: "/r", task: "change", commit: commit),
                                             .approved(root: "/r", task: "change", commit: commit)]
        for request in requests {
            #expect(try JSONDecoder().decode(LeadVault.Request.self, from: JSONEncoder().encode(request)) == request)
        }
        for reply in [LeadVault.Reply.approved(true), .approved(false)] {
            #expect(try JSONDecoder().decode(LeadVault.Reply.self, from: JSONEncoder().encode(reply)) == reply)
        }
    }

    @Test func anApprovalNamesAWholeCommit() {
        let commit = String(repeating: "ab", count: 20)
        #expect(LeadVault.approvedCommit(in: "Approve \(commit)") == commit)
        #expect(LeadVault.approvedCommit(in: "  approve \(commit.uppercased())\n") == commit)
        #expect(LeadVault.approvedCommit(in: "Approve \(String(repeating: "cd", count: 32))") == String(repeating: "cd", count: 32))
        for answer in ["Approve \(commit.prefix(12))", "Not yet", "Approve \(commit) and more", "Approve", "\(commit)",
                       "Approve \(String(repeating: "zz", count: 20))", "Disapprove \(commit)"] {
            #expect(LeadVault.approvedCommit(in: answer) == nil, "\(answer)")
        }
    }

    @Test func aForgedBoardApprovalDoesntMerge() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "ask_all"]).isError)
        let commit = try audited(lead, runtime, root: root, file: "b.txt")
        // The lead (or a worker) asks and answers in board.json itself: the board shows the user's approval.
        let outcome = try forged(root, LeadWorkflow.approval(of: commit))
        guard case .answered(let question, _) = outcome else { Issue.record("not answered: \(outcome)"); return }
        #expect(LeadWorkflow.approves(question, commit: commit))
        let refused = lead.call("merge", ["task": "change"])
        #expect(refused.isError)
        #expect(refused.text.contains("The board shows an approval of \(commit.prefix(8))"), "\(refused.text)")
        #expect(refused.text.contains("only their answer there counts"))
        #expect(BoardStore(root: root).load().task("change")?.status != .done)
        // A board.json written whole (the question already answered, as the app would leave it) doesn't either.
        var board = BoardStore(root: root).load()
        board.questions.append(question)
        try JSONEncoder().encode(board).write(to: URL(fileURLWithPath: BoardStore(root: root).folder + "/board.json"))
        #expect(lead.call("merge", ["task": "change"]).isError)
        #expect(try !vault.approved(root: root, task: "change", commit: commit))

        // The user answers in the app: it merges.
        try answer(root, LeadWorkflow.approval(of: commit))
        #expect(try vault.approved(root: root, task: "change", commit: commit))
        let merged = lead.call("merge", ["task": "change"])
        #expect(!merged.isError, "\(merged.text)")
    }

    @Test func noSessionOfTheTeamRecordsAnApproval() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "ask_all"]).isError)
        let commit = try audited(lead, runtime, root: root, file: "b.txt")
        // The lead's own session, the task's worker and verifier, and anything outside the sessions.
        let worker = FakeSeat(runtime, agent: LeadAgent(pid: 7200, tty: "ttys072", session: try launched("worker-change", runtime).session))
        let verifier = FakeSeat(runtime, agent: LeadAgent(pid: 7201, tty: "ttys073", session: try launched("verify-change", runtime).session))
        let callers: [LeadRuntime] = [runtime, worker, verifier, NoAgent(runtime)]
        for caller in callers {
            let theirs = vault(for: caller)
            #expect(throws: LeadVault.Refused.self) { try theirs.approve(root: root, task: "change", commit: commit) }
            // Nor through the app's answer path run in their session.
            let question = LeadQuestion(text: "Merge change?", options: [LeadWorkflow.approval(of: commit)])
            var answered = question
            answered.answer = LeadWorkflow.approval(of: commit)
            #expect(throws: LeadVault.Refused.self) { try theirs.recordApproval(LeadWorkflow.approval(of: commit), of: answered, root: root) }
            // They can read whether there's one.
            #expect(try !theirs.approved(root: root, task: "change", commit: commit))
        }
        #expect(lead.call("merge", ["task": "change"]).isError)
        #expect(try !vault.approved(root: root, task: "change", commit: commit))
    }

    @Test func anApprovalIsBoundToTheProjectTheTaskAndTheCommit() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("configure", ["merge_policy": "ask_all"]).isError)
        let commit = try audited(lead, runtime, root: root, file: "b.txt")
        // Another task at that commit, another project, or a prefix of the commit: none approves this merge.
        try vault.approve(root: root, task: "other", commit: commit)
        try vault.approve(root: temp.url("elsewhere").path, task: "change", commit: commit)
        #expect(throws: LeadVault.Refused.self) { try vault.approve(root: root, task: "change", commit: String(commit.prefix(12))) }
        #expect(throws: LeadVault.Refused.self) { try vault.approve(root: root, task: "", commit: commit) }
        #expect(lead.call("merge", ["task": "change"]).isError)
        // The commit is recorded whole, however it was written.
        try vault.approve(root: root, task: "change", commit: commit.uppercased())
        #expect(try vault.approved(root: root, task: "change", commit: commit))
        #expect(!lead.call("merge", ["task": "change"]).isError)
    }

    @Test func theAppRecordsOnlyAnAnsweredApprovalForTheTaskAtThatCommit() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        let commit = try audited(lead, runtime, root: root, file: "b.txt")
        var question = LeadQuestion(text: "Merge change?", options: [LeadWorkflow.approval(of: commit), "Not yet"])
        question.answer = LeadWorkflow.approval(of: commit)
        // Not an approval, withdrawn, or decided by its timer: nothing is recorded.
        var notYet = question
        notYet.answer = "Not yet"
        #expect(try vault.recordApproval("Not yet", of: notYet, root: root) == nil)
        var withdrawn = question
        withdrawn.withdrawnAt = 1
        #expect(try vault.recordApproval(LeadWorkflow.approval(of: commit), of: withdrawn, root: root) == nil)
        var timedOut = question
        timedOut.autoDecidedAt = 1
        #expect(try vault.recordApproval(LeadWorkflow.approval(of: commit), of: timedOut, root: root) == nil)
        #expect(try !vault.approved(root: root, task: "change", commit: commit))
        // A commit no task's branch is at: nothing to bind it to.
        let nowhere = String(repeating: "0", count: 40)
        #expect(try vault.recordApproval(LeadWorkflow.approval(of: nowhere), of: question, root: root) == [])
        // Answered: for the task whose branch is at it.
        #expect(try vault.recordApproval(LeadWorkflow.approval(of: commit), of: question, root: root) == ["change"])
        #expect(try vault.approved(root: root, task: "change", commit: commit))
        // Retired, the task's approvals go: a new task of that name starts with none.
        try vault(for: runtime).retire(root: root, task: "change")
        #expect(try !vault.approved(root: root, task: "change", commit: commit))
    }
}
