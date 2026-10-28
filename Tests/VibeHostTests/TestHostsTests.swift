import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// No host a test starts outlives it (see `TestHosts`): on 2026-10-18 a handover scene's host, its runner gone, ran on
/// for hours with the scene's sessions, never idle.
@Suite(.serialized, hostTestLimit) struct TestHostsTests {
    struct Failure: Error {}

    /// A host on a scratch socket, lock and home, not yet started.
    func host(idleExit: Int, log: String? = nil) -> (Process, socket: String, home: URL) {
        let socket = scratchSocketPath()
        let home = scratchRoot.appendingPathComponent("vsh-home-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let host = Process()
        host.executableURL = URL(fileURLWithPath: hostLauncher)
        host.arguments = ["--socket", socket, "--lock", socket + ".lock", "--idle-exit", String(idleExit)] + (log.map { ["--log", $0] } ?? [])
        host.environment = ["CFFIXED_USER_HOME": home.path, "HOME": home.path, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
        // Not the runner's: a host left running would hold its output open, and `swift test` would wait on it.
        host.standardOutput = FileHandle.nullDevice
        host.standardError = FileHandle.nullDevice
        return (host, socket, home)
    }

    func remove(_ socket: String, _ home: URL) {
        unlink(socket)
        unlink(socket + ".lock")
        try? FileManager.default.removeItem(at: home)
    }

    /// Whether `pid` is a process at all (a zombie counts: not yet reaped).
    func exists(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// A test that fails with its host still running and live sessions on it, never stopping it: the host goes.
    @Test func aFailingTestsHostIsEnded() throws {
        var pid: pid_t = 0, dir = "", session: pid_t = 0
        withKnownIssue("the body fails on purpose, its host still running") {
            let host = try ScratchHostProcess()
            // Kept until the body throws (Swift may otherwise let it go after its last use).
            try withExtendedLifetime(host) {
                pid = host.pid
                dir = host.dir
                let (client, _, _, _, _, _, _) = try TestClient.welcomed(host.socket, appKey: host.appKey)
                session = try client.spawn(keepRunning).childPID
                // Running on its terminal (a session the host leaves before it has one never sees it hang up).
                #expect(eventually { (ProcessTable.info(pid: session)?.comm ?? "") == "sleep" })
                #expect(exists(pid) && TestHosts.running.contains(pid))
                throw Failure()
            }
        }
        #expect(pid > 0)
        #expect(!exists(pid) && !TestHosts.running.contains(pid))
        #expect(!FileManager.default.fileExists(atPath: dir))
        // Its session lost its terminal with it.
        #expect(eventually(timeout: 30) { !exists(session) })
    }

    /// A test past its time limit (cancelled) still asks its host to end before it kills it: the host goes on SIGTERM,
    /// not on a SIGKILL sent at once.
    @Test func aCancelledTestsHostIsAskedToEndFirst() async throws {
        let (host, socket, home) = host(idleExit: 600)
        defer { remove(socket, home) }
        try TestHosts.run(host)
        #expect(eventually { FileManager.default.fileExists(atPath: socket) })
        // Ended from a task that is cancelled already, as a test past its limit is.
        let ending = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            TestHosts.end(host)
        }
        ending.cancel()
        await ending.value
        #expect(host.terminationReason == .uncaughtSignal && host.terminationStatus == SIGTERM,
                "ended by \(host.terminationReason == .uncaughtSignal ? "signal" : "exit") \(host.terminationStatus)")
    }

    /// A handover scene whose test fails before it ends it: the host goes.
    @Test func aFailingSceneIsEnded() throws {
        var pid: pid_t = 0
        withKnownIssue("the body fails on purpose") {
            let scene = try HostHandoverTests().scene()
            try withExtendedLifetime(scene.host) {
                pid = scene.host.pid
                if scene.background > 0 { kill(scene.background, SIGKILL) }
                #expect(scene.host.process.isRunning)
                throw Failure()
            }
        }
        #expect(pid > 0 && !exists(pid))
    }

    /// The runner dies (killed, crashed, stopped as hung): its hosts' watchdogs end them, sessions and all.
    @Test func aHostWhoseRunnerDiedIsEnded() throws {
        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        runner.arguments = ["600"]
        try runner.run()
        let (host, socket, home) = host(idleExit: 600)
        defer {
            if runner.isRunning { kill(runner.processIdentifier, SIGKILL); runner.waitUntilExit() }
            TestHosts.end(host)
            remove(socket, home)
        }
        let key = try TestHosts.authorize(host)
        try TestHosts.run(host, owner: runner.processIdentifier)
        #expect(eventually { FileManager.default.fileExists(atPath: socket) })
        let client = try TestClient(socket: socket, appKey: key)
        let session = try client.spawn(keepRunning)
        // Its program running: one still starting (a fresh launcher copy waits on its first exec on a busy Mac) has no
        // terminal yet, so the hangup when its host dies never reaches it.
        #expect(eventually { (ProcessTable.info(pid: session.childPID)?.comm ?? "") == "sleep" })
        // Never idle while its session runs: nothing but the watchdog would end it.
        Thread.sleep(forTimeInterval: 2)
        #expect(host.isRunning)
        kill(runner.processIdentifier, SIGKILL)
        runner.waitUntilExit()
        try #require(eventually(timeout: 10) { !host.isRunning })
        #expect(host.terminationReason == .uncaughtSignal && host.terminationStatus == SIGKILL)
        #expect(eventually(timeout: 30) { !exists(session.childPID) })
    }

    /// Waits for `pid`'s exit (any process, not only a child: a kqueue watch), up to `timeout`. True once it's gone.
    func waitForExit(of pid: pid_t, timeout: TimeInterval) -> Bool {
        let gone = DispatchSemaphore(value: 0)
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        watch.setEventHandler { gone.signal() }
        watch.resume()
        defer { watch.cancel() }
        // Gone before the watch began: no exit comes.
        if kill(pid, 0) != 0, errno == ESRCH { return true }
        return gone.wait(timeout: .now() + timeout) == .success
    }

    /// `--exit-with PID` (a bench's host, audit P2 #3 of 2026-10-22): its owner killed outright, the host ends every
    /// session and exits by itself, well before any watchdog.
    @Test func aHostWhoseOwnerIsKilledEndsItsSessionsAndExits() throws {
        let bench = Process()
        bench.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bench.arguments = ["600"]
        try bench.run()
        let log = scratchRoot.appendingPathComponent("vsh-owner-\(UUID().uuidString.prefix(8)).log").path
        let (host, socket, home) = host(idleExit: 600, log: log)
        host.arguments! += ["--exit-with", String(bench.processIdentifier)]
        defer {
            if bench.isRunning { kill(bench.processIdentifier, SIGKILL); bench.waitUntilExit() }
            TestHosts.end(host)
            remove(socket, home)
            unlink(log)
        }
        let hostEnded = DispatchSemaphore(value: 0)
        host.terminationHandler = { _ in hostEnded.signal() }
        let key = try TestHosts.authorize(host)
        try TestHosts.run(host)
        var connected: TestClient?
        #expect(eventually { connected = try? TestClient(socket: socket, appKey: key); return connected != nil })
        let client = try #require(connected)
        let sessions = try (0..<2).map { _ in try client.spawn(keepRunning).childPID }
        #expect(eventually { sessions.allSatisfy { (ProcessTable.info(pid: $0)?.comm ?? "") == "sleep" } })
        #expect(host.isRunning)
        kill(bench.processIdentifier, SIGKILL)
        bench.waitUntilExit()
        try #require(hostEnded.wait(timeout: .now() + 10) == .success, "the host outlived its owner")
        #expect(host.terminationReason == .exit && host.terminationStatus == 0)
        for session in sessions { #expect(waitForExit(of: session, timeout: 10), "session pid \(session) outlived the host") }
        let lines = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        #expect(lines.contains("host: owner pid \(bench.processIdentifier) is gone, ending 2 sessions and exiting"))
        #expect(!FileManager.default.fileExists(atPath: socket))
    }

    /// An owner already gone when the host starts (the bench died while it launched): the host doesn't stay.
    @Test func aHostWhoseOwnerIsAlreadyGoneExits() throws {
        let bench = Process()
        bench.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try bench.run()
        bench.waitUntilExit()
        let (host, socket, home) = host(idleExit: 600)
        host.arguments! += ["--exit-with", String(bench.processIdentifier)]
        defer {
            TestHosts.end(host)
            remove(socket, home)
        }
        let hostEnded = DispatchSemaphore(value: 0)
        host.terminationHandler = { _ in hostEnded.signal() }
        try TestHosts.run(host)
        try #require(hostEnded.wait(timeout: .now() + 10) == .success, "the host outlived its owner")
        #expect(host.terminationReason == .exit && host.terminationStatus == 0)
    }

    /// `--idle-exit`: a host whose last client went away, with no session, exits once it's been idle that long, and
    /// not while the client is there.
    @Test func aHostWithNoClientLeftExitsWhenIdle() throws {
        let log = scratchRoot.appendingPathComponent("vsh-idle-\(UUID().uuidString.prefix(8)).log").path
        let (host, socket, home) = host(idleExit: 2, log: log)
        defer {
            TestHosts.end(host)
            remove(socket, home)
            unlink(log)
        }
        let key = try TestHosts.authorize(host)
        try TestHosts.run(host)
        var connected: TestClient?
        #expect(eventually { connected = try? TestClient(socket: socket, appKey: key); return connected != nil })
        let client = try #require(connected)
        let seq = client.send(.hello(protocolVersion: HostProtocol.version, app: "test"))
        #expect(eventually { client.reply(to: seq) != nil })
        // A client counts: well past the idle time, still running.
        Thread.sleep(forTimeInterval: 4)
        #expect(host.isRunning)
        client.close()
        let gone = Date()
        try #require(eventually(timeout: 10) { !host.isRunning })
        #expect(Date().timeIntervalSince(gone) < 6)
        #expect(host.terminationReason == .exit && host.terminationStatus == 0)
        let lines = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        #expect(lines.contains("host: idle 2 s with no session and no app, exiting"))
    }
}
