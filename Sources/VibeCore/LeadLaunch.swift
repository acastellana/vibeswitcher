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
        /// What the session's environment adds (`SpawnRequest.env`): its TMPDIR, a folder of its own (see `SessionTemp`),
        /// and its role (`SessionNote.roleVariable`).
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
    /// `git remote`'s subcommands that write (.git/config, which a worktree shares with the main checkout, or the
    /// remote-tracking refs), each also after `-v`/`--verbose`, which git takes before them (`git remote -v set-url`,
    /// git 2.39). A changed origin would send the user's own `git push origin main` elsewhere, and the lead's first
    /// fetch_remote pins the URL it finds. Listing them (`git remote`, `-v`, `show`, `get-url`) stays open.
    static let remoteWrites: [String] = ["", "-v ", "--verbose "].flatMap { option in
        ["add", "rename", "remove", "rm", "set-head", "set-branches", "set-url", "prune", "update"].map { "Bash(git remote \(option)\($0):*)" }
    }
    /// Shell commands that write files, for the roles that only read.
    static let fileWrites = ["Bash(sed -i:*)", "Bash(perl -i:*)", "Bash(perl -pi:*)", "Bash(perl -e:*)", "Bash(tee:*)", "Bash(dd:*)",
                             "Bash(truncate:*)", "Bash(cp:*)", "Bash(mv:*)", "Bash(rm:*)", "Bash(ln:*)", "Bash(touch:*)", "Bash(install:*)",
                             "Bash(rsync:*)", "Bash(patch:*)", "Bash(python -c:*)", "Bash(python3 -c:*)", "Bash(ruby -e:*)",
                             "Bash(node -e:*)", "Bash(osascript:*)", "Bash(cat >:*)", "Bash(echo >:*)", "Bash(printf >:*)",
                             "Bash(git * --output*)"]
    /// VibeSwitcher's private files (the team's capabilities, the seal on your messages): no role's tools touch them.
    static let privateFiles = ["Read(~/.vibeswitcher/lead/**)", "Edit(~/.vibeswitcher/lead/**)",
                               "Read(~/.vibeswitcher/steer/**)", "Edit(~/.vibeswitcher/steer/**)"]

    /// A first layer, before the hook's parser (`hooks`, `ReadOnlyCommand`), which is what keeps them from running
    /// unasked: the git forms that print a file from outside the repository, where the Read rules above don't look
    /// (shown on git 2.39, 2026-11-01): `git diff --no-index`, and `git diff` given a path outside
    /// the work tree (it then compares the files without `--no-index`); a path from home, up out of the checkout, or
    /// behind an expansion or a quote is refused, since a rule can't tell where it points. `git blame`
    /// annotating another file's contents or reading its revisions from one, `git log --stdin`, a commit message taken
    /// from a file, and pathspecs read from one (git prints each line it can't match). Refused to every role.
    static let outsideReads: [String] = {
        // Not a path written absolute: one inside the worktree is an everyday form (round 1's F9), and the hook's
        // parser tells it from one outside, symlinks resolved.
        let paths: [String] = ["~", "../", "\"~", "'~", "\"../", "'../"]
        var rules: [String] = arguments("git diff", starting: ["--no-index"] + paths)
        // A path that climbs out partway (`sub/../../x`, `./../x`); a revision range (`main...HEAD`) has no `/..`.
        rules += ["Bash(git diff*$*)", "Bash(git diff*`*)", "Bash(git diff */..*)"]
        rules += arguments("git blame", starting: ["--contents", "-S", "--ignore-revs-file"])
        rules += arguments("git log", starting: ["--stdin"])
        rules += ["Bash(git log --stdin)", "Bash(git log * --stdin)"]
        rules += arguments("git commit", starting: ["-F", "--file"])
        rules.append("Bash(git *--pathspec-from-file*)")
        return rules
    }()

    /// Rules refusing `command` with an argument that starts with one of `starting`, first or later: `command *` alone
    /// would leave the first argument out wherever a `*` must match some text.
    static func arguments(_ command: String, starting: [String]) -> [String] {
        starting.flatMap { ["Bash(\(command) \($0)*)", "Bash(\(command) * \($0)*)"] }
    }

    /// The user's own settings for every project, edited in Settings › Project lead (the app writes them; no role's
    /// session does): the Mac-wide limits on sessions and load (`MacLimits`), the boost the app decided (`BoostState`,
    /// which raises them) and the working policy (`WorkingPolicy`). They aren't among the vault's guarded settings, so
    /// a worker that wrote them could raise its own cap.
    static let userSettings = ["Edit(~/.vibeswitcher/mac-limits.json)", "Write(~/.vibeswitcher/mac-limits.json)",
                               "Edit(~/.vibeswitcher/boost.json)", "Write(~/.vibeswitcher/boost.json)",
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

    /// Claude Code's raw cross-session messaging (another session on the Mac, by its name). Anyone on the Mac can send
    /// one and claim any name, and a role that could reach every session could steer them: a lead tells another
    /// project's lead with `tell_lead` (`LeadMail`: the sender filled in by the vault, guarded, recorded), and a worker
    /// or verifier reaches only its own lead, through its tools. Bare tool names, as `readOnly`'s: "To match all uses of a
    /// tool, use only the tool name without parentheses", and as a deny rule it "removes the tool from Claude's context
    /// entirely" (code.claude.com/docs/en/permissions, "Match all uses of a tool", "Manage permissions").
    static let crossSession = ["SendMessage", "ListAgents"]

    /// Claude Code's own folder in your home: your settings and hooks, CLAUDE.md, skills, agents, and each project's
    /// auto-memory (`~/.claude/projects/<folder>/memory`), which Claude Code loads into every later session there. A
    /// worker that wrote a note there planted it in the verifier that audits it, as its own memory (harness review of
    /// 2026-11-07); a verifier writing there would speak to the next one. Refused to workers and verifiers (the lead's
    /// tools edit nothing). A rule binds the file tools only: a worker's shell can still write there. Of that, the
    /// verifier loads no auto-memory (`verifierEnvironment`); settings, CLAUDE.md and skills a shell writes stay open.
    static let claudeHome = ["Edit(~/.claude/**)", "Write(~/.claude/**)"]

    /// What each role may not do. `records`: the workflow's `records_dir`, which only the lead's tool server writes
    /// (and commits to the base branch): a worker editing it would conflict with those commits.
    public static func deny(_ role: Role, base: String? = nil, records: String? = nil) -> [String] {
        switch role {
        case .lead:
            return readOnly + gitWrites + gitAround + remoteWrites + fileWrites + privateFiles + outsideReads + userSettings + killsByName
                + crossSession
        case .verifier:
            return readOnly + gitWrites + gitAround + remoteWrites + fileWrites + privateFiles + outsideReads + userSettings + killsByName + debuggers
                + crossSession + claudeHome
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
            return rules + gitAround + remoteWrites + privateFiles + outsideReads + userSettings + killsByName + debuggers + crossSession + claudeHome
        }
    }

    /// The git commands `deny` refuses `role`, as its prompt lists them: each `Bash(...)` rule that runs git, without
    /// its `:*` ("git worktree", "git checkout * main", "env git"). Made from the rules, so the list never drifts from them.
    /// Not `outsideReads`: patterns of quotes, backticks and wildcards that read as noise in a brief (round 1's F8), for
    /// reads no brief asks for.
    public static func deniedGit(_ role: Role, base: String? = nil, records: String? = nil) -> [String] {
        var seen = Set<String>()
        let patterns = Set(outsideReads)
        return deny(role, base: base, records: records).compactMap { rule -> String? in
            guard rule.hasPrefix("Bash("), rule.hasSuffix(")"), !patterns.contains(rule) else { return nil }
            var command = String(rule.dropFirst("Bash(".count).dropLast())
            if command.hasSuffix(":*") { command.removeLast(2) }
            guard command.hasPrefix("git ") || command.hasSuffix(" git") || command.hasSuffix("/git") else { return nil }
            return seen.insert(command).inserted ? command : nil
        }
    }

    /// The VibeSwitcher tool server's tools, by the server's whole name (Claude Code 2.1.299+ reads `mcp__<server>__*`
    /// as that server only). Which tools a role gets is its capability's business (see `LeadVault`).
    static let ownTools = "mcp__vibeswitcher__*"

    /// What each role may do without asking, the deny rules permitting, by rule: its VibeSwitcher tools (they never
    /// wait on a prompt, whether or not auto mode, the default since Claude Code 2.1.284, is on), `git branch
    /// --show-current`, and for a worker, the bare steps of bringing its branch up to date with `base` and taking a fix
    /// out and putting it back with `git apply` (the patch from git on its input: `LeadPrompts.Policy.regressionTest`).
    /// Every other git read, and a worker's `git add`, `git rm` and `git commit`, goes to the role's hook (`hooks`): a
    /// rule such as `Bash(git diff:*)` lets through any spelling of any argument, and on 2026-11-01 `git diff --no-index
    /// /var/empty <file>` printed the lead's private files past the Read rules, as did global options, abbreviations,
    /// `--stdin`, `..` and commit's `--template`, which no list of deny rules can enumerate.
    public static func allow(_ role: Role, base: String? = nil) -> [String] {
        let reads = [ownTools, "Bash(git branch --show-current)"]
        guard role == .worker else { return reads }
        var rules = reads + ["Bash(git rebase --continue)", "Bash(git rebase --abort)", "Bash(git rebase --skip)", "Bash(git merge --continue)",
                             "Bash(git merge --abort)", "Bash(git apply -R)", "Bash(git apply)"]
        if let base { rules += ["Bash(git rebase \(base))", "Bash(git merge \(base))", "Bash(git merge --no-edit \(base))"] }
        return rules
    }

    /// What a verifier on `task` may read outside its worktree without a prompt: the image files its task's worker
    /// reported as evidence, kept in the main checkout (`<root>/.vibeswitcher/evidence/<task>/<report id>/<image>`,
    /// see `KeptImages`), which its brief names. On 2026-11-05 three audits stopped on the Read prompt for one, which
    /// no one answers; one waited 155 minutes. A rule per folder spelling and extension, two levels deep and no
    /// deeper ("//" starts a path from the file system's root; `*` stays within one name). Claude Code (2.1.318, read
    /// in its bundle) allows a read by rule only when every spelling of the file matches one (the path as asked, `..`
    /// resolved, and where its symlinks land) and no deny rule matches any: a link out of the folder, another task's
    /// evidence, the rest of `.vibeswitcher` and the lead's private files stay as they were. Nothing for a worker or
    /// the lead, nor for a root or task `KeptImages.evidenceFolders` finds unusual.
    public static func evidenceReads(_ role: Role, root: String, task: String?) -> [String] {
        guard role == .verifier, let task else { return [] }
        return KeptImages.evidenceFolders(root: root, task: task).flatMap { folder in
            KeptImages.readExtensions.map { "Read(/\(folder)/*/*.\($0))" }
        }
    }

    /// The hook every role's settings add: its `PermissionRequest` hook lets a command line run without a prompt when
    /// it parses cleanly as git reads and grep/rg/head/tail/wc/sort with known flags, every path in the role's worktree
    /// `root` (symlinks resolved), and for a worker its own `git add`, `git rm`, `git commit -m` and `git apply`
    /// (`ReadOnlyCommand`), chained or not. No one answers a verifier's prompts, and two audits hung on prompts for
    /// read-only git and grep (2026-10-31, 2026-11-01). Claude Code asks it only about what the deny rules let through
    /// (`outsideReads` stays a first layer); anything it doesn't allow prompts as an unlisted command does (and the
    /// witness declines a verifier's when no one answers it: `LeadWitness.stuckPrompts`). Loaded from `--settings`
    /// whatever `--setting-sources` says.
    public static func hooks(_ role: Role, server: String, root: String) -> [String: Any] {
        var words = [RecentProjects.shellQuote(server), ReadOnlyCommand.hookArgument, ReadOnlyCommand.rootArgument, RecentProjects.shellQuote(root)]
        if role == .worker { words.append(ReadOnlyCommand.workerArgument) }
        return ["PermissionRequest": [["matcher": "Bash", "hooks": [["type": "command", "command": words.joined(separator: " "), "timeout": 10]]]]]
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

    /// What a verifier's session adds to its environment, given its tool server's binary `server`: every command it
    /// runs goes under the branch-code wrapper, its own tool server excepted (`BranchCode.prefixEnvironment`), and
    /// Claude Code's auto-memory is off: no notes from its folder are loaded as the verifier's own (a worker's shell
    /// can write them: Claude Code 2.1.319 keeps a worktree's under the main checkout's folder, shared with the lead's
    /// and your sessions), and the verifier leaves none for the next one.
    public static func verifierEnvironment(server: String) -> [String: String] {
        BranchCode.prefixEnvironment(server: server).merging([autoMemoryVariable: "1"]) { $1 }
    }

    static let autoMemoryVariable = "CLAUDE_CODE_DISABLE_AUTO_MEMORY"

    /// Claude Code's folder for the project at `path` (in `~/.claude/projects`): every character but an ASCII letter or
    /// digit made a "-", and a name longer than 200 cut there and followed by "-" and its hash (as Claude Code 2.1.319
    /// names it: a JavaScript string hash of the UTF-16 path, its absolute value in base 36).
    public static func claudeProjectFolder(_ path: String, home: String = VibePaths.home) -> String {
        let units = Array(path.utf16)
        var name = String(units.map { unit -> Character in
            let scalar = UnicodeScalar(unit).map(Character.init)
            guard let scalar, scalar.isASCII, scalar.isLetter || scalar.isNumber else { return "-" }
            return scalar
        })
        if name.count > 200 {
            var hash: Int32 = 0
            for unit in units { hash = (hash &<< 5) &- hash &+ Int32(unit) }
            name = String(name.prefix(200)) + "-" + String(abs(Int64(hash)), radix: 36)
        }
        return (home as NSString).appendingPathComponent(".claude/projects/\(name)")
    }

    /// Moves aside the auto-memory Claude Code keeps for a session started in `cwd`, a task's worktree (by its path as
    /// given and as resolved, each only while it's still a worktree's path), before a verifier starts there: to `memory.set-aside-<time>` beside it, which nothing loads and the
    /// audit can still read. Returns the folders moved. The main checkout's own memory (where Claude Code 2.1.319 keeps
    /// a worktree's) is yours and the lead's, and stays: the verifier doesn't load any (`verifierEnvironment`).
    ///
    /// A worker's shell can write `~/.claude` (the `Write(~/.claude/**)` rule holds only its tools), so nothing here
    /// follows a link it could plant: the project folder is opened with `O_NOFOLLOW` (a link there, say to the main
    /// checkout's folder, is skipped), and `memory` is renamed within that open folder, never through a path read again
    /// (`renameatx_np`, which moves a link itself, not what it names, and never replaces an earlier set-aside folder).
    @discardableResult
    public static func setAsideMemory(cwd: String, home: String = VibePaths.home, now: Date = Date()) -> [String] {
        let resolved = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        let stamp = Int(now.timeIntervalSince1970)
        var moved: [String] = []
        // Only a task's worktree, by both its paths: Claude Code's names are lossy ("/dev/x" and "/dev.x" share one), so
        // a worktree a worker's shell moved, a link left in its place, must not name another project's folder when
        // followed (the main checkout's: yours and the lead's). A folder named for `.vibeswitcher/worktrees/<slug>` is
        // only ever a worktree's.
        let slug = (cwd as NSString).lastPathComponent
        func isWorktree(_ path: String) -> Bool {
            (path as NSString).lastPathComponent == slug
                && ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent == "worktrees"
                && (((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent as NSString)
                    .lastPathComponent == ".vibeswitcher"
        }
        for path in Array(Set([cwd, resolved])).sorted() where isWorktree(path) {
            let folder = claudeProjectFolder(path, home: home)
            let projects = open((folder as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard projects >= 0 else { continue }
            defer { close(projects) }
            let dir = openat(projects, (folder as NSString).lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dir >= 0 else { continue }
            defer { close(dir) }
            var info = stat()
            guard fstatat(dir, "memory", &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            for tries in 1...100 {
                let name = "memory.set-aside-\(stamp)" + (tries > 1 ? "-\(tries)" : "")
                if renameatx_np(dir, "memory", dir, name, UInt32(RENAME_EXCL)) == 0 {
                    moved.append((folder as NSString).appendingPathComponent(name))
                    break
                }
                if errno != EEXIST { break }
            }
        }
        return moved
    }

    /// Writes the role's files (0600) and returns the command line to run. They go in `folder`: the vault's run folder
    /// for the role (`LeadVault.runFolder`, outside the repository); `<root>/.vibeswitcher/run/<name>/` when none is given.
    /// The session's TMPDIR is made under `temporary` for `cwd`, where it's started (the task's worktree, else `root`):
    /// what its swift builds and tests leave there goes with it (see `SessionTemp`).
    public static func prepare(role: Role, root: String, task: String?, base: String, prompt: String, start: String,
                               server: String, name: String, model: String? = nil, advisor: String? = nil, effort: String? = nil,
                               branch: String? = nil, records: String? = nil, folder: URL? = nil, cwd: String? = nil,
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
        // Where it's started (the task's worktree, else `root`): the hook's paths stay in it.
        let cwd = cwd ?? task.map { Worktrees.path(root: root, slug: $0) } ?? root
        var settings: [String: Any] = ["permissions": ["allow": allow(role, base: branch) + evidenceReads(role, root: root, task: task),
                                                       "deny": deny(role, base: branch, records: records)]]
        var env = environment(role)
        if role == .verifier {
            // Never started with its commands as itself (see `verifierEnvironment`).
            guard BranchCode.prefixable(server) else { throw VerifierUnsafe(server: server) }
            env.merge(verifierEnvironment(server: server)) { $1 }
            settings["autoMemoryEnabled"] = false
            setAsideMemory(cwd: cwd)
        }
        if !env.isEmpty { settings["env"] = env }
        settings["hooks"] = hooks(role, server: server, root: cwd)
        // The account's usage windows reach VibeSwitcher only through a status line's input: its own records them and
        // shows yours (see `UsageStatusLine`): for a verifier, only your user settings' (its project settings don't run).
        settings["statusLine"] = UsageStatusLine.settings(server: server, userOnly: role == .verifier)
        try LeadVault.writePrivate(try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
                                   to: URL(fileURLWithPath: settingsFile))
        let quote = RecentProjects.shellQuote
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        // The model given replaces one the project's command names (`--model x`, `--model=x`): `claude --help` doesn't
        // say which of two wins.
        // Likewise an effort given replaces the command's own. The command's own advisor never goes through, passed one
        // or not: lead_advisor, worker_advisor and the task decide a session's advisor (`run`), so a command's
        // `--advisor fable` can't reach a session while Fable is held back, a task that says none, or a main it ranks
        // below (an interactive session exits at launch on that pairing).
        var command = without("--advisor", in: trimmed.isEmpty ? "claude" : model == nil ? trimmed : withoutModel(trimmed))
        if effort != nil { command = without("--effort", in: command) }
        var parts = [command.isEmpty ? "claude" : command]
        // From its file, so the prompt's length and characters never matter on the command line.
        parts.append("--append-system-prompt-file \(quote(promptFile))")
        parts.append("--mcp-config \(quote(mcpFile))")
        parts.append("--settings \(quote(settingsFile))")
        // A verifier checks a branch a worker wrote: that branch's project settings, hooks and MCP servers don't run
        // in it (its rules come from --settings, VibeSwitcher's hooks from your user settings).
        if role == .verifier { parts.append("--setting-sources user --strict-mcp-config") }
        parts.append("--name \(quote(name))")
        if let model { parts.append("--model \(quote(model))") }
        // Consulted at decision points (Claude Code's advisor; the flag isn't in `claude --help`).
        if let advisor { parts.append("--advisor \(quote(advisor))") }
        if let effort { parts.append("--effort \(quote(claudeEffort(effort)))") }
        parts.append("-- \(quote(start))")
        var prepared = Prepared(command: parts.joined(separator: " "), promptFile: promptFile, mcpFile: mcpFile, settingsFile: settingsFile)
        // Marks the role's session: its hook gives it none of the notes plain sessions get (`SessionNote`).
        prepared.environment[SessionNote.roleVariable] = role.rawValue
        // The lead's model, for its tool server to note on the board (`LeadBoard.leadModel`): a refusal its session
        // stops at is then kept for that model, so a lead stopped at Fable's limit holds Fable back.
        if role == .lead, let model { prepared.environment[leadModelVariable] = model }
        // Also from the start (Claude Code takes the settings' env as it reads them).
        if role == .verifier { prepared.environment.merge(verifierEnvironment(server: server)) { $1 } }
        // Not made (another user's folder in its place): the session keeps the TMPDIR it would have had.
        if let temporary = SessionTemp.make(cwd: cwd, name: name, in: temporary) { prepared.environment["TMPDIR"] = temporary.path + "/" }
        return prepared
    }

    /// A verifier isn't started when its tool server's path can't be its shell prefix (`BranchCode.prefixable`).
    public struct VerifierUnsafe: Error, CustomStringConvertible {
        public let server: String
        public var description: String {
            "A verifier runs its commands through VibeSwitcher's tool server, and Claude Code can't take \(server) as that (it isn't an absolute path, or it holds \" -\")."
        }
    }

    // MARK: Codex workers

    /// Whether a Codex worker can be started: yes, unless `VIBESWITCHER_CODEX_WORKERS=0` is in the lead's tool server's
    /// environment (an off switch, should a Codex release stop working under the host again). Off from 2026-11-01 until
    /// task codex-s-tui-renders made it work: every hosted session started on a 0×0 terminal (`PTYSpawn.spawn`), the
    /// worktree's trust key never applied (`prepareCodex`), and an idle Codex worker couldn't be messaged (its composer
    /// is `LeadDelivery.codexBox`; its hooks say its turn is over). While it's off, start_worker refuses codex tasks,
    /// auto_advance starts none, and the usage watch suggests none.
    public static let codexWorkersUsable = ProcessInfo.processInfo.environment["VIBESWITCHER_CODEX_WORKERS"] != "0"

    /// Why a codex task's worker isn't started, while `codexWorkersUsable` is false.
    public static let codexUnusable = "Codex workers are switched off (VIBESWITCHER_CODEX_WORKERS=0 in the lead's tool server's environment)."

    /// The guard rails a Claude worker's rules hold that Codex can't be made to hold, each with what checks it instead.
    /// Codex has no per-session deny rules: its command rules (`.rules` files) load only from its own home, the
    /// project's `.codex` folder or managed requirements, none of which a session's command line names, and its
    /// sandbox draws no line inside the folder it writes. Listed in the Codex worker's brief, start_worker's reply and
    /// the guide (docs/guide/project-lead.md, "Codex workers").
    public static let codexUnenforced: [(rule: String, instead: String)] = [
        ("git commands refused to a Claude worker (amend, reset --hard, checkout or branch -D of another agent/ branch)",
         "its sandbox holds the ones that write outside its own branch (main, tags, config, the remote: no network); the Claude audit's integrity check reads its branch's history"),
        ("no edits to the records folder (docs/lead)",
         "merge takes the base's copy of the lead's records whatever the branch did to them (`Worktrees.takeBaseRecords`), and the Claude audit's integrity check reads the rest of the diff"),
        ("no reads of VibeSwitcher's private files (~/.vibeswitcher/lead, ~/.vibeswitcher/steer)",
         "its brief, and the session host's checks: it tells callers apart by their process, never by what they've read"),
        ("your own Codex rules (~/.codex/rules) stay in force: a command prefix you approved there runs outside the sandbox",
         "Codex's TUI loads them whatever a session says (only `codex exec --ignore-rules` skips them); keep them narrow, and the Claude audit reads what the branch did"),
        ("pkill, killall and debuggers refused by rule",
         "its brief, and its sandbox: a sandboxed command signals only its own processes"),
    ]

    /// Codex's own flags a project's Codex command may carry that would loosen the worker's sandbox or clash with the
    /// ones `prepareCodex` gives (clap refuses an option given twice), and whether each takes a value.
    static let codexFlags: [(flag: String, value: Bool)] = [
        ("--dangerously-bypass-approvals-and-sandbox", false), ("--yolo", false), ("--full-auto", false), ("--approve-for-me", false),
        ("--sandbox", true), ("-s", true), ("--ask-for-approval", true), ("-a", true), ("--cd", true), ("-C", true),
        ("--add-dir", true), ("--profile", true), ("-p", true), ("--search", false), ("--worktree", false), ("--remote", true),
    ]

    /// The writable roots a Codex worker's sandbox adds to its worktree: the git folders its commits write (its
    /// worktree's own git folder, the object store, and the agent/ branches' refs and logs, where git takes its
    /// lock files) and its TMPDIR. Never the repository's other refs (main, tags), its config or another checkout.
    /// The worktrees' shared module cache (`<root>/.vibeswitcher/module-cache`, scripts/lib/module-cache.sh), when the
    /// repository keeps one: its builds write there.
    public static func codexWritableRoots(cwd: String, slug: String?, temporary: String?, root: String? = nil) -> [String] {
        let asked = Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir", "--git-dir"], in: cwd)
        let found = asked.ok ? asked.output.split(whereSeparator: \.isNewline).map(String.init) : []
        let common = found.first ?? (cwd as NSString).appendingPathComponent(".git")
        let own = found.count > 1 ? found[1] : slug.map { (common as NSString).appendingPathComponent("worktrees/\($0)") } ?? common
        var roots = [own, "\(common)/objects", "\(common)/refs/heads/agent", "\(common)/logs/refs/heads/agent"]
        if let temporary { roots.append(temporary) }
        if let root {
            let cache = (root as NSString).appendingPathComponent(".vibeswitcher/module-cache")
            var folder: ObjCBool = false
            if FileManager.default.fileExists(atPath: cache, isDirectory: &folder), folder.boolValue { roots.append(cache) }
        }
        var seen = Set<String>()
        return roots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }.filter { seen.insert($0).inserted }
    }

    /// The variables a Codex worker's tool server is handed from its session's environment (Codex hands an MCP server
    /// only a few of its own): what `VibePaths` finds VibeSwitcher's folder, home and tools by.
    static let mcpVariables = ["VIBESWITCHER_HOME", "CFFIXED_USER_HOME", "HOME", "PATH", "TMPDIR"]

    /// A TOML string for Codex's `-c key=value` (the value is parsed as TOML): JSON's escapes are TOML's, slashes left.
    static func toml(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func toml(_ list: [String]) -> String { "[" + list.map { toml($0) }.joined(separator: ", ") + "]" }

    /// How a Codex task's worker is started: the project's Codex command (its sandbox-loosening flags dropped) in the
    /// worktree, with the worker's brief as Codex's developer instructions, the VibeSwitcher tool server as its one MCP
    /// server (scoped to the role and the repository as a Claude worker's is), the workspace-write sandbox (writes in
    /// the worktree, `codexWritableRoots` and nowhere else; no network: no push or fetch), approvals never asked (no one
    /// answers them; a refused command's failure goes back to Codex), and the worktree trusted for this session only.
    /// `--no-daemon`: its tool server must run under the session's own process, which is how the session host tells
    /// which session asks (see `LeadVault.Caller`); a shared app-server daemon would start it outside every session.
    /// What Codex can't hold is `codexUnenforced`. The files go in `folder` as `prepare`'s do: the prompt, and the
    /// configuration given on the command line as JSON, for reading back.
    public static func prepareCodex(root: String, task: String, base: String, prompt: String, start: String, server: String,
                                    name: String, model: String? = nil, effort: String? = nil, folder: URL? = nil, cwd: String? = nil,
                                    temporary: URL = SessionTemp.root,
                                    toolTimeout: TimeInterval = LeadDoneCheck.callTimeout(limit: LeadDoneCheck.defaultMinutes * 60)) throws -> Prepared {
        let folder = folder?.path ?? (root as NSString).appendingPathComponent(".vibeswitcher/run/\(name)")
        try VibePaths.ensurePrivate(URL(fileURLWithPath: folder, isDirectory: true))
        let promptFile = (folder as NSString).appendingPathComponent("prompt.md")
        let configFile = (folder as NSString).appendingPathComponent("codex-config.json")
        try LeadVault.writePrivate(Data(prompt.utf8), to: URL(fileURLWithPath: promptFile))
        let cwd = cwd ?? Worktrees.path(root: root, slug: task)
        let temporaryFolder = SessionTemp.make(cwd: cwd, name: name, in: temporary)
        let writable = codexWritableRoots(cwd: cwd, slug: task, temporary: temporaryFolder?.path, root: root)
        let args = [MCPKeeper.flag, "--role", Role.worker.rawValue, "--root", root, "--task", task]
        // In order; each is one `-c key=value`.
        var config: [(key: String, value: String)] = [
            ("sandbox_workspace_write.writable_roots", toml(writable)),
            ("sandbox_workspace_write.network_access", "false"),
            // The worktree trusted, as the whole `projects` table (for this session only: the file isn't changed). Not as
            // `projects."<cwd>".trust_level`: Codex splits a -c key on every dot and keeps its quotes, so that key never
            // matched the folder, and an untrusted folder's TUI opens a trust prompt before it starts any MCP server
            // (Codex 0.160, task codex-s-tui-renders).
            ("projects", "{\(toml(cwd)) = {trust_level = \"trusted\"}}"),
            // No "Update available" prompt at start: no one answers it, and it holds the TUI before the first turn.
            ("check_for_update_on_startup", "false"),
            ("developer_instructions", toml(prompt)),
            ("mcp_servers.vibeswitcher.command", toml(server)),
            ("mcp_servers.vibeswitcher.args", toml(args)),
            ("mcp_servers.vibeswitcher.startup_timeout_sec", "60"),
            // A tool call may take minutes (report runs the pre-done check, `LeadDoneCheck`): Codex's own limit, 60 s
            // unless set, would drop the call while the check runs, and its worker would see a timeout, not the result.
            ("mcp_servers.vibeswitcher.tool_timeout_sec", String(Int(toolTimeout.rounded(.up)))),
            // Its tools need no approval: under approval never, Codex refuses a tool call that needs one ("MCP tool call
            // requires approval, but approval policy is never", the real run of 2026-11-01), and no worker could report.
            ("mcp_servers.vibeswitcher.default_tools_approval_mode", toml("approve")),
            // Codex starts an MCP server with a few of its variables only (HOME, PATH, …): where VibeSwitcher's folder
            // and home are, when set (a scratch home's), go along, or the tool server looks for the session host in
            // the wrong place and never gets its role (the host run of 2026-11-01).
            ("mcp_servers.vibeswitcher.env_vars", toml(mcpVariables)),
        ]
        // The task's effort; not set: config.toml's model_reasoning_effort, as before.
        if let effort { config.append(("model_reasoning_effort", toml(codexEffort(effort)))) }
        let record: [String: Any] = ["config": config.map { ["key": $0.key, "value": $0.value] }, "writableRoots": writable,
                                     "mcpServer": ["command": server, "args": args],
                                     "unenforced": codexUnenforced.map { ["rule": $0.rule, "instead": $0.instead] }]
        try LeadVault.writePrivate(try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]),
                                   to: URL(fileURLWithPath: configFile))
        let quote = RecentProjects.shellQuote
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        var command = withoutCodexFlags(trimmed.isEmpty ? "codex" : trimmed)
        if model != nil { command = withoutModel(command, short: true) }
        var parts = [command.isEmpty ? "codex" : command, "--no-daemon", "--cd \(quote(cwd))", "--sandbox workspace-write", "--ask-for-approval never"]
        parts += config.map { "-c \(quote("\($0.key)=\($0.value)"))" }
        if let model { parts.append("--model \(quote(model))") }
        parts.append("-- \(quote(start))")
        var prepared = Prepared(command: parts.joined(separator: " "), promptFile: promptFile, mcpFile: configFile, settingsFile: configFile)
        prepared.environment[SessionNote.roleVariable] = Role.worker.rawValue
        prepared.environment.merge(environment(.worker)) { $1 }
        if let temporaryFolder { prepared.environment["TMPDIR"] = temporaryFolder.path + "/" }
        return prepared
    }

    /// `command` (a Codex command line) without `codexFlags`, each with its value (`-s x`, `--sandbox=x`).
    static func withoutCodexFlags(_ command: String) -> String {
        var result = command
        for (flag, value) in codexFlags {
            let escaped = NSRegularExpression.escapedPattern(for: flag)
            let pattern = value ? #"(^|\s+)"# + escaped + #"(=|\s+)('[^']*'|"[^"]*"|\S+)"# : #"(^|\s+)"# + escaped + #"(?=\s|$)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// `command` (a Claude command line) without its `--model` options (`--model x`, `--model 'x y'`, `--model=x`); the
    /// rest as it was. `short`: `-m x` too (Codex's).
    static func withoutModel(_ command: String, short: Bool = false) -> String {
        let pattern = (short ? #"(^|\s+)(--model|-m)"# : #"(^|\s+)--model"#) + #"(=|\s+)('[^']*'|"[^"]*"|\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return command }
        let range = NSRange(command.startIndex..., in: command)
        return regex.stringByReplacingMatches(in: command, range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
    }

    /// `command` without `option` and its value (`--advisor x`, `--effort=x`); the rest as it was.
    static func without(_ option: String, in command: String) -> String {
        let pattern = #"(^|\s+)"# + NSRegularExpression.escapedPattern(for: option) + #"(=|\s+)('[^']*'|"[^"]*"|\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return command }
        let range = NSRange(command.startIndex..., in: command)
        return regex.stringByReplacingMatches(in: command, range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Models, advisors and effort

    /// The variable a lead's session carries its `--model` in (none: Claude's default).
    public static let leadModelVariable = "VIBESWITCHER_LEAD_MODEL"

    /// What a session runs on: its model (`--model`; nil: its command's, else Claude's settings'), the advisor its main
    /// model consults at decision points (Claude Code's `--advisor`: before it commits to an approach, when an error
    /// recurs, before it declares done; billed at the advisor's rates only when called), and its reasoning effort
    /// (`effortLevels`; nil: the CLI's default). The user, 2026-11-12: Opus for nearly everything, Fable where judgment
    /// decides the outcome (the lead, hard tasks, re-rolls, sensitive audits).
    public struct Run: Equatable, Sendable {
        public var model: String?
        public var advisor: String?
        public var effort: String?

        public init(model: String? = nil, advisor: String? = nil, effort: String? = nil) {
            self.model = model
            self.advisor = advisor
            self.effort = effort
        }

        /// "opus, effort high, advisor fable"; `fallback` names the model when none is passed ("its command's model").
        public func text(fallback: String) -> String {
            ([model ?? fallback] + [effort.map { "effort \($0)" }, advisor.map { "advisor \($0)" }].compactMap { $0 }).joined(separator: ", ")
        }
    }

    /// What a Codex session runs when it's given no model or effort: config.toml's top-level `model` and
    /// `model_reasoning_effort` (in `$CODEX_HOME`, else `~/.codex`), for showing only; nil for one not set or not read.
    /// VibeSwitcher never names a Codex model itself.
    public static func codexDefaults(home: String = VibePaths.home,
                                     codexHome: String? = ProcessInfo.processInfo.environment["CODEX_HOME"]) -> (model: String?, effort: String?) {
        let folder = codexHome.flatMap { $0.isEmpty ? nil : $0 } ?? (home as NSString).appendingPathComponent(".codex")
        guard let text = try? String(contentsOfFile: (folder as NSString).appendingPathComponent("config.toml"), encoding: .utf8) else { return (nil, nil) }
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard key == "model" || key == "model_reasoning_effort" else { continue }
            var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { values[key] = value }
        }
        return (values["model"], values["model_reasoning_effort"])
    }

    /// The effort levels a task may set (add_task's and update_task's `effort`).
    public static let effortLevels = ["low", "medium", "high", "xhigh"]
    /// The advisors a task may set: fable, opus, or none (no advisor, whatever worker_advisor says).
    public static let advisorChoices = ["fable", "opus", "none"]
    /// A hard task's effort when it sets none (a task the lead marks advisor: fable).
    public static let hardEffort = "high"
    /// The model a re-rolled task's next worker runs on when the task names none: two rounds of patching that didn't
    /// land call for more judgment, not more of the same.
    public static let rerollModel = "fable"

    /// Effort levels from least to most, as both CLIs order theirs.
    static let effortLadder = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
    /// `claude --effort`'s levels (Claude Code's `--help`, 2026-11-12: low, medium, high, xhigh, max).
    static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    /// Codex's `model_reasoning_effort` values (codex-cli 0.167.0's: none, minimal, low, medium, high, xhigh, max).
    static let codexEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// `level` as a CLI with `levels` takes it: itself when it has it, else its nearest on `effortLadder` (the higher one
    /// on a tie: a task asked for more, not less), else as it is.
    static func nearestEffort(_ level: String, in levels: [String]) -> String {
        if levels.contains(level) { return level }
        guard let at = effortLadder.firstIndex(of: level) else { return level }
        let known = levels.compactMap { effortLadder.firstIndex(of: $0) }
        return known.min { (abs($0 - at), -$0) < (abs($1 - at), -$1) }.map { effortLadder[$0] } ?? level
    }

    static func claudeEffort(_ level: String) -> String { nearestEffort(level, in: claudeEfforts) }
    static func codexEffort(_ level: String) -> String { nearestEffort(level, in: codexEfforts) }

    /// A model family's rank for the advisor rule ("an advisor must rank at or above your session's main model",
    /// code.claude.com/docs/en/advisor): fable above opus above sonnet above haiku; nil for one not known.
    static func rank(_ model: String?) -> Int? {
        switch AccountUsage.family(model) {
        case "fable": return 4
        case "opus": return 3
        case "sonnet": return 2
        case "haiku": return 1
        default: return nil
        }
    }

    /// The advisor a session whose main model is `main` (nil: not known) gets, of `advisor`; nil for none. Claude Code
    /// refuses a pairing whose advisor ranks below its main (a Fable main with an Opus advisor), and an interactive
    /// session it refuses one for exits at launch: such an advisor is dropped, as is a Fable advisor to a Fable main
    /// (nothing more to consult), and with the main unknown, every advisor but Fable (which ranks above every main).
    public static func advisor(_ advisor: String?, main: String?) -> String? {
        guard let advisor = advisor?.trimmingCharacters(in: .whitespaces).lowercased(), !advisor.isEmpty, advisor != "none",
              let wanted = rank(advisor) else { return nil }
        guard let ranked = rank(main) else { return wanted == rank("fable") ? advisor : nil }
        if ranked == rank("fable") { return nil }
        return wanted >= ranked ? advisor : nil
    }

    /// The run a session meant for `model`, `advisor` and `effort` starts with. `defaultModel`: what no `--model` runs
    /// (the command's own, else Claude's settings'; nil: not known). While Fable is held back (`AccountUsage.fableHeldBack`),
    /// a session meant for Fable starts on Opus, passed explicitly when it was Fable by default, and a Fable advisor is
    /// dropped: no session starts with `--advisor fable` then.
    public static func run(model: String?, advisor: String?, effort: String?, defaultModel: String?, fableHeldBack: Bool) -> Run {
        var model = model
        if fableHeldBack, AccountUsage.family(model ?? defaultModel) == AccountUsage.heldBackFamily { model = AccountUsage.fallbackModel }
        var advisor = advisor
        if fableHeldBack, AccountUsage.family(advisor) == AccountUsage.heldBackFamily { advisor = nil }
        return Run(model: model, advisor: Self.advisor(advisor, main: model ?? defaultModel), effort: effort)
    }

    /// The lead's run: lead_model (Fable by default: the session that decides what to do and judges what comes back),
    /// Opus in Fable's place while Fable is held back; lead_advisor only while it runs on Opus.
    public static func leadRun(_ workflow: LeadWorkflow, defaultModel: String?, fableHeldBack: Bool) -> Run {
        let chosen = run(model: workflow.leadModel, advisor: nil, effort: nil, defaultModel: defaultModel, fableHeldBack: fableHeldBack)
        guard AccountUsage.family(chosen.model ?? defaultModel) == "opus" else { return chosen }
        return run(model: chosen.model, advisor: workflow.leadAdvisor, effort: nil, defaultModel: defaultModel, fableHeldBack: fableHeldBack)
    }

    /// A worker's run on `task`. Claude: the task's model, else Fable once it's been re-rolled (`rerollModel`), else the
    /// command's; its advisor (none: no advisor), else worker_advisor; its effort, else high for a hard task. Codex: no
    /// advisor (a Claude flag), the task's model unless an auto task was routed there (`routed`: Claude's model names
    /// mean nothing to Codex), and the effort as Codex's model_reasoning_effort.
    public static func workerRun(_ task: LeadTask, workflow: LeadWorkflow, codex: Bool, routed: Bool = false, defaultModel: String?,
                                 fableHeldBack: Bool) -> Run {
        let effort = task.effort ?? (task.hard ? hardEffort : nil)
        if codex { return Run(model: routed ? nil : task.model, effort: effort) }
        return run(model: task.intendedModel, advisor: task.advisor ?? workflow.workerAdvisor, effort: effort, defaultModel: defaultModel,
                   fableHeldBack: fableHeldBack)
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
