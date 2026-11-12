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

    /// Each private name as two halves, matched with an optional "-", "_", "." or space between them: the list the
    /// lead's recording tools refuse too (`RecordLint`: one list, never a copy).
    static let names = RecordLint.privateNames

    static let pattern = RecordLint.privateNamesPattern

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

    // MARK: Email addresses

    /// Domains an address in code may use: the ones reserved for examples and tests (RFC 2606, RFC 6761), and their
    /// subdomains. Any other domain may be someone's real mailbox, as the user's own address once was, in a doc comment
    /// (2026-11-07).
    static let exampleDomains = ["example.com", "example.org", "example.net", "example", "invalid", "test", "localhost"]

    /// Deliberate exceptions, one per line ('#' starts a comment): an address that names no person.
    static let allowlist = URL(fileURLWithPath: "Tests/Fixtures/email-allowlist.txt", relativeTo: repo)

    /// An address, not inside a URL's user part ("https://me:token@host" is a credential's shape: SecretShapeLint's) nor
    /// glued to a longer word: nothing address-like or ':', '/' or '\' just before it, unless that's an escape such as
    /// the "\n" in a string literal, which is no part of the address that follows.
    static let email = try! NSRegularExpression(
        pattern: #"(?:(?<=\\[nrt0])|(?<![A-Za-z0-9._%+\-:/\\]))[A-Za-z0-9._%+\-]+@([A-Za-z0-9\-]+\.)+[A-Za-z]{2,}"#)

    static func allowed(in text: String) -> Set<String> {
        Set(text.split(separator: "\n").compactMap {
            let entry = $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            return entry.isEmpty ? nil : entry.lowercased()
        })
    }

    static func isExample(_ address: String) -> Bool {
        let domain = address.lowercased().split(separator: "@").last.map(String.init) ?? ""
        return exampleDomains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// "Sources/…/File.swift:12 (the address)" for each address under Sources/ or Tests/ of `root` whose domain
    /// isn't an example one and that `allowed` doesn't list, in order.
    static func emails(under root: URL, allowed: Set<String>) throws -> [String] {
        var found: [String] = []
        for file in try SecretShapeLintTests.files(under: root) where file.hasPrefix("Sources/") || file.hasPrefix("Tests/") {
            guard let data = FileManager.default.contents(atPath: root.appendingPathComponent(file).path),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
            for match in email.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let address = String(text[range])
                guard !isExample(address), !allowed.contains(address.lowercased()) else { continue }
                let line = text.utf16.prefix(match.range.location).count { $0 == 10 } + 1
                found.append("\(file):\(line) (\(address))")
            }
        }
        return found
    }

    @Test func noSourceOrTestNamesARealEmailAddress() throws {
        let allowed = Self.allowed(in: try String(contentsOf: Self.allowlist, encoding: .utf8))
        #expect(allowed.contains("git@github.com"))
        let found = try Self.emails(under: Self.repo, allowed: allowed)
        #expect(found == [], """
            these may be someone's real email address: use an example domain (someone@example.com, *.invalid, *.test), \
            or list a deliberate one in Tests/Fixtures/email-allowlist.txt:
            \(found.joined(separator: "\n"))
            """)
    }

    /// A real-looking address is found in a doc comment and a test; an example domain, a URL's user part, an allowed
    /// address and a file outside Sources/ and Tests/ are not.
    @Test func anAddressOnARealDomainIsFoundAndExamplesAreNot() throws {
        let root = temp.url("emails")
        for folder in ["Sources/Core", "Tests/CoreTests", "docs"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        #expect(Git.run(["init", "-q"], in: root.path).ok)
        let real = "someone" + "@" + "corp.dev", other = "Bo.B+x" + "@" + "mail.co.uk"
        try """
            /// An email masked: "\(real)" → "so•••@co•••.dev".
            let a = "alice@example.com", b = "bob@corp.test", c = "x@y.invalid", d = "z@sub.example.org"
            let url = "https://me:s3cret@github.com/x", remote = "git@github.com:o/r.git"
            """.write(to: root.appendingPathComponent("Sources/Core/Account.swift"), atomically: true, encoding: .utf8)
        try "login(\"\\n\(other)\")\n".write(to: root.appendingPathComponent("Tests/CoreTests/LoginTests.swift"),
                                          atomically: true, encoding: .utf8)
        try "Mail \(real)\n".write(to: root.appendingPathComponent("docs/notes.md"), atomically: true, encoding: .utf8)

        let allowed = Self.allowed(in: "# exceptions\ngit@github.com   # a remote\n\n")
        #expect(allowed == ["git@github.com"])
        #expect(try Self.emails(under: root, allowed: allowed)
            == ["Sources/Core/Account.swift:1 (\(real))", "Tests/CoreTests/LoginTests.swift:1 (\(other))"])
        #expect(try Self.emails(under: root, allowed: []).contains("Sources/Core/Account.swift:3 (git@github.com)"))
    }
}
