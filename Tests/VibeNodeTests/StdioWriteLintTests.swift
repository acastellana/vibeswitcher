import Foundation
import Testing

/// No `FileHandle.standardError` or `FileHandle.standardOutput` in the node's targets: their `write(_:)` traps when
/// the write fails (a SIGILL on Linux, reproduced with stderr on /dev/full), so a log line on a full disk would end the
/// server, then the host, then every session (the architecture review's row 2). Standard error and output are written
/// with `Platform.Stdio` (raw `write(2)`, failures ignored). Comments and string literals don't count.
struct StdioWriteLintTests {
    /// Every portable target but the Mac app's (`Sources/VibeSwitcher` isn't edited on v2).
    static let covered = ["Sources/VibePlatform", "Sources/VibeCore", "Sources/VibeHost", "Sources/VibeNode", "Sources/vibeswitcher-host",
                          "Sources/vibeswitcher-server", "Sources/vibeswitcher-cli", "Sources/vibeswitcher-mcp", "Sources/vibeswitcher-hook"]

    static let refused = #"\bFileHandle\s*\.\s*standard(Error|Output)\b"#

    /// Each use in `text`, as its line number.
    static func findings(in text: String) -> [Int] {
        let regex = try! Regex(refused).wordBoundaryKind(.simple)
        return ServerLintTests.code(text).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .filter { $0.element.contains(regex) }.map { $0.offset + 1 }
    }

    @Test func noTargetWritesStandardErrorOrOutputThroughFileHandle() throws {
        var found: [String] = []
        for folder in Self.covered {
            let root = ServerLintTests.repo.appendingPathComponent(folder)
            #expect(FileManager.default.fileExists(atPath: root.path), "\(folder)")
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                found += Self.findings(in: text).map { "\(folder)/\(file.path.dropFirst(root.path.count + 1)):\($0)" }
            }
        }
        #expect(found.isEmpty, "write with Platform.Stdio.error/output instead (FileHandle's write traps on a failed write):\n\(found.joined(separator: "\n"))")
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
