import Foundation
import Testing

/// An elapsed-time guard in the node's processes reads the steady clock (`Platform.Clock.steadyDate`, or
/// `MacTime.real.awake()`), not the wall clock (the architecture review's row 6): this machine's wall clock steps by up
/// to 7 s when Windows sets it, and a 10 s typing guard on it could shrink to 3 s. Refused, outside comments and
/// string literals: `Date().timeIntervalSince(`, `Date.now.timeIntervalSince(`, `.timeIntervalSinceNow`, a deadline
/// made with `Date().addingTimeInterval(`, and `Date()` compared with `<`, `>`, `<=` or `>=`. A comparison of stamps
/// stored or shown (a file's date, a record's `at`) is the wall clock's and goes in `allowed` with its reason.
///
/// A guard on a feature's injected clock (`now`, `handoverNow`, `dialogNow`, … a test drives) isn't caught: the engine's
/// injected clocks are read by their tests to move time, and also stamp what is shown.
struct ElapsedGuardLintTests {
    /// The node's processes: the host, the server, the engine, the command line, and the platform layer under them.
    static let covered = ["Sources/VibeNode", "Sources/VibeHost", "Sources/vibeswitcher-server", "Sources/vibeswitcher-cli",
                          "Sources/vibeswitcher-host", "Sources/VibePlatform"]

    static let refused: [(pattern: String, what: String)] = [
        (#"(?<![\w.])Date\(\)\s*\.\s*timeIntervalSince\("#, "Date().timeIntervalSince("),
        (#"(?<![\w.])Date\s*\.\s*now\s*\.\s*timeIntervalSince\("#, "Date.now.timeIntervalSince("),
        (#"\.\s*timeIntervalSinceNow\b"#, ".timeIntervalSinceNow"),
        (#"(?<![\w.])Date\(\)\s*\.\s*addingTimeInterval\("#, "a deadline on Date()"),
        (#"(?<![\w.])Date\(\)\s*[<>]"#, "Date() compared"),
        (#"[<>]=?\s*Date\(\)"#, "Date() compared"),
    ]

    /// Wall-clock uses kept, by file and the line's text, each with its reason. One that matches nothing is stale.
    static let allowed: [(path: String, text: String, reason: String)] = [
        ("Sources/VibeNode/Server/Requests.swift", "Date().timeIntervalSince(began) <= Self.rerunWithin",
         "a vault record's stamp, written before this server started: only the wall clock spans processes, and a step of seconds on 15 minutes changes nothing"),
    ]

    /// Each refused use in `text`, as "LINE: WHAT: the line".
    static func findings(in text: String) -> [(line: Int, what: String, text: String)] {
        let original = text.split(separator: "\n", omittingEmptySubsequences: false)
        var found: [(Int, String, String)] = []
        for (number, line) in ServerLintTests.code(text).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            // Foundation's expressions: Swift's `Regex` has no lookbehind.
            for (pattern, what) in refused where String(line).range(of: pattern, options: .regularExpression) != nil {
                found.append((number + 1, what, String(original[number])))
                break
            }
        }
        return found
    }

    @Test func noElapsedGuardReadsTheWallClock() throws {
        var found: [String] = []
        var used = Set<Int>()
        for folder in Self.covered {
            let root = ServerLintTests.repo.appendingPathComponent(folder)
            #expect(FileManager.default.fileExists(atPath: root.path), "\(folder)")
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                let path = "\(folder)/\(file.path.dropFirst(root.path.count + 1))"
                for finding in Self.findings(in: try String(contentsOf: file, encoding: .utf8)) {
                    if let index = Self.allowed.firstIndex(where: { $0.path == path && finding.text.contains($0.text) }) {
                        used.insert(index)
                    } else {
                        found.append("\(path):\(finding.line): \(finding.what)")
                    }
                }
            }
        }
        #expect(found.isEmpty, "an elapsed-time guard on the wall clock: use Platform.Clock.steadyDate() (or MacTime.real.awake()), or allow a stamp's comparison with its reason:\n\(found.joined(separator: "\n"))")
        let stale = Self.allowed.indices.filter { !used.contains($0) }.map { "\(Self.allowed[$0].path): \(Self.allowed[$0].text)" }
        #expect(stale.isEmpty, "allowed, and no such line any more: \(stale)")
    }

    /// The rule on a fixture: each form found on its line; the steady clock, a stamp's own arithmetic, a comment and a
    /// string aren't.
    @Test func theRuleFindsEachForm() {
        let fixture = """
            guard Date().timeIntervalSince(typedAt) > 10 else { return }
            let left = deadline.timeIntervalSinceNow
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {}
            guard deadline >= Date() else { return }
            let age = Date.now.timeIntervalSince(started)
            guard Platform.Clock.steadyDate().timeIntervalSince(typedAt) > 10 else { return }
            let stamp = record.at.timeIntervalSince1970
            // Date().timeIntervalSince(x) in a comment
            log("ended \\(Int(-ended.at.timeIntervalSinceNow)) s ago")
            """
        #expect(Self.findings(in: fixture).map(\.line) == [1, 2, 3, 4, 5, 6])
    }
}
