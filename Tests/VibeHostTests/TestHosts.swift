import Darwin
import Foundation
import CryptoKit
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
    static func authorize(_ host: Process) throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
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
        try host.run()
        let pid = host.processIdentifier
        lock.withLock { started.insert(pid) }
        watch(pid, owner: owner)
    }

    /// Ends `host` (SIGTERM, then SIGKILL if it doesn't go) and waits for it.
    static func end(_ host: Process) {
        let pid = host.processIdentifier
        guard pid > 0 else { return }
        if host.isRunning {
            kill(pid, SIGTERM)
            // Its 10 s even in a cancelled test (past its time limit), where `eventually` would end at once: the host
            // ends as any other does, its log saying who signalled it, not cut off by a SIGKILL straight away.
            let deadline = Date().addingTimeInterval(10)
            while host.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if host.isRunning { kill(pid, SIGKILL) }
        }
        host.waitUntilExit()
        lock.withLock { _ = started.remove(pid) }
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
