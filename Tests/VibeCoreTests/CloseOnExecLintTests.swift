import Foundation
import Testing

/// Every descriptor the host, its launcher, the platform layer and `UnixSocket` make is close-on-exec from the call
/// that makes it (`SOCK_CLOEXEC`, `accept4`, `O_CLOEXEC`, `pipe2`, `MFD_CLOEXEC`), so no program another thread starts
/// in between holds it; and every spawn in the host names what its child keeps (the stage 2 plan's Global
/// Constraints, Task 4a). The calls go through `Platform.Sockets.makeSocket`, `accept` and `pair` and
/// `Sys.pipeClosedOnExec`; an `open` that names a flag names `O_CLOEXEC`.
///
/// Calls are matched, not substrings: a name at a word boundary, called, not declared (`func open(`), bare or
/// qualified by the C library's module or `Sys` (so `ChaChaPoly.open(` and `posix_spawn_file_actions_addopen(`, which
/// opens in the child, aren't calls of `open`), outside comments and string literals.
struct CloseOnExecLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// What the rule covers: folders, and single files, relative to the repository. The server's folder once it exists.
    static let covered = ["Sources/VibeHost", "Sources/vibeswitcher-host", "Sources/VibeCore/UnixSocket.swift",
                          "Sources/vibeswitcher-server", "Sources/VibePlatform"]

    /// Where every spawn names what it keeps.
    static let spawning = ["Sources/VibeHost", "Sources/vibeswitcher-host"]

    /// The calls that make a descriptor that isn't close-on-exec, whatever their arguments.
    static let bare: Set<String> = ["socket", "socketpair", "accept", "pipe"]
    /// The qualifiers under which a call is still the C library's (the raw wrappers, and the systems' modules).
    static let libraryQualifiers: Set<String> = ["Sys", "Darwin", "Glibc", "Musl"]
    /// A Linux form whose call carries one of these is close-on-exec from its making.
    static let linuxFlags = ["SOCK_CLOEXEC", "O_CLOEXEC", "MFD_CLOEXEC"]

    /// The calls left as they are, by file and call as written, each with its reason. A call not listed here breaks
    /// the rule; a listing that matches nothing is stale and fails too.
    static let exemptions: [(path: String, call: String?, reason: String)] = [
        ("Sources/VibePlatform/Sys.swift", nil,
         "the raw wrappers themselves (`Sys.pipe`, `Sys.accept`, `Sys.open`) and the Mac's pipe then FD_CLOEXEC in `pipeClosedOnExec`"),
        ("Sources/VibePlatform/PipeCommand+Darwin.swift", "pipe(",
         "the Mac's status-line pipes, left as they are (not marked close-on-exec): changing them would change the Mac (docs/process/v2-mac-tasks.md)"),
        ("Sources/VibePlatform/FolderWatch+Darwin.swift", "open(",
         "the Mac's folder watch opens with O_EVTONLY and marks it close-on-exec after, as it always did"),
        ("Sources/VibePlatform/FolderWatch+Darwin.swift", "pipe(",
         "the Mac's folder watch's wake pipe, marked close-on-exec after, as it always was: the Mac has no pipe2"),
        ("Sources/VibePlatform/SocketMaking+Darwin.swift", "socket(",
         "the Mac's `makeSocket`: socket, then FD_CLOEXEC, the Mac having no SOCK_CLOEXEC"),
        ("Sources/VibePlatform/SocketMaking+Darwin.swift", "Darwin.accept(",
         "the Mac's `accept`: accept, then FD_CLOEXEC, the Mac having no accept4"),
        ("Sources/VibePlatform/SocketMaking+Darwin.swift", "socketpair(",
         "the Mac's `pair`: socketpair, then FD_CLOEXEC on both ends, the Mac having no SOCK_CLOEXEC"),
    ]

    struct Finding: Equatable, CustomStringConvertible {
        var path: String
        var line: Int
        /// The call as written, qualifier included: "socket(", "Sys.accept(".
        var call: String
        var description: String { "\(path):\(line): \(call)" }
    }

    // MARK: The rule

    /// `text` with its comments and string literals blanked (each of their bytes but a newline made a space), so a
    /// call named in a doc comment or a message isn't one, and lines keep their numbers.
    static func code(_ text: String) -> [UInt8] {
        var bytes = Array(text.utf8)
        var index = 0
        func blank(_ from: Int, _ to: Int) {
            for at in from..<min(to, bytes.count) where bytes[at] != UInt8(ascii: "\n") { bytes[at] = UInt8(ascii: " ") }
        }
        func at(_ offset: Int) -> UInt8? { index + offset < bytes.count ? bytes[index + offset] : nil }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "/"), at(1) == UInt8(ascii: "/") {
                let end = bytes[index...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
                blank(index, end)
                index = end
            } else if byte == UInt8(ascii: "/"), at(1) == UInt8(ascii: "*") {
                var end = index + 2
                while end + 1 < bytes.count, !(bytes[end] == UInt8(ascii: "*") && bytes[end + 1] == UInt8(ascii: "/")) { end += 1 }
                blank(index, end + 2)
                index = end + 2
            } else if byte == UInt8(ascii: "#") || byte == UInt8(ascii: "\"") {
                // A raw string's hashes, then its quotes: `#"…"#`, `"""…"""`, `"…"`.
                var hashes = 0
                while at(hashes) == UInt8(ascii: "#") { hashes += 1 }
                guard at(hashes) == UInt8(ascii: "\"") else {
                    index += max(hashes, 1)
                    continue
                }
                let triple = at(hashes + 1) == UInt8(ascii: "\"") && at(hashes + 2) == UInt8(ascii: "\"")
                let quotes = triple ? 3 : 1
                var end = index + hashes + quotes
                while end < bytes.count {
                    if hashes == 0, bytes[end] == UInt8(ascii: "\\") {
                        end += 2
                        continue
                    }
                    if !triple, bytes[end] == UInt8(ascii: "\n") { break }
                    let closes = (0..<quotes).allSatisfy { end + $0 < bytes.count && bytes[end + $0] == UInt8(ascii: "\"") }
                        && (0..<hashes).allSatisfy { end + quotes + $0 < bytes.count && bytes[end + quotes + $0] == UInt8(ascii: "#") }
                    if closes {
                        end += quotes + hashes
                        break
                    }
                    end += 1
                }
                blank(index, end)
                index = end
            } else {
                index += 1
            }
        }
        return bytes
    }

    static func isWord(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "_")
    }

    /// Each call in `code`: its name, its qualifier (the word before a "." in front of it, nil for none), where its
    /// name begins, and its arguments up to the parenthesis that closes them. Not a declaration (`func open(`).
    static func calls(_ code: [UInt8]) -> [(name: String, qualifier: String?, at: Int, arguments: String)] {
        var found: [(name: String, qualifier: String?, at: Int, arguments: String)] = []
        var index = 0
        while index < code.count {
            guard isWord(code[index]), index == 0 || !isWord(code[index - 1]) else {
                index += 1
                continue
            }
            var end = index
            while end < code.count, isWord(code[end]) { end += 1 }
            defer { index = end }
            guard end < code.count, code[end] == UInt8(ascii: "(") else { continue }
            let name = String(decoding: code[index..<end], as: UTF8.self)
            // The word before: a qualifier after a ".", or `func` for a declaration.
            var before = index - 1
            var qualifier: String?
            if before >= 0, code[before] == UInt8(ascii: ".") {
                var start = before
                while start > 0, isWord(code[start - 1]) { start -= 1 }
                qualifier = String(decoding: code[start..<before], as: UTF8.self)
            } else {
                while before >= 0, code[before] == UInt8(ascii: " ") { before -= 1 }
                var start = before + 1
                while start > 0, isWord(code[start - 1]) { start -= 1 }
                if String(decoding: code[start..<(before + 1)], as: UTF8.self) == "func" { continue }
            }
            var depth = 0
            var close = end
            while close < code.count {
                if code[close] == UInt8(ascii: "(") { depth += 1 }
                if code[close] == UInt8(ascii: ")") {
                    depth -= 1
                    if depth == 0 { break }
                }
                close += 1
            }
            found.append((name, qualifier, index, String(decoding: code[(end + 1)..<min(close, code.count)], as: UTF8.self)))
        }
        return found
    }

    /// The calls in the file at `path` (relative to the repository) holding `text` that make a descriptor not
    /// close-on-exec from its making, exemptions not applied.
    static func findings(path: String, text: String) -> [Finding] {
        let code = code(text)
        let linuxForm = path.hasSuffix("+Linux.swift")
        let flag = try! Regex(#"\bO_[A-Z]+\b"#)
        var found: [Finding] = []
        for call in calls(code) {
            guard call.qualifier == nil || libraryQualifiers.contains(call.qualifier!) else { continue }
            let breaks: Bool
            if bare.contains(call.name) {
                breaks = !(linuxForm && linuxFlags.contains { call.arguments.contains($0) })
            } else if call.name == "open" {
                breaks = call.arguments.contains(flag) && !call.arguments.contains("O_CLOEXEC")
            } else {
                breaks = false
            }
            guard breaks else { continue }
            let line = code[..<call.at].filter { $0 == UInt8(ascii: "\n") }.count + 1
            found.append(Finding(path: path, line: line, call: (call.qualifier.map { $0 + "." } ?? "") + call.name + "("))
        }
        return found
    }

    /// The Swift files under `place` (a folder or one file, relative to the repository), by path, with their text.
    static func files(_ place: String) -> [(path: String, text: String)] {
        let url = repo.appendingPathComponent(place)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return [] }
        let paths = isFolder.boolValue
            ? (FileManager.default.subpaths(atPath: url.path) ?? []).filter { $0.hasSuffix(".swift") }.sorted().map { "\(place)/\($0)" }
            : [place]
        return paths.compactMap { path in
            (try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)).map { (path, $0) }
        }
    }

    static func exempted(_ finding: Finding) -> Bool {
        exemptions.contains { $0.path == finding.path && ($0.call == nil || $0.call == finding.call) }
    }

    // MARK: Spawns

    /// Each `Platform.Spawn(` in `text` whose spawn doesn't set `keep` before it starts (`start(` or
    /// `replaceProcess(` on the same variable), or isn't held in a variable that could: "line: what".
    static func spawnsNotNamingKeep(_ text: String) -> [String] {
        let code = String(decoding: code(text), as: UTF8.self)
        let made = try! Regex(#"(?:var|let)\s+(\w+)\s*=\s*Platform\.Spawn\("#)
        var found: [String] = []
        var bound = Set<String.Index>()
        for match in code.matches(of: made) {
            let name = String(code[match.output[1].range!])
            bound.insert(code.index(match.range.upperBound, offsetBy: -"Platform.Spawn(".count))
            let rest = code[match.range.upperBound...]
            let starts = rest.firstRange(of: try! Regex("\\b\(name)\\.(start|replaceProcess)\\("))
            let scope = rest[..<(starts?.lowerBound ?? rest.endIndex)]
            if scope.firstRange(of: try! Regex("\\b\(name)\\.keep\\s*=")) == nil {
                found.append("\(code[..<match.range.lowerBound].filter { $0 == "\n" }.count + 1): \(name) doesn't set keep")
            }
        }
        for match in code.ranges(of: "Platform.Spawn(") where !bound.contains(match.lowerBound) {
            found.append("\(code[..<match.lowerBound].filter { $0 == "\n" }.count + 1): a spawn held in no variable")
        }
        return found
    }

    // MARK: Tests

    @Test func noBareSocketAcceptOrOpen() {
        var unexempted: [Finding] = []
        var all: [Finding] = []
        for place in Self.covered {
            for file in Self.files(place) {
                let found = Self.findings(path: file.path, text: file.text)
                all += found
                unexempted += found.filter { !Self.exempted($0) }
            }
        }
        #expect(unexempted.isEmpty, "made without close-on-exec: \(unexempted)")
        for exemption in Self.exemptions {
            #expect(all.contains { $0.path == exemption.path && (exemption.call == nil || $0.call == exemption.call) },
                    "a stale exemption: \(exemption.path) \(exemption.call ?? "")")
        }
    }

    @Test func everySpawnInTheHostNamesWhatItKeeps() {
        for place in Self.spawning {
            for file in Self.files(place) {
                let found = Self.spawnsNotNamingKeep(file.text)
                #expect(found.isEmpty, "\(file.path): \(found)")
            }
        }
    }

    /// The rule on fixtures: what it finds, and what it leaves.
    @Test func aBareSocketIsFoundAndCallsThatArentAreNot() {
        let fixture = """
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            let other = Sys.accept(listener, nil, nil)
            guard pipe(&ends) == 0 else { return }
            let file = open(path, O_RDONLY)
            let raw = Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
            """
        #expect(Self.findings(path: "Sources/VibeHost/Fixture.swift", text: fixture).map(\.description) == [
            "Sources/VibeHost/Fixture.swift:1: socket(", "Sources/VibeHost/Fixture.swift:2: Sys.accept(",
            "Sources/VibeHost/Fixture.swift:3: pipe(", "Sources/VibeHost/Fixture.swift:4: open(",
            "Sources/VibeHost/Fixture.swift:5: Darwin.socketpair(",
        ])
        let clean = """
            // A comment naming socket(AF_UNIX, SOCK_STREAM, 0) and pipe(&ends).
            /// `accept(listener, nil, nil)`, then FD_CLOEXEC.
            let said = "socket( failed: \\(errno)"
            let raw = #"open(path, O_RDONLY)"#
            let sealed = try ChaChaPoly.open(box, using: key)
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
            public static func open(rows: UInt16, cols: UInt16) -> Result<Int32, Error> { fatalError() }
            let exit = open(pid)
            let file = Sys.open(path, O_RDONLY | O_CLOEXEC)
            let made = Platform.Sockets.makeSocket(type: Platform.Sockets.stream)
            let taken = Platform.Sockets.accept(listener)
            guard Sys.pipeClosedOnExec(&ends) == 0 else { return }
            """
        #expect(Self.findings(path: "Sources/VibeHost/Fixture.swift", text: clean).isEmpty)
        // A Linux form whose call carries the flag is close-on-exec from its making; elsewhere the flag isn't enough
        // (the Mac has none of them).
        let flagged = "let fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0)"
        #expect(Self.findings(path: "Sources/VibePlatform/Fixture+Linux.swift", text: flagged).isEmpty)
        #expect(Self.findings(path: "Sources/VibePlatform/Fixture+Darwin.swift", text: flagged).count == 1)
    }

    @Test func aSpawnThatDoesntNameItsKeepIsFound() {
        let named = """
            var spawn = Platform.Spawn(executable: path, arguments: [path])
            spawn.keep = []
            let started = spawn.start()
            """
        #expect(Self.spawnsNotNamingKeep(named).isEmpty)
        let unnamed = """
            var spawn = Platform.Spawn(executable: path, arguments: [path])
            spawn.group = .ownSession
            let started = spawn.start()
            spawn.keep = []
            _ = Platform.Spawn(executable: path, arguments: [path]).replaceProcess()
            """
        #expect(Self.spawnsNotNamingKeep(unnamed) == ["1: spawn doesn't set keep", "5: a spawn held in no variable"])
    }
}
