import Foundation
import Testing

/// The test files of the core and of the session host that are compiled only on the Mac, whole or in part, are the
/// ones listed in each target's MacOnlyTests.txt (Tests/VibeCoreTests/, Tests/VibeHostTests/): a file's name, two
/// spaces, the reason (for a file wrapped in part, which of its tests). A file wrapped whole in
/// `#if canImport(Darwin)` and not listed runs nowhere but the Mac without anyone having said why; a file listed and
/// not wrapped runs on Linux too, and the list says it doesn't.
struct MacOnlyTestsLintTests {
    /// A test target with a list, and what its stop rule leaves out of the count.
    struct Target: Sendable, CustomTestStringConvertible {
        let name: String
        /// The plan whose stop rule it is, and its step.
        let rule: String
        /// Lines the plan lists itself, or counts apart (the session host's tests of the app's key, listed by name):
        /// not counted against the rule.
        let countedApart: @Sendable (_ file: String, _ reason: String) -> Bool

        var folder: URL { PlatformLintTests.repo.appendingPathComponent("Tests/\(name)") }
        var testDescription: String { name }
    }

    static let core = Target(name: "VibeCoreTests", rule: "docs/superpowers/plans/2026-11-12-v2-stage-1-core-on-linux.md, Task 12 Step 3",
                             countedApart: { _, _ in false })
    /// The reason the session host's tests of the app's key give: on Linux the app is a connector's connection.
    static let appKeyReason = "the Linux app is a connector's connection and holds no key"
    /// The stage 2 plan's own three (Task 5a Step 1).
    static let hostPlanned: Set<String> = ["AppCodeTests.swift", "ParserCostTests.swift", "UpgradeFromLeadHostTests.swift"]
    static let host = Target(name: "VibeHostTests", rule: "docs/superpowers/plans/2026-11-13-v2-stage-2-session-host.md, Task 5b Step 1",
                             countedApart: { file, reason in hostPlanned.contains(file) || reason.contains(appKeyReason) })
    static let targets = [core, host]
    static let wrap = "#if canImport(Darwin)"

    /// `target`'s MacOnlyTests.txt lines, in its order: the file, and the reason ("" when the line gives none).
    static func listed(_ target: Target) throws -> [(file: String, reason: String)] {
        let list = try String(contentsOf: target.folder.appendingPathComponent("MacOnlyTests.txt"), encoding: .utf8)
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

    @Test(arguments: targets) func theListMatchesTheFiles(_ target: Target) throws {
        let files = (try FileManager.default.contentsOfDirectory(atPath: target.folder.path)).filter { $0.hasSuffix(".swift") }.sorted()
        #expect(files.contains("TestSupport.swift"), "\(target.name) wasn't read")
        func text(_ file: String) -> String? { try? String(contentsOf: target.folder.appendingPathComponent(file), encoding: .utf8) }
        let listed = try Self.listed(target)
        let names = Set(listed.map(\.file))
        let path = "Tests/\(target.name)/MacOnlyTests.txt"

        let unlisted = files.filter { file in text(file).map(Self.isWrappedWhole) == true && !names.contains(file) }
        #expect(unlisted == [], """
            wrapped whole in `\(Self.wrap)` and not in \(path): add a line, the file's name, two spaces, why it is the \
            Mac's alone:
            \(unlisted.joined(separator: "\n"))
            """)
        let unwrapped = listed.map(\.file).filter { file in text(file)?.contains(Self.wrap) != true }
        #expect(unwrapped == [], """
            listed in \(path) and not there, or with no `\(Self.wrap)` in it: take the line out:
            \(unwrapped.joined(separator: "\n"))
            """)
        let unexplained = listed.filter { $0.reason.isEmpty }.map(\.file)
        #expect(unexplained == [], "listed in \(path) without a reason (two spaces, then why): \(unexplained)")
        #expect(listed.map(\.file) == names.sorted(), "\(path) is sorted, each file once")
    }

    /// The stop rule of the plans' sorting (the stage 1 plan's Task 12 Step 3, the stage 2 plan's Task 5b Step 1) as
    /// a fraction: `listed` lines of a MacOnlyTests.txt are fewer than a tenth of the target's `files`.
    static func underTheStopRule(listed: Int, files: Int) -> Bool { listed * 10 < files }

    /// Fewer than a tenth of a target's test files are the Mac's, whole or in part, besides those its plan counts
    /// apart: both counted as they are now, so the threshold moves with the target.
    @Test(arguments: targets) func fewerThanATenthOfATargetsFilesAreMacOnly(_ target: Target) throws {
        let files = (try FileManager.default.contentsOfDirectory(atPath: target.folder.path)).filter { $0.hasSuffix(".swift") }
        #expect(files.contains("TestSupport.swift"), "\(target.name) wasn't read")
        let counted = try Self.listed(target).filter { !target.countedApart($0.file, $0.reason) }
        #expect(Self.underTheStopRule(listed: counted.count, files: files.count), """
            \(counted.count) of \(target.name)'s \(files.count) test files are in its MacOnlyTests.txt, besides those \
            counted apart: a tenth or more, the plan's point to stop and report (\(target.rule)) before listing another
            """)
    }

    @Test func theStopRulesEdge() {
        // 23 of 236 is under it, 24 isn't; a tenth exactly isn't.
        #expect(Self.underTheStopRule(listed: 23, files: 236))
        #expect(!Self.underTheStopRule(listed: 24, files: 236))
        #expect(!Self.underTheStopRule(listed: 10, files: 100))
        #expect(Self.underTheStopRule(listed: 0, files: 1))
        // The session host's: five of 58 is under it, six isn't; its plan's own three, and its tests of the app's
        // key, aren't counted.
        #expect(Self.underTheStopRule(listed: 5, files: 58))
        #expect(!Self.underTheStopRule(listed: 6, files: 58))
        #expect(Self.host.countedApart("AppCodeTests.swift", "cdhash"))
        #expect(Self.host.countedApart("AppKeyTests.swift", "the whole file: \(Self.appKeyReason)"))
        #expect(!Self.host.countedApart("HostLogTests.swift", "something else"))
        #expect(!Self.core.countedApart("AppCodeTests.swift", Self.appKeyReason))
    }

    @Test func aWholeFileWrapIsToldFromAWrapInside() {
        #expect(Self.isWrappedWhole("#if canImport(Darwin)\nimport Foundation\n#endif\n"))
        #expect(Self.isWrappedWhole("// Why.\n\n  /// More.\n#if canImport(Darwin)\nimport Security\n#endif\n"))
        #expect(!Self.isWrappedWhole("import Foundation\n#if canImport(Darwin)\nimport Network\n#endif\n"))
        #expect(!Self.isWrappedWhole("#if canImport(Darwin) || os(Linux)\n#endif\n"))
        #expect(!Self.isWrappedWhole(""))
    }
}
