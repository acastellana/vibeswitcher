import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A session's terminal is named as everything else names it (the stage 2 plan's Task 6a): `HostSession.tty` is the
/// name `ProcessTable` gives the program's controlling terminal (`Platform.Terminals.name`: "ttys003" on the Mac,
/// "ttypts3" on Linux), so a match by terminal (`session(of:)`'s fallback, the hook's state file, the steer inbox)
/// finds the session, and the state file sits directly in `state/`.
@Suite(hostTestLimit) struct HostedSessionTerminalTests {
    let temp = Scratch()

    /// A scratch host's session running `command`, once its program has its terminal as its own (the launcher makes
    /// it so before it execs): the session, and the name `ProcessTable` gives that terminal.
    private func session(of host: TestHost, running command: String) async throws -> (session: HostSession, tty: String) {
        let client = try TestClient(host)
        let session = try await client.spawn(command)
        #expect(await eventually { ProcessTable.info(pid: session.childPID)?.tty != nil })
        let tty = try #require(ProcessTable.info(pid: session.childPID)?.tty)
        return (session, tty)
    }

    @Test func aSessionsTerminalIsTheTablesName() async throws {
        let host = try TestHost()
        let (session, tty) = try await session(of: host, running: "sleep 30")
        #expect(session.tty == tty)
        if !Platform.CodeIdentity.isAvailable { #expect(session.tty.hasPrefix("ttypts")) }
    }

    /// A process on the session's terminal that isn't under its program (one that left it: a double fork, so its parent
    /// is whatever takes this process's orphans) is the session's by its terminal.
    @Test func aProcessOnTheSessionsTerminalIsThatSessions() async throws {
        let host = try TestHost()
        let pidFile = temp.url("orphan-pid").path
        let (session, tty) = try await session(of: host, running:
            "(sh -c 'echo $$ > \(pidFile).partial && mv \(pidFile).partial \(pidFile); exec sleep 30' &); \(keepRunning)")
        #expect(await eventually { FileManager.default.fileExists(atPath: pidFile) })
        let text = try String(contentsOfFile: pidFile, encoding: .utf8)
        let orphan = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(orphan, SIGKILL) }
        // Not under the program: only its terminal makes it the session's.
        #expect(await eventually { ProcessTable.ancestry(of: orphan).map { !$0.map(\.pid).contains(session.childPID) } == true })
        #expect(ProcessTable.info(pid: orphan)?.tty == tty)
        #expect(host.server.queue.sync { host.server.session(of: orphan) } == session.id.uuidString)
    }

    @Test func theHookStateFileOfASessionIsDirectlyInState() async throws {
        let host = try TestHost()
        let (session, _) = try await session(of: host, running: "sleep 30")
        let file = VibePaths.stateFile(tty: session.tty)
        #expect(file.deletingLastPathComponent().standardizedFileURL.path == VibePaths.stateDir.standardizedFileURL.path)
        #expect(file.lastPathComponent == session.tty + ".json")
    }
}
