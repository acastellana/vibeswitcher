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
        func hook(_ event: String) -> ReadOnlyCommand.HookOptions? {
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
            guard let answer = ReadOnlyCommand.hookAnswer(try JSONSerialization.data(withJSONObject: event), root: options.root, writes: options.writes,
                                                          base: options.base, records: options.records),
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
        // Arithmetic's `<<` is a shift: the next line is still read. Programs that run the command after them.
        "echo $((1<<2))\ngit -C x status", "echo \"$((1<<2))\"\ngit -C x status", "/usr/bin/time git -C x status",
        "git ls-files | xargs -n 1 git --git-dir=x log",
        // Audit F1: process substitution is a command of its own, and the words after it are still read.
        "cat <(true); git -C x status", "diff <(git show HEAD:a) <(cat a) && git --git-dir=../x/.git log",
        "git status 2> >(cat); git -C x status", "cat <(git -C x show HEAD:a)", "git log > >(git --work-tree=x add .)",
        "diff <(git show main:f) <(cat f) && git --git-dir=../x/.git update-ref refs/heads/main HEAD",
        // Audit F2: an unquoted here-document's substitutions run.
        "cat <<EOF\n$(git -C x status)\nEOF", "cat <<EOF\n`git --git-dir=x log`\nEOF",
        "cat > notes.md <<EOF\nmain is at $(git -C ../.. rev-parse HEAD)\nEOF", "cat <<-EOF\n\t\"$(git -C x log)\"\n\tEOF",
        "cat <<EOF\ntext\nEOF\ngit -C x status", "cat <<'EOF'\ntext\nEOF\ngit -C x status",
        // Audit F4: an arithmetic command's `<<` is a shift; its substitutions run, and `((…) …)` is two subshells.
        "((x = 1<<2))\ngit -C x status", "if ((1<<2)); then git -C x status; fi", "echo $(( $(git -C x rev-list --count HEAD) + 1 ))",
        "((n = $(git --git-dir=x rev-list --count HEAD)))", "((cd src); git -C x status)",
        // Audit F5: ANSI-C quoting, where a backslash escapes the quote.
        "echo $'it\\'s' && git -C x status", "git $'-C' x status",
        // Audit F6: a substitution inside `${…}` runs.
        "echo ${x:-$(git -C x status)}", "echo \"${x:-$(git -C x status)}\"",
        // Audit F7: the wrappers workers use.
        "timeout 60 git -C x status", "timeout -k 5 60 git --git-dir=x log", "arch -arm64 git -C x status", "stdbuf -oL git -C x status",
        "vs-heavy --timeout 2h git -C x status", "caffeinate -i git -C x status", "nohup git --git-dir=x log",
        // The blind check's: `time -p`, a `function` keyword, `$[…]` arithmetic, a valued `--shallow-file`, quotes in
        // `${…}`, and `find -exec`.
        "time -p git -C x status", "function f { git --git-dir=x status; }; f", "echo $[1<<2]\ngit -C x status",
        "git --shallow-file x -C y status", "echo ${x:-'}'}; git -C x status", "echo ${x:-\"}\"}; git -C x status",
        "echo \"${x:-\"}\"}\"; git -C x status", "find . -name a -exec git -C x status \\;", "find . -execdir git --git-dir=x log {} +",
    ]

    /// The same lines' harmless neighbours: options after the subcommand, the words in a message or a pattern.
    static let harmless = [
        "git status", "git log --oneline", "git diff --stat", "git diff -C --stat", "git log -c -1",
        "git blame -C a.txt", "git log --grep=--git-dir", "git grep -e -C", "git -P log --oneline", "git --no-pager diff --stat",
        "GIT_OPTIONAL_LOCKS=0 git status", "git log --oneline -- docs/git-dir.md", "echo 'git -C x status; git --git-dir=y'",
        "cat <<'EOF'\ngit --git-dir=x status\nEOF", "grep -rn 'git -C' Sources", "cd src && git log --oneline",
        // The audit's lines without the refused option, and quoted here-documents, whose bodies are text.
        "diff <(git show HEAD:a) <(cat a)", "git status 2> >(cat); git log --oneline", "cat <<'EOF'\n$(git -C x status)\nEOF",
        "cat <<\\EOF\n`git -C x status`\nEOF", "cat <<EOF\ngit -C x status is refused\nEOF\ngit log --oneline",
        "((x = 1<<2))\ngit status", "echo $((1<<2)) && git log --oneline", "echo $'it\\'s' && git status", "echo ${x:-$(git status)}",
        "timeout 60 git status", "vs-heavy --timeout 2h git log --oneline", "echo $(echo $(echo $(git status)))",
        "time -p git status", "function f { git status; }; f", "echo $[1<<2]\ngit status", "echo ${x:-'}'}; git status",
        "find . -name '*.swift' -exec git log --oneline -- {} \\;",
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

    /// Audit F3: a line nested deeper than the scanner reads is refused, not read (an unbounded read could overflow
    /// the stack, and a crashed hook says nothing, which lets the call through); nested less, it's read as before.
    @Test func aLineNestedTooDeepIsRefusedNotRead() throws {
        func nested(_ levels: Int, _ inner: String) -> String {
            String(repeating: "echo $(", count: levels) + inner + String(repeating: ")", count: levels)
        }
        let worker = try Guard(.worker, temp: temp)
        #expect(try !worker.refuses(nested(10, "git status")))
        #expect(try worker.refuses(nested(10, "git -C x status")))
        #expect(try worker.refuses(nested(40, "git status")))
        for deep in [nested(100_000, "git status"), String(repeating: "(", count: 100_000), String(repeating: "${", count: 100_000),
                     String(repeating: "$((", count: 50_000), String(repeating: "<(", count: 100_000),
                     // Shallow, but each `((` looks ahead to the line's end: refused, not read in the square of its length.
                     String(repeating: "(('((' ) ); ", count: 20_000) + "git status"] {
            #expect(try worker.refuses(deep))
        }
        // A long line of honest arithmetic is still read.
        #expect(try !worker.refuses(String(repeating: "((x = 1<<2)); ", count: 20_000) + "git status"))
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
