import Foundation
import Testing
@testable import VibeCore

/// Claude Code's prompt history (`~/.claude/history.jsonl`) and the other stores in `~/.claude` that hold every
/// session's words on this Mac: no worker, verifier or finder reads them (Read rules, which also bind Claude Code's own
/// check of a shell read), the hook auto-allows no shell read of them, and the lead's rules are as they were. A scratch
/// home with fake files: nothing here opens the user's own.
struct ClaudeStoresTests {
    let temp = Scratch()

    /// A scratch home whose `.claude` is a link to a folder elsewhere (so a path as resolved differs from the `~` one),
    /// with a fake history file, a fake paste and transcript folders: another repository's, the project's main
    /// checkout's, one of its other worktrees' and the role's own.
    struct Home {
        let home: String, real: String, root: String, cwd: String
        let other: String, main: String, sibling: String, own: String
    }

    func home(_ claudeFolder: String = "claude", in scratch: String = "stores") throws -> Home {
        let made = temp.url(scratch)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // As the kernel resolves it (`/private` kept), as the rules spell a resolved path.
        let base = try #require(realpath(made.path, nil).map { path in defer { free(path) }; return String(cString: path) })
        let home = base + "/home", real = base + "/elsewhere/" + claudeFolder, root = base + "/dev/acme"
        let cwd = Worktrees.path(root: root, slug: "fix-login")
        let fm = FileManager.default
        try fm.createDirectory(atPath: real + "/paste-cache", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/.claude", withDestinationPath: real)
        try Data("{\"display\":\"FAKE PROMPT\"}\n".utf8).write(to: URL(fileURLWithPath: real + "/history.jsonl"))
        try Data("FAKE PASTE".utf8).write(to: URL(fileURLWithPath: real + "/paste-cache/0.txt"))
        func name(_ path: String) -> String { (LeadLaunch.claudeProjectFolder(path, home: home) as NSString).lastPathComponent }
        let folders = (other: name(base + "/dev/other-repo"), main: name(root), sibling: name(Worktrees.path(root: root, slug: "add-b")),
                       own: name(cwd))
        for folder in [folders.other, folders.main, folders.sibling, folders.own] {
            try fm.createDirectory(atPath: real + "/projects/\(folder)", withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: URL(fileURLWithPath: real + "/projects/\(folder)/s.jsonl"))
        }
        return Home(home: home, real: real, root: root, cwd: cwd, other: folders.other, main: folders.main, sibling: folders.sibling,
                    own: folders.own)
    }

    func deny(_ role: LeadLaunch.Role, _ h: Home, name: String) throws -> [String] {
        let launch = try LeadLaunch.prepare(role: role, root: h.root, task: role == .lead ? nil : "fix-login", base: "claude", prompt: "p",
                                            start: "Go.", server: "/App/vibeswitcher-mcp", name: name, records: "docs/lead",
                                            folder: temp.url("run-\(name)"), cwd: role == .lead ? h.root : h.cwd,
                                            temporary: temp.url("session-tmp"), home: h.home)
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any]
        return try #require((settings?["permissions"] as? [String: Any])?["deny"] as? [String])
    }

    /// Whether a Read rule in `rules` matches `path` (`~/…`, or absolute: a rule's `//…`), as Claude Code's gitignore-style
    /// patterns do (`LeadWorkflow.matches`).
    func denied(_ path: String, by rules: [String]) -> Bool {
        rules.contains { rule in
            guard rule.hasPrefix("Read("), rule.hasSuffix(")") else { return false }
            let pattern = String(rule.dropFirst("Read(".count).dropLast())
            if pattern.hasPrefix("~/"), path.hasPrefix("~/") {
                return LeadWorkflow.matches(String(path.dropFirst(2)), glob: "/" + pattern.dropFirst(2))
            }
            if pattern.hasPrefix("//"), path.hasPrefix("/") {
                return LeadWorkflow.matches(String(path.dropFirst()), glob: String(pattern.dropFirst()))
            }
            return false
        }
    }

    @Test func workersVerifiersAndFindersAreDeniedThePromptHistoryAsWrittenAndAsResolved() throws {
        let h = try home()
        for (role, name) in [(LeadLaunch.Role.worker, "worker-fix-login"), (.verifier, "verify-fix-login"), (.verifier, "finder2-fix-login")] {
            let rules = try deny(role, h, name: name)
            #expect(rules.contains("Read(~/.claude/history.jsonl)"), "\(name)")
            #expect(rules.contains("Read(/\(h.real)/history.jsonl)"), "\(name): \(rules.suffix(12))")
            #expect(denied("~/.claude/history.jsonl", by: rules) && denied(h.real + "/history.jsonl", by: rules), "\(name)")
            // Once each: a team verifier's rules don't add it again (`memberTranscripts`).
            #expect(rules.filter { $0 == LeadLaunch.promptHistory }.count == 1)
            // The other stores of every session's words, as written and as resolved.
            for store in LeadLaunch.sessionStores {
                #expect(denied("~/.claude/\(store)/x", by: rules) && denied(h.real + "/\(store)/x", by: rules), "\(name): \(store)")
            }
        }
    }

    /// Background jobs' records (`~/.claude/jobs/<id>/timeline.jsonl`) are another session's words too (audit F1).
    @Test func backgroundJobsAreDenied() throws {
        let h = try home()
        for (role, name) in [(LeadLaunch.Role.worker, "worker-fix-login"), (.verifier, "verify-fix-login"), (.verifier, "finder2-fix-login")] {
            let rules = try deny(role, h, name: name)
            #expect(denied("~/.claude/jobs", by: rules) && denied("~/.claude/jobs/5d041167/timeline.jsonl", by: rules), "\(name)")
            #expect(denied(h.real + "/jobs/5d041167/timeline.jsonl", by: rules), "\(name)")
        }
    }

    /// Where `~/.claude` resolves to a folder whose path holds a space (an iCloud Drive one, "Mobile Documents"), its
    /// stores and other repositories' transcripts are denied there too, not skipped (audit F2).
    @Test func aResolvedPathWithASpaceIsDeniedNotSkipped() throws {
        let h = try home("my claude", in: "spaced")
        for (role, name) in [(LeadLaunch.Role.worker, "worker-fix-login"), (.verifier, "verify-fix-login")] {
            let rules = try deny(role, h, name: name)
            #expect(rules.contains("Read(/\(h.real)/history.jsonl)"), "\(name): \(rules.suffix(12))")
            #expect(denied(h.real + "/history.jsonl", by: rules) && denied(h.real + "/paste-cache/0.txt", by: rules), "\(name)")
            #expect(denied(h.real + "/projects/\(h.other)/s.jsonl", by: rules), "\(name)")
            #expect(!denied(h.real + "/projects/\(h.own)/s.jsonl", by: rules), "\(name)")
        }
    }

    /// One a rule can't name as it is (a glob's `*`, a parenthesis) starts no worker or verifier, rather than one
    /// without those rules (audit F2); the lead, which has none of them, still starts.
    @Test func aResolvedPathNoRuleCanHoldStartsNoWorkerOrVerifier() throws {
        for (index, folder) in ["claude*", "claude (old)", "claude[1]"].enumerated() {
            let h = try home(folder, in: "unholdable\(index)")
            for (role, name) in [(LeadLaunch.Role.worker, "worker-fix-login"), (.verifier, "verify-fix-login")] {
                #expect(throws: BoardError.self, "\(folder): \(name)") { _ = try deny(role, h, name: name) }
            }
            _ = try deny(.lead, h, name: "lead-acme")
        }
    }

    @Test func theLeadsRulesAreUnchanged() throws {
        let h = try home()
        let rules = try deny(.lead, h, name: "lead-acme")
        #expect(rules == LeadLaunch.deny(.lead))
        #expect(!denied("~/.claude/history.jsonl", by: rules) && !denied(h.real + "/history.jsonl", by: rules))
        #expect(!rules.contains { $0.contains(".claude/projects") || $0.contains(h.real) })
    }

    /// Another repository's transcript folder is denied (as written and as resolved); the project's own (its main
    /// checkout's, its worktrees', the role's own) stay readable.
    @Test func otherRepositoriesTranscriptsAreDeniedAndTheProjectsOwnAreNot() throws {
        let h = try home()
        for (role, name) in [(LeadLaunch.Role.worker, "worker-fix-login"), (.verifier, "verify-fix-login")] {
            let rules = try deny(role, h, name: name)
            #expect(denied("~/.claude/projects/\(h.other)/s.jsonl", by: rules), "\(name)")
            #expect(denied(h.real + "/projects/\(h.other)/s.jsonl", by: rules), "\(name)")
            #expect(denied("~/.claude/projects/\(h.other)", by: rules))
            for folder in [h.main, h.sibling, h.own] {
                #expect(!denied("~/.claude/projects/\(folder)/s.jsonl", by: rules), "\(name): \(folder)")
                #expect(!denied(h.real + "/projects/\(folder)/s.jsonl", by: rules), "\(name): \(folder)")
            }
        }
    }

    /// The shell forms the hook knows (head, tail, grep, rg, wc, sort; cat and sed it never allows) don't run unasked on
    /// the history file for a worker or a verifier, by any spelling: `~`, the home's absolute path, as resolved, `$HOME`,
    /// climbing out, or a link committed in the worktree that points at it.
    @Test func noShellReadOfThePromptHistoryRunsUnasked() throws {
        let h = try home()
        try FileManager.default.createSymbolicLink(atPath: h.cwd + "/notes.jsonl", withDestinationPath: h.real + "/history.jsonl")
        let climb = String(repeating: "../", count: h.cwd.split(separator: "/").count) + String(h.real.dropFirst())
        let files = ["~/.claude/history.jsonl", h.home + "/.claude/history.jsonl", h.real + "/history.jsonl", "$HOME/.claude/history.jsonl",
                     "\"$HOME\"/.claude/history.jsonl", climb + "/history.jsonl", "notes.jsonl", "./notes.jsonl"]
        let forms = ["cat %@", "head %@", "head -n 5 %@", "tail %@", "tail -n 1 %@", "grep -n x %@", "grep -c '' %@", "rg x %@",
                     "sed -n 1p %@", "wc -l %@", "sort %@", "git status && head %@", "grep -n x README.md %@", "cat < %@"]
        for role in [LeadLaunch.Role.worker, .verifier] {
            for scope in [ReadOnlyCommand.Scope(root: h.cwd, cwd: h.cwd, writes: role == .worker)] {
                for file in files {
                    for form in forms {
                        let line = form.replacingOccurrences(of: "%@", with: file)
                        #expect(!ReadOnlyCommand.allows(line, in: scope), "\(role): \(line)")
                        let input: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": line], "cwd": h.cwd]
                        let event = try JSONSerialization.data(withJSONObject: input)
                        #expect(ReadOnlyCommand.hookAnswer(event, root: h.cwd, writes: role == .worker) == nil, "\(role): \(line)")
                    }
                }
            }
        }
        // The same forms on a file in the worktree do run unasked: the test reaches the hook's allow path.
        #expect(ReadOnlyCommand.allows("head -n 5 README.md", in: .init(root: h.cwd, cwd: h.cwd)))
    }
}
