import Foundation
import Testing
import VibePlatform

/// Glibc-only spellings in a Swift file the Mac's CI jobs compile, outside a Linux-only block: none of the team can
/// build for the Mac locally, and on 2026-11-22/23 three of them broke every `v2 macos` job (a pthread argument
/// unwrapped as Linux's optional, `st_mtim`, `SOCK_STREAM.rawValue`). The files: the portable targets, VibePlatform's
/// files but its `+Linux` ones, and every test target the Mac jobs build. A line inside `#if os(Linux)`,
/// `#if canImport(Glibc)` (or Musl), `#if !os(macOS)`, `#if !canImport(Darwin)`, or the `#else` of a Darwin condition is
/// Linux's alone and may use them. Text in string literals and comments doesn't count. (`environ` isn't one: Swift's
/// Darwin module has it, and VibePlatform's `+Darwin` files spawn with it.) Nor, in those places, a name `Sources`
/// declares only on Linux, in a `+Linux` file or a Linux-only block (eb72e42b's three tests named `InotifyHub`): the
/// list is built from the sources as the test runs.
struct MacCompileLintTests {
    static let repo = PlatformLintTests.repo

    /// What the Mac job compiles: the keeper's package (`Keeper/Sources`, which the repository's package names by path:
    /// what slice K0 moved there from VibePlatform and VibeCore, and the keeper itself) too.
    static let sources = ["Sources", "Keeper/Sources"]
    static let folders = ["Sources/VibeCore", "Sources/VibeHost", "Sources/VibeNode", "Sources/VibePlatform", "Sources/vibeswitcher-cli",
                          "Sources/vibeswitcher-server", "Sources/vibeswitcher-host", "Sources/vibeswitcher-hook", "Sources/vibeswitcher-mcp",
                          "Keeper/Sources",
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

    /// For each line of `text`: whether the Mac doesn't compile it as code (inside a Linux-only branch), or it is
    /// no code (a directive, a multi-line string's line).
    static func linuxOnly(_ text: String) -> [Bool] {
        // Each open `#if`: whether its current branch is Linux's alone.
        var stack: [(condition: String, linux: Bool)] = []
        var inTripleQuote = false
        var mask: [Bool] = []
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // A multi-line string: its lines are text. The line that opens one is code before its quotes (a `static let`).
            if trimmed.components(separatedBy: "\"\"\"").count % 2 == 0 {
                inTripleQuote.toggle()
                mask.append(inTripleQuote ? stack.contains(where: \.linux) : true)
                continue
            }
            if inTripleQuote {
                mask.append(true)
                continue
            }
            if trimmed.hasPrefix("#if ") {
                stack.append((trimmed, Self.isLinuxBranch(String(trimmed.dropFirst(4)))))
            } else if trimmed.hasPrefix("#elseif ") {
                if !stack.isEmpty { stack[stack.count - 1] = (trimmed, Self.isLinuxBranch(String(trimmed.dropFirst(8)))) }
            } else if trimmed.hasPrefix("#else") {
                if let top = stack.last { stack[stack.count - 1] = (top.condition, Self.isElseLinux(top.condition)) }
            } else if trimmed.hasPrefix("#endif") {
                _ = stack.popLast()
            } else {
                mask.append(stack.contains(where: \.linux))
                continue
            }
            mask.append(true)
        }
        return mask
    }

    /// The lines of `text` that use a glibc-only spelling outside a Linux-only block, as "12: …".
    static func violations(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n"), mask = linuxOnly(text)
        var found: [String] = []
        for (index, raw) in lines.enumerated() where !mask[index] {
            let code = Self.code(of: raw)
            for spelling in spellings where code.contains(spelling.pattern) {
                found.append("\(index + 1): \(raw.trimmingCharacters(in: .whitespaces)) — use \(spelling.use)")
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

    // MARK: Names declared on Linux alone

    /// A type (class, struct, enum, protocol, actor, typealias), a function, a static member or a top-level `let`/`var`
    /// declared on `line` (its code); one private to its file only when `privateToo`.
    static func declared(on line: String, privateToo: Bool = false) -> [String] {
        let code = Self.code(of: line)
        let words = code.split { !($0.isLetter || $0.isNumber || $0 == "_") }
        guard privateToo || !words.contains("private") && !words.contains("fileprivate") else { return [] }
        var names = code.matches(of: declaration).compactMap { match in
            match.output[2].substring.map(String.init).flatMap { Self.keywords.contains($0) ? nil : $0 }
        }
        // A top-level `let` or `var` (not indented).
        if let first = line.first, !first.isWhitespace, let match = code.firstMatch(of: topLevel), let name = match.output[1].substring {
            names.append(String(name))
        }
        return names
    }

    /// Swift's words: never a name (`for a, protocol in …` is a loop, not a protocol).
    static let keywords: Set<String> = ["var", "let", "func", "class", "static", "final", "init", "subscript", "override", "in", "where", "async", "throws"]
    static let declaration = try! Regex(#"\b(class|struct|enum|protocol|actor|typealias|func|static let|static var|class let|class var)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        .wordBoundaryKind(.simple)
    static let topLevel = try! Regex(#"^(?:(?:public|internal|nonisolated|nonisolated\(unsafe\))\s+)*(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)"#)

    /// The names `Sources` declares only where the Mac doesn't compile them, across `files` (path, text), each with
    /// where (its first "path:line"): in a `+Linux` file or a Linux-only block, and nowhere else (a name the Mac's
    /// side declares too, as `+Darwin` files do, or any `let`, `var` or parameter of that name the Mac compiles, a
    /// test's included, is no one's alone). A test's own Linux-only shims aren't counted: on the Mac the SDK may
    /// declare them (`__dispatch_queue_get_label`).
    static func linuxOnlyNames(_ files: [(path: String, text: String)]) -> [String: String] {
        var linux: [String: String] = [:], other: Set<String> = []
        for file in files {
            let linuxFile = file.path.hasSuffix("+Linux.swift"), mask = linuxOnly(file.text), source = sources.contains { file.path.hasPrefix($0 + "/") }
            for (index, line) in file.text.components(separatedBy: "\n").enumerated() {
                if linuxFile || mask[index] {
                    guard source else { continue }
                    for name in declared(on: line) where linux[name] == nil { linux[name] = "\(file.path):\(index + 1)" }
                } else {
                    other.formUnion(declared(on: line, privateToo: true))
                    other.formUnion(Self.code(of: line).matches(of: anyBinding).compactMap { ($0.output[1].substring ?? $0.output[2].substring).map(String.init) })
                }
            }
        }
        return linux.filter { !other.contains($0.key) }
    }

    /// Any binding's or parameter's name (`let a`, `var a`, `case let a`, `a:` in a signature or a call, `{ a in`):
    /// a name the Mac's side uses for its own.
    static let anyBinding = try! Regex(#"(?:\blet|\bvar|\bcase)\s+([A-Za-z_][A-Za-z0-9_]*)|([A-Za-z_][A-Za-z0-9_]*)\s*:"#).wordBoundaryKind(.simple)

    /// The lines of `text` that name one of `names` where the Mac compiles them, as "12: … — Name (declared at …)".
    static func uses(of names: [String: String], in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n"), mask = linuxOnly(text)
        var found: [String] = []
        for (index, raw) in lines.enumerated() where !mask[index] {
            let words = Self.code(of: raw).split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init)
            if let name = words.first(where: { names[$0] != nil }) {
                found.append("\(index + 1): \(raw.trimmingCharacters(in: .whitespaces)) — \(name) is Linux's alone (\(names[name]!)): gate the use")
            }
        }
        return found
    }

    /// Every Swift file under `folders` (of the repository, or of `root`, a test's tree), as (path, text).
    static func swiftFiles(_ folders: [String], root: URL = repo) -> [(path: String, text: String)] {
        folders.flatMap { folder in
            (FileManager.default.subpaths(atPath: root.appendingPathComponent(folder).path) ?? []).sorted().filter { $0.hasSuffix(".swift") }.compactMap { file in
                let path = "\(folder)/\(file)"
                return (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)).map { (path, $0) }
            }
        }
    }

    /// Every file the Mac compiles (in the repository, or in `root`, a test's tree), with its violations; the platform
    /// layers' `+Linux` files are Linux's.
    static func files(root: URL = repo) -> [(path: String, violations: [String])] {
        // Declared on Linux alone: from every source (the Mac app's too, whose declarations are the Mac's) and every
        // test file the Mac builds (a test's own helper of the same name is the Mac's).
        let linuxNames = linuxOnlyNames(swiftFiles(sources + folders.filter { $0.hasPrefix("Tests/") }, root: root))
        var found: [(path: String, violations: [String])] = []
        for file in swiftFiles(folders, root: root) where !file.path.hasSuffix("+Linux.swift") && !file.path.hasSuffix("MacCompileLintTests.swift") {
            let lines = Self.violations(in: file.text) + Self.uses(of: linuxNames, in: file.text)
            if !lines.isEmpty { found.append((file.path, lines)) }
        }
        return found
    }

    @Test func noFileTheMacCompilesUsesAGlibcOnlySpelling() {
        let found = Self.files()
        let said = found.map { "\($0.path):\n  " + $0.violations.joined(separator: "\n  ") }.joined(separator: "\n")
        #expect(found.isEmpty, "\(said)")
    }

    /// The keeper's package is read: its real files are among the compiled ones, and in a sample tree's `Keeper/Sources`
    /// a Glibc-only spelling and a use of a name only its `+Linux` file declares are both found.
    @Test func theKeepersSourcesAreCovered() throws {
        #expect(Self.swiftFiles(Self.folders).contains { $0.path == "Keeper/Sources/VibeKeep/NodePins.swift" })
        let tree = try TestScriptLinuxTests.scratch("mac-compile-keeper")
        defer { try? FileManager.default.removeItem(at: tree) }
        let folder = tree.appendingPathComponent("Keeper/Sources/VibeKeep")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "enum KeepInotify { static func watch() {} }\n".write(to: folder.appendingPathComponent("Watch+Linux.swift"), atomically: true, encoding: .utf8)
        try "import Foundation\n_ = pipe2(&fds, 0)\nKeepInotify.watch()\n".write(to: folder.appendingPathComponent("Planted.swift"), atomically: true, encoding: .utf8)
        let found = Self.files(root: tree)
        #expect(found.map(\.path) == ["Keeper/Sources/VibeKeep/Planted.swift"], "\(found)")
        #expect(found.first?.violations.map { $0.prefix(while: { $0 != ":" }) } == ["2", "3"], "\(found)")
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

    /// A name declared only in a `+Linux` file or a Linux-only block is flagged where the Mac compiles a use of it; a
    /// name the Mac's side declares too, a private one, a use in a Linux block, a string or a comment, isn't.
    @Test func aNameDeclaredOnLinuxAloneIsFlaggedWhereTheMacCompilesIt() {
        let linuxFile = """
            public final class InotifyHub {
                public static let shared = InotifyHub()
                public func add(_ path: String) {}
            }
            extension Platform.Files {
                public static func modified(_ path: String) -> Double { 0 }
                public static func inotifyLimit() -> Int { 128 }
                private static func helper() {}
            }
            enum Small { static var watched = 0 }
            """
        let darwinFile = """
            extension Platform.Files {
                public static func modified(_ path: String) -> Double { 0 }
            }
            """
        let shared = """
            enum Watches {
                #if os(Linux)
                static func hubbed() -> InotifyHub { .shared }
                #endif
            }
            """
        let names = Self.linuxOnlyNames([("Sources/VibePlatform/Watches+Linux.swift", linuxFile), ("Sources/VibePlatform/Files+Darwin.swift", darwinFile),
                                         ("Sources/VibePlatform/Watches.swift", shared)])
        // A Linux-only type's members are Linux's too (`add`, `shared`); `modified` is the Mac's as well, `helper` private.
        #expect(Set(names.keys) == ["InotifyHub", "shared", "add", "inotifyLimit", "Small", "watched", "hubbed"], "\(names.keys.sorted())")
        let test = """
            let hub = InotifyHub.shared
            let when = Platform.Files.modified(path)
            #if os(Linux)
            let limit = Platform.Files.inotifyLimit()
            #endif
            let said = "InotifyHub" // InotifyHub in a comment
            _ = Watches.hubbed()
            helper()
            """
        let found = Self.uses(of: names, in: test).map { $0.prefix(while: { $0 != ":" }) }
        #expect(found == ["1", "7"], "\(Self.uses(of: names, in: test))")
    }
}
