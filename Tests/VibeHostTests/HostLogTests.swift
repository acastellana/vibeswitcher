import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// The host's session log, on a private host with a scratch log file: what started each session, how each one
/// ended (a signal or an exit code), and who asked to kill a session or shut the host down.
struct HostLogTests {
    func scratchLog() -> String { "\(shortScratchRoot)/vsh-log-\(UUID().uuidString.prefix(8)).log" }

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

    /// Each change of a session's PTY size is a line in the host's log (`resize 1A2B3C4D to 110×40 (initial)`: the
    /// attach's size, or a client's), a drag's steps one line. The app's log says why (window resize, pane split…), same
    /// id, same clock. The one real-time wait here (the held line, a second after the attach's) is bounded at 10 s;
    /// the timing itself is `theResizeLogHoldsABurstOnItsClock`'s, on a clock the test moves.
    @Test func eachResizeIsLoggedOnTheScratchHost() throws {
        let path = scratchLog()
        defer { unlink(path) }
        let host = try TestHost(log: path)
        let client = try TestClient(host)
        let session = try client.spawn(keepRunning)
        defer { kill(-session.childPID, SIGKILL) }
        let short = session.id.uuidString.prefix(8)
        func resizes() -> [String] { log(path).components(separatedBy: "\n").filter { $0.contains("resize \(short) ") } }
        let attach = client.send(.attach(id: session.id, cols: 110, rows: 40))
        #expect(eventually(timeout: 10) { client.reply(to: attach) == .attached(id: session.id) })
        // A drag: five steps right after; then the same size again (the PTY doesn't change: no line).
        for cols in 111...115 { client.send(.resize(id: session.id, cols: cols, rows: 40)) }
        client.send(.resize(id: session.id, cols: 115, rows: 40))
        #expect(eventually(timeout: 10) { resizes().count == 2 })
        let lines = resizes()
        #expect(lines.first?.hasSuffix("resize \(short) to 110×40 (initial)") == true)
        #expect(lines.last?.contains("resize \(short) to 115×40 (client)") == true)
    }

    /// One line a second at most per session: resizes within a second of a line are held, and the newest is written a
    /// second after that line, with how many it stands for; a resize a second or more after a line is written at once.
    /// On a clock the test moves (no real time passes); a scratch program on a real PTY.
    @Test func theResizeLogHoldsABurstOnItsClock() throws {
        let probe = SessionProbe()
        let request = SpawnRequest(cwd: NSHomeDirectory(), command: keepRunning, env: [:], cols: 80, rows: 24, keepShell: false, label: "Test", agent: nil)
        let session = try probe.queue.sync {
            try HostedSession.spawn(request, shell: "/bin/sh", launcher: hostLauncher,
                                    baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], ringCapacity: 1 << 20, queue: probe.queue)
        }
        defer { probe.queue.sync { session.terminate() } }
        let short = session.id.uuidString.prefix(8)
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var later: [(at: Date, write: () -> Void)] = []
        var lines: [(at: Date, line: String)] = []
        probe.queue.sync {
            session.resizeClock = { now }
            session.resizeLater = { wait, write in later.append((now + wait, write)) }
            session.onResized = { lines.append((now, $0)) }
        }
        func resize(_ cols: Int, _ rows: Int, _ reason: String = "client") { probe.queue.sync { session.resize(cols: cols, rows: rows, reason: reason) } }
        /// Moves the clock on (in eighths of a second: exact sums), writing what came due.
        func advance(_ seconds: TimeInterval) {
            now += seconds
            let due = later.filter { $0.at <= now }
            later.removeAll { $0.at <= now }
            probe.queue.sync { due.forEach { $0.write() } }
        }

        resize(110, 40, "initial")
        #expect(lines.map(\.line) == ["resize \(short) to 110×40 (initial)"])
        for cols in 111...115 {
            advance(0.125)
            resize(cols, 40)
        }
        resize(115, 40)
        #expect(lines.count == 1)
        advance(0.25)
        #expect(lines.count == 1)
        advance(0.125)
        #expect(lines.count == 2)
        #expect(lines.last?.line == "resize \(short) to 115×40 (client), the last of 5 within a second")
        #expect(lines[1].at.timeIntervalSince(lines[0].at) == 1)
        // One alone within the second after: held, written without a count a second after the line before.
        advance(0.5)
        resize(120, 40)
        advance(0.5)
        #expect(lines.last?.line == "resize \(short) to 120×40 (client)" && lines[2].at.timeIntervalSince(lines[1].at) == 1)
        // A second or more after a line: at once.
        advance(1)
        resize(160, 40)
        #expect(lines.count == 4 && lines.last?.line == "resize \(short) to 160×40 (client)" && lines[3].at == now)
        #expect(later.isEmpty)
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
        let home = scratchRoot.appendingPathComponent("vsh-home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // The signal ends it before it can remove its socket.
        defer { unlink(path); unlink(socket); unlink(socket + ".lock"); try? FileManager.default.removeItem(at: home) }
        let host = Process()
        host.executableURL = URL(fileURLWithPath: hostLauncher)
        host.arguments = ["--socket", socket, "--lock", socket + ".lock", "--log", path, "--idle-exit", "60"]
        // Its own ~/.vibeswitcher (for the launcher copy), never the user's.
        host.environment = ["CFFIXED_USER_HOME": home.path, "HOME": home.path, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
        host.standardError = FileHandle.nullDevice
        try TestHosts.run(host)
        defer { TestHosts.end(host) }
        #expect(eventually { log(path).contains("host: started") })
        kill(host.processIdentifier, SIGTERM)
        host.waitUntilExit()
        #expect(host.terminationReason == .uncaughtSignal && host.terminationStatus == SIGTERM)
        #expect(log(path).contains("host: got SIGTERM from pid \(getpid())"))
    }
}
