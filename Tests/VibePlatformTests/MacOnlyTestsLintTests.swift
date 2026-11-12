import Foundation
import Testing

/// The core's test files that are compiled only on the Mac, whole or in part, are the ones listed in
/// Tests/VibeCoreTests/MacOnlyTests.txt: a file's name, two spaces, the reason (for a file wrapped in part, which of
/// its tests). A file wrapped whole in `#if canImport(Darwin)` and not listed runs nowhere but the Mac without anyone
/// having said why; a file listed and not wrapped runs on Linux too, and the list says it doesn't.
struct MacOnlyTestsLintTests {
    static let folder = PlatformLintTests.repo.appendingPathComponent("Tests/VibeCoreTests")
    static let wrap = "#if canImport(Darwin)"

    /// MacOnlyTests.txt's lines, in its order: the file, and the reason ("" when the line gives none).
    static func listed() throws -> [(file: String, reason: String)] {
        let list = try String(contentsOf: folder.appendingPathComponent("MacOnlyTests.txt"), encoding: .utf8)
        return list.components(separatedBy: "\n").filter { !$0.isEmpty }.map { line in
            guard let gap = line.range(of: "  ") else { return (line, "") }
            return (String(line[..<gap.lowerBound]), line[gap.upperBound...].trimmingCharacters(in: .whitespaces))
        }
    }

    /// Whether `text`'s first line that is neither empty nor a `//` comment is the wrap: the whole file is the Mac's.
    static func isWrappedWhole(_ text: String) -> Bool {
        let first = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("//") }
        return first == wrap
    }

    @Test func theListMatchesTheFiles() throws {
        let files = (try FileManager.default.contentsOfDirectory(atPath: Self.folder.path)).filter { $0.hasSuffix(".swift") }.sorted()
        #expect(files.contains("TestSupport.swift"), "the core's tests weren't read")
        func text(_ file: String) -> String? { try? String(contentsOf: Self.folder.appendingPathComponent(file), encoding: .utf8) }
        let listed = try Self.listed()
        let names = Set(listed.map(\.file))

        let unlisted = files.filter { file in text(file).map(Self.isWrappedWhole) == true && !names.contains(file) }
        #expect(unlisted == [], """
            wrapped whole in `\(Self.wrap)` and not in Tests/VibeCoreTests/MacOnlyTests.txt: add a line, the file's \
            name, two spaces, why it is the Mac's alone:
            \(unlisted.joined(separator: "\n"))
            """)
        let unwrapped = listed.map(\.file).filter { file in text(file)?.contains(Self.wrap) != true }
        #expect(unwrapped == [], """
            listed in Tests/VibeCoreTests/MacOnlyTests.txt and not there, or with no `\(Self.wrap)` in it: take the \
            line out:
            \(unwrapped.joined(separator: "\n"))
            """)
        let unexplained = listed.filter { $0.reason.isEmpty }.map(\.file)
        #expect(unexplained == [], "listed in Tests/VibeCoreTests/MacOnlyTests.txt without a reason (two spaces, then why): \(unexplained)")
        #expect(listed.map(\.file) == names.sorted(), "MacOnlyTests.txt is sorted, each file once")
    }

    @Test func aWholeFileWrapIsToldFromAWrapInside() {
        #expect(Self.isWrappedWhole("#if canImport(Darwin)\nimport Foundation\n#endif\n"))
        #expect(Self.isWrappedWhole("// Why.\n\n  /// More.\n#if canImport(Darwin)\nimport Security\n#endif\n"))
        #expect(!Self.isWrappedWhole("import Foundation\n#if canImport(Darwin)\nimport Network\n#endif\n"))
        #expect(!Self.isWrappedWhole("#if canImport(Darwin) || os(Linux)\n#endif\n"))
        #expect(!Self.isWrappedWhole(""))
    }
}
