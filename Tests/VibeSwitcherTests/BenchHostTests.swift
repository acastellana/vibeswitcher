import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// A bench's private session host ends with the bench, however the bench ends (audit P2 #3 of 2026-10-22: four hosts
/// of killed benches ran for 35 h with ~200 processes and their title loops). The benches start theirs with
/// `HostClient.endsWithThisProcess`; here the app's `--idle-bench --power` (no window), killed outright once its host
/// runs its sessions.
struct BenchHostTests {
    private let scratch = Scratch()

    /// Waits for `pid`'s exit (any process: a kqueue watch), up to `timeout`. True once it's gone.
    static func waitForExit(of pid: pid_t, timeout: TimeInterval) -> Bool {
        let gone = DispatchSemaphore(value: 0)
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        watch.setEventHandler { gone.signal() }
        watch.resume()
        defer { watch.cancel() }
        // Gone before the watch began: no exit comes.
        if kill(pid, 0) != 0, errno == ESRCH { return true }
        return gone.wait(timeout: .now() + timeout) == .success
    }

    @Test func aKilledBenchsHostAndSessionsAreGoneWithin10Seconds() throws {
        let app = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("VibeSwitcher")
        try #require(FileManager.default.isExecutableFile(atPath: app.path))
        let home = URL(fileURLWithPath: try scratch.shortFolder("vsbh"))
        let bench = Process()
        bench.executableURL = app
        bench.arguments = ["--idle-bench", "600", "--power"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["VIBESWITCHER_HOME"] = nil  // the run's own (scripts/test.sh) would come before this home
        bench.environment = environment
        // Its shells are running once it says how long its phases are.
        let output = Pipe()
        let ready = DispatchSemaphore(value: 0)
        let said = NSLock()
        var text = ""
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let now = said.withLock { text += String(decoding: data, as: UTF8.self); return text }
            if now.contains("power bench: ") { ready.signal() }
        }
        bench.standardOutput = output
        bench.standardError = FileHandle.nullDevice
        var host: pid_t = 0
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if bench.isRunning { kill(bench.processIdentifier, SIGKILL); bench.waitUntilExit() }
            // Only on a failure: this test's own bench's host.
            if host > 0, kill(host, 0) == 0 { kill(host, SIGKILL) }
        }
        try bench.run()
        try #require(ready.wait(timeout: .now() + hangGuard) == .success, "the bench never started its shells: \(said.withLock { text })")
        let table = ProcessTable.snapshot()
        host = try #require(table.values.first { $0.ppid == bench.processIdentifier && $0.comm.hasPrefix("vibeswitcher-hos") }?.pid,
                            "no host under the bench")
        let sessions = table.values.filter { $0.ppid == host }.map(\.pid)
        #expect(sessions.count >= 3, "the host's children: \(sessions)")
        kill(bench.processIdentifier, SIGKILL)
        bench.waitUntilExit()
        let killed = Date()
        #expect(Self.waitForExit(of: host, timeout: 10), "the host outlived its bench")
        for session in sessions {
            #expect(Self.waitForExit(of: session, timeout: max(0, 10 - Date().timeIntervalSince(killed))), "pid \(session) outlived its bench")
        }
    }
}

private final class Anchor {}
