import Foundation

/// Batched merges (workflow.md's `merge_batching`): several review-passed tasks tested with one run of the merge checks
/// instead of one each. On 2026-10-31 the wallet feature was batched by hand (6 heavy runs down to 1); a merge's suite
/// takes ~200 s on a calm Mac and 240–500 s under load, serialized through the Mac-wide heavy slots.
///
/// Each task passes every check merge makes of it on its own first (`mergeGate`: its audit or done report, findings
/// open or held by strict_paths, kept, the merge policy's approval). The ones that do are stacked on the base in the
/// order given (`Worktrees.Stack`: each rebased, or squashed when it merged the base in, onto the one before), and the
/// merge checks run once on the stack, holding one heavy slot. A failing run is rerun as merge reruns one
/// (`MergeRerun`: its failing tests, once); a pass on the rerun lands the stack, the flakes in the ledger. A run that
/// still fails is split: a binary search over the stack's prefixes (each a stack on the base as it is) finds the first
/// task whose prefix fails while the one before passes, in about log2(N) more runs. The prefix that passed lands, the
/// task that breaks it goes back to its worker with its failing output (failed, as a merge's failure sets it), and the
/// tasks after it are stacked again on the new base and tested as a batch of their own. A task that doesn't apply on
/// the stack is left out and told to merge the base. The base only ever moves to a commit a run passed on, through the
/// same fast-forward as merge's, and each task's merge is recorded on its own: its own commit, the one under it as
/// `onto` (so revert undoes just it), its receipt, its line in the merge stats.
///
/// Fail closed: a hang, a cancel, an error, a refused fast-forward, or a task the lead held while the tests ran stops the
/// batch; what wasn't decided stays as it was (`untouched`), and auto_advance merges those one at a time from then on.
extension LeadToolset {
    /// How one of a batch's tasks came out.
    public enum BatchEnd: Equatable, Sendable {
        /// On the base, at this commit.
        case merged(String)
        /// The merge checks fail with it on the stack (after a rerun): failed, with a merge setback; what to tell its worker.
        case failed(String)
        /// It doesn't apply on the base with the batch's tasks before it: failed, told to merge the base.
        case conflict(String)
        /// Refused as merge refuses it (its own checks, or the lead's word while the tests ran): it stays as it was.
        case refused(String)
        /// The batch stopped (hung, cancelled, an error) before it was decided: it stays as it was.
        case untouched(String)
    }

    public struct BatchResult: Sendable {
        /// Each task asked for, in the order given, and how it came out.
        public var ends: [(slug: String, end: BatchEnd)]
        /// How many test runs the batch took (reruns not counted).
        public var runs: Int
        /// Why the batch stopped short (`untouched` tasks), or nil.
        public var stopped: String?
        /// What the lead is told.
        public var text: String

        public func end(_ slug: String) -> BatchEnd? { ends.first { $0.slug == slug }?.end }
    }

    /// The most tasks one batch takes.
    public static let batchLimit = 8

    /// Whether `workflow`'s merge_batching batches now: always, or boost while Boost mode is on.
    func batching(_ workflow: LeadWorkflow) -> Bool {
        switch workflow.mergeBatching {
        case .off: return false
        case .always: return true
        case .boost: return isBoosting
        }
    }

    /// One test run of a batch's stack, as it came out.
    private struct BatchRun {
        enum Outcome {
            case passed
            /// The first run failed with `failed`, and the rerun passed.
            case flaked(plan: MergeRerun.Plan, failed: String, rerun: String)
            /// It failed (on its rerun too, when there was one): the output to tell.
            case failed(String)
            /// Hung, cancelled or an error: the batch stops.
            case stopped(kind: String, text: String)
        }
        var outcome: Outcome
        /// The passing run's test count, for the receipts.
        var tests: Int?
        /// The rerun planned after its first run failed, for the stats.
        var plan: MergeRerun.Plan?
        var passed: Bool { if case .stopped = outcome { return false } else if case .failed = outcome { return false } else { return true } }
    }

    /// Merges `slugs` as one batch (see the extension's comment). Throws, with nothing tested or changed, when the batch
    /// can't start at all (the battery hold, the settings, another merge into the base, the load, no test command).
    func mergeBatch(_ given: [String]) throws -> BatchResult {
        var slugs: [String] = []
        for slug in given where !slugs.contains(slug) { slugs.append(slug) }
        guard slugs.count <= Self.batchLimit else { throw Problem(text: "Not merged: a batch takes at most \(Self.batchLimit) tasks; this was \(slugs.count).") }
        try checkBattery(not: "Not merged")
        let workflow = self.workflow
        try checkSettings(workflow, not: "Not merged (nothing was tested)")
        // Nothing to test them together with: one at a time, as merge does.
        guard workflow.testCommand != nil, let checks = workflow.mergeChecks else {
            throw Problem(text: "Not merged as a batch: there's no test_command to run on the stack. Merge each on its own.")
        }
        var ends: [String: BatchEnd] = [:]
        var gates: [MergeGate] = []
        var locks: [FileLock] = []
        defer { for lock in locks { lock.release() } }
        for slug in slugs {
            do {
                let gate = try mergeGate(slug)
                guard let lock = FileLock.attempt((store.folder as NSString).appendingPathComponent("run/merge-\(slug).lock")) else {
                    ends[slug] = .refused("A merge of \(slug) is already running; its result comes back to the call that started it.")
                    continue
                }
                locks.append(lock)
                gates.append(gate)
            } catch let problem as Problem {
                ends[slug] = .refused(problem.text)
            }
        }
        let base = workflow.base
        guard !gates.isEmpty else {
            return BatchResult(ends: slugs.map { ($0, ends[$0]!) }, runs: 0, stopped: nil,
                               text: "Nothing merged: none of \(slugs.joined(separator: ", ")) may merge now.\n" + Self.endLines(slugs, ends))
        }
        let baseLock = vault.scratch(root: root, "merge-into-\(LeadVault.hash(base).prefix(16)).lock")
        try vault.ensurePrivate(baseLock.deletingLastPathComponent())
        guard let held = FileLock.attempt(baseLock.path) else {
            throw Problem(text: "Another merge into \(base) is running; merge \(slugs.joined(separator: ", ")) when it's done.")
        }
        defer { held.release() }
        guard let current = branchHead(base) else { throw Problem(text: "There's no branch \(base) to merge into.") }
        try checkBaseMoves(base: base, current: current)
        if let lock = Worktrees.indexLock(blocking: base, root: root) {
            throw Problem(text: "Not merged (nothing was tested): \(Worktrees.refusal(lock))")
        }
        let names = gates.map(\.task.slug).joined(separator: ", ")
        let waited = try waitForLoad(workflow, slug: names)

        let place = vault.scratch(root: root, "merge-batch")
        try vault.ensurePrivate(place.deletingLastPathComponent())
        let stack = Worktrees.Stack(root: root, scratch: place, home: vault.scratch(root: root, "merge-batch-home"), records: workflow.recordsDir,
                                     remote: fetchedTip(workflow))
        defer { stack.remove() }
        let called = Date()
        var begun: (at: Date, load: [Double])?
        var runs = 0
        var firstRun: String?
        var stopped: String?
        // For each task's stats line: its result, when it was decided, and the rerun of the run that decided it.
        var results: [String: (result: String, at: Date, plan: MergeRerun.Plan?)] = [:]
        var landed: [String] = []
        var lines: [String] = []
        var flakeNotes: [String] = []
        var onto = current

        /// Tests the stack's first `count` tasks, `top` the last of them (the flake ledger's rerun record names it).
        /// A rerun is recorded, with its paired base run, only for a round's whole stack (`recorded`): a bisect's runs
        /// would count one failure again for each prefix tried, and run the base again each time.
        func run(_ count: Int, top: String, recorded: Bool) -> BatchRun {
            runs += 1
            var plan: MergeRerun.Plan?
            var tests: Int?
            // The branches' code runs from here, outside any session: the team isn't quiet (`ConfigSeal`). Unmarked, it
            // doesn't run.
            let mark: String
            do { mark = try markBranchRun(not: "the stack wasn't tested") } catch let problem as Problem {
                return BatchRun(outcome: .stopped(kind: "error", text: problem.text), tests: nil, plan: nil)
            } catch {
                return BatchRun(outcome: .stopped(kind: "error", text: "\(error)"), tests: nil, plan: nil)
            }
            defer { endBranchRun(mark) }
            var load: Double?
            // The failing tests' one run on the stack's base after a rerun: record only (`MergeRerun.baseline`).
            let pairing = MergeRerun.Pairing()
            let under = stack.base
            let check = stack.test(prefix: count, setup: workflow.initCommand, test: checks, timeout: workflow.testTimeout, lock: heavyLock(workflow),
                                   rerun: { output in
                                       plan = MergeRerun.plan(after: output, workflow: workflow)
                                       return plan?.command
                                   }, baseline: recorded ? baseline(on: under, plan: { plan }, pairing: pairing) : nil,
                                   tested: { tests = LeadReceipt.testCount($0) },
                                   begun: { at in
                                       load = LoadRecorder.averages()?.first
                                       if begun == nil { begun = (at, LoadRecorder.averages() ?? []) }
                                   })
            if recorded, let plan {
                switch check {
                case .passedOnRerun(let tip, _, let again):
                    recordRerun(plan, task: top, commit: tip, base: under, passed: MergeRerun.unshown(plan, rerun: again).isEmpty, load: load, pairing: pairing)
                case .failed:
                    recordRerun(plan, task: top, commit: stack.tips[count - 1], base: under, passed: false, load: load, pairing: pairing)
                default: break
                }
            }
            let outcome: BatchRun.Outcome
            // What the tests wrote outside the worktree (the agents' config) holds the merge, whatever they said.
            var held: String?
            if case .passed = check { held = heldConfig() } else if case .passedOnRerun = check { held = heldConfig() }
            if let held { return BatchRun(outcome: .stopped(kind: "error", text: held), tests: tests, plan: plan) }
            switch check {
            case .passed: outcome = .passed
            case .passedOnRerun(_, let failed, let again):
                // A filter that matched nothing ran nothing: that's no pass.
                if let plan, MergeRerun.unshown(plan, rerun: again).isEmpty {
                    outcome = .flaked(plan: plan, failed: failed, rerun: again)
                } else {
                    outcome = .failed(failed)
                }
            case .failed(let output): outcome = .failed(output)
            case .hung(let command, let after, let output, let stall):
                let saved = saveMergeLog(output, slug: "merge-batch", name: "hung.log")
                outcome = .stopped(kind: "hung", text: "the \(command) \(Worktrees.hung(after: after, stall: stall)) on the stack's first \(count) task\(count == 1 ? "" : "s") and was stopped. "
                                   + MergeRerun.phaseText(output)
                                   + (saved.map { " (the output so far: \($0))" } ?? ""))
            case .cancelled: outcome = .stopped(kind: "cancelled", text: "it was cancelled")
            case .error(let text): outcome = .stopped(kind: "error", text: text)
            case .conflict: outcome = .stopped(kind: "error", text: "a test run reported a conflict")
            }
            if firstRun == nil {
                switch outcome {
                case .passed: firstRun = "passed"
                case .flaked, .failed: firstRun = "failed"
                case .stopped: break
                }
            }
            return BatchRun(outcome: outcome, tests: tests, plan: plan)
        }

        /// Lands the stack's first `count` tasks (`stacked`), which `passing` passed on: false when something stopped it.
        func land(_ stacked: [MergeGate], count: Int, passing: BatchRun) -> Bool {
            let prefix = Array(stacked.prefix(count))
            let tip = stack.tips[count - 1]
            if ShellCancel.current?.isCancelled == true {
                stopped = "it was cancelled after its checks passed"
                return false
            }
            // The lead's word while the tests ran stands, and the stack tested with that task on it doesn't land.
            for gate in prefix {
                if let changed = changedMeanwhile(gate.task.slug, since: gate.task, tests: "passed in a batch") {
                    ends[gate.task.slug] = .refused(changed.text)
                    results[gate.task.slug] = ("passed", Date(), passing.plan)
                    stopped = "\(gate.task.slug) was set \(Self.shownState(store.load().task(gate.task.slug) ?? gate.task)) while the tests ran, so the stack tested with it on doesn't land"
                    return false
                }
            }
            switch ShellCancel.with(nil, { Worktrees.fastForward(root: root, base: base, to: tip, from: onto) }) {
            case .refused(let reason):
                stopped = reason
                return false
            case .merged: break
            }
            let order = prefix.map(\.task.slug)
            // Moved, but not recorded: nothing is said merged that the board and the vault don't hold (merge throws then).
            func unrecorded(_ what: String, _ error: Error) -> Bool {
                let text = "\(base) was fast-forwarded to \(tip.prefix(8)) with \(order.joined(separator: ", ")), but \(what) (\(error)), so their merge isn't recorded: check \(base) and the board before merging anything more."
                for slug in order { ends[slug] = .refused(text) }
                stopped = text
                try? store.appendProgress("Batch merge of \(order.joined(separator: ", ")) not recorded: \(text)")
                return false
            }
            do { try vault.setHead(tip, root: root, branch: base) } catch { return unrecorded("the vault couldn't record its head", error) }
            foldRemoteRecords(landed: tip, from: onto)
            let last = order[order.count - 1]
            var flaked: (plan: MergeRerun.Plan, failed: String, log: String?)?
            if case .flaked(let plan, let failed, let again) = passing.outcome {
                flaked = (plan, failed, saveMergeLog(failed + "\n" + again, slug: last))
            }
            // A flake is one event: recorded once, under the task whose commit the run tested (the stack's top).
            let flakes = flaked.map { MergeRerun.flakes(in: $0.failed) } ?? []
            let flakeLines = flaked.map { MergeRerun.evidence(in: $0.failed, tests: flakes) } ?? [:]
            let flakedAt = Date()
            let flakeLog = flakeLines.isEmpty ? nil : saveFlakeEvidence(flakeLines, tests: flakes, slug: last, commit: tip, at: flakedAt)
            var under: [String: String] = [:]
            var brought: [String: Int] = [:]
            var usage: [String: LeadReceipts.Usage] = [:]
            let build = runningBuild()?.label
            for (index, gate) in prefix.enumerated() {
                let below = index == 0 ? onto : stack.tips[index - 1]
                under[gate.task.slug] = below
                brought[gate.task.slug] = Int(Git.run(["rev-list", "--count", "\(below)..\(stack.tips[index])"], in: root).output)
                usage[gate.task.slug] = receiptUsage(gate.task)
            }
            let flakePlan: FlakePlan
            do { flakePlan = try store.update { board -> FlakePlan in
                for (index, gate) in prefix.enumerated() {
                    guard let at = board.taskIndex(gate.task.slug) else { continue }
                    // The batch's waits and its runs until now, in its receipt (`LeadWaits`).
                    board.tasks[at].noteMergeRun(loadWait: waited?.after ?? 0, called: called, begun: begun?.at, ended: Date())
                    board.tasks[at].status = .done
                    board.tasks[at].merged = LeadMergeRecord(commit: stack.tips[index], tested: true, onto: under[gate.task.slug],
                                                             regression: workflow.regressionCommand.map { _ in true },
                                                             audited: gate.audited ? nil : false, batch: order.count > 1 ? order : nil)
                    board.tasks[at].receipt = LeadReceipt(board.tasks[at], ending: .merged, questions: board.questions,
                                                          usage: usage[gate.task.slug] ?? LeadReceipts.Usage(),
                                                          tests: passing.tests, mergeReruns: flaked == nil ? 0 : 1, commits: brought[gate.task.slug] ?? nil)
                    board.tasks[at].receipt?.build = build
                }
                return planFlakeFixes(&board, flakes: flakes, slug: last, commit: tip, at: flakedAt, logged: Set(flakeLines.keys),
                                      log: flakeLog, load: begun?.load.first, filtered: flaked?.plan.filtered, workflow: workflow)
            } } catch { return unrecorded("the board couldn't be written", error) }
            let planned = flakePlan.planned
            // A fix-the-flaky-test task (or an open one a due flake was noted in) merging fixes its test.
            noteFlakeFixes(prefix.enumerated().map { ($0.element.task.slug, stack.tips[$0.offset]) })
            let decided = Date()
            let together = order.count > 1 ? " (in a batch: \(order.joined(separator: ", ")) landed on one test run)" : " (in a batch, on a test run of its own)"
            for gate in prefix {
                let slug = gate.task.slug
                ends[slug] = .merged(stack.tips[prefix.firstIndex { $0.task.slug == slug }!])
                results[slug] = (flaked == nil ? "passed" : "passed_on_rerun", decided, passing.plan)
                try? store.appendProgress("Merged \(slug): \(gate.task.title)\(gate.audited ? "" : " (no audit: review none)")"
                    + (gate.dismissed.isEmpty ? "" : " (its audit's Important findings dismissed by the lead: \(gate.dismissed.map(\.id).joined(separator: ", ")))")
                    + together + buildNote)
            }
            landed += order
            lines.append("Merged \(order.joined(separator: ", ")) into \(base) at \(tip.prefix(8)), \(onto.prefix(8))..\(tip.prefix(8)), on one test run"
                         + (flaked == nil ? "." : " that passed on its rerun."))
            if let flaked {
                let names = flakes.joined(separator: ", ")
                try? store.appendProgress("Flaky in the batch \(order.joined(separator: ", ")): \(Self.clip(names, 300)) failed the first test run and passed its rerun (\(flaked.plan.filtered ? "the failing tests only" : "the whole test command")); merged on the rerun")
                for (test, fix, noted) in planned {
                    try? store.appendProgress((noted ? "Noted in \(fix)'s context (an open task naming it; no new task)" : "Planned \(fix)")
                                              + ": \(test) flaked \(LeadBoard.flakeLimit) times within \(Int(LeadBoard.flakeWindow / 86_400)) days")
                }
                flakeNotes.append("Its first test run failed on \(Self.clip(names, 300)) and the rerun of \(flaked.plan.filtered ? "those tests" : "the whole test command") passed, so \(order.joined(separator: ", ")) merged on the rerun: recorded once in the flake ledger (under \(last)), which status lists."
                                  + (flaked.log.map { " Both runs' output: \($0)." } ?? "")
                                  + (flakeLog.map { " Each flaky test's failing lines, readable by its fixer: \(MergeRerun.evidenceFile(root: root, log: $0))." } ?? "")
                                  + planned.map { test, fix, noted in " \(test) flaked \(LeadBoard.flakeLimit) times within \(Int(LeadBoard.flakeWindow / 86_400)) days: " + (noted ? "the open task \(fix) names it, so that's noted in its context." : "planned \(fix) to fix it.") }.joined()
                                  + tellRecurrences(flakePlan.recurred, slug: last))
            }
            let caughtUp = tellToCatchUp(merged: order.joined(separator: ", "), from: onto, to: tip, base: base)
            if !caughtUp.isEmpty { lines.append(caughtUp.trimmingCharacters(in: .whitespaces)) }
            onto = tip
            return true
        }

        /// `gate`'s task breaks the stack on top of the base as it is now (`onto`): back to its worker with `output`.
        func broke(_ gate: MergeGate, output: String, before: [String]) {
            let slug = gate.task.slug
            results[slug] = ("failed", Date(), nil)
            if let changed = changedMeanwhile(slug, since: gate.task, tests: "failed in a batch") {
                ends[slug] = .refused(changed.text)
                return
            }
            let tests = TestFailures(output: output).tests.joined(separator: ", ")
            let last = tests.isEmpty ? output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "" : tests
            let what = output.components(separatedBy: "\n").contains(LeadWorkflow.regressionMarker) ? "regression_command fails" : "Tests fail"
            do {
                try setStatus(slug, .failed, setback: LeadSetback(stage: .merge, reason: "\(what) rebased onto \(base) (in a batch)" + (last.isEmpty ? "." : ": \(last.prefix(200))")))
            } catch {
                ends[slug] = .refused("Its tests failed in the batch, but the board couldn't be written (\(error)).")
                return
            }
            // First on the stack: what failed was the base with it alone on top.
            let context = before.isEmpty ? "It was tested in a batch, first on the stack: it fails on \(base) with it on top."
                : "It was tested in a batch: the stack with it on top fails, the stack without it passes. The batch's tasks before it on the stack (\(before.joined(separator: ", "))) merged first, so they're on \(base) now."
            ends[slug] = .failed(testFailure(output, slug: slug, base: base, commit: gate.commit, onto: onto, worktree: place)
                                 + "\n" + context)
            try? store.appendProgress("Didn't merge \(slug) in the batch: \(what.lowercased()) with it on \(base)" + (last.isEmpty ? "" : " (\(Self.clip(last, 200)))") + "; back to its worker")
            lines.append("\(slug) breaks the stack: \(what.lowercased())" + (last.isEmpty ? "" : " (\(Self.clip(last, 200)))") + "; it's failed, with the output for its worker.")
        }

        /// `gate`'s task doesn't apply with the batch's tasks before it (`before`) on the base.
        func conflicted(_ gate: MergeGate, before: [String]) {
            let slug = gate.task.slug
            results[slug] = ("conflict", Date(), nil)
            if let changed = changedMeanwhile(slug, since: gate.task, tests: "didn't run: it conflicts with the batch's stack") {
                ends[slug] = .refused(changed.text)
                return
            }
            do {
                try setStatus(slug, .failed, setback: LeadSetback(stage: .merge, reason: "Conflicts with \(base): the branch needs bringing up to date."))
            } catch {
                ends[slug] = .refused("It conflicts with the batch's stack, but the board couldn't be written (\(error)).")
                return
            }
            let with = before.isEmpty ? "" : " with the batch's tasks before it (\(before.joined(separator: ", "))) on it"
            ends[slug] = .conflict("\(slug) conflicts with \(base)\(with), so it was left out of the batch. " + Self.bringUpToDate(base))
            lines.append("\(slug) doesn't apply on \(base)\(with): left out, failed, to merge \(base).")
        }

        var pending = gates
        var round = 0
        batch: while !pending.isEmpty, stopped == nil {
            round += 1
            // Restacked after a split: each is checked again as merge checks it before its run (its gate was read before
            // the first run, minutes ago: a new commit, a finding, a withdrawn approval since then counts).
            if round > 1 {
                pending = pending.compactMap { gate in
                    let slug = gate.task.slug
                    do {
                        let again = try mergeGate(slug)
                        if let changed = changedMeanwhile(slug, since: gate.task, tests: "were run in a batch, and it's to be tested again") {
                            ends[slug] = .refused(changed.text)
                            return nil
                        }
                        return again
                    } catch let problem as Problem {
                        ends[slug] = .refused(problem.text)
                        lines.append("\(slug) left out of the next run: merge's own checks refuse it now.")
                        return nil
                    } catch {
                        ends[slug] = .refused("\(error)")
                        return nil
                    }
                }
                guard !pending.isEmpty else { break }
            }
            if let error = stack.reset(to: onto) {
                stopped = error
                break
            }
            var stacked: [MergeGate] = []
            for gate in pending {
                switch stack.push(gate.commit, trailers: provenance(gate)) {
                case nil: stacked.append(gate)
                case .conflict?: conflicted(gate, before: landed + stacked.map(\.task.slug))
                case .cancelled?:
                    stopped = "it was cancelled"
                    break batch
                case .error(let text)?:
                    stopped = "stacking \(gate.task.slug) failed: \(text)"
                    break batch
                case .some(let other):
                    stopped = "stacking \(gate.task.slug) stopped: \(other)"
                    break batch
                }
            }
            pending = []
            guard !stacked.isEmpty else { break }
            let count = stacked.count
            let whole = run(count, top: stacked[count - 1].task.slug, recorded: true)
            if case .stopped(_, let text) = whole.outcome {
                stopped = text
                break
            }
            if whole.passed {
                _ = land(stacked, count: count, passing: whole)
                break
            }
            guard case .failed(var failing) = whole.outcome else { break }
            // The first prefix that fails: `lo` passes (or is empty), `hi` fails.
            var lo = 0, hi = count
            var passing: BatchRun?
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                let tried = run(mid, top: stacked[mid - 1].task.slug, recorded: false)
                switch tried.outcome {
                case .stopped(_, let text):
                    stopped = text
                    break batch
                case .failed(let output):
                    hi = mid
                    failing = output
                case .passed, .flaked:
                    lo = mid
                    passing = tried
                }
            }
            let before = landed
            if lo > 0, let passing {
                guard land(stacked, count: lo, passing: passing) else { break }
            }
            broke(stacked[hi - 1], output: failing, before: Array(landed.dropFirst(before.count)))
            pending = Array(stacked[hi...])
            lines.append(pending.isEmpty ? "" : "Stacked again on \(base) without it: \(pending.map(\.task.slug).joined(separator: ", ")).")
        }
        // What wasn't decided stays as it was.
        let why = stopped ?? "the batch stopped"
        for gate in gates where ends[gate.task.slug] == nil {
            ends[gate.task.slug] = .untouched("The batch stopped before \(gate.task.slug) was decided (\(why)); it stays as it was.")
        }

        // One stats line per task tested: the batch's id, size and runs on each.
        if let folder = mergeStats() {
            let start = begun?.at ?? called
            let id = LoadStats.stamp(start) + "-" + (gates.first?.task.slug ?? "")
            let kind = stopped.flatMap { text in ["hung", "cancelled"].first { text.contains($0) } } ?? "error"
            for gate in gates {
                let slug = gate.task.slug
                if case .refused = ends[slug]!, results[slug] == nil { continue }
                let decided = results[slug] ?? (kind, Date(), nil)
                var sample = MergeSample(t: LoadStats.stamp(start), project: (root as NSString).lastPathComponent, task: slug,
                                         load: (begun?.load ?? LoadRecorder.averages() ?? []).map { ($0 * 100).rounded() / 100 },
                                         waitedS: Int((waited?.after ?? 0).rounded()), slotWaitS: begun.map { Int(max(0, $0.at.timeIntervalSince(called)).rounded()) },
                                         durationS: Int(max(0, decided.at.timeIntervalSince(start)).rounded()),
                                         firstRun: decided.result == "conflict" ? nil : firstRun, reran: decided.plan?.tests,
                                         rerunWhole: decided.plan.map { !$0.filtered }, result: decided.result)
                sample.batch = id
                sample.batchTasks = gates.count
                sample.batchRuns = runs
                sample.taskFirstRun = decided.result == "passed" ? "passed" : ["failed", "passed_on_rerun"].contains(decided.result) ? "failed" : nil
                try? sample.append(in: folder, at: start)
            }
        }
        // The tasks tested that didn't land: the batch's waits and runs until each was decided (`LeadWaits`); the landed
        // ones' are in their receipts.
        let unlanded = gates.filter { !landed.contains($0.task.slug) && results[$0.task.slug] != nil }
        if !unlanded.isEmpty {
            _ = try? store.update { board in
                for gate in unlanded {
                    guard let at = board.taskIndex(gate.task.slug), let decided = results[gate.task.slug]?.at else { continue }
                    board.tasks[at].noteMergeRun(loadWait: waited?.after ?? 0, called: called, begun: begun?.at, ended: decided)
                }
            }
        }
        if !landed.isEmpty { archiveFinished(force: false) }
        let patience = waited.map { " (The tests waited \(Worktrees.duration($0.after)) for the Mac's load to drop from \(MacLoad.number($0.from)) below load_threshold.)" } ?? ""
        let head = "Batch of \(gates.count) (\(names)) onto \(base): \(runs) test run\(runs == 1 ? "" : "s")"
            + (landed.isEmpty ? ", nothing merged." : ", \(landed.count) merged.")
        var text = head + patience + "\n" + lines.filter { !$0.isEmpty }.map { "- " + $0 }.joined(separator: "\n")
        if !flakeNotes.isEmpty { text += "\n" + flakeNotes.map { "(" + $0 + ")" }.joined(separator: "\n") }
        if stopped != nil { text += "\nThe batch stopped short: \(why); what wasn't decided stays as it was, to merge one at a time." }
        text += "\n" + Self.endLines(slugs, ends)
        if !landed.isEmpty { text += "\nNext: cleanup each merged task. \(LeadPrompts.Policy.updates)" }
        return BatchResult(ends: slugs.map { ($0, ends[$0]!) }, runs: runs, stopped: stopped, text: text)
    }

    /// A line per task: how it came out.
    static func endLines(_ slugs: [String], _ ends: [String: BatchEnd]) -> String {
        slugs.map { slug -> String in
            switch ends[slug] {
            case .merged(let commit)?: return "\(slug): merged at \(commit.prefix(8))."
            case .failed(let text)?: return "\(slug): failed. \(text)"
            case .conflict(let text)?: return "\(slug): failed. \(text)"
            case .refused(let text)?: return "\(slug): not merged. \(text)"
            case .untouched(let text)?: return "\(slug): \(text)"
            case nil: return "\(slug): not merged."
            }
        }.joined(separator: "\n")
    }

    /// The merge tool's batch (merge with `tasks`): `mergeBatch`, said as one result; an error when nothing merged.
    func mergeTool(batch slugs: [String]) throws -> MCPToolResult {
        guard slugs.count >= 2 else { throw Problem(text: "A batch is two tasks or more; merge(task) merges one.") }
        let result = try mergeBatch(slugs)
        let merged = result.ends.contains { if case .merged = $0.end { return true } else { return false } }
        return MCPToolResult(text: result.text, isError: !merged)
    }

    /// auto_advance's batch step: `mergeBatch`, with the records flushed after.
    func advanceMergeBatch(_ slugs: [String]) throws -> BatchResult {
        let result = try mergeBatch(slugs)
        records.flush(base: base)
        return result
    }
}
