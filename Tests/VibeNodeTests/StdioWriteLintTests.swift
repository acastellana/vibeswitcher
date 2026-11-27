import Foundation
import Testing

/// No `FileHandle.standardError` or `FileHandle.standardOutput` in the node's targets: their `write(_:)` traps when
/// the write fails (a SIGILL on Linux, reproduced with stderr on /dev/full), so a log line on a full disk would end the
/// server, then the host, then every session (the architecture review's row 2). Standard error and output are written
/// with `Platform.Stdio` (raw `write(2)`, failures ignored). Comments and string literals don't count.
struct StdioWriteLintTests {
    /// Every portable target but the Mac app's (`Sources/VibeSwitcher` isn't edited on v2), and the keeper's package
    /// (`Keeper/Sources`: what slice K0 moved there from VibePlatform and VibeCore, and the keeper itself).
    static let covered = ["Sources/VibePlatform", "Sources/VibeCore", "Sources/VibeHost", "Sources/VibeNode", "Sources/vibeswitcher-host",
                          "Sources/vibeswitcher-server", "Sources/vibeswitcher-cli", "Sources/vibeswitcher-mcp", "Sources/vibeswitcher-hook",
                          "Keeper/Sources"]
    private let scratch = Scratch()

    static let refused = #"\bFileHandle\s*\.\s*standard(Error|Output)\b"#

    /// Each use in `text`, as its line number.
    static func findings(in text: String) -> [Int] {
        let regex = try! Regex(refused).wordBoundaryKind(.simple)
        return ServerLintTests.code(text).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .filter { $0.element.contains(regex) }.map { $0.offset + 1 }
    }

    /// Each use in the covered folders of `tree` (the repository, or a test's tree), as "PATH:LINE".
    static func scan(_ tree: URL = ServerLintTests.repo) throws -> [String] {
        var found: [String] = []
        for folder in covered {
            let root = tree.appendingPathComponent(folder)
            // Relative to the folder as the walk gives them (a test's tree under a linked TMPDIR is walked resolved).
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
            for case let relative as String in walker where relative.hasSuffix(".swift") {
                let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
                found += findings(in: text).map { "\(folder)/\(relative):\($0)" }
            }
        }
        return found
    }

    @Test func noTargetWritesStandardErrorOrOutputThroughFileHandle() throws {
        for folder in Self.covered {
            #expect(FileManager.default.fileExists(atPath: ServerLintTests.repo.appendingPathComponent(folder).path), "\(folder)")
        }
        let found = try Self.scan()
        #expect(found.isEmpty, "write with Platform.Stdio.error/output instead (FileHandle's write traps on a failed write):\n\(found.joined(separator: "\n"))")
    }

    /// The keeper's package is read: a `FileHandle.standardError` planted in a sample tree's `Keeper/Sources` is found by
    /// the same scan.
    @Test func theKeepersSourcesAreCovered() throws {
        let tree = scratch.url("stdio-write-keeper")
        let planted = tree.appendingPathComponent("Keeper/Sources/vibeswitcher-keeper/main.swift")
        try FileManager.default.createDirectory(at: planted.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "import Foundation\nFileHandle.standardError.write(Data(\"x\\n\".utf8))\n".write(to: planted, atomically: true, encoding: .utf8)
        #expect(try Self.scan(tree) == ["Keeper/Sources/vibeswitcher-keeper/main.swift:2"])
    }

    /// The rule on a fixture: each form found on its line; a name in a comment or a string isn't.
    @Test func theRuleFindsEachForm() {
        let fixture = """
            FileHandle.standardError.write(Data("x".utf8))
            try? FileHandle.standardOutput.write(contentsOf: data)
            let handle = FileHandle . standardError
            // FileHandle.standardError.write in a comment
            log("FileHandle.standardOutput in a string")
            Platform.Stdio.error("fine\\n")
            """
        #expect(Self.findings(in: fixture) == [1, 2, 3])
    }
}
