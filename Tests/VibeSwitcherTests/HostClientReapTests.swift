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
        // Reaped here should the client not have: no zombie outlives the test.
        defer { kill(pid, SIGKILL); var status: Int32 = 0; _ = waitpid(pid, &status, 0) }

        // The exit event, while the host can't be reaped yet (still running here, as one still exiting is).
        client.hostExited(pid)
        #expect(reaped.isEmpty)
        // Then it ends: the client reaps it (its exit source still watching, or its look again).
        kill(pid, SIGKILL)
        #expect(await until { reaped == [pid] }, "the host that ended wasn't reaped")
    }
}
