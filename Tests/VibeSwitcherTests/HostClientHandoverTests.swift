import Darwin
import Foundation
import Testing
@testable import VibeCore
@testable import VibeHost
@testable import VibeSwitcher

/// What app.log says about a handover, on a fake host (a socket that speaks the protocol; no real host, no real
/// sessions): the connection dropping is the handover working, and only the welcome after it says how it went.
@MainActor
struct HostClientHandoverTests {
    /// What the fake host does when it's asked to hand over.
    indirect enum OnHandover {
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
        /// The new build's probe takes this long (a loaded Mac's first exec), then the rest as `then`.
        case after(TimeInterval, then: OnHandover)
        /// The probe ends when the test says so (`FakeHost.cue()`), then the rest as `then`: an answer ordered after
        /// something the client logged, not by a timer racing the client's own on a loaded Mac.
        case onCue(then: OnHandover)
        /// The probe goes on for as long as the test does.
        case hold
    }

    /// A host on its own socket: welcomes every hello with one live session and the handover capability.
    final class FakeHost: @unchecked Sendable {
        /// The short folder its socket is in, removed with it.
        private let temp = Scratch()
        let path: String
        private let queue = DispatchQueue(label: "fake-host")
        private let onHandover: OnHandover
        private var pid: Int32
        private var build: Int
        private var listener: DispatchSourceRead?
        /// The answer an `.onCue` handover holds back until `cue()`.
        private var cued: (() -> Void)?
        private var clients: [Int32: (source: DispatchSourceRead, decoder: HostFrameDecoder)] = [:]
        private let session = HostSession(id: UUID(), tty: "ttys999", childPID: 1, cwd: "/tmp/fake", command: nil, label: "Shell",
                                          agent: nil, title: "", startedAt: Date(), cols: 80, rows: 24, exit: nil)

        init(pid: Int32, build: Int, onHandover: OnHandover) throws {
            self.pid = pid
            self.build = build
            self.onHandover = onHandover
            path = try temp.shortFolder("vsh-ho") + "/h.sock"
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
            rmdir((path as NSString).deletingLastPathComponent)
        }

        /// Ends an `.onCue` handover's probe: the held answer goes now. False if no handover was asked yet.
        @discardableResult
        func cue() -> Bool {
            queue.sync {
                guard let answer = cued else { return false }
                cued = nil
                answer()
                return true
            }
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
                handOver(onHandover, replyTo: envelope.seq, on: fd)
            case .screen:
                // Never answered: the request's own wait ends it.
                break
            default:
                send(.ok, replyTo: envelope.seq, on: fd)
            }
        }

        private func handOver(_ how: OnHandover, replyTo seq: Int, on fd: Int32) {
            switch how {
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
                send(.error(message), replyTo: seq, on: fd)
            case .after(let delay, let then):
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.handOver(then, replyTo: seq, on: fd) }
            case .onCue(let then):
                cued = { [weak self] in self?.handOver(then, replyTo: seq, on: fd) }
            case .hold:
                break
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
    /// `wait`: its handover's wait and breadcrumb, shortened.
    func client(of host: FakeHost, log: Log, wait: (handover: TimeInterval, breadcrumb: TimeInterval)? = nil) -> HostClient {
        let client = HostClient(socketPath: host.path, appKey: { nil }, bundledBuild: { 9 }, reconnectDelays: [0.05, 0.1, 0.2],
                                note: { log.note($0) })
        if let wait {
            client.handoverWait = wait.handover
            client.handoverBreadcrumb = wait.breadcrumb
        }
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

    /// The host's probe of the new build takes past a request's 15 s (a loaded Mac's first exec waits on amfid): the
    /// handover is waited for, with a breadcrumb every 15 s, and logged as handed over; never as failed first.
    @Test func aProbePastFifteenSecondsIsWaitedFor() async throws {
        let host = try FakeHost(pid: 31589, build: 8, onHandover: .after(20, then: .reExec(build: 9)))
        defer { host.stop() }
        let log = Log()
        let client = client(of: host, log: log)
        #expect(await until { client.state == .connected })
        #expect(log.handover == ["host: handed over (pid 31589, build 9)"], "\(log.lines)")
        #expect(log.lines.contains("host: handover: waiting for the new build's probe, 15 s"), "\(log.lines)")
        #expect(!log.lines.contains { $0.contains("didn't answer") || $0.contains("no answer") }, "\(log.lines)")
    }

    /// While a handover is waited for, any other request still gets its 15 s.
    @Test func otherRequestsKeepTheirFifteenSecondsDuringAHandover() async throws {
        let host = try FakeHost(pid: 31589, build: 8, onHandover: .hold)
        defer { host.stop() }
        let log = Log()
        let client = client(of: host, log: log)
        #expect(await until { log.lines.contains { $0.hasPrefix("host: handing over") } })
        let asked = Date()
        var screen: (text: String?, after: TimeInterval)?
        client.screen(UUID()) { screen = ($0, Date().timeIntervalSince(asked)) }
        #expect(await until { screen != nil })
        let unanswered = try #require(screen)
        #expect(unanswered.text == nil && unanswered.after >= 14.9, "\(unanswered)")
        // The handover is still waited for.
        #expect(log.handover.isEmpty && !log.lines.contains { $0.contains("no answer") }, "\(log.lines)")
        #expect(client.state == .outdated(live: 1, compatible: true))
    }

    /// The handover's wait runs out and the host hands over after it: the connection was kept, and the new build's
    /// welcome is the handover's success. The host answers once the app has logged its wait out, so that's the order
    /// however loaded the Mac.
    @Test func aHandoverAfterTheWaitIsLoggedAsHandedOver() async throws {
        let host = try FakeHost(pid: 31589, build: 8, onHandover: .onCue(then: .reExec(build: 9)))
        defer { host.stop() }
        let log = Log()
        let client = client(of: host, log: log, wait: (handover: 2, breadcrumb: 1))
        #expect(await until { log.lines.contains { $0.hasPrefix("host: handover: no answer in") } }, "\(log.lines)")
        #expect(log.handover.isEmpty, "\(log.lines)")
        #expect(await until { host.cue() })
        #expect(await until { client.state == .connected })
        #expect(log.handover == ["host: handed over after the wait (pid 31589, build 9)"], "\(log.lines)")
        let waiting = log.lines.filter { $0.hasPrefix("host: handover: ") }
        #expect(waiting == ["host: handover: waiting for the new build's probe, 1 s",
                            "host: handover: no answer in 2 s; the connection stays open and the next welcome says how it went"])
    }

    /// The host refuses after the app stopped waiting: that's the handover failing, and the old build carries on.
    @Test func aRefusalAfterTheWaitIsLoggedAsAFailure() async throws {
        let host = try FakeHost(pid: 31589, build: 8, onHandover: .onCue(then: .refuse("Couldn't hand over: probe failed.")))
        defer { host.stop() }
        let log = Log()
        let client = client(of: host, log: log, wait: (handover: 1, breadcrumb: 1))
        #expect(await until { log.lines.contains { $0.hasPrefix("host: handover: no answer in") } }, "\(log.lines)")
        #expect(log.handover.isEmpty, "\(log.lines)")
        #expect(await until { host.cue() })
        #expect(await until { !log.handover.isEmpty })
        #expect(log.handover == ["host: handover failed: Couldn't hand over: probe failed."], "\(log.lines)")
        #expect(log.lines.contains { $0.hasPrefix("host: handover: no answer in 1 s") }, "\(log.lines)")
        #expect(client.state == .outdated(live: 1, compatible: true))
    }

    /// The app's wait covers the host's: its probe limit, and a margin for saving the sessions and the exec.
    @Test func theHandoverWaitCoversTheHostsProbe() {
        #expect(HostClient.hostProbeLimit == HostHandover.probeLimit)
        let client = HostClient(socketPath: "/nonexistent", bundledBuild: { 0 }, note: { _ in })
        #expect(client.handoverWait >= HostHandover.probeLimit + 15)
        #expect(client.handoverBreadcrumb == 15)
        #expect(HostClient.replyWait == 15)
    }

    @Test func theOutcomeNamesWhoAnswered() {
        let asked: (pid: Int32?, build: Int) = (31589, 9)
        #expect(HostClient.handoverOutcome(asked: asked, pid: 31589, build: 9) == "host: handed over (pid 31589, build 9)")
        #expect(HostClient.handoverOutcome(asked: asked, pid: 31589, build: 9, afterTheWait: true)
                == "host: handed over after the wait (pid 31589, build 9)")
        #expect(HostClient.handoverOutcome(asked: asked, pid: 31589, build: 8, afterTheWait: true).hasPrefix("host: handover failed: the old build"))
        #expect(HostClient.handoverOutcome(asked: asked, pid: 31589, build: 8).hasPrefix("host: handover failed: the old build"))
        #expect(HostClient.handoverOutcome(asked: asked, pid: 1, build: 9).hasPrefix("host: handover failed: a different host"))
        #expect(HostClient.handoverOutcome(asked: asked, pid: nil, build: 9).hasPrefix("host: handover failed: a different host"))
        // A host too old to give its pid: only the build tells.
        #expect(HostClient.handoverOutcome(asked: (nil, 9), pid: nil, build: 9) == "host: handed over (pid ?, build 9)")
    }
}
