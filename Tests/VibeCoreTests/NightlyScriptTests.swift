import Foundation
import Testing

/// scripts/nightly.sh's report (`--report`), the file the supervisor reads after the nightly full suite: PASS or FAIL,
/// each failed test once with its first issue's file and line, the tests that passed on their retry, and what else the
/// run said went wrong. From a log as `scripts/test.sh --retry-failed` writes it; nothing runs the suite here.
struct NightlyScriptTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let temp = Scratch()

    /// `scripts/nightly.sh ARGUMENTS`: its exit status and all of its output.
    func run(_ arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repo.appendingPathComponent("scripts/nightly.sh").path] + arguments
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
        return (process.terminationStatus, output)
    }

    func log(_ text: String) throws -> String {
        let url = temp.url("nightly.log")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// The section of `report` under `heading`, its lines up to the next heading.
    func section(_ report: String, _ heading: String) -> [String] {
        let lines = report.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "## \(heading)") else { return [] }
        return Array(lines[(start + 1)...].prefix { !$0.hasPrefix("## ") }).filter { !$0.isEmpty }
    }

    @Test func aFailedRunNamesEachFailedTestOnceWithWhereItFailed() async throws {
        let path = try log("""
            Building for debugging...
            ✘ Test aRestartedNodeReopens() recorded an issue at RestartResumeTests.swift:95:9: Expectation failed: x
            ✘ Test aRestartedNodeReopens() recorded an issue at RestartResumeTests.swift:97:9: Expectation failed: y
            ✘ Test aRestartedNodeReopens() failed after 8.930 seconds with 2 issues.
            ✘ Test hangs() failed after 600.000 seconds with 1 issue.
            RETRY FAILED: the failed tests' retry didn't pass (swift test exited 1). The first run's failures:
            web tests: 10 of 10 passed
            web tests: 3 of 4 passed; failed: x.test.mjs
            WEB TEST FAILED: x.test.mjs (exit 1)
            """)
        let (status, report) = try await run(["--report", path, "1", "1763600000", "1763602820", "abc123 (v2, /repo)"])
        #expect(status == 0, "\(report)")
        #expect(report.hasPrefix("# Nightly full suite: FAIL\n"), "\(report)")
        #expect(report.contains("- commit: abc123 (v2, /repo)") && report.contains("(47 min)") && report.contains("- exit: 1"), "\(report)")
        #expect(section(report, "Failed") == ["- aRestartedNodeReopens() (RestartResumeTests.swift:95:9)", "- hangs()"], "\(report)")
        #expect(section(report, "Flaky (passed on retry)") == ["none"], "\(report)")
        #expect(section(report, "Other") == ["- RETRY FAILED: the failed tests' retry didn't pass (swift test exited 1). The first run's failures:",
                                             "- web tests: 3 of 4 passed; failed: x.test.mjs", "- WEB TEST FAILED: x.test.mjs (exit 1)"], "\(report)")
    }

    /// A pass whose first run failed a test that then passed alone: no failure, the test listed as flaky.
    @Test func aPassListsTheRetriedTestsAsFlakyNotFailed() async throws {
        let path = try log("""
            ✘ Test slow() recorded an issue at SlowTests.swift:12:9: Expectation failed: z
            ✘ Test slow() failed after 1.000 seconds with 1 issue.
            retry-failed: swift test failed on 1 tests and nothing else; running only them once more, in a fresh run (a new swift test, a new scratch home):
            flaky (passed on retry): VibeCoreTests.SlowTests/slow()
            retry-failed: each test that failed passed on its retry: the Swift tests pass, those above listed as flaky.
            web tests: 10 of 10 passed
            """)
        let (_, report) = try await run(["--report", path, "0", "1763600000", "1763600100", "abc"])
        #expect(report.hasPrefix("# Nightly full suite: PASS\n"), "\(report)")
        #expect(section(report, "Failed") == ["none"], "\(report)")
        #expect(section(report, "Flaky (passed on retry)") == ["- VibeCoreTests.SlowTests/slow()"], "\(report)")
        #expect(section(report, "Other") == ["nothing"], "\(report)")
    }

    @Test func aBadArgumentRunsNothing() async throws {
        let (status, output) = try await run(["--bogus"])
        #expect(status == 2 && output.contains("usage: scripts/nightly.sh"), "\(output)")
        let (report, said) = try await run(["--report", "only-a-log"])
        #expect(report == 2 && said.contains("usage"), "\(said)")
    }
}
