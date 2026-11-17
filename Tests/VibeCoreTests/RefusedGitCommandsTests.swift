import Foundation
import Testing
@testable import VibeCore

/// A refused git command behind a harmless global option (`git -P push` matches no `Bash(git push:*)`), and git's
/// own settings through its environment (`GIT_DIR=x git status` reaches no option the hook reads): the role's
/// `PreToolUse` hook refuses both, in every permission mode.
struct RefusedGitCommandsTests {
    let temp = Scratch()
    typealias Guard = RefusedGitSpellingsTests.Guard

    /// The reported symptoms, as the contract quotes them.
    @Test func theWorkersGuardRefusesPushBehindAGlobalOptionAndGitDirInTheEnvironment() throws {
        let worker = try Guard(.worker, temp: temp)
        #expect(try worker.refuses("git -P push origin main"))
        #expect(try worker.refuses("GIT_DIR=/x git status"))
    }

    /// git's global options that change nothing a rule looks at, the one that takes a value (`--namespace n`) included.
    static let globalOptions = ["-P", "--no-pager", "-p", "--paginate", "--no-optional-locks", "--literal-pathspecs",
                                "--no-replace-objects", "--namespace n", "-P --no-pager"]

    /// Each git command a worker's rules refuse (`Guard` starts it on base `main`, records `docs/lead`), as git runs it
    /// after its options: named here rather than read from the rules they test.
    static let workersRefusedCommands: [String] = {
        var commands = ["push", "push origin main", "push --force origin agent/x",
                        "rebase main agent/other", "rebase --onto main HEAD~1 agent/other", "rebase --update-refs main",
                        "checkout -B main", "checkout --ignore-other-worktrees agent/other", "switch -C agent/other",
                        "switch --ignore-other-worktrees agent/other", "branch -f main HEAD", "branch --force main HEAD",
                        "branch -m agent/x", "branch -M agent/x", "commit-tree HEAD^{tree}", "branch -D x", "branch -d x",
                        "worktree add ../x", "worktree remove ../x", "tag v1", "tag -d v1", "commit --amend", "commit --amend -m x",
                        "add docs/lead/progress.md", "rm docs/lead/progress.md", "rm --cached docs/lead/x.md",
                        "update-ref refs/heads/main HEAD", "symbolic-ref HEAD refs/heads/main", "config user.name x",
                        "config --global alias.p push", "fetch", "fetch origin", "pull", "pull origin main", "replace HEAD HEAD~1",
                        "filter-branch --force", "reset --hard agent/"]
        for branch in ["main", "master", "agent/other"] {
            commands += ["checkout \(branch)", "checkout \(branch) -- a.txt", "checkout -f \(branch)", "switch \(branch)",
                         "switch \(branch) --discard-changes", "switch -f \(branch)", "reset --hard \(branch)", "reset --hard \(branch)~1"]
        }
        for verbose in ["", "-v ", "--verbose "] {
            commands += ["add x u", "rename origin x", "remove origin", "rm origin", "set-head origin main", "set-branches origin x",
                         "set-url origin u", "prune origin", "update"].map { "remote \(verbose)\($0)" }
        }
        return commands
    }()

    /// git's refused variables, named here.
    static let variables = ["GIT_DIR", "GIT_WORK_TREE", "GIT_EXEC_PATH", "GIT_COMMON_DIR", "GIT_CONFIG", "GIT_CONFIG_GLOBAL",
                            "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0",
                            "GIT_CONFIG_PARAMETERS"]

    /// Each variable set as an assignment before git, through `env`, and exported, then a few other ways.
    static let refusedEnvironment: [String] = variables.flatMap { name in
        ["\(name)=/x git status", "env \(name)=/x git status", "export \(name)=/x; git status"]
    } + ["export GIT_DIR=/x\ngit log", "GIT_DIR=/x; git status", "declare -x GIT_DIR=/x; git status", "export GIT_DIR; git status",
         "GIT_DIR+=/x git status", "GIT_PAGER=cat GIT_DIR=/x git log", "env -u HOME GIT_WORK_TREE=/x git status",
         "cd src && GIT_DIR=../x/.git git log", "(export GIT_CONFIG_PARAMETERS=\"'alias.s=push'\"; git s)", "GIT_DIR=/x make",
         "readonly GIT_DIR=/x; git status", "typeset -x GIT_WORK_TREE=/x; git status", "echo $(GIT_DIR=/x git log)",
         "/usr/bin/env GIT_DIR=/x git status", "time GIT_DIR=/x git status"]

    /// The contract's harmless lines and their neighbours: global options before a read, a variable git doesn't take
    /// from these, and the same forms as text (a message, a quoted here-document, a pattern).
    static let harmless = [
        "git -P log", "git --no-pager diff", "git status", "GIT_PAGER=cat git log", "git -P log --grep=push", "git -p log -1",
        "git --no-pager show HEAD:push.md", "git -P branch --show-current", "git --no-pager branch -a", "git log -- push.md",
        "GIT_OPTIONAL_LOCKS=0 git -P log", "echo GIT_DIR=x", "grep -rn 'GIT_DIR=' Sources", "unset GIT_DIR", "env -u GIT_DIR git status",
        "echo 'git -P push origin main; GIT_DIR=/x git status; export GIT_DIR=/x'", "git -P log --oneline main..HEAD",
        "cat <<'EOF'\ngit -P push origin main\nGIT_DIR=/x git status\nexport GIT_CONFIG_GLOBAL=/x\nEOF",
        "printf '%s\\n' 'git --no-pager branch -D x'", "git -P diff main...HEAD", "export PATH=/x:$PATH; git status",
        "find . -name '*.md' -exec grep -l push {} \\;",
    ]

    /// A worker's own harmless writes, and its steps onto its base, behind a global option.
    static let harmlessForAWorker = [
        "git commit -m 'git -P push origin main; GIT_DIR=/x git status'", "git -P merge main", "git --no-pager rebase main",
        "git -P switch -c topic", "git -P add a.txt", "git -P checkout -- a.txt", "git -P reset --hard HEAD",
        "git commit -m \"$(cat <<'EOF'\nGuard: export GIT_DIR=/x and git --no-pager branch -D x are refused\nEOF\n)\"",
        "git -P commit -m 'export GIT_DIR=/x'",
    ]

    @Test func eachCommandAWorkersRulesRefuseIsRefusedBehindAGlobalOption() throws {
        let worker = try Guard(.worker, temp: temp)
        for (at, command) in Self.workersRefusedCommands.enumerated() {
            let option = Self.globalOptions[at % Self.globalOptions.count]
            #expect(try worker.refuses("git \(option) \(command)"), "lets through: git \(option) \(command)")
            #expect(try worker.refuses("cd src && git \(option) \(command)"), "lets through: cd src && git \(option) \(command)")
        }
        // In the other wrappers' and compounds' forms the option check reads.
        for line in ["env git -P push", "/usr/bin/git --no-pager push", "(git -P push)", "echo $(git -P tag v1)",
                     "timeout 60 git --no-pager fetch", "find . -exec git -P push \\;", "git -P \"push\" origin main",
                     "git --no-pager 'branch' -D x", "git status; git -p pull"] {
            #expect(try worker.refuses(line), "lets through: \(line)")
        }
        for line in Self.harmless + Self.harmlessForAWorker {
            #expect(try !worker.refuses(line), "refuses: \(line)")
        }
    }

    /// The table names a command for each of the worker's git rules (as the test's own matcher reads a rule), so a rule
    /// added later without a row here fails.
    @Test func theTableCoversEachGitRuleOfAWorker() {
        let rules = LeadLaunch.deny(.worker, base: "main", records: "docs/lead").filter { $0.hasPrefix("Bash(git ") }
            .filter { !LeadLaunch.outsideReads.contains($0) && !RefusedGit.spellingRules.contains($0) && !RefusedGit.rules.contains($0) }
        #expect(rules.count > 40)
        for rule in rules {
            let covered = Self.workersRefusedCommands.contains { LeadGuardRailsTests.matches(rule, "git \($0)", emptyStar: false) }
            #expect(covered, "no row for \(rule)")
        }
    }

    @Test(arguments: [LeadLaunch.Role.worker, .verifier, .lead])
    func gitsVariablesAreRefusedHoweverSet(_ role: LeadLaunch.Role) throws {
        let guardRail = try Guard(role, temp: temp)
        for line in Self.refusedEnvironment {
            #expect(try guardRail.refuses(line), "\(role) lets through: \(line)")
        }
        for line in Self.harmless {
            #expect(try !guardRail.refuses(line), "\(role) refuses: \(line)")
        }
    }

    /// The lead and the verifier have their own list (no commits, no checkout): behind a global option too.
    @Test(arguments: [LeadLaunch.Role.verifier, .lead])
    func theLeadsAndVerifiersRefusedCommandsAreRefusedBehindAGlobalOption(_ role: LeadLaunch.Role) throws {
        let guardRail = try Guard(role, temp: temp)
        for line in ["git -P commit -m x", "git --no-pager push", "git -P checkout x", "git -P merge main", "git -P stash",
                     "git --no-pager config user.name x", "git -P log --output=x"] {
            #expect(try guardRail.refuses(line), "\(role) lets through: \(line)")
        }
    }

    /// Audit worker-git-guard-the:F3's remainder: each `find` in a `find -exec` read every `-exec` after it, so a chain
    /// of them cost 2^n and the hook timed out (which lets the call through). Refused now, without reading it all;
    /// waited on off the test's thread, so a reader that hangs fails the test rather than the run.
    @Test func aPathologicalFindExecLineIsRefusedNotReadForever() async throws {
        let worker = try Guard(.worker, temp: temp)
        let chain = "find . " + String(repeating: "-exec find . ", count: 60) + "-exec git status \\;"
        let deep = "find . " + String(repeating: "-exec find . ", count: 5_000) + "-exec git status \\;"
        let done = DispatchSemaphore(value: 0)
        let answers = Answers()
        Thread {
            answers.set([(try? worker.refuses(chain)) ?? false, (try? worker.refuses(deep)) ?? false])
            done.signal()
        }.start()
        #expect(await offPool { done.wait(timeout: .now() + hangGuard) } == .success)
        #expect(answers.get() == [true, true])
        // An honest find with several commands is still read: the git in it is checked, and a harmless one runs.
        #expect(try !worker.refuses("find . -name a -exec git log -1 -- {} \\; -exec git status \\;"))
        #expect(try worker.refuses("find . -name a -exec git log -1 -- {} \\; -exec git -P push \\;"))
        #expect(try worker.refuses("find . -exec echo {} + -exec git --no-pager tag v1 \\;"))
    }

    /// The lead's and the verifier's git rules are one list, so the hook reads either for both (it isn't told which).
    @Test func theLeadsAndVerifiersGitRulesAreTheSame() {
        #expect(LeadLaunch.deniedGit(.lead, base: "main", records: "docs/lead") == LeadLaunch.deniedGit(.verifier, base: "main", records: "docs/lead"))
    }

    /// A worker's hook written before it named its base still reads, and guards main and master.
    @Test func aWorkersHookWithoutItsBaseStillRefusesMain() throws {
        #expect(ReadOnlyCommand.hookOptions(["--root", "/r", "--worker"])?.writes == true)
        #expect(ReadOnlyCommand.hookOptions(["--root", "/r", "--worker", "--base", "lead", "--records", "docs/lead"])?.base == "lead")
        #expect(ReadOnlyCommand.hookOptions(["--root", "/r", "--worker", "--bogus", "x"]) == nil)
        let event: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "git -P checkout main"]]
        let answer = ReadOnlyCommand.hookAnswer(try JSONSerialization.data(withJSONObject: event), root: "/r", writes: true)
        #expect(answer.map { String(decoding: $0, as: UTF8.self) }?.contains("\"deny\"") == true)
    }

    /// A worker on a base other than main: the hook's command line carries it (`LeadLaunch.hooks` → `hookOptions` →
    /// `gitRules`), so its base is refused behind an option too, and its own steps onto it still run.
    @Test func aWorkersHookRefusesItsOwnBaseBehindAGlobalOption() throws {
        let hooks = LeadLaunch.hooks(.worker, server: "/opt/vibe switcher/vibeswitcher-mcp", root: "/r", base: "project-lead", records: "docs/lead")
        let group = try #require((hooks["PreToolUse"] as? [[String: Any]])?.first)
        let command = try #require((group["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        let words = try #require(ReadOnlyCommand.parts(of: command)?.first)
        let options = try #require(ReadOnlyCommand.hookOptions(Array(words.dropFirst(2))))
        #expect(options.base == "project-lead" && options.records == "docs/lead" && options.writes)
        func denies(_ line: String) throws -> Bool {
            let event: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": line]]
            let answer = ReadOnlyCommand.hookAnswer(try JSONSerialization.data(withJSONObject: event), root: options.root,
                                                    writes: options.writes, base: options.base, records: options.records)
            return answer.map { String(decoding: $0, as: UTF8.self) }?.contains("\"deny\"") == true
        }
        for line in ["git -P checkout project-lead", "git --no-pager switch project-lead", "git -P reset --hard project-lead",
                     "git -P add docs/lead/progress.md"] {
            #expect(try denies(line), "lets through: \(line)")
        }
        for line in ["git -P merge project-lead", "git --no-pager rebase project-lead", "git -P add a.txt"] {
            #expect(try !denies(line), "refuses: \(line)")
        }
    }

    /// The blind check's: a long line of short gits is read to its end (each git tries only the rules naming its
    /// command, charged to the budget), and its refused command found.
    @Test func aLongLineOfShortGitsIsReadToItsRefusal() throws {
        let worker = try Guard(.worker, temp: temp)
        let many = String(repeating: "git a; ", count: 20_000)
        #expect(try worker.refuses(many + "git -P push"))
        #expect(try !worker.refuses(many + "git -P log"))
    }

    /// A combining mark (U+0301) right after a space or `=` joins it in one `Character`, though the shell splits the
    /// words there as ever: the words are compared a byte at a time, so `git push ́x` is still `git push`.
    @Test func aCombiningMarkAfterASpaceOrEqualsHidesNothing() throws {
        let worker = try Guard(.worker, temp: temp)
        for line in ["git -P push \u{301}x", "git -P remote add \u{301}r u", "GIT_DIR=\u{301}x git status", "env GIT_DIR=\u{301}x git status",
                     "export GIT_CONFIG_GLOBAL=\u{301}x; git status", "git --no-pager checkout \u{301}x main", "git -P tag \u{301}v"] {
            #expect(try worker.refuses(line), "lets through: \(line.unicodeScalars.map { $0.isASCII ? String($0) : "\\u{\(String($0.value, radix: 16))}" }.joined())")
        }
        #expect(try !worker.refuses("git -P log \u{301}x"))
    }

    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [Bool] = []
        func set(_ new: [Bool]) { lock.withLock { value = new } }
        func get() -> [Bool] { lock.withLock { value } }
    }
}
