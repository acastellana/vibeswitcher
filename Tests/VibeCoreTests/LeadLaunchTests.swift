import Foundation
import Testing
@testable import VibeCore

struct LeadLaunchTests {
    func root() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
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
        #expect(server?["args"] as? [String] == ["--role", "lead", "--root", root])
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
        let mcp = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.mcpFile))) as? [String: Any]
        let args = ((mcp?["mcpServers"] as? [String: Any])?["vibeswitcher"] as? [String: Any])?["args"] as? [String]
        #expect(args == ["--role", "worker", "--root", root, "--task", "add-login"])
        #expect(launch.promptFile.contains("/.vibeswitcher/run/worker-add-login/"))
    }

    @Test func theCapabilityGoesToTheToolServerOnlyInPrivateFiles() throws {
        let root = try root()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID().uuidString)/verify-x")
        let launch = try LeadLaunch.prepare(role: .verifier, root: root, task: "x", base: "claude", prompt: "p", start: "Check.",
                                            server: "/s", name: "verify-x", capability: "secret", folder: folder)
        #expect(launch.mcpFile.hasPrefix(folder.path))
        let mcp = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.mcpFile))) as? [String: Any]
        let entry = (mcp?["mcpServers"] as? [String: Any])?["vibeswitcher"] as? [String: Any]
        #expect((entry?["env"] as? [String: String])?[LeadVault.environmentKey] == "secret")
        // Never on the command line (other processes see that).
        #expect(!launch.command.contains("secret"))
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
}
