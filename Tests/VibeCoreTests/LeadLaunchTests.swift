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
        for rule in ["Bash(git rebase project-lead)", "Bash(git rebase --continue)", "Bash(git merge project-lead)", "Bash(git log:*)"] {
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
        // Its session's git takes no optional index.lock either.
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any]
        #expect(settings?["env"] as? [String: String] == ["GIT_OPTIONAL_LOCKS": "0"])
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
                     "Edit(~/.vibeswitcher/policy.md)", "Write(~/.vibeswitcher/policy.md)"]
        for role in [LeadLaunch.Role.lead, .worker, .verifier] {
            let launch = try LeadLaunch.prepare(role: role, root: root, task: role == .lead ? nil : "fix", base: "claude",
                                                prompt: "p", start: "s", server: "/App/vibeswitcher-mcp", name: "\(role.rawValue)-fix")
            let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any]
            let deny = (settings?["permissions"] as? [String: Any])?["deny"] as? [String] ?? []
            for rule in rules { #expect(deny.contains(rule), "\(role): \(rule)") }
            #expect(!((settings?["permissions"] as? [String: Any])?["allow"] as? [String] ?? []).contains { $0.contains("mac-limits") || $0.contains("policy.md") })
        }
        // The app's own writes (Settings' save) go through, as before.
        let file = URL(fileURLWithPath: root).appendingPathComponent("home/mac-limits.json")
        try MacLimits(maxSessions: 8).save(to: file)
        #expect(MacLimits.load(from: file).maxSessions == 8)
        let policy = URL(fileURLWithPath: root).appendingPathComponent("home/policy.md")
        try WorkingPolicy.save("- Be brief.", to: policy)
        #expect(WorkingPolicy.load(from: policy) == "- Be brief.")
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
            #expect(allow.contains("Bash(git log:*)"))
        }
    }
}
