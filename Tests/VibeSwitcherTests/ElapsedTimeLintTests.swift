import Foundation
import Testing

/// A correctness test doesn't judge how long something took against a bare number: on a loaded Mac any such bound is
/// a flake (the ledger's 202 flakes over 166 tests in 22 days, most on these), and the rule since 2026-10-23 is that a
/// test waits on events. It judges the order of what happened, or a baseline from the same test, or it's a bench
/// (`.perf`). A bound against `hangGuard` or a named limit isn't caught, so a test's own hang guard doesn't need a place here.
struct ElapsedTimeLintTests {
    /// A use allowed in `file`, on a line containing `text`, for `reason`.
    struct Allowed: Hashable {
        let file: String, text: String, reason: String
    }

    /// Each a hang guard (the step ends long before it, or the test would hang), or older than this lint and still to move.
    static let allowed: [Allowed] = [
        Allowed(file: "VibeCoreTests/TestLockTests.swift", text: "timeIntervalSince(interrupted) < 30", reason: "hang guard: a's sleep is far longer"),
        Allowed(file: "VibeCoreTests/TestLockTests.swift", text: "timeIntervalSince(started) < 30, \"it waited for the sleep\"", reason: "hang guard: the sleep is far longer"),
        Allowed(file: "VibeCoreTests/TestLockTests.swift", text: "timeIntervalSince(killed) < 30", reason: "hang guard: a's sleep is far longer"),
        Allowed(file: "VibeCoreTests/TestLockTests.swift", text: "#expect(waited < 30)", reason: "hang guard for a wait that must not sit out a long hold"),
        Allowed(file: "VibeHostTests/ParserCostTests.swift", text: "timeIntervalSince(start) < 30", reason: "hang guard: the child sleeps 600 s and is ended at 1 s"),
        Allowed(file: "VibeSwitcherTests/ChatTextPrepareLeakTests.swift", text: "timeIntervalSince(start) < 30", reason: "hang guard: the tool is ended at 1 s"),
        // Older than this lint, outside the 2026-11-08 change: each still to judge order or move to `.perf`.
        Allowed(file: "VibeHostTests/ParserIsolationTests.swift", text: "timeIntervalSince(sent) < 5", reason: "to move: a host's end after SIGTERM"),
        Allowed(file: "VibeHostTests/ParserIsolationTests.swift", text: "timeIntervalSince(killed) < 5", reason: "to move: reaped after the kill"),
        Allowed(file: "VibeHostTests/TestHostsTests.swift", text: "timeIntervalSince(gone) < 6", reason: "to move: a host's end after its last client"),
        Allowed(file: "VibeCoreTests/ProcessTableTests.swift", text: "timeIntervalSince(started) < 2", reason: "to move: a caller's wait at a stuck read's limit"),
        Allowed(file: "VibeCoreTests/ProcessTableTests.swift", text: "timeIntervalSince(behind) < 1", reason: "to move: the next caller told nil at once"),
        Allowed(file: "VibeCoreTests/IndexLockTests.swift", text: "timeIntervalSince(started) < 2.5", reason: "to move: a search's time limit"),
        Allowed(file: "VibeCoreTests/MacLoadTests.swift", text: "timeIntervalSince(started) < 5", reason: "to move: a refused merge comes back at once"),
    ]

    /// `took`/`waited`/… against a bare number, `Date().timeIntervalSince(x)` or `seconds(since: x)` against one, and a
    /// list of times checked against one. Comments and messages aside, a bound against a name passes.
    private static let number = #"<=?\s*(?:\.?[0-9]|\.milliseconds\(|\.seconds\()"#
    static let patterns: [Regex<AnyRegexOutput>] = [
        #"\b(?:took|waited|elapsed|duration|seconds|own)\)?\s*"# + number,
        #"(?:Date\(\)\.timeIntervalSince\([^)]*\)|seconds\(since:[^)]*\))\s*"# + number,
        #"\b(?:took|waited|times|elapsed|durations)\b[^{]*\.allSatisfy\s*\{\s*\$0\s*"# + number,
    ].map { try! Regex($0).wordBoundaryKind(.simple) }

    /// "file:line" for each flagged line of `text`, and the allowed entries it used. A line outside a `#expect`, a
    /// comment, or in a test or suite tagged `.perf` isn't flagged.
    static func flagged(file: String, text: String, allowed: [Allowed]) -> (flagged: [String], used: Set<Allowed>) {
        var flagged: [String] = []
        var used: Set<Allowed> = []
        var perfTest = false, perfSuite = false, suiteTagged = false
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let opening = line.trimmingCharacters(in: .whitespaces)
            if opening.hasPrefix("//") { continue }
            if line.hasPrefix("@Suite") {
                suiteTagged = PerfRunTests.isTagged(line)
                perfSuite = suiteTagged
            } else if line.hasPrefix("struct ") || line.hasPrefix("final class ") || line.hasPrefix("class ") {
                if !suiteTagged { perfSuite = false }
                suiteTagged = false
            }
            if opening.hasPrefix("@Test") { perfTest = PerfRunTests.isTagged(line) }
            guard !perfTest, !perfSuite, line.contains("#expect("), patterns.contains(where: { line.contains($0) }) else { continue }
            let allowing = allowed.filter { $0.file == file && line.contains($0.text) }
            if allowing.isEmpty { flagged.append("\(file):\(index + 1)") } else { used.formUnion(allowing) }
        }
        return (flagged, used)
    }

    @Test func noCorrectnessTestJudgesAnElapsedTimeByABareNumber() throws {
        var flagged: [String] = []
        var used: Set<Allowed> = []
        for (name, text) in try PerfRunTests.testFiles() where name != "VibeSwitcherTests/ElapsedTimeLintTests.swift" {
            let found = Self.flagged(file: name, text: text, allowed: Self.allowed)
            flagged += found.flagged
            used.formUnion(found.used)
        }
        #expect(flagged.isEmpty, "judge the order of events, a baseline from the same test, or make it a bench (.perf): \(flagged)")
        let stale = Set(Self.allowed).subtracting(used).map { "\($0.file): \($0.text)" }.sorted()
        #expect(stale.isEmpty, "allowed, and no such line any more: \(stale)")
        #expect(Self.allowed.count <= 13, "the list is for hang guards and shrinks: \(Self.allowed.count)")
    }

    @Test func theLintCatchesAnElapsedBoundAndOnlyThat() {
        func flagged(_ text: String, allowed: [Allowed] = []) -> [String] { Self.flagged(file: "a.swift", text: text, allowed: allowed).flagged }
        for line in ["#expect(took < 0.05, \"x\")", "#expect(waited < 1 && ok)", "#expect(run.own < 8)", "#expect(run.seconds < .5)",
                     "#expect(Date().timeIntervalSince(start) < 5)", "#expect(seconds(since: start) < 2)",
                     "#expect(took < .milliseconds(250))", "#expect(took.allSatisfy { $0 < 5 })"] {
            #expect(flagged("@Test func a() {\n    \(line)\n}") == ["a.swift:2"], "\(line)")
        }
        for line in ["#expect(took < hangGuard)", "#expect(times.allSatisfy { $0 < ProcessTable.snapshotLimit + 1 })",
                     "#expect(count < 5)", "#expect(waited >= 0.95)", "#expect(tick.timeIntervalSince(now) <= 60.01)",
                     "// #expect(took < 0.05)", "let took = 0 < 5"] {
            #expect(flagged("@Test func a() {\n    \(line)\n}").isEmpty, "\(line)")
        }
        #expect(flagged("@Test(.tags(.perf), .enabled(if: perfRun, perfOnly))\nfunc a() {\n    #expect(took < 0.05)\n}").isEmpty)
        #expect(flagged("@Suite(.tags(.perf))\nstruct S {\n    @Test func a() {\n        #expect(took < 0.05)\n    }\n}").isEmpty)
        let two = "@Test(.tags(.perf), .enabled(if: perfRun, perfOnly))\nfunc a() {}\n@Test func b() {\n    #expect(took < 1)\n}"
        #expect(flagged(two) == ["a.swift:4"])
        let allowed = [Allowed(file: "a.swift", text: "took < 1", reason: "hang guard")]
        #expect(flagged("@Test func a() {\n    #expect(took < 1)\n}", allowed: allowed).isEmpty)
    }
}
