import Foundation
import Testing
@testable import VibeCore

/// redact_record: the lead replaces one line of its records that a lint fails on, and the records commit, which
/// otherwise refuses any change to an existing line ("records only ever grow"), carries exactly that change, naming it
/// in its message. On 2026-11-12 the user's hand fix of a progress.md line naming another project could never be
/// committed, and every later record was stuck behind it.
@Suite(.serialized)
struct LeadRedactionTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    static let privateName = LeadRecordTextTests.privateName

    func repo(lints: Bool = true) throws -> String {
        let url = temp.url("redact")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let root = url.resolvingSymlinksInPath().path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"]] { Git.run(args, in: root) }
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        Git.run(["add", "a.txt"], in: root)
        // The repository carries the two lints (as this one does), so its records are held to them.
        if lints {
            try FileManager.default.createDirectory(atPath: root + "/Tests/CoreTests", withIntermediateDirectories: true)
            for name in ["PrivateNamesLintTests.swift", "SecretShapeLintTests.swift"] {
                try "// the lint\n".write(toFile: root + "/Tests/CoreTests/" + name, atomically: true, encoding: .utf8)
                Git.run(["add", "Tests/CoreTests/" + name], in: root)
            }
        }
        Git.run(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    func committed(_ root: String, _ file: String = "docs/lead/progress.md") -> String {
        Git.run(["show", "main:\(file)"], in: root).output
    }

    /// progress.md on main with a line PrivateNamesLint fails on, as a dismiss_finding reason put it there before the
    /// tools linted their text: written past the tools, as it was then.
    func badLine(_ lead: LeadToolset, _ root: String) throws -> String {
        try lead.store.appendProgress("Dismissed F2 on add-b: it was \(Self.privateName)'s parser")
        try lead.store.appendProgress("Planned add-c")
        guard case .committed = lead.records.flush(base: "main") else { throw Failed("not committed") }
        let line = try #require(committed(root).components(separatedBy: "\n").first { $0.contains(Self.privateName) })
        #expect(!RecordLint.problems(in: line).isEmpty)
        return line
    }

    struct Failed: Error { var text: String; init(_ text: String) { self.text = text } }

    /// The user fixed the line by hand: the records commit refuses it (a line the base has would be lost), until
    /// redact_record names the fix; then it lands, with the redaction in its message and nothing else changed.
    @Test func aHandFixOfALintedLineIsCommittedOnceRedacted() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        let bad = try badLine(lead, root)
        let path = root + "/docs/lead/progress.md"
        let fixed = bad.replacingOccurrences(of: Self.privateName, with: "project-b")
        try (try String(contentsOfFile: path, encoding: .utf8)).replacingOccurrences(of: bad, with: fixed)
            .write(toFile: path, atomically: true, encoding: .utf8)
        try lead.store.appendProgress("Merged add-c")
        let before = Git.run(["rev-parse", "main"], in: root).output
        // As on 2026-11-12: stuck behind the fix.
        guard case .failed(let why) = lead.records.flush(base: "main") else { Issue.record("committed without a redaction"); return }
        #expect(why.contains("would lose 1 line"), "\(why)")
        #expect(Git.run(["rev-parse", "main"], in: root).output == before)

        // The lead names the fix, by a part of the old line.
        let result = lead.call("redact_record", ["file": "progress.md", "line": "it was \(Self.privateName)", "text": fixed])
        #expect(!result.isError, "\(result.text)")
        #expect(result.text.contains("corrected already") && result.text.contains("Committed to main"), "\(result.text)")
        let text = committed(root)
        #expect(!text.contains(Self.privateName))
        #expect(text.contains(fixed) && text.contains("Merged add-c") && text.contains("Planned add-c"))
        let message = Git.run(["log", "-1", "--format=%B", "main"], in: root).output
        #expect(message.contains("Redacted by the lead (redact_record)"), "\(message)")
        #expect(message.contains("docs/lead/progress.md: one line replaced with “\(fixed)” to clear PrivateNamesLint"), "\(message)")
        #expect(RecordLint.problems(in: message).isEmpty)
        // Only the records changed, and the redaction is no longer pending.
        #expect(Git.run(["diff", "--name-only", before, "main"], in: root).output == "docs/lead/progress.md")
        #expect(LeadRedaction.pending(lead.store).isEmpty)
        #expect(PrivateNamesLintTests.pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil)
    }

    /// The line still in the working file: redact_record replaces it there and the commit carries it. Any other
    /// change to an existing line is still refused.
    @Test func theLineIsReplacedAndOnlyThatChangeIsAccepted() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        let bad = try badLine(lead, root)
        // Another line changed too, by hand: that one isn't a redaction, and the commit stays refused.
        let path = root + "/docs/lead/progress.md"
        let planned = try #require(committed(root).components(separatedBy: "\n").first { $0.contains("Planned add-c") })
        try (try String(contentsOfFile: path, encoding: .utf8)).replacingOccurrences(of: planned, with: planned + " (edited)")
            .write(toFile: path, atomically: true, encoding: .utf8)
        let result = lead.call("redact_record", ["file": "docs/lead/progress.md", "line": bad, "text": "- Dismissed F2 on add-b: it was project-b's parser"])
        #expect(!result.isError, "\(result.text)")
        #expect(result.text.contains("Replaced the line") && result.text.contains("Not committed yet"), "\(result.text)")
        #expect(committed(root).contains(Self.privateName))
        #expect(!LeadRedaction.pending(lead.store).isEmpty)

        // The hand edit undone: the redaction alone lands.
        try (try String(contentsOfFile: path, encoding: .utf8)).replacingOccurrences(of: planned + " (edited)", with: planned)
            .write(toFile: path, atomically: true, encoding: .utf8)
        guard case .committed = lead.records.flush(base: "main") else { Issue.record("the redaction didn't land"); return }
        #expect(!committed(root).contains(Self.privateName))
        #expect(committed(root).contains("- Dismissed F2 on add-b: it was project-b's parser"))
        #expect(LeadRedaction.pending(lead.store).isEmpty)
    }

    /// Only to clear a lint, with text that passes it, naming one line.
    @Test func whatRedactRecordRefuses() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        _ = try badLine(lead, root)
        let progress = try String(contentsOfFile: root + "/docs/lead/progress.md", encoding: .utf8)
        let cases: [([String: Any], String)] = [
            (["file": "progress.md", "line": "Planned add-c", "text": "- Planned add-d"], "passes PrivateNamesLint and SecretShapeLint"),
            (["file": "progress.md", "line": Self.privateName, "text": "- it was \(Self.privateName) again"], "fails the lints too"),
            (["file": "progress.md", "line": Self.privateName, "text": "two\nlines"], "one line"),
            (["file": "progress.md", "line": "nowhere at all", "text": "- fine"], "no line of docs/lead/progress.md holds that text"),
            (["file": "progress.md", "line": "add-", "text": "- fine"], "lines of docs/lead/progress.md hold that text"),
            (["file": "../a.txt", "line": "one", "text": "two"], "isn't one of the lead's records"),
        ]
        for (arguments, says) in cases {
            let result = lead.call("redact_record", arguments)
            #expect(result.isError && result.text.contains(says), "\(arguments): \(result.text)")
        }
        #expect(try String(contentsOfFile: root + "/docs/lead/progress.md", encoding: .utf8) == progress)
        #expect(LeadRedaction.pending(lead.store).isEmpty)
    }
}
