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

    /// Your answer to `question`, as the app records it after the board took it (`LeadBoard.answer` said `.answered`):
    /// when it approves a commit, the approval goes to the vault for each task whose branch (agent/<slug>) is at that
    /// commit now (the one merge holds back is). The tasks it was recorded for; nil when the answer approves nothing.
    @discardableResult
    public func recordApproval(_ answer: String, of question: LeadQuestion, root: String) throws -> [String]? {
        guard question.state == .answered, let commit = Self.approvedCommit(in: answer) else { return nil }
        let refs = Git.run(["for-each-ref", "--points-at", commit, "--format=%(refname:short)", "refs/heads/agent/"], in: root)
        guard refs.ok else { throw Refused("Couldn't tell which task's branch is at \(commit.prefix(8)) (\(refs.error)).") }
        let tasks = refs.output.split(whereSeparator: \.isNewline).map { String($0.dropFirst("agent/".count)) }.filter { !$0.isEmpty }
        for task in tasks { try approve(root: root, task: task, commit: commit) }
        return tasks
    }
}
