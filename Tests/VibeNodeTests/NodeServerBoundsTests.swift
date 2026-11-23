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

    /// A client given a bye for its hello (a process past its share, a full server) says the server's reason, not
    /// only that no hello came (`NodeWire.greeting`, which the command line reads its first line with).
    @Test func aByeInPlaceOfTheHelloSaysWhy() {
        let bye = NodeWire.line(NodeWire.Bye(reason: "this process has 8 connections open to the server: close one first", code: nil))
        guard case .failure(let why) = NodeWire.greeting(bye.dropLast()) else {
            Issue.record("a bye taken as a hello")
            return
        }
        #expect(why.description == "the node's server closed the connection: this process has 8 connections open to the server: close one first")
        guard case .failure(let none) = NodeWire.greeting(nil), case .failure(let other) = NodeWire.greeting(Data("{}".utf8)) else {
            Issue.record("nothing taken as a hello")
            return
        }
        #expect(none.description == "the node's server sent no hello" && other == none)
    }

    /// The caps as one decision (`NodeServer.refusal`), over every connection that holds a descriptor (closing ones
    /// too): a process at its share, a share that isn't the user's at its own (its processes together), the slots kept
    /// for the user, and a full server: each newcomer past one is refused, saying why; nothing open is ever closed for it.
    @Test func theCapsRefuseANewcomerAndCloseNothing() {
        func holders(_ count: Int, pid: (Int) -> pid_t, share: String) -> [NodeServer.Holder] {
            (0..<count).map { NodeServer.Holder(pid: pid($0), share: share) }
        }
        let eight = holders(NodeServer.maxPerPeer, pid: { _ in 7 }, share: "pid 7")
        #expect(NodeServer.refusal(eight, pid: 7, share: "pid 7", voice: false)?.contains("this process has \(NodeServer.maxPerPeer) connections") == true)
        #expect(NodeServer.refusal(eight, pid: 7, share: "pid 7", voice: true)?.contains("this process has") == true, "the user's process too")
        #expect(NodeServer.refusal(eight, pid: 8, share: "pid 8", voice: false) == nil)
        // A share's processes together (a peer that forks): held to `maxPerShare` when it isn't the user's.
        let forked = holders(NodeServer.maxPerShare, pid: { pid_t(100 + $0 / 4) }, share: "session 99")
        #expect(NodeServer.refusal(forked, pid: 200, share: "session 99", voice: false)?.contains("share (session 99)") == true)
        #expect(NodeServer.refusal(forked, pid: 200, share: "session 99", voice: true) == nil, "the user's aren't held to a share")
        // The slots kept for the user: one that isn't the user's is refused there; the user's still gets in.
        let most = holders(NodeServer.maxConnections - NodeServer.reservedForUser, pid: { pid_t(300 + $0 / 4) }, share: "")
            .enumerated().map { NodeServer.Holder(pid: $0.element.pid, share: "cgroup /s\($0.offset / 8)") }
        #expect(NodeServer.refusal(most, pid: 900, share: "cgroup /x", voice: false)?.contains("kept for the user's own") == true)
        #expect(NodeServer.refusal(most, pid: 900, share: "cgroup /x", voice: true) == nil)
        // Full: everyone is refused, the user's too.
        let full = most + holders(NodeServer.reservedForUser, pid: { pid_t(800 + $0) }, share: "cgroup /user")
        #expect(full.count == NodeServer.maxConnections)
        #expect(NodeServer.refusal(full, pid: 901, share: "cgroup /y", voice: true)?.contains("\(NodeServer.maxConnections) connections open") == true)
    }

    /// Who sits idle (`NodeServer.idleReason`): no request within the hello's limit; then, with no subscription the hub
    /// serves, no request within the quiet limit. A subscriber may sit for good once it has asked.
    @Test func whoSitsIdleIsSaid() {
        let idle = NodeServer.Idle(hello: 30, quiet: 600)
        #expect(NodeServer.idleReason(accepted: 0, lastRequest: nil, subscribed: false, now: 29, idle: idle) == nil)
        #expect(NodeServer.idleReason(accepted: 0, lastRequest: nil, subscribed: false, now: 30, idle: idle) == "no request since the hello (30 s)")
        #expect(NodeServer.idleReason(accepted: 0, lastRequest: nil, subscribed: true, now: 30, idle: idle) != nil, "a subscription comes with a request")
        #expect(NodeServer.idleReason(accepted: 0, lastRequest: 10, subscribed: false, now: 609, idle: idle) == nil)
        #expect(NodeServer.idleReason(accepted: 0, lastRequest: 10, subscribed: false, now: 610, idle: idle) == "no request and no subscription for 10 minutes")
        #expect(NodeServer.idleReason(accepted: 0, lastRequest: 10, subscribed: true, now: 10_000, idle: idle) == nil)
        #expect(NodeServer.idleReason(accepted: 0, lastRequest: 10, subscribed: false, answering: true, now: 10_000, idle: idle) == nil,
                "a request still being answered (an engine's wait) isn't quiet")
    }

    /// A command that asks first (`end` looks its session up), then waits at the typed-code prompt past the quiet limit
    /// (2 s here; 10 minutes on the user's node, the time to read an `approve` batch): its connection closed meanwhile,
    /// it connects again, once and silently, and the session ends. The code is the action's (`NodeIds.code(action:)`),
    /// not the connection's.
    @Test func aCommandThatAskedFirstThenWaitedAtThePromptStillGoesThrough() async throws {
        let node = try await ScratchNode(scratch, hostArguments: ["--server-arg", ServerArguments.testIdleFlag + "1"])
        defer { node.stop() }
        let (session, _) = try await NodeAcceptanceTests.newClaude(node)
        let short = NodeAcceptanceTests.short(session)
        let path = node.serverSocket
        let ended = try await node.runOnTerminal(["end", short]) { code in
            // Held until a connection that asked once, made now, has been closed for its quiet: the command line's, which
            // asked before it, has been too.
            guard let later = try? Raw(path), Self.isHello(later.line()),
                  later.sendAll(NodeWire.line(NodeWire.Request(id: "q", kind: "no.such.kind"))) else { return code }
            while let line = later.line(timeout: 30) { if Self.bye(line) != nil { break } }
            return code
        }
        #expect(ended.status == 0 && ended.output.contains("ended: session \(short)"), "\(ended.output)\(ended.errors)\n\(node.said)")
    }

    /// The command line connects before it asks for the typed code, which can take longer than the hello's limit: its
    /// connection closed meanwhile, it connects again, once and silently, and the change goes through.
    @Test func aTypedCodeSlowerThanTheHelloLimitStillGoesThrough() async throws {
        let node = try await ScratchNode(scratch, hostArguments: ["--server-arg", ServerArguments.testIdleFlag + "1"])
        defer { node.stop() }
        let path = node.serverSocket
        let set = try await node.runOnTerminal(["set", "node_max_sessions", "7"]) { code in
            // Held until a connection made now has been closed for sitting idle: the command line's, made before it, has too.
            guard let later = try? Raw(path), Self.isHello(later.line()) else { return code }
            while let line = later.line(timeout: 30) { if Self.bye(line) != nil { break } }
            return code
        }
        #expect(set.status == 0 && set.output.contains("set node_max_sessions: \(MacLimits.defaultMaxSessions) → 7"), "\(set.output)\(set.errors)\n\(node.said)")
    }

    /// The server closes the command line's connection after its check that the connection is open and before its
    /// request is written (injected: the command line waits there for the close, `VIBESWITCHER_TEST_CLOSE_BEFORE_SEND`):
    /// the request wasn't taken, so it is sent again on a fresh connection and goes through, and nothing says its outcome
    /// isn't known.
    @Test func aServerThatClosesBetweenTheCheckAndTheSendIsAskedAgain() async throws {
        let node = try await ScratchNode(scratch, hostArguments: ["--server-arg", ServerArguments.testIdleFlag + "1"])
        defer { node.stop() }
        let set = try await ScratchNodes.onTerminal(commandLine.path, ["set", "node_max_sessions", "7"],
                                                    environment: node.environment(["VIBESWITCHER_TEST_CLOSE_BEFORE_SEND": "1"]), answer: { $0 })
        let said = set.output + set.errors
        #expect(set.status == 0 && said.contains("set node_max_sessions: \(MacLimits.defaultMaxSessions) → 7"), "\(said)\n\(node.said)")
        #expect(!said.contains("isn't known") && !said.contains("closed the connection"), "\(said)")
    }

    /// The idle byes say the server took no request on their connection (`NodeServer.tookNoRequest`); no other bye does.
    @Test func theIdleByesSayNoRequestWasTaken() {
        let idle = NodeServer.Idle(hello: 1, quiet: 120)
        let hello = try? #require(NodeServer.idleReason(accepted: 0, lastRequest: nil, subscribed: false, now: 2, idle: idle))
        let quiet = try? #require(NodeServer.idleReason(accepted: 0, lastRequest: 1, subscribed: false, now: 200, idle: idle))
        for reason in [hello, quiet].compactMap({ $0 }) { #expect(NodeServer.tookNoRequest(NodeWire.Bye(reason: reason, code: "busy")), "\(reason)") }
        for reason in ["the node is stopping", "a line over 1 bytes", "no room for this connection"] {
            #expect(!NodeServer.tookNoRequest(NodeWire.Bye(reason: reason, code: "busy")), "\(reason)")
        }
    }

    /// On a scratch node whose limits are 1 s and 2 s (`--test-idle=1`): a connection that never asks is told why and
    /// closed; one that asked once, then sat, is too; a subscriber older than both still answers.
    @Test func connectionsThatOnlySitThereAreClosed() async throws {
        let node = try await ScratchNode(scratch, hostArguments: ["--server-arg", ServerArguments.testIdleFlag + "1"])
        defer { node.stop() }
        let path = node.serverSocket
        let subscriber = try Raw(path)
        try #require(Self.isHello(subscriber.line()))
        #expect(subscriber.sendAll(NodeWire.line(NodeWire.Request(id: "s", kind: "subscribe", args: ["sub": .string("s1"), "collection": .string("sessions")]))))
        let silent = try Raw(path)
        try #require(Self.isHello(silent.line()))
        let once = try Raw(path)
        try #require(Self.isHello(once.line()))
        #expect(once.sendAll(NodeWire.line(NodeWire.Request(id: "q", kind: "no.such.kind"))))
        let silentBye = await offPool { () -> NodeWire.Bye? in
            while let line = silent.line(timeout: 30) { if let bye = Self.bye(line) { return bye } }
            return nil
        }
        #expect(silentBye?.reason == "no request since the hello (1 s)" && silentBye?.code == "busy", "\(String(describing: silentBye))")
        let onceBye = await offPool { () -> NodeWire.Bye? in
            while let line = once.line(timeout: 30) { if let bye = Self.bye(line) { return bye } }
            return nil
        }
        #expect(onceBye?.reason.hasPrefix("no request and no subscription for") == true, "\(String(describing: onceBye))")
        // The subscriber, which asked before both and has sat since, still answers.
        #expect(subscriber.sendAll(NodeWire.line(NodeWire.Request(id: "after", kind: "no.such.kind"))))
        let answered = await offPool { () -> Bool in
            while let line = subscriber.line(timeout: 30) {
                if Self.bye(line) != nil { return false }
                if NodeWire.decode(NodeWire.Reply.self, line)?.re == "after" { return true }
            }
            return false
        }
        #expect(answered, "\(node.said)")
    }

    /// Under the Mac's rule the reserved slots go by what a session's process can't change: a process under a live
    /// session's program, the host or the server isn't the user's whatever its environment says.
    @Test func theReservedSlotsUnderTheMacsRuleIgnoreTheSessionMarker() throws {
        let scratchRoot = scratch.url("approval-root")
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let queue = DispatchQueue(label: "reserved-slots")
        let requests = Requests(link: HostLink(dialer: NoHost(), root: scratchRoot, queue: queue), sessions: nil,
                                rule: VoiceRule(mode: .approval, scopes: [], uid: getuid(), says: VoiceRule.approvalSays),
                                root: scratchRoot, hostSocket: scratch.url("h.sock").path, commit: "test", hostPID: 4242)
        func facts(_ ancestry: [pid_t], marker: Bool) -> PeerFacts {
            PeerFacts(pid: ancestry[0], uid: getuid(), cgroup: nil, ancestry: ancestry.map { .init(pid: $0, startTicks: 1) },
                      terminal: .named("ttys009"), sessionMarker: marker, underRunner: false)
        }
        #expect(queue.sync { requests.mayBeUsersVoice(facts([9_100, 9_000], marker: false)) })
        #expect(!queue.sync { requests.mayBeUsersVoice(facts([9_100, 4242], marker: false)) }, "under the host, its marker unset")
        #expect(queue.sync { requests.mayBeUsersVoice(facts([9_100, 9_000], marker: true)) } == queue.sync { requests.mayBeUsersVoice(facts([9_100, 9_000], marker: false)) },
                "the marker counts for nothing either way")
        var unread = facts([9_100], marker: false)
        unread.ancestry = nil
        #expect(!queue.sync { requests.mayBeUsersVoice(unread) }, "an ancestry that can't be read gets no reserved slot")
    }

    private struct NoHost: HostDialer {
        func connect(queue: DispatchQueue, patience: TimeInterval) throws -> HostConnection { throw HostLink.Failure("no host in this test") }
    }

    /// A connection told `bye` that won't read its output still counts toward its process's share, and is closed within
    /// `NodeServer.closingLife`, its output dropped: the slot comes back though it never reads.
    @Test func aClosingConnectionCountsAndIsClosedWithinItsLife() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let path = node.serverSocket
        // This process's share taken, whatever it holds already (the node's start-up probe may still count, its end not
        // yet read under load); the last one admitted is the one that won't read.
        var others: [Raw] = []
        for _ in 0..<NodeServer.maxPerPeer {
            let raw = try Raw(path)
            guard Self.isHello(raw.line()) else { break }
            others.append(raw)
        }
        let last = others.popLast()
        let stuck = try #require(last, "no connection admitted")
        let count = 3_000
        var lines = Data()
        for index in 0..<count { lines.append(NodeWire.line(NodeWire.Request(id: "d\(index)", kind: "draft"))) }
        lines.append(NodeWire.line(NodeWire.Request(id: "end", kind: "no.such.kind", must: true)))
        #expect(await offPool { stuck.sendAll(lines) })
        // While it holds a descriptor it counts: a ninth is refused; once it is closed (never read), a ninth gets in.
        let admitted = await offPool { () -> (refused: Int, admitted: Bool) in
            var refused = 0
            let deadline = MacTime.real.awake() + 60
            while MacTime.real.awake() < deadline {
                guard let raw = try? Raw(path) else { continue }
                if Self.isHello(raw.line()) { return (refused, true) }
                refused += 1
            }
            return (refused, false)
        }
        #expect(admitted.admitted, "\(node.said)")
        #expect(admitted.refused > 0, "the closing connection was counted while it held its descriptor")
        let replies = await offPool { () -> Int in
            var got = 0
            while let line = stuck.line(timeout: 30) { if NodeWire.decode(NodeWire.Reply.self, line) != nil { got += 1 } }
            return got
        }
        #expect(replies < count, "its output was dropped at the close: \(replies) replies")
        others.removeAll()
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

    /// The host started with a soft limit of 2048 open files (`prlimit --nofile=2048:` execs it): it raises its own to
    /// the hard limit, its server child inherits that, and a session's program gets 2048 back, after a handover too.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: prlimit), "util-linux's prlimit starts the host with a lower limit"))
    func theHostRaisesItsDescriptorLimitAndItsSessionsGetTheOldOne() async throws {
        let hard = try #require(Self.descriptorLimits(getpid())?.hard)
        try #require(hard == "unlimited" || (Int(hard) ?? 0) > 2048, "the hard limit is \(hard)")
        let node = try await ScratchNode(scratch, hostPrefix: [Self.prlimit, "--nofile=2048:"])
        defer { node.stop() }
        let host = try #require(Self.descriptorLimits(node.hostPID))
        #expect(host.soft == host.hard && host.hard == hard, "\(host)")
        let server = try #require(node.serverPID.flatMap(Self.descriptorLimits))
        #expect(server.soft == hard, "\(server)")
        let out = node.root.appendingPathComponent("ulimit.txt").path
        _ = try await node.spawn("ulimit -n > \(out); sleep 60")
        let read = await eventually(timeout: 60) { ((try? String(contentsOfFile: out, encoding: .utf8)) ?? "").hasSuffix("\n") }
        #expect(read && (try? String(contentsOfFile: out, encoding: .utf8)) == "2048\n", "\((try? String(contentsOfFile: out, encoding: .utf8)) ?? "nothing")\n\(node.said)")

        // Handed over to the same build: the new image starts with the limit raised, and its sessions still get 2048.
        try await node.handOver()
        let after = node.root.appendingPathComponent("ulimit-after.txt").path
        _ = try await node.spawn("ulimit -n > \(after); sleep 60")
        let readAfter = await eventually(timeout: 60) { ((try? String(contentsOfFile: after, encoding: .utf8)) ?? "").hasSuffix("\n") }
        #expect(readAfter && (try? String(contentsOfFile: after, encoding: .utf8)) == "2048\n",
                "\((try? String(contentsOfFile: after, encoding: .utf8)) ?? "nothing")\n\(node.said)")
        #expect(Self.descriptorLimits(node.hostPID)?.soft == hard)
    }

    /// A fresh start's environment is the user manager's, which any process of the user can set: a carried soft limit
    /// planted there (0, which would leave every session unable to open a file) is refused, said, and the host's own
    /// soft limit before its raise is what its sessions get.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: prlimit), "util-linux's prlimit starts the host with a lower limit"))
    func aCarriedLimitPlantedForAFreshStartIsRefused() async throws {
        let node = try await ScratchNode(scratch, hostPrefix: ["/usr/bin/env", "VIBESWITCHER_HOST_NOFILE_BEFORE=0", Self.prlimit, "--nofile=2048:"])
        defer { node.stop() }
        let out = node.root.appendingPathComponent("ulimit.txt").path
        _ = try await node.spawn("ulimit -n > \(out); sleep 60")
        let read = await eventually(timeout: 60) { ((try? String(contentsOfFile: out, encoding: .utf8)) ?? "").hasSuffix("\n") }
        #expect(read && (try? String(contentsOfFile: out, encoding: .utf8)) == "2048\n", "\((try? String(contentsOfFile: out, encoding: .utf8)) ?? "nothing")\n\(node.said)")
        #expect(node.said.contains("VIBESWITCHER_HOST_NOFILE_BEFORE not taken: a fresh start takes none"), "\(node.said)")
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

    /// One connection pipelining thousands of requests each judged afresh (a draft, refused on the socket): they are taken
    /// a share a turn (`NodeServer.requestsPerTurn`), every one answered, in order, while another connection is answered
    /// meanwhile; and the refusals' log lines stop at their share (`Requests.refusalsPerWindow`).
    @Test func aPipelinedFloodIsTakenAShareATurnAndEveryRequestAnswered() async throws {
        let node = try await ScratchNode(scratch)
        defer { node.stop() }
        let flood = try Raw(node.serverSocket)
        try #require(Self.isHello(flood.line()))
        let count = 2_000
        var lines = Data()
        for index in 0..<count { lines.append(NodeWire.line(NodeWire.Request(id: "a\(index)", kind: "draft"))) }
        let sent = await offPool { flood.sendAll(lines) }
        #expect(sent)
        let other = try Raw(node.serverSocket)
        try #require(Self.isHello(other.line()))
        #expect(other.sendAll(NodeWire.line(NodeWire.Request(id: "b", kind: "no.such.kind"))))
        let answered = await offPool { () -> (other: TimeInterval?, last: TimeInterval?, ids: [String]) in
            var ids: [String] = []
            var last: TimeInterval?
            let otherAt = other.line(timeout: 120).map { _ in MacTime.real.awake() }
            while ids.count < count, let line = flood.line(timeout: 120) {
                if let reply = NodeWire.decode(NodeWire.Reply.self, line) { ids.append(reply.re) }
                last = MacTime.real.awake()
            }
            return (otherAt, last, ids)
        }
        #expect(answered.ids == (0..<count).map { "a\($0)" }, "every request answered once, in order: \(answered.ids.count)")
        let otherAt = try #require(answered.other, "the other connection got no reply")
        #expect(otherAt < (answered.last ?? 0), "the other connection was answered before the flood's last reply")
        // At most `refusalsPerWindow` lines a window (a loaded machine may take more than one window for them all), the
        // fifth saying the rest are counted.
        let refusals = node.said.components(separatedBy: "\n").filter { $0.contains("refused draft from pid") }
        #expect(refusals.count >= Requests.refusalsPerWindow && refusals.count < count / 20, "\(refusals.count) refusal lines")
        #expect(refusals.count >= Requests.refusalsPerWindow && refusals[Requests.refusalsPerWindow - 1].contains("are counted, not logged"), "\(refusals)")
    }

    /// What a sender's facts read of `/proc` is capped: an environment past its limit is unreadable (which the voice
    /// rule refuses), a command line past its limit is read to it.
    @Test func whatIsReadOfAProcessIsCapped() throws {
        let environment = try #require(Platform.Processes.environment(getpid()))
        let size = environment.reduce(0) { $0 + $1.utf8.count + 1 }
        #expect(Platform.Processes.environment(getpid(), limit: size - 1) == nil)
        #expect(Platform.Processes.environment(getpid(), limit: size)?.count == environment.count)
        let arguments = Platform.Processes.arguments(getpid())
        try #require(!arguments.isEmpty)
        #expect(Platform.Processes.arguments(getpid(), limit: 3) == [String(arguments[0].prefix(3))])
        #expect(PeerFacts.deepest <= 64 && PeerFacts.ancestorArguments <= 16 * 1024)
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
