import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost

/// E-16: an ended session lets go of its PTY, replay buffer and terminal, and still shows its last screen and exit.
struct EndedSessionTests {
    @Test func anEndedSessionKeepsItsLastScreenOnly() throws {
        let probe = SessionProbe()
        let request = SpawnRequest(cwd: "/tmp", command: "printf '\\033[31mred\\033[0m line-%s\\n' 1 2 3; exit 4", env: [:], cols: 80, rows: 24,
                                   keepShell: false, label: "Test", agent: nil)
        let session = try probe.queue.sync {
            let session = try HostedSession.spawn(request, shell: "/bin/sh", launcher: hostLauncher, baseEnvironment: ["PATH": "/usr/bin:/bin"],
                                                  ringCapacity: 1 << 20, queue: probe.queue)
            probe.attach(session)
            return session
        }
        #expect(eventually { probe.lastChange?.exit != nil })
        probe.queue.sync {
            #expect(session.info.exit?.status == 4)
            #expect(!session.holdsLiveResources)
            #expect(session.screenText().contains("red line-3"))
            #expect(session.styledScreen().runs.contains { $0.color == .palette(1) })
            let replay = String(decoding: session.replay(), as: UTF8.self)
            #expect(replay.contains("line-1") && replay.contains("line-3"))
            #expect(replay.contains("\u{1b}[38;5;1mred"))
            #expect(!session.write(Data("late".utf8)))
        }
    }

    /// Spawns and ends sessions on a host of its own (a process, so other tests' descriptors don't count) and
    /// counts that host's open descriptors.
    @Test func endedSessionsCloseTheirPTYs() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vsh-home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let socket = scratchSocketPath()
        let host = Process()
        host.executableURL = URL(fileURLWithPath: hostLauncher)
        host.arguments = ["--socket", socket, "--lock", socket + ".lock", "--idle-exit", "600"]
        // Its own ~/.vibeswitcher (for the launcher copy), never the user's.
        host.environment = ["CFFIXED_USER_HOME": home.path, "HOME": home.path, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
        host.standardError = FileHandle.nullDevice
        try host.run()
        defer {
            if host.isRunning { host.terminate() }
            unlink(socket + ".lock")
            try? FileManager.default.removeItem(at: home)
        }
        #expect(eventually { FileManager.default.fileExists(atPath: socket) })
        let client = try TestClient(socket: socket)
        func ended(_ id: UUID) -> Bool {
            client.hasEvent { if case .sessionChanged(let s) = $0 { return s.id == id && s.exit != nil }; return false }
        }

        let warmUp = try client.spawn("exit 0")
        #expect(eventually { ended(warmUp.id) })
        Thread.sleep(forTimeInterval: 0.3)
        let baseline = openDescriptors(of: host.processIdentifier)

        let count = 20
        let sessions = try (0..<count).map { try client.spawn("sleep 3; echo ended-\($0)") }
        #expect(openDescriptors(of: host.processIdentifier) >= baseline + count, "each live session holds its PTY")
        #expect(eventually(timeout: 15) { sessions.allSatisfy { ended($0.id) } })
        #expect(eventually { openDescriptors(of: host.processIdentifier) == baseline },
                "open: \(openDescriptors(of: host.processIdentifier)), at first: \(baseline)")

        // Still listed for their day, with their last screen.
        let hello = client.send(.hello(protocolVersion: HostProtocol.version, app: "test"))
        #expect(eventually { client.reply(to: hello) != nil })
        guard case .welcome(_, _, let listed, _, _, _) = client.reply(to: hello) else { Issue.record("no welcome"); return }
        #expect(Set(sessions.map(\.id)).isSubset(of: Set(listed.filter { $0.exit != nil }.map(\.id))))
        let screen = client.send(.screen(id: sessions[7].id))
        #expect(eventually { client.reply(to: screen) != nil })
        #expect(client.reply(to: screen).map { if case .screenText(_, let text) = $0 { return text.contains("ended-7") }; return false } == true)
        client.attach(sessions[7].id)
        #expect(eventually { client.text(sessions[7].id).contains("ended-7") })

        let shutdown = client.send(.shutdown)
        #expect(eventually { client.reply(to: shutdown) == .ok })
        #expect(eventually { !host.isRunning })
    }

    private func openDescriptors(of pid: pid_t) -> Int {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return -1 }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 16)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        return Int(used) / MemoryLayout<proc_fdinfo>.stride
    }
}

/// E-29: a reply too large for a frame is answered with an error instead of vanishing.
struct TooLargeReplyTests {
    @Test func aReplyTooLargeToSendBecomesAnError() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[1]) }
        _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
        let queue = DispatchQueue(label: "too-large")
        let connection = ClientConnection(fd: fds[0], queue: queue)
        let huge = String(repeating: "x", count: HostFrame.maxPayload)
        queue.sync {
            connection.start()
            // Not a reply (nobody waits for it): nothing is sent.
            connection.send(HostEventEnvelope(replyTo: nil, event: .screenText(id: UUID(), text: huge)))
            connection.send(HostEventEnvelope(replyTo: 9, event: .screenText(id: UUID(), text: huge)))
            connection.send(HostEventEnvelope(replyTo: 10, event: .ok))
        }
        defer { queue.sync { connection.close() } }
        var decoder = HostFrameDecoder()
        var received: [HostEventEnvelope] = []
        var buffer = [UInt8](repeating: 0, count: 65_536)
        #expect(eventually {
            let count = read(fds[1], &buffer, buffer.count)
            if count > 0 { decoder.append(Data(buffer[0..<count])) }
            while let frame = try? decoder.next() {
                if let envelope = try? HostCoding.decode(HostEventEnvelope.self, from: frame.payload) { received.append(envelope) }
            }
            return received.count >= 2
        })
        #expect(received == [HostEventEnvelope(replyTo: 9, event: ClientConnection.tooLarge), HostEventEnvelope(replyTo: 10, event: .ok)])
    }
}
