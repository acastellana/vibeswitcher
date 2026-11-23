import Foundation
import Testing
import VibePlatform

/// Glibc-only spellings in a Swift file the Mac's CI jobs compile, outside a Linux-only block: none of the team can
/// build for the Mac locally, and on 2026-11-22/23 three of them broke every `v2 macos` job (a pthread argument
/// unwrapped as Linux's optional, `st_mtim`, `SOCK_STREAM.rawValue`). The files: the portable targets, VibePlatform's
/// files but its `+Linux` ones, and every test target the Mac jobs build. A line inside `#if os(Linux)`,
/// `#if canImport(Glibc)` (or Musl), `#if !os(macOS)`, `#if !canImport(Darwin)`, or the `#else` of a Darwin condition is
/// Linux's alone and may use them. Text in string literals and comments doesn't count. (`environ` isn't one: Swift's
/// Darwin module has it, and VibePlatform's `+Darwin` files spawn with it.)
struct MacCompileLintTests {
    static let repo = PlatformLintTests.repo

    /// What the Mac job compiles.
    static let folders = ["Sources/VibeCore", "Sources/VibeHost", "Sources/VibeNode", "Sources/VibePlatform", "Sources/vibeswitcher-cli",
                          "Sources/vibeswitcher-server", "Sources/vibeswitcher-host", "Sources/vibeswitcher-hook", "Sources/vibeswitcher-mcp",
                          "Tests/VibePlatformTests", "Tests/VibeCoreTests", "Tests/VibeNodeTests", "Tests/VibeHostTests", "Tests/VibeSwitcherTests"]

    /// Each spelling, and what to use instead, with simple word boundaries: Unicode's don't break at a "." between
    /// letters (`st_ctim.tv_sec`). What has no spelling to look for, and so isn't linted:
    /// - a value optional on one system only (a pthread start's argument): bind it per system rather than unwrap it;
    /// - an expression whose type the two compilers infer differently (on 2026-11-23 the Mac's took a test helper's
    ///   `interpreter.map { Array($0.utf8) + [0] } ?? []` as `[Any]?`, and every `v2 macos` job failed to build):
    ///   annotate collection literals and optional maps, in test helpers too (`let bytes: [UInt8] = …`).
    static let spellings: [(pattern: Regex<AnyRegexOutput>, use: String)] = rules.map { (try! Regex($0.pattern).wordBoundaryKind(.simple), $0.use) }
    static let rules: [(pattern: String, use: String)] = [
        (#"\bSOCK_[A-Z]+\.rawValue\b"#, "Platform.Sockets.stream / .seqpacket (glibc's socket types are an enum)"),
        (#"\.st_[mca]tim\b"#, "Platform.Files.modified / changed (the Mac's fields are st_mtimespec, st_ctimespec)"),
        (#"\b__errno_location\b"#, "errno"),
        (#"\bGlibc\."#, "the unqualified name, or a Platform helper"),
        (#"\bpipe2\("#, "Sys.pipeClosedOnExec"),
        (#"\bSOCK_(CLOEXEC|NONBLOCK)\b"#, "Platform.Sockets' makers (the Mac has neither flag)"),
        (#"\bPR_SET_[A-Z_]+\b"#, "a Platform helper (prctl is Linux's)"),
        (#"\bprctl\("#, "a Platform helper (prctl is Linux's)"),
        (#"\bepoll_[a-z_]+\b"#, "Dispatch sources"),
        (#"\bmemfd_create\b"#, "Platform.ProcessSelf.sealedCopy"),
    ]

    /// The lines of `text` that use a glibc-only spelling outside a Linux-only block, as "12: …".
    static func violations(in text: String) -> [String] {
        // Each open `#if`: whether its current branch is Linux's alone.
        var stack: [(condition: String, linux: Bool)] = []
        var inTripleQuote = false
        var found: [String] = []
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // A multi-line string: its lines are text.
            if trimmed.components(separatedBy: "\"\"\"").count % 2 == 0 {
                inTripleQuote.toggle()
                continue
            }
            if inTripleQuote { continue }
            if trimmed.hasPrefix("#if ") {
                stack.append((trimmed, Self.isLinuxBranch(String(trimmed.dropFirst(4)))))
                continue
            }
            if trimmed.hasPrefix("#elseif ") {
                if !stack.isEmpty { stack[stack.count - 1] = (trimmed, Self.isLinuxBranch(String(trimmed.dropFirst(8)))) }
                continue
            }
            if trimmed.hasPrefix("#else") {
                if let top = stack.last { stack[stack.count - 1] = (top.condition, Self.isElseLinux(top.condition)) }
                continue
            }
            if trimmed.hasPrefix("#endif") {
                _ = stack.popLast()
                continue
            }
            if stack.contains(where: \.linux) { continue }
            let code = Self.code(of: raw)
            for spelling in spellings where code.contains(spelling.pattern) {
                found.append("\(index + 1): \(trimmed) — use \(spelling.use)")
                break
            }
        }
        return found
    }

    /// Whether an `#if` or `#elseif` condition makes its branch Linux's alone.
    static func isLinuxBranch(_ condition: String) -> Bool {
        let linux = ["os(Linux)", "canImport(Glibc)", "canImport(Musl)"].contains { condition.contains($0) && !condition.contains("!" + $0) }
        let notDarwin = ["!os(macOS)", "!canImport(Darwin)"].contains { condition.contains($0) }
        return (linux && !condition.contains("||")) || (notDarwin && !condition.contains("||"))
    }

    /// Whether the `#else` of `condition` (its whole line) is Linux's alone: the else of a Darwin condition.
    static func isElseLinux(_ line: String) -> Bool {
        let condition = line.replacingOccurrences(of: "#elseif ", with: "").replacingOccurrences(of: "#if ", with: "")
        return ["os(macOS)", "canImport(Darwin)"].contains { condition.contains($0) && !condition.contains("!" + $0) } && !condition.contains("||")
    }

    /// `line` without its string literals and its comment.
    static func code(of line: String) -> String {
        var result = ""
        var inString = false, escaped = false
        var previous: Character = " "
        for character in line {
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true; continue }
            if character == "/", previous == "/" { result.removeLast(); break }
            result.append(character)
            previous = character
        }
        return result
    }

    /// Every file the Mac compiles, with its violations; VibePlatform's `+Linux` files are Linux's.
    static func files() -> [(path: String, violations: [String])] {
        var found: [(path: String, violations: [String])] = []
        for folder in folders {
            for file in (FileManager.default.subpaths(atPath: repo.appendingPathComponent(folder).path) ?? []).sorted() where file.hasSuffix(".swift") {
                let path = "\(folder)/\(file)"
                guard !path.hasSuffix("+Linux.swift"), !path.hasSuffix("MacCompileLintTests.swift"),
                      let text = try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8) else { continue }
                let lines = Self.violations(in: text)
                if !lines.isEmpty { found.append((path, lines)) }
            }
        }
        return found
    }

    @Test func noFileTheMacCompilesUsesAGlibcOnlySpelling() {
        let found = Self.files()
        let said = found.map { "\($0.path):\n  " + $0.violations.joined(separator: "\n  ") }.joined(separator: "\n")
        #expect(found.isEmpty, "\(said)")
    }

    /// The lint fires where the Mac would fail to compile, and not in Linux's blocks, strings or comments.
    @Test func theLintFiresOutsideLinuxBlocksAlone() {
        let fixture = """
            let a = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
            #if os(Linux)
            let b = Int32(SOCK_DGRAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
            #else
            let c = SOCK_DGRAM
            #endif
            #if canImport(Darwin)
            let d = info.st_mtimespec
            #else
            let e = info.st_mtim
            #endif
            let f = info.st_ctim.tv_sec
            let g = "/proc/\\(pid)/environ" // environ in a comment, prctl( too
            #if !canImport(Darwin)
            _ = prctl(PR_SET_DUMPABLE, 0)
            #endif
            _ = pipe2(&fds, 0)
            """
        let found = Self.violations(in: fixture).map { $0.prefix(while: { $0 != ":" }) }
        #expect(found == ["1", "12", "17"], "\(Self.violations(in: fixture))")
    }
}
