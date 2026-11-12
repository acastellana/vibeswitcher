import Foundation
import Testing
@testable import VibeCore

/// The lead's recording tools run the repository's text lints that read docs/lead/ (PrivateNamesLint's names,
/// SecretShapeLint's shapes) on their text before anything is recorded (`RecordLint`), and refuse it saying what
/// matched. On 2026-11-12 a dismiss_finding reason naming another project held every merge for hours.
@Suite(.serialized)
struct LeadRecordTextTests: LeadTeamFixture {
    let temp = Scratch()
    let vault: LeadVault
    init() { vault = Self.newVault(in: temp) }

    /// One of the user's other projects' names, assembled (this file passes PrivateNamesLint).
    static let privateName = RecordLint.privateNames[0].0.capitalized + RecordLint.privateNames[0].1.capitalized
    /// A GitLab token's shape, assembled (this file passes SecretShapeLint).
    static let secret = "gl" + "pat-" + String(repeating: "Ab1", count: 8)

    func repo(lints: Bool = true) throws -> String {
        let url = temp.url(lints ? "lint-repo" : "plain-repo")
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

    /// Every file under docs/lead and .vibeswitcher's logs, joined: what the records hold.
    func recorded(_ root: String) -> String {
        var text = ""
        for folder in ["docs/lead", ".vibeswitcher"] {
            let path = root + "/" + folder
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] where name.hasSuffix(".md") || name == "board.json" {
                text += (try? String(contentsOfFile: path + "/" + name, encoding: .utf8)) ?? ""
            }
        }
        return text
    }

    @Test func theLintsFindANameInAnySpellingAndASecretsShape() {
        let (a, b) = RecordLint.privateNames[1]
        #expect(RecordLint.problems(in: "nothing private here, project-b and project-c").isEmpty)
        for spelling in ["\(a)\(b)", "\(a.uppercased())-\(b)", "\(a) \(b.capitalized)", "~/dev/\(a)_\(b)/x"] {
            let found = RecordLint.problems(in: spelling)
            #expect(found.count == 1 && found[0].hasPrefix("PrivateNamesLint"), "\(spelling)")
            // The refusal doesn't carry the name whole.
            #expect(RecordLint.privateNamesPattern.firstMatch(in: found[0], range: NSRange(found[0].startIndex..., in: found[0])) == nil)
        }
        let shape = RecordLint.problems(in: "token \(Self.secret)")
        #expect(shape == ["SecretShapeLint: it holds a string shaped like a GitLab token; quote it cut short (`glpat-AbCd…`) or leave it out"])
        // Nested arguments are read too: a list in a contract.
        #expect(RecordLint.refusal(tool: "add_task", arguments: ["contract": ["acceptance": ["fine", "in \(Self.privateName)"]]]) != nil)
        #expect(RecordLint.refusal(tool: "add_task", arguments: ["title": "fine", "contract": ["goal": "fine"]]) == nil)
    }

    /// Each lead tool that records text refuses a private name and a secret's shape, saying what matched, and records
    /// nothing; the same call without it goes through.
    @Test func eachRecordingToolRefusesWhatTheLintsFailOn() throws {
        let root = try repo()
        let lead = try lead(root, FakeRuntime())
        #expect(!lead.call("add_task", ["title": "Add b", "goal": "b exists", "acceptance": ["b.txt exists"]]).isError)
        let calls: [(String, (String) -> [String: Any])] = [
            ("record_decision", { ["decision": "Keep \($0)", "why": "w"] }),
            ("dismiss_finding", { ["task": "add-b", "finding": "F1", "reason": "it was \($0)'s"] }),
            ("record_incident", { ["what": "Broke in \($0)", "evidence": "the log"] }),
            ("add_task", { ["title": "Port from \($0)", "goal": "g", "acceptance": ["a"]] }),
            ("update_task", { ["task": "add-b", "context": "as in \($0)"] }),
            ("post_update", { ["title": "Plan", "body": "Next: \($0)"] }),
        ]
        for (tool, arguments) in calls {
            for (bad, lint) in [(Self.privateName, "PrivateNamesLint"), (Self.secret, "SecretShapeLint")] {
                let before = recorded(root)
                let result = lead.call(tool, arguments(bad))
                #expect(result.isError, "\(tool)")
                #expect(result.text.hasPrefix("Refused, nothing recorded: \(tool)'s text"), "\(tool): \(result.text)")
                #expect(result.text.contains(lint), "\(tool): \(result.text)")
                #expect(recorded(root) == before, "\(tool) recorded something")
                #expect(!recorded(root).contains(bad))
            }
        }
        // Without it, the same tools record.
        #expect(!lead.call("record_decision", ["decision": "Keep project-b out", "why": "w"]).isError)
        #expect(recorded(root).contains("Keep project-b out"))
    }

    /// The lints are this repository's: a project that doesn't carry them (another project's own repository, whose
    /// records name it) refuses nothing, and redact_record has nothing to clear there.
    @Test func aRepositoryWithoutTheLintsRefusesNothing() throws {
        let root = try repo(lints: false)
        #expect(RecordLint.carried(root: root).isEmpty)
        let lead = try lead(root, FakeRuntime())
        #expect(!lead.call("record_decision", ["decision": "Release \(Self.privateName) v2", "why": "w"]).isError)
        #expect(recorded(root).contains("Release \(Self.privateName) v2"))
        let redact = lead.call("redact_record", ["file": "decisions.md", "line": Self.privateName, "text": "Release it"])
        #expect(redact.isError && redact.text.contains("carries neither"), "\(redact.text)")
        // One that carries them: both found, wherever their files are.
        #expect(RecordLint.carried(root: try repo()) == .all)
    }

    /// A worker's progress line is refused the same way, and one without it is noted.
    @Test func aWorkersProgressLineIsLintedToo() throws {
        let root = try repo()
        let runtime = FakeRuntime()
        let lead = try lead(root, runtime)
        #expect(!lead.call("add_task", ["title": "Add b", "goal": "b exists", "acceptance": ["b.txt exists"]]).isError)
        let worker = try issued(.worker, task: "add-b", root: root, runtime)
        let refused = worker.call("progress", ["text": "ported the \(Self.privateName) parser"])
        #expect(refused.isError)
        #expect(refused.text.contains("PrivateNamesLint"), "\(refused.text)")
        #expect(BoardStore(root: root).load().task("add-b")?.checkpoints?.isEmpty ?? true)
        let secret = worker.call("progress", ["text": "used \(Self.secret)"])
        #expect(secret.isError && secret.text.contains("SecretShapeLint"), "\(secret.text)")
        let fine = worker.call("progress", ["text": "parser ported"])
        #expect(!fine.isError, "\(fine.text)")
        #expect(BoardStore(root: root).load().task("add-b")?.checkpoints?.last?.text == "parser ported")
    }
}
