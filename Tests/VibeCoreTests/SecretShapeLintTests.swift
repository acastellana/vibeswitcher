import Foundation
import Testing
@testable import VibeCore

/// No text file in the repository (every one git has or would add: Sources, Tests, docs, scripts, Web, …) holds a
/// string shaped like a vendor's credential: a Slack or Discord webhook, a Slack, Stripe, AWS, Google, GitHub,
/// GitLab, SendGrid, npm, PyPI, Hugging Face, age, Anthropic or OpenAI key. GitHub push protection matches these
/// shapes in every commit pushed, whatever the string says (an EXAMPLE in it changes nothing), and refuses the push
/// until someone clicks to expose it. 2026-10-20 it refused project-lead twice for made-up redaction fixtures (a Slack
/// webhook, then a GitLab token). A fixture that must look real is assembled at run time ("gl" + "pat-" and a body
/// from a helper); a doc quotes a shape cut short (`glpat-AbCd…`). Comments count: GitHub scans them like the rest.
/// Nothing is allowed by name: a string that must keep the shape is split in its source, this file's own included.
struct SecretShapeLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let temp = Scratch()

    /// Close to the shapes GitHub's supported patterns list, and looser where that costs nothing (shorter minimum
    /// lengths, no checksums), so a string fails here before it reaches a push.
    static let shapes: [(name: String, pattern: NSRegularExpression)] = [
        ("Slack webhook", #"hooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9_-]+/[A-Za-z0-9_/-]+"#),
        ("Slack token", #"xox[abposr]-[A-Za-z0-9-]{10,}"#),
        ("Discord webhook", #"discord(?:app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+"#),
        ("Stripe key", #"[spr]k_(?:live|test)_[A-Za-z0-9]{10,}"#),
        ("AWS access key ID", #"(?:AKIA|ASIA)[0-9A-Z]{16}"#),
        // 40 characters of base64 with a lower case letter, a capital and a digit, standing alone: not a commit hash
        // (hex, one case) nor part of a longer run.
        ("AWS secret access key",
         #"(?<![A-Za-z0-9/+])(?=[A-Za-z0-9/+]{0,39}[a-z])(?=[A-Za-z0-9/+]{0,39}[A-Z])(?=[A-Za-z0-9/+]{0,39}[0-9])[A-Za-z0-9/+]{40}(?![A-Za-z0-9/+=])"#),
        ("Google API key", #"AIza[0-9A-Za-z_-]{30,}"#),
        ("GitHub token", #"gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}"#),
        ("GitLab token", #"glpat-[A-Za-z0-9_-]{20,}"#),
        ("SendGrid key", #"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#),
        ("npm token", #"npm_[A-Za-z0-9]{30,}"#),
        ("PyPI token", #"pypi-AgE[A-Za-z0-9_-]{16,}"#),
        ("Hugging Face token", #"hf_[A-Za-z0-9]{30,}"#),
        ("age secret key", #"AGE-SECRET-KEY-1[0-9A-Z]{20,}"#),
        ("Anthropic key", #"sk-ant-(?:api|admin)[0-9]{2}-[A-Za-z0-9_-]{80,}"#),
        ("OpenAI key", #"sk-[A-Za-z0-9_-]{16,}T3BlbkFJ[A-Za-z0-9_-]{16,}"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// The files under `root` a push could carry, relative to it: the ones git tracks and the new ones it doesn't
    /// ignore (not .build/, nor the worktrees under .vibeswitcher/ in the main checkout). Empty when git can't say.
    static func files(under root: URL) -> [String] {
        let listed = Git.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: root.path)
        guard listed.ok else { return [] }
        return Set(listed.output.split(separator: "\0").map(String.init)).filter { !$0.hasSuffix("/") }.sorted()
    }

    /// "docs/…/file.md:12 (GitLab token)" for each shape on each line of the text files under `root`, in order. Each
    /// pattern searches a whole file with ICU (Swift's Regex, a line at a time, took 6 s over the repository); no shape
    /// crosses a line.
    static func matches(under root: URL) -> [String] {
        var found: [String] = []
        for file in files(under: root) {
            guard let data = FileManager.default.contents(atPath: root.appendingPathComponent(file).path),
                  let text = String(data: data, encoding: .utf8) else { continue }
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

    @Test func noFileHoldsACredentialsShape() {
        // The listing works here, so an empty result means clean, not unread.
        let files = Self.files(under: Self.repo)
        #expect(files.contains("docs/eval/security.md"))
        #expect(files.contains("Tests/VibeCoreTests/RedactionAgreementTests.swift"))
        let found = Self.matches(under: Self.repo)
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

        #expect(Self.matches(under: root) == ["Notes.swift:1 (Stripe key)"]
            + samples.enumerated().map { "Tests/VibeCoreTests/FixtureTests.swift:\($0.offset + 2) (\($0.element.name))" }
            + ["docs/security.md:3 (GitLab token)"])
    }
}
