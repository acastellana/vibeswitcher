import Foundation
import Testing
@testable import VibeCore

/// No file in the repository (every one git has or would add, docs/lead/ included) names the user's other projects:
/// the repository is public, and they aren't. 2026-10-28 they were scrubbed from code comments, test fixtures, docs
/// and the lead's records, each replaced by a stand-in ('project-b', 'project-c'); a mention that comes back fails
/// here, in any case and with or without a separator between its halves. The names are assembled so this file passes
/// its own check. Git history still holds them: only a rewrite and a force-push would take them out.
struct PrivateNamesLintTests {
    static let repo = SecretShapeLintTests.repo
    let temp = Scratch()

    /// Each private name as two halves, matched with an optional "-", "_", "." or space between them.
    static let names: [(String, String)] = [("stake", "gen"), ("gen", "swap")]

    static let pattern = try! NSRegularExpression(
        pattern: names.map { "\($0.0)[-_. ]?\($0.1)" }.joined(separator: "|"), options: [.caseInsensitive])

    /// "docs/…/file.md:12" for each line naming one, in order. A file that isn't UTF-8 is read as Latin-1, as
    /// SecretShapeLintTests does, so a name in it is still found.
    static func matches(under root: URL) throws -> [String] {
        var found: [String] = []
        for file in try SecretShapeLintTests.files(under: root) {
            guard let data = FileManager.default.contents(atPath: root.appendingPathComponent(file).path),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
            let lines = Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                text.utf16.prefix($0.range.location).count { $0 == 10 } + 1
            })
            found += lines.sorted().map { "\(file):\($0)" }
        }
        return found
    }

    @Test func noFileNamesTheUsersOtherProjects() throws {
        let files = try SecretShapeLintTests.files(under: Self.repo)
        #expect(files.contains("docs/lead/progress.md"))
        let found = try Self.matches(under: Self.repo)
        #expect(found == [], """
            these name the user's other projects in a public repository: write 'project-b' or 'project-c' instead:
            \(found.joined(separator: "\n"))
            """)
    }

    /// A name is found in any case and spelling, in a doc and in an untracked file; a folder git ignores isn't read.
    @Test func aNameIsFoundInAnyCaseAndAnIgnoredFolderIsNot() throws {
        let root = temp.url("lint")
        for folder in ["docs/lead", ".build"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        #expect(Git.run(["init", "-q"], in: root.path).ok)
        let (b, c) = (Self.names[0].0 + Self.names[0].1, Self.names[1].0 + Self.names[1].1)
        try "# Progress\n\n- \(b.uppercased()) merged\n- the stand-in project-c\n- ~/dev/\(c)/.vibeswitcher\n"
            .write(to: root.appendingPathComponent("docs/lead/progress.md"), atomically: true, encoding: .utf8)
        try "// \(Self.names[1].0.capitalized)-\(Self.names[1].1.capitalized) logs\n"
            .write(to: root.appendingPathComponent("Notes.swift"), atomically: true, encoding: .utf8)
        try ".build/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try b.write(to: root.appendingPathComponent(".build/Built.swift"), atomically: true, encoding: .utf8)

        #expect(try Self.matches(under: root) == ["Notes.swift:1", "docs/lead/progress.md:3", "docs/lead/progress.md:5"])
    }
}
