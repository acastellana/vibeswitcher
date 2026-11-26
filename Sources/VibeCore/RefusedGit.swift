import Foundation

/// The git options no role runs, in every spelling git takes: global options (before git's command) that pick another
/// repository, work tree, config or set of git programs, so a role's rules on `git <command>` would see a different git
/// than the one that runs (`git -C . push`, `git -c alias.x=push x`, `git --git-dir=<main>/.git update-ref …`). The
/// same settings through git's environment (`variables`), and the git commands a role's deny rules refuse, behind any
/// global option (`git -P push` matches no `Bash(git push:*)`).
///
/// A rule matches by its text: `Bash(git --git-dir:*)` is `git --git-dir` then a space, so on 2026-11-17 the Code Mode
/// trial's worker ran `git --git-dir=<path> for-each-ref` in auto mode, where nothing asked. So the list is kept here
/// once: `rules` and `spellingRules` (each role's deny rules, `LeadLaunch.gitAround`, a first layer that holds even if
/// the hook fails to run), and `refusal`, the parsed check each role's `PreToolUse` hook runs on every Bash call
/// whatever the permission mode (`ReadOnlyCommand.hookAnswer`): it finds each git a line runs (after `;`, `&&`, `|`, in
/// a subshell, `$(…)`, backticks, behind `env`/`command`/a full path) and refuses a listed option anywhere before git's
/// command (`git -P -C x status`), spaced, with `=`, or attached (`-C<path>`, `-c<name>=<value>`: git 2.54 rejects
/// those, refused anyway); a refused command after git's options, whichever come first (`git --no-pager branch -D x`,
/// matched as `git branch -D x` against the role's rules, `LeadLaunch.gitRules`); and a refused variable set for a
/// command (`GIT_DIR=x git status`, `env GIT_DIR=x git …`), on its own (`GIT_DIR=x; git …`) or exported
/// (`export GIT_DIR=x`, `declare -x`, `readonly`), whatever runs after it; and `HOME` or `XDG_CONFIG_HOME` (git's global
/// config) set for a git (`arch -e` too). The program and git's command are found without their case (`GIT -P push`,
/// `git Filter-Branch`: this Mac's volume finds them), behind zsh's precommand modifiers (`noglob`, `nocorrect`, `-`),
/// its `repeat N`, its short forms' tests (`if [[ … ]] git …`, `while (( … )) git …`) and its `{ … } always { … }`,
/// with a redirection anywhere (`git &>/dev/null push`, `git >&/dev/null push`); and git's own programs by their name in
/// any folder (`…/libexec/git-core/git-push` is `git push`).
///
/// What can't be read is refused, not guessed at (`Refusal.Unread`; decision 2026-10-25 16:33: hardening fails closed):
/// the same git run plainly is read, so a refusal costs a rewrite. That is text naming git (`names`: without its case,
/// quotes and backslashes taken out) handed to another interpreter: a shell's `-c` string (`sh`/`bash`/`zsh -c '…'`,
/// behind `xargs` or `find -exec` too), `eval`, `trap`, `watch`, `env -S`, zsh's glob qualifiers (`*(e:'…':)`), or a
/// name made for it (`alias g='git …'`, `hash -p /usr/bin/git g`); text that isn't all on the line (a word of it made
/// from an expansion, by this shell or the one it's handed to, `x=git; eval '$x push'`, or put in by `xargs` or `find`;
/// zsh's `${(e)x}`; or a shell or `source`/`.` reading its input: a here-string, a here-document, a pipe, `/dev/stdin`,
/// `<(…)`, zsh's `=(…)`, a shell option this doesn't read (`bash -s`, fish's), or any path when the command is given
/// input) on a line that names git anywhere. And a git whose option or command word the shell makes from an expansion
/// (`git $x …`, `git ${o:--C} x`, `git {push,x}`, `git pus?`, zsh's `git =x` and `git pus(h|x)`), or that the program
/// running it fills in (`xargs git`, `xargs -I% git % x`, `find -exec git {} \;`).
///
/// And, on any line (`built`; the audit of keychain-keys-the-stated, F3), a program whose own name the shell makes,
/// since it can be git or security: a pattern, a variable or a substitution in its last name (`/usr/bin/gi? push`,
/// `g=gi; ${g}t push`, `"$tool" x`, `$(echo git) push`, zsh's `=git push`), an expansion not quoted anywhere in it,
/// which the shell splits, braces too (`$(brew --prefix)/bin/x`, `{/usr/bin/gi,x}t`), or what xargs or find put there
/// (`find … -exec {} \;`); a loop whose body's program is a variable too (`for t in git; do $t push; done`). A path
/// whose expansion is in double quotes and whose last name is written out is read by that name (`"$ROOT/scripts/x.sh"`,
/// `"$d/git" push` is a git). And a launcher it doesn't read (`script`, `setsid`, `chroot`, `su`, …: `launchers`),
/// whatever it runs. A `[[ … ]]` test's operands aren't programs only in its plain form, and a `case` arm's pattern
/// only in its plain form (`ShellWords.scan`); a line with any other (a quoted or escaped `[[`, `)]]`, a test across
/// lines, a `case` with a test) is read the strict way: each word that could be a program is read as one, and the
/// reason says to write the test plainly. That costs a rewrite of an odd-looking test; it never lets a line through
/// that the reading before refused (RefusedGitMonotonicTests holds it to that, against a copy of it).
///
/// Not seen here, and so open, because the guard reads the Bash lines a session types: script files, other
/// interpreters and remote shells are outside it. That is a file a shell runs or sources (`bash x.sh`, `bash -x x.sh`,
/// `source x`, which is how every script runs, whatever is in it); another language's interpreter, a remote shell, or
/// a program or launcher not listed that runs a command (`python3 -c`, `perl -e`, `osascript`, `ssh`, `tmux`); input a
/// shell takes from further off, a reader nested in what's given it (`… | { true; bash dev/stdin; }`, `zsh -c '.
/// /dev/stdin' <<< …`); text handed to another interpreter (`sh -c`, `eval`, zsh's `*(e:…:)`) that names neither git
/// nor security, which is read only for naming them (`sh -c 'a=gi; ${a}t push'`, `eval $'\x67it push'`, base64); an
/// argument after git's command that the shell makes (`git checkout $b`: a rule reads it as written); a variable set
/// another way (`read GIT_DIR` after `set -a`, a file sourced; `HOME` or `XDG_CONFIG_HOME` set on its own or exported,
/// which every program reads, before a git); a function or alias defined in a file the shell reads; and a git alias the
/// user's config already has. A spelling found later is refused the same way, as unreadable, not listed here.
public enum RefusedGit {
    /// The refused options. `--config-env` is `-c` with its value read from an environment variable.
    public static let options = ["-C", "-c", "--git-dir", "--work-tree", "--exec-path", "--config-env"]

    /// The global options that take the next word as their value when it isn't joined with `=` (`git --namespace n`),
    /// from `git -h` (2.54) and git.c; `--exec-path` alone prints the path and takes none.
    static let valued: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix",
                                      "--attr-source", "--shallow-file"]

    /// The rules as they were, by name: the spaced spelling (`Bash(git -C:*)`).
    static let rules: [String] = options.map { "Bash(git \($0):*)" }

    /// The other spellings, where a rule can name them: `=` after a long option, and anything attached to a short one
    /// (`Bash(git -C*)` takes `git -C/x` and `git -C x` alike). Only at the line's start: the hook finds the rest.
    static let spellingRules: [String] = options.map { $0.hasPrefix("--") ? "Bash(git \($0)=*)" : "Bash(git \($0)*)" }

    /// git's environment variables that do what the refused options do: pick the repository (`GIT_DIR`, and
    /// `GIT_COMMON_DIR`, where a worktree's refs and config are), the work tree, git's programs, or its config
    /// (`GIT_CONFIG_PARAMETERS` is how `-c` reaches the programs git runs; `GIT_CONFIG_COUNT`/`_KEY_<n>`/`_VALUE_<n>`
    /// are `-c` again; `GIT_CONFIG`, `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` name another file): every `GIT_CONFIG_*`.
    /// `GIT_INDEX_FILE` names another index, so a commit there writes a tree no rule on the worktree's saw.
    public static let variables: Set<String> = ["GIT_DIR", "GIT_WORK_TREE", "GIT_EXEC_PATH", "GIT_COMMON_DIR", "GIT_CONFIG",
                                                "GIT_CONFIG_PARAMETERS", "GIT_INDEX_FILE"]

    /// Variables that pick git's global config file (`$HOME/.gitconfig`, `$XDG_CONFIG_HOME/git/config`), and with it
    /// any alias: refused only when set for a git (before it, or through `env`), since everything else reads them too.
    static let configHomes: Set<String> = ["HOME", "XDG_CONFIG_HOME"]

    static func isRefused(variable name: String) -> Bool { variables.contains(name) || starts(name, with: "GIT_CONFIG_") }

    /// `hasPrefix` a byte at a time: a combining mark after the prefix (`-C\u{301}`, `push \u{301}x`) joins its last
    /// `Character`, so `hasPrefix` says no where the shell and git see the same bytes as ever.
    static func starts(_ text: String, with prefix: String) -> Bool { text.utf8.starts(with: prefix.utf8) }

    /// Why a line is refused: a git it runs takes a refused option (as written), runs a command the role's rules
    /// refuse (the rule), a refused variable is set for it (its name), or what git it runs can't be read (`Unread`).
    public enum Refusal: Equatable {
        case option(String)
        case command(String)
        case variable(String)
        /// The `security` command-line tool, which reaches your Keychains (`keychainTool`).
        case keychain
        case unreadable(Unread)

        /// Why a line's git can't be read. Refused, not guessed at (decision 2026-10-25 16:33: hardening fails closed):
        /// the same git run plainly is read, so a refusal costs a rewrite and nothing else.
        public enum Unread: Equatable {
            /// Nested deeper than `ShellWords.depthLimit`, or more work to read than its length warrants.
            case tangled
            /// Text that names git, or text that isn't on the line where it does, handed to another interpreter
            /// (its name: `sh`, `eval`, `env -S`, `source`).
            case handed(String)
            /// A git whose option or command word (as written) the shell makes from an expansion.
            case expanded(String)
            /// A program whose own name (as written) the shell makes from an expansion, on a line that names git; or,
            /// on any line (`built`), from a pattern, a variable or a substitution in its last name, an expansion not
            /// quoted anywhere in it, or what xargs or find put there.
            case program(String)
            /// The same, on a line whose `[[ … ]]` test or `case` arm isn't written plainly, so each word that could be
            /// a program was read as one (`ShellWords.scan`).
            case test(String)
            /// A launcher that runs the command it's given in a way this doesn't read (its name: `script`, `setsid`).
            case launcher(String)
        }

        /// The hook's reason, as the session reads it.
        public var reason: String {
            switch self {
            case .option(let option):
                "VibeSwitcher refuses git's \(option) to every role, in every spelling: it points git at another repository, "
                    + "work tree, config or programs. Run git in your own worktree without it."
            case .command(let rule):
                "VibeSwitcher refuses \(rule) to this role, with git's global options before the command too (`git -P …`, "
                    + "`git --no-pager …`): its deny rules do. It isn't this role's to run."
            case .variable(let name):
                "VibeSwitcher refuses setting \(name)\(configHomes.contains(name) ? " for git" : "") to every role: it points git at another repository, work tree, config "
                    + "or programs, as git's -C, -c and --git-dir do. Run git in your own worktree without it."
            case .keychain:
                "VibeSwitcher refuses the `security` command to every session it starts: it reaches your Keychains, where "
                    + "VibeSwitcher keeps its keys, and on 2026-11-26 probing them crashed the Mac's keychain daemon and locked "
                    + "your login keychain. Keychain checks are done only in a keyboard session with the user: ask your lead."
            case .unreadable(.tangled):
                "VibeSwitcher refuses a command nested more than \(ShellWords.depthLimit) levels deep (subshells, substitutions) "
                    + "or too tangled to read: it can't check what git it runs. Write it flatter."
            case .unreadable(.handed(let interpreter)):
                "VibeSwitcher refuses a line that hands text naming git or security to \(interpreter), which runs it as commands of "
                    + "its own (as `sh -c '…'`, `eval`, `env -S`, `trap`, `watch` and a shell or `source` reading its input do): it "
                    + "can't check what that runs. Run the git command plainly, on a line of its own, without the wrapper."
            case .unreadable(.expanded(let word)):
                "VibeSwitcher refuses git with `\(Self.short(word))` where its options or its command go: the shell makes that "
                    + "word from an expansion (a variable, a substitution, braces or a pattern), so it can't check what git "
                    + "runs. Run the git command plainly, its options and command written out, without the variable."
            case .unreadable(.program(let word)):
                "VibeSwitcher refuses a command whose name the shell makes (`\(Self.short(word))`): a pattern, a variable or a "
                    + "substitution there (or what xargs or find put there) can make it git or security, which it can't check. "
                    + "Write the program's name out. In a path, put the variable in double quotes and write the last name out "
                    + "(\"$ROOT/scripts/x.sh\"); in a loop, name the program or pass the variable to one (bash \"$f\")."
            case .unreadable(.test(let word)):
                "VibeSwitcher refuses a command whose name the shell makes (`\(Self.short(word))`): this line has a `[[ … ]]` "
                    + "test or a `case` pattern that isn't written plainly, so each word that could be a command is read as one. "
                    + "Write the program's name out, or write the test plainly: `[[` first in the command (after if, while, "
                    + "until, !, then or do only), `]]` a word of its own after a space, all on one line, with no ( … ) "
                    + "grouping and no `case` on the same line; a case pattern as words joined by | before its )."
            case .unreadable(.launcher(let name)):
                "VibeSwitcher refuses `\(name)`: it runs the command after it in a way this guard doesn't read, so it can't "
                    + "check whether that's git or security. Run the command without it."
            }
        }

        /// A word for a reason's text: its start, when it's long.
        static func short(_ word: String) -> String { word.count > 40 ? word.prefix(40) + "…" : word }
    }

    /// The refusal a git in `line` would run with, or nil when none does. `rules`: the role's deny rules that run git
    /// (`LeadLaunch.gitRules`).
    public static func refusal(in line: String, rules: [String] = []) -> Refusal? {
        guard let scan = ShellWords.scan(line) else { return .unreadable(.tangled) }
        let commands = scan.commands
        // As `ShellWords.Scanner.lookahead`: what reading the commands may cost, a word at a time (`find -exec` reads
        // each command after it, and each `find` there its own, so `find . -exec find . -exec …` costs 2^n unbounded:
        // a hook that times out lets the call through). Past it, the line is refused, not read.
        // Each git's command is tried against the rules that name it, and those tries are charged too: a line of many
        // short gits (`git a;` over and over, 1 MB) otherwise read every rule for each, near the hook's timeout.
        var budget = 64 * line.unicodeScalars.count + 100_000
        let rules = Rules(rules)
        let named = names(line)
        if named, evaluatesValue(line) { return .unreadable(.handed("zsh's (e) flag")) }
        for command in commands {
            if let refusal = refusal(command: command, rules: rules, named: named, budget: &budget) { return refusal }
        }
        // Then, on any line, a program whose name the shell makes, or a launcher this doesn't read: after everything
        // above, which reads the line as it did before (RefusedGitMonotonicTests: nothing it refused is let through).
        if scan.tangled { return .unreadable(.tangled) }
        for command in commands {
            if let refusal = built(command, odd: scan.odd, budget: &budget) { return refusal }
        }
        return nil
    }

    /// The programs a line is read closely for: git, and `security` (`keychainTool`), whose text handed to another
    /// interpreter, or whose name made by the shell, is refused as git's is.
    static let named = ["git", keychainTool]

    /// The `security` command-line tool (/usr/bin/security), refused to every role whatever its arguments, by its
    /// name in any folder and behind every wrapper `refusal(command:)` reads (`env`, `command`, `xcrun`, `sudo`, …):
    /// it reaches your Keychains, where the app's and the vault's keys are, and another program of your account can
    /// replace them with it (2026-11-26, a measurement on scratch keychains, which also crashed securityd and locked
    /// the login keychain). Not seen, as for git: a script file a shell runs (scripts/build-app.sh runs it, in your own
    /// shell), another language's interpreter, or a program that calls the Security framework itself.
    public static let keychainTool = "security"

    /// Whether `text` names git or `security` (`named`): the word without its case, between characters that aren't
    /// ASCII letters or digits (`/usr/bin/git`, `GIT_DIR`, `.git`; not `github`, `digit`, `RefusedGit`, `SecurityAudit`),
    /// read as a shell would read it again: quotes, backslashes and a backslash's line break taken out (`g""it`, `g\it`).
    static func names(_ text: String) -> Bool {
        var bytes: [UInt8] = []
        var skipBreak = false
        for byte in folded(text).utf8 {
            defer { skipBreak = byte == UInt8(ascii: "\\") }
            if byte == UInt8(ascii: "'") || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") { continue }
            if skipBreak, byte == UInt8(ascii: "\n") { continue }
            bytes.append(byte)
        }
        func wordByte(_ byte: UInt8) -> Bool {
            (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
        }
        for name in named {
            let word = Array(name.utf8)
            var at = 0
            while at + word.count <= bytes.count {
                if bytes[at..<(at + word.count)].elementsEqual(word),
                   at == 0 || !wordByte(bytes[at - 1]), at + word.count == bytes.count || !wordByte(bytes[at + word.count]) {
                    return true
                }
                at += 1
            }
        }
        return false
    }

    /// A role's git rules, read once a line: each by the git command it names (`push` for `Bash(git push:*)`), and
    /// those whose command has a `*` in it (`Bash(git * --output*)`) tried for every git.
    struct Rules {
        struct Rule {
            /// The rule as its brief names it (`git push:*`), for the refusal's reason.
            let text: String
            /// `X:*`: `X` alone or followed by a space.
            let prefix: Bool
            /// The pattern split at its `*`s (the whole pattern for a prefix rule), as bytes (`starts(_:with:)`).
            let pieces: [[UInt8]]
        }
        var byCommand: [String: [Rule]] = [:]
        var anyCommand: [Rule] = []

        init(_ rules: [String]) {
            for rule in rules where rule.hasPrefix("Bash(git ") && rule.hasSuffix(")") {
                let text = String(rule.dropFirst("Bash(".count).dropLast())
                let prefix = text.hasSuffix(":*")
                var pattern = prefix ? String(text.dropLast(2)) : text
                // Its command's name without its case, as `refusal(command:)` reads a git's.
                let name = RefusedGit.command(of: Array(pattern.utf8))
                pattern = "git " + RefusedGit.folded(name) + pattern.dropFirst("git ".count + name.count)
                let pieces = prefix ? [pattern] : pattern.components(separatedBy: "*")
                let parsed = Rule(text: text, prefix: prefix, pieces: pieces.map { Array($0.utf8) })
                let command = RefusedGit.command(of: Array(pattern.utf8))
                if command.isEmpty || command.contains("*") {
                    anyCommand.append(parsed)
                } else {
                    byCommand[command, default: []].append(parsed)
                }
            }
        }

        /// The rules a git with this command (`push`) could match.
        func candidates(_ command: String) -> [Rule] { (byCommand[command] ?? []) + anyCommand }
    }

    /// The git command a `git …` text (its bytes) runs: its second word.
    static func command(of text: [UInt8]) -> String {
        String(decoding: text.dropFirst("git ".utf8.count).prefix { $0 != UInt8(ascii: " ") }, as: UTF8.self)
    }

    /// Whether `command` (`git` and its words after git's options) matches `rule` as Claude Code reads one: `X:*` is
    /// `X` alone or followed by a space, a `*` elsewhere any text (none included: the hook only refuses, so it takes
    /// the wider reading), and no `*` the whole command. In time linear in the command's length.
    /// Compared a byte at a time (`starts(_:with:)`).
    static func matches(_ rule: Rules.Rule, _ command: [UInt8]) -> Bool {
        let pieces = rule.pieces
        let space = UInt8(ascii: " ")
        if rule.prefix {
            return command == pieces[0] || (command.starts(with: pieces[0]) && command.count > pieces[0].count && command[pieces[0].count] == space)
        }
        guard pieces.count > 1 else { return command == pieces[0] }
        if pieces.count == 2, pieces[1].isEmpty, pieces[0].last == space, command[...] == pieces[0].dropLast() { return true }
        guard let first = pieces.first, let last = pieces.last, command.starts(with: first) else { return false }
        var at = first.count
        for piece in pieces.dropFirst().dropLast() where !piece.isEmpty {
            // The first place it starts at or after `at`: each piece is a few bytes, so this stays linear in practice.
            var found: Int?
            var from = at
            while from + piece.count <= command.count {
                if command[from..<(from + piece.count)].elementsEqual(piece) {
                    found = from
                    break
                }
                from += 1
            }
            guard let found else { return false }
            at = found + piece.count
        }
        guard command.count - last.count >= at else { return false }
        return command[(command.count - last.count)...].elementsEqual(last)
    }

    /// Words that come before the program a command runs, with no effect on which it is (`time` is a wrapper, for its `-p`).
    /// A program's name as this Mac's volume finds it: without its case (`GIT`, `/usr/bin/Find`, `xargſ` all run the
    /// lowercase program), as APFS folds names.
    static func folded(_ name: String) -> String { name.folding(options: [.caseInsensitive], locale: nil) }

    static let keywords: Set<String> = ["!", "{", "}", "(", ")", "if", "then", "else", "elif", "fi", "do", "done", "while", "until",
                                        "coproc", "always"]
    /// Programs that run the command after them: their options that take a value (`env -u NAME git …`), and the
    /// operands before the command (`timeout 60 git …`).
    struct Wrapper {
        var valued: Set<String> = []
        var operands = 0
    }
    static let wrappers: [String: Wrapper] = {
        let timeout = Wrapper(valued: ["-s", "--signal", "-k", "--kill-after"], operands: 1)
        return ["env": Wrapper(valued: ["-u", "-P", "-S", "-C"]), "command": Wrapper(), "builtin": Wrapper(), "exec": Wrapper(valued: ["-a"]),
                "nohup": Wrapper(), "nice": Wrapper(valued: ["-n"]), "xcrun": Wrapper(valued: ["--sdk", "--toolchain", "-sdk"]),
                "sudo": Wrapper(valued: ["-u", "-g"]), "caffeinate": Wrapper(valued: ["-t", "-w"]), "time": Wrapper(valued: ["-o"]),
                "xargs": Wrapper(valued: ["-I", "-J", "-L", "-n", "-P", "-E", "-s", "-R", "-S"]),
                "timeout": timeout, "gtimeout": timeout, "arch": Wrapper(valued: ["-arch", "-d", "-e"]),
                "stdbuf": Wrapper(valued: ["-i", "-o", "-e"]), "gstdbuf": Wrapper(valued: ["-i", "-o", "-e"]),
                "vs-heavy": Wrapper(valued: ["--as", "--timeout", "--stall"]),
                // zsh's precommand modifiers, and its `repeat N git …`.
                "noglob": Wrapper(), "nocorrect": Wrapper(), "-": Wrapper(), "repeat": Wrapper(operands: 1)]
    }()

    /// Programs that run a command they're given in a way `wrappers` doesn't read (a typescript, a new session, another
    /// root, a sandbox profile, a lock, another user): refused whatever they run, since what that is isn't checked.
    /// One not listed here isn't seen (the header's "Not seen").
    static let launchers: Set<String> = ["script", "setsid", "chroot", "sandbox-exec", "taskpolicy", "unbuffer", "su", "doas",
                                         "runuser", "pkexec", "flock", "chrt", "ionice", "daemonize", "unshare", "nsenter",
                                         "setpriv", "systemd-run", "firejail"]

    /// Why a command is refused for its program, on any line (the audit of keychain-keys-the-stated, F3): a name the
    /// shell makes, so it can't tell what runs, or a launcher it doesn't read. Its program is found as `refusal(command:)`
    /// finds it (after variables set, keywords, `[[ … ]]`, the wrappers it reads, find's `-exec`), skipping the words
    /// that are never one (`ShellWords.Kind`: a plain test's operands, a `case` arm's pattern, a glob group). An
    /// array's words aren't run. `odd`: the line has a test or an arm that isn't plain (the reason says so);
    /// `filled`: the text xargs or find puts in a command's words (`{}`, `-I %`); `appends`: xargs adds its input's.
    static func built(_ command: ShellWords.Command, odd: Bool, budget: inout Int, depth: Int = 0, filled: [String] = [],
                      appends: Bool = false) -> Refusal? {
        guard depth <= ShellWords.depthLimit else { return .unreadable(.tangled) }
        let words = command.words
        // What follows a test's `]]` or zsh's `always` is a command too, as `refusal(command:)` reads it.
        if let close = words.firstIndex(where: { $0 == "]]" || $0 == "always" }),
           let refusal = built(command.from(close + 1), odd: odd, budget: &budget, depth: depth + 1, filled: filled, appends: appends) {
            return refusal
        }
        var filled = filled
        var appends = appends
        var wrapped = false
        var index = 0
        while index < words.count {
            budget -= 1
            guard budget >= 0 else { return .unreadable(.tangled) }
            let word = words[index]
            if command.kinds[index] != .plain || assigned(word) != nil || keywords.contains(word) {
                index += 1
                continue
            }
            if word == "function" {
                index += 2
                continue
            }
            if word == "[[" {
                index += 1
                while index < words.count, words[index] != "]]" {
                    budget -= 1
                    guard budget >= 0 else { return .unreadable(.tangled) }
                    index += 1
                }
                index += 1
                continue
            }
            if starts(word, with: "(("), word.hasSuffix("))") {
                index += 1
                continue
            }
            // The program, or a wrapper before it: by its name as written, so a name the shell makes is refused first.
            let name = folded((word as NSString).lastPathComponent)
            if command.last[index].expanded || command.bare[index] || filled.contains(where: { !$0.isEmpty && word.contains($0) }) {
                return .unreadable(odd ? .test(word) : .program(word))
            }
            if launchers.contains(name) { return .unreadable(.launcher(name)) }
            guard let wrapper = wrappers[name] else { break }
            index += 1
            wrapped = appends
            while index < words.count, starts(words[index], with: "-") || ((name == "env" || name == "sudo") && assigned(words[index]) != nil) {
                budget -= 1
                guard budget >= 0 else { return .unreadable(.tangled) }
                let option = words[index]
                // `command -v x` (`-V`) says what `x` is, and runs nothing.
                if name == "command", option.dropFirst().contains(where: { $0 == "v" || $0 == "V" }) { return nil }
                // `env -S '…'`: its string is text handed over (`refusal(command:)`), not read here; the word after it
                // is env's program all the same (`env -S '' setsid ls`).
                if name == "env", let string = split(option) {
                    index += string.isEmpty ? 2 : 1
                    continue
                }
                if name == "xargs", wrapper.valued.contains(option) || starts(option, with: "-I") || starts(option, with: "-J") {
                    var values = wrapper.valued.contains(option) && index + 1 < words.count ? [words[index + 1]] : []
                    for valued in ["-I", "-J"] where option.utf8.count > 2 && starts(option, with: valued) {
                        values.append(String(decoding: option.utf8.dropFirst(2), as: UTF8.self))
                    }
                    if starts(option, with: "-I") || starts(option, with: "-J") { filled += values }
                }
                index += wrapper.valued.contains(option) ? 2 : 1
            }
            if name == "xargs" { appends = true }
            index += wrapper.operands
        }
        // No program after a wrapper behind xargs (`xargs env`, `xargs nohup`): xargs' input is the command.
        guard index < words.count else { return appends && wrapped ? .unreadable(odd ? .test("xargs") : .program("xargs")) : nil }
        let program = folded((words[index] as NSString).lastPathComponent)
        guard program == "find" || program == "gfind" else { return nil }
        // `find … -exec x … \;`: each command find runs, read to BSD's end and to GNU's, as `refusal(command:)` does.
        var at = index + 1
        while at < words.count {
            budget -= 1
            guard budget >= 0 else { return .unreadable(.tangled) }
            guard ["-exec", "-execdir", "-ok", "-okdir"].contains(words[at]) else {
                at += 1
                continue
            }
            func ends(_ end: Int, exactly: Bool) -> Bool {
                let word = words[end]
                let plus = words[end - 1] == "{}"
                return exactly ? word == ";" || (plus && word == "+") : starts(word, with: ";") || (plus && starts(word, with: "+"))
            }
            var end = at + 1
            while end < words.count, !ends(end, exactly: false) { end += 1 }
            var gnuEnd = end
            while gnuEnd < words.count, !ends(gnuEnd, exactly: true) { gnuEnd += 1 }
            budget -= gnuEnd - at
            guard budget >= 0 else { return .unreadable(.tangled) }
            for last in gnuEnd == end ? [end] : [end, gnuEnd] {
                if let refusal = built(command[(at + 1)..<last], odd: odd, budget: &budget, depth: depth + 1, filled: filled + ["{}"]) {
                    return refusal
                }
            }
            at = end + 1
        }
        return nil
    }

    /// The builtins that export (or declare) the variables named after them, `NAME=value` or `NAME`.
    static let exporters: Set<String> = ["export", "declare", "typeset", "readonly", "local"]

    /// Why one simple command (its words, quotes taken off) is refused, if it is: a refused variable set for it or
    /// exported, a git it runs with a refused option or command, or a git that can't be read (text handed to another
    /// interpreter, an expansion where git's options and command go). `named`: whether the line names git anywhere
    /// (`names`); `budget`: what reading it may still cost; `depth`:
    /// how many `find -exec` it's in (past `ShellWords.depthLimit`, refused as the scanner refuses a line nested deeper);
    /// `home`: a `configHomes` variable the `find` running it was given, which a git it runs takes too; `filled`: the
    /// text the program running it replaces in its words (find's `{}`).
    static func refusal(command: ShellWords.Command, rules: Rules, named: Bool, budget: inout Int, depth: Int = 0,
                        home: String? = nil, filled: [String] = []) -> Refusal? {
        guard depth <= ShellWords.depthLimit else { return .unreadable(.tangled) }
        let words = command.words
        // zsh's glob qualifiers and groups (`*(e:'…':)`, `*(+f)` run code): their text, read as text handed over.
        if command.group, let refusal = handed(words, to: "a zsh glob qualifier", reads: false, named: named, budget: &budget) {
            return refusal
        }
        // A short form's test the scanner split (`if [[ -n a && -n b ]] git …`, `=~ (a|b) ]] git …`), or zsh's
        // `{ … } always { … }`: what follows its `]]` or `always` is read as a command too.
        if let close = words.firstIndex(where: { $0 == "]]" || $0 == "always" }),
           let refusal = refusal(command: command.from(close + 1), rules: rules, named: named, budget: &budget, depth: depth + 1,
                                 home: home, filled: filled) {
            return refusal
        }
        var home = home
        // What xargs puts in the command it runs: its `-I`/`-J` text wherever a word has it, or else its input's
        // words after the command's last.
        var filled = filled
        var appends = false
        // xargs' input is the whole command of a wrapper after it (`xargs env`), not just words after a command.
        var wrapped = false
        var index = 0
        while index < words.count {
            budget -= 1
            guard budget >= 0 else { return .unreadable(.tangled) }
            let word = words[index]
            let name = folded((word as NSString).lastPathComponent)
            if let variable = assigned(word) {
                if isRefused(variable: variable) { return .variable(variable) }
                if configHomes.contains(variable) { home = home ?? variable }
                index += 1
            } else if keywords.contains(word) {
                index += 1
            } else if word == "function" {
                // `function f { git …; }`: the keyword, then the function's name.
                index += 2
            } else if word == "[[" {
                // zsh's short forms, `if [[ … ]] git …` (and `while`, `until`): the test, then the command it runs.
                index += 1
                while index < words.count, words[index] != "]]" {
                    budget -= 1
                    guard budget >= 0 else { return .unreadable(.tangled) }
                    index += 1
                }
                index += 1
            } else if starts(word, with: "(("), word.hasSuffix("))") {
                // The same with an arithmetic test, `if (( 1 )) git …`: the scanner gives `((…))` as one word.
                index += 1
            } else if let wrapper = wrappers[name] {
                index += 1
                wrapped = appends
                // `env NAME=value git …` (and sudo's), each variable checked as one set before the command, and an
                // option's value that sets one (`arch -arm64 -e GIT_DIR=x git …`, or attached, `-eGIT_DIR=x`).
                while index < words.count, starts(words[index], with: "-") || ((name == "env" || name == "sudo") && assigned(words[index]) != nil) {
                    budget -= 1
                    guard budget >= 0 else { return .unreadable(.tangled) }
                    let option = words[index]
                    // `env -S 'git …'` splits its string into the command it runs: text handed over, as `sh -c` is.
                    if name == "env", let string = split(option) {
                        var text = command.from(index)
                        text.words[0] = string
                        guard let fills = fills(text.words, appends: appends, filled, named: named, budget: &budget) else { return .unreadable(.tangled) }
                        if let refusal = unread(by: "env -S", text, reads: fills, named: named, budget: &budget) { return refusal }
                    }
                    var values = [option]
                    if wrapper.valued.contains(option), index + 1 < words.count { values.append(words[index + 1]) }
                    for valued in wrapper.valued where option.utf8.count > valued.utf8.count && starts(option, with: valued) {
                        values.append(String(decoding: option.utf8.dropFirst(valued.utf8.count), as: UTF8.self))
                    }
                    for value in values {
                        guard let variable = assigned(value) else { continue }
                        if isRefused(variable: variable) { return .variable(variable) }
                        if configHomes.contains(variable) { home = home ?? variable }
                    }
                    if name == "xargs", starts(option, with: "-I") || starts(option, with: "-J") {
                        filled += values.dropFirst().filter { !$0.isEmpty }
                    }
                    index += wrapper.valued.contains(option) ? 2 : 1
                }
                if name == "xargs" { appends = true }
                index += wrapper.operands
            } else {
                break
            }
        }
        guard index < words.count else { return appends && wrapped && named ? .unreadable(.expanded("xargs")) : nil }
        let program = folded((words[index] as NSString).lastPathComponent)
        // `security`, by its name in any folder, behind any wrapper above: whatever it's asked.
        if program == keychainTool { return .keychain }
        if exporters.contains(program) {
            // `export GIT_DIR=x`, `declare -x GIT_DIR`: refused whatever runs after it on the line.
            for word in words.dropFirst(index + 1) {
                budget -= 1
                guard budget >= 0 else { return .unreadable(.tangled) }
                let variable = assigned(word) ?? word
                if isRefused(variable: variable) { return .variable(variable) }
            }
            return nil
        }
        if program == "find" || program == "gfind" {
            // `find … -exec git … \;`: each command find runs, up to its `;` (or `{} +`), and find's words after it.
            // This Mac's find (BSD) ends the command at any word that starts with `;`, or with `+` after `{}` (`\;x`,
            // `{} +x`), and reads on from there; GNU find only at `;` or `+` exactly, so its command runs on past BSD's
            // end: both are read, and find's words from BSD's end on.
            var at = index + 1
            while at < words.count {
                budget -= 1
                guard budget >= 0 else { return .unreadable(.tangled) }
                guard ["-exec", "-execdir", "-ok", "-okdir"].contains(words[at]) else {
                    at += 1
                    continue
                }
                func ends(_ end: Int, exactly: Bool) -> Bool {
                    let word = words[end]
                    let plus = words[end - 1] == "{}"
                    return exactly ? word == ";" || (plus && word == "+") : starts(word, with: ";") || (plus && starts(word, with: "+"))
                }
                var end = at + 1
                while end < words.count, !ends(end, exactly: false) { end += 1 }
                var gnuEnd = end
                while gnuEnd < words.count, !ends(gnuEnd, exactly: true) { gnuEnd += 1 }
                budget -= gnuEnd - at
                guard budget >= 0 else { return .unreadable(.tangled) }
                for last in gnuEnd == end ? [end] : [end, gnuEnd] {
                    if let refusal = refusal(command: command[(at + 1)..<last], rules: rules, named: named, budget: &budget,
                                             depth: depth + 1, home: home, filled: filled + ["{}"]) {
                        return refusal
                    }
                }
                at = end + 1
            }
            return nil
        }
        if let refusal = handed(to: program, command.from(index + 1), appends: appends, filled: filled, named: named, budget: &budget) {
            return refusal
        }
        // git's own programs by their name, in any folder (`git-push`, `…/libexec/git-core/git-push`): git's command, with
        // no global options before it.
        let dashed = starts(program, with: "git-") && program.utf8.count > "git-".utf8.count
        guard program == "git" || dashed else {
            // The program's own name made by the shell (`g=git; $g push`, zsh's `=git push`, `$(echo git) push`,
            // `command {git,push}`) on a line that names git: it may be git. A path built on a substitution
            // (`"$(git rev-parse --show-toplevel)/scripts/x.sh"`) is an everyday form, and the command inside it is
            // read on its own. An array's words aren't run (`files=($(git ls-files))`).
            let how = command.made[index]
            let made = how.contains(.variable) || how == .substitution
                || (how.contains(.pattern) && (starts(words[index], with: "=") || words[index].contains("{")))
            return named && made && !command.array ? .unreadable(.program(words[index])) : nil
        }
        if let home { return .variable(home) }
        // git's own options, up to its command: the first word that isn't one. Each as written: one the shell makes
        // from an expansion (`git $x …`, `git ${o:--C} x`, `git {push,x}`, an option's value too) can't be read, nor
        // one the program running git fills in (`xargs -I% git % x`, `find -exec git {} \;`).
        func unseen(_ at: Int) -> Refusal? {
            if command.made[at].expanded { return .unreadable(.expanded(words[at])) }
            guard let fills = fills([words[at]], appends: false, filled, named: true, budget: &budget) else { return .unreadable(.tangled) }
            return fills ? .unreadable(.expanded(words[at])) : nil
        }
        if dashed {
            if let refusal = unseen(index) { return refusal }
            return ruled(["git", String(program.dropFirst("git-".count))] + words[(index + 1)...], rules: rules, budget: &budget)
        }
        index += 1
        while index < words.count {
            budget -= 1
            guard budget >= 0 else { return .unreadable(.tangled) }
            let word = words[index]
            let option = starts(word, with: "-") && word != "-" && word != "--"
            if option, options.contains(where: { starts(word, with: $0) }) { return .option(word) }
            if let refusal = unseen(index) { return refusal }
            guard option else { break }
            if valued.contains(word), index + 1 < words.count, let refusal = unseen(index + 1) { return refusal }
            index += valued.contains(word) ? 2 : 1
        }
        // No command on the line: xargs' input is the command (`echo push | xargs git`).
        if index >= words.count, appends { return .unreadable(.expanded("xargs")) }
        guard index < words.count else { return nil }
        // Its command, without the options before it, as the rules name it: `git -P push x` is `git push x`. The
        // command's name without its case, as the rules are read: this Mac's volume finds `git-Filter-Branch` (a script
        // git runs), and a builtin in another case (`git PUSH`) fails anyway. Its options keep theirs (`-c` isn't `-C`).
        return ruled(["git", folded(words[index])] + words[(index + 1)...], rules: rules, budget: &budget)
    }

    /// The rule `words` (`git`, its command, the command's words) matches, as a refusal; nil when none does.
    static func ruled(_ words: [String], rules: Rules, budget: inout Int) -> Refusal? {
        let command = Array(words.joined(separator: " ").utf8)
        let candidates = rules.candidates(Self.command(of: command))
        budget -= command.count + candidates.count
        guard budget >= 0 else { return .unreadable(.tangled) }
        return candidates.first { matches($0, command) }.map { .command($0.text) }
    }

    /// The shells, which run a `-c` string, their input, or a file as commands.
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish"]
    /// The builtins that run a file (or their input) in this shell.
    static let sourcers: Set<String> = ["source", "."]
    /// What runs its words as a shell line: now (`eval`), on a signal (`trap`), or over and over (`watch`); or makes a
    /// name that runs them later (`alias g='git -C x'`, `hash -p /usr/bin/git g`, then `g`).
    static let evaluators: Set<String> = ["eval", "trap", "watch", "alias", "hash"]

    /// Why a command that hands text to another interpreter is refused, if it is: `program` (its name, without its
    /// case) run with `arguments`, behind an xargs that `appends` its input's words or a program that replaces
    /// `filled` in them. A shell or `source` given a file by a plain path isn't read here: the file isn't on the line.
    static func handed(to program: String, _ arguments: ShellWords.Command, appends: Bool, filled: [String], named: Bool,
                       budget: inout Int) -> Refusal? {
        guard evaluators.contains(program) || shells.contains(program) || sourcers.contains(program) else { return nil }
        // Words of its text that xargs or find put in aren't on the line.
        guard let fills = fills(arguments.words, appends: appends, filled, named: named, budget: &budget) else { return .unreadable(.tangled) }
        if evaluators.contains(program) { return unread(by: program, arguments, reads: fills, named: named, budget: &budget) }
        guard !arguments.words.isEmpty else {
            // A shell alone reads its input; `source` alone runs nothing.
            return shells.contains(program) && named ? .unreadable(.handed(program)) : nil
        }
        // A script's path, as written (`bash scripts/test.sh --filter X`, `bash -x scripts/x.sh`): the file isn't on the
        // line. Given input on a line that names git, the path may be that input by another name (`//dev/stdin`).
        if script(program, arguments) {
            return arguments.input && named ? .unreadable(.handed(program)) : nil
        }
        // Without a `-c`, a shell reads its commands from its input: a here-string, a here-document, a pipe.
        let string = shells.contains(program) && takesString(arguments.words)
        return unread(by: program, arguments, reads: !string || fills, named: named, budget: &budget)
    }

    /// The shells whose options `script` reads: these take a command string only with `-c`, read their input with `-s`
    /// (or with no file), and take a value only after `-o`/`-O` (`+o` too).
    static let posixShells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]
    /// Their flags that take no value and run nothing else (`-x`, `-e`, `-n`, `-l`, `-f`): `set`'s, and the login,
    /// interactive and restricted ones. Any other letter is read as text handed over (a wider reading only refuses more).
    static let scriptFlags = Set("abefhiklmnprtuvxBCEHP".utf8)
    static let scriptLongOptions: Set<String> = ["--login", "--noprofile", "--norc", "--posix", "--restricted", "--verbose",
                                                 "--noediting"]

    /// Whether a shell or `source` runs a script from a path as written (`bash scripts/test.sh`, `bash -x scripts/x.sh`,
    /// `bash -euo pipefail scripts/x.sh`): after `posixShells`' flags only, the first operand, not `/dev/…` (its input),
    /// not one the shell makes (`<(…)`, `$f`). Not with a `-c` or `-s`, or an option it doesn't know.
    static func script(_ program: String, _ arguments: ShellWords.Command) -> Bool {
        let words = arguments.words
        var index = 0
        if posixShells.contains(program) {
            while index < words.count, arguments.made[index] == .text, starts(words[index], with: "-") || starts(words[index], with: "+") {
                let word = words[index]
                if word == "--" || word == "-" {
                    index += 1
                    break
                }
                if scriptLongOptions.contains(word) {
                    index += 1
                    continue
                }
                let letters = Array(word.utf8.dropFirst())
                let valued = { (letter: UInt8) in letter == UInt8(ascii: "o") || letter == UInt8(ascii: "O") }
                guard let last = letters.last, letters.allSatisfy({ scriptFlags.contains($0) || valued($0) }),
                      !letters.dropLast().contains(where: valued) else { return false }
                guard valued(last) else {
                    index += 1
                    continue
                }
                guard index + 1 < words.count, arguments.made[index + 1] == .text else { return false }
                index += 2
            }
        }
        guard index < words.count, arguments.made[index] == .text else { return false }
        let path = words[index]
        return !starts(path, with: "-") && !starts(path, with: "+") && !starts(folded(path), with: "/dev/")
    }

    /// Whether a shell's options have a `-c` (alone or in a cluster, `-lc`; fish's `--command`): only its own options,
    /// before `--` or its first operand (`bash -s -- -c` reads its input). An option's value isn't an operand (`-o
    /// pipefail`, `--rcfile x`).
    static func takesString(_ arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            guard word != "--", starts(word, with: "-") || starts(word, with: "+") else { return false }
            if starts(word, with: "--") {
                if starts(word, with: "--command") { return true }
                index += ["--rcfile", "--init-file"].contains(word) ? 2 : 1
            } else {
                if starts(word, with: "-"), word.utf8.contains(UInt8(ascii: "c")) { return true }
                index += word.utf8.last == UInt8(ascii: "o") || word.utf8.last == UInt8(ascii: "O") ? 2 : 1
            }
        }
        return false
    }

    /// Whether the program running a command puts text of its own in `words`: xargs' input after them (`appends`), or
    /// in place of `filled` where a word has it (xargs' `-I`, find's `{}`). Asked only on a line that names git; nil
    /// when looking costs more than `budget` has left (many `-I`, long words).
    static func fills(_ words: [String], appends: Bool, _ filled: [String], named: Bool, budget: inout Int) -> Bool? {
        guard named, !appends, !filled.isEmpty else { return named && appends }
        let weight = filled.reduce(0) { $0 + $1.utf8.count }
        for word in words {
            budget -= word.utf8.count * weight + filled.count
            guard budget >= 0 else { return nil }
            if filled.contains(where: { word.contains($0) }) { return true }
        }
        return false
    }

    /// Text handed to `interpreter` in `arguments`: refused when it names git, and when it isn't all there to read
    /// (the shell makes a word of it from an expansion, the interpreter makes one, `x=git; eval '$x push'`, or `reads`:
    /// it comes through the interpreter's input) on a line that names git anywhere.
    static func unread(by interpreter: String, _ arguments: ShellWords.Command, reads: Bool, named: Bool, budget: inout Int) -> Refusal? {
        if named, arguments.made.contains(where: \.expanded) { return .unreadable(.handed(interpreter)) }
        return handed(arguments.words, to: interpreter, reads: reads, named: named, budget: &budget)
    }

    /// Text that `interpreter` reads again (`words`, as written): refused when it names git, or on a line that names
    /// git when it holds an expansion that interpreter makes (a `$` or a backtick) or `reads` its input too.
    static func handed(_ words: [String], to interpreter: String, reads: Bool, named: Bool, budget: inout Int) -> Refusal? {
        budget -= words.reduce(words.count) { $0 + $1.utf8.count }
        guard budget >= 0 else { return .unreadable(.tangled) }
        if names(words.joined(separator: " ")) { return .unreadable(.handed(interpreter)) }
        let expands = words.contains { $0.utf8.contains(UInt8(ascii: "$")) || $0.utf8.contains(UInt8(ascii: "`")) }
        return named && (reads || expands) ? .unreadable(.handed(interpreter)) : nil
    }

    /// zsh's `(e)` flag on a parameter (`${(e)x}`, `${(%e)x}`): it runs the substitutions in the value as commands.
    /// Flags longer than a parameter's ever are read as having it (and the line isn't read past them).
    static func evaluatesValue(_ line: String) -> Bool {
        var rest = Substring(line)
        while let open = rest.range(of: "${(") {
            rest = rest[open.upperBound...]
            let flags = rest.prefix(64).prefix { $0 != ")" }
            if flags.contains("e") || flags.count == 64 { return true }
        }
        return false
    }

    /// The string attached to env's `-S` (`--split-string`) when `option` is one, alone (then empty: the next word is
    /// the string), in a cluster (`-iS`) or with it (`-S'git …'`); nil for another option, `S` in the value attached
    /// to it included (`-uSSH_AUTH_SOCK`).
    static func split(_ option: String) -> String? {
        let long = "--split-string"
        if starts(option, with: "--") { return starts(option, with: long) ? String(decoding: option.utf8.dropFirst(long.utf8.count), as: UTF8.self) : nil }
        var rest = option.utf8.dropFirst()
        while let letter = rest.popFirst() {
            if letter == UInt8(ascii: "S") { return String(decoding: rest, as: UTF8.self) }
            if [UInt8(ascii: "u"), UInt8(ascii: "P"), UInt8(ascii: "C")].contains(letter) { return nil }
        }
        return nil
    }

    /// `NAME=value` (or `NAME+=value`, `NAME[i]=value`), a variable the shell sets: its name; nil for any other word.
    /// Read a byte at a time: `=` followed by a combining mark (`GIT_DIR=\u{301}x`) is one `Character`, but the shell's
    /// `=` all the same.
    static func assigned(_ word: String) -> String? {
        let bytes = Array(word.utf8)
        guard let equals = bytes.firstIndex(of: UInt8(ascii: "=")), equals > 0 else { return nil }
        var name = bytes[..<equals]
        if name.last == UInt8(ascii: "+") { name = name.dropLast() }
        if name.last == UInt8(ascii: "]"), let bracket = name.firstIndex(of: UInt8(ascii: "[")) { name = name[..<bracket] }
        func letter(_ byte: UInt8) -> Bool { byte == UInt8(ascii: "_") || (byte | 0x20 >= UInt8(ascii: "a") && byte | 0x20 <= UInt8(ascii: "z")) }
        guard let head = name.first, letter(head),
              name.allSatisfy({ letter($0) || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) }) else { return nil }
        return String(decoding: name, as: UTF8.self)
    }
}

/// The simple commands a shell line runs, each as its words with quotes and escapes taken off: split at `;`, `&`, `&&`,
/// `|`, `||` and newlines, with those in subshells, groups, `$(…)`, backticks, `<(…)`/`>(…)`, and inside `$((…))`,
/// `((…))`, `${…}` and unquoted here-document bodies (where the shell runs them) as commands of their own. Quoted
/// here-document bodies and comments are text, not commands, and a redirection's target isn't a word. Made for
/// finding what runs (`RefusedGit`), so it's lenient: a line the shell would reject still gives what it holds.
enum ShellWords {
    /// Deeper than this (subshells, substitutions, expansions in each other), a line isn't read: `commands` gives nil
    /// and the hook refuses it. Unbounded, a deep enough line would overflow the stack, and a hook that crashes says
    /// nothing, which lets the call through. 16 is far past any line a session writes, and small enough for a debug
    /// build on a 512 KB thread (64 overflowed one: about 4 KB a frame, two or three frames a level).
    static let depthLimit = 16

    /// How the shell makes a word: from the text as written, and from what it expands at run time, which isn't read.
    struct Made: OptionSet {
        let rawValue: UInt8
        /// Characters as written, quoted or not.
        static let text = Made(rawValue: 1)
        /// A parameter or arithmetic expansion (`$x`, `${x:-y}`, `$((…))`), or `$'…'` with an escape that isn't read.
        static let variable = Made(rawValue: 2)
        /// What a command prints (`$(…)`, backticks) or a process substitution's path (`<(…)`).
        static let substitution = Made(rawValue: 4)
        /// Braces (`{a,b}`), a file pattern (`*`, `?`, `[`) or zsh's leading `=` (`=git` is git's full path).
        static let pattern = Made(rawValue: 8)

        /// Whether the shell makes any of it: the word that runs isn't the word as written.
        var expanded: Bool { !isDisjoint(with: [.variable, .substitution, .pattern]) }
    }

    /// How the word being read is made: as a whole, in its last name (what follows its last `/` as written, the name
    /// of the program it runs), and whether an expansion in it isn't quoted (`$x`, `$(…)`, braces: the shell splits
    /// the value into words, or braces make several, so its first word can be anything).
    struct Shape: ExpressibleByArrayLiteral {
        var all: Made = []
        var last: Made = []
        var bare = false

        init(arrayLiteral elements: Made...) { elements.forEach { insert($0) } }

        mutating func insert(_ how: Made) {
            all.insert(how)
            last.insert(how)
        }

        /// A `/` as written: what follows is the last name.
        mutating func slash() { last = [] }
    }

    /// What a word is to `RefusedGit.built`, which reads each command's program: a word that may be one (`plain`), or
    /// one that never is: an operand of a plain `[[ … ]]` test, a word of a `case` arm's pattern, of zsh's glob group
    /// or qualifier written without spaces (`*(om[1])`, `^(a|b)$`), or an array's element in parentheses that hold
    /// no separator and are closed (`a=(x $y)`).
    enum Kind { case plain, operand, pattern, group, element }

    /// One simple command: its words, quotes and escapes taken off, and how each was made.
    struct Command {
        var words: [String] = []
        var made: [Made] = []
        /// How each word's last name is made (`Shape.last`), whether an expansion in it isn't quoted (`Shape.bare`), and
        /// what it is to `RefusedGit.built` (`Kind`).
        var last: [Made] = []
        var bare: [Bool] = []
        var kinds: [Kind] = []
        /// Its input is given on the line: a pipe into it, a here-string, a here-document, a `<` redirection.
        var input = false
        /// The words in an array's parentheses (`a=(x y)`): read as a command, though the shell runs none.
        var array = false
        /// The words in zsh's glob group or qualifier (`pus(h|x)`, `*(e:'…':)`): read as a command, and as text handed over.
        var group = false

        subscript(range: Range<Int>) -> Command {
            Command(words: Array(words[range]), made: Array(made[range]), last: Array(last[range]), bare: Array(bare[range]),
                    kinds: Array(kinds[range]), input: input, array: array, group: group)
        }
        /// The words from `index` on.
        func from(_ index: Int) -> Command { self[min(index, words.count)..<words.count] }
    }

    /// Words with a brace or a bracket that the shell doesn't expand: its own keywords and tests, and find's `{}`.
    static let unexpanded: Set<String> = ["{", "}", "{}", "[", "[[", "]", "]]"]

    /// The simple commands in `line`, or nil when it nests deeper than `depthLimit` or costs more than `lookahead` allows.
    static func commands(in line: String) -> [Command]? { scan(line)?.commands }

    /// A line read for `RefusedGit.built`: its commands, each word's `Kind` settled, and whether it has a `[[ … ]]` test
    /// or a `case` arm that isn't written plainly (`odd`), which is then read the strict way.
    struct Scan {
        var commands: [Command]
        var odd: Bool
        /// A redirection it doesn't know, which the shell may read otherwise: the line isn't read for `built`.
        var tangled: Bool
    }

    /// The simple commands in `line`, as `commands(in:)`, with what `RefusedGit.built` reads of them. A plain test's
    /// operands, a `case` arm's pattern words: only when every test (or every arm) on the line is plain, and no `case`
    /// is on a line with a test; otherwise each such word is `plain`, read as one that may be a program.
    static func scan(_ line: String) -> Scan? {
        var scanner = Scanner(chars: line.unicodeScalars.map(Character.init))
        scanner.list(until: nil)
        guard !scanner.unreadable else { return nil }
        let tests = !scanner.oddTest && !(scanner.sawCase && scanner.sawTest)
        let patterns = !scanner.oddPattern
        var commands = scanner.commands
        for index in commands.indices {
            commands[index].kinds = commands[index].kinds.map {
                ($0 == .operand && !tests) || ($0 == .pattern && !patterns) ? .plain : $0
            }
        }
        return Scan(commands: commands, odd: !tests || !patterns, tangled: scanner.oddRedirection)
    }

    /// The keywords after which `[[` opens a test, or `case` a case: unquoted, in a command's own place.
    static let opening: Set<String> = ["!", "{", "if", "then", "else", "elif", "do", "while", "until"]

    struct Scanner {
        let chars: [Character]
        var i = 0
        var commands: [Command] = []
        /// How the word being read (the innermost list's) is made so far.
        var made: Shape = []
        /// A `[[` that opens no plain test, a test that isn't plain (`list`), or a `case` anywhere; a `case` arm that
        /// isn't plain. Any of them, and the line's tests (or arms) are read the strict way (`scan`).
        var oddTest = false
        var sawTest = false
        var sawCase = false
        var oddPattern = false
        /// A redirection this doesn't know (`<|`, `>>>`): the line is refused as too tangled (`RefusedGit.built`'s caller).
        var oddRedirection = false
        /// Here-documents whose bodies start after the current line: each delimiter, whether `<<-` strips tabs, and
        /// whether the delimiter was quoted (the body is then text; unquoted, the shell runs its substitutions).
        var pending: [(delimiter: String, tabs: Bool, quoted: Bool)] = []
        var depth = 0
        var unreadable = false
        /// What `isArithmetic`'s look-aheads may still read: each reads on to its `((`'s close, so lines built for it
        /// (`(('((' ) ); ` over and over) cost the square of their length. Past it, the line is refused, not read.
        var lookahead: Int

        init(chars: [Character]) {
            self.chars = chars
            lookahead = 64 * chars.count + 100_000
        }

        func peek(_ offset: Int = 0) -> Character? { i + offset < chars.count ? chars[i + offset] : nil }

        /// One level deeper; false (and the rest of the line skipped) past `depthLimit`. Each `enter` that returns
        /// true is paired with `depth -= 1`.
        mutating func enter() -> Bool {
            depth += 1
            guard depth > ShellWords.depthLimit else { return true }
            depth -= 1
            giveUp()
            return false
        }

        /// The line isn't read further, and is refused.
        mutating func giveUp() {
            unreadable = true
            i = chars.count
        }

        /// Reads commands until `terminator` (`)` of a subshell or `$(`, or a backtick) or the line's end; past it.
        /// `array`: the words of an array's parentheses; `input`: the list's commands take the input of the subshell
        /// they're in; `group`: the words of zsh's glob group or qualifier, and `inert` when they are never a command's
        /// (not after a keyword, `if(…)`, `{(…)`, `!(…)`, where the shell reads a subshell); `parenthesized`: a plain
        /// test's `( … )`, whose words are its operands.
        mutating func list(until terminator: Character?, array: Bool = false, group: Bool = false, inert: Bool = false,
                           input inherited: Bool = false, parenthesized: Bool = false) {
            guard enter() else { return }
            // The word this list is read inside of (`a$(…)b`) keeps how it was made.
            let outer = made
            made = []
            defer {
                depth -= 1
                made = outer
            }
            var command = Command(input: inherited, array: array, group: group)
            var word: String?
            var redirectTarget = false
            // What `RefusedGit.built` reads of this list (`Kind`); none of it changes how the list is read. Where the word
            // being read starts, as written. Whether a command starts here (the list's start, or after `;`, `&`, `|`
            // or a line break, not after a subshell's `)`), and its words so far are unquoted `opening` keywords with
            // no redirection: only then does `[[` open a test, or `case` a case. A plain test open. The `case`s open
            // (and where the one being read has its `case`), whether an arm's pattern is being read, whether it has a
            // word, whether the alternative being read has one, and where an arm's `;;` (`;&`, `;;&`, `;|`) goes on.
            // In a glob group: whether it has spaces or separators (then its words may be commands), and the commands
            // read at this level.
            var start = i
            var fresh = true
            var opening = true
            var testing = parenthesized
            var arms = 0
            var caseWord = -1
            var pattern = false
            var armWord = false
            var alternative = false
            var armEnd = -1
            var spaced = false
            var mine: [Int] = []
            func endWord() {
                if let current = word {
                    let raw = String(chars[min(start, chars.count)..<min(i, chars.count)])
                    if redirectTarget {
                        redirectTarget = false
                        if testing || pattern, raw.contains("]]") || current.contains("]]") { oddTest = true }
                    } else {
                        let kept = ShellWords.unexpanded.contains(current)
                        command.words.append(current)
                        command.made.append(kept ? made.all.subtracting(.pattern) : made.all)
                        command.last.append(kept ? made.last.subtracting(.pattern) : made.last)
                        command.bare.append(made.bare && !kept)
                        command.kinds.append(kind(current, literal: raw == current))
                    }
                }
                word = nil
                made = []
            }
            /// What the word just read is (`Kind`), and the state it moves to: a plain test opens at an unquoted `[[`
            /// in a command's place followed by a space, and closes at a `]]` word of its own with a space before it;
            /// any other `[[` or `]]` makes the line's tests odd. A `case` arm's pattern words: one to an alternative.
            func kind(_ current: String, literal: Bool) -> Kind {
                let before: Character? = start > 0 ? chars[start - 1] : nil
                var kind = array ? Kind.element : Kind.plain
                if current == "case" { sawCase = true }
                if testing {
                    kind = .operand
                    if literal, current == "]]", before == " " || before == "\t" {
                        testing = false
                    } else if current.contains("]]") || current == "[[" {
                        oddTest = true
                    }
                } else if pattern {
                    kind = .pattern
                    if literal, current == "esac", !armWord {
                        arms -= 1
                        pattern = false
                        kind = .plain
                    } else {
                        if alternative { oddPattern = true }
                        alternative = true
                        armWord = true
                    }
                } else if current == "[[" {
                    if literal, fresh, opening, peek() == " " || peek() == "\t" {
                        testing = true
                        sawTest = true
                        kind = .operand
                    } else {
                        oddTest = true
                    }
                } else if literal, current == "case", fresh, opening {
                    caseWord = command.words.count - 1
                } else if literal, current == "in", caseWord >= 0, command.words.count - 1 == caseWord + 2 {
                    arms += 1
                    pattern = true
                    armWord = false
                    alternative = false
                } else if literal, current == "esac", fresh, opening, arms > 0 {
                    arms -= 1
                }
                opening = opening && literal && ShellWords.opening.contains(current)
                return kind
            }
            func endCommand() {
                endWord()
                // A command not begun keeps the input a pipe before a line break gave it (`a |⏎ b`).
                if !command.words.isEmpty {
                    mine.append(commands.count)
                    commands.append(command)
                    command = Command(input: inherited, array: array, group: group)
                }
                redirectTarget = false
                opening = true
                caseWord = -1
                alternative = false
            }
            /// The list's end: a test or a `case` still open is odd; a glob group's words never run when it has no
            /// spaces or separators and is closed.
            func finish(closed: Bool) {
                endCommand()
                // A test still open, or a test's parentheses that its `]]` closed inside (`[[ ( a ]] )`), or that never closed.
                if parenthesized ? !testing || !closed : testing { oddTest = true }
                if pattern || arms > 0 { oddPattern = true }
                if group, inert, closed, !spaced {
                    for index in mine { commands[index].kinds = commands[index].words.map { _ in .group } }
                }
                // An array's parentheses with a separator in them, or never closed: the shell doesn't read them as an
                // array's, and each word that could be a program is read as one.
                if array, !closed || spaced {
                    for index in mine { commands[index].kinds = commands[index].kinds.map { $0 == .element ? .plain : $0 } }
                }
            }
            /// Whether `(` after `word` opens an array's parentheses (`a=(x y)`, `a+=(x)`, `a[1]=(x)`: a name and one
            /// `=`, last).
            func isArray(_ word: String?) -> Bool {
                word.map { $0.hasSuffix("=") && $0.utf8.filter { $0 == UInt8(ascii: "=") }.count == 1 && RefusedGit.assigned($0) != nil } ?? false
            }
            while let c = peek() {
                if word == nil { start = i }
                let prior: Character? = i > 0 ? chars[i - 1] : nil
                if testing {
                    // In a plain test: the characters it can hold, by one reading. Anything else (a `;`, a line break, a
                    // lone `&` or `|`, a parenthesis that isn't glued to a word, `]]` with text after it), and the line's
                    // tests are read the strict way.
                    let closer = word == "]]" && start > 0 && String(chars[start..<i]) == "]]" && (chars[start - 1] == " " || chars[start - 1] == "\t")
                    let usual: Bool
                    if closer {
                        usual = !parenthesized && (c == " " || c == "\t" || c == ";" || c == "&" || c == "|" || c == ")" || c == "\n" || c == terminator)
                    } else if c == terminator {
                        usual = parenthesized
                    } else {
                        switch c {
                        case ";", "\n", ")": usual = false
                        case "#": usual = word != nil
                        case "&": usual = peek(1) != ">" && ((peek(1) == "&" && prior != "&") || (prior == "&" && (i < 2 || chars[i - 2] != "&") && peek(1) != "&"))
                        case "|": usual = peek(1) == "|" && peek(2) != "|" && peek(2) != "&"
                        case "(": usual = word == "=" || (word != nil && peek(1) != ")" && !isArray(word)) || (word == nil && (peek(1) == " " || peek(1) == "\t"))
                        case "<", ">": usual = word == nil && (peek(1) == " " || peek(1) == "\t" || peek(1) == "(")
                        default: usual = true
                        }
                    }
                    if !usual { oddTest = true }
                }
                if pattern {
                    // In a `case` arm's pattern: words, one to an alternative, `|` between them and `)` after. Anything
                    // else, and the line's arms are read as commands.
                    let usual: Bool
                    if i == armEnd || (i == armEnd + 1 && chars[armEnd] == ";" && c == "&") {
                        usual = true
                    } else if c == terminator {
                        usual = false
                    } else {
                        switch c {
                        case " ", "\t": usual = true
                        case "\n": usual = word == nil && !armWord
                        case "#": usual = word != nil || !armWord
                        case "|": usual = (word != nil || alternative) && peek(1) != "|" && peek(1) != "&"
                        case ")": usual = word != nil || alternative
                        case "(": usual = word != nil && word != "=" && peek(1) != ")" && !isArray(word)
                        case ";", "&", "<", ">": usual = false
                        default: usual = true
                        }
                    }
                    if !usual { oddPattern = true }
                }
                if group, " \t\n;&<>".contains(c) || (c == "|" && peek(1) == "|") || ((c == "(" || c == "#") && word == nil) { spaced = true }
                if array, ";&|<>".contains(c) || (c == "(" && word == nil) { spaced = true }
                if let terminator, c == terminator {
                    finish(closed: true)
                    i += 1
                    return
                }
                switch c {
                case " ", "\t":
                    endWord()
                    i += 1
                case "\n":
                    endCommand()
                    fresh = true
                    i += 1
                    bodies()
                    made = []
                case "&" where peek(1) == ">":
                    // `&>file`, `&>>file`: a redirection of both outputs, not the end of the command.
                    endWord()
                    opening = false
                    i += 1
                case ";", "&", "|":
                    // A `case` arm's end, `;;` (`;&`, `;;&`, zsh's `;|`): the next arm's pattern follows.
                    let arm = c == ";" && arms > 0 && !pattern && (peek(1) == ";" || peek(1) == "&" || peek(1) == "|")
                    endCommand()
                    fresh = true
                    if arm {
                        pattern = true
                        armWord = false
                        armEnd = i + 1
                    }
                    if c == "|", peek(1) != "|" {
                        // A pipe (`|`, `|&`): the next command reads what the last one wrote.
                        i += peek(1) == "&" ? 2 : 1
                        command.input = true
                    } else {
                        i += c == "|" ? 2 : 1
                    }
                case "(" where word == nil && isArithmetic():
                    // An arithmetic command, `((x<<2))`: its `<<` is a shift, and only its substitutions run.
                    word = arithmetic()
                case "(" where word == "=":
                    // zsh's `=(…)`, a process substitution as `<(…)` is (the word `=` alone, so not an array's): its
                    // commands are read as commands.
                    i += 1
                    list(until: ")")
                    made.insert(.substitution)
                case "(":
                    // A subshell, which takes the input of the command it's in place of; or an array's parentheses
                    // (`a=(x y)`, `a+=(x)`, `a[1]=(x)`: a name and one `=`, last), whose words are then a command of
                    // their own, marked as one that isn't run. After other text it's zsh's glob group (`git pus(h|x)`):
                    // the word before it is one the shell makes, and the group is read as commands, a wider reading.
                    let array = isArray(word)
                    let group = word != nil && !array && peek(1) != ")"
                    if group { made.insert(.pattern) }
                    let input = command.input
                    // A plain test's own parentheses, `[[ -n $a && ( $b || $c ) ]]`: spaced, and read as operands.
                    let parenthesized = testing && word == nil && (peek(1) == " " || peek(1) == "\t")
                    // A keyword glued to it (`{($x);}`, `if($x);then …`, `!($x)`, `time($x)`): bash, and zsh after `{`,
                    // read a subshell, whose words may run.
                    let inert = group && !(word.map { RefusedGit.keywords.contains($0) || ShellWords.opening.contains($0) || $0 == "time" } ?? false)
                    endCommand()
                    i += 1
                    list(until: ")", array: array, group: group, inert: inert, input: input && !array, parenthesized: parenthesized)
                    fresh = false
                    // A pattern's group (`@(a|b))`) is its alternative's.
                    if pattern, group { alternative = true }
                case ")":
                    // An arm's `)` ends its pattern: its commands follow, in a command's place.
                    let arm = pattern && (word != nil || alternative)
                    endCommand()
                    if arm { pattern = false }
                    fresh = arm
                    i += 1
                case "`":
                    i += 1
                    list(until: "`")
                    word = word ?? ""
                    made.insert(.substitution)
                    made.bare = true
                case "$" where peek(1) == "(" || peek(1) == "{" || peek(1) == "[":
                    word = (word ?? "") + expansion()
                    made.bare = true
                case "$" where peek(1) == "\"":
                    // bash's `$"…"`, a quoted string it may translate: the quoted text (zsh reads `$` and the quotes,
                    // `$push`; the hook takes bash's reading, which a rule can match).
                    i += 1
                case "$" where peek(1) == "'":
                    // ANSI-C quoting: a backslash escapes the next character (`$'it\'s'`). Its other escapes
                    // (`\x67`, `\147`) aren't read: the word is then one the shell makes.
                    i += 2
                    var text = ""
                    while let d = peek(), d != "'" {
                        if d == "\\", let next = peek(1) {
                            if next != "'", next != "\\" { made.insert(.variable) }
                            text.append(next)
                            i += 2
                        } else {
                            if d == "/" { made.slash() }
                            text.append(d)
                            i += 1
                        }
                    }
                    i += 1
                    if !text.isEmpty { made.insert(.text) }
                    word = (word ?? "") + text
                case "'":
                    i += 1
                    var text = ""
                    while let d = peek(), d != "'" {
                        if d == "/" { made.slash() }
                        text.append(d)
                        i += 1
                    }
                    i += 1
                    if !text.isEmpty { made.insert(.text) }
                    word = (word ?? "") + text
                case "\"":
                    i += 1
                    word = (word ?? "") + expanded(until: "\"")
                    i += 1
                case "\\":
                    if peek(1) == "\n" { i += 2; continue }
                    if let next = peek(1) {
                        word = (word ?? "") + String(next)
                        if next == "/" { made.slash() }
                        made.insert(.text)
                    }
                    i += 2
                case "#" where word == nil:
                    while let d = peek(), d != "\n" { i += 1 }
                case "<" where peek(1) == "<" && peek(2) != "<":
                    endWord()
                    opening = false
                    i += 2
                    command.input = true
                    hereDocument()
                case "<", ">":
                    // A file descriptor's number before it isn't a word; the next word is the target.
                    if let current = word, !current.isEmpty, current.allSatisfy(\.isNumber) {
                        word = nil
                        made = []
                    } else {
                        endWord()
                    }
                    opening = false
                    let run = i
                    i += 1
                    if peek() == "(" {
                        // Process substitution, `<(…)` or `>(…)`: commands of their own, and a word (or the target).
                        i += 1
                        list(until: ")")
                        word = word ?? ""
                        made.insert(.substitution)
                        continue
                    }
                    if c == "<" { command.input = true }
                    while let d = peek(), d == "<" || d == ">" || d == "|" { i += 1 }
                    // The operators the shells have; another (`<|`, `>>>`) may be read otherwise, as a pipe after it.
                    if !["<", ">", ">>", ">|", ">>|", "<>", "<<<"].contains(String(chars[run..<i])) { oddRedirection = true }
                    if peek() == "&", let d = peek(1), d.isNumber || d == "-" {
                        // A descriptor copied or closed (`2>&1`, `>&-`).
                        i += 1
                        while let d = peek(), d.isNumber || d == "-" { i += 1 }
                    } else {
                        // A file, `>&file` (as `&>file`) included: the next word is the target.
                        if peek() == "&" { i += 1 }
                        redirectTarget = true
                    }
                default:
                    switch c {
                    case "$" where startsParameter():
                        made.insert(.variable)
                        made.bare = true
                    case "{":
                        // Braces make several words, and may hold a `/` (`{/usr/bin/gi,x}t`).
                        made.insert([.pattern, .text])
                        made.bare = true
                    case "*", "?", "[": made.insert([.pattern, .text])
                    case "=" where word == nil: made.insert([.pattern, .text])
                    case "/":
                        made.slash()
                        made.insert(.text)
                    default: made.insert(.text)
                    }
                    word = (word ?? "") + String(c)
                    i += 1
                }
            }
            finish(closed: terminator == nil)
        }

        /// At a `$` that opens no `$(`, `${`, `$[` or `$'`: whether a parameter's name follows (`$x`, `$1`, `$@`), read
        /// widely: anything but the end of the word or of its double quotes.
        func startsParameter() -> Bool {
            guard let next = peek(1) else { return false }
            return !" \t\n\"".contains(next)
        }

        /// The text up to `terminator` (not past it) as the shell expands it in double quotes or an unquoted
        /// here-document's line: `\` escapes, and `$(…)`, backticks, `$((…))` and `${…}` are read for their commands.
        mutating func expanded(until terminator: Character) -> String {
            var text = ""
            while let c = peek(), c != terminator {
                switch c {
                case "\\":
                    if let next = peek(1) {
                        text.append(next)
                        made.insert(.text)
                    }
                    i += 2
                case "`":
                    i += 1
                    list(until: "`")
                    made.insert(.substitution)
                case "$" where peek(1) == "(" || peek(1) == "{" || peek(1) == "[":
                    text += expansion()
                default:
                    if c == "/" { made.slash() }
                    made.insert(c == "$" && startsParameter() ? .variable : .text)
                    text.append(c)
                    i += 1
                }
            }
            return text
        }

        /// At `$(`, `${` or `$[`: past the expansion, reading the commands it runs; its text, for the word it's in.
        mutating func expansion() -> String {
            let start = i
            i += 1
            if peek() == "{" {
                // `${x:-$(…)}`: its substitutions run, and quotes in it are quotes (`${x:-'}'}`, in double quotes too).
                guard enter() else { return "" }
                defer { depth -= 1 }
                i += 1
                while let c = peek(), c != "}" {
                    switch c {
                    case "\\": i += 2
                    case "`":
                        i += 1
                        list(until: "`")
                    case "'":
                        i += 1
                        while let d = peek(), d != "'" { i += 1 }
                        i += 1
                    case "\"":
                        i += 1
                        _ = expanded(until: "\"")
                        i += 1
                    case "$" where peek(1) == "(" || peek(1) == "{" || peek(1) == "[": _ = expansion()
                    default: i += 1
                    }
                }
                i += 1
                made.insert(.variable)
            } else if peek() == "[" {
                // `$[1<<2]`, bash's old arithmetic: its `<<` is a shift.
                _ = arithmetic(open: "[", close: "]")
                made.insert(.variable)
            } else if isArithmetic() {
                _ = arithmetic()
                made.insert(.variable)
            } else {
                i += 1
                list(until: ")")
                made.insert(.substitution)
            }
            return String(chars[start..<min(i, chars.count)])
        }

        /// At `((`: whether `))` closes it, as bash reads an arithmetic expansion or command (`((cd x); y)` is two subshells).
        mutating func isArithmetic() -> Bool {
            guard peek() == "(", peek(1) == "(" else { return false }
            var level = 0
            var j = i
            while j < chars.count {
                lookahead -= 1
                if lookahead < 0 {
                    giveUp()
                    return false
                }
                if chars[j] == "(" {
                    level += 1
                } else if chars[j] == ")" {
                    level -= 1
                    if level == 1 { return j + 1 < chars.count && chars[j + 1] == ")" }
                }
                j += 1
            }
            return false
        }

        /// At `((` (or `[` of `$[`): past the matching close, reading the commands its substitutions run
        /// (`$((1 + $(…)))`); its text.
        mutating func arithmetic(open: Character = "(", close: Character = ")") -> String {
            let start = i
            guard enter() else { return "" }
            defer { depth -= 1 }
            var level = 0
            while let c = peek() {
                switch c {
                case "`":
                    i += 1
                    list(until: "`")
                case "$" where peek(1) == "(" || peek(1) == "{" || peek(1) == "[":
                    _ = expansion()
                case open:
                    level += 1
                    i += 1
                case close:
                    level -= 1
                    i += 1
                    if level == 0 { return String(chars[start..<i]) }
                default:
                    i += 1
                }
            }
            return String(chars[start..<min(i, chars.count)])
        }

        /// After `<<`: notes the here-document's delimiter (quoted or not), whose body starts on the next line.
        mutating func hereDocument() {
            var tabs = false
            var quoted = false
            if peek() == "-" { tabs = true; i += 1 }
            while peek() == " " || peek() == "\t" { i += 1 }
            var delimiter = ""
            while let c = peek(), !" \t\n;&|<>()".contains(c) {
                if c == "'" || c == "\"" {
                    quoted = true
                    i += 1
                    while let d = peek(), d != c { delimiter.append(d); i += 1 }
                    i += 1
                } else if c == "\\" {
                    quoted = true
                    if let next = peek(1) { delimiter.append(next) }
                    i += 2
                } else {
                    delimiter.append(c)
                    i += 1
                }
            }
            pending.append((delimiter, tabs, quoted))
        }

        /// At a line's start: past the bodies of the here-documents its previous line opened, each to its delimiter.
        /// A quoted delimiter's body is text; an unquoted one's lines are expanded, so their substitutions are read.
        mutating func bodies() {
            while !pending.isEmpty {
                let (delimiter, tabs, quoted) = pending.removeFirst()
                while i < chars.count {
                    var end = i
                    while end < chars.count, chars[end] != "\n" { end += 1 }
                    let line = chars[i..<end].drop { tabs && $0 == "\t" }
                    if String(line) == delimiter {
                        i = end + 1
                        break
                    }
                    if quoted {
                        i = end + 1
                    } else {
                        _ = expanded(until: "\n")
                        i += 1
                    }
                }
            }
        }
    }
}
