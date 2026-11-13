import Foundation
import Testing

/// The server never execs (the stage 2 plan's Task 8a, S2-D1; the security architecture document's S2): it is started
/// by the host from a sealed copy, non-dumpable from its exec, and holds the app's connector. An exec of anything
/// else would leave that process dumpable (a readable image) with whatever it hadn't closed, and an exec of its own
/// file would run what is on disk now, not the copy the host checked. So `Sources/vibeswitcher-server` and
/// `Sources/VibeNode` call no `execve` or `execv` (nor their `p`/`e` forms), no `Platform.Spawn(…).replaceProcess()`,
/// no `HostHandover.exec`, no `BinaryWatch` (which restarts a process in place when its file changes), and never ask
/// the host for a connection by its path (`viaConnector: false`): its connections are its connector's. Comments and
/// string literals don't count. It passes on nothing until the engine's E1 creates the server.
struct ServerLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The folders the rule covers, relative to the repository (one that doesn't exist yet holds nothing).
    static let covered = ["Sources/vibeswitcher-server", "Sources/VibeNode"]

    /// What the rule refuses, each with what it says.
    static let refused: [(pattern: String, what: String)] = [
        (#"\bexecv[pe]*\s*\("#, "an exec"),
        (#"\bexecve?\b"#, "an exec"),
        (#"\.replaceProcess\s*\("#, "a spawn that replaces the process"),
        (#"\bHostHandover\s*\.\s*exec\b"#, "a handover's exec"),
        (#"\bBinaryWatch\b"#, "a watch that restarts the process in place"),
        (#"\bviaConnector\s*:\s*false\b"#, "a connection by the host's path"),
    ]

    /// `text` with its comments and string literals blanked (each byte but a newline made a space), so a name in a doc
    /// comment or a message isn't a call, and lines keep their numbers.
    static func code(_ text: String) -> String {
        var bytes = Array(text.utf8)
        var index = 0
        func blank(_ from: Int, _ to: Int) {
            for at in from..<min(to, bytes.count) where bytes[at] != UInt8(ascii: "\n") { bytes[at] = UInt8(ascii: " ") }
        }
        while index < bytes.count {
            let byte = bytes[index], next = index + 1 < bytes.count ? bytes[index + 1] : 0
            if byte == UInt8(ascii: "/"), next == UInt8(ascii: "/") {
                let end = bytes[index...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
                blank(index, end)
                index = end
            } else if byte == UInt8(ascii: "/"), next == UInt8(ascii: "*") {
                var end = index + 2
                while end + 1 < bytes.count, !(bytes[end] == UInt8(ascii: "*") && bytes[end + 1] == UInt8(ascii: "/")) { end += 1 }
                blank(index, end + 2)
                index = end + 2
            } else if byte == UInt8(ascii: "\"") {
                // A string on one line (a multi-line one's lines are blanked line by line the same way), escapes kept
                // inside it.
                var end = index + 1
                while end < bytes.count, bytes[end] != UInt8(ascii: "\""), bytes[end] != UInt8(ascii: "\n") {
                    end += bytes[end] == UInt8(ascii: "\\") ? 2 : 1
                }
                blank(index + 1, end)
                index = end + 1
            } else {
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Each refused use in `text`, as "LINE: WHAT".
    static func findings(in text: String) -> [String] {
        let code = code(text)
        var found: [String] = []
        for (number, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            for (pattern, what) in refused where line.contains(try! Regex(pattern)) {
                found.append("\(number + 1): \(what)")
                break
            }
        }
        return found
    }

    @Test func theServerNeverExecs() throws {
        var found: [String] = []
        for folder in Self.covered {
            let root = Self.repo.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                found += Self.findings(in: text).map { "\(folder)/\(file.path.dropFirst(root.path.count + 1)):\($0)" }
            }
        }
        #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    }

    /// The rule on a fixture: each refused form found, on its line; a name in a comment or a string isn't.
    @Test func theRuleFindsEachForm() {
        let fixture = """
            execve(path, argv, envp)
            _ = execv(path, argv)
            _ = Platform.Spawn(executable: path, arguments: [path]).replaceProcess()
            throw HostHandover.exec(path, arguments: [], inherit: nil)
            let watch = BinaryWatch(path: path)
            let connection = try HostConnection(path: socket, viaConnector: false)
            // execve( in a comment, BinaryWatch too
            log("never execve(, never viaConnector: false")
            let fine = HostConnection(path: socket)
            """
        #expect(Self.findings(in: fixture) == ["1: an exec", "2: an exec", "3: a spawn that replaces the process", "4: a handover's exec",
                                               "5: a watch that restarts the process in place", "6: a connection by the host's path"])
    }
}
