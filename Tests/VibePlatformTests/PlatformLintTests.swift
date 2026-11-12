import Foundation
import Testing

/// Outside the platform layer, no file of the targets that build on every system imports the C library or an
/// Apple-only framework, or asks which system it is on: what differs between systems is in Sources/VibePlatform, and
/// what only the Mac has in Sources/VibeCore/MacOnly. The files that still break the rule are listed in
/// PlatformLintPending.txt, one path a line; a file leaves the list in the change that cleans it, and the list only
/// gets shorter.
struct PlatformLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The portable targets' folders.
    static let folders = ["Sources/VibeCore", "Sources/VibeHost", "Sources/vibeswitcher-host", "Sources/vibeswitcher-hook",
                          "Sources/vibeswitcher-mcp"]
    /// The Mac's own files, each wrapped whole in `#if canImport(Darwin)`.
    static let macOnly = "Sources/VibeCore/MacOnly/"
    /// VibeCore's one file of exported imports: the platform layer, and what a system names differently.
    static let exempt: Set<String> = ["Sources/VibeCore/PlatformExport.swift"]

    /// A word ends at a "." too (`import IOKit.ps`), which Regex's own word boundary doesn't hold.
    static let systemImport = try! Regex(#"^\s*(@_exported\s+)?import\s+(Darwin|Glibc|Musl|CryptoKit|Security|Network|CoreGraphics|ImageIO|UniformTypeIdentifiers|AppKit|SwiftUI|Combine|IOKit)\b"#)
        .wordBoundaryKind(.simple)
    static let systemCondition = try! Regex(#"^\s*#(if|elseif)\s+.*\b(os|canImport)\("#).wordBoundaryKind(.simple)

    /// Whether `line` is code only the platform layer may have.
    static func breaksTheRule(_ line: String) -> Bool {
        line.contains(systemImport) || line.contains(systemCondition)
    }

    /// Each Swift file the rule covers, by its path in the repository, with the lines that break it ("12: import Darwin").
    static func files() -> [(path: String, violations: [String])] {
        var found: [(path: String, violations: [String])] = []
        for folder in folders {
            for file in (FileManager.default.subpaths(atPath: repo.appendingPathComponent(folder).path) ?? []).sorted() where file.hasSuffix(".swift") {
                let path = "\(folder)/\(file)"
                guard !path.hasPrefix(macOnly), !exempt.contains(path),
                      let text = try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8) else { continue }
                let violations = text.components(separatedBy: "\n").enumerated()
                    .filter { breaksTheRule($0.element) }
                    .map { "\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }
                found.append((path, violations))
            }
        }
        return found
    }

    /// PlatformLintPending.txt's paths, in its order.
    static func pending() throws -> [String] {
        let list = try String(contentsOf: repo.appendingPathComponent("Tests/VibePlatformTests/PlatformLintPending.txt"), encoding: .utf8)
        return list.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    @Test func noSystemCodeOutsideThePlatform() throws {
        let files = Self.files()
        #expect(files.contains { $0.path == "Sources/VibeCore/Paths.swift" }, "the rule's folders weren't read")
        let pending = Set(try Self.pending())
        let breaking = files.filter { !$0.violations.isEmpty && !pending.contains($0.path) }
            .flatMap { file in file.violations.map { "\(file.path):\($0)" } }
        #expect(breaking == [], """
            system code outside the platform layer: call it through VibePlatform (Sources/VibePlatform), or move what \
            only the Mac has to Sources/VibeCore/MacOnly:
            \(breaking.joined(separator: "\n"))
            """)
    }

    @Test func thePendingListHoldsOnlyFilesThatStillBreakTheRule() throws {
        let pending = try Self.pending()
        let breaking = Set(Self.files().filter { !$0.violations.isEmpty }.map(\.path))
        let clean = pending.filter { !breaking.contains($0) }
        #expect(clean == [], """
            listed in Tests/VibePlatformTests/PlatformLintPending.txt and not breaking the rule (cleaned, moved or \
            gone): take the line out:
            \(clean.joined(separator: "\n"))
            """)
        #expect(pending == Set(pending).sorted(), "PlatformLintPending.txt is sorted, each path once")
    }

    @Test func theRuleKnowsSystemCodeFromTheRest() {
        for line in ["import Darwin", "import Glibc", "  import Musl", "@_exported import CryptoKit", "import Security", "import Network",
                     "import CoreGraphics", "import ImageIO", "import UniformTypeIdentifiers", "import AppKit", "import SwiftUI",
                     "import Combine", "import IOKit.ps", "#if os(Linux)", "    #if canImport(Darwin)", "#elseif canImport(Glibc)",
                     "#if DEBUG && os(macOS)", "#if !canImport(Darwin)"] {
            #expect(Self.breaksTheRule(line), "\(line)")
        }
        for line in ["import Foundation", "import Dispatch", "import VibeCore", "import SwiftTerm", "@_exported import VibePlatform",
                     "import NetworkExtras", "// import Darwin", "let text = \"import Darwin\"", "#if DEBUG", "#else", "#endif",
                     "if Platform.canImport(x) {}"] {
            #expect(!Self.breaksTheRule(line), "\(line)")
        }
    }

    // MARK: SIGPIPE in the executables

    /// The executables' mains (`Sources/vibeswitcher*/main.swift`: the host, the hook, the tool server, and the command
    /// line and the server once they exist).
    static func executables() -> [String] {
        let sources = repo.appendingPathComponent("Sources")
        return ((try? FileManager.default.contentsOfDirectory(atPath: sources.path)) ?? []).sorted()
            .filter { $0.hasPrefix("vibeswitcher") }
            .map { "Sources/\($0)/main.swift" }
            .filter { FileManager.default.fileExists(atPath: repo.appendingPathComponent($0).path) }
    }

    /// Mode dispatches that are calls: each returns only when this process isn't in that mode (the host's three), or
    /// never (`MCPHandover.answerProbe`, declared `-> Never`).
    static let dispatchCalls = ["PTYSpawn.execIfLaunched(", "SessionParser.runIfAsked(", "HostHandover.probeIfAsked(",
                                "MCPHandover.answerProbe()"]

    /// `line`'s code: without the comment that ends it, and with its string literals emptied (a bracket or "//" in
    /// one counts for nothing).
    static func code(_ line: String) -> String {
        var kept = "", inString = false, escaped = false
        for character in line {
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" {
                    inString = false
                    kept.append(character)
                }
                continue
            }
            if character == "/", kept.last == "/" {
                kept.removeLast()
                break
            }
            if character == "\"" { inString = true }
            kept.append(character)
        }
        return kept.trimmingCharacters(in: .whitespaces)
    }

    /// `text`'s top-level statements in order, each as its lines' `code`, blank and comment lines left out: a statement
    /// goes on while a bracket it opened is open, or while a line ends, or the next begins, with an operator.
    static func topLevelStatements(_ text: String) -> [[String]] {
        let lines = text.components(separatedBy: "\n").map(code).filter { !$0.isEmpty }
        var statements: [[String]] = [], current: [String] = []
        var depth = 0
        for (index, line) in lines.enumerated() {
            current.append(line)
            for character in line {
                if "{([".contains(character) { depth += 1 } else if "})]".contains(character) { depth -= 1 }
            }
            let next = index + 1 < lines.count ? lines[index + 1] : ""
            let goesOn = depth > 0 || [",", "=", "&&", "||", "+", "?", ":"].contains { line.hasSuffix($0) }
                || [".", "+", "&&", "||", "?", ":", "else"].contains { next.hasPrefix($0) }
            if !goesOn {
                statements.append(current)
                current = []
            }
        }
        if !current.isEmpty { statements.append(current) }
        return statements
    }

    /// Whether `statement` is a mode dispatch: one of `dispatchCalls`, or an `if` whose block's last statement ends
    /// the process (`exit`, `_exit`, an exec, a dispatch call that never returns).
    static func isDispatch(_ statement: [String]) -> Bool {
        let text = statement.joined(separator: "\n")
        if dispatchCalls.contains(where: { text.hasPrefix($0) }) { return true }
        guard text.hasPrefix("if "), text.hasSuffix("}"), let open = text.firstIndex(of: "{") else { return false }
        let block = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        let last = topLevelStatements(block).last?.first ?? ""
        return ["exit(", "_exit(", "execv", "execl"].contains { last.hasPrefix($0) } || dispatchCalls.contains { last.hasPrefix($0) }
    }

    /// What breaks the rule in a main's `text`, one line each: its first top-level statement that is neither an
    /// import nor a mode dispatch isn't `signal(SIGPIPE, …)`; a dispatch that settles SIGPIPE does so after it has
    /// written; a dispatch that is a hook (it reads an agent's event on stdin and answers on stdout) doesn't settle it.
    static func sigpipeProblems(_ text: String) -> [String] {
        var problems: [String] = []
        for statement in topLevelStatements(text) where !statement[0].hasPrefix("import ") {
            guard isDispatch(statement) else {
                if !statement[0].hasPrefix("signal(SIGPIPE") {
                    problems.append("the first statement after the mode dispatches isn't signal(SIGPIPE, …): \(statement[0])")
                }
                return problems
            }
            let block = statement.joined(separator: "\n")
            let settles = block.range(of: "signal(SIGPIPE")
            let writes = [".write(", "print("].compactMap { block.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
            if let settles, let writes, writes.lowerBound < settles.lowerBound {
                problems.append("a mode dispatch writes before it settles SIGPIPE: \(statement[0])")
            }
            if settles == nil, block.contains("FileHandle.standardInput"), block.contains("FileHandle.standardOutput.write") {
                problems.append("a mode dispatch that answers a hook on stdout doesn't settle SIGPIPE: \(statement[0])")
            }
        }
        problems.append("no statement after the mode dispatches")
        return problems
    }

    /// In each executable, the first top-level statement after its mode dispatches settles SIGPIPE, before anything
    /// is written: Linux has no switch per descriptor (`Platform.Sockets.noSigPipe` does nothing there), so a write to
    /// a reader that has gone would otherwise end the process. Mode dispatches run first because what the host's
    /// launcher execs, and a branch's code, must start with SIGPIPE at its default (an ignored signal stays ignored
    /// through execve). A hook's dispatch settles it itself before it answers.
    @Test func everyExecutableSettlesSIGPIPEBeforeItWrites() throws {
        let mains = Self.executables()
        #expect(mains.contains("Sources/vibeswitcher-hook/main.swift") && mains.contains("Sources/vibeswitcher-mcp/main.swift")
                && mains.contains("Sources/vibeswitcher-host/main.swift"), "\(mains)")
        for main in mains {
            let text = try String(contentsOf: Self.repo.appendingPathComponent(main), encoding: .utf8)
            #expect(Self.sigpipeProblems(text) == [], "\(main)")
        }
    }

    /// The rule on mains of its own: what passes, and each way to break it.
    @Test func theSIGPIPERuleKnowsADispatchFromTheRest() {
        let dispatches = """
            import Foundation
            // A comment { (
            PTYSpawn.execIfLaunched(CommandLine.arguments)
            if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--probe" { MCPHandover.answerProbe() }
            if let at = CommandLine.arguments.firstIndex(of: "--keeper") {
                let text = "a } in a string"
                exit(Keeper.run(at,
                                more: 1))
            }
            if CommandLine.arguments[1] == "--hook" {
                if let answer = answer(FileHandle.standardInput.readDataToEndOfFile()) {
                    signal(SIGPIPE, SIG_IGN)
                    try? FileHandle.standardOutput.write(contentsOf: answer)
                }
                exit(0)
            }

            """
        #expect(Self.sigpipeProblems(dispatches + "signal(SIGPIPE, SIG_IGN)\nsignal(SIGALRM) { _ in _exit(0) }\n") == [])
        #expect(Self.sigpipeProblems(dispatches + "signal(SIGPIPE) { _ in }\n") == [])
        // Something else first: a write, a setting, an `if` that goes on.
        #expect(Self.sigpipeProblems(dispatches + "FileHandle.standardError.write(x)\nsignal(SIGPIPE, SIG_IGN)\n").count == 1)
        #expect(Self.sigpipeProblems(dispatches + "signal(SIGALRM) { _ in _exit(0) }\nsignal(SIGPIPE, SIG_IGN)\n").count == 1)
        #expect(Self.sigpipeProblems(dispatches + "if verbose { print(1) }\nsignal(SIGPIPE, SIG_IGN)\n").count == 1)
        #expect(Self.sigpipeProblems(dispatches).count == 1)
        // A hook's dispatch that answers without settling it, or settles it after its answer.
        let unsettled = dispatches.replacingOccurrences(of: "        signal(SIGPIPE, SIG_IGN)\n", with: "")
        #expect(unsettled != dispatches)
        #expect(Self.sigpipeProblems(unsettled + "signal(SIGPIPE, SIG_IGN)\n").count == 1)
        let late = dispatches.replacingOccurrences(of: "        signal(SIGPIPE, SIG_IGN)\n        try? FileHandle.standardOutput.write(contentsOf: answer)\n",
                                                   with: "        try? FileHandle.standardOutput.write(contentsOf: answer)\n        signal(SIGPIPE, SIG_IGN)\n")
        #expect(late != dispatches)
        #expect(Self.sigpipeProblems(late + "signal(SIGPIPE, SIG_IGN)\n").count == 1)
    }
}
