import Foundation
import Testing
import VibeCore

/// The incident of 2026-10-31 and 2026-11-01 (docs/lead/incidents.md), end to end for its part (a): a verifier's
/// settings, as `LeadLaunch.prepare` writes them for an audit, let the finder's read-only command line run without a
/// permission prompt. Its allow rules, or else the `PermissionRequest` hook in them, run here as Claude Code runs it
/// (`/bin/sh -c`, the event's JSON on stdin) with the built tool server; anything else still prompts.
@Suite(.serialized) struct VerifierHookTests {
    let temp = Scratch()

    /// The second incident's command (crypto-hardening-harness's finder, 2026-11-01 00:31), and other read-only lines.
    static let readOnly = [
        "git ls-files -s package.json; git remote -v; git branch -r | grep origin/main; grep -n lodash package-lock.json",
        "git log --oneline -5 && git status --short", "git cat-file -p HEAD | head -5", "rg -n TODO Sources | wc -l",
    ]
    /// What still prompts (the witness declines it once no one has answered: `LeadWitness.stuckPrompts`).
    static let prompting = ["git config user.name x", "git log > out.txt", "git branch -D main", "git log $(rm -rf x)", "ls; git log",
                            "git diff --no-index /var/empty ~/.vibeswitcher/lead", "head ../../x", "git -P log"]

    @Test func theVerifiersSettingsLetReadOnlyCommandLinesRunWithoutAPrompt() async throws {
        let mcp = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().appendingPathComponent("vibeswitcher-mcp").path
        #expect(FileManager.default.isExecutableFile(atPath: mcp), "no built tool server at \(mcp)")
        let root = temp.url("verifier-hook").path
        // The worktree the audit runs in, where the hook confines its paths (the event's cwd).
        let worktree = Worktrees.path(root: root, slug: "audit-me")
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        let launch = try LeadLaunch.prepare(role: .verifier, root: root, task: "audit-me", base: "claude", prompt: "p", start: "Check.",
                                            server: mcp, name: "verifier-audit-me", temporary: temp.url("session-tmp"))
        let settings = try LaunchArguments.json("--settings", in: launch.command)
        let allow = ((settings["permissions"] as? [String: Any])?["allow"] as? [String]) ?? []
        let hooks = (((settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]) ?? [])
            .filter { ($0["matcher"] as? String).map { $0 == "Bash" || $0 == "*" || $0.isEmpty } ?? true }
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }

        for line in Self.readOnly {
            #expect(try await runsWithoutAPrompt(line, allow: allow, hooks: hooks, cwd: worktree),
                    "`\(line)` waits on a permission prompt no one answers (allow rules \(allow), PermissionRequest hooks \(hooks))")
        }
        // The hook allows none of these (the allow rules are as they were, and Claude Code's own parser keeps a
        // redirection or a substitution from matching them).
        #expect(!hooks.isEmpty)
        for line in Self.prompting {
            for hook in hooks { #expect(try await !hookAllows(hook, line, cwd: worktree), "`\(line)` runs without a prompt") }
        }
    }

    /// Whether Claude Code runs `line` without asking: each of its parts (split at `;`, `&&`, `||`, `|`) matches an
    /// allow rule (`Bash(<prefix>:*)` or `Bash(<command>)`), or a `PermissionRequest` hook answers allow.
    func runsWithoutAPrompt(_ line: String, allow: [String], hooks: [String], cwd: String) async throws -> Bool {
        let parts = line.replacingOccurrences(of: "&&", with: ";").replacingOccurrences(of: "||", with: ";")
            .replacingOccurrences(of: "|", with: ";").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let byRules = parts.allSatisfy { part in
            allow.contains { rule in
                guard rule.hasPrefix("Bash("), rule.hasSuffix(")") else { return false }
                let body = String(rule.dropFirst(5).dropLast())
                return body.hasSuffix(":*") ? part.hasPrefix(String(body.dropLast(2))) : part == body
            }
        }
        if byRules { return true }
        for hook in hooks where try await hookAllows(hook, line, cwd: cwd) { return true }
        return false
    }

    /// Runs `hook` as Claude Code does for a Bash call of `line` from the shell's folder `cwd`, and reads its answer.
    func hookAllows(_ hook: String, _ line: String, cwd: String) async throws -> Bool {
        let event: [String: Any] = ["session_id": "s", "hook_event_name": "PermissionRequest", "cwd": cwd, "permission_mode": "default",
                                    "tool_name": "Bash", "tool_input": ["command": line, "description": "probe"]]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", hook]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: event))
        try input.fileHandleForWriting.close()
        // The tool's run read to its end and waited for on a thread of its own, not the cooperative pool.
        let answer = await offPool { () -> Data in
            let read = output.fileHandleForReading.readDataToEndOfFile()
            waitForEnd(process)
            return read
        }
        guard process.terminationStatus == 0, !answer.isEmpty,
              let object = try JSONSerialization.jsonObject(with: answer) as? [String: Any],
              let decision = (object["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any] else { return false }
        return decision["behavior"] as? String == "allow"
    }
}
