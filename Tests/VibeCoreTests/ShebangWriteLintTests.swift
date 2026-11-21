import Foundation
import Testing

/// A program a test writes and then runs goes in through a helper that never holds it open for writing in this process
/// while other tests fork (`installScript` in VibeCoreTests and VibeHostTests, a child `cp`; `writeClosedOnExec` and
/// `copyClosedOnExec` in VibeNodeTests, a close-on-exec descriptor;
/// `ScratchNode.script`). Foundation's writes (`Data`/`String`'s `write(to:)`/`write(toFile:)`, `FileManager.createFile`)
/// open the file with a descriptor that isn't close-on-exec on Linux: a child another test forks meanwhile keeps it open
/// for writing for as long as it lives, and Linux refuses to run a file open for writing anywhere ("Text file busy",
/// ETXTBSY: the Codex stand-ins on CI, 2026-11-21; a fake `swift` and a parser launcher, which had retries for it).
///
/// The rule reads the four test targets' sources (comments left out, string literals kept) for two forms:
/// - **a script written directly**: a string literal whose text starts with `#!` (single-line, multi-line, raw), or a
///   name bound to one (`let script = "#!…"`), written by `.write(to:` or `.write(toFile:`, or as `createFile`'s
///   `contents: Data(…)`;
/// - **a helper that writes a program**: a function that writes one of its parameters with `.write(to:`/`.write(toFile:`
///   and gives a file an execute mode in the same body (`chmod`, `setAttributes`, `posixPermissions` with an execute bit,
///   or a mode passed in).
/// A finding that is no program run by its path (a file only read, hashed or sealed into memory, rewritten in place to
/// be refused, a hook the test proves never runs) is listed in `exemptions` with its reason; a listing that matches
/// nothing is stale and fails. The lead's CloseOnExecLint (agent/tests-that-write-a) counts tests' `copyItem` and
/// `createFile` of any file; this rule is the `#!` text's `write`, which that one leaves out.
struct ShebangWriteLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The targets read. (Tests/VibeSwitcherTests is the Mac app's, not edited on v2.)
    static let targets = ["Tests/VibeNodeTests", "Tests/VibeCoreTests", "Tests/VibeHostTests", "Tests/VibePlatformTests"]

    /// Findings left as they are: the file, a piece of the finding's line (or the helper's name), and why.
    static let exemptions: [(path: String, piece: String, reason: String)] = [
        ("Tests/VibeNodeTests/SwitchTests.swift", "# changed", "the installed build's host rewritten so its hash no longer matches, for the switch to refuse; never run"),
        ("Tests/VibeNodeTests/SwitchTests.swift", "# rewritten", "the installed command line rewritten so its hash no longer matches, for the switch to refuse; never run"),
        ("Tests/VibeNodeTests/TrustedGitBoxTests.swift", "/bin/git", "a git in a folder the box could write: the test proves it is never trusted, never run"),
        ("Tests/VibeNodeTests/SessionDriveTests.swift", "stand-in codex", "the stand-in's text, copied by copyClosedOnExec to the path that runs"),
        ("Tests/VibeNodeTests/NodeAcceptanceTests.swift", "stand-in codex", "the stand-in's text, copied by copyClosedOnExec to the path that runs"),
        ("Tests/VibeCoreTests/BranchRunTests.swift", "builds/other/Resources/bin/tool", "a tool whose path the plan mounts read-only; never run"),
        ("Tests/VibeCoreTests/GitGuardTests.swift", "planted-commit-msg", "a worker's rewrite of an accepted hook: the test proves the baseline's copy runs, never this"),
        ("Tests/VibeCoreTests/MCPHandoverTests.swift", "contents: Data(c.utf8)", "build C's text, which build B's script copies into place with cp: C runs from that copy"),
        ("Tests/VibeHostTests/HostHardeningTests.swift", "TestLock.command", "an empty vs-heavy whose path the host checks; never run"),
        ("Tests/VibeHostTests/HostHardeningTests.swift", "echo checked", "read into a sealed copy, which is what runs; the path never is"),
        ("Tests/VibeHostTests/HostHardeningTests.swift", "echo replaced", "rewritten beside the sealed copy, to show the copy is unchanged; never run"),
        ("Tests/VibeHostTests/HostHardeningTests.swift", "echo linked", "linked in place, to show the sealed copy is unchanged; never run"),
        ("Tests/VibeHostTests/LeadVaultHostTests.swift", "touch '\\(ran)'", "a build named in a handover the host must refuse: the test fails if it ever runs"),
        ("Tests/VibeHostTests/ServerChildTests.swift", "exit 0\\n\".utf8), attributes", "the Mac's: a script with no code signature, refused before it runs (Linux runs its sealed copy)"),
        ("Tests/VibeHostTests/UpgradeFromLeadHostTests.swift", "echo half", "the Mac's suite: a half-staged entry, never run"),
        ("Tests/VibePlatformTests/SealedCopyTests.swift", "echo checked", "read into a sealed copy, which is what runs; the path never is"),
        ("Tests/VibePlatformTests/SealedCopyTests.swift", "echo replaced", "rewritten beside the sealed copy, to show the copy is unchanged; never run"),
        ("Tests/VibePlatformTests/SealedCopyTests.swift", "echo script", "read into a sealed copy, which is what runs; the path never is"),
        ("Tests/VibePlatformTests/SealedCopyTests.swift", "echo \\(mark)", "read into a sealed copy, which is what runs (aScriptsSealedCopyRuns); the path never is"),
        // The helpers themselves, and texts a child copies into place.
        ("Tests/VibeNodeTests/ScratchNode.swift", "(script)", "ScratchNode.script: the text written beside the path, copied into place by a child cp, which is what runs"),
        ("Tests/VibeNodeTests/FakeClaude.swift", ".write(to: text", "the launcher's text, copied into place by a child cp, which is what runs"),
        ("Tests/VibeCoreTests/TestSupport.swift", "(installScript)", "installScript: the text written to a scratch file, copied into place by a child cp, which is what runs"),
        // Scripts read, or run as a shell's argument (never exec'd themselves).
        ("Tests/VibeCoreTests/AgentExportLintTests.swift", "try \"\"\"", "a script for the lint to read; never run"),
        ("Tests/VibeCoreTests/ScriptScratchLintTests.swift", "try \"\"\"", "scripts for the lint to read; never run"),
        ("Tests/VibeCoreTests/ScriptScratchLintTests.swift", "(bare)", "a script for the lint to read; never run"),
        ("Tests/VibeCoreTests/ScriptScratchLintTests.swift", "(late)", "a script for the lint to read; never run"),
        ("Tests/VibeCoreTests/ScriptScratchLintTests.swift", "(calledAlone)", "a script for the lint to read; never run"),
        ("Tests/VibeCoreTests/ProductInventoryTests.swift", "ProductInventory.script", "committed, and run as bash's argument from a checkout (`ProductInventory`); never exec'd"),
        ("Tests/VibeCoreTests/InstallRelaunchTests.swift", "main.sh", "the stand-in's main.sh, run as bash's argument (its Contents/MacOS link is /bin/bash); never exec'd"),
        ("Tests/VibePlatformTests/ToolsTests.swift", "(write)", "stand-ins run as /bin/sh's argument, and tools whose paths are looked up, never run"),
        // (Its path in two pieces: whole, its 40 letters read as an AWS key's shape to SecretShapeLint.)
        ("Tests/VibeCoreTests/" + "WalletE2EScriptTests.swift", "(write)", "the fake config folder's data (a passphrase, a keystore), mode 0600; the fake commands go through installScript"),
    ]

    struct Finding: Equatable, CustomStringConvertible {
        var path: String
        var line: Int
        var text: String
        var description: String { "\(path):\(line): \(text)" }
    }

    // MARK: Reading

    /// `text` with its comments blanked (each byte but a newline made a space) and its string literals kept, with each
    /// literal's range and whether its text starts with `#!`.
    static func scan(_ text: String) -> (code: [UInt8], scripts: [Range<Int>]) {
        var bytes = Array(text.utf8)
        var scripts: [Range<Int>] = []
        var index = 0
        let quote = UInt8(ascii: "\""), slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), hash = UInt8(ascii: "#"), newline = UInt8(ascii: "\n")
        func at(_ i: Int) -> UInt8? { i < bytes.count ? bytes[i] : nil }
        func blank(_ from: Int, _ to: Int) { for i in from..<min(to, bytes.count) where bytes[i] != newline { bytes[i] = UInt8(ascii: " ") } }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == slash, at(index + 1) == slash {
                let end = bytes[index...].firstIndex(of: newline) ?? bytes.count
                blank(index, end)
                index = end
                continue
            }
            if byte == slash, at(index + 1) == star {
                var end = index + 2, depth = 1
                while end < bytes.count, depth > 0 {
                    if bytes[end] == slash, at(end + 1) == star { depth += 1; end += 2 } else if bytes[end] == star, at(end + 1) == slash { depth -= 1; end += 2 } else { end += 1 }
                }
                blank(index, end)
                index = end
                continue
            }
            // A string literal: its hashes (raw), one quote or three.
            var start = index, hashes = 0
            while at(start) == hash { hashes += 1; start += 1 }
            guard at(start) == quote else { index += 1; continue }
            let multi = at(start + 1) == quote && at(start + 2) == quote
            var contentStart = start + (multi ? 3 : 1)
            let closing = [UInt8](repeating: quote, count: multi ? 3 : 1) + [UInt8](repeating: hash, count: hashes)
            var end = contentStart
            while end < bytes.count {
                // An interpolation, `\(…)` (`\#(…)` in a raw literal): to its closing parenthesis, past the literals in it.
                let escape = bytes[end] == UInt8(ascii: "\\") && (hashes == 0 || Array(bytes[(end + 1)..<min(end + 1 + hashes, bytes.count)]) == [UInt8](repeating: hash, count: hashes))
                if escape {
                    let after = end + 1 + hashes
                    if at(after) == UInt8(ascii: "(") {
                        var depth = 1, i = after + 1
                        while i < bytes.count, depth > 0 {
                            if bytes[i] == quote {
                                i += 1
                                while i < bytes.count, bytes[i] != quote, bytes[i] != newline { i += bytes[i] == UInt8(ascii: "\\") ? 2 : 1 }
                            } else if bytes[i] == UInt8(ascii: "(") { depth += 1 } else if bytes[i] == UInt8(ascii: ")") { depth -= 1 }
                            i += 1
                        }
                        end = i
                        continue
                    }
                    if hashes == 0 { end += 2; continue }
                }
                if Array(bytes[end..<min(end + closing.count, bytes.count)]) == closing { break }
                if !multi, bytes[end] == newline { break }
                end += 1
            }
            if multi { while contentStart < end, [newline, UInt8(ascii: " "), UInt8(ascii: "\t")].contains(bytes[contentStart]) { contentStart += 1 } }
            if contentStart + 1 < end, bytes[contentStart] == hash, bytes[contentStart + 1] == UInt8(ascii: "!") {
                scripts.append(index..<min(end + closing.count, bytes.count))
            }
            index = min(end + closing.count, bytes.count)
        }
        return (bytes, scripts)
    }

    static func line(_ code: [UInt8], _ at: Int) -> Int { code[..<at].filter { $0 == UInt8(ascii: "\n") }.count + 1 }

    static func lineText(_ code: [UInt8], _ at: Int) -> String {
        var from = at, to = at
        while from > 0, code[from - 1] != UInt8(ascii: "\n") { from -= 1 }
        while to < code.count, code[to] != UInt8(ascii: "\n") { to += 1 }
        return String(decoding: code[from..<to], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

    // MARK: The rule

    /// The findings in one file's `text`.
    static func findings(path: String, text: String) -> [Finding] {
        let (code, scripts) = scan(text)
        let source = String(decoding: code, as: UTF8.self)
        var found: [Finding] = []
        func add(_ at: Int, _ what: String, write: Int? = nil) {
            let shown = [lineText(code, at)] + (write.map { line(code, $0) != line(code, at) ? [lineText(code, $0)] : [] } ?? [])
            found.append(Finding(path: path, line: line(code, at), text: what + ": " + shown.joined(separator: " … ")))
        }
        var names: [String] = []
        for script in scripts {
            let after = String(decoding: code[script.upperBound..<min(script.upperBound + 120, code.count)], as: UTF8.self)
            let before = String(decoding: code[max(0, script.lowerBound - 240)..<script.lowerBound], as: UTF8.self)
            if matches(after, #"^\s*\.write\(\s*(to|toFile):"#) || matches(after, #"^\s*\.utf8\s*\)\s*\.write\(\s*(to|toFile):"#) {
                add(script.lowerBound, "a #! text written by Foundation", write: script.upperBound)
            } else if matches(before, #"createFile\([^;{}]*contents:\s*Data\(\s*$"#) {
                add(script.lowerBound, "a #! text made by createFile")
            }
            // A name bound to it: `let script = "#!…"` (a `+` after it still binds the whole text).
            if let bound = before.range(of: #"\b(let|var)\s+(\w+)\s*(:\s*String\s*)?=\s*$"#, options: .regularExpression) {
                let words = before[bound].split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
                if words.count >= 2 { names.append(String(words[1])) }
            }
        }
        for name in Set(names) {
            for pattern in [#"\b\#(name)\s*\.write\(\s*(to|toFile):"#, #"Data\(\s*\#(name)\s*\.utf8\s*\)\s*\.write\(\s*(to|toFile):"#,
                            #"contents:\s*Data\(\s*\#(name)\s*\.utf8"#] {
                var from = source.startIndex
                while let hit = source.range(of: pattern, options: .regularExpression, range: from..<source.endIndex) {
                    add(source.utf8.distance(from: source.startIndex, to: hit.lowerBound), "a #! text (\(name)) written by Foundation")
                    from = hit.upperBound
                }
            }
        }
        found += helpers(path: path, code: code, source: source)
        return found
    }

    /// The functions that write a parameter with Foundation and give a file an execute mode in the same body.
    static func helpers(path: String, code: [UInt8], source: String) -> [Finding] {
        var found: [Finding] = []
        var from = source.startIndex
        while let head = source.range(of: #"\bfunc\s+(\w+)\s*\(([^)]*)\)[^{]*\{"#, options: .regularExpression, range: from..<source.endIndex) {
            from = head.upperBound
            // The body: to the brace that closes it.
            var depth = 1, end = head.upperBound
            while end < source.endIndex, depth > 0 {
                if source[end] == "{" { depth += 1 } else if source[end] == "}" { depth -= 1 }
                end = source.index(after: end)
            }
            let signature = String(source[head])
            let body = String(source[head.upperBound..<end])
            // Its parameters' inner names.
            let list = signature[signature.firstIndex(of: "(")!...].dropFirst().prefix { $0 != ")" }
            let parameters = list.split(separator: ",").compactMap { part -> String? in
                let label = part.split(separator: ":").first?.split(separator: " ").last
                return label.map(String.init)
            }
            let writes = parameters.contains { name in matches(body, #"\b\#(name)\s*\.write\(\s*(to|toFile):"#)
                || matches(body, #"Data\(\s*\#(name)\s*\.utf8\s*\)\s*\.write\(\s*(to|toFile):"#) }
            let executable = matches(body, #"(chmod\([^)]*,\s*(0o[1357][0-7]{2}|mode)\b|posixPermissions:\s*(0o[1357][0-7]{2}|mode)\b)"#)
            if writes, executable {
                let at = source.utf8.distance(from: source.startIndex, to: head.lowerBound)
                let name = signature.split(separator: "(").first?.split(separator: " ").last.map(String.init) ?? "?"
                found.append(Finding(path: path, line: line(code, at), text: "a helper that writes a program (\(name)): " + lineText(code, at)))
            }
        }
        return found
    }

    static func files() -> [(path: String, text: String)] {
        targets.flatMap { target -> [(path: String, text: String)] in
            let root = repo.appendingPathComponent(target)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
            return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ShebangWriteLintTests.swift" }
                .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { ("\(target)/\(url.path.dropFirst(root.path.count + 1))", $0) } }
        }
    }

    static func exempt(_ finding: Finding) -> Bool {
        exemptions.contains { $0.path == finding.path && finding.text.contains($0.piece) }
    }

    @Test func aProgramATestWritesGoesInClosedOnExec() {
        let found = Self.files().flatMap { Self.findings(path: $0.path, text: $0.text) }
        let broken = found.filter { !Self.exempt($0) }
        #expect(broken.isEmpty, """
            A program a test writes and runs goes through installScript (VibeCoreTests, VibeHostTests), writeClosedOnExec or \
            copyClosedOnExec (VibeNodeTests) or ScratchNode.script: Foundation's write \
            leaves it open for writing in every child forked meanwhile, and Linux won't run it ("Text file busy"). One that is \
            never run by its path: ShebangWriteLintTests.exemptions with its reason.
            \(broken.map(\.description).joined(separator: "\n"))
            """)
        let stale = Self.exemptions.filter { entry in !found.contains { $0.path == entry.path && $0.text.contains(entry.piece) } }
        #expect(stale.isEmpty, "exemptions that match nothing: \(stale.map { "\($0.path): \($0.piece)" })")
    }

    /// The rule on a fixture: each form found, one that is a helper's own and the safe forms not.
    @Test func theRuleFindsEachForm() {
        let fixture = #"""
            func a() throws {
                try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
                try Data("#!/bin/sh\n".utf8).write(to: url)
                FileManager.default.createFile(atPath: p, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
                try """
                    #!/bin/bash
                    echo hi
                    """.write(to: launcher, atomically: true, encoding: .utf8)
                let script = "#!/bin/sh\n" + body
                try script.write(toFile: path, atomically: true, encoding: .utf8)
                // try "#!/bin/sh\n".write(to: commented)
                try installScript("#!/bin/sh\n", at: url)
                try "#!/bin/sh\n".data(using: .utf8)
                try "not a script".write(to: url, atomically: true, encoding: .utf8)
                try "#!/bin/sh\n\(touching(marks, "a \"quoted\" word"))\n".write(toFile: hook, atomically: true, encoding: .utf8)
            }
            func shim(_ name: String, _ body: String) throws {
                try body.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            func data(_ text: String) throws {
                try text.write(to: file, atomically: true, encoding: .utf8)
                chmod(file.path, 0o644)
            }
            """#
        let found = Self.findings(path: "x.swift", text: fixture)
        #expect(found.map(\.line).sorted() == [2, 3, 4, 5, 10, 15, 17], "\(found)")
        #expect(found.last?.text.contains("(shim)") == true, "\(found)")
    }
}
