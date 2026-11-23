import Foundation

/// A merge's one rerun of its failing tests. Over 2026-10-18..25, 17 of 29 failing merge runs passed when the lead ran
/// merge again by hand: each such retry built and ran the whole suite in a fresh worktree, and a worker was often sent
/// back first. Now, when the test command fails, the failing tests run once more in the same worktree (its build
/// already made), holding the same slot of the test lock; if they pass, the merge goes ahead and each is recorded as a
/// flake (`FlakeLedger.recordFlakes`). Never more than one rerun.
///
/// When a filtered rerun fails, the tests it still fails (`redOnBranch`) run once on the base (`baseline`). Green
/// there: the branch's failure, and the merge is refused with the rerun's output, as before. Red there too
/// (`excused`): broken or flaky before the branch, so they don't send it back. The rest of its checks ran on the
/// branch first without them (`rest`: the test command skipping them, then regression_command), and passed: the merge
/// goes ahead and each such test gets a task to fix it, or a note in the open task that names it. On 2026-11-06 and
/// 11-07 two branches were sent back for AccountUsage date tests that were red on main. Either way the rerun goes in
/// the flake ledger with the base's result (`LeadRerunRecord`).
///
/// What runs again: the failing tests only when the test command takes `swift test`'s options last (`filterable`:
/// this repository's `bash scripts/test.sh`, or `swift test` itself), as `--filter` patterns; else (any other command,
/// more than `filterLimit` of them, or an ambiguous selection) the whole test command. A run stopped partway skips
/// only suites proved to have passed in full, by the module-qualified IDs discovery gives them (`continuation`);
/// unfinished, never-started and unresolved suites still run, and a run that left processes or preferences behind
/// reruns whole. Then regression_command, as
/// merge always runs it: it's never skipped. No rerun after a build error (the output names errors and no test), nor
/// after regression_command fails: the incidents' checks aren't retried.
public enum MergeRerun {
    /// The most failing tests a rerun names; more, and the whole test command runs again.
    public static let filterLimit = 20

    /// What a failed run is run again as: `command`, and the tests it names (empty when it runs everything).
    public struct Plan: Equatable, Sendable {
        /// The failing tests, as the output named them (empty when none was).
        public var tests: [String]
        /// The rerun selects a subset (named tests or unfinished suites); false: the whole test command.
        public var filtered: Bool
        /// The script to run in the failed one's place: the test command (filtered or not), then regression_command.
        public var command: String
        /// The filtered test command alone, run once on the base the branch was rebased onto to pair with the
        /// branch's failure (`MergeRerun.baseline`); nil for a whole rerun, which isn't run twice.
        public var baseCommand: String?
        /// A continuation skips completed suites instead of selecting just the named failures. These are the
        /// started suites it must show passing, and its selection note (also kept in the ledger's existing notes).
        public var requiredSuites: [String] = []
        public var note: String?

        public init(tests: [String], filtered: Bool, command: String, baseCommand: String? = nil,
                    requiredSuites: [String] = [], note: String? = nil) {
            self.tests = tests
            self.filtered = filtered
            self.command = command
            self.baseCommand = baseCommand
            self.requiredSuites = requiredSuites
            self.note = note
        }

        public var continuing: Bool { note?.hasPrefix("Unfinished-suite rerun:") == true }

        /// Included in the saved merge output, so a whole rerun explains itself even when it fails.
        public var annotatedCommand: String {
            guard let note else { return command }
            return "printf '%s\\n' \(RecentProjects.shellQuote(note))\n" + command
        }
    }

    /// The rerun after `workflow`'s merge checks failed with `output`; nil when there's none. `suites`: the test IDs
    /// discovery lists (`discoverTests`), asked only for a run that stopped partway.
    public static func plan(after output: String, workflow: LeadWorkflow, suites discovered: () -> [String]? = { nil }) -> Plan? {
        guard let test = workflow.testCommand,
              !output.components(separatedBy: "\n").contains(LeadWorkflow.regressionMarker) else { return nil }
        let failures = TestFailures(output: output)
        let ranToEnd = finished(output)
        var tests = failures.tests
        if !ranToEnd { for name in failures.running where !tests.contains(name) { tests.append(name) } }
        // A build that failed fails again. (A crash that left tests unfinished isn't one, named or not.)
        if tests.isEmpty, failures.unfinished.isEmpty, !failures.errors.isEmpty,
           output.range(of: #"(?m)^\S{1,2} Test run started\.$"#, options: .regularExpression) == nil,
           suiteEvents(output).isEmpty { return nil }
        var again = workflow
        let patterns = tests.map(pattern)
        let named = !tests.isEmpty && tests.count <= filterLimit && !patterns.contains(nil)
        let baseCommand = named && filterable(test) ? test.trimmingCharacters(in: .whitespacesAndNewlines) + " --filter "
            + RecentProjects.shellQuote(patterns.compactMap { $0 }.joined(separator: "|")) : nil
        var filtered = false, required: [String] = [], note: String?
        if !filterable(test) {
            note = "Whole rerun: the test command cannot safely take Swift test filters."
        } else if ranToEnd, let baseCommand {
            filtered = true
            again.testCommand = baseCommand
        } else if !ranToEnd {
            let selection = continuation(output, command: test, discovered: discovered)
            if let skip = selection.skip {
                filtered = true
                again.testCommand = test.trimmingCharacters(in: .whitespacesAndNewlines) + " --skip " + RecentProjects.shellQuote(skip)
                required = selection.required
                note = "Unfinished-suite rerun: skipped \(selection.count) completed passing suites; unfinished and never-started suites still run."
            } else {
                note = "Whole rerun: " + selection.why + "."
            }
        } else {
            note = "Whole rerun: " + (tests.isEmpty ? "the failure named no test" : tests.count > filterLimit
                ? "more than \(filterLimit) tests failed" : "a failing test has no unambiguous filter") + "."
        }
        guard let command = again.mergeChecks else { return nil }
        return Plan(tests: tests, filtered: filtered, command: command, baseCommand: filtered ? baseCommand : nil,
                    requiredSuites: required, note: note)
    }

    private static let suiteEvent = try! NSRegularExpression(pattern: #"^\S{1,2} Suite (.+) (started\.|passed after .+|failed after .+)$"#)

    private static func suiteEvents(_ output: String) -> [(name: String, event: String)] {
        output.components(separatedBy: "\n").compactMap { raw in
            let line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard let match = suiteEvent.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let name = Range(match.range(at: 1), in: line), let event = Range(match.range(at: 2), in: line) else { return nil }
            return (String(line[name]), String(line[event]))
        }
    }

    /// Discovery is through the merge's runner: the same scratch home, branch-code wrapper and held heavy slot.
    /// A failed discovery never supplies a partial inventory. `--skip-build` lists the tests just built by the run:
    /// each test's ID, `Module.Suite/test()` or, in a nested suite, `Module.Outer/Inner/test()`.
    static func discoverTests(command: String, run: (String) -> Git.Result) -> [String]? {
        let listed = run(command + " --skip-build --list-tests")
        guard listed.ok else { return nil }
        let ids = listed.output.components(separatedBy: "\n").filter {
            $0.range(of: #"^[^\s/]+\.[^\s/]+(/[^\s/]+)+$"#, options: .regularExpression) != nil
        }
        return ids.isEmpty ? nil : Array(Set(ids)).sorted()
    }

    /// The label Swift Testing prints for a suite ID: a top-level suite's type (`Module.Suite` prints `Suite`), a nested
    /// one's last part (`Module.Outer/Inner` prints `Inner`).
    static func label(of suite: String) -> String {
        guard let last = suite.components(separatedBy: "/").last else { return suite }
        return suite.contains("/") ? last : String(last.drop { $0 != "." }.dropFirst())
    }

    /// Output gives short suite labels, while filters take module-qualified IDs. A label skips its suites only when
    /// discovery holds as many suite IDs of that label (nested suites included) as the output started, and each of
    /// them passed in full: two `TestHomeGuardTests`, one in each of two modules, that both passed are both skipped.
    /// Each test under a skipped suite must also show its own pass. A label that doesn't resolve that way (a display
    /// name, a suite of that label that hadn't started, one that failed or never ended) is simply not skipped: it runs
    /// again. Missing discovery, nothing provably complete or nothing left to resume costs a whole rerun.
    private static func continuation(_ output: String, command: String, discovered: () -> [String]?)
        -> (skip: String?, required: [String], count: Int, why: String) {
        func whole(_ why: String) -> (String?, [String], Int, String) { (nil, [], 0, why) }
        // Discovery must describe this exact build/selection. Other options may select another configuration,
        // package or scratch path, or skip tests: support those only once discovery can reproduce them exactly.
        guard ["bash scripts/test.sh", "sh scripts/test.sh", "scripts/test.sh", "./scripts/test.sh", "swift test", "swift build && swift test"]
            .contains(command.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return whole("the stopped run's command has options discovery cannot reproduce")
        }
        // scripts/test.sh says so after all the Swift tests, naming no suite: any passed suite may have left them, and
        // a rerun that skipped it would see nothing left (each run compares its own before and after).
        guard !suiteMarkers.contains(where: output.contains) else {
            return whole("the stopped run left processes or preferences behind, which no suite can be told from")
        }
        var starts: [String: Int] = [:], passes: [String: Int] = [:], failed: Set<String> = []
        var order: [String] = []
        for (name, event) in suiteEvents(output) {
            if event == "started." {
                if starts[name] == nil { order.append(name) }
                starts[name, default: 0] += 1
            } else if event.hasPrefix("passed after ") { passes[name, default: 0] += 1 }
            else { failed.insert(name) }
        }
        let complete = order.filter { passes[$0] == starts[$0] && !failed.contains($0) }
        guard !complete.isEmpty else { return whole("the run stopped partway without proving any complete passing suite") }
        guard let ids = discovered(), !ids.isEmpty else { return whole("suite discovery was unavailable or failed") }
        // Every suite a test ID names (each prefix of its path), with the tests under it at any depth.
        var under: [String: [String]] = [:]
        for id in ids {
            // A test whose name repeats elsewhere is listed with its source location: `…/test()/File.swift:8:6`.
            var parts = id.components(separatedBy: "/")
            if parts.count > 2, parts[parts.count - 1].range(of: #"\.swift:\d+:\d+$"#, options: .regularExpression) != nil { parts.removeLast() }
            for depth in 1..<parts.count { under[parts[..<depth].joined(separator: "/"), default: []].append(parts[parts.count - 1]) }
        }
        let byLabel = Dictionary(grouping: under.keys.sorted(), by: label(of:))
        // How many times each test's own pass line shows ("✔ Test x() passed after", a parameterized one's
        // "… with 2 test cases passed after", a known issue's "━ … passed after").
        var shown: [String: Int] = [:]
        for raw in output.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard let match = testPass.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let name = Range(match.range(at: 1), in: line) else { continue }
            shown[String(line[name]), default: 0] += 1
        }
        var skipped: [String] = [], needed: [String: Int] = [:]
        for name in complete {
            guard let suites = byLabel[name], suites.count == starts[name] else { continue }
            for suite in suites where !skipped.contains(where: { suite == $0 || suite.hasPrefix($0 + "/") }) {
                var wants = needed
                for test in under[suite] ?? [] { wants[test, default: 0] += 1 }
                // Outer suites skipped after their nested ones cover them: count their tests once.
                for inner in skipped where inner.hasPrefix(suite + "/") { for test in under[inner] ?? [] { wants[test, default: 0] -= 1 } }
                guard wants.allSatisfy({ shown[$0.key, default: 0] >= $0.value }) else { continue }
                needed = wants
                skipped = skipped.filter { !$0.hasPrefix(suite + "/") } + [suite]
            }
        }
        guard !skipped.isEmpty else { return whole("no completed suite's ID could be told from discovery") }
        func covered(_ id: String) -> Bool { skipped.contains { id == $0 || id.hasPrefix($0 + "/") } }
        guard ids.contains(where: { !covered($0) }) else { return whole("discovery shows no remaining suite to resume") }
        let pattern = skipped.sorted().map { "^" + NSRegularExpression.escapedPattern(for: $0) + "(/|$)" }.joined(separator: "|")
        guard pattern.utf8.count <= 65_536 else { return whole("the completed-suite filter is too large") }
        // Each label the rerun runs must show passing as often as the first run started it.
        var required: [String] = []
        for name in order {
            let skippedHere = (byLabel[name] ?? []).filter(covered).count
            required += Array(repeating: name, count: max(0, starts[name, default: 0] - skippedHere))
        }
        return (pattern, required, skipped.count, "")
    }

    private static let testPass = try! NSRegularExpression(pattern: #"^\S{1,2} Test (.+?\))(?: with \d+ test cases?)? passed after "#)

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
    /// A parameterized test's end names its cases ("✘ Test f(hook:) with 2 test cases failed after …"), so `TestFailures`
    /// names it both ways: the filter is its function's (on 2026-11-16 the case count's name sent a rerun whole).
    static func pattern(_ test: String) -> String? {
        let test = test.replacingOccurrences(of: #"\) with \d+ test cases?$"#, with: ")", options: .regularExpression)
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
        var missing = plan.tests.filter { test in
            // Its function's own passing line, or its cases' ("✔ Test f(hook:) with 2 test cases passed after"); a
            // known issue's mark ("━ Test f() passed after 1.0 seconds with 1 known issue.") passed too.
            let function = test.replacingOccurrences(of: #"\) with \d+ test cases?$"#, with: ")", options: .regularExpression)
            let passed = #"^\S{1,2} Test "# + NSRegularExpression.escapedPattern(for: function) + #"( with \d+ test cases?)? passed after "#
            return !lines.contains { line in
                line.range(of: passed, options: .regularExpression) != nil
                    || (line.hasPrefix("Test Case '") && line.contains(test.replacingOccurrences(of: ".", with: " ") + "]' passed"))
            }
        }
        if plan.continuing {
            var passed: [String: Int] = [:]
            for event in suiteEvents(output) where event.event.hasPrefix("passed after ") { passed[event.name, default: 0] += 1 }
            for name in plan.requiredSuites {
                if passed[name, default: 0] > 0 { passed[name, default: 0] -= 1 } else { missing.append("suite \(name)") }
            }
            // Zero matches, or a process that exited 0 without finishing, isn't a continuation's pass.
            if !finished(output) || !lines.contains(where: { $0.range(of: #"^\S{1,2} Test run with [1-9]\d* tests?\b.* passed after "#, options: .regularExpression) != nil }) {
                missing.append("a completed nonempty test run")
            }
        }
        return missing
    }

    // MARK: Ran to its end

    /// Swift Testing's closing line: "✘ Test run with 547 tests in 80 suites failed after 190.1 seconds with 1 issue."
    private static let runEnd = try! NSRegularExpression(pattern: #"^\S{1,2} Test run with \d+ tests?\b.* (passed|failed) after "#)

    /// Whether a failed run's `output` ran to its end: each explicit run start has its own closing summary, and either
    /// no test it started was left unfinished, or Swift Testing's
    /// closing line came after the last test started, with no fatal error after it, and its output shows as many issue
    /// lines as that line counts (one glued to a test's own output would leave a failure unnamed), less its known
    /// issues: "with 5 issues (including 4 known issues)" is one failure, and a known issue's lines carry a mark of their
    /// own ("━ Test x() recorded a known issue"). Counting them all against the ✘ lines judged every whole run of this
    /// repository (4 tests pass with known issues) not finished: none of the 29 merge reruns of 2026-11-08..18 ran
    /// filtered, cache-aware-vibeswitcher's for one named test included. A crash or a stop
    /// ends the output with tests started and no closing line: the rest of the suite never ran (`plan` resumes it).
    /// A run that ended and named its failing tests reruns just them, whatever start lines its output left open: a
    /// parameterized test's cases print their start ("◇ Test case passing 2 arguments … started.") and no end when they
    /// pass, so a whole suite's run leaves hundreds open.
    public static func finished(_ output: String) -> Bool {
        let unfinished = !TestFailures(output: output).unfinished.isEmpty
        var ended = false, counted = 0, issues = 0, pendingRun = false, interruptedRun = false, sawRun = false
        for raw in output.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if line.range(of: #"^\S{1,2} Test run started\.$"#, options: .regularExpression) != nil {
                if sawRun && (pendingRun || !ended || issues < counted) { interruptedRun = true }
                pendingRun = true
                sawRun = true
                ended = false
                issues = 0
                counted = 0
            } else if runEnd.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                ended = true
                pendingRun = false
                counted = max(0, number(#" with (\d+) issues?\b"#, in: line) - number(#"including (\d+) known issues?\b"#, in: line))
            } else if TestFailures.swiftTesting(line, " started.", marks: ["◇"]) != nil || line.contains("Fatal error: ") {
                ended = false
            } else if TestFailures.swiftTesting(line, " recorded an issue") != nil {
                issues += 1
            }
        }
        if interruptedRun || pendingRun { return false }
        return !unfinished && !sawRun ? true : ended && issues >= counted
    }

    /// The first group of `pattern` in `line` as a number; 0 when it isn't there.
    private static func number(_ pattern: String, in line: String) -> Int {
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let found = Range(match.range(at: 1), in: line) else { return 0 }
        return Int(line[found]) ?? 0
    }

    // MARK: Red on the branch, then on the base

    /// What this repository's scripts/test.sh says of what the Swift tests left behind, after they ran: a rest of the
    /// checks that runs no Swift test (`rest`) can't see it again, so a run that says it excuses nothing.
    static let suiteMarkers = ["LEFTOVER PROCESSES:", "PREFERENCE FILES LEFT:", "PREFERENCES CHANGED:"]

    /// The tests a failed filtered rerun of `plan` still fails, when its failure is theirs alone: it ran to its end
    /// (`finished`), named each failing test among `plan`'s, each started once (a name two suites share could excuse
    /// one suite's test by the other's red on the base), showed each other of `plan`'s passing, wrote no error that
    /// names no test, and never reached regression_command (which runs only once the tests pass); and neither it nor
    /// the `first` run says the Swift tests left processes or preferences behind (`suiteMarkers`). Nil otherwise (a
    /// whole rerun, a crash, a filter that matched nothing, a regression_command that failed): the failure stands.
    public static func redOnBranch(_ plan: Plan, first: String, rerun output: String) -> [String]? {
        guard plan.filtered, !plan.continuing, !output.components(separatedBy: "\n").contains(LeadWorkflow.regressionMarker), finished(output),
              !suiteMarkers.contains(where: { first.contains($0) || output.contains($0) }) else { return nil }
        let failures = TestFailures(output: output)
        guard !failures.tests.isEmpty, failures.errors.isEmpty, failures.tests.allSatisfy(plan.tests.contains) else { return nil }
        var starts: [String: Int] = [:]
        for raw in output.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if let name = TestFailures.swiftTesting(line, " started.", marks: ["◇"]) { starts[name, default: 0] += 1 }
        }
        guard failures.tests.allSatisfy({ starts[$0, default: 0] <= 1 }) else { return nil }
        var others = plan
        others.tests = plan.tests.filter { !failures.tests.contains($0) }
        guard unshown(others, rerun: output).isEmpty else { return nil }
        return failures.tests
    }

    /// The rest of a merge's checks without `tests` (`redOnBranch`'s): the test command with them both filtered and
    /// skipped, so no Swift test runs and all else it checks does (this repository's web and security tests, its
    /// leftover processes and preferences), then regression_command. A failing test red on the base too mustn't let
    /// anything else that failed through. Nil when the test command takes no filter or a test has no pattern.
    public static func rest(without tests: [String], workflow: LeadWorkflow) -> String? {
        guard let test = workflow.testCommand, filterable(test), !tests.isEmpty else { return nil }
        let patterns = tests.compactMap(pattern)
        guard patterns.count == tests.count else { return nil }
        let quoted = RecentProjects.shellQuote(patterns.joined(separator: "|"))
        var again = workflow
        again.testCommand = test.trimmingCharacters(in: .whitespacesAndNewlines) + " --filter \(quoted) --skip \(quoted)"
        return again.mergeChecks
    }

    /// Whether the base's run of the failing tests (`baseline`) failed each of `tests` too.
    public static func excused(_ tests: [String], base run: Worktrees.Baseline.Run) -> Bool {
        guard !tests.isEmpty, case .ran(false, let output) = run else { return false }
        let failed = TestFailures(output: output).tests
        return tests.allSatisfy(failed.contains)
    }

    // MARK: The paired base run

    /// What a merge's paired base run (`Worktrees.Baseline`) found, for its rerun's record: heard on the run's thread,
    /// read once the run returns.
    public final class Pairing: @unchecked Sendable {
        private let lock = NSLock()
        private var found: (base: LeadRerunRecord.Base, note: String?)?

        public init() {}

        public var result: (base: LeadRerunRecord.Base, note: String?)? {
            lock.lock()
            defer { lock.unlock() }
            return found
        }

        public func note(_ base: LeadRerunRecord.Base, _ note: String? = nil) {
            lock.lock()
            found = (base, note)
            lock.unlock()
        }

        /// The base run's own word, when it ran to its end: the failing tests it failed too (`red`), and its output.
        private var ran: (red: [String], output: String)?

        public var onBase: (red: [String], output: String)? {
            lock.lock()
            defer { lock.unlock() }
            return ran
        }

        public func heard(red: [String], output: String) {
            lock.lock()
            ran = (red, output)
            lock.unlock()
        }
    }

    /// What a run that failed for good says of the base, from its paired base run (`pairing`): the tests its rerun
    /// still failed (`output`, the failure) that failed on the base too, and whether they're the whole failure (`all`):
    /// each test the rerun still failed is red on the base, the rest of the checks didn't fail, and the run left
    /// nothing else (an error naming no test, processes or preferences behind). Nil when none is red on the base.
    public static func redOnBase(_ output: String, pairing: Pairing) -> (red: [String], all: Bool, output: String)? {
        guard let base = pairing.onBase, !base.red.isEmpty else { return nil }
        let failures = TestFailures(output: output)
        let failing = failures.tests
        let red = base.red.filter(failing.contains)
        guard !red.isEmpty else { return nil }
        let all = failing.allSatisfy(red.contains) && failures.errors.isEmpty && !output.contains(Worktrees.restHeader)
            && !suiteMarkers.contains(where: output.contains)
            && !output.components(separatedBy: "\n").contains(LeadWorkflow.regressionMarker)
        return (red, all, base.output)
    }

    /// The base run of `plan`'s failing tests on `commit`, after a filtered rerun that failed (a whole one isn't run
    /// twice): its result goes to `pairing`. Never skipped for the Mac's load, as it was while it only fed the ledger:
    /// a skipped one would send back a branch for a test red on the base. With the rest of `workflow`'s checks run on the branch first without the tests the rerun still
    /// failed (`redOnBranch`, `rest`), and passing, a base run that fails each of them too (`excused`) lets the merge go
    /// ahead (`Worktrees.Check.passedRedOnBase`).
    public static func baseline(commit: String, plan: @escaping () -> Plan?, workflow: LeadWorkflow, pairing: Pairing) -> Worktrees.Baseline {
        Worktrees.Baseline(commit: commit, rest: { first, rerun in
            guard let plan = plan(), let red = redOnBranch(plan, first: first, rerun: rerun),
                  let command = rest(without: red, workflow: workflow) else { return nil }
            return (red, command)
        }, command: { _ in
            guard let plan = plan() else { return nil }
            guard let command = plan.baseCommand else {
                pairing.note(.skipped, plan.filtered ? "the stopped run named no tests to pair" : "a whole rerun isn't run on the base")
                return nil
            }
            // Not skipped over load_threshold: it decides the merge now, and it's a few tests.
            return command
        }, heard: { run in
            guard let plan = plan() else { return }
            switch run {
            case .ran(let ok, let output):
                let result = baseResult(plan, ok: ok, output: output)
                pairing.note(result.base, result.note)
                if !ok { pairing.heard(red: TestFailures(output: output).tests.filter(plan.tests.contains), output: output) }
            case .hung: pairing.note(.hung)
            case .unchecked(let why): pairing.note(.skipped, why)
            }
        })
    }

    /// The paired base run's result from its exit and `output`: red when it failed naming one of `plan`'s tests;
    /// green when it passed showing them pass; absent when it passed showing none (the base lacks them: a branch's new
    /// tests); skipped when it failed naming none of them (a base that doesn't build is no evidence either way).
    static func baseResult(_ plan: Plan, ok: Bool, output: String) -> (base: LeadRerunRecord.Base, note: String?) {
        if !ok {
            let failed = TestFailures(output: output).tests
            return failed.contains(where: plan.tests.contains) ? (.red, nil)
                : (.skipped, "the base's run failed naming none of the failing tests")
        }
        var named = plan
        named.note = nil
        named.requiredSuites = []
        return unshown(named, rerun: output).count == plan.tests.count ? (.absent, nil) : (.green, nil)
    }

    /// What a flake is recorded under when the failed run named no test.
    public static let unnamed = "(the test command, naming no test)"

    /// What a merge whose rerun passed records as flaky, from its failed run's `output`: the tests it named failing,
    /// and `unnamed` for a crash or a stop (`finished`), or a failure naming no test. Never the tests a crash left unfinished: they
    /// were only running beside it. On 2026-10-30 one crash logged every test then running, 200 and more, and with two
    /// misread earlier runs that was a third flake for six tests that had never failed (fix-the-flaky-test-7..12).
    public static func flakes(in output: String) -> [String] {
        let failures = TestFailures(output: output)
        return failures.tests + (failures.tests.isEmpty || !finished(output) ? [unnamed] : [])
    }

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

    /// Unstructured evidence of the first failure survives merge-worktree cleanup beside the flake log. Mask the
    /// whole output before cutting it, so a tail beginning inside a secret is safe too. At most 200 lines of 1,000
    /// characters: a stopped run may have printed every queued test and megabytes of compiler diagnostics.
    static func firstRunLog(task: String, commit: String, plan: Plan, output: String) -> String {
        let tail = Redaction.secrets(in: output).components(separatedBy: "\n").suffix(200).map {
            $0.count > 1000 ? String($0.prefix(999)) + "…" : $0
        }
        return "First failing run in \(task)'s merge (\(commit.prefix(12))).\n"
            + (plan.note ?? "Filtered rerun: the named failing tests only.") + "\n"
            + "First run's last \(tail.count) lines (secrets masked; 1,000 characters a line):\n"
            + tail.joined(separator: "\n") + "\n"
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
        var seen: Set<String> = []
        return openTests(in: output).map(\.name).filter { seen.insert($0).inserted }
    }

    /// What a stopped run's `output` can say of which tests were executing when it stopped (`running(in:)`).
    public struct Running: Equatable, Sendable {
        /// The tests that were executing, in the order they started.
        public var named: [String] = []
        /// How many tests printed their start and never finished when the output can't say which of them were
        /// executing; 0 when it can.
        public var unknown = 0

        public init(named: [String] = [], unknown: Int = 0) {
            self.named = named
            self.unknown = unknown
        }
    }

    /// Which tests a stopped run's `output` shows executing. Swift Testing prints a test's "started" before the test
    /// gets a slot of the run's width (SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH), and hands slots out in no order
    /// its output shows, so a "started" with no end doesn't mean running: on 2026-11-08 about 2,800 tests only queued
    /// for a slot were listed as running, and whichever printed last would have been blamed. One such test alone is
    /// certain, though: a test waits for a slot only while others that haven't finished hold every one, and those would
    /// have printed their start too. Two or more could be any mix of running and queued, whatever the width, so none
    /// is named. XCTest prints its "started" as the test begins, one at a time: each is executing.
    public static func running(in output: String) -> Running {
        let open = openTests(in: output)
        let plain = open.filter(\.swiftTesting)
        var seen: Set<String> = []
        let named = open.filter { (!$0.swiftTesting || plain.count == 1) && seen.insert($0.name).inserted }.map(\.name)
        return Running(named: named, unknown: plain.count > 1 ? plain.count : 0)
    }

    /// What's said of a stopped run with `count` tests the output can't tell apart (`Running.unknown`).
    public static func cantTell(_ count: Int) -> String {
        "\(count) tests printed their start and never finished, but Swift Testing prints that line before a test gets a slot to run in, so the output can't say which of them were running"
    }

    /// Each test that started more times than it ended, in the order they started (one that started twice and ended
    /// once is still open: two suites may have a test of one name), and whether it's Swift Testing's.
    private static func openTests(in output: String) -> [(name: String, swiftTesting: Bool)] {
        var started: [(name: String, swiftTesting: Bool)] = [], ended: [String] = []
        var lines = output.components(separatedBy: "\n")
        // A stall's report comes last and repeats the run's last lines: they aren't the run's a second time, and each
        // open test counted twice would make one hung test look like two that can't be told apart.
        if let report = lines.lastIndex(where: { $0.hasPrefix(StallWatch.Stall.reportStart) }) { lines.removeSubrange(report...) }
        for raw in lines {
            let line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            var name: String, event: String, swiftTesting = true
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
                swiftTesting = false
            } else {
                continue
            }
            if event.hasPrefix("started") {
                started.append((name, swiftTesting))
            } else {
                ended.append(name)
            }
        }
        let open = TestFailures.stillOpen(started.map(\.name), ended: ended)
        var left = Dictionary(open.map { ($0, 1) }, uniquingKeysWith: +)
        return started.filter { test in
            guard let count = left[test.name], count > 0 else { return false }
            left[test.name] = count - 1
            return true
        }
    }

    /// What a stopped run was doing, from its output (`phase(in:)`).
    public enum Phase: Equatable, Sendable {
        /// Running tests: those that were executing when it stopped (`running(in:)`), maybe none.
        case testing(unfinished: [String])
        /// Running tests, `open` of them started and unfinished, and the output can't say which were executing.
        case testingUnknown(open: Int)
        /// Building, no test started since its last build line: that line (a module or file it was compiling).
        case building(last: String)
        /// Neither shows in its output.
        case unknown
    }

    /// A build's progress line: SwiftPM's "[223/295] Compiling VibeSwitcherTests TerminalAnswerTests.swift" (and its
    /// "Emitting module", "Linking", "Write" ones), "Building for debugging...", "Build complete! (118.02s)".
    private static let buildLine = try! NSRegularExpression(pattern: #"^(\[\d+/\d+\] \S|Building for |Build complete!)"#)
    /// Any line of a test run: Swift Testing's ("◇ Test run started.", a test's start or end) or XCTest's.
    private static let testLine = try! NSRegularExpression(pattern: #"^(\S{1,2} Test .+ (started\.$|passed after |failed after |skipped)|Test (Case|Suite) ')"#)

    /// The phase a stopped run's `output` was in: testing when a test was executing or the output can't say which was,
    /// else whichever came
    /// last of a build line and a test line. On 2026-11-08 a merge hung 45 min in its test target's compile, with only
    /// compiler warnings in its tail, and the hung file said only "No test in its output started and never finished".
    public static func phase(in output: String) -> Phase {
        let shown = running(in: output)
        if !shown.named.isEmpty { return .testing(unfinished: shown.named) }
        if shown.unknown > 0 { return .testingUnknown(open: shown.unknown) }
        var lastBuild: String?, testedAfter = false
        for raw in output.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            if buildLine.firstMatch(in: line, range: range) != nil {
                lastBuild = line
                testedAfter = false
            } else if testLine.firstMatch(in: line, range: range) != nil {
                testedAfter = true
            }
        }
        if testedAfter { return .testing(unfinished: []) }
        return lastBuild.map { .building(last: $0) } ?? .unknown
    }

    /// The line a run stopped at test_timeout_min ends its output with (`Worktrees.runChecks`): how long it had been
    /// silent. A build that crawls keeps writing warnings; one that's stuck goes quiet.
    public static func quietNote(_ quiet: TimeInterval) -> String {
        quietPrefix + "\(Worktrees.duration(quiet)) before it was stopped."
    }
    static let quietPrefix = "Its last output line came "

    /// What the hung file and the lead's message say of `output`'s phase: "Started and never finished: x()." (or, when
    /// several Swift Testing tests are open, `cantTell`) /
    /// "No test in its output started and never finished." while testing (or unknown), "It was building and no test
    /// had started; its last build line: [223/295] Compiling …" while building. Secrets masked, the line cut at
    /// `evidenceWidth`.
    public static func phaseText(_ output: String) -> String {
        switch phase(in: output) {
        case .testing(let unfinished) where !unfinished.isEmpty:
            return "Started and never finished: " + Redaction.secrets(in: unfinished.joined(separator: ", ")) + "."
        case .testingUnknown(let open):
            return cantTell(open).prefix(1).uppercased() + cantTell(open).dropFirst() + "."
        case .building(let last):
            let line = Redaction.secrets(in: last)
            return "It was building and no test had started; its last build line: "
                + (line.count > evidenceWidth ? String(line.prefix(evidenceWidth - 1)) + "…" : line)
        case .testing, .unknown:
            return "No test in its output started and never finished."
        }
    }

    /// Where a hung merge's evidence is kept, beside its flake evidence: `.vibeswitcher/flakes/<yyyy-mm-dd>-<task>-<commit>-hung.log`.
    public static func hungPath(task: String, commit: String, at date: Date) -> String {
        String(evidencePath(task: task, commit: commit, at: date).dropLast(".log".count)) + "-hung.log"
    }

    /// The hung file's text: which of `task`'s merge commands (`command`, testing `commit`) ran past test_timeout_min
    /// (`after`) and was stopped, the phase it was in (`phase(in:)`: the tests its `output` left started and unfinished,
    /// or the build's last line when no test had started), how long it had been silent (`quietNote`), and the output's
    /// last `hungTail` lines. Masked whole before it's cut (`Redaction`): a secret the tail starts partway into (a
    /// key's lines under its header) is masked as it would be in full. Each line cut at `evidenceWidth`.
    /// With `stall`, it was stopped for making no progress (stall_min) rather than at test_timeout_min: the file says
    /// that, the last test it started, and its processes when it was stopped.
    public static func hungLog(task: String, commit: String, command: String, after: TimeInterval, output: String,
                               stall: StallWatch.Stall? = nil) -> String {
        let masked = Redaction.secrets(in: output).components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        let tail = masked.reversed().drop { $0.isEmpty }.prefix(hungTail).reversed()
            .map { $0.count > evidenceWidth ? String($0.prefix(evidenceWidth - 1)) + "…" : $0 }
        let what = command == "rerun" ? "the rerun of its failing tests" : "its \(command)"
        var text = stall.map { stall in
            "Hung in \(task)'s merge (tested \(commit.prefix(12))): \(what) made \(Redaction.secrets(in: stall.summary)) and was stopped \(Worktrees.duration(after)) in (stall_min), with everything started under it.\n"
                + (stall.processes.isEmpty ? "" : "\nIts processes when stopped (pid, parent, state, CPU seconds, name):\n" + stall.processes.map { "    " + $0 }.joined(separator: "\n") + "\n")
        } ?? "Hung in \(task)'s merge (tested \(commit.prefix(12))): \(what) ran past test_timeout_min (\(Worktrees.duration(after))) and was stopped, with everything started under it.\n"
        switch phase(in: masked.joined(separator: "\n")) {
        case .testing(let tests) where !tests.isEmpty:
            text += "\nIt was testing.\nStarted and never finished (secrets masked):\n" + tests.map { "    " + $0 }.joined(separator: "\n") + "\n"
        case .testingUnknown(let open):
            text += "\nIt was testing.\n" + cantTell(open) + ".\n"
        case .building(let last):
            let line = last.count > evidenceWidth ? String(last.prefix(evidenceWidth - 1)) + "…" : last
            text += "\nIt was building and no test had started. Its last build line (the module or file it was compiling):\n    \(line)\n"
        case .testing:
            text += "\nIt was testing.\nNo test in its output started and never finished.\n"
        case .unknown:
            text += "\nNo test in its output started and never finished. It shows no build line either.\n"
        }
        // How long it had been silent (stopped at test_timeout_min; a stall's summary above says its own).
        if let quiet = masked.last(where: { $0.hasPrefix(quietPrefix) }) { text += quiet + "\n" }
        if let why = masked.last(where: { $0.hasPrefix(causePrefix) }) { text += why + "\n" }
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
    /// again (`flakes`, oldest first: those since the last one noted or planned), in place of a new task to fix it,
    /// with each flake's evidence file and its failing lines.
    static func flakeNote(test: String, flakes: [LeadFlake], root: String) -> String {
        let merges = flakes.map(\.task)
        return "Flake ledger: \(test) flaked in the merge\(merges.count == 1 ? "" : "s") of \(merges.joined(separator: ", ")) (failed its first run and passed its rerun); no new task was planned to fix it, as this one names it."
            + FlakeLedger.evidenceFiles(flakes, root: root) + quoted(flakes, root: root)
    }

    /// The task planned for `test`, red on the base: it failed a merge's run, its rerun and the same run on the base,
    /// so the merge went ahead without it (`Worktrees.Check.passedRedOnBase`). `context` says where and quotes its lines.
    static func redOnBaseContract(test: String, workflow: LeadWorkflow, context: String) -> LeadContract {
        let base = workflow.base
        let tests = workflow.testCommand.map { "`\($0)` passes" } ?? "The project's tests pass"
        return LeadContract(
            goal: "\(test) passes on \(base) again: it fails there, so merges go ahead without it and nothing checks what it tests.",
            acceptance: ["Say why it fails on \(base) (a date or clock it depends on, the Mac's state, a change that broke it), with the evidence",
                         "If it's a real bug, fix the code; if it's the test, it waits on the real event it checks (a file, a reply, a semaphore, an injected clock), never a fixed sleep or a wall-clock window",
                         "It passes repeatedly under load (scripts/test-under-load.sh when the project has it)",
                         tests],
            boundaries: ["The test and what it checks; nothing else changes unless it's the bug"],
            context: context)
    }

    /// The task planned once `test` flaked (`LeadBoard.flakeLimit` times, once, within `LeadBoard.flakeWindow`):
    /// `flakes` (in the merges they held up, oldest first), whose evidence files under `root` it names and whose
    /// failing lines its context quotes. It finds the root cause and fixes it, never hides the flake (a sleep, a retry,
    /// a longer timeout, a skip): a flaky test that's rerun until it passes teaches agents to rerun rather than fix
    /// (2026-11-23). If the cause can't be found, the test goes, with the reason written down.
    static func fixContract(test: String, flakes: [LeadFlake], workflow: LeadWorkflow, root: String) -> LeadContract {
        let merges = flakes.map(\.task)
        let tests = workflow.testCommand.map { "`\($0)` passes" } ?? "The project's tests pass"
        let held = merges.count == 1 ? "a merge's test run" : "\(merges.count) merges' test runs"
        return LeadContract(
            goal: "\(test) stops flaking: it failed \(held) and passed the rerun, so the merge went ahead on the rerun alone. Find the root cause and fix it; if it can't be found within the budget, delete the test and write down why.",
            acceptance: ["Say the root cause (a fixed sleep, a wall-clock window, a race or shared state in the test, or a real bug in what it tests), with the evidence from the flaky runs (the evidence files below)",
                         "Fix the root cause: if it's a real bug, fix the code; if it's the test, it waits on the real event it checks (a file, a reply, a semaphore, an injected clock). Never add a sleep, a retry or a longer timeout as the fix, and never skip or disable the test",
                         "If the root cause can't be found within the budget, delete the test instead, and write why (what was tried, what the evidence showed) in the commit message and in the done report",
                         "Unless it was deleted, it passes repeatedly under load (scripts/test-under-load.sh when the project has it)",
                         tests],
            boundaries: ["The test and what it checks; nothing else changes unless it's the bug",
                         "No sleep, retry, longer timeout, skip or disabled test as the fix: the root cause fixed, or the test deleted with the reason"],
            context: "Flake ledger (\(FlakeLedgerStore.path); status lists it): \(test) failed its first run and passed its rerun in the merge\(merges.count == 1 ? "" : "s") of \(merges.joined(separator: ", "))."
                + FlakeLedger.evidenceFiles(flakes, root: root) + quoted(flakes, root: root))
    }
}
