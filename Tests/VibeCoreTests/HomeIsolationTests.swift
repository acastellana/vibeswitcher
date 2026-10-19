import Foundation
import Testing
import VibeCore

/// A scratch HOME or VIBESWITCHER_HOME keeps a process off the user's own ~/.vibeswitcher, and the tests refuse to run
/// on it (docs/eval/open-2026-10-19.md, E-30 + R10). 2026-10-19: tests run on a scratch HOME alone still wrote the
/// user's app.log, because `NSHomeDirectory()` follows CFFIXED_USER_HOME and not HOME.
struct HomeIsolationTests {
    let temp = Scratch()
    static let real = "/Users/jane"
    static let scratch = "/Users/jane/dev/app/.build/scratchhome"

    /// The doc's four environments. `fallbackHome` is what `NSHomeDirectory()` gives in each: the real home unless
    /// CFFIXED_USER_HOME moves it.
    @Test func theRootFollowsVibeswitcherHomeThenHomeThenTheHomeFolder() {
        func root(_ environment: [String: String], fallbackHome: String = HomeIsolationTests.real) -> String {
            VibePaths.root(environment: environment, fallbackHome: fallbackHome).path
        }
        #expect(root(["HOME": Self.real]) == "/Users/jane/.vibeswitcher")
        #expect(root(["HOME": Self.scratch]) == Self.scratch + "/.vibeswitcher")
        #expect(root(["HOME": Self.scratch, "CFFIXED_USER_HOME": Self.scratch], fallbackHome: Self.scratch)
                == Self.scratch + "/.vibeswitcher")
        #expect(root(["HOME": Self.real, "VIBESWITCHER_HOME": Self.scratch + "/vs"]) == Self.scratch + "/vs")
        // VIBESWITCHER_HOME is the folder itself, and comes before HOME.
        #expect(root(["HOME": "/elsewhere", "VIBESWITCHER_HOME": "/tmp/vs"]) == "/tmp/vs")
        // Only an absolute path counts: an empty or relative one falls through to the next.
        #expect(root(["HOME": Self.scratch, "VIBESWITCHER_HOME": ""]) == Self.scratch + "/.vibeswitcher")
        #expect(root(["HOME": Self.scratch, "VIBESWITCHER_HOME": "vs"]) == Self.scratch + "/.vibeswitcher")
        #expect(root(["HOME": ""]) == "/Users/jane/.vibeswitcher")
        #expect(root(["HOME": "~/x"]) == "/Users/jane/.vibeswitcher")
        #expect(root([:]) == "/Users/jane/.vibeswitcher")
        // The agents' home (`~/.claude`) follows HOME too, and never VIBESWITCHER_HOME.
        #expect(VibePaths.home(environment: ["HOME": Self.scratch, "VIBESWITCHER_HOME": "/tmp/vs"], fallbackHome: Self.real) == Self.scratch)
        #expect(VibePaths.home(environment: [:], fallbackHome: Self.real) == Self.real)
    }

    /// This process's root is the one worked out from its own environment.
    @Test func theRootIsWorkedOutFromThisProcesssEnvironment() {
        #expect(VibePaths.root == VibePaths.root(environment: ProcessInfo.processInfo.environment, fallbackHome: NSHomeDirectory()))
        #expect(VibePaths.statsDir.deletingLastPathComponent() == VibePaths.root)
    }

    /// Only the account's own folder is refused, however it's spelled; a scratch home under the account's home (a
    /// worktree's, the merge runner's) is not.
    @Test func theTestsRefuseOnlyTheAccountsOwnFolder() throws {
        func refusal(_ root: String) -> String? {
            VibePaths.testRefusal(root: URL(fileURLWithPath: root), accountHome: Self.real)
        }
        let message = try #require(refusal("/Users/jane/.vibeswitcher"))
        #expect(message.contains("/Users/jane/.vibeswitcher"))
        #expect(message.contains("VIBESWITCHER_HOME") && message.contains("HOME") && message.contains("scripts/test.sh"))
        #expect(refusal("/Users/jane/.vibeswitcher/") != nil)
        #expect(refusal("/Users/jane/dev/../.vibeswitcher") != nil)
        #expect(refusal("/Users/jane/./.vibeswitcher") != nil)
        #expect(refusal(Self.scratch + "/.vibeswitcher") == nil)
        #expect(refusal("/Users/jane/.vibeswitcher/scratch") == nil)
        #expect(refusal("/Users/jane") == nil)
        #expect(refusal("/tmp/vs-test.x/home/.vibeswitcher") == nil)

        // A symlink to the account's folder is that folder.
        let home = temp.url("account")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".vibeswitcher"), withIntermediateDirectories: true)
        let link = temp.url("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent(".vibeswitcher"))
        #expect(VibePaths.testRefusal(root: link, accountHome: home.path) != nil)
        #expect(VibePaths.testRefusal(root: home.appendingPathComponent("other"), accountHome: home.path) == nil)
    }

    /// This suite runs, so its guard ran and let it: the run's root isn't the account's own.
    @Test func thisRunsGuardRanAndItsRootIsntTheAccountsOwn() {
        #expect(homeGuardRan)
        #expect(!VibePaths.isAccountRoot(VibePaths.root, accountHome: VibePaths.accountHome))
    }

    /// Runs only in the child of `aRunOnTheAccountsFolderStopsBeforeAnyTest`, where the guard must stop it first.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBESWITCHER_GUARD_PROBE"] == "1"))
    func guardProbe() {
        print("guard probe: the test body ran")
    }

    /// The test bundle, started the way `swift test` starts it, on the account's own folder (VIBESWITCHER_HOME): it
    /// stops as it loads with the one message, and no test body runs. Only `guardProbe`, which writes nothing, is
    /// asked for, so a broken guard costs nothing either.
    @Test func aRunOnTheAccountsFolderStopsBeforeAnyTest() throws {
        let bundle = try #require(Bundle(for: TestBundleAnchor.self).executablePath)
        let helper = try #require(Self.testingHelper, "no swiftpm-testing-helper to start the bundle with")
        let home = temp.url("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["VIBESWITCHER_HOME"] = VibePaths.accountHome + "/.vibeswitcher"
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["VIBESWITCHER_GUARD_PROBE"] = "1"
        let (status, output) = try Self.run(helper, ["--test-bundle-path", bundle, bundle, "--testing-library", "swift-testing",
                                                     "--filter", "HomeIsolationTests/guardProbe"], environment: environment)
        #expect(status == 78, "\(output)")
        #expect(!output.contains("guard probe: the test body ran"))
        #expect(output.contains("Refusing to run the tests"), "\(output)")
        #expect(output.contains("VIBESWITCHER_HOME") && output.contains("HOME"))
        #expect(output.components(separatedBy: "Refusing to run the tests").count == 2, "one message: \(output)")
    }

    /// The built hook, given only HOME (no CFFIXED_USER_HOME, no VIBESWITCHER_HOME), writes its state under that home and
    /// adds nothing to the user's own ~/.vibeswitcher (looked at, never written).
    @Test func theHookOnAScratchHomeWritesThereAndNotInTheUsersFolder() throws {
        let hook = Bundle(for: TestBundleAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-hook").path
        try #require(FileManager.default.isExecutableFile(atPath: hook), "build it first: swift build")
        let home = temp.url("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let real = URL(fileURLWithPath: VibePaths.accountHome).appendingPathComponent(".vibeswitcher")
        let before = Self.listing(real)

        // Under `script` the hook has a terminal of its own; started in the background of a shell that exits at once,
        // it has no agent above it (a test run inside a Claude session would otherwise give it that session's TTY).
        let event = #"{"hook_event_name":"UserPromptSubmit","session_id":"home-isolation","cwd":"/tmp","prompt":"hi"}"#
        let script = #"/usr/bin/script -q /dev/null /bin/sh -c 'printf %s "$1" | "$2" claude' sh "$EVENT" "$HOOK" </dev/null >/dev/null 2>&1 &"#
        let (status, output) = try Self.run("/bin/sh", ["-c", script],
                                            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "EVENT": event, "HOOK": hook])
        #expect(status == 0, "\(output)")

        let state = home.appendingPathComponent(".vibeswitcher/state")
        var written: [String] = []
        #expect(eventually(timeout: 30) {
            written = ((try? FileManager.default.contentsOfDirectory(atPath: state.path)) ?? []).filter { $0.hasSuffix(".json") }
            return !written.isEmpty
        }, "no state file under \(state.path)")
        let file = try #require(written.first)
        let saved = try #require(HookState.load(from: state.appendingPathComponent(file)))
        #expect(saved.sessionId == "home-isolation")

        let after = Self.listing(real)
        #expect(after.names == before.names, "new under \(real.path): \(after.names.subtracting(before.names).sorted())")
        // The hook's own file, if the user's folder has one by that name (a terminal of theirs, long closed), is untouched.
        #expect(after.modified["state/" + file] == before.modified["state/" + file])
    }

    /// The names in `root` and its state and stats folders, and when each was last changed. Read-only.
    static func listing(_ root: URL) -> (names: Set<String>, modified: [String: Date]) {
        var names: Set<String> = []
        var modified: [String: Date] = [:]
        for folder in ["", "state", "stats"] {
            let url = folder.isEmpty ? root : root.appendingPathComponent(folder)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
                let key = folder.isEmpty ? name : folder + "/" + name
                names.insert(key)
                modified[key] = (try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(name).path))?[.modificationDate] as? Date
            }
        }
        return (names, modified)
    }

    /// What `swift test` starts the test bundle with: this process when it is that, else the toolchain's.
    static var testingHelper: String? {
        let own = CommandLine.arguments.first ?? ""
        if URL(fileURLWithPath: own).lastPathComponent == "swiftpm-testing-helper" { return own }
        guard let swift = try? run("/usr/bin/xcrun", ["--find", "swift"], environment: ProcessInfo.processInfo.environment),
              swift.status == 0 else { return nil }
        let helper = URL(fileURLWithPath: swift.output.trimmingCharacters(in: .whitespacesAndNewlines))
            .deletingLastPathComponent().appendingPathComponent("../libexec/swift/pm/swiftpm-testing-helper").standardizedFileURL.path
        return FileManager.default.isExecutableFile(atPath: helper) ? helper : nil
    }

    /// Runs `path` with `arguments` to its end: its status, and its output and errors together.
    static func run(_ path: String, _ arguments: [String], environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

private final class TestBundleAnchor {}
