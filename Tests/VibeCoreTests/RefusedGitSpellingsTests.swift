import Foundation
import Testing
@testable import VibeCore

/// 2026-11-17, the Code Mode trial's worker: `git --git-dir=<path> for-each-ref` ran in its own worker session although
/// its rules deny `Bash(git --git-dir:*)`. Claude Code reads `:*` as a space then anything, so the `=` spelling (and an
/// attached `-C<path>`, `-c<name>=<value>`, or a refused option behind a harmless one, `git -P -C x`) matched no rule,
/// and in auto mode, where workers run, nothing asked. Each role's guard is its deny rules plus its `PreToolUse` hook,
/// which Claude Code asks about every Bash call whatever the permission mode; the `PermissionRequest` hook only allows.
struct RefusedGitSpellingsTests {
    let temp = Scratch()

    /// A role's guard as `prepare` writes its settings: the deny rules, and the hooks' command lines.
    struct Guard {
        let role: LeadLaunch.Role
        let root: String
        let deny: [String]
        let allow: [String]
        let settings: [String: Any]

        init(_ role: LeadLaunch.Role, temp: Scratch) throws {
            let url = temp.url("repo-\(role)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            root = url.resolvingSymlinksInPath().path
            let launch = try LeadLaunch.prepare(role: role, root: root, task: role == .lead ? nil : "t", base: "claude", prompt: "p",
                                                start: "Go.", server: "/opt/vibe switcher/vibeswitcher-mcp", name: "\(role)-spellings",
                                                branch: "main", records: "docs/lead", folder: temp.url("run-\(role)"), cwd: root,
                                                temporary: temp.url("session-tmp-\(role)"))
            settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: launch.settingsFile))) as? [String: Any])
            let permissions = try #require(settings["permissions"] as? [String: Any])
            self.role = role
            deny = permissions["deny"] as? [String] ?? []
            allow = permissions["allow"] as? [String] ?? []
        }

        /// The tool server's hook options for `event`'s hook, as its command line in the settings sets them up; nil
        /// without one.
        func hook(_ event: String) -> (root: String?, writes: Bool)? {
            let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]]
            guard let group = groups?.first(where: { $0["matcher"] as? String == "Bash" }),
                  let command = (group["hooks"] as? [[String: Any]])?.first?["command"] as? String,
                  let words = ReadOnlyCommand.parts(of: command)?.first, words.dropFirst().first == ReadOnlyCommand.hookArgument else { return nil }
            return ReadOnlyCommand.hookOptions(Array(words.dropFirst(2)))
        }

        /// Whether the `PreToolUse` hook refuses `line`, run from `cwd`.
        func hookDenies(_ line: String, cwd: String) throws -> Bool {
            guard let options = hook("PreToolUse") else { return false }
            let event: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": line], "cwd": cwd]
            guard let answer = ReadOnlyCommand.hookAnswer(try JSONSerialization.data(withJSONObject: event), root: options.root, writes: options.writes),
                  let object = try JSONSerialization.jsonObject(with: answer) as? [String: Any],
                  let output = object["hookSpecificOutput"] as? [String: Any] else { return false }
            return output["hookEventName"] as? String == "PreToolUse" && output["permissionDecision"] as? String == "deny"
        }

        /// Refused before it runs: a deny rule takes it whichever way a `*` reads, or the `PreToolUse` hook does.
        func refuses(_ line: String) throws -> Bool {
            try LeadGuardRailsTests.denied(line, by: deny) || hookDenies(line, cwd: root)
        }

        /// Runs without a prompt: refused by nothing, and an allow rule or the `PermissionRequest` hook takes it.
        func runsUnasked(_ line: String) throws -> Bool {
            guard try !refuses(line) else { return false }
            if LeadGuardRailsTests.allowed(line, by: (allow, deny)) { return true }
            guard let options = hook("PermissionRequest") else { return false }
            return ReadOnlyCommand.allows(line, in: ReadOnlyCommand.Scope(root: options.root, cwd: root, writes: options.writes))
        }
    }

    /// The reported symptom, as the contract quotes it.
    @Test func theWorkersGuardRefusesTheGitDirEqualsSpelling() throws {
        let worker = try Guard(.worker, temp: temp)
        #expect(try worker.refuses("git --git-dir=/tmp/x status"))
    }

    /// Each refused option in every spelling: spaced, `=`, attached. git 2.54 itself rejects the attached `-C<path>` and
    /// `-c<name>=<value>` ("unknown option"), refused anyway: another git, or a later one, may take them.
    static let refusedSpellings = [
        // -C
        "git -C ../other status", "git -C../other status", "git -C . push origin main",
        // -c
        "git -c core.pager=cat log", "git -ccore.pager=cat log", "git -c alias.x=push x",
        // --git-dir
        "git --git-dir ../x/.git status", "git --git-dir=../x/.git status", "git --git-dir=../x/.git for-each-ref",
        // --work-tree
        "git --work-tree ../x status", "git --work-tree=../x status",
        // --exec-path (alone it prints the path; it's refused in every form, as its rule was)
        "git --exec-path=../bin status", "git --exec-path ../bin status", "git --exec-path",
        // --config-env: `-c` with the value from an environment variable
        "git --config-env=core.pager=HOME log", "git --config-env core.pager=HOME log",
        // Behind a harmless global option, or one that takes a value of its own.
        "git --no-pager --git-dir=x status", "git -P -C x status", "git --bare --work-tree=x status",
        "git --namespace n -C x status", "git --no-optional-locks -cuser.name=x commit -m y",
        // Behind the wrappers that are refused already, and a full path.
        "env git --git-dir=x status", "command git --git-dir=x status", "/usr/bin/git --git-dir=x status", "xcrun git -C x status",
        "/opt/homebrew/bin/git --git-dir=x status", "GIT_OPTIONAL_LOCKS=0 git --work-tree=x status",
        // Quoted: the shell takes the quotes off.
        "git '--git-dir=x' status", "git \"-C\" x status", "git --git-dir=\"../x y\" status", "\\git -C x status",
    ]

    /// In a compound line: after `&&`, `;`, `||`, `|`, a newline, in a subshell, a group, a substitution, `if`.
    static let refusedCompounds = [
        "cd src && git --git-dir=x log", "true; git -C/elsewhere status", "(git --git-dir=x status)", "(cd src; git -C .. status)",
        "git status || git -cuser.name=x commit -m y", "git log | (git --work-tree=. log)", "echo $(git -C x status)",
        "echo \"$(git --git-dir=x log)\"", "echo `git -c a.b=c log`", "{ git --git-dir=x log; }", "if true; then git -C x status; fi",
        "git status\ngit --git-dir=x status", "git status & git -C x status", "! git --git-dir=x status", "time git -C x status",
        "for f in a; do git --git-dir=x log; done", "x=$(git --exec-path=y version)",
    ]

    /// The same lines' harmless neighbours: options after the subcommand, the words in a message or a pattern.
    static let harmless = [
        "git status", "git log --oneline", "git diff --stat", "git diff -C --stat", "git log -c -1",
        "git blame -C a.txt", "git log --grep=--git-dir", "git grep -e -C", "git -P log --oneline", "git --no-pager diff --stat",
        "GIT_OPTIONAL_LOCKS=0 git status", "git log --oneline -- docs/git-dir.md", "echo 'git -C x status; git --git-dir=y'",
        "cat <<'EOF'\ngit --git-dir=x status\nEOF", "grep -rn 'git -C' Sources", "cd src && git log --oneline",
    ]

    /// A worker's own harmless writes (the lead and the verifier are refused `git switch` and `git commit` outright).
    static let harmlessForAWorker = [
        "git switch -c topic", "git commit -m 'Guard: cd src && git --git-dir=x log is refused'",
        "git commit -m \"$(cat <<'EOF'\nGuard: refuse the spellings\n\ncd src && git --git-dir=x log; (git -C/elsewhere status)\nEOF\n)\"",
    ]

    @Test(arguments: [LeadLaunch.Role.worker, .verifier, .lead])
    func everyRefusedOptionIsRefusedInEverySpelling(_ role: LeadLaunch.Role) throws {
        let guardRail = try Guard(role, temp: temp)
        for line in Self.refusedSpellings + Self.refusedCompounds {
            #expect(try guardRail.refuses(line), "\(role) lets through: \(line)")
        }
        for line in Self.harmless + (role == .worker ? Self.harmlessForAWorker : []) {
            #expect(try !guardRail.refuses(line), "\(role) refuses: \(line)")
        }
    }

    /// The refused options, named here rather than read from the list they test.
    static let options = ["-C", "-c", "--git-dir", "--work-tree", "--exec-path", "--config-env"]

    /// The briefs list each refused option once, as before, not again in each spelling the rules add.
    @Test func theBriefsListOfRefusedGitKeepsOneEntryPerOption() {
        let listed = LeadLaunch.deniedGit(.worker, base: "main", records: "docs/lead")
        for option in Self.options {
            #expect(listed.filter { $0.hasPrefix("git \(option)") } == ["git \(option)"], "\(option): \(listed)")
        }
    }

    /// The everyday reads still run without a prompt in a worker's worktree.
    @Test func aWorkersEverydayGitReadsStillRunUnasked() throws {
        let worker = try Guard(.worker, temp: temp)
        for line in ["git status", "git log --oneline", "git diff --stat", "git status && git log --oneline -3"] {
            #expect(try worker.runsUnasked(line), "\(line)")
        }
    }
}
