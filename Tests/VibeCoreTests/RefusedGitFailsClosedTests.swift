import Foundation
import Testing
@testable import VibeCore

/// The spellings `RefusedGit`'s header listed as open until 2026-11-18: a line that hands text naming git to another
/// interpreter (`sh -c '…'`, `eval`, `env -S`, a sourced here-string, `watch`, `xargs sh -c`), and a git whose option
/// or command word the shell makes from an expansion (`git $x …`). The hook can't read what git those run, so it
/// refuses them (decision 2026-10-25 16:33: hardening fails closed), and says to run the git plainly.
struct RefusedGitFailsClosedTests {
    let temp = Scratch()
    typealias Guard = RefusedGitSpellingsTests.Guard

    /// The reported symptom, as the contract quotes it: the hook itself (not a deny rule) refuses each.
    @Test func theHookRefusesGitHandedToAnotherShellOrBuiltFromAVariable() throws {
        let worker = try Guard(.worker, temp: temp)
        for line in ["sh -c 'git push origin main'", "eval \"git -C /x status\"", "x=push; git $x origin main"] {
            #expect(try worker.hookDenies(line, cwd: worker.root), "the hook lets through: \(line)")
        }
    }

    /// Text naming git handed to another interpreter.
    static let handed = [
        // A shell's `-c` string: alone, in a cluster, after another option, by a full path, in another case.
        "sh -c 'git push origin main'", "bash -c 'git status'", "zsh -c \"git log\"", "bash -lc 'git push'", "zsh -fc 'git status'",
        "bash -o pipefail -c 'git push'", "/bin/sh -c 'git push'", "SH -c 'GIT push'", "dash -c 'git status'", "ksh -c 'git log'",
        "sh -c 'cd src && git -C /x status'", "sh -c '/usr/bin/git push'", "sh -c 'GIT_DIR=/x make'", "sh -c '\"$@\"' _ git push",
        // Quotes and backslashes the second shell takes off.
        "sh -c 'g\"\"it push'", "sh -c 'g\\it push'", "bash -c \"g''it status\"", "sh -c 'gi\\\nt push'",
        // eval, and what the shell evaluates later.
        "eval \"git -C /x status\"", "eval git push origin main", "eval 'git push'", "builtin eval 'git push'", "command eval 'git push'",
        "eval \"$(echo git push)\"", "trap 'git push origin main' EXIT", "watch git status", "watch -n 1 'git push'",
        // env -S: spaced, attached, in a cluster, long.
        "env -S 'git push origin main'", "env -S'git push'", "env -iS 'git push'", "env --split-string='git push'",
        "/usr/bin/env -S 'git -C /x status'", "env -u HOME -S 'git push'",
        // Behind the programs that run a command, and in a compound line.
        "echo x | xargs sh -c 'git push'", "xargs -I{} sh -c 'git push {}'", "find . -name a -exec sh -c 'git push' \\;",
        "timeout 60 bash -c 'git push'", "nohup zsh -c 'git push'", "vs-heavy sh -c 'git status'", "cd src && sh -c 'git push'",
        "(eval 'git push')", "echo $(sh -c 'git status')", "if true; then eval 'git push'; fi", "f() { sh -c 'git push'; }; f",
        "true\nsh -c 'git push'", "noglob eval 'git push'",
    ]

    /// Text that isn't all on the line (a variable, a shell's or `source`'s input) on a line that names git.
    static let handedUnseen = [
        "c='git push origin main'; sh -c \"$c\"", "c='git push'; bash -c $c", "c='git push'; eval $c", "c='git push'; eval \"$c\"",
        "c='git push'; env -S \"$c\"", "c='git push'; trap \"$c\" EXIT", "eval `echo git push`",
        // A shell reading its commands from its input.
        "bash <<< 'git push origin main'", "sh <<'EOF'\ngit push\nEOF", "echo 'git push origin main' | sh", "printf 'git push\\n' | bash -s",
        "zsh -s <<< 'git status'", "bash /dev/stdin <<< 'git push'", "bash <(echo git push)", "cat <<'EOF' | zsh\ngit push\nEOF",
        "zsh =(echo git push)", "bash -x /dev/stdin <<< 'git push'", "bash < <(echo git push)",
        // source and `.` of text on the line.
        "source /dev/stdin <<< 'git push origin main'", ". /dev/stdin <<< 'git push'", "source <(echo git push)", ". <(echo 'git push')",
        "source /dev/stdin <<'EOF'\ngit push origin main\nEOF", "source =(echo git push)", "source \"$f\"; git status",
    ]

    /// A git whose option or command word the shell makes, or the program running it fills in.
    static let expanded = [
        "x=push; git $x origin main", "git $x", "git ${o:--C} x", "git \"$cmd\" origin", "git \"$@\"", "git $*", "git ${=cmd}",
        "git $(echo push) origin main", "git `echo push`", "git \"$(echo push)\" origin", "git -P $x", "git --no-pager \"${cmd}\"",
        "git --namespace $ns log", "git --namespace n $x", "git -$o x status", "git --$long=x status",
        // Braces, a file pattern, zsh's `=`, an ANSI-C escape.
        "git {push,origin}", "git pu{sh,ll}", "git -{C,P} x status", "git pus? origin main", "git p*", "git [p]ush", "git =push",
        "git $'pu\\x73h' origin", "git -P {log,push}",
        // In a compound line, behind a wrapper, by a full path, in another case.
        "for c in status push; do git $c; done", "cd src && git $x", "echo $(git $x)", "timeout 60 git $x", "GIT $x", "/usr/bin/git ${x}",
        "while read c; do git $c; done", "f() { git \"$@\"; }; f push", "find . -name a -exec git $x \\;", "noglob git p*",
        // Filled in by xargs or find.
        "echo push origin main | xargs git", "xargs git -P", "echo push | xargs -n 1 git", "xargs -I% git % origin main",
        "xargs -I {} git {} status", "xargs -I{} git -P {}", "xargs -J % git -P %", "find . -name push -exec git {} origin main \\;",
        "find . -exec git -P {} \\;", "find . -execdir git --namespace {} log \\;",
    ]

    /// Harmless lines for every role: interpreters given text that doesn't name git, git with an expansion after its
    /// command, the scripts a brief says to run, and the refused forms as text.
    static let harmless = [
        "sh -c 'echo hi'", "bash -c 'ls | wc -l'", "eval \"$(ssh-agent)\"", "eval \"$(ssh-agent -s)\" && ssh-add ~/.ssh/id_github",
        "eval \"$(direnv hook zsh)\"", "zsh -c 'swift build 2>&1 | tail -5'", "sh -c 'echo hi' && git status",
        "bash -c 'ls | wc -l'; git log --oneline", "sh -c 'curl -s https://github.com/x/y | wc -c'", "bash -c 'grep -c digit a.txt'",
        "trap 'rm -f \"$tmp\"' EXIT", "watch -n 5 ls", "env -S 'swift build'", "env -uSSH_AUTH_SOCK git status", "env FOO=1 swift test",
        "echo hi | sh", "source ~/.config/x/tokens.env", ". scripts/env.sh", "source .venv/bin/activate && git status",
        // An expansion after git's command.
        "git log \"$branch\"", "git log \"$base\"..HEAD", "git log --oneline -- \"$f\"", "git show HEAD:\"$f\"", "git log -$n",
        "for f in a b; do git log --oneline -- $f; done", "git show HEAD@{1}", "git log -- *.swift", "git log --format='%h {%s}'",
        "git log $(git merge-base main HEAD)..HEAD", "git log --oneline `git merge-base main HEAD`..HEAD",
        "git ls-files | xargs wc -l", "git ls-files '*.swift' | xargs grep -l RefusedGit",
        "git diff --name-only | xargs -I{} git log -1 --oneline -- {}", "find . -name '*.swift' -exec git log --oneline -- {} \\;",
        "git ls-files | xargs git log --oneline --", "[ -d .git ] && git status", "[[ -n $x ]] && git status", "{ git status; git log -1; }",
        // The check scripts, as the briefs say to run them.
        "bash scripts/worktree-init.sh", "bash scripts/test.sh --filter 'RefusedGit'", "bash scripts/test.sh --filter 'LintTests/'",
        "bash scripts/test.sh --filter 'AccessibilityLint|AgentExportLint|DebugAidsLint|DocLinksLint|ElapsedTimeLint|HomePathLint|KeychainLint"
            + "|PreferencesLint|PrivateNamesLint|PrivateWriteLint|ScriptScratchLint|SecretShapeLint|TemporaryFolderLint'",
        "vs-heavy bash scripts/test.sh", "vs-heavy --timeout 2h bash scripts/test.sh", "bash scripts/test.sh --filter RefusedGit 2>&1 | tail -20",
        "scripts/test-under-load.sh --load 24 -r 3 -f 'RefusedGit'",
        "scripts/test-under-load.sh --load $((2 * $(getconf _NPROCESSORS_ONLN))) -r 3 -f 'RefusedGitFailsClosedTests'",
        "bash scripts/sandbox-app.sh run", "bash scripts/sandbox-app.sh type 'git status'", "bash scripts/sandbox-app.sh shot git-guard",
        "bash scripts/sandbox-app.sh quit", "bash scripts/test.sh --perf", "zsh scratch/probe.zsh", "bash scripts/e2e/wallet-e2e.sh",
        // The refused forms as text: an argument, a pattern, a here-document's body.
        "echo \"sh -c 'git push origin main'\"", "grep -rn 'eval \"git' Sources", "printf '%s\\n' 'x=push; git $x origin main'",
        "cat <<'EOF'\nsh -c 'git push origin main'\neval \"git -C /x status\"\nx=push; git $x origin main\nEOF",
        "cat > notes.md <<EOF\nsh -c 'git push' and eval \"git status\" are refused, as git \\$x is\nEOF",
        "cat > notes.md <<'EOF'\necho push | xargs git\nsource /dev/stdin <<< 'git push'\nEOF\ngit status",
    ]

    /// A worker's own harmless writes (the lead and the verifier are refused `git commit` and `git add` outright).
    static let harmlessForAWorker = [
        "git commit -m \"$msg\"", "git add \"$f\"", "for f in a.txt b.txt; do git add \"$f\"; done", "git merge main",
        "git commit -m 'Guard: sh -c \"git push\", eval \"git status\" and git $x are refused'",
        "git commit -m \"$(cat <<'EOF'\nGuard: refuse sh -c 'git push', eval \"git -C /x status\"\n\nx=push; git $x origin main; echo push | xargs git\nEOF\n)\"",
        "git commit -F - <<'EOF'\nGuard: sh -c 'git push' is refused\nEOF", "git diff HEAD -- a.txt | git apply -R",
        "git diff abc1234 HEAD -- Sources/VibeCore/RefusedGit.swift | git apply -R",
    ]

    @Test(arguments: [LeadLaunch.Role.worker, .verifier, .lead])
    func gitThatCantBeReadIsRefusedAndHarmlessLinesPass(_ role: LeadLaunch.Role) throws {
        let guardRail = try Guard(role, temp: temp)
        for line in Self.handed + Self.handedUnseen + Self.expanded {
            #expect(try guardRail.hookDenies(line, cwd: guardRail.root), "\(role)'s hook lets through: \(line)")
        }
        for line in Self.harmless {
            #expect(try !guardRail.hookDenies(line, cwd: guardRail.root), "\(role)'s hook refuses: \(line)")
        }
        guard role == .worker else { return }
        for line in Self.harmless + Self.harmlessForAWorker {
            #expect(try !guardRail.refuses(line), "a worker is refused: \(line)")
        }
    }

    /// Each refusal is the unreadable kind, and its reason says what to do instead: run the git plainly, without the
    /// wrapper or the variable.
    @Test func theReasonSaysToRunGitPlainly() throws {
        for line in Self.handed + Self.handedUnseen {
            guard case .unreadable(.handed)? = RefusedGit.refusal(in: line) else {
                Issue.record("not refused as handed over: \(line)")
                continue
            }
        }
        for line in Self.expanded {
            guard case .unreadable(.expanded)? = RefusedGit.refusal(in: line) else {
                Issue.record("not refused as expanded: \(line)")
                continue
            }
        }
        // As the session reads it, in the hook's answer.
        func reason(_ line: String) throws -> String {
            let event: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": line]]
            let answer = try #require(ReadOnlyCommand.hookAnswer(try JSONSerialization.data(withJSONObject: event), root: "/r", writes: true))
            let output = try #require((try JSONSerialization.jsonObject(with: answer) as? [String: Any])?["hookSpecificOutput"] as? [String: Any])
            #expect(output["permissionDecision"] as? String == "deny")
            return try #require(output["permissionDecisionReason"] as? String)
        }
        let wrapped = try reason("sh -c 'git push origin main'")
        #expect(wrapped.contains("Run the git command plainly") && wrapped.contains("without the wrapper") && wrapped.contains("to sh"))
        #expect(try reason("eval \"git -C /x status\"").contains("to eval"))
        #expect(try reason("env -S 'git push'").contains("to env -S"))
        let variable = try reason("x=push; git $x origin main")
        #expect(variable.contains("Run the git command plainly") && variable.contains("without the variable") && variable.contains("`$x`"))
        // A long word is cut in the reason.
        #expect(try reason("git $(echo \(String(repeating: "a", count: 500)))").count < 500)
    }

    /// The program's own name made by the shell, on a line that names git: it may be git (`g=git; $g push`; zsh's
    /// `=git` is git's full path). Refused when it comes from a variable, `=`, or a substitution alone; a path built
    /// on a substitution is an everyday form and passes, as does any of them on a line that doesn't name git.
    @Test(arguments: [LeadLaunch.Role.worker, .verifier, .lead])
    func aProgramNamedByAnExpansionIsRefusedOnALineThatNamesGit(_ role: LeadLaunch.Role) throws {
        let guardRail = try Guard(role, temp: temp)
        for line in ["g=git; $g push origin main", "g=git; ${g} status", "g=git; \"$g\" push", "g=/usr/bin/git; $g -P push", "=git -P push",
                     "=git status", "$(echo git) push", "`which git` status", "\"$(which git)\" log", "g=git; noglob $g push",
                     "g=git; timeout 60 $g push", "g=git; env $g push", "cd src && $(command -v git) status", "$EDITOR .git/config"] {
            #expect(try guardRail.hookDenies(line, cwd: guardRail.root), "\(role)'s hook lets through: \(line)")
            guard case .unreadable(.program)? = RefusedGit.refusal(in: line) else {
                Issue.record("not refused for its program's name: \(line)")
                continue
            }
        }
        for line in ["\"$(git rev-parse --show-toplevel)/scripts/x.sh\" args", "$(git rev-parse --show-toplevel)/scripts/test.sh --filter X",
                     "\"$HOME/bin/tool\" x", "$EDITOR notes.md", "\"$TMPDIR/probe\" && echo ok", "$(brew --prefix)/bin/swiftlint",
                     "x=1; $cmd arg", "=ls -l", "$(command -v swift) build", "`which swift` build", "./scripts/*.sh; git status"] {
            #expect(try !guardRail.hookDenies(line, cwd: guardRail.root), "\(role)'s hook refuses: \(line)")
        }
        let reason = try #require(RefusedGit.refusal(in: "g=git; $g push origin main")?.reason)
        #expect(reason.contains("`$g`") && reason.contains("run the git command plainly") && reason.contains("without the variable"))
    }

    /// What names git: the word alone, in a path, in git's variables and folder, in any case; not a longer word.
    @Test func gitIsNamedAsAWordNotInsideOne() {
        for text in ["git", "git push", "/usr/bin/git status", "GIT -P push", "x; git", "GIT_DIR=/x make", "cat .git/config", "g\"\"it", "g\\it",
                     "g''it push", "$(git status)", "a=1;git", "git-upload-pack", "égit"] {
            #expect(RefusedGit.names(text), "\(text)")
        }
        for text in ["", "gi", "github.com", "digit", "RefusedGit", "legit", "gitignore", "git2go", "ls | wc -l", "gi t", "g i t"] {
            #expect(!RefusedGit.names(text), "\(text)")
        }
    }

    /// A long line of interpreters is read to its end (each one's text is charged to the budget once), not refused
    /// for its length, and a refused one at its end is found.
    @Test func aLongLineOfInterpretersIsReadToItsEnd() throws {
        let worker = try Guard(.worker, temp: temp)
        let many = String(repeating: "eval 'echo a'; sh -c 'ls'; ", count: 10_000)
        #expect(try !worker.hookDenies(many + "echo done", cwd: worker.root))
        #expect(try worker.hookDenies(many + "eval 'git push'", cwd: worker.root))
        #expect(try worker.hookDenies(many + "git $x", cwd: worker.root))
    }
}
