import Foundation
import Testing
@testable import VibeCore

/// scripts/lib/developer-dir.sh, which tells scripts/test-under-load.sh where Testing.framework is for the developer
/// folder in use: the caller's DEVELOPER_DIR as it is, else xcode-select's (the Command Line Tools' layout as well as
/// an Xcode's), else an Xcode it finds; none, one line and a failure. Each test lays out fake developer folders and puts
/// a fake `xcode-select` first on PATH: the Mac's own choice is never read or changed.
@Suite struct DeveloperDirTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let temp = Scratch()
    let root: URL
    let bin: URL

    init() throws {
        root = temp.url("developer-dir")
        bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    /// Command Line Tools at `root/<name>`: Testing.framework in Library/Developer/Frameworks (`testing`), no platform.
    func commandLineTools(_ name: String, testing: Bool = true) throws -> String {
        let folder = root.appendingPathComponent(name)
        let frameworks = folder.appendingPathComponent(testing ? "Library/Developer/Frameworks/Testing.framework" : "usr/bin")
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        return folder.path
    }

    /// An Xcode at `root/<name>.app`, its macOS platform holding Testing.framework; its Contents/Developer.
    func xcode(_ name: String) throws -> String {
        let app = root.appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks/Testing.framework"),
            withIntermediateDirectories: true)
        return app.appendingPathComponent("Contents/Developer").path
    }

    /// A fake xcode-select that prints `selected` for -p (and fails for anything else: nothing may be switched).
    func select(_ selected: String) throws {
        let script = bin.appendingPathComponent("xcode-select")
        try "#!/bin/bash\n[[ $1 == -p ]] || exit 9\necho '\(selected)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    /// pick_developer_dir with `xcodes` (the Xcode apps to look in), DEVELOPER_DIR `developerDir` or unset: its status,
    /// what it said, and the developer_dir, test_frameworks, test_libraries and exported DEVELOPER_DIR it left.
    func pick(_ xcodes: [String], developerDir: String? = nil) throws -> (status: Int32, said: String, values: [String: String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", """
            source scripts/lib/developer-dir.sh
            pick_developer_dir "$@"; status=$?
            echo "developer_dir=$developer_dir"; echo "test_frameworks=$test_frameworks"
            echo "test_libraries=$test_libraries"; echo "exported=$(printenv DEVELOPER_DIR)"
            exit $status
            """, "pick"] + xcodes
        process.currentDirectoryURL = Self.repo
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = developerDir
        environment["PATH"] = "\(bin.path):/usr/bin:/bin"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        var said: [Substring] = []
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            if let equals = line.firstIndex(of: "="), ["developer_dir", "test_frameworks", "test_libraries", "exported"].contains(String(line[..<equals])) {
                values[String(line[..<equals])] = String(line[line.index(after: equals)...])
            } else {
                said.append(line)
            }
        }
        return (process.terminationStatus, said.joined(separator: "\n"), values)
    }

    /// The Mac this was reported on (2026-10-31): xcode-select at the Command Line Tools, which have Testing.framework
    /// but no macOS platform, and an Xcode beside them. Their own frameworks, as `swift test` uses: the same toolchain
    /// test.sh builds with, and nothing exported.
    @Test func commandLineToolsSelectedAreUsedWithTheirOwnFrameworks() throws {
        let tools = try commandLineTools("CommandLineTools")
        let xcode = try xcode("Xcode")
        try select(tools)
        let run = try pick([root.appendingPathComponent("Xcode.app").path])
        #expect(run.status == 0, "\(run.said)")
        #expect(run.values["developer_dir"] == tools)
        #expect(run.values["test_frameworks"] == "\(tools)/Library/Developer/Frameworks")
        #expect(run.values["test_libraries"] == "\(tools)/Library/Developer/usr/lib")
        #expect(run.values["exported"] == "")
        #expect(!run.values["test_frameworks", default: ""].contains(xcode))
    }

    @Test func anXcodeSelectedIsUsedThroughItsPlatform() throws {
        let xcode = try xcode("Xcode")
        try select(xcode)
        let run = try pick([])
        let platform = "\(xcode)/Platforms/MacOSX.platform/Developer"
        #expect(run.status == 0, "\(run.said)")
        #expect(run.values["developer_dir"] == xcode)
        #expect(run.values["test_frameworks"] == "\(platform)/Library/Frameworks:\(platform)/Library/PrivateFrameworks")
        #expect(run.values["test_libraries"] == "\(platform)/usr/lib")
        #expect(run.values["exported"] == "")
    }

    /// Command Line Tools without Swift Testing selected: the first Xcode that has it, exported so the build uses it too.
    @Test func withoutTestingSelectedAnXcodeIsFoundAndExported() throws {
        try select(try commandLineTools("CommandLineTools", testing: false))
        let xcode = try xcode("Xcode")
        let run = try pick([root.appendingPathComponent("Missing.app").path, root.appendingPathComponent("Xcode.app").path])
        #expect(run.status == 0, "\(run.said)")
        #expect(run.values["developer_dir"] == xcode)
        #expect(run.values["exported"] == xcode)
    }

    /// The caller's DEVELOPER_DIR comes first, over a selected folder that would do.
    @Test func theCallersDeveloperDirIsRespected() throws {
        try select(try commandLineTools("CommandLineTools"))
        let xcode = try xcode("Xcode")
        let run = try pick([], developerDir: xcode)
        #expect(run.status == 0, "\(run.said)")
        #expect(run.values["developer_dir"] == xcode)
        #expect(run.values["exported"] == xcode)
    }

    /// DEVELOPER_DIR given as the Xcode.app itself, as xcrun and swift take it: its Contents/Developer, the caller's
    /// DEVELOPER_DIR left as it was.
    @Test func aCallersXcodeAppIsTakenAsItsDeveloperFolder() throws {
        try select(try commandLineTools("CommandLineTools"))
        let xcode = try xcode("Xcode")
        let app = root.appendingPathComponent("Xcode.app").path
        let run = try pick([], developerDir: app)
        #expect(run.status == 0, "\(run.said)")
        #expect(run.values["developer_dir"] == xcode)
        #expect(run.values["test_frameworks", default: ""].hasPrefix("\(xcode)/Platforms/MacOSX.platform/"))
        #expect(run.values["exported"] == app)
    }

    /// One without Testing.framework is an error, not passed over for another.
    @Test func aCallersDeveloperDirWithoutTestingFailsInOneLine() throws {
        try select(try commandLineTools("CommandLineTools"))
        let empty = try commandLineTools("Empty", testing: false)
        let run = try pick([], developerDir: empty)
        #expect(run.status != 0)
        #expect(run.said.split(separator: "\n").count == 1, "\(run.said)")
        #expect(run.said.contains("DEVELOPER_DIR is \(empty)"), "\(run.said)")
        #expect(run.values["developer_dir"] == "")
    }

    @Test func noXcodeFoundFailsInOneClearLine() throws {
        try select(try commandLineTools("CommandLineTools", testing: false))
        let missing = root.appendingPathComponent("Xcode.app").path
        let run = try pick([missing])
        #expect(run.status != 0)
        #expect(run.said.split(separator: "\n").count == 1, "\(run.said)")
        #expect(run.said.hasPrefix("no Xcode found"), "\(run.said)")
        #expect(run.said.contains(missing), "\(run.said)")
        #expect(run.values["exported"] == "")
    }

    /// xcode-select failing (no developer folder chosen), and no Xcode: the same line.
    @Test func noSelectedFolderAndNoXcodeFailsInOneLine() throws {
        let script = bin.appendingPathComponent("xcode-select")
        try "#!/bin/bash\necho 'xcode-select: error: unable to get active developer directory' >&2\nexit 2\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let run = try pick([root.appendingPathComponent("Xcode.app").path])
        #expect(run.status != 0)
        #expect(run.said.split(separator: "\n").count == 1, "\(run.said)")
        #expect(run.said.hasPrefix("no Xcode found"), "\(run.said)")
    }
}
