import Foundation
import Testing

/// The Mac's ElapsedTimeLintTests on Linux (`MacText`): a correctness test doesn't judge an elapsed time by a bare number.
/// Its `number`, patterns, allow-list and bound are read from the Mac file; `flagged` is its copy.
struct MacElapsedTimeLintTests {
    static let mac = "ElapsedTimeLintTests.swift"

    struct Allowed: Hashable {
        let file: String, text: String, reason: String
    }

    static let allowed: [Allowed] = {
        let text = (try? MacText.file(mac)) ?? ""
        let entry = try! NSRegularExpression(pattern: #"Allowed\(file: "((?:\\.|[^"\\])*)", text: "((?:\\.|[^"\\])*)", reason: "((?:\\.|[^"\\])*)"\)"#)
        return entry.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            func part(_ at: Int) -> String? { Range(match.range(at: at), in: text).map { MacText.unescaped(String(text[$0])) } }
            guard let file = part(1), let line = part(2), let reason = part(3), file != "a.swift" else { return nil }
            return Allowed(file: file, text: line, reason: reason)
        }
    }()

    /// The Mac's `number` and its three patterns, each a raw string, `+ number` where the Mac adds it.
    static let patterns: [Regex<AnyRegexOutput>] = {
        let text = (try? MacText.file(mac)) ?? ""
        guard let number = MacText.literals((try? MacText.between(text, "private static let number = ", "\n")) ?? "").first,
              let list = try? MacText.between(text, "static let patterns: [Regex<AnyRegexOutput>] = [", "].map") else { return [] }
        return list.split(separator: "\n").compactMap { line -> Regex<AnyRegexOutput>? in
            guard let raw = MacText.literals(String(line)).first else { return nil }
            return try? Regex(raw + (line.contains("+ number") ? number : "")).wordBoundaryKind(.simple)
        }
    }()

    static func flagged(file: String, text: String, allowed: [Allowed]) -> (flagged: [String], used: Set<Allowed>) {
        var flagged: [String] = []
        var used: Set<Allowed> = []
        var perfTest = false, perfSuite = false, suiteTagged = false
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let opening = line.trimmingCharacters(in: .whitespaces)
            if opening.hasPrefix("//") { continue }
            if line.hasPrefix("@Suite") {
                suiteTagged = MacPerfRunLintTests.isTagged(line)
                perfSuite = suiteTagged
            } else if line.hasPrefix("struct ") || line.hasPrefix("final class ") || line.hasPrefix("class ") {
                if !suiteTagged { perfSuite = false }
                suiteTagged = false
            }
            if opening.hasPrefix("@Test") { perfTest = MacPerfRunLintTests.isTagged(line) }
            guard !perfTest, !perfSuite, line.contains("#expect("), patterns.contains(where: { line.contains($0) }) else { continue }
            let allowing = allowed.filter { $0.file == file && line.contains($0.text) }
            if allowing.isEmpty { flagged.append("\(file):\(index + 1)") } else { used.formUnion(allowing) }
        }
        return (flagged, used)
    }

    @Test func theMacsRuleHoldsOnEveryTestFile() throws {
        let text = try MacText.file(Self.mac)
        #expect(Self.patterns.count == 3, "the Mac's patterns weren't read: \(Self.patterns.count)")
        #expect(Self.allowed.count >= 1, "the Mac's allow-list wasn't read")
        var flagged: [String] = []
        var used: Set<Allowed> = []
        for (name, file) in try MacPerfRunLintTests.testFiles() where name != "VibeSwitcherTests/" + Self.mac {
            let found = Self.flagged(file: name, text: file, allowed: Self.allowed)
            flagged += found.flagged
            used.formUnion(found.used)
        }
        #expect(flagged.isEmpty, "the Mac's ElapsedTimeLint fails on these (judge the order of events, a baseline, or make it a bench .perf): \(flagged)")
        let stale = Set(Self.allowed).subtracting(used).map { "\($0.file): \($0.text)" }.sorted()
        #expect(stale.isEmpty, "the Mac's allow-list names lines no longer there (its gate fails): \(stale)")
        let bound = try #require(Int(try MacText.between(text, "Self.allowed.count <= ", ",")), "the Mac's bound")
        #expect(Self.allowed.count <= bound)
    }

    /// The Mac test's own sample lines (both lists of `theLintCatchesAnElapsedBoundAndOnlyThat`): the copy flags the
    /// first and not the second, as the original does.
    @Test func theCopyFlagsTheMacsSamplesAsTheMacDoes() throws {
        let text = try MacText.file(Self.mac)
        let test = try MacText.between(text, "func theLintCatchesAnElapsedBoundAndOnlyThat()", "\n    }\n")
        let lists = test.components(separatedBy: "for line in [").dropFirst().map { $0.components(separatedBy: "] {").first ?? "" }
        try #require(lists.count == 2, "the Mac's two sample lists weren't found")
        let caught = MacText.literals(lists[0]), passed = MacText.literals(lists[1])
        #expect(caught.count >= 5 && passed.count >= 5, "\(caught) \(passed)")
        func flagged(_ line: String) -> [String] { Self.flagged(file: "a.swift", text: "@Test func a() {\n    \(line)\n}", allowed: []).flagged }
        for line in caught { #expect(flagged(line) == ["a.swift:2"], "\(line)") }
        for line in passed { #expect(flagged(line).isEmpty, "\(line)") }
    }
}
