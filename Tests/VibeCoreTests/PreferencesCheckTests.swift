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
    func run(_ dir: URL, _ script: String) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repo.appendingPathComponent("scripts/test.sh").path, "--preferences", dir.path, "--",
                             "/bin/bash", "-c", "cd \"$0\" && \(script)", dir.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // The tool's run read to its end and waited for on a thread of its own, not the cooperative pool.
        let output = await offPool { () -> String in
            let read = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            waitForEnd(process)
            return read
        }
        return (process.terminationStatus, output)
    }

    @Test func aRunThatLeavesThePreferencesAlonePasses() async throws {
        let dir = try preferences(["VibeSwitcher.plist": "before", "com.apple.dock.plist": "dock"])
        let (status, output) = try await run(dir, "cat VibeSwitcher.plist > /dev/null")
        #expect(status == 0, "\(output)")
        #expect(!output.contains("PREFERENCE"), "\(output)")
    }

    @Test func aRunThatChangesTheBuildsDefaultsFailsNamingThem() async throws {
        let dir = try preferences(["VibeSwitcher.plist": "before"])
        let (status, output) = try await run(dir, "echo after > VibeSwitcher.plist")
        #expect(status == 1, "\(output)")
        #expect(output.contains("PREFERENCES CHANGED: the run changed \(dir.path)/VibeSwitcher.plist"), "\(output)")
        #expect(output.contains("BenchDefaults"), "\(output)")
    }

    /// Made where there was none (a bench on a Mac that never had one) counts too.
    @Test func aRunThatMakesTheBuildsDefaultsFails() async throws {
        let dir = try preferences([:])
        let (status, output) = try await run(dir, "echo new > VibeSwitcher.plist")
        #expect(status == 1, "\(output)")
        #expect(output.contains("PREFERENCES CHANGED"), "\(output)")
    }

    /// A suite a process of this run opened, as the bundle's hook records it (`PreferenceLedger`), and its file left.
    static func leave(_ domain: String) -> String {
        "echo \(domain) >> \"$VIBESWITCHER_PREFERENCE_LEDGER\"; echo x > \(domain).plist"
    }

    @Test func aRunThatAddsATestsSuiteFileFailsNamingIt() async throws {
        let dir = try preferences(["VibeSwitcher.plist": "before"])
        let (status, output) = try await run(dir, Self.leave("dev.vibeswitcher.tests.0B9E"))
        #expect(status == 1, "\(output)")
        #expect(output.contains("PREFERENCE FILES LEFT: the run added 1 to \(dir.path)"), "\(output)")
        #expect(output.contains("  dev.vibeswitcher.tests.0B9E.plist"), "\(output)")
        #expect(!output.contains("PREFERENCES CHANGED"), "\(output)")
    }

    /// Up to 3 suites run at once (vs-heavy's slots), and the check reads the one real folder: what another worktree's
    /// run leaves between this run's two snapshots is that run's. Two real runs on one folder, each waiting on the other's
    /// event: `quiet` is under way (its snapshot taken, as its command has started), then `leaver` leaves a file, then
    /// `quiet` ends. `leaver` fails naming it; `quiet` passes, and says what it saw.
    @Test func aPlistAnotherRunLeavesFailsThatRunAlone() async throws {
        let dir = try preferences(["VibeSwitcher.plist": "before"])
        let file = "dev.vibeswitcher.tests.0THER.plist"
        // Long enough for any load; each ends at once when the event comes, and a missing event is a failure, not a pass.
        let wait = { (path: String) in "for _ in $(seq 1 6000); do [[ -e \(path) ]] && break; sleep 0.02; done; [[ -e \(path) ]]" }
        async let quiet = run(dir, "touch quiet-started; \(wait(file))")
        async let leaver = run(dir, "\(wait("quiet-started")) && \(Self.leave("dev.vibeswitcher.tests.0THER"))")
        let (quietRun, leaverRun) = try await (quiet, leaver)
        #expect(leaverRun.status == 1, "\(leaverRun.output)")
        #expect(leaverRun.output.contains("  \(file)"), "\(leaverRun.output)")
        #expect(quietRun.status == 0, "\(quietRun.output)")
        #expect(!quietRun.output.contains("PREFERENCE FILES LEFT"), "\(quietRun.output)")
        #expect(quietRun.output.contains("no process of this run opened"), "\(quietRun.output)")
        #expect(quietRun.output.contains("  \(file)"), "\(quietRun.output)")
        // Left as it is: it's another run's to answer for.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path))
    }

    /// The hook itself, in this very process: a suite opened here is in this run's ledger before the open returns. The
    /// suite is `Scratch.defaults`', named by a path, so nothing goes near the real folder.
    @Test func aSuiteOpenedInThisProcessIsInTheRunsLedger() throws {
        let ledger = try #require(ProcessInfo.processInfo.environment["VIBESWITCHER_PREFERENCE_LEDGER"],
                                  "scripts/test.sh gives every run a ledger")
        let prefix = "ledger-\(UUID().uuidString)"
        _ = temp.defaults(prefix)
        let lines = try String(contentsOfFile: ledger, encoding: .utf8).components(separatedBy: "\n")
        #expect(lines.contains { $0.contains(prefix) }, "the bundle's hook didn't record the suite: \(ledger)")
    }

    /// The installed app's own defaults change as you use it, during a run too: never the run's failure.
    @Test func theInstalledAppsDefaultsStayOutOfIt() async throws {
        let dir = try preferences(["VibeSwitcher.plist": "before", "dev.vibeswitcher.VibeSwitcher.plist": "app"])
        let (status, output) = try await run(dir, "echo used > dev.vibeswitcher.VibeSwitcher.plist")
        #expect(status == 0, "\(output)")
        #expect(!output.contains("PREFERENCE"), "\(output)")
    }

    /// The full run takes the build's defaults before swift test and checks them after.
    @Test func theFullRunChecksTheBuildsDefaults() throws {
        let lines = try String(contentsOf: Self.repo.appendingPathComponent("scripts/test.sh"), encoding: .utf8)
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let build = #"Resources/bin/vs-heavy --as scripts/test.sh bash -c 'slot_width; heavy_swift build || { : > "$VS_BUILD_FAILED_MARK"; exit 1; }; heavy_swift test "$@"' scripts/test.sh "$@""#
        let before = lines.firstIndex(of: "defaults_before=$(build_defaults)")
        let swift = lines.firstIndex(of: build)
        let check = lines.firstIndex(of: #"check_preferences "$preferences_before" "$defaults_before" || status=1"#)
        #expect(before != nil && swift != nil && check != nil, "scripts/test.sh doesn't check the build's defaults around swift test")
        guard let before, let swift, let check else { return }
        #expect(before < swift && swift < check)
    }
}
