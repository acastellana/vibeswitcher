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
                                            server: "/s", name: "worker-add-login")
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any]
        let deny = (settings?["permissions"] as? [String: Any])?["deny"] as? [String] ?? []
        #expect(!deny.contains("Edit"))
        for rule in ["Bash(git push:*)", "Bash(git merge:*)", "Bash(git rebase:*)", "Bash(git reset --hard:*)", "Bash(git switch main:*)", "Bash(git branch -D:*)"] {
            #expect(deny.contains(rule), "missing \(rule)")
        }
        let mcp = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.mcpFile))) as? [String: Any]
        let args = ((mcp?["mcpServers"] as? [String: Any])?["vibeswitcher"] as? [String: Any])?["args"] as? [String]
        #expect(args == ["--role", "worker", "--root", root, "--task", "add-login"])
        #expect(launch.promptFile.contains("/.vibeswitcher/run/worker-add-login/"))
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
