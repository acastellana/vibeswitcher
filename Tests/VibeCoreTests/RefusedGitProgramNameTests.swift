import Foundation
import Testing
@testable import VibeCore

/// The audit of keychain-keys-the-stated (round 1, F3): the guard read a program's name made by the shell only when it
/// came from a variable or a substitution alone, or a pattern starting with `=` or holding `{`, and only on a line that
/// names git. `/usr/bin/gi? push origin main`, `g=gi; ${g}t push origin main`, `script -q /dev/null git push origin
/// main` and `setsid git push origin main` all ran unrefused, and `security` with them. Now a command whose name the
/// shell makes (a pattern, a variable or a substitution in its last name, or an expansion unquoted anywhere in it,
/// which the shell splits) is refused on any line, and so is a launcher the guard doesn't read (`script`, `setsid`, …),
/// whatever it runs. A `[[ … ]]` test's operands aren't programs only in its plain form; any other is read the strict
/// way (the re-roll's contract, after two attempts that modelled the shell's grammar and let commands through).
/// Lines are only read: nothing here runs git, `security` or a launcher.
struct RefusedGitProgramNameTests {
    let temp = Scratch()
    typealias Guard = RefusedGitSpellingsTests.Guard

    /// The finding's lines, as the audit ran them through the hook, and their `security` twins.
    static let finding = ["/usr/bin/gi? push origin main", "g=gi; ${g}t push origin main", "script -q /dev/null git push origin main",
                          "setsid git push origin main", "/usr/bin/securit? list-keychains", "s=securit; ${s}y list-keychains",
                          "script -q /dev/null security list-keychains", "setsid security find-generic-password -s x"]

    /// The re-roll's audit: each was allowed by the earlier attempt (a test it took as open where the shell had closed
    /// it, or never opened one) and hides a command that runs.
    static let audit = ["[[ ( -z a )]] || git -C /tmp status", "[[ ( -z a )]] || setsid ls", "[[ ( -z a )]] || $EDITOR notes.md",
                        "\"[[\" x || setsid ls", "\\[[ x || $EDITOR notes.md", "\"if\" [[ x || setsid ls",
                        "case y in a) :;; \\[\\[ ) setsid ls ;; esac"]

    /// A program's name the shell makes: a pattern, a variable or a substitution in its last name; braces anywhere
    /// (they hold `/` and `,`); an unquoted expansion anywhere (split into words); zsh's `=`.
    static let made = [
        "/usr/bin/gi? push origin main", "/usr/bin/g[i]t push", "/usr/bin/*it status", "/usr/bin/gi* push", "g=gi; ${g}t push origin main",
        "g=gi; $g't' push", "a=g; b=it; $a$b push", "\"$(echo /usr/bin/gi)t\" push", "`echo gi`t push", "\"${d:-/usr/bin/gi}t\" push",
        "\"$d/gi$x\" push", "\"$tool\" --version", "$tool --version", "${t} push", "$(printf 'gi%s push origin main -o' t)/x",
        "$d/x push", "$(brew --prefix)/bin/swiftlint", "{/usr/bin/gi,x}t push", "/usr/bin/{gi,x}t push", "\"\"{/usr/bin/gi,-C}t",
        "=ls -l", "$'\\x67it' push", "cd src && ${g}t push", "true; $(echo gi)t push", "(${g}t push)",
        "echo $(${g}t push)", "timeout 60 ${g}t push", "env ${g}t push", "noglob /usr/bin/gi? push", "FOO=1 ${g}t push",
        "if true; then ${g}t push; fi", "find . -name x -exec ${g}t push \\;", "for f in a; do $f push; done",
        "xargs -I{} ${g}t {}", "vs-heavy --timeout 2h $cmd", "sudo -u x $cmd", "command $cmd", "exec \"$@\"",
        // `case … in` as an argument doesn't make what follows a pattern.
        "(echo case x in; /usr/bin/gi? push origin main)", "echo case x in; (g=gi; ${g}t push origin main)",
        "(echo case x in; g=git; $g push origin main)", "echo case x in\n(/usr/bin/gi? push)",
        // A test's `&&`, `||` and parentheses are its own only in a plain `[[ … ]]` test; what follows runs, and a
        // substitution in a test runs.
        "echo [[ && /usr/bin/gi? push", "echo [[ || ${g}t push", "echo x [[ ; (/usr/bin/gi? push)", "[[ -n a ]]&& /usr/bin/gi? push",
        "[[ -n a ]] && ${g}t push", "if [[ -n a ]]; then ${g}t push; fi", "[[ -n $(${g}t push) ]]", "[[ $x =~ (a) ]] || $(echo gi)t push",
        "[[ -n `$cmd` ]]", "[[ -n <($cmd) ]]", "if [[ -n a ]] $cmd x", "[[ a ]]\n$cmd x", "x=$([[ a ]] && $cmd)",
        // The forms the old reading let through as everyday, now refused: a program from a variable or a substitution,
        // and a loop whose body's program is a variable (the lead's ruling, 2026-11-26).
        "$EDITOR notes.md", "x=1; $cmd arg", "$(command -v swift) build", "`which swift` build", "./scripts/*.sh; git status",
        "$(git rev-parse --show-toplevel)/scripts/test.sh --filter X", "for t in a b; do $t --version; done",
        "ls | while read -r f; do \"$f\" --version; done",
    ]

    /// Odd-looking tests, read the strict way: not the plain form, so each word that could be a program is read as one.
    /// Harmless, and the accepted cost: the reason says to write the test plainly.
    static let oddTests = [
        "[[ $f == (*.swift|*.md) ]] && echo yes", "[[ -n $a &&\n $b ]] && echo ok", "[[ ( $a == x )]] && echo $b", "[[ ( $a ]] ) || $b",
        "\"[[\" $a ]] || $b", "[[ \"]]\" || $b ]]", "[[ a ]]x || $b", "[[ a || $b", "[[ x || $y )]]",
        "case $x in *) [[ -n a || $b ]] ;; esac", "[[ $a == x ||\t$b == y ]]extra",
    ]

    /// The launchers it doesn't read: refused whatever they run, and behind the wrappers it does read.
    static let launchers = [
        "script -q /dev/null git push origin main", "setsid git push origin main", "script -q /dev/null swift test", "setsid -f make",
        "/usr/bin/script -q out.log ls", "env setsid git push", "timeout 5 script -q /dev/null git push", "nohup setsid git push",
        "find . -exec setsid git push \\;", "cd src && setsid ls", "chroot / git push", "sandbox-exec -n no-network git push",
        "taskpolicy -b git push", "unbuffer git push", "su -c 'make' root", "doas git push", "flock .build/x.lock git push",
        "SCRIPT -q /dev/null git push", "(echo case x in; script -q /dev/null git push origin main)", "echo case x in; (setsid git push)",
        "[[ a ]] && script -q /dev/null git push", "[[ -n a ]] && setsid ls", "case x in a) setsid ls ;; esac",
        "case x in a) :;; [[ ) setsid ls ;; esac", "case x in (a) setsid ls;; esac", "case x in a|b) :;; c d) setsid ls;; esac",
    ]

    /// The `[[ … ]]` tests the contract names, read as tests: none is refused.
    static let plainTests = [
        "[[ -z $x || $y == z ]] && echo ok", "[[ -n \"$a\" && \"$a\" != x ]] && echo ok", "[[ $a && $b ]]",
        "while [[ $i -lt 3 && -n $x ]]; do :; done", "if [[ ! -e $f || $f -nt $g ]]; then :; fi", "[[ $x == *.swift || $x == *.md ]]",
        "[[ $v =~ ^[0-9]+(\\.[0-9]+)?$ ]]",
    ]

    /// Everyday lines, from this repository's scripts and the workers' usual commands: paths and arguments with patterns,
    /// variables and substitutions in arguments, a path with its expansion quoted and its last name written out, loops
    /// over files, `case` arms, zsh's glob qualifiers and a test's pattern group, arrays. None is refused.
    static let everyday = plainTests + [
        "bash scripts/worktree-init.sh", "bash scripts/test.sh --filter RefusedGitProgramNameTests", "vs-heavy bash scripts/test.sh",
        "vs-heavy --timeout 2h bash scripts/test.sh", "scripts/test-under-load.sh --load 24 -r 3 -f 'RefusedGit'",
        "scripts/test-under-load.sh --load $((2 * $(getconf _NPROCESSORS_ONLN))) -r 3 -f 'NewTests'",
        "bash scripts/sandbox-app.sh run", "bash scripts/sandbox-app.sh shot settings", "bash scripts/sandbox-app.sh quit",
        "swift build -j 2 -Xswiftc -j$(( (VS_HEAVY_CORES + 1) / 2 ))", "vs-heavy swift build -j 2 -Xswiftc -j$(( (VS_HEAVY_CORES + 1) / 2 ))",
        "vs-heavy make -j $VS_HEAVY_CORES", "vs-heavy node --test --test-concurrency=$VS_HEAVY_CORES",
        "ls Sources/VibeCore/*.swift", "wc -l Sources/VibeCore/*.swift | sort -n | tail -5", "grep -rn RefusedGit Sources Tests --include=*.swift",
        "rg -n 'program' Sources/VibeCore", "for f in Tests/VibeCoreTests/RefusedGit*.swift; do wc -l \"$f\"; done",
        "for f in scripts/*.sh; do bash -n \"$f\" || echo \"$f\"; done",
        "for t in RefusedGitSpellingsTests RefusedSecurityTests; do bash scripts/test.sh --filter \"$t\"; done",
        "while read -r f; do echo \"$f\"; done < files.txt", "find Sources -name '*.swift' -newer Package.swift",
        "find . -name '*.orig' -print", "find Tests -name 'Refused*.swift' -exec wc -l {} +", "git ls-files '*.swift' | xargs wc -l | tail -1",
        "git diff main...HEAD --stat", "git log --oneline -5 -- Sources/VibeCore/RefusedGit.swift", "git status",
        "git diff HEAD -- Sources/VibeCore/RefusedGit.swift | head -40", "git blame -L 454,466 Sources/VibeCore/RefusedGit.swift",
        "git log --format='%h %s' main..HEAD", "git log -- *.swift", "cat \"$TMPDIR/notes.txt\"",
        "mkdir -p \"$TMPDIR/scratch\" && cd \"$TMPDIR/scratch\"", "echo \"$HOME\" \"$PWD\" ${#PATH}", "export PATH=\"$HOME/.local/bin:$PATH\"",
        "ROOT=$(git rev-parse --show-toplevel); cd \"$ROOT\"", "\"$(git rev-parse --show-toplevel)/scripts/test.sh\" --filter X",
        "\"$(git rev-parse --show-toplevel)\"/scripts/test.sh --filter X", "\"$ROOT/scripts/x.sh\" args",
        "\"$HOME/.vibeswitcher/bin/vibeswitcher-hook\" --version", "\"$TMPDIR/probe\" && echo ok", "\"$ROOT\"/.build/debug/vibeswitcher-mcp --help",
        "\"$(brew --prefix)/bin/swiftlint\" lint", "./.build/debug/VibeSwitcher --dump", ".build/arm64-apple-macosx/debug/vibeswitcher-hook --help",
        "~/.vibeswitcher/bin/vibeswitcher-hook --version", "case \"$1\" in *.swift) echo swift ;; a|b*) echo b ;; *) echo other ;; esac",
        "case $f in\n  *.md) echo doc ;;\n  [A-Z]*|x|y) echo upper ;;\n  *)\n    ;;\nesac", "case $x in\n  @(a|b)) echo ab ;;\nesac",
        "ls *(.om[1])", "ls -d Sources/*(/)", "files=(Sources/**/*.swift); echo ${#files}",
        "files=($(git ls-files '*.swift')); wc -l \"${files[@]}\"", "tail -n 50 .build/sandbox-shots/*.log", "ls .build/sandbox-shots/*-dark.png",
        "dyld_info -disassemble .build/debug/VibeSwitcher | head", "ls ~/Library/Logs/DiagnosticReports/VibeSwitcher*",
        "jq '.permissions.deny' \"$f\"", "python3 -I scripts/cache-cold-cost.py --help", "sed -n '450,470p' Sources/VibeCore/RefusedGit.swift",
        "awk '/func /{print FILENAME\": \"$0}' Sources/VibeCore/*.swift | head", "printf '%s\\n' \"${lines[@]}\"", "test -f Package.swift && echo yes",
        "[ -d .build ] || mkdir .build", "time swift build", "timeout 600 bash scripts/test.sh --filter X", "kill $!", "pgrep -f \"$PWD\"",
        "nohup bash scripts/sandbox-app.sh run > \"$TMPDIR/sandbox.log\" 2>&1 &", "echo $((1 + 2))", "if [ -n \"$CI\" ]; then echo ci; fi",
        "x=$(date +%s); echo \"$x\"", "cd \"$(dirname \"$0\")\"", "source .venv/bin/activate", "env -u CLAUDECODE bash scripts/test.sh",
        "xargs -n 1 echo < list.txt", "ls -la \"${TMPDIR:-/tmp}\"", "swift package describe --type json | jq '.targets[].name'",
        "diff <(git show main:Sources/VibeCore/RefusedGit.swift) Sources/VibeCore/RefusedGit.swift | head", "{ echo a; echo b; } | wc -l",
        "grep -rn 'script -q' docs", "echo setsid", "man script", "command -v swift", "command -v \"$tool\" >/dev/null || echo missing",
        "[[ $x =~ ^[0-9]+([.][0-9]+)?$ ]] && echo n", "[[ $x =~ ^(a|b)$ ]]", "if ! [[ -d $dir || -L \"$dir\" ]]; then mkdir -p \"$dir\"; fi",
        "x=$([[ $v =~ ^(a|b)$ ]] && echo y)", "[[ $x == @(a|b) ]] && echo ab", "[[ -n $a ]] && [[ -z $b || $c ]] && echo ok",
        "{ [[ -n $a || $b ]]; } && echo ok", "[[ ( -n $a ) && ( $b || $c ) ]] && echo ok", "[[ $n -gt 1 && ( $s -ne 0 || $c -eq 0 ) ]]", "( [[ -n $a || $b ]] ) && echo ok", "until [[ -e $f || $n -gt 9 ]]; do sleep 1; done",
        "[[ $a < $b || $c > $d ]] && echo ok", "[[ $(git rev-parse HEAD) == $x ]] && echo same", "[[ -n $a ]]; echo $?",
        // docs/guide/development.md's heavy jobs: text handed to sh that doesn't name git, its variable an argument.
        "vs-heavy sh -c 'node --test --test-concurrency=\"$VS_HEAVY_CORES\"'", "vs-heavy sh -c 'make -j \"$VS_HEAVY_CORES\"'",
        "vs-heavy sh -c 'swift build -j 2 -Xswiftc -j$(( (VS_HEAVY_CORES + 1) / 2 ))'", "f() { echo \"$1\"; }; f x", "[ \"$a\" = \"$b\" ] && echo same",
    ]

    @Test func theFindingsAndTheAuditsLinesAreRefusedByTheHook() throws {
        for role in [LeadLaunch.Role.worker, .verifier, .lead] {
            let guardRail = try Guard(role, temp: temp)
            for line in Self.finding + Self.audit {
                #expect(try guardRail.hookDenies(line, cwd: guardRail.root), "\(role)'s hook lets through: \(line)")
            }
        }
    }

    @Test(arguments: [LeadLaunch.Role.worker, .verifier, .lead])
    func aProgramNameTheShellMakesOrALauncherIsRefusedAndEverydayLinesPass(_ role: LeadLaunch.Role) throws {
        let guardRail = try Guard(role, temp: temp)
        for line in Self.made + Self.launchers + Self.oddTests {
            #expect(try guardRail.hookDenies(line, cwd: guardRail.root), "\(role)'s hook lets through: \(line)")
        }
        #expect(Self.everyday.count >= 80)
        for line in Self.everyday {
            #expect(try !guardRail.hookDenies(line, cwd: guardRail.root), "\(role)'s hook refuses: \(line)")
        }
    }

    /// The everyday lines pass the guard itself (not only a role's hook), and the refused ones say why and how to
    /// rewrite the line.
    @Test func eachRefusalSaysHowToRewriteTheLine() {
        for line in Self.everyday {
            #expect(RefusedGit.refusal(in: line) == nil, "refused: \(line): \(RefusedGit.refusal(in: line)?.reason ?? "")")
        }
        for line in Self.made where !line.contains("git ") || line.contains("${g}t") {
            let reason = RefusedGit.refusal(in: line)?.reason ?? ""
            #expect(reason.contains("whose name the shell makes") && reason.contains("Write the program's name out"), "\(line): \(reason)")
        }
        for line in Self.launchers where !line.contains("case") || line.contains("setsid ls") {
            let reason = RefusedGit.refusal(in: line)?.reason ?? ""
            #expect(reason.contains("doesn't read") && reason.contains("Run the command without it"), "\(line): \(reason)")
        }
        for line in Self.oddTests {
            let reason = RefusedGit.refusal(in: line)?.reason ?? ""
            #expect(reason.contains("write the test plainly"), "\(line): \(reason)")
        }
        // The word, and how to keep a path's expansion and a loop's variable.
        let reason = RefusedGit.refusal(in: "g=gi; ${g}t push origin main")?.reason ?? ""
        #expect(reason.contains("`${g}t`") && reason.contains("double quotes") && reason.contains("\"$ROOT/scripts/x.sh\"")
            && reason.contains("bash \"$f\""), "\(reason)")
        #expect(RefusedGit.refusal(in: "setsid git push")?.reason.contains("`setsid`") == true)
    }

    /// A path whose last name is written out is read by that name, its expansion quoted: git and `security` there are
    /// read as themselves (`"$d/git" push` is a git push, refused by the role's rules like any).
    @Test func aQuotedPathIsReadByItsLastName() throws {
        let worker = try Guard(.worker, temp: temp)
        #expect(RefusedGit.refusal(in: "\"$d/git\" -C /x status") == .option("-C"))
        #expect(RefusedGit.refusal(in: "\"$(brew --prefix)/bin/git\" -c x=y log") == .option("-c"))
        #expect(RefusedGit.refusal(in: "\"$d/security\" list-keychains") == .keychain)
        #expect(try worker.hookDenies("\"$d/git\" push origin main", cwd: worker.root))
    }
}
