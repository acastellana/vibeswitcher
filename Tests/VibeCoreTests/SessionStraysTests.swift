import Foundation
import Testing
@testable import VibeCore

/// Only processes these tests start (`/bin/sleep`), each told apart by a session id made here or by a scratch folder.
struct SessionStraysTests {
    let temp = Scratch()

    /// A `sleep` this test started, in `cwd`, with `environment` and nothing else (not this test's own
    /// `VIBESWITCHER_SESSION`, if it runs in a session).
    func sleeper(in cwd: String = NSTemporaryDirectory(), environment: [String: String] = [:]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["300"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment.merging(["PATH": "/usr/bin:/bin"]) { mine, _ in mine }
        try process.run()
        return process
    }

    func folder(_ name: String) throws -> String {
        let url = temp.url(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test func procargsGiveTheArgumentsAndTheEnvironmentNotTheKernelsOwn() {
        var buffer = withUnsafeBytes(of: Int32(2)) { Array($0) }
        buffer += Array("/bin/sleep\0\0\0sleep\0300\0A=1\0VIBESWITCHER_SESSION=x\0\0\0ptr_munge=\0".utf8)
        let parsed = ProcessTable.parse(procargs: buffer)
        #expect(parsed.arguments == ["sleep", "300"])
        #expect(parsed.environment == ["A=1", "VIBESWITCHER_SESSION=x"])
        #expect(ProcessTable.parse(procargs: [1, 0]).arguments.isEmpty)
    }

    @Test func insideMeansTheFolderOrUnderIt() {
        #expect(SessionStrays.isInside("/a/wt", folder: "/a/wt"))
        #expect(SessionStrays.isInside("/a/wt/src", folder: "/a/wt/"))
        #expect(!SessionStrays.isInside("/a/wt-2", folder: "/a/wt"))
        #expect(!SessionStrays.isInside("/a", folder: "/a/wt"))
    }

    /// Apple's sleep hides its environment: it's the session's only when the session started it (it's among `started`),
    /// and still is that process. (Environments that can be read: `EndingASessionTests`.)
    @Test func aProcessWhoseEnvironmentIsHiddenIsTheSessionsOnlyWhenItStartedIt() throws {
        let id = UUID()
        let started = try sleeper(environment: ["VIBESWITCHER_SESSION": id.uuidString])
        let unrelated = try sleeper(environment: ["VIBESWITCHER_SESSION": id.uuidString])
        defer { [started, unrelated].forEach { $0.terminate() } }
        let found = try #require(SessionStrays.descendants(of: getpid()).first { $0.pid == started.processIdentifier })
        #expect(ProcessTable.environment(pid: started.processIdentifier) == [])
        #expect(SessionStrays.carrying(session: id).isEmpty)
        #expect(SessionStrays.of(session: id, started: [found]) == [found])
        // A pid taken by another process since.
        #expect(SessionStrays.of(session: id, started: [SessionStrays.Found(pid: found.pid, group: found.group, start: found.start + 1)]).isEmpty)
        #expect(SessionStrays.carrying(session: id, user: geteuid() + 1).isEmpty)
    }

    /// A worktree's removal ends what runs in it, and only that.
    @Test func endingInsideAFolderSparesWhatRunsElsewhere() throws {
        let worktree = try folder("strays-wt"), elsewhere = try folder("strays-wt-2")
        let inside = try sleeper(in: worktree + "/")
        let outside = try sleeper(in: elsewhere)
        defer { outside.terminate() }
        #expect(eventually { SessionStrays.inside(folder: worktree).map(\.pid) == [inside.processIdentifier] })
        let ended = SessionStrays.endInside(folder: worktree)
        #expect(ended.map(\.pid) == [inside.processIdentifier])
        #expect(eventually { !inside.isRunning })
        #expect(inside.terminationReason == .uncaughtSignal && inside.terminationStatus == SIGTERM)
        #expect(outside.isRunning)
    }

    /// One that ignores SIGTERM is killed at the end of the grace.
    @Test func whatIgnoresTheTermIsKilled() throws {
        let worktree = try folder("strays-stubborn")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "$SIG{TERM}=q(IGNORE); $|=1; print qq(ready\\n); sleep 300"]
        process.currentDirectoryURL = URL(fileURLWithPath: worktree)
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        defer { process.terminate() }
        // Its handler is set once it printed.
        _ = pipe.fileHandleForReading.availableData
        let started = Date()
        #expect(SessionStrays.endInside(folder: worktree, grace: 0.5).count == 1)
        #expect(Date().timeIntervalSince(started) >= 0.5)
        #expect(eventually { !process.isRunning })
        #expect(process.terminationStatus == SIGKILL)
    }
}
