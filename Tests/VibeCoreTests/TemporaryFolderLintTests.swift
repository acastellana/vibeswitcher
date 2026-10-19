import Foundation
import Testing

/// No test uses the system temporary folder itself (FileManager's temporaryDirectory, NSTemporaryDirectory(), a /tmp
/// path): it goes in scratchRoot, so parallel runs, the merge runner and the load harness never share or leak files
/// there. 2026-10-19: scripts/test-under-load.sh refused every run on project-lead for KeepAwakeTests.swift:246,
/// BriefingSnapshots.swift:42 and PhoneBriefingTests.swift:245, all added that day and green here, where nothing
/// checked it. The rule is scripts/temporary-folder-lint.txt, read here and by scripts/temporary-folder-lint.sh (the
/// harness runs it), so a full run here fails on the lines the harness would refuse.
struct TemporaryFolderLintTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let script = repo.appendingPathComponent("scripts/temporary-folder-lint.sh").path
    let temp = Scratch()

    /// A use allowed in `file`, on a line containing `text`, for `reason`.
    struct Allowed: Hashable {
        let file: String, text: String, reason: String
    }

    /// The patterns and allowed uses in scripts/temporary-folder-lint.txt.
    static func rules() throws -> (patterns: [Regex<AnyRegexOutput>], allowed: [Allowed]) {
        let list = try String(contentsOf: repo.appendingPathComponent("scripts/temporary-folder-lint.txt"), encoding: .utf8)
        var patterns: [Regex<AnyRegexOutput>] = []
        var allowed: [Allowed] = []
        for line in list.components(separatedBy: "\n") {
            if line.hasPrefix("pattern: ") { patterns.append(try Regex(String(line.dropFirst("pattern: ".count)))) }
            if line.hasPrefix("allow: ") {
                let fields = line.dropFirst("allow: ".count).components(separatedBy: " | ")
                allowed.append(Allowed(file: fields[0], text: fields.count > 1 ? fields[1] : "", reason: fields.count > 2 ? fields[2] : ""))
            }
        }
        return (patterns, allowed)
    }

    /// "Tests/…/File.swift:12" for each use in the Swift files under `root`/Tests that isn't allowed, in order; and the
    /// allowed entries some use matched. A line that's only a comment names these, it doesn't use them.
    static func uses(under root: URL) throws -> (flagged: [String], used: Set<Allowed>) {
        let (patterns, allowed) = try rules()
        let tests = root.appendingPathComponent("Tests")
        let files = (FileManager.default.subpaths(atPath: tests.path) ?? []).filter { $0.hasSuffix(".swift") }.sorted()
        var flagged: [String] = []
        var used: Set<Allowed> = []
        for file in files {
            let path = "Tests/" + file
            let text = try String(contentsOf: tests.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//"), patterns.contains(where: { line.contains($0) }) else { continue }
                let allowing = allowed.filter { $0.file == path && line.contains($0.text) }
                if allowing.isEmpty { flagged.append("\(path):\(index + 1)") } else { used.formUnion(allowing) }
            }
        }
        return (flagged, used)
    }

    /// What scripts/temporary-folder-lint.sh names under `root`, as "file:line", and its exit status.
    static func harnessLint(under root: URL) throws -> (status: Int32, flagged: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script, root.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let flagged = output.split(separator: "\n").map { $0.split(separator: ":", maxSplits: 2).prefix(2).joined(separator: ":") }
        return (process.terminationStatus, flagged)
    }

    @Test func noTestUsesTheSystemTemporaryFolder() throws {
        let flagged = try Self.uses(under: Self.repo).flagged
        #expect(flagged == [], """
            these use the system temporary folder: put them under scratchRoot (a Scratch; Scratch.shortFolder for a socket), \
            or allow one in scripts/temporary-folder-lint.txt with its reason:
            \(flagged.joined(separator: "\n"))
            """)
    }

    /// Each allowed use says why, and is still there (a test changed or gone would leave an entry that excuses nothing).
    @Test func everyAllowedUseHasAReasonAndIsStillThere() throws {
        let allowed = try Self.rules().allowed
        #expect(!allowed.isEmpty)
        #expect(allowed.filter { $0.file.isEmpty || $0.text.isEmpty || $0.reason.trimmingCharacters(in: .whitespaces).isEmpty } == [])
        let used = try Self.uses(under: Self.repo).used
        #expect(allowed.filter { !used.contains($0) }.map { "\($0.file) | \($0.text)" } == [])
    }

    /// The load harness runs the same lint, and it names what this test names: nothing, on this tree.
    @Test func theLoadHarnessAgrees() throws {
        let harness = try String(contentsOf: Self.repo.appendingPathComponent("scripts/test-under-load.sh"), encoding: .utf8)
        #expect(harness.contains("scripts/temporary-folder-lint.sh"))
        let lint = try Self.harnessLint(under: Self.repo)
        let flagged = try Self.uses(under: Self.repo).flagged
        #expect(lint.flagged == flagged)
        #expect(lint.status == 0, "the harness's lint names \(lint.flagged.joined(separator: ", "))")
    }

    /// A new test file using the temporary folder fails here and in the harness, on the same lines; what's only a
    /// comment, or a name that merely starts with "tmp", doesn't.
    @Test func aTestUsingTheTemporaryFolderIsNamedWithItsLine() throws {
        let root = temp.url("lint")
        let folder = root.appendingPathComponent("Tests/VibeCoreTests")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let example = """
            import Foundation
            // NSTemporaryDirectory() named in a comment
            let folder = NSTemporaryDirectory() + "x"  // the lint's example
            let url = FileManager.default.temporaryDirectory  // the lint's example
            let socket = "/tmp/vsh-\\(UUID()).sock"  // the lint's example
            let spelled = "/private/tmp"  // the lint's example
            let name = "/tmpfoo", tmp = "tmp"
            """
        try example.write(to: folder.appendingPathComponent("ScratchTests.swift"), atomically: true, encoding: .utf8)
        let expected = (3...6).map { "Tests/VibeCoreTests/ScratchTests.swift:\($0)" }
        #expect(try Self.uses(under: root).flagged == expected)
        let lint = try Self.harnessLint(under: root)
        #expect(lint.flagged == expected)
        #expect(lint.status == 1)
    }
}
