import Foundation

/// A merge's one rerun of its failing tests. Over 2026-10-18..25, 17 of 29 failing merge runs passed when the lead ran
/// merge again by hand: each such retry built and ran the whole suite in a fresh worktree, and a worker was often sent
/// back first. Now, when the test command fails, the failing tests run once more in the same worktree (its build
/// already made), holding the same slot of the test lock; if they pass, the merge goes ahead and each is recorded as a
/// flake (`LeadBoard.recordFlakes`). If they fail again, the merge is refused with the rerun's output, as before. Never
/// more than one rerun.
///
/// What runs again: the failing tests only when the test command takes `swift test`'s options last (`filterable`:
/// this repository's `bash scripts/test.sh`, or `swift test` itself), as `--filter` patterns; else (any other command,
/// a failure naming no test, more than `filterLimit` of them, or a run that crashed or was stopped partway, so the rest
/// of the suite never ran) the whole test command. Then regression_command, as
/// merge always runs it: it's never skipped. No rerun after a build error (the output names errors and no test), nor
/// after regression_command fails: the incidents' checks aren't retried.
public enum MergeRerun {
    /// The most failing tests a rerun names; more, and the whole test command runs again.
    public static let filterLimit = 20

    /// What a failed run is run again as: `command`, and the tests it names (empty when it runs everything).
    public struct Plan: Equatable, Sendable {
        /// The failing tests, as the output named them (empty when none was).
        public var tests: [String]
        /// The rerun runs only them (`--filter`); false: the whole test command.
        public var filtered: Bool
        /// The script to run in the failed one's place: the test command (filtered or not), then regression_command.
        public var command: String
    }

    /// The rerun after `workflow`'s merge checks failed with `output`; nil when there's none.
    public static func plan(after output: String, workflow: LeadWorkflow) -> Plan? {
        guard let test = workflow.testCommand,
              !output.components(separatedBy: "\n").contains(LeadWorkflow.regressionMarker) else { return nil }
        let failures = TestFailures(output: output)
        var tests = failures.tests
        for name in failures.unfinished where !tests.contains(name) { tests.append(name) }
        // A build that failed fails again.
        if tests.isEmpty, !failures.errors.isEmpty { return nil }
        var again = workflow
        let patterns = tests.map(pattern)
        // A run that crashed or was stopped (tests started and never ended) never ran the rest of the suite: it all
        // runs again, so nothing merges that only part of the suite checked.
        let filtered = filterable(test) && !tests.isEmpty && tests.count <= filterLimit && !patterns.contains(nil)
            && failures.unfinished.isEmpty
        if filtered {
            again.testCommand = test.trimmingCharacters(in: .whitespacesAndNewlines) + " --filter "
                + RecentProjects.shellQuote(patterns.compactMap { $0 }.joined(separator: "|"))
        }
        guard let command = again.mergeChecks else { return nil }
        return Plan(tests: tests, filtered: filtered, command: command)
    }

    /// Whether `command` ends in `swift test`'s options, so `--filter` can be added to it: one line, `swift test` (after
    /// `swift build &&` at most) or `[bash ]scripts/test.sh`, with no shell syntax that would put the option elsewhere.
    public static func filterable(_ command: String) -> Bool {
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = #"( +[^;&|<>`$()\n'"\\]*)?$"#
        return line.range(of: #"^(swift build *&& *)?swift test"# + options, options: .regularExpression) != nil
            || line.range(of: #"^((ba)?sh +)?(\./)?scripts/test\.sh"# + options, options: .regularExpression) != nil
    }

    /// The `swift test --filter` pattern for a test as `TestFailures` names it: a Swift Testing function
    /// (`name()`, `param(n:)`: matched as its identifier's last part, `Module.Suite/name()`), or an XCTest
    /// `Suite.testName` (`Module.Suite/testName`). Nil for a display name (`"Some words"`), which no filter matches.
    /// A Swift Testing ID ends in its source location (`…/name()/File.swift:46:6`), hence `(/|$)`, not `$`: with `$`
    /// the filter matched nothing and `swift test` passed with 0 tests run.
    static func pattern(_ test: String) -> String? {
        guard !test.hasPrefix("\""), !test.isEmpty else { return nil }
        if test.hasSuffix(")") { return "/" + NSRegularExpression.escapedPattern(for: test) + "(/|$)" }
        let parts = test.split(separator: ".")
        guard parts.count == 2 else { return nil }
        return "\\." + NSRegularExpression.escapedPattern(for: String(parts[0])) + "/" + NSRegularExpression.escapedPattern(for: String(parts[1])) + "$"
    }

    /// Whether a rerun that exited 0 counts as a pass: a whole run does; a filtered one only when its output shows
    /// each test it was for passing (a filter that matched nothing runs nothing, and passes). The tests it didn't show
    /// passing; empty when it counts.
    public static func unshown(_ plan: Plan, rerun output: String) -> [String] {
        guard plan.filtered else { return [] }
        let lines = output.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        return plan.tests.filter { test in
            !lines.contains { line in
                ["✔", "􁁛"].contains { line.hasPrefix("\($0) Test \(test) passed after") }
                    || TestFailures.passedWithKnownIssues(line) == test
                    || (line.hasPrefix("Test Case '") && line.contains(test.replacingOccurrences(of: ".", with: " ") + "]' passed"))
            }
        }
    }

    /// What a flake is recorded under when the failed run named no test.
    public static let unnamed = "(the test command, naming no test)"

    // MARK: Evidence

    /// The most lines a flaky test's evidence keeps, and the most characters of each.
    public static let evidenceLimit = 20
    static let evidenceWidth = 400

    /// Each of `tests`' failure lines in a failed run's `output`, where workers and verifiers can read them: the merge's
    /// own log is in the vault's scratch, which every session's permissions refuse (on 2026-10-28 three fix tasks and
    /// their verifiers re-derived each flake's cause by reproduction). Swift Testing's issue lines ("recorded an issue
    /// at File.swift:12:5: …", with the ↳ details and an expectation's source lines under them, as `TestFailures`
    /// reads them) and its "failed after" line; XCTest's error: and "Test Case … failed" lines. Secrets masked
    /// (`Redaction`), each line cut at `evidenceWidth`, at most `evidenceLimit` lines a test. A test with none is left out.
    public static func evidence(in output: String, tests: [String]) -> [String: [String]] {
        var found: [String: [String]] = [:]
        var issue: (test: String, count: Int)?
        for raw in output.components(separatedBy: "\n") {
            let plain = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            let line = plain.trimmingCharacters(in: .whitespaces)
            if let (test, count) = issue {
                if line.hasPrefix("↳ ") { found[test, default: []].append(line); continue }
                if count < 20, !line.isEmpty, line.range(of: #"^\S (Test|Suite|Passing) "#, options: .regularExpression) == nil {
                    found[test, default: []].append(plain.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression))
                    issue = (test, count + 1)
                    continue
                }
            }
            issue = nil
            if let test = TestFailures.swiftTesting(line, " recorded an issue") {
                found[test, default: []].append(line)
                issue = (test, 0)
            } else if let test = TestFailures.swiftTesting(line, " failed after") {
                found[test, default: []].append(line)
            } else if let match = line.range(of: #": error: -?\[?[^ :\]]+[ .][^ :\]]+\]? : "#, options: .regularExpression) {
                found[TestFailures.xcTestName(String(line[match]).dropFirst(": error: ".count).dropLast(3)), default: []].append(line)
            } else if let match = line.range(of: #"^Test Case '[^']+' failed"#, options: .regularExpression) {
                found[TestFailures.xcTestName(line[match].dropFirst("Test Case '".count).prefix { $0 != "'" }), default: []].append(line)
            }
        }
        var evidence: [String: [String]] = [:]
        for test in tests {
            guard let lines = found[test], !lines.isEmpty else { continue }
            evidence[test] = capped(lines)
        }
        return evidence
    }

    /// `lines` with secrets masked, each cut at `evidenceWidth`, at most `evidenceLimit` of them. Masked together, so a
    /// secret an expectation spreads over lines is seen whole. Lines it gave back come back the same.
    static func capped(_ lines: [String]) -> [String] {
        let masked = Redaction.secrets(in: lines.joined(separator: "\n")).components(separatedBy: "\n")
            .map { $0.count > evidenceWidth ? String($0.prefix(evidenceWidth - 1)) + "…" : $0 }
        return masked.count > evidenceLimit
            ? masked.prefix(evidenceLimit - 1) + ["… and \(masked.count - evidenceLimit + 1) more lines."] : masked
    }

    /// Where a merge's flake evidence is kept, relative to the repository's root (as the ledger keeps it, so the
    /// board's size doesn't grow with the root's): `.vibeswitcher/flakes/<yyyy-mm-dd>-<task>-<commit>.log`, in its
    /// ignored folder, where every session can read it. The merge's short commit tells a task's merges on one day apart.
    public static func evidencePath(task: String, commit: String, at date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.dateFormat = "yyyy-MM-dd"
        return ".vibeswitcher/flakes/\(format.string(from: date))-\(task)-\(commit.prefix(8)).log"
    }

    public static func evidenceFile(root: String, task: String, commit: String, at date: Date) -> URL {
        URL(fileURLWithPath: evidenceFile(root: root, log: evidencePath(task: task, commit: commit, at: date)))
    }

    /// A ledger entry's `log` as a path to open: relative to `root`, or absolute as entries before kept it.
    public static func evidenceFile(root: String, log: String) -> String {
        log.hasPrefix("/") ? log : (root as NSString).appendingPathComponent(log)
    }

    /// The evidence file's text: what flaked in `task`'s merge (tested at `commit`), and each test's lines.
    public static func evidenceLog(task: String, commit: String, evidence: [String: [String]], tests: [String]) -> String {
        var text = "Flaky in \(task)'s merge (tested \(commit.prefix(12))): each test below failed the merge's first test run and passed its rerun. "
            + "Its lines from the failing run (secrets masked, at most \(evidenceLimit) a test):\n"
        for test in tests {
            guard let lines = evidence[test] else { continue }
            text += "\n" + test + "\n" + lines.map { "    " + $0 }.joined(separator: "\n") + "\n"
        }
        return text
    }

    // MARK: A hung run

    /// The most of a hung run's output its evidence keeps: its last lines.
    public static let hungTail = 60

    private static let swiftTestingEvent = try! NSRegularExpression(
        pattern: #"^\S{1,2} Test (.+?) (started\.$|passed after |failed after |skipped(\.$|:| with))"#)
    private static let xcTestEvent = try! NSRegularExpression(pattern: #"^Test Case '([^']+)' (started|passed|failed|skipped)"#)

    /// The tests a stopped run's `output` shows started and never finished, in the order they started: Swift Testing's
    /// "◇ Test x() started." with no "passed after", "failed after" or "skipped" line of its own, XCTest's "Test Case
    /// '-[Module.Suite testName]' started." with no "passed", "failed" or "skipped" one. On 2026-10-28 a merge hung
    /// 45 min and its log was in the vault's scratch, which no session can read: its fixer had to guess which test hung.
    public static func hung(in output: String) -> [String] {
        var started: [String] = [], ended: Set<String> = []
        for raw in output.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            var name: String, event: String
            if let match = swiftTestingEvent.firstMatch(in: line, range: range),
               let found = Range(match.range(at: 1), in: line), let what = Range(match.range(at: 2), in: line) {
                name = String(line[found])
                event = String(line[what])
                // The run's own lines ("◇ Test run started.", "✔ Test run with 5 tests passed after …").
                guard name != "run", !name.hasPrefix("run with ") else { continue }
            } else if let match = xcTestEvent.firstMatch(in: line, range: range),
                      let found = Range(match.range(at: 1), in: line), let what = Range(match.range(at: 2), in: line) {
                name = TestFailures.xcTestName(line[found])
                event = String(line[what])
            } else {
                continue
            }
            if event.hasPrefix("started") {
                if !started.contains(name) { started.append(name) }
            } else {
                ended.insert(name)
            }
        }
        return started.filter { !ended.contains($0) }
    }

    /// Where a hung merge's evidence is kept, beside its flake evidence: `.vibeswitcher/flakes/<yyyy-mm-dd>-<task>-<commit>-hung.log`.
    public static func hungPath(task: String, commit: String, at date: Date) -> String {
        String(evidencePath(task: task, commit: commit, at: date).dropLast(".log".count)) + "-hung.log"
    }

    /// The hung file's text: which of `task`'s merge commands (`command`, testing `commit`) ran past test_timeout_min
    /// (`after`) and was stopped, the tests its `output` left started and unfinished (`hung(in:)`), and the output's
    /// last `hungTail` lines. Masked whole before it's cut (`Redaction`): a secret the tail starts partway into (a
    /// key's lines under its header) is masked as it would be in full. Each line cut at `evidenceWidth`.
    public static func hungLog(task: String, commit: String, command: String, after: TimeInterval, output: String) -> String {
        let masked = Redaction.secrets(in: output).components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        let tail = masked.reversed().drop { $0.isEmpty }.prefix(hungTail).reversed()
            .map { $0.count > evidenceWidth ? String($0.prefix(evidenceWidth - 1)) + "…" : $0 }
        let tests = hung(in: masked.joined(separator: "\n"))
        let what = command == "rerun" ? "the rerun of its failing tests" : "its \(command)"
        var text = "Hung in \(task)'s merge (tested \(commit.prefix(12))): \(what) ran past test_timeout_min (\(Worktrees.duration(after))) and was stopped, with everything started under it.\n"
        text += tests.isEmpty ? "\nNo test in its output started and never finished.\n"
            : "\nStarted and never finished (secrets masked):\n" + tests.map { "    " + $0 }.joined(separator: "\n") + "\n"
        text += "\nIts output's last \(tail.count) lines (secrets masked, each cut at \(evidenceWidth) characters):\n"
            + tail.map { "    " + $0 }.joined(separator: "\n") + "\n"
        return text
    }

    /// The most of an evidence file read back: more than a merge's evidence writes.
    static let evidenceRead = 1 << 20

    /// `test`'s lines in the evidence file at `path` (as `evidenceLog` wrote them), masked and capped again
    /// (`capped`): the file is the repository's to change. Nil when it can't be read (gone, or not a plain file).
    /// Opened without blocking: a FIFO put in its place would otherwise hold the merge, and the board's lock it's read
    /// under, until something wrote to it.
    static func evidence(for test: String, inLog path: String) -> [String]? {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let data = try? handle.read(upToCount: evidenceRead) else { return nil }
        // A test's lines: under its name, after a blank line, each indented four spaces.
        var lines: [String] = [], found = false, previous: String?
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
            if found {
                guard line.hasPrefix("    ") else { break }
                lines.append(String(line.dropFirst(4)))
            } else if line == test, previous == "" {
                found = true
            }
            previous = line
        }
        return lines.isEmpty ? [] : capped(lines)
    }

    /// For a task's context: each of `flakes`' failing lines, read from its evidence file, under the merge it held up
    /// and where that file is. The ledger keeps only the file's path: the board is read and rewritten by every lead
    /// call, and 200 entries' lines would make it megabytes.
    static func quoted(_ flakes: [LeadFlake], root: String) -> String {
        var text = ""
        for flake in flakes {
            guard let log = flake.log.map({ evidenceFile(root: root, log: $0) }) else { continue }
            text += "\n- \(flake.task)'s merge (\(log)):"
            guard let lines = evidence(for: flake.test, inLog: log) else {
                text += " (its file can't be read now)"
                continue
            }
            for line in lines { text += "\n    " + line }
        }
        return text.isEmpty ? "" : "\nThe failing runs' lines (secrets masked):" + text
    }

    /// The line added to an open task's context that names `test` (`LeadBoard.openTask(naming:)`) once it flaked
    /// `LeadBoard.flakeLimit` times within `LeadBoard.flakeWindow` (`flakes`, oldest first), in place of a task to fix
    /// it, with the failing runs' lines.
    static func flakeNote(test: String, flakes: [LeadFlake], root: String) -> String {
        let merges = flakes.map(\.task)
        return "Flake ledger: \(test) flaked \(merges.count) times within \(Int(LeadBoard.flakeWindow / 86_400)) days (failed its first run and passed its rerun in the merges of \(merges.joined(separator: ", "))); no task was planned to fix it, as this one names it."
            + quoted(flakes, root: root)
    }

    /// The task planned once `test` flaked `LeadBoard.flakeLimit` times within `LeadBoard.flakeWindow`: `flakes` (in
    /// the merges they held up, oldest first), whose failing lines its context quotes from their files under `root`.
    static func fixContract(test: String, flakes: [LeadFlake], workflow: LeadWorkflow, root: String) -> LeadContract {
        let merges = flakes.map(\.task)
        let tests = workflow.testCommand.map { "`\($0)` passes" } ?? "The project's tests pass"
        return LeadContract(
            goal: "\(test) stops flaking: it failed \(merges.count) merges' test runs within \(Int(LeadBoard.flakeWindow / 86_400)) days and passed each one's rerun, so the merges went ahead on the rerun alone.",
            acceptance: ["Say why it failed (a fixed sleep, a wall-clock window, a race in the test, or a real bug in what it tests), with the evidence from the merges' runs",
                         "If it's a real bug, fix the code; if it's the test, it waits on the real event it checks (a file, a reply, a semaphore, an injected clock), never a fixed sleep or a wall-clock window",
                         "It passes repeatedly under load (scripts/test-under-load.sh when the project has it)",
                         tests],
            boundaries: ["The test and what it checks; nothing else changes unless it's the bug"],
            context: "Flake ledger (the board's flakes; status lists them): \(test) failed its first run and passed its rerun in the merges of \(merges.joined(separator: ", "))."
                + quoted(flakes, root: root))
    }
}
