import Foundation
import Testing

/// No path under the home folder is worked out once for the whole process. 2026-10-19: `Breadcrumbs.shared` kept the
/// app.log path it took from the home the process started with, and test runs on the user's own home (the load
/// script's) wrote 34 lines from fake leads ('lead: kept the running lead of relaunch-DABE6BDC-…') into the real
/// ~/.vibeswitcher/debug/app.log, the log the lead reads for 'main thread stuck' after an install. A path is looked up
/// where it's used (`VibePaths.root` is computed), so it's the scratch home's whenever the code runs on one.
struct HomePathLintTests {
    /// Kept once per process, and correct so: each is the top-level code of an executable of its own (the host, the
    /// hook), which runs once at its start, on the home that process was started with.
    static let allowed: Set<String> = [
        "Sources/vibeswitcher-host/main.swift: lockPath",
        "Sources/vibeswitcher-host/main.swift: ownsLaunchers",
        "Sources/vibeswitcher-host/main.swift: launchers",
        "Sources/vibeswitcher-host/main.swift: vaultFile",
        "Sources/vibeswitcher-host/main.swift: config",
        "Sources/vibeswitcher-hook/main.swift: stateURL",
    ]

    /// What reads the home folder.
    static let home = try! Regex(#"VibePaths\.|NSHomeDirectory\(|homeDirectoryForCurrentUser|homeDirectory\(forUser|expandingTildeInPath|getpwuid|CFCopyHomeDirectoryURL|"~/|environment\["(HOME|CFFIXED_USER_HOME)"\]"#)
    static let staticDeclaration = try! Regex(#"^\s*(?:@[\w.()"]+\s+)*(?:(?:public|private|fileprivate|internal|open|nonisolated|final)(?:\((?:set|unsafe)\))?\s+)*static\s+(?:let|var)\s+(\w+)"#)
    static let globalDeclaration = try! Regex(#"^(?:(?:public|private|fileprivate|internal|nonisolated)\s+)*(?:let|var)\s+(\w+)"#)

    /// The values in `lines` (one file's code) kept once per process: a `static let`/`static var` with a value, a global
    /// `let`/`var` (lazy, or the top-level code of a `main.swift`), whose value reads the home folder. By name.
    static func homeOnce(in lines: [String]) -> [String] {
        var found: [String] = []
        for (index, line) in lines.enumerated() {
            guard let match = line.firstMatch(of: staticDeclaration) ?? line.firstMatch(of: globalDeclaration),
                  let name = match.output[1].substring.map(String.init) else { continue }
            // After the name: a type, then `=` (a value worked out once) or `{` (computed each time it's read).
            var rest = Substring(line[match.range.upperBound...])
            var depth = 0
            var value: String?
            var previous: Character = " "
            while let character = rest.first {
                rest = rest.dropFirst()
                defer { previous = character }
                if "([<".contains(character) { depth += 1 } else if ")]".contains(character) || (character == ">" && previous != "-") { depth -= 1 }
                if depth == 0, character == "{" { break }
                if depth == 0, character == "=" { value = String(rest); break }
            }
            guard var text = value else { continue }
            // The value runs on while its brackets are open (a closure called at once, a call over several lines).
            var open = brackets(in: text)
            var next = index + 1
            while open > 0, next < lines.count {
                text += "\n" + lines[next]
                open += brackets(in: lines[next])
                next += 1
            }
            // A closure kept to be called later looks the home up at each call; one called at once (`{ … }()`) doesn't.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let closure = trimmed.hasPrefix("{") && !trimmed.hasSuffix("}()")
            if !closure, text.contains(home) { found.append(name) }
        }
        return found
    }

    /// Opened minus closed brackets in `line`, outside string literals.
    static func brackets(in line: String) -> Int {
        var count = 0
        var quoted = false
        var escaped = false
        for character in line {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            guard !quoted else { continue }
            if "([{".contains(character) { count += 1 } else if ")]}".contains(character) { count -= 1 }
        }
        return count
    }

    @Test func noPathUnderTheHomeIsKeptOncePerProcess() {
        let kept = KeychainLintTests.code(in: "Sources").flatMap { file in Self.homeOnce(in: file.lines).map { "\(file.path): \($0)" } }
        #expect(Set(kept).subtracting(Self.allowed).sorted() == [],
                "worked out once per process from the home folder: look it up where it's used (a computed var), so a test on a scratch home never gets the user's")
        // The allowed ones are still there (a rename would leave a stale entry that excuses nothing).
        #expect(Self.allowed.subtracting(kept).sorted() == [])
    }

    /// The lint tells a value kept once from one looked up each time.
    @Test func theLintTellsKeptFromLookedUp() {
        let code = """
            enum Log {
                static let file = VibePaths.root.appendingPathComponent("debug/app.log")
                public static let shared = Writer(capacity: 400, file: VibePaths.root.appendingPathComponent("x"))
                private static let folder: URL = {
                    let home = NSHomeDirectory()
                    return URL(fileURLWithPath: home)
                }()
                nonisolated(unsafe) static var cached: [String: URL] = ["a": FileManager.default.homeDirectoryForCurrentUser]
                static let expanded = ("~/x" as NSString).expandingTildeInPath
                static var root: URL { VibePaths.root }
                static var hostLog: URL {
                    VibePaths.root.appendingPathComponent("host.log")
                }
                static let queue = DispatchQueue(label: "vibeswitcher.log")
                static var enabled = true
                static let size: Int = 400
                static let resolve: @Sendable () -> URL = { VibePaths.root }
                func write() { let file = VibePaths.root }
            }
            let stateURL = VibePaths.stateFile(tty: tty)
            private let shared = Log()
            """
        #expect(Self.homeOnce(in: code.components(separatedBy: "\n")) == ["file", "shared", "folder", "cached", "expanded", "stateURL"])
    }
}
