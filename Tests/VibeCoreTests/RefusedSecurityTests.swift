import Foundation
import Testing
@testable import VibeCore

/// 2026-11-26: another program of your account can replace VibeSwitcher's Keychain keys with `security
/// add-generic-password -U` and friends, and that measurement's probing crashed the Mac's keychain daemon and locked
/// the login keychain. No session VibeSwitcher starts (lead, worker, verifier) runs `security`: each role's deny
/// rules name its usual forms, and its `PreToolUse` hook refuses it in every form the git guard reads for git (a full
/// path, behind `env`, `command`, `xcrun`, `sudo` and the rest, in a compound line, handed to `sh -c` or `eval`).
/// Nothing here runs it: the lines are only read.
struct RefusedSecurityTests {
    let temp = Scratch()
    typealias Guard = RefusedGitSpellingsTests.Guard

    static let roles: [LeadLaunch.Role] = [.lead, .worker, .verifier]

    /// `security` as the git guard's spellings name git (`RefusedGitSpellingsTests.refusedSpellings`): bare, by path,
    /// behind each wrapper, in its case or quoted.
    static let refusedSpellings = [
        "security add-generic-password -U -s dev.vibeswitcher.app-proof -a app -w x",
        "security delete-generic-password -s dev.vibeswitcher.lead-vault -a vault", "security find-generic-password -s x -w",
        "security list-keychains -d user", "security dump-keychain", "security create-keychain -p x k.keychain", "security",
        "/usr/bin/security find-generic-password -s x", "/usr/bin/../bin/security list-keychains", "./security list-keychains",
        "env security list-keychains", "/usr/bin/env security list-keychains", "env -i security list-keychains",
        "env -u HOME security list-keychains", "env FOO=1 security list-keychains", "command security list-keychains",
        "command -p security list-keychains", "builtin security", "exec security list-keychains",
        "xcrun security list-keychains", "xcrun --sdk macosx security list-keychains", "sudo security list-keychains",
        "sudo -u root security list-keychains", "nohup security list-keychains", "nice -n 5 security list-keychains",
        "time security list-keychains", "/usr/bin/time security list-keychains",
        // Under `timeout`, its name interpolated: KeychainCallLintTests never lets that text stand in any file (a
        // keychain client killed mid-call), and this one is only read.
        "timeout 5 \(RefusedGit.keychainTool) list-keychains",
        "caffeinate -t 5 security list-keychains", "arch -arm64 security list-keychains", "stdbuf -o0 security list-keychains",
        "vs-heavy security list-keychains", "noglob security list-keychains", "nocorrect security list-keychains",
        "repeat 2 security list-keychains", "FOO=1 security list-keychains",
        "SECURITY list-keychains", "Security list-keychains", "/USR/BIN/SECURITY list-keychains",
        "'security' list-keychains", "\"security\" list-keychains", "\\security list-keychains", "s\"\"ecurity list-keychains",
    ]

    /// In a compound line, as `RefusedGitSpellingsTests.refusedCompounds` puts git.
    static let refusedCompounds = [
        "cd src && security list-keychains", "true; security list-keychains", "(security list-keychains)",
        "git status || security list-keychains", "git log | security list-keychains", "echo $(security find-generic-password -s x -w)",
        "echo \"$(security find-generic-password -s x -w)\"", "echo `security list-keychains`", "{ security list-keychains; }",
        "if true; then security list-keychains; fi", "git status\nsecurity list-keychains", "git status & security list-keychains",
        "! security list-keychains", "for f in a; do security list-keychains; done", "x=$(security list-keychains)",
        "cat <(security list-keychains)", "cat <<EOF\n$(security list-keychains)\nEOF",
        "find . -name x -exec security list-keychains \\;", "find . -execdir security delete-keychain {} +",
        "echo k | xargs security delete-keychain", "echo k | xargs -n 1 security delete-keychain",
        "if [[ -n x ]] security list-keychains", "function f { security list-keychains; }",
        // Text handed to another interpreter, or a name the shell makes, on a line that names it.
        "sh -c 'security list-keychains'", "bash -c \"security add-generic-password -U -s x -a y -w z\"", "zsh -c 'security'",
        "eval 'security list-keychains'", "eval \"sec\"\"urity list-keychains\"", "env -S 'security list-keychains'",
        "watch security list-keychains", "trap 'security list-keychains' EXIT", "alias k='security list-keychains'",
        "x=security; $x list-keychains", "$(echo security) list-keychains", "echo security | sh", "sh <<< 'security list-keychains'",
    ]

    /// Lines that mention it as text, and the scripts that run it in your own shell: refused by nothing new. A shell
    /// running a file isn't read (scripts/build-app.sh's `security list-keychains` and `find-identity` run when you
    /// install, in your shell, never in a team session).
    static let harmless = [
        "grep -rn security Sources", "rg 'security add-generic-password' docs", "git log --grep=security",
        "echo 'security add-generic-password -U'", "cat docs/eval/security.md",
        "ls Tests/SecurityAudit", "swift test --filter SecurityAuditTests", "bash scripts/build-app.sh", "bash scripts/build-app.sh --install",
        "scripts/build-app.sh", "bash scripts/sandbox-app.sh run", "bash scripts/test.sh --filter RefusedSecurityTests",
        "cat <<'EOF'\nsecurity list-keychains\nEOF", "printf '%s\\n' 'security dump-keychain'", "which security", "man security",
    ]

    @Test func everyRoleRefusesSecurityInEveryFormTheGitGuardReads() throws {
        for role in Self.roles {
            let roleGuard = try Guard(role, temp: temp)
            for line in Self.refusedSpellings + Self.refusedCompounds {
                #expect(try roleGuard.hookDenies(line, cwd: roleGuard.root), "\(role) hook: \(line)")
            }
            // The deny rules, a first layer that holds even if the hook doesn't run: the forms a rule can name.
            for line in ["security list-keychains", "security add-generic-password -U -s x -a y -w z", "security",
                         "/usr/bin/security list-keychains", "env security list-keychains", "/usr/bin/env security list-keychains",
                         "command security list-keychains", "xcrun security list-keychains", "sudo security list-keychains",
                         "exec security list-keychains"] {
                #expect(LeadGuardRailsTests.denied(line, by: roleGuard.deny), "\(role) rules: \(line)")
            }
        }
    }

    @Test func itsRefusalSaysWhyAndWhereKeychainChecksGo() throws {
        let reason = try #require(RefusedGit.refusal(in: "env security list-keychains")).reason
        for words in ["`security`", "every session it starts", "keychain daemon", "keyboard session with the user"] {
            #expect(reason.contains(words), "\(words): \(reason)")
        }
    }

    @Test func textAboutItAndTheInstallScriptsAreAsBefore() throws {
        for role in Self.roles {
            let roleGuard = try Guard(role, temp: temp)
            for line in Self.harmless {
                #expect(try !roleGuard.hookDenies(line, cwd: roleGuard.root), "\(role) hook: \(line)")
                #expect(!LeadGuardRailsTests.denied(line, by: roleGuard.deny.filter { $0.contains("security") }), "\(role) rules: \(line)")
            }
        }
        // A worker's commit message that names it (the lead and the verifier commit nothing).
        #expect(try !Guard(.worker, temp: temp).hookDenies("git commit -m 'refuse security to every role'", cwd: Guard(.worker, temp: temp).root))
        // The install script still does its keychain work itself, in your shell.
        let script = try String(contentsOfFile: Self.repository + "/scripts/build-app.sh", encoding: .utf8)
        #expect(script.contains("security list-keychains -d user") && script.contains("security find-identity"))
    }

    /// The worker's brief (and the verifier's) says Keychain probes are the user's, in a keyboard session; a Codex
    /// worker, which has no deny rules, is told it's a rule it holds itself.
    @Test func theBriefsSayKeychainProbesAreDoneOnlyWithTheUser() throws {
        for words in ["never run `security`", "keyboard session with the user", "scratch seams", "locked the user's login keychain"] {
            #expect(LeadPrompts.keychain.contains(words), "\(words)")
        }
        var task = LeadTask(slug: "t", title: "T", contract: LeadContract(goal: "g", acceptance: ["a"], boundaries: [], context: ""))
        let worker = LeadPrompts.worker(task: task, root: "/r", workflow: LeadWorkflow(), policy: "", lints: [], screenshots: .some(nil))
        #expect(worker.contains(LeadPrompts.keychain))
        task.agent = .codex
        let codex = LeadPrompts.worker(task: task, root: "/r", workflow: LeadWorkflow(), policy: "", lints: [], screenshots: .some(nil))
        #expect(codex.contains(LeadPrompts.keychain))
        #expect(LeadLaunch.codexUnenforced.contains { $0.rule.contains("`security`") })
    }

    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().path
}
