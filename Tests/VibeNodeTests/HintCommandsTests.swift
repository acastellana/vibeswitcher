import Foundation
import Testing
@testable import VibeNode

/// Every command line the node prints as a hint parses with the command line's own parser (2026-11-24: `approve` told
/// the user "vibeswitcher hooks install --agent claude --agent codex", and running exactly that printed the usage).
///
/// The hints are read from the sources: a span in backticks starting `vibeswitcher ` or `vs `, and the end of a string
/// after ": ", "with ", "run " or "then ". Usage lines (with `[`, `|` or `...`) are the parsers' own and are left out.
/// Each interpolation and each upper-case placeholder (CARD, FOLDER, …) takes a sample value of its kind. A hint of
/// command words only (`vibeswitcher approve`, `vibeswitcher base accept`) names a command: its first word must be one
/// the command line dispatches. Any other is run, with a scratch home and node root where no server listens: the
/// parser runs first, so a usage refusal (exit 64, "usage:") is a hint the command line refuses; anything else (no
/// server) is a hint it parsed. Commands that work locally before they look for a server (`start`, `doctor`, `logs`,
/// the build's own tools) are never run here; their hints are checked by name only.
@Suite(.timeLimit(.minutes(5)))
struct HintCommandsTests {
    private let scratch = Scratch()
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Never run: each does something locally before it asks a server, or is a build tool.
    static let notRun: Set<String> = ["start", "doctor", "logs", "wire-vectors", "kinds-doc", "agent-plist", "install-record",
                                      "accepted-snapshot", "help", "update"]

    struct Hint: Hashable {
        var file: String
        var line: Int
        var text: String
    }

    /// The hints in the node's and the command line's sources.
    static func hints() throws -> [Hint] {
        let folders = ["Sources/VibeNode", "Sources/vibeswitcher-cli", "Sources/VibeCore/V2"].map { repo.appendingPathComponent($0) }
        var found: Set<Hint> = []
        let ticked = try NSRegularExpression(pattern: "`((?:vibeswitcher|vs) [^`]+)`")
        let ending = try NSRegularExpression(pattern: #"(?:: |\bwith |\brun |\bthen )((?:vibeswitcher|vs) [a-z][^"`”;(]*)""#)
        for folder in folders {
            let files = FileManager.default.enumerator(atPath: folder.path)?.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") } ?? []
            for file in files.sorted() {
                let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") { continue }
                    let range = NSRange(line.startIndex..., in: line)
                    for pattern in [ticked, ending] {
                        for match in pattern.matches(in: line, range: range) {
                            guard let span = Range(match.range(at: 1), in: line) else { continue }
                            found.insert(Hint(file: file, line: index + 1, text: String(line[span])))
                        }
                    }
                }
            }
        }
        return found.sorted { ($0.file, $0.line, $0.text) < ($1.file, $1.line, $1.text) }
    }

    /// The command words the command line dispatches (`main.swift`'s cases).
    static func commands() throws -> Set<String> {
        let main = try String(contentsOf: repo.appendingPathComponent("Sources/vibeswitcher-cli/main.swift"), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"^case ((?:"[a-z-]+"(?:, )?)+):"#, options: [.anchorsMatchLines])
        var words: Set<String> = []
        for match in pattern.matches(in: main, range: NSRange(main.startIndex..., in: main)) {
            guard let range = Range(match.range(at: 1), in: main) else { continue }
            for word in main[range].split(separator: ",") { words.insert(word.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))) }
        }
        return words
    }

    /// `text` with each interpolation and placeholder given a sample value; nil for a usage line.
    static func filled(_ text: String, folder: String) -> [String]? {
        guard !text.contains("["), !text.contains("|"), !text.contains("...") else { return nil }
        // Interpolations: the expression replaced by a value of the kind the word before it asks for; one glued to the
        // word before it (`held\(folder.map { " " + $0 } ?? "")`) is an optional tail, left out.
        var out = ""
        var rest = Substring(text)
        while let start = rest.range(of: "\\(") {
            out += rest[..<start.lowerBound]
            var depth = 1
            var index = start.upperBound
            while index < rest.endIndex, depth > 0 {
                if rest[index] == "(" { depth += 1 } else if rest[index] == ")" { depth -= 1 }
                index = rest.index(after: index)
            }
            let glued = out.last.map { $0 != " " } ?? false
            out += glued ? "" : "\u{1}"
            rest = rest[index...]
        }
        out += rest
        // A closing paren or a sentence's end that isn't the command's.
        while let last = out.last {
            if ".,: ".contains(last) || (last == ")" && out.filter({ $0 == ")" }).count > out.filter({ $0 == "(" }).count) {
                out.removeLast()
            } else {
                break
            }
        }
        var words = out.split(separator: " ").map(String.init)
        guard words.first == "vibeswitcher" || words.first == "vs" else { return nil }
        words.removeFirst()
        let samples: [String: String] = [
            "CARD": "abcd1234", "FOLDER": folder, "TEXT": "hello", "SESSION": "ttys001", "VALUE": "1", "CHOICE": "1", "NAME": "probe",
            "COMMIT": String(repeating: "a", count: 40), "N": "5", "PREFIX": folder, "LOCATION": folder, "PATH": folder, "FILE": folder,
            "KEY": "max_workers", "C": String(repeating: "a", count: 40), "F": folder, "M": "haiku", "WORDS": "word",
        ]
        for (index, word) in words.enumerated() {
            if let sample = samples[word] { words[index] = sample; continue }
            guard word == "\u{1}" else { continue }
            let before = index > 0 ? words[index - 1] : ""
            switch before {
            case "--agent": words[index] = "claude"
            case "switch": words[index] = String(repeating: "a", count: 40)
            case "answer", "accept", "keep", "hold": words[index] = "abcd1234"
            case "plugin": words[index] = "on"
            case "on", "off", "remove": words[index] = "probe"
            case "end", "send", "reply", "resume", "pause", "rename": words[index] = "ttys001"
            case "set" where index + 1 < words.count && words[index + 1] == "VALUE": words[index] = "max_workers"
            default: words[index] = folder
            }
        }
        return words
    }

    @Test(NodeTraits.linuxOnly) func everyHintTheNodePrintsParses() async throws {
        let hints = try Self.hints()
        let commands = try Self.commands()
        #expect(hints.count > 100, "the hints weren't found: \(hints.count)")
        let home = scratch.url("home")
        let root = scratch.url("root")
        let folder = scratch.url("project")
        for made in [home, root, folder] { try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true) }
        var environment = ProcessInfo.processInfo.environment
        for key in ["CLAUDE_CONFIG_DIR", "CODEX_HOME", PeerFacts.sessionMarkerName] { environment[key] = nil }
        environment["HOME"] = home.path
        environment["VIBESWITCHER_HOME"] = root.path
        environment["TMPDIR"] = scratch.url("tmp").path + "/"
        try FileManager.default.createDirectory(at: scratch.url("tmp"), withIntermediateDirectories: true)
        var ran: [[String]: Hint] = [:]
        for hint in hints {
            guard let words = Self.filled(hint.text, folder: folder.path), let command = words.first else { continue }
            #expect(commands.contains(command), "\(hint.file):\(hint.line): `\(hint.text)` names no command the command line has")
            // Command words only: a name, not a command line to run.
            let named = words.allSatisfy { $0.range(of: "^[a-z][a-z-]*$", options: .regularExpression) != nil } && words.count <= 2
            guard !named, !Self.notRun.contains(command), ran[words] == nil else { continue }
            ran[words] = hint
        }
        #expect(ran.count > 30, "too few hints with arguments: \(ran.keys.sorted { $0.joined() < $1.joined() })")
        for (words, hint) in ran.sorted(by: { $0.key.joined(separator: " ") < $1.key.joined(separator: " ") }) {
            let result = try await run(commandLine, words, environment: environment, limit: 30)
            let said = result.output + result.errors
            #expect(result.status != 64 && !said.contains("usage:"),
                    "\(hint.file):\(hint.line): `\(hint.text)` (run as `vibeswitcher \(words.joined(separator: " "))`) is refused by the command line: \(said)")
        }
    }

    /// The one that started it: the hooks' hint, in `status`'s notice and `approve`'s own line, is a command line the
    /// command line takes, and it is the plain form (every agent), as the user ran it; `--agent` once per agent parses too.
    @Test(NodeTraits.linuxOnly) func theHooksHintIsThePlainInstallAndParses() async throws {
        let notice = HooksLook.notice(reasons: ["x"], agents: [.claude, .codex])
        let command = try #require(notice.range(of: "vibeswitcher hooks install[a-z -]*", options: .regularExpression).map { String(notice[$0]) })
        #expect(command.trimmingCharacters(in: .whitespaces) == HooksRequest.installCommand, "\(notice)")
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = scratch.url("home").path
        environment["VIBESWITCHER_HOME"] = scratch.url("root").path
        for made in ["home", "root"] { try FileManager.default.createDirectory(at: scratch.url(made), withIntermediateDirectories: true) }
        for words in [Array(HooksRequest.installCommand.split(separator: " ").dropFirst().map(String.init)),
                      ["hooks", "install", "--agent", "claude", "--agent", "codex"]] {
            let parsed = try await run(commandLine, words, environment: environment, limit: 30)
            #expect(parsed.status != 64 && !(parsed.output + parsed.errors).contains("usage:"), "\(words): \(parsed)")
        }
        let refused = try await run(commandLine, ["hooks", "install", "--agent", "claude", "--agent"], environment: environment, limit: 30)
        #expect(refused.status == 64, "\(refused)")
    }
}
