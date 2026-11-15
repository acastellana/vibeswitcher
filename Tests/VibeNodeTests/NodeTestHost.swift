import Foundation
import Testing
import VibeCore
@testable import VibeHost
import VibeNode

/// A scratch session host in the test process, for the engine's tests (the engine plan's E0), made as stage 2's Task
/// 5a makes `VibeHostTests`' `TestHost` (which lives in that target and can't be shared): the test process is its app,
/// through the app connector the host opens for it and this registers for its socket (`HostConnection.register`), so
/// every connection this process makes to that socket (`HostCall`'s, `dialer`'s, `vault`'s) is the app's. Linux only:
/// the Mac has no connector (`NodeTraits.linuxOnly`).
///
/// One root per test: its own scratch folder, with its own root (`<folder>/home/.vibeswitcher`, which no engine or
/// helper of this process takes from `VibePaths`) and its sessions' own `HOME` (`<folder>/home`), so tests that run at
/// once never share a steer inbox, a state folder or a socket. Its sessions get that `HOME` and a `PATH` of
/// `/usr/bin:/bin`, with no `claude` on it, as the node's unit has none (EN-D13). Its vault is a `LeadVault.Book` of
/// its own, whose config home is that `HOME`. Stopped, its sessions ended, and its folder removed when it goes (or `stop()`).
final class NodeTestHost: @unchecked Sendable {
    /// The scratch folder everything of this host is in.
    let folder: URL
    /// The sessions' `HOME`.
    let home: URL
    /// The host's root: what `VibePaths.root` is in its sessions (`.vibeswitcher` in their `HOME`). The steer inbox,
    /// the state folder and the vault's launch files go here.
    let root: URL
    /// The host's socket, in a short folder of its own (a socket's path is limited to 108 bytes).
    let socket: String
    let server: HostServer
    /// The host's lead vault.
    let book: LeadVault.Book
    /// The connector the host opened for this process, registered for `socket`.
    private(set) var appConnector: Int32?
    private let socketFolder: URL
    private var stopped = false
    private let lock = NSLock()

    /// What every session gets besides what the host adds (`HostedSession.environment`).
    var baseEnvironment: [String: String] { ["HOME": home.path, "PATH": "/usr/bin:/bin"] }

    init(_ scratch: Scratch) throws {
        folder = scratch.url("node-host")
        home = folder.appendingPathComponent("home", isDirectory: true)
        root = home.appendingPathComponent(".vibeswitcher", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        socketFolder = try scratch.shortFolder("vsn")
        socket = socketFolder.appendingPathComponent("h.sock").path
        book = LeadVault.Book()
        // Its agents' config (a config check's hashes) and its seal copies are in its sessions' HOME, as on a node,
        // where the two are one folder; never this process's home, which every test in it shares.
        book.configHome = home.path
        var config = HostServer.Config(socketPath: socket, lockPath: socket + ".lock", shell: "/bin/sh", launcher: hostLauncher.path,
                                       baseEnvironment: ["HOME": home.path, "PATH": "/usr/bin:/bin"], hostBuild: 42)
        config.idleExit = nil
        config.vault = book
        config.appExecutable = HostServer.executable(of: getpid())
        config.ringCapacity = 1 << 20
        config.logPath = folder.appendingPathComponent("host.log").path
        server = HostServer(config: config)
        do { try server.start() } catch {
            try? FileManager.default.removeItem(at: socketFolder)
            throw error
        }
        // The Mac opens none (`openAppConnector` is nil there).
        if let connector = server.openAppConnector(expecting: Platform.Processes.token(getpid()), requireNonDumpable: false, onDumpable: nil) {
            HostConnection.register(connector: connector, for: socket)
            appConnector = connector
        }
    }

    deinit { stop() }

    /// Ends its sessions, stops it, ends the connector's registration and removes its socket's folder. Once.
    func stop() {
        let first = lock.withLock { () -> Bool in
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        if let appConnector {
            if HostConnection.connector(for: socket) == appConnector { HostConnection.unregister(path: socket) }
            server.closeAppConnector(appConnector)
            Sys.close(appConnector)
        }
        server.stop(terminateSessions: true)
        try? FileManager.default.removeItem(at: socketFolder)
    }

    /// How the engine reaches this host (`HostLink`'s dialer): a `HostConnection` to its socket, through the registry,
    /// so the app's.
    var dialer: HostDialer { Dialer(socket: socket) }

    private struct Dialer: HostDialer {
        let socket: String
        func connect(queue: DispatchQueue) throws -> HostConnection {
            try HostConnection(path: socket, queue: queue, appKey: nil)
        }
    }

    /// The host's lead vault as the engine asks it: `HostCall.vault` on this host's socket, through the connector.
    var vault: LeadVault {
        LeadVault(folder: root.appendingPathComponent("lead", isDirectory: true)) { [socket] in try HostCall.vault($0, socket: socket) }
    }

    /// Starts `command` (a bash line) in a new session, as the app does, and returns it.
    func spawn(_ command: String, cwd: String? = nil, label: String = "Test", agent: String? = nil, cols: Int = 100,
               rows: Int = 40) async throws -> HostSession {
        let request = SpawnRequest(cwd: cwd ?? home.path, command: command, env: [:], cols: cols, rows: rows, keepShell: false,
                                   label: label, agent: agent)
        let reply = try await offPool { [socket] in try HostCall.request(.spawn(request), socket: socket, appKey: nil, timeout: 60) }
        guard case .spawned(let session) = reply else {
            throw HostCall.Failure(description: "the scratch host didn't start the session: \(reply)")
        }
        return session
    }

    /// The session's screen as the host draws it now (one round trip; nil when it didn't answer).
    func screen(_ id: UUID) -> String? {
        HostCall.styledScreen(id, socket: socket, appKey: nil)?.text
    }

    /// The host's sessions now, from its welcome.
    func sessions() throws -> [HostSession] {
        try HostCall.sessions(socket: socket, appKey: nil)
    }
}

/// The built `vibeswitcher-host`, which starts each session's program (`--pty-exec`), beside this test bundle.
let hostLauncher = builtProducts.appendingPathComponent("vibeswitcher-host")

/// A scratch git repository at `folder` with one commit, made with the system's git and no global or system config.
func scratchRepository(_ folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "scratch\n".write(to: folder.appendingPathComponent("README"), atomically: true, encoding: .utf8)
    let environment = ["HOME": folder.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                       "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                       "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"]
    for arguments in [["init", "-q", "-b", "main"], ["add", "README"], ["commit", "-q", "-m", "first"]] {
        let ran = try await run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", folder.path] + arguments, environment: environment)
        guard ran.status == 0 else { throw HostCall.Failure(description: "git \(arguments.joined(separator: " ")): \(ran.errors)") }
    }
}
