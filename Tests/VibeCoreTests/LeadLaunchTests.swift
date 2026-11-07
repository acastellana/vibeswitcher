import Foundation
import Testing
@testable import VibeCore

struct LeadLaunchTests {
    let temp = Scratch()
    func root() throws -> String {
        let url = temp.url("launch")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test func theLeadsCommandAddsItsPromptToolsAndRules() throws {
        let root = try root()
        let launch = try LeadLaunch.prepare(role: .lead, root: root, task: nil, base: "claude --dangerously-skip-permissions",
                                            prompt: "You are the lead.", start: "Say hello.", server: "/App/vibeswitcher-mcp", name: "lead-acme")
        #expect(launch.command.hasPrefix("claude --dangerously-skip-permissions "))
        #expect(launch.command.contains("--append-system-prompt-file '\(launch.promptFile)'"))
        #expect(launch.command.contains("--mcp-config "))
        #expect(launch.command.contains("--settings "))
        #expect(launch.command.contains("--name 'lead-acme'"))
        #expect(launch.command.hasSuffix(" -- 'Say hello.'"))
        let prompt = try String(contentsOfFile: launch.promptFile, encoding: .utf8)
        #expect(prompt == "You are the lead.")
        let mcp = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.mcpFile))) as? [String: Any]
        let server = (mcp?["mcpServers"] as? [String: Any])?["vibeswitcher"] as? [String: Any]
        #expect(server?["command"] as? String == "/App/vibeswitcher-mcp")
        // Through its keeper, which starts it again if it stops (MCPKeeperTests).
        #expect(server?["args"] as? [String] == ["--keeper", "--role", "lead", "--root", root])
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any]
        let deny = (settings?["permissions"] as? [String: Any])?["deny"] as? [String] ?? []
        #expect(deny.contains("Edit") && deny.contains("Write") && deny.contains("Bash(git commit:*)"))
    }

    @Test func workersMayEditButNotTouchHistoryOrMain() throws {
        let root = try root()
        let launch = try LeadLaunch.prepare(role: .worker, root: root, task: "add-login", base: "claude", prompt: "p", start: "Go.",
                                            server: "/s", name: "worker-add-login", branch: "project-lead")
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any]
        let deny = (settings?["permissions"] as? [String: Any])?["deny"] as? [String] ?? []
        let allow = (settings?["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
        #expect(!deny.contains("Edit"))
        for rule in ["Bash(git push:*)", "Bash(git rebase * *)", "Bash(git reset --hard project-lead)", "Bash(git reset --hard agent/*)",
                     "Bash(git switch main *)", "Bash(git checkout project-lead)", "Bash(git checkout agent/*)", "Bash(git branch -D:*)",
                     "Bash(git branch -f:*)", "Bash(git update-ref:*)"] {
            #expect(deny.contains(rule), "missing \(rule)")
        }
        // Its own branch it brings up to date with the lead's (the rest of the rules: LeadGuardRailsTests).
        for rule in ["Bash(git rebase project-lead)", "Bash(git rebase --continue)", "Bash(git merge project-lead)"] {
            #expect(allow.contains(rule), "missing \(rule)")
        }
        // Its git never opens an editor, so the `git commit` that ends a merge needs nothing in front; its `git status`
        // (its status line's too) never takes index.lock (IndexLockTests).
        #expect(settings?["env"] as? [String: String] == ["GIT_EDITOR": "true", "GIT_OPTIONAL_LOCKS": "0"])
        let mcp = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.mcpFile))) as? [String: Any]
        let args = ((mcp?["mcpServers"] as? [String: Any])?["vibeswitcher"] as? [String: Any])?["args"] as? [String]
        #expect(args == ["--keeper", "--role", "worker", "--root", root, "--task", "add-login"])
        #expect(launch.promptFile.contains("/.vibeswitcher/run/worker-add-login/"))
    }

    @Test func theLaunchFilesArePrivateAndHoldNoRole() throws {
        let root = try root()
        let folder = temp.url("run").appendingPathComponent("verify-x")
        let launch = try LeadLaunch.prepare(role: .verifier, root: root, task: "x", base: "claude", prompt: "p", start: "Check.",
                                            server: "/s", name: "verify-x", folder: folder)
        #expect(launch.mcpFile.hasPrefix(folder.path))
        let mcp = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.mcpFile))) as? [String: Any]
        let entry = (mcp?["mcpServers"] as? [String: Any])?["vibeswitcher"] as? [String: Any]
        // The session host knows which session holds the role: the tool server gets nothing that would make one.
        #expect(entry?["env"] == nil)
        #expect(Set(entry?.keys.map { $0 } ?? []) == ["command", "args"])
        // Its session's git takes no optional index.lock either; its commands run as branch code, with no auto-memory
        // (`LeadLaunch.verifierEnvironment`).
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any]
        #expect(settings?["env"] as? [String: String] == ["GIT_OPTIONAL_LOCKS": "0"].merging(LeadLaunch.verifierEnvironment(server: "/s")) { $1 })
        for file in [launch.mcpFile, launch.promptFile, launch.settingsFile] {
            #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int) == 0o600, "\(file)")
        }
        #expect((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) == 0o700)
        // A verifier doesn't load the branch's project settings or MCP servers.
        #expect(launch.command.contains("--setting-sources user --strict-mcp-config"))
        let worker = try LeadLaunch.prepare(role: .worker, root: root, task: "x", base: "claude", prompt: "p", start: "Go.", server: "/s", name: "worker-x")
        #expect(!worker.command.contains("--setting-sources"))
    }

    @Test func theVerifierIsReadOnlyAndMayUseAnotherModel() throws {
        let launch = try LeadLaunch.prepare(role: .verifier, root: try root(), task: "x", base: "claude", prompt: "p", start: "Check.",
                                            server: "/s", name: "verify-x", model: "sonnet")
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any]
        let deny = (settings?["permissions"] as? [String: Any])?["deny"] as? [String] ?? []
        for rule in ["Edit", "Write", "NotebookEdit", "Bash(git commit:*)", "Bash(git add:*)", "Bash(git stash:*)"] {
            #expect(deny.contains(rule), "missing \(rule)")
        }
        #expect(launch.command.contains("--model 'sonnet'"))
    }

    /// Checked with claude 2.1.302 on a scratch repository with these files: in auto mode (the default since 2.1.284,
    /// and the user's `defaultMode`) the deny rules still refuse (a worker's tag, checkout of main, branch -D, push; a
    /// verifier's Write, touch, commit) and the allowed ones run; in default mode the VibeSwitcher tools run only
    /// because of `mcp__vibeswitcher__*` (without it: "you haven't granted it yet").
    /// The Mac-wide limits and the working policy are the user's, set in Settings: no role's session writes them (a
    /// worker raising mac_max_sessions there would start more of itself). The app writes them as ever.
    @Test func noRoleMayWriteTheUsersMacWideSettings() throws {
        let root = try root()
        let rules = ["Edit(~/.vibeswitcher/mac-limits.json)", "Write(~/.vibeswitcher/mac-limits.json)",
                     "Edit(~/.vibeswitcher/boost.json)", "Write(~/.vibeswitcher/boost.json)",
                     "Edit(~/.vibeswitcher/policy.md)", "Write(~/.vibeswitcher/policy.md)"]
        for role in [LeadLaunch.Role.lead, .worker, .verifier] {
            let launch = try LeadLaunch.prepare(role: role, root: root, task: role == .lead ? nil : "fix", base: "claude",
                                                prompt: "p", start: "s", server: "/App/vibeswitcher-mcp", name: "\(role.rawValue)-fix")
            let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any]
            let deny = (settings?["permissions"] as? [String: Any])?["deny"] as? [String] ?? []
            for rule in rules { #expect(deny.contains(rule), "\(role): \(rule)") }
            #expect(!((settings?["permissions"] as? [String: Any])?["allow"] as? [String] ?? []).contains { $0.contains("mac-limits") || $0.contains("boost.json") || $0.contains("policy.md") })
        }
        // The app's own writes (Settings' save) go through, as before.
        let file = URL(fileURLWithPath: root).appendingPathComponent("home/mac-limits.json")
        try MacLimits(maxSessions: 8).save(to: file)
        #expect(MacLimits.load(from: file).maxSessions == 8)
        let policy = URL(fileURLWithPath: root).appendingPathComponent("home/policy.md")
        try WorkingPolicy.save("- Be brief.", to: policy)
        #expect(WorkingPolicy.load(from: policy) == "- Be brief.")
    }

    /// No role reaches another session by Claude Code's raw cross-session messaging: anyone on the Mac can send one and
    /// claim any name. A lead uses tell_lead (`LeadMail`). Bare tool names, as `Edit` and `Write` are denied: the whole
    /// tool, out of the session's context. Nothing allows them back.
    @Test func noRoleMayMessageOtherSessionsRaw() throws {
        let root = try root()
        for role in [LeadLaunch.Role.lead, .worker, .verifier] {
            let launch = try LeadLaunch.prepare(role: role, root: root, task: role == .lead ? nil : "fix", base: "claude",
                                                prompt: "p", start: "s", server: "/App/vibeswitcher-mcp", name: "\(role.rawValue)-fix",
                                                branch: "project-lead", records: "docs/lead")
            let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any]
            let permissions = settings?["permissions"] as? [String: Any]
            let deny = permissions?["deny"] as? [String] ?? [], allow = permissions?["allow"] as? [String] ?? []
            for tool in ["SendMessage", "ListAgents"] {
                #expect(deny.contains(tool), "\(role): \(tool)")
                #expect(!allow.contains { $0 == tool || $0.hasPrefix(tool + "(") }, "\(role): \(tool) allowed")
            }
        }
    }

    /// No role changes the repository's remotes: .git/config is the main checkout's too, so a worker's `git remote
    /// set-url origin <elsewhere>` would send the user's own `git push origin main` there, and have the lead's first
    /// fetch_remote pin it. Listing them stays open.
    @Test func noRoleMayChangeTheRemotes() throws {
        let root = try root()
        let writes = ["add", "rename", "remove", "rm", "set-head", "set-branches", "set-url", "prune", "update"]
        for role in [LeadLaunch.Role.lead, .worker, .verifier] {
            let launch = try LeadLaunch.prepare(role: role, root: root, task: role == .lead ? nil : "fix", base: "claude",
                                                prompt: "p", start: "s", server: "/App/vibeswitcher-mcp", name: "\(role.rawValue)-fix",
                                                branch: "project-lead", records: "docs/lead")
            let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any]
            let deny = (settings?["permissions"] as? [String: Any])?["deny"] as? [String] ?? []
            for sub in writes {
                for option in ["", "-v ", "--verbose "] {
                    #expect(deny.contains("Bash(git remote \(option)\(sub):*)"), "\(role): git remote \(option)\(sub)")
                }
            }
            // Reading them: no rule names `git remote` alone, `-v`, `show` or `get-url`.
            let remote = deny.filter { $0.hasPrefix("Bash(git remote") }
            #expect(remote.count == writes.count * 3, "\(role): \(remote)")
            for read in ["git remote", "git remote -v", "git remote --verbose", "git remote show", "git remote show origin",
                         "git remote get-url origin", "git remote -v show origin"] {
                #expect(!remote.contains { rule in
                    let prefix = String(rule.dropFirst("Bash(".count).dropLast(":*)".count))
                    return read == prefix || read.hasPrefix(prefix + " ")
                }, "\(role): \(read) denied")
            }
        }
    }

    @Test func everyRoleMayUseItsToolsByTheServersWholeNameInAnyPermissionMode() throws {
        for role in [LeadLaunch.Role.lead, .worker, .verifier] {
            let launch = try LeadLaunch.prepare(role: role, root: try root(), task: "x", base: "claude", prompt: "p", start: "Go.",
                                                server: "/s", name: "\(role.rawValue)-x", branch: "project-lead")
            let mcp = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.mcpFile))) as? [String: Any]
            #expect((mcp?["mcpServers"] as? [String: Any])?.keys.sorted() == ["vibeswitcher"])
            let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any])
            let permissions = try #require(settings["permissions"] as? [String: Any])
            // The permission mode stays the user's (auto, by default): the rules don't pick one.
            #expect(permissions.keys.sorted() == ["allow", "deny"])
            #expect(!launch.command.contains("--permission-mode"))
            let allow = permissions["allow"] as? [String] ?? [], deny = permissions["deny"] as? [String] ?? []
            // 2.1.299+: `mcp__<server>__*` with the whole name; a bare `mcp__vibeswitcher` or a prefix no longer reads the same.
            #expect(allow.filter { $0.hasPrefix("mcp__") } == ["mcp__vibeswitcher__*"])
            #expect(!deny.contains { $0.hasPrefix("mcp__") })
            // git reads go to the role's hook (LeadLaunchOutsideReadsTests), not to a rule.
            #expect(!allow.contains("Bash(git log:*)") && settings["hooks"] != nil)
        }
    }
}

/// Every role's git reads go through its `PermissionRequest` hook's parser (`ReadOnlyCommand`), not broad allow rules
/// such as `Bash(git diff:*)`, which let `git diff --no-index /var/empty <file>` print the lead's private files past
/// `Read(~/.vibeswitcher/lead/**)` (2026-11-01). Each leak form of round 1's findings (F1–F6), and a symlink the branch
/// commits, is shown printing a scratch "private" file for real, then shown not running unasked for any role; the
/// everyday reads, and a worker's commits, still do.
struct LeadLaunchOutsideReadsTests {
    let temp = Scratch()

    func run(_ command: String, in folder: String) throws -> String { try Self.shell(command, in: folder) }

    /// Runs `command` with sh in `folder` (no hooks, no global git config) and returns what it printed, errors included.
    static func shell(_ command: String, in folder: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        var env = ProcessInfo.processInfo.environment
        for (key, value) in ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_EDITOR": "true", "GIT_PAGER": "cat",
                             "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"] {
            env[key] = value
        }
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        waitForEnd(process)
        return String(decoding: data, as: UTF8.self)
    }

    /// A role's permissions as `prepare` writes them, and whether Claude Code runs a line under them without asking:
    /// no deny rule matches it, and an allow rule or the `PermissionRequest` hook (as its command line sets it up) takes it.
    struct Role {
        let role: LeadLaunch.Role
        let allow: [String], deny: [String]
        /// Nil when its settings have no hook (what runs unasked is then the allow rules' alone).
        let hook: (root: String?, writes: Bool)?

        init(_ role: LeadLaunch.Role, root: String, temp: Scratch) throws {
            let launch = try LeadLaunch.prepare(role: role, root: root, task: role == .lead ? nil : "t", base: "claude", prompt: "p",
                                                start: "Go.", server: "/opt/vibe switcher/vibeswitcher-mcp", name: "\(role)-outside",
                                                branch: "main", records: "docs/lead", folder: temp.url("run-\(role)"), cwd: root,
                                                temporary: temp.url("session-tmp"))
            let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any])
            let permissions = try #require(settings["permissions"] as? [String: Any])
            self.role = role
            allow = permissions["allow"] as? [String] ?? []
            deny = permissions["deny"] as? [String] ?? []
            let groups = (settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]
            let command = (groups?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
            let words = command.flatMap { ReadOnlyCommand.parts(of: $0)?.first } ?? []
            hook = words.dropFirst().first == ReadOnlyCommand.hookArgument ? ReadOnlyCommand.hookOptions(Array(words.dropFirst(2))) : nil
        }

        func runsUnasked(_ line: String, cwd: String) -> Bool {
            if LeadGuardRailsTests.denied(line, by: deny) { return false }
            if LeadGuardRailsTests.allowed(line, by: (allow, deny)) { return true }
            guard let hook else { return false }
            return ReadOnlyCommand.allows(line, in: ReadOnlyCommand.Scope(root: hook.root, cwd: cwd, writes: hook.writes))
        }
    }

    @Test func gitReadsOfFilesOutsideTheWorktreeRunUnaskedForNoRole() throws {
        let scratch = temp.url("outside").resolvingSymlinksInPath().path
        let secret = "SECRET-SEAL-VALUE"
        let privateDir = scratch + "/private", repo = scratch + "/repo"
        try FileManager.default.createDirectory(atPath: privateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        // A line of its own, then "--": rev-parse --parseopt prints the lines before "--" as its usage.
        try Data((secret + "\n--\n").utf8).write(to: URL(fileURLWithPath: privateDir + "/seal"))
        _ = try run("git init -q -b main && mkdir sub && echo a > a && echo b > sub/b && git add a sub/b && git commit -qm a"
                    + " && echo c >> a && git commit -qam c", in: repo)
        let seal = privateDir + "/seal"
        // Each prints the secret when run (checked below), so each is a real way to read it.
        let leaks = [
            // The first report: --no-index, and a path outside the work tree (git then compares without it).
            "git diff --no-index /var/empty \(privateDir)", "git diff /dev/null \(seal)", "git diff ../private/seal a",
            "git diff sub/../../private/seal a", "git diff \"\(seal)\" a",
            // F1: global options before the command.
            "git -P diff /dev/null \(seal)", "git --no-pager diff --no-index /dev/null \(seal)",
            "git --literal-pathspecs diff /dev/null ../private/seal",
            // F2: a bare `..`.
            "git diff /var/empty ..", "git diff .. /var/empty",
            // F3: --stdin on diff and show (and log).
            "git diff --stdin < \(seal)", "git show --stdin < \(seal)", "git log --stdin < \(seal)",
            // F4: abbreviations and bundled short options of the flags that read a file.
            "git add --pathspec-from=\(seal)", "git blame --cont \(seal) -- a", "git blame -wS \(seal) a",
            "git blame --ignore-revs \(seal) a",
            // F5: rev-parse --parseopt prints its input's usage lines.
            "git rev-parse --parseopt -- -h < \(seal)",
            // F6: commit's template (and its file, and abbreviations of both).
            "git commit -q --allow-empty -t \(seal) --cleanup=verbatim && git log -1 --format=%B",
            "git commit -q --allow-empty --templ=\(seal) --cleanup=verbatim && git log -1 --format=%B",
            "git commit -q --allow-empty -F \(seal) && git log -1 --format=%B",
            "git commit -q --allow-empty --fil=\(seal) && git log -1 --format=%B",
            // Pathspecs from a file (git prints each line it can't match).
            "git add --pathspec-from-file=\(seal)", "git rm --pathspec-from-file=\(seal)",
        ]
        for command in leaks {
            #expect(try run(command, in: repo).contains(secret), "not a leak: \(command)")
        }
        // As a session would send them, plus shapes no rule can resolve: a path from home, behind an expansion.
        let refused = leaks + ["git diff \"$S/private\" a", "git diff `echo /etc/hosts` a", "git diff /dev/null ~/.vibeswitcher/lead/x",
                               "git diff --pathspec-from-file \(seal)"]
        let roles = try [LeadLaunch.Role.lead, .worker, .verifier].map { try Role($0, root: repo, temp: temp) }
        for role in roles {
            // No broad git rule is left: every git read goes to the hook.
            #expect(!role.allow.contains { $0.hasPrefix("Bash(git ") && $0.hasSuffix(":*)") }, "\(role.role): \(role.allow)")
            #expect(role.hook?.root == repo && role.hook?.writes == (role.role == .worker), "\(role.role)")
            for command in refused {
                #expect(!role.runsUnasked(command, cwd: repo), "\(role.role): \(command)")
            }
            // The deny rules still come first: --no-index is refused there before the hook is asked.
            #expect(LeadGuardRailsTests.denied("git diff --no-index /var/empty \(privateDir)", by: role.deny))
        }

        // What each role reads every day runs without a prompt: relative paths, paths absolute inside the worktree (F9),
        // revisions and ranges.
        let base = try run("git rev-parse HEAD~1", in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let reads = ["git diff main...HEAD", "git diff \(base) HEAD -- a sub/b", "git diff \(base) HEAD -- \(repo)/a \(repo)/sub/b",
                     "git diff HEAD~1", "git diff --stat", "git diff main...HEAD -- a sub/b", "git log --oneline -5 -- a",
                     "git log -p \(repo)/sub/b", "git show HEAD:a", "git show --stat HEAD", "git blame a", "git blame -L 1,2 \(repo)/a",
                     "git status", "git status --short", "git log --format='%h %s' main..HEAD", "grep -rn x sub", "head -5 a"]
        for role in roles {
            for command in reads { #expect(role.runsUnasked(command, cwd: repo), "\(role.role): \(command)") }
        }
        // From a subfolder, `..` is the worktree (the deny rules still refuse a `git diff` path that starts with `../`).
        for role in roles { #expect(role.runsUnasked("head ../a", cwd: repo + "/sub"), "\(role.role)") }
        #expect(ReadOnlyCommand.allows("git diff HEAD~1 -- ../a", in: .init(root: repo, cwd: repo + "/sub")))
        #expect(!ReadOnlyCommand.allows("git diff HEAD~1 -- ../../a", in: .init(root: repo, cwd: repo + "/sub")))
        // A worker stages, removes, commits (a message on the line or in a here-document) and takes a fix out and back.
        let writes = ["git add a", "git add -A", "git add \(repo)/sub/b", "git rm sub/b", "git rm --cached a", "git commit -m 'Add the login form'",
                      "git commit -am \"Fix the form\"", "git commit", "git commit --no-edit",
                      "git commit -m \"$(cat <<'EOF'\nRefuse `..` in ~/.vibeswitcher paths\n\nCo-Authored-By: x <x@y>\nEOF\n)\"",
                      "git diff \(base) HEAD -- a | git apply -R", "git diff \(base) HEAD -- a | git apply"]
        for role in roles {
            for command in writes {
                #expect(role.runsUnasked(command, cwd: repo) == (role.role == .worker), "\(role.role): \(command)")
            }
        }
        // A here-document whose delimiter isn't quoted, or with anything after its closing line, still prompts.
        let worker = try #require(roles.first { $0.role == .worker })
        for command in ["git commit -m \"$(cat <<EOF\n$(id)\nEOF\n)\"", "git commit -m \"$(cat <<'EOF'\nx\nEOF\n); id)\"",
                        "git commit -m \"$(cat <<'EOF'\nx\nEOF\n)\" -t \(seal)", "git commit -m x -t \(seal)", "git commit -m x --template \(seal)"] {
            #expect(!worker.runsUnasked(command, cwd: repo), "worker: \(command)")
        }
    }

    /// A symlink committed inside the worktree that points outside: the text of the path is inside, the file isn't.
    /// Reads through it, directly, through a chain of links, from an absolute path, or by a flag that follows links
    /// while it recurses, print the secret; none runs unasked for any role. A link that stays inside still reads.
    @Test func aSymlinkInTheWorktreeThatPointsOutsidePrompts() throws {
        let scratch = temp.url("symlink").resolvingSymlinksInPath().path
        let secret = "SECRET-SEAL-VALUE"
        let privateDir = scratch + "/private", repo = scratch + "/repo"
        try FileManager.default.createDirectory(atPath: privateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try Data((secret + "\n").utf8).write(to: URL(fileURLWithPath: privateDir + "/seal"))
        _ = try run("git init -q -b main && mkdir sub && echo a > a && ln -s ../private/seal inner && ln -s inner chain"
                    + " && ln -s \(privateDir) linkdir && ln -s ../a sub/up && git add -A && git commit -qm links", in: repo)
        let leaks = ["head inner", "tail -n 3 chain", "grep -h SECRET linkdir/seal", "head \(repo)/linkdir/seal", "wc -c inner && head inner",
                     "grep -rS SECRET .", "rg -L SECRET .", "rg --follow SECRET ."]
        for command in leaks {
            let out = try run(command, in: repo)
            // rg isn't on every Mac: where it's missing its forms can't leak here, and the refusals below still hold.
            if command.hasPrefix("rg "), out.contains("rg: command not found") || out.contains("rg: not found") { continue }
            #expect(out.contains(secret), "not a leak: \(command): \(out)")
        }
        let roles = try [LeadLaunch.Role.lead, .worker, .verifier].map { try Role($0, root: repo, temp: temp) }
        for role in roles {
            for command in leaks + ["git diff --stat inner a", "head sub/../inner"] {
                #expect(!role.runsUnasked(command, cwd: repo), "\(role.role): \(command)")
            }
            for command in ["head sub/up", "head a", "grep -rn a ."] {
                #expect(role.runsUnasked(command, cwd: repo), "\(role.role): \(command)")
            }
        }
        // A link the line makes itself (the blind check's): a patch the worker wrote, applied, then read through in the
        // same line, after the hook resolved its paths. `git apply` only ends a line; before it, a link it makes isn't there.
        let patches = scratch + "/patches"
        try FileManager.default.createDirectory(atPath: patches, withIntermediateDirectories: true)
        _ = try run("git init -q && ln -s \(privateDir)/seal made && ln -s \(privateDir)/seal made2 && git add made && git diff --cached > \(repo)/one.patch"
                    + " && git reset -q && git add made2 && git diff --cached > \(repo)/two.patch", in: patches)
        let made = ["head -n 50 one.patch | git apply && head made", "head -n 50 two.patch | git apply | sort - made2"]
        let worker = try #require(roles.first { $0.role == .worker })
        #expect(!ReadOnlyCommand.allows(made[0], in: .init(root: repo, cwd: repo)))  // a read-only role has no git apply
        for command in made + ["head one.patch | git apply ; head made", "head one.patch | git apply -R || head made",
                               "head one.patch | git apply | git apply"] {
            #expect(!worker.runsUnasked(command, cwd: repo), "worker: \(command)")
        }
        #expect(worker.runsUnasked("head -n 50 one.patch | git apply", cwd: repo))
        #expect(worker.runsUnasked("git diff HEAD~0 HEAD -- a | git apply -R", cwd: repo))
        // Asked while the links aren't there yet, as the hook is; then run, each prints the secret.
        #expect(!FileManager.default.fileExists(atPath: repo + "/made") && !FileManager.default.fileExists(atPath: repo + "/made2"))
        for command in made {
            #expect(try run(command, in: repo).contains(secret), "not a leak: \(command)")
        }
        // A shell outside the worktree runs nothing unasked; nor does a worktree that isn't there.
        #expect(!ReadOnlyCommand.allows("git status", in: .init(root: repo, cwd: privateDir)))
        #expect(!ReadOnlyCommand.allows("git status", in: .init(root: scratch + "/gone", cwd: scratch + "/gone")))
        #expect(ReadOnlyCommand.allows("git status", in: .init(root: repo, cwd: repo + "/sub")))
    }
}
