import Foundation

/// The git options no role runs, in every spelling git takes: global options (before git's command) that pick another
/// repository, work tree, config or set of git programs, so a role's rules on `git <command>` would see a different git
/// than the one that runs (`git -C . push`, `git -c alias.x=push x`, `git --git-dir=<main>/.git update-ref …`).
///
/// A rule matches by its text: `Bash(git --git-dir:*)` is `git --git-dir` then a space, so on 2026-11-17 the Code Mode
/// trial's worker ran `git --git-dir=<path> for-each-ref` in auto mode, where nothing asked. So the list is kept here
/// once: `rules` and `spellingRules` (each role's deny rules, `LeadLaunch.gitAround`, a first layer that holds even if
/// the hook fails to run), and `refusal`, the parsed check each role's `PreToolUse` hook runs on every Bash call
/// whatever the permission mode (`ReadOnlyCommand.hookAnswer`): it finds each git a line runs (after `;`, `&&`, `|`, in
/// a subshell, `$(…)`, backticks, behind `env`/`command`/a full path) and refuses a listed option anywhere before git's
/// command (`git -P -C x status`), spaced, with `=`, or attached (`-C<path>`, `-c<name>=<value>`: git 2.54 rejects
/// those, refused anyway).
///
/// Not seen here, and so open: the same settings through git's environment (`GIT_DIR=x git …`, `GIT_CONFIG_*`),
/// a line run by another shell (`sh -c '…'`, `eval`, `env -S '…'`), a refused command behind a harmless option
/// (`git -P push`), and a word the shell makes from an expansion (`git $opt x`, `git ${o:--C} x`).
public enum RefusedGit {
    /// The refused options. `--config-env` is `-c` with its value read from an environment variable.
    public static let options = ["-C", "-c", "--git-dir", "--work-tree", "--exec-path", "--config-env"]

    /// The global options that take the next word as their value when it isn't joined with `=` (`git --namespace n`),
    /// from `git -h` (2.54) and git.c; `--exec-path` alone prints the path and takes none.
    static let valued: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix",
                                      "--attr-source"]

    /// The rules as they were, by name: the spaced spelling (`Bash(git -C:*)`).
    static let rules: [String] = options.map { "Bash(git \($0):*)" }

    /// The other spellings, where a rule can name them: `=` after a long option, and anything attached to a short one
    /// (`Bash(git -C*)` takes `git -C/x` and `git -C x` alike). Only at the line's start: the hook finds the rest.
    static let spellingRules: [String] = options.map { $0.hasPrefix("--") ? "Bash(git \($0)=*)" : "Bash(git \($0)*)" }

    /// Why a line is refused: a git it runs takes a refused option (as written), or it nests deeper than it's read.
    public enum Refusal: Equatable {
        case option(String)
        case tooDeep

        /// The hook's reason, as the session reads it.
        public var reason: String {
            switch self {
            case .option(let option):
                "VibeSwitcher refuses git's \(option) to every role, in every spelling: it points git at another repository, "
                    + "work tree, config or programs. Run git in your own worktree without it."
            case .tooDeep:
                "VibeSwitcher refuses a command nested more than \(ShellWords.depthLimit) levels deep (subshells, substitutions): "
                    + "it can't check what git it runs. Write it flatter."
            }
        }
    }

    /// The refusal a git in `line` would run with, or nil when none does.
    public static func refusal(in line: String) -> Refusal? {
        guard let commands = ShellWords.commands(in: line) else { return .tooDeep }
        for words in commands {
            if let option = refusal(command: words) { return .option(option) }
        }
        return nil
    }

    /// Words that come before the program a command runs, with no effect on which it is.
    static let keywords: Set<String> = ["!", "{", "}", "(", ")", "if", "then", "else", "elif", "fi", "do", "done", "while", "until",
                                        "time", "coproc"]
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
                "vs-heavy": Wrapper(valued: ["--as", "--timeout", "--stall"])]
    }()

    /// The refused option in one simple command (its words, quotes taken off), when it runs git.
    static func refusal(command words: [String]) -> String? {
        var index = 0
        while index < words.count {
            let word = words[index]
            let name = (word as NSString).lastPathComponent
            if keywords.contains(word) || isAssignment(word) {
                index += 1
            } else if let wrapper = wrappers[name] {
                index += 1
                while index < words.count, words[index].hasPrefix("-") || (name == "env" && isAssignment(words[index])) {
                    index += wrapper.valued.contains(words[index]) ? 2 : 1
                }
                index += wrapper.operands
            } else {
                break
            }
        }
        guard index < words.count, (words[index] as NSString).lastPathComponent == "git" else { return nil }
        index += 1
        // git's own options, up to its command: the first word that isn't one.
        while index < words.count {
            let word = words[index]
            guard word.hasPrefix("-"), word != "-", word != "--" else { return nil }
            if options.contains(where: { word.hasPrefix($0) }) { return word }
            index += valued.contains(word) ? 2 : 1
        }
        return nil
    }

    /// `NAME=value`, a variable the shell sets for the command.
    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        return name.first.map { $0 == "_" || ($0.isASCII && $0.isLetter) } == true
            && name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
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

    /// The simple commands in `line`, or nil when it nests deeper than `depthLimit`.
    static func commands(in line: String) -> [[String]]? {
        var scanner = Scanner(chars: line.unicodeScalars.map(Character.init))
        scanner.list(until: nil)
        return scanner.tooDeep ? nil : scanner.commands
    }

    struct Scanner {
        let chars: [Character]
        var i = 0
        var commands: [[String]] = []
        /// Here-documents whose bodies start after the current line: each delimiter, whether `<<-` strips tabs, and
        /// whether the delimiter was quoted (the body is then text; unquoted, the shell runs its substitutions).
        var pending: [(delimiter: String, tabs: Bool, quoted: Bool)] = []
        var depth = 0
        var tooDeep = false

        init(chars: [Character]) { self.chars = chars }

        func peek(_ offset: Int = 0) -> Character? { i + offset < chars.count ? chars[i + offset] : nil }

        /// One level deeper; false (and the rest of the line skipped) past `depthLimit`. Each `enter` that returns
        /// true is paired with `depth -= 1`.
        mutating func enter() -> Bool {
            depth += 1
            guard depth > ShellWords.depthLimit else { return true }
            depth -= 1
            tooDeep = true
            i = chars.count
            return false
        }

        /// Reads commands until `terminator` (`)` of a subshell or `$(`, or a backtick) or the line's end; past it.
        mutating func list(until terminator: Character?) {
            guard enter() else { return }
            defer { depth -= 1 }
            var words: [String] = []
            var word: String?
            var redirectTarget = false
            func endWord() {
                if let current = word {
                    if redirectTarget { redirectTarget = false } else { words.append(current) }
                }
                word = nil
            }
            func endCommand() {
                endWord()
                if !words.isEmpty { commands.append(words) }
                words = []
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
                case ";", "&", "|":
                    endCommand()
                    i += 1
                case "(" where word == nil && isArithmetic():
                    // An arithmetic command, `((x<<2))`: its `<<` is a shift, and only its substitutions run.
                    word = arithmetic()
                case "(":
                    // A subshell (or an array's parentheses: its words are then a command of their own, which is harmless).
                    endCommand()
                    i += 1
                    list(until: ")")
                case ")":
                    endCommand()
                    i += 1
                case "`":
                    i += 1
                    list(until: "`")
                    word = word ?? ""
                case "$" where peek(1) == "(" || peek(1) == "{":
                    word = (word ?? "") + expansion()
                case "$" where peek(1) == "'":
                    // ANSI-C quoting: a backslash escapes the next character (`$'it\'s'`).
                    i += 2
                    var text = ""
                    while let d = peek(), d != "'" {
                        if d == "\\", let next = peek(1) { text.append(next); i += 2 } else { text.append(d); i += 1 }
                    }
                    i += 1
                    word = (word ?? "") + text
                case "'":
                    i += 1
                    var text = ""
                    while let d = peek(), d != "'" { text.append(d); i += 1 }
                    i += 1
                    word = (word ?? "") + text
                case "\"":
                    i += 1
                    word = (word ?? "") + expanded(until: "\"")
                    i += 1
                case "\\":
                    if peek(1) == "\n" { i += 2; continue }
                    if let next = peek(1) { word = (word ?? "") + String(next) }
                    i += 2
                case "#" where word == nil:
                    while let d = peek(), d != "\n" { i += 1 }
                case "<" where peek(1) == "<" && peek(2) != "<":
                    endWord()
                    i += 2
                    hereDocument()
                case "<", ">":
                    // A file descriptor's number before it isn't a word; the next word is the target.
                    if let current = word, !current.isEmpty, current.allSatisfy(\.isNumber) { word = nil } else { endWord() }
                    i += 1
                    if peek() == "(" {
                        // Process substitution, `<(…)` or `>(…)`: commands of their own, and a word (or the target).
                        i += 1
                        list(until: ")")
                        word = word ?? ""
                        continue
                    }
                    while let d = peek(), d == "<" || d == ">" || d == "|" { i += 1 }
                    if peek() == "&" {
                        i += 1
                        while let d = peek(), d.isNumber || d == "-" { i += 1 }
                    } else {
                        redirectTarget = true
                    }
                default:
                    word = (word ?? "") + String(c)
                    i += 1
                }
            }
            endCommand()
        }

        /// The text up to `terminator` (not past it) as the shell expands it in double quotes or an unquoted
        /// here-document's line: `\` escapes, and `$(…)`, backticks, `$((…))` and `${…}` are read for their commands.
        mutating func expanded(until terminator: Character) -> String {
            var text = ""
            while let c = peek(), c != terminator {
                switch c {
                case "\\":
                    if let next = peek(1) { text.append(next) }
                    i += 2
                case "`":
                    i += 1
                    list(until: "`")
                case "$" where peek(1) == "(" || peek(1) == "{":
                    text += expansion()
                default:
                    text.append(c)
                    i += 1
                }
            }
            return text
        }

        /// At `$(` or `${`: past the expansion, reading the commands it runs; its text, for the word it's in.
        mutating func expansion() -> String {
            let start = i
            i += 1
            if peek() == "{" {
                // `${x:-$(…)}`: its substitutions run.
                guard enter() else { return "" }
                defer { depth -= 1 }
                i += 1
                while let c = peek(), c != "}" {
                    switch c {
                    case "\\": i += 2
                    case "`":
                        i += 1
                        list(until: "`")
                    case "$" where peek(1) == "(" || peek(1) == "{": _ = expansion()
                    default: i += 1
                    }
                }
                i += 1
            } else if isArithmetic() {
                _ = arithmetic()
            } else {
                i += 1
                list(until: ")")
            }
            return String(chars[start..<min(i, chars.count)])
        }

        /// At `((`: whether `))` closes it, as bash reads an arithmetic expansion or command (`((cd x); y)` is two subshells).
        func isArithmetic() -> Bool {
            guard peek() == "(", peek(1) == "(" else { return false }
            var level = 0
            var j = i
            while j < chars.count {
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

        /// At `((`: past the matching `))`, reading the commands its substitutions run (`$((1 + $(…)))`); its text.
        mutating func arithmetic() -> String {
            let start = i
            guard enter() else { return "" }
            defer { depth -= 1 }
            var level = 0
            while let c = peek() {
                switch c {
                case "`":
                    i += 1
                    list(until: "`")
                case "$" where peek(1) == "(" || peek(1) == "{":
                    _ = expansion()
                case "(":
                    level += 1
                    i += 1
                case ")":
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
