import Foundation
import Testing

/// scripts/test.sh fails a run that adds a test-named preference file to the real ~/Library/Preferences, or changes
/// VibeSwitcher.plist there (the unbundled build's defaults, which the benches wrote until 2026-10-25); the installed
/// app's dev.vibeswitcher.VibeSwitcher.plist stays out of it. Driven through `scripts/test.sh --preferences DIR --
/// COMMAND` on a scratch folder standing for ~/Library/Preferences: no swift build, and nothing real is touched.
struct PreferencesCheckTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let temp = Scratch()

    /// A folder standing for ~/Library/Preferences, holding `files` (name to text).
    func preferences(_ files: [String: String]) throws -> URL {
        let folder = temp.url("preferences")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files { try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return folder
    }

    /// `scripts/test.sh --preferences DIR -- bash -c SCRIPT` (SCRIPT run in DIR): its exit status and all of its output.
    func run(_ dir: URL, _ script: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repo.appendingPathComponent("scripts/test.sh").path, "--preferences", dir.path, "--",
                             "/bin/bash", "-c", "cd \"$0\" && \(script)", dir.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    @Test func aRunThatLeavesThePreferencesAlonePasses() throws {
        let dir = try preferences(["VibeSwitcher.plist": "before", "com.apple.dock.plist": "dock"])
        let (status, output) = try run(dir, "cat VibeSwitcher.plist > /dev/null")
        #expect(status == 0, "\(output)")
        #expect(!output.contains("PREFERENCE"), "\(output)")
    }

    @Test func aRunThatChangesTheBuildsDefaultsFailsNamingThem() throws {
        let dir = try preferences(["VibeSwitcher.plist": "before"])
        let (status, output) = try run(dir, "echo after > VibeSwitcher.plist")
        #expect(status == 1, "\(output)")
        #expect(output.contains("PREFERENCES CHANGED: the run changed \(dir.path)/VibeSwitcher.plist"), "\(output)")
        #expect(output.contains("BenchDefaults"), "\(output)")
    }

    /// Made where there was none (a bench on a Mac that never had one) counts too.
    @Test func aRunThatMakesTheBuildsDefaultsFails() throws {
        let dir = try preferences([:])
        let (status, output) = try run(dir, "echo new > VibeSwitcher.plist")
        #expect(status == 1, "\(output)")
        #expect(output.contains("PREFERENCES CHANGED"), "\(output)")
    }

    @Test func aRunThatAddsATestsSuiteFileFailsNamingIt() throws {
        let dir = try preferences(["VibeSwitcher.plist": "before"])
        let (status, output) = try run(dir, "echo x > dev.vibeswitcher.tests.0B9E.plist")
        #expect(status == 1, "\(output)")
        #expect(output.contains("PREFERENCE FILES LEFT: the run added 1 to \(dir.path)"), "\(output)")
        #expect(output.contains("  dev.vibeswitcher.tests.0B9E.plist"), "\(output)")
        #expect(!output.contains("PREFERENCES CHANGED"), "\(output)")
    }

    /// The installed app's own defaults change as you use it, during a run too: never the run's failure.
    @Test func theInstalledAppsDefaultsStayOutOfIt() throws {
        let dir = try preferences(["VibeSwitcher.plist": "before", "dev.vibeswitcher.VibeSwitcher.plist": "app"])
        let (status, output) = try run(dir, "echo used > dev.vibeswitcher.VibeSwitcher.plist")
        #expect(status == 0, "\(output)")
        #expect(!output.contains("PREFERENCE"), "\(output)")
    }

    /// The full run takes the build's defaults before swift test and checks them after.
    @Test func theFullRunChecksTheBuildsDefaults() throws {
        let lines = try String(contentsOf: Self.repo.appendingPathComponent("scripts/test.sh"), encoding: .utf8)
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let build = #"Resources/bin/vs-heavy --as scripts/test.sh bash -c 'swift build || { : > "$VS_BUILD_FAILED_MARK"; exit 1; }; swift test "$@"' scripts/test.sh "$@""#
        let before = lines.firstIndex(of: "defaults_before=$(build_defaults)")
        let swift = lines.firstIndex(of: build)
        let check = lines.firstIndex(of: #"check_preferences "$preferences_before" "$defaults_before" || status=1"#)
        #expect(before != nil && swift != nil && check != nil, "scripts/test.sh doesn't check the build's defaults around swift test")
        guard let before, let swift, let check else { return }
        #expect(before < swift && swift < check)
    }
}
