import Foundation

/// A task's merge dry run (merge(task, dry_run: true)), kept on the task: when the merge's own rebase and test run
/// ended, whether it passed, on which commit and onto which head of the base. A team experiment's arm is compared at
/// merge-ready (the merge's test run passing after a passing audit), and the arm that isn't merged gets that time from
/// here (`LeadReceipt.mergeReady`, once it's kept).
public struct LeadDryRun: Codable, Equatable, Sendable {
    /// Its fields, behind one reference: `LeadTask` is copied whole many times in one stack frame (update_task's board
    /// change), and its size is what that frame grows by. Inline, these fields overflowed a test thread's stack.
    private final class Fields: Codable, Equatable, Sendable {
        let at: Double
        let passed: Bool
        let commit: String
        let onto: String
        let tests: Int?
        let rerun: Bool?
        let reason: String?

        init(at: Double, passed: Bool, commit: String, onto: String, tests: Int?, rerun: Bool?, reason: String?) {
            self.at = at
            self.passed = passed
            self.commit = commit
            self.onto = onto
            self.tests = tests
            self.rerun = rerun
            self.reason = reason
        }

        static func == (a: Fields, b: Fields) -> Bool {
            a.at == b.at && a.passed == b.passed && a.commit == b.commit && a.onto == b.onto && a.tests == b.tests && a.rerun == b.rerun && a.reason == b.reason
        }
    }

    private let fields: Fields

    /// When its test run was decided.
    public var at: Double { fields.at }
    public var passed: Bool { fields.passed }
    /// The branch's commit it rebased (the audited one), and the base's head it went onto.
    public var commit: String { fields.commit }
    public var onto: String { fields.onto }
    /// The tests its passing run reported (nil: none ran, or its output named no count).
    public var tests: Int? { fields.tests }
    /// It passed on its rerun (`MergeRerun`), or failed: why, in one line.
    public var rerun: Bool? { fields.rerun }
    public var reason: String? { fields.reason }

    public init(at: Double, passed: Bool, commit: String, onto: String, tests: Int? = nil, rerun: Bool? = nil, reason: String? = nil) {
        fields = Fields(at: at, passed: passed, commit: commit, onto: onto, tests: tests, rerun: rerun, reason: reason)
    }

    // Encoded flat, as its fields: {"at": …, "passed": …, …}.
    public init(from decoder: Decoder) throws { fields = try Fields(from: decoder) }
    public func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }

    /// "passed at 14:02 (1234 tests), agent/x's 3f2a1b4c onto main at 9c0d1e2f"; "failed at 14:02: Tests fail …".
    public func text(slug: String, base: String) -> String {
        (passed ? "passed at \(LeadBoard.clock(at))" + (tests.map { " (\($0) tests\(rerun == true ? ", on its rerun" : ""))" } ?? (rerun == true ? " (on its rerun)" : ""))
                : "failed at \(LeadBoard.clock(at))" + (reason.map { ": \($0)" } ?? ""))
            + ", agent/\(slug)'s \(commit.prefix(8)) onto \(base) at \(onto.prefix(8))"
    }
}

extension LeadToolset {
    /// merge(task, dry_run: true): what merge does up to its fast-forward, and no further. The same gate (a passing
    /// audit), merge's own lock for the task (a real merge of it under way refuses this, and this one refuses that),
    /// the same wait for the Mac's load and the same Mac-wide test slot, the same rebase and test command (and rerun)
    /// in a detached scratch worktree that's removed after, pass or fail. Nothing moves: no records committed first,
    /// no fast-forward, the task's state, branch and worktree as they were (a failure isn't sent back to its worker,
    /// and its log isn't copied into its worktree). Its pass or failure, with the time, goes on the task (`dryRun`),
    /// and its waits into the task's `LeadWaits`, as a merge's do. A run that hung, was cancelled or errored says so
    /// and records no result.
    func dryRunMerge(_ slug: String, acceptStale: String? = nil) throws -> MCPToolResult {
        let not = "Dry run not run (nothing was tested)"
        let fetched = try fetchedTip(self.workflow, not: not)
        let gate = try mergeGate(slug, acceptStale: acceptStale, fetched: fetched)
        let commit = gate.commit
        guard let lock = FileLock.attempt((store.folder as NSString).appendingPathComponent("run/merge-\(slug).lock")) else {
            throw Problem(text: "\(not): a merge of \(slug) (or a dry run of it) is already running.")
        }
        defer { lock.release() }
        let workflow = self.workflow
        try checkSettings(workflow, not: not)
        let base = workflow.base
        guard let current = branchHead(base) else { throw Problem(text: "There's no branch \(base) to try \(slug) onto.") }
        let waited = try waitForLoad(workflow, slug: slug, doing: "dry run", done: "run")
        let mark = try markBranchRun(not: not)
        defer { endBranchRun(mark) }
        var rerun: MergeRerun.Plan?
        var testCount: Int?
        let called = Date()
        var begun: Date?
        let pairing = MergeRerun.Pairing()
        let checked = Worktrees.rebaseAndTest(root: root, commit: commit, onto: current, setup: workflow.initCommand, test: workflow.mergeChecks,
                                              scratch: vault.scratch(root: root, "merge-\(slug)"), home: vault.scratch(root: root, "merge-\(slug)-home"),
                                              timeout: workflow.testTimeout, lock: heavyLock(workflow), records: workflow.recordsDir,
                                              remote: fetched, trailers: provenance(gate), rerun: { output in
                                                  rerun = MergeRerun.plan(after: output, workflow: workflow)
                                                  return rerun?.command
                                              }, baseline: baseline(on: current, plan: { rerun }, pairing: pairing),
                                              tested: { testCount = LeadReceipt.testCount($0) },
                                              begun: { begun = $0 })
        let ended = Date()
        // Passed as merge would land it, or why not; nil: nothing is known about the work (hung, cancelled, an error).
        var verdict: (passed: Bool, reason: String?, output: String?, rerun: Bool)?
        switch checked {
        case .passed: verdict = (true, nil, nil, false)
        case .passedOnRerun(_, let failed, let again):
            let unshown = rerun.map { MergeRerun.unshown($0, rerun: again) } ?? ["(no rerun was planned)"]
            verdict = unshown.isEmpty ? (true, nil, nil, true)
                : (false, "its rerun exited 0 but didn't show \(unshown.prefix(8).joined(separator: ", ")) passing", failed + "\n" + again, true)
        case .passedRedOnBase: verdict = (true, nil, nil, true)
        case .conflict: verdict = (false, "conflicts with \(base): the branch needs bringing up to date", nil, false)
        case .failed(let output):
            let what = output.components(separatedBy: "\n").contains(LeadWorkflow.regressionMarker) ? "regression_command fails" : "Tests fail"
            verdict = (false, "\(what) rebased onto \(base): \(MergeFailure.reason(in: scrubbed(output)))", output, false)
        case .cancelled, .hung, .error: verdict = nil
        }
        // What its tests wrote outside the worktree (the agents' config) holds a merge: it fails a dry run.
        if verdict?.passed == true {
            do { try checkConfig(not: "\(slug)'s dry run passed its tests, and after them") } catch let problem as Problem {
                verdict = (false, Self.clip(problem.text, 200), nil, verdict?.rerun ?? false)
            }
        }
        let record = verdict.map {
            LeadDryRun(at: ended.timeIntervalSince1970, passed: $0.passed, commit: commit, onto: current, tests: $0.passed ? testCount : nil,
                       rerun: $0.rerun ? true : nil, reason: $0.reason.map { Self.clip($0, 300) })
        }
        // Its waits for the load and a slot and its run's time, as a merge's (`LeadWaits`), with its result.
        try? store.update { board in
            guard let index = board.taskIndex(slug) else { return }
            board.tasks[index].noteMergeRun(loadWait: waited?.after ?? 0, called: called, begun: begun, ended: ended)
            if let record { board.tasks[index].dryRun = record }
        }
        let waitedText = waited.map { " It waited \(Worktrees.duration($0.after)) for the Mac's load to drop first." } ?? ""
        let unchanged = " Nothing moved: \(base), agent/\(slug) and its worktree are as they were, and \(slug) stays \(LeadToolset.shownState(store.load().task(slug) ?? gate.task))."
        guard let record else {
            switch checked {
            case .cancelled: throw Problem(text: "The dry run of \(slug) was cancelled; nothing is recorded." + unchanged)
            case .hung(let command, let after, let output, let stall):
                _ = saveMergeLog(output, slug: slug, name: "dry-run-hung.log")
                throw Problem(text: "Dry run of \(slug): the \(command == "init_command" ? "init_command" : "tests") \(Worktrees.hung(after: after, stall: stall)), and were stopped; nothing is recorded."
                              + unchanged + "\n" + MergeFailure.end(of: scrubbed(output)))
            case .error(let text): throw Problem(text: "Dry run of \(slug) not run: \(text)" + unchanged)
            default: throw Problem(text: "Dry run of \(slug): no result." + unchanged)
            }
        }
        if record.passed {
            return MCPToolResult(text: "Dry run of \(slug) \(record.text(slug: slug, base: base)): merge-ready at \(LeadBoard.clock(record.at)), not merged."
                                 + waitedText + unchanged + " Kept with update_task(status: kept), its receipt keeps this time.")
        }
        let output = verdict?.output
        if let output { _ = saveMergeLog(output, slug: slug, name: "dry-run-test.log") }
        return MCPToolResult(text: "Dry run of \(slug) \(record.text(slug: slug, base: base)). Not sent back: a dry run only records it."
                             + waitedText + unchanged + (output.map { "\n" + MergeFailure.end(of: scrubbed($0)) } ?? ""), isError: true)
    }
}
