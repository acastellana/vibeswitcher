import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The project allow-list (the stage 2 plan's Task 10d, S2-D11; the security architecture document's S11, threat
/// T25): a host given a list (`HostServer.Config.projectAllowList`, the node's host's on Linux) starts a session only
/// inside a repository it names, or one of its worktrees, found by reading files. An in-process host (`TestHost`) with
/// a list in a scratch folder; the app asks, since the list holds for whoever asks. The repositories are made with git
/// by the test, never by the host.
struct ProjectAllowListTests {
    let scratch = Scratch()

    /// A new folder under the scratch folder, resolved (`/tmp` is `/private/tmp` on the Mac).
    func folder(_ name: String) throws -> String {
        let url = scratch.url(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().path
    }

    /// A repository with one commit, in a new folder.
    func repository(_ name: String) throws -> String {
        let root = try folder(name)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "T"], ["config", "commit.gpgsign", "false"]] {
            #expect(Git.run(args, in: root).ok)
        }
        try "a\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        #expect(Git.run(["add", "a.txt"], in: root).ok)
        #expect(Git.run(["commit", "-q", "-m", "a"], in: root).ok)
        return root
    }

    /// A real worktree of `repository` at `path`, on a branch of its own.
    func worktree(of repository: String, at path: String, branch: String) {
        #expect(Git.run(["worktree", "add", "-q", "-b", branch, path], in: repository).ok)
    }

    /// The list, naming `repositories`, in a folder of its own (with a comment and a blank line, which are skipped).
    func list(_ repositories: [String]) throws -> URL {
        let file = URL(fileURLWithPath: try folder("allow-list")).appendingPathComponent("projects")
        try (["# the repositories sessions may start in", ""] + repositories).joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// The host's reply to the app's spawn in `cwd`.
    func spawn(in cwd: String, _ client: TestClient) async -> HostEvent? {
        let seq = client.send(.spawn(SpawnRequest(cwd: cwd, command: "true", env: [:], cols: 80, rows: 24, keepShell: false,
                                                  label: "Allow-list", agent: nil)))
        #expect(await eventually { client.reply(to: seq) != nil })
        return client.reply(to: seq)
    }

    /// Whether `event` is a session started.
    static func started(_ event: HostEvent?) -> Bool {
        if case .spawned? = event { return true }
        return false
    }

    /// Why the spawn was refused, or nil when it wasn't.
    static func refusal(_ event: HostEvent?) -> String? {
        if case .error(let why)? = event { return why }
        return nil
    }

    /// A repository not on the list, a plain folder and a link inside the allowed repository to the other one are each
    /// refused, the reason naming the folder and the list; the allowed repository and a folder in it aren't.
    @Test func aSpawnOutsideTheListIsRefusedWithItsReason() async throws {
        let allowed = try repository("allowed")
        let other = try repository("other")
        let plain = try folder("plain")
        try FileManager.default.createDirectory(atPath: allowed + "/sub", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: allowed + "/elsewhere", withDestinationPath: other)
        let list = try list([allowed])
        let host = try TestHost(projectAllowList: list)
        let app = try TestClient(host)
        defer { app.close() }
        for cwd in [other, plain, allowed + "/elsewhere"] {
            let why = Self.refusal(await spawn(in: cwd, app))
            #expect(why?.contains(cwd) == true && why?.contains(list.path) == true && why?.contains("allow-list") == true,
                    "\(cwd): \(String(describing: why))")
        }
        for cwd in [allowed, allowed + "/sub"] {
            let event = await spawn(in: cwd, app)
            #expect(Self.started(event), "\(cwd): \(String(describing: event))")
        }
    }

    /// A worktree of the allowed repository outside its folder, a folder inside that worktree, and one of VibeSwitcher's
    /// own (`Worktrees.path`, inside the repository) each start a session.
    @Test func aWorktreeOfAnAllowedRepositoryIsAllowed() async throws {
        let allowed = try repository("allowed")
        let outside = try folder("worktrees") + "/one"
        worktree(of: allowed, at: outside, branch: "one")
        try FileManager.default.createDirectory(atPath: outside + "/deeper/still", withIntermediateDirectories: true)
        let inside = Worktrees.path(root: allowed, slug: "two")
        worktree(of: allowed, at: inside, branch: Worktrees.branch("two"))
        let host = try TestHost(projectAllowList: try list([allowed]))
        let app = try TestClient(host)
        defer { app.close() }
        for cwd in [outside, outside + "/deeper/still", inside] {
            let event = await spawn(in: cwd, app)
            #expect(Self.started(event), "\(cwd): \(String(describing: event))")
        }
    }

    /// A folder whose `.git` file names a real worktree's folder in the allowed repository (that folder's `gitdir`
    /// names the real worktree, not it) is refused; so is one whose `.git` names a folder that isn't there, and one
    /// whose `.git` names the allowed repository's own `.git`.
    @Test func aForgedGitFileIsRefused() async throws {
        let allowed = try repository("allowed")
        let real = try folder("worktrees") + "/real"
        worktree(of: allowed, at: real, branch: "real")
        let names = try FileManager.default.contentsOfDirectory(atPath: allowed + "/.git/worktrees")
        let entry = try #require(names.first, "no worktree entry")
        let forged = try folder("forged")
        try "gitdir: \(allowed)/.git/worktrees/\(entry)\n".write(toFile: forged + "/.git", atomically: true, encoding: .utf8)
        let nowhere = try folder("nowhere")
        try "gitdir: \(allowed)/.git/worktrees/missing\n".write(toFile: nowhere + "/.git", atomically: true, encoding: .utf8)
        let common = try folder("common")
        try "gitdir: \(allowed)/.git\n".write(toFile: common + "/.git", atomically: true, encoding: .utf8)
        let list = try list([allowed])
        let host = try TestHost(projectAllowList: list)
        let app = try TestClient(host)
        defer { app.close() }
        for cwd in [forged, nowhere, common] {
            let why = Self.refusal(await spawn(in: cwd, app))
            #expect(why?.contains(cwd) == true && why?.contains(list.path) == true, "\(cwd): \(String(describing: why))")
        }
        #expect(Self.started(await spawn(in: real, app)))
    }

    /// The guard rail's known limit: a folder whose `.git` file and an entry the test writes in the allowed
    /// repository's `.git/worktrees` name each other passes, though git never made it. Asserted, so a change to it is
    /// seen (the security architecture document's S11).
    @Test func aForgedWorktreePairPassesAsKnown() async throws {
        let allowed = try repository("allowed")
        let forged = try folder("forged-pair")
        let entry = allowed + "/.git/worktrees/forged"
        try FileManager.default.createDirectory(atPath: entry, withIntermediateDirectories: true)
        try "\(forged)/.git\n".write(toFile: entry + "/gitdir", atomically: true, encoding: .utf8)
        try "../..\n".write(toFile: entry + "/commondir", atomically: true, encoding: .utf8)
        try "gitdir: \(entry)\n".write(toFile: forged + "/.git", atomically: true, encoding: .utf8)
        let host = try TestHost(projectAllowList: try list([allowed]))
        let app = try TestClient(host)
        defer { app.close() }
        let event = await spawn(in: forged, app)
        #expect(Self.started(event), "\(String(describing: event))")
    }

    /// A scratch host (no `--node`) has no list: with a list in its home naming another folder, it starts a session in
    /// a folder that is in no repository. Only the node's host on Linux is given one (`ProjectAllowList.place`), and a
    /// `Config` has none until it is set.
    @Test func aScratchHostHasNoList() async throws {
        let config = HostServer.Config(socketPath: "/nonexistent/h.sock", lockPath: "/nonexistent/h.lock", shell: "/bin/sh", launcher: hostLauncher,
                                       baseEnvironment: [:], hostBuild: 1)
        #expect(config.projectAllowList == nil)
        #expect(ProjectAllowList.place(arguments: ["vibeswitcher-host", "--socket", "/x/h.sock", "--lock", "/x/h.lock"], accountHome: "/home/u") == nil)
        let node = ProjectAllowList.place(arguments: ["vibeswitcher-host", HostImages.nodeFlag], accountHome: "/home/u")
        #expect(node?.path == (Platform.CodeIdentity.isAvailable ? nil : "/home/u/.vibeswitcher/v2/projects"))

        let host = try await ScratchHostProcess { dir in
            try FileManager.default.createDirectory(atPath: dir + "/home/.vibeswitcher/v2", withIntermediateDirectories: true)
            try "\(dir)/home/elsewhere\n".write(toFile: dir + "/home/.vibeswitcher/v2/projects", atomically: true, encoding: .utf8)
        }
        defer { host.stop() }
        let (client, _, _, _, _, _, _) = try await TestClient.welcomed(host.socket, appKey: host.appKey)
        let ran = host.dir + "/ran"
        let session = try await client.spawn("touch '\(ran)'; \(keepRunning)", cwd: host.dir)
        defer { kill(-session.childPID, SIGKILL) }
        #expect(await eventually { FileManager.default.fileExists(atPath: ran) }, "\(host.log)")
    }

    /// With no file at the list's place, every spawn is refused, the allowed-looking repository's too, and the reason
    /// says where the list goes and what it holds. A FIFO there is no list either, and is refused at once, not waited on.
    @Test func aMissingListRefusesEverySpawnAndSaysWhereTheListGoes() async throws {
        let repository = try repository("repo")
        let missing = URL(fileURLWithPath: try folder("no-list")).appendingPathComponent("projects")
        let fifo = URL(fileURLWithPath: try folder("fifo-list")).appendingPathComponent("projects")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        for list in [missing, fifo] {
            let host = try TestHost(projectAllowList: list)
            let app = try TestClient(host)
            defer { app.close() }
            for cwd in [repository, try folder("plain")] {
                let why = Self.refusal(await spawn(in: cwd, app))
                #expect(why?.contains("no project allow-list at \(list.path)") == true && why?.contains("one absolute path a line") == true,
                        "\(list.path), \(cwd): \(String(describing: why))")
            }
        }
    }

    /// The check reads files only. Run in a process of its own (the test binary's `ProjectAllowListHelper` mode) whose
    /// PATH has first a `git` that records being run, and which may start no process at all (`RLIMIT_NPROC` 0): it
    /// still tells the allowed repository, its worktree and the forged pair from a forged file and a plain folder, and
    /// the `git` is never run.
    @Test func noGitRunsInTheHost() async throws {
        let allowed = try repository("allowed")
        let real = try folder("worktrees") + "/real"
        worktree(of: allowed, at: real, branch: "real")
        let entry = try #require(try FileManager.default.contentsOfDirectory(atPath: allowed + "/.git/worktrees").first)
        let forgedFile = try folder("forged")
        try "gitdir: \(allowed)/.git/worktrees/\(entry)\n".write(toFile: forgedFile + "/.git", atomically: true, encoding: .utf8)
        let forgedPair = try folder("forged-pair")
        let pairEntry = allowed + "/.git/worktrees/forged"
        try FileManager.default.createDirectory(atPath: pairEntry, withIntermediateDirectories: true)
        try "\(forgedPair)/.git\n".write(toFile: pairEntry + "/gitdir", atomically: true, encoding: .utf8)
        try "../..\n".write(toFile: pairEntry + "/commondir", atomically: true, encoding: .utf8)
        try "gitdir: \(pairEntry)\n".write(toFile: forgedPair + "/.git", atomically: true, encoding: .utf8)
        let plain = try folder("plain")
        let bin = try folder("bin")
        let marker = bin + "/git-ran"
        FileManager.default.createFile(atPath: bin + "/git", contents: Data("#!/bin/sh\ntouch '\(marker)'\nexec /usr/bin/git \"$@\"\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let list = try list([allowed])

        let folders = [allowed, real, forgedPair, forgedFile, plain]
        let said = try ProjectAllowListHelper.run(list: list.path, folders: folders, path: bin + ":/usr/bin:/bin")
        #expect(said == ["allowed", "allowed", "allowed", "refused", "refused"], "\(said)")
        #expect(!FileManager.default.fileExists(atPath: marker), "the check ran git")
    }
}

/// The test binary as the allow-list's check in a process of its own (`ProjectAllowListTests.noGitRunsInTheHost`).
/// Started again with `variable` set to a list's path and `foldersVariable` to folders, one a line, it first makes
/// itself unable to start a process (`RLIMIT_NPROC` 0), then checks each folder against the list
/// (`ProjectAllowList.refusal`) before any test of its own, says "allowed" or "refused" for each, one a line, and ends.
enum ProjectAllowListHelper {
    static let variable = "VIBE_ALLOW_LIST_HELPER"
    static let foldersVariable = "VIBE_ALLOW_LIST_HELPER_FOLDERS"

    static func checkIfAsked() {
        guard let value = getenv(variable) else { return }
        let list = URL(fileURLWithPath: String(cString: value))
        let folders = getenv(foldersVariable).map { String(cString: $0).split(separator: "\n").map(String.init) } ?? []
        // Where the limit can't be set, the recording git alone tells.
        _ = noProcesses()
        let said = folders.map { ProjectAllowList.refusal($0, list: list) == nil ? "allowed\n" : "refused\n" }.joined()
        _ = write(STDOUT_FILENO, said, said.utf8.count)
        _exit(0)
    }

    /// This process may start no other (`RLIMIT_NPROC` 0, soft and hard: a fork or spawn fails with `EAGAIN`, as the
    /// account runs processes already); whether that took.
    static func noProcesses() -> Bool {
        var none = rlimit(rlim_cur: 0, rlim_max: 0)
        #if os(Linux)
        return setrlimit(__rlimit_resource_t(__RLIMIT_NPROC.rawValue), &none) == 0
        #else
        return setrlimit(RLIMIT_NPROC, &none) == 0
        #endif
    }

    /// The helper's lines, for `folders` checked against the list at `list`, its PATH `path`. Ended after the hang
    /// guard: a check that tried to start a process (git) can wait for good on a thread that couldn't be made.
    static func run(list: String, folders: [String], path: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(Bundle.main.executablePath))
        process.arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment[variable] = list
        environment[foldersVariable] = folders.joined(separator: "\n")
        environment["PATH"] = path
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier
        let guardTimer = DispatchWorkItem { if process.isRunning { kill(pid, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + hangGuard, execute: guardTimer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guardTimer.cancel()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

// Runs as the test bundle loads, as the home guard does (TestSupport.swift).
#if os(Linux)
@_used @_section(".init_array")
private let checkTheAllowList: @convention(c) () -> Void = { ProjectAllowListHelper.checkIfAsked() }
#else
@_used @_section("__DATA,__mod_init_func")
private let checkTheAllowList: @convention(c) () -> Void = { ProjectAllowListHelper.checkIfAsked() }
#endif
