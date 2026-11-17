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
        // Fake files in the stores no prompt is in: the daemon's key, telemetry, a hook's environment script, a backup.
        for (folder, file) in Self.otherStores {
            let path = real + "/\(folder)/\(file)"
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data("FAKE".utf8).write(to: URL(fileURLWithPath: path))
        }
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

    /// The stores beside the prompts' (each with a fake file's name in it): Claude Code's daemon folder (its
    /// `control.key`), telemetry, the hooks' environment scripts and backups.
    static let otherStores = [("daemon", "control.key"), ("telemetry", "1p_failed_events.json"),
                              ("session-env", "5d041167/sessionstart-hook-0.sh"), ("backups", ".claude.json.backup")]

    func deny(_ role: LeadLaunch.Role, _ h: Home, name: String) throws -> [String] {
        let launch = try LeadLaunch.prepare(role: role, root: h.root, task: role == .lead ? nil : "fix-login", base: "claude", prompt: "p",
                                            start: "Go.", server: "/App/vibeswitcher-mcp", name: name, records: "docs/lead",
                                            folder: temp.url("run-\(name)"), cwd: role == .lead ? h.root : h.cwd,
                                            temporary: temp.url("session-tmp"), home: h.home)
        let settings = try LaunchArguments.json("--settings", in: launch.command)
        return try #require((settings["permissions"] as? [String: Any])?["deny"] as? [String])
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

    /// Claude Code's daemon folder (`control.key`, a credential), telemetry, the hooks' environment scripts and its
    /// backups: denied to every worker, verifier and finder, the folder and everything under it, as written and as
    /// resolved; the lead keeps them.
    @Test func theDaemonKeyTelemetryHookEnvironmentAndBackupsAreDenied() throws {
        let h = try home()
        for (role, name) in [(LeadLaunch.Role.worker, "worker-fix-login"), (.verifier, "verify-fix-login"), (.verifier, "finder2-fix-login")] {
            let rules = try deny(role, h, name: name)
            for (folder, file) in Self.otherStores {
                #expect(rules.contains("Read(~/.claude/\(folder))") && rules.contains("Read(~/.claude/\(folder)/**)"), "\(name): \(folder)")
                #expect(rules.contains("Read(/\(h.real)/\(folder))") && rules.contains("Read(/\(h.real)/\(folder)/**)"), "\(name): \(folder)")
                for path in ["~/.claude/\(folder)", "~/.claude/\(folder)/\(file)", h.real + "/\(folder)", h.real + "/\(folder)/\(file)"] {
                    #expect(denied(path, by: rules), "\(name): \(path)")
                }
            }
        }
        let lead = try deny(.lead, h, name: "lead-acme")
        for (folder, file) in Self.otherStores {
            #expect(!denied("~/.claude/\(folder)/\(file)", by: lead) && !denied(h.real + "/\(folder)/\(file)", by: lead), "lead: \(folder)")
        }
    }

    static let roles: [(LeadLaunch.Role, String)] = [(.worker, "worker-fix-login"), (.verifier, "verify-fix-login"), (.verifier, "finder2-fix-login")]

    /// Fake entries directly in `~/.claude` beside the stores: a store no rule names (invented here), the daemon's
    /// `daemon.json`, Claude Code's own files and folders, and the keep list's (a skill's reference file, a plugin's).
    static let unnamed = ["zz-store-from-a-later-release/records.jsonl", "daemon.json", "a-new-file.json", "CLAUDE.md", "settings.json",
                          "settings.local.json", "agents/a.md", "commands/c.md", "rules/r.md", "ide/1.lock", ".credentials.json",
                          "plugins/data/acme-inline/token.json", "plugins/config.json", "plugins/zz-later/x.json"]
    static let kept = ["skills/tdd/references/notes.md", "plugins/cache/acme/acme/1.0/skills/s/references/r.md",
                       "plugins/marketplaces/acme/plugins/p/skills/s/SKILL.md"]

    func withUnnamed(_ h: Home) throws {
        for file in Self.unnamed + Self.kept {
            let path = h.real + "/" + file
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data("FAKE".utf8).write(to: URL(fileURLWithPath: path))
        }
        try FileManager.default.createDirectory(atPath: h.real + "/projects/\(h.main)/memory", withIntermediateDirectories: true)
        try Data("FAKE".utf8).write(to: URL(fileURLWithPath: h.real + "/projects/\(h.main)/memory/MEMORY.md"))
    }

    /// Everything directly in `~/.claude` but the keep list is denied to every worker, verifier and finder, as written
    /// and as resolved, a store no rule names among them: listed at launch, not named. The keep list (skills, plugins)
    /// and the project's own memory stay readable, `plugins` itself listed (only its `cache` and `marketplaces` kept);
    /// the lead is denied none of it.
    @Test func everyEntryButTheKeepListIsDenied() throws {
        let h = try home(in: "listed")
        try withUnnamed(h)
        for (role, name) in Self.roles {
            let rules = try deny(role, h, name: name)
            for file in Self.unnamed {
                // The entry denied whole: one of `~/.claude`, or of `plugins`, which holds kept ones.
                let parts = file.split(separator: "/")
                let top = parts.prefix(parts.first == "plugins" ? 2 : 1).joined(separator: "/")
                for path in ["~/.claude/\(top)", "~/.claude/\(file)", h.real + "/\(top)", h.real + "/\(file)"] {
                    #expect(denied(path, by: rules), "\(name): \(path)")
                }
            }
            for file in Self.kept + ["projects/\(h.main)/memory/MEMORY.md", "projects/\(h.own)/s.jsonl"] {
                #expect(!denied("~/.claude/\(file)", by: rules) && !denied(h.real + "/\(file)", by: rules), "\(name): \(file)")
            }
            // The named stores aren't added twice by the listing.
            #expect(rules.filter { $0 == "Read(~/.claude/daemon)" }.count == 1, "\(name)")
        }
        let lead = try deny(.lead, h, name: "lead-acme")
        #expect(lead == LeadLaunch.deny(.lead))
        for file in Self.unnamed { #expect(!denied("~/.claude/\(file)", by: lead) && !denied(h.real + "/\(file)", by: lead), "lead: \(file)") }
    }

    /// `daemon.json` is denied by name, there or not when the role starts: the known stores never depend on the listing.
    @Test func daemonJSONIsDeniedByName() throws {
        let h = try home(in: "no-daemon-json")
        #expect(!FileManager.default.fileExists(atPath: h.real + "/daemon.json"))
        for (role, name) in Self.roles {
            let rules = try deny(role, h, name: name)
            #expect(rules.contains("Read(~/.claude/daemon.json)") && rules.contains("Read(/\(h.real)/daemon.json)"), "\(name)")
        }
        #expect(LeadLaunch.deny(.worker).contains("Read(~/.claude/daemon.json)") && LeadLaunch.deny(.verifier).contains("Read(~/.claude/daemon.json)"))
    }

    /// A `~/.claude` that's there but can't be listed starts no worker or verifier: what's in it couldn't be denied.
    /// None at all still starts them; the lead starts either way.
    @Test func anUnlistableClaudeFolderStartsNoWorkerOrVerifier() throws {
        let h = try home(in: "unlistable-claude")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: h.real)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.real) }
        #expect(throws: (any Error).self) { _ = try FileManager.default.contentsOfDirectory(atPath: h.real) }
        for (role, name) in Self.roles {
            #expect(throws: BoardError.self, "\(name)") { _ = try deny(role, h, name: name) }
        }
        _ = try deny(.lead, h, name: "lead-acme")

        let missing = try home(in: "no-claude")
        try FileManager.default.removeItem(atPath: missing.home + "/.claude")
        for (role, name) in Self.roles {
            let rules = try deny(role, missing, name: name)
            #expect(denied("~/.claude/daemon.json", by: rules) && denied("~/.claude/history.jsonl", by: rules), "\(name)")
        }
    }

    /// An entry whose name a rule can't hold as it is would go undenied: no worker or verifier starts instead.
    @Test func anEntryNoRuleCanNameStartsNoWorkerOrVerifier() throws {
        for (index, entry) in ["store*", "store (old)", "store[1]"].enumerated() {
            let h = try home(in: "unnameable\(index)")
            try FileManager.default.createDirectory(atPath: h.real + "/" + entry, withIntermediateDirectories: true)
            for (role, name) in Self.roles {
                #expect(throws: BoardError.self, "\(entry): \(name)") { _ = try deny(role, h, name: name) }
            }
            _ = try deny(.lead, h, name: "lead-acme")
        }
    }

    /// A `projects` folder that's there but can't be listed starts no worker or verifier (as an unreadable board starts
    /// no team verifier): the other projects' transcripts in it couldn't be denied (audit workers-and-verifiers-4:F3).
    /// None at all still starts them, and the lead starts either way.
    @Test func anUnlistableProjectsFolderStartsNoWorkerOrVerifier() throws {
        let h = try home(in: "unlistable")
        let projects = h.real + "/projects"
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: projects)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projects) }
        // The test runs as a user the mode binds (not root): the folder really can't be listed.
        #expect(throws: (any Error).self) { _ = try FileManager.default.contentsOfDirectory(atPath: projects) }
        for (role, name) in [(LeadLaunch.Role.worker, "worker-fix-login"), (.verifier, "verify-fix-login"), (.verifier, "finder2-fix-login")] {
            #expect(throws: BoardError.self, "\(name)") { _ = try deny(role, h, name: name) }
        }
        _ = try deny(.lead, h, name: "lead-acme")

        let missing = try home(in: "no-projects")
        try FileManager.default.removeItem(atPath: missing.real + "/projects")
        for (role, name) in [(LeadLaunch.Role.worker, "worker-fix-login"), (.verifier, "verify-fix-login")] {
            let rules = try deny(role, missing, name: name)
            #expect(denied("~/.claude/daemon/control.key", by: rules), "\(name)")
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
    /// the history file, the daemon's key, telemetry, a hook's environment script or a backup, for a worker or a verifier, by any spelling: `~`, the home's absolute path, as resolved, `$HOME`,
    /// climbing out, or a link committed in the worktree that points at it.
    @Test func noShellReadOfThePromptHistoryRunsUnasked() throws {
        let h = try home()
        try FileManager.default.createSymbolicLink(atPath: h.cwd + "/notes.jsonl", withDestinationPath: h.real + "/history.jsonl")
        let climb = String(repeating: "../", count: h.cwd.split(separator: "/").count) + String(h.real.dropFirst())
        try FileManager.default.createSymbolicLink(atPath: h.cwd + "/key.txt", withDestinationPath: h.real + "/daemon/control.key")
        var files = ["~/.claude/history.jsonl", h.home + "/.claude/history.jsonl", h.real + "/history.jsonl", "$HOME/.claude/history.jsonl",
                     "\"$HOME\"/.claude/history.jsonl", climb + "/history.jsonl", "notes.jsonl", "./notes.jsonl", "key.txt"]
        // The daemon's key, telemetry, a hook's environment script and a backup, by the same spellings.
        for (folder, file) in Self.otherStores {
            files += ["~/.claude/\(folder)/\(file)", h.home + "/.claude/\(folder)/\(file)", h.real + "/\(folder)/\(file)",
                      "$HOME/.claude/\(folder)/\(file)", climb + "/\(folder)/\(file)"]
        }
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
