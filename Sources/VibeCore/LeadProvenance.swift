import Foundation

/// Where a merged commit came from, as git trailers on the commit that lands on the base (`Worktrees.stamp`), so the
/// history itself says it and it survives across Macs: the task, its review, the models that worked on and audited it,
/// the build of the tool server that merged it (`ServerBuild`), and a hash of its contract's text.
///
/// Backlog A2, 2026-11-08: the other Mac's records lived outside commits and were lost; a commit's trailers go
/// wherever the commit goes. `scripts/merge-provenance.sh` lists them from `git log` alone.
///
/// Only slugs, model names, verdict words and hashes: every value keeps to `allowed` (no `@`, so no email; no `/`,
/// so no path, no newline); a value holding anything else is left out (`clean`).
public enum LeadProvenance {
    public static let task = "VS-Task"
    public static let review = "VS-Review"
    public static let workerModel = "VS-Worker-Model"
    public static let verifierModel = "VS-Verifier-Model"
    public static let build = "VS-Build"
    public static let contract = "VS-Contract"

    /// The characters a trailer's value may hold: letters, digits, and `. _ - : , ( ) [ ]` and the space.
    static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:,()[] ")

    /// `text` trimmed, at most 120 characters; `empty` when blank, and "unknown (not a plain name)" when it holds a
    /// character outside `allowed` (an email, a path, a newline that would start a trailer of its own): such a value
    /// isn't shown in part either, as a path's folder names would be.
    static func clean(_ text: String?, empty: String = "unknown") -> String {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return empty }
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return "unknown (not a plain name)" }
        return String(trimmed.prefix(120))
    }

    /// The hash a contract's text is named by: the first 16 hex characters of the SHA-256 of the brief its worker was
    /// given (`WorkerBrief.render`: title, goal, acceptance checks, boundaries, context).
    public static func contractHash(_ task: LeadTask) -> String {
        String(LeadVault.hash(WorkerBrief.render(task)).prefix(16))
    }

    /// The review it merged on: "none" (review none: its worker's done report and the merge's tests), or
    /// "audit (pass at <commit>)", with the Important findings the lead dismissed named when it passed on those.
    public static func reviewText(audited: Bool, commit: String, dismissed: [String]) -> String {
        guard audited else { return "none" }
        let verdict = dismissed.isEmpty ? "pass" : "pass, dismissed " + dismissed.joined(separator: " ")
        return "audit (\(verdict) at \(commit.prefix(12)))"
    }

    /// The build's value: its source commit in full (" (with changes not committed)" beside), else what's known.
    public static func buildText(_ build: ServerBuild?) -> String {
        guard let build else { return "unknown (not an app build)" }
        guard let commit = build.commit else { return "unknown (no commit recorded)" }
        return commit + (build.changed ? " (with changes not committed)" : "")
    }

    /// The trailers for `task`'s merge, in order.
    public static func trailers(task: LeadTask, audited: Bool, commit: String, dismissed: [String], workerModel worker: String?,
                                verifierModel verifier: String?, build: ServerBuild?) -> [Worktrees.Trailer] {
        [Worktrees.Trailer(Self.task, clean(task.slug)),
         Worktrees.Trailer(review, clean(reviewText(audited: audited, commit: commit, dismissed: dismissed))),
         Worktrees.Trailer(workerModel, clean(worker)),
         Worktrees.Trailer(verifierModel, audited ? clean(verifier) : "none"),
         Worktrees.Trailer(Self.build, clean(buildText(build))),
         Worktrees.Trailer(contract, contractHash(task))]
    }
}

extension LeadToolset {
    /// The provenance trailers for the merge `gate` lets in (`LeadProvenance`): the models its sessions were started
    /// on (`LeadTask.launchedModels`), a session on Claude's default ("") or one not noted going by the model that
    /// answered most in its role's transcripts (read only then), and the build of this tool server.
    func provenance(_ gate: MergeGate) -> [Worktrees.Trailer] {
        let task = gate.task
        let launched = task.launchedModels ?? [:]
        func noted(_ session: String?) -> String? {
            guard let session, let model = launched[session]?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return nil }
            return model
        }
        var worker = noted(task.worker)
        let verifierSessions = [task.verifier].compactMap { $0 } + (task.panel?.sessions ?? []).filter { $0 != task.verifier }
        var verifiers: [String] = []
        for model in verifierSessions.compactMap(noted) where !verifiers.contains(model) { verifiers.append(model) }
        if worker == nil || (gate.audited && verifiers.isEmpty) {
            let usage = receiptUsage(task)
            if worker == nil { worker = usage.worker?.models.first }
            if gate.audited, verifiers.isEmpty, let answered = usage.verifier?.models.first { verifiers = [answered] }
        }
        return LeadProvenance.trailers(task: task, audited: gate.audited, commit: gate.commit, dismissed: gate.dismissed.map(\.id),
                                       workerModel: worker, verifierModel: verifiers.isEmpty ? nil : verifiers.joined(separator: ", "),
                                       build: runningBuild())
    }
}
