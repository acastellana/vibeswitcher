import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The user's running host is a build from before PR #1 (which made every session the app's alone to see, once it
/// proves itself). At the next install it hands its sessions over to this build: the app, proving itself to the new
/// build, sees them all and reaches them; a client that proves nothing sees none. The old build is the host of
/// project-lead just before PR #1 landed, built once from that commit into .build/old-hosts (its dependencies from this
/// checkout's, so nothing is downloaded). On a scratch host process (its own home, socket, lock and key).
/// Its time limit is `hostTestLimit`'s, plus the old host's build (`buildLimit`) that its first run makes.
@Suite(.serialized, .timeLimit(.minutes(25))) struct UpgradeFromLeadHostTests {
    /// project-lead before PR #1.
    static let commit = "6311e1890da61ca763de25fe6f67e96ca746598e"
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct BuildFailed: Error, CustomStringConvertible {
        let description: String
    }

    /// The old build's host: built once (minutes), then reused.
    static func oldHost() throws -> String {
        let folder = repo.appendingPathComponent(".build/old-hosts/\(commit)")
        let built = folder.appendingPathComponent("vibeswitcher-host").path
        if FileManager.default.isExecutableFile(atPath: built) { return built }
        // Built in a folder of its own and moved into place: two runs at once build twice, and neither sees half a build.
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
            try run("/bin/cp", ["-c", "-R", repo.appendingPathComponent(".build/\(item)").path, scratch.path + "/"])
        }
        // SwiftPM leaves folders in its TMPDIR: the build's own, removed with it.
        try run("/usr/bin/xcrun", ["swift", "build", "--package-path", source.path, "--scratch-path", scratch.path,
                                   "--disable-automatic-resolution", "--product", "vibeswitcher-host"], temporary: temporary, limit: buildLimit)
        let product = try run("/usr/bin/xcrun", ["swift", "build", "--package-path", source.path, "--scratch-path", scratch.path,
                                                 "--disable-automatic-resolution", "--show-bin-path"], temporary: temporary, limit: buildLimit)
        let binary = product.trimmingCharacters(in: .whitespacesAndNewlines) + "/vibeswitcher-host"
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

    /// The old build can be made here without downloading anything: built already, or its commit is in this clone, pins
    /// the same dependencies, and this checkout's resolved ones are in .build. A fresh clone without the commit, or another Mac without
    /// the dependencies, skips the test.
    static var canBuildOldHost: Bool {
        let built = repo.appendingPathComponent(".build/old-hosts/\(commit)/vibeswitcher-host").path
        if FileManager.default.isExecutableFile(atPath: built) { return true }
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
    @Test func aStepPastItsLimitIsStopped() throws {
        let started = Date()
        #expect(throws: BuildFailed.self) { try Self.run("/bin/sleep", ["3600"], limit: 1) }
        #expect(Date().timeIntervalSince(started) < hangGuard)
    }

    /// The old commit's export, where the old host builds (.build/old-hosts/COMMIT/work-*/src), holds its files but
    /// not its AGENTS.md or CLAUDE.md: while it's there, the audit sees no agent file under .build.
    @Test(.enabled(if: hasOldCommit, "needs commit 6311e18 in this clone"))
    func theOldCommitsExportLeavesItsAgentFilesOut() throws {
        let tracked = try Self.run("/usr/bin/git", ["ls-tree", "--name-only", Self.commit], in: Self.repo).components(separatedBy: "\n")
        #expect(tracked.contains("AGENTS.md") && tracked.contains("CLAUDE.md"), "the commit has no agent files to leave out")
        let work = Self.repo.appendingPathComponent(".build/old-hosts/\(Self.commit)/work-\(UUID().uuidString.prefix(8))")
        let source = work.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try Self.export(Self.commit, into: source, through: work.appendingPathComponent("tree.tar"))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("Package.swift").path))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("Sources").path))
        #expect(Self.agentFilesUnderBuild() == [])
    }

    @Test(.enabled(if: canBuildOldHost, "needs commit 6311e18 in this clone and its resolved dependencies in .build (or the old host built already in .build/old-hosts); a fresh clone or another Mac has neither, and nothing is downloaded"))
    func theAppSeesItsSessionsAfterAnOlderHostHandsOver() throws {
        let host = try ScratchHostProcess(old: try Self.oldHost())
        defer { host.stop() }
        let (client, _, build, _, capabilities, pid, startedAt) = try TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(build == host.oldBuild && pid == host.pid)
        #expect(capabilities?.contains(HostProtocol.Capability.handover) == true)
        let shell = try client.spawn(nil)
        let done = try client.spawn("echo finished-early; exit 3")
        #expect(eventually { client.exitStatus(done.id) == 3 })
        #expect(eventually { client.screen(shell.id)?.contains("$") == true })
        defer { kill(-shell.childPID, SIGKILL) }
        // The build from before PR #1: it shows its sessions to any client.
        let (before, _, _, shown, _, _, _) = try TestClient.welcomed(host.socket)
        #expect(shown.map(\.id) == [shell.id, done.id])
        before.close()

        // A handover that doesn't happen ends the test here: every step after it would wait out a hang guard of its own.
        let seq = client.send(.handover(executable: host.newBinary))
        try #require(eventually { client.reply(to: seq) != nil }, "no answer to the handover: \(host.log)")
        try #require(client.reply(to: seq) == .ok, "\(host.log)")
        try #require(eventually { client.closed }, "the old build answered ok but kept the connection: \(host.log)")

        // The app proves itself to the new build and sees every session, as it was.
        let (app, _, newBuild, sessions, _, newPID, newStart) = try TestClient.welcomed(host.socket, appKey: host.appKey)
        defer { app.close() }
        #expect(newBuild == host.newBuild, "\(host.log)")
        #expect(newPID == host.pid && newStart == startedAt)
        #expect(sessions.map(\.id) == [shell.id, done.id])
        #expect(sessions.first { $0.id == done.id }?.exit?.status == 3)
        #expect(app.screen(done.id)?.contains("finished-early") == true)
        app.attach(shell.id)
        app.send(.input(id: shell.id, bytes: Data("echo upgraded-$((6*7))\r".utf8), reply: false))
        #expect(eventually { app.text(shell.id).contains("upgraded-42") })

        // A client that proves nothing sees none of them, and reaches none.
        let (stranger, _, _, seen, _, _, _) = try TestClient.welcomed(host.socket)
        defer { stranger.close() }
        #expect(seen.isEmpty)
        let read = stranger.send(.screen(id: shell.id))
        #expect(eventually { stranger.reply(to: read) != nil })
        #expect(stranger.reply(to: read) == .error(HostProtocol.unauthorized))
        // The old host's build left no agent file where the lead's audit would count it as the worktree's.
        #expect(Self.agentFilesUnderBuild() == [])
    }
}
