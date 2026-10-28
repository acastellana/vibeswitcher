import CryptoKit
import Foundation

/// A code block in a reply that's a shell command, as the prompt that runs it in the session (`! command`: Claude
/// Code runs it in its shell and the output joins the conversation).
///
/// Run must type only what the block shows: a block with characters you can't see (zero-width, bidi overrides,
/// escape sequences), lines past what's on screen, or a heredoc gets no Run at all; anything else that isn't plainly
/// harmless is shown in full to confirm first. A bash, sh, zsh or shell block whose lines mean something only together
/// (`if`/`fi`, `{ … }`, a quote across lines, a `;` at a line's end) isn't joined with `&&`: it runs as one script,
/// its text exactly as shown, from a private file (`Script`).
public enum RunnableCommand {
    static let shells: Set<String> = ["bash", "sh", "zsh", "shell", "console", "terminal"]

    public struct Runnable: Equatable, Sendable {
        /// Exactly what's typed into the session.
        public let prompt: String
        /// More than one line, or not plainly harmless: ask first, showing what runs: `prompt` as it is, or a
        /// script's text.
        public let needsConfirmation: Bool
        /// A block run as one script: `prompt` runs its file, which `Script.write` makes first.
        public var script: Script? = nil
    }

    /// A block run as one script: its text byte for byte, in a file only you can read under `folder`, run by `shell`
    /// and removed once it has run (the rest at the app's quit, `Script.removeAll`). The file is named after the text,
    /// so the Run button shown for a block always types the same prompt.
    public struct Script: Equatable, Sendable {
        public let text: String
        /// bash, sh or zsh: the block's language (bash for `shell`).
        public let shell: String
        public let file: URL

        /// The app's own: under VibeSwitcher's folder, private to you.
        public static var folder: URL { VibePaths.root.appendingPathComponent("run-blocks") }

        init(text: String, shell: String, folder: URL) {
            self.text = text
            self.shell = shell
            let digest = SHA256.hash(data: Data((shell + "\n" + text).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            file = folder.appendingPathComponent("block-\(digest).sh")
        }

        /// What's typed: the shell runs the file, then it's removed (also when the script exits early or fails).
        public var prompt: String {
            let path = Self.quoted(file.path)
            return "! \(shell) \(path); rm -f \(path)"
        }

        /// Writes the file (0600, its folder 0700) with the block's text exactly.
        public func write() throws {
            try VibePaths.ensurePrivate(file.deletingLastPathComponent())
            try VibePaths.writePrivate(Data(text.utf8), to: file)
        }

        /// Removes every script file in `folder`: at quit, and at launch for those a crash left.
        public static func removeAll(in folder: URL = Script.folder) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasPrefix("block-") || name.hasPrefix(".block-") {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }

        static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    }

    public static func prompt(code: String, language: String?, visibleLines: Int? = nil) -> String? {
        runnable(code: code, language: language, visibleLines: visibleLines)?.prompt
    }

    /// The shell a script block runs in, by its language.
    static let scriptShells: [String: String] = ["bash": "bash", "sh": "sh", "zsh": "zsh", "shell": "bash"]

    /// `visibleLines`: how many of the block's lines are on screen (nil: all of them). `scripts`: where a script's
    /// file goes.
    public static func runnable(code: String, language: String?, visibleLines: Int? = nil,
                                scripts: URL = Script.folder) -> Runnable? {
        let language = language?.lowercased()
        let raw = code.components(separatedBy: "\n")
        if let visibleLines, raw.dropFirst(visibleLines).contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return nil
        }
        guard !hasHiddenCharacters(code) else { return nil }
        let lines = raw.map { $0.trimmingCharacters(in: .whitespaces) }
        let first = lines.first { !$0.isEmpty } ?? ""
        let marked = first.hasPrefix("!") || first.hasPrefix("$ ")
        guard language.map(shells.contains) ?? false || (language == nil && marked) else { return nil }
        // A heredoc spans lines that mean something only together.
        guard !code.contains("<<") else { return nil }
        let console = language == "console" || language == "terminal"
        var commands: [String] = []
        var pending = ""
        var sourceLines = 0
        for line in lines {
            var command = line
            if console, pending.isEmpty {
                guard command.hasPrefix("$ ") else { continue }
            }
            for prompt in ["$ ", "% ", "!"] where command.hasPrefix(prompt) {
                command = String(command.dropFirst(prompt.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            if pending.isEmpty, command.isEmpty || command.hasPrefix("#") { continue }
            sourceLines += 1
            if command.hasSuffix("\\") {
                pending += String(command.dropLast()).trimmingCharacters(in: .whitespaces) + " "
                continue
            }
            commands.append(pending + command)
            pending = ""
        }
        if !pending.isEmpty { commands.append(pending.trimmingCharacters(in: .whitespaces)) }
        guard !commands.isEmpty else { return nil }
        guard commands.allSatisfy(readsAsTyped), commands.count == 1 || commands.allSatisfy(joinsCleanly) else {
            return script(code: code, lines: lines, sourceLines: sourceLines, language: language, folder: scripts)
        }
        let prompt = "! " + commands.joined(separator: " && ")
        return Runnable(prompt: prompt, needsConfirmation: sourceLines > 1 || !plainlyHarmless(commands[0]))
    }

    /// Several lines of a bash, sh, zsh or shell block that only mean something together, as one script; nil for one
    /// line, a block written as typed at a prompt (`$ `, `% `, `!`), or a long blank run that pushes the rest of a line
    /// out of sight.
    static func script(code: String, lines: [String], sourceLines: Int, language: String?, folder: URL) -> Runnable? {
        guard sourceLines > 1, let shell = language.flatMap({ scriptShells[$0] }) else { return nil }
        let content = lines.filter { !$0.isEmpty }
        guard !content.contains(where: { $0.hasPrefix("$ ") || $0.hasPrefix("% ") || $0.hasPrefix("!") }),
              !content.contains(where: { $0.contains(String(repeating: " ", count: 8)) || $0.contains("\t\t") })
        else { return nil }
        let script = Script(text: code, shell: shell, folder: folder)
        return Runnable(prompt: script.prompt, needsConfirmation: true, script: script)
    }

    // MARK: What's refused

    /// Characters that don't show, or change how what's around them shows: controls (escape sequences, carriage
    /// returns, backspaces), format characters (zero-width, bidi overrides and isolates, tags), separators other than
    /// a plain space, private-use and unassigned code points.
    static func hasHiddenCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            if scalar == "\n" || scalar == "\t" || scalar == " " { return false }
            switch scalar.properties.generalCategory {
            case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned,
                 .surrogate:
                return true
            default:
                // Variation selectors, the combining grapheme joiner and the blank-looking fillers draw nothing.
                return (0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value)
                    || [0x034F, 0x115F, 0x1160, 0x2800, 0x3164, 0xFFA0].contains(scalar.value)
            }
        }
    }

    /// One command as the shell will read it: quotes closed, and no long blank run that pushes the rest of the line
    /// out of sight.
    static func readsAsTyped(_ command: String) -> Bool {
        scan(command).balanced && !command.contains(String(repeating: " ", count: 8))
            && !command.contains(String(repeating: "\t", count: 2))
    }

    static let compoundStarts: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
                                               "case", "esac", "select", "function", "{", "}", "(", ")"]

    /// One of several lines: joined with `&&`, it still runs on its own. Not when a `#` comments out the lines
    /// after it, a line ends in `&`, `|`, `;` or opens a block, or it's part of `if`/`for`/`case` and the like.
    static func joinsCleanly(_ command: String) -> Bool {
        guard !scan(command).comment else { return false }
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, let last = words.last, !compoundStarts.contains(first),
              !compoundStarts.contains(last), !last.hasSuffix("()") else { return false }
        if let opener = command.first, "|&;)}".contains(opener) { return false }
        if let closer = command.last, "|&;({".contains(closer) { return false }
        return true
    }

    /// Whether quotes (and backticks) close on the line, and whether an unquoted `#` starts a comment in it.
    static func scan(_ line: String) -> (balanced: Bool, comment: Bool) {
        var quote: Character?
        var escaped = false
        var previous: Character = " "
        for character in line {
            defer { previous = character }
            if escaped { escaped = false; continue }
            if quote == "'" {
                if character == "'" { quote = nil }
                continue
            }
            if character == "\\" { escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "'", "\"", "`": quote = character
            case "#" where previous.isWhitespace: return (true, true)
            default: break
            }
        }
        return (quote == nil && !escaped, false)
    }

    // MARK: What runs without asking

    /// Programs that delete, overwrite, escalate, fetch or run other code: asked about even on one short line.
    static let riskyPrograms: Set<String> = [
        "rm", "rmdir", "mv", "cp", "dd", "mkfs", "diskutil", "sudo", "su", "doas", "chmod", "chown", "chgrp", "kill",
        "killall", "pkill", "shutdown", "reboot", "halt", "curl", "wget", "eval", "exec", "source", ".", "sh", "bash",
        "zsh", "fish", "python", "python3", "node", "ruby", "perl", "osascript", "launchctl", "defaults", "security",
        "ssh", "scp", "rsync", "env", "xargs", "nohup", "command", "builtin", "find", "truncate", "shred", "crontab",
    ]
    static let riskyGit: Set<String> = ["push", "reset", "clean", "checkout", "restore", "rebase", "branch", "tag",
                                        "stash", "rm", "mv", "filter-branch", "filter-repo", "gc", "prune", "worktree",
                                        "update-ref", "config", "switch", "merge", "cherry-pick", "revert", "commit"]

    /// One short line of plain ASCII words, no shell syntax (pipes, redirects, `;`, `&`, substitutions, globs,
    /// quotes), no force flags, and not a program on the risky list: `swift test`, `npm install`, `git status`.
    static func plainlyHarmless(_ command: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_./:=@%+,~^")
        guard command.count <= 80, !command.contains("   "),
              command.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        let words = command.split(separator: " ").map(String.init)
        guard let program = words.first.map({ ($0 as NSString).lastPathComponent }), !riskyPrograms.contains(program)
        else { return false }
        // Any risky word, not just the subcommand: `git -C <folder> push` puts a path first.
        if program == "git", words.dropFirst().contains(where: riskyGit.contains) { return false }
        return !words.contains { $0 == "--force" || $0.hasPrefix("--force-") || $0 == "--hard"
            || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("f")) }
    }
}
