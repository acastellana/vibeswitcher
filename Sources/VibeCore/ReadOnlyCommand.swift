import Foundation

/// The command lines a verifier (or an audit's finder) runs without a permission prompt: read-only git and
/// grep/rg/head/tail/wc/sort, alone or chained with `;`, `&&`, `||` and `|`, when every part is on the list. No one
/// answers a verifier's prompt (the user doesn't see its session, and the lead can't answer one): on 2026-10-31 and
/// 2026-11-01 two audits hung on prompts, the second for `git ls-files -s …; git remote -v; git branch -r | grep …;
/// grep … package-lock.json`, all read-only, and each could only be started again, the finders' work lost.
///
/// Fail closed: a line is allowed only when it parses cleanly here and each part is a listed program with arguments
/// that only read. Anything else (redirection to a file, `$…`, `$(…)`, backticks, subshells, `&`, an unknown flag such
/// as `git branch -D`, `git config`, a program not on the list) isn't allowed, and goes to the prompt as before (which
/// the witness declines when no one answers it: `LeadWitness.stuckPrompts`). The verifier's deny rules come first:
/// Claude Code asks its `PermissionRequest` hook (`hookArgument`) only about what they let through.
public enum ReadOnlyCommand {
    /// The tool server's argument that makes it a role's `PermissionRequest` hook (see `hookAnswer`), followed by
    /// `--root <worktree>` and, for a worker, `--worker`.
    public static let hookArgument = "--read-only-permission"
    public static let rootArgument = "--root"
    public static let workerArgument = "--worker"

    /// Where a line runs, and for whom. `root`: the worktree (or the lead's checkout) every path must stay in, symlinks
    /// resolved (`resolvesInside`); without one, a path is judged by its text alone (absolute, "~" and climbing out of
    /// where it starts are outside). `cwd`: where the session's shell is (the hook's event says), else `root`.
    /// `writes`: a worker's own commits (`git add`, `git rm`, `git commit -m`, `git apply` of a patch on its input).
    public struct Scope: Sendable {
        public var root: String?
        public var cwd: String?
        public var writes: Bool

        public init(root: String? = nil, cwd: String? = nil, writes: Bool = false) {
            self.root = root
            self.cwd = cwd
            self.writes = writes
        }
    }

    /// Whether `line` runs without a prompt.
    public static func allows(_ line: String, in scope: Scope = Scope()) -> Bool {
        guard let parts = parts(of: line), !parts.isEmpty else { return false }
        let confined = scope.root.flatMap { Confined(root: $0, cwd: scope.cwd) }
        if scope.root != nil, confined == nil { return false }  // a worktree that isn't there, or a shell outside it
        // A worker's `git apply` writes the tree, a symlink pointing anywhere included, after the paths here were
        // resolved: once, as the line's last part, so nothing in the line opens a path after it (`… | git apply &&
        // head link`, `… | git apply | sort - link`). What comes before it in its pipeline is done reading before it
        // has its whole patch.
        let applies = parts.indices.filter { parts[$0].count >= 2 && parts[$0][0] == "git" && parts[$0][1] == "apply" }
        guard applies.isEmpty || applies == [parts.count - 1] else { return false }
        return parts.allSatisfy { words in
            guard let checked = allowsPart(words, scope) else { return false }
            return !checked.contains { reachesOutside($0, confined) }
        }
    }

    /// Whether `word` (quotes and escapes taken off) could name a path outside the worktree: the hook mustn't open a
    /// way to read private files (~/.vibeswitcher/lead, the steer folder) without a prompt. "$HOME" anywhere; a short
    /// flag with a value attached that holds a "/" (`-f/etc/x`), or whose value, after any of its letters, is outside
    /// (`-finner`, a link out); and each piece of it (split at "=", ":" and ",", as in
    /// `--file=x`, `HEAD:x`) that starts with "~" or, as a path from the shell's folder, lands outside the worktree
    /// (`confined`; without one, by its text: absolute, or climbing above where it starts, `..`, `a/../..`). A pattern
    /// that looks like one still prompts: fail closed.
    static func reachesOutside(_ word: String, _ confined: Confined? = nil) -> Bool {
        if word.contains("$HOME") || word.contains("${HOME") { return true }
        if word.hasPrefix("-"), !word.hasPrefix("--"), word.contains("/") { return true }
        // A short flag's value attached after any of its letters (`-finner`, `-nfinner`, `-O..`), whichever letter takes
        // one: each rest of the word is a path the program may open, a link committed in the branch included.
        if word.hasPrefix("-"), !word.hasPrefix("--"), word.count > 2,
           (2..<word.count).contains(where: { reachesOutside(String(word.dropFirst($0)), confined) }) { return true }
        return word.split(omittingEmptySubsequences: false, whereSeparator: { "=:,".contains($0) }).contains { piece in
            if piece.hasPrefix("~") { return true }
            if let confined { return !piece.isEmpty && !confined.resolvesInside(String(piece)) }
            if piece.hasPrefix("/") { return true }
            var depth = 0
            for component in piece.split(separator: "/") where component != "." {
                depth += component == ".." ? -1 : 1
                if depth < 0 { return true }
            }
            return false
        }
    }

    /// A worktree and the shell's folder in it, for resolving a path the way the program will open it: component by
    /// component from the worktree, each symlink read (never followed) and its target walked in turn, so a link
    /// committed in the branch that points outside is seen. Nothing outside the worktree is looked at: a path written
    /// absolute must start with the worktree's path to be walked at all, and a walk that climbs above it, or reaches
    /// a link whose absolute target isn't under it, stops there as outside.
    struct Confined {
        /// The worktree as given and as `realpath` has it (/var → /private/var); `realRoot` is where walks start.
        let given: String
        let realRoot: String
        /// The shell's folder, as components under `realRoot`.
        private(set) var cwd: [String]

        init?(root: String, cwd: String?) {
            guard let real = realpath(root, nil) else { return nil }
            defer { free(real) }
            given = Self.trimmed(root)
            realRoot = Self.trimmed(String(cString: real))
            self.cwd = []
            guard let folder = cwd.map(Self.trimmed), let inside = walk(absolute: folder) else {
                if cwd != nil { return nil }
                return
            }
            self.cwd = inside
        }

        static func trimmed(_ path: String) -> String {
            var path = path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }

        /// Whether `path` (relative to the shell's folder, or absolute) resolves inside the worktree.
        func resolvesInside(_ path: String) -> Bool {
            path.hasPrefix("/") ? walk(absolute: path) != nil : walk(cwd + Self.components(path)) != nil
        }

        static func components(_ path: String) -> [String] { path.split(separator: "/").map(String.init) }

        /// An absolute path written under the worktree (as given or resolved), walked from it; nil for any other.
        func walk(absolute path: String) -> [String]? {
            for prefix in [given, realRoot] {
                if path == prefix { return walk([]) }
                if path.hasPrefix(prefix + "/") { return walk(Self.components(String(path.dropFirst(prefix.count + 1)))) }
            }
            return nil
        }

        /// The components under `realRoot` that `components` resolve to, or nil once they leave it.
        func walk(_ components: [String]) -> [String]? {
            var pending = components[...]
            var resolved: [String] = []
            var links = 0
            while let component = pending.popFirst() {
                if component.isEmpty || component == "." { continue }
                if component == ".." {
                    guard !resolved.isEmpty else { return nil }
                    resolved.removeLast()
                    continue
                }
                let candidate = ([realRoot] + resolved + [component]).joined(separator: "/")
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) else {
                    resolved.append(component)
                    continue
                }
                links += 1
                guard links <= 40 else { return nil }  // a loop
                if target.hasPrefix("/") {
                    let prefix = [given, realRoot].first { target == $0 || target.hasPrefix($0 + "/") }
                    guard let prefix else { return nil }
                    resolved = []
                    pending = (Self.components(String(target.dropFirst(prefix.count))) + pending)[...]
                } else {
                    pending = (Self.components(target) + pending)[...]
                }
            }
            return resolved
        }
    }

    /// The hook's answer to Claude Code's `PermissionRequest` event (its JSON on stdin, whose `cwd` is the shell's
    /// folder): allow a Bash call `allows` takes in the role's worktree `root`; nil otherwise (the hook prints nothing,
    /// and the prompt shows as before).
    public static func hookAnswer(_ input: Data, root: String? = nil, writes: Bool = false) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              object["tool_name"] as? String == "Bash",
              let command = (object["tool_input"] as? [String: Any])?["command"] as? String,
              allows(command, in: Scope(root: root, cwd: object["cwd"] as? String, writes: writes)) else { return nil }
        let answer: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]]
        return try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
    }

    /// The hook's command-line arguments after `hookArgument` (`--root <worktree>`, then `--worker` for a worker):
    /// nil for anything else, and the hook then allows nothing.
    public static func hookOptions(_ arguments: [String]) -> (root: String?, writes: Bool)? {
        switch arguments.count {
        case 0: return (nil, false)
        case 2 where arguments[0] == rootArgument: return (arguments[1], false)
        case 3 where arguments[0] == rootArgument && arguments[2] == workerArgument: return (arguments[1], true)
        default: return nil
        }
    }

    // MARK: Parsing

    /// The line's commands, each as its words (quotes taken off), split at `;`, `&&`, `||`, `|` and newlines; nil
    /// when it holds anything else the shell would act on.
    static func parts(of line: String) -> [[String]]? {
        // `Character` compares canonically: U+037E is `;` here and a word character to the shell. Nothing legitimate
        // holds one of these, so the line prompts.
        guard !line.unicodeScalars.contains(where: { !$0.isASCII && String($0).decomposedStringWithCanonicalMapping.utf8.allSatisfy { $0 < 0x80 } }) else {
            return nil
        }
        var parts: [[String]] = []
        var words: [String] = []
        var word: String?
        // One Character per code point, as the shell reads the line: a mark after a quote or an operator would otherwise
        // join it in one grapheme, a word character here and the same quote or operator to the shell.
        let chars = line.unicodeScalars.map(Character.init)
        var i = 0
        func endWord() {
            if let current = word { words.append(current) }
            word = nil
        }
        /// Ends a command at a separator: one with no words (`;;`, `| |`, a leading `&&`) isn't clean.
        func endPart() -> Bool {
            endWord()
            guard !words.isEmpty else { return false }
            parts.append(words)
            words = []
            return true
        }
        func boundary(_ index: Int) -> Bool { index >= chars.count || " \t\n;&|".contains(chars[index]) }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ", "\t":
                endWord()
            case "\n", ";":
                guard endPart() else { return nil }
            case "&":
                // `&&`; a lone `&` runs in the background.
                guard i + 1 < chars.count, chars[i + 1] == "&", endPart() else { return nil }
                i += 1
            case "|":
                guard i + 1 < chars.count, chars[i + 1] != "&", endPart() else { return nil }
                if chars[i + 1] == "|" { i += 1 }
            case "'":
                guard let close = chars[(i + 1)...].firstIndex(of: "'") else { return nil }
                word = (word ?? "") + String(chars[(i + 1)..<close])
                i = close
            case "\"" where hereDocument(chars, at: i) != nil:
                // `"$(cat <<'EOF'` … `EOF` `)"`: a commit message, as literal as a single-quoted word.
                let (text, end) = hereDocument(chars, at: i)!
                word = (word ?? "") + text
                i = end
            case "\"":
                // Taken as written only when nothing in it expands or escapes.
                guard let close = chars[(i + 1)...].firstIndex(of: "\"") else { return nil }
                let inner = chars[(i + 1)..<close]
                guard !inner.contains(where: { "$`\\!".contains($0) }) else { return nil }
                word = (word ?? "") + String(inner)
                i = close
            case "\\":
                guard i + 1 < chars.count, chars[i + 1] != "\n" else { return nil }
                word = (word ?? "") + String(chars[i + 1])
                i += 1
            case ">":
                // Only to /dev/null, or from one output to the other (`2>&1`, `>&2`): never to a file.
                if let fd = word {
                    guard !fd.isEmpty, fd.allSatisfy({ $0 == "1" || $0 == "2" }), fd.count == 1 else { return nil }
                    word = nil
                }
                i += 1
                if i < chars.count, chars[i] == "&" {
                    guard i + 1 < chars.count, chars[i + 1] == "1" || chars[i + 1] == "2", boundary(i + 2) else { return nil }
                    i += 2
                    continue
                }
                while i < chars.count, chars[i] == " " { i += 1 }
                var target = ""
                while !boundary(i) {
                    target.append(chars[i])
                    i += 1
                }
                guard target == "/dev/null" else { return nil }
                continue
            case "$", "`", "(", ")", "<", "#", "!", "*", "?", "[", "{", "}":
                // Expansions, substitutions, subshells, input redirection and here-docs, comments, negation, globs (a
                // file the branch names `--output=x` would be an argument: quote a pattern for grep or rg) and braces
                // (`--{output=f,stat}` is `--output=f --stat` once the shell expands it).
                return nil
            default:
                guard !c.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
                word = (word ?? "") + String(c)
            }
            i += 1
        }
        endWord()
        if !words.isEmpty { parts.append(words) } else if !parts.isEmpty { return nil }  // `git log |`, `git log &&`
        return parts
    }

    /// A double-quoted here-document read by `cat` at `start` (the opening `"`), the way Claude Code writes a commit
    /// message: `"$(cat <<'EOF'`, a newline, the text, a line `EOF`, then `)"` at once. Its delimiter is quoted, so
    /// nothing in the text expands: the word is the text, its trailing newlines dropped as `$(…)` drops them. Returns the
    /// text and the index of the closing `"`; nil for any other shape (an unquoted delimiter, anything after it on its
    /// line, anything but `)"` after the closing line), which the caller then refuses.
    static func hereDocument(_ chars: [Character], at start: Int) -> (String, Int)? {
        let opening = Array("\"$(cat <<'")
        guard start + opening.count <= chars.count, Array(chars[start..<(start + opening.count)]) == opening else { return nil }
        var i = start + opening.count
        var delimiter = ""
        while i < chars.count, chars[i].isASCII, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
            delimiter.append(chars[i])
            i += 1
        }
        guard !delimiter.isEmpty, i + 1 < chars.count, chars[i] == "'", chars[i + 1] == "\n" else { return nil }
        i += 2
        var lines: [String] = []
        var line = ""
        while i < chars.count {
            if chars[i] == "\n" {
                if line == delimiter {
                    // The line before was the last of the text; `)"` must follow.
                    guard i + 2 < chars.count, chars[i + 1] == ")", chars[i + 2] == "\"" else { return nil }
                    var text = lines.joined(separator: "\n")
                    while text.hasSuffix("\n") { text.removeLast() }
                    return (text, i + 2)
                }
                lines.append(line)
                line = ""
            } else {
                line.append(chars[i])
            }
            i += 1
        }
        return nil
    }

    // MARK: What each program may do

    /// The git commands that only read, with what each may take (`allowsGit`).
    static let gitReads: Set<String> = ["ls-files", "log", "show", "diff", "status", "rev-parse", "merge-base", "cat-file",
                                        "blame", "remote", "branch", "grep", "merge-tree", "ls-tree", "rev-list", "diff-tree",
                                        "check-ignore", "stash"]

    /// The words of `words` (a command) that the path check reads, when the command is on the list for `scope`: all
    /// its arguments, but a commit's message (text, not a path); nil when it isn't on the list.
    static func allowsPart(_ words: [String], _ scope: Scope = Scope()) -> [String]? {
        guard let program = words.first else { return nil }
        let args = Array(words.dropFirst())
        let allowed: Bool
        switch program {
        case "git": return allowsGit(args, writes: scope.writes)
        case "grep":
            // Not into the symlinks it meets on the way (`-R`, `--dereference-recursive`; BSD grep's `-S` and `-O`):
            // a link the branch commits could point outside, where the path check doesn't look.
            allowed = !args.contains { long($0, ["--dereference-recursive"]) || shortFlags($0).contains { "RSO".contains($0) } }
        case "wc", "head": allowed = true
        case "rg":
            // Only flags known to read: others run programs (`--pre`, `--hostname-bin`, `-z`'s decompressors), and
            // ripgrep gains flags. `--follow` (`-L`) isn't one: it goes into symlinks, as grep's `-R` does.
            allowed = args.allSatisfy(allowsRipgrepArgument)
        case "tail":
            // Follows forever: a verifier's turn would never end.
            allowed = !args.contains { long($0, ["--follow", "--retry"]) || shortFlags($0).contains { $0 == "f" || $0 == "F" } }
        case "sort":
            // Only flags known to read: `-o` writes a file, `-T` (`--temporary-directory`) writes into a directory,
            // `--compress-program` runs a program, and getopt takes abbreviations (`--tem=x`).
            allowed = allowsSort(args)
        default: allowed = false
        }
        return allowed ? args : nil
    }

    /// `arg` is one of the long options `names`, or could be read as one: git and getopt_long take any unambiguous
    /// start of a long option (`--outp=f` is `--output=f`), so any start counts, as does a
    /// longer option that starts with one (`--output-directory`).
    static func long(_ arg: String, _ names: [String]) -> Bool {
        guard arg.hasPrefix("--") else { return false }
        let name = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
        guard name.count > 2 else { return false }
        return names.contains { $0.hasPrefix(name) || name.hasPrefix($0) }
    }

    /// ripgrep's flags that only read (it takes no abbreviations), its short ones as letters (`-C3`, `-uu` too);
    /// any word that isn't a flag (a pattern, a path, a flag's value) is taken.
    static let ripgrepLong: Set<String> = [
        "--line-number", "--no-line-number", "--ignore-case", "--smart-case", "--case-sensitive", "--fixed-strings",
        "--word-regexp", "--line-regexp", "--files-with-matches", "--files-without-match", "--count", "--count-matches",
        "--hidden", "--no-ignore", "--no-ignore-vcs", "--no-ignore-parent", "--glob", "--iglob", "--type", "--type-not",
        "--files", "--context", "--before-context", "--after-context", "--max-count", "--max-depth", "--multiline",
        "--json", "--heading", "--no-heading", "--with-filename", "--no-filename", "--only-matching", "--invert-match",
        "--regexp", "--sort", "--sortr", "--color", "--column", "--vimgrep", "--trim", "--max-columns", "--null", "--stats",
        "--type-list", "--no-messages", "--quiet", "--unrestricted", "--text", "--replace", "--passthru",
        "--max-filesize", "--engine", "--pcre2", "--crlf", "--null-data", "--byte-offset", "--no-config", "--",
    ]
    static let ripgrepShort = Set("niSsFwxlcuUgtTABCmdeovHINqaRrj" + "0123456789")  // no L (`--follow`)

    static func allowsRipgrepArgument(_ arg: String) -> Bool {
        guard arg.hasPrefix("-"), arg != "-" else { return true }
        if arg.hasPrefix("--") { return ripgrepLong.contains(arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg) }
        return shortFlags(arg).allSatisfy(ripgrepShort.contains)
    }

    /// sort's flags that only read, taken exactly (an abbreviation still prompts); `-k` and `-t` (`--key`,
    /// `--field-separator`) take a value, the rest of their word or the next one, as getopt does: a next word that
    /// starts with "-" still prompts (getopt takes it as the value; a sort that didn't would take it as a flag).
    static let sortLong: Set<String> = [
        "--ignore-leading-blanks", "--dictionary-order", "--ignore-case", "--general-numeric-sort", "--ignore-nonprinting",
        "--month-sort", "--human-numeric-sort", "--numeric-sort", "--random-sort", "--reverse", "--version-sort", "--check",
        "--merge", "--stable", "--unique", "--zero-terminated",
    ]
    static let sortValuedLong: Set<String> = ["--key", "--field-separator"]
    static let sortShort = Set("bdfgiMhnRrVcCmsuz")
    static let sortValuedShort = Set("kt")

    static func allowsSort(_ args: [String]) -> Bool {
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if arg == "--" { return true }  // files only after it
            guard arg.hasPrefix("-"), arg != "-" else { continue }  // a file, or stdin
            if arg.hasPrefix("--") {
                let name = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
                if sortLong.contains(arg) || (name == "--sort" && arg.hasPrefix("--sort=")) { continue }
                guard sortValuedLong.contains(name) else { return false }
                if name == arg {  // its value is the next word
                    guard index < args.count, !args[index].hasPrefix("-") else { return false }
                    index += 1
                }
                continue
            }
            for (offset, letter) in arg.dropFirst().enumerated() {
                if sortValuedShort.contains(letter) {
                    if offset == arg.count - 2 {  // nothing after it in this word: the next word
                        guard index < args.count, !args[index].hasPrefix("-") else { return false }
                        index += 1
                    }
                    break
                }
                guard sortShort.contains(letter) else { return false }
            }
        }
        return true
    }

    /// The letters of a short-flag word (`-rv` → "rv"); empty for anything else.
    private static func shortFlags(_ word: String) -> String {
        guard word.count > 1, word.hasPrefix("-"), !word.hasPrefix("--") else { return "" }
        return String(word.dropFirst())
    }

    /// The words of a git command line (after `git`) for the path check, when it's on the list: a read in `gitReads`
    /// (`merge-tree`'s trial merges among them), or for a worker (`writes`) `add`, `rm`, `commit` and `apply` of a patch
    /// on its input; nil otherwise. Nothing before
    /// the command (`-C`, `-c`, `--git-dir`, `-P`, `--no-pager`, `--literal-pathspecs`): global options change what git
    /// reads or runs. Each command takes only the flags its `GitOptions` know, spelled out: git takes any unambiguous
    /// start of a long option (`--no-ind`), so an abbreviation, like any flag not listed (`--no-index`, `--stdin`,
    /// `--pathspec-from-file`, `--output`, `--ext-diff`, `--textconv`, blame's `--contents`, commit's `--template` and
    /// `--file`, rev-parse's `--parseopt`), prompts.
    static func allowsGit(_ args: [String], writes: Bool = false) -> [String]? {
        guard let command = args.first else { return nil }
        let rest = Array(args.dropFirst())
        switch command {
        case "remote":
            return rest.isEmpty || rest == ["-v"] || rest == ["--verbose"] ? rest : nil
        case "branch":
            return allowsBranch(rest) ? rest : nil
        case "merge-tree":
            return allowsMergeTree(rest) ? rest : nil
        case "stash":
            // Listing only: every other `git stash` changes the worktree or the stash.
            return rest == ["list"] ? rest : nil
        case "commit" where writes:
            return GitOptions.commit.messages(rest, message: ("--message", "m")).map { messages in rest.indices.filter { !messages.contains($0) }.map { rest[$0] } }
        case "apply" where writes:
            // `git diff <commit> HEAD -- <files> | git apply -R`: the patch from git on its input, into the worktree (git
            // apply refuses a path outside it, or beyond a symlink, without `--unsafe-paths`); `--check` only tries it.
            // No patch file, `--directory`, `--include`/`--exclude` or any other flag.
            return Set(rest).count == rest.count && rest.allSatisfy({ $0 == "-R" || $0 == "--check" }) ? rest : nil
        case "add" where writes, "rm" where writes:
            return GitOptions.writes[command]!.allows(rest) ? rest : nil
        default:
            guard let options = GitOptions.reads[command], options.allows(rest) else { return nil }
            return rest
        }
    }

    /// The flags a git command takes without a prompt, spelled out (no abbreviation), each long one in `long` (a flag),
    /// `valued` (`--x=v`, or `--x v`) or `optional` (`--x`, or `--x=v`); the short ones as letters, bundled or not:
    /// `letters` alone, `valuedLetters` with a value (the rest of the word, or the next word), `optionalLetters` with
    /// the rest of the word as an optional value (`-M50%`, `-U3`, `-uno`); `-5` when `counts`. Every other word (a
    /// revision, a path) is taken, and the path check reads it; so does every value. A next word taken as a value that
    /// starts with "-" prompts: git would take it as the value, a check that didn't would take it as a flag.
    struct GitOptions {
        var long: Set<String> = []
        var valued: Set<String> = []
        var optional: Set<String> = []
        var letters = ""
        var valuedLetters = ""
        var optionalLetters = ""
        var counts = false

        func allows(_ args: [String]) -> Bool { messages(args, message: nil) != nil }

        /// The indices of `args` that are values of `message` flags (commit's `-m`), when every word is taken; nil
        /// when one isn't.
        func messages(_ args: [String], message: (long: String, letter: Character)? = nil) -> Set<Int>? {
            var values = Set<Int>()
            var index = 0
            /// Takes the next word as the value of the flag at `index - 1`.
            func nextValue() -> Bool {
                guard index < args.count, !args[index].hasPrefix("-") else { return false }
                index += 1
                return true
            }
            while index < args.count {
                let arg = args[index]
                index += 1
                if arg == "--" { return values }  // paths only after it
                guard arg.hasPrefix("-"), arg != "-" else { continue }
                if arg.hasPrefix("--") {
                    let name = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
                    let attached = name != arg
                    if let message, name == message.long {
                        if !attached {
                            guard index < args.count else { return nil }
                            values.insert(index)
                            index += 1
                        } else {
                            values.insert(index - 1)
                        }
                        continue
                    }
                    if long.contains(arg) || optional.contains(name) { continue }
                    guard valued.contains(name) else { return nil }
                    if !attached, !nextValue() { return nil }
                    continue
                }
                let flags = Array(arg.dropFirst())
                if counts, flags.allSatisfy(\.isNumber) { continue }
                for (offset, letter) in flags.enumerated() {
                    let last = offset == flags.count - 1
                    if let message, letter == message.letter {
                        if last {
                            guard index < args.count else { return nil }
                            values.insert(index)
                            index += 1
                        } else {
                            values.insert(index - 1)
                        }
                        break
                    }
                    if optionalLetters.contains(letter) { break }
                    if valuedLetters.contains(letter) {
                        if last, !nextValue() { return nil }
                        break
                    }
                    guard letters.contains(letter) else { return nil }
                }
            }
            return values
        }

        /// log, show and diff: their output and revision flags (no `--output`, `--ext-diff`, `--textconv`,
        /// `--no-index`, `--stdin` or `--pathspec-from-file`).
        static let history = GitOptions(
            long: ["--stat", "--shortstat", "--numstat", "--name-only", "--name-status", "--summary", "--patch", "--no-patch",
                   "--raw", "--patch-with-stat", "--patch-with-raw", "--cached", "--staged", "--merge-base", "--oneline",
                   "--graph", "--all", "--no-decorate", "--reverse", "--first-parent", "--no-merges", "--merges", "--follow",
                   "--full-diff", "--left-right", "--cherry-pick", "--cherry-mark", "--cherry", "--boundary", "--date-order",
                   "--topo-order", "--author-date-order", "--abbrev-commit", "--no-abbrev-commit", "--full-history",
                   "--simplify-merges", "--ancestry-path", "--source", "--ignore-all-space", "--ignore-space-change",
                   "--ignore-space-at-eol", "--ignore-blank-lines", "--ignore-cr-at-eol", "--minimal", "--patience",
                   "--histogram", "--color-words", "--no-color", "--text", "--binary", "--full-index", "--no-renames",
                   "--check", "--exit-code", "--quiet", "--no-relative", "--function-context", "--compact-summary",
                   "--no-ext-diff", "--no-textconv", "--no-notes", "--cc", "--irreversible-delete", "--regexp-ignore-case",
                   "--extended-regexp", "--fixed-strings", "--perl-regexp", "--all-match", "--invert-grep", "--no-walk",
                   "--do-walk", "--root", "--parents", "--children", "--show-pulls", "--no-expand-tabs", "--branches",
                   "--tags", "--remotes", "--use-mailmap", "--no-prefix", "--name-rev", "--no-abbrev", "--remerge-diff",
                   "--dense", "--sparse", "--simplify-by-decoration", "--show-linear-break", "--walk-reflogs", "--not"],
            valued: ["--format", "--pretty", "--date", "--since", "--after", "--until", "--before", "--author", "--committer",
                     "--grep", "--max-count", "--skip", "--diff-filter", "--word-diff-regex", "--diff-algorithm",
                     "--inter-hunk-context", "--stat-width", "--stat-name-width", "--stat-count", "--min-parents",
                     "--max-parents", "--encoding", "--diff-merges", "--anchored", "--line-prefix", "--src-prefix",
                     "--dst-prefix", "--exclude", "--rotate-to", "--skip-to", "--unified", "--max-age", "--min-age"],
            optional: ["--decorate", "--color", "--word-diff", "--relative", "--find-renames", "--find-copies", "--dirstat",
                       "--abbrev", "--stat", "--expand-tabs", "--color-moved", "--submodule", "--ws-error-highlight",
                       "--branches", "--tags", "--remotes", "--glob", "--notes", "--show-notes"],
            letters: "puszwbRaWDiEFmctrg", valuedLetters: "nSGLO", optionalLetters: "MCBUl", counts: true)

        /// `history` and one flag more: rev-list's `--count`, diff-tree's `--no-commit-id`.
        func with(_ flag: String) -> GitOptions {
            var options = self
            options.long.insert(flag)
            return options
        }

        static let reads: [String: GitOptions] = [
            "log": history, "show": history, "diff": history,
            "rev-list": history.with("--count"), "diff-tree": history.with("--no-commit-id"),
            // Its search flags: no `--open-files-in-pager` (`-O`, which runs a pager), `--no-index` or `--untracked`
            // (files git doesn't track), `--textconv` (a program), `--recurse-submodules` or `--threads`, and no `-f`
            // (patterns from a file): git opens it from the top of the work tree, not the shell's folder the path check
            // judges it from (`git grep -f ../x` in a subfolder reads outside), and `-f -` reads its input. A pattern is
            // a word like any other, so the path check reads it: one that looks like a path outside still prompts.
            "grep": GitOptions(
                long: ["--cached", "--exclude-standard", "--invert-match", "--ignore-case", "--word-regexp", "--text",
                       "--recursive", "--extended-regexp", "--basic-regexp", "--fixed-strings", "--perl-regexp",
                       "--line-number", "--column", "--full-name", "--files-with-matches", "--name-only",
                       "--files-without-match", "--null", "--only-matching", "--count", "--no-color", "--break", "--heading",
                       "--show-function", "--function-context", "--and", "--or", "--not", "--quiet", "--all-match"],
                valued: ["--max-depth", "--context", "--before-context", "--after-context", "--max-count"],
                optional: ["--color"],
                letters: "viwaIrEGFPnhHlLzocpWq", valuedLetters: "CBAme", counts: true),
            // No `--full-tree`: its paths are from the top of the work tree, not the shell's folder.
            "ls-tree": GitOptions(
                long: ["--long", "--name-only", "--name-status", "--object-only", "--full-name"],
                valued: ["--format"], optional: ["--abbrev"], letters: "drtlz"),
            "check-ignore": GitOptions(long: ["--quiet", "--verbose", "--non-matching"], letters: "qvnz"),
            "status": GitOptions(
                long: ["--short", "--branch", "--porcelain", "--long", "--verbose", "--show-stash", "--ahead-behind",
                       "--no-ahead-behind", "--renames", "--no-renames", "--no-column"],
                optional: ["--porcelain", "--untracked-files", "--ignored", "--ignore-submodules", "--column", "--find-renames"],
                letters: "sbvz", optionalLetters: "u"),
            "ls-files": GitOptions(
                long: ["--stage", "--cached", "--deleted", "--modified", "--others", "--ignored", "--exclude-standard",
                       "--directory", "--no-empty-directory", "--error-unmatch", "--full-name", "--killed", "--unmerged",
                       "--eol", "--deduplicate", "--sparse", "--recurse-submodules"],
                valued: ["--exclude", "--exclude-per-directory", "--format"], optional: ["--abbrev"],
                letters: "scdmoiztvuk", valuedLetters: "x"),
            "rev-parse": GitOptions(
                long: ["--verify", "--quiet", "--show-toplevel", "--show-prefix", "--show-cdup", "--git-dir", "--git-common-dir",
                       "--absolute-git-dir", "--is-inside-work-tree", "--is-inside-git-dir", "--is-bare-repository",
                       "--is-shallow-repository", "--symbolic", "--symbolic-full-name", "--all", "--head",
                       "--show-object-format", "--not", "--revs-only", "--no-revs", "--flags", "--no-flags"],
                optional: ["--abbrev-ref", "--short", "--branches", "--tags", "--remotes"], letters: "q"),
            "merge-base": GitOptions(long: ["--is-ancestor", "--all", "--octopus", "--independent", "--fork-point"], letters: "a"),
            "cat-file": GitOptions(long: [], letters: "ptse"),
            "blame": GitOptions(
                long: ["--porcelain", "--line-porcelain", "--root", "--show-stats", "--incremental", "--first-parent",
                       "--show-email", "--show-name", "--show-number", "--color-lines", "--color-by-age", "--minimal",
                       "--reverse", "--progress", "--no-progress", "--score-debug"],
                valued: ["--date", "--since"], optional: ["--abbrev"],
                letters: "wesltfnpcbk", valuedLetters: "L", optionalLetters: "MC"),
        ]

        /// A worker's own changes: staging and unstaging the files of its worktree.
        static let writes: [String: GitOptions] = [
            "add": GitOptions(long: ["--all", "--update", "--intent-to-add", "--verbose", "--dry-run", "--force", "--no-all",
                                     "--ignore-removal", "--renormalize"],
                              letters: "AuNvnf"),
            "rm": GitOptions(long: ["--cached", "--force", "--quiet", "--dry-run", "--ignore-unmatch"], letters: "rfqn"),
        ]

        /// git commit with a message on the command line (`-m`, `--message`), or none (the commit that ends a merge
        /// keeps its own): no `--file`, `--template` or `--reuse-message`.
        static let commit = GitOptions(long: ["--all", "--quiet", "--allow-empty", "--allow-empty-message", "--no-edit",
                                              "--signoff", "--no-verify", "--verbose"],
                                       letters: "aqsnv")
    }

    /// `git merge-tree`'s two trial merges, which move no ref and touch no file: `--write-tree` (the default with two
    /// commits) writes the merged tree's objects, unreferenced, and prints its id and any conflicts; `--trivial-merge`
    /// (the default with three) only prints. Their flags only, spelled out; no `--stdin` (a merge per line of input),
    /// no strategy options, and exactly the commits each form takes.
    static func allowsMergeTree(_ args: [String]) -> Bool {
        let realFlags: Set<String> = ["--messages", "--no-messages", "--name-only", "--allow-unrelated-histories", "-z"]
        var commits = 0
        var write = false, trivial = false, realOnly = false
        for arg in args {
            switch arg {
            case "--write-tree": write = true
            case "--trivial-merge": trivial = true
            case _ where realFlags.contains(arg): realOnly = true
            case _ where arg.hasPrefix("--merge-base=") && arg.count > "--merge-base=".count: realOnly = true
            case _ where arg.hasPrefix("-"): return false  // `--stdin`, `-X`, an abbreviation, `--`, a bundle
            default: commits += 1
            }
        }
        if trivial || (!write && !realOnly && commits == 3) { return !write && !realOnly && commits == 3 }
        return commits == 2
    }

    /// `git branch` listing only: its listing flags, and names only after `--list` or as the value of a filter
    /// (`--contains X`). `git branch foo` makes a branch; `-D`, `-m`, `-f`, `-u`, `--edit-description` and the rest
    /// aren't listing flags.
    static func allowsBranch(_ args: [String]) -> Bool {
        let flags: Set<String> = ["--remotes", "--all", "--verbose", "--list", "--show-current", "--no-color", "--color",
                                  "--no-column", "--column", "--ignore-case", "--omit-empty"]
        let valued: Set<String> = ["--contains", "--no-contains", "--merged", "--no-merged", "--points-at"]
        let prefixed = ["--sort=", "--format=", "--color=", "--column=", "--abbrev="] + valued.map { $0 + "=" }
        var listing = false
        var names = 0
        var index = 0
        while index < args.count {
            let arg = args[index]
            if flags.contains(arg) || prefixed.contains(where: arg.hasPrefix) {
                if arg == "--list" { listing = true }
            } else if valued.contains(arg) {
                // Its value is the next word (a commit, as git takes it): a word that's a flag stays a flag.
                if index + 1 < args.count, !args[index + 1].hasPrefix("-") { index += 1 }
            } else if !shortFlags(arg).isEmpty {
                guard shortFlags(arg).allSatisfy({ "ravl".contains($0) }) else { return false }
                if shortFlags(arg).contains("l") { listing = true }
            } else if arg.hasPrefix("-") {
                return false
            } else {
                names += 1
            }
            index += 1
        }
        return names == 0 || listing
    }
}
