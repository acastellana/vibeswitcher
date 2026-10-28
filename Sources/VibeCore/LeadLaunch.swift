import Foundation

/// How the lead, a worker or a verifier is started: the project's Claude command plus its role's prompt, the
/// VibeSwitcher tool server and its permission rules, kept as data in the role's run folder. The role itself isn't in
/// them: the session host knows which session holds it (see `LeadVault`).
public enum LeadLaunch {
    public enum Role: String, Codable, Sendable { case lead, worker, verifier }

    public struct Prepared: Equatable, Sendable {
        public var command: String
        public var promptFile: String
        public var mcpFile: String
        public var settingsFile: String
        /// What the session's environment adds (`SpawnRequest.env`): its TMPDIR, a folder of its own (see `SessionTemp`).
        public var environment: [String: String] = [:]
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
                             "Bash(node -e:*)", "Bash(osascript:*)", "Bash(cat >:*)", "Bash(echo >:*)", "Bash(printf >:*)",
                             "Bash(git * --output*)"]
    /// VibeSwitcher's private files (the team's capabilities, the seal on your messages): no role's tools touch them.
    static let privateFiles = ["Read(~/.vibeswitcher/lead/**)", "Edit(~/.vibeswitcher/lead/**)",
                               "Read(~/.vibeswitcher/steer/**)", "Edit(~/.vibeswitcher/steer/**)"]

    /// The user's own settings for every project, edited in Settings › Project lead (the app writes them; no role's
    /// session does): the Mac-wide limits on sessions and load (`MacLimits`) and the working policy (`WorkingPolicy`).
    /// They aren't among the vault's guarded settings, so a worker that wrote them could raise its own cap.
    static let userSettings = ["Edit(~/.vibeswitcher/mac-limits.json)", "Write(~/.vibeswitcher/mac-limits.json)",
                               "Edit(~/.vibeswitcher/policy.md)", "Write(~/.vibeswitcher/policy.md)"]

    /// Killing by name. Its pattern matches every command line it's in, other sessions' too: on 2026-10-17 a worker's
    /// `pkill -f "cat" -n` (BSD pkill takes the `-n` as a second pattern) ended three workers, two verifiers (each
    /// role's `--name`), every tool server and the app ("cat" is in /Applications). `kill <pid>` stays open.
    static let killsByName = ["Bash(pkill:*)", "Bash(killall:*)", "Bash(/usr/bin/pkill:*)", "Bash(/usr/bin/killall:*)"]

    /// Debuggers and the other tools that take another process's task port (task_for_pid). With Developer mode off,
    /// macOS asks for the user's password in a "Developer Tools Access" dialog on their screen, and every leaks and
    /// sample on the Mac waits behind it: on 2026-10-23 a worker's lldb stalled two merges. The test suite's own leak
    /// checks run them from inside the tests, which these rules don't see (`LeadPrompts.debuggers`).
    static let debuggers = ["Bash(lldb:*)", "Bash(xcrun lldb:*)", "Bash(/usr/bin/lldb:*)", "Bash(debugserver:*)", "Bash(gdb:*)",
                            "Bash(sample:*)", "Bash(/usr/bin/sample:*)", "Bash(leaks:*)", "Bash(/usr/bin/leaks:*)", "Bash(heap:*)",
                            "Bash(vmmap:*)", "Bash(malloc_history:*)", "Bash(dtrace:*)", "Bash(dtruss:*)",
                            "Bash(sudo dtrace:*)", "Bash(sudo dtruss:*)"]

    /// What each role may not do. `records`: the workflow's `records_dir`, which only the lead's tool server writes
    /// (and commits to the base branch): a worker editing it would conflict with those commits.
    public static func deny(_ role: Role, base: String? = nil, records: String? = nil) -> [String] {
        switch role {
        case .lead:
            return readOnly + gitWrites + gitAround + fileWrites + privateFiles + userSettings + killsByName
        case .verifier:
            return readOnly + gitWrites + gitAround + fileWrites + privateFiles + userSettings + killsByName + debuggers
        case .worker:
            // Edits and commits on its own branch, and brings it up to date with the lead's (`git merge <base>`, what
            // the brief gives, or `git rebase <base>`); nothing that moves the lead's branch or another one. Rebase and merge only move
            // the branch checked out here, which can't be another: a second branch named after `git rebase` would
            // be checked out and rebased.
            let protected: [String] = Array(Set(["main", "master"] + (base.map { [$0] } ?? []))).sorted()
            var rules: [String] = ["Bash(git push:*)", "Bash(git rebase * *)", "Bash(git rebase --update-refs:*)"]
            // Onto another branch, or this one reset hard to another (that only moves this branch, but drops its work).
            for branch in protected + ["agent/"] {
                let name = branch.hasSuffix("/") ? branch + "*" : branch
                rules += ["Bash(git checkout \(name))", "Bash(git checkout \(name) *)", "Bash(git checkout * \(name))",
                          "Bash(git switch \(name))", "Bash(git switch \(name) *)", "Bash(git switch * \(name))",
                          "Bash(git reset --hard \(branch))", "Bash(git reset --hard \(branch)*)"]
            }
            // Ways onto a branch checked out elsewhere, or of moving one, that the rules above don't name.
            rules += ["Bash(git checkout -B:*)", "Bash(git checkout --ignore-other-worktrees:*)", "Bash(git switch -C:*)",
                      "Bash(git switch --ignore-other-worktrees:*)", "Bash(git branch -f:*)", "Bash(git branch --force:*)",
                      "Bash(git branch -m:*)", "Bash(git branch -M:*)", "Bash(git commit-tree:*)"]
            rules += ["Bash(git branch -D:*)", "Bash(git branch -d:*)", "Bash(git worktree:*)", "Bash(git tag:*)", "Bash(git commit --amend:*)"]
            if let records {
                rules += ["Edit(\(records)/**)", "Write(\(records)/**)", "Bash(git add \(records)*)", "Bash(git rm \(records)*)",
                          "Bash(git rm * \(records)*)"]
            }
            return rules + gitAround + privateFiles + userSettings + killsByName + debuggers
        }
    }

    /// The git commands `deny` refuses `role`, as its prompt lists them: each `Bash(...)` rule that runs git, without
    /// its `:*` ("git worktree", "git checkout * main", "env git"). Made from the rules, so the list never drifts from them.
    public static func deniedGit(_ role: Role, base: String? = nil, records: String? = nil) -> [String] {
        var seen = Set<String>()
        return deny(role, base: base, records: records).compactMap { rule -> String? in
            guard rule.hasPrefix("Bash("), rule.hasSuffix(")") else { return nil }
            var command = String(rule.dropFirst("Bash(".count).dropLast())
            if command.hasSuffix(":*") { command.removeLast(2) }
            guard command.hasPrefix("git ") || command.hasSuffix(" git") || command.hasSuffix("/git") else { return nil }
            return seen.insert(command).inserted ? command : nil
        }
    }

    /// The VibeSwitcher tool server's tools, by the server's whole name (Claude Code 2.1.299+ reads `mcp__<server>__*`
    /// as that server only). Which tools a role gets is its capability's business (see `LeadVault`).
    static let ownTools = "mcp__vibeswitcher__*"

    /// What each role may do without asking, the deny rules permitting: its VibeSwitcher tools (they never wait on a
    /// prompt, whether or not auto mode, the default since Claude Code 2.1.284, is on), reading git at any time
    /// (after a denied command too), and for a worker, committing, removing a file its change deletes (`git rm`: only
    /// files git tracks in this checkout, so nothing outside its worktree), bringing its branch up to date with `base`,
    /// and taking a fix out of its worktree and putting it back (`git diff <commit> HEAD -- <files> | git apply -R`, the
    /// patch from git on its input: `LeadPrompts.Policy.regressionTest`).
    public static func allow(_ role: Role, base: String? = nil) -> [String] {
        let reads = [ownTools, "Bash(git log:*)", "Bash(git diff:*)", "Bash(git status:*)", "Bash(git show:*)", "Bash(git rev-parse:*)",
                     "Bash(git merge-base:*)", "Bash(git ls-files:*)", "Bash(git blame:*)", "Bash(git branch --show-current)"]
        guard role == .worker else { return reads }
        var rules = reads + ["Bash(git add:*)", "Bash(git commit:*)", "Bash(git rm:*)", "Bash(git rebase --continue)", "Bash(git rebase --abort)",
                             "Bash(git rebase --skip)", "Bash(git merge --continue)", "Bash(git merge --abort)", "Bash(git apply -R)", "Bash(git apply)"]
        if let base { rules += ["Bash(git rebase \(base))", "Bash(git merge \(base))", "Bash(git merge --no-edit \(base))"] }
        return rules
    }

    /// The environment a role's session (and every command it runs) starts with. A worker's git never opens an
    /// editor: `git rebase --continue`, `git merge --continue` and the `git commit` that ends a merge keep their
    /// message as it is, so the bare commands its rules allow are all it needs (a `GIT_EDITOR=true git ...` prefix
    /// matches no rule and is refused).
    /// No role's `git status` takes index.lock (`GIT_OPTIONAL_LOCKS`), its status line's included: Claude Code stops
    /// a status line it gives up on with TERM, then SIGKILL about 2 s later, and on a busy Mac a `git status` killed
    /// so leaves a 0-byte lock that blocks every commit and merge in that checkout (2026-10-18).
    public static func environment(_ role: Role) -> [String: String] {
        ["GIT_OPTIONAL_LOCKS": "0"].merging(role == .worker ? ["GIT_EDITOR": "true"] : [:]) { $1 }
    }

    /// Writes the role's files (0600) and returns the command line to run. They go in `folder`: the vault's run folder
    /// for the role (`LeadVault.runFolder`, outside the repository); `<root>/.vibeswitcher/run/<name>/` when none is given.
    /// The session's TMPDIR is made under `temporary` for `cwd`, where it's started (the task's worktree, else `root`):
    /// what its swift builds and tests leave there goes with it (see `SessionTemp`).
    public static func prepare(role: Role, root: String, task: String?, base: String, prompt: String, start: String,
                               server: String, name: String, model: String? = nil, branch: String? = nil,
                               records: String? = nil, folder: URL? = nil, cwd: String? = nil,
                               temporary: URL = SessionTemp.root) throws -> Prepared {
        let folder = folder?.path ?? (root as NSString).appendingPathComponent(".vibeswitcher/run/\(name)")
        try VibePaths.ensurePrivate(URL(fileURLWithPath: folder, isDirectory: true))
        let promptFile = (folder as NSString).appendingPathComponent("prompt.md")
        let mcpFile = (folder as NSString).appendingPathComponent("mcp.json")
        let settingsFile = (folder as NSString).appendingPathComponent("settings.json")
        try LeadVault.writePrivate(Data(prompt.utf8), to: URL(fileURLWithPath: promptFile))
        // The role and task here are only what the server expects; the session host says what its session holds.
        // Through a keeper (`MCPKeeper`): a server that stops is started again, and the session's tools come back by
        // themselves, with no /mcp.
        var args = [MCPKeeper.flag, "--role", role.rawValue, "--root", root]
        if let task { args += ["--task", task] }
        let entry: [String: Any] = ["command": server, "args": args]
        let mcp: [String: Any] = ["mcpServers": ["vibeswitcher": entry]]
        try LeadVault.writePrivate(try JSONSerialization.data(withJSONObject: mcp, options: [.prettyPrinted, .sortedKeys]),
                                   to: URL(fileURLWithPath: mcpFile))
        var settings: [String: Any] = ["permissions": ["allow": allow(role, base: branch), "deny": deny(role, base: branch, records: records)]]
        if !environment(role).isEmpty { settings["env"] = environment(role) }
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
        var prepared = Prepared(command: parts.joined(separator: " "), promptFile: promptFile, mcpFile: mcpFile, settingsFile: settingsFile)
        // Not made (another user's folder in its place): the session keeps the TMPDIR it would have had.
        let cwd = cwd ?? task.map { Worktrees.path(root: root, slug: $0) } ?? root
        if let temporary = SessionTemp.make(cwd: cwd, name: name, in: temporary) { prepared.environment["TMPDIR"] = temporary.path + "/" }
        return prepared
    }

    /// Where a new lead finds the last turns of the lead it replaces: in the project's `.vibeswitcher` folder (kept out
    /// of git), which its tools may read (the vault's run folder is closed to them).
    public static func turnsFile(root: String) -> String {
        (root as NSString).appendingPathComponent(".vibeswitcher/replaced-lead-turns.md")
    }

    /// Writes the replaced lead's last turns (0600) for the new lead and returns the file; with none, removes an
    /// earlier lead's file and returns nil (the prompt then names no file).
    @discardableResult
    public static func writeTurns(_ turns: String?, root: String) throws -> String? {
        let file = turnsFile(root: root)
        guard let turns, !turns.isEmpty else {
            unlink(file)
            return nil
        }
        try VibePaths.ensurePrivate(URL(fileURLWithPath: (file as NSString).deletingLastPathComponent, isDirectory: true))
        try LeadVault.writePrivate(Data(turns.utf8), to: URL(fileURLWithPath: file))
        return file
    }

    /// The `--name` a command line from `prepare` gives its session (Claude writes it into the transcript).
    public static func name(inCommand command: String) -> String? {
        guard let range = command.range(of: #"--name '[^']*'"#, options: .regularExpression) else { return nil }
        let name = String(command[range].dropFirst("--name '".count).dropLast())
        return name.isEmpty ? nil : name
    }
}
