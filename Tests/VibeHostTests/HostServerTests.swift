import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A host on a scratch socket, running `/bin/sh` sessions only.
final class TestHost {
    let socket = scratchSocketPath()
    let lock: String
    let server: HostServer

    init(build: Int = 42) throws {
        lock = socket + ".lock"
        var config = HostServer.Config(socketPath: socket, lockPath: lock, shell: "/bin/sh",
                                       launcher: hostLauncher, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], hostBuild: build)
        config.idleExit = nil
        config.ringCapacity = 1 << 20
        server = HostServer(config: config)
        try server.start()
    }

    deinit {
        server.stop(terminateSessions: true)
        unlink(lock)
    }
}

/// The app's side, recording everything it receives.
final class TestClient {
    let queue = DispatchQueue(label: "test-client")
    private let lock = NSLock()
    private var events: [HostEventEnvelope] = []
    private var output: [UUID: Data] = [:]
    private(set) var closed = false
    var connection: HostConnection!

    init(_ host: TestHost) throws {
        try queue.sync {
            connection = try HostConnection(path: host.socket, queue: queue)
            connection.onEvent = { [weak self] e in self?.with { $0.events.append(e) } }
            connection.onOutput = { [weak self] id, data in self?.with { $0.output[id, default: Data()].append(data) } }
            connection.onClose = { [weak self] in self?.with { $0.closed = true } }
        }
    }

    func with(_ body: (TestClient) -> Void) { lock.lock(); body(self); lock.unlock() }
    @discardableResult func send(_ request: HostRequest) -> Int { queue.sync { connection.send(request) } }
    func text(_ id: UUID) -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: output[id] ?? Data(), as: UTF8.self) }
    func reply(to seq: Int) -> HostEvent? {
        lock.lock(); defer { lock.unlock() }
        return events.first { $0.replyTo == seq }?.event
    }
    func hasEvent(_ match: (HostEvent) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return events.contains { match($0.event) }
    }
    func close() { queue.sync { connection.close() } }

    /// Spawns a scratch program and waits for the reply.
    func spawn(_ command: String, cwd: String = "/tmp") throws -> HostSession {
        let seq = send(.spawn(SpawnRequest(cwd: cwd, command: command, env: [:], cols: 80, rows: 24, keepShell: false,
                                           label: "Test", agent: nil)))
        #expect(eventually { reply(to: seq) != nil })
        guard case .spawned(let session) = reply(to: seq) else { throw CancellationError() }
        return session
    }

    func attach(_ id: UUID) {
        let seq = send(.attach(id: id, cols: 80, rows: 24))
        #expect(eventually { reply(to: seq) == .attached(id: id) })
    }
}

struct HostServerTests {
    @Test func helloListsSessionsAndTheBuild() throws {
        let host = try TestHost(build: 42)
        let client = try TestClient(host)
        let session = try client.spawn("sleep 5")
        let seq = client.send(.hello(protocolVersion: HostProtocol.version, app: "test"))
        #expect(eventually { client.reply(to: seq) != nil })
        guard case .welcome(let version, let build, let sessions) = client.reply(to: seq) else { Issue.record("no welcome"); return }
        #expect(version == HostProtocol.version && build == 42)
        #expect(sessions.map(\.id) == [session.id])
    }

    @Test func inputAndOutputFlowThroughAnAttachedSession() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let session = try client.spawn("read x; echo got:$x; sleep 5")
        client.attach(session.id)
        client.send(.input(id: session.id, bytes: Data("hi\r".utf8), reply: false))
        #expect(eventually { client.text(session.id).contains("got:hi") })
    }

    @Test func reattachReplaysEarlierOutput() throws {
        let host = try TestHost()
        let first = try TestClient(host)
        let session = try first.spawn("echo first-line; sleep 10")
        first.attach(session.id)
        #expect(eventually { first.text(session.id).contains("first-line") })
        first.close()
        let second = try TestClient(host)
        second.attach(session.id)
        #expect(eventually { second.text(session.id).contains("first-line") })
    }

    @Test func aSecondHostRefusesToStart() throws {
        let host = try TestHost()
        let config = HostServer.Config(socketPath: scratchSocketPath(), lockPath: host.lock, shell: "/bin/sh",
                                       launcher: hostLauncher, baseEnvironment: [:], hostBuild: 1)
        #expect(throws: HostServer.Failure.alreadyRunning) { try HostServer(config: config).start() }
    }

    @Test func repliesFromNonPrimaryClientAreDropped() throws {
        let host = try TestHost()
        let a = try TestClient(host)
        let session = try a.spawn("read x; echo got:$x; sleep 5")
        a.attach(session.id)
        let b = try TestClient(host)
        b.attach(session.id)   // the latest to attach is primary
        a.send(.input(id: session.id, bytes: Data("zzz".utf8), reply: true))
        b.send(.input(id: session.id, bytes: Data("ok\r".utf8), reply: true))
        #expect(eventually { b.text(session.id).contains("got:") })
        #expect(b.text(session.id).contains("got:ok"))
        #expect(!b.text(session.id).contains("zzz"))
    }

    @Test func slowClientGetsResyncAndProgramKeepsRunning() throws {
        let host = try TestHost()
        let watcher = try TestClient(host)
        let session = try watcher.spawn("sleep 0.5; head -c 40000000 /dev/zero | tr '\\0' x; echo; echo all-done; sleep 5")
        // A client that attaches and then never reads: the host must not wait for it.
        let fd = try UnixSocket.connect(path: host.socket)
        defer { close(fd) }
        let attach = HostFrame.encode(.control, try HostCoding.encode(HostRequestEnvelope(seq: 1, request:
            .attach(id: session.id, cols: 80, rows: 24))))
        _ = attach.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        // The program finishes (its output wasn't blocked), which the host reports on screen.
        #expect(eventually(timeout: 30) {
            let seq = watcher.send(.screen(id: session.id))
            Thread.sleep(forTimeInterval: 0.2)
            if case .screenText(_, let text) = watcher.reply(to: seq) { return text.contains("all-done") }
            return false
        })
        // Now drain the slow client: somewhere in its stream is a resync.
        var decoder = HostFrameDecoder()
        var sawResync = false
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = Date().addingTimeInterval(10)
        while !sawResync, Date() < deadline {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { decoder.append(Data(buffer[0..<count])) } else { Thread.sleep(forTimeInterval: 0.01) }
            while let frame = try decoder.next() {
                if frame.kind == .control,
                   let envelope = try? HostCoding.decode(HostEventEnvelope.self, from: frame.payload),
                   envelope.event == .resync(id: session.id) { sawResync = true }
            }
        }
        #expect(sawResync)
    }

    /// Scrollback of wide lines (3-byte box drawing) can exceed a frame: the reply is trimmed to fit,
    /// never dropped (the phone would wait for it forever).
    @Test func historyLargerThanAFrameIsTrimmedNotDropped() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let seq0 = client.send(.spawn(SpawnRequest(cwd: "/tmp", command: "perl -CS -e 'print qq(\\x{2500}) x 900, qq(\\n) for 1..2000; print qq(wide-done\\n)'; sleep 30",
                                                   env: [:], cols: 1000, rows: 24, keepShell: false, label: "Test", agent: nil)))
        #expect(eventually { client.reply(to: seq0) != nil })
        guard case .spawned(let session) = client.reply(to: seq0) else { Issue.record("no spawn"); return }
        #expect(eventually(timeout: 20) {
            let seq = client.send(.screen(id: session.id))
            Thread.sleep(forTimeInterval: 0.2)
            if case .screenText(_, let text) = client.reply(to: seq) { return text.contains("wide-done") }
            return false
        })
        let seq = client.send(.history(id: session.id, lines: 5_000))
        #expect(eventually(timeout: 10) { client.reply(to: seq) != nil })
        guard case .historyText(_, let history, _) = client.reply(to: seq) else { Issue.record("no history reply"); return }
        #expect(!history.isEmpty)
        #expect(history.utf8.count < HostFrame.maxPayload)
    }

    @Test func killEndsTheSessionAndRemoveForgetsIt() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let session = try client.spawn("sleep 30 & sleep 30; wait")
        let early = client.send(.remove(id: session.id))
        #expect(eventually { client.reply(to: early) != nil })
        #expect(client.reply(to: early) == .error("The session is still running."))
        client.send(.kill(id: session.id))
        #expect(eventually(timeout: 8) { client.hasEvent { if case .sessionChanged(let s) = $0 { return s.id == session.id && s.exit != nil }; return false } })
        let seq = client.send(.remove(id: session.id))
        #expect(eventually { client.reply(to: seq) == .ok })
        #expect(eventually { client.hasEvent { $0 == .sessionRemoved(id: session.id) } })
    }

    @Test func spawnInAMissingFolderIsAnError() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let seq = client.send(.spawn(SpawnRequest(cwd: "/no/such/folder", command: "true", env: [:], cols: 80, rows: 24,
                                                  keepShell: false, label: "Test", agent: nil)))
        #expect(eventually { client.reply(to: seq) != nil })
        #expect(client.reply(to: seq) == .error("No such folder: /no/such/folder"))
    }

    @Test func shutdownWaitsForLiveSessions() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        _ = try client.spawn("sleep 30")
        let seq = client.send(.shutdown)
        #expect(eventually { client.reply(to: seq) != nil })
        #expect(client.reply(to: seq) == .error("Sessions are running."))
    }

    @Test func connectionsComeFromThisUser() throws {
        let host = try TestHost()
        let fd = try UnixSocket.connect(path: host.socket)
        defer { close(fd) }
        #expect(UnixSocket.peerUID(fd) == getuid())
        var info = stat()
        #expect(stat(host.socket, &info) == 0 && info.st_mode & 0o777 == 0o600)
    }
}

struct HostCallTests {
    @Test func inputIsSentWithoutWaitingForAReplyThatNeverComes() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let session = try client.spawn("cat")
        client.attach(session.id)
        let started = Date()
        try HostCall.send(.input(id: session.id, bytes: Data("ping\n".utf8), reply: false), socket: host.socket)
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(eventually { client.text(session.id).contains("ping") })
        // A request the host doesn't answer still times out through `request`, so callers must use `send` for it.
        #expect(throws: HostCall.Failure.self) {
            try HostCall.request(.input(id: session.id, bytes: Data(), reply: false), socket: host.socket, timeout: 0.3)
        }
    }

    @Test func aOneShotSenderDoesntTakeTheSessionFromTheApp() throws {
        let host = try TestHost()
        let app = try TestClient(host)
        let session = try app.spawn("cat")
        app.attach(session.id)
        try HostCall.send(.input(id: session.id, bytes: Data("typed\n".utf8), reply: false), socket: host.socket)
        #expect(eventually { app.text(session.id).contains("typed") })
        // The app's terminal still answers the program (its replies go through only from the primary client).
        app.send(.input(id: session.id, bytes: Data("answer\n".utf8), reply: true))
        #expect(eventually { app.text(session.id).contains("answer") })
    }

    @Test func anUnknownRequestIsAnsweredNotFatal() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        // A newer app's request this host doesn't know.
        client.queue.sync { client.connection.sendRaw(Data(#"{"seq":77,"request":{"teleport":{"to":"mars"}}}"#.utf8)) }
        #expect(eventually { client.reply(to: 77).map { if case .error = $0 { return true } else { return false } } ?? false })
        let seq = client.send(.hello(protocolVersion: HostProtocol.version, app: "test"))
        #expect(eventually { client.reply(to: seq) != nil })
        #expect(!client.closed)
    }
}

