import Foundation

/// What a command in a settings or plugin file runs, for the config seal: the files that are code, not what the
/// command only reads or writes. A log it appends to, or a database it's handed, changes as it works and must hold nothing.
///
/// Counted as code: the program a command starts (when it's named with a slash; a bare name is `PATH`'s), past
/// assignments and prefixes like `env` and `nohup`; the script an interpreter is given; what `source` loads, and a
/// `sh -c` string's own commands; and any other argument that is a script by its extension, or a file with an execute
/// bit. Not counted: redirect targets, and every other argument. What a variable left in the word, a glob or a
/// substitution would compute can't be told, so it isn't named.
extension ConfigSeal {
    /// How a settings or plugin file runs something.
    enum Invocation: Equatable {
        /// A string a shell runs (a hook's, the status line's).
        case shell(String)
        /// A program and its arguments, run with no shell (an MCP or LSP server's), and the folder it runs in if told.
        case argv([String], cwd: String?)
    }

    /// Everything a hooks, MCP, LSP or settings JSON runs. A `"type":"command"` entry is a shell string, one with `args`
    /// a program with arguments. With neither (`command` alone), it could be either, so it's read as both.
    static func commands(in object: Any) -> [Invocation] {
        var found: [Invocation] = []
        if let dictionary = object as? [String: Any] {
            if let command = dictionary["command"] as? String {
                let args = (dictionary["args"] as? [Any])?.compactMap { $0 as? String }
                let type = dictionary["type"] as? String
                if type == "command" || (type == nil && args == nil) { found.append(.shell(command)) }
                if type != "command" { found.append(.argv([command] + (args ?? []), cwd: dictionary["cwd"] as? String)) }
            }
            for key in dictionary.keys.sorted() {
                let value = dictionary[key] as Any
                if value is [String: Any] || value is [Any] { found += commands(in: value) }
            }
        } else if let array = object as? [Any] {
            for value in array { found += commands(in: value) }
        }
        return found
    }

    /// The code files `invocation` runs (`namedPaths` of a string), an argv's relative words against its `cwd`.
    static func namedPaths(_ invocation: Invocation, vars: [String: String], home: String, base: String? = nil) -> [String] {
        switch invocation {
        case .shell(let command): return namedPaths(command, vars: vars, home: home, base: base)
        case .argv(let words, let dir):
            var cwd = base
            if let dir { cwd = expanded(dir, vars: vars, home: home).flatMap { absolute($0, in: base) } }
            return ran(words, stdin: nil, vars: vars, home: home, cwd: &cwd)
        }
    }

    /// The code files the shell string `command` runs, absolute, with `vars` (`${NAME}` or `$NAME`) and a leading `~`
    /// put in. A relative one is taken from `base`, the folder it runs in, and from a `cd` before it; with no folder
    /// known (your own settings' hooks run wherever each session is) it isn't named.
    static func namedPaths(_ command: String, vars: [String: String], home: String, base: String? = nil) -> [String] {
        var cwd = base
        return simpleCommands(command).flatMap { ran($0.words, stdin: $0.stdin, vars: vars, home: home, cwd: &cwd) }
    }

    /// One command of a shell string: its words, redirections gone, and the file a `<` feeds it.
    struct SimpleCommand: Equatable {
        var words: [String] = []
        var stdin: String?
    }

    /// `text` split as a shell would into simple commands: at `; | & ( )`, backticks and newlines, the quotes and
    /// backslashes undone, each redirection and its target taken out.
    static func simpleCommands(_ text: String) -> [SimpleCommand] {
        let chars = Array(text)
        var all: [SimpleCommand] = []
        var current = SimpleCommand()
        var word = "", started = false
        var quote: Character?
        var escaped = false
        var target: Character?
        func endWord() {
            guard started else { return }
            if let redirect = target {
                if redirect == "<" { current.stdin = word }
                target = nil
            } else {
                current.words.append(word)
            }
            word = ""
            started = false
        }
        func endCommand() {
            endWord()
            target = nil
            if !current.words.isEmpty || current.stdin != nil { all.append(current) }
            current = SimpleCommand()
        }
        var index = 0
        while index < chars.count {
            let char = chars[index]
            index += 1
            if escaped {
                word.append(char)
                started = true
                escaped = false
            } else if let open = quote {
                if char == open { quote = nil } else if char == "\\" && open == "\"" { escaped = true } else { word.append(char) }
            } else if char == "\\" {
                escaped = true
            } else if char == "\"" || char == "'" {
                quote = char
                started = true
            } else if char == "<" || char == ">" {
                // A file-descriptor number right before the operator (`2>`) belongs to it.
                if started, !word.isEmpty, word.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    word = ""
                    started = false
                }
                endWord()
                var operatorText = String(char)
                while index < chars.count, "<>&|-".contains(chars[index]) {
                    operatorText.append(chars[index])
                    index += 1
                }
                target = operatorText == "<" ? "<" : ">"
            } else if char == "&", index < chars.count, chars[index] == ">" {
                endWord()
            } else if ";|&()`\n".contains(char) {
                endCommand()
            } else if char.isWhitespace {
                endWord()
            } else {
                word.append(char)
                started = true
            }
        }
        endCommand()
        return all
    }

    /// Words a shell reads before a command, not as one.
    private static let shellKeywords: Set<String> = ["{", "}", "!", "if", "then", "elif", "else", "fi", "do", "done", "while", "until"]

    /// Commands that start the command after them.
    private static let prefixes: Set<String> = ["env", "exec", "command", "builtin", "nohup", "time", "nice", "caffeinate", "stdbuf", "timeout", "gtimeout", "xargs"]

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

    /// How an interpreter reads its flags: which give code on the command line (no script file follows), which name a
    /// code file, and which take a value that isn't one.
    private struct Interpreter {
        var inline: Set<String> = []
        var code: Set<String> = []
        var value: Set<String> = []
        /// Its first plain argument is its script (awk's and sed's is the program text instead: `-f` names their file).
        var firstArgumentIsScript = true
    }

    private static let python = Interpreter(inline: ["-c", "-m"], value: ["-W", "-X"])

    private static let javaScript = Interpreter(inline: ["-e", "--eval", "-p", "--print"], code: ["-r", "--require", "--import", "--loader", "--experimental-loader"],
                                                value: ["--env-file", "--input-type", "--conditions", "-C"])

    private static let interpreters: [String: Interpreter] = [
        "node": javaScript, "nodejs": javaScript, "bun": javaScript, "deno": javaScript, "tsx": javaScript, "ts-node": javaScript,
        "ruby": Interpreter(inline: ["-e"], code: ["-r"], value: ["-I"]),
        "perl": Interpreter(inline: ["-e", "-E"], value: ["-I"]),
        "php": Interpreter(inline: ["-r"], value: ["-d", "-c"]),
        "lua": Interpreter(inline: ["-e"], code: ["-l"]),
        "osascript": Interpreter(inline: ["-e"]), "Rscript": Interpreter(inline: ["-e"]),
        "awk": Interpreter(code: ["-f"], value: ["-F", "-v"], firstArgumentIsScript: false),
        "gawk": Interpreter(code: ["-f"], value: ["-F", "-v"], firstArgumentIsScript: false),
        "sed": Interpreter(code: ["-f"], value: ["-e"], firstArgumentIsScript: false),
    ]

    private static func interpreter(named name: String) -> Interpreter? {
        name.hasPrefix("python") || name.hasPrefix("pypy") ? python : interpreters[name]
    }

    /// File extensions that mean an argument is a script, wherever it stands.
    private static let scriptExtensions: Set<String> = [
        "sh", "bash", "zsh", "fish", "nu", "py", "js", "mjs", "cjs", "ts", "mts", "cts", "rb", "pl", "php", "lua", "jar", "swift", "go",
        "awk", "ps1", "tcl", "r", "R", "jl", "dart", "groovy", "kts", "exs", "applescript", "scpt",
    ]

    /// The code files one simple command runs. `cwd` moves with a `cd`.
    private static func ran(_ all: [String], stdin: String?, vars: [String: String], home: String, cwd: inout String?) -> [String] {
        var words = all[...]
        let base = cwd
        var paths: [String] = []
        func add(_ word: String, in folder: String?) {
            if let word = expanded(word, vars: vars, home: home), let path = absolute(word, in: folder) { paths.append(path) }
        }
        while let word = words.first, shellKeywords.contains(word) || isAssignment(word) { words.removeFirst() }
        while let word = words.first, prefixes.contains(baseName(word)) {
            if word.contains("/") { add(word, in: base) }
            words.removeFirst()
            while let next = words.first, next.hasPrefix("-") || isAssignment(next) || isDuration(next) { words.removeFirst() }
        }
        guard let first = words.first else { return paths }
        let name = baseName(first)
        var args = Array(words.dropFirst())
        if name == "cd" || name == "pushd" {
            let target = args.first { !$0.hasPrefix("-") }
            cwd = target.flatMap { expanded($0, vars: vars, home: home) }.flatMap { absolute($0, in: base) }
            return paths
        }
        if first.contains("/") { add(first, in: base) }
        var folder = base
        if name == "source" || name == "." {
            if let script = args.first { add(script, in: base) }
            args.removeFirst(min(1, args.count))
        } else if shells.contains(name) {
            var index = 0
            while index < args.count, args[index].hasPrefix("-") || args[index].hasPrefix("+") {
                let flag = args[index]
                if flag == "--" {
                    index += 1
                    break
                }
                if flag == "--rcfile" || flag == "--init-file" {
                    if index + 1 < args.count { add(args[index + 1], in: base) }
                    index += 2
                } else if ["-o", "+o", "-O", "+O"].contains(flag) {
                    index += 2
                } else if !flag.hasPrefix("--"), flag.dropFirst().contains("c") {
                    // The string a `-c` is given is commands of its own, its flags before it included (`bash -c -x 'a'`).
                    guard let string = args[(index + 1)...].first(where: { !$0.hasPrefix("-") }) else { return paths }
                    return paths + namedPaths(string, vars: vars, home: home, base: base)
                } else {
                    index += 1
                }
            }
            if index < args.count {
                add(args[index], in: base)
                index += 1
            } else if let stdin {
                add(stdin, in: base)
            }
            args.removeFirst(min(index, args.count))
        } else if let reads = interpreter(named: name) {
            var index = 0
            var inline = false
            if name == "deno" || name == "bun", args.first == "run" { index = 1 }
            while index < args.count, args[index].hasPrefix("-") {
                let flag = args[index]
                let plain = flag.firstIndex(of: "=").map { String(flag[..<$0]) } ?? flag
                if reads.inline.contains(flag) {
                    inline = true
                    index += 1
                    break
                }
                if reads.code.contains(plain) {
                    if plain == flag, index + 1 < args.count {
                        add(args[index + 1], in: base)
                        index += 2
                    } else {
                        add(String(flag.dropFirst(plain.count + 1)), in: base)
                        index += 1
                    }
                } else if reads.value.contains(flag) {
                    index += 2
                } else {
                    index += 1
                }
            }
            if !inline, reads.firstArgumentIsScript {
                if index < args.count {
                    add(args[index], in: base)
                    index += 1
                } else if let stdin {
                    add(stdin, in: base)
                }
            }
            args.removeFirst(min(index, args.count))
        } else if name == "uv", let dir = uvDirectory(args) {
            folder = expanded(dir, vars: vars, home: home).flatMap { absolute($0, in: base) }
        }
        for arg in args {
            let value: String
            if arg.hasPrefix("-") {
                guard let equals = arg.firstIndex(of: "=") else { continue }
                value = String(arg[arg.index(after: equals)...])
            } else {
                value = arg
            }
            guard let word = expanded(value, vars: vars, home: home) else { continue }
            let isScript = scriptExtensions.contains((word as NSString).pathExtension)
            guard isScript || word.contains("/"), let path = absolute(word, in: folder) else { continue }
            if isScript || isExecutableFile(path) { paths.append(path) }
        }
        return paths
    }

    /// The folder `uv --directory` runs in (MCP servers' usual form).
    private static func uvDirectory(_ args: [String]) -> String? {
        if let index = args.firstIndex(of: "--directory"), index + 1 < args.count { return args[index + 1] }
        return args.first { $0.hasPrefix("--directory=") }.map { String($0.dropFirst("--directory=".count)) }
    }

    /// `word` with `vars` and a leading `~` put in; nil when something a shell would compute is left in it.
    private static func expanded(_ word: String, vars: [String: String], home: String) -> String? {
        var word = word
        for (name, value) in vars.sorted(by: { $0.key.count > $1.key.count }) {
            word = word.replacingOccurrences(of: "${\(name)}", with: value)
            word = word.replacingOccurrences(of: "$\(name)", with: value)
        }
        if word == "~" || word.hasPrefix("~/") { word = home + word.dropFirst() }
        guard !word.isEmpty, !word.hasPrefix("~"), !word.contains("$"), !word.contains("*"), !word.contains("?") else { return nil }
        return word
    }

    /// `word` as an absolute path, a relative one taken from `folder`; nil when there's no folder to take it from.
    private static func absolute(_ word: String, in folder: String?) -> String? {
        if word.hasPrefix("/") { return URL(fileURLWithPath: word).standardized.path }
        guard let folder else { return nil }
        return URL(fileURLWithPath: (folder as NSString).appendingPathComponent(word)).standardized.path
    }

    private static func baseName(_ word: String) -> String { (word as NSString).lastPathComponent }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        return !(name.first?.isNumber ?? true) && name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }

    /// A number a prefix takes (`timeout 10s`, `nice -n 5`).
    private static func isDuration(_ word: String) -> Bool {
        Double(word.last.map { "smhd".contains($0) } == true ? String(word.dropLast()) : word) != nil
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && (info.st_mode & 0o111) != 0
    }
}
