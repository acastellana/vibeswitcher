import Foundation
import Testing

/// No script or test of this project can put a Keychain password dialog on the user's screen by accident. 2026-11-26:
/// a worker's probe let its scratch keychain auto-lock after the default 300 s, and `security add-generic-password`
/// waited on an unlock dialog on the user's screen (twice); other probes' `security` and SecKeychain calls left the
/// user's login keychain locked, with a stream of real password prompts, and an ACL change raised a dialog even with
/// user interaction switched off. So under scripts/ and Tests/, by their source:
/// - `security` runs only through scripts/lib/scratch-keychain.sh's keychain_call (a scratch keychain file made
///   unlocked with no timeout, a scratch HOME, a hard timeout), but for a few read-only subcommands;
/// - each SecItem call passes no-UI (`kSecUseAuthenticationUI: kSecUseAuthenticationUIFail`);
/// - no SecKeychain, SecAccess, SecACL or SecTrustedApplication call (ACLs, locks, unlocks, settings, the search
///   list), but the read-only lock-state probe (open, get status);
/// each other use allowed below by file and text, with its reason.
struct KeychainCallLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let helper = "scripts/lib/scratch-keychain.sh"
    static let me = "Tests/VibeCoreTests/KeychainCallLintTests.swift"

    /// Files left out whole, with why.
    static let allowedFiles: [(file: String, reason: String)] = [
        ("scripts/build-app.sh", "the user's interactive install path: it reads the user's search list and signing keychain and asks to unlock it, as the user runs it"),
        ("scripts/setup-signing.sh", "the user's interactive install path: it makes the user's signing keychain at the user's own password prompt"),
        ("scripts/test-signing.sh", "the signing scripts' own check, run by hand: each security call is on a scratch HOME (its search list), its keychains made with their password on stdin, never the user's"),
    ]

    /// A use in `file`, on a line containing `text`, allowed for `reason`. An entry nothing matches fails the lint.
    static let allowed: [(file: String, text: String, reason: String)] = [
        ("Tests/VibeSwitcherTests/BriefingKeyTests.swift", "$(security find-generic-password -w)",
         "a line BriefingKey.parse is given, and refuses: nothing runs it"),
        ("Tests/VibeCoreTests/AppUpdateTests.swift", "== \"security unlock-keychain '\\(keychain.path)' && scripts/build-app.sh --install\"",
         "the command AppUpdate hands the user to run in a real terminal, compared as text: nothing runs it"),
        // The live test runs only when the user asks for it (VIBESWITCHER_KEYCHAIN_LIVE=1, KeychainLintTests), in the
        // user's own login keychain, and reads the access list of the item it made: it changes none.
        ("Tests/VibeCoreTests/KeychainLiveTests.swift", "SecKeychainItemCopyAccess", "the user's opt-in live test reads its item's access list"),
        ("Tests/VibeCoreTests/KeychainLiveTests.swift", "SecAccessCopyMatchingACLList", "the user's opt-in live test reads its item's access list"),
        ("Tests/VibeCoreTests/KeychainLiveTests.swift", "SecKeychainPromptSelector", "the user's opt-in live test reads its item's access list"),
        ("Tests/VibeCoreTests/KeychainLiveTests.swift", "SecACLCopyContents", "the user's opt-in live test reads its item's access list"),
        ("Tests/VibeCoreTests/KeychainLiveTests.swift", "SecTrustedApplicationCopyData", "the user's opt-in live test reads its item's access list"),
    ]

    /// `security SUBCOMMAND` where it could run: a hyphenated subcommand, one of the plain ones, or one from a variable
    /// (`"$@"`, `$verb`). "the security checklist" isn't one.
    static let securityCall = try! Regex(#"(?:^|[^A-Za-z0-9_.\-/])(?:/usr/bin/)?security\s+("?\$[^\s"]*|[a-z]+(?:-[a-z]+)+|import|export|authorize|authorizationdb|cms|leaks|smartcards|filevault)\b"#)
    /// The subcommands that read only, and never ask: the search list (not set), certificates, an error code.
    static let readOnly: Set<String> = ["list-keychains", "find-certificate", "verify-cert", "error", "help"]
    /// security started from code: `["security", …]` handed to env or a shell, or its path.
    static let securityLaunch = try! Regex(#"\[\s*["'](?:/usr/bin/)?security["']\s*,|["']/usr/bin/security["']"#)
    /// A SecItem call, and the no-UI flag its query must hold.
    static let secItemCall = try! Regex(#"\bSec[I]tem(?:Add|CopyMatching|Update|Delete)\s*\("#)
    static let noUI = "kSecUseAuthenticationUIFail"
    /// A legacy keychain or ACL call (SecKeychainLock, …SetSettings, …SetSearchList, …ItemSetAccess, SecAccessCreate,
    /// SecTrustedApplicationCreateFromPath, …), named in its first capture.
    static let aclOrKeychainCall = try! Regex(#"\b(Sec(?:[K]eychain|Access|ACL|TrustedApplication)[A-Za-z]*)\s*\("#)
    /// The lock-state probe build-app.sh and test-signing.sh use: it opens a keychain and reads its status, no dialog.
    static let lockStateProbe: Set<String> = ["Sec" + "KeychainOpen", "Sec" + "KeychainGetStatus", "Sec" + "KeychainStatus"]

    struct Finding: Equatable, CustomStringConvertible {
        let file: String, line: Int, text: String, rule: String
        var description: String { "\(file):\(line): \(rule): \(text.trimmingCharacters(in: .whitespaces))" }
    }

    /// Every text file under `root`/scripts and `root`/Tests, by its path from `root`, with its lines; files that
    /// aren't UTF-8 (a .gz) left out, and the helper and this file.
    static func files(under root: URL) -> [(path: String, lines: [String])] {
        var found: [(String, [String])] = []
        for folder in ["scripts", "Tests"] {
            let base = root.appendingPathComponent(folder)
            for sub in (FileManager.default.subpaths(atPath: base.path) ?? []).sorted() {
                let path = folder + "/" + sub
                guard path != helper, path != me else { continue }
                var isFolder: ObjCBool = false
                let url = base.appendingPathComponent(sub)
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue,
                      let data = FileManager.default.contents(atPath: url.path),
                      let text = String(data: data, encoding: .utf8) else { continue }
                found.append((path, text.components(separatedBy: "\n")))
            }
        }
        return found
    }

    /// Whether `line` is only a comment in `path`'s language: `//` in Swift and JavaScript, `#` in the rest.
    static func isComment(_ line: String, in path: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return [".swift", ".js", ".mjs"].contains { path.hasSuffix($0) } ? trimmed.hasPrefix("//") : trimmed.hasPrefix("#")
    }

    /// The text from the first `(`, `[` or `{` at or after `start` (line `index`) to where it closes, at most 40 lines.
    static func balanced(_ lines: [String], from index: Int, at start: String.Index? = nil) -> String {
        var depth = 0, opened = false, text = ""
        for row in index..<min(lines.count, index + 40) {
            let line = lines[row]
            let chars = row == index ? line[(start ?? line.startIndex)...] : line[...]
            for char in chars {
                text.append(char)
                if "([{".contains(char) { depth += 1; opened = true } else if ")]}".contains(char) { depth -= 1 }
                if opened, depth == 0 { return text }
            }
            text.append("\n")
        }
        return text
    }

    /// Whether the SecItem call at `lines[index]` (its `(` at `open`) asks with no UI: the flag in its arguments, or
    /// in the definition of the query it's handed (`query as CFDictionary`), or set on that query in the file.
    static func asksWithoutUI(_ lines: [String], at index: Int, open: String.Index) -> Bool {
        let call = balanced(lines, from: index, at: open)
        if call.contains(noUI) { return true }
        guard let name = call.firstMatch(of: #/^\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:as\s+CFDictionary)?\s*[,)]/#)?.1 else { return false }
        for (row, line) in lines.enumerated() {
            // From its `=`: a type annotation's brackets (`: [String: Any]`) come before it.
            if let definition = line.firstMatch(of: try! Regex(#"\b(?:let|var)\s+\#(name)\b[^=]*="#)),
               balanced(lines, from: row, at: definition.range.upperBound).contains(noUI) { return true }
            if line.contains("\(name)[") && line.contains(noUI) { return true }
        }
        return false
    }

    /// What the lint flags under `root`, in file and line order, before the allowed entries are taken out.
    static func findings(under root: URL) -> [Finding] {
        var flagged: [Finding] = []
        for (path, lines) in files(under: root) {
            for (index, line) in lines.enumerated() where !isComment(line, in: path) {
                func flag(_ rule: String) { flagged.append(Finding(file: path, line: index + 1, text: line, rule: rule)) }
                let unsafe = line.matches(of: securityCall).contains { match in
                    let subcommand = String(match.output[1].substring ?? "")
                    guard readOnly.contains(subcommand) else { return true }
                    return subcommand == "list-keychains" && line[match.range.upperBound...].contains(#/\s-s\b/#)
                }
                if unsafe || line.contains(securityLaunch) { flag("security outside \(helper)'s keychain_call") }
                for match in line.matches(of: secItemCall) {
                    let open = line[match.range].lastIndex(of: "(")!
                    if !asksWithoutUI(lines, at: index, open: open) { flag("SecItem call without \(noUI)") }
                }
                if line.matches(of: aclOrKeychainCall).contains(where: { !lockStateProbe.contains(String($0.output[1].substring ?? "")) }) {
                    flag("keychain or ACL call")
                }
            }
        }
        return flagged
    }

    /// The findings left once the allowed files and entries are taken out, and the entries nothing matched.
    static func check(under root: URL) -> (offending: [Finding], unused: [String]) {
        var used = Set<Int>()
        let offending = findings(under: root).filter { finding in
            if allowedFiles.contains(where: { $0.file == finding.file }) { return false }
            guard let entry = allowed.firstIndex(where: { $0.file == finding.file && finding.text.contains($0.text) }) else { return true }
            used.insert(entry)
            return false
        }
        let unused = allowed.indices.filter { !used.contains($0) }.map { "\(allowed[$0].file) | \(allowed[$0].text)" }
            + allowedFiles.filter { !FileManager.default.fileExists(atPath: root.appendingPathComponent($0.file).path) }.map(\.file)
        return (offending, unused)
    }

    @Test func noScriptOrTestCanPutAKeychainDialogUp() {
        let (offending, unused) = Self.check(under: Self.repo)
        #expect(offending == [], """
            these can put a Keychain password dialog on the user's screen: call security through \(Self.helper) \
            (scratch_keychain, then keychain_call), pass \(Self.noUI) on each SecItem call, and make no SecKeychain or \
            ACL call; or allow the line in KeychainCallLintTests.allowed, with its reason:
            \(offending.map(\.description).joined(separator: "\n"))
            """)
        #expect(unused == [], "allowed entries nothing matches any more: take them out")
        #expect(Self.allowed.allSatisfy { !$0.reason.isEmpty } && Self.allowedFiles.allSatisfy { !$0.reason.isEmpty })
    }

    /// A planted offending line of each kind is named with its line; what's dialog-proof isn't. Built here from parts,
    /// so this file holds no call KeychainLintTests would take for one.
    @Test func aPlantedOffenderIsNamedWithItsLine() throws {
        let temp = Scratch()
        let root = temp.url("keychain-call-lint")
        let item = "Sec" + "Item", keychain = "Sec" + "Keychain"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts/lib"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tests/SomeTests"), withIntermediateDirectories: true)
        let script = """
            #!/bin/bash
            security add-generic-password -s probe -a me -w x "$kc"
            pw=$(security find-generic-password -s probe -w)
            security delete-generic-password -s probe
            security unlock-keychain "$kc"
            security lock-keychain
            security set-keychain-settings -t 300
            security default-keychain -s "$kc"
            security list-keychains -d user -s "$kc"
            security login-keychain
            security set-key-partition-list -S apple-tool: "$kc"
            exec /usr/bin/security "$@"
            if true; then security add-trusted-cert -r trustRoot c.pem; fi
            # security add-generic-password in a comment
            echo "the security checklist"
            security list-keychains -d user
            security find-certificate -c Name -p
            keychain_call add-generic-password -s probe -a me -w x "$scratch_keychain"
            print(score['security'])
            """
        try script.write(to: root.appendingPathComponent("scripts/probe.sh"), atomically: true, encoding: .utf8)
        try "security add-generic-password\n".write(to: root.appendingPathComponent(Self.helper), atomically: true, encoding: .utf8)
        let swift = """
            import Security
            func probe(_ service: String) {
                let bad: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
                \(item)Add(bad as CFDictionary, nil)
                \(item)Delete([kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: service] as CFDictionary)
                let good: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                           kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
                \(item)CopyMatching(good as CFDictionary, nil)
                \(item)Delete([kSecClass as String: kSecClassGenericPassword, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail] as CFDictionary)
                var later: [String: Any] = [kSecClass as String: kSecClassGenericPassword]
                later[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
                \(item)Update(later as CFDictionary, [:] as CFDictionary)
                \(keychain)ItemSetAccess(item, access)
                \(keychain)SetUserInteractionAllowed(false)
                \(keychain)Lock(nil)
                SecAccessCreate("probe" as CFString, nil, &access)
                SecTrustedApplicationCreateFromPath(nil, &app)
                guard \(keychain)Open(path, &kc) == errSecSuccess, \(keychain)GetStatus(kc, &status) == errSecSuccess else { return }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = ["security", "find-generic-password"]
                #expect(\(item)CopyMatching(bad as CFDictionary, nil) == errSecSuccess)
                // \(item)Add(bad as CFDictionary, nil) in a comment
            }
            """
        try swift.write(to: root.appendingPathComponent("Tests/SomeTests/Probe.swift"), atomically: true, encoding: .utf8)
        let found = Self.findings(under: root).map { "\($0.file):\($0.line)" }
        #expect(found == (2...13).map { "scripts/probe.sh:\($0)" }
            + [4, 5, 14, 15, 16, 17, 18, 21, 22, 23].map { "Tests/SomeTests/Probe.swift:\($0)" })
    }

    // MARK: The helper, run with a stand-in security: nothing here reaches the real one or any keychain.

    /// Runs `body` in bash with the helper sourced, keychain_call_timeout 1 s, and a stand-in `security` (`standIn`, a
    /// bash body that logs each call) first on a PATH that holds no real one; returns the output, the stand-in's log
    /// and the exit status, once bash has ended (a hang guard: a call the timeout didn't end would hang it).
    func runHelper(_ body: String, standIn: String, in folder: URL) async throws -> (output: String, log: [String], status: Int32) {
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("security.log")
        try """
            #!/bin/bash
            printf '%s|%s|%s\\n' "$HOME" "$CFFIXED_USER_HOME" "$*" >> '\(log.path)'
            \(standIn)
            exit 0
            """.write(to: bin.appendingPathComponent("security"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("security").path)
        // od and tr from /usr/bin, where the real security is: linked here alone, so PATH needs only this and /bin.
        for tool in ["od", "tr"] {
            try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent(tool).path, withDestinationPath: "/usr/bin/" + tool)
        }
        let script = folder.appendingPathComponent("run.sh")
        try """
            set -uo pipefail
            source '\(Self.repo.appendingPathComponent("scripts/lib/scratch.sh").path)'
            keychain_call_timeout=1
            source '\(Self.repo.appendingPathComponent(Self.helper).path)'
            \(body)
            """.write(to: script, atomically: true, encoding: .utf8)
        let outputFile = folder.appendingPathComponent("output.txt")
        FileManager.default.createFile(atPath: outputFile.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, folder.path]
        process.environment = ["PATH": bin.path + ":/bin", "HOME": folder.path]
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let ended = await exited(process)
        try output.close()
        #expect(ended, "the helper's script didn't end: a call through it blocked")
        let logged = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return (try String(contentsOf: outputFile, encoding: .utf8), logged.split(separator: "\n").map(String.init), process.terminationStatus)
    }

    /// scratch_keychain makes the keychain in the folder it's given, unlocked with a password, then at once with no
    /// timeout and no lock on sleep; each call is on a scratch HOME beside it, never the search list; it's deleted on
    /// exit. keychain_call runs an item call that names it, and refuses, before security runs, one that doesn't, one
    /// with -T, and the subcommands that lock, unlock, or take the default keychain or the search list.
    @Test func theHelperKeepsToItsScratchKeychain() async throws {
        let temp = Scratch()
        let folder = temp.url("scratch-keychain")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (output, log, status) = try await runHelper("""
            scratch_keychain "$1"; echo "made=$? $scratch_keychain"
            keychain_call add-generic-password -s probe -a me -w x "$scratch_keychain"; echo "add=$?"
            keychain_call find-generic-password -s probe -a me; echo "unnamed=$?"
            keychain_call add-generic-password -s probe -a me -w x -T /bin/ls "$scratch_keychain"; echo "acl=$?"
            for sub in lock-keychain unlock-keychain set-keychain-settings default-keychain list-keychains login-keychain \\
                set-key-partition-list dump-keychain import; do
                keychain_call $sub "$scratch_keychain"; echo "$sub=$?"
            done
            """, standIn: "", in: folder)
        let keychain = folder.appendingPathComponent("vs-scratch.keychain-db").path
        let home = folder.appendingPathComponent("vs-keychain-home").path
        #expect(status == 0, "\(output)")
        #expect(output.contains("made=0 \(keychain)\n") && output.contains("add=0\n") && output.contains("unnamed=2\n") && output.contains("acl=2\n"), "\(output)")
        for sub in ["lock-keychain", "unlock-keychain", "set-keychain-settings", "default-keychain", "list-keychains", "login-keychain",
                    "set-key-partition-list", "dump-keychain", "import"] {
            #expect(output.contains("\(sub)=2\n"), "\(sub): \(output)")
        }
        // What security was asked, in order: made with a password, settings with no options (no timeout, no lock on
        // sleep), the one item call, deleted on exit; all on the scratch HOME.
        #expect(log.count == 4, "\(log)")
        #expect(log.allSatisfy { $0.hasPrefix("\(home)|\(home)|") }, "\(log)")
        let calls = log.map { $0.split(separator: "|", maxSplits: 2).last.map(String.init) ?? "" }
        let made = try #require(calls.first?.wholeMatch(of: #/create-keychain -p ([0-9a-f]{24}) (.+)/#))
        #expect(made.2 == keychain)
        #expect(Array(calls.dropFirst()) == ["set-keychain-settings \(keychain)", "add-generic-password -s probe -a me -w x \(keychain)",
                                            "delete-keychain \(keychain)"])
    }

    /// A call through the helper can't block: a stand-in security that never answers (as one waiting on a dialog) is
    /// killed at the timeout, and the call fails with 124 and says so; the script goes on. Shown with a stand-in only:
    /// a real locked keychain would mean a real dialog, so that case rests on the lint (nothing locks the scratch one).
    @Test func aCallThroughTheHelperEndsAtItsTimeout() async throws {
        let temp = Scratch()
        let folder = temp.url("scratch-keychain-hang")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (output, log, status) = try await runHelper("""
            scratch_keychain "$1"; echo "made=$?"
            keychain_call find-generic-password -s probe -w "$scratch_keychain"; echo "find=$?"
            """, standIn: #"[[ $1 == find-generic-password ]] && exec /bin/sleep 600"#, in: folder)
        #expect(status == 0, "\(output)")
        #expect(output.contains("made=0\n") && output.contains("find=124\n"), "\(output)")
        #expect(output.contains("security find-generic-password timed out after 1 s (killed)"), "\(output)")
        #expect(log.last?.hasSuffix("|delete-keychain \(folder.appendingPathComponent("vs-scratch.keychain-db").path)") == true, "\(log)")
    }
}
