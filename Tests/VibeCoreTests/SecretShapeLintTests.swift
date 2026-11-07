import Foundation
import Testing
@testable import VibeCore

/// No text file in the repository (every one git has or would add: Sources, Tests, docs, scripts, Web, …) holds a
/// string shaped like a vendor's credential: a Slack or Discord webhook, a Slack, Stripe, AWS, Google, GitHub,
/// GitLab, SendGrid, npm, PyPI, Hugging Face, age, Anthropic or OpenAI key, or a private key's header and first body
/// line. GitHub push protection matches these
/// shapes in every commit pushed, whatever the string says (an EXAMPLE in it changes nothing), and refuses the push
/// until someone clicks to expose it. 2026-10-20 it refused project-lead twice for made-up redaction fixtures (a Slack
/// webhook, then a GitLab token). A fixture that must look real is assembled at run time ("gl" + "pat-" and a body
/// from a helper); a doc quotes a shape cut short (`glpat-AbCd…`). Comments count: GitHub scans them like the rest.
/// Nothing is allowed by name: a string that must keep the shape is split in its source, this file's own included.
struct SecretShapeLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let temp = Scratch()

    /// The shapes, as `tell_lead` refuses them too (`SecretShapes`: one list, never a copy).
    static let shapes = SecretShapes.shapes

    /// git couldn't list the files: what it said, so the failure names the cause rather than a missing file.
    struct ListingFailed: Error, CustomStringConvertible {
        var description: String
    }

    /// The files under `root` a push could carry, relative to it: the ones git tracks and the new ones it doesn't
    /// ignore (not .build/, nor the worktrees under .vibeswitcher/ in the main checkout). Throws, with git's error,
    /// when git can't say.
    static func files(under root: URL) throws -> [String] {
        let listed = Git.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: root.path)
        guard listed.ok else {
            let said = listed.error.isEmpty ? (listed.timedOut ? "timed out" : "exit \(listed.status)") : listed.error
            throw ListingFailed(description: "git ls-files can't list the files in \(root.path): \(said)")
        }
        return Set(listed.output.split(separator: "\0").map(String.init)).filter { !$0.hasSuffix("/") }.sorted()
    }

    /// "docs/…/file.md:12 (GitLab token)" for each shape on each line of the files under `root`, in order. Each
    /// pattern searches a whole file with ICU (Swift's Regex, a line at a time, took 6 s over the repository); no shape
    /// crosses a line. A file that isn't UTF-8 (an image, a capture in another encoding) is read as Latin-1, a
    /// character a byte: every shape is ASCII, so it's found there as in text, and no file is passed over.
    static func matches(under root: URL) throws -> [String] {
        var found: [String] = []
        for file in try files(under: root) {
            guard let data = FileManager.default.contents(atPath: root.appendingPathComponent(file).path),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
            var places: Set<[Int]> = []
            for (shape, (_, pattern)) in shapes.enumerated() {
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    let line = text.utf16.prefix(match.range.location).count { $0 == 10 } + 1
                    places.insert([line, shape])
                }
            }
            found += places.sorted { $0.lexicographicallyPrecedes($1) }.map { "\(file):\($0[0]) (\(shapes[$0[1]].name))" }
        }
        return found
    }

    @Test func noFileHoldsACredentialsShape() throws {
        // The listing works here, so an empty result means clean, not unread.
        let files = try Self.files(under: Self.repo)
        #expect(files.contains("docs/eval/security.md"))
        #expect(files.contains("Tests/VibeCoreTests/RedactionAgreementTests.swift"))
        let found = try Self.matches(under: Self.repo)
        #expect(found == [], """
            these look like real credentials, and GitHub push protection refuses a push carrying them: assemble the \
            string at run time ("gl" + "pat-" and a body from a helper), or quote it cut short in a doc (`glpat-AbCd…`):
            \(found.joined(separator: "\n"))
            """)
    }

    /// Every shape is named with its file and line, in a doc and a comment too, and in a new file git doesn't track
    /// yet; the same strings assembled in source aren't, nor one in a folder git ignores.
    @Test func aLiteralIsNamedWithItsLineAndAnAssembledStringIsNot() throws {
        let root = temp.url("lint")
        for folder in ["Tests/VibeCoreTests", "docs", ".build"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        #expect(Git.run(["init", "-q"], in: root.path).ok)
        func run(_ count: Int) -> String {
            String(String(repeating: "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789", count: 4).prefix(count))
        }
        // name, the literal a file would hold, the same split as source assembles it
        let samples: [(name: String, literal: String, assembled: String)] = [
            ("Slack webhook", "https://hooks.slack" + ".com/services/T0123ABCD/B0456EFGH/" + run(24), "https://hooks.slack.com/\" + \"services/T0123ABCD/B0456EFGH/"),
            ("Slack token", "xo" + "xb-1234567890-" + run(24), "xo\" + \"xb-1234567890-" + run(24)),
            ("Discord webhook", "https://discord" + ".com/api/webhooks/123456789012345678/" + run(36), "https://discord.com/api/webhooks/\" + \"123456789012345678/"),
            ("Stripe key", "sk" + "_live_" + run(24), "sk_live_\" + \"" + run(24)),
            ("AWS access key ID", "AK" + "IAIOSFODNN7EXAMPLE", "AKIA\" + \"IOSFODNN7EXAMPLE"),
            ("AWS secret access key", "wJalrXUtnFEMI/K7MDENG/" + "bPxRfiCYEXAMPLEKEY", "wJalrXUtnFEMI/K7MDENG/\" + \"bPxRfiCYEXAMPLEKEY"),
            ("Google API key", "AI" + "za" + run(35), "AIza\" + \"" + run(35)),
            ("GitHub token", "gh" + "p_" + run(36), "ghp_\" + \"" + run(36)),
            ("GitLab token", "gl" + "pat-" + run(20), "gl\" + \"pat-" + run(20)),
            ("SendGrid key", "SG" + "." + run(22) + "." + run(43), "SG\" + \"." + run(22) + "." + run(43)),
            ("npm token", "np" + "m_" + run(36), "npm_\" + \"" + run(36)),
            ("PyPI token", "py" + "pi-AgE" + run(50), "pypi-\" + \"AgE" + run(50)),
            ("Hugging Face token", "h" + "f_" + run(34), "hf_\" + \"" + run(34)),
            ("age secret key", "AGE-SECRET-" + "KEY-1" + run(58).uppercased(), "AGE-SECRET-KEY-\" + \"1" + run(58).uppercased()),
            ("Anthropic key", "sk-" + "ant-api03-" + run(93) + "AA", "sk-ant-api03-\" + \"" + run(93) + "AA"),
            ("OpenAI key", "sk-" + "proj-" + run(20) + "T3Blbk" + "FJ" + run(20), "sk-proj-" + run(20) + "\" + \"T3BlbkFJ" + run(20)),
            ("Private key", "-----BEGIN RSA " + "PRIVATE KEY-----\\n" + run(64), "-----BEGIN RSA \" + \"PRIVATE KEY-----\\n" + run(64)),
        ]
        let literals = samples.map { "let \($0.name.filter(\.isLetter)) = \"\($0.literal)\"" }
        try (["import Foundation"] + literals).joined(separator: "\n")
            .write(to: root.appendingPathComponent("Tests/VibeCoreTests/FixtureTests.swift"), atomically: true, encoding: .utf8)
        try (["// Assembled: nothing here is a whole shape."] + samples.map { "let \($0.name.filter(\.isLetter)) = \"\($0.assembled)\"" })
            .joined(separator: "\n").write(to: root.appendingPathComponent("Tests/VibeCoreTests/AssembledTests.swift"), atomically: true, encoding: .utf8)
        try "# Leaks\n\n| `\(samples[8].literal)` (GitLab) | masked |\n"
            .write(to: root.appendingPathComponent("docs/security.md"), atomically: true, encoding: .utf8)
        try "    // a comment quoting \(samples[3].literal)\n".write(to: root.appendingPathComponent("Notes.swift"), atomically: true, encoding: .utf8)
        try ".build/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try literals.joined(separator: "\n").write(to: root.appendingPathComponent(".build/Built.swift"), atomically: true, encoding: .utf8)

        #expect(try Self.matches(under: root) == ["Notes.swift:1 (Stripe key)"]
            + samples.enumerated().map { "Tests/VibeCoreTests/FixtureTests.swift:\($0.offset + 2) (\($0.element.name))" }
            + ["docs/security.md:3 (GitLab token)"])
    }

    /// A file whose bytes aren't UTF-8 (a Latin-1 note, binary around a string) is read a byte a character, not passed
    /// over: its shape is named with its line like any other.
    @Test func aFileThatIsntUTF8IsReadAsLatin1() throws {
        let root = temp.url("lint")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(Git.run(["init", "-q"], in: root.path).ok)
        let token = "gl" + "pat-" + String(repeating: "AbCd0123", count: 3)
        // "café" in Latin-1 (0xE9 alone is no UTF-8), then bytes no decoder takes, then the token.
        var bytes = Data("caf".utf8) + Data([0xE9, 0x0A, 0xFF, 0xFE, 0xC0, 0x0A])
        bytes += Data("token = \(token)\n".utf8)
        try bytes.write(to: root.appendingPathComponent("Legacy.txt"))
        #expect(String(data: bytes, encoding: .utf8) == nil)
        #expect(try Self.matches(under: root) == ["Legacy.txt:3 (GitLab token)"])
    }

    /// A private key is its header and a whole body line under it, indented or not, in a key file as in a string
    /// literal's `\n`; a header over a body cut short (as the redaction fixtures quote one) or alone is no key.
    @Test func aPrivateKeyIsItsHeaderAndABodyLine() throws {
        let root = temp.url("lint")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(Git.run(["init", "-q"], in: root.path).ok)
        let body = String(String(repeating: "AbCdEfGh0123+/", count: 6).prefix(64))
        let begin = "-----BEGIN OPENSSH " + "PRIVATE KEY-----"
        try "notes\n\(begin)\n\(body)\n\(body)\n-----END OPENSSH PRIVATE KEY-----\n"
            .write(to: root.appendingPathComponent("id_test"), atomically: true, encoding: .utf8)
        try ("-----BEGIN PGP " + "PRIVATE KEY BLOCK-----\r\n\r\n\(body)\r\n")
            .write(to: root.appendingPathComponent("armored.asc"), atomically: true, encoding: .utf8)
        // In a multi-line literal or YAML the body is indented.
        try "key: |\n  \(begin)\n  \(body)\n".write(to: root.appendingPathComponent("config.yml"), atomically: true, encoding: .utf8)
        try "let short = \"\(begin)\\nb3BlbnNzaC1rZXktdjE\\n-----END\"\nlet bare = \"\(begin)\"\n"
            .write(to: root.appendingPathComponent("Fixture.swift"), atomically: true, encoding: .utf8)
        #expect(try Self.matches(under: root) == ["armored.asc:1 (Private key)", "config.yml:2 (Private key)", "id_test:2 (Private key)"])
    }

    /// When git can't list the files the lint fails saying what git said, not with an expectation about a file it
    /// never got to read.
    @Test func aListingGitRefusesFailsWithGitsError() throws {
        let root = temp.url("lint")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Not a repository: git ls-files refuses.
        let refused = Git.run(["ls-files"], in: root.path)
        #expect(!refused.ok && refused.error.contains("not a git repository"))
        let error = try #require(throws: ListingFailed.self) { try Self.files(under: root) }
        #expect(error.description.contains(refused.error), "\(error)")
        #expect(throws: ListingFailed.self) { try Self.matches(under: root) }
    }
}
