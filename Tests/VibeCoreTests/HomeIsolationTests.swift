import Foundation
import Testing
@testable import VibeCore

/// A scratch HOME or VIBESWITCHER_HOME keeps a process off the user's own ~/.vibeswitcher, and the tests refuse to run
/// on it (docs/eval/open-2026-10-19.md, E-30 + R10). 2026-10-19: tests run on a scratch HOME alone still wrote the
/// user's app.log, because `NSHomeDirectory()` follows CFFIXED_USER_HOME and not HOME.
struct HomeIsolationTests {
    let temp = Scratch()
    static let real = "/Users/jane"
    static let scratch = "/Users/jane/dev/app/.build/scratchhome"

    /// The doc's four environments, then the others. `fallbackHome` is what `NSHomeDirectory()` gives in each: the real
    /// home unless CFFIXED_USER_HOME moves it.
    @Test func theRootFollowsVibeswitcherHomeThenHomeThenTheHomeFolder() {
        func root(_ environment: [String: String], fallbackHome: String = HomeIsolationTests.real) -> String {
            VibePaths.root(environment: environment, fallbackHome: fallbackHome).path
        }
        #expect(root(["HOME": Self.real]) == "/Users/jane/.vibeswitcher")
        #expect(root(["HOME": Self.scratch]) == Self.scratch + "/.vibeswitcher")
        #expect(root(["HOME": Self.scratch, "CFFIXED_USER_HOME": Self.scratch], fallbackHome: Self.scratch)
                == Self.scratch + "/.vibeswitcher")
        #expect(root(["HOME": Self.real, "VIBESWITCHER_HOME": Self.scratch + "/vs"]) == Self.scratch + "/vs")
        // CFFIXED_USER_HOME alone (the debug modes', the chat benches') moves it too: it's what moved NSHomeDirectory().
        #expect(root(["HOME": Self.real, "CFFIXED_USER_HOME": Self.scratch], fallbackHome: Self.scratch)
                == Self.scratch + "/.vibeswitcher")
        #expect(root(["HOME": "/elsewhere", "CFFIXED_USER_HOME": Self.scratch], fallbackHome: Self.scratch)
                == Self.scratch + "/.vibeswitcher")
        // VIBESWITCHER_HOME is the folder itself, and comes before HOME and CFFIXED_USER_HOME.
        #expect(root(["HOME": "/elsewhere", "CFFIXED_USER_HOME": "/elsewhere", "VIBESWITCHER_HOME": "/tmp/vs"]) == "/tmp/vs")
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
        // By path: a URL ends in "/" or not by whether its folder was there when it was made, and this one's parent always does.
        #expect(VibePaths.statsDir.deletingLastPathComponent().path == VibePaths.root.path)
    }

    /// VibeSwitcher's folder and its state folder (each session's prompts and tool calls) are the user's alone (E-32):
    /// made 0700 with their parents, and an older install's 0755 tightened with what's in it kept.
    @Test func vibeSwitchersFoldersAreMadePrivateAndOlderOnesTightened() throws {
        let fm = FileManager.default
        let root = temp.url("private").appendingPathComponent("home/.vibeswitcher")
        let state = root.appendingPathComponent("state")
        func mode(_ url: URL) throws -> Int { try #require(fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) }
        func isFolder(_ url: URL) -> Bool { var folder: ObjCBool = false; return fm.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue }

        VibePaths.ensurePrivateDirectories(root: root)
        #expect(isFolder(root) && isFolder(state))
        #expect(try mode(root) == 0o700 && mode(state) == 0o700)
        #expect(try fm.contentsOfDirectory(atPath: root.path) == ["state"])
        #expect(try fm.contentsOfDirectory(atPath: state.path).isEmpty)

        // An older install's, open to others, with a session's state in it.
        let saved = state.appendingPathComponent("ttys001.json")
        try Data("{}".utf8).write(to: saved)
        for folder in [root, state] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        VibePaths.ensurePrivateDirectories(root: root)
        #expect(try mode(root) == 0o700 && mode(state) == 0o700)
        #expect(try Data(contentsOf: saved) == Data("{}".utf8))
        // The state folder it makes private is the one the hook writes in.
        #expect(VibePaths.stateDir == VibePaths.root.appendingPathComponent("state"))
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
    /// adds nothing to the user's own ~/.vibeswitcher (looked at, never written). That folder is live (the installed app,
    /// its host and every session write there all the time), so only what the hook could write there is compared:
    /// `hookWrites`.
    @Test func theHookOnAScratchHomeWritesThereAndNotInTheUsersFolder() throws {
        let hook = Bundle(for: TestBundleAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vibeswitcher-hook").path
        try #require(FileManager.default.isExecutableFile(atPath: hook), "build it first: swift build")
        let home = temp.url("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let real = URL(fileURLWithPath: VibePaths.accountHome).appendingPathComponent(".vibeswitcher")
        let before = Self.snapshot(real)
        // This run's own, so a state file holding it can only be this hook's.
        let session = "home-isolation-" + UUID().uuidString

        // Under `script` the hook has a terminal of its own; started in the background of a shell that exits at once,
        // it has no agent above it (a test run inside a Claude session would otherwise give it that session's TTY).
        let event = #"{"hook_event_name":"UserPromptSubmit","session_id":"\#(session)","cwd":"/tmp","prompt":"hi"}"#
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
        #expect(saved.sessionId == session)

        let writes = Self.hookWrites(before: before, after: Self.snapshot(real), tty: String(file.dropLast(".json".count)),
                                     session: session)
        if !writes.ignored.isEmpty { print("HomeIsolationTests: ignored under \(real.path): \(writes.ignored.joined(separator: "; "))") }
        #expect(writes.unexpected.isEmpty, "the hook wrote under \(real.path): \(writes.unexpected.joined(separator: "; "))")
    }

    /// The real-folder check: the live app's own changes pass (said as ignored, with why), the hook's are named.
    @Test func theRealFolderCheckIgnoresTheLiveAppsWritesAndNamesTheHooks() {
        let then = Date(timeIntervalSince1970: 1_000), now = then.addingTimeInterval(5)
        let ours = "home-isolation-test", tty = "ttys012"
        let before: Snapshot = ["": Entry(modified: then), "state": Entry(modified: then), "debug/app.log": Entry(modified: then),
                                "state/.dat.nosync3f2a.Qx81Tb": Entry(modified: then),
                                "state/ttys007.json": Entry(modified: then, session: "theirs")]
        // The live app's: a temp file of an atomic save gone, a line more in app.log, a new terminal's session.
        var live = before
        live["state/.dat.nosync3f2a.Qx81Tb"] = nil
        live["debug/app.log"] = Entry(modified: now)
        live["state/ttys030.json"] = Entry(modified: now, session: "a new one")
        live["state/ttys030.json.lock"] = Entry(modified: now)
        let quiet = Self.hookWrites(before: before, after: live, tty: tty, session: ours)
        #expect(quiet.unexpected.isEmpty, "\(quiet.unexpected)")
        #expect(quiet.ignored.count == 4, "\(quiet.ignored)")
        #expect(quiet.ignored.contains { $0.hasPrefix("state/.dat.nosync3f2a.Qx81Tb (gone): a temp file") }, "\(quiet.ignored)")
        #expect(quiet.ignored.contains { $0.hasPrefix("debug/app.log (changed): the live app's log") }, "\(quiet.ignored)")

        // The hook's: its state file for this session, and its lock.
        var written = live
        written["state/\(tty).json"] = Entry(modified: now, session: ours)
        written["state/\(tty).json.lock"] = Entry(modified: now)
        let caught = Self.hookWrites(before: before, after: written, tty: tty, session: ours)
        #expect(caught.unexpected.contains { $0.hasPrefix("state/\(tty).json (new") && $0.contains(ours) }, "\(caught.unexpected)")
        #expect(caught.unexpected.contains { $0.hasPrefix("state/\(tty).json.lock (new)") }, "\(caught.unexpected)")
        #expect(caught.ignored == quiet.ignored)

        // This session in another terminal's file, or the folders made where there were none, are the hook's too.
        var elsewhere = live
        elsewhere["state/ttys007.json"] = Entry(modified: now, session: ours)
        #expect(Self.hookWrites(before: before, after: elsewhere, tty: tty, session: ours).unexpected
                .contains { $0.hasPrefix("state/ttys007.json (changed") })
        let made = Self.hookWrites(before: [:], after: ["": Entry(modified: now), "state": Entry(modified: now)], tty: tty, session: ours)
        #expect(made.unexpected.count == 2 && made.unexpected.allSatisfy { $0.contains("(new)") }, "\(made.unexpected)")
        // Its terminal, once closed, taken by a session of the user's: that session's file and lock are theirs.
        var reused = live
        reused["state/\(tty).json"] = Entry(modified: now, session: "theirs, on the freed terminal")
        reused["state/\(tty).json.lock"] = Entry(modified: now)
        #expect(Self.hookWrites(before: before, after: reused, tty: tty, session: ours).unexpected.isEmpty)
        // A state file of its terminal that can't be read (a session's is never left half-written) isn't passed.
        var unreadable = live
        unreadable["state/\(tty).json"] = Entry(modified: now)
        #expect(!Self.hookWrites(before: before, after: unreadable, tty: tty, session: ours).unexpected.isEmpty)
    }

    /// The installer's default home is the one this process was given: an explicit one is used as it is.
    @Test func theInstallersDefaultHomeIsVibePathsHome() {
        #expect(HookInstaller.configURL(for: .claude).path == VibePaths.home + "/.claude/settings.json")
        #expect(HookInstaller.configURL(for: .codex).path == VibePaths.home + "/.codex/hooks.json")
        #expect(HookInstaller.configURL(for: .claude, home: Self.scratch).path == Self.scratch + "/.claude/settings.json")
        #expect(HookInstaller.configURL(for: .codex, home: Self.real).path == "/Users/jane/.codex/hooks.json")
    }

    /// Runs only in the children of `theInstallerOnAScratchHomeWritesThereAndNotInTheUsersFiles`, with HOME alone on a
    /// scratch home: installs or uninstalls both agents' hooks at the installer's defaults. A default that isn't under
    /// HOME is recorded before anything is written, so a wrong one never reaches the user's files.
    @Test(.enabled(if: ["install", "uninstall"].contains(ProcessInfo.processInfo.environment["VIBESWITCHER_INSTALLER_PROBE"])))
    func installerProbe() throws {
        let environment = ProcessInfo.processInfo.environment
        let home = try #require(environment["HOME"])
        for agent in Agent.allCases {
            let url = HookInstaller.configURL(for: agent)
            guard url.path.hasPrefix(home + "/") else {
                Issue.record("installer probe: \(agent.rawValue)'s default \(url.path) isn't under HOME \(home)")
                continue
            }
            if environment["VIBESWITCHER_INSTALLER_PROBE"] == "install" {
                try HookInstaller.install(agent: agent)
            } else {
                try HookInstaller.uninstall(agent: agent)
            }
            print("installer probe: \(agent.rawValue) installed=\(HookInstaller.isInstalled(agent: agent)) at \(url.path)")
        }
    }

    /// The test bundle with only HOME set (no CFFIXED_USER_HOME, so `NSHomeDirectory()` is the user's, and no
    /// VIBESWITCHER_HOME) installs both agents' hooks into the scratch home's ~/.claude and ~/.codex, then uninstalls
    /// them there; the user's own config files are only stat'd, before and after, and nothing changes or appears.
    @Test func theInstallerOnAScratchHomeWritesThereAndNotInTheUsersFiles() throws {
        let bundle = try #require(Bundle(for: TestBundleAnchor.self).executablePath)
        let helper = try #require(Self.testingHelper, "no swiftpm-testing-helper to start the bundle with")
        let home = temp.url("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let before = Self.configListing(home: VibePaths.accountHome)
        let files = Agent.allCases.map { HookInstaller.configURL(for: $0, home: home.path) }

        func probe(_ mode: String) throws -> String {
            var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "VIBESWITCHER_INSTALLER_PROBE": mode]
            // Where the bundle finds XCTest and Testing, as `swift test` told this process: Swift Build's per-target
            // bundles (Swift 6.4's default layout) have no rpath to the platform's frameworks, so without these the
            // child stops in dlopen before any test. Neither names a home.
            for key in ["DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH"] {
                environment[key] = ProcessInfo.processInfo.environment[key]
            }
            let (status, output) = try Self.run(helper, ["--test-bundle-path", bundle, bundle, "--testing-library", "swift-testing",
                                                         "--filter", "HomeIsolationTests/installerProbe"], environment: environment)
            #expect(status == 0, "\(output)")
            #expect(!output.contains("isn't under HOME"), "\(output)")
            return output
        }

        let installed = try probe("install")
        for (agent, file) in zip(Agent.allCases, files) {
            #expect(installed.contains("installer probe: \(agent.rawValue) installed=true at \(file.path)"), "\(installed)")
            let config = try HookInstaller.readConfigThrowing(file)
            #expect(HookInstaller.isComplete(in: config, agent: agent), "\(file.path)")
            // The hook binary it wrote is the scratch home's too.
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains(home.path + "/.vibeswitcher/bin/vibeswitcher-hook"), "\(text)")
        }

        let uninstalled = try probe("uninstall")
        for (agent, file) in zip(Agent.allCases, files) {
            #expect(uninstalled.contains("installer probe: \(agent.rawValue) installed=false at \(file.path)"), "\(uninstalled)")
            #expect(!HookInstaller.isInstalled(in: try HookInstaller.readConfigThrowing(file)), "\(file.path)")
        }

        let after = Self.configListing(home: VibePaths.accountHome)
        #expect(after == before, "the user's config files changed: \(before) → \(after)")
    }

    /// Whether ~/.claude and ~/.codex in `home` are there, and each entry in them named after the installer's file
    /// (the config, its backup, a temp file mid-write) with its size and when it was last changed. Read-only: stat only.
    static func configListing(home: String) -> [String: String] {
        var listing: [String: String] = [:]
        for agent in Agent.allCases {
            let file = HookInstaller.configURL(for: agent, home: home)
            let folder = file.deletingLastPathComponent()
            listing[folder.path] = FileManager.default.fileExists(atPath: folder.path) ? "folder" : "absent"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.contains(file.lastPathComponent) {
                let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
                let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                listing[folder.appendingPathComponent(name).path] = "\((attributes?[.size] as? NSNumber)?.int64Value ?? 0) bytes, \(modified)"
            }
        }
        return listing
    }

    /// An entry in a snapshot of a ~/.vibeswitcher: when it last changed and, for a state file, the session it holds.
    struct Entry: Equatable {
        var modified: Date?
        var session: String?
    }

    /// A ~/.vibeswitcher's entries by path in it: "" is the folder itself, then what's in it, its state, stats and debug
    /// folders. Read-only.
    typealias Snapshot = [String: Entry]

    static func snapshot(_ root: URL) -> Snapshot {
        let fm = FileManager.default
        func modified(_ url: URL) -> Date? { (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }
        var snapshot: Snapshot = [:]
        guard fm.fileExists(atPath: root.path) else { return snapshot }
        snapshot[""] = Entry(modified: modified(root))
        for folder in ["", "state", "stats", "debug"] {
            let url = folder.isEmpty ? root : root.appendingPathComponent(folder)
            for name in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] {
                let file = url.appendingPathComponent(name)
                let session = folder == "state" && name.hasSuffix(".json") ? HookState.load(from: file)?.sessionId : nil
                snapshot[folder.isEmpty ? name : folder + "/" + name] = Entry(modified: modified(file), session: session)
            }
        }
        return snapshot
    }

    /// Whose the changes the live app makes in the user's ~/.vibeswitcher are, by name, for the report: the first that
    /// matches. None is ever the hook's; it writes only what `hookWrites` looks at.
    static let liveWriters: [(matches: @Sendable (String) -> Bool, whose: String)] = [
        ({ ["", "state", "stats", "debug"].contains($0) }, "a folder, changed as what's in it is"),
        ({ ($0.split(separator: "/").last ?? "").hasPrefix(".dat.nosync") },
         "a temp file of an atomic save (Foundation's), the app's, its host's or a session's hook's: it comes and goes"),
        ({ $0 == "debug/app.log" || $0 == "host.log" }, "the live app's log, or its host's"),
        ({ $0.hasPrefix("debug") }, "the live app's debug files"),
        ({ $0.hasPrefix("stats") }, "the app's usage counts, written as sessions work"),
        ({ $0.hasPrefix("state/") }, "another terminal's session, written by its own hook, or cleared by the app"),
        ({ ["lead", "steer", "attachments", "host", "remote", "headless"].contains($0) },
         "the lead's runs and scratch folders, steered messages, attachments, the host's and remote's folders"),
        ({ _ in true }, "the live app's or its host's own file; no name the hook writes"),
    ]

    /// What the hook, run for `session` on `tty`, wrote in the user's folder going by snapshots of it before and after,
    /// each named with how it changed; and what else changed there, ignored, each with whose it is (`liveWriters`). The
    /// hook writes (Sources/vibeswitcher-hook): the folder and its state folder where there are none, `state/<tty>.json`
    /// and `state/<tty>.json.lock` (and the temp file of that state file's atomic save, there for an instant). So the
    /// hook's are those two folders made, any state file holding `session` (this run's alone), and its terminal's state
    /// file or lock new or changed, unless that state file holds a session of the user's (one on that terminal once
    /// the hook's closed); the folders, files and temp files the live app, its host and other sessions keep writing
    /// are not compared.
    static func hookWrites(before: Snapshot, after: Snapshot, tty: String, session: String)
        -> (unexpected: [String], ignored: [String]) {
        let state = "state/\(tty).json", lock = state + ".lock"
        let theirs = after[state]?.session.map { $0 != session } ?? false
        var unexpected: [String] = []
        var ignored: [String] = []
        for path in Set(before.keys).union(after.keys).sorted() where before[path] != after[path] {
            let change = before[path] == nil ? "new" : after[path] == nil ? "gone" : "changed"
            let name = (path.isEmpty ? "the folder itself" : path) + " (\(change))"
            let hooks: Bool
            switch path {
            case "", "state": hooks = change == "new"
            case state: hooks = after[path]?.session == session || (change != "gone" && !theirs)
            case lock: hooks = change == "new" && !theirs
            default: hooks = after[path]?.session == session
            }
            if hooks {
                unexpected.append(name + (after[path]?.session.map { ", holds session \($0)" } ?? ""))
            } else {
                ignored.append(name + ": " + (liveWriters.first { $0.matches(path) }?.whose ?? ""))
            }
        }
        return (unexpected, ignored)
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
