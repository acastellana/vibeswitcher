import Darwin
import Foundation

/// Every `vibeswitcher-host` process a test starts, by pid. A host runs in a process group of its own (so a signal to
/// the test runner's group misses it), and with a live session it's never idle (its `--idle-exit` waits for no session
/// and no app), so a host the test doesn't end runs on. Each is ended: by the test (`end`, or `ScratchHostProcess`
/// going away, however the test ends), when the runner exits, and, should the runner die first (killed, crashed, or
/// stopped as hung), by a watchdog of its own.
enum TestHosts {
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
            if !eventually(timeout: 10, { !host.isRunning }) { kill(pid, SIGKILL) }
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
