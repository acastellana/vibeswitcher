import Foundation
import Testing

/// The Mac's PerfRunTests on Linux (`MacText`): the tests tagged `.perf` are test.sh's `perf_tests`, each skipped outside
/// `--perf`, and a test judged only on a calm Mac is a bench. Its markers and bound are read from the Mac file; the
/// functions are its copies (and DebugAidsLintTests' `blocks`).
struct MacPerfRunLintTests {
    static let mac = "PerfRunTests.swift"
    static let repo = MacText.repo

    static func listed() throws -> Set<String> {
        let script = try String(contentsOf: repo.appendingPathComponent("scripts/test.sh"), encoding: .utf8)
        guard let list = script.firstMatch(of: #/\nperf_tests=\(\n([^)]*)\n\)/#) else { return [] }
        return Set(list.1.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    static func testFiles() throws -> [(name: String, text: String)] {
        let tests = repo.appendingPathComponent("Tests")
        let files = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try files.filter { $0.pathExtension == "swift" }.map {
            ($0.path.replacingOccurrences(of: tests.path + "/", with: ""), try String(contentsOf: $0, encoding: .utf8))
        }
    }

    static func isTagged(_ line: String) -> Bool {
        let opening = line.trimmingCharacters(in: .whitespaces)
        return (opening.hasPrefix("@Test(") || opening.hasPrefix("@Suite(")) && opening.contains(".tags(.perf)")
    }

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

    static func blocks(in text: String, opening: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var found: [String] = []
        for (index, line) in lines.enumerated() where line.contains(opening) {
            let indent = line.prefix { $0 == " " }
            let end = lines[(index + 1)...].firstIndex { $0 == indent + "}" } ?? lines.count - 1
            found.append(lines[index...end].joined(separator: "\n"))
        }
        return found
    }

    @Test func theScriptsBenchesAreTheTaggedOnes() throws {
        let tagged = try Self.testFiles().reduce(into: Set<String>()) { $0.formUnion(Self.tagged(in: $1.text)) }
        let listed = try Self.listed()
        #expect(!listed.isEmpty, "no perf_tests in scripts/test.sh")
        #expect(tagged == listed, "tagged .perf, not in test.sh's perf_tests: \(tagged.subtracting(listed).sorted()); in perf_tests, not tagged: \(listed.subtracting(tagged).sorted())")
        for file in try Self.testFiles() {
            for line in file.text.components(separatedBy: "\n") where Self.isTagged(line) {
                #expect(line.contains(".enabled(if: perfRun, perfOnly)"), "\(file.name): \(line)")
            }
        }
    }

    @Test func aTestJudgedOnlyOnACalmMacIsABench() throws {
        let text = try MacText.file(Self.mac)
        let markers = MacText.literals(try MacText.between(text, "static let markers = [", "]\n"))
        #expect(markers.count >= 3, "the Mac's markers weren't read: \(markers)")
        let bound = try #require(Int(try MacText.between(text, "#expect(found >= ", ",")), "the Mac's bound")
        var found = 0
        for file in try Self.testFiles() where file.name != "VibeSwitcherTests/" + Self.mac {
            for test in Self.blocks(in: file.text, opening: "@Test") {
                let marks = markers.filter(test.contains)
                guard !marks.isEmpty else { continue }
                found += 1
                #expect(test.components(separatedBy: "\n").contains(where: Self.isTagged), "\(file.name): \(marks) in a test the default run runs")
            }
        }
        #expect(found >= bound, "found \(found) tests with a bench's markers")
    }

    /// DebugAidsLintTests' sample, lifted: the copy of `blocks` finds the block and stops at its end.
    @Test func theBlockScanFindsWhatTheMacsDoes() throws {
        let text = try MacText.file("DebugAidsLintTests.swift")
        let sample = try MacText.between(text, "let sample = \"\"\"\n", "\n        \"\"\"")
        let lines = sample.components(separatedBy: "\n").map { String($0.dropFirst(min(8, $0.prefix { $0 == " " }.count))) }.joined(separator: "\n")
        let found = Self.blocks(in: lines, opening: "addObserver(")
        #expect(found.count == 1 && !found[0].contains("other()"), "\(found)")
    }
}
