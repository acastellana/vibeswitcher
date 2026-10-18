import CryptoKit
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// A host on a scratch socket, running `/bin/sh` sessions only.
final class TestHost {
    let socket = scratchSocketPath()
    let lock: String
    let server: HostServer
    /// Just before and just after the server was made and started.
    let startedAt = Date()
    private(set) var readyAt = Date.distantFuture
    /// The app's key (see `AppProof`): a `TestClient` of this host answers its challenge with it, as the app does.
    let appKey = SymmetricKey(size: .bits256)

    /// `appExecutable`: by default this test process's own binary, so its clients are the app (they answer the
    /// challenge too).
    /// `holdsKey: false`: a host that holds no app key yet (one handed over from a build before keys).
    init(build: Int = 42, vault: LeadVault.Book? = nil, appExecutable: String? = HostServer.executable(of: getpid()), log: String? = nil,
         holdsKey: Bool = true) throws {
        lock = socket + ".lock"
        var config = HostServer.Config(socketPath: socket, lockPath: lock, shell: "/bin/sh",
                                       launcher: hostLauncher, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], hostBuild: build)
        config.idleExit = nil
        config.vault = vault
        if holdsKey {
            vault?.adoptAppKey(appKey.data)
            config.appKey = appKey
        }
        config.appExecutable = appExecutable
        config.ringCapacity = 1 << 20
        config.logPath = log
        server = HostServer(config: config)
        try server.start()
        readyAt = Date()
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

    /// Answers the host's challenge with its app key (the app's client); `asApp: false`, it doesn't (another process).
    convenience init(_ host: TestHost, asApp: Bool = true) throws { try self.init(socket: host.socket, appKey: asApp ? host.appKey : nil) }

    init(socket: String, appKey: SymmetricKey? = nil) throws {
        try queue.sync {
            connection = try HostConnection(path: socket, queue: queue, appKey: appKey)
            connection.onEvent = { [weak self] e in self?.with { $0.events.append(e) } }
            connection.onOutput = { [weak self] id, data in self?.with { $0.output[id, default: Data()].append(data) } }
            connection.onClose = { [weak self] in self?.with { $0.closed = true } }
        }
    }

    func with(_ body: (TestClient) -> Void) { lock.lock(); body(self); lock.unlock() }
    /// Every event so far; read inside `with`.
    var allEvents: [HostEvent] { events.map(\.event) }
    @discardableResult func send(_ request: HostRequest) -> Int { queue.sync { (try? connection.send(request)) ?? -1 } }
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
    /// The latest the host said about a session.
    func latest(_ id: UUID) -> HostSession? {
        lock.lock(); defer { lock.unlock() }
        for envelope in events.reversed() {
            if case .sessionChanged(let session) = envelope.event, session.id == id { return session }
        }
        return nil
    }

    /// Spawns a scratch program and waits for the reply.
    func spawn(_ command: String?, cwd: String = "/tmp") throws -> HostSession {
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

    /// The session's screen as the host draws it now: asks, and waits for the answer.
    func screen(_ id: UUID) -> String? {
        let seq = send(.screen(id: id))
        guard eventually({ reply(to: seq) != nil }), case .screenText(_, let text) = reply(to: seq) else { return nil }
        return text
    }
}

struct HostServerTests {
    @Test func helloListsSessionsAndTheBuild() throws {
        let host = try TestHost(build: 42)
        let client = try TestClient(host)
        let session = try client.spawn(keepRunning)
        let seq = client.send(.hello(protocolVersion: HostProtocol.version, app: "test"))
        #expect(eventually { client.reply(to: seq) != nil })
        guard case .welcome(let version, let build, let sessions, let capabilities, let pid, let startedAt) = client.reply(to: seq) else {
            Issue.record("no welcome"); return
        }
        #expect(version == HostProtocol.version && build == 42)
        #expect(sessions.map(\.id) == [session.id])
        #expect(capabilities?.contains(HostProtocol.Capability.styledScreen) == true)
        #expect(capabilities?.contains(HostProtocol.Capability.inputRefusals) == true)
        #expect(capabilities?.contains(HostProtocol.Capability.leadVault) == true)
        #expect(pid == getpid())
        // Stamped while the test host was being made (a millisecond's slack for the encoding).
        #expect(startedAt.map { $0.timeIntervalSince(host.startedAt) > -0.001 && host.readyAt.timeIntervalSince($0) > -0.001 } == true)
    }

    @Test func inputAndOutputFlowThroughAnAttachedSession() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let session = try client.spawn("read x; echo got:$x; \(keepRunning)")
        client.attach(session.id)
        client.send(.input(id: session.id, bytes: Data("hi\r".utf8), reply: false))
        #expect(eventually { client.text(session.id).contains("got:hi") })
    }

    @Test func reattachReplaysEarlierOutput() throws {
        let host = try TestHost()
        let first = try TestClient(host)
        let session = try first.spawn("echo first-line; \(keepRunning)")
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
        defer { unlink(config.socketPath) }
        #expect(throws: HostServer.Failure.alreadyRunning) { try HostServer(config: config).start() }
    }

    @Test func repliesFromNonPrimaryClientAreDropped() throws {
        let host = try TestHost()
        let a = try TestClient(host)
        let session = try a.spawn("read x; echo got:$x; \(keepRunning)")
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
        // Half as much again as a client may have queued: a client that never reads must overflow. It starts once
        // the slow client is attached (told to go), however long that takes.
        let session = try watcher.spawn("read go; head -c \(ClientConnection.maxQueued * 3 / 2) /dev/zero | tr '\\0' x; echo; echo all-done; "
            + keepRunning)
        // A client that attaches and then never reads: the host must not wait for it.
        let fd = try UnixSocket.connect(path: host.socket)
        defer { close(fd) }
        let attach = HostFrame.encode(.control, try HostCoding.encode(HostRequestEnvelope(seq: 1, request:
            .attach(id: session.id, cols: 80, rows: 24))))
        _ = attach.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var decoder = HostFrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        /// Reads what the slow client has been sent until `done` says stop (or the hang guard passes).
        func readSlowClient(until done: (HostEvent) -> Bool) throws -> Bool {
            let deadline = Date().addingTimeInterval(hangGuard)
            while Date() < deadline {
                let count = read(fd, &buffer, buffer.count)
                // Closed by the host: nothing more will come.
                if count == 0 { return false }
                if count > 0 { decoder.append(Data(buffer[0..<count])) } else { Thread.sleep(forTimeInterval: 0.01) }
                while let frame = try decoder.next() {
                    if frame.kind == .control, let envelope = try? HostCoding.decode(HostEventEnvelope.self, from: frame.payload),
                       done(envelope.event) { return true }
                }
            }
            return false
        }
        // It reads only until it's attached, and never again.
        #expect(try readSlowClient { $0 == .attached(id: session.id) })
        watcher.send(.input(id: session.id, bytes: Data("go\r".utf8), reply: false))
        // The program finishes (its output wasn't blocked), which the host reports on screen. Blocked, it never
        // would; the time is the host taking in 24 MB, which a busy Mac stretches (10 s alone, 12-16 s in the suite).
        #expect(eventually { watcher.screen(session.id)?.contains("all-done") == true })
        // Now drain the slow client: somewhere in its stream is a resync.
        #expect(try readSlowClient { $0 == .resync(id: session.id) })
    }

    /// Scrollback of wide lines (3-byte box drawing) can exceed a frame: the reply is trimmed to fit,
    /// never dropped (the phone would wait for it forever).
    @Test func historyLargerThanAFrameIsTrimmedNotDropped() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let seq0 = client.send(.spawn(SpawnRequest(cwd: "/tmp", command: "perl -CS -e 'print qq(\\x{2500}) x 900, qq(\\n) for 1..2000; print qq(wide-done\\n)'; \(keepRunning)",
                                                   env: [:], cols: 1000, rows: 24, keepShell: false, label: "Test", agent: nil)))
        #expect(eventually { client.reply(to: seq0) != nil })
        guard case .spawned(let session) = client.reply(to: seq0) else { Issue.record("no spawn"); return }
        // The host takes in 5 MB of wide lines first, which a busy Mac stretches (over 20 s at load 110).
        #expect(eventually { client.screen(session.id)?.contains("wide-done") == true })
        let seq = client.send(.history(id: session.id, lines: 5_000))
        #expect(eventually { client.reply(to: seq) != nil })
        guard case .historyText(_, let history, _) = client.reply(to: seq) else { Issue.record("no history reply"); return }
        #expect(!history.isEmpty)
        #expect(history.utf8.count < HostFrame.maxPayload)
    }

    @Test func killEndsTheSessionAndRemoveForgetsIt() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let session = try client.spawn("\(keepRunning) & \(keepRunning); wait")
        let early = client.send(.remove(id: session.id))
        #expect(eventually { client.reply(to: early) != nil })
        #expect(client.reply(to: early) == .error("The session is still running."))
        client.send(.kill(id: session.id))
        #expect(eventually { client.hasEvent { if case .sessionChanged(let s) = $0 { return s.id == session.id && s.exit != nil }; return false } })
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
        _ = try client.spawn(keepRunning)
        let seq = client.send(.shutdown)
        #expect(eventually { client.reply(to: seq) != nil })
        #expect(client.reply(to: seq) == .error("Sessions are running."))
    }

    /// E-38: a spawn that arrives once a shutdown was accepted is refused, not started and torn down with the host.
    @Test func noSpawnOnceAShutdownWasAccepted() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let other = try TestClient(host)
        let shutdown = client.send(.shutdown)
        let spawn = client.send(.spawn(SpawnRequest(cwd: "/tmp", command: keepRunning, env: [:], cols: 80, rows: 24,
                                                    keepShell: false, label: "Test", agent: nil)))
        #expect(eventually { client.reply(to: spawn) != nil })
        #expect(client.reply(to: shutdown) == .ok)
        #expect(client.reply(to: spawn) == .error(HostProtocol.shuttingDown))
        #expect(!other.hasEvent { if case .sessionChanged = $0 { return true }; return false })
        #expect(eventually { other.closed })
    }

    /// E-07: a paste larger than the host's input buffer into a program that isn't reading yet: every piece either
    /// goes in, in order, or is answered with an error naming how many of its bytes didn't.
    @Test func inputBeyondTheBufferIsRefusedOutLoudNeverLost() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let out = scratchRoot.appendingPathComponent("paste-\(UUID().uuidString.prefix(8))").path
        defer { unlink(out) }
        // It reads nothing until the test says go (a file appears), however long sending 3 MB takes.
        let go = out + ".go"
        defer { unlink(go) }
        let session = try client.spawn("stty raw -echo; echo ready; while [ ! -e \(go) ]; do sleep 0.05; done; exec cat > \(out)")
        client.attach(session.id)
        #expect(eventually { client.text(session.id).contains("ready") })
        let piece = 64 << 10
        let pieces = (0..<48).map { Data(repeating: UInt8(ascii: "A") + UInt8($0 % 26), count: piece) }   // 3 MB
        let seqs = pieces.map { client.send(.input(id: session.id, bytes: $0, reply: false)) }
        let receipt = client.send(.screen(id: session.id))
        #expect(eventually { client.reply(to: receipt) != nil })
        let refused = seqs.indices.filter { client.reply(to: seqs[$0]) != nil }
        for index in refused {
            #expect(client.reply(to: seqs[index]).map { if case .error(let m) = $0 { return m.contains("\(piece) bytes") }; return false } == true)
        }
        #expect(!refused.isEmpty, "3 MB fit into a program that wasn't reading?")
        #expect(FileManager.default.createFile(atPath: go, contents: nil))
        let expected = seqs.indices.filter { !refused.contains($0) }.reduce(into: Data()) { $0.append(pieces[$1]) }
        #expect(eventually { (try? Data(contentsOf: URL(fileURLWithPath: out)))?.count == expected.count })
        #expect((try? Data(contentsOf: URL(fileURLWithPath: out))) == expected)
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
        try HostCall.send(.input(id: session.id, bytes: Data("ping\n".utf8), reply: false), socket: host.socket, timeout: hangGuard)
        // Well inside its own timeout: it returned on the host's answer to what followed, not by giving up.
        #expect(Date().timeIntervalSince(started) < hangGuard / 2)
        #expect(eventually { client.text(session.id).contains("ping") })
        // A request the host doesn't answer still times out through `request`, so callers must use `send` for it.
        // (The host never answers it: a busy Mac can only make this time out, as it should.)
        #expect(throws: HostCall.Failure.self) {
            try HostCall.request(.input(id: session.id, bytes: Data(), reply: false), socket: host.socket, timeout: 0.3)
        }
    }

    @Test func inputLargerThanTheSocketBufferReachesABusyHost() throws {
        // E-06: `send` used to close 50 ms after queueing; a host busy for longer than that lost what was still
        // waiting to go out (over ~8 KB), while the caller reported the message as typed.
        let path = scratchRoot.appendingPathComponent("busy-\(UUID().uuidString.prefix(8)).sock").path
        let listener = try UnixSocket.listen(path: path)
        final class Seen: @unchecked Sendable { var bytes = 0 }
        let seen = Seen()
        let finished = DispatchSemaphore(value: 0)
        // The fake host closes its socket itself, so it never accepts on a number handed out again after the test.
        let testDone = Flag()
        defer { testDone.set() }
        Thread.detachNewThread {
            defer {
                close(listener)
                unlink(path)
                finished.signal()
            }
            var fd: Int32 = -1
            while fd < 0, !testDone.isSet {
                fd = accept(listener, nil, nil)
                if fd < 0 { usleep(5_000) }
            }
            guard fd >= 0 else { return }
            defer { close(fd) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var decoder = HostFrameDecoder()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var welcomed = false, rested = false
            func answer(_ seq: Int, _ event: HostEvent) {
                guard let payload = try? HostCoding.encode(HostEventEnvelope(replyTo: seq, event: event)) else { return }
                let frame = HostFrame.encode(.control, payload)
                _ = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            }
            while true {
                // Busy for a while once it has said hello (another client, a big replay). The case itself, not a
                // wait: a busy Mac only makes it busier.
                if welcomed, !rested {
                    rested = true
                    usleep(300_000)
                }
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { return }
                decoder.append(Data(buffer[0..<count]))
                while let frame = try? decoder.next() {
                    guard let envelope = try? HostCoding.decode(HostRequestEnvelope.self, from: frame.payload) else { continue }
                    switch envelope.request {
                    case .hello:
                        answer(envelope.seq, .welcome(protocolVersion: HostProtocol.version, hostBuild: 0, sessions: []))
                        welcomed = true
                    case .input(_, let bytes, _): seen.bytes += bytes.count
                    case .screen(let id): answer(envelope.seq, .screenText(id: id, text: ""))
                    default: break
                    }
                }
            }
        }
        try HostCall.send(.input(id: UUID(), bytes: Data(repeating: 0x61, count: 64_000), reply: false), socket: path, timeout: hangGuard)
        #expect(finished.wait(timeout: .now() + hangGuard) == .success)
        #expect(seen.bytes == 64_000)
    }

    /// E-07: input the host refuses (the program isn't reading and the buffer is full) fails the call.
    @Test func refusedInputIsAnError() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let session = try client.spawn("stty raw -echo; echo ready; \(keepRunning)")
        client.attach(session.id)
        #expect(eventually { client.text(session.id).contains("ready") })
        var refusal: String?
        for _ in 0..<6 where refusal == nil {
            do {
                try HostCall.send(.input(id: session.id, bytes: Data(repeating: 0x61, count: 512 << 10), reply: false), socket: host.socket,
                                  timeout: hangGuard)
            } catch {
                refusal = "\(error)"
            }
        }
        #expect(refusal?.contains("Input refused") == true, "\(String(describing: refusal))")
    }

    /// E-29: input too large for one frame (base64 takes ~786 KB past 1 MiB) used to be skipped without a word, and
    /// the screen read sent after it was then taken as the host's receipt: the call said it went in.
    @Test func inputTooLargeForOneFrameIsAnErrorNotAReceipt() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let session = try client.spawn("cat")
        client.attach(session.id)
        let huge = Data(repeating: 0x61, count: 900 << 10)
        #expect(throws: HostCall.Failure.self) {
            try HostCall.send(.input(id: session.id, bytes: huge, reply: false), socket: host.socket, timeout: hangGuard)
        }
        do {
            try HostCall.send(.input(id: session.id, bytes: huge, reply: false), socket: host.socket, timeout: hangGuard)
        } catch {
            #expect("\(error)".contains("too large"), "\(error)")
        }
        // Nothing of it went in, and the connection still works for what fits.
        try HostCall.send(.input(id: session.id, bytes: Data("after\n".utf8), reply: false), socket: host.socket, timeout: hangGuard)
        #expect(eventually { client.text(session.id).contains("after") })
        #expect(!client.text(session.id).contains("aaaa"))
    }

    /// E-05: a lead's 30 KB message to an idle agent is typed into its terminal whole (a scratch PTY: a program that
    /// copies what it reads to a file).
    @Test func aLongLeadMessageIsTypedWholeIntoAnIdleSession() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("typed-\(UUID().uuidString.prefix(8))").path
        defer { unlink(out) }
        let session = try client.spawn("stty raw -echo; echo ready; exec cat > \(out)")
        client.attach(session.id)
        #expect(eventually { client.text(session.id).contains("ready") })
        let brief = (0..<600).map { "Line \($0): " + String(repeating: "brief ", count: 8) }.joined(separator: "\n")
        #expect(brief.utf8.count > 30_000)
        let rule = String(repeating: "─", count: 40)
        let empty = LeadDelivery.Screen(text: "\(rule)\n❯ \n\(rule)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lead-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = LeadAgent(pid: 7, tty: "ttys908", session: session.id.uuidString)
        let delivered = try LeadDelivery.deliver(brief, from: .lead("lead"), to: agent, activity: .idle(background: nil), styledScreen: { empty },
                                                 typeInto: { text in
            for write in ComposerText.writes(text, bracketed: true) {
                if write.delay > 0 { usleep(useconds_t(write.delay * 1_000_000)) }
                guard (try? HostCall.send(.input(id: session.id, bytes: Data(write.bytes), reply: false), socket: host.socket,
                                          timeout: hangGuard)) != nil else { return false }
            }
            return true
        }, root: root)
        #expect(delivered == .typed)
        // As typed: a paste of the marked message (trailing spaces dropped), then Enter.
        let typed = "\u{1b}[200~" + LeadDelivery.typed(brief, from: .lead("lead")).trimmingCharacters(in: .whitespaces) + "\u{1b}[201~\r"
        #expect(eventually { (try? String(contentsOfFile: out, encoding: .utf8)) == typed })
        #expect(SteerInbox.pending(tty: agent.tty, root: root).isEmpty)
    }

    @Test func aConnectionRefusesToSendWhatNoFrameHolds() throws {
        let host = try TestHost()
        let client = try TestClient(host)
        let huge = HostRequest.input(id: UUID(), bytes: Data(repeating: 0x61, count: 900 << 10), reply: false)
        #expect(throws: HostConnection.SendFailure.self) { try client.queue.sync { try client.connection.send(huge) } }
        client.close()
        #expect(throws: HostConnection.SendFailure.closed) { try client.queue.sync { try client.connection.send(.screen(id: UUID())) } }
    }

    @Test func aOneShotSenderDoesntTakeTheSessionFromTheApp() throws {
        let host = try TestHost()
        let app = try TestClient(host)
        let session = try app.spawn("cat")
        app.attach(session.id)
        try HostCall.send(.input(id: session.id, bytes: Data("typed\n".utf8), reply: false), socket: host.socket, timeout: hangGuard)
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

