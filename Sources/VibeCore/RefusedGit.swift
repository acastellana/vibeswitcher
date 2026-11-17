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
/// a line run by another shell (`sh -c '…'`, `eval`), and a refused command behind a harmless option (`git -P push`).
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

    /// The refused option (as written) a git in `line` would run with, or nil when none does.
    public static func refusal(in line: String) -> String? {
        for words in ShellWords.commands(in: line) {
            if let option = refusal(command: words) { return option }
        }
        return nil
    }

    /// Words that come before the program a command runs, with no effect on which it is.
    static let keywords: Set<String> = ["!", "{", "}", "(", ")", "if", "then", "else", "elif", "fi", "do", "done", "while", "until",
                                        "time", "coproc"]
    /// Programs that run the command after them, and their options that take a value (`env -u NAME git …`).
    static let wrappers: [String: Set<String>] = ["env": ["-u", "-P", "-S", "-C"], "command": [], "builtin": [], "exec": ["-a"],
                                                  "nohup": [], "nice": ["-n"], "xcrun": ["--sdk", "--toolchain", "-sdk"], "sudo": ["-u", "-g"],
                                                  "caffeinate": ["-t", "-w"], "time": ["-o"],
                                                  "xargs": ["-I", "-J", "-L", "-n", "-P", "-E", "-s", "-R", "-S"]]

    /// The refused option in one simple command (its words, quotes taken off), when it runs git.
    static func refusal(command words: [String]) -> String? {
        var index = 0
        while index < words.count {
            let word = words[index]
            let name = (word as NSString).lastPathComponent
            if keywords.contains(word) || isAssignment(word) {
                index += 1
            } else if let valued = wrappers[name] {
                index += 1
                while index < words.count, words[index].hasPrefix("-") || (name == "env" && isAssignment(words[index])) {
                    index += valued.contains(words[index]) ? 2 : 1
                }
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
/// `|`, `||` and newlines, with those in subshells, groups, `$(…)` and backticks (in double quotes too) as commands of
/// their own; here-document bodies and comments are text, not commands, and a redirection's target isn't a word. Made
/// for finding what runs (`RefusedGit`), so it's lenient: a line the shell would reject still gives what it holds.
enum ShellWords {
    static func commands(in line: String) -> [[String]] {
        var scanner = Scanner(chars: line.unicodeScalars.map(Character.init))
        scanner.list(until: nil)
        return scanner.commands
    }

    struct Scanner {
        let chars: [Character]
        var i = 0
        var commands: [[String]] = []
        /// Here-documents whose bodies start after the current line: each delimiter, and whether `<<-` strips tabs.
        var pending: [(delimiter: String, tabs: Bool)] = []

        init(chars: [Character]) { self.chars = chars }

        func peek(_ offset: Int = 0) -> Character? { i + offset < chars.count ? chars[i + offset] : nil }

        /// Reads commands until `terminator` (`)` of a subshell or `$(`, or a backtick) or the line's end; past it.
        mutating func list(until terminator: Character?) {
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
                case "$" where peek(1) == "(" && peek(2) == "(":
                    // Arithmetic: its `<<` is a shift, not a here-document.
                    word = (word ?? "") + skip(from: "(", to: ")")
                case "$" where peek(1) == "(":
                    i += 2
                    list(until: ")")
                    word = word ?? ""
                case "$" where peek(1) == "{":
                    word = (word ?? "") + skip(from: "{", to: "}")
                case "'":
                    i += 1
                    var text = ""
                    while let d = peek(), d != "'" { text.append(d); i += 1 }
                    i += 1
                    word = (word ?? "") + text
                case "\"":
                    i += 1
                    word = (word ?? "") + doubleQuoted()
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

        /// The text of a double-quoted word from after its opening quote, past its closing one; commands substituted in
        /// it are read as commands.
        mutating func doubleQuoted() -> String {
            var text = ""
            while let c = peek(), c != "\"" {
                switch c {
                case "\\":
                    if let next = peek(1) { text.append(next) }
                    i += 2
                case "`":
                    i += 1
                    list(until: "`")
                case "$" where peek(1) == "(" && peek(2) == "(":
                    text += skip(from: "(", to: ")")
                case "$" where peek(1) == "(":
                    i += 2
                    list(until: ")")
                case "$" where peek(1) == "{":
                    text += skip(from: "{", to: "}")
                default:
                    text.append(c)
                    i += 1
                }
            }
            i += 1
            return text
        }

        /// The text from `$` and `open` to its matching `close`, past it.
        mutating func skip(from open: Character, to close: Character) -> String {
            var depth = 0
            var text = ""
            while let c = peek() {
                text.append(c)
                i += 1
                if c == open { depth += 1 } else if c == close { depth -= 1; if depth == 0 { break } }
            }
            return text
        }

        /// After `<<`: notes the here-document's delimiter (quoted or not), whose body starts on the next line.
        mutating func hereDocument() {
            var tabs = false
            if peek() == "-" { tabs = true; i += 1 }
            while peek() == " " || peek() == "\t" { i += 1 }
            var delimiter = ""
            while let c = peek(), !" \t\n;&|<>()".contains(c) {
                if c == "'" || c == "\"" {
                    i += 1
                    while let d = peek(), d != c { delimiter.append(d); i += 1 }
                    i += 1
                } else if c == "\\" {
                    if let next = peek(1) { delimiter.append(next) }
                    i += 2
                } else {
                    delimiter.append(c)
                    i += 1
                }
            }
            pending.append((delimiter, tabs))
        }

        /// At a line's start: skips the bodies of the here-documents its previous line opened, each to its delimiter.
        mutating func bodies() {
            while !pending.isEmpty {
                let (delimiter, tabs) = pending.removeFirst()
                while i < chars.count {
                    var line = ""
                    while let c = peek(), c != "\n" { line.append(c); i += 1 }
                    i += 1
                    if (tabs ? String(line.drop { $0 == "\t" }) : line) == delimiter { break }
                }
            }
        }
    }
}
