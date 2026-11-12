import Foundation

/// The pre-done check: what a worker's done report runs before it's taken (`LeadToolset.report`). The brief asked
/// workers to run their focused tests and the lints before reporting done, and some didn't: a worker reported done
/// twice while still needing rework (a-blocked-task-s), and 7 merges in 7 days needed a rerun of a 9–14 min suite.
/// Checks that must happen are the harness's, not the prompt's: a failing one refuses the report with its output, and
/// the worker goes back and fixes it. It's a help, not the gate: a run that times out or can't start lets the report
/// through, saying so, and the merge's full suite stays the gate.
///
/// What runs, first found: the task's own `done_check` (add_task, update_task), workflow.md's `done_check_command`
/// ("off": none), else the default, the brief's own commands: the project's test command filtered to its lint tests
/// (`LeadPrompts.Policy.lintTests`) and the suites of the files the branch changes, for a project that has lint tests
/// (its test command then takes swift test's options, as AGENTS.md's `bash scripts/test.sh --filter …` does). Without
/// one, nothing runs and the report goes through as before.
public enum LeadDoneCheck {
    /// workflow.md's or a task's word for no check at all.
    public static let off = "off"
    /// How many minutes a check may run (`done_check_min:`) before it's stopped, and lets the report through. A focused
    /// run here takes 1–2 min on an incremental build; the limit covers a slow one, never a full suite.
    public static let defaultMinutes: Double = 5
    /// The most of a failing check's output the refusal carries (its end, where the failures and the summary are).
    static let shownOutput = 6000

    /// Where a check's command came from, as the report's notes name it.
    public enum Source: String, Sendable {
        case task = "the task's done_check"
        case workflow = "workflow.md's done_check_command"
        case standard = "the default pre-done check (the lint tests and the suites of the files your branch changes)"
    }

    /// The command a done report runs, and where it came from; nil: none (set off, or no default for this project).
    /// `test`: the project's test command; `lints`: its lint tests' filter names; `suites`: those of the changed files.
    public static func command(task: String?, workflow: String?, test: String?, lints: [String], suites: [String]) -> (command: String, source: Source)? {
        let given = { (text: String?) -> String? in
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        if let own = given(task) { return own.lowercased() == off ? nil : (own, .task) }
        if let set = given(workflow) { return set.lowercased() == off ? nil : (set, .workflow) }
        guard let test = given(test), !lints.isEmpty else { return nil }
        let names = lints + suites.filter { !lints.contains($0) }
        return ("\(test) --filter '\(names.joined(separator: "|"))'", .standard)
    }

    /// The test suites of `changed` (paths from the repository's root): a changed test file's suites (the types it
    /// declares whose name ends in Tests, else its file's name: HistoryTests.swift holds ScrollbackTests), and for a
    /// changed source file `X.swift`, `XTests` when a test file of that name is among `testFiles`. `sources`: each
    /// changed test file's text. Sorted, each once.
    public static func suites(changed: [String], testFiles: [String], sources: [String: String] = [:]) -> [String] {
        let isTest = { (path: String) in path.hasPrefix("Tests/") && path.hasSuffix(".swift") }
        let testNames = Set(testFiles.filter(isTest).map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension })
        var found = Set<String>()
        for path in changed where path.hasSuffix(".swift") {
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            if isTest(path) {
                let declared = declaredSuites(sources[path] ?? "")
                if !declared.isEmpty { found.formUnion(declared) } else if name.hasSuffix("Tests") { found.insert(name) }
            } else if path.hasPrefix("Sources/"), testNames.contains(name + "Tests") {
                found.insert(name + "Tests")
            }
        }
        return found.sorted()
    }

    private static let declaredType = try! NSRegularExpression(pattern: #"\b(?:struct|class|actor|enum|extension)\s+([A-Za-z_][A-Za-z0-9_]*Tests)\b"#)

    /// The type names ending in Tests that `source` declares.
    static func declaredSuites(_ source: String) -> [String] {
        declaredType.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
    }

    /// `command` as it runs for a Codex worker: inside Codex's own sandbox, as its commands do (workspace-write: writes
    /// only in the worktree, `writable` and the temporary folders; no network), so the check can't do what the worker
    /// couldn't. `codex`: the Codex executable. When this process is in a sandbox already (`alreadySandboxed`: macOS
    /// refuses a sandbox inside one), it runs as it is, told it's inside Codex's: CODEX_SANDBOX set, as Codex sets it
    /// for its commands, so scripts/test.sh leaves SwiftPM's own sandbox out.
    public static func sandboxed(_ command: String, codex: String, writable: [String], alreadySandboxed: Bool) -> String {
        let quote = RecentProjects.shellQuote
        guard !alreadySandboxed else { return "export CODEX_SANDBOX=seatbelt\n" + command }
        let options = ["sandbox_mode=\"workspace-write\"",
                       "sandbox_workspace_write.writable_roots=" + LeadLaunch.toml(writable),
                       "sandbox_workspace_write.network_access=false"]
        return ([quote(codex), "sandbox"] + options.map { "-c " + quote($0) } + ["--", "/bin/bash", "-c", quote(command)]).joined(separator: " ")
    }

    /// Whether this process runs in a macOS sandbox (a Codex worker's tool server, if Codex sandboxes it): libsystem's
    /// `sandbox_check` on its own pid, with no operation, says so. False when it can't be asked.
    public static func inSandbox() -> Bool {
        typealias Check = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else { return false }
        return unsafeBitCast(symbol, to: Check.self)(getpid(), nil, 0) == 1
    }

    /// How a check went, for the report.
    public enum Outcome: Equatable, Sendable {
        case passed
        /// It failed: its output's end.
        case failed(String)
        /// It didn't decide: why (it ran past its limit, or couldn't start). The report goes through.
        case undecided(String)
        /// The call was cancelled (its client gave up, or the server stops): nothing is recorded, as for a refusal.
        case cancelled
    }

    /// The outcome of `runChecks`' result for a check limited to `limit`.
    static func outcome(_ stopped: Worktrees.Check?, limit: TimeInterval) -> Outcome {
        switch stopped {
        case nil, .passed?, .passedOnRerun?, .passedRedOnBase?: return .passed
        case .failed(let output)?: return .failed(tail(output))
        case .hung(_, let after, _, let stall)?:
            return .undecided(stall == nil ? "it ran past its \(Worktrees.duration(limit)) limit and was stopped"
                              : "it made no progress and was stopped (\(Worktrees.hung(after: after, stall: stall)))")
        case .error(let text)?: return .undecided("it couldn't start: \(text)")
        case .cancelled?: return .cancelled
        case .conflict?: return .undecided("it couldn't start")
        }
    }

    /// How long a report call may take with a check limited to `limit`: a wait for a slot up to `limit`, the run up to
    /// `limit`, and two minutes for the rest. A Codex worker's tool server is given it (`LeadLaunch.prepareCodex`).
    public static func callTimeout(limit: TimeInterval) -> TimeInterval { 2 * limit + 120 }

    /// `output`'s last `shownOutput` characters, from a line's start.
    static func tail(_ output: String) -> String {
        guard output.count > shownOutput else { return output }
        let end = String(output.suffix(shownOutput))
        let cut = end.firstIndex(of: "\n").map { end.index(after: $0) } ?? end.startIndex
        return "…\n" + end[cut...]
    }

    /// The refusal of a done report whose check failed.
    public static func refusal(command: String, source: Source, output: String) -> String {
        "Not reported: the pre-done check failed (\(source.rawValue): `\(command)`). Fix what it shows, commit, and report "
            + "done again; it runs again then. Its output's end:\n\(output)"
    }

    /// What the report's reply and the lead's note say of a check that didn't decide.
    public static func undecidedNote(command: String, why: String) -> String {
        "The pre-done check (`\(command)`) didn't decide: \(why). The report went through; the merge's full suite is the gate."
    }
}
