import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The user's running host is a build from before PR #1 (which made every session the app's alone to see, once it
/// proves itself). At the next install it hands its sessions over to this build: the app, proving itself to the new
/// build, sees them all and reaches them; a client that proves nothing sees none. The old build is the host of
/// project-lead just before PR #1 landed, built once per Mac and toolchain from that commit into the main checkout's
/// .vibeswitcher/old-hosts (`sharedCache`; its dependencies from this checkout's, so nothing is downloaded) and reused by
/// every checkout. On a scratch host process (its own home, socket, lock and key).
/// Its time limit is `hostTestLimit`'s, plus the old host's build (`buildLimit`) that its first run makes.
@Suite(.serialized, .timeLimit(.minutes(25))) struct UpgradeFromLeadHostTests {
    let temp = Scratch()
    /// project-lead before PR #1.
    static let commit = "6311e1890da61ca763de25fe6f67e96ca746598e"
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct BuildFailed: Error, CustomStringConvertible {
        let description: String
    }

    /// The run's slot's share of the cores, as scripts/lib/swift-jobs.sh gives SwiftPM: two modules at once, with
    /// VS_HEAVY_CORES ÷ 2 (rounded up) compiles each; nothing without it. A merge's fresh checkout builds the old host
    /// in its suite: bare, that build ran 24 swift-frontends at ~780 % CPU inside a 4-core slot (2026-11-01).
    static func heavyJobs(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        guard let cores = environment[TestLock.coresVariable].flatMap({ Int($0) }), cores >= 1 else { return [] }
        return ["-j", "2", "-Xswiftc", "-j\((cores + 1) / 2)"]
    }

    /// What scripts/lib/swift-jobs.sh's `swiftpm_options` gives every SwiftPM command: the native build system (the
    /// Command Line Tools of 2026-11-05 made swiftbuild the default, which compiles SwiftTerm's .metal file and wants
    /// Xcode's Metal Toolchain), and inside Codex's sandbox `--disable-sandbox` (macOS refuses a sandbox in a sandbox).
    static func swiftpmOptions(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        ["--build-system", "native"] + ((environment["CODEX_SANDBOX"] ?? "").isEmpty ? [] : ["--disable-sandbox"])
    }

    @Test func theOldHostBuildsAsTheScriptsBuild() {
        #expect(Self.swiftpmOptions([:]) == ["--build-system", "native"])
        #expect(Self.swiftpmOptions(["CODEX_SANDBOX": "seatbelt"]) == ["--build-system", "native", "--disable-sandbox"])
        #expect(Self.swiftpmOptions(["CODEX_SANDBOX": ""]) == ["--build-system", "native"])
    }

    @Test func theOldHostsBuildTakesTheSlotsShareOfTheCores() {
        #expect(Self.heavyJobs(["VS_HEAVY_CORES": "4"]) == ["-j", "2", "-Xswiftc", "-j2"])
        #expect(Self.heavyJobs(["VS_HEAVY_CORES": "5"]) == ["-j", "2", "-Xswiftc", "-j3"])
        #expect(Self.heavyJobs([:]).isEmpty && Self.heavyJobs(["VS_HEAVY_CORES": "x"]).isEmpty && Self.heavyJobs(["VS_HEAVY_CORES": "0"]).isEmpty)
    }

    /// Where the old build is kept for every checkout of this clone: the worktrees and the merge's and the audits'
    /// scratch checkouts (all git worktrees, wherever their folder is) share the main checkout's .vibeswitcher folder
    /// (git-ignored), as they share its module cache (scripts/lib/module-cache.sh). Until 2026-11-08 each checkout built
    /// it into its own .build, and a merge's or an audit's starts with an empty one: its full suite compiled the
    /// package a second time, beside the parallel tests (an audit's run: 303 s for this suite's first test).
    static let sharedCache: URL = {
        let common = (try? run("/usr/bin/git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repo, limit: 30))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let main = common.isEmpty ? repo : URL(fileURLWithPath: common).deletingLastPathComponent()
        return main.appendingPathComponent(".vibeswitcher/old-hosts")
    }()

    /// The toolchain's part of a cache entry's name: what `swift --version` says (the compiler and the target, the
    /// macOS version in it), hashed. A new toolchain builds the old host again, once.
    static func toolchainKey(xcrun: String = "/usr/bin/xcrun") throws -> String {
        let version = try run(xcrun, ["swift", "--version"])
        return SHA256.hash(data: Data(version.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The cache entry for `commit` built by this toolchain: `cache`/COMMIT-TOOLCHAIN.
    static func cacheEntry(in cache: URL = sharedCache, xcrun: String = "/usr/bin/xcrun") throws -> URL {
        cache.appendingPathComponent("\(commit)-\(try toolchainKey(xcrun: xcrun))")
    }

    /// The old build's host: built once per Mac and toolchain (minutes), into `cache`, then reused by every checkout.
    /// Its dependencies come from `checkout`'s .build. `waitingForLock` runs when another run is building it (tests).
    /// Blocking: a test awaits it through `offPool`.
    static func oldHost(cache: URL = sharedCache, checkout: URL = repo, xcrun: String = "/usr/bin/xcrun",
                        waitingForLock: () -> Void = {}) throws -> String {
        let folder = try cacheEntry(in: cache, xcrun: xcrun)
        let built = folder.appendingPathComponent("vibeswitcher-host").path
        // Only a finished build is ever at this name (it's renamed in whole, below).
        if FileManager.default.isExecutableFile(atPath: built) { return built }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // One build per entry, whichever run gets here first; the others wait on the lock, then take what it made. The
        // kernel lets an flock go with its file, so a run stopped mid-build leaves no lock behind.
        let lock = open(folder.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard lock >= 0 else { throw BuildFailed(description: "can't open \(folder.path).lock: \(String(cString: strerror(errno)))") }
        defer { close(lock) }
        if flock(lock, LOCK_EX | LOCK_NB) != 0 {
            waitingForLock()
            while flock(lock, LOCK_EX) != 0 {
                guard errno == EINTR else { throw BuildFailed(description: "can't lock \(folder.path).lock: \(String(cString: strerror(errno)))") }
            }
        }
        if FileManager.default.isExecutableFile(atPath: built) { return built }
        // Built in a folder of its own and moved into place: what a stopped run left (a work folder, a staged copy) is
        // never taken for the build.
        let work = folder.appendingPathComponent("work-\(UUID().uuidString.prefix(8))")
        let source = work.appendingPathComponent("src"), scratch = work.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let tree = work.appendingPathComponent("tree.tar")
        let temporary = work.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try export(commit, into: source, through: tree)
        // This checkout's resolved dependencies (the same versions: Package.resolved is unchanged since), cloned.
        for item in ["checkouts", "repositories", "workspace-state.json"] {
            try run("/bin/cp", ["-c", "-R", checkout.appendingPathComponent(".build/\(item)").path, scratch.path + "/"])
        }
        // SwiftPM leaves folders in its TMPDIR: the build's own, removed with it.
        try run(xcrun, ["swift", "build"] + swiftpmOptions() + ["--package-path", source.path, "--scratch-path", scratch.path,
                                   "--disable-automatic-resolution", "--product", "vibeswitcher-host"] + heavyJobs(), temporary: temporary, limit: buildLimit)
        let product = try run(xcrun, ["swift", "build"] + swiftpmOptions() + ["--package-path", source.path, "--scratch-path", scratch.path,
                                                 "--disable-automatic-resolution", "--show-bin-path"], temporary: temporary, limit: buildLimit)
        // Its last line: the native build system says first, in the same output, that it's deprecated.
        let binPath = product.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let binary = binPath.trimmingCharacters(in: .whitespaces) + "/vibeswitcher-host"
        let staged = folder.appendingPathComponent("host-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.copyItem(atPath: binary, toPath: staged)
        if rename(staged, built) != 0 { unlink(staged) }
        return built
    }

    /// Writes `commit`'s tree into `source` (by way of the archive `tree`), its agent files left out: AGENTS.md,
    /// CLAUDE*.md, .claude/ and .mcp.json, in any folder (tar's --exclude matches at any depth). 2026-10-28: the export
    /// under .build/old-hosts held the old commit's AGENTS.md and CLAUDE.md while it built, and the lead's audit
    /// (Worktrees.localAgentConfig) took them for instructions the worktree held uncommitted: its verifier waited on a
    /// trust question. The build needs neither.
    static func export(_ commit: String, into source: URL, through tree: URL) throws {
        try run("/usr/bin/git", ["archive", "--output", tree.path, commit], in: repo)
        try run("/usr/bin/tar", ["-xf", tree.path, "-C", source.path,
                                 "--exclude", "AGENTS.md", "--exclude", "CLAUDE*.md", "--exclude", ".claude", "--exclude", ".mcp.json"])
    }

    /// The agent files under .build that the lead's audit sees in this checkout (git status, ignored files included,
    /// as Worktrees.localAgentConfig reads it): AGENTS.md, CLAUDE*.md, .mcp.json, and anything in a .claude folder.
    static func agentFilesUnderBuild() -> [String] {
        Worktrees.status(in: repo.path, ignored: true).map(\.path).filter { path in
            let parts = path.split(separator: "/").map(String.init)
            guard parts.first == ".build", let name = parts.last else { return false }
            return name == "AGENTS.md" || name == ".mcp.json" || (name.hasPrefix("CLAUDE") && name.hasSuffix(".md")) || parts.contains(".claude")
        }.sorted()
    }

    /// The old commit is in this clone.
    static var hasOldCommit: Bool {
        (try? run("/usr/bin/git", ["cat-file", "-e", "\(commit)^{commit}"], in: repo, limit: 30)) != nil
    }

    /// The old build can be made here without downloading anything: built already (in `sharedCache`, by this toolchain),
    /// or its commit is in this clone, pins the same dependencies, and this checkout's resolved ones are in .build. A
    /// fresh clone without the commit, or another Mac without the dependencies, skips the test.
    static var canBuildOldHost: Bool {
        if let entry = try? cacheEntry(), FileManager.default.isExecutableFile(atPath: entry.appendingPathComponent("vibeswitcher-host").path) {
            return true
        }
        let dependencies = ["checkouts", "repositories", "workspace-state.json"]
            .allSatisfy { FileManager.default.fileExists(atPath: repo.appendingPathComponent(".build/\($0)").path) }
        // The same pins as this checkout's dependencies: otherwise the old build would want others, and download them.
        return dependencies && hasOldCommit
            && (try? run("/usr/bin/git", ["diff", "--quiet", commit, "--", "Package.resolved"], in: repo, limit: 30)) != nil
    }

    /// The old host's build gets this long (under a minute on a calm Mac; minutes on a loaded one): a build that hangs
    /// fails the test rather than holding the run. Every other step gets the hang guard.
    static let buildLimit: TimeInterval = 15 * 60

    /// Runs `tool`, its output read as it goes (a build prints more than a pipe holds); throws when it fails or runs
    /// past `limit` seconds (it's stopped then).
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], in folder: URL? = nil, temporary: URL? = nil,
                    limit: TimeInterval = hangGuard) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        if let temporary {
            var environment = ProcessInfo.processInfo.environment
            environment["TMPDIR"] = temporary.path + "/"
            process.environment = environment
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // Read on its own thread: the pipe's end comes when the tool and anything it left running close it.
        let read = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var data = Data()
        Thread.detachNewThread {
            data = output.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        let command = "\(tool) \(arguments.joined(separator: " "))"
        guard exited.wait(timeout: .now() + limit) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 10) != .success { kill(process.processIdentifier, SIGKILL) }
            throw BuildFailed(description: "\(command) ran past its limit of \(Int(limit)) s and was stopped")
        }
        guard read.wait(timeout: .now() + 10) == .success else {
            throw BuildFailed(description: "\(command) exited, but what it left running kept its output open")
        }
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw BuildFailed(description: "\(command) exited \(process.terminationStatus):\n\(text.suffix(4_000))")
        }
        return text
    }

    /// A step that hangs is stopped at its limit and fails, rather than holding the run.
    @Test func aStepPastItsLimitIsStopped() async throws {
        let started = Date()
        await #expect(throws: BuildFailed.self) { try await offPool { try Self.run("/bin/sleep", ["3600"], limit: 1) } }
        #expect(Date().timeIntervalSince(started) < hangGuard)
    }

    /// The old commit's export (where the old host builds: `sharedCache`/COMMIT-TOOLCHAIN/work-*/src; here in this
    /// checkout's .build, where the audit looks) holds its files but not its AGENTS.md or CLAUDE.md: while it's there,
    /// the audit sees no agent file under .build.
    @Test(.enabled(if: hasOldCommit, "needs commit 6311e18 in this clone"))
    func theOldCommitsExportLeavesItsAgentFilesOut() async throws {
        let tracked = try await offPool { try Self.run("/usr/bin/git", ["ls-tree", "--name-only", Self.commit], in: Self.repo) }.components(separatedBy: "\n")
        #expect(tracked.contains("AGENTS.md") && tracked.contains("CLAUDE.md"), "the commit has no agent files to leave out")
        let work = Self.repo.appendingPathComponent(".build/old-hosts/\(Self.commit)/work-\(UUID().uuidString.prefix(8))")
        let source = work.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try await offPool { try Self.export(Self.commit, into: source, through: work.appendingPathComponent("tree.tar")) }
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("Package.swift").path))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("Sources").path))
        #expect(Self.agentFilesUnderBuild() == [])
    }

    /// A toolchain that builds nothing: an xcrun whose `swift --version` says "fake", whose `swift build --product`
    /// makes a small script where `--show-bin-path` says (once the file `go` is there, when `gated`), and that writes
    /// each command it's given to `calls`. In a scratch folder, beside the cache it builds into.
    struct FakeToolchain {
        let folder: URL
        var xcrun: String { folder.appendingPathComponent("xcrun").path }
        var cache: URL { folder.appendingPathComponent("cache") }
        var go: URL { folder.appendingPathComponent("go") }
        var started: URL { folder.appendingPathComponent("started") }

        init(in folder: URL, version: String = "fake swift 1.0", gated: Bool = false) throws {
            self.folder = folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !gated { FileManager.default.createFile(atPath: folder.appendingPathComponent("go").path, contents: nil) }
            let script = """
                #!/bin/sh
                printf '%s\\n' "$*" >> '\(folder.path)/calls'
                scratch=""; previous=""
                for argument in "$@"; do [ "$previous" = --scratch-path ] && scratch=$argument; previous=$argument; done
                case " $* " in
                *" --version "*) echo "\(version)" ;;
                *" --show-bin-path "*) echo "$scratch/debug" ;;
                *" --product "*)
                    : > '\(folder.path)/started'
                    # Until the test says go: bounded, so a test that fails first doesn't leave it running.
                    n=0; while [ ! -e '\(folder.path)/go' ]; do n=$((n + 1)); [ $n -gt 6000 ] && exit 1; sleep 0.05; done
                    mkdir -p "$scratch/debug"
                    printf '#!/bin/sh\\necho the whole old host\\n' > "$scratch/debug/vibeswitcher-host"
                    chmod +x "$scratch/debug/vibeswitcher-host" ;;
                esac
                """
            try script.write(to: folder.appendingPathComponent("xcrun"), atomically: true, encoding: .utf8)
            try UpgradeFromLeadHostTests.run("/bin/chmod", ["+x", folder.appendingPathComponent("xcrun").path])
        }

        /// Each command it was given, in order.
        var calls: [String] {
            ((try? String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        /// The builds it made (the --show-bin-path after each asks where, and builds nothing).
        var builds: Int { calls.filter { $0.hasPrefix("swift build") && $0.contains("--product") }.count }
    }

    /// A checkout of its own (a worktree, a merge's or an audit's scratch one): only the resolved dependencies in its
    /// .build that the old host's build copies.
    static func fakeCheckout(_ folder: URL) throws -> URL {
        for item in ["checkouts", "repositories"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(".build/\(item)"), withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: folder.appendingPathComponent(".build/workspace-state.json").path, contents: Data("{}".utf8))
        return folder
    }

    /// A second checkout (another path, another .build) finds the old host the first built in the shared cache, and
    /// runs no swift build: only `swift --version`, for the toolchain's part of the entry's name. Another toolchain
    /// builds its own, once.
    @Test(.enabled(if: hasOldCommit, "needs commit 6311e18 in this clone"))
    func anotherCheckoutTakesTheCachedOldHost() async throws {
        let fake = try FakeToolchain(in: temp.url("old-host-toolchain"))
        let first = try Self.fakeCheckout(temp.url("old-host-checkout")), second = try Self.fakeCheckout(temp.url("old-host-checkout"))
        let built = try await offPool { try Self.oldHost(cache: fake.cache, checkout: first, xcrun: fake.xcrun) }
        #expect(fake.builds == 1)
        #expect(built.hasPrefix(fake.cache.path + "/\(Self.commit)-"))
        let before = fake.calls.count
        let again = try await offPool { try Self.oldHost(cache: fake.cache, checkout: second, xcrun: fake.xcrun) }
        #expect(again == built)
        #expect(Array(fake.calls.dropFirst(before)) == ["swift --version"])
        #expect(fake.builds == 1)

        let newer = try FakeToolchain(in: fake.folder, version: "fake swift 2.0")
        let rebuilt = try await offPool { try Self.oldHost(cache: newer.cache, checkout: second, xcrun: newer.xcrun) }
        #expect(rebuilt != built && newer.builds == 2)
    }

    /// Two runs at once build it once: the second waits on the lock while the first builds, then takes its build. What
    /// a stopped run left in the entry (a half-copied host under its staging name) is never taken for it, and the
    /// entry holds no host at all until the build is whole.
    @Test(.enabled(if: hasOldCommit, "needs commit 6311e18 in this clone"))
    func twoRunsAtOnceBuildItOnceAndNeitherTakesHalfABuild() async throws {
        let fake = try FakeToolchain(in: temp.url("old-host-toolchain"), gated: true)
        let first = try Self.fakeCheckout(temp.url("old-host-checkout")), second = try Self.fakeCheckout(temp.url("old-host-checkout"))
        let entry = try await offPool { try Self.cacheEntry(in: fake.cache, xcrun: fake.xcrun) }
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: entry.appendingPathComponent("host-0dead0ff").path, contents: Data("#!/bin/sh\necho half".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let host = entry.appendingPathComponent("vibeswitcher-host").path

        let waiting = DispatchSemaphore(value: 0)
        async let one = offPool { try Self.oldHost(cache: fake.cache, checkout: first, xcrun: fake.xcrun, waitingForLock: { waiting.signal() }) }
        async let two = offPool { try Self.oldHost(cache: fake.cache, checkout: second, xcrun: fake.xcrun, waitingForLock: { waiting.signal() }) }
        // One run holds the lock and builds; the other waits on it.
        #expect(await offPool { waiting.wait(timeout: .now() + hangGuard) } == .success)
        #expect(await eventually { FileManager.default.fileExists(atPath: fake.started.path) })
        #expect(!FileManager.default.fileExists(atPath: host), "the entry held a host before its build was done")
        FileManager.default.createFile(atPath: fake.go.path, contents: nil)
        let (a, b) = try await (one, two)
        #expect(a == host && b == host)
        #expect(fake.builds == 1)
        #expect(try String(contentsOfFile: host, encoding: .utf8).contains("the whole old host"))
    }

    @Test(.enabled(if: canBuildOldHost, "needs commit 6311e18 in this clone and its resolved dependencies in .build (or the old host built already in the main checkout's .vibeswitcher/old-hosts); a fresh clone or another Mac has neither, and nothing is downloaded"))
    func theAppSeesItsSessionsAfterAnOlderHostHandsOver() async throws {
        // The build (minutes on a loaded Mac) on a thread of its own, not on the cooperative pool.
        let host = try await ScratchHostProcess(old: try await offPool { try Self.oldHost() })
        defer { host.stop() }
        let (client, _, build, _, capabilities, pid, startedAt) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(build == host.oldBuild && pid == host.pid)
        #expect(capabilities?.contains(HostProtocol.Capability.handover) == true)
        let shell = try await client.spawn(nil)
        let done = try await client.spawn("echo finished-early; exit 3")
        #expect(await eventually { client.exitStatus(done.id) == 3 })
        #expect(await eventually { client.screen(shell.id)?.contains("$") == true })
        defer { kill(-shell.childPID, SIGKILL) }
        // The build from before PR #1: it shows its sessions to any client.
        let (before, _, _, shown, _, _, _) = try await TestClient.welcomed(host.socket)
        #expect(shown.map(\.id) == [shell.id, done.id])
        before.close()

        // A handover that doesn't happen ends the test here: every step after it would wait out a hang guard of its own.
        let seq = client.send(.handover(executable: host.newBinary))
        try #require(await eventually { client.reply(to: seq) != nil }, "no answer to the handover: \(host.log)")
        try #require(client.reply(to: seq) == .ok, "\(host.log)")
        try #require(await eventually { client.closed }, "the old build answered ok but kept the connection: \(host.log)")

        // The app proves itself to the new build and sees every session, as it was.
        let (app, _, newBuild, sessions, _, newPID, newStart) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        defer { app.close() }
        #expect(newBuild == host.newBuild, "\(host.log)")
        #expect(newPID == host.pid && newStart == startedAt)
        #expect(sessions.map(\.id) == [shell.id, done.id])
        #expect(sessions.first { $0.id == done.id }?.exit?.status == 3)
        await #expect(app.screen(done.id)?.contains("finished-early") == true)
        await app.attach(shell.id)
        app.send(.input(id: shell.id, bytes: Data("echo upgraded-$((6*7))\r".utf8), reply: false))
        #expect(await eventually { app.text(shell.id).contains("upgraded-42") })

        // A client that proves nothing sees none of them, and reaches none.
        let (stranger, _, _, seen, _, _, _) = try await TestClient.welcomed(host.socket)
        defer { stranger.close() }
        #expect(seen.isEmpty)
        let read = stranger.send(.screen(id: shell.id))
        #expect(await eventually { stranger.reply(to: read) != nil })
        #expect(stranger.reply(to: read) == .error(HostProtocol.unauthorized))
        // The old host's build left no agent file where the lead's audit would count it as the worktree's.
        #expect(Self.agentFilesUnderBuild() == [])
    }
}
