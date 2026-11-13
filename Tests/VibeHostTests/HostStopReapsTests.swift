import Foundation
import Testing
import VibeCore
@testable import VibeHost

/// A host stopped with its sessions ended (`stop(terminateSessions: true)`, every in-process scratch host's teardown)
/// reaps their programs: its closed sessions no longer do, and a host that runs on (the test runner) kept each as a
/// zombie, 431 in one full suite's runner on 2026-11-01.
struct HostStopReapsTests {
    @Test(hostTestLimit) func stoppingAHostReapsItsSessionsPrograms() async throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let running = try await client.spawn(keepRunning)
        host.server.stop(terminateSessions: true)
        // Its program gets SIGHUP, SIGKILL 5 s on: gone from the process table, not left a zombie.
        #expect(await eventually(timeout: 60) { Self.state(of: running.childPID) == nil },
                "pid \(running.childPID) is \(Self.state(of: running.childPID) == .zombie ? "a zombie" : "still running")")
    }

    /// A session told to end and closed at once (as the host's stop does, and tests that start sessions themselves)
    /// reaps its program as it goes.
    @Test(hostTestLimit) func aSessionToldToEndAndClosedReapsItsProgram() async throws {
        let probe = SessionProbe()
        let request = SpawnRequest(cwd: scratchRoot.path, command: "echo up; \(keepRunning)", env: [:], cols: 80, rows: 24,
                                   keepShell: false, label: "T", agent: nil)
        let session = try probe.queue.sync {
            let session = try HostedSession.spawn(request, shell: "/bin/sh", launcher: hostLauncher, baseEnvironment: ["PATH": "/usr/bin:/bin"],
                                                  ringCapacity: 1 << 16, queue: probe.queue)
            probe.attach(session)
            return session
        }
        #expect(await eventually { probe.text.contains("up") })
        let pid = probe.queue.sync { session.info.childPID }
        probe.queue.sync { session.terminate(); session.close() }
        #expect(await eventually(timeout: 60) { Self.state(of: pid) == nil },
                "pid \(pid) is \(Self.state(of: pid) == .zombie ? "a zombie" : "still running")")
    }

    /// The process's state (running, a zombie…), nil once it's gone from the process table (reaped): the kernel's own
    /// record, zombies included.
    static func state(of pid: pid_t) -> Platform.Processes.State? {
        Platform.Processes.kernelRecord(pid)?.state
    }
}
