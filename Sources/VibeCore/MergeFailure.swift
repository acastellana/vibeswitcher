import Foundation

/// What a merge's failed or stopped test run is told as, on every route that runs the suite for a merge (merge, a
/// batch, merge_remote, revert). On 2026-11-09 two merges said only "Tests fail rebased onto main: web tests: 2 of 2
/// passed" and pointed at the vault's merge-test.log, which every session's rules refuse, and one was never explained.
/// So: the reason is what failed or that the run stopped, never the output's last line; what happened is carried
/// inline, capped and with secrets masked; the whole log goes where its reader may read it.
public enum MergeFailure {
    /// The most of a reason's failing names, and of what it says of a run that stopped ("Why it stopped" is in that).
    static let namedWidth = 200
    static let stoppedWidth = 500
    /// The most of the inline text's failing lines, of its end of the log (and how many lines of it), and of a setback.
    static let summaryLimit = 2500
    static let endLimit = 2000
    static let endLines = 30
    static let detailLimit = 6000
    /// The largest log copied whole. Past it the copy is refused and the run is read only for its last `readWindow`:
    /// masking and parsing a log of hundreds of MB would hold up the merge that has to report.
    public static let copyLimit = 16 << 20
    static let readWindow = 4 << 20

    /// `output` as it may be shown, secrets masked: only its end when it's past `copyLimit`.
    static func readable(_ output: String) -> String {
        Redaction.secrets(in: output.utf8.count > copyLimit ? String(decoding: output.utf8.suffix(readWindow), as: UTF8.self) : output)
    }

    /// One line for the setback and the progress log: the failing tests (the first one first) or the first error line,
    /// that the run stopped when it did, else that the output names nothing. Never a line of the output's own choosing.
    public static func reason(in output: String) -> String {
        let text = readable(output)
        let failures = TestFailures(output: text)
        let named = failures.tests.isEmpty ? failures.errors.first : failures.tests.joined(separator: ", ")
        switch (named.map { clip($0, namedWidth) }, stopped(failures, text).map { clip($0, stoppedWidth) }) {
        case let (named?, stopped?): return named + "; " + stopped
        case let (named?, nil): return named
        case let (nil, stopped?): return stopped
        case (nil, nil): return "it exited non-zero and its output names no failing test or error"
        }
    }

    /// That the run stopped partway, what it left unfinished and why, from a masked `text`; nil for a run that ended.
    private static func stopped(_ failures: TestFailures, _ text: String) -> String? {
        let cause = MergeRerun.causeText(text).trimmingCharacters(in: .whitespaces)
        let said: String
        if !failures.running.isEmpty {
            said = "the run stopped partway; started and never finished: \(failures.running.joined(separator: ", "))"
        } else if !failures.unfinished.isEmpty {
            said = "the run stopped partway: " + MergeRerun.cantTell(failures.unfinished.count)
        } else if !cause.isEmpty {
            said = "the run stopped"
        } else {
            return nil
        }
        return cause.isEmpty ? said : said + ". " + cause
    }

    /// What the worker and the lead read in place of the log: how the run stopped, the failing lines, and the log's end.
    public static func detail(_ output: String) -> String {
        let text = readable(output)
        let failures = TestFailures(output: text)
        var parts: [String] = []
        if failures.tests.isEmpty, let stopped = stopped(failures, text) {
            parts.append(stopped.prefix(1).uppercased() + stopped.dropFirst() + ".")
        } else if !failures.tests.isEmpty {
            let cause = MergeRerun.causeText(text).trimmingCharacters(in: .whitespaces)
            if !cause.isEmpty { parts.append(cause) }
        }
        parts.append(failures.summary(limit: summaryLimit) ?? "Nothing in the output names a failing test or an error.")
        if let end = end(ofMasked: text) { parts.append(end) }
        return parts.joined(separator: "\n")
    }

    /// The log's last lines, for a run whose failing lines are said elsewhere (a hung run's phase).
    public static func end(of output: String) -> String { end(ofMasked: readable(output)) ?? "" }

    private static func end(ofMasked text: String) -> String? {
        var kept: [String] = []
        var total = 0
        let lines = text.components(separatedBy: "\n").reversed().lazy
            .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty }).filter { !isBuildWarning($0) }.prefix(endLines)
        for raw in lines {
            let plain = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            let line = "    " + (plain.count > MergeRerun.evidenceWidth ? String(plain.prefix(MergeRerun.evidenceWidth - 1)) + "…" : plain)
            guard total + line.count + 1 <= endLimit else { break }
            kept.append(line)
            total += line.count + 1
        }
        guard !kept.isEmpty else { return nil }
        return "The output's last \(kept.count) line\(kept.count == 1 ? "" : "s") (secrets masked):\n" + kept.reversed().joined(separator: "\n")
    }

    /// A compiler warning or a line of the source excerpt under one: the end of a build's stderr, which comes after the
    /// test results and says nothing of why the run failed.
    private static func isBuildWarning(_ line: String) -> Bool {
        line.contains(": warning: ") || line.contains("`- warning: ") || line.range(of: #"^\s*\d*\s*\|"#, options: .regularExpression) != nil
    }

    /// `message` for the board (`LeadSetback.detail`), which every lead call reads and rewrites: its last line (where to
    /// read the whole log) is kept when the rest is cut.
    public static func capped(_ message: String) -> String {
        guard message.count > detailLimit else { return message }
        let last = message.components(separatedBy: "\n").last ?? ""
        return String(message.prefix(max(0, detailLimit - last.count - 3))) + "\n…\n" + last
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

/// Where a merge's whole log was copied for its reader, or why it couldn't be.
struct MergeLogCopy {
    var path: String?
    /// Why it isn't there, or (with a `path`) why it isn't in the worktree the task's worker reads.
    var why: String?

    /// "<label>: <path>." or "(The output couldn't be copied: why. …)", ending a sentence or standing as a line.
    func said(_ label: String, stop: String = "") -> String {
        if let path { return "\(label): \(path)\(stop)" + (why.map { " (Not in its worktree: \($0).)" } ?? "") }
        return "(The full output couldn't be copied\(why.map { ": \($0)" } ?? ""). What's above is what can be read of it.)"
    }
}

extension LeadToolset {
    /// Where a task's merge log goes in its own worktree (`.vibeswitcher/` is excluded for every worktree of the
    /// repository: `BoardStore.prepare`), a file its worker may read and git doesn't count.
    static let worktreeLogFolder = ".vibeswitcher/merge-failure"

    /// Copies a merge's whole `output`, secrets masked, for whoever reads it next: into the task's worktree when it has
    /// one (`inWorktree`), else (or when the worktree can't take it) into `.vibeswitcher/flakes/`, which the lead reads.
    /// The vault's log (`saveMergeLog`) is the user's alone: no session may read it, so no message names it.
    func copyMergeLog(_ output: String, slug: String, commit: String, name: String = "merge-test.log", inWorktree: Bool = true) -> MergeLogCopy {
        guard output.utf8.count <= MergeFailure.copyLimit else {
            return MergeLogCopy(path: nil, why: "at \(Worktrees.Leftover.size(Int64(output.utf8.count))) it's over the \(Worktrees.Leftover.size(Int64(MergeFailure.copyLimit))) a copy can be")
        }
        let text = Redaction.secrets(in: scrubbed(output))
        var refused: String?
        if inWorktree {
            switch writeInWorktree(text, slug: slug, name: name) {
            case .success(let path): return MergeLogCopy(path: path)
            case .failure(let why): refused = why.text
            }
        }
        let log = String(MergeRerun.evidencePath(task: slug, commit: commit, at: Date()).dropLast(".log".count)) + "-\(name)"
        guard let saved = saveEvidence(text, log: log) else { return MergeLogCopy(path: nil, why: refused ?? "the folder for it couldn't be written") }
        return MergeLogCopy(path: MergeRerun.evidenceFile(root: root, log: saved), why: refused)
    }

    /// `output` without the vault's paths, as the sessions may see it: a merge runs in the vault's scratch, so its
    /// compiler errors and its scratch home's first line name folders no session may read. The merge's own folders go
    /// from the front of a path (`merge-x/Sources/A.swift` reads `Sources/A.swift`, as the repository has it); any other
    /// mention of one is said rather than named. Only the end of a log past `copyLimit`, as it's all that will be read.
    func scrubbed(_ output: String) -> String {
        let scratch = vault.scratch(root: root, "x").deletingLastPathComponent()
        var text = output.utf8.count > MergeFailure.copyLimit ? String(decoding: output.utf8.suffix(MergeFailure.readWindow), as: UTF8.self) : output
        for folder in Set([scratch.path, scratch.resolvingSymlinksInPath().path]) where text.contains(folder) {
            let escaped = NSRegularExpression.escapedPattern(for: folder)
            text = text.replacingOccurrences(of: escaped + #"/[^/\s]+/"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: escaped + #"/[^/\s]*"#, with: "(a scratch folder of the merge's)", options: .regularExpression)
        }
        return text
    }

    private struct CopyRefused: Error { let text: String }

    /// `text` as `<worktree>/.vibeswitcher/merge-failure/<name>`, 0600 in a 0700 folder. A worktree holds what its branch
    /// and its worker put there, so the copy is made only where git ignores it and only through real folders: a link
    /// there could lead the app's write anywhere.
    private func writeInWorktree(_ text: String, slug: String, name: String) -> Result<String, CopyRefused> {
        guard Worktrees.isWorktree(root: root, slug: slug) else { return .failure(CopyRefused(text: "it has none")) }
        let worktree = Worktrees.path(root: root, slug: slug)
        let relative = Self.worktreeLogFolder + "/" + name
        guard Git.run(["check-ignore", "-q", relative], in: worktree).ok else {
            return .failure(CopyRefused(text: "git doesn't ignore \(relative) there"))
        }
        var folder = worktree
        for part in Self.worktreeLogFolder.split(separator: "/") {
            folder += "/" + part
            var info = stat()
            guard lstat(folder, &info) != 0 || info.st_mode & S_IFMT == S_IFDIR else {
                return .failure(CopyRefused(text: "\(part) there isn't a plain folder"))
            }
        }
        let file = URL(fileURLWithPath: worktree + "/" + relative)
        do {
            try VibePaths.ensurePrivate(file.deletingLastPathComponent(), within: URL(fileURLWithPath: worktree + "/.vibeswitcher"))
            try VibePaths.writePrivate(Data(text.utf8), to: file)
            return .success(file.path)
        } catch {
            return .failure(CopyRefused(text: "it couldn't be written (\(error.localizedDescription))"))
        }
    }
}
