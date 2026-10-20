import Foundation
import Testing

/// No script under scripts/ runs swift build, swift test or swift run with the TMPDIR it was given: SwiftPM leaves empty
/// TemporaryDirectory.XXXXXX folders in TMPDIR at each (7 a no-op swift build, 5 a swift test --skip-build) and never
/// removes them, and 32,871 had piled up in the user's /var/folders/…/T/ by 2026-10-20 (build-app.sh, ui-bench.sh,
/// test-under-load.sh and the sessions' own runs; scripts/test.sh alone had a scratch TMPDIR). Each script sources
/// scripts/lib/scratch.sh and calls its scratch_tmpdir before the first one: one helper, not copies of it.
struct ScriptScratchLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let helper = "scripts/lib/scratch.sh"
    let temp = Scratch()

    /// `swift build`, `swift test` or `swift run` where a command starts: at the start of a line, after `;`, `&`, `|`,
    /// `(` or `$(`, a keyword, or variables set in front. "run swift build" in a message isn't one.
    static let invocation = try! Regex(#"(^|[;&|(]|\b(then|do|else|exec|command|xcrun|env|time))\s*([A-Za-z_][A-Za-z0-9_]*=\S*\s+)*swift\s+(build|test|run)\b"#)
    static let sourced = try! Regex(#"^\s*(source|\.)\s+("?\$?[^ ]*/)?scripts/lib/scratch\.sh"?\s*$"#)
    static let scratched = try! Regex(#"^\s*scratch_tmpdir\s"#)
    /// TMPDIR set (`TMPDIR=…` in front of a command or alone, `${TMPDIR=…}`) or exported: only the helper does.
    static let setsTMPDIR = try! Regex(#"(^|[^A-Za-z0-9_])TMPDIR=|\bexport\s+(-\S+\s+)*([A-Za-z_][A-Za-z0-9_]*(=\S*)?\s+)*TMPDIR\b"#)
    /// A trap on EXIT: it replaces the helper's, and the scratch folder would stay. Scripts use on_exit.
    static let exitTrap = try! Regex(#"(^|[;&|(]|\b(then|do|else))\s*trap\s.*\s(EXIT|SIGEXIT|0)(\s|;|$)"#)

    /// "scripts/…:12" for each line of code under `root`/scripts matching `pattern`, the helper's left out, in order.
    static func lines(under root: URL, matching pattern: Regex<AnyRegexOutput>) throws -> [String] {
        let scripts = root.appendingPathComponent("scripts")
        let files = (FileManager.default.subpaths(atPath: scripts.path) ?? []).filter { $0.hasSuffix(".sh") && "scripts/" + $0 != helper }.sorted()
        var flagged: [String] = []
        for file in files {
            let text = try String(contentsOf: scripts.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") && line.contains(pattern) {
                flagged.append("scripts/\(file):\(index + 1)")
            }
        }
        return flagged
    }

    /// "scripts/…:12" for each line under `root`/scripts that runs one before the script has sourced the helper and
    /// called scratch_tmpdir, in order. Lines that are only a comment name these, they don't run them.
    static func unscratched(under root: URL) throws -> [String] {
        let scripts = root.appendingPathComponent("scripts")
        let files = (FileManager.default.subpaths(atPath: scripts.path) ?? []).filter { $0.hasSuffix(".sh") && "scripts/" + $0 != helper }.sorted()
        var flagged: [String] = []
        for file in files {
            let text = try String(contentsOf: scripts.appendingPathComponent(file), encoding: .utf8)
            var source = false, scratch = false
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
                if line.contains(sourced) { source = true }
                if source, line.contains(scratched) { scratch = true }
                if line.contains(invocation), !scratch { flagged.append("scripts/\(file):\(index + 1)") }
            }
        }
        return flagged
    }

    @Test func everyScriptRunsSwiftToolsInAScratchTMPDIR() throws {
        let flagged = try Self.unscratched(under: Self.repo)
        #expect(flagged == [], """
            these run swift build, swift test or swift run with the user's TMPDIR, where SwiftPM leaves folders it never \
            removes: `source scripts/lib/scratch.sh` and call `scratch_tmpdir NAME` before them:
            \(flagged.joined(separator: "\n"))
            """)
    }

    /// The scripts that run them all use the one helper, and none makes a TMPDIR of its own beside it.
    @Test func theScriptsShareOneHelper() throws {
        for script in ["scripts/test.sh", "scripts/build-app.sh", "scripts/ui-bench.sh", "scripts/test-under-load.sh"] {
            let text = try String(contentsOf: Self.repo.appendingPathComponent(script), encoding: .utf8)
            #expect(text.components(separatedBy: "\n").contains { $0.contains(Self.invocation) }, "\(script) runs no swift tool any more")
            #expect(text.components(separatedBy: "\n").contains { $0.contains(Self.sourced) }, "\(script) doesn't source \(Self.helper)")
        }
        #expect(try Self.lines(under: Self.repo, matching: Self.setsTMPDIR) == [], "these set TMPDIR: use \(Self.helper)'s scratch_tmpdir or with_tmpdir")
        #expect(try Self.lines(under: Self.repo, matching: Self.exitTrap) == [], "these trap EXIT, replacing \(Self.helper)'s: use on_exit")
    }

    /// `TMPDIR=/elsewhere swift build` after the helper, an export, a default set in passing: each would send SwiftPM's
    /// folders where nothing removes them. Reading TMPDIR, or naming it in a message or a comment, is fine.
    @Test func aScriptSettingTMPDIRIsNamedWithItsLine() throws {
        let root = temp.url("lint-tmpdir")
        let scripts = root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try """
            #!/bin/bash
            source scripts/lib/scratch.sh
            scratch_tmpdir vs-x
            TMPDIR=/elsewhere swift build
            export TMPDIR=/elsewhere
            TMPDIR=/elsewhere; export TMPDIR
            echo "${TMPDIR=/elsewhere}"
            env TMPDIR=/elsewhere swift test
            home=$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")
            # TMPDIR=/elsewhere in a comment
            echo "left in TMPDIR: none"
            MYTMPDIR=/x true
            """.write(to: scripts.appendingPathComponent("set.sh"), atomically: true, encoding: .utf8)
        try "export TMPDIR=/x\n".write(to: root.appendingPathComponent(Self.helper), atomically: true, encoding: .utf8)
        #expect(try Self.lines(under: root, matching: Self.setsTMPDIR) == (4...8).map { "scripts/set.sh:\($0)" })
    }

    /// A `trap … EXIT` after the helper's would replace it: the scratch folder would never be removed. Other signals,
    /// on_exit, and the word in a message or a comment are fine.
    @Test func aScriptTrappingEXITIsNamedWithItsLine() throws {
        let root = temp.url("lint-trap")
        let scripts = root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try """
            #!/bin/bash
            source scripts/lib/scratch.sh
            scratch_tmpdir vs-x
            trap 'rm -r "$home"' EXIT
            trap cleanup INT TERM EXIT
            trap - EXIT
            [[ -n $x ]] && trap cleanup 0
            trap 'exit 130' INT TERM
            on_exit cleanup
            # trap cleanup EXIT in a comment
            echo "on EXIT the trap runs"
            """.write(to: scripts.appendingPathComponent("trap.sh"), atomically: true, encoding: .utf8)
        try "trap scratch_exit EXIT\n".write(to: root.appendingPathComponent(Self.helper), atomically: true, encoding: .utf8)
        #expect(try Self.lines(under: root, matching: Self.exitTrap) == (4...7).map { "scripts/trap.sh:\($0)" })
    }

    /// A script running them without the helper, or before it, is named with its line; one that runs them after it,
    /// a message naming one, and a comment aren't.
    @Test func aScriptWithoutTheHelperIsNamedWithItsLine() throws {
        let root = temp.url("lint")
        let scripts = root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts.appendingPathComponent("lib"), withIntermediateDirectories: true)
        let bare = """
            #!/bin/bash
            # swift build in a comment
            swift build -c release
            BIN="$(swift build --show-bin-path)"
            echo "the build failed: run swift build --build-tests"
            cd x && swift test --filter A
            FOO=1 swift run tool
            if true; then swift build; fi
            """
        let late = """
            #!/bin/bash
            source scripts/lib/scratch.sh
            swift build
            scratch_tmpdir vs-late
            swift test
            """
        let calledAlone = """
            #!/bin/bash
            scratch_tmpdir vs-alone
            swift build
            """
        try bare.write(to: scripts.appendingPathComponent("bare.sh"), atomically: true, encoding: .utf8)
        try late.write(to: scripts.appendingPathComponent("late.sh"), atomically: true, encoding: .utf8)
        try calledAlone.write(to: scripts.appendingPathComponent("lib/alone.sh"), atomically: true, encoding: .utf8)
        // The helper itself, and the real scripts copied over, aren't flagged.
        try "swift build\n".write(to: root.appendingPathComponent(Self.helper), atomically: true, encoding: .utf8)
        for script in ["test.sh", "build-app.sh", "ui-bench.sh", "test-under-load.sh"] {
            try FileManager.default.copyItem(at: Self.repo.appendingPathComponent("scripts/" + script), to: scripts.appendingPathComponent(script))
        }
        #expect(try Self.unscratched(under: root) == ["scripts/bare.sh:3", "scripts/bare.sh:4", "scripts/bare.sh:6", "scripts/bare.sh:7",
                                                      "scripts/bare.sh:8", "scripts/late.sh:3", "scripts/lib/alone.sh:3"])
    }

    /// The helper's scratch: a short folder under /tmp, 0700, TMPDIR its tmp/ (0700), removed when the script exits:
    /// normally, on Ctrl-C (SIGINT) and on TERM, after the script's own exit hooks, keeping its exit status.
    @Test func theHelpersScratchGoesWhenTheScriptExits() throws {
        let script = temp.url("script.sh")
        try """
            set -uo pipefail
            source '\(Self.repo.appendingPathComponent(Self.helper).path)'
            scratch_tmpdir vs-lint
            on_exit 'echo "hook $tool_scratch"'
            echo "$TMPDIR"
            [[ ${1:-} == cue ]] && read -r _
            [[ ${1:-} == wait ]] && { sleep 30 & sleeper=$!; on_exit 'kill $sleeper'; wait $sleeper; }
            exit 3
            """.write(to: script, atomically: true, encoding: .utf8)
        for signal in [nil, SIGINT, SIGTERM] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            // Each holds its scratch until told: an exit waits on its cue (its input closing), so the folder's modes are
            // read while it's there, not after a quick script already removed it (under load it once had).
            process.arguments = [script.path, signal == nil ? "cue" : "wait"]
            let pipe = Pipe(), cue = Pipe()
            process.standardOutput = pipe
            process.standardInput = cue
            try process.run()
            var output = Data()
            // The first line is TMPDIR: once it's there, the scratch is made.
            while !output.contains(UInt8(ascii: "\n")) {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                output += chunk
            }
            let tmpdir = String(decoding: output, as: UTF8.self).components(separatedBy: "\n")[0]
            #expect(tmpdir.wholeMatch(of: #/\/tmp\/vs-lint\.[A-Za-z0-9]{6}\/tmp\//#) != nil, "\(tmpdir)")
            let scratch = (tmpdir as NSString).deletingLastPathComponent
            #expect(try FileManager.default.attributesOfItem(atPath: scratch)[.posixPermissions] as? Int == 0o700)
            #expect(try FileManager.default.attributesOfItem(atPath: tmpdir)[.posixPermissions] as? Int == 0o700)
            if let signal { kill(process.processIdentifier, signal) } else { try cue.fileHandleForWriting.close() }
            output += pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(!FileManager.default.fileExists(atPath: scratch), "\(signal.map { "signal \($0)" } ?? "exit"): \(scratch) is still there")
            #expect(String(decoding: output, as: UTF8.self).contains("hook \(scratch)"))
            if signal == nil { #expect(process.terminationStatus == 3) }
        }
    }
}
