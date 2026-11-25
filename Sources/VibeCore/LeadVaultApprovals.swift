import Foundation

/// The user's approvals of held merges (workflow.md's merge_policy, ask_sensitive or ask_all): kept in the vault, bound
/// to the project, the task and the full commit, and written by the app only, when you answer "Approve <commit>" in
/// it. The board's copy of your answer is for showing: board.json is in the project's `.vibeswitcher` folder, which
/// the lead and its workers can write (Bash isn't held by the roles' deny rules), so merge doesn't take an approval
/// from it.
extension LeadVault {
    /// The commit an answer approves (`LeadWorkflow.approval(of:)`): a whole one, 40 hex digits (64 in a SHA-256
    /// repository), lowercased; nil when the answer approves none.
    public static func approvedCommit(in answer: String) -> String? {
        let words = answer.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
        guard words.count == 2, words[0].caseInsensitiveCompare("Approve") == .orderedSame else { return nil }
        let commit = words[1].lowercased()
        return isFullCommit(commit) ? commit : nil
    }

    static func isFullCommit(_ commit: String) -> Bool {
        (commit.count == 40 || commit.count == 64) && commit.allSatisfy { $0.isHexDigit }
    }

    /// The user approved merging `task` at `commit` (the app only).
    public func approve(root: String, task: String, commit: String) throws {
        _ = try call(.approve(root: root, task: task, commit: commit))
    }

    /// Whether the user approved merging `task` at exactly `commit`, as the app recorded it here.
    public func approved(root: String, task: String, commit: String) throws -> Bool {
        guard case .approved(let approved) = try call(.approved(root: root, task: task, commit: commit)) else { throw Self.unexpected }
        return approved
    }

    /// An answer allowing a model to audit a task at one commit, the floor having left none (`LeadToolset
    /// .askWhichModelAudits`'s options): "Audit <task> at <commit> on <model>"; nil otherwise.
    public static func auditGrant(in answer: String) -> (task: String, commit: String, model: String)? {
        let words = answer.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == 6, words[0].caseInsensitiveCompare("Audit") == .orderedSame, words[2].lowercased() == "at", words[4].lowercased() == "on",
              words[3].count >= 7, words[3].allSatisfy(\.isHexDigit), let family = WorkerLaunch.family(of: words[5]) else { return nil }
        return (words[1], words[3].lowercased(), family)
    }

    /// Your answer to `question` when it allows a model to audit a task (`auditGrant`), recorded in the vault by the app
    /// (a merge approval's way), only when the answer is one of the question's options, names the task the question is
    /// about, and the question is one the lead's audit asked (the vault's `AuditOffer` for it, at that commit). What to
    /// tell the user ("recorded: …"), or why it wasn't; nil when the answer allows nothing.
    public func recordAuditGrant(_ answer: String, of question: LeadQuestion, root: String) -> String? {
        guard question.state == .answered, let grant = Self.auditGrant(in: answer) else { return nil }
        let refused = "No model was allowed to audit \(grant.task): "
        guard question.options.contains(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(answer.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }) else {
            return refused + "the answer isn't one of the question's options."
        }
        guard question.task == grant.task else { return refused + "the question isn't about \(grant.task)." }
        do {
            _ = try call(.allowAuditModel(root: root, task: grant.task, commit: grant.commit, model: grant.model, question: question.id))
        } catch {
            return refused + "\(error)"
        }
        return "Recorded: \(grant.task) may be audited on \(grant.model) at \(grant.commit.prefix(12)), by its next audit only."
    }

    /// Your answer to `question`, as the app records it after the board took it (`LeadBoard.answer` said `.answered`):
    /// when it approves a commit, the approval goes to the vault for each task whose branch (agent/<slug>) is at that
    /// commit now (the one merge holds back is). The tasks it was recorded for; nil when the answer approves nothing.
    /// An answer allowing a model to audit a task is recorded too (`recordAuditGrant`, which says what it recorded).
    @discardableResult
    public func recordApproval(_ answer: String, of question: LeadQuestion, root: String) throws -> [String]? {
        guard question.state == .answered else { return nil }
        if Self.auditGrant(in: answer) != nil {
            _ = recordAuditGrant(answer, of: question, root: root)
            return nil
        }
        guard let commit = Self.approvedCommit(in: answer) else { return nil }
        let refs = Git.run(["for-each-ref", "--points-at", commit, "--format=%(refname:short)", "refs/heads/agent/"], in: root)
        guard refs.ok else { throw Refused("Couldn't tell which task's branch is at \(commit.prefix(8)) (\(refs.error)).") }
        let tasks = refs.output.split(whereSeparator: \.isNewline).map { String($0.dropFirst("agent/".count)) }.filter { !$0.isEmpty }
        for task in tasks { try approve(root: root, task: task, commit: commit) }
        return tasks
    }
}
