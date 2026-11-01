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
    /// The tool server's argument that makes it the verifier's `PermissionRequest` hook (see `hookAnswer`).
    public static let hookArgument = "--read-only-permission"

    /// Whether `line` runs without a prompt.
    public static func allows(_ line: String) -> Bool {
        guard let parts = parts(of: line), !parts.isEmpty else { return false }
        return parts.allSatisfy(allowsPart)
    }

    /// The hook's answer to Claude Code's `PermissionRequest` event (its JSON on stdin): allow a Bash call `allows`
    /// takes; nil otherwise (the hook prints nothing, and the prompt shows as before).
    public static func hookAnswer(_ input: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              object["tool_name"] as? String == "Bash",
              let command = (object["tool_input"] as? [String: Any])?["command"] as? String, allows(command) else { return nil }
        let answer: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]]
        return try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
    }

    // MARK: Parsing

    /// The line's commands, each as its words (quotes taken off), split at `;`, `&&`, `||`, `|` and newlines; nil
    /// when it holds anything else the shell would act on.
    static func parts(of line: String) -> [[String]]? {
        var parts: [[String]] = []
        var words: [String] = []
        var word: String?
        let chars = Array(line)
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

    // MARK: What each program may do

    /// The git commands that only read, with what each may take (`allowsGit`).
    static let gitReads: Set<String> = ["ls-files", "log", "show", "diff", "status", "rev-parse", "merge-base", "cat-file",
                                        "blame", "remote", "branch"]

    static func allowsPart(_ words: [String]) -> Bool {
        guard let program = words.first else { return false }
        let args = Array(words.dropFirst())
        switch program {
        case "git": return allowsGit(args)
        case "grep": return true
        case "wc", "head": return true
        case "rg":
            // Only flags known to read: others run programs (`--pre`, `--hostname-bin`, `-z`'s decompressors), and
            // ripgrep gains flags.
            return args.allSatisfy(allowsRipgrepArgument)
        case "tail":
            // Follows forever: a verifier's turn would never end.
            return !args.contains { long($0, ["--follow", "--retry"]) || shortFlags($0).contains { $0 == "f" || $0 == "F" } }
        case "sort":
            // `-o` writes a file; `--compress-program` runs one.
            return !args.contains { long($0, ["--output", "--compress-program", "--random-source"]) || shortFlags($0).contains("o") }
        default: return false
        }
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
        "--follow", "--type-list", "--no-messages", "--quiet", "--unrestricted", "--text", "--replace", "--passthru",
        "--max-filesize", "--engine", "--pcre2", "--crlf", "--null-data", "--byte-offset", "--no-config", "--",
    ]
    static let ripgrepShort = Set("niSsFwxlcuUgtTABCmdeovHINqLaRrj0123456789")

    static func allowsRipgrepArgument(_ arg: String) -> Bool {
        guard arg.hasPrefix("-"), arg != "-" else { return true }
        if arg.hasPrefix("--") { return ripgrepLong.contains(arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg) }
        return shortFlags(arg).allSatisfy(ripgrepShort.contains)
    }

    /// The letters of a short-flag word (`-rv` → "rv"); empty for anything else.
    private static func shortFlags(_ word: String) -> String {
        guard word.count > 1, word.hasPrefix("-"), !word.hasPrefix("--") else { return "" }
        return String(word.dropFirst())
    }

    static func allowsGit(_ args: [String]) -> Bool {
        var args = args[...]
        if args.first == "--no-pager" { args = args.dropFirst() }
        // Options before the command (`-C`, `-c`, `--git-dir`) aren't taken: they change what git reads or runs.
        guard let command = args.first, gitReads.contains(command) else { return false }
        let rest = Array(args.dropFirst())
        // Writes a file, or runs a program the repository's config names.
        if rest.contains(where: { long($0, ["--output", "--ext-diff", "--textconv", "--filters", "--exec", "--open-files-in-pager"]) }) {
            return false
        }
        switch command {
        case "remote":
            return rest.isEmpty || rest == ["-v"] || rest == ["--verbose"]
        case "branch":
            return allowsBranch(rest)
        default:
            return true
        }
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
