import Foundation
import Testing
@testable import VibeCore

/// Real `swift build && swift test` output (paths shortened): this repository's Swift 6 warnings, then a Swift
/// Testing run where three tests fail, the way a failed merge saw it.
let swiftTestingFailure = #"""
[1/1] Compiling plugin SwiftTermBuildInfoPlugin
Building for debugging...
/repo/Tests/VibeCoreTests/DevPreviewTests.swift:306:45: warning: reference to captured var 'resumed' in concurrently-executing code; this is an error in the Swift 6 language mode
304 |             var resumed = false
305 |             listener.stateUpdateHandler = { [listener] state in
306 |                 guard case .ready = state, !resumed else { return }
    |                                             `- warning: reference to captured var 'resumed' in concurrently-executing code; this is an error in the Swift 6 language mode
307 |                 resumed = true
308 |                 continuation.resume(returning: listener.port!.rawValue)

/repo/Tests/VibeCoreTests/DevPreviewTests.swift:307:17: warning: mutation of captured var 'resumed' in concurrently-executing code; this is an error in the Swift 6 language mode
305 |             listener.stateUpdateHandler = { [listener] state in
306 |                 guard case .ready = state, !resumed else { return }
307 |                 resumed = true
    |                 `- warning: mutation of captured var 'resumed' in concurrently-executing code; this is an error in the Swift 6 language mode
Build complete! (0.93s)
◇ Test run started.
↳ Testing Library Version: 124.4
↳ Target Platform: arm64e-apple-macos14.0
◇ Suite NetTests started.
✘ Test skipped() skipped.
◇ Test passes() started.
◇ Test param(n:) started.
◇ Test answerIsRight() started.
◇ Test recordsIssue() started.
✔ Test passes() passed after 0.001 seconds.
◇ Passing 1 argument n → 2 to param(n:)
✘ Test recordsIssue() recorded an issue at SwiftTestingTests.swift:11:21: Issue recorded
↳ listener never became ready
✘ Test param(n:) recorded an issue with 1 argument n → 2 at SwiftTestingTests.swift:16:51: Expectation failed: (n → 2) == 1
◇ Passing 1 argument n → 1 to param(n:)
✘ Test answerIsRight() recorded an issue at SwiftTestingTests.swift:8:9: Expectation failed: (answer() → 41) == (expected → 42)
↳ the answer drifted
✘ Test recordsIssue() recorded an issue at SwiftTestingTests.swift:13:17: Expectation failed: value → nil
✘ Test param(n:) failed after 0.001 seconds with 1 issue.
✘ Test answerIsRight() failed after 0.001 seconds with 1 issue.
✘ Test recordsIssue() failed after 0.001 seconds with 2 issues.
✘ Suite NetTests failed after 0.001 seconds with 4 issues.
✘ Test run with 5 tests failed after 0.001 seconds with 4 issues.
"""#

struct TestFailuresTests {
    @Test func swiftTestingFailuresLeadWithTheirNamesAndIssues() throws {
        let failures = TestFailures(output: swiftTestingFailure)
        #expect(failures.tests == ["recordsIssue()", "param(n:)", "answerIsRight()"])
        #expect(failures.lines == [
            "✘ Test recordsIssue() recorded an issue at SwiftTestingTests.swift:11:21: Issue recorded",
            "↳ listener never became ready",
            "✘ Test param(n:) recorded an issue with 1 argument n → 2 at SwiftTestingTests.swift:16:51: Expectation failed: (n → 2) == 1",
            "✘ Test answerIsRight() recorded an issue at SwiftTestingTests.swift:8:9: Expectation failed: (answer() → 41) == (expected → 42)",
            "↳ the answer drifted",
            "✘ Test recordsIssue() recorded an issue at SwiftTestingTests.swift:13:17: Expectation failed: value → nil",
        ])
        #expect(failures.unfinished.isEmpty)
        let summary = try #require(failures.summary())
        #expect(summary.hasPrefix("Failing tests (3): recordsIssue(), param(n:), answerIsRight()\n✘ Test recordsIssue() recorded an issue"))
        #expect(summary.hasSuffix("✘ Test run with 5 tests failed after 0.001 seconds with 4 issues."))
        // Neither the build's warnings nor a skipped test is a failure.
        #expect(!summary.contains("resumed") && !summary.contains("skipped()") && !summary.contains("Build complete"))
    }

    /// Real output from this suite (a flake under load): the expectation's source spans lines, its comment after.
    @Test func anExpectationOverSeveralLinesIsKeptWhole() {
        let failures = TestFailures(output: """
            ✔ Test historyLargerThanAFrameIsTrimmedNotDropped() passed after 18.796 seconds.
            ✘ Test slowClientGetsResyncAndProgramKeepsRunning() recorded an issue at HostServerTests.swift:139:9: Expectation failed: eventually(timeout: 30) {
                        let seq = watcher.send(.screen(id: session.id))
                        Thread.sleep(forTimeInterval: 0.2)
                        if case .screenText(_, let text) = watcher.reply(to: seq) { return text.contains("all-done") }
                        return false
                    }
            ↳ // The program finishes (its output wasn't blocked), which the host reports on screen.
            ✘ Test slowClientGetsResyncAndProgramKeepsRunning() failed after 35.827 seconds with 1 issue.
            ✘ Suite HostServerTests failed after 35.834 seconds with 1 issue.
            ✘ Test run with 524 tests failed after 35.835 seconds with 1 issue.
            """)
        #expect(failures.tests == ["slowClientGetsResyncAndProgramKeepsRunning()"])
        #expect(failures.lines.count == 7)
        #expect(failures.lines[4] == "            return false")
        #expect(failures.lines.last == "↳ // The program finishes (its output wasn't blocked), which the host reports on screen.")
    }

    @Test func aFailureWithNoIssueLineStillShows() {
        let failures = TestFailures(output: """
            ◇ Test slowThing() started.
            ✘ Test slowThing() failed after 60.001 seconds with 0 issues.
            """)
        #expect(failures.tests == ["slowThing()"])
        #expect(failures.lines == ["✘ Test slowThing() failed after 60.001 seconds with 0 issues."])
    }

    /// XCTest's lines as it prints them (this Mac has no XCTest to capture from).
    @Test func xcTestFailuresAreNamedByTheirErrorLines() {
        let failures = TestFailures(output: """
            Test Case '-[VibeCoreTests.LegacyTests testPasses]' passed (0.001 seconds).
            Test Case '-[VibeCoreTests.LegacyTests testFails]' started.
            /repo/Tests/LegacyTests.swift:6: error: -[VibeCoreTests.LegacyTests testFails] : XCTAssertEqual failed: ("41") is not equal to ("42") - legacy drift
            Test Case '-[VibeCoreTests.LegacyTests testFails]' failed (0.002 seconds).
            Test Case '-[VibeCoreTests.LegacyTests testThrows]' failed (0.001 seconds).
            /repo/Tests/LegacyTests.swift:9: error: LegacyTests.testLinux : XCTAssertTrue failed
            """)
        #expect(failures.tests == ["LegacyTests.testFails", "LegacyTests.testThrows", "LegacyTests.testLinux"])
        #expect(failures.lines.count == 2 && failures.lines[0].contains("legacy drift"))
    }

    /// Real output of a build that failed: the compiler's errors, once each.
    @Test func aBuildThatFailsShowsItsErrors() throws {
        let failures = TestFailures(output: #"""
            [3/6] Write swift-version--1AB21518FC5DEDBE.txt
            error: emit-module command failed with exit code 1 (use -v to see invocation)
            [5/9] Emitting module LibTests
            /repo/Tests/LibTests/XCTests.swift:1:8: error: no such module 'XCTest'
            1 | import XCTest
              |        `- error: no such module 'XCTest'
            2 | @testable import Lib
            3 |
            [6/9] Compiling LibTests XCTests.swift
            /repo/Tests/LibTests/XCTests.swift:1:8: error: no such module 'XCTest'
            1 | import XCTest
              |        `- error: no such module 'XCTest'
            error: fatalError
            """#)
        #expect(failures.tests.isEmpty)
        #expect(failures.errors == ["error: emit-module command failed with exit code 1 (use -v to see invocation)",
                                    "/repo/Tests/LibTests/XCTests.swift:1:8: error: no such module 'XCTest'", "error: fatalError"])
        #expect(try #require(failures.summary()).hasPrefix("No test failed by name; the errors:\nerror: emit-module"))
    }

    @Test func aCrashNamesTheTestsStillRunning() throws {
        let failures = TestFailures(output: """
            ◇ Test a() started.
            ◇ Test b() started.
            ✔ Test a() passed after 0.001 seconds.
            Fatal error: Unexpectedly found nil while unwrapping an Optional value
            error: Exited with unexpected signal code 5
            """)
        #expect(failures.unfinished == ["b()"])
        let summary = try #require(failures.summary())
        #expect(summary.hasPrefix("Started and never finished: b()\nThe errors:\nFatal error: "))
        #expect(summary.contains("signal code 5"))
    }

    @Test func outputThatNamesNothingHasNoSummary() {
        #expect(TestFailures(output: "Build complete!\nsomething went wrong").summary() == nil)
    }

    @Test func aLongSummaryIsCut() throws {
        let output = (1...200).map { "✘ Test t\($0)() recorded an issue at T.swift:1:1: Expectation failed" }.joined(separator: "\n")
        let summary = try #require(TestFailures(output: output).summary(limit: 1000))
        #expect(summary.count < 1100)
        #expect(summary.hasPrefix("Failing tests (200): t1(), t2()"))
        #expect(summary.hasSuffix("more lines."))
    }

    @Test func interleavedOutputKeepsTheOrderItWasWrittenIn() {
        let run = Shell.run(executable: "/bin/sh", args: ["-c", "echo one; echo two >&2; echo three"], in: "/", interleaved: true)
        #expect(run.output == "one\ntwo\nthree" && run.error.isEmpty)
    }
}
