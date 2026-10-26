import Foundation
import Testing

/// AGENTS.md at the repository's root holds the few rules and commands an agent can't find out from the repository;
/// CLAUDE.md only imports it (`@AGENTS.md`), since Claude Code reads CLAUDE.md and Codex reads AGENTS.md. A file or
/// script it names that was moved or renamed sends agents to run something that isn't there, so every path it names
/// must exist, every lint its filter names must be a test, and it stays short: a map of the repository costs every
/// session context and doesn't help agents find files.
struct ProjectMapTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let lineLimit = 40

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

    /// The names in each `--filter 'A|B'` of `text` (quoted, with alternatives), in order.
    static func filterNames(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"--filter '([^']+)'"#)
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
            .flatMap { $0.split(separator: "|").map(String.init) }
    }

    /// The test types (`struct …Tests`) declared under `Tests/`.
    static func testTypes() throws -> [String] {
        let tests = repo.appendingPathComponent("Tests")
        let declaration = try NSRegularExpression(pattern: #"(?m)^(?:final )?(?:struct|class) (\w+Tests)\b"#)
        var types: [String] = []
        for case let file as URL in FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)! where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            types += declaration.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
        }
        return types
    }

    static func agents() throws -> String {
        try String(contentsOf: repo.appendingPathComponent("AGENTS.md"), encoding: .utf8)
    }

    @Test func everyPathAgentsNamesExists() throws {
        let text = try Self.agents()
        let named = Self.paths(in: text)
        #expect(named.count >= 5, "AGENTS.md names only \(named.count) paths: the check isn't reading it")
        let missing = Self.missing(in: text, under: Self.repo)
        #expect(missing == [], """
            AGENTS.md names paths that don't exist (moved or renamed?): fix it, every agent's session starts with it:
            \(missing.joined(separator: "\n"))
            """)
    }

    @Test func everyLintAgentsNamesIsATest() throws {
        let names = Self.filterNames(in: try Self.agents())
        #expect(names.count >= 5, "AGENTS.md's lint filter names only \(names.count) tests: the check isn't reading it")
        let types = try Self.testTypes()
        let unknown = names.filter { name in !types.contains { $0.contains(name) } }
        #expect(unknown == [], "AGENTS.md's --filter names no test type (renamed?): \(unknown.joined(separator: ", "))")
    }

    @Test func agentsStaysShort() throws {
        let lines = try Self.agents().components(separatedBy: "\n").count
        #expect(lines <= Self.lineLimit, """
            AGENTS.md has \(lines) lines: keep only what an agent can't find out from the repository \
            (a rule for a repeated mistake, a command), not a map of it
            """)
    }

    /// Claude Code reads CLAUDE.md, not AGENTS.md beside it: CLAUDE.md imports AGENTS.md and holds nothing else.
    @Test func claudeImportsAgents() throws {
        let text = try String(contentsOf: Self.repo.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "@AGENTS.md")
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

    /// The lint check itself: the names of a quoted filter are read, alternatives split.
    @Test func aFiltersNamesAreRead() {
        let text = "bash scripts/test.sh --filter 'KeychainLint|NoSuchLint'\nbash scripts/test.sh --filter LeadBoardTests"
        #expect(Self.filterNames(in: text) == ["KeychainLint", "NoSuchLint"])
    }
}
