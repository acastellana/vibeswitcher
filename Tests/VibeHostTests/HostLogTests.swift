import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The host's session log, on a private host with a scratch log file: what started each session, how each one
/// ended (a signal or an exit code), and who asked to kill a session or shut the host down.
struct HostLogTests {
    func scratchLog() -> String { "/tmp/vsh-log-\(UUID().uuidString.prefix(8)).log" }

    func log(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    func ended(_ client: TestClient, _ id: UUID) -> HostSession.Exit? { client.latest(id)?.exit }

    @Test func aSignalDeathAndAnExitCodeAreToldApart() throws {
        let path = scratchLog()
        defer { unlink(path) }
        let host = try TestHost(log: path)
        let client = try TestClient(host)
        // SIGTERM from outside, as on 2026-10-17 (the session's interactive shell ignores its own).
        let signalled = try client.spawn("exec sleep 30")
        let exited = try client.spawn("exit 143")
        #expect(eventually { (ProcessTable.info(pid: signalled.childPID)?.comm ?? "") == "sleep" })
        kill(signalled.childPID, SIGTERM)
        #expect(eventually { ended(client, signalled.id) != nil && ended(client, exited.id) != nil })
        let killed = try #require(ended(client, signalled.id)), code = try #require(ended(client, exited.id))
        #expect(killed.status == 143 && killed.signal == 15 && killed.core == false && killed.killedBy == nil)
        #expect(killed.cause == "killed by SIGTERM")
        #expect(code.status == 143 && code.signal == nil && code.cause == "exited 143")
        #expect(eventually { log(path).components(separatedBy: "\n").filter { $0.contains("exit ") }.count == 2 })
        let lines = log(path).components(separatedBy: "\n")
        let spawn = try #require(lines.first { $0.contains("spawn") && $0.contains("pid \(signalled.childPID)") })
        #expect(spawn.contains("label 'Test'") && spawn.contains("cwd '/tmp'") && spawn.contains("peer pid \(getpid())"))
        let death = try #require(lines.first { $0.contains("exit ") && $0.contains("pid \(signalled.childPID)") })
        #expect(death.contains("wait status 0x000f") && death.contains("signal 15 (SIGTERM)") && death.contains("no core"))
        let exit = try #require(lines.first { $0.contains("exit ") && $0.contains("pid \(exited.childPID)") })
        #expect(exit.contains("wait status 0x8f00") && exit.contains("exit code 143"))
    }

    @Test func aKillAndAShutdownNameWhoAsked() throws {
        let path = scratchLog()
        defer { unlink(path) }
        let host = try TestHost(log: path)
        let client = try TestClient(host)
        let session = try client.spawn("sleep 30")
        let refused = client.send(.shutdown)
        #expect(eventually { client.reply(to: refused) != nil })
        client.send(.kill(id: session.id))
        #expect(eventually { ended(client, session.id) != nil })
        let exit = try #require(ended(client, session.id))
        let me = ProcessTable.info(pid: getpid())?.comm
        #expect(exit.signal == SIGHUP && exit.killedBy == getpid() && exit.killedByName == me)
        #expect(exit.cause.hasPrefix("killed by SIGHUP from pid \(getpid())"))
        let accepted = client.send(.shutdown)
        #expect(eventually { client.reply(to: accepted) == .ok })
        let lines = log(path).components(separatedBy: "\n")
        #expect(lines.contains { $0.contains("kill \(session.id.uuidString.prefix(8))") && $0.contains("pid \(session.childPID)")
            && $0.contains("peer pid \(getpid())") })
        #expect(lines.contains { $0.contains("shutdown refused") && $0.contains("peer pid \(getpid())") })
        #expect(lines.contains { $0.contains("shutdown accepted") && $0.contains("peer pid \(getpid())") })
    }

    /// The built host on a private socket, lock, log and home: a SIGTERM is logged with its sender, and still ends it.
    @Test func theHostLogsWhoSignalledIt() throws {
        let path = scratchLog(), socket = scratchSocketPath()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vsh-home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { unlink(path); unlink(socket + ".lock"); try? FileManager.default.removeItem(at: home) }
        let host = Process()
        host.executableURL = URL(fileURLWithPath: hostLauncher)
        host.arguments = ["--socket", socket, "--lock", socket + ".lock", "--log", path, "--idle-exit", "60"]
        // Its own ~/.vibeswitcher (for the launcher copy), never the user's.
        host.environment = ["CFFIXED_USER_HOME": home.path, "HOME": home.path, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
        host.standardError = FileHandle.nullDevice
        try host.run()
        #expect(eventually { log(path).contains("host: started") })
        kill(host.processIdentifier, SIGTERM)
        host.waitUntilExit()
        #expect(host.terminationReason == .uncaughtSignal && host.terminationStatus == SIGTERM)
        #expect(log(path).contains("host: got SIGTERM from pid \(getpid())"))
    }
}
