import Foundation

/// How the lead, a worker or a verifier is started: the project's Claude command plus its role's prompt, the
/// VibeSwitcher tool server (with the role's capability, see `LeadVault`) and its permission rules, kept as data in
/// the role's run folder.
public enum LeadLaunch {
    public enum Role: String, Codable, Sendable { case lead, worker, verifier }

    public struct Prepared: Equatable, Sendable {
        public var command: String
        public var promptFile: String
        public var mcpFile: String
        public var settingsFile: String
    }

    static let readOnly = ["Edit", "Write", "NotebookEdit"]
    static let gitWrites = ["Bash(git commit:*)", "Bash(git add:*)", "Bash(git push:*)", "Bash(git merge:*)", "Bash(git rebase:*)",
                            "Bash(git reset:*)", "Bash(git checkout:*)", "Bash(git switch:*)", "Bash(git stash:*)", "Bash(git branch -D:*)",
                            "Bash(git branch -d:*)", "Bash(git worktree:*)", "Bash(git tag:*)", "Bash(git commit-tree:*)",
                            "Bash(git cherry-pick:*)", "Bash(git revert:*)", "Bash(git am:*)", "Bash(git apply:*)", "Bash(git restore:*)",
                            "Bash(git clean:*)", "Bash(git rm:*)", "Bash(git mv:*)", "Bash(git notes:*)", "Bash(git branch -f:*)",
                            "Bash(git branch --force:*)", "Bash(git branch -m:*)", "Bash(git branch -M:*)"]
    /// git with options before its command (`git -C . push`, `git -c alias.x=push x`), plumbing that moves refs, and
    /// git under another name: what prefix rules on `git <command>` don't see. Rules are a speed bump; `merge`
    /// checks the lead's branch itself.
    static let gitAround = ["Bash(git -C:*)", "Bash(git -c:*)", "Bash(git --git-dir:*)", "Bash(git --work-tree:*)",
                            "Bash(git --exec-path:*)", "Bash(git update-ref:*)", "Bash(git symbolic-ref:*)", "Bash(git config:*)",
                            "Bash(git fetch:*)", "Bash(git pull:*)", "Bash(git replace:*)", "Bash(git filter-branch:*)",
                            "Bash(env git:*)", "Bash(command git:*)", "Bash(/usr/bin/git:*)", "Bash(xcrun git:*)"]
    /// Shell commands that write files, for the roles that only read.
    static let fileWrites = ["Bash(sed -i:*)", "Bash(perl -i:*)", "Bash(perl -pi:*)", "Bash(perl -e:*)", "Bash(tee:*)", "Bash(dd:*)",
                             "Bash(truncate:*)", "Bash(cp:*)", "Bash(mv:*)", "Bash(rm:*)", "Bash(ln:*)", "Bash(touch:*)", "Bash(install:*)",
                             "Bash(rsync:*)", "Bash(patch:*)", "Bash(python -c:*)", "Bash(python3 -c:*)", "Bash(ruby -e:*)",
                             "Bash(node -e:*)", "Bash(osascript:*)", "Bash(cat >:*)", "Bash(echo >:*)", "Bash(printf >:*)"]
    /// VibeSwitcher's private files (the team's capabilities, the seal on your messages): no role's tools touch them.
    static let privateFiles = ["Read(~/.vibeswitcher/lead/**)", "Edit(~/.vibeswitcher/lead/**)",
                               "Read(~/.vibeswitcher/steer/**)", "Edit(~/.vibeswitcher/steer/**)"]

    /// What each role may not do.
    public static func deny(_ role: Role, base: String? = nil) -> [String] {
        switch role {
        case .lead, .verifier:
            return readOnly + gitWrites + gitAround + fileWrites + privateFiles
        case .worker:
            // Edits and commits on its own branch; nothing that rewrites history or touches the lead's branch.
            let protected: [String] = Array(Set(["main", "master"] + (base.map { [$0] } ?? []))).sorted()
            var rules: [String] = ["Bash(git push:*)", "Bash(git merge:*)", "Bash(git rebase:*)", "Bash(git reset --hard:*)"]
            rules += protected.flatMap { ["Bash(git checkout \($0):*)", "Bash(git switch \($0):*)"] }
            // Ways onto a branch checked out elsewhere, or of moving one, that the rules above don't name.
            rules += ["Bash(git checkout -B:*)", "Bash(git checkout --ignore-other-worktrees:*)", "Bash(git switch -C:*)",
                      "Bash(git switch --ignore-other-worktrees:*)", "Bash(git branch -f:*)", "Bash(git branch --force:*)",
                      "Bash(git branch -m:*)", "Bash(git branch -M:*)", "Bash(git commit-tree:*)"]
            rules += ["Bash(git branch -D:*)", "Bash(git branch -d:*)", "Bash(git worktree:*)", "Bash(git tag:*)", "Bash(git commit --amend:*)"]
            return rules + gitAround + privateFiles
        }
    }

    /// Writes the role's files (0600) and returns the command line to run. They go in `folder`: the vault's run folder
    /// for the role (`LeadVault.runFolder`, out of the team's reach, since the tool server's entry holds the role's
    /// `capability`); `<root>/.vibeswitcher/run/<name>/` when none is given.
    public static func prepare(role: Role, root: String, task: String?, base: String, prompt: String, start: String,
                               server: String, name: String, model: String? = nil, branch: String? = nil,
                               capability: String? = nil, folder: URL? = nil) throws -> Prepared {
        let folder = folder?.path ?? (root as NSString).appendingPathComponent(".vibeswitcher/run/\(name)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let promptFile = (folder as NSString).appendingPathComponent("prompt.md")
        let mcpFile = (folder as NSString).appendingPathComponent("mcp.json")
        let settingsFile = (folder as NSString).appendingPathComponent("settings.json")
        try LeadVault.writePrivate(Data(prompt.utf8), to: URL(fileURLWithPath: promptFile))
        // The role and task here are only what the server expects; it takes both from its capability.
        var args = ["--role", role.rawValue, "--root", root]
        if let task { args += ["--task", task] }
        var entry: [String: Any] = ["command": server, "args": args]
        if let capability { entry["env"] = [LeadVault.environmentKey: capability] }
        let mcp: [String: Any] = ["mcpServers": ["vibeswitcher": entry]]
        try LeadVault.writePrivate(try JSONSerialization.data(withJSONObject: mcp, options: [.prettyPrinted, .sortedKeys]),
                                   to: URL(fileURLWithPath: mcpFile))
        let settings: [String: Any] = ["permissions": ["deny": deny(role, base: branch)]]
        try LeadVault.writePrivate(try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
                                   to: URL(fileURLWithPath: settingsFile))
        let quote = RecentProjects.shellQuote
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        var parts = [trimmed.isEmpty ? "claude" : trimmed]
        // From its file, so the prompt's length and characters never matter on the command line.
        parts.append("--append-system-prompt-file \(quote(promptFile))")
        parts.append("--mcp-config \(quote(mcpFile))")
        parts.append("--settings \(quote(settingsFile))")
        // A verifier checks a branch a worker wrote: that branch's project settings, hooks and MCP servers don't run
        // in it (its rules come from --settings, VibeSwitcher's hooks from your user settings).
        if role == .verifier { parts.append("--setting-sources user --strict-mcp-config") }
        parts.append("--name \(quote(name))")
        if let model { parts.append("--model \(quote(model))") }
        parts.append("-- \(quote(start))")
        return Prepared(command: parts.joined(separator: " "), promptFile: promptFile, mcpFile: mcpFile, settingsFile: settingsFile)
    }

    /// The `--name` a command line from `prepare` gives its session (Claude writes it into the transcript).
    public static func name(inCommand command: String) -> String? {
        guard let range = command.range(of: #"--name '[^']*'"#, options: .regularExpression) else { return nil }
        let name = String(command[range].dropFirst("--name '".count).dropLast())
        return name.isEmpty ? nil : name
    }
}
