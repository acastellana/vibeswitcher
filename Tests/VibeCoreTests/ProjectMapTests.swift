import Foundation
import Testing

/// CLAUDE.md at the repository's root is the map every worker and verifier reads first (Claude Code loads it by itself in
/// every worktree). A map that names a file that was moved or renamed sends them looking in the wrong place, so every
/// path it names must exist, and it stays short: a map that points to docs/, not a manual.
struct ProjectMapTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let lineLimit = 160

    /// A repository path where one starts (not inside `.build/…` or `~/…`): under one of the top-level folders, or a
    /// root file. A trailing `/` names a folder; a `*` in the last part is a glob that must match something.
    static let pathPattern = try! NSRegularExpression(
        pattern: #"(?<![\w./~-])(?:(?:Sources|Tests|scripts|docs|Web|Resources)/[\w./*-]*|Package\.swift|README\.md)"#)

    /// The paths `text` names, in order, without a sentence's closing period.
    static func paths(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return pathPattern.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
    }

    /// Whether `path` exists under `root`; a glob in its last part needs at least one match.
    static func exists(_ path: String, under root: URL) -> Bool {
        let url = root.appendingPathComponent(path)
        let name = url.lastPathComponent
        guard name.contains("*") else { return FileManager.default.fileExists(atPath: url.path) }
        let folder = url.deletingLastPathComponent().path
        return (try? FileManager.default.contentsOfDirectory(atPath: folder))?.contains { fnmatch(name, $0, 0) == 0 } ?? false
    }

    /// The paths `text` names that don't exist under `root`, each once, in order.
    static func missing(in text: String, under root: URL) -> [String] {
        var seen = Set<String>()
        return paths(in: text).filter { seen.insert($0).inserted && !exists($0, under: root) }
    }

    @Test func everyPathTheMapNamesExists() throws {
        let text = try String(contentsOf: Self.repo.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        let named = Self.paths(in: text)
        #expect(named.count > 40, "CLAUDE.md names only \(named.count) paths: the check isn't reading it")
        let missing = Self.missing(in: text, under: Self.repo)
        #expect(missing == [], """
            CLAUDE.md names paths that don't exist (moved or renamed?): fix the map, it's what every worker reads first:
            \(missing.joined(separator: "\n"))
            """)
    }

    @Test func theMapStaysShort() throws {
        let text = try String(contentsOf: Self.repo.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        let lines = text.components(separatedBy: "\n").count
        #expect(lines <= Self.lineLimit, "CLAUDE.md has \(lines) lines: keep it a map (point to docs/ instead of copying them)")
    }

    /// The check itself: a wrong path, folder or glob is named; real ones, `.build/…` and `~/…` aren't checked.
    @Test func aWrongPathIsNamed() {
        let text = """
            - Board: `Sources/VibeCore/LeadBoard.swift`, tests `Tests/VibeCoreTests/`, `Tests/Web/*.test.mjs`.
            - Gone: `Sources/VibeCore/NoSuchFile.swift` and `docs/nowhere/`, `Tests/Web/*.nothing`.
            - Not checked: .build/sandbox-shots/, ~/Library/Logs/DiagnosticReports, see README.md.
            """
        #expect(Self.paths(in: text) == [
            "Sources/VibeCore/LeadBoard.swift", "Tests/VibeCoreTests/", "Tests/Web/*.test.mjs",
            "Sources/VibeCore/NoSuchFile.swift", "docs/nowhere/", "Tests/Web/*.nothing", "README.md",
        ])
        #expect(Self.missing(in: text, under: Self.repo) == ["Sources/VibeCore/NoSuchFile.swift", "docs/nowhere/", "Tests/Web/*.nothing"])
    }
}
