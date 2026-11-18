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
/// its `repeat N` and its short forms' tests (`if [[ … ]] git …`, `while (( … )) git …`).
///
/// What can't be read is refused, not guessed at (`Refusal.Unread`; decision 2026-10-25 16:33: hardening fails closed):
/// the same git run plainly is read, so a refusal costs a rewrite. That is text naming git (`names`: without its case,
/// quotes and backslashes taken out) handed to another interpreter: a shell's `-c` string (`sh`/`bash`/`zsh -c '…'`,
/// behind `xargs` or `find -exec` too), `eval`, `trap`, `watch`, `env -S`; text that isn't all on the line (a word of it
/// made from an expansion or put in by `xargs` or `find`, or a shell or `source`/`.` reading its input: a here-string,
/// a here-document, a pipe, `/dev/stdin`, `<(…)`, or any path when the command is given input) on a line that names
/// git anywhere. And a git whose option or command word the shell makes from
/// an expansion (`git $x …`, `git ${o:--C} x`, `git {push,x}`, `git pus?`, zsh's `git =x`), or that the program running
/// it fills in (`xargs git`, `xargs -I% git % x`, `find -exec git {} \;`). And, on a line that names git, a program
/// whose own name the shell makes from a variable, braces, zsh's `=`, or a substitution alone (`g=git; $g push`,
/// `command {git,push}`, `=git push`, `$(echo git) push`; not a path built on one, `"$(git rev-parse
/// --show-toplevel)/scripts/x.sh"`).
///
/// Not seen here, and so open: a file a shell runs or sources (`bash x.sh`, `source x`, which is how every script
/// runs), and another language's interpreter or a program not listed that runs a command (`python3 -c`, `perl -e`,
/// `osascript`, `script`, `ssh`); input a shell takes from further off (`… | { true; bash dev/stdin; }`, `zsh -c
/// '. /dev/stdin' <<< …`); text that reaches git without naming it (`a=gi; ${a}t push`, `$'\x67it'`, base64);
/// git's own programs by their path (`…/git-core/git-push`); an argument after git's command that the shell makes
/// (`git checkout $b`: a rule reads it as written); a variable set another way (`read GIT_DIR` after `set -a`, a file
/// sourced; `HOME` or `XDG_CONFIG_HOME` set on its own or exported, which every program reads, before a git); and a git
/// alias the user's config already has. A spelling found later is refused the same way, as unreadable, not listed here.
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
            /// A program whose own name (as written) the shell makes from an expansion, on a line that names git.
            case program(String)
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
            case .unreadable(.tangled):
                "VibeSwitcher refuses a command nested more than \(ShellWords.depthLimit) levels deep (subshells, substitutions) "
                    + "or too tangled to read: it can't check what git it runs. Write it flatter."
            case .unreadable(.handed(let interpreter)):
                "VibeSwitcher refuses a line that hands text naming git to \(interpreter), which runs it as commands of its own "
                    + "(as `sh -c '…'`, `eval`, `env -S`, `trap`, `watch` and a shell or `source` reading its input do): it can't "
                    + "check what git that runs. Run the git command plainly, on a line of its own, without the wrapper."
            case .unreadable(.expanded(let word)):
                "VibeSwitcher refuses git with `\(Self.short(word))` where its options or its command go: the shell makes that "
                    + "word from an expansion (a variable, a substitution, braces or a pattern), so it can't check what git "
                    + "runs. Run the git command plainly, its options and command written out, without the variable."
            case .unreadable(.program(let word)):
                "VibeSwitcher refuses a command whose name the shell makes from an expansion (`\(Self.short(word))`) on a line "
                    + "that names git: it can't check whether that runs git. Write the program's name out, and run the git "
                    + "command plainly, without the variable."
            }
        }

        /// A word for a reason's text: its start, when it's long.
        static func short(_ word: String) -> String { word.count > 40 ? word.prefix(40) + "…" : word }
    }

    /// The refusal a git in `line` would run with, or nil when none does. `rules`: the role's deny rules that run git
    /// (`LeadLaunch.gitRules`).
    public static func refusal(in line: String, rules: [String] = []) -> Refusal? {
        guard let commands = ShellWords.commands(in: line) else { return .unreadable(.tangled) }
        // As `ShellWords.Scanner.lookahead`: what reading the commands may cost, a word at a time (`find -exec` reads
        // each command after it, and each `find` there its own, so `find . -exec find . -exec …` costs 2^n unbounded:
        // a hook that times out lets the call through). Past it, the line is refused, not read.
        // Each git's command is tried against the rules that name it, and those tries are charged too: a line of many
        // short gits (`git a;` over and over, 1 MB) otherwise read every rule for each, near the hook's timeout.
        var budget = 64 * line.unicodeScalars.count + 100_000
        let rules = Rules(rules)
        let named = names(line)
        for command in commands {
            if let refusal = refusal(command: command, rules: rules, named: named, budget: &budget) { return refusal }
        }
        return nil
    }

    /// Whether `text` names git: `git` without its case, between characters that aren't ASCII letters or digits
    /// (`/usr/bin/git`, `GIT_DIR`, `.git`; not `github`, `digit`, `RefusedGit`), read as a shell would read it again:
    /// quotes, backslashes and a backslash's line break taken out (`g""it`, `g\it`).
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
        let git = Array("git".utf8)
        var at = 0
        while at + git.count <= bytes.count {
            if bytes[at] == git[0], bytes[at + 1] == git[1], bytes[at + 2] == git[2],
               at == 0 || !wordByte(bytes[at - 1]), at + git.count == bytes.count || !wordByte(bytes[at + git.count]) {
                return true
            }
            at += 1
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
                                        "coproc"]
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
        // A short form's test the scanner split (`if [[ -n a && -n b ]] git …`, `=~ (a|b) ]] git …`): what follows its
        // `]]` is read as a command too.
        if let close = words.firstIndex(of: "]]"),
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
        guard program == "git" else {
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
        index += 1
        // git's own options, up to its command: the first word that isn't one. Each as written: one the shell makes
        // from an expansion (`git $x …`, `git ${o:--C} x`, `git {push,x}`, an option's value too) can't be read, nor
        // one the program running git fills in (`xargs -I% git % x`, `find -exec git {} \;`).
        func unseen(_ at: Int) -> Refusal? {
            if command.made[at].expanded { return .unreadable(.expanded(words[at])) }
            guard let fills = fills([words[at]], appends: false, filled, named: true, budget: &budget) else { return .unreadable(.tangled) }
            return fills ? .unreadable(.expanded(words[at])) : nil
        }
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
        let command = Array((["git", folded(words[index])] + words[(index + 1)...]).joined(separator: " ").utf8)
        let candidates = rules.candidates(Self.command(of: command))
        budget -= command.count + candidates.count
        guard budget >= 0 else { return .unreadable(.tangled) }
        return candidates.first { matches($0, command) }.map { .command($0.text) }
    }

    /// The shells, which run a `-c` string, their input, or a file as commands.
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish"]
    /// The builtins that run a file (or their input) in this shell.
    static let sourcers: Set<String> = ["source", "."]
    /// What runs its words as a shell line: now (`eval`), on a signal (`trap`), or over and over (`watch`).
    static let evaluators: Set<String> = ["eval", "trap", "watch"]

    /// Why a command that hands text to another interpreter is refused, if it is: `program` (its name, without its
    /// case) run with `arguments`, behind an xargs that `appends` its input's words or a program that replaces
    /// `filled` in them. A shell or `source` given a file by a plain path isn't read here: the file isn't on the line.
    static func handed(to program: String, _ arguments: ShellWords.Command, appends: Bool, filled: [String], named: Bool,
                       budget: inout Int) -> Refusal? {
        guard evaluators.contains(program) || shells.contains(program) || sourcers.contains(program) else { return nil }
        // Words of its text that xargs or find put in aren't on the line.
        guard let fills = fills(arguments.words, appends: appends, filled, named: named, budget: &budget) else { return .unreadable(.tangled) }
        if evaluators.contains(program) { return unread(by: program, arguments, reads: fills, named: named, budget: &budget) }
        guard let first = arguments.words.first else {
            // A shell alone reads its input; `source` alone runs nothing.
            return shells.contains(program) && named ? .unreadable(.handed(program)) : nil
        }
        // A script's path, as written and nothing else (`bash scripts/test.sh --filter X`): not `/dev/stdin`, not
        // `<(…)`, not after an option (`bash -x …`, read as text handed over: a wider reading only refuses more).
        // Given input on a line that names git, the path may be that input by another name (`//dev/stdin`).
        if arguments.made[0] == .text, !starts(first, with: "-"), !starts(first, with: "+"), !starts(folded(first), with: "/dev/") {
            return arguments.input && named ? .unreadable(.handed(program)) : nil
        }
        // Without a `-c`, a shell reads its commands from its input: a here-string, a here-document, a pipe.
        let string = shells.contains(program) && takesString(arguments.words)
        return unread(by: program, arguments, reads: !string || fills, named: named, budget: &budget)
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
    /// (the shell makes a word of it from an expansion, or `reads`: it comes through the interpreter's input) on a
    /// line that names git anywhere.
    static func unread(by interpreter: String, _ arguments: ShellWords.Command, reads: Bool, named: Bool, budget: inout Int) -> Refusal? {
        budget -= arguments.words.reduce(arguments.words.count) { $0 + $1.utf8.count }
        guard budget >= 0 else { return .unreadable(.tangled) }
        if names(arguments.words.joined(separator: " ")) { return .unreadable(.handed(interpreter)) }
        if named, reads || arguments.made.contains(where: \.expanded) { return .unreadable(.handed(interpreter)) }
        return nil
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

    /// One simple command: its words, quotes and escapes taken off, and how each was made.
    struct Command {
        var words: [String] = []
        var made: [Made] = []
        /// Its input is given on the line: a pipe into it, a here-string, a here-document, a `<` redirection.
        var input = false
        /// The words in an array's parentheses (`a=(x y)`): read as a command, though the shell runs none.
        var array = false

        subscript(range: Range<Int>) -> Command {
            Command(words: Array(words[range]), made: Array(made[range]), input: input, array: array)
        }
        /// The words from `index` on.
        func from(_ index: Int) -> Command { self[min(index, words.count)..<words.count] }
    }

    /// Words with a brace or a bracket that the shell doesn't expand: its own keywords and tests, and find's `{}`.
    static let unexpanded: Set<String> = ["{", "}", "{}", "[", "[[", "]", "]]"]

    /// The simple commands in `line`, or nil when it nests deeper than `depthLimit` or costs more than `lookahead` allows.
    static func commands(in line: String) -> [Command]? {
        var scanner = Scanner(chars: line.unicodeScalars.map(Character.init))
        scanner.list(until: nil)
        return scanner.unreadable ? nil : scanner.commands
    }

    struct Scanner {
        let chars: [Character]
        var i = 0
        var commands: [Command] = []
        /// How the word being read (the innermost list's) is made so far.
        var made: Made = []
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
        /// they're in.
        mutating func list(until terminator: Character?, array: Bool = false, input inherited: Bool = false) {
            guard enter() else { return }
            // The word this list is read inside of (`a$(…)b`) keeps how it was made.
            let outer = made
            made = []
            defer {
                depth -= 1
                made = outer
            }
            var command = Command(input: inherited, array: array)
            var word: String?
            var redirectTarget = false
            func endWord() {
                if let current = word {
                    if redirectTarget {
                        redirectTarget = false
                    } else {
                        command.words.append(current)
                        command.made.append(ShellWords.unexpanded.contains(current) ? made.subtracting(.pattern) : made)
                    }
                }
                word = nil
                made = []
            }
            func endCommand() {
                endWord()
                // A command not begun keeps the input a pipe before a line break gave it (`a |⏎ b`).
                if !command.words.isEmpty {
                    commands.append(command)
                    command = Command(input: inherited, array: array)
                }
                redirectTarget = false
            }
            while let c = peek() {
                if let terminator, c == terminator {
                    i += 1
                    endCommand()
                    return
                }
                switch c {
                case " ", "\t":
                    endWord()
                    i += 1
                case "\n":
                    endCommand()
                    i += 1
                    bodies()
                    made = []
                case ";", "&", "|":
                    endCommand()
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
                case "(":
                    // A subshell, which takes the input of the command it's in place of; or an array's parentheses
                    // (`a=(x y)`, `a+=(x)`), whose words are then a command of their own, marked as one that isn't run.
                    let array = word?.hasSuffix("=") == true
                    let input = command.input
                    endCommand()
                    i += 1
                    list(until: ")", array: array, input: input && !array)
                case ")":
                    endCommand()
                    i += 1
                case "`":
                    i += 1
                    list(until: "`")
                    word = word ?? ""
                    made.insert(.substitution)
                case "$" where peek(1) == "(" || peek(1) == "{" || peek(1) == "[":
                    word = (word ?? "") + expansion()
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
                    while let d = peek(), d != "'" { text.append(d); i += 1 }
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
                        made.insert(.text)
                    }
                    i += 2
                case "#" where word == nil:
                    while let d = peek(), d != "\n" { i += 1 }
                case "<" where peek(1) == "<" && peek(2) != "<":
                    endWord()
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
                    if peek() == "&" {
                        i += 1
                        while let d = peek(), d.isNumber || d == "-" { i += 1 }
                    } else {
                        redirectTarget = true
                    }
                default:
                    switch c {
                    case "$": made.insert(startsParameter() ? .variable : .text)
                    case "{", "*", "?", "[": made.insert([.pattern, .text])
                    case "=" where word == nil: made.insert([.pattern, .text])
                    default: made.insert(.text)
                    }
                    word = (word ?? "") + String(c)
                    i += 1
                }
            }
            endCommand()
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
