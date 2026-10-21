import Foundation
import Testing

/// The default run is correctness only; the benches (judged by wall-clock time or memory, so passing or not with the
/// Mac's load) run in `scripts/test.sh --perf` alone. A bench is tagged `.perf` and skipped unless VIBESWITCHER_PERF=1,
/// and `--perf` picks the benches by test.sh's `perf_tests`: the two must name the same tests, and a test that reads
/// the Mac's load to decide whether to judge its numbers is a bench.
struct PerfRunTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// test.sh's `perf_tests`: `Suite/test` or `Suite`.
    static func listed() throws -> Set<String> {
        let script = try String(contentsOf: repo.appendingPathComponent("scripts/test.sh"), encoding: .utf8)
        guard let list = script.firstMatch(of: #/\nperf_tests=\(\n([^)]*)\n\)/#) else { return [] }
        return Set(list.1.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Each Swift file under Tests/ with its text.
    static func testFiles() throws -> [(name: String, text: String)] {
        let tests = repo.appendingPathComponent("Tests")
        let files = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try files.filter { $0.pathExtension == "swift" }.map {
            ($0.path.replacingOccurrences(of: tests.path + "/", with: ""), try String(contentsOf: $0, encoding: .utf8))
        }
    }

    /// Whether `line` opens a test or suite tagged `.perf`.
    static func isTagged(_ line: String) -> Bool {
        let opening = line.trimmingCharacters(in: .whitespaces)
        return (opening.hasPrefix("@Test(") || opening.hasPrefix("@Suite(")) && opening.contains(".tags(.perf)")
    }

    /// The tests tagged `.perf` in `text`, as `perf_tests` names them: a suite's name, or `Suite/test` for a test, its
    /// suite the last top-level `struct` before it.
    static func tagged(in text: String) -> Set<String> {
        let lines = text.components(separatedBy: "\n")
        var found: Set<String> = []
        var suite = ""
        for (index, line) in lines.enumerated() {
            if let name = line.firstMatch(of: #/^struct (\w+)/#) { suite = String(name.1) }
            guard isTagged(line) else { continue }
            let rest = lines[index...].prefix(3).joined(separator: "\n")
            if line.contains("@Suite("), let name = rest.firstMatch(of: #/struct (\w+)/#) {
                found.insert(String(name.1))
            } else if let name = rest.firstMatch(of: #/func (\w+)\(/#) {
                found.insert("\(suite)/\(name.1)")
            }
        }
        return found
    }

    @Test func theScriptsBenchesAreTheTaggedOnes() throws {
        let tagged = try Self.testFiles().reduce(into: Set<String>()) { $0.formUnion(Self.tagged(in: $1.text)) }
        let listed = try Self.listed()
        #expect(!listed.isEmpty, "no perf_tests in scripts/test.sh")
        let unlisted = tagged.subtracting(listed).sorted(), untagged = listed.subtracting(tagged).sorted()
        #expect(tagged == listed, "tagged .perf, not in test.sh's perf_tests: \(unlisted); in perf_tests, not tagged: \(untagged)")
        // Each tagged one is also skipped outside --perf.
        for file in try Self.testFiles() {
            for line in file.text.components(separatedBy: "\n") where Self.isTagged(line) {
                #expect(line.contains(".enabled(if: perfRun, perfOnly)"), "\(file.name): \(line)")
            }
        }
    }

    /// What a bench reads to decide whether the Mac is calm enough to judge it, or how it times the app's main thread.
    static let markers = ["= MacLoad.oneMinute()", "is over load_threshold\")", "\"--board-bench\""]

    @Test func aTestJudgedOnlyOnACalmMacIsABench() throws {
        var found = 0
        for file in try Self.testFiles() where file.name != "VibeSwitcherTests/PerfRunTests.swift" {
            for test in DebugAidsLintTests.blocks(in: file.text, opening: "@Test") {
                let marks = Self.markers.filter(test.contains)
                guard !marks.isEmpty else { continue }
                found += 1
                #expect(test.components(separatedBy: "\n").contains(where: Self.isTagged), "\(file.name): \(marks) in a test the default run runs:\n\(test.prefix(300))")
            }
        }
        #expect(found >= 4, "found \(found) tests with a bench's markers: the scan no longer finds them")
    }
}
