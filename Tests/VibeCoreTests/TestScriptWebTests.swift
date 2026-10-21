import Foundation
import Testing

/// scripts/test.sh runs the phone's web tests (Tests/Web/*.test.mjs) with node after swift test, in its scratch home
/// and TMPDIR, names a failing one and says how many passed; without node on PATH it stops, naming it, before anything
/// runs. Phone tests had been run only by hand at merge twice (PhoneWebTests skips them without node). Driven through
/// `scripts/test.sh --web DIR` with a fake node first on PATH: no swift build, and the same with or without node here.
struct TestScriptWebTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let temp = Scratch()

    /// A folder with a fake `node` in bin/ (it says where it ran, HOME and TMPDIR, and fails a file holding FAIL) and
    /// `tests` in web/, each name to its text.
    func folder(_ tests: [String: String]) throws -> URL {
        let root = temp.url("web-run")
        let bin = root.appendingPathComponent("bin"), web = root.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let node = bin.appendingPathComponent("node")
        try """
            #!/bin/bash
            echo "ran $(basename "$1") HOME=$HOME TMPDIR=$TMPDIR"
            grep -q FAIL "$1" && { echo "assertion failed in $(basename "$1")"; exit 3; }
            exit 0
            """.write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        for (name, text) in tests { try text.write(to: web.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return root
    }

    /// `scripts/test.sh --web DIR` with PATH `path`: its exit status and all of its output.
    func run(_ dir: URL, path: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repo.appendingPathComponent("scripts/test.sh").path, "--web", dir.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    @Test func passingWebTestsPassWithOneSummaryLine() throws {
        let root = try folder(["a.test.mjs": "ok", "b.test.mjs": "ok", "helper.mjs": "FAIL: not a test"])
        let (status, output) = try run(root.appendingPathComponent("web"), path: root.path + "/bin:/usr/bin:/bin")
        #expect(status == 0, "\(output)")
        #expect(output.contains("ran a.test.mjs") && output.contains("ran b.test.mjs"), "\(output)")
        #expect(!output.contains("helper.mjs"), "only *.test.mjs run: \(output)")
        #expect(output.components(separatedBy: "\n").filter { $0.hasPrefix("web tests:") } == ["web tests: 2 of 2 passed"], "\(output)")
        // Each in the run's scratch home and TMPDIR, never the caller's.
        for line in output.components(separatedBy: "\n") where line.hasPrefix("ran ") {
            #expect(line.wholeMatch(of: #/ran \w\.test\.mjs HOME=\/tmp\/vs-test\.(\w{6})\/home TMPDIR=\/tmp\/vs-test\.\1\/tmp\//#) != nil, "\(line)")
        }
    }

    @Test func aFailingWebTestFailsTheRunNamingTheFile() throws {
        let root = try folder(["a.test.mjs": "ok", "b.test.mjs": "FAIL", "c.test.mjs": "ok"])
        let web = root.appendingPathComponent("web")
        let (status, output) = try run(web, path: root.path + "/bin:/usr/bin:/bin")
        #expect(status == 1, "\(output)")
        // The ones after it still run, and its own output stays in the log.
        #expect(output.contains("ran c.test.mjs") && output.contains("assertion failed in b.test.mjs"), "\(output)")
        let failed = web.appendingPathComponent("b.test.mjs").path
        #expect(output.contains("WEB TEST FAILED: \(failed) (exit 3)"), "\(output)")
        #expect(!output.contains("WEB TEST FAILED: \(web.appendingPathComponent("a.test.mjs").path)"), "\(output)")
        #expect(output.contains("web tests: 2 of 3 passed; failed: \(failed)"), "\(output)")
    }

    /// No web tests where they should be is a failure too, not a pass with nothing run.
    @Test func noWebTestsFailsTheRun() throws {
        let root = try folder([:])
        let (status, output) = try run(root.appendingPathComponent("web"), path: root.path + "/bin:/usr/bin:/bin")
        #expect(status == 1, "\(output)")
        #expect(output.contains("web tests: none in "), "\(output)")
    }

    /// Without node the run stops before anything, saying node is missing: never a silent skip.
    @Test func withoutNodeTheRunFailsNamingIt() throws {
        try #require(!FileManager.default.isExecutableFile(atPath: "/usr/bin/node") && !FileManager.default.isExecutableFile(atPath: "/bin/node"))
        let root = try folder(["a.test.mjs": "ok"])
        let (status, output) = try run(root.appendingPathComponent("web"), path: "/usr/bin:/bin")
        #expect(status == 1, "\(output)")
        #expect(output.contains("node isn't on PATH"), "\(output)")
        #expect(!output.contains("ran ") && !output.contains("web tests:"), "\(output)")
    }

    /// The full run: the web tests in Tests/Web after swift build and swift test, failing the run when they fail.
    @Test func theFullRunRunsTheWebTestsAfterSwiftTest() throws {
        let lines = try String(contentsOf: Self.repo.appendingPathComponent("scripts/test.sh"), encoding: .utf8)
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // Under vs-heavy (the Mac-wide lock for heavy work), as one command.
        let build = #"Resources/bin/vs-heavy --as scripts/test.sh bash -c 'swift build && swift test "$@"' scripts/test.sh "$@""#
        let swift = lines.firstIndex(of: build), web = lines.firstIndex(of: "run_web_tests Tests/Web || status=1")
        #expect(swift != nil, "scripts/test.sh has no line `\(build)`")
        #expect(web != nil, "scripts/test.sh doesn't run the web tests: no line `run_web_tests Tests/Web || status=1`")
        guard let swift, let web else { return }
        #expect(swift < web, "the web tests run before swift test")
        #expect(lines[swift + 1] == "status=$?", "swift test's status isn't kept before the web tests run")
    }
}
