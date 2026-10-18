import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// What app.log says about a handover, on a fake host (a socket that speaks the protocol; no real host, no real
/// sessions): the connection dropping is the handover working, and only the welcome after it says how it went.
@MainActor
struct HostClientHandoverTests {
    /// What the fake host does when it's asked to hand over.
    enum OnHandover {
        /// Re-executes in place as `build`: the same pid, the connection dropped without an answer.
        case reExec(build: Int)
        /// The new build couldn't take over and went back to this one: the same pid and build.
        case fallBack
        /// Another host took the socket.
        case replacedBy(pid: Int32, build: Int)
        /// Gone, socket and all.
        case quit
        /// Says no, and carries on.
        case refuse(String)
    }

    /// A host on its own socket: welcomes every hello with one live session and the handover capability.
    final class FakeHost: @unchecked Sendable {
        let path = "/tmp/vsh-ho-\(UUID().uuidString.prefix(8)).sock"
        private let queue = DispatchQueue(label: "fake-host")
        private let onHandover: OnHandover
        private var pid: Int32
        private var build: Int
        private var listener: DispatchSourceRead?
        private var clients: [Int32: (source: DispatchSourceRead, decoder: HostFrameDecoder)] = [:]
        private let session = HostSession(id: UUID(), tty: "ttys999", childPID: 1, cwd: "/tmp/fake", command: nil, label: "Shell",
                                          agent: nil, title: "", startedAt: Date(), cols: 80, rows: 24, exit: nil)

        init(pid: Int32, build: Int, onHandover: OnHandover) throws {
            self.pid = pid
            self.build = build
            self.onHandover = onHandover
            let fd = try UnixSocket.listen(path: path)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.accept(fd) }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
            listener = source
        }

        func stop() {
            queue.sync {
                Array(clients.keys).forEach(drop)
                listener?.cancel()
                listener = nil
            }
            unlink(path)
        }

        private func accept(_ listening: Int32) {
            let fd = Darwin.accept(listening, nil, nil)
            guard fd >= 0 else { return }
            UnixSocket.configure(fd)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(fd) }
            source.setCancelHandler { Darwin.close(fd) }
            clients[fd] = (source, HostFrameDecoder())
            source.resume()
        }

        private func read(_ fd: Int32) {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { return drop(fd) }
            clients[fd]?.decoder.append(Data(buffer[0..<count]))
            while let frame = try? clients[fd]?.decoder.next() {
                guard let envelope = try? HostCoding.decode(HostRequestEnvelope.self, from: frame.payload) else { continue }
                handle(envelope, on: fd)
            }
        }

        private func handle(_ envelope: HostRequestEnvelope, on fd: Int32) {
            switch envelope.request {
            case .hello:
                send(.welcome(protocolVersion: HostProtocol.version, hostBuild: build, sessions: [session],
                              capabilities: [HostProtocol.Capability.handover], pid: pid), replyTo: envelope.seq, on: fd)
            case .handover:
                switch onHandover {
                case .reExec(let build):
                    self.build = build
                    drop(fd)
                case .fallBack:
                    drop(fd)
                case .replacedBy(let pid, let build):
                    self.pid = pid
                    self.build = build
                    drop(fd)
                case .quit:
                    Array(clients.keys).forEach(drop)
                    listener?.cancel()
                    listener = nil
                    unlink(path)
                case .refuse(let message):
                    send(.error(message), replyTo: envelope.seq, on: fd)
                }
            default:
                send(.ok, replyTo: envelope.seq, on: fd)
            }
        }

        private func send(_ event: HostEvent, replyTo: Int, on fd: Int32) {
            guard let payload = try? HostCoding.encode(HostEventEnvelope(replyTo: replyTo, event: event)) else { return }
            let frame = HostFrame.encode(.control, payload)
            _ = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }

        private func drop(_ fd: Int32) {
            clients.removeValue(forKey: fd)?.source.cancel()
        }
    }

    /// The client's app.log lines.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func note(_ line: String) { lock.lock(); all.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return all }
        var handover: [String] { lines.filter { $0.contains("handed over") || $0.contains("handover failed") } }
    }

    /// A client of `host` whose bundled build is 9, connected to it (an outdated host at build 8, so it hands over).
    func client(of host: FakeHost, log: Log) -> HostClient {
        let client = HostClient(socketPath: host.path, appKey: { nil }, bundledBuild: { 9 }, reconnectDelays: [0.05, 0.1, 0.2],
                                note: { log.note($0) })
        client.connectIfRunning()
        return client
    }

    @Test func aHandoverInPlaceIsLoggedAsHandedOver() async throws {
        let host = try FakeHost(pid: 31589, build: 8, onHandover: .reExec(build: 9))
        defer { host.stop() }
        let log = Log()
        let client = client(of: host, log: log)
        #expect(await until { client.state == .connected })
        #expect(log.handover == ["host: handed over (pid 31589, build 9)"])
        #expect(client.sessions.count == 1)
    }

    @Test func theOldBuildAnsweringIsLoggedAsAFailure() async throws {
        let host = try FakeHost(pid: 31589, build: 8, onHandover: .fallBack)
        defer { host.stop() }
        let log = Log()
        let client = client(of: host, log: log)
        #expect(await until { !log.handover.isEmpty })
        #expect(log.handover == ["host: handover failed: the old build answered (pid 31589, build 8; asked for 9)"])
        // Asked once for this build: the old one keeps serving its session.
        #expect(await until { client.state == .outdated(live: 1, compatible: true) })
    }

    @Test func aDifferentHostAnsweringIsLoggedAsAFailure() async throws {
        let host = try FakeHost(pid: 31589, build: 8, onHandover: .replacedBy(pid: 40000, build: 9))
        defer { host.stop() }
        let log = Log()
        let client = client(of: host, log: log)
        #expect(await until { client.state == .connected })
        #expect(log.handover == ["host: handover failed: a different host answered (pid 40000, build 9; was pid 31589)"])
    }

    @Test func aHostThatGoesAwayIsLoggedAsAFailure() async throws {
        let host = try FakeHost(pid: 31589, build: 8, onHandover: .quit)
        defer { host.stop() }
        let log = Log()
        let client = client(of: host, log: log)
        #expect(await until { client.state == .notRunning })
        #expect(log.handover == ["host: handover failed: the host (pid 31589) went away and no build answered"])
        #expect(client.sessions.allSatisfy { !$0.isLive })
    }

    @Test func aRefusalIsLoggedAsAFailure() async throws {
        let host = try FakeHost(pid: 31589, build: 8, onHandover: .refuse("Couldn't hand over: probe failed."))
        defer { host.stop() }
        let log = Log()
        let client = client(of: host, log: log)
        #expect(await until { !log.handover.isEmpty })
        #expect(log.handover == ["host: handover failed: Couldn't hand over: probe failed."])
        #expect(client.state == .outdated(live: 1, compatible: true))
    }

    @Test func theOutcomeNamesWhoAnswered() {
        let asked: (pid: Int32?, build: Int) = (31589, 9)
        #expect(HostClient.handoverOutcome(asked: asked, pid: 31589, build: 9) == "host: handed over (pid 31589, build 9)")
        #expect(HostClient.handoverOutcome(asked: asked, pid: 31589, build: 8).hasPrefix("host: handover failed: the old build"))
        #expect(HostClient.handoverOutcome(asked: asked, pid: 1, build: 9).hasPrefix("host: handover failed: a different host"))
        #expect(HostClient.handoverOutcome(asked: asked, pid: nil, build: 9).hasPrefix("host: handover failed: a different host"))
        // A host too old to give its pid: only the build tells.
        #expect(HostClient.handoverOutcome(asked: (nil, 9), pid: nil, build: 9) == "host: handed over (pid ?, build 9)")
    }
}
