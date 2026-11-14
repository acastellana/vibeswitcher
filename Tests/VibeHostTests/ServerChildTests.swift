import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A scratch host started as its own process with `--server` (this test binary by default, whose helper mode
/// `ServerChildHelper` stands in for the server), on its own home, socket and lock. The helper's actions file and its
/// results sit beside the socket; the host's stderr and stdout go to `output`, its session log to `sessionLog`.
final class ServerChildHost {
    /// `usersHost` asked on the Mac, where that host would read the real Keychain.
    struct UsersHostOnTheMac: Error {}

    let dir: String
    let home: String
    let socket: String
    let lock: String
    let sessionLog: String
    let output: String
    /// The `--server` path.
    let image: String
    let process = Process()

    /// `copyImage`: the server is a copy of the test binary in the host's folder (a test rewrites it), not the binary.
    /// `idleExit`: the host's `--idle-exit`. `extra`: more of the host's arguments. `usersHost`: no `--lock`, so the host
    /// takes its home's own lock (`<home>/.vibeswitcher/host.lock`) and is that home's user's host (`ownsLaunchers`).
    /// Linux only: on the Mac the user's host reads its vault's key from the real Keychain (`VaultStorage.keychainKey()`),
    /// which no test may (`KeychainLintTests`), so there it throws before anything starts.
    init(actions: [String] = [], copyImage: Bool = false, idleExit: String = "600", extra: [String] = [],
         usersHost: Bool = false) async throws {
        guard !usersHost || !Platform.CodeIdentity.isAvailable else { throw UsersHostOnTheMac() }
        // Short: a socket's path has a 104-byte limit.
        dir = "\(shortScratchRoot)/vssc-\(UUID().uuidString.prefix(8))"
        home = dir + "/home"
        socket = dir + "/h.sock"
        lock = usersHost ? home + "/.vibeswitcher/host.lock" : dir + "/h.lock"
        sessionLog = dir + "/session.log"
        output = dir + "/host.out"
        let files = FileManager.default
        for folder in [home, dir + "/work"] { try files.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        let binary = try #require(Bundle.main.executablePath)
        if copyImage {
            image = dir + "/server-image"
            try files.copyItem(atPath: binary, toPath: image)
        } else {
            image = binary
        }
        files.createFile(atPath: dir + "/" + ServerChildHelper.actionsName,
                         contents: Data(actions.map { $0 + "\n" }.joined().utf8))
        files.createFile(atPath: output, contents: nil)
        process.executableURL = URL(fileURLWithPath: hostLauncher)
        process.arguments = ["--socket", socket] + (usersHost ? [] : ["--lock", lock])
            + ["--idle-exit", idleExit, "--log", sessionLog, "--server", image] + extra
        process.environment = ["HOME": home, "CFFIXED_USER_HOME": home, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin", "TMPDIR": dir + "/"]
        let said = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
        process.standardOutput = said
        process.standardError = said
        process.standardInput = FileHandle.nullDevice
        try TestHosts.run(process)
        #expect(await eventually { (try? UnixSocket.connect(path: socket)).map { Sys.close($0); return true } ?? false }, "\(self.said)")
    }

    /// The host's stderr and stdout so far.
    var said: String { (try? String(contentsOfFile: output, encoding: .utf8)) ?? "" }
    /// The host's session log so far.
    var noted: String { (try? String(contentsOfFile: sessionLog, encoding: .utf8)) ?? "" }
    /// The helpers' result lines so far, each "PID WHAT".
    var results: [String] {
        ((try? String(contentsOfFile: dir + "/" + ServerChildHelper.resultsName, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// The helpers started so far, in order: their pids and the rest of their `started` lines.
    var started: [(pid: pid_t, line: String)] {
        results.compactMap { line in
            let words = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard words.count == 2, words[1].hasPrefix("started "), let pid = pid_t(words[0]) else { return nil }
            return (pid, words[1])
        }
    }

    /// What the helper `pid` said, without its pid, in order.
    func lines(of pid: pid_t) -> [String] {
        results.compactMap { line in
            let prefix = "\(pid) "
            return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
        }
    }

    /// The first helper, once it has started.
    func firstHelper() async -> pid_t? {
        _ = await eventually { !started.isEmpty }
        return started.first?.pid
    }

    /// The actions a helper started from now on reads: a new file put in the old one's place (the one running reads
    /// the file it opened).
    func replaceActions(_ actions: [String]) throws {
        let path = dir + "/" + ServerChildHelper.actionsName
        try Data(actions.map { $0 + "\n" }.joined().utf8).write(to: URL(fileURLWithPath: path + ".new"))
        guard rename(path + ".new", path) == 0 else { throw CancellationError() }
    }

    /// More actions for the helper running now (and any after it).
    func append(_ actions: [String]) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: dir + "/" + ServerChildHelper.actionsName))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(actions.map { $0 + "\n" }.joined().utf8))
    }

    var pid: pid_t { process.processIdentifier }

    /// Ends the host (its helper follows, its connector gone) and removes its files. Also when this goes.
    func stop() {
        let helpers = started.map(\.pid)
        TestHosts.end(process)
        // A helper sees its connector's end within a moment: waited for, so none outlives the test.
        _ = eventuallyBlocking(timeout: 30) { helpers.allSatisfy { kill($0, 0) != 0 && errno == ESRCH } }
        try? FileManager.default.removeItem(atPath: dir)
    }

    deinit { stop() }
}

/// The app on Linux is the host's server child, through its connector (the stage 2 plan's Task 8a, S2-D1; the
/// security architecture document's S2): the connections the host makes for the child it started from a sealed copy
/// of `--server` are the app, and nothing else is: not a connection by the socket's path, not a child of the server,
/// not another process writing on the server's connection, not a server that made itself dumpable. The child is
/// started again when it ends, from the copy, never from the file as it is by then; while it runs the host doesn't
/// exit idle. The child is this test binary in a helper mode (`ServerChildHelper`).
///
/// Serialized: each test's host holds a sealed copy of this binary (some hundreds of megabytes) in memory.
@Suite(hostTestLimit, .serialized) struct ServerChildTests {
    /// Three `HostCall`s from the helper, three connections through its connector, each answered as the app's: the
    /// census, a lead's grant from the vault, a spawn. The host's log names each connection it made, for the helper.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func theServerChildsConnectorConnectionsAreTheApp() async throws {
        let dir = "\(shortScratchRoot)/vssc-repo-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/work", withIntermediateDirectories: true)
        let host = try await ServerChildHost(actions: ["call census", "call vault-issue \(dir)/repo", "call spawn \(dir)/work"])
        defer { host.stop() }
        let helper = try #require(await host.firstHelper(), "\(host.said)")
        #expect(await eventually { host.lines(of: helper).count >= 4 }, "\(host.results)\n\(host.said)")
        #expect(Array(host.lines(of: helper).dropFirst()) == ["census ok", "vault-issue ok", "spawn ok"], "\(host.said)")
        let made = host.noted.components(separatedBy: "app connection made through connector").count - 1
        #expect(made == 3, "\(host.noted)")
        #expect(host.noted.contains("for pid \(helper)"), "\(host.noted)")
    }

    /// This test's own connection by the socket's path, to a host whose app is its server child (no stand-in of the
    /// test's: the host is started without one), is refused every request only the app may make.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func aConnectionFromAnotherProcessIsNotTheApp() async throws {
        let host = try await ServerChildHost(actions: ["sleep"])
        defer { host.stop() }
        #expect(await host.firstHelper() != nil, "\(host.said)")
        #expect(HostConnection.connector(for: host.socket) == nil)
        let byPath = try TestClient(socket: host.socket, appKey: nil, viaConnector: false)
        let requests: [HostRequest] = [
            .census,
            .spawn(SpawnRequest(cwd: host.dir + "/work", command: keepRunning, env: [:], cols: 80, rows: 24, keepShell: false, label: "Test",
                                agent: nil)),
            .vault(.issue(role: .lead, root: host.dir + "/repo", task: nil, auditing: nil)),
            .handover(executable: hostLauncher),
        ]
        let seqs = requests.map { byPath.send($0) }
        #expect(await eventually { seqs.allSatisfy { byPath.reply(to: $0) != nil } })
        for (request, seq) in zip(requests, seqs) {
            switch byPath.reply(to: seq) {
            case .error(let reason)?: #expect(reason == HostProtocol.unauthorized, "\(request): \(reason)")
            case .vault(.refused)?: break
            case let other: Issue.record("\(request) by path: \(String(describing: other))")
            }
        }
    }

    /// A child the helper starts, keeping every descriptor it may: the connector isn't among them (close-on-exec in the
    /// server from its first statements), and what it asks by the socket's path is refused.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func aChildOfTheServerIsNotTheApp() async throws {
        let binary = try #require(Bundle.main.executablePath)
        let host = try await ServerChildHost(actions: ["child-call census \(binary)", "call census"])
        defer { host.stop() }
        let helper = try #require(await host.firstHelper(), "\(host.said)")
        #expect(await eventually { host.lines(of: helper).contains("census ok") }, "\(host.results)\n\(host.said)")
        #expect(host.lines(of: helper).contains("child-called 0"), "\(host.results)")
        let child = host.results.filter { $0.contains(" child connector ") && !$0.hasPrefix("\(helper) ") }
        #expect(child.count == 1, "\(host.results)")
        #expect(child.first?.contains("child connector closed census refused") == true, "\(host.results)")
    }

    /// Task 7's rule on an app connection: a shell the helper starts writes a request on the helper's kept connection;
    /// the helper's own census on it, answered before, is refused after.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func anotherProcessWritingOnTheServersConnectionMakesItNobodys() async throws {
        let host = try await ServerChildHost(actions: ["hold", "held census", "fork-write census", "held census"])
        defer { host.stop() }
        let helper = try #require(await host.firstHelper(), "\(host.said)")
        #expect(await eventually { host.lines(of: helper).count >= 5 }, "\(host.results)\n\(host.said)")
        let said = Array(host.lines(of: helper).dropFirst())
        #expect(said.count == 4, "\(said)")
        guard said.count == 4 else { return }
        #expect(said[0] == "held")
        #expect(said[1] == "held census ok")
        #expect(said[2].hasPrefix("fork-wrote ") && said[2].hasSuffix(" 0"), "\(said[2])")
        #expect(said[3].hasPrefix("held census refused"), "\(said[3])")
        #expect(host.said.contains("pid \(helper) is no longer the one sending on its connection"), "\(host.said)")
    }

    /// Killed, the helper is started again: a new pid is the app, and the connection the old one left open (a shell of
    /// its keeps it) is ended. The host says both on its stderr.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func theServerIsStartedAgainAfterItDies() async throws {
        let host = try await ServerChildHost(actions: ["call census", "hold", "keep-held"])
        defer { host.stop() }
        let first = try #require(await host.firstHelper(), "\(host.said)")
        #expect(await eventually { host.lines(of: first).contains { $0.hasPrefix("keeping ") } }, "\(host.results)\n\(host.said)")
        #expect(host.lines(of: first).contains("census ok"), "\(host.results)")
        try host.replaceActions(["call census"])
        kill(first, SIGKILL)

        #expect(await eventually { host.started.count >= 2 }, "\(host.results)\n\(host.said)")
        let second = try #require(host.started.dropFirst().first?.pid)
        #expect(second != first)
        #expect(await eventually { host.lines(of: second).contains("census ok") }, "\(host.results)\n\(host.said)")
        #expect(await eventually { host.lines(of: first).contains("held-closed") }, "\(host.results)")
        #expect(host.said.contains("server child pid \(first) ended"), "\(host.said)")
        #expect(host.said.contains("server child pid \(second) started"), "\(host.said)")
    }

    /// Killed while a shell of its keeps its connector as well as its kept connection (so the host's end of the
    /// connector never sees the other end go), the helper's connection is still ended: on the child's end the host
    /// closes its connector itself, and with it every connection made through it, which is then no one's. Not only
    /// when the next start opens a connector under the same number, which would end the old one too, a second later:
    /// the old one is gone from the host's connectors by then, so nothing is replaced.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func aConnectionTheOldServerLeftIsEndedThoughItsConnectorLives() async throws {
        let host = try await ServerChildHost(actions: ["hold", "keep-held connector"])
        defer { host.stop() }
        let first = try #require(await host.firstHelper(), "\(host.said)")
        #expect(await eventually { host.lines(of: first).contains { $0.hasPrefix("keeping ") } }, "\(host.results)\n\(host.said)")
        #expect(host.lines(of: first).contains("held"), "\(host.results)")
        try host.replaceActions(["sleep"])
        kill(first, SIGKILL)

        #expect(await eventually { host.said.contains("server child pid \(first) ended") }, "\(host.said)")
        #expect(await eventually { host.lines(of: first).contains("held-closed") }, "\(host.results)\n\(host.said)")
        #expect(await eventually { host.started.count >= 2 }, "\(host.results)\n\(host.said)")
        let second = try #require(host.started.dropFirst().first?.pid)
        #expect(await eventually { host.said.contains("server child pid \(second) started") }, "\(host.said)")
        #expect(!host.noted.contains("replaced by a new one under its number"), "\(host.noted)")
    }

    /// A host that stops (as one told `--exit-with` does when its owner goes, and then waits for its sessions' end)
    /// ends its server child and starts none again: none running, none about to start. The child's token, recorded
    /// at its start, named it while it ran.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func aStoppedHostStartsNoServerChildAgain() async throws {
        let dir = "\(shortScratchRoot)/vssc-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let socket = dir + "/h.sock"
        FileManager.default.createFile(atPath: dir + "/" + ServerChildHelper.actionsName, contents: Data("sleep\n".utf8))
        var config = HostServer.Config(socketPath: socket, lockPath: dir + "/h.lock", shell: "/bin/sh", launcher: hostLauncher,
                                       baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], hostBuild: 42)
        config.idleExit = nil
        config.logPath = dir + "/host.log"
        let server = HostServer(config: config)
        try server.start()
        defer { server.stop(terminateSessions: true) }
        let binary = try #require(Bundle.main.executablePath)
        let child = try #require(ServerChild.start(.init(image: binary, socketPath: socket, arguments: [], environment: config.baseEnvironment),
                                                   server: server))
        defer { child.stop() }
        #expect(await eventually { child.pid != nil })
        let helper = try #require(child.pid)
        let token = try #require(child.token)
        #expect(Platform.Processes.link(helper)?.isProcess(of: token) == true)

        server.stop(terminateSessions: true)
        // The helper's end, however it came, handled on the host's queue to the end of that turn.
        #expect(await eventually { child.pid == nil && kill(helper, 0) != 0 && errno == ESRCH })
        server.queue.sync {}
        #expect(!child.isRunning)
        #expect(child.token == nil)
        #expect(child.restarts == 0)
    }

    /// `--server-arg` reaches a scratch host's server only: the user's host gives its server none of them (and says
    /// so, `ServerChild.adopt`), only its root and node root; without `--server`, nothing is started.
    @Test func theUsersHostGivesItsServerNoTestArguments() throws {
        let arguments = ["vibeswitcher-host", "--server", "/srv/server", "--server-arg", "--test-flag=1", "--idle-exit", "5",
                         "--server-arg", "two"]
        func launch(_ arguments: [String], usersHost: Bool) -> (launch: ServerChild.Launch, refused: [String])? {
            ServerChild.launch(arguments: arguments, ownsLaunchers: usersHost, socketPath: "/s", root: "/r", nodeRoot: "/n",
                               environment: ["A": "1"])
        }
        let users = try #require(launch(arguments, usersHost: true))
        #expect(users.launch.image == "/srv/server")
        #expect(users.launch.socketPath == "/s")
        #expect(users.launch.environment == ["A": "1"])
        #expect(users.launch.arguments == ["--root", "/r", "--node-root", "/n"])
        #expect(users.refused == ["--test-flag=1", "two"])
        let scratch = try #require(launch(arguments, usersHost: false))
        #expect(scratch.launch.arguments == ["--root", "/r", "--node-root", "/n", "--test-flag=1", "two"])
        #expect(scratch.refused.isEmpty)
        #expect(launch(["vibeswitcher-host", "--server-arg", "x"], usersHost: false) == nil)
    }

    /// The `--server` file rewritten in place (a script now) while the helper runs from its copy: what is started
    /// after the helper is killed is the helper again, from the copy, never the script.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func aServerFileRewrittenInPlaceIsNotWhatRestarts() async throws {
        let host = try await ServerChildHost(actions: ["sleep"], copyImage: true)
        defer { host.stop() }
        let first = try #require(await host.firstHelper(), "\(host.said)")
        let results = host.dir + "/" + ServerChildHelper.resultsName
        let script = Array("#!/bin/sh\necho \"$$ replaced\" >>'\(results)'\nexec sleep 3600\n".utf8)
        let fd = open(host.image, O_WRONLY | O_TRUNC | O_CLOEXEC)
        #expect(fd >= 0, "errno \(errno)")
        #expect(write(fd, script, script.count) == script.count)
        Sys.close(fd)
        kill(first, SIGKILL)

        #expect(await eventually { host.started.count >= 2 }, "\(host.results)\n\(host.said)")
        #expect(host.started.dropFirst().first?.line.contains("mark=\(ServerChildHelper.mark)") == true, "\(host.results)")
        #expect(!host.results.contains { $0.hasSuffix(" replaced") }, "\(host.results)")
    }

    /// A helper that makes itself dumpable again before it asks for a connection gets none, and is ended; the host's
    /// log and stderr say why.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func aServerChildThatIsDumpableIsNotTheApp() async throws {
        let host = try await ServerChildHost(actions: ["dumpable", "call census"])
        defer { host.stop() }
        let first = try #require(await host.firstHelper(), "\(host.said)")
        #expect(await eventually { host.said.contains("server child pid \(first) ended") }, "\(host.said)")
        #expect(host.lines(of: first).contains("dumpable 0"), "\(host.results)")
        #expect(host.noted.contains("pid \(first) is dumpable"), "\(host.noted)")
        #expect(host.said.contains("server child pid \(first) ended: it was dumpable when it asked for a connection"), "\(host.said)")
        #expect(!host.lines(of: first).contains("census ok"), "\(host.results)")
        #expect(!host.noted.contains("app connection made"), "\(host.noted)")
        #expect(await eventually { kill(first, 0) != 0 && errno == ESRCH })
    }

    /// With `maxClients` 2 taken by two clients by the socket's path (a third is turned away), the helper's
    /// connections through its connector are still made, and answered as the app's.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func appConnectionsDontCountTowardMaxClients() async throws {
        let dir = "\(shortScratchRoot)/vssc-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let socket = dir + "/h.sock", actions = dir + "/" + ServerChildHelper.actionsName
        FileManager.default.createFile(atPath: actions, contents: nil)
        var config = HostServer.Config(socketPath: socket, lockPath: dir + "/h.lock", shell: "/bin/sh", launcher: hostLauncher,
                                       baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], hostBuild: 42)
        config.idleExit = nil
        config.maxClients = 2
        config.vault = LeadVault.Book()
        config.logPath = dir + "/host.log"
        let server = HostServer(config: config)
        try server.start()
        defer { server.stop(terminateSessions: true) }
        let binary = try #require(Bundle.main.executablePath)
        let child = try #require(ServerChild.start(.init(image: binary, socketPath: socket, arguments: [], environment: config.baseEnvironment),
                                                   server: server))
        defer { child.stop() }
        func results() -> [String] {
            ((try? String(contentsOfFile: dir + "/" + ServerChildHelper.resultsName, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        #expect(await eventually { results().contains { $0.contains(" started ") } }, "\(results())")

        let clients = try (0..<2).map { _ in try TestClient(socket: socket, appKey: nil, viaConnector: false) }
        #expect(await eventually { clients.allSatisfy { $0.hasEvent { if case .challenge = $0 { return true } else { return false } } } })
        let turnedAway = try TestClient(socket: socket, appKey: nil, viaConnector: false)
        #expect(await eventually { turnedAway.closed })

        let actionsFile = try FileHandle(forWritingTo: URL(fileURLWithPath: actions))
        try actionsFile.write(contentsOf: Data("call census\ncall census\n".utf8))
        try actionsFile.close()
        #expect(await eventually { results().filter { $0.hasSuffix(" census ok") }.count == 2 }, "\(results())")
        #expect(child.pid != nil)
    }

    /// A host told to exit after 1 s idle, with a server child that holds no connection, is still there when a host
    /// beside it, told the same with no server, has exited idle.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func aHostWithAServerChildDoesNotExitIdle() async throws {
        let host = try await ServerChildHost(actions: ["sleep"], idleExit: "1")
        defer { host.stop() }
        let helper = try #require(await host.firstHelper(), "\(host.said)")

        let plain = Process()
        plain.executableURL = URL(fileURLWithPath: hostLauncher)
        plain.arguments = ["--socket", host.dir + "/plain.sock", "--lock", host.dir + "/plain.lock", "--idle-exit", "1"]
        plain.environment = ["HOME": host.home, "CFFIXED_USER_HOME": host.home, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin",
                             "TMPDIR": host.dir + "/"]
        plain.standardOutput = FileHandle.nullDevice
        plain.standardError = FileHandle.nullDevice
        plain.standardInput = FileHandle.nullDevice
        try TestHosts.run(plain)
        defer { TestHosts.end(plain) }
        #expect(await exited(plain), "the plain host never exited idle")

        #expect(host.process.isRunning, "\(host.said)")
        #expect(kill(helper, 0) == 0)
        #expect(!host.noted.contains("idle"), "\(host.noted)")
    }

    /// Under a host that is its own process (never this test process, which is dumpable and would hold the copy), the
    /// helper is non-dumpable from its exec, before its own `harden()`: it said so first thing, and its memory is
    /// closed to this process.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func theServerHelperIsNotDumpable() async throws {
        let host = try await ServerChildHost(actions: ["sleep"])
        defer { host.stop() }
        let helper = try #require(await host.firstHelper(), "\(host.said)")
        #expect(host.started.first?.line.contains("dumpable-at-start=false") == true, "\(host.results)")
        #expect(host.started.first?.line.contains("image=none") == false, "\(host.results)")
        let memory = open("/proc/\(helper)/mem", O_RDONLY | O_CLOEXEC)
        let code = errno
        if memory >= 0 { Sys.close(memory) }
        #expect(memory < 0 && code == EACCES, "open: \(memory), errno \(code)")
        #expect(Platform.Processes.isDumpable(helper) == false)
    }

    /// The helper is given the host's socket, the host's VibeSwitcher folder as `--root`, the folder of the host's
    /// executable as `--node-root` (until Task 9b's `--node-root`), and each `--server-arg` after them.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func theServerChildIsToldItsSocketAndFolder() async throws {
        let host = try await ServerChildHost(actions: ["sleep"], extra: ["--server-arg", "--test-flag=1", "--server-arg", "two"])
        defer { host.stop() }
        #expect(await host.firstHelper() != nil, "\(host.said)")
        let line = try #require(host.started.first?.line)
        let folder = URL(fileURLWithPath: hostLauncher).deletingLastPathComponent().path
        #expect(line.contains(" socket=\(host.socket) "), "\(line)")
        #expect(line.contains(" root=\(host.home)/.vibeswitcher "), "\(line)")
        #expect(line.contains(" node-root=\(folder) "), "\(line)")
        #expect(line.hasSuffix(" rest=--test-flag=1,two"), "\(line)")
    }

    // MARK: Task 8b: across a handover, the host's path, and the journal

    /// After a handover to the same build, the helper started before is still the app: the same pid, through the
    /// connector it was started with (the new image took the host's end from the state, once it had checked it), its
    /// census answered; no helper was started again. Killed then, it is started again from the copy the handover
    /// carried, non-dumpable from its exec.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func theServerChildSurvivesAHandover() async throws {
        let host = try await ServerChildHost(actions: ["call census", "handover \(hostLauncher)", "call census"])
        defer { host.stop() }
        let helper = try #require(await host.firstHelper(), "\(host.said)")
        #expect(await eventually { host.lines(of: helper).count >= 4 }, "\(host.results)\n\(host.said)")
        #expect(Array(host.lines(of: helper).dropFirst()) == ["census ok", "handover ok", "census ok"], "\(host.results)\n\(host.said)")
        #expect(host.said.contains("took over"), "\(host.said)")
        #expect(host.said.contains("server child pid \(helper) carried over from the build before"), "\(host.said)")
        #expect(!host.said.contains("server child record refused"), "\(host.said)")
        #expect(host.started.count == 1, "\(host.results)")
        #expect(host.process.isRunning)
        let made = host.noted.components(separatedBy: "app connection made through connector").count - 1
        #expect(made == 3, "\(host.noted)")

        try host.replaceActions(["call census"])
        kill(helper, SIGKILL)
        #expect(await eventually { host.started.count >= 2 }, "\(host.results)\n\(host.said)")
        let second = try #require(host.started.dropFirst().first)
        #expect(second.line.contains("mark=\(ServerChildHelper.mark)") && second.line.contains("dumpable-at-start=false"), "\(second.line)")
        #expect(await eventually { host.lines(of: second.pid).contains("census ok") }, "\(host.results)\n\(host.said)")
        #expect(host.said.contains("server child pid \(helper) ended"), "\(host.said)")
    }

    /// The restore's own check (`ServerChild.restore`), given a record that names a session's program (a child of
    /// the host, as a server child is, but not the server) and a connector of the test's making: the record is
    /// refused, saying why; its connector is taken by no one and the program is left running and is no app; a new
    /// server child is started, from a fresh copy of `--server`.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func aForgedServerChildInTheStateIsNotTheApp() async throws {
        let dir = "\(shortScratchRoot)/vssc-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: dir + "/" + ServerChildHelper.actionsName, contents: Data("sleep\n".utf8))
        let host = try TestHost(log: dir + "/host.log", socket: dir + "/h.sock")
        let app = try TestClient(host)
        let session = try await app.spawn(keepRunning)
        let program = session.childPID
        let link = try #require(Platform.Processes.link(program))
        #expect(link.parent == getpid(), "a session's program is the host's child, as its server is")
        let (forged, othersEnd) = try #require(Platform.Sockets.pair(type: Platform.Sockets.seqpacket))
        defer {
            Sys.close(forged)
            Sys.close(othersEnd)
        }
        let binary = try #require(Bundle.main.executablePath)
        let record = HostHandover.ServerChildRecord(pid: program, startTicks: link.startTicks, connector: forged, image: -1, path: binary)
        #expect(ServerChild.check(record, sessionPrograms: [program], otherDescriptors: [])
                == "pid \(program) is a session's program")
        let child = try #require(ServerChild.restore(record, launch: .init(image: binary, socketPath: host.socket, arguments: [],
                                                                           environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]),
                                                     sessionPrograms: [program], otherDescriptors: [], server: host.server))
        defer { child.stop() }
        #expect(await eventually { child.pid != nil })
        let helper = try #require(child.pid)
        #expect(helper != program)
        func results() -> [String] {
            ((try? String(contentsOfFile: dir + "/" + ServerChildHelper.resultsName, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        #expect(await eventually { results().contains { $0.hasPrefix("\(helper) started ") } }, "\(results())")
        #expect(host.server.queue.sync { host.server.appConnectors[forged] == nil })
        #expect(host.server.queue.sync { host.server.appConnectors.values.allSatisfy { $0.sender?.pid != program } })
        #expect(host.server.identify(Platform.Processes.token(program)) == .session(session.id.uuidString))
        #expect(kill(program, 0) == 0, "a session's program named in a record is left alone")
        // Nothing reads the forged connector: a byte on its other end is never answered with a connection.
        var byte: UInt8 = 1
        #expect(send(othersEnd, &byte, 1, 0) == 1)
        #expect(await eventually { child.pid != nil && child.token != nil })
        var waiting = pollfd(fd: othersEnd, events: Int16(POLLIN), revents: 0)
        #expect(poll(&waiting, 1, 500) == 0, "the forged connector was answered")
        #expect(host.server.queue.sync { host.server.appConnectors.count } == 2, "the test's connector and the new child's")
    }

    /// The other half of the check: a record of the host's own child, started when it says, no session's program nor
    /// parser, is still refused when its connector isn't one handed over (one this image made, close-on-exec; another
    /// descriptor of the state; no socket), and when its start ticks or parent differ. One that names another
    /// `--server` is not refused: a handover to another build keeps the running server (S2-D8).
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func theRestoresCheckNamesWhatIsWrong() throws {
        var child: pid_t = 0
        var spawn = Platform.Spawn(executable: "/bin/sleep", arguments: ["sleep", "60"])
        spawn.keep = []
        if case .success(let pid) = spawn.start() { child = pid }
        #expect(child > 0)
        defer {
            kill(child, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(child, &status, 0)
        }
        let link = try #require(Platform.Processes.link(child))
        let (made, other) = try #require(Platform.Sockets.pair(type: Platform.Sockets.seqpacket))
        defer {
            Sys.close(made)
            Sys.close(other)
        }
        // As a handover's exec leaves a kept descriptor: open, not close-on-exec.
        let inherited = fcntl(made, F_DUPFD, 3)
        defer { Sys.close(inherited) }
        let record = HostHandover.ServerChildRecord(pid: child, startTicks: link.startTicks, connector: inherited, image: -1, path: "/srv/server")
        func check(_ record: HostHandover.ServerChildRecord, others: Set<Int32> = [], links: @escaping (pid_t) -> Platform.Processes.Link? = Platform.Processes.link) -> String? {
            ServerChild.check(record, sessionPrograms: [], otherDescriptors: others, links: links, isParser: { _ in false })
        }
        #expect(check(record) == nil)
        var closedOnExec = record
        closedOnExec.connector = made
        #expect(check(closedOnExec) == "its connector \(made) isn't a connector handed over")
        #expect(check(record, others: [inherited]) == "its connector \(inherited) isn't a connector handed over")
        let file = open("/dev/null", O_RDONLY)
        defer { Sys.close(file) }
        var notASocket = record
        notASocket.connector = file
        #expect(check(notASocket)?.hasPrefix("its connector") == true)
        var elsewhere = record
        elsewhere.path = "/opt/server"
        #expect(check(elsewhere) == nil)
        var later = record
        later.startTicks += 1
        #expect(check(later) == "pid \(child) isn't the process recorded (it started at another time)")
        #expect(check(record, links: { pid in Platform.Processes.link(pid).map { var other = $0; other.parent = 1; return other } })
                == "pid \(child) isn't this host's child")
        #expect(check(record, links: { _ in nil }) == "pid \(child) is gone")
        #expect(ServerChild.check(record, sessionPrograms: [], otherDescriptors: [], isParser: { $0 == child })
                == "pid \(child) is a session's parser")
    }

    /// A host that watches its path: a process renames its own listening socket over the host's; the host binds its
    /// path again at once (its folder watch), a client by the path then reaches the host (its challenge), and the
    /// app's `hostNotes` lists the path; by the path, `hostNotes` is refused.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "the host watches its path on Linux"))
    func aSquattedHostPathIsBoundAgain() async throws {
        let dir = "\(shortScratchRoot)/vssp-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let host = try TestHost(watchesItsPath: true, socket: dir + "/h.sock")
        let bound = try #require(HostPathWatch.identity(atPath: host.socket))
        let squat = dir + "/squat.sock"
        let squatter = try UnixSocket.listen(path: squat)
        defer { Sys.close(squatter) }
        let squatted = try #require(HostPathWatch.identity(atPath: squat))
        #expect(rename(squat, host.socket) == 0)
        #expect(await eventually {
            let now = HostPathWatch.identity(atPath: host.socket)
            return now != nil && now != squatted && now != bound
        })
        let byPath = try TestClient(socket: host.socket, appKey: nil, viaConnector: false)
        #expect(await eventually { byPath.hasEvent { if case .challenge = $0 { return true } else { return false } } })

        let app = try TestClient(host)
        let seq = app.send(.hostNotes)
        #expect(await eventually { app.reply(to: seq) != nil })
        guard case .hostNotes(let notes)? = app.reply(to: seq) else { Issue.record("\(String(describing: app.reply(to: seq)))"); return }
        #expect(notes.replacedPaths == [host.socket])
        #expect(notes.startedAt <= Date() && notes.startedAt >= host.startedAt.addingTimeInterval(-1))
        let refused = byPath.send(.hostNotes)
        #expect(await eventually { byPath.reply(to: refused) != nil })
        #expect(byPath.reply(to: refused) == .error(HostProtocol.unauthorized))
    }

    /// A host that watches its path: another file renamed over its lock is locked again, so a second host can't take
    /// it; the app's `hostNotes` lists the path.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "the host watches its path on Linux"))
    func aReplacedLockPathIsLockedAgain() async throws {
        let dir = "\(shortScratchRoot)/vssp-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let host = try TestHost(watchesItsPath: true, socket: dir + "/h.sock")
        let other = dir + "/other.lock"
        #expect(FileManager.default.createFile(atPath: other, contents: nil))
        #expect(rename(other, host.lock) == 0)
        #expect(await eventually {
            let fd = open(host.lock, O_RDWR | O_CLOEXEC)
            defer { if fd >= 0 { Sys.close(fd) } }
            return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
        })
        let app = try TestClient(host)
        let seq = app.send(.hostNotes)
        #expect(await eventually { app.reply(to: seq) != nil })
        guard case .hostNotes(let notes)? = app.reply(to: seq) else { Issue.record("\(String(describing: app.reply(to: seq)))"); return }
        #expect(notes.replacedPaths == [host.lock])
    }

    /// A host that isn't told to watch its path (every scratch host, and the Mac's) leaves a squatter there.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "the host watches its path on Linux"))
    func aHostNotToldToWatchLeavesItsPath() async throws {
        let dir = "\(shortScratchRoot)/vssp-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let host = try TestHost(housekeeping: 0.2, socket: dir + "/h.sock")
        let squat = dir + "/squat.sock"
        let squatter = try UnixSocket.listen(path: squat)
        defer { Sys.close(squatter) }
        let squatted = try #require(HostPathWatch.identity(atPath: squat))
        #expect(rename(squat, host.socket) == 0)
        // Two housekeepings and more.
        await pause(1)
        #expect(HostPathWatch.identity(atPath: host.socket) == squatted)
        #expect(host.server.queue.sync { host.server.pathWatch == nil })
    }

    /// The counts `hostNotes` gives the app alone: a request on an app connector before its process is named
    /// is refused and counted; no restart, no path replaced; the welcome lists the capability on Linux.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "hostNotes is Linux's"))
    func hostNotesCountWhatTheHostRefused() async throws {
        let host = try TestHost()
        // A connector whose process isn't named yet: every request on it is refused.
        let connector = try #require(host.server.openAppConnector(expecting: nil, requireNonDumpable: false, onDumpable: nil))
        defer {
            host.server.closeAppConnector(connector)
            Sys.close(connector)
        }
        var byte: UInt8 = 1
        #expect(send(connector, &byte, 1, 0) == 1)
        #expect(await eventually { host.server.queue.sync { host.server.tally.refusedAppConnections } == 1 })
        let app = try TestClient(host)
        let seq = app.send(.hostNotes)
        #expect(await eventually { app.reply(to: seq) != nil })
        guard case .hostNotes(let notes)? = app.reply(to: seq) else { Issue.record("\(String(describing: app.reply(to: seq)))"); return }
        #expect(notes.serverRestarts == 0 && notes.replacedPaths.isEmpty && notes.refusedAppConnections == 1)
        let hello = app.send(.hello(protocolVersion: HostProtocol.version, app: "test"))
        #expect(await eventually { app.reply(to: hello) != nil })
        guard case .welcome(_, _, _, let capabilities, _, _)? = app.reply(to: hello) else { Issue.record("no welcome"); return }
        #expect(capabilities?.contains(HostProtocol.Capability.hostNotes) == true)
    }

    /// The journal: the host's stderr says its start, the server child's end with its status, its start again, and an
    /// app connection refused, each one line of its own, ids and counts only.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func theHostWritesStartsAndServerRestartsToStderr() async throws {
        let host = try await ServerChildHost(actions: ["dumpable", "call census"])
        defer { host.stop() }
        let first = try #require(await host.firstHelper(), "\(host.said)")
        #expect(await eventually { host.started.count >= 2 }, "\(host.results)\n\(host.said)")
        let second = try #require(host.started.dropFirst().first?.pid)
        #expect(await eventually { host.said.contains("server child pid \(second) started") }, "\(host.said)")
        let lines = host.said.split(separator: "\n").map(String.init)
        func line(_ part: String) -> String? { lines.first { $0.contains(part) } }
        #expect(lines.contains { $0.hasPrefix("vibeswitcher-host: started ") }, "\(host.said)")
        let ended = try #require(line("server child pid \(first) ended after"), "\(host.said)")
        #expect(ended.hasPrefix("vibeswitcher-host: ") && ended.contains("signal 9 (SIGKILL)"), "\(ended)")
        let restarted = try #require(line("server child pid \(second) started from"), "\(host.said)")
        #expect(restarted.hasPrefix("vibeswitcher-host: "), "\(restarted)")
        let refused = try #require(line("refused an app connection through connector"), "\(host.said)")
        #expect(refused.hasPrefix("vibeswitcher-host: ") && refused.contains("pid \(first) is dumpable"), "\(refused)")
    }

    /// A record the restore keeps, of a process of this test's (a `sleep`, the host's child as a server child is) and a
    /// connector handed over, whose copy is a pipe's writing end inherited across the exec, which no sealed copy is:
    /// restored with `path` as the record's `--server`, the child runs on, now the app's, and the copy is closed (the
    /// pipe's reading end, here, sees its end). The host's log is returned.
    private func restoreAKeptChild(recordedPath: (_ binary: String) -> String) async throws -> String {
        let dir = "\(shortScratchRoot)/vssc-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/" + ServerChildHelper.actionsName, contents: Data("sleep\n".utf8))
        let log = dir + "/host.log"
        let host = try TestHost(log: log, removing: dir, socket: dir + "/h.sock")
        var child: pid_t = 0
        var spawn = Platform.Spawn(executable: "/bin/sleep", arguments: ["sleep", "600"])
        spawn.keep = []
        if case .success(let pid) = spawn.start() { child = pid }
        try #require(child > 0)
        let link = try #require(Platform.Processes.link(child))
        // Ended here only when nothing reaped it (the restored child's `stop` does): its pid, once reaped, may be
        // another test's process by now.
        defer {
            var status: Int32 = 0
            if Platform.Processes.link(child)?.startTicks == link.startTicks, waitpid(child, &status, WNOHANG) == 0 {
                kill(child, SIGKILL)
                _ = waitpid(child, &status, 0)
            }
        }
        let (made, othersEnd) = try #require(Platform.Sockets.pair(type: Platform.Sockets.seqpacket))
        defer { Sys.close(othersEnd) }
        // As a handover's exec leaves kept descriptors: open, not close-on-exec.
        let connector = fcntl(made, F_DUPFD, 3)
        Sys.close(made)
        var pipe: [Int32] = [-1, -1]
        try #require(Sys.pipeClosedOnExec(&pipe) == 0)
        defer { Sys.close(pipe[0]) }
        let copy = fcntl(pipe[1], F_DUPFD, 3)
        Sys.close(pipe[1])
        let binary = try #require(Bundle.main.executablePath)
        let record = HostHandover.ServerChildRecord(pid: child, startTicks: link.startTicks, connector: connector, image: copy,
                                                    path: recordedPath(binary))
        let restored = try #require(ServerChild.restore(record, launch: .init(image: binary, socketPath: host.socket, arguments: [],
                                                                              environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]),
                                                        sessionPrograms: [], otherDescriptors: [], server: host.server))
        defer { restored.stop() }
        #expect(await eventually { restored.pid == child })
        #expect(kill(child, 0) == 0, "the child runs on")
        #expect(host.server.queue.sync { host.server.appConnectors[connector]?.sender?.pid } == child)
        // The copy's descriptor closed (by `restore` itself, before it returned): the pipe's other end reads its end.
        var byte: UInt8 = 0
        var waiting = pollfd(fd: pipe[0], events: Int16(POLLIN), revents: 0)
        #expect(poll(&waiting, 1, 0) == 1 && read(pipe[0], &byte, 1) == 0, "the carried copy is still open")
        return (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
    }

    /// A handover to another build (its `--server` another path, S2-D7) keeps the running server child: it is still
    /// the app, and its next start is from this image's `--server`, the copy carried closed (S2-D8; Task 9d decides any
    /// start again at once, by hash).
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func aServerChildOfAnotherServerPathRunsOn() async throws {
        let log = try await restoreAKeptChild { _ in "/opt/an-older-build/vibeswitcher-server" }
        #expect(log.contains("runs on from /opt/an-older-build/vibeswitcher-server; its next start is from this image's --server"), "\(log)")
        #expect(!log.contains("record refused"), "\(log)")
    }

    /// A record whose copy is not one to take again (inherited, but no sealed copy): the next start is from a fresh copy,
    /// and the inherited descriptor is closed, not left open and inheritable for the host's life.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "Linux's server child; the Mac's app proves itself by its code"))
    func aCarriedCopyNotTakenIsClosed() async throws {
        let log = try await restoreAKeptChild { $0 }
        #expect(log.contains("sealed copy wasn't one to take again"), "\(log)")
    }

    /// A process renames its own listening socket over the host's path just after the host bound a fresh one there
    /// (the watch's test hook, between the bind and the check): what the path names then leads to that process, not the
    /// host, so it is not recorded as the host's; the host binds again, and a client by the path reaches the host.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "the host watches its path on Linux"))
    func aSocketRenamedOverJustAfterTheBindIsNotTakenForTheHosts() async throws {
        let dir = "\(shortScratchRoot)/vssp-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = dir + "/host.log"
        let host = try TestHost(log: log, removing: dir, watchesItsPath: true, socket: dir + "/h.sock")
        let squat = dir + "/squat.sock"
        let squatter = try PathSquatterHelper.Running.start(at: squat)
        defer { squatter.end() }
        let squatted = try #require(HostPathWatch.identity(atPath: squat))
        let watch = try #require(host.server.queue.sync { host.server.pathWatch })
        // The path alone: the hook, held by the host's watch, holds no `TestHost`, which would never go then.
        let socket = host.socket
        host.server.queue.sync {
            var renamed = false
            watch.afterBind = {
                guard !renamed else { return }
                renamed = true
                _ = rename(squat, socket)
            }
        }
        #expect(unlink(host.socket) == 0)
        func noted() -> String { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }
        #expect(await eventually { noted().contains("socket path \(host.socket) named nothing: bound a fresh listener there") }, "\(noted())")
        #expect(HostPathWatch.identity(atPath: squat) == nil, "the squatter's socket was renamed over the path")
        let now = HostPathWatch.identity(atPath: host.socket)
        #expect(now != nil && now != squatted)
        let byPath = try TestClient(socket: host.socket, appKey: nil, viaConnector: false)
        #expect(await eventually(timeout: 60) { byPath.hasEvent { if case .challenge = $0 { return true } else { return false } } })
    }

    /// Both paths changed before the watch begins (as during a handover's exec): a squatter's socket at the socket path
    /// is not recorded as the host's, and the first check, at once rather than a housekeeping later, binds the path
    /// again and locks the file at the lock path.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "the host watches its path on Linux"))
    func pathsChangedBeforeTheWatchBeginsAreTakenBackAtOnce() async throws {
        let dir = "\(shortScratchRoot)/vssp-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = dir + "/host.log"
        let host = try TestHost(log: log, removing: dir, socket: dir + "/h.sock")
        let squat = dir + "/squat.sock"
        let squatter = try PathSquatterHelper.Running.start(at: squat)
        defer { squatter.end() }
        let squatted = try #require(HostPathWatch.identity(atPath: squat))
        #expect(rename(squat, host.socket) == 0)
        // The server's own lock file, for its identity (as its descriptor's `fstat` gives it).
        let ownLock = open(host.lock, O_RDWR | O_CLOEXEC)
        defer { Sys.close(ownLock) }
        let other = dir + "/other.lock"
        #expect(FileManager.default.createFile(atPath: other, contents: nil))
        let otherFD = open(other, O_RDWR | O_CLOEXEC)
        defer { Sys.close(otherFD) }
        #expect(rename(other, host.lock) == 0)
        var config = HostServer.Config(socketPath: host.socket, lockPath: host.lock, shell: "/bin/sh", launcher: hostLauncher,
                                       baseEnvironment: [:], hostBuild: 42)
        // No housekeeping within the test: only the first check can take them back.
        config.housekeepingInterval = 3600
        host.server.queue.sync { host.server.pathWatch = HostPathWatch.start(for: host.server, config: config, lockFD: ownLock) }
        func noted() -> String { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }
        #expect(await eventually(timeout: 60) { noted().contains("socket path \(host.socket) named another file: bound a fresh listener there") },
                "\(noted())")
        let now = HostPathWatch.identity(atPath: host.socket)
        #expect(now != nil && now != squatted)
        let byPath = try TestClient(socket: host.socket, appKey: nil, viaConnector: false)
        #expect(await eventually(timeout: 60) { byPath.hasEvent { if case .challenge = $0 { return true } else { return false } } })
        #expect(await eventually(timeout: 60) { noted().contains("lock path \(host.lock) named another file: locked the file there again") },
                "\(noted())")
        #expect(flock(otherFD, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK)
    }

    /// Fresh files renamed over the lock path one after another: each is locked again, and the one locked before
    /// released (it is no longer at the path), so the host holds two locks at most, not one more each time. The host's
    /// own lock file put back is held already: the lock taken again is released, and nothing says another process
    /// holds it.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "the host watches its path on Linux"))
    func aLockPathReplacedAgainAndAgainHoldsOnlyTheNewest() async throws {
        let dir = "\(shortScratchRoot)/vssp-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = dir + "/host.log"
        let host = try TestHost(log: log, removing: dir, watchesItsPath: true, socket: dir + "/h.sock")
        func noted() -> String { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }
        let original = dir + "/original.lock"
        #expect(link(host.lock, original) == 0)
        var files: [Int32] = []
        defer { files.forEach { Sys.close($0) } }
        for round in 1...4 {
            let file = dir + "/other-\(round).lock"
            #expect(FileManager.default.createFile(atPath: file, contents: nil))
            files.append(open(file, O_RDWR | O_CLOEXEC))
            #expect(rename(file, host.lock) == 0)
            #expect(await eventually { noted().components(separatedBy: "locked the file there again").count - 1 == round }, "\(noted())")
        }
        for (round, fd) in files.dropLast().enumerated() {
            #expect(flock(fd, LOCK_EX | LOCK_NB) == 0, "the file of round \(round + 1) is still locked")
            _ = flock(fd, LOCK_UN)
        }
        let newest = try #require(files.last)
        #expect(flock(newest, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK)

        #expect(rename(original, host.lock) == 0)
        #expect(await eventually(timeout: 60) { noted().contains("lock path \(host.lock) names the host's own lock file again") }, "\(noted())")
        #expect(!noted().contains("another process holds"), "\(noted())")
        #expect(host.server.queue.sync { host.server.pathWatch?.retakenLock } == -1)
        #expect(flock(newest, LOCK_EX | LOCK_NB) == 0, "the lock taken again is still held")
    }

    /// A handover's state carries the lock the lock path names (the one taken again), not the host's first lock, whose
    /// file is no longer there: the next image holds the user's lock. It carries what `hostNotes` counted too. The
    /// state is read while the probe (a script that waits to be told) runs; the probe's no leaves the host serving.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "the host watches its path on Linux"))
    func aHandoverCarriesTheLockThePathNamesAndTheCounts() async throws {
        let dir = "\(shortScratchRoot)/vssp-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = dir + "/host.log"
        let host = try TestHost(log: log, removing: dir, watchesItsPath: true, socket: dir + "/h.sock")
        func noted() -> String { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" }
        let other = dir + "/other.lock"
        #expect(FileManager.default.createFile(atPath: other, contents: nil))
        #expect(rename(other, host.lock) == 0)
        #expect(await eventually { noted().contains("locked the file there again") }, "\(noted())")
        let replaced = try #require(HostPathWatch.identity(atPath: host.lock))
        // A request on a connector whose process isn't named yet: refused and counted.
        let connector = try #require(host.server.openAppConnector(expecting: nil, requireNonDumpable: false, onDumpable: nil))
        defer {
            host.server.closeAppConnector(connector)
            Sys.close(connector)
        }
        var byte: UInt8 = 1
        #expect(send(connector, &byte, 1, 0) == 1)
        #expect(await eventually { host.server.queue.sync { host.server.tally.refusedAppConnections } == 1 })

        let probe = dir + "/probe.sh", go = dir + "/go"
        try Data("#!/bin/sh\nwhile [ ! -e '\(go)' ]; do sleep 0.05; done\nexit 1\n".utf8).write(to: URL(fileURLWithPath: probe))
        #expect(chmod(probe, 0o755) == 0)
        let app = try TestClient(host)
        let seq = app.send(.handover(executable: probe))
        let statePath = host.lock + ".handover"
        #expect(await eventually { (try? HostHandover.read(from: statePath)) != nil })
        let state = try HostHandover.read(from: statePath)
        #expect(FileManager.default.createFile(atPath: go, contents: nil))
        var info = stat()
        #expect(fstat(state.lockFD, &info) == 0)
        #expect(HostPathWatch.FileIdentity(info) == replaced, "the state carries the host's first lock, no longer at the path")
        #expect(state.tally == HostHandover.Tally(serverRestarts: 0, replacedPaths: [host.lock], refusedAppConnections: 1))
        #expect(await eventually { app.reply(to: seq) != nil })
        guard case .error? = app.reply(to: seq) else { Issue.record("\(String(describing: app.reply(to: seq)))"); return }
    }

    /// What `hostNotes` counted runs on across a handover: the counts the state carried are the new image's from its
    /// start, as `startedAt` is.
    @Test(.enabled(if: !Platform.CodeIdentity.isAvailable, "hostNotes is Linux's"))
    func theCountsRunOnAcrossAHandover() throws {
        let path = scratchSocketPath()
        let lock = path + ".lock"
        defer { unlink(path); unlink(lock) }
        let lockFD = open(lock, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        #expect(flock(lockFD, LOCK_EX | LOCK_NB) == 0)
        let listenFD = try UnixSocket.listen(path: path)
        var config = HostServer.Config(socketPath: path, lockPath: lock, shell: "/bin/sh", launcher: hostLauncher,
                                       baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], hostBuild: 43)
        config.idleExit = nil
        let server = HostServer(config: config)
        var state = HostHandover.State(fromBuild: 42, startedAt: Date(timeIntervalSinceNow: -60), lockFD: lockFD, listenFD: listenFD,
                                       secretFD: nil, sessions: [])
        state.tally = HostHandover.Tally(serverRestarts: 2, replacedPaths: ["/a.sock"], refusedAppConnections: 3)
        _ = try server.start(restoring: state)
        defer { server.stop(terminateSessions: true) }
        let notes = server.queue.sync { server.hostNotes(startedAt: state.startedAt) }
        #expect(notes.serverRestarts == 2 && notes.replacedPaths == ["/a.sock"] && notes.refusedAppConnections == 3)
        #expect(server.queue.sync { server.tallyForHandover } == state.tally)
    }

    /// The Mac: no server child, and no connector opened for one.
    @Test(.enabled(if: Platform.CodeIdentity.isAvailable, "the Mac has no server child; Linux's tests are above"))
    func theMacStartsNoServerChild() throws {
        let host = try TestHost(appConnector: false)
        let binary = try #require(Bundle.main.executablePath)
        let child = ServerChild.start(.init(image: binary, socketPath: host.socket, arguments: [], environment: [:]), server: host.server)
        #expect(child == nil)
        #expect(host.server.queue.sync { host.server.appConnectors.isEmpty && host.server.serverChild == nil })
    }
}
