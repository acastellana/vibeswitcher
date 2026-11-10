import Foundation

/// Where a merged commit came from, as git trailers on the commit that lands on the base (`Worktrees.stamp`), so the
/// history itself says it and it survives across Macs: the task, its review, the models that worked on and audited it,
/// the build of the tool server that merged it (`ServerBuild`), a hash of its contract's text, and the Claude Code
/// version its worker ran (Claude Code updates itself and changes behaviour, so a change in results needs its version).
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
    public static let cli = "VS-CLI"

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
    public static func reviewText(audited: Bool, commit: String, dismissed: [String], accepted: Bool = false) -> String {
        guard audited else { return "none" }
        if accepted { return "audit (suspect, accepted by the lead as an exception at \(commit.prefix(12)))" }
        let verdict = dismissed.isEmpty ? "pass" : "pass, dismissed " + dismissed.joined(separator: " ")
        return "audit (\(verdict) at \(commit.prefix(12)))"
    }

    /// The build's value: its source commit in full (" (with changes not committed)" beside), else what's known.
    public static func buildText(_ build: ServerBuild?) -> String {
        guard let build else { return "unknown (not an app build)" }
        guard let commit = build.commit else { return "unknown (no commit recorded)" }
        return commit + (build.changed ? " (with changes not committed)" : "")
    }

    /// The Claude Code version `slug`'s worker last ran, as its own transcripts say (each line's top-level `version`),
    /// from `since` on (a folder a removed task of the same name used stays out): the newest across its sessions, so a
    /// worker resumed on a newer Claude Code goes by that one. Nil when none says, a Codex worker's task included. Read
    /// from the transcripts rather than by running `claude --version`, which says what's installed now and, as a
    /// process, could hang the merge that asks; nothing here can fail or wait.
    static func cliVersion(root: String, slug: String, since: Double, home: String = VibePaths.home) -> String? {
        var newest: (at: Double, version: String)?
        for file in LeadReceipts.transcripts(root: root, slug: slug, home: home) where file.role == .worker {
            if let found = lastVersion(in: file.url, since: since), found.at >= newest?.at ?? -.infinity { newest = found }
        }
        return newest?.version
    }

    /// `url`'s last line saying a version and when, nil when that's before `since` (lines are in time order). A line
    /// that doesn't parse, as one still being written, is passed over.
    private static func lastVersion(in url: URL, since: Double) -> (at: Double, version: String)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let version = object["version"] as? String, !version.isEmpty,
                  let at = (object["timestamp"] as? String).flatMap({ LeadReceipts.iso.date(from: $0) })?.timeIntervalSince1970 else { continue }
            return at < since ? nil : (at, version)
        }
        return nil
    }

    /// The trailers for `task`'s merge, in order.
    public static func trailers(task: LeadTask, audited: Bool, commit: String, dismissed: [String], accepted: Bool = false, workerModel worker: String?,
                                verifierModel verifier: String?, build: ServerBuild?, cliVersion: String?) -> [Worktrees.Trailer] {
        [Worktrees.Trailer(Self.task, clean(task.slug)),
         Worktrees.Trailer(review, clean(reviewText(audited: audited, commit: commit, dismissed: dismissed, accepted: accepted))),
         Worktrees.Trailer(workerModel, clean(worker)),
         Worktrees.Trailer(verifierModel, audited ? clean(verifier) : "none"),
         Worktrees.Trailer(Self.build, clean(buildText(build))),
         Worktrees.Trailer(contract, contractHash(task)),
         Worktrees.Trailer(cli, clean(cliVersion))]
    }
}

extension LeadToolset {
    /// The provenance trailers for the merge `gate` lets in (`LeadProvenance`): the models its sessions were started
    /// on (`LeadTask.launchedModels`), a session on Claude's default ("") or one not noted going by the model that
    /// answered most in its role's transcripts (read only then), the build of this tool server, and the Claude Code
    /// version its worker ran.
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
        return LeadProvenance.trailers(task: task, audited: gate.audited, commit: gate.commit, dismissed: gate.dismissed.map(\.id), accepted: gate.accepted != nil,
                                       workerModel: worker, verifierModel: verifiers.isEmpty ? nil : verifiers.joined(separator: ", "),
                                       build: runningBuild(),
                                       cliVersion: LeadProvenance.cliVersion(root: root, slug: task.slug, since: task.createdAt, home: claudeHome))
    }
}
