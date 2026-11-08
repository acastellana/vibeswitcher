import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// A host the client started is reaped when it ends, even when its exit event comes before it can be reaped: the
/// kernel posts the event a moment before the process is a zombie, and under load `waitpid` then finds it still
/// exiting. The event is posted once, so the client looks again rather than letting go of it (a zombie host for the
/// app's life otherwise). The host here is `sleep`, so nothing listens and nothing else reaps it (`stillRuns` looks
/// only while a start waits for its host).
@MainActor
@Suite(hostTestLimit) struct HostClientReapTests {
    private let scratch = Scratch()

    /// A client host's pid file naming a pid that is now another test's child (the host ended long ago, and a full
    /// run's pids wrap past 99,999): ending "the host" leaves that child alone, unkilled and unreaped, so its own
    /// `Process` still sees it end. Audit F1 of 2026-11-06: a SIGKILL and a waitpid on a stale pid took LongHistoryTests'
    /// scratch host, whose `waitUntilExit` then held the whole run at 0 % CPU until vs-heavy's timeout.
    @Test func endingAHostByAStalePidLeavesTheProcessNowUnderItAlone() async throws {
        let dir = try scratch.shortFolder("vshp")
        let pidFile = dir + "/host.pid"
        // The pid file first, as the host wrote it; then the pid's new process, another test's, started after it.
        FileManager.default.createFile(atPath: pidFile, contents: Data("1\n".utf8))
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["600"]
        try other.run()
        defer { if other.isRunning { kill(other.processIdentifier, SIGKILL) } }
        try Data("\(other.processIdentifier)\n".utf8).write(to: URL(fileURLWithPath: pidFile))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: pidFile)
        endClientHost(other.processIdentifier, pidFile: pidFile, folder: dir)
        #expect(other.isRunning, "the stale pid's new process was ended")
        // Still its own Process's to see end.
        other.terminate()
        #expect(await exited(other, within: 30), "its Process never saw it end: reaped by someone else")
    }

    @Test func aHostWhoseExitEventComesBeforeItCanBeReapedIsStillReaped() async throws {
        let dir = try scratch.shortFolder("vshr")
        // The host's output goes to the run's (scratch) ~/.vibeswitcher/host.log, as the app's does.
        try FileManager.default.createDirectory(at: VibePaths.hostLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        let client = HostClient(socketPath: dir + "/h.sock", bundledBuild: { 0 }, note: { _ in })
        client.hostPath = "/bin/sleep"
        client.hostArguments = ["3600"]
        var reaped: [pid_t] = []
        client.onHostReaped = { reaped.append($0) }
        let pid = try client.startHost()
        // Reaped here should the client not have: no zombie outlives the test. Once the client reaped it, its pid may be
        // another test's child (pids wrap in a full run): left alone then.
        defer { if !reaped.contains(pid) { kill(pid, SIGKILL); var status: Int32 = 0; _ = waitpid(pid, &status, 0) } }

        // The exit event, while the host can't be reaped yet (still running here, as one still exiting is).
        client.hostExited(pid)
        #expect(reaped.isEmpty)
        // Then it ends: the client reaps it (its exit source still watching, or its look again).
        kill(pid, SIGKILL)
        #expect(await until { reaped == [pid] }, "the host that ended wasn't reaped")
    }
}
