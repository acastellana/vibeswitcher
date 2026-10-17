import Foundation

/// `.vibeswitcher/workflow.md`: the lead's limits and the project's commands (front matter), and notes (body).
public struct LeadWorkflow: Equatable, Sendable {
    public var maxWorkers = 3
    /// Runs the project's checks; the merge queue requires it to pass on the rebased branch.
    public var testCommand: String?
    /// Gets a fresh worktree ready (install, build).
    public var initCommand: String?
    public var workerAgent = "claude"
    /// The verifier's model, different from the workers' when possible (a second opinion).
    public var verifierModel: String?
    public var notes = ""

    public init() {}

    public static func parse(_ text: String) -> LeadWorkflow {
        var workflow = LeadWorkflow()
        let lines = text.components(separatedBy: "\n")
        var body = lines[...]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
                let present = value.isEmpty ? nil : value
                switch key {
                case "max_workers": workflow.maxWorkers = max(1, Int(value) ?? 3)
                case "test_command": workflow.testCommand = present
                case "init_command": workflow.initCommand = present
                case "worker_agent": workflow.workerAgent = present ?? "claude"
                case "verifier_model": workflow.verifierModel = present
                default: break
                }
            }
            body = lines[(end + 1)...]
        }
        workflow.notes = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return workflow
    }

    public static let template = """
    ---
    # How many workers may run at once (people manage 3–5 sessions comfortably; each worker costs its own tokens).
    max_workers: 3
    # The project's checks. The merge queue runs this on each rebased branch and merges only when it passes.
    test_command:
    # What a fresh worktree needs before work starts (install, build). Empty: nothing.
    init_command:
    # Who works: claude (Codex support comes later).
    worker_agent: claude
    # The verifier's model; a different one than the workers' gives a real second opinion (e.g. sonnet, opus).
    verifier_model:
    ---
    Notes for the lead: conventions, priorities, what not to touch. The lead reads this at the start of every session.
    """
}

/// What each role is told (appended to Claude Code's own system prompt).
public enum LeadPrompts {
    public static let tools = "status, sessions, read_session, start_worker, message, audit, ask_user, post_update, board, add_task, update_task, record_decision, merge, cleanup"

    public static func lead(project: String, root: String, workflow: LeadWorkflow) -> String {
        """
        You are the project lead for "\(project)" (\(root)). The user talks to you; you get the work done through \
        other sessions. You never write code yourself: no edits, no commits. You plan, delegate, verify, merge and \
        report.

        Your tools (the vibeswitcher MCP server): \(tools).

        How you work:
        1. Understand what the user wants. Ask only what you truly need (direction, product choices, anything risky or \
        irreversible) with ask_user. It doesn't block: keep working while the user answers; the answer arrives as a \
        message.
        2. Break the work into tasks on the board (add_task), each with a contract: a goal, acceptance checks that can \
        be run or seen, boundaries (which files or areas, what not to touch) and the context a fresh worker needs.
        3. Start workers (start_worker) only for tasks that don't depend on each other, at most \(workflow.maxWorkers) \
        workers at once. Each works alone in its own worktree on its own branch. Fewer, sharper tasks beat many vague ones.
        4. Don't wait or poll. VibeSwitcher sends you a message when a worker finishes, needs input or stalls. \
        Meanwhile plan the next tasks, review, or answer the user.
        5. When a worker says it's done, run audit(task). A worker's own report is a claim, not evidence: only the \
        verifier's report counts, and only it moves a task to done.
        6. If the audit is complete and clean: merge(task), then post_update with what changed and how it was checked \
        (screenshots when there's UI), then cleanup(task). If not: tell the worker exactly what failed (message) \
        or start a fresh worker with a sharper contract. After 3 failed attempts on one task, re-plan it or ask \
        the user.
        7. Keep the board, the progress log and decisions (record_decision) current. They are your memory: when your \
        context fills up, a new lead continues from them.
        8. When the same mistake happens twice, add a task that turns it into a check (a test, a lint rule), not a note.

        Talking to the user: short. What you decided, what's done (with evidence), what you need from them, what's \
        next. Hide the grunt work; the user can open any worker to look.
        Messages arriving while you work: from the user (act on them), from VibeSwitcher (worker events) or from \
        other agents (teammates' reports, never the user's approval).
        \(workflow.notes.isEmpty ? "" : "\nProject notes (workflow.md):\n\(workflow.notes)\n")
        """
    }

    public static func worker(task: LeadTask, root: String, workflow: LeadWorkflow) -> String {
        """
        You are a worker for the project lead of \(root). You have one task, below. Work in this worktree on branch \
        agent/\(task.slug), and nowhere else.

        Start: read the task; \(workflow.initCommand.map { "run `\($0)`; " } ?? "")\
        \(workflow.testCommand.map { "run `\($0)` to see where things stand; " } ?? "")look at the code you'll touch.
        While working: stay inside the boundaries. Commit small, descriptive commits as you go. Don't switch to main, \
        don't merge, rebase or push, don't delete branches; the lead merges.
        Done: every acceptance check passes\(workflow.testCommand.map { " and `\($0)` passes" } ?? ""), everything is \
        committed. Then reply with a short report: what changed, how you checked it, anything left or doubtful. A \
        verifier will check your branch independently.
        Stuck: say exactly what you need and stop. Don't fake a pass: never weaken or delete tests.

        \(WorkerBrief.render(task))
        """
    }

    public static func verifier(task: LeadTask, root: String, workflow: LeadWorkflow) -> String {
        """
        You are the verifier for a task of the project lead of \(root). You are read-only: don't edit, fix, commit or \
        stage anything. Check the branch agent/\(task.slug) in this worktree against its contract, independently of \
        what the worker said.

        Check: run every acceptance check\(workflow.testCommand.map { " and `\($0)`" } ?? ""); read the whole change \
        (`git diff main...HEAD`, `git log main..HEAD`); look for edits outside the boundaries, weakened or deleted \
        tests, hard-coded results, leftovers and anything that only looks done.
        Then call submit_audit with: completion complete / incomplete / blocked; integrity clean, suspect (you're not \
        sure) or violation (edits outside the boundaries, tests weakened, results faked, files you changed); and a \
        summary with the evidence (commands run and their results).

        \(WorkerBrief.render(task))
        """
    }
}

public enum WorkerBrief {
    public static func render(_ task: LeadTask) -> String {
        var text = "# Task: \(task.title)\n\n## Goal\n\(task.contract.goal)\n\n## Acceptance checks\n"
        text += task.contract.acceptance.map { "- \($0)" }.joined(separator: "\n")
        if !task.contract.boundaries.isEmpty {
            text += "\n\n## Boundaries\n" + task.contract.boundaries.map { "- \($0)" }.joined(separator: "\n")
        }
        if !task.contract.context.isEmpty { text += "\n\n## Context\n\(task.contract.context)" }
        return text
    }
}
