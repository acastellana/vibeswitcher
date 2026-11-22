import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The server's Unix socket is bounded (the architecture review's row 4), against a process-started scratch node: at
/// most `NodeServer.maxConnections` connections, the newest past it told why and closed; a reader that doesn't read
/// closed past `maxPending` bytes waiting; an accept that fails for want of descriptors pauses accepting, said once,
/// then takes the connection that waited; a turn's reads end after `chunksPerTurn`. And the session host raises its
/// soft limit on descriptors, its sessions' programs getting the old one back.
@Suite(NodeTraits.linuxOnly)
struct NodeServerBoundsTests {
    private let scratch = Scratch()

    /// A raw connection to the server's socket: its first line (the hello, or a bye), read within `timeout`.
    final class Raw {
        let fd: Int32
        private var buffer = Data()

        init(_ path: String) throws { fd = try UnixSocket.connect(path: path) }
        deinit { Sys.close(fd) }

        /// The next line, or nil at the end, an error, or `timeout`.
        func line(timeout: TimeInterval = 10) -> Data? {
            let deadline = MacTime.real.awake() + timeout
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return Data(line)
                }
                let left = deadline - MacTime.real.awake()
                guard left > 0 else { return nil }
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, Int32(min(left, 1) * 1000)) >= 0 else { return nil }
                guard poller.revents != 0 else { continue }
                var chunk = [UInt8](repeating: 0, count: 65_536)
                let got = Sys.read(fd, &chunk, chunk.count)
                guard got > 0 else { return nil }
                buffer.append(contentsOf: chunk[..<got])
            }
        }

        /// Whether any byte comes within `timeout`.
        func bytes(timeout: TimeInterval) -> Bool {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return false }
            var byte: UInt8 = 0
            return Sys.read(fd, &byte, 1) == 1
        }

        /// Writes all of `data`, waiting while the socket is full. Whether it all went (false once the server closed it).
        func sendAll(_ data: Data) -> Bool {
            var offset = 0
            while offset < data.count {
                let wrote = data.withUnsafeBytes { Platform.Sockets.send(fd, $0.baseAddress! + offset, $0.count - offset) }
                if wrote > 0 {
                    offset += wrote
                } else if wrote < 0, errno == EAGAIN || errno == EINTR {
                    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&poller, 1, 1000)
                } else {
                    return false
                }
            }
            return true
        }

        /// Whether the server closed it (an end of file, after whatever it still sent).
        func closed(timeout: TimeInterval = 30) -> Bool {
            let deadline = MacTime.real.awake() + timeout
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while MacTime.real.awake() < deadline {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 1000) >= 0 else { return false }
                guard poller.revents != 0 else { continue }
                let got = Sys.read(fd, &chunk, chunk.count)
                if got == 0 { return true }
                if got < 0 { return errno == ECONNRESET }
            }
            return false
        }
    }

    static func isHello(_ line: Data?) -> Bool { line.flatMap { NodeWire.decode(NodeWire.Hello.self, $0) } != nil }
    static func bye(_ line: Data?) -> NodeWire.Bye? { line.flatMap { NodeWire.decode(NodeWire.Bye.self, $0) } }

    /// One process holding its share (`NodeServer.maxPerPeer`) is told why its next connection is closed, and can't
    /// keep a second process (the command line) from connecting and getting `status`.
    @Test func oneProcessAtItsShareCantLockOutAnother() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let path = node.serverSocket
        var (open, refused) = try await offPool { Result { () throws -> ([Raw], NodeWire.Bye?) in
            var open: [Raw] = []
            for _ in 0...NodeServer.maxPerPeer {
                let raw = try Raw(path)
                let first = raw.line()
                if let bye = Self.bye(first) { return (open, bye) }
                guard Self.isHello(first) else { break }
                open.append(raw)
            }
            return (open, nil)
        } }.get()
        let bye = try #require(refused, "no bye after \(open.count) connections")
        #expect(open.count == NodeServer.maxPerPeer)
        #expect(bye.reason.contains("this process has \(NodeServer.maxPerPeer) connections open"), "\(bye)")
        let status = try await node.run(["status"])
        #expect(status.status == 0, "\(status.output)\(status.errors)\n\(node.said)")
        // One closed: this process has room again.
        refused = nil
        open.removeLast()
        let again = await offPool { () -> Bool in
            let deadline = MacTime.real.awake() + 30
            while MacTime.real.awake() < deadline {
                if let raw = try? Raw(path), Self.isHello(raw.line()) { return true }
            }
            return false
        }
        #expect(again, "\(node.said)")
        open.removeAll()
    }

    /// At the limit the newcomer displaces the heaviest holder's longest-idle connection, one with no request first; a
    /// newcomer that isn't the user's displaces only connections that aren't either.
    @Test func theEvictionTakesTheHeaviestHoldersIdlestConnection() {
        func holder(_ pid: pid_t, voice: Bool = false, requested: Bool = true, idle: TimeInterval) -> NodeServer.Holder {
            NodeServer.Holder(id: ObjectIdentifier(NSObject()), pid: pid, voice: voice, requested: requested, idleSince: idle)
        }
        let quiet = holder(7, requested: false, idle: 50)
        let busy = [holder(7, idle: 10), holder(7, idle: 20), quiet]
        let lighter = [holder(8, idle: 1), holder(8, idle: 2)]
        let user = [holder(9, voice: true, requested: false, idle: 0)]
        let open = busy + lighter + user
        #expect(NodeServer.evictee(open, newcomerVoice: false) == quiet.id, "the heaviest holder's, one with no request since its hello first")
        #expect(NodeServer.evictee(open, newcomerVoice: true) == quiet.id)
        #expect(NodeServer.evictee(user, newcomerVoice: false) == nil, "the user's connections aren't another's to displace")
        #expect(NodeServer.evictee(user, newcomerVoice: true) == user[0].id)
        let ties = [holder(1, idle: 30), holder(2, idle: 5)]
        #expect(NodeServer.evictee(ties, newcomerVoice: false) == ties[1].id, "of equal holders, the longest idle")
    }

    /// A client that sends requests and never reads its replies: once more than `maxPending` bytes wait for it, it is
    /// closed, said in the log; the server answers others.
    @Test func aReaderThatDoesntReadIsClosedPastThePendingLimit() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let raw = try Raw(node.serverSocket)
        try #require(Self.isHello(raw.line()))
        // Each a small request with a reply about three times its size (`unknown-kind`): 12 MiB of replies.
        let one = NodeWire.line(NodeWire.Request(id: "x", kind: "no.such.kind"))
        let count = (12 << 20) / 90
        let sent = await offPool { () -> Int in
            var batch = Data()
            for _ in 0..<2_000 { batch.append(one) }
            var total = 0
            while total < count, raw.sendAll(batch) { total += 2_000 }
            return total
        }
        #expect(sent > 0)
        #expect(await eventually(timeout: 60) { node.said.contains("waited to be written to it, past \(NodeServer.maxPending)") }, "\(node.said)")
        let other = try WireClient(node)
        #expect(WireClient.reply(other.request("status", action: nil))?.ok == true)
    }

    /// The server's soft limit on descriptors lowered below what it holds (util-linux's prlimit, on a process of this
    /// uid), so its accept fails with EMFILE: said, accepting paused rather than tried again at once (its source would
    /// fire for as long as the connection waits); the limit put back, the connection that waited is taken.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: prlimit), "util-linux's prlimit sets another process's limit"))
    func anAcceptOutOfDescriptorsPausesAndThenTakesTheConnection() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let server = try #require(node.serverPID)
        let old = try #require(Self.descriptorLimits(server))
        try #require(try await Self.setSoftLimit(server, "8"))
        let waiting = try Raw(node.serverSocket)
        let said = await eventually(timeout: 30) { node.said.contains("vibeswitcher-server: the server couldn't accept a connection (errno \(EMFILE))") }
        let restored = try await Self.setSoftLimit(server, old.soft)
        #expect(said, "\(node.said)")
        #expect(restored)
        let taken = await offPool { Self.isHello(waiting.line(timeout: 30)) }
        #expect(taken, "\(node.said)")
    }

    /// The same for the session host's own socket (`HostServer.acceptFailed`): said on its stderr, then the connection
    /// that waited is taken (its challenge comes).
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: prlimit), "util-linux's prlimit sets another process's limit"))
    func aHostAcceptOutOfDescriptorsPausesAndThenTakesTheConnection() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let host = node.hostPID
        let old = try #require(Self.descriptorLimits(host))
        try #require(try await Self.setSoftLimit(host, "8"))
        let waiting = try Raw(node.socket)
        // On its stderr: its log's file is what it can't open now.
        let said = await eventually(timeout: 30) { node.said.contains("vibeswitcher-host: couldn't accept a connection (errno \(EMFILE))") }
        let restored = try await Self.setSoftLimit(host, old.soft)
        #expect(said, "\(node.said)")
        #expect(restored)
        let answered = await offPool { waiting.bytes(timeout: 30) }
        #expect(answered, "\(node.said)")
    }

    /// The host started with a soft limit of 512 open files (`prlimit --nofile=512:` execs it): it raises its own to
    /// the hard limit, its server child inherits that, and a session's program gets 512 back.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: prlimit), "util-linux's prlimit starts the host with a lower limit"))
    func theHostRaisesItsDescriptorLimitAndItsSessionsGetTheOldOne() async throws {
        let hard = try #require(Self.descriptorLimits(getpid())?.hard)
        try #require(hard == "unlimited" || (Int(hard) ?? 0) > 512, "the hard limit is \(hard)")
        let node = try await ScratchNode(scratch, hostPrefix: [Self.prlimit, "--nofile=512:"])
        defer { node.stop() }
        let host = try #require(Self.descriptorLimits(node.hostPID))
        #expect(host.soft == host.hard && host.hard == hard, "\(host)")
        let server = try #require(node.serverPID.flatMap(Self.descriptorLimits))
        #expect(server.soft == hard, "\(server)")
        let out = node.root.appendingPathComponent("ulimit.txt").path
        _ = try await node.spawn("ulimit -n > \(out); sleep 60")
        let read = await eventually(timeout: 60) { ((try? String(contentsOfFile: out, encoding: .utf8)) ?? "").hasSuffix("\n") }
        #expect(read && (try? String(contentsOfFile: out, encoding: .utf8)) == "512\n", "\((try? String(contentsOfFile: out, encoding: .utf8)) ?? "nothing")\n\(node.said)")
    }

    static let prlimit = "/usr/bin/prlimit"

    /// A process's soft and hard limits on open files, as /proc/<pid>/limits says them (readable for any process).
    static func descriptorLimits(_ pid: pid_t) -> (soft: String, hard: String)? {
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/limits", encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("Max open files") }) else { return nil }
        let words = line.dropFirst("Max open files".count).split(separator: " ")
        return words.count >= 2 ? (String(words[0]), String(words[1])) : nil
    }

    /// `pid`'s soft limit on open files set to `soft` (`prlimit --pid PID --nofile=SOFT:`). Whether it held.
    static func setSoftLimit(_ pid: pid_t, _ soft: String) async throws -> Bool {
        let ran = try await run(URL(fileURLWithPath: prlimit), ["--pid", String(pid), "--nofile=\(soft):"], environment: ["PATH": "/usr/bin:/bin"])
        return ran.status == 0 && descriptorLimits(pid)?.soft == soft
    }

    /// A turn's reads stop after `chunksPerTurn`, however much more waits.
    @Test func aTurnsReadsStopAtTheirShare() {
        var calls = 0
        #expect(NodeServer.readTurn { calls += 1; return true } == false)
        #expect(calls == NodeServer.chunksPerTurn)
        calls = 0
        #expect(NodeServer.readTurn { calls += 1; return calls < 3 })
        #expect(calls == 3)
    }
}
