import Foundation
import Testing
@testable import VibeCore

/// The guard never lets through a line main's guard refused (the re-roll's contract for the-command-guard-fails): two
/// earlier attempts at refusing a program name the shell makes modelled `[[ … ]]` tests more cleverly than main and let
/// commands through that main refused (`[[ ( -z a )]] || git -C /tmp status`). Each line here goes through main's guard
/// as it was (`MainRefusedGit`, RefusedGitMainCopy.swift) and through `RefusedGit`: every line main refused is refused.
/// The lines: every string written in the guard's tests, generated lines that hide a refused command among tests,
/// quotes, parentheses and keywords, and every line of this repository's scripts and of the code in its docs, whose
/// newly refused lines are counted by shape (the cost a session pays). Lines are only read: nothing here runs them.
struct RefusedGitMonotonicTests {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The rules each role's hook reads lines with.
    static let rules = [LeadLaunch.gitRules(.worker, base: "main", records: "docs/lead"), LeadLaunch.gitRules(.lead), []]

    /// Lines main refused (for any role's rules) that `RefusedGit` lets through.
    static func loosened(_ lines: [String]) -> [String] {
        lines.filter { line in
            rules.contains { MainRefusedGit.refusal(in: line, rules: $0) != nil && RefusedGit.refusal(in: line, rules: $0) == nil }
        }
    }

    // MARK: The guard's own tests

    /// The files whose strings are read: the guard's tests (not main's copy).
    static let testFiles = ["RefusedGitCommandsTests", "RefusedGitFailsClosedTests", "RefusedGitSpellingsTests", "RefusedGitProgramNameTests",
                            "RefusedSecurityTests", "LeadGuardRailsTests", "GitGuardTests", "RefusedGitMonotonicTests"]

    /// Every string literal in Swift `source`, its escapes read (`\n`, `\"`, `\\`, `\u{…}`), an interpolation as `X`,
    /// a multi-line one without its indentation. Comments are skipped.
    static func literals(_ source: String) -> [String] {
        let chars = Array(source.unicodeScalars)
        var found: [String] = []
        var i = 0
        func at(_ j: Int) -> Unicode.Scalar? { j < chars.count ? chars[j] : nil }
        /// The escape at `i` (after its `\`), appended to `text`.
        func escape(_ text: inout String) {
            guard let c = at(i) else { return }
            switch c {
            case "n": text += "\n"; i += 1
            case "t": text += "\t"; i += 1
            case "r": text += "\r"; i += 1
            case "0": text += "\0"; i += 1
            case "u":
                var hex = ""
                i += 2
                while let d = at(i), d != "}" { hex.unicodeScalars.append(d); i += 1 }
                i += 1
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) { text.unicodeScalars.append(scalar) }
            case "(":
                var depth = 0
                repeat {
                    if at(i) == "(" { depth += 1 } else if at(i) == ")" { depth -= 1 }
                    i += 1
                } while depth > 0 && i < chars.count
                text += "X"
            default: text.unicodeScalars.append(c); i += 1
            }
        }
        while i < chars.count {
            let c = chars[i]
            if c == "/", at(i + 1) == "/" {
                while let d = at(i), d != "\n" { i += 1 }
            } else if c == "/", at(i + 1) == "*" {
                i += 2
                while i < chars.count, !(chars[i] == "*" && at(i + 1) == "/") { i += 1 }
                i += 2
            } else if c == "\"", at(i + 1) == "\"", at(i + 2) == "\"" {
                i += 3
                while let d = at(i), d != "\n" { i += 1 }
                i += 1
                var text = ""
                while i < chars.count, !(chars[i] == "\"" && at(i + 1) == "\"" && at(i + 2) == "\"") {
                    if chars[i] == "\\" {
                        i += 1
                        escape(&text)
                    } else {
                        text.unicodeScalars.append(chars[i])
                        i += 1
                    }
                }
                i += 3
                var lines = text.components(separatedBy: "\n")
                let indent = lines.last.map { $0.prefix { $0 == " " }.count } ?? 0
                lines = lines.dropLast().map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }
                found.append(lines.joined(separator: "\n"))
            } else if c == "\"" {
                i += 1
                var text = ""
                while let d = at(i), d != "\"", d != "\n" {
                    if d == "\\" {
                        i += 1
                        escape(&text)
                    } else {
                        text.unicodeScalars.append(d)
                        i += 1
                    }
                }
                i += 1
                found.append(text)
            } else {
                i += 1
            }
        }
        return found
    }

    @Test func theLiteralReaderReadsEscapesAndInterpolations() {
        #expect(Self.literals(#"let a = ["x\"y", "a\\b\nc", "\(z) q", "\u{41}"] // "not"#) == ["x\"y", "a\\b\nc", "X q", "A"])
        #expect(Self.literals("let b = \"\"\"\n    one\n      two\n    \"\"\"") == ["one\n  two"])
    }

    /// Every string in the guard's tests: what main refused, the branch refuses.
    @Test func noLineMainsGuardRefusedIsLetThrough() throws {
        var lines: [String] = []
        for name in Self.testFiles {
            let url = Self.repository.appendingPathComponent("Tests/VibeCoreTests/\(name).swift")
            lines += Self.literals(try String(contentsOf: url, encoding: .utf8))
        }
        lines += RefusedGitProgramNameTests.finding + RefusedGitProgramNameTests.audit + RefusedGitProgramNameTests.made
            + RefusedGitProgramNameTests.launchers + RefusedGitProgramNameTests.oddTests + RefusedGitProgramNameTests.everyday
        // Main refuses many of them: the property is checked, not empty.
        let refusedOnMain = lines.filter { MainRefusedGit.refusal(in: $0, rules: Self.rules[0]) != nil }
        #expect(lines.count > 2_000 && refusedOnMain.count > 400, "\(lines.count) lines, \(refusedOnMain.count) refused on main")
        #expect(Self.loosened(lines) == [])
    }

    // MARK: Generated lines

    /// SplitMix64: the same lines every run.
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Words a test, a quote, a parenthesis, a keyword or a `case` is made of, each closed (no open quote, no comment, no
    /// here-document): before a separator and a refused command, none of them stops the shell running the command
    /// (when the line parses at all).
    static let noise = ["[[", "]]", "\"[[\"", "\\[[", "'[['", "\"]]\"", "\\]]", ")]]", "]])", "(", ")", "((", "))", "( -z a )", "(a|b)",
                        "!", "if", "\"if\"", "then", "else", "while", "until", "do", "done", "fi", "{", "}", "-z", "-n", "a", "$x", "\"$y\"",
                        "==", "!=", "=~", "^(a|b)$", "^[0-9]+(\\.[0-9]+)?$", "*.md", "@(a|b)", "&&", "||", ";", "|", "&", "\n", "case",
                        "in", "esac", ";;", "a)", "x|y)", "$(true)", "`true`", "\"$(echo ]])\"", "< f", "> f", "2>&1", "x=1", "'q'", "\"q r\"",
                        "$((1))", "[", "]", "time", "env", "--", "\\(", "\\)", "=(", "a(", "]]x", "x]]", "[[x", "$'x'", "function", "f()",
                        "<(true)", "{a,b}", "~", "-e", "a=(x y)", "a=(", "\\\n"]
    static let separators = [" || ", " && ", "; ", " | ", " & ", "\n", " ||", "&&", ";", "|", " |& "]
    static let refused = ["git -C /tmp status", "setsid ls", "$EDITOR f", "/usr/bin/gi? push origin main", "script -q /dev/null security list-keychains"]
    /// Where the command goes after the separator: plainly, in a substitution, a subshell, a group, a test's substitution,
    /// behind a keyword.
    static let placings: [(String) -> String] = [
        { $0 }, { "echo $(\($0))" }, { "(\($0))" }, { "{ \($0); }" }, { "echo `\($0)`" }, { "[[ -n $(\($0)) ]]" }, { "if \($0); then :; fi" },
        { "while \($0); do :; done" }, { "! \($0)" }, { "x=\"$(\($0))\"" },
    ]
    /// What may follow it: none holds `]]`, which could close a test the noise opened and make the command its operand.
    static let suffixes = ["", "; :", " &", " # c", ")", " )", " x", "\n:", " ;;", "; done", " }"]

    static func generated(count: Int) -> [String] {
        var random = Generator(state: 0x5EED_2026_1126)
        return (0..<count).map { _ in
            var prefix = ""
            for _ in 0..<Int.random(in: 0...8, using: &random) {
                let word = noise.randomElement(using: &random)!
                prefix += prefix.isEmpty || Int.random(in: 0..<5, using: &random) == 0 ? word : " " + word
            }
            let command = placings.randomElement(using: &random)!(refused.randomElement(using: &random)!)
            return prefix + (prefix.isEmpty ? "" : separators.randomElement(using: &random)!) + command + suffixes.randomElement(using: &random)!
        }
    }

    /// A refused command after, inside and around test, quote, parenthesis and keyword noise: none is let through.
    @Test func aRefusedCommandAmongTestsQuotesAndKeywordsIsRefused() {
        let lines = Self.generated(count: 4_000)
        #expect(Set(lines).count > 3_500)
        let allowed = lines.filter { RefusedGit.refusal(in: $0) == nil }
        #expect(allowed.isEmpty, "\(allowed.count) let through, first: \(allowed.prefix(10).map { "\($0.debugDescription)" }.joined(separator: ", "))")
        #expect(Self.loosened(lines) == [])
    }

    // MARK: The cost: this repository's scripts and the code in its docs

    /// Every line of scripts/*.sh and scripts/lib, and of the fenced code in AGENTS.md and docs/guide, and each code
    /// block whole.
    static func repositoryLines() throws -> [(file: String, line: String)] {
        let manager = FileManager.default
        var lines: [(String, String)] = []
        let scripts = Self.repository.appendingPathComponent("scripts")
        var files = try manager.contentsOfDirectory(atPath: scripts.path).filter { $0.hasSuffix(".sh") }.map { "scripts/\($0)" }
        files += try manager.contentsOfDirectory(atPath: scripts.appendingPathComponent("lib").path).map { "scripts/lib/\($0)" }
        for file in files.sorted() {
            let text = try String(contentsOf: Self.repository.appendingPathComponent(file), encoding: .utf8)
            lines += text.components(separatedBy: "\n").map { (file, $0) }
        }
        let guide = Self.repository.appendingPathComponent("docs/guide")
        let docs = ["AGENTS.md"] + (try manager.contentsOfDirectory(atPath: guide.path)).filter { $0.hasSuffix(".md") }.map { "docs/guide/\($0)" }
        for file in docs.sorted() {
            let text = try String(contentsOf: Self.repository.appendingPathComponent(file), encoding: .utf8)
            var block: [String]?
            for line in text.components(separatedBy: "\n") {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    if let done = block { lines.append((file, done.joined(separator: "\n"))) }
                    block = block == nil ? [] : nil
                } else if block != nil {
                    block?.append(line)
                    lines.append((file, line))
                }
            }
        }
        return lines
    }

    /// What a newly refused line's refusal is: a program named by a variable, a substitution or braces; a `case`
    /// arm read out of its `case` (`*) exit 64 ;;`, a pattern as the program); another pattern (a glob, or a call in
    /// embedded perl, awk, python or C, `print(…)`, read as zsh's glob group); each on a line with a test or a case arm
    /// that isn't plain, or not; or a launcher.
    static func shape(_ refusal: RefusedGit.Refusal, line: String) -> String? {
        switch refusal {
        case .unreadable(.program(let word)), .unreadable(.test(let word)):
            let arm = line.range(of: #"^\s*\(?[^\s()=]+\)(\s|$)"#, options: .regularExpression) != nil
            let how = word.contains("$") || word.contains("`") || word.contains("{") ? "variable" : arm ? "case arm" : "pattern"
            if case .unreadable(.test) = refusal { return "\(how), odd test" }
            return how
        case .unreadable(.launcher): return "launcher"
        default: return nil
        }
    }

    /// The words of a plain `[[ … ]]` test in `line`, by a reading of its own, simpler than the scanner's: `[[` first
    /// (after keywords), a space-separated `]]` on the line, and nothing between them that is a parenthesis, a quote,
    /// a backslash, a `;` or a line break; nil without one.
    static func plainTest(_ line: String) -> [String]? {
        let words = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
        guard let open = words.firstIndex(of: "[["), words[..<open].allSatisfy({ ShellWords.opening.contains($0) }),
              let close = words[open...].firstIndex(where: { $0 == "]]" || $0 == "]];" }) else { return nil }
        let inside = Array(words[(open + 1)..<close])
        let text = inside.joined(separator: " ")
        return text.contains { "();\n\"'\\`".contains($0) } || text.contains("[[") || text.contains("]]") ? nil : inside
    }

    /// Every line of the scripts and of the docs' code, through both guards: nothing main refused is let through, no
    /// plain test is newly refused, and each newly refused line is a program named by a variable or a pattern (whole
    /// lines, and fragments of a statement or of embedded perl, awk or python read out of it), or a launcher.
    @Test func theRepositorysScriptsAndDocsCostWhatTheContractAllows() throws {
        let lines = try Self.repositoryLines()
        #expect(lines.count > 3_000)
        #expect(Self.loosened(lines.map(\.line)) == [])
        var newly: [(file: String, line: String, shape: String)] = []
        for (file, line) in lines where MainRefusedGit.refusal(in: line) == nil {
            guard let refusal = RefusedGit.refusal(in: line) else { continue }
            let shape = Self.shape(refusal, line: line)
            #expect(shape != nil, "\(file): \(line.debugDescription): \(refusal)")
            newly.append((file, line, shape ?? "?"))
        }
        // A plain test's words are never what's refused (what follows it may be: `[[ -z $x ]] || $EDITOR f`).
        for entry in newly {
            guard let test = Self.plainTest(entry.line), case .unreadable(let unread) = RefusedGit.refusal(in: entry.line) else { continue }
            switch unread {
            case .program(let word), .test(let word):
                #expect(!test.contains(word), "a plain test's word newly refused: \(entry.file): \(entry.line.debugDescription)")
            default: break
            }
        }
        // The report: how many, of what shape (printed for the record; the counts are what this commit found).
        var counts: [String: Int] = [:]
        for entry in newly { counts[entry.shape, default: 0] += 1 }
        print("RefusedGitMonotonicTests cost: \(lines.count) lines, \(newly.count) newly refused: "
              + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        for entry in newly { print("  newly refused [\(entry.shape)] \(entry.file): \(entry.line.debugDescription)") }
        // The commands the docs give (AGENTS.md, docs/guide) all still run.
        #expect(newly.filter { !$0.file.hasPrefix("scripts/") }.map(\.line) == [])
    }
}
