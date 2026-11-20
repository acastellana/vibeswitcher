import Foundation
import Testing

/// `scripts/test.sh --retry-failed`, a merge's and an audit's full run: when swift test fails on a few tests and nothing
/// else, only those run once more in a fresh run (a new swift test, a new scratch home), and the Swift tests pass when
/// they pass there, each named on a line "flaky (passed on retry): Module.Suite/name()". On 2026-11-19 every full run on
/// the node tripped on one or two of several load-sensitive tests, each passing alone. Anything the script can't vouch
/// for fails as it would without the option. Driven in a copy of the scripts (test.sh, scripts/lib, vs-heavy) beside
/// one empty web, phone and security test each, with a fake `swift` first on PATH that replays canned runs: their
/// console output and Swift Testing's event stream (the JSON swift test writes at --event-stream-output-path). No real
/// build or suite runs, nor anything of the user's: vs-heavy's slots are the test's own.
struct TestScriptRetryTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let temp = Scratch()

    /// One swift test run the fake replays: its event stream (nil: it writes none), console output and exit status.
    struct FakeRun {
        var events: String?
        var console: String
        var status: Int32
    }

    /// A test's full Swift Testing ID, as the event stream gives it.
    static func id(_ suite: String, _ name: String, line: Int = 12) -> String { "VibeCoreTests.\(suite)/\(name)/F.swift:\(line):6" }

    /// The name the console prints for `id`: its function.
    static func name(_ id: String) -> String { id.split(separator: "/").dropFirst().first.map(String.init) ?? id }

    static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// A run of `passing` and `failing` tests (each failing one with one issue saying its message), as swift test
    /// leaves it: one "test" record a test, then its events, the run's end (unless `ended` is false), and the console's
    /// lines down to Swift Testing's closing one. `stray`: an issue recorded outside any test.
    static func run(passing: [String] = [], failing: [(id: String, says: String)] = [], ended: Bool = true, stray: String? = nil) -> FakeRun {
        var records: [String] = []
        let all = passing + failing.map(\.id)
        for id in all { records.append(json(["kind": "test", "version": 0, "payload": ["id": id, "kind": "function", "name": name(id)]])) }
        func event(_ payload: [String: Any]) { records.append(json(["kind": "event", "version": 0, "payload": payload])) }
        func issue(_ id: String?, _ says: String) {
            event(["kind": "issueRecorded", "testID": id ?? NSNull(), "issue": ["isKnown": false],
                   "messages": [["symbol": "fail", "text": says]]])
        }
        var console = ["Test Suite 'All tests' started at 2026-11-19 21:58:11.693",
                       "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds",
                       "◇ Test run started."]
        event(["kind": "runStarted"])
        for id in passing {
            event(["kind": "testStarted", "testID": id])
            event(["kind": "testEnded", "testID": id])
            console += ["◇ Test \(name(id)) started.", "✔ Test \(name(id)) passed after 0.001 seconds."]
        }
        for (id, says) in failing {
            event(["kind": "testStarted", "testID": id])
            issue(id, says)
            event(["kind": "testEnded", "testID": id])
            console += ["◇ Test \(name(id)) started.", "✘ Test \(name(id)) recorded an issue at F.swift:1:1: \(says)",
                        "✘ Test \(name(id)) failed after 0.001 seconds with 1 issue."]
        }
        if let stray {
            issue(nil, stray)
            console.append("✘ Test run recorded an issue: \(stray)")
        }
        let issues = failing.count + (stray == nil ? 0 : 1)
        if ended {
            event(["kind": "runEnded"])
            console.append(issues == 0 ? "✔ Test run with \(all.count) tests in 1 suite passed after 0.001 seconds."
                : "✘ Test run with \(all.count) tests in 1 suite failed after 0.001 seconds with \(issues) issue\(issues == 1 ? "" : "s").")
        }
        return FakeRun(events: records.joined(separator: "\n") + "\n", console: console.joined(separator: "\n") + "\n", status: issues == 0 ? 0 : 1)
    }

    /// The variables a team's session carries (scripts/lib/test-environment.sh's `team_session_variables`).
    static let teamSession = ["VIBESWITCHER_SESSION", "VIBESWITCHER_ROLE", "VIBESWITCHER_CODEX_WORKERS", "VIBESWITCHER_CLAUDE",
                              "VIBESWITCHER_LEAD_MODEL", "VIBESWITCHER_DOOR"]

    /// What one fake swift test was called with: its arguments, the scratch home and TMPDIR it ran in, and how many of
    /// the team session's variables it was given ("0": none, as a clean test environment has).
    struct Invocation {
        var arguments: [String]
        var home: String
        var tmpdir: String
        var session: String
    }

    /// `scripts/test.sh ARGS` in a copy of the scripts, its `swift test`s replaying `runs` in turn (one past them
    /// passes with no output and no stream), its `swift build` exiting `build`: its status, all of its output, and the
    /// swift tests it ran.
    func script(_ arguments: [String], runs: [FakeRun], build: Int32 = 0) async throws -> (status: Int32, output: String, ran: [Invocation]) {
        let root = temp.url("retry-run")
        let files = FileManager.default
        for folder in ["scripts", "Resources/bin", "bin", "fake", "locks", "Tests/Web", "WebApp/tests", "Tests/SecurityAudit", ".build/debug"] {
            try files.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try files.copyItem(at: Self.repo.appendingPathComponent("scripts/test.sh"), to: root.appendingPathComponent("scripts/test.sh"))
        try files.copyItem(at: Self.repo.appendingPathComponent("scripts/lib"), to: root.appendingPathComponent("scripts/lib"))
        try installScript(String(contentsOf: Self.repo.appendingPathComponent("Resources/bin/vs-heavy"), encoding: .utf8),
                          at: root.appendingPathComponent("Resources/bin/vs-heavy"))
        // The host the security tests need, which no test here runs; one empty test in each web folder, which passes.
        try installScript("#!/bin/sh\nexit 1\n", at: root.appendingPathComponent(".build/debug/vibeswitcher-host"))
        for folder in ["Tests/Web", "WebApp/tests", "Tests/SecurityAudit"] {
            try "".write(to: root.appendingPathComponent(folder).appendingPathComponent("ok.test.mjs"), atomically: true, encoding: .utf8)
        }
        let fake = root.appendingPathComponent("fake")
        for (index, run) in runs.enumerated() {
            if let events = run.events { try events.write(to: fake.appendingPathComponent("run-\(index + 1).events"), atomically: true, encoding: .utf8) }
            try run.console.write(to: fake.appendingPathComponent("run-\(index + 1).console"), atomically: true, encoding: .utf8)
            try "\(run.status)".write(to: fake.appendingPathComponent("run-\(index + 1).status"), atomically: true, encoding: .utf8)
        }
        // The fake swift: `build` exits as told; each `test` is the next run, its arguments kept one a line (NUL-ended),
        // its stream copied where it was told to write one.
        try installScript("""
            #!/bin/bash
            dir=$FAKE_SWIFT_DIR
            verb=$1
            shift
            if [[ $verb == build ]]; then echo "fake swift build"; exit \(build); fi
            [[ $verb == test ]] || { echo "fake swift: no $verb"; exit 64; }
            n=$(( $(cat "$dir/runs" 2> /dev/null || echo 0) + 1 ))
            echo $n > "$dir/runs"
            printf '%s\\0' "$@" > "$dir/run-$n.args"
            carried=0
            for name in \(Self.teamSession.joined(separator: " ")); do [[ -n ${!name+set} ]] && carried=$((carried + 1)); done
            printf '%s\\n%s\\n%s\\n' "$HOME" "$TMPDIR" "$carried" > "$dir/run-$n.env"
            out=""
            while (( $# > 0 )); do [[ $1 == --event-stream-output-path ]] && out=$2; shift; done
            [[ -n $out && -f $dir/run-$n.events ]] && cp "$dir/run-$n.events" "$out"
            cat "$dir/run-$n.console" 2> /dev/null
            exit $(cat "$dir/run-$n.status" 2> /dev/null || echo 0)
            """, at: root.appendingPathComponent("bin/swift"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/test.sh").path] + arguments
        var environment = ProcessInfo.processInfo.environment
        // vs-heavy's slots in the test's own folder, never the run's or the user's.
        for key in environment.keys where key.hasPrefix("VIBESWITCHER_HEAVY_") || key == "VS_HEAVY_CORES" || key == "VIBESWITCHER_TEST_LOCK" {
            environment[key] = nil
        }
        environment["VIBESWITCHER_TEST_LOCK_DIR"] = root.appendingPathComponent("locks").path
        environment["PATH"] = root.appendingPathComponent("bin").path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["FAKE_SWIFT_DIR"] = fake.path
        // Whatever the caller's session carries: a team session's variables, which no test process may carry
        // (scripts/lib/test-environment.sh), set here; CODEX_SANDBOX, which skips the security tests (a Codex
        // worker's run), and the width's, taken out.
        for name in Self.teamSession { environment[name] = "a-team-session" }
        for name in ["CODEX_SANDBOX", "VIBESWITCHER_TESTS_PER_CORE", "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH", "VIBESWITCHER_TEST_WIDTH_DEFAULT"] {
            environment[name] = nil
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = await offPool { () -> String in
            let read = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            waitForEnd(process)
            return read
        }
        let count = Int((try? String(contentsOf: fake.appendingPathComponent("runs"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
        let ran = try (0..<count).map { index -> Invocation in
            let args = try Data(contentsOf: fake.appendingPathComponent("run-\(index + 1).args"))
                .split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
            let env = try String(contentsOf: fake.appendingPathComponent("run-\(index + 1).env"), encoding: .utf8).components(separatedBy: "\n")
            return Invocation(arguments: args, home: env[0], tmpdir: env.count > 1 ? env[1] : "", session: env.count > 2 ? env[2] : "")
        }
        return (process.terminationStatus, output, ran)
    }

    static func lines(_ output: String, from prefix: String) -> [String] {
        output.components(separatedBy: "\n").filter { $0.hasPrefix(prefix) }
    }

    /// The script's output for a failure message, each line behind "| ": its fake runs' ✘ and closing lines, shown
    /// bare, would read as this run's own to whatever reads the suite's output (a merge's judge, retry-failed.mjs).
    static func shown(_ output: String) -> String {
        output.components(separatedBy: "\n").map { "| " + $0 }.joined(separator: "\n")
    }

    /// The value of the retry's --filter=… (nil when it has none, or more than one).
    static func filter(_ invocation: Invocation) -> String? {
        let filters = invocation.arguments.filter { $0 == "--filter" || $0.hasPrefix("--filter=") }
        guard filters.count == 1, let only = filters.first, only.hasPrefix("--filter=") else { return nil }
        return String(only.dropFirst("--filter=".count))
    }

    static let flakyID = id("SwitchTests", "aWorkerStartedByAPreSwitchLeadKeepsTheOldBuild()")
    static let steadyID = id("SwitchTests", "theSwitchIsQuick()", line: 40)

    // MARK: Red, then green

    /// A test that fails once and passes on its retry: the run passes, naming it flaky on one line, and the retry ran
    /// it alone (exactly it, by its whole ID), with --skip-build, in a scratch home of its own.
    @Test func aTestThatFailsOnceThenPassesIsNamedFlakyAndTheRunPasses() async throws {
        let first = Self.run(passing: [Self.steadyID], failing: [(Self.flakyID, "Expectation failed: the old build")])
        let again = Self.run(passing: [Self.flakyID])
        let (status, output, ran) = try await script(["--retry-failed"], runs: [first, again])
        #expect(status == 0, "\(Self.shown(output))")
        #expect(Self.lines(output, from: "flaky") == ["flaky (passed on retry): VibeCoreTests.SwitchTests/aWorkerStartedByAPreSwitchLeadKeepsTheOldBuild()"], "\(Self.shown(output))")
        try #require(ran.count == 2, "\(Self.shown(output))")
        // The first run is the default run: nothing filtered or skipped out of it.
        #expect(!ran[0].arguments.contains { $0.hasPrefix("--filter") || $0.hasPrefix("--skip") }, "\(ran[0].arguments)")
        #expect(Self.filter(ran[1]) == #"^(VibeCoreTests\.SwitchTests\/aWorkerStartedByAPreSwitchLeadKeepsTheOldBuild\(\)\/F\.swift\:12\:6)$"#, "\(ran[1].arguments)")
        #expect(ran[1].arguments.contains("--skip-build"), "\(ran[1].arguments)")
        // A fresh scratch home and TMPDIR, inside the first's scratch folder (so its leftover check covers the retry).
        #expect(ran[0].home != ran[1].home && ran[0].tmpdir != ran[1].tmpdir, "\(ran[0]) \(ran[1])")
        let scratch = URL(fileURLWithPath: ran[0].home).deletingLastPathComponent().path
        #expect(ran[1].home == scratch + "/r/home" && ran[1].tmpdir == scratch + "/r/tmp/", "\(ran[1])")
        // Both in a clean test environment: none of the team session's variables.
        #expect(ran.map(\.session) == ["0", "0"], "\(ran)")
        // Nothing of the retry is said to have failed, and the web, phone and security checks still ran, once each.
        #expect(!output.contains("RETRY FAILED") && !output.contains("not retried"), "\(Self.shown(output))")
        #expect(Self.lines(output, from: "web tests: 1 of 1 passed").count == 3, "\(Self.shown(output))")
    }

    /// A test that fails twice fails the run, with both failures shown.
    @Test func aTestThatFailsTwiceFailsTheRunShowingBothFailures() async throws {
        let first = Self.run(passing: [Self.steadyID], failing: [(Self.flakyID, "Expectation failed: first time")])
        let again = Self.run(failing: [(Self.flakyID, "Expectation failed: second time")])
        let (status, output, ran) = try await script(["--retry-failed"], runs: [first, again])
        #expect(status != 0, "\(Self.shown(output))")
        #expect(ran.count == 2, "\(Self.shown(output))")
        #expect(output.contains("RETRY FAILED"), "\(Self.shown(output))")
        #expect(output.contains("\(Self.flakyID): Expectation failed: first time"), "\(Self.shown(output))")
        #expect(output.contains("\(Self.flakyID): Expectation failed: second time"), "\(Self.shown(output))")
        #expect(!output.contains("flaky (passed on retry)"), "\(Self.shown(output))")
    }

    /// A run with no failure runs once.
    @Test func aPassingRunHasNoSecondRun() async throws {
        let (status, output, ran) = try await script(["--retry-failed"], runs: [Self.run(passing: [Self.steadyID, Self.flakyID])])
        #expect(status == 0, "\(Self.shown(output))")
        #expect(ran.count == 1, "\(Self.shown(output))")
        #expect(!output.contains("flaky") && !output.contains("retry-failed:"), "\(Self.shown(output))")
        // Swift Testing wrote its event stream for the judge.
        #expect(ran.first?.arguments.contains("--event-stream-output-path") == true, "\(ran.first?.arguments ?? [])")
    }

    /// Without the option nothing changes: a failure fails the run, with no retry and no event stream asked for.
    @Test func withoutTheOptionAFailureIsNotRetried() async throws {
        let first = Self.run(failing: [(Self.flakyID, "Expectation failed")])
        let (status, output, ran) = try await script([], runs: [first, Self.run(passing: [Self.flakyID])])
        #expect(status == 1, "\(Self.shown(output))")
        #expect(ran.count == 1, "\(Self.shown(output))")
        #expect(ran.first?.arguments.contains("--event-stream-output-path") == false, "\(ran.first?.arguments ?? [])")
        #expect(!output.contains("retry-failed") && !output.contains("flaky"), "\(Self.shown(output))")
    }

    // MARK: Never a pass by accident

    /// Each run the script can't vouch for fails as without the option, its retry never run: what it says, then why.
    func expectNotRetried(_ first: FakeRun, _ arguments: [String] = ["--retry-failed"], build: Int32 = 0, saying why: String,
                          sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let (status, output, ran) = try await script(arguments, runs: [first, Self.run(passing: [Self.flakyID])], build: build)
        #expect(status != 0, "\(Self.shown(output))", sourceLocation: sourceLocation)
        #expect(ran.count <= 1, "a second swift test ran: \(Self.shown(output))", sourceLocation: sourceLocation)
        #expect(output.contains("retry-failed: not retried: " + why), "\(Self.shown(output))", sourceLocation: sourceLocation)
        #expect(!output.contains("flaky (passed on retry)"), "\(Self.shown(output))", sourceLocation: sourceLocation)
    }

    /// A crash or a kill: the stream has no end (the console no closing line), and the rest of the suite never ran.
    @Test func aRunThatCrashedIsNotRetried() async throws {
        var crashed = Self.run(passing: [Self.steadyID], failing: [(Self.flakyID, "Expectation failed")], ended: false)
        crashed.console += "error: Process '/x/VibeSwitcherPackageTests.xctest' exited with unexpected signal code 4\n"
        try await expectNotRetried(crashed, saying: "Swift Testing's run never ended")
    }

    /// Ended by a signal after its run ended: SwiftPM says so for signals 1, 3, 4 (a fatalError's), 6, 7, 8, 10, 11, 13
    /// and 14, and exits 1 as for a failing test. (SIGKILL, SIGTERM and SIGINT it doesn't say: scripts/test.sh's
    /// `swift_tests_retrying_failed` names that limit.)
    @Test func aTestProcessKilledAfterItsRunIsNotRetried() async throws {
        for signal in [1, 3, 4, 6, 7, 8, 10, 11, 13, 14] {
            var killed = Self.run(failing: [(Self.flakyID, "Expectation failed")])
            killed.console += "error: Process '/x/VibeSwitcherPackageTests.xctest' exited with unexpected signal code \(signal)\n"
            try await expectNotRetried(killed, saying: "the test process didn't end by itself")
        }
    }

    /// Stopped or timed out (vs-heavy's limit ends it with a signal): an exit that isn't failing tests'.
    @Test func aRunStoppedOrTimedOutIsNotRetried() async throws {
        var stopped = Self.run(failing: [(Self.flakyID, "Expectation failed")])
        stopped.status = 143
        try await expectNotRetried(stopped, saying: "swift test exited 143, not 1")
    }

    /// No summary: the console never shows Swift Testing's closing line, or the stream is missing or cut off.
    @Test func aRunWithNoSummaryOrNoWholeStreamIsNotRetried() async throws {
        var silent = Self.run(failing: [(Self.flakyID, "Expectation failed")])
        silent.console = silent.console.components(separatedBy: "\n").filter { !$0.contains("Test run with") }.joined(separator: "\n")
        try await expectNotRetried(silent, saying: "the output shows 0 Swift Testing closing lines")
        var unwritten = Self.run(failing: [(Self.flakyID, "Expectation failed")])
        unwritten.events = nil
        try await expectNotRetried(unwritten, saying: "Swift Testing wrote no event stream")
        var cut = Self.run(failing: [(Self.flakyID, "Expectation failed")])
        cut.events = String(cut.events!.dropLast(12))
        try await expectNotRetried(cut, saying: "line ")
    }

    /// A build that fails runs no test, and fails.
    @Test func aBuildFailureFails() async throws {
        let (status, output, ran) = try await script(["--retry-failed"], runs: [Self.run(passing: [Self.flakyID])], build: 1)
        #expect(status != 0, "\(Self.shown(output))")
        #expect(ran.isEmpty, "\(Self.shown(output))")
        #expect(output.contains("retry-failed: not retried: the build failed"), "\(Self.shown(output))")
    }

    /// Failures it can't name exactly: an issue outside any test (a SIGPIPE, a disk read), an issue in a suite, a
    /// console that counts more issues than the stream holds, an XCTest failure.
    @Test func failuresThatCantBeNamedExactlyAreNotRetried() async throws {
        try await expectNotRetried(Self.run(failing: [(Self.flakyID, "Expectation failed")], stray: "SIGPIPE: a write to a pipe"),
                                   saying: "an issue was recorded outside any test: SIGPIPE: a write to a pipe")
        var suite = Self.run(failing: [(Self.flakyID, "Expectation failed")])
        suite.events = suite.events!.replacingOccurrences(of: #""kind":"function","name":"aWorkerStartedByAPreSwitchLeadKeepsTheOldBuild()""#,
                                                          with: #""kind":"suite","name":"aWorkerStartedByAPreSwitchLeadKeepsTheOldBuild()""#)
        try await expectNotRetried(suite, saying: "an issue was recorded in \(Self.flakyID), not a test function")
        var miscounted = Self.run(failing: [(Self.flakyID, "Expectation failed")])
        miscounted.console = miscounted.console.replacingOccurrences(of: "with 1 issue.\n", with: "with 2 issues.\n")
        try await expectNotRetried(miscounted, saying: "the closing line counts 2 failing issues and the event stream 1")
        var xctest = Self.run(failing: [(Self.flakyID, "Expectation failed")])
        xctest.console = "Test Case '-[VibeCoreTests.OldTests testIt]' failed (0.001 seconds).\n" + xctest.console
        try await expectNotRetried(xctest, saying: "XCTest failed")
    }

    /// A test started and never ended (the run's end written all the same) is a run cut short.
    @Test func aTestLeftUnendedIsNotRetried() async throws {
        var open = Self.run(passing: [Self.steadyID], failing: [(Self.flakyID, "Expectation failed")])
        open.events = open.events!.components(separatedBy: "\n")
            .filter { !($0.contains(#""kind":"testEnded""#) && $0.contains("theSwitchIsQuick")) }.joined(separator: "\n")
        try await expectNotRetried(open, saying: "1 tests started and never ended")
    }

    /// More failed tests than the cap is a broken change, not a flake.
    @Test func moreFailuresThanTheCapAreNotRetried() async throws {
        let many = (1...11).map { (Self.id("BrokenTests", "test\($0)()", line: $0), "Expectation failed") }
        try await expectNotRetried(Self.run(failing: many), saying: "11 tests failed, more than 10")
        // At the cap, they are.
        let ten = Array(many.prefix(10))
        let (status, output, ran) = try await script(["--retry-failed"], runs: [Self.run(failing: ten), Self.run(passing: ten.map(\.0))])
        #expect(status == 0 && ran.count == 2, "\(Self.shown(output))")
        #expect(Self.lines(output, from: "flaky (passed on retry): ").count == 10, "\(Self.shown(output))")
    }

    /// A retry that exits 0 having run something else, or not all of them, isn't a pass: a filter that matched
    /// nothing passes with nothing run.
    @Test func aRetryThatDidntRunExactlyTheFailedTestsFails() async throws {
        let first = Self.run(failing: [(Self.flakyID, "Expectation failed")])
        let nothing = try await script(["--retry-failed"], runs: [first, Self.run()])
        #expect(nothing.status != 0 && nothing.output.contains("RETRY FAILED") && nothing.output.contains("didn't run \(Self.flakyID)"), "\(Self.shown(nothing.output))")
        let wider = try await script(["--retry-failed"], runs: [first, Self.run(passing: [Self.flakyID, Self.steadyID])])
        #expect(wider.status != 0 && wider.output.contains("ran more than the failed tests: \(Self.steadyID)"), "\(Self.shown(wider.output))")
        var unended = Self.run(passing: [Self.flakyID], ended: false)
        unended.status = 0
        let cut = try await script(["--retry-failed"], runs: [first, unended])
        #expect(cut.status != 0 && cut.output.contains("RETRY FAILED"), "\(Self.shown(cut.output))")
    }

    // MARK: The retry's filter

    /// Names are matched literally and whole: a test whose name holds |, .*, quotes, spaces or a leading - gets each
    /// character escaped, in one --filter=… argument anchored at both ends; a parameterized test runs whole (its
    /// function's ID). The caller's own --filter and --skip go to the first run only.
    @Test func theRetrysFilterMatchesEachNameLiterallyAndWhole() async throws {
        let odd = Self.id("OddTests", #"`-x | .* "q" ünï`()"#), parameterized = Self.id("OddTests", "param(n:)", line: 30)
        let first = Self.run(passing: [Self.steadyID], failing: [(odd, "Expectation failed"), (parameterized, "Expectation failed")])
        let (status, output, ran) = try await script(["--retry-failed", "--filter", "OddTests|SwitchTests", "--skip", "Slow"],
                                                     runs: [first, Self.run(passing: [odd, parameterized])])
        #expect(status == 0, "\(Self.shown(output))")
        try #require(ran.count == 2, "\(Self.shown(output))")
        #expect(ran[0].arguments.contains("OddTests|SwitchTests") && ran[0].arguments.contains("Slow"), "\(ran[0].arguments)")
        #expect(!ran[1].arguments.contains("OddTests|SwitchTests") && !ran[1].arguments.contains("--skip") && !ran[1].arguments.contains("Slow"), "\(ran[1].arguments)")
        #expect(Self.filter(ran[1]) == #"^(VibeCoreTests\.OddTests\/\`\-x\ \|\ \.\*\ \"q\"\ \x{FC}n\x{EF}\`\(\)\/F\.swift\:12\:6|VibeCoreTests\.OddTests\/param\(n\:\)\/F\.swift\:30\:6)$"#,
                "\(ran[1].arguments)")
        #expect(Self.lines(output, from: "flaky (passed on retry): ") == ["flaky (passed on retry): VibeCoreTests.OddTests/`-x | .* \"q\" ünï`()",
                                                                          "flaky (passed on retry): VibeCoreTests.OddTests/param(n:)"], "\(Self.shown(output))")
    }

    /// The option goes with the default run alone.
    @Test func theOptionIsRefusedWithAnotherMode() async throws {
        let (status, output, ran) = try await script(["--retry-failed", "--perf"], runs: [])
        #expect(status == 2 && ran.isEmpty, "\(Self.shown(output))")
        #expect(output.contains("--retry-failed is for the default run"), "\(Self.shown(output))")
    }
}
