import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// Each session's output is parsed in a process of its own (see `SessionParser`): a parser that stalls or traps (a test
/// hook, on a scratch host only) holds up or ends only itself; the watchdog logs it and starts another.
@Suite(.serialized) struct ParserIsolationTests {
    /// Prints the time every 50 ms, so a client can tell how late each line reached it.
    static let clock = "perl -MTime::HiRes=time -e '$|=1; while (1) { printf qq(t=%.4f\\n), time; select(undef, undef, undef, 0.05) }'"
    /// Prints a line, then the hook's sequence on its own, then counts.
    static func breaking(_ hook: String) -> String {
        "printf 'before\\n'; sleep 0.3; printf '\\033]7599;\(hook)\\007'; sleep 0.3; i=0; while :; do i=$((i+1)); echo after-$i; sleep 0.1; done"
    }

    func host(stallLimit: TimeInterval) throws -> (ScratchHostProcess, TestClient) {
        let host = try ScratchHostProcess(arguments: ["--parser-test-hooks", "--parser-stall-limit", String(stallLimit)])
        let (client, _, _, _, _, _, _) = try TestClient.welcomed(host.socket, appKey: host.appKey)
        return (host, client)
    }

    func end(_ host: ScratchHostProcess, _ sessions: [HostSession]) {
        for session in sessions where kill(session.childPID, 0) == 0 { kill(-session.childPID, SIGKILL) }
        host.stop()
    }

    func sessionLog(_ host: ScratchHostProcess) -> String { (try? String(contentsOfFile: host.sessionLog, encoding: .utf8)) ?? "" }

    /// The parser processes the host runs now (its children started with `--parse-session`).
    func parsers(of host: pid_t) -> [pid_t] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-ax", "-o", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count == 3, pid_t(fields[1]) == host, fields[2].contains("--parse-session") else { return nil }
            return pid_t(fields[0])
        }
    }

    /// How late each of the clock's lines reached `client`, from when it's called (see `clock`).
    final class Lateness {
        private let lock = NSLock()
        private var partial = ""
        private var delays: [TimeInterval] = []

        init(_ client: TestClient, session: UUID) {
            client.queue.sync {
                let earlier = client.connection.onOutput
                client.connection.onOutput = { [weak self] id, data in
                    earlier?(id, data)
                    guard id == session else { return }
                    self?.received(data, at: Date().timeIntervalSince1970)
                }
            }
        }

        private func received(_ data: Data, at now: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            partial += String(decoding: data, as: UTF8.self)
            var lines = partial.components(separatedBy: "\n")
            partial = lines.removeLast()
            for line in lines {
                guard let range = line.range(of: "t="), let printed = TimeInterval(line[range.upperBound...].prefix { $0.isNumber || $0 == "." }) else { continue }
                delays.append(now - printed)
            }
        }

        /// Forgets what came so far.
        func reset() { lock.lock(); delays = []; lock.unlock() }
        var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return delays }
    }

    /// One session's parser hangs mid-parse: another session's output still reaches its view within 100 ms, its
    /// screen is still answered, the stalled session's own output still flows, and the watchdog logs the stall
    /// (with the session) and replaces the parser, whose screen then shows what came after.
    @Test func aStalledParserHoldsUpOnlyItsSession() throws {
        let (host, client) = try host(stallLimit: 3)
        let clock = try client.spawn(Self.clock)
        let lateness = Lateness(client, session: clock.id)
        client.attach(clock.id)
        #expect(eventually { client.text(clock.id).contains("t=") })
        let stalled = try client.spawn(Self.breaking("stall"))
        defer { end(host, [clock, stalled]) }
        client.attach(stalled.id)
        // Past the hook: its parser is stuck now, the watchdog not there yet.
        #expect(eventually { client.text(stalled.id).contains("after-1") })
        lateness.reset()
        let started = Date()
        while Date().timeIntervalSince(started) < 2 { Thread.sleep(forTimeInterval: 0.05) }
        let delays = lateness.all
        #expect(delays.count >= 20, "the clock's lines while the other parser was stuck: \(delays.count)")
        #expect((delays.max() ?? 1) < 0.1, "the clock's lines arrived up to \(delays.max() ?? 0) s late")
        let asked = Date()
        #expect(client.screen(clock.id)?.contains("t=") == true)
        #expect(Date().timeIntervalSince(asked) < 1)
        #expect(!sessionLog(host).contains("watchdog"), "the watchdog came early: \(sessionLog(host))")

        let short = HostServer.short(stalled.id)
        #expect(eventually(timeout: 30) { sessionLog(host).contains("watchdog: session \(short)'s parser") })
        let line = sessionLog(host).split(separator: "\n").first { $0.contains("watchdog: session \(short)'s parser") } ?? ""
        #expect(line.contains("stalled for") && line.contains("started another"), "\(line)")
        #expect(!sessionLog(host).contains("watchdog: session \(HostServer.short(clock.id))"))
        // Every "after-" line before the restart was left unparsed: one on the screen came through the new parser.
        #expect(eventually(timeout: 30) { client.screen(stalled.id)?.contains("after-") == true }, "\(client.screen(stalled.id) ?? "no screen")")
        #expect(kill(stalled.childPID, 0) == 0 && host.process.isRunning)
        #expect(eventually { parsers(of: host.pid).count == 2 })
    }

    /// One session's parser traps: the host and every session carry on, attachable and typed into; the watchdog
    /// logs it and starts another parser for that session.
    @Test func aParserThatTrapsEndsOnlyItself() throws {
        let (host, client) = try host(stallLimit: 10)
        let shell = try client.spawn("while read line; do echo got:$line; done")
        let trapped = try client.spawn(Self.breaking("trap"))
        defer { end(host, [shell, trapped]) }
        let short = HostServer.short(trapped.id)
        #expect(eventually(timeout: 30) { sessionLog(host).contains("watchdog: session \(short)'s parser") }, "\(host.log)")
        let line = sessionLog(host).split(separator: "\n").first { $0.contains("watchdog: session \(short)'s parser") } ?? ""
        #expect(line.contains("ended (wait status") && line.contains("started another"), "\(line)")
        #expect(host.process.isRunning)

        // A new view of each: the shell answers, the trapped session's program still prints.
        let (viewer, _, _, listed, _, pid, _) = try TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(pid == host.pid && listed.filter(\.isLive).map(\.id) == [shell.id, trapped.id])
        viewer.attach(shell.id)
        viewer.attach(trapped.id)
        viewer.send(.input(id: shell.id, bytes: Data("hello\r".utf8), reply: false))
        #expect(eventually { viewer.text(shell.id).contains("got:hello") })
        let printed = counted(viewer.text(trapped.id).replacingOccurrences(of: "after-", with: "n=")).last ?? 0
        #expect(eventually { (counted(viewer.text(trapped.id).replacingOccurrences(of: "after-", with: "n=")).last ?? 0) > printed + 3 })
        #expect(eventually { viewer.screen(shell.id)?.contains("got:hello") == true })
        #expect(eventually { viewer.screen(trapped.id)?.contains("after-") == true }, "\(viewer.screen(trapped.id) ?? "no screen")")
        #expect(kill(trapped.childPID, 0) == 0)
        #expect(eventually { parsers(of: host.pid).count == 2 })
    }

    /// A handover leaves no parser behind: the old build's are gone, the new build runs one per live session.
    @Test func aHandoverReplacesEveryParser() throws {
        let host = try ScratchHostProcess()
        let (client, _, _, _, _, _, _) = try TestClient.welcomed(host.socket, appKey: host.appKey)
        let first = try client.spawn("printf 'first screen\\n'; \(keepRunning)")
        let second = try client.spawn("printf '\\033[2J\\033[3;5Hpainted'; \(keepRunning)")
        let done = try client.spawn("echo done-early; exit 2")
        defer { end(host, [first, second]) }
        #expect(eventually { client.exitStatus(done.id) == 2 })
        #expect(eventually { client.screen(second.id)?.contains("painted") == true })
        #expect(eventually { parsers(of: host.pid).count == 2 })
        let before = parsers(of: host.pid)
        let screens = [first.id, second.id, done.id].map { client.screen($0) ?? "" }

        let seq = client.send(.handover(executable: host.newBinary))
        #expect(eventually { client.reply(to: seq) != nil })
        #expect(client.reply(to: seq) == .ok, "\(host.log)")
        #expect(eventually { host.log.contains("took over 3 sessions") })
        let (next, _, build, _, _, _, _) = try TestClient.welcomed(host.socket, appKey: host.appKey)
        #expect(build == host.newBuild)
        #expect([first.id, second.id, done.id].map { next.screen($0) ?? "" } == screens)
        #expect(before.allSatisfy { kill($0, 0) != 0 }, "old parsers still running: \(before.filter { kill($0, 0) == 0 })")
        let after = parsers(of: host.pid)
        #expect(after.count == 2 && Set(after).isDisjoint(with: before))
    }

    /// SIGTERM is handled on the host's queue, which never runs a parse: it's logged and ends the host at once, even
    /// with a session's parser stuck; no parser outlives it.
    @Test func sigtermEndsTheHostWhileAParserIsStuck() throws {
        let (host, client) = try host(stallLimit: 600)
        let stalled = try client.spawn(Self.breaking("stall"))
        let other = try client.spawn(keepRunning)
        defer { end(host, [stalled, other]) }
        client.attach(stalled.id)
        #expect(eventually { client.text(stalled.id).contains("after-1") })
        #expect(eventually { parsers(of: host.pid).count == 2 })
        let running = parsers(of: host.pid)
        let sent = Date()
        kill(host.pid, SIGTERM)
        host.process.waitUntilExit()
        #expect(Date().timeIntervalSince(sent) < 5)
        #expect(host.process.terminationReason == .uncaughtSignal && host.process.terminationStatus == SIGTERM)
        #expect(sessionLog(host).contains("host: got SIGTERM from pid \(getpid())"))
        #expect(eventually { running.allSatisfy { kill($0, 0) != 0 } }, "parsers left running: \(running.filter { kill($0, 0) == 0 })")
    }
}
