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
    /// The node's processes: the host, the server, the engine, the command line, the platform layer under them, and the
    /// keeper's package (`Keeper/Sources`: what slice K0 moved there from VibePlatform, and the keeper itself).
    static let covered = ["Sources/VibeNode", "Sources/VibeHost", "Sources/vibeswitcher-server", "Sources/vibeswitcher-cli",
                          "Sources/vibeswitcher-host", "Sources/VibePlatform", "Keeper/Sources"]
    private let scratch = Scratch()

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

    /// Each refused use in the covered folders of `tree` (the repository, or a test's tree) that `allowed` doesn't list,
    /// as "PATH:LINE: WHAT", and the indices of the allowed uses met.
    static func scan(_ tree: URL = ServerLintTests.repo) throws -> (found: [String], used: Set<Int>) {
        var found: [String] = []
        var used = Set<Int>()
        for folder in covered {
            let root = tree.appendingPathComponent(folder)
            // Relative to the folder as the walk gives them (a test's tree under a linked TMPDIR is walked resolved).
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
            for case let relative as String in walker where relative.hasSuffix(".swift") {
                let path = "\(folder)/\(relative)"
                for finding in findings(in: try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)) {
                    if let index = allowed.firstIndex(where: { $0.path == path && finding.text.contains($0.text) }) {
                        used.insert(index)
                    } else {
                        found.append("\(path):\(finding.line): \(finding.what)")
                    }
                }
            }
        }
        return (found, used)
    }

    @Test func noElapsedGuardReadsTheWallClock() throws {
        for folder in Self.covered {
            #expect(FileManager.default.fileExists(atPath: ServerLintTests.repo.appendingPathComponent(folder).path), "\(folder)")
        }
        let (found, used) = try Self.scan()
        #expect(found.isEmpty, "an elapsed-time guard on the wall clock: use Platform.Clock.steadyDate() (or MacTime.real.awake()), or allow a stamp's comparison with its reason:\n\(found.joined(separator: "\n"))")
        let stale = Self.allowed.indices.filter { !used.contains($0) }.map { "\(Self.allowed[$0].path): \(Self.allowed[$0].text)" }
        #expect(stale.isEmpty, "allowed, and no such line any more: \(stale)")
    }

    /// The keeper's package is read: a wall-clock guard planted in a sample tree's `Keeper/Sources` is found by the same
    /// scan.
    @Test func theKeepersSourcesAreCovered() throws {
        let tree = scratch.url("elapsed-guard-keeper")
        let planted = tree.appendingPathComponent("Keeper/Sources/VibeKeep/Planted.swift")
        try FileManager.default.createDirectory(at: planted.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "import Foundation\nguard Date().timeIntervalSince(asked) < 5 else { return }\n".write(to: planted, atomically: true, encoding: .utf8)
        #expect(try Self.scan(tree).found == ["Keeper/Sources/VibeKeep/Planted.swift:2: Date().timeIntervalSince("])
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
