import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// No host a test starts outlives it (see `TestHosts`): on 2026-10-18 a handover scene's host, its runner gone, ran on
/// for hours with the scene's sessions, never idle.
@Suite(.serialized) struct TestHostsTests {
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
            pid = host.pid
            dir = host.dir
            let (client, _, _, _, _, _, _) = try TestClient.welcomed(host.socket, appKey: host.appKey)
            session = try client.spawn(keepRunning).childPID
            #expect(exists(pid) && TestHosts.running.contains(pid))
            throw Failure()
        }
        #expect(pid > 0)
        #expect(!exists(pid) && !TestHosts.running.contains(pid))
        #expect(!FileManager.default.fileExists(atPath: dir))
        // Its session lost its terminal with it.
        #expect(eventually(timeout: 30) { !exists(session) })
    }

    /// A handover scene whose test fails before it ends it: the host goes.
    @Test func aFailingSceneIsEnded() throws {
        var pid: pid_t = 0
        withKnownIssue("the body fails on purpose") {
            let scene = try HostHandoverTests().scene()
            pid = scene.host.pid
            if scene.background > 0 { kill(scene.background, SIGKILL) }
            throw Failure()
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
        try TestHosts.run(host, owner: runner.processIdentifier)
        #expect(eventually { FileManager.default.fileExists(atPath: socket) })
        let client = try TestClient(socket: socket)
        let session = try client.spawn(keepRunning)
        // Never idle while its session runs: nothing but the watchdog would end it.
        Thread.sleep(forTimeInterval: 2)
        #expect(host.isRunning)
        kill(runner.processIdentifier, SIGKILL)
        runner.waitUntilExit()
        #expect(eventually(timeout: 10) { !host.isRunning })
        #expect(host.terminationReason == .uncaughtSignal && host.terminationStatus == SIGKILL)
        #expect(eventually(timeout: 30) { !exists(session.childPID) })
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
        try TestHosts.run(host)
        var connected: TestClient?
        #expect(eventually { connected = try? TestClient(socket: socket); return connected != nil })
        let client = try #require(connected)
        let seq = client.send(.hello(protocolVersion: HostProtocol.version, app: "test"))
        #expect(eventually { client.reply(to: seq) != nil })
        // A client counts: well past the idle time, still running.
        Thread.sleep(forTimeInterval: 4)
        #expect(host.isRunning)
        client.close()
        let gone = Date()
        #expect(eventually(timeout: 10) { !host.isRunning })
        #expect(Date().timeIntervalSince(gone) < 6)
        #expect(host.terminationReason == .exit && host.terminationStatus == 0)
        let lines = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        #expect(lines.contains("host: idle 2 s with no session and no app, exiting"))
    }
}
