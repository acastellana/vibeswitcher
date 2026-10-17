import Foundation
import Testing
@testable import VibeCore

struct LeadWorkflowTests {
    @Test func frontMatterSetsTheLimitsAndTheRestIsNotes() {
        let workflow = LeadWorkflow.parse("---\nmax_workers: 2\ntest_command: swift test\ninit_command: \"swift build\"\nverifier_model: sonnet\n---\nPrefer small PRs.")
        #expect(workflow.maxWorkers == 2)
        #expect(workflow.testCommand == "swift test")
        #expect(workflow.initCommand == "swift build")
        #expect(workflow.verifierModel == "sonnet")
        #expect(workflow.notes == "Prefer small PRs.")
    }

    @Test func defaultsAndTheTemplate() {
        let empty = LeadWorkflow.parse("")
        #expect(empty.maxWorkers == 3)
        #expect(empty.testCommand == nil)
        #expect(LeadWorkflow.parse(LeadWorkflow.template).maxWorkers == 3)
        #expect(LeadWorkflow.parse("---\nmax_workers: 0\n---").maxWorkers == 1)
    }

    // MARK: Reading what's on disk (E-04)

    func file(_ bytes: Data) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-\(UUID().uuidString).md").path
        try bytes.write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test func crlfABOMAndAStrayByteStillGiveTheTestCommand() throws {
        let lf = "---\nmax_workers: 2\ntest_command: swift test\nbase_branch: dev\n---\nNotes."
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        for (name, data) in [("LF", Data(lf.utf8)), ("CRLF", Data(crlf.utf8)), ("BOM", Data([0xEF, 0xBB, 0xBF]) + Data(lf.utf8)),
                             ("BOM+CRLF", Data([0xEF, 0xBB, 0xBF]) + Data(crlf.utf8)),
                             ("Latin-1 byte in the notes", Data((lf + " caf").utf8) + Data([0xE9]) + Data(".".utf8))] {
            let workflow = LeadWorkflow.load(from: try file(data))
            #expect(workflow.testCommand == "swift test", "\(name)")
            #expect(workflow.maxWorkers == 2, "\(name)")
            #expect(workflow.baseBranch == "dev", "\(name)")
            #expect(workflow.problem == nil, "\(name)")
            #expect(workflow.notes.hasPrefix("Notes."), "\(name)")
        }
        #expect(LeadWorkflow.parse(crlf).notes == "Notes.")
    }

    @Test func aFileWhoseSettingsCantBeReadSaysSo() throws {
        #expect(LeadWorkflow.load(from: "/nonexistent/workflow.md").problem?.contains("no workflow.md") == true)
        let noFrontMatter = LeadWorkflow.load(from: try file(Data("test_command: swift test\nNotes".utf8)))
        #expect(noFrontMatter.testCommand == nil)
        #expect(noFrontMatter.problem?.contains("front matter") == true)
        let unclosed = LeadWorkflow.parse("---\ntest_command: swift test\n")
        #expect(unclosed.testCommand == nil && unclosed.problem != nil)
        #expect(LeadWorkflow.parse("").problem == nil)
        #expect(LeadWorkflow.parse(LeadWorkflow.template).problem == nil)
    }

    @Test func commentsAreNotSettings() {
        let workflow = LeadWorkflow.parse("---\n# test_command: make lint\n# Who works: codex\nworker_agent: claude\n---")
        #expect(workflow.testCommand == nil)
        #expect(workflow.workerAgent == "claude")
    }

    // MARK: Changing settings

    @Test func updatingKeepsCommentsUnknownKeysAndNotes() {
        let original = LeadWorkflow.template.replacingOccurrences(of: "max_workers: 3", with: "max_workers: 3\ncustom_key: keep me")
            + "\n\n# A heading in the notes\ntest_command: not a setting, just notes\n"
        let updated = LeadWorkflow.updating(original, with: [("test_command", "swift build && swift test"), ("max_workers", "4")])
        let workflow = LeadWorkflow.parse(updated)
        #expect(workflow.testCommand == "swift build && swift test")
        #expect(workflow.maxWorkers == 4)
        // Only those two lines changed.
        let before = original.components(separatedBy: "\n"), after = updated.components(separatedBy: "\n")
        #expect(before.count == after.count)
        #expect(zip(before, after).filter { $0 != $1 }.map(\.1) == ["max_workers: 4", "test_command: swift build && swift test"])
        #expect(updated.contains("custom_key: keep me"))
        #expect(updated.contains("# The project's checks."))
        #expect(updated.hasSuffix("test_command: not a setting, just notes\n"))
        // Round trip: setting it again changes nothing.
        #expect(LeadWorkflow.updating(updated, with: [("test_command", "swift build && swift test")]) == updated)
    }

    @Test func missingKeysAreAddedAndValuesCleared() {
        let updated = LeadWorkflow.updating("---\nmax_workers: 2\nverifier_model: opus\n---\nNotes", with: [("base_branch", "dev"), ("verifier_model", "")])
        #expect(updated == "---\nmax_workers: 2\nverifier_model:\nbase_branch: dev\n---\nNotes")
        let workflow = LeadWorkflow.parse(updated)
        #expect(workflow.baseBranch == "dev" && workflow.verifierModel == nil && workflow.notes == "Notes")
        // No front matter yet: one is put on top of the notes.
        let fresh = LeadWorkflow.updating("Just notes.", with: [("test_command", "make test")])
        #expect(fresh == "---\ntest_command: make test\n---\nJust notes.")
        #expect(LeadWorkflow.parse(fresh).notes == "Just notes.")
        // A quoted value keeps its quotes.
        #expect(LeadWorkflow.parse(LeadWorkflow.updating("---\n---", with: [("test_command", "\"quoted\"")])).testCommand == "\"quoted\"")
    }

    @Test func updatingKeepsCRLFTheBOMAndStrayBytes() throws {
        let crlf = Data([0xEF, 0xBB, 0xBF]) + Data("---\r\ntest_command:\r\nodd_key: 1\r\n---\r\nNotes caf".utf8) + Data([0xE9, 0x0D, 0x0A])
        let updated = LeadWorkflow.updating(crlf, with: [("test_command", "swift test"), ("init_command", "make")])
        #expect(updated == Data([0xEF, 0xBB, 0xBF]) + Data("---\r\ntest_command: swift test\r\nodd_key: 1\r\ninit_command: make\r\n---\r\nNotes caf".utf8) + Data([0xE9, 0x0D, 0x0A]))
        let workflow = LeadWorkflow.load(from: try file(updated))
        #expect(workflow.testCommand == "swift test" && workflow.initCommand == "make")
        // Valid UTF-8 notes stay as they were, too.
        let utf8 = Data("---\nmax_workers: 2\n---\nCafé ☕️\n".utf8)
        #expect(String(decoding: LeadWorkflow.updating(utf8, with: [("max_workers", "5")]), as: UTF8.self) == "---\nmax_workers: 5\n---\nCafé ☕️\n")
    }

    // MARK: Detection

    func project(_ files: [String: String]) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("detect-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for (name, text) in files { try text.write(toFile: root + "/" + name, atomically: true, encoding: .utf8) }
        return root
    }

    @Test func theTestCommandIsDetectedFromTheRepository() throws {
        let cases: [([String: String], String?)] = [
            (["Package.swift": "// swift-tools-version:5.9"], "swift build && swift test"),
            (["package.json": #"{"scripts": {"test": "vitest run"}}"#], "npm test"),
            (["package.json": #"{"scripts": {"test": "jest"}}"#, "pnpm-lock.yaml": ""], "pnpm test"),
            (["package.json": #"{"scripts": {"test": "jest"}}"#, "yarn.lock": ""], "yarn test"),
            (["package.json": #"{"scripts": {"test": "bun test"}}"#, "bun.lock": ""], "bun run test"),
            // npm init's placeholder isn't a test suite.
            (["package.json": #"{"scripts": {"test": "echo \"Error: no test specified\" && exit 1"}}"#], nil),
            (["package.json": #"{"name": "x"}"#], nil),
            (["Makefile": "build:\n\tcc a.c\n\ntest: build\n\t./a\n"], "make test"),
            (["Makefile": "test := 1\nall:\n\techo\n"], nil),
            (["Cargo.toml": "[package]"], "cargo test"),
            (["go.mod": "module x"], "go test ./..."),
            (["README.md": "hi"], nil),
        ]
        for (files, expected) in cases {
            #expect(LeadWorkflow.detectTestCommand(root: try project(files)) == expected, "\(files)")
        }
        #expect(LeadWorkflow.detectInitCommand(root: try project(["package.json": "{}", "package-lock.json": "{}"])) == "npm ci")
        #expect(LeadWorkflow.detectInitCommand(root: try project(["package.json": "{}", "pnpm-lock.yaml": ""])) == "pnpm install")
        #expect(LeadWorkflow.detectInitCommand(root: try project(["Package.swift": ""])) == nil)
    }

    let task = LeadTask(slug: "add-login", title: "Add login",
                        contract: LeadContract(goal: "Users can log in with email", acceptance: ["swift test passes", "LoginTests cover bad passwords"],
                                               boundaries: ["only Sources/Auth"], context: "We use Keychain."))

    @Test func theLeadsPromptCarriesThePlaybook() {
        let prompt = LeadPrompts.lead(project: "acme", root: "/r", workflow: LeadWorkflow.parse("---\nmax_workers: 2\n---"))
        for needle in ["acme", "never write code", "at most 2 workers", "audit", "merge", "ask_user", "board", "Don't wait", "configure", "reports wake you", "When woken, call status"] {
            #expect(prompt.localizedCaseInsensitiveContains(needle), "missing \(needle)")
        }
    }

    @Test func workerAndVerifierPromptsCarryTheContract() {
        let worker = LeadPrompts.worker(task: task, root: "/r", workflow: LeadWorkflow.parse("---\ninit_command: make\ntest_command: make test\n---"))
        for needle in ["Users can log in with email", "LoginTests cover bad passwords", "only Sources/Auth", "agent/add-login", "make test", "Keychain"] {
            #expect(worker.contains(needle), "missing \(needle)")
        }
        let verifier = LeadPrompts.verifier(task: task, root: "/r", workflow: LeadWorkflow.parse(""))
        for needle in ["read-only", "submit_audit", "Users can log in with email", "violation"] {
            #expect(verifier.localizedCaseInsensitiveContains(needle), "missing \(needle)")
        }
    }
}
