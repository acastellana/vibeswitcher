import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A scratch host started as its own process with `--server` (this test binary by default, whose helper mode
/// `ServerChildHelper` stands in for the server), on its own home, socket and lock. The helper's actions file and its
/// results sit beside the socket; the host's stderr and stdout go to `output`, its session log to `sessionLog`.
final class ServerChildHost {
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
    /// `idleExit`: the host's `--idle-exit`. `extra`: more of the host's arguments.
    init(actions: [String] = [], copyImage: Bool = false, idleExit: String = "600", extra: [String] = []) async throws {
        // Short: a socket's path has a 104-byte limit.
        dir = "\(shortScratchRoot)/vssc-\(UUID().uuidString.prefix(8))"
        home = dir + "/home"
        socket = dir + "/h.sock"
        lock = dir + "/h.lock"
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
        process.arguments = ["--socket", socket, "--lock", lock, "--idle-exit", idleExit, "--log", sessionLog, "--server", image] + extra
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
