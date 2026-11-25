import Foundation

extension LeadToolset {
    /// A validated passing run held for Accept, only in this tool server's memory. No file or host message can
    /// assert a pass: a new server has no retained results and tests again.
    struct KeptMerge {
        struct Input: Equatable {
            var slug: String
            var commit: String
            var revision: Int
        }
        struct Context: Equatable {
            var root: String
            var base: String
            var onto: String
            var fetched: String?
            var inputs: [Input]
            var setup: String?
            var checks: String?
            var records: String?
        }
        var context: Context
        var tips: [String]
        var failed: String?
        var rerun: String?
        var onBase: String?
        var tests: Int?
        var cores: Int?
        var ended: Date

        var check: Worktrees.Check {
            let tip = tips[tips.count - 1]
            if let failed, let rerun, let onBase { return .passedRedOnBase(commit: tip, failed: failed, rerun: rerun, base: onBase) }
            if let failed, let rerun { return .passedOnRerun(commit: tip, failed: failed, rerun: rerun) }
            return .passed(tip)
        }

        init?(context: Context, tips: [String], check: Worktrees.Check, tests: Int?, cores: Int?, ended: Date) {
            self.context = context
            self.tips = tips
            self.tests = tests
            self.cores = cores
            self.ended = ended
            switch check {
            case .passed: break
            case .passedOnRerun(_, let failed, let rerun): self.failed = failed; self.rerun = rerun
            case .passedRedOnBase(_, let failed, let rerun, let onBase): self.failed = failed; self.rerun = rerun; self.onBase = onBase
            default: return nil
            }
        }
    }

    func mergeSealContext(_ gates: [MergeGate], onto: String, fetched: String?, workflow: LeadWorkflow) -> KeptMerge.Context {
        KeptMerge.Context(root: root, base: workflow.base, onto: onto, fetched: fetched,
                            inputs: gates.map { .init(slug: $0.task.slug, commit: $0.commit, revision: $0.task.contractRevision) },
                            setup: workflow.initCommand, checks: workflow.mergeChecks, records: workflow.recordsDir)
    }

    private func mergePassKey(_ gates: [MergeGate]) -> String {
        gates.map { $0.task.slug }.joined(separator: "\n")
    }

    private func mergeSealRef(_ key: String) -> String {
        "refs/vibeswitcher/seal-passes/\(LeadVault.hash(key))"
    }

    func keptMerge(_ gates: [MergeGate], onto: String, fetched: String?, workflow: LeadWorkflow) -> KeptMerge? {
        let kept = mergePassLock.withLock { mergePasses[mergePassKey(gates)] }
        guard let kept else { return nil }
        guard kept.context == mergeSealContext(gates, onto: onto, fetched: fetched, workflow: workflow),
              kept.tips.count == gates.count, !kept.tips.isEmpty,
              kept.tips.allSatisfy({ Git.run(["cat-file", "-e", "\($0)^{commit}"], in: root).ok }) else {
            // A moved base or task head, an amended contract, or different commands needs a new test run.
            forgetKeptMerge(gates)
            return nil
        }
        return kept
    }

    /// Saving is part of the refusal, never permission to land: the normal gates and the seal are checked on retry.
    func keepMerge(_ kept: KeptMerge, gates: [MergeGate]) throws {
        // The scratch worktree is removed after a hold. Keep its tested commits reachable even if Accept comes
        // after git's next garbage collection; the top of a batch holds every prefix too.
        try mergePassLock.withLock {
            let key = mergePassKey(gates)
            let pinned = Git.run(["update-ref", mergeSealRef(key), kept.tips[kept.tips.count - 1]], in: root)
            guard pinned.ok else { throw Problem(text: "Not merged: couldn't keep the passing commit for Accept: \(Worktrees.said(pinned))") }
            // Only the newest passing prefix can be reused. Drop superseded prefixes (or a larger pass
            // replaced by a smaller bisect prefix), including their pins, before storing this one.
            let slugs = Set(kept.context.inputs.map(\.slug))
            let superseded = mergePasses.filter { $0.key != key && $0.value.context.inputs.contains { slugs.contains($0.slug) } }.map(\.key)
            for old in superseded { dropMergePass(old) }
            mergePasses[key] = kept
        }
    }

    /// Called under mergePassLock, so a concurrent save cannot have its new pin removed by a drop.
    private func dropMergePass(_ key: String) {
        mergePasses.removeValue(forKey: key)
        _ = Git.run(["update-ref", "-d", mergeSealRef(key)], in: root)
    }

    func forgetKeptMerge(_ gates: [MergeGate]) {
        mergePassLock.withLock { dropMergePass(mergePassKey(gates)) }
    }

    /// A fresh lead server has no in-memory passes. Their refs only keep otherwise unreachable commits alive.
    func clearOrphanedMergePassRefs() {
        let refs = Git.run(["for-each-ref", "--format=%(refname)", "refs/vibeswitcher/seal-passes/"], in: root)
        guard refs.ok else { return }
        for ref in refs.output.split(separator: "\n") {
            _ = Git.run(["update-ref", "-d", String(ref)], in: root)
        }
    }
}
