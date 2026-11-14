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
        // The prompt from its file (on Linux, on the command line while it fits there: aRolesLaunchSettingsAreInlineOnLinux).
        #expect(launch.command.contains(Platform.Tools.roleSettingsInline ? "--append-system-prompt 'You are the lead.'"
                                            : "--append-system-prompt-file '\(launch.promptFile)'"))
        #expect(launch.command.contains("--mcp-config "))
        #expect(launch.command.contains("--settings "))
        #expect(launch.command.contains("--name 'lead-acme'"))
        #expect(launch.command.hasSuffix(" -- 'Say hello.'"))
        #expect(try LaunchArguments.prompt(in: launch.command) == "You are the lead.")
        let mcp = try LaunchArguments.json("--mcp-config", in: launch.command) as [String: Any]?
        let server = (mcp?["mcpServers"] as? [String: Any])?["vibeswitcher"] as? [String: Any]
        #expect(server?["command"] as? String == "/App/vibeswitcher-mcp")
        // Through its keeper, which starts it again if it stops (MCPKeeperTests).
        #expect(server?["args"] as? [String] == ["--keeper", "--role", "lead", "--root", root])
        let settings = try LaunchArguments.json("--settings", in: launch.command) as [String: Any]?
        let deny = (settings?["permissions"] as? [String: Any])?["deny"] as? [String] ?? []
        #expect(deny.contains("Edit") && deny.contains("Write") && deny.contains("Bash(git commit:*)"))
    }

    @Test func workersMayEditButNotTouchHistoryOrMain() throws {
        let root = try root()
        let launch = try LeadLaunch.prepare(role: .worker, root: root, task: "add-login", base: "claude", prompt: "p", start: "Go.",
                                            server: "/s", name: "worker-add-login", branch: "project-lead")
        let settings = try LaunchArguments.json("--settings", in: launch.command) as [String: Any]?
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
        let mcp = try LaunchArguments.json("--mcp-config", in: launch.command) as [String: Any]?
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
        let mcp = try LaunchArguments.json("--mcp-config", in: launch.command) as [String: Any]?
        let entry = (mcp?["mcpServers"] as? [String: Any])?["vibeswitcher"] as? [String: Any]
        // The session host knows which session holds the role: the tool server gets nothing that would make one.
        #expect(entry?["env"] == nil)
        #expect(Set(entry?.keys.map { $0 } ?? []) == ["command", "args"])
        // Its session's git takes no optional index.lock either; its commands run as branch code, with no auto-memory
        // (`LeadLaunch.verifierEnvironment`).
        let settings = try LaunchArguments.json("--settings", in: launch.command) as [String: Any]?
        #expect(settings?["env"] as? [String: String] == ["GIT_OPTIONAL_LOCKS": "0"].merging(LeadLaunch.verifierEnvironment(server: "/s")) { $1 })
        // On Linux none is left: each is on the command line (aRolesLaunchSettingsAreInlineOnLinux).
        for file in [launch.mcpFile, launch.promptFile, launch.settingsFile] {
            if Platform.Tools.roleSettingsInline { #expect(!FileManager.default.fileExists(atPath: file), "\(file)"); continue }
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
        let settings = try LaunchArguments.json("--settings", in: launch.command) as [String: Any]?
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
            let settings = try LaunchArguments.json("--settings", in: launch.command) as [String: Any]?
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
            let settings = try LaunchArguments.json("--settings", in: launch.command) as [String: Any]?
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
            let settings = try LaunchArguments.json("--settings", in: launch.command) as [String: Any]?
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
            let mcp = try LaunchArguments.json("--mcp-config", in: launch.command) as [String: Any]?
            #expect((mcp?["mcpServers"] as? [String: Any])?.keys.sorted() == ["vibeswitcher"])
            let settings = try LaunchArguments.json("--settings", in: launch.command)
            let permissions = try #require(settings["permissions"] as? [String: Any])
            // The rules don't pick the permission mode: the command line names it (eachRoleIsLaunchedInAutoModeByName).
            #expect(permissions.keys.sorted() == ["allow", "deny"])
            #expect(launch.command.contains("--permission-mode auto"))
            let allow = permissions["allow"] as? [String] ?? [], deny = permissions["deny"] as? [String] ?? []
            // 2.1.299+: `mcp__<server>__*` with the whole name; a bare `mcp__vibeswitcher` or a prefix no longer reads the same.
            #expect(allow.filter { $0.hasPrefix("mcp__") } == ["mcp__vibeswitcher__*"])
            #expect(!deny.contains { $0.hasPrefix("mcp__") })
            // git reads go to the role's hook (LeadLaunchOutsideReadsTests), not to a rule.
            #expect(!allow.contains("Bash(git log:*)") && settings["hooks"] != nil)
        }
    }

    // MARK: The roles' launch on Linux, and the permission mode (stage 2 Task 10b, the security document's S10)

    /// Each role names its permission mode, auto mode, the one it ran in when no launch named one (Claude Code's
    /// default since 2.1.284, still 2.1.323's: `LinuxLaunch.permissionMode`), on both systems: no longer whatever
    /// Claude Code's default or the user's `defaultMode` becomes. Once, after the project's command and the
    /// launch's settings, before `--name` and the start.
    @Test(arguments: [LeadLaunch.Role.lead, .worker, .verifier])
    func eachRoleIsLaunchedInAutoModeByName(role: LeadLaunch.Role) throws {
        let launch = try LeadLaunch.prepare(role: role, root: try root(), task: role == .lead ? nil : "x", base: "claude", prompt: "p",
                                            start: "Go.", server: "/s", name: "\(role.rawValue)-x", branch: "project-lead")
        let words = LaunchArguments.words(launch.command)
        #expect(words.filter { $0 == "--permission-mode" }.count == 1, "\(role): \(launch.command)")
        #expect(LaunchArguments.value("--permission-mode", in: launch.command) == "auto")
        let mode = try #require(words.firstIndex(of: "--permission-mode")), name = try #require(words.firstIndex(of: "--name"))
        #expect(mode < name && words.firstIndex(of: "--settings").map { $0 < mode } == true, "\(role): \(words.prefix(12))")
    }

    /// A project whose Claude command names a permission mode keeps it, as it did, and `claude` isn't given two.
    @Test func aProjectsOwnPermissionModeIsKept() throws {
        let root = try root()
        for base in ["claude --permission-mode manual", "claude --permission-mode=plan", "claude --dangerously-skip-permissions",
                     "claude --verbose --permission-mode bypassPermissions --model opus"] {
            for role in [LeadLaunch.Role.lead, .worker, .verifier] {
                let launch = try LeadLaunch.prepare(role: role, root: root, task: role == .lead ? nil : "x", base: base, prompt: "p",
                                                    start: "Go.", server: "/s", name: "\(role.rawValue)-x")
                #expect(!launch.command.contains("--permission-mode auto") && launch.command.hasPrefix(base + " "), "\(role): \(launch.command)")
                #expect(launch.command.components(separatedBy: "--permission-mode").count <= 2, "\(launch.command)")
            }
        }
        #expect(!LinuxLaunch.namesPermissionMode("claude --permission-modes x --allow-dangerously-skip-permissions"))
    }

    /// The rules Linux adds (`Platform.Tools.roleDenyRules`), as Claude Code permission rules, for every role.
    static let linuxRules = ["Bash(strace:*)", "Bash(ltrace:*)", "Bash(gdbserver:*)", "Bash(perf:*)", "Bash(systemctl --user:*)",
                             "Bash(systemd-run:*)", "Bash(loginctl:*)", "Bash(crontab:*)", "Bash(at:*)", "Bash(wsl.exe:*)", "Bash(cmd.exe:*)",
                             "Bash(powershell.exe:*)", "Bash(gh:*)", "Bash(git credential:*)", "Bash(git -c credential*)",
                             "Edit(~/.config/systemd/**)", "Write(~/.config/systemd/**)", "Edit(~/.config/environment.d/**)",
                             "Write(~/.config/environment.d/**)", "Edit(~/.vibeswitcher/v2/**)", "Write(~/.vibeswitcher/v2/**)",
                             "Edit(~/.vibeswitcher/lead/**)", "Write(~/.vibeswitcher/lead/**)",
                             "Read(//mnt/c/**)", "Edit(//mnt/c/**)", "Write(//mnt/c/**)"]

    /// Each role's rules as its session gets them, for the four shapes `prepare` is called with.
    func rulesOfEachRole() throws -> [(role: LeadLaunch.Role, deny: [String])] {
        let root = try root()
        let shapes: [(LeadLaunch.Role, String?, String?)] = [(.lead, nil, nil), (.worker, "project-lead", "docs/lead"), (.worker, nil, nil),
                                                              (.verifier, "project-lead", "docs/lead")]
        return try shapes.enumerated().map { index, shape in
            let launch = try LeadLaunch.prepare(role: shape.0, root: root, task: shape.0 == .lead ? nil : "x", base: "claude", prompt: "p",
                                                start: "Go.", server: "/s", name: "\(shape.0.rawValue)-\(index)", branch: shape.1, records: shape.2)
            let permissions = try #require(try LaunchArguments.json("--settings", in: launch.command)["permissions"] as? [String: Any])
            return (shape.0, permissions["deny"] as? [String] ?? [])
        }
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's rules; the Mac's are theMacsDenyRulesAreTodays"))
    func aRoleOnLinuxIsDeniedTracersTheUsersManagerWindowsAndGh() throws {
        for (role, deny) in try rulesOfEachRole() {
            for rule in Self.linuxRules { #expect(deny.contains(rule), "\(role): \(rule)") }
            for rule in Self.linuxRules { #expect(deny.filter { $0 == rule }.count == 1, "\(role): \(rule) twice") }
            for command in ["strace -p 1", "perf record -p 1", "systemctl --user restart vibeswitcher", "systemd-run --user sh",
                            "crontab -e", "at now", "wsl.exe -u root", "cmd.exe /c dir", "powershell.exe -c x", "gh pr list",
                            "gh auth token", "git credential fill", "git -c credential.helper=x push"] {
                #expect(LeadGuardRailsTests.denied(command, by: deny), "\(role): \(command)")
            }
            // Read by name: the node's own folders, and the Windows side's, which no rule lets through.
            #expect(!deny.contains { $0.hasPrefix("Read(/mnt") }, "\(role): /mnt/c is //mnt/c, from the root")
        }
    }

    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's rules; the Mac's lead has no debugger rules"))
    func theLeadOnLinuxGetsTheTracerRules() throws {
        let lead = try #require(try rulesOfEachRole().first { $0.role == .lead })
        for rule in LeadLaunch.debuggers + ["Bash(strace:*)", "Bash(ltrace:*)", "Bash(gdbserver:*)", "Bash(perf:*)"] {
            #expect(lead.deny.contains(rule), "\(rule)")
        }
        // Added after the rules both systems give, none twice (`Edit(~/.vibeswitcher/lead/**)` is one of those already).
        let all = LeadLaunch.deny(.lead), both = Self.withoutLinuxRules(all, .lead)
        #expect(all == both + (LeadLaunch.debuggers + Self.linuxRules).filter { !both.contains($0) })
    }

    /// `rules` (a role's) without the ones this system adds at their end (`LinuxLaunch.denyRules`): all of them.
    static func withoutLinuxRules(_ rules: [String], _ role: LeadLaunch.Role) -> [String] {
        let added = Set(Platform.Tools.roleDenyRules + (role == .lead && Platform.Tools.leadGetsTracerRules ? LeadLaunch.debuggers : []))
        var rules = rules
        while let last = rules.last, added.contains(last) { rules.removeLast() }
        return rules
    }

    /// The Mac's rules are the ones at 47636aaf, the commit stage 2's plan starts from, for each role (each list's
    /// SHA-256, its rules one a line): Linux's are added only where `Platform.Tools.roleDenyRules` has them, at the
    /// end. The rules both systems give are checked on both.
    @Test func theMacsDenyRulesAreTodays() throws {
        let recorded: [String: String] = [
            "lead": "f9a8bf505bc2a335acb239622cf0575f47bb40cfbf032c2f22585acd8dee016d",
            "worker-project-lead-docs/lead": "03a8e95f7c38fb3af67648cfab7bad491c015e4394cb861d46a8b0aedcbe6de7",
            "worker": "59c6eea671ff14ce0e2791c28cc9dd447fdddeb84ba7576572f6df80e8ba64e1",
            "verifier-project-lead-docs/lead": "8f05b04170bc7cfbd8e435b7546bb18860ab1b0eccf337e5d76dc3fa2e2d51ee",
        ]
        let shapes: [(LeadLaunch.Role, String?, String?)] = [(.lead, nil, nil), (.worker, "project-lead", "docs/lead"), (.worker, nil, nil),
                                                              (.verifier, "project-lead", "docs/lead")]
        for (role, base, records) in shapes {
            let key = ([role.rawValue] + [base, records].compactMap { $0 }).joined(separator: "-")
            let all = LeadLaunch.deny(role, base: base, records: records), both = Self.withoutLinuxRules(all, role)
            #expect(LeadVault.hash(both.joined(separator: "\n")) == recorded[key], "\(key): \(LeadVault.hash(both.joined(separator: "\n")))")
            if Platform.CodeIdentity.isAvailable { #expect(all == both, "\(key)") }
        }
        #expect(Platform.Tools.roleDenyRules.isEmpty == Platform.CodeIdentity.isAvailable)
        #expect(Platform.Tools.leadGetsTracerRules != Platform.CodeIdentity.isAvailable)
        #expect(Platform.Tools.roleSettingsInline != Platform.CodeIdentity.isAvailable)
    }

    /// The words `command` gives a program, as bash itself splits it: `claude` (its first word) replaced by a function
    /// that prints each argument it gets.
    static func argumentsAsBashGivesThem(_ command: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        let line = "f() { printf '%s\\0' \"$@\"; }; f" + command.dropFirst("claude".count)
        process.arguments = ["--noprofile", "--norc", "-c", line]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        #expect(waitForEnd(process) && process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// On Linux a role's settings and MCP configuration are `claude`'s arguments, as JSON, and so is its prompt while the
    /// command fits one argument (128 KiB here): no file is left in its run folder for a worker to rewrite before
    /// `claude` reads it. A prompt too long for that stays its file (the security document's S11, item 7).
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's inline launch; the Mac's are files"))
    func aRolesLaunchSettingsAreInlineOnLinux() throws {
        let root = try root()
        let prompt = "You're the worker: don't stop.\nIt's \"quoted\", $HOME and `id` stay as they are; \\ too. ✓"
        for role in [LeadLaunch.Role.lead, .worker, .verifier] {
            let folder = temp.url("inline-\(role.rawValue)")
            let task: String? = role == .lead ? nil : "x"
            let launch = try LeadLaunch.prepare(role: role, root: root, task: task, base: "claude", prompt: prompt, start: "Go.",
                                                server: "/opt/vibe switcher/vibeswitcher-mcp", name: "\(role.rawValue)-x",
                                                branch: "project-lead", records: "docs/lead", folder: folder)
            // Nothing in the run folder: the files `prepare` wrote are gone.
            #expect((try FileManager.default.contentsOfDirectory(atPath: folder.path)).isEmpty, "\(role)")
            for file in [launch.settingsFile, launch.mcpFile, launch.promptFile] { #expect(!FileManager.default.fileExists(atPath: file)) }
            // As bash hands them to claude: the prompt as it was, and both JSON objects as they were written.
            let words = try Self.argumentsAsBashGivesThem(launch.command)
            func after(_ flag: String) -> String? { words.firstIndex(of: flag).flatMap { $0 + 1 < words.count ? words[$0 + 1] : nil } }
            #expect(after("--append-system-prompt") == prompt, "\(role)")
            #expect(!words.contains("--append-system-prompt-file") && after("--mcp-config")?.hasPrefix("{") == true)
            let mcp = try #require(try JSONSerialization.jsonObject(with: Data((after("--mcp-config") ?? "").utf8)) as? [String: Any])
            let entry = try #require((mcp["mcpServers"] as? [String: Any])?["vibeswitcher"] as? [String: Any])
            #expect(entry["command"] as? String == "/opt/vibe switcher/vibeswitcher-mcp")
            #expect(entry["args"] as? [String] == [MCPKeeper.flag, "--role", role.rawValue, "--root", root] + (task.map { ["--task", $0] } ?? []))
            let settings = try #require(try JSONSerialization.jsonObject(with: Data((after("--settings") ?? "").utf8)) as? [String: Any])
            let permissions = try #require(settings["permissions"] as? [String: Any])
            #expect(permissions["deny"] as? [String] == LeadLaunch.deny(role, base: "project-lead", records: "docs/lead"), "\(role)")
            #expect(permissions["allow"] as? [String] == LeadLaunch.allow(role, base: "project-lead") + LeadLaunch.evidenceReads(role, root: root, task: task),
                    "\(role)")
            let hooks = LeadLaunch.hooks(role, server: "/opt/vibe switcher/vibeswitcher-mcp", root: task.map { Worktrees.path(root: root, slug: $0) } ?? root)
            #expect(try LinuxLaunch.json(settings["hooks"] as? [String: Any] ?? [:]) == LinuxLaunch.json(hooks), "\(role)")
            #expect(settings["statusLine"] != nil && (settings["env"] as? [String: String])?["GIT_OPTIONAL_LOCKS"] == "0")
            #expect(words.last == "Go." && words[words.count - 2] == "--")
        }

        // A prompt too long for one argument stays its file, which `claude` is given; the settings are still inline.
        let long = String(repeating: "Check every line. ", count: 8 * 1024)
        #expect(long.utf8.count > LinuxLaunch.argumentLimit)
        let folder = temp.url("inline-long")
        let launch = try LeadLaunch.prepare(role: .worker, root: root, task: "x", base: "claude", prompt: long, start: "Go.", server: "/s",
                                            name: "worker-long", folder: folder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["prompt.md"])
        #expect(try String(contentsOfFile: launch.promptFile, encoding: .utf8) == long)
        #expect(LaunchArguments.value("--append-system-prompt-file", in: launch.command) == launch.promptFile)
        #expect(LaunchArguments.value("--settings", in: launch.command)?.hasPrefix("{") == true)
        #expect(LaunchArguments.value("--mcp-config", in: launch.command)?.hasPrefix("{") == true)
        #expect(launch.command.utf8.count < LinuxLaunch.argumentLimit - LinuxLaunch.argumentRoom)
        // Just under: inline, the whole command within the limit.
        let fits = try LeadLaunch.prepare(role: .worker, root: root, task: "x", base: "claude", prompt: "", start: "Go.", server: "/s",
                                          name: "worker-fits", folder: temp.url("inline-fits"))
        let room = LinuxLaunch.argumentLimit - LinuxLaunch.argumentRoom - fits.command.utf8.count
        let most = try LeadLaunch.prepare(role: .worker, root: root, task: "x", base: "claude", prompt: String(repeating: "a", count: room),
                                          start: "Go.", server: "/s", name: "worker-fits", folder: temp.url("inline-most"))
        #expect(most.command.utf8.count == LinuxLaunch.argumentLimit - LinuxLaunch.argumentRoom)
        #expect(!FileManager.default.fileExists(atPath: most.promptFile) && LaunchArguments.value("--append-system-prompt", in: most.command)?.count == room)
        let over = try LeadLaunch.prepare(role: .worker, root: root, task: "x", base: "claude", prompt: String(repeating: "a", count: room + 1),
                                          start: "Go.", server: "/s", name: "worker-fits", folder: temp.url("inline-over"))
        #expect(FileManager.default.fileExists(atPath: over.promptFile) && over.command.contains("--append-system-prompt-file"))
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
            let settings = try LaunchArguments.json("--settings", in: launch.command)
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
        #if os(Linux)
        // Linux has no /var/empty: an empty folder of the test's own, outside the worktree as that one is.
        let empty = scratch + "/empty"
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        #else
        let empty = "/var/empty"
        #endif
        // Each prints the secret when run (checked below), so each is a real way to read it.
        let leaks = [
            // The first report: --no-index, and a path outside the work tree (git then compares without it).
            "git diff --no-index \(empty) \(privateDir)", "git diff /dev/null \(seal)", "git diff ../private/seal a",
            "git diff sub/../../private/seal a", "git diff \"\(seal)\" a",
            // F1: global options before the command.
            "git -P diff /dev/null \(seal)", "git --no-pager diff --no-index /dev/null \(seal)",
            "git --literal-pathspecs diff /dev/null ../private/seal",
            // F2: a bare `..`.
            "git diff \(empty) ..", "git diff .. \(empty)",
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
            #expect(LeadGuardRailsTests.denied("git diff --no-index \(empty) \(privateDir)", by: role.deny))
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
        #if os(Linux)
        // GNU grep goes into the links it meets as it recurses with -R; BSD grep's -S is no option of it.
        let followingGrep = "grep -R SECRET ."
        #else
        let followingGrep = "grep -rS SECRET ."
        #endif
        let leaks = ["head inner", "tail -n 3 chain", "grep -h SECRET linkdir/seal", "head \(repo)/linkdir/seal", "wc -c inner && head inner",
                     followingGrep, "rg -L SECRET .", "rg --follow SECRET ."]
        for command in leaks {
            let out = try run(command, in: repo)
            // rg isn't on every Mac: where it's missing its forms can't leak here, and the refusals below still hold.
            // (Not on PATH: dash says "Permission denied" for it when a folder of PATH can't be searched.)
            if command.hasPrefix("rg "), Platform.Tools.find("rg") == nil || out.contains("rg: command not found") || out.contains("rg: not found") { continue }
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
        #if os(Linux)
        // GNU sort checks that each of its files can be read before it reads its input (git apply's, still running):
        // cat reads them in turn, as the Mac's sort does.
        let readAfter = "cat - made2"
        #else
        let readAfter = "sort - made2"
        #endif
        let made = ["head -n 50 one.patch | git apply && head made", "head -n 50 two.patch | git apply | \(readAfter)"]
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
