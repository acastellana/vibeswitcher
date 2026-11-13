import Foundation
import Testing
import VibeCore
@testable import VibeHost

/// Every `vibeswitcher-host` process a test starts, by pid. A host runs in a process group of its own (so a signal to
/// the test runner's group misses it), and with a live session it's never idle (its `--idle-exit` waits for no session
/// and no app), so a host the test doesn't end runs on. Each is ended: by the test (`end`, or `ScratchHostProcess`
/// going away, however the test ends), when the runner exits, and, should the runner die first (killed, crashed, or
/// stopped as hung), by a watchdog of its own.
enum TestHosts {
    /// Give a process-based scratch host the same identity/proof setup as the in-process TestHost.
    /// The key travels on stdin, not argv, disk or a shared global used by other tests.
    /// On Linux the test process is the app through a connector instead (`connectAsApp`): the key is then the host's
    /// to ignore, and a client given it goes through the connector (`TestClient`).
    static func authorize(_ host: Process) throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        if try connectAsApp(host) { return key }
        guard let app = HostServer.executable(of: getpid()), let executable = host.executableURL,
              let home = host.environment?["HOME"] else { throw CancellationError() }
        // Use the real bundle layout in private fixture storage, rather than a CLI identity override.
        let folder = URL(fileURLWithPath: home).appendingPathComponent("host-code-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let launcher = folder.appendingPathComponent("vibeswitcher-host")
        try FileManager.default.copyItem(at: executable, to: launcher)
        try FileManager.default.copyItem(atPath: app, toPath: folder.appendingPathComponent("VibeSwitcher").path)
        host.executableURL = launcher
        host.arguments = (host.arguments ?? []) + [AppProof.hostStdinFlag]
        let input = Pipe()
        try input.fileHandleForWriting.write(contentsOf: key.data)
        try input.fileHandleForWriting.close()
        host.standardInput = input
        return key
    }

    /// The app's stand-in on Linux (the stage 2 plan's Task 5a): Linux has no code identity, so a host's app is the
    /// connections it makes through an app connector. `host` (not yet started, its `--socket` and its own `--lock`
    /// among its arguments, as every host a test starts has: `KeychainLintTests`) is
    /// given one end of a `SOCK_SEQPACKET` pair as its stdin, with `--test-app-pid <this process>
    /// --test-app-connector 0` (see `TestAppPrincipal`), and the other end is registered for its socket
    /// (`HostConnection.register(connector:for:)`): a `HostConnection` to that socket from this process, `TestClient`'s
    /// and `HostCall`'s, is then the app's. Its end here is closed once the host has started (`run`), and the
    /// registration ended with the host (`end`). True when it did so; false on the Mac, where nothing is done (the app
    /// proves itself there: `authorize`).
    @discardableResult
    static func connectAsApp(_ host: Process) throws -> Bool {
        guard !Platform.CodeIdentity.isAvailable else { return false }
        let arguments = host.arguments ?? []
        guard arguments.contains("--lock"), let index = arguments.firstIndex(of: "--socket"), arguments.indices.contains(index + 1) else {
            throw CancellationError()
        }
        guard let (hostEnd, testEnd) = Platform.Sockets.pair(type: Platform.Sockets.seqpacket) else { throw CancellationError() }
        // Its senders passed from its making, as the host's own connectors' are (`openAppConnector`): a request this
        // process sends before the host has adopted its end would otherwise come with no sender, and be refused.
        Platform.Sockets.enableCredentials(hostEnd)
        // Foundation's `Process` hands a child nothing from 3 up: the host's stdin carries the connector.
        host.standardInput = FileHandle(fileDescriptor: hostEnd, closeOnDealloc: false)
        host.arguments = arguments + [TestAppPrincipal.pidFlag, String(getpid()), TestAppPrincipal.connectorFlag, "0"]
        let socket = arguments[index + 1]
        lock.withLock { connectors[ObjectIdentifier(host)] = Connector(hostEnd: hostEnd, testEnd: testEnd, socket: socket) }
        HostConnection.register(connector: testEnd, for: socket)
        return true
    }

    /// A stand-in's two ends (`connectAsApp`): the host's, -1 once the host has started; this process's; and the
    /// socket it is registered for.
    private struct Connector {
        var hostEnd: Int32
        let testEnd: Int32
        let socket: String
    }
    private static var connectors: [ObjectIdentifier: Connector] = [:]

    private static let lock = NSLock()
    private static var started: Set<pid_t> = []
    private static var watchdogs: [Process] = []
    private static let endedAtExit: Void = { atexit { TestHosts.killAll() } }()

    /// The hosts started and not yet ended.
    static var running: Set<pid_t> { lock.withLock { started } }

    /// Starts `host` and records it. `owner`: the process whose death ends it (the test runner; a test of the watchdog
    /// gives a stand-in).
    static func run(_ host: Process, owner: pid_t = getpid()) throws {
        _ = endedAtExit
        defer {
            // The host's end of a stand-in connector is the host's alone once it has started (or won't start): held
            // here too, a connect to a host gone would wait out its patience instead of failing at once.
            lock.withLock {
                if let hostEnd = connectors[ObjectIdentifier(host)]?.hostEnd, hostEnd >= 0 {
                    Sys.close(hostEnd)
                    connectors[ObjectIdentifier(host)]?.hostEnd = -1
                }
            }
        }
        try host.run()
        let pid = host.processIdentifier
        lock.withLock { started.insert(pid) }
        watch(pid, owner: owner)
    }

    /// Ends `host` (SIGTERM, then SIGKILL if it doesn't go) and waits for it.
    static func end(_ host: Process) {
        defer { disconnect(host) }
        let pid = host.processIdentifier
        guard pid > 0 else { return }
        if host.isRunning {
            kill(pid, SIGTERM)
            // Its 10 s even in a cancelled test (past its time limit), where `eventually` would end at once: the host
            // ends as any other does, its log saying who signalled it, not cut off by a SIGKILL straight away.
            let deadline = MacTime.real.awake() + 10
            while host.isRunning, MacTime.real.awake() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if host.isRunning { kill(pid, SIGKILL) }
        }
        // Bounded, not `waitUntilExit`: a child something else reaped (a waitpid on a stale, reused pid) is never seen
        // to end by its `Process`, and waiting on it held a full run at 0 % CPU until vs-heavy's timeout (2026-11-06).
        // Gone from the process table (no zombie left) for 2 s while its `Process` still says running: reaped elsewhere.
        let killed = MacTime.real.awake() + hangGuard
        var goneSince: TimeInterval?
        while host.isRunning, MacTime.real.awake() < killed {
            if kill(pid, 0) != 0, errno == ESRCH {
                if let since = goneSince { if MacTime.real.awake() - since > 2 { break } } else { goneSince = MacTime.real.awake() }
            } else {
                goneSince = nil
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if host.isRunning {
            Issue.record(Comment(rawValue: "scratch host pid \(pid) never seen to end" + (goneSince != nil ? ": gone, reaped by someone else" : "")))
        }
        lock.withLock { _ = started.remove(pid) }
    }

    /// The stand-in connector of `host` closed here and no longer registered for its socket (unless another host's
    /// is registered for it by now).
    private static func disconnect(_ host: Process) {
        guard let connector = lock.withLock({ connectors.removeValue(forKey: ObjectIdentifier(host)) }) else { return }
        if HostConnection.connector(for: connector.socket) == connector.testEnd { HostConnection.unregister(path: connector.socket) }
        Sys.close(connector.testEnd)
        if connector.hostEnd >= 0 { Sys.close(connector.hostEnd) }
    }

    /// At the runner's exit: whatever a test left running.
    private static func killAll() {
        for pid in running { kill(pid, SIGKILL) }
    }

    /// A shell that ends the host once `owner` is gone, and goes itself once the host is.
    private static func watch(_ host: pid_t, owner: pid_t) {
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", "while kill -0 \(host) 2>/dev/null; do kill -0 \(owner) 2>/dev/null || exec kill -KILL \(host); sleep 1; done",
                              "test-host-watchdog"]
        watchdog.standardInput = FileHandle.nullDevice
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        guard (try? watchdog.run()) != nil else { return }
        lock.withLock { watchdogs.append(watchdog) }
    }
}
