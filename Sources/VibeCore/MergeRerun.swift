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

    /// The line added to an open task's context that names `test` (`LeadBoard.openTask(naming:)`) once it flaked
    /// `LeadBoard.flakeLimit` times within `LeadBoard.flakeWindow`, in place of a task to fix it.
    static func flakeNote(test: String, merges: [String]) -> String {
        "Flake ledger: \(test) flaked \(merges.count) times within \(Int(LeadBoard.flakeWindow / 86_400)) days (failed its first run and passed its rerun in the merges of \(merges.joined(separator: ", "))); no task was planned to fix it, as this one names it."
    }

    /// The task planned once `test` flaked `LeadBoard.flakeLimit` times within `LeadBoard.flakeWindow`: in `merges`
    /// (the tasks whose merges it held up, oldest first).
    static func fixContract(test: String, merges: [String], workflow: LeadWorkflow) -> LeadContract {
        let tests = workflow.testCommand.map { "`\($0)` passes" } ?? "The project's tests pass"
        return LeadContract(
            goal: "\(test) stops flaking: it failed \(merges.count) merges' test runs within \(Int(LeadBoard.flakeWindow / 86_400)) days and passed each one's rerun, so the merges went ahead on the rerun alone.",
            acceptance: ["Say why it failed (a fixed sleep, a wall-clock window, a race in the test, or a real bug in what it tests), with the evidence from the merges' runs",
                         "If it's a real bug, fix the code; if it's the test, it waits on the real event it checks (a file, a reply, a semaphore, an injected clock), never a fixed sleep or a wall-clock window",
                         "It passes repeatedly under load (scripts/test-under-load.sh when the project has it)",
                         tests],
            boundaries: ["The test and what it checks; nothing else changes unless it's the bug"],
            context: "Flake ledger (the board's flakes; status lists them): \(test) failed its first run and passed its rerun in the merges of \(merges.joined(separator: ", ")).")
    }
}
